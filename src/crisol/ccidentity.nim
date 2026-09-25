## ccidentity.nim -- C toolchain + runtime IDENTITY probe (RFC-0004, A2-pre;
## split out of ccprobe.nim, CR7 code review 2026-09-21).
##
## Answers ONE question: what compiler+runtime is this host, and is that
## identity sound enough to key a shared cache on. `ccprobe.nim` used to
## answer this AND a second, unrelated question -- "which headers did this
## translation unit actually include" -- sharing nothing but the word "cc".
## CR7 splits those: this module keeps concern (1); `ccprobe.nim` keeps
## concern (2), dependency-header probing, and is now a pure, I/O-free module
## (it spawns nothing -- every proc there transforms a string a CALLER already
## captured). The process-execution seam both used to share
## (`RunProc`/`realRun*`/`lastProbeStderr`/`ToolProbeTimeoutMs`) is now its
## own module, `crisol/toolrun` -- see that module's doc for why a third
## module was chosen over folding the seam into either half.
##
## Effectful I/O. Every probe goes through an injectable seam -- `RunProc`
## for a subprocess, `BinHashProc` for an artifact's content, `LinkProbeProc`
## for the MSVC linker's library trace -- so a unit test supplies synthetic
## output and spawns nothing, on any host. The platform differences live in a
## `CcProbeProfile` VALUE rather than in `when defined(windows)` branches, so
## the Windows behaviour is exercisable from a Linux test run.
##
## Public API
## ----------
##   ccFingerprint(run = realRunMerged, profile = hostCcProfile(),
##                 hashFile = realFileHash, linkProbe = realLinkVerbose): CcFingerprint
##     THE canonical derivation (CR11). Returns a structured value -- a
##     compiler half and a runtime half, each a `CcHalf` carrying its legible
##     text, an optional content digest, and an explicit degraded-state
##     discriminant (`CcFieldState`) rather than a magic sentinel string.
##     "Probe succeeded but found nothing" is unrepresentable in the type: only
##     `cfsKnown` carries a `text` field at all. Every consumer that needs the
##     VALUE (soundness-key fold, staleness compare, `--explain-miss`) should
##     take this, or the ONE serialization below -- never re-derive/re-parse
##     the grammar itself (see `CcFingerprint`'s own doc).
##
##     Not exported (CR8): nothing outside this module calls it directly --
##     every production consumer goes through `cachedCcFingerprint()` (the
##     memoised entry point), and tests go through `ccVersion` (the legacy
##     string accessor, below) or, for the compiler half alone, call the
##     exported `ccIdentity` directly (`tests/unit/test_ccprobe.nim`,
##     `tests/unit/test_cc_banner_selection.nim`,
##     `tests/integration/test_r7_toolchain_warning_ladder.nim`). Default-argument expressions are
##     evaluated in the DEFINITION scope, so `hostCcProfile()`/`realLinkVerbose`
##     staying un-exported does not change what `ccVersion`'s own defaults
##     resolve to for an external caller.
##
##   ccVersion*(run = realRunMerged, profile = hostCcProfile(),
##             hashFile = realFileHash, linkProbe = realLinkVerbose): string
##     `$ccFingerprint(run, profile, hashFile, linkProbe)` -- the legacy
##     rendered-string accessor, kept because `KeyInputs.ccVersion`,
##     `DepGraphHeader.ccVersion` and `depgraph.loadDepGraph`'s staleness
##     compare all thread a `string` today (RFC-0004's key fold; the persisted
##     depgraph header). Two "|"-separated halves as before (a shape
##     `parseCcFingerprint` -- THE single parser, `render.nim` -- relies on):
##       - the COMPILER: every candidate driver's version line, folded
##       - the RUNTIME:  legible version text, then " #" and a CONTENT hash of
##         the runtime artifact(s) the toolchain will link
##     Issue #23 added the content hash. A version string alone cannot see a
##     distro glibc backport (RFC-0006 §Soundness), and on Windows there is no
##     runtime version string to read at all -- Nim+vcc links the CRT
##     statically, so the runtime IS a set of .lib files and only their bytes
##     identify them.
##     Every half degrades to a documented sentinel rather than to emptiness,
##     so the fingerprint is always a stable non-empty string. Never raises.
##
## Sentinel values (exported for consumer awareness):
##   CcSentinel*       = "<cc-unavailable>"
##   RuntimeSentinel*  = "<runtime-unidentified>"
##   FileHashSentinel* = "<artifact-unreadable>"
##
## Caching
## -------
## The pure derivation (`ccVersion`) is seam-injectable and can be called freely
## in tests.  The memoised accessor is `cachedCcFingerprint`, which calls the
## real probe exactly once per process; `cachedCcVersion` is only its `$`
## projection. Unit tests bypass both (a few integration tests call
## `cachedCcVersion` to observe the real host).
##
## Cycle-freeness
## --------------
## `crisol/fnv` (the driver/runtime content hashes) is this module's only
## crisol import besides the seam. Both it and `crisol/toolrun` are
## themselves genuine std-only-rooted leaves (`fnv.nim` imports `std/
## algorithm` alone; `toolrun.nim` imports only `crisol/toolexec`, itself
## std-only), so this module's own crisol-dependency graph terminates
## immediately rather than reaching back toward `closure`/`depgraph`:
## `depgraph.nim` imports `closure.nim`, and `artifactid.nim` imports
## `depgraph.nim` -- so anything this module imported that reached back
## toward either would close a cycle. It does not.

import std/[algorithm, os, sequtils, strutils, tempfiles]
import crisol/fnv       # fnv1a64/toHex16 -- NEVER std/hashes, which is not stable across Nim versions
import crisol/toolrun   # RunProc/realRunMerged/runViaOsproc -- the process-execution seam (CR7)

# ---------------------------------------------------------------------------
# Sentinels
# ---------------------------------------------------------------------------

const
  CcSentinel*  = "<cc-unavailable>"
    ## The compiler half is not identified: no candidate compiler driver
    ## answered, OR `ccIdentity` refused one that did (it ran and exited
    ## non-zero, or printed no version banner -- `CcHalf.refusedDrivers`).
    ## The serialized value cannot tell the two apart; the structured
    ## `CcHalf` can (`answeredUnidentified`).
  RuntimeSentinel* = "<runtime-unidentified>"
    ## No runtime library could be identified at all: on POSIX the version
    ## probe failed AND the artifact could not be resolved or read; on Windows
    ## the linker named no library to search. Distinct from
    ## `FileHashSentinel`, which means "named but unreadable".
    ##
    ## There is deliberately no "this platform has no runtime probe" sentinel
    ## any more. `<ldd-unavailable>` was one until issue #23 slice 4b gave
    ## Windows a real runtime probe, and a sentinel that means "we did not
    ## look" is indistinguishable, in a soundness key, from two hosts agreeing.
  FileHashSentinel* = "<artifact-unreadable>"
    ## The runtime artifact was named but could not be read. Distinct from
    ## `RuntimeSentinel` ("nothing was named at all") on purpose: gcc ECHOES THE
    ## NAME BACK when `-print-file-name=` finds nothing (measured; rc is still
    ## 0), so on a musl host the path is the bare string `libc.so.6` and this
    ## is the honest outcome rather than a silent success.

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  BinHashProc* = proc(path: string): string {.closure.}
    ## Content-hash the file at `path`; a documented sentinel if it cannot be
    ## read. Never raises. Same seam shape as `nimprobe.BinHashProc`, so a
    ## test can vary an artifact's CONTENT without putting bytes on disk.

  LinkProbeProc* = proc(): string {.closure.}
    ## Produce the MSVC linker's verbose library trace, or `""` if it cannot
    ## be had. Takes no `RunProc`: unlike every other probe in this module it
    ## owns a scratch directory and a translation unit as well as a
    ## subprocess, so the whole effect sits behind one seam rather than half
    ## of it (see `realLinkVerbose`). A test supplies canned linker output and
    ## touches no disk.

# ---------------------------------------------------------------------------
# realLinkVerbose -- the one MSVC-specific probe that owns its own process
# ---------------------------------------------------------------------------

const
  RuntimeProbeTu = "crisol_runtime_probe.c"
    ## The translation unit `realLinkVerbose` writes. A fixed name inside a
    ## randomized scratch directory: `cl` echoes the SOURCE NAME it is
    ## compiling to stdout, so a name derived from the scratch path would put
    ## that path into the capture, one careless parser change away from the
    ## fingerprint. Nothing host-specific may reach a soundness key.

  RuntimeProbeSrc = "int main(void){return 0;}\n"
    ## As small as a linkable program gets. The point is not the program: it
    ## is to make the linker state which runtime libraries it searches, which
    ## it will not do without one. `link /VERBOSE:LIB` with no inputs fails at
    ## LNK1561 (entry point must be defined) and names no library at all
    ## (measured).

proc realLinkVerbose(): string =
  ## Default `LinkProbeProc`: build a trivial program with Nim's own cl
  ## wrapper and ask the linker which libraries it searched.
  ##
  ## Not exported (CR8): zero external references -- reached only as
  ## `runtimeIdentity`/`ccFingerprint`/`ccVersion`'s own default `linkProbe`
  ## argument, evaluated in this module's scope regardless of its own export
  ## status. Every test that needs a `LinkProbeProc` builds one directly
  ## (`makeLinkProbe` in `test_ccprobe.nim`) rather than calling this.
  ##
  ## `vccexe /nologo <tu> /link /VERBOSE:LIB` does compile and link in ONE
  ## process. `vccexe` is Nim's cl wrapper and sits beside `nim`, so it
  ## locates cl whether or not crisol was launched from a Developer Command
  ## Prompt -- `cl` and `link` themselves are on PATH only inside one.
  ##
  ## The scratch directory is randomized (`std/tempfiles.createTempDir`, the
  ## same primitive `runner.makeTmpDir` uses) and removed again. It is also
  ## the subprocess's CWD, so `m.obj` and `m.exe` land inside it and no
  ## `/Fo`/`/Fe` path -- which would be host-specific -- has to be passed on
  ## the command line.
  ##
  ## The exit code is deliberately ignored: a link that fails late still
  ## reports the libraries it searched on the way, and a link that reports
  ## nothing degrades through `parseVerboseLibPaths` to `RuntimeSentinel`.
  ## Never raises.
  var dir: string
  try:
    dir = createTempDir("crisol_rtprobe_", "")
  except CatchableError:
    return ""
  defer:
    try: removeDir(dir)
    except CatchableError: discard

  try:
    writeFile(dir / RuntimeProbeTu, RuntimeProbeSrc)
  except CatchableError:
    return ""

  # Merged streams for the same reason the version probe merges them: which
  # stream a Microsoft tool writes a given line to is not a contract.
  # Calls `runViaOsproc` directly (not `realRunMerged`) because this probe
  # needs BOTH a caller-chosen workingDir (this scratch directory) AND
  # merged streams -- a combination none of `toolrun`'s three named wrappers
  # expose on their own; see that module's doc for why the primitive itself
  # is exported instead of adding a fourth wrapper for this one caller.
  runViaOsproc("vccexe",
               ["/nologo", RuntimeProbeTu, "/link", "/VERBOSE:LIB"],
               dir, mergeStderr = true).output

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc realFileHash*(path: string): string =
  ## Default `BinHashProc`: FNV-1a over the file's bytes. An empty path, a
  ## missing or unreadable file, and an empty file all yield
  ## `FileHashSentinel`. Never raises.
  if path.len == 0: return FileHashSentinel
  try:
    let content = readFile(path)
    if content.len == 0: return FileHashSentinel
    toHex16(fnv1a64(content))
  except CatchableError:
    FileHashSentinel

proc firstLine(s: string): string =
  ## First non-empty, trimmed line; `""` if there is none.
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0: return t
  ""

proc hasDottedVersion(s: string): bool =
  ## True iff `s` contains a `<digit>.<digit>` token -- the locale-proof mark
  ## of a version banner. `Microsoft (R) C/C++ Optimizing Compiler Version
  ## 19.44.35228 for x64` keeps its `19.44` in every localization; every word
  ## around it may be translated. `usage: cl [ option... ] filename...` and
  ## `Copyright (C) Microsoft Corporation.` have none.
  for i in 1 ..< max(s.len - 1, 1):
    if s[i] == '.' and s[i-1] in Digits and s[i+1] in Digits:
      return true
  false

