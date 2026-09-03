## ccprobe.nim — C compiler + libc version probe (RFC-0004, A2-pre).
##
## Effectful I/O, Linux-oriented.  All command execution goes through an
## injectable `run` proc seam so unit tests can supply synthetic output
## without spawning any real process.
##
## Seam contract
## -------------
## The `run` proc has signature:
##   proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
## where:
##   - `output` is the combined stdout of the command (stderr is not captured).
##   - `ok` is true when the command exited with code 0.
##   - On failure (command not found, non-zero exit, etc.): `ok = false`,
##     `output` may be empty or partial — callers must handle both gracefully.
## The seam never raises; all errors are surfaced via the `ok` flag.
##
## Public API
## ----------
##   ccVersion*(run = realRun): string
##     Returns a stable, normalized fingerprint combining:
##       - first line of `cc --version` output (C compiler identity)
##       - first line of `ldd --version` output (libc identity)
##     Joined with "|" as a fixed separator.  Each half is trimmed.
##     If a probe command fails or produces empty output the corresponding
##     half is replaced by a documented sentinel so the fingerprint is always
##     a stable non-empty string.  Never raises.
##
##   realRun*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
##     Default seam: executes the command via osproc and returns its output.
##     Never raises.
##
## Sentinel values (exported for consumer awareness):
##   CcSentinel*  = "<cc-unavailable>"
##   LddSentinel* = "<ldd-unavailable>"
##
## Caching
## -------
## The pure derivation (`ccVersion`) is seam-injectable and can be called freely
## in tests.  The memoised accessor (`cachedCcVersion`) is a thin wrapper that
## calls the real probe exactly once at startup; tests bypass it entirely.
##
## ## `cc -M` invocation derivation (`shellSplit`/`deriveCcMInvocation`/
## `parseCcMDeps`/`ccIncludeHeaders`)
##
## These four procs originated in `artifactid.nim` (RFC-0006) and were moved
## here (issue #16) so `crisol/closure`'s `extractCompileInputs` could reuse
## them without reimplementing `cc -M` parsing. They are dependency-free
## (no `fnv1a64`/hashing, unlike `artifactid.includeClosureContentHash`/
## `artifactKeyHash`, which stay in `artifactid.nim` since those need
## `crisol/depgraph`'s hash primitives) — moving only these four keeps this
## module a true leaf (std-only imports) that both `crisol/closure` and
## `crisol/artifactid` can depend on without a cycle: `depgraph.nim` imports
## `closure.nim` (for `extractClosure`/`SourceIndex`), and `artifactid.nim`
## imports `depgraph.nim` (for `fnv1a64`/`toHex16`) — so `closure.nim`
## importing `artifactid.nim` directly would close a cycle
## (closure -> artifactid -> depgraph -> closure). `artifactid.nim`
## re-exports all four (`export ccprobe.shellSplit`, etc.) so every existing
## caller that does `import crisol/artifactid` and calls them unqualified
## keeps compiling unchanged.

import std/[osproc, streams, strutils]  # process-contract-exempt: cc/nim probes are short-lived tool invocations, not compile/run children (RFC-0007 §Scope)

# ---------------------------------------------------------------------------
# Sentinels
# ---------------------------------------------------------------------------

const
  CcSentinel*  = "<cc-unavailable>"
  LddSentinel* = "<ldd-unavailable>"

# ---------------------------------------------------------------------------
# Seam type
# ---------------------------------------------------------------------------

type
  RunProc* = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]

# ---------------------------------------------------------------------------
# realRun / realRunIn — default seam (wraps osproc)
# ---------------------------------------------------------------------------

proc runViaOsproc(cmd: string; args: openArray[string]; workingDir: string):
                  tuple[output: string, ok: bool] =
  ## Shared body for `realRun`/`realRunIn` — an explicit argv array, no
  ## shell interpretation. Uses startProcess with poUsePath so bare command
  ## names (e.g. "cc", "ldd") resolve via PATH. poEvalCommand is
  ## intentionally NOT used (that is the shell path). Captures stdout;
  ## stderr is not captured. Never raises; failure (command not found,
  ## non-zero exit, OSError) surfaces as ok=false. `workingDir = ""` means
  ## "inherit the calling process's cwd" (osproc's own default).
  try:
    var argSeq = newSeq[string](args.len)
    for i, a in args: argSeq[i] = a
    let p = startProcess(cmd, workingDir = workingDir, args = argSeq,
                         options = {poUsePath})
    defer: p.close()   # R2-b: close on every exit path (readAll/waitForExit may raise)
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (output: output, ok: exitCode == 0)
  except CatchableError:
    result = (output: "", ok: false)

