## ccprobe.nim -- C compiler dependency-header PROBING (RFC-0006/issue #16;
## split out to its narrower scope, CR7 code review 2026-09-21).
##
## Answers ONE question: which headers did this translation unit actually
## include, given the exact `ccCmd` a real compile ran. This module used to
## also answer "what compiler+runtime is this host" (toolchain-identity
## fingerprinting, RFC-0004) -- an unrelated concern sharing nothing with this
## one but the word "cc". CR7 moved that half to `crisol/ccidentity`; see that
## module's doc for the identity-side API (`ccVersion`, `cachedCcFingerprint`,
## `CcFingerprint`, etc.) and for where the shared process-execution seam
## (`RunProc`/`realRun*`/`lastProbeStderr`) ended up (`crisol/toolrun`, a third
## module -- see its own doc for why).
##
## **This module is now PURE and I/O-free.** None of `shellSplit`,
## `deriveDepInvocation`, `parseCcMDeps`, `parseMsvcSourceDeps`, or
## `depIncludeHeaders` spawns a process, reads a file, or hashes anything --
## each one transforms a string a CALLER already captured (typically via
## `crisol/toolrun`'s `RunProc` seam, replayed through `realRunIn`). That is a
## direct, visible consequence of the CR7 split: before it, this file imported
## `crisol/toolexec` and `crisol/fnv` purely to serve the identity half: this
## half never called either. Neither import survived the split.
##
## These four procs (plus their private helpers below) originated in
## `artifactid.nim` (RFC-0006) and were moved here (issue #16) so
## `crisol/closure`'s `extractCompileInputs` could reuse them without
## reimplementing `cc -M` parsing. `artifactid.nim` re-exports the ones its
## own callers use unqualified (`export ccprobe.shellSplit`, etc.), so every
## existing caller that does `import crisol/artifactid` keeps compiling
## unchanged.
##
## Cycle-freeness: this module imports only `crisol/paths` (for
## `ReportedPath` -- see below) among crisol modules, and `paths.nim`'s only
## crisol import is the std-only leaf `crisol/ioutils`, so this module's own
## crisol-dependency graph terminates immediately rather than reaching back toward
## `closure`/`depgraph`: `depgraph.nim` imports `closure.nim`, and
## `artifactid.nim` imports `depgraph.nim` -- so `closure.nim` importing
## `artifactid.nim` directly would close a cycle
## (closure -> artifactid -> depgraph -> closure), and this module sits
## outside that cycle entirely, same as before the split.

import std/[json, os, strutils]
import crisol/paths     # CR10: ReportedPath -- `parseCcMDeps`/`parseMsvcSourceDeps`/
                        # `depIncludeHeaders` yield foreign-tool header spellings in this
                        # type, never a bare `string`, so provenance survives into
                        # `closure`/`artifactid`'s consumption without an argument either
                        # of them could forget to pass. `paths.nim` imports only std plus
                        # the std-only `crisol/ioutils` leaf (see its own imports), so it
                        # is as terminal as `toolexec`/`fnv` were for the identity half
                        # before this split -- this does not reopen the cycle this
                        # module's doc comment (above) documents avoiding.

# ---------------------------------------------------------------------------
# cc -M invocation derivation (moved from artifactid.nim, issue #16 — see
# module doc above for why this lives here rather than in artifactid.nim)
# ---------------------------------------------------------------------------