proc versionLine*(s: string): string =
  ## The line of `s` that carries the version, trimmed; the first non-empty
  ## line if none does; `""` if `s` has no non-empty line.
  ##
  ## Selected by CONTENT, never by position. A merged capture interleaves two
  ## pipes, and which of them flushes first is a buffering detail -- resting
  ## on it is exactly the mistake issue #22 was: `cl` writes its banner to
  ## stderr and `usage: cl [ option... ]` to stdout, so a positional "first
  ## line" rule can pick the line that has no version in it.
  ##
  ## The fallback keeps this a strict superset of the first-non-empty-line
  ## rule it replaces: gcc, clang and ldd all put their version on line 1, so
  ## POSIX fingerprints are unchanged.
  var fallback = ""
  for line in s.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    if fallback.len == 0: fallback = t
    if hasDottedVersion(t): return t
  fallback

# ---------------------------------------------------------------------------
# namesCompilerVersion -- "a BANNER, not a DIAGNOSTIC" (R5-4, round-5 review
# 2026-09-24)
# ---------------------------------------------------------------------------
#
# WHY A SECOND PREDICATE INSTEAD OF TIGHTENING `hasDottedVersion`. R4-1 spelled
# "this candidate identified itself" as `hasDottedVersion(versionLine(output))`,
# and that is a much weaker test than the sentence it was documented with.
# `versionLine` returns the first line that carries a dotted token IF ANY LINE
# DOES, so `not hasDottedVersion(versionLine(output))` is false as soon as ONE
# `<digit>.<digit>` appears ANYWHERE in the whole capture -- including in a
# diagnostic that merely echoes an argument back. Measured shape (R5-4):
#
#   cl : Command line warning D9024 : unrecognized source file type
#   '10.0.22621.0', object file assumed
#
# is a pure diagnostic -- it identifies no compiler at all -- yet it satisfied
# R4-1's check and folded into the compiler half as if it were a banner. `CL`
# and `_CL_` routinely carry vcpkg/Qt/Python/SDK paths, every one of which
# contains a `digit.digit`, so this is the ordinary poisoned-`cl` shape rather
# than a contrived one.
#
# `hasDottedVersion` and `versionLine` themselves are deliberately NOT changed.
# `versionLine` also produces the `ldd` runtime label, and `ldd (GNU libc) 2.38`
# carries exactly ONE dotted token; R3-11 established that requiring two would
# push the runtime half back onto the positional first-line rule issue #22
# exists to eliminate. So the tightening lives HERE, as an extra condition at
# the two places that need it (`ccIdentity`'s `cdVersionOnly` selection and
# degrade, via `bannerLine`, and `toolchainUnsound`'s backstop disjunct).
#
# DIRECTION. `namesCompilerVersion(s)` implies `hasDottedVersion(s)` for every
# `s` (its first conjunct only ever selects a subset of the same tokens), and
# R6's tightening (round-6 review 2026-09-24: `hasBannerVersion` replacing the
# unquoted-token test, `hasQuote` and `hasSwitchToken` joining
# `looksLikeDiagnostic`) only narrows it further. So every LINE R4-1 or R5-4
# refused is still refused. That is the mandated direction --
# `WindowsCcCandidates`: "under-invalidation is the defect this probe exists to
# prevent; over-invalidation only costs a miss". For a REFUSED line the
# cost is larger than one miss -- a refusal degrades the whole compiler half,
# and a host whose half is refused caches nothing while the cause persists
# (R8-D1; see `ccIdentity`) -- but it is still paid locally, never by
# another host.
#
# The one place R6 believes MORE is per CAPTURE, not per line, and it is
# deliberate: `bannerLine` now finds a line passing this predicate wherever it
# sits, where `versionLine` handed over only the first dotted line. A capture
# whose real banner followed a dotted diagnostic was refused before and is
# believed now -- on the banner line, which passes the tightened predicate on
# its own. See `bannerLine` for why a diagnostic ELSEWHERE in the capture is
# not grounds to refuse it.

proc freeStanding(s: string; lo, hi: int): bool =
  ## True iff `s[lo .. hi]` is a WORD of its own: preceded by the start of the
  ## text or whitespace, AND followed by the end of the text, whitespace, or
  ## `-`. That is how every banner this profile asks for states its version
  ## -- `... Version 19.44.35228 for x64`, `... project) 13.2.0`, `clang
  ## version 17.0.6 (...)`, `... 19.44.35228 (x64) 用コンパイラ` -- with `-`
  ## admitting a distro suffix (`Ubuntu clang version 14.0.0-1ubuntu1.1`,
  ## whose only version token it is; observed by
  ## `test_cc_banner_selection.nim`).
  ##
  ## R7-L4 (round-7 review) REMOVED `(` on the left and `)`, `,`, `;` on the
  ## right. None was observed by any test, and no banner states its version
  ## that way. The `;` arm's stated purpose -- the fold's "; " join, judged by
  ## `toolchainUnsound`'s backstop -- was dead: every folded segment is a line
  ## `bannerLine` accepted on its own, and the LAST segment keeps its own
  ## right-hand context (end of text) in the joined string, so the backstop's
  ## existential `hasBannerVersion` is satisfied without it. Removing a
  ## boundary can only REFUSE more (no caching on that host while the
  ## refusal persists -- R8-D1), never believe more.
  ##
  ## The two sides are separate arms, each load-bearing on its own (R6,
  ## round-6 review 2026-09-24; `tests/unit/test_cc_banner_selection.nim`):
  ##   - LEFT rejects a version glued to what precedes it -- a path component
  ##     (`...\Lib\10.0.22621.0`, `C:\Python3.11\include`), an assignment
  ##     (`/DVER=3.11`), an echoed token (`'10.0.22621.0'`).
  ##   - RIGHT rejects one glued to what follows it -- a wrapped path's
  ##     continuation line (`10.0.22621.0\um\x64`), a closing quote.
  ##
  ## SUPERSEDES R5-4's `quoteFlanked`, which rejected only a QUOTE on either
  ## side and whose doc cited `'/I C:\Python3.11\include'` as a token it
  ## rejected. It did not: that `3.11` sits between `n` and `\`, so it passed,
  ## and a wrapped D9002 whose continuation line carried it was BELIEVED (R6
  ## case C). Structural, so it holds in every localization.
  (lo == 0 or s[lo - 1] in Whitespace) and
    (hi + 1 >= s.len or s[hi + 1] in Whitespace or s[hi + 1] == '-')

proc hasBannerVersion(s: string): bool =
  ## True iff some maximal digits-and-dots run of `s` is `freeStanding` and
  ## carries at least TWO `<digit>.<digit>` separators -- a major.minor.patch
  ## (or longer) version, stated as a word of its own. A strict subset of
  ## `hasDottedVersion(s)`: every run accepted here is one that proc accepts,
  ## so this only ever REJECTS tokens it already accepted.
  ##
  ## THREE COMPONENTS, and here rather than in `hasDottedVersion` (whose
  ## one-dot rule `ldd (GNU libc) 2.38` needs -- R3-11). Every driver
  ## `WindowsCcCandidates` asks prints three or more (`19.44.35228`, `13.2.0`,
  ## `17.0.6`), while the incidental tokens that reach a merged capture are
  ## typically two (`3.11` from a Python path, `14.0` from a "Visual C++ 14.0"
  ## message whose wrapped continuation line carries nothing any diagnostic
  ## anchor could see). Refusing a hypothetical two-component banner costs
  ## caching on that host (nothing is cached while it persists -- R8-D1);
  ## believing a two-component fragment poisons L2.
  var i = 0
  while i < s.len:
    if s[i] in Digits:
      var j = i
      while j < s.len and (s[j] in Digits or s[j] == '.'): inc j
      var seps = 0
      for k in i + 1 ..< j - 1:
        if s[k] == '.' and s[k - 1] in Digits and s[k + 1] in Digits: inc seps
      if seps >= 2 and freeStanding(s, i, j - 1):
        return true
      i = j          # always > i: s[i] was a digit, so the run is non-empty
    else:
      inc i
  false

const DiagnosticPhrases = ["command line warning", "command line error"]
  ## English-locale anchors, matched case-insensitively anywhere in the text.
  ## They are a BONUS, not the load-bearing part: in a localized toolset these
  ## strings are translated and simply never fire, and the structural anchors
  ## below (`hasToolColonPrefix`, `hasDiagnosticCode`, `hasQuote`,
  ## `hasSwitchToken`) are what still catch the same line there -- MSVC
  ## translates the PROSE of a diagnostic but not the program name it prefixes
  ## it with, the diagnostic code, or the punctuation it quotes a token with.
  ##
  ## Chosen so no version BANNER could plausibly contain them in any language:
  ## a banner names a product and a version, never a warning or an error. They
  ## are matched against the whole text rather than a word list, so nothing
  ## here depends on tokenization.

proc hasToolColonPrefix(s: string): bool =
  ## True iff `s` begins with a non-empty whitespace-free token, then an
  ## OPTIONAL single space, then `:`, then whitespace or end of line -- i.e.
  ## `cl : Command line error D8003 : ...`, `LINK : fatal error ...`,
  ## `vccexe: could not find ...`, `usage: cl [ option... ]`, and every
  ## localized form of those, all of which translate the PROSE after the colon
  ## and leave the program name and the separator alone. A localized usage line
  ## (`使用法: cl [ オプション... ]`) is caught by this anchor for the same
  ## reason -- a usage line always opens `<word>: `.
  ##
  ## No compiler banner has this shape: `Microsoft (R) C/C++ Optimizing
  ## Compiler Version ...`, `Microsoft (R) C/C++-Optimierungscompiler Version
  ## ...`, `gcc.exe (Rev3, ...) 13.2.0` and `clang version 17.0.6` all put a
  ## SPACE and then a non-colon character after their first token, which is
  ## exactly what this rejects. The trailing-whitespace requirement is what
  ## keeps a path (`C:\msvc\vc\lib\LIBCMT.lib`) and a clock-like token
  ## (`19:44`) out of it.
  let idx = s.find(':')
  if idx <= 0: return false
  let pre = if s[idx - 1] == ' ': idx - 1 else: idx   # the `cl : ` spelling
  if pre == 0: return false
  for i in 0 ..< pre:
    if s[i] in Whitespace: return false
  idx + 1 >= s.len or s[idx + 1] in Whitespace

proc hasDiagnosticCode(s: string): bool =
  ## True iff `s` carries a token of 1..4 upper-case ASCII letters immediately
  ## followed by 4 or 5 digits, at both ends a non-identifier boundary --
  ## MSVC's diagnostic-code shape: `D8003`, `D9024`, `C2065`, `C1083`,
  ## `LNK1561`, `LNK2019`, `RC2104`. The CODE is the one part of a diagnostic
  ## that is never translated, which is what makes this anchor locale-proof.
  ##
  ## The 4-or-5-digit width is what keeps it off real banners: `x64` and `X64`
  ## are one letter and two digits, `MSYS2` (in mingw's own banner) is four
  ## letters and ONE digit, and a bare version (`19.44.35228`) has no letters
  ## attached at all. None of them match.
  var i = 0
  while i < s.len:
    if s[i] in {'A'..'Z'} and (i == 0 or s[i - 1] notin IdentChars):
      var j = i
      while j < s.len and s[j] in {'A'..'Z'}: inc j
      var k = j
      while k < s.len and s[k] in Digits: inc k
      if j - i <= 4 and k - j in 4 .. 5 and (k == s.len or s[k] notin IdentChars):
        return true
      i = k          # always > i: s[i] was a letter, so the token is non-empty
    else:
      inc i
  false

