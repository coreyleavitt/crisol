## toolrun.nim -- the process-execution seam for short-lived HOST TOOL probes
## (RFC-0004, CR7 extraction).
##
## Split out of `ccprobe.nim` (CR7 code review, 2026-09-21), which used to
## carry two unrelated "cc" concerns (toolchain-identity fingerprinting and
## dependency-header probing) plus this seam, all under one file that shared
## nothing but the word "cc". This module is the THIRD piece: "run a
## short-lived tool and capture its output" is not itself a cc-identity or a
## cc-dependency concern -- it is the shape any host-tool probe needs, and
## `crisol/nimprobe` (the Nim BINARY's own identity probe) already reused it
## verbatim before this split, importing the whole of `ccprobe.nim` just to
## get `RunProc`/`realRun`. That was the tell: the seam was never "cc"'s to
## own, it was hosted there by accident of file history.
##
## **Decision (CR7): a third module, not folded into either half.** The
## alternative -- leaving this seam inside the dependency-probing half of the
## old `ccprobe.nim` and having `ccidentity.nim` import that module for it --
## was rejected because the dependency-probing module (`ccprobe.nim`, post-
## split) is otherwise a PURE, I/O-free module: none of `shellSplit`,
## `deriveDepInvocation`, `parseCcMDeps`, `parseMsvcSourceDeps`, or
## `depIncludeHeaders` spawns anything themselves -- they transform strings a
## CALLER already captured via this seam. Making that module import a process-
## execution primitive it never calls, purely so a third module could get it
## by reaching through, would be exactly the kind of "shares nothing but a
## name" coupling CR7 exists to remove. A caller that only needs to run a tool
## now says so directly by importing `crisol/toolrun`, instead of importing a
## C-toolchain-flavoured module for an unrelated reason. (Round-4 review, R4-7,
## 2026-09-24: this sentence used to name three such callers, which is the very
## census R3-10 reports having deleted twelve lines below — and the count was
## still wrong, at three of the six real importers. The point was never who the
## callers are, it is that each of them can state its own need; the criterion
## below and `grep` answer the rest.)
##
## WHAT BELONGS HERE (the criterion, not a roll-call of importers). Import this
## module if you spawn a SHORT-LIVED HOST TOOL and need its output: a compiler
## driver's version banner, `ldd`, the MSVC `vccexe ... /link /VERBOSE:LIB`
## probe, a replayed `cc -M` / `/sourceDependencies-` invocation, the Nim
## compiler's own `--version`. Import NOTHING here if you spawn a compile or run
## CHILD — those belong to RFC-0007's Supervisor (`crisol/process`), and the
## `# process-contract-exempt` marker below draws exactly that line.
##
## Deliberately no list of current importers: this doc carried one, it was wrong
## about two modules within a single review cycle (round-3 review, R3-10 — it
## named `crisol/ccprobe`, which imports nothing from here since CR7 left it
## I/O-free, and undercounted at "three" when there are six), and `grep -l
## "crisol/toolrun" src/` answers the question correctly and forever. A criterion
## a future contributor can apply is worth more than a census that rots.
##
## A std-only leaf on purpose, same shape `ccprobe.nim` documented before this
## split: `crisol/toolexec` (the only crisol import below) is itself a
## std-only leaf (`std/[monotimes, os, osproc, streams, times]` alone, no
## crisol import), so this module's own crisol-dependency graph terminates
## immediately. `crisol/ccidentity`, `crisol/ccprobe` and `crisol/closure` can
## all import this module directly with no risk of closing a cycle back
## toward `crisol/depgraph`/`crisol/artifactid`.
##
## Seam contract
## -------------
## The `run` proc has signature:
##   proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
## where:
##   - `output` is the command's stdout; `realRunMerged` additionally folds
##     in its stderr, which a version banner may be written to instead.
##   - `ok` is true when the command exited with code 0.
##   - On failure (command not found, non-zero exit, etc.): `ok = false`,
##     `output` may be empty or partial -- callers must handle both gracefully.
##   - The real implementations (`runViaOsproc` and its wrappers) return
##     `output = ""` on every path that did not run the command to an exit:
##     spawn failure (not on PATH), an OSError, a CR4 timeout. So non-empty
##     output with `ok = false` means the command RAN and exited non-zero.
##     `ccidentity.presentButFailed` relies on this to tell a present driver
##     that failed from an absent one (R7-S1, round-7 review); it is pinned
##     against the real primitive by
##     `tests/integration/test_r7_probe_presence_contract.nim`. A future
##     change that makes a spawn failure return text breaks that.
## The seam never raises; all errors are surfaced via the `ok` flag.
##
## `RunProc`'s shape is fixed at exactly `tuple[output, ok]` -- never widened
## (destructured by every caller: the `cc -M`/`sourceDependencies` probes in
## `closure`/`artifactid`, and `nimprobe`'s `nim --version` probe). A non-merged real run
## (`realRun`/`realRunIn`) additionally keeps the child's STDERR in a side
## channel a caller can read right after the call: `lastProbeStderr()`
## (W9a) -- this is how a dependency-probe failure (or a probe that exits 0
## with no usable document) can still surface the tool's own diagnostic
## without widening the seam every existing caller relies on.
##
## Public API
## ----------
##   RunProc*
##     The seam type itself: `proc(cmd: string, args: openArray[string]):
##     tuple[output: string, ok: bool]`. Every probe in the tree takes one of
##     these rather than calling a process primitive directly, which is what
##     makes them testable without a subprocess. Listed here because it is
##     exported and is the type callers actually name in their own signatures
##     (R3-10: it was missing from this list).
##
##   ToolProbeTimeoutMs*
##     The deadline every probe through this module is bounded by (CR4). Also
##     previously absent from this list (R3-10).
##
##   realRun*(cmd, args): tuple[output: string, ok: bool]
##     Default seam: executes the command via osproc and returns its output.
##     Never raises.
##
##   realRunMerged*(cmd, args): tuple[output: string, ok: bool]
##     A `RunProc` for VERSION-BANNER probes: the child's stderr is merged
##     into its stdout rather than drained and dropped, because which stream
##     a compiler's banner lands on is not a fixed contract (`cl`/`vccexe`
##     write theirs to stderr; gcc/clang write theirs to stdout).
##
##   realRunIn*(workingDir): RunProc
##     Returns a `RunProc` that always executes its command with `workingDir`
##     as the SUBPROCESS's cwd, regardless of the calling process's own.
##
##   lastProbeStderr*(): string
##     W9a: the STDERR captured by the most recent NON-MERGED `RunProc` call
##     (`realRun`/`realRunIn`) made through this module. `""` after a merged
##     call (`realRunMerged`) or one with no stderr.
##
##   runViaOsproc*(cmd, args, workingDir, mergeStderr = false): tuple[output, ok]
##     The primitive `realRun`/`realRunMerged`/`realRunIn` are all thin
##     bindings of. Exported (not merely internal) because
##     `ccidentity.realLinkVerbose` needs the one combination none of the
##     three named wrappers expose -- a caller-chosen `workingDir` (its own
##     randomized scratch directory) together with `mergeStderr = true`
##     (a Microsoft tool's banner has no fixed stream, same reason
##     `realRunMerged` merges). Adding a fourth named wrapper for one caller
##     would be more surface for the same behaviour this already provides
##     directly.
##
## Caching
## -------
## None. Every proc here is a plain, seam-injectable primitive; each memoised
## probe in the codebase (e.g. `ccidentity.cachedCcFingerprint`,
## `nimprobe.cachedNimFingerprint`, `caps.cachedCapabilities`) lives in the
## module that owns the value being cached, not here.