proc shellSplit*(s: string): tuple[toks: seq[string]; ok: bool] =
  ## Tokenizes a manifest `ccCmd` string shell-AWARE, for `deriveDepInvocation`'s
  ## own use below — a whitespace-containing path (realistic under WSL2 — the
  ## RFC-0006 review itself calls this out) would otherwise silently corrupt
  ## a naive `splitWhitespace()` derivation instead of failing loudly.
  ##
  ## Minimal POSIX-shell-like tokenizer: single-quoted segments (literal, no
  ## escapes inside — matches `sh`), double-quoted segments (backslash
  ## escapes `\\`, `\"`, `\$`, `` \` `` inside — matches `sh`), and
  ## backslash-escaping outside quotes. Whitespace (space/tab/newline/CR)
  ## separates tokens outside quotes. `ok = false` on an unterminated quote
  ## or a trailing unescaped backslash — cases this parser cannot
  ## disambiguate; callers MUST treat that as a derivation failure
  ## (fail-safe: never guess, never emit a wrong-but-plausible tokenization).
  ##
  ## This is deliberately the SAME quoting convention `std/os.quoteShellPosix`
  ## produces (single-quote-wrap, `'\''`-escape for an embedded quote), so it
  ## correctly round-trips a Nim-generated cc command whose `-I` argument
  ## contains a space (realistic under WSL2 / a mounted toolchain) — the real
  ## compile runs that same string through a shell (`execProcesses`'s
  ## `poEvalCommand` — see compiledriver.nim's module doc), so deriving the
  ## `cc -M` probe args must tokenize identically or the probe silently runs
  ## with wrong/omitted flags (R1b).
  var toks: seq[string]
  var cur = ""
  var haveCur = false
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i]
    case c
    of ' ', '\t', '\n', '\r':
      if haveCur:
        toks.add cur
        cur = ""
        haveCur = false
      inc i
    of '\'':
      haveCur = true
      inc i
      while i < n and s[i] != '\'':
        cur.add s[i]
        inc i
      if i >= n:
        return (toks: newSeq[string](), ok: false)   # unterminated single quote
      inc i   # skip closing quote
    of '"':
      haveCur = true
      inc i
      while i < n and s[i] != '"':
        if s[i] == '\\' and i + 1 < n and s[i + 1] in {'\\', '"', '$', '`'}:
          cur.add s[i + 1]
          i += 2
        else:
          cur.add s[i]
          inc i
      if i >= n:
        return (toks: newSeq[string](), ok: false)   # unterminated double quote
      inc i   # skip closing quote
    of '\\':
      when defined(windows):
        # RFC-0009 B4a: on Windows a bare `\` outside quotes is a LITERAL
        # path separator, not a shell escape — Windows/MSVC argv rules only
        # treat `\` as special immediately before a `"` (already handled by
        # the `"` case above; a lone backslash between tokens is never an
        # escape). The nimcache manifest's `compile[]` ccCmd strings on
        # Windows are backslash-separated paths, NOT POSIX-escaped, so
        # consuming `\` as an escape here would corrupt e.g. `-o
        # obj\add.obj` into `-o objadd.obj`, and deriveDepInvocation's
        # ccCmdOutputObj match (closure.nim) would then never find it.
        # POSIX keeps the original escaping tokenizer unconditionally (the
        # `else` branch below) — this `when` compiles to only ONE arm per
        # target, so POSIX output is byte-identical to before this fix.
        haveCur = true
        cur.add c
        inc i
      else:
        haveCur = true
        if i + 1 < n:
          cur.add s[i + 1]
          i += 2
        else:
          return (toks: newSeq[string](), ok: false)   # trailing unescaped backslash
    else:
      haveCur = true
      cur.add c
      inc i
  if haveCur:
    toks.add cur
  result = (toks: toks, ok: true)

type
  CcFamily* = enum
    ccfGnuMake   ## gcc/clang/cc: `-M`, GNU-make-style dependency rule on stdout
    ccfMsvc      ## cl/vccexe/clang-cl: `/Zs /sourceDependencies-`, JSON on stdout

  DepProbeError* = enum
    ## Why a dependency probe produced no usable header set. `dpeNone` is the
    ## only value that means "trust the headers"; every other value MUST reach
    ## the caller as a loud failure. An empty header set is a legitimate
    ## answer (a `.c` file that includes nothing); "the probe did not answer"
    ## is not, and the two were indistinguishable before issue #21 -- which is
    ## how a vcc host recorded a one-entry bogus closure and called it sound.
    dpeNone         ## parsed; `headers` is the real answer, empty or not
    dpeNoJson       ## no `/sourceDependencies` document on stdout at all
    dpeBadJson      ## a document that is not the shape cl documents
    dpeNoIncludes   ## a valid document whose `Data` carries no `Includes` array