proc hasQuote(s: string): bool =
  ## True iff `s` contains a QUOTE: a `"` or a backtick anywhere, or a `'`
  ## that is not an ELISION. MSVC diagnostics quote what they echo back
  ## (`unrecognized source file type '...'`, `ignoring unknown option '...'`,
  ## `cannot open file '...'`), and a WRAPPED one leaves a closing quote on its
  ## continuation line -- the line that carries no other anchor. No compiler
  ## banner this profile asks for quotes anything, in any localization.
  ##
  ## Line-wide rather than token-adjacent (R5-4's `quoteFlanked` was the
  ## adjacent form): a continuation such as `6.5.3 beta', object file assumed`
  ## states its token as a free-standing word and closes the quote a word
  ## later (R6, round-6 review 2026-09-24).
  ##
  ## THE ELISION EXCEPTION (R7-D1, round-7 review). A `'` with a letter
  ## immediately on BOTH sides is an apostrophe inside a word, not a quote:
  ## the French banner is `Compilateur d'optimisation Microsoft (R) C/C++
  ## version 19.44.35228 pour x64`, and R6's any-apostrophe rule refused it.
  ## A quote that delimits an echoed token sits at the token's EDGE -- a
  ## space, punctuation, a digit or the line's end on at least one side
  ## (`'10.0.22621.0'`, `beta',`, `'/I C:\...'`) -- so every quote R6's
  ## fixtures carry still fires. A "letter" here is an ASCII letter or any
  ## non-ASCII byte, so an elision before an accented letter (`l'éditeur`)
  ## is an elision too; that byte-level test never reaches ASCII punctuation.
  const ElisionSide = Letters + {'\x80' .. '\xFF'}
  for i, c in s:
    if c in {'"', '`'}: return true
    if c == '\'' and not (i > 0 and i + 1 < s.len and
                          s[i - 1] in ElisionSide and s[i + 1] in ElisionSide):
      return true
  false

proc hasSwitchToken(s: string): bool =
  ## True iff some whitespace-delimited token of `s` begins with `/` or `-`
  ## followed by an ASCII letter -- a command-line SWITCH (`/nologo`, `/Zs`,
  ## `-std`). A driver that ECHOES its argv (R6 case D) prints no banner, no
  ## program-colon prefix and no code, so its switches are its only
  ## locale-proof mark. No banner carries one: `C/C++` has its slash mid-token,
  ## `(x86_64-posix-seh-rev0,` opens with `(`, and a distro suffix
  ## (`14.0.0-1ubuntu1`) has its `-` mid-token.
  for i in 0 ..< s.len - 1:
    if s[i] in {'/', '-'} and s[i + 1] in Letters and
       (i == 0 or s[i - 1] in Whitespace):
      return true
  false

proc looksLikeDiagnostic(s: string): bool =
  ## True iff `s` has the shape of a compiler DIAGNOSTIC, a usage line or an
  ## echoed command line rather than a version banner, by any one of five
  ## anchors: one of `DiagnosticPhrases`, a `<program>: `/`<program> : ` prefix
  ## (`hasToolColonPrefix`, which also covers `usage:` in any language), an
  ## MSVC diagnostic code (`hasDiagnosticCode`), a quote character
  ## (`hasQuote`), or a command-line switch (`hasSwitchToken`). All but the
  ## phrases are structural and survive translation; the phrases are an
  ## English-locale bonus (see `DiagnosticPhrases`).
  ##
  ## Deliberately NOT a claim to recognise every diagnostic there is -- it
  ## cannot be, and nothing here rests on that. It is one side of an
  ## intentionally asymmetric test: a match REFUSES the line (at worst, no
  ## caching on that host while the cause persists -- R8-D1; never a wrong
  ## entry on another host), a non-match only means none of these anchors fired, and the
  ## other conjunct in `namesCompilerVersion` (a free-standing, three-component
  ## version token) still has to hold before the line is believed.
  let low = s.toLowerAscii
  for phrase in DiagnosticPhrases:
    if phrase in low: return true
  hasToolColonPrefix(s) or hasDiagnosticCode(s) or hasQuote(s) or
    hasSwitchToken(s)

proc namesCompilerVersion(s: string): bool =
  ## True iff `s` states a compiler version: it carries a free-standing,
  ## three-component version token (`hasBannerVersion`) and shows none of
  ## `looksLikeDiagnostic`'s shapes. This is R4-1's `hasDottedVersion` check,
  ## tightened twice (R5-4, then R6) -- and it is exactly that and nothing
  ## more: it does not verify that a compiler exists, that the version is real,
  ## or that the text is a banner. It says only "a version is stated as a word
  ## of its own, and this does not look like a diagnostic or an argv echo".
  ##
  ## A localized `cl` banner still passes, which is the property this whole
  ## family of predicates must not break. `Microsoft (R) C/C++-
  ## Optimierungscompiler Version 19.44.35228 für x64` (or its Japanese form,
  ## `... Version 19.44.35228 (x64) 用コンパイラ`, or its French form,
  ## `Compilateur d'optimisation Microsoft (R) C/C++ version 19.44.35228 pour
  ## x64`) has a free-standing `19.44.35228`, no `<token>:`/`<token> : `
  ## prefix, no 4-or-5-digit diagnostic code, no quote (an elision apostrophe
  ## is not one -- R7-D1, see `hasQuote`), no switch and none of the English
  ## phrases --
  ## and every one of those observations is about PUNCTUATION AND DIGITS, never
  ## about a translatable word. That is the same locale-proofing argument
  ## `hasDottedVersion` itself rests on.
  hasBannerVersion(s) and not looksLikeDiagnostic(s)

proc bannerLine(s: string): string =
  ## The first non-empty line of `s` (trimmed) that satisfies
  ## `namesCompilerVersion`; `""` if no line does. THE selector and THE
  ## acceptor for a `cdVersionOnly` candidate, as one predicate (R6, round-6
  ## review 2026-09-24).
  ##
  ## WHY NOT `versionLine`. `ccIdentity` used to SELECT with `versionLine` --
  ## the first line bearing ANY dotted token -- and then ACCEPT or refuse that
  ## one line with `namesCompilerVersion`. Two predicates over one capture
  ## disagree, in both directions:
  ##   - a real banner AFTER a dotted diagnostic was never looked at, so the
  ##     same two lines were believed banner-first and refused
  ##     diagnostic-first -- the verdict rested on which of two merged pipes
  ##     flushed first, the positional dependence issue #22 exists to remove;
  ##   - a diagnostic whose dotted token sat on an otherwise-clean line (a
  ##     wrapped continuation, an unprefixed SDK path under a `LINK : fatal
  ##     error`, an echoed argv) had THAT line selected, and it passed.
  ## Selecting BY the acceptor removes the first by construction: a banner is
  ## found wherever it sits. The second is removed by the acceptor itself
  ## (`hasBannerVersion`, `hasQuote`, `hasSwitchToken`), because once every
  ## line is a candidate, every line has to be refused on its own merits.
  ##
  ## WHY A DIAGNOSTIC ELSEWHERE DOES NOT REFUSE A REAL BANNER. The half keys
  ## the TOOLSET, and a genuine banner line varies with the toolset whether or
  ## not the same `cl` also complained about its `CL`/`_CL_` environment; the
  ## complaint itself carries no toolset identity. Refusing on it would make a
  ## pipe-ordering accident a verdict again, merely in the other direction.
  ## What must never happen is a NON-banner line being believed, and that is
  ## judged per line, not per capture.
  ##
  ## SCOPE: this is about a capture from a driver that EXITED 0 -- the only
  ## captures `bannerLine` is ever asked to judge. It does not contradict
  ## `ccIdentity` refusing a present driver that exited NON-zero "whatever it
  ## printed, banner included" (R7-S1): that refusal is on the EXIT STATUS,
  ## never on the capture's text, and `bannerLine` is not consulted for it.
  ## It exists because a non-empty `CL` (the cause of cl's non-zero exit)
  ## reaches every compile cl performs without reaching the key; it is a
  ## stopgap tied to R7-S6, the split-out compile-environment issue, and
  ## is revisited when that issue puts the compile environment in the key
  ## (R8-D5, round-8 review).
  ##
  ## `versionLine` itself is unchanged: it still labels the `ldd` runtime half,
  ## where one-dot `2.38` is the real version (R3-11).
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0 and namesCompilerVersion(t): return t
  ""

proc relaysDriverAnswer(output: string): bool =
  ## True iff a `crWrapper` candidate's failing output shows that the driver
  ## it wraps RAN: some line is a compiler banner (`bannerLine`) or carries an
  ## MSVC diagnostic code (`hasDiagnosticCode`). R7-S1, round-7 review.
  ##
  ## Both are what cl itself prints, and both survive localization (a version
  ## token and an untranslated code). Measured through `realRunMerged` in the
  ## MSVC image: `vccexe` under `CL=/W4` relays the banner AND
  ## `cl : Command line error D8003 : ...` (exit 2); under `CL=/nologo`, the
  ## D8003 alone (exit 2). With no reachable cl it prints only Nim's own
  ## `Hint: vcvarsall.bat was not found` and an unhandled-OSError traceback
  ## (exit 1), which carries neither -- that host has no MSVC to refuse.
  ##
  ## RESIDUAL, on record: a wrapped driver that ran, failed, and printed
  ## neither a banner nor a coded diagnostic would read as absent here. cl has
  ## not been observed to do so, and a sibling `cl` on PATH (a Developer
  ## Command Prompt) is a `crDriver` and is refused on the exit code alone.
  if bannerLine(output).len > 0: return true
  for line in output.splitLines():
    if hasDiagnosticCode(line): return true
  false

const LibSuffix = ".lib"

proc libPathIn(line: string): string =
  ## The library path inside one `/VERBOSE:LIB` trace line, or `""`.
  ##
  ## Anchored on the path's own SYNTAX, never on the verb before it or on
  ## position. Two anchors, checked together in one left-to-right scan so
  ## whichever occurs first in the line wins:
  ##
  ## - a DRIVE LETTER (`letter` + `:` + `\` or `/`). `Searching
  ##   C:\msvc\vc\lib\LIBCMT.lib:` is translated wholesale in a localized
  ##   toolset -- the same trap `/showIncludes` sets, which CMake ships an
  ##   entire probe to work around (issue #21) -- but a drive letter is not
  ##   translated.
  ## - a UNC PREFIX: two consecutive matching separators (`\\` or the
  ##   forward-slash spelling `//`) not themselves preceded by a separator,
  ##   so the anchor lands on the FIRST pair rather than a later one nested
  ##   inside it. A library reached over a network share has no drive
  ##   letter and no colon at all, so the drive-letter anchor can never fire
  ##   for it.
  ##
  ## CR1 (code review 2026-09-21): before this anchor existed, a UNC line
  ## fell to a positional drop-one-leading-word fallback -- precisely the
  ## positional heuristic the drive-letter anchor exists to avoid. A
  ## one-word localized verb ("Suche in") happened to survive it; a
  ## two-or-more-word one ("Suche jetzt in") did not, leaving a garbage
  ## leading token ahead of `hashFile`. Every such entry then degraded to
  ## the SAME `FileHashSentinel`, so two toolchains sharing the fixed
  ## standard `.lib` basename set (LIBCMT, libvcruntime, libucrt, oldnames,
  ## kernel32, uuid) folded to an IDENTICAL fingerprint regardless of what
  ## those libraries actually contained: an under-invalidation soundness-key
  ## collision, the exact defect class issue #23 exists to eliminate.
  ##
  ## Both anchors are space-proof (`C:\Program Files\...` survives) for the
  ## same reason: they anchor on syntax the OS assigns meaning to, never on
  ## whitespace or word position.
  ##
  ## No separate case for a `\\?\` long-path prefix. `\\?\C:\...` and
  ## `\\?\UNC\server\share\...` both begin with two consecutive `\`, so the
  ## UNC anchor already matches at that leading pair and returns the whole
  ## extended-length path intact, starting from `\\?\`. A drive-letter match
  ## occurring later in the same string (inside `\\?\C:\...`) can never win
  ## the scan, because it is left-to-right and the UNC pair is always the
  ## earlier of the two.
  ##
  ## No fallback beyond these two anchors. `libPathIn` is only ever called
  ## on a line already confirmed (by its caller) to end in `.lib`, and every
  ## resolved-library line MSVC has been measured to emit is an absolute
  ## path -- drive-letter, UNC, or one of the two long-path spellings above,
  ## all covered. A `.lib`-suffixed line matching NEITHER anchor is not a
  ## resolved library crisol can hash; fabricating an entry for it (the old
  ## drop-one-leading-word fallback) chains a real-looking basename to a
  ## `FileHashSentinel` digest, which is worse than no entry -- it looks
  ## like a resolved, unreadable library instead of the unrecognised text it
  ## actually is, and does so IDENTICALLY across different hosts, which is
  ## the same collision this fix exists to close. Returning `""` lets the
  ## caller skip the line, same as it already skips a non-`.lib` one.
  for i in 0 ..< max(line.len - 1, 0):
    if line[i] == ':' and i > 0 and line[i+1] in {'\\', '/'} and
       line[i-1] in Letters:
      return line[i-1 .. ^1]
    if line[i] in {'\\', '/'} and line[i+1] == line[i] and
       (i == 0 or line[i-1] notin {'\\', '/'}):
      return line[i .. ^1]
  ""