proc realRun*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
  ## Execute `cmd` with `args`, inheriting the calling process's cwd. See
  ## `runViaOsproc` for the shared contract.
  runViaOsproc(cmd, args, "")

proc realRunIn*(workingDir: string): RunProc =
  ## Returns a `RunProc` that always executes its command with `workingDir`
  ## as the SUBPROCESS's cwd — never the calling process's own, whatever
  ## that happens to be. `closure.extractCompileInputs` uses this (bound to
  ## `config.projectRoot`) to replay a `cc -M` probe from the SAME
  ## directory the real compile (rfc-0007 A2c, issue #17) ran `cc` from, so
  ## a relative header the manifest's `ccCmd` names resolves identically
  ## regardless of the crisol process's own cwd.
  proc run(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    runViaOsproc(cmd, args, workingDir)
  run

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc firstLine(s: string): string =
  ## Return the first non-empty, trimmed line of `s`; empty string if none.
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0:
      return t
  ""

# ---------------------------------------------------------------------------
# ccVersion — pure derivation (injectable)
# ---------------------------------------------------------------------------

proc ccVersion*(run: RunProc = realRun): string =
  ## Derive a stable fingerprint from cc and ldd version probes.
  ## Both probes go through `run`; default is the real process runner.
  ## Never raises.

  # --- cc probe ---
  let (ccOut, ccOk) = run("cc", ["--version"])
  let ccLine = if ccOk: firstLine(ccOut) else: ""
  let ccPart = if ccLine.len > 0: ccLine else: CcSentinel

  # --- ldd probe ---
  let (lddOut, lddOk) = run("ldd", ["--version"])
  let lddLine = if lddOk: firstLine(lddOut) else: ""
  let lddPart = if lddLine.len > 0: lddLine else: LddSentinel

  ccPart & "|" & lddPart

# ---------------------------------------------------------------------------
# cachedCcVersion — memoised startup accessor (uses the real runner)
# ---------------------------------------------------------------------------

var ccVersionCache: string = ""

proc cachedCcVersion*(): string =
  ## Probe cc/ldd exactly once; return the cached value on subsequent calls.
  ## Always uses the real runner — unit tests should call ccVersion directly.
  if ccVersionCache.len == 0:
    ccVersionCache = ccVersion()
  ccVersionCache

# ---------------------------------------------------------------------------
# cc -M invocation derivation (moved from artifactid.nim, issue #16 — see
# module doc above for why this lives here rather than in artifactid.nim)
# ---------------------------------------------------------------------------

proc shellSplit*(s: string): tuple[toks: seq[string]; ok: bool] =
  ## Tokenizes a manifest `ccCmd` string shell-AWARE, for `deriveCcMInvocation`'s
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

proc deriveCcMInvocation*(ccCmd: string):
    tuple[cmd: string; args: seq[string]; sourceFile: string; ok: bool] =
  ## Derive a `cc -M` dependency-generation invocation from one manifest
  ## `ccCmd` string (see `closure.parseCompileManifest`).
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
    return (cmd: "", args: newSeq[string](), sourceFile: "", ok: false)
  let cc = toks[0]
  let sourceFile = toks[^1]
  var kept: seq[string] = @["-M"]
  var idx = 1
  while idx < toks.len - 1:
    let t = toks[idx]
    if t == "-c":
      inc idx   # drop the compile-action flag
      continue
    if t == "-o":
      idx += 2   # drop the flag AND its separated argument
      continue
    if t.startsWith("-o") and t.len > 2:
      inc idx   # drop the fused "-o<obj>" form (no separate argument)
      continue
    kept.add t
    inc idx
  kept.add sourceFile
  result = (cmd: cc, args: kept, sourceFile: sourceFile, ok: true)

proc parseCcMDeps*(ccMOutput: string): seq[string] =
  ## Parse GNU-make-style dependency output (`target: dep1 dep2 \` with
  ## backslash line continuations) into the flat list of dependency tokens,
  ## INCLUDING the source file itself (callers that need it excluded should
  ## filter by the known source path — see `ccIncludeHeaders`).
  let joined = ccMOutput.replace("\\\r\n", " ").replace("\\\n", " ")
  let colonIdx = joined.find(':')
  let depsStr = if colonIdx >= 0: joined[colonIdx + 1 .. ^1] else: joined
  for tok in depsStr.splitWhitespace():
    result.add tok

proc ccIncludeHeaders*(ccMOutput: string; sourceFile: string): seq[string] =
  ## The header set: every dependency `cc -M` reports EXCEPT the compiled
  ## source file itself (excluded by exact match on the known path used to
  ## derive the invocation — never guessed).
  for p in parseCcMDeps(ccMOutput):
    if p.len > 0 and p != sourceFile:
      result.add p