const MsvcDrivers = ["cl", "vccexe", "clang-cl"]
  ## Compiler-driver basenames that take MSVC-spelled flags. `clang-cl` is
  ## here deliberately even though it does NOT implement
  ## `/sourceDependencies`: it accepts `/`-spelled flags, so the GNU arm
  ## would be wrong for it too, and the JSON-absence check turns its silence
  ## into a loud, specific failure instead of an empty header set. Nothing in
  ## crisol claims clang-cl support.
  ##
  ## Not exported (CR8): zero external references -- read only by
  ## `ccFamilyOfDriver`, below, in this module.

proc ccFamilyOfDriver*(driver: string): CcFamily =
  ## Classify a compile command by the driver token the MANIFEST ITSELF
  ## recorded -- never by a compile-time `defined(vcc)`, never by the host OS,
  ## never by a global config.
  ##
  ## Two reasons, both load-bearing. A crisol built by gcc can be asked to
  ## read a nimcache produced by cl (and the reverse), so the reading
  ## process's own toolchain says nothing about the artifact in front of it.
  ## And the classification is PER COMPILE UNIT: one manifest's `compile`
  ## array is not guaranteed homogeneous, and a rule keyed on the whole run
  ## would have to pick a winner.
  ##
  ## Matching is on the basename, case-folded, with any `.exe` suffix
  ## removed, so an absolute driver path out of a real manifest
  ## (`C:\nim\...\vccexe.exe`) classifies the same as a bare `vccexe`.
  var base = driver.extractFilename.toLowerAscii
  if base.endsWith(".exe"):
    base.setLen(base.len - 4)
  result = if base in MsvcDrivers: ccfMsvc else: ccfGnuMake

type
  GnuOutputFlag* = enum
    ## How (if at all) one already-tokenized ccCmd token spells the GNU
    ## `-o <obj>` output flag -- the ONE fact `deriveDepInvocation` (below,
    ## which STRIPS it) and `closure.ccCmdOutputObj` (which EXTRACTS it)
    ## must agree on bit for bit (CR9). Before this type existed each proc
    ## hard-coded its own copy of `t == "-o"` (separated) and
    ## `t.startsWith("-o") and t.len > 2` (fused), with no shared constant
    ## or helper and no test exercising both against the same `ccCmd` -- so
    ## a divergence between them would have been silent, exactly the defect
    ## class `closure.nim`'s own `ccCmdOutputObj` doc records as having
    ## already broken MSVC impact selection once (issue #21 layer 2, there
    ## for the MSVC `/Fo` spelling instead of this GNU one).
    ##
    ## This type does NOT cover MSVC's `/Fo`/`-Fo` grammar -- verified while
    ## fixing CR9, that spelling is genuinely single-owner:
    ## `deriveDepInvocation`'s MSVC arm is a blanket verbatim replay of the
    ## whole command that never mentions `/Fo` at all (see its own doc,
    ## below), so only `closure.ccCmdOutputObj` needs to know it, and there
    ## is nothing to share.
    gofNone        ## `tok` is not the output flag in either form
    gofSeparated   ## `tok` IS `-o`; the value is the NEXT token
    gofFused       ## `tok` is `-o<obj>` fused; the value is embedded in `tok`

proc classifyGnuOutputFlag*(tok: string): GnuOutputFlag =
  ## Classify ONE already-tokenized ccCmd token against the GNU `-o`
  ## output-flag grammar (CR9). See `GnuOutputFlag` for why this is the
  ## single place that grammar is spelled out.
  if tok == "-o": gofSeparated
  elif tok.startsWith("-o") and tok.len > 2: gofFused
  else: gofNone

proc gnuFusedOutputValue*(tok: string): string =
  ## The value embedded in a token the caller has already classified
  ## `gofFused` via `classifyGnuOutputFlag` -- `-ofoo` -> `foo`. Behaviour is
  ## unspecified if `tok` was not so classified first.
  tok[2 .. ^1]