proc libBasename(path: string): string =
  ## The final component of `path`, splitting on EITHER separator.
  ##
  ## Deliberately not `os.extractFilename`, which splits on the HOST's
  ## `DirSep` -- and the host here is whatever machine is running the
  ## probe, not the machine the linker trace describes. Under a POSIX
  ## build `os.extractFilename` returns a Windows path whole, so the MSVC
  ## arm would fingerprint PATHS on every host but Windows: exactly the
  ## path-dependence this arm exists to avoid, and invisible in a unit test
  ## until it reached a Windows CI leg.
  for i in countdown(path.high, 0):
    if path[i] in {'\\', '/'}: return path[i+1 .. ^1]
  path

proc parseVerboseLibPaths(output: string): seq[string] =
  ## Every distinct library path the MSVC linker reports searching, in the
  ## order it first searched them.
  ##
  ## Selected by CONTENT -- a line naming a `.lib` -- not by matching the word
  ## "Searching", for the localization reason in `libPathIn`, and the same
  ## reason `versionLine` does not take the first line.
  ##
  ## Deduplication is load-bearing, not tidiness: the linker repeats its
  ## search list once per resolution pass, and how many passes it makes is a
  ## property of the program being linked. Folding the repeats would make the
  ## fingerprint depend on the probe's translation unit rather than on the
  ## toolchain.
  result = @[]
  for line in output.splitLines():
    var t = line.strip()
    if t.endsWith(":"): t.setLen(t.len - 1)
    if not t.toLowerAscii.endsWith(LibSuffix): continue
    let path = libPathIn(t)
    if path.len > 0 and path notin result:
      result.add path

# ---------------------------------------------------------------------------
# ccVersion -- pure derivation (injectable)
# ---------------------------------------------------------------------------

type
  CandidateRole = enum
    ## What a candidate that was SPAWNED and exited non-zero says about the
    ## host (R7-S1, round-7 review). Only consulted under `cdVersionOnly`.
    crDriver   ## the compiler driver itself. Spawned at all means PRESENT, so
               ## a non-zero exit is a present driver that would not identify
               ## itself: refused, never dropped as absent. Measured: with any
               ## non-empty `CL`, `cl` prints D8003 and exits 2 -- with its
               ## full banner when `CL` does not carry `/nologo`.
    crWrapper  ## a launcher that has to FIND the driver it wraps (`vccexe`,
               ## Nim's cl wrapper). A non-zero exit means either "the driver
               ## it wraps answered and failed" (it relays cl's output and exit
               ## code: measured identical to cl's under `CL=/W4` and
               ## `CL=/nologo`) or "there is no such driver on this host"
               ## (measured on a Nim + mingw host with no MSVC: exit 1, a Nim
               ## traceback, `Requested command not found: 'cl.exe'`). Only
               ## the first is present, and only it is refused -- see
               ## `relaysDriverAnswer`. Refusing the second would report
               ## every Nim + mingw Windows host as a refused MSVC.

  CcCandidate = tuple[driver: string; args: seq[string]; role: CandidateRole]
    ## A compiler driver and the arguments that make it state its version.
    ## The arguments are per-driver because MSVC has no `--version`: `cl`
    ## treats it as a source filename and fails. `cl` with NO arguments and
    ## an empty `CL` exits 0 and prints its banner; with ANY non-empty `CL` it
    ## exits 2 (measured -- R7-S1; `_CL_` is ignored when there are no
    ## arguments, so it does not change this probe).
    ##
    ## Not exported (CR8): appears only as the element type of the EXPORTED
    ## field `CcProbeProfile.ccCandidates*`, never named directly by any
    ## consumer -- every caller builds a profile from the exported
    ## `PosixCcProfile`/`WindowsCcProfile` consts rather than assembling a
    ## candidate list of its own. Reading `profile.ccCandidates` still works
    ## with this type unexported (Nim allows an exported field of an
    ## un-nameable type); only spelling `CcCandidate` itself would fail, and
    ## nothing in the tree does.

const
  PosixCcCandidates: seq[CcCandidate] = @[("cc", @["--version"], crDriver)]
    ## On POSIX `cc` is the canonical driver -- a symlink to whichever
    ## compiler the system means -- so there is exactly one to ask.
    ##
    ## Not exported (CR8): zero external references -- read only by
    ## `PosixCcProfile`, below, in this module.

  WindowsCcCandidates: seq[CcCandidate] = @[
    ("cl",      newSeq[string](), crDriver),
    ("vccexe",  newSeq[string](), crWrapper),
    ("gcc",     @["--version"],   crDriver),
    ("clang",   @["--version"],   crDriver),
    ("cc",      @["--version"],   crDriver),
  ]
    ## Windows has no canonical `cc`, so every plausible driver is asked and
    ## EVERY DISTINCT ANSWER IS FOLDED IN -- deliberately not first-match-wins.
    ## On a host carrying both Visual Studio and mingw, first-match-wins would
    ## report `cl` while Nim built with gcc, so a gcc upgrade would not change
    ## the key and a stale result would be served. Under-invalidation is the
    ## defect this probe exists to prevent; over-invalidation only costs a
    ## miss.
    ##
    ## `vccexe` is Nim's own cl wrapper and sits beside `nim`. It is asked
    ## because `cl` is on PATH only inside a Developer Command Prompt, while
    ## `vccexe` locates cl regardless -- so crisol run from a plain shell still
    ## identifies the toolchain Nim will actually use.
    ##
    ## Not exported (CR8): zero external references -- read only by
    ## `WindowsCcProfile`, below, in this module.

static:
  # DRIVER NAMES ARE UNIQUE per candidate list (R8-L3, round-8 review). This
  # is what keeps `CcHalf.refusedDrivers` duplicate-free: `ccIdentity` appends
  # a refused candidate's name without a membership test, since one candidate
  # can add itself at most once. A repeated name would print twice in the
  # warning ladder -- cosmetic, since refusal keys on `refusedDrivers.len > 0`
  # -- but it would also mean asking one driver twice, which is never intended.
  for candidates in [PosixCcCandidates, WindowsCcCandidates]:
    for i in 0 ..< candidates.len:
      for j in i + 1 ..< candidates.len:
        doAssert candidates[i].driver != candidates[j].driver,
          "duplicate cc candidate driver: " & candidates[i].driver

type
  RuntimeProbe* = enum
    ## How this platform names the C runtime library the toolchain will link.
    rpPrintFileName     ## ask the driver: `cc -print-file-name=<artifact>`
    rpMsvcLinkVerbose   ## link a trivial program and read `/VERBOSE:LIB`

  CcDriverIdentity* = enum
    ## How much of the compiler DRIVER reaches the fingerprint -- and, with
    ## it, how `ccIdentity` reads a candidate's output (R7-D4/D5):
    ##   - `cdVersionOnly` SELECTS AND ACCEPTS with `bannerLine` (the text is
    ##     the whole identity, so a line must prove it is a banner), and
    ##     REFUSES the half on a present driver that will not identify itself
    ##     (`CcHalf.refusedDrivers`);
    ##   - `cdVersionAndBinary` takes `versionLine` (first dotted line, else
    ##     the first line), never refuses, and drops a failed candidate: the
    ##     binary hash is the identity, and the text only labels it.
    cdVersionOnly       ## its banner alone
    cdVersionAndBinary  ## its banner, then " #" and a hash of its bytes

  CcProbeProfile* = object
    ## Everything platform-specific about the probe, in one value, so the
    ## WINDOWS behaviour can be driven from a test on any host. Without this
    ## the Windows arm would be exercisable only inside the MSVC container --
    ## the trap issue #22's capture tests are still stuck with.
    ##
    ## Stays exported (CR8 CAUTION): appears in the signature of `ccIdentity`,
    ## `ccVersion`, and (un-exported) `ccFingerprint`/`runtimeIdentity` --
    ## `ccVersion` is called directly from the test suites (`test_ccprobe`,
    ## `test_issue23_cc_identity`, `test_render`). Tests never name this
    ## TYPE directly (they pass the `PosixCcProfile`/`WindowsCcProfile`
    ## consts), so a raw name count reads zero, but un-exporting it would
    ## leave an unnameable type in a heavily-used public signature -- worse
    ## than the small amount of exposed surface it costs to keep it exported.
    ccCandidates*: seq[CcCandidate]
    driver*: CcDriverIdentity
    runtime*: RuntimeProbe

const
  LibcArtifact* = "libc.so.6"
    ## What `rpPrintFileName` asks the driver to resolve. The glibc runtime is
    ## the artifact whose implementation a version string cannot see.

  PosixCcProfile* = CcProbeProfile(
    ccCandidates: PosixCcCandidates,
    driver: cdVersionAndBinary,
    runtime: rpPrintFileName)

  WindowsCcProfile* = CcProbeProfile(
    ccCandidates: WindowsCcCandidates,
    driver: cdVersionOnly,
    runtime: rpMsvcLinkVerbose)
    ## `cdVersionOnly` on Windows is a DELIBERATE asymmetry, not an omission.
    ##
    ## Hashing a driver binary here would make the key depend on the SHELL.
    ## Windows has no canonical `cc`: which candidates answer depends on
    ## whether crisol was launched from a Developer Command Prompt (`cl` on
    ## PATH) or a plain shell (only `vccexe`), and those are two different
    ## binaries for one toolchain. Banner-text dedup is what keeps those two
    ## launches on the same key today; attaching a per-driver hash would split
    ## them again, and a spurious miss on every shell switch is a cost
    ## RFC-0005's shared cache cannot carry.
    ##
    ## Nothing is lost by it. The gap a driver hash closes on POSIX is a
    ## rebuild that moves no version string -- and cl's banner carries a full
    ## build number (`19.44.35228`) that moves with every toolset patch, while
    ## the runtime half content-hashes the `.lib` files the linker actually
    ## consumes. The bytes that matter are already keyed.

proc hostCcProfile(): CcProbeProfile =
  ## The profile for the host crisol is running on. The single platform fork
  ## in this module's probe logic.
  ##
  ## Not exported (CR8): zero external references -- reached only as
  ## `ccFingerprint`/`ccVersion`'s own default `profile` argument. Every test
  ## passes `PosixCcProfile`/`WindowsCcProfile` explicitly instead, exactly
  ## because a test wants to pin a platform regardless of which host it runs
  ## on.
  when defined(windows): WindowsCcProfile
  else:                  PosixCcProfile

proc resolveDriver*(name: string): string =
  ## The compiler driver `name` resolves to on PATH, or `""`.
  ##
  ## `findExe`, for the same reason `nimprobe.resolveNimBin` uses it: crisol's
  ## compile path spawns the bare command name through `poUsePath`, so a PATH
  ## lookup names the binary that will actually run -- not a configured one,
  ## and not a guess.
  findExe(name)

# ---------------------------------------------------------------------------
# CcFingerprint -- the structured canonical identity value (CR11)
#
# `ccVersion`'s "<legible text> #<hex digest>" grammar used to have THREE
# independent consumers of the same ad-hoc pipe/hash-mark shape: `keys.nim`
# (folds the rendered string into the soundness key), `planner.nim` (string-
# compares it for compile staleness), and `render.nim` (RE-PARSED it back out
# for `--explain-miss`) -- and that re-parse had already drifted from the real
# grammar (W7: no `#`-digest arm at all). `CcFingerprint` is now the canonical
# VALUE; the legacy pipe-string is a derived, SINGLE-producer
# (`` `$`(CcFingerprint) ``) / SINGLE-parser (`parseCcFingerprint`)
# serialization of it, kept only because `KeyInputs.ccVersion`,
# `DepGraphHeader.ccVersion` (the persisted depgraph header field) and
# `depgraph.loadDepGraph`'s staleness compare all thread a bare `string` today
# -- widening every one of those is out of RFC-0004's key-fold scope and
# unnecessary: a canonical serialization that round-trips is exactly as sound
# a key/comparison input as the structured value itself.
# ---------------------------------------------------------------------------