import std/osproc  # process-contract-exempt: this module IS the process-execution seam for short-lived TOOL invocations (cc/ldd/nim/cc -M probes), not the compile/run children RFC-0007's Supervisor governs (RFC-0007 §Scope)
import crisol/toolexec  # drainBoth/drainToEof -- the capture primitives (issue #22); deadline variants -- CR4

const
  ToolProbeTimeoutMs* = 10_000
    ## CR4: bound on ONE subprocess spawned by `runViaOsproc` (one compiler
    ## driver's version probe, `ldd`, `cc -print-file-name=`, the MSVC
    ## `vccexe ... /link /VERBOSE:LIB` probe, or a `cc -M`/
    ## `/sourceDependencies-` replay) -- every caller of this seam runs
    ## entirely in the host process during plan-building, outside RFC-0007's
    ## Supervisor and its `compileTimeoutMs`/tree-kill, so nothing else
    ## bounds it.
    ##
    ## Sized against the only real measurement on record
    ## (docs/handoff/msvc-selection-layer.md, "Probe cost, measured"): the
    ## WHOLE `cachedCcVersion()` -- up to five candidate driver spawns, the
    ## vccexe compile-and-link probe, and six file hashes together -- costs
    ## 193-242 ms end to end on the slowest host measured (Windows/MSVC), 9 ms
    ## on Linux, and 0 us on every call after the first (memoised). 10 s is
    ## over 40x that WHOLE chained cost for a SINGLE spawn within it, so a
    ## legitimately slow-but-working probe is never at risk; a wedged driver
    ## (the defect this constant exists to bound -- e.g. a `cc` shim blocked on
    ## a broken installer prompt) is bounded to single-digit seconds instead
    ## of hanging the invocation forever. Applied unconditionally: these
    ## probes have no existing user-facing timeout surface, and adding one is
    ## out of scope for this fix.