proc deriveDepInvocation*(ccCmd: string):
    tuple[cmd: string; args: seq[string]; sourceFile: string;
          family: CcFamily; ok: bool] =
  ## Derive a dependency-generation invocation from one manifest `ccCmd`
  ## string (see `closure.parseCompileManifest`), in whichever form the
  ## driver that produced it understands. The family is classified from the
  ## command's own first token via `ccFamilyOfDriver` and returned alongside,
  ## because the CALLER must parse the output with the matching parser --
  ## feeding a `/sourceDependencies` document to the make-rule parser yields
  ## a plausible-looking, entirely wrong header list.
  ##
  ## **MSVC arm: a pure prepend, with ZERO removals.** `@["/Zs",
  ## "/sourceDependencies-"]` goes in front and every remaining token is
  ## replayed verbatim, including the `/c` and `/Fo<obj>` that the GNU arm
  ## below must strip. This is sound because `/Zs` (syntax-check only)
  ## DOMINATES both: measured against cl 19.44, no `.obj`, no `.pdb` and no
  ## `.idb` is written even with both flags left in place. It is a strictly
  ## stronger form of the replicate-don't-allow-list rule than the GNU arm
  ## can manage, since `-M` does not suppress `-c` -- and it is what stops
  ## the probe rewriting the nimcache object as a side effect.
  ##
  ## The GNU arm is unchanged:
  ##
  ## **Review Finding 1 (soundness): REPLICATE the real command, don't
  ## allow-list.** Every flag token survives VERBATIM except the two that
  ## must not be there for a `-M` run: the compile-action flag `-c`, and the
  ## output flag `-o <obj>` — removed in EITHER its space-separated form
  ## (the `-o` token AND the single token immediately following it) or its
  ## fused form (a token starting with `-o` and longer than 2 characters,
  ## e.g. `-ofoo`; that token alone is dropped, it has no separate argument).
  ## `-M` is prepended and the original source file (the command's last
  ## shell token — matching `closure.parseCompileManifest`'s own convention
  ## that the compiled `.c` is always the final argument) is appended last.
  ## See `artifactid.nim`'s module doc's "ccIncludeClosure()" section for WHY
  ## this must be a denylist of exactly these two things, never an allow-list
  ## of flags assumed to matter: any OTHER flag (`-isystem`, `-iquote`,
  ## `-include`, `-nostdinc`, …) changes header resolution just as much as
  ## `-I`/`-D`/`-std` and must reach the probe unchanged.
  ##
  ## Tokenizes via `shellSplit` — shell-AWARE (R1b), not a naive
  ## `splitWhitespace` — because the real compile runs `ccCmd` through a
  ## shell (compiledriver's `execProcesses`/`poEvalCommand`), so a
  ## whitespace-naive split would mis-tokenize a shell-quoted path
  ## containing a space and silently derive a WRONG-but-nonempty probe
  ## (feeds R1's soundness bug). `ok = false` (R4/R1b) — never a raise, never
  ## a `Defect` — whenever the command can't be cleanly tokenized (an
  ## unterminated quote) OR has fewer than 2 tokens (no source file to
  ## target): a per-unit oddity must degrade, never crash the worker past
  ## its `except CatchableError` escape hatch (R4).
  let (toks, splitOk) = shellSplit(ccCmd)
  if not splitOk or toks.len < 2:
    return (cmd: "", args: newSeq[string](), sourceFile: "",
            family: ccfGnuMake, ok: false)
  let cc = toks[0]
  let sourceFile = toks[^1]
  let family = ccFamilyOfDriver(cc)

  case family
  of ccfMsvc:
    var kept: seq[string] = @["/Zs", "/sourceDependencies-"]
    for idx in 1 ..< toks.len:
      kept.add toks[idx]     # verbatim replay -- nothing is removed
    result = (cmd: cc, args: kept, sourceFile: sourceFile,
              family: family, ok: true)
  of ccfGnuMake:
    var kept: seq[string] = @["-M"]
    var idx = 1
    while idx < toks.len - 1:
      let t = toks[idx]
      if t == "-c":
        inc idx   # drop the compile-action flag
        continue
      case classifyGnuOutputFlag(t)   # CR9: the one shared grammar
      of gofSeparated:
        idx += 2   # drop the flag AND its separated argument
        continue
      of gofFused:
        inc idx   # drop the fused "-o<obj>" form (no separate argument)
        continue
      of gofNone:
        discard
      kept.add t
      inc idx
    kept.add sourceFile
    result = (cmd: cc, args: kept, sourceFile: sourceFile,
              family: family, ok: true)