type
  CcDigestKind* = enum
    ## What (if anything) a `CcHalf`'s content digest means.
    cdkNone        ## no digest attempted/applicable to this half (e.g. the
                    ## Windows DRIVER half under `cdVersionOnly` -- see
                    ## `WindowsCcProfile`'s own doc for why that is a
                    ## deliberate decision, not a gap)
    cdkUnreadable  ## an artifact was NAMED but its content could not be read
                    ## (the old `FileHashSentinel` case -- e.g. a musl host,
                    ## where gcc echoes a library name back with rc=0 for a
                    ## file that does not exist)
    cdkKnown       ## a real content digest was computed

  CcDigest* = object
    case kind*: CcDigestKind
    of cdkKnown: hex*: string
    of cdkNone, cdkUnreadable: discard

  CcFieldState* = enum
    ## Ordered so `cfsNotProbed` is ordinal 0 -- the ZERO VALUE of a
    ## default-constructed `CcHalf()` -- DELIBERATELY. A case object's default
    ## branch is whichever the discriminant defaults to; putting "identified"
    ## first would make an uninitialized `CcHalf` silently read as "probe
    ## succeeded, found nothing" (a `cfsKnown` with an empty `text`), which is
    ## exactly the "probe succeeded but found nothing" state that must stay
    ## unrepresentable. With THIS ordering the zero value instead reads as "we
    ## never looked" -- honest, and never confusable with either real outcome.
    cfsNotProbed    ## no probe was attempted for this half at all -- "we did
                     ## not look", distinct from `cfsUnavailable` below. The
                     ## real `ccFingerprint()` derivation never produces this
                     ## for either half (it always attempts both probes); the
                     ## state exists so the TYPE can express "did not look" at
                     ## all, rather than aliasing it onto a magic sentinel
                     ## string the way the retired `LddSentinel` did (see this
                     ## module's "Sentinel values" doc, and CR11).
    cfsUnavailable  ## the probe RAN; nothing could be identified -- "we
                     ## looked and found nothing" (the old `CcSentinel`/
                     ## `RuntimeSentinel` case).
    cfsKnown        ## the probe ran and identified something real.

  CcHalf* = object
    ## One half (compiler driver, or runtime library) of a `CcFingerprint`.
    ## Only `cfsKnown` carries `text`/`digest` -- a case object, so
    ## "cfsUnavailable but claims a text value" is a COMPILE ERROR, not a
    ## runtime convention a caller has to honor by hand. This is what makes
    ## "probe succeeded but found nothing" unrepresentable: there is no field
    ## to smuggle an empty-but-present identity through on the other branches.
    case state*: CcFieldState
    of cfsKnown:
      text*:   string    ## legible identity text (a version banner, or a
                          ## runtime library name/version)
      digest*: CcDigest   ## optional content digest -- see `CcDigestKind`
    of cfsUnavailable:
      refusedDrivers*: seq[string]
        ## The candidate drivers `ccIdentity` REFUSED, in candidate order:
        ## drivers that were PRESENT and would not identify themselves -- one
        ## that exited 0 with no banner line (R4-1/R5-4/R6), or one that was
        ## spawned and exited non-zero (R7-S1). Empty when the half is
        ## unavailable because nothing answered at all. Replaces R6's
        ## `answeredUnidentified: bool` field, which is now the derived
        ## accessor below, so the flag and the names cannot disagree (R7-D6:
        ## the warning ladder names them).
        ##
        ## Each name appears at most once: `ccIdentity` adds a candidate at
        ## most once, and the shipped candidate lists' driver names are unique
        ## (the compile-time assertion after `WindowsCcCandidates`; R8-L3).
        ##
        ## Only a `cdVersionOnly` producer refuses, so only `ccIdentity` under
        ## `WindowsCcProfile` ever sets this; under `cdVersionAndBinary` an
        ## unavailable compiler half always carries `@[]`, whatever its one
        ## driver did (R7-D5). Every runtime half carries `@[]`.
        ##
        ## Diagnostic metadata for the warning ladder (`toolchainUnsoundReason`),
        ## NOT identity, and NOT a function of the serialized value:
        ## `serializeCcHalf` drops it (both a refused and an absent compiler
        ## half serialize to `CcSentinel`), `parseCcHalf` always yields `@[]`,
        ## and `==` ignores it, so a prior run's parsed half still compares
        ## equal to this run's (R6, round-6 review 2026-09-24). The reason can
        ## only be read off the probe's own in-process value.
    of cfsNotProbed:
      discard

  CcFingerprint* = object
    ## The canonical, structured C-toolchain identity (RFC-0004 component 4,
    ## CR11). `compiler` is the driver half (`ccIdentity`); `runtime` is the
    ## C runtime library half (`runtimeIdentity`).
    compiler*: CcHalf
    runtime*:  CcHalf

proc `==`*(a, b: CcDigest): bool =
  ## Nim's auto-derived `==` cannot walk a `case` object's parallel fields (a
  ## known limitation -- see `process/types.Exit`'s own `==`, same reason).
  ## Provided explicitly so `CcHalf`'s own `==` (and `render.nim`'s
  ## `prev.digest != curr.digest` field comparison, W7) work structurally.
  if a.kind != b.kind: return false
  case a.kind
  of cdkKnown:                 a.hex == b.hex
  of cdkNone, cdkUnreadable:    true

proc `==`*(a, b: CcHalf): bool =
  ## Same reason as `CcDigest`'s `==` above.
  if a.state != b.state: return false
  case a.state
  of cfsKnown:                      a.text == b.text and a.digest == b.digest
  of cfsUnavailable, cfsNotProbed:  true

proc ccKnown(text: string; digest = CcDigest(kind: cdkNone)): CcHalf =
  CcHalf(state: cfsKnown, text: text, digest: digest)

proc ccUnavailable(refusedDrivers: seq[string]): CcHalf =
  ## No default for `refusedDrivers`, by the same rule
  ## `ci/assert-defaulted-params.sh` enforces: a call site that forgot it
  ## would silently report a REFUSED driver as an absent one.
  CcHalf(state: cfsUnavailable, refusedDrivers: refusedDrivers)

proc answeredUnidentified*(h: CcHalf): bool =
  ## True iff `h` is `cfsUnavailable` because `ccIdentity` REFUSED one or more
  ## drivers that were present (`refusedDrivers` non-empty), as opposed to no
  ## driver answering at all. False for every other state. See
  ## `refusedDrivers` for when a producer sets it (only under `cdVersionOnly`)
  ## and why it is not recoverable from the serialized value.
  h.state == cfsUnavailable and h.refusedDrivers.len > 0

proc isFullyDegraded*(fp: CcFingerprint): bool =
  ## W4: true iff NEITHER half identified anything (both `cfsUnavailable`) --
  ## the fully-blind host, where the fingerprint folds to the SAME constant
  ## regardless of what toolchain is actually installed (structurally the
  ## same constant-folding defect issue #23 was opened to kill, narrowed to a
  ## broken host). `cfsNotProbed` is deliberately NOT included here --
  ## `ccFingerprint()` never produces it (see `CcFieldState`'s doc), so a
  ## caller observing it is looking at a value nothing in this module emits,
  ## not a degraded real probe.
  fp.compiler.state == cfsUnavailable and fp.runtime.state == cfsUnavailable

proc toolchainUnsound*(fp: CcFingerprint): bool =
  ## W4 (full fix): true when EITHER half is not `cfsKnown` (`cfsUnavailable`,
  ## or `cfsNotProbed` -- R7-S3, below), OR when the
  ## COMPILER half is `cfsKnown` but its text was never established to
  ## describe a real compiler at all (round-2 review finding, "a
  ## fallback-derived identity is recorded as a KNOWN toolchain") -- the
  ## trigger for `cachedispatch.shouldStore`'s `cdmToolchainUnidentified`
  ## refusal.
  ##
  ## Deliberately BROADER than `isFullyDegraded` (both halves unavailable).
  ## A single degraded half already makes the SoundnessKey's cc component
  ## untrustworthy for PUBLICATION: that half folds to a fixed sentinel
  ## (`CcSentinel`/`RuntimeSentinel`) regardless of what is actually
  ## installed, so any two hosts that share the SAME known other half (a
  ## fleet running one common, correctly-identified compiler package is the
  ## ordinary case, not the rare one) but differ in whatever real toolchain
  ## detail the degraded half failed to see -- a missing `ldd`, a sandboxed
  ## MSVC link-verbose probe, a musl vs. glibc runtime neither could read --
  ## collide on the exact same key. That is structurally the SAME defect
  ## `isFullyDegraded` exists to catch, narrowed to one axis instead of two,
  ## and if anything reached MORE often in practice: total probe blindness
  ## (both halves failing) tends to mean the whole host environment is
  ## broken, which is rare and usually noticed immediately; one half
  ## failing while the other resolves cleanly is exactly the kind of
  ## partial, easy-to-miss degradation (a container image without `ldd`,
  ## a locked-down linker) that would otherwise poison the shared cache
  ## silently.
  ##
  ## Deliberately NARROWER than "any imperfection": a `cfsKnown` half with
  ## no content digest (`CcDigest.kind != cdkKnown`, e.g. the Windows
  ## `cdVersionOnly` profile -- there is no `.lib` search list without a
  ## real link, so on some hosts none is available even though the version
  ## text IS) is not automatically this defect -- ONLY when its text ALSO
  ## fails `namesCompilerVersion` (no free-standing three-component version
  ## token, or one present in text that has a DIAGNOSTIC shape) does it trip. A
  ## real `cl`/`vccexe` banner ("Microsoft (R) C/C++ Optimizing Compiler
  ## Version 19.44.35228 for x64") keeps its `19.44.35228` across every
  ## localization (`namesCompilerVersion`'s own doc), so that TEXT still varies
  ## by real compiler identity even with no content proof behind it -- an
  ## already-accepted, documented degradation (RFC-0006). Refusing on that
  ## too would disable caching on every legitimate Windows publish, which
  ## stays out of scope for this fix.
  ##
  ## Text that names no compiler version is different IN KIND, not in degree,
  ## and that is what the extra trigger catches. Before R6, `ccIdentity`
  ## selected with `versionLine`, which falls back to the first non-empty line
  ## -- whatever the driver happened to print -- so a digest-less `cfsKnown`
  ## half could carry text never shown to describe a compiler. Two different
  ## drivers on two hosts could print the same such line and fold to one
  ## `cfsKnown` half with no digest to tell them apart: the "two hosts collide
  ## on a value that does not vary with what is installed" defect this proc
  ## exists to catch, reached through `cfsKnown` instead of `cfsUnavailable`.
  ## `ccIdentity` no longer produces that (it selects with `bannerLine`, which
  ## has no fallback, and refuses instead), so the disjunct is the backstop
  ## described below; the exemption for a digest-less half covers only text
  ## where its own justification -- "it names a compiler version" -- holds.
  ##
  ## R5-4 (round-5 review 2026-09-24) narrowed the exemption once more, for the
  ## same reason at the producer: a dotted token can be INCIDENTAL. `cl : Command
  ## line warning D9024 : ... '10.0.22621.0'` satisfied `hasDottedVersion`, so
  ## the same input that slipped past `ccIdentity`'s check also disarmed this
  ## backstop, and under `cdVersionOnly` there is no content digest behind it.
  ## The disjunct now asks `namesCompilerVersion`, so a diagnostic-shaped text
  ## trips it even when it carries a version-shaped token.
  ##
  ## WHAT THE DISJUNCT MEANS AFTER THAT CHANGE, EXACTLY. It is evaluated on
  ## `fp.compiler.text` WHOLE -- which for a multi-candidate Windows host is
  ## `ccIdentity`'s "; "-joined fold, not one banner. So:
  ##   - `hasBannerVersion` (R6; R5-4's unquoted-token test before it) stays
  ##     EXISTENTIAL over the fold: one honest banner's token still satisfies
  ##     it for the whole string. (R6 had `freeStanding` admit `;` on a
  ##     token's right for the fold's "; " join; R7-L4 removed it as dead --
  ##     the last folded segment keeps its own end-of-text context, see
  ##     `freeStanding`.)
  ##   - `hasDiagnosticCode`, `DiagnosticPhrases`, `hasQuote` and
  ##     `hasSwitchToken` scan the whole string, so a diagnostic ANYWHERE in the
  ##     fold trips the disjunct -- strictly more refusals, never fewer.
  ##   - `hasToolColonPrefix` is anchored at position 0, so it observes only the
  ##     FIRST folded segment. That is a real limit of judging a joined string
  ##     and is not worked around here; it does not matter for soundness
  ##     because the PRODUCER already refuses per candidate (below), and this
  ##     predicate is only the backstop.
  ##
  ## WHERE THE REAL GUARANTEE LIVES (R3-1, round-3 review; CORRECTED BY R4-1,
  ## round-4 review 2026-09-24; TIGHTENED BY R5-4, round-5 review 2026-09-24).
  ## This disjunct is a BACKSTOP, not the primary
  ## defence, and must not be relied on as one. Round 2 placed the check here
  ## alone, and here it is an EXISTENTIAL over an aggregate: `ccIdentity` joins
  ## every surviving candidate line with "; " before this proc ever sees them,
  ## so one honest driver's version token vouched for every other driver's
  ## text. The property needed is UNIVERSAL over candidates, so it is enforced
  ## per candidate at the producer instead: under `cdVersionOnly`, a candidate
  ## that answers `ok` and whose line fails `namesCompilerVersion` makes
  ## `ccIdentity` return `cfsUnavailable` for the WHOLE half -- tripping the
  ## FIRST disjunct above -- however many siblings did identify themselves.
  ## So does a candidate that answers NOT `ok` but was PRESENT
  ## (`presentButFailed`: a `crDriver` that ran and exited non-zero, or a
  ## `crWrapper` that relays its driver's answer -- R7-S1, round-7 review),
  ## whatever it printed. That arm is the one the real `CL`-poisoned `cl`
  ## takes (it exits 2); the `ok` arm covers a driver that exits 0 without
  ## identifying itself. Both are at the producer; this predicate sees
  ## neither directly (R8-D5, round-8 review).
  ##
  ## R3-1's own first form did NOT achieve that, and this paragraph used to
  ## claim it did. It merely dropped the unversioned candidate from the fold,
  ## which cures the zero-survivor case and leaves the multi-candidate one: the
  ## very `CL=/nologo` + mingw-`gcc` host it was written for HAS a survivor, so
  ## the half stayed `cfsKnown` on gcc's banner and the run published a
  ## bystander compiler's identity for a build the MSVC toolset performed
  ## (R4-1; see `ccIdentity`'s inline comment for the measured shape). Neither
  ## disjunct here could have caught it -- the joined text genuinely carries
  ## `13.2.0` -- which is precisely why the producer, not this predicate, has to
  ## hold the property.
  ##
  ## What remains here is cheap insurance for a future `cdVersionOnly` producer
  ## that forgets to check. It is kept rather than deleted because it is a pure
  ## predicate over `CcHalf`, and it is tested directly over its own input space
  ## (`test_cachedispatch.nim`) rather than left to be reached through
  ## production -- an untested backstop is the thing worth deleting; a tested
  ## one costs a branch.
  ##
  ## Scoped to the COMPILER half only -- `fp.runtime` is never inspected by
  ## this extra trigger. The runtime half's text is a set of library
  ## basenames (`msvcRuntimeIdentity`) or a libc version line
  ## (`runtimeIdentity`'s `rpPrintFileName` arm), never a compiler banner;
  ## applying `namesCompilerVersion` to it would be a category error, not a
  ## soundness check.
  ##
  ## `cfsNotProbed` FAILS CLOSED (R7-S3/D7, round-7 review). It is the ZERO
  ## VALUE of `CcHalf`, and `api.CcFingerprintProbe` (R5-10) makes a value
  ## built outside this module reachable here; "we never looked" identifies
  ## nothing, so it is unsound on either half, exactly like `cfsUnavailable`.
  ## It used to read as SOUND: the first two disjuncts tested
  ## `== cfsUnavailable`, and the third only a `cfsKnown` compiler.
  ##
  ## POSIX is unaffected in practice, without needing a platform check.
  ## `PosixCcProfile` is `cdVersionAndBinary`, and `ccIdentity`'s
  ## `cdVersionAndBinary` arm always constructs `CcDigest(kind: cdkKnown, ...)`
  ## for the compiler half -- even when `hashFile` itself degrades to
  ## `FileHashSentinel`, that string is embedded as `cdkKnown`'s `hex`, never
  ## surfaced as `cdkUnreadable` (a pre-existing POSIX quirk, unchanged by
  ## this fix: `$`-serialized bytes are identical either way, since
  ## `digestText` renders `cdkUnreadable` back to the same `FileHashSentinel`
  ## string). So `digest.kind == cdkKnown` holds for every `cfsKnown` POSIX
  ## compiler half today, and the new disjunct's `digest.kind != cdkKnown`
  ## guard can never be satisfied there.
  fp.compiler.state != cfsKnown or fp.runtime.state != cfsKnown or
    (fp.compiler.digest.kind != cdkKnown and
     not namesCompilerVersion(fp.compiler.text))