# ---------------------------------------------------------------------------
# Seam type
# ---------------------------------------------------------------------------

type
  RunProc* = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
    ## Run `cmd` with `args` and return its captured output and whether it
    ## exited 0. Never raises.
    ##
    ## CONTRACT (R7-S1; stated here by R8-D10, round-8 review, as well as in
    ## the module doc): `output` is `""` on every path that did not run the
    ## command to an exit -- spawn failure (not on PATH), an OSError, a CR4
    ## timeout. So non-empty output with `ok = false` means the command RAN
    ## and exited non-zero. Only that direction is guaranteed: a command that
    ## ran, failed and printed nothing also returns `("", false)`.
    ## `ccidentity.ccIdentity` relies on it to tell a present, failing driver
    ## from an absent one, so an implementation -- including a test fake --
    ## must not return text for a command that never ran (a shell's `command
    ## not found`, say). The real implementations (`runViaOsproc` and its
    ## wrappers) hold it, pinned by
    ## `tests/integration/test_r7_probe_presence_contract.nim`.

# ---------------------------------------------------------------------------
# realRun / realRunIn / realRunMerged -- default seam (wraps osproc)
# ---------------------------------------------------------------------------

var lastCapturedStderrVal: string = ""
  ## W9a side channel: the STDERR of the most recent NON-MERGED
  ## `runViaOsproc` call (`realRun`/`realRunIn`; never `realRunMerged`, whose
  ## whole point is that there is no separate stream to carry here).
  ##
  ## Exists because `RunProc`'s `tuple[output, ok]` shape is load-bearing --
  ## destructured by every caller (the `cc -M`/`sourceDependencies` probes in
  ## `closure`/`artifactid`, `nimprobe`'s `nim --version`) and explicitly not
  ## to be widened (see
  ## `runViaOsproc`'s own doc, and `realRunMerged`'s, on why a second
  ## implementation was chosen over a third tuple field last time this
  ## exact question came up). A dependency probe can exit 0 with NO usable
  ## document (an old `cl` answers `/sourceDependencies` with a bare banner
  ## on stdout and `cl : Command line warning D9002 : ignoring unknown
  ## option` on stderr) -- `ok` is true, so there is no "failure path" for a
  ## richer return value to ride on either. The driver's own stderr is the
  ## ONLY signal that explains a `dpeNoJson`/etc. beyond "no document", and
  ## draining it was already mandatory (issue #22) -- this just stops
  ## throwing the drained bytes away.
  ##
  ## Reset at the top of every `runViaOsproc` call (merged or not) so a
  ## caller always reads either the immediately preceding call's own stderr
  ## or nothing -- never a stale value left over from an EARLIER, unrelated
  ## probe. Module-global rather than per-call because it sits behind the
  ## fixed `RunProc` signature; safe under this module's stated model (all
  ## probes run serially in the host process during plan-building -- module
  ## doc, `ToolProbeTimeoutMs` -- never from `measureworker`'s re-exec'd
  ## child, which imports neither this module nor calls a probe concurrently
  ## with another).