proc findRuleTargetColon(s: string): int =
  ## Locate the colon that separates a GNU make rule's TARGET from its
  ## dependency list — never a Windows drive-letter colon (`C:/...` or
  ## `C:\...`). A drive-letter colon is always immediately followed by a
  ## path separator; the rule's real target colon never is (whatever follows
  ## it is the start of the dependency list, or nothing). This is a property
  ## of the rule TEXT itself — issue CR15 — so it must classify correctly
  ## regardless of which host is parsing it, including a non-Windows crisol
  ## reading a mingw-produced rule.
  result = -1
  var start = 0
  while true:
    let idx = s.find(':', start)
    if idx < 0:
      return -1
    if idx + 1 < s.len and s[idx + 1] in {'/', '\\'}:
      start = idx + 1
      continue
    return idx

proc unescapeMakeRuleTokens(depsStr: string): seq[string] =
  ## Split a GNU make dependency-rule's token list, reversing `-M`'s own
  ## escaping (cpp's dependency writer, mkdeps.cc `make_write_name`) instead
  ## of naively `splitWhitespace()`-ing through it — issue W8. Undoing this
  ## is a property of the rule TEXT's own escaping convention, never of the
  ## host reading it (unlike `shellSplit`'s `ccCmd`-tokenizing backslash arm,
  ## which is intentionally host-gated for the unrelated reason RFC-0009 B4a
  ## documents — that gate is a separate, tracked finding (W9e) and is not
  ## reused or imitated here).
  ##
  ## - A run of N backslashes immediately before a space/tab collapses to
  ##   `N div 2` literal backslashes; if N is odd the space/tab is an
  ##   ESCAPED, embedded character of the token (not a separator), and if N
  ##   is even (including zero) the backslashes are literal and the
  ##   space/tab IS the separator. This is make's own quoting rule for
  ##   whitespace in a dependency-rule path.
  ## - `\#` unescapes to a literal `#`.
  ## - `$$` unescapes to a literal `$`.
  ## - A bare, unescaped space/tab/newline/CR is always a separator.
  result = @[]
  var cur = ""
  var haveCur = false
  var i = 0
  let n = depsStr.len
  while i < n:
    let c = depsStr[i]
    if c == '\\' and i + 1 < n and depsStr[i + 1] == '#':
      cur.add '#'
      haveCur = true
      i += 2
    elif c == '\\':
      var j = i
      while j < n and depsStr[j] == '\\': inc j
      let bsCount = j - i
      if j < n and depsStr[j] in {' ', '\t'}:
        let half = bsCount div 2
        for _ in 0 ..< half: cur.add '\\'
        if half > 0: haveCur = true
        if bsCount mod 2 == 1:
          cur.add depsStr[j]     # escaped space/tab: embedded, not a separator
          haveCur = true
          i = j + 1
        else:
          if haveCur:
            result.add cur
            cur = ""
            haveCur = false
          i = j + 1
      else:
        for _ in 0 ..< bsCount: cur.add '\\'
        haveCur = true
        i = j
    elif c == '$' and i + 1 < n and depsStr[i + 1] == '$':
      cur.add '$'
      haveCur = true
      i += 2
    elif c in {' ', '\t', '\n', '\r'}:
      if haveCur:
        result.add cur
        cur = ""
        haveCur = false
      inc i
    else:
      cur.add c
      haveCur = true
      inc i
  if haveCur:
    result.add cur