type
  ToolchainUnsoundReason* = enum
    ## WHY `toolchainUnsound` fired -- one value per message the warning
    ## ladder in `api.nim` prints, so that ladder is an exhaustive `case` and a
    ## new reason is a compile error there rather than a silently inherited
    ## message (R3-4's stated intent for that ladder, now enforced).
    turSound            ## `toolchainUnsound` is false
    turCompilerRefused  ## a compiler driver was PRESENT and did not identify
                        ## itself -- no banner line, or a non-zero exit (R7-S1)
                        ## -- so `ccIdentity` refused the half; the drivers are
                        ## in `fp.compiler.refusedDrivers`
    turBlind            ## neither half is `cfsKnown` (unavailable or never
                        ## probed), and no driver was refused
    turCompilerUnnamed  ## both halves `cfsKnown`, but the digest-less compiler
                        ## text names no compiler version (the backstop)
    turHalfMissing      ## exactly one half is not `cfsKnown`, and not because
                        ## a driver was refused

proc toolchainUnsoundReason*(fp: CcFingerprint): ToolchainUnsoundReason =
  ## The reason `toolchainUnsound(fp)` is true, or `turSound` when it is not.
  ## Agrees with `toolchainUnsound` by construction: it asks that predicate
  ## first and only classifies a positive answer.
  ##
  ## `turCompilerRefused` is checked FIRST, ahead of `turBlind` (R6, round-6
  ## review 2026-09-24). Before it existed a refused driver fell through to
  ## "a compiler driver or a runtime library answered, but not both" -- or,
  ## with the runtime half also down, "neither ... answered" -- and both are
  ## false: the compiler DID answer, it merely printed no banner. That is the
  ## one case whose remedy the user can act on (look at `CL`; not `_CL_`,
  ## which the no-argument probe ignores, so it cannot cause a refusal --
  ## R8-D6), so it must not be reported as absence.
  ##
  ## `turBlind` is "neither half `cfsKnown`" rather than `isFullyDegraded`
  ## (both `cfsUnavailable`), so the zero-value fingerprint `toolchainUnsound`
  ## refuses (R7-S3) gets the blind message rather than "half missing".
  if not toolchainUnsound(fp): return turSound
  if fp.compiler.answeredUnidentified:
    return turCompilerRefused
  if fp.compiler.state != cfsKnown and fp.runtime.state != cfsKnown:
    return turBlind
  if fp.compiler.state == cfsKnown and fp.runtime.state == cfsKnown:
    return turCompilerUnnamed
  turHalfMissing

proc digestText(d: CcDigest): string =
  case d.kind
  of cdkKnown:      d.hex
  of cdkUnreadable: FileHashSentinel
  of cdkNone:       ""

proc serializeCcHalf*(h: CcHalf; unavailableSentinel: string): string =
  ## Serialize one half back to its legacy raw-string shape --
  ## `<text> #<digest>`, `<text>` alone when there is no digest, or
  ## `unavailableSentinel` verbatim. The sentinel spelling is PER-HALF
  ## (`CcSentinel` vs `RuntimeSentinel`), so a caller must supply the right
  ## one; `` `$`(CcFingerprint) `` below is the only production caller that
  ## knows both, but `render.nim` also calls this directly to reconstruct a
  ## raw segment for its non-digest-only diff lines (never re-deriving the
  ## grammar itself -- see that module's `renderCcVersionLines`).
  case h.state
  of cfsKnown:
    let dt = digestText(h.digest)
    if dt.len > 0: h.text & " #" & dt else: h.text
  of cfsUnavailable, cfsNotProbed:
    unavailableSentinel

proc `$`*(fp: CcFingerprint): string =
  ## THE single producer of the legacy `"<cc identity>|<runtime identity>"`
  ## string -- RFC-0004 component 4's key-fold shape, `DepGraphHeader.
  ## ccVersion`'s persisted shape, `depgraph.loadDepGraph`'s staleness-compare
  ## shape. Round-trips through `parseCcFingerprint` for any value this proc
  ## produced.
  serializeCcHalf(fp.compiler, CcSentinel) & "|" &
    serializeCcHalf(fp.runtime, RuntimeSentinel)

proc parseCcHalf(s, unavailableSentinel: string): CcHalf =
  ## THE single parser for one serialized half -- the inverse of
  ## `serializeCcHalf`. Used by `parseCcFingerprint` so no second, ad-hoc
  ## re-parse of this grammar exists anywhere else in the tree (CR11:
  ## `render.splitFirstPipe` used to be exactly that second parser, and it
  ## had already drifted -- W7, no `#`-digest arm at all).
  if s == unavailableSentinel:
    return ccUnavailable(refusedDrivers = @[])
  let hashIdx = s.rfind(" #")
  if hashIdx < 0:
    return ccKnown(s)
  let text = s[0 ..< hashIdx]
  let tail = s[hashIdx + 2 .. ^1]
  if tail == FileHashSentinel:
    ccKnown(text, CcDigest(kind: cdkUnreadable))
  else:
    ccKnown(text, CcDigest(kind: cdkKnown, hex: tail))

proc parseCcFingerprint*(s: string): tuple[fp: CcFingerprint; ok: bool] =
  ## Parse a `ccVersion()`/`` `$`(CcFingerprint) `` string back into its
  ## structured halves -- the ONE place this grammar is read, so a future
  ## consumer (like `render.nim`'s `--explain-miss`) never re-derives it by
  ## hand again. `ok = false` for any value with no top-level `|` -- a
  ## malformed or foreign string (e.g. a stale/synthetic `KeyDiff` fixture) --
  ## callers must fall back rather than guess. Splits on the FIRST `|`: both
  ## halves are already single lines, so there is exactly one meaningful
  ## split point (same rule `render.splitFirstPipe` used to apply by hand).
  let idx = s.find('|')
  if idx < 0:
    return (CcFingerprint(), false)
  let compiler = parseCcHalf(s[0 ..< idx], CcSentinel)
  let runtime  = parseCcHalf(s[idx + 1 .. ^1], RuntimeSentinel)
  (CcFingerprint(compiler: compiler, runtime: runtime), true)

proc presentButFailed(role: CandidateRole; output: string): bool =
  ## True iff a candidate that answered `ok = false` was nonetheless PRESENT
  ## (R7-S1). The `RunProc` contract (see `toolrun.RunProc`) guarantees ONE
  ## direction only: `toolrun.runViaOsproc` returns `""` on every path that
  ## does not run the command to an exit (spawn failure -- not on PATH -- an
  ## OSError, a CR4 timeout). So non-empty output with `ok = false` is a
  ## process that ran and exited non-zero (pinned against the real primitive
  ## by `tests/integration/test_r7_probe_presence_contract.nim`). Such a
  ## `crDriver` is present by that fact alone; a `crWrapper` only if it relays
  ## its driver's answer (`relaysDriverAnswer`).
  ##
  ## The converse does NOT hold: empty output does not prove the command never
  ## ran. A driver that ran, exited non-zero and printed nothing at all also
  ## comes back `("", false)`, and is read as absent. RESIDUAL, on record
  ## (R8-D5, round-8 review): no real driver has been observed to do that --
  ## cl and vccexe print a D8003 or a banner, gcc/clang/cc print a diagnostic
  ## -- and there is no way to tell it from a spawn failure without widening
  ## `RunProc`, which the next paragraph declines.
  ##
  ## WHITESPACE-ONLY output is NOT empty, and is read as present (R8-L3,
  ## round-8 review). Under the contract only `""` can mean "did not run", so
  ## a capture of only spaces or newlines came from a process that ran and
  ## exited non-zero: a `crDriver` is refused on it like on any other
  ## failure. The test is `output.len == 0`, deliberately not
  ## `output.strip.len == 0` (the R7-S1 form, which read such a driver as
  ## absent and let a bystander's banner stand in for it). A `crWrapper` with
  ## whitespace-only output still reads absent, because it relays neither a
  ## banner nor a code -- the same rule as for any other wrapper capture.
  ##
  ## Why output rather than a spawn flag: `RunProc` is `tuple[output, ok]`,
  ## destructured by every probe in `closure`/`artifactid`/`nimprobe` and by
  ## their fakes, and `ccVersion`/`ccFingerprint` pin its default in
  ## `ci/assert-defaulted-params.sh`; widening it for one caller is the churn
  ## `toolrun`'s doc already declined twice. The emptiness test is exact for
  ## the real seam, not a guess about it.
  ##
  ## RESIDUAL, on record: a driver that is present but WEDGED is cut off by
  ## CR4's deadline and comes back `""` too, so it reads as absent. That path
  ## prints its own `crisol: warning:` naming the driver, and a driver that
  ## cannot answer `--version` within 10 s is not compiling anything either.
  if output.len == 0: return false
  case role
  of crDriver:  true
  of crWrapper: relaysDriverAnswer(output)