proc lastProbeStderr*(): string =
  ## Accessor for `lastCapturedStderrVal` (W9a): the STDERR captured by the
  ## most recent NON-MERGED `RunProc` call (`realRun`/`realRunIn`) made
  ## through this module. `""` if the last such call merged streams
  ## (`realRunMerged`), timed out before capturing anything, or produced no
  ## stderr at all. A caller whose `RunProc` failed, or whose probe ran but
  ## produced no usable document, calls this IMMEDIATELY after the `run(...)`
  ## call it wants the diagnostic for -- see `closure.extractCompileInputs`'s
  ## header-probe error paths.
  lastCapturedStderrVal

proc runViaOsproc*(cmd: string; args: openArray[string]; workingDir: string;
                   mergeStderr: bool = false):
                   tuple[output: string, ok: bool] =
  ## Shared body for `realRun`/`realRunIn`/`realRunMerged`, and (directly,
  ## for the one combination those named wrappers do not cover)
  ## `ccidentity.realLinkVerbose` -- an explicit argv array, no shell
  ## interpretation. Uses startProcess with poUsePath so bare command
  ## names (e.g. "cc", "ldd") resolve via PATH. poEvalCommand is
  ## intentionally NOT used (that is the shell path). Captures stdout; on a
  ## non-merged run the child's stderr is DRAINED and, since W9a, kept --
  ## not in the returned tuple (see `lastCapturedStderrVal`'s doc for why),
  ## but in the `lastProbeStderr()` side channel. Draining it was never
  ## optional even when the bytes were unwanted, because an undrained stderr
  ## pipe wedges any tool that fills it (issue #22; see
  ## `toolexec.drainBoth`). Never raises; failure (command not found,
  ## non-zero exit, OSError) surfaces as ok=false. `workingDir = ""` means
  ## "inherit the calling process's cwd" (osproc's own default).
  ##
  ## `mergeStderr` routes the child's stderr into the SAME pipe as its stdout
  ## (`poStdErrToStdOut`) and returns the combination. That is wrong for a
  ## probe whose output is PARSED -- a `cc -M` reply with a warning spliced
  ## into it is corrupt -- and right for a probe that wants a version banner,
  ## which a compiler may print to either stream: cl prints its banner to
  ## stderr, gcc prints its to stdout. See `realRun` vs `realRunMerged`.
  ##
  ## CR4: bounded by `ToolProbeTimeoutMs` at both the drain and the
  ## `waitForExit` stage -- every caller of this seam runs in the host
  ## process during plan-building, outside the Supervisor's
  ## `compileTimeoutMs`/tree-kill, so nothing else stops a wedged driver from
  ## hanging the whole invocation. On a timeout the child is terminated and
  ## reaped (`toolexec.terminateAndReap` -- never leaked) and this returns
  ## `ok = false`, same as any other probe failure -- but with a
  ## `crisol: warning:` line to stderr naming the timeout specifically, so it
  ## reads differently from "the tool answered nothing" in a log a human is
  ## actually looking at. `RunProc`'s `tuple[output, ok]` shape is unchanged
  ## (see the module doc on why a third state was rejected: `RunProc` is
  ## destructured by every caller across `closure`/`artifactid`/`nimprobe`).
  lastCapturedStderrVal = ""   # W9a: reset on every call -- never a stale echo
  try:
    var argSeq = newSeq[string](args.len)
    for i, a in args: argSeq[i] = a
    var opts = {poUsePath}
    if mergeStderr: opts.incl poStdErrToStdOut
    let p = startProcess(cmd, workingDir = workingDir, args = argSeq,
                         options = opts)
    defer: p.close()   # R2-b: close on every exit path (the drain/waitForExit may raise)
    # One pipe when merged, two when not: `drainBoth` on a merged spawn would
    # wait on an errorHandle osproc never opened.
    var output: string
    var drainTimedOut: bool
    if mergeStderr:
      (output, drainTimedOut) = drainToEofDeadline(p, ToolProbeTimeoutMs)
    else:
      let drained = drainBothDeadline(p, ToolProbeTimeoutMs)
      output = drained.output
      drainTimedOut = drained.timedOut
      lastCapturedStderrVal = drained.errOutput   # W9a: kept even on a timeout below
    if drainTimedOut:
      terminateAndReap(p)
      stderr.write("crisol: warning: `" & cmd & "` did not answer within " &
                   $ToolProbeTimeoutMs & "ms; giving up and treating it as " &
                   "unavailable (CR4 -- see " &
                   "docs/handoff/msvc-selection-layer.md)\n")
      try: stderr.flushFile() except CatchableError: discard
      return (output: "", ok: false)
    let (exitCode, waitTimedOut) = waitForExitDeadline(p, ToolProbeTimeoutMs)
    if waitTimedOut:
      terminateAndReap(p)
      stderr.write("crisol: warning: `" & cmd & "` closed its output but did " &
                   "not exit within " & $ToolProbeTimeoutMs & "ms; giving up " &
                   "and treating it as unavailable (CR4 -- see " &
                   "docs/handoff/msvc-selection-layer.md)\n")
      try: stderr.flushFile() except CatchableError: discard
      return (output: "", ok: false)
    result = (output: output, ok: exitCode == 0)
  except CatchableError:
    result = (output: "", ok: false)