proc parseCcMDeps*(ccMOutput: string): seq[ReportedPath] =
  ## Parse GNU-make-style dependency output (`target: dep1 dep2 \` with
  ## backslash line continuations) into the flat list of dependency tokens,
  ## INCLUDING the source file itself (callers that need it excluded should
  ## filter by the known source path — see `depIncludeHeaders`). Tokenizes
  ## via `unescapeMakeRuleTokens`, which reverses `-M`'s escaping (a
  ## backslash-escaped space survives as ONE token instead of shattering —
  ## issue W8), and locates the target/dependency-list separator via
  ## `findRuleTargetColon`, which skips a Windows drive-letter colon instead
  ## of taking the first colon in the string — issue CR15.
  ##
  ## CR10: returns `ReportedPath`, not `string` — this is gcc/clang `-M`'s
  ## own echo of the `#include` directive's literal spelling, unresolved
  ## against the real on-disk file. `paths.classify`/`tracked`'s
  ## `ReportedPath` overload is the sanctioned way to turn one of these into
  ## identity material.
  let joined = ccMOutput.replace("\\\r\n", " ").replace("\\\n", " ")
  let colonIdx = findRuleTargetColon(joined)
  let depsStr = if colonIdx >= 0: joined[colonIdx + 1 .. ^1] else: joined
  for tok in unescapeMakeRuleTokens(depsStr):
    result.add ReportedPath(tok)

proc msvcSourceDepsDocStart(s: string): int =
  ## The BYTE index in `s` at which the `/sourceDependencies` JSON document
  ## begins: the position of a `{` that is the first non-whitespace
  ## character on its line -- `-1` if there is none.
  ##
  ## CR14 (code review 2026-09-21): the previous locator reconstructed this
  ## index by summing `line.len + 1` over `splitLines()`'s own output, which
  ## ASSUMES every line terminator is exactly 1 byte. `splitLines()` strips a
  ## CRLF terminator as 2 bytes, so every CRLF-terminated line preceding the
  ## document undercounted the reconstructed offset by one byte -- harmless
  ## at 1-2 preceding lines (the slice merely starts one or two bytes early,
  ## landing on trailing whitespace `parseJson` already skips) and genuinely
  ## corrupting at 3+ (the slice starts INSIDE the text of a preceding line,
  ## handing `parseJson` a leading non-whitespace byte and turning a real
  ## document into `dpeBadJson`).
  ##
  ## This scans `s` directly instead of reconstructing an offset from
  ## derived line lengths, so the located index is correct BY CONSTRUCTION
  ## regardless of whether the surrounding lines are LF- or CRLF-terminated
  ## -- terminator width is never assumed, or even computed.
  var atLineStart = true
  for i in 0 ..< s.len:
    case s[i]
    of '{':
      if atLineStart: return i
      atLineStart = false
    of '\n':
      atLineStart = true
    of ' ', '\t', '\r':
      discard   # leading whitespace -- still could be the start of the line
    else:
      atLineStart = false
  -1