proc ccIdentity*(run: RunProc; profile: CcProbeProfile;
                 hashFile: BinHashProc): CcHalf =
  ## Ask every candidate driver for its version and fold the distinct answers,
  ## in CANDIDATE order, joined with "; ". A `cfsUnavailable` half (serialized
  ## as `CcSentinel`) if none answers.
  ##
  ## `run` MUST honour `toolrun.RunProc`'s contract: `output = ""` on every
  ## path that did not run the command to an exit (not on PATH, an OSError, a
  ## timeout). This proc reads non-empty output with `ok = false` as a driver
  ## that RAN and failed (`presentButFailed`), so an injected `RunProc` that
  ## returns text for a command that never ran -- a shell's `command not
  ## found`, say -- makes an absent driver look present and refuses the half
  ## (R8-D10, round-8 review).
  ##
  ## Under `cdVersionOnly` a candidate that ANSWERED (`ok`) and has NO line
  ## satisfying `namesCompilerVersion` (`bannerLine` returns `""`) -- no line
  ## states a free-standing, three-component version without a DIAGNOSTIC or
  ## argv-echo shape (`looksLikeDiagnostic`) -- DEGRADES THE WHOLE HALF to
  ## `cfsUnavailable`, naming it in `refusedDrivers`. It is not merely left
  ## out of the fold (R4-1, round-4 review 2026-09-24; R3-1's original
  ## drop-and-continue is exactly what that finding corrects), and the
  ## predicate is no longer the bare `hasDottedVersion` R4-1 used, which one
  ## incidental dotted token anywhere in the capture satisfied (R5-4, round-5
  ## review 2026-09-24). The line that is judged is also the line that is
  ## folded: `bannerLine` selects BY the acceptor, where R5-4 still selected
  ## with `versionLine` and judged only that one line (R6, round-6 review
  ## 2026-09-24 -- see `bannerLine`). Such a
  ## candidate is positive evidence that a driver IS present and that this probe
  ## cannot enumerate the toolchain honestly, so no sibling's version token may
  ## be allowed to stand in for it -- not in the fold, and not by the half
  ## staying `cfsKnown`. See the inline comment at the check, and
  ## `toolchainUnsound`'s "WHERE THE REAL GUARANTEE LIVES".
  ##
  ## A candidate that EXITED NON-ZERO (`not ok`) is judged by whether it was
  ## PRESENT (`presentButFailed`; R7-S1, round-7 review 2026-09-25). Under
  ## `cdVersionOnly` a present one is refused exactly like an unidentifiable
  ## answer: with any non-empty `CL`, a real `cl` prints D8003 and exits 2
  ## (measured), and reading that as "absent" let a bystander gcc's banner
  ## become the whole compiler half while cl compiled. A candidate that is
  ## ABSENT -- never spawned, so its output is empty -- is still dropped
  ## silently and does NOT degrade the half: most of the five Windows
  ## candidates are missing on any given host (`cl` answers only inside a
  ## Developer Command Prompt, `vccexe` only where Nim is installed), so their
  ## absence says nothing at all about the toolchain. `vccexe` failing because
  ## it cannot find cl is absence of MSVC, not a present MSVC (`crWrapper`).
  ##
  ## Deduplicated on the BANNER TEXT, never on the driver name. `cl` and
  ## `vccexe` return byte-identical banners, so text-dedup gives one
  ## fingerprint whether or not crisol was launched from a Developer Command
  ## Prompt; name-dedup would fingerprint one toolchain two different ways
  ## depending on the shell, and spurious misses would look like real
  ## toolchain drift.
  ##
  ## Candidate order, not PATH order: the result must not move because a
  ## directory was prepended to PATH.
  ## Under `cdVersionAndBinary` each distinct banner additionally carries a
  ## content hash of the driver that produced it -- the `nimprobe` idiom,
  ## which `nimprobe`'s own module doc has always claimed this module already
  ## used. A distro that rebuilds gcc with a codegen fix and leaves the
  ## version string alone changes the object code crisol caches against; a
  ## banner cannot see that, and bytes can.
  ##
  ## The hash attaches to the FIRST driver that produced a given banner, in
  ## candidate order. On POSIX there is exactly one candidate, so that is the
  ## whole story; the Windows profile does not use this mode at all, for the
  ## reason recorded on `WindowsCcProfile`.
  var found: seq[tuple[line, driver: string]] = @[]
  # R4-1: the candidates that were present under `cdVersionOnly` and would not
  # name a version (R7-D6: by name, for the warning). Collected rather than
  # returned on immediately so the remaining candidates are still probed: the
  # loop has no other early exit, and bailing mid-list would make which drivers
  # get spawned depend on candidate order.
  #
  # Appended WITHOUT a membership test (R8-L3, round-8 review): each of the two
  # `refused.add` sites below is followed by `continue`, so one candidate adds
  # its name at most once, and the candidate lists' driver names are unique
  # (asserted at compile time beside `WindowsCcCandidates`). A `notin refused`
  # guard used to sit on both sites; it was unreachable, and replacing it with
  # `true` stayed green in every test. Soundness never depended on it either:
  # the half is refused on `refused.len > 0`; the names only feed the warning.
  var refused: seq[string] = @[]
  for candidate in profile.ccCandidates:
    let (output, ok) = run(candidate.driver, candidate.args)
    # EXITED NON-ZERO (R7-S1, round-7 review). This arm used to read every
    # `not ok` as ABSENT and drop it silently -- right for a driver that is not
    # on PATH, which is most of them on any host, and wrong for one that ran
    # and failed: cl under any non-empty `CL` prints its D8003 (and its whole
    # banner, unless `CL` carries `/nologo`) and EXITS 2, measured with
    # `!ERRORLEVEL!`. Round 4 recorded exit 0 for that shape, which is why
    # R4-1's refusal was written only for the `ok` arm below. `presentButFailed`
    # tells the two apart (see it for why the output, not a spawn flag). A
    # present one is refused whatever it printed, banner included: a non-zero
    # exit is not a clean answer, and `CL`'s contents reach every compile cl
    # performs without reaching the key. That refusal is on the EXIT STATUS,
    # not the text, so it does not contradict `bannerLine`'s rule that a
    # diagnostic beside a real banner does not refuse it (that rule judges
    # exit-0 captures); it is a stopgap tied to R7-S6, the split-out
    # compile-environment issue (R8-D5). Absent stays silent, or no host could
    # ever publish. `cdVersionAndBinary` keeps dropping every failure -- see
    # the NEVER paragraph below.
    if not ok:
      if profile.driver == cdVersionOnly and
         presentButFailed(candidate.role, output):
        refused.add candidate.driver
      continue
    # SELECTED BY THE ACCEPTOR under `cdVersionOnly` (R6): `bannerLine` returns
    # the first line satisfying `namesCompilerVersion`, or `""`. So the check
    # below judges exactly the line that is folded, and a banner is found
    # wherever the merged capture happened to put it. `cdVersionAndBinary`
    # keeps `versionLine`, unchanged -- see the NEVER paragraph below.
    let line =
      case profile.driver
      of cdVersionOnly:      bannerLine(output)
      of cdVersionAndBinary: versionLine(output)
    # R3-1 (round-3 review), CORRECTED BY R4-1 (round-4 review 2026-09-24),
    # CORRECTED AGAIN BY R5-4 (round-5 review 2026-09-24) AND R6 (round-6).
    #
    # Under `cdVersionOnly` the compiler half carries NO content digest, so this
    # TEXT is the whole identity. A candidate with no banner line (`line == ""`)
    # printed nothing shown to describe a compiler -- a diagnostic, an argv
    # echo, a usage line, or nothing -- so it must not be folded in and
    # re-judged downstream. (Before R6 the line came from `versionLine`, whose
    # first-non-empty-line fallback handed over whatever the driver printed;
    # `bannerLine` has no fallback.) Judging it PER CANDIDATE is the whole point: the fold below
    # joins every surviving line with "; ", and `toolchainUnsound` sees only
    # that joined result, so one honest driver's version token would otherwise
    # vouch for every other driver's text.
    #
    # WHAT R3-1's FIRST FORM GOT WRONG. It merely `continue`d here -- it DROPPED
    # the unidentifiable candidate. That cures only the ZERO-survivor case
    # (`found.len == 0` below -> `ccUnavailable(refusedDrivers = @[])`), and the
    # trigger R3-1 itself cited HAS a survivor: `CL=/nologo` in the environment
    # makes a real `cl` print `cl : Command line error D8003 : missing source
    # filename` (the probes inherit the parent env), on a windows-latest-shaped
    # host that ALSO ships mingw `gcc`. With cl's line dropped, gcc's `13.2.0`
    # stood alone in the fold, the half was `cfsKnown`, `toolchainUnsound`
    # returned false, and the run published to the SHARED L2 tier with a
    # BYSTANDER compiler's identity standing in for the MSVC toolset that
    # actually compiles (`cc = vcc`) -- the same cross-host under-invalidation
    # this check exists to close, merely relabelled. (That `cl` in fact exits
    # 2, not the 0 recorded then -- R7-S1. The `not ok` arm above now refuses
    # it; this arm keeps the same property for a driver that answers rc=0
    # without identifying itself.)
    #
    # WHAT THIS FORM GUARANTEES. A candidate that answered and will not identify
    # itself is positive evidence that a driver IS present and that this probe
    # CANNOT enumerate the toolchain honestly. That is a fact about the HOST,
    # not about one candidate, so it degrades the whole half: a non-empty
    # `refused` forces `ccUnavailable(refusedDrivers = refused)` below however
    # many siblings were identifiable,
    # which trips `toolchainUnsound`'s FIRST disjunct and disables caching.
    # Over-invalidation is not one cache MISS: a refused half makes
    # `shouldStore` refuse EVERY store (the local tier too) and the degraded
    # key is one no host stores under, so a misconfigured host caches nothing
    # on every run while the cause persists (R8-D1, round-8 review). That
    # cost stays on the host that has the problem; under-invalidation poisons
    # a tier shared across hosts. This module's own
    # doc mandates that direction -- see `WindowsCcCandidates`: "under-
    # invalidation is the defect this probe exists to prevent; over-invalidation
    # only costs a miss".
    #
    # WHAT R4-1's OWN FORM GOT WRONG (R5-4). It spelled the test
    # `not hasDottedVersion(line)`, which is a far weaker predicate than the
    # sentence above: `versionLine` returns the first line carrying a dotted
    # token if ANY line does, so that test only fires when NO
    # `<digit>.<digit>` appears anywhere in the whole capture. ONE incidental
    # dotted token -- an SDK version echoed back by `cl : Command line warning
    # D9024 : unrecognized source file type '10.0.22621.0'`, which the poisoned
    # `CL`/`_CL_` environments this check exists for routinely produce -- let
    # R4-1's own named laundering scenario through unchanged, and in the
    # no-bystander case folded a pure diagnostic (text that cannot vary with
    # the installed toolset at all, so two hosts with different MSVC toolsets
    # get the SAME compiler half) into a published key. The condition now also
    # requires the line to look like a BANNER and not a DIAGNOSTIC --
    # `namesCompilerVersion`, whose own doc states exactly what that does and
    # does not establish, and which can only degrade a SUPERSET of what
    # `hasDottedVersion` alone degraded.
    #
    # WHAT R5-4's OWN FORM GOT WRONG (R6). It still SELECTED with `versionLine`
    # and judged only the selected line, so selector and acceptor were two
    # predicates. A wrapped D9002 whose continuation held `C:\Python3.11\...`,
    # an echoed argv, and an unprefixed SDK path under `LINK : fatal error`
    # each had a clean-looking dotted line selected, and each was BELIEVED;
    # while a real banner printed AFTER a dotted D9024 was never looked at, so
    # the verdict flipped with pipe flush order. `bannerLine` makes selection
    # and acceptance one predicate, and the predicate itself now refuses those
    # lines on their own merits (`namesCompilerVersion`). A real banner is
    # believed wherever it sits, even beside a diagnostic -- see `bannerLine`
    # for why that is sound. Written as `not namesCompilerVersion(line)` rather
    # than `line.len == 0` (equivalent here, since `bannerLine` returns only
    # lines that satisfy it) so the condition names the predicate it enforces.
    #
    # `ok` with no non-empty output at all (`line.len == 0`) is the SAME
    # situation, not a milder one, so it takes this arm too -- measured:
    # `vccexe.exe /Zs --platform:amd64 /nologo /Qzzzbogus unit.c` exits 0 with
    # its diagnostic on a stream the version probe never reads. That is why the
    # `line.len == 0` skip below sits UNDER this check and not above it: hoisted
    # above it, such a candidate is dropped silently and a versioned sibling's
    # banner stands alone in a `cfsKnown` half. R5-5 found that the ordering was
    # observed by no test at all (every empty-output fixture had no surviving
    # sibling, so `found.len == 0` reached `ccUnavailable()` for the other
    # reason); suite 3c-iv in `tests/unit/test_ccprobe.nim` now pins it with a
    # bystander present.
    #
    # NEVER applied under `cdVersionAndBinary`: there the driver binary is
    # content-hashed, so unversioned text still sits behind a real content
    # proof, and discarding the candidate -- let alone refusing the half --
    # would throw that proof away to punish its banner: strictly worse, and
    # POSIX's only candidate at that. That arm keeps the original behaviour
    # exactly, which is why the `line.len == 0` skip below survives for it.
    if profile.driver == cdVersionOnly and not namesCompilerVersion(line):
      refused.add candidate.driver
      continue
    if line.len == 0: continue
    if not found.anyIt(it.line == line):
      found.add (line: line, driver: candidate.driver)
  if refused.len > 0 or found.len == 0:
    return ccUnavailable(refusedDrivers = refused)

  let text = found.mapIt(it.line).join("; ")
  case profile.driver
  of cdVersionOnly:
    ccKnown(text)
  of cdVersionAndBinary:
    # `cdVersionAndBinary` is used only by `PosixCcProfile`, which has EXACTLY
    # one candidate (`PosixCcCandidates`), so `found.len == 1` always holds
    # here -- one text, one digest, attached to the driver that produced it.
    ccKnown(text, CcDigest(kind: cdkKnown, hex: hashFile(resolveDriver(found[0].driver))))