proc realRun*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
  ## Execute `cmd` with `args`, inheriting the calling process's cwd. See
  ## `runViaOsproc` for the shared contract.
  runViaOsproc(cmd, args, "")

proc realRunMerged*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
  ## A `RunProc` for VERSION-BANNER probes: identical to `realRun` except that
  ## the child's stderr is merged into its stdout rather than drained and
  ## dropped.
  ##
  ## This is a second IMPLEMENTATION of `RunProc`, deliberately not a widening
  ## of the type. `RunProc` is re-exported by `artifactid`/`closure`/`nimprobe`
  ## and destructured by every caller; threading a second stream through
  ## all of them to serve one caller would be churn for no gain, and every
  ## existing injected fake keeps compiling unchanged.
  ##
  ## Needed because a compiler's banner has no fixed stream: `cl` and `vccexe`
  ## print theirs to STDERR (measured -- cl with no arguments and an empty
  ## `CL` exits 0, writes `usage: cl [ option... ]` to stdout and its version
  ## banner to stderr; with a non-empty `CL` it exits 2 -- R7-S1),
  ## while gcc/clang print theirs to stdout. A stdout-only probe sees the
  ## usage line and no version at all.
  runViaOsproc(cmd, args, "", mergeStderr = true)

proc realRunIn*(workingDir: string): RunProc =
  ## Returns a `RunProc` that always executes its command with `workingDir`
  ## as the SUBPROCESS's cwd -- never the calling process's own, whatever
  ## that happens to be. `closure.extractCompileInputs` uses this (bound to
  ## `config.projectRoot`) to replay a `cc -M` probe from the SAME
  ## directory the real compile (rfc-0007 A2c, issue #17) ran `cc` from, so
  ## a relative header the manifest's `ccCmd` names resolves identically
  ## regardless of the crisol process's own cwd.
  proc run(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    runViaOsproc(cmd, args, workingDir)
  run