proc parseMsvcSourceDeps*(depOutput: string):
    tuple[source: string; includes: seq[ReportedPath]; err: DepProbeError] =
  ## Parse a `/sourceDependencies-` document off cl's STDOUT.
  ##
  ## CR10: `includes` is `seq[ReportedPath]`, not `seq[string]` — cl
  ## lowercases every one of these unconditionally, so each is a
  ## potentially non-canonical spelling of a real tracked file until
  ## resolved via `paths.classify`/`tracked`'s `ReportedPath` overload.
  ## `source` stays a plain `string`: it is never sliced into identity
  ## material, only compared by basename against the known, TRUSTED
  ## `sourceFile` the probe was invoked for (`msvcSourceMatches`, below).
  ##
  ## cl prints one banner line -- the source's base name -- and then the
  ## pretty-printed JSON, and sends every diagnostic to STDERR (measured),
  ## including the `D9002 ignoring unknown option` that a cl older than
  ## 19.27 answers `/sourceDependencies` with. `closure.extractCompileInputs`
  ## drives this through `crisol/toolrun`'s `realRunIn`, whose capture is
  ## stdout-only (`drainBoth(p).output`), so stdout here is exactly
  ## `<banner>\n<document>` and the document begins at the first line whose
  ## first non-blank character is `{`. Locating it by CONTENT rather than by
  ## line index is what keeps a second banner line, or none, from shifting
  ## the parse.
  ##
  ## The prefix test is deliberately looser than "a line that IS `{`". cl
  ## pretty-prints today, so the two agree; but if a future toolset (or
  ## clang-cl, or a `/diagnostics` setting) emitted the document COMPACTLY on
  ## one line, the strict form would classify a document that is plainly
  ## present as `dpeNoJson` — "the probe did not run" — which is a
  ## MISDIAGNOSIS, not merely a stricter check. The enum exists to tell
  ## "no document" apart from "a document of the wrong shape"; a locator
  ## that collapses the second into the first defeats it. cl's banner is a
  ## source FILENAME and cannot begin with `{`, so nothing is given up.
  ##
  ## Absence of the document is a LOUD failure, never an empty header set:
  ## an empty `Includes` array is a real answer about a real translation
  ## unit; a missing document means the probe did not run. Distinguishing
  ## those is the whole reason `/sourceDependencies` was chosen over
  ## `/showIncludes`, which cannot express the difference.
  let start = msvcSourceDepsDocStart(depOutput)
  if start < 0:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeNoJson)

  var doc: JsonNode
  try:
    doc = parseJson(depOutput[start .. ^1])
  except CatchableError:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)

  if doc.kind != JObject or "Data" notin doc or doc["Data"].kind != JObject:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)
  let data = doc["Data"]
  if "Includes" notin data or data["Includes"].kind != JArray:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeNoIncludes)

  var incs: seq[ReportedPath] = @[]
  for n in data["Includes"]:
    if n.kind != JString:
      return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)
    incs.add ReportedPath(n.getStr)
  let src = if "Source" in data and data["Source"].kind == JString:
              data["Source"].getStr
            else: ""
  (source: src, includes: incs, err: dpeNone)

type
  DepSourceCheck* = enum
    ## W9j: whether `depIncludeHeaders`' MSVC arm cross-checked the
    ## `/sourceDependencies` document's own `Data.Source` field against the
    ## translation unit it was actually asked to probe — the one available
    ## check that the document really describes the source just compiled,
    ## rather than a stale or misattributed one left behind by an earlier
    ## probe. `parseMsvcSourceDeps` has always extracted `Data.Source`; until
    ## this fix nothing read it, so a stale/misattributed document would
    ## have passed silently (the caller had no way to tell).
    ##
    ## Kept as a SEPARATE type from `DepProbeError` deliberately, not a new
    ## arm of it: `DepProbeError` is matched by an EXHAUSTIVE `case` in
    ## `artifactid.toClosureProbeError`, a module outside this fix's
    ## concurrency lock, and widening that enum would force an edit there
    ## this fix is not permitted to make. A mismatch still fails the probe
    ## just as loudly — `closure.extractCompileInputs` raises on
    ## `dscMismatch` immediately after checking `err != dpeNone` — only the
    ## TYPE the signal travels on differs from a literal new `DepProbeError`
    ## case.
    dscSkipped    ## GNU family, or the document carried no `Source` field
                  ## to compare against (nothing to check)
    dscMatch      ## `Data.Source` names the translation unit that was probed
    dscMismatch   ## `Data.Source` names a DIFFERENT translation unit