proc msvcRuntimeIdentity(linkProbe: LinkProbeProc;
                         hashFile: BinHashProc): CcHalf =
  ## The MSVC arm of `runtimeIdentity`: the set of libraries the linker
  ## actually searches, each by BASENAME and CONTENT.
  ##
  ## There is no version string to read. Nim+vcc links the CRT STATICALLY
  ## (measured: `dumpbin /dependents` on a `nim c --cc:vcc` binary lists
  ## KERNEL32.dll and nothing else), so there is no libc DLL on the host to
  ## fingerprint -- which is why the two obvious candidates, hashing
  ## `System32/ucrtbase.dll` or keying on the OS build, are not merely costly
  ## but WRONG: they move on Windows Updates that cannot affect the binary and
  ## stay still on the SDK changes that can.
  ##
  ## Asking the linker closes that gap precisely. `LIBCMT.lib` and
  ## `libvcruntime.lib` ship with the VC toolset, so cl's banner already
  ## covers them -- but `libucrt.lib` ships with the WINDOWS SDK and is
  ## versioned independently of cl, so a cl-banner-only fingerprint leaves
  ## exactly that library invisible.
  ##
  ## Only the BASENAME and the CONTENT reach the result, never the path: the
  ## same toolset installed under `C:/msvc` and under
  ## `C:/Program Files/Microsoft Visual Studio/...` must key the same, and the
  ## randomized scratch directory `realLinkVerbose` builds in must never key
  ## anything (`test_rfc9_a5c_cache_portability.nim` rests on this probe being
  ## constant for the lifetime of the process).
  ##
  ## A library that cannot be read keeps its entry, carrying
  ## `FileHashSentinel` as its digest -- dropping it would silently narrow the
  ## key, which is the failure mode this whole issue exists to remove.
  type Entry = tuple[name, digest: string]
  var entries: seq[Entry] = @[]
  for path in parseVerboseLibPaths(linkProbe()):
    # One entry per path the parser kept -- `parseVerboseLibPaths` is the
    # single place duplicates are collapsed, and hashing is the expensive
    # step, so a second dedup here would only hide whether that one works.
    entries.add (name: libBasename(path).toLowerAscii, digest: hashFile(path))

  if entries.len == 0: return ccUnavailable(refusedDrivers = @[])

  # A total order on (name, digest) -- never on the path, and never the order
  # the linker happened to search in, which is a property of the probe's
  # translation unit rather than of the toolchain.
  entries.sort(proc (a, b: Entry): int =
    result = cmp(a.name, b.name)
    if result == 0: result = cmp(a.digest, b.digest))

  var names: seq[string] = @[]
  var running = ""
  for e in entries:
    # Chained through BOTH name and digest, so swapping two libraries'
    # contents changes the result (the same non-commutative fold
    # `fnv.chainedContentHash` uses, which cannot be reused here because it
    # reads files itself and would bypass the `hashFile` seam).
    running = toHex16(fnv1a64(running & "\x00" & e.name & "\x00" & e.digest))
    names.add(if e.name.endsWith(LibSuffix):
                e.name[0 ..< e.name.len - LibSuffix.len]
              else: e.name)
  ccKnown(names.join("+"), CcDigest(kind: cdkKnown, hex: running))

proc runtimeIdentity(run: RunProc; profile: CcProbeProfile;
                     hashFile: BinHashProc;
                     linkProbe: LinkProbeProc = realLinkVerbose): CcHalf =
  ## Identify the C runtime library the toolchain will link, as
  ## `<version text> #<content hash>`.
  ##
  ## Not exported (CR8): zero external references -- reached only via
  ## `ccFingerprint`. Every test drives this indirectly through `ccVersion`.
  ##
  ## The hash is what makes it SOUND -- a distro backport patches
  ## `libc.so.6` without moving the version `ldd` prints, and the old
  ## version-string-only fingerprint could not see that. The text is what
  ## keeps `--explain-miss` legible: "glibc 2.38 -> 2.39" reads; two opaque
  ## digests do not.
  ##
  ## Only the artifact's CONTENT reaches the result -- never its path, so two
  ## hosts carrying the same glibc under different prefixes still agree, which
  ## is what RFC-0005's shared-cache argument needs.
  case profile.runtime
  of rpMsvcLinkVerbose:
    msvcRuntimeIdentity(linkProbe, hashFile)
  of rpPrintFileName:
    let (lddOut, lddOk) = run("ldd", ["--version"])
    let label = if lddOk: versionLine(lddOut) else: ""

    # Ask the DRIVER where the runtime is; never guess a path. gcc echoes the
    # bare name back when it cannot resolve one (musl), and `realFileHash`
    # turns that into FileHashSentinel rather than a silent success.
    let (pathOut, pathOk) = run("cc", ["-print-file-name=" & LibcArtifact])
    let path = if pathOk: firstLine(pathOut) else: ""

    let digest = hashFile(path)

    # Nothing identified the runtime -- no version text AND no readable
    # artifact. Say so, rather than a `cfsKnown` half naming "libc.so.6" with
    # an unreadable digest, which reads like a resolved artifact that merely
    # failed to open.
    if label.len == 0 and digest == FileHashSentinel:
      return ccUnavailable(refusedDrivers = @[])

    # A host with no `ldd` (musl, or Windows-hosted gcc) can still have its
    # runtime identified by content; the artifact name stands in for the text.
    let text = if label.len > 0: label else: LibcArtifact
    if digest == FileHashSentinel:
      ccKnown(text, CcDigest(kind: cdkUnreadable))
    else:
      ccKnown(text, CcDigest(kind: cdkKnown, hex: digest))

proc ccFingerprint(run: RunProc = realRunMerged;
                   profile: CcProbeProfile = hostCcProfile();
                   hashFile: BinHashProc = realFileHash;
                   linkProbe: LinkProbeProc = realLinkVerbose): CcFingerprint =
  ## THE canonical derivation (CR11): a structured fingerprint of the host's C
  ## toolchain and its runtime library. Every probe goes through `run`; the
  ## default is the MERGED-stream runner, because a version banner has no
  ## fixed stream (see `realRunMerged`). Never raises.
  ##
  ## Not exported (CR8): see this module's own top-of-file doc for why --
  ## every external caller goes through `cachedCcFingerprint()` (production)
  ## or `ccVersion` (tests).
  CcFingerprint(
    compiler: ccIdentity(run, profile, hashFile),
    runtime:  runtimeIdentity(run, profile, hashFile, linkProbe))

proc ccVersion*(run: RunProc = realRunMerged;
                profile: CcProbeProfile = hostCcProfile();
                hashFile: BinHashProc = realFileHash;
                linkProbe: LinkProbeProc = realLinkVerbose): string =
  ## `$ccFingerprint(run, profile, hashFile, linkProbe)` -- the legacy
  ## rendered-string accessor (see this module's doc). Shape is
  ## `<cc identity>|<runtime identity>` -- two `|`-separated segments, which
  ## `parseCcFingerprint` (THE single parser -- `render.nim`'s consumer)
  ## relies on to show a readable miss.
  $ccFingerprint(run, profile, hashFile, linkProbe)

# ---------------------------------------------------------------------------
# cachedCcFingerprint / cachedCcVersion — memoised startup accessors (real runner)
# ---------------------------------------------------------------------------

var
  ccFingerprintVal:    CcFingerprint
  ccFingerprintCached: bool = false
    ## Separate bool, not "is `ccFingerprintVal` still the zero value" --
    ## the zero value (`CcHalf()` on both halves, i.e. `cfsNotProbed`/
    ## `cfsNotProbed`) is unreachable from a real `ccFingerprint()` call (see
    ## `CcFieldState`'s doc: production always attempts both probes), so it
    ## WOULD be a safe sentinel in principle -- this flag is the same
    ## precaution `ccVersionCache.len == 0` took for the string form, kept
    ## explicit rather than resting on that unreachability.

proc cachedCcFingerprint*(): CcFingerprint =
  ## Probe the C toolchain exactly once per process; return the cached value
  ## on subsequent calls. Always uses the real runner — unit tests should
  ## call `ccVersion` (or `ccIdentity`) directly with an injected seam;
  ## `ccFingerprint` itself is not exported.
  ##
  ## THE ONE memoised probe. `cachedCcVersion` below is a thin projection of
  ## this cache (`$` is pure and cheap), not a second probe -- there is still
  ## exactly one real `ccFingerprint()` call per process, preserving the
  ## measured cost profile (193-242 ms Windows / 9 ms Linux, once) and the
  ## determinism `test_rfc9_a5c_cache_portability.nim` relies on (a whole test
  ## run happens in one process, so both call sites -- `crisol.nim` and
  ## `api.nim` -- see the identical value).
  if not ccFingerprintCached:
    ccFingerprintVal = ccFingerprint()
    ccFingerprintCached = true
  ccFingerprintVal

proc cachedCcVersion*(): string =
  ## `$cachedCcFingerprint()` -- see that proc's doc. Kept as its own accessor
  ## for callers that want the legacy string form directly: `crisol.nim`'s
  ## `clean` handler (its only production caller) and several integration
  ## tests. `api.nim` does not call it -- it derives its `ccVer` as `$ccFp`
  ## from the injected `ccProbe` seam, whose default is `cachedCcFingerprint`.
  $cachedCcFingerprint()