proc msvcSourceMatches(probedSource, docSource: string): bool =
  ## Whether a `/sourceDependencies` document's `Data.Source` could
  ## plausibly describe `probedSource` — the translation unit
  ## `deriveDepInvocation` actually targeted (W9j).
  ##
  ## Compared by BASENAME, case-insensitively, with either path separator
  ## treated as a break — never by full-path equality. cl LOWERCASES every
  ## path it reports (measured) and may report it ABSOLUTE where the
  ## probe's own `sourceFile` (the manifest `ccCmd`'s last token) is
  ## relative to `config.projectRoot` — a layer this proc has no access to
  ## and cannot resolve against. A full-path comparison would therefore
  ## false-positive-mismatch a document that genuinely describes the probed
  ## unit; basename is the strictest comparison available without a project
  ## root. It is not infallible, but a stale or misattributed document
  ## naming a DIFFERENT translation unit almost never happens to share the
  ## probed unit's final path component, so this still catches the defect
  ## class it exists for without manufacturing false positives out of case
  ## or relative-vs-absolute spelling alone.
  proc baseOf(p: string): string =
    for i in countdown(p.high, 0):
      if p[i] in {'\\', '/'}: return p[i+1 .. ^1]
    p
  baseOf(probedSource).toLowerAscii == baseOf(docSource).toLowerAscii

proc depIncludeHeaders*(family: CcFamily; depOutput: string;
                        sourceFile: string):
    tuple[headers: seq[ReportedPath]; err: DepProbeError;
          sourceCheck: DepSourceCheck] =
  ## The header set a dependency probe reported, EXCLUDING the compiled
  ## source file itself (excluded by exact match on the known path used to
  ## derive the invocation — never guessed).
  ##
  ## Parsed by the family that produced it. The GNU arm cannot fail: a
  ## make-rule parse of arbitrary text yields a possibly-empty token list and
  ## always has, and gcc answering `-M` is not in question. The MSVC arm can
  ## and must, so the result carries a `DepProbeError` the caller is
  ## obliged to check.
  ##
  ## cl's `Includes` never lists the translation unit itself, so the
  ## source-exclusion filter is belt-and-braces on that arm rather than
  ## load-bearing as it is on the GNU one; it is applied to both so the two
  ## arms cannot disagree about what a header set contains.
  ##
  ## `sourceCheck` (W9j, MSVC only) is `dscMismatch` when the document's own
  ## `Data.Source` names a different translation unit than `sourceFile` —
  ## the caller MUST treat that the same as a `DepProbeError`, i.e. as a
  ## loud failure, never as a usable-but-suspicious header set (so `headers`
  ## is empty on a mismatch, same as on any other failure arm here).
  ##
  ## CR10: `headers` is `seq[ReportedPath]`, not `seq[string]` — every
  ## element here came out of a foreign tool's dependency report and must be
  ## resolved (`paths.classify`/`tracked`'s `ReportedPath` overload) before
  ## it becomes cache-key material. `p != sourceFile` and `p.len > 0` are
  ## `ReportedPath`'s two deliberately-exposed, identity-safe operations
  ## (see that type's own doc comment) — neither reads or leaks `sourceFile`
  ## as anything but a known, TRUSTED comparison text.
  case family
  of ccfGnuMake:
    var hs: seq[ReportedPath] = @[]
    for p in parseCcMDeps(depOutput):
      if p.len > 0 and p != sourceFile:
        hs.add p
    (headers: hs, err: dpeNone, sourceCheck: dscSkipped)
  of ccfMsvc:
    let parsed = parseMsvcSourceDeps(depOutput)
    if parsed.err != dpeNone:
      return (headers: newSeq[ReportedPath](), err: parsed.err,
              sourceCheck: dscSkipped)
    let sourceCheck =
      if parsed.source.len == 0: dscSkipped
      elif msvcSourceMatches(sourceFile, parsed.source): dscMatch
      else: dscMismatch
    if sourceCheck == dscMismatch:
      return (headers: newSeq[ReportedPath](), err: dpeNone,
              sourceCheck: dscMismatch)
    var hs: seq[ReportedPath] = @[]
    for p in parsed.includes:
      if p.len > 0 and p != sourceFile:
        hs.add p
    (headers: hs, err: dpeNone, sourceCheck: sourceCheck)
