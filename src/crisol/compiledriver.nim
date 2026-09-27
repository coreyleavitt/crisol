## compiledriver.nim — RFC-0006 M-driver: split-compile MEASUREMENT driver.
##
## crisol compiles each entrypoint as one opaque `nim c ... -o:<bin> <ep>`
## (runner.nim's `spawnCompileStable` builds it via `nimCompileArgs`, from
## `crisol/nimargv` and re-exported here,
## and hands it to the Supervisor as the slot's compile child).
## That hides the codegen/cc/link cost split RFC-0006's Stage M needs to
## report `cc%` and per-unit cc wall-time (the inputs to the whole
## Stage R/S decision gate — see docs/rfc/0006). This module drives ONE
## entrypoint's compile as three OBSERVABLE phases instead:
##
##   1. `nim c --compileOnly <ep>`      — codegen only: emits `.c` files +
##                                        `<nimcache>/<bin>.json` (no cc, no link).
##   2. replay each `(cFile, ccCmd)` from the manifest, reproducing Nim's own
##      `execCmdsInParallel` concurrency (§Concurrency below) — so the
##      measured cc-phase wall-time matches a real `nim c`, not summed CPU time.
##   3. run the manifest's `linkcmd`.
##
## It records OVERLAP-AWARE spans (codegen, cc-as-real-wall-clock-of-the-
## parallel-phase, link) plus PER-UNIT cc wall-time. `newMeasureDriver`
## (measure mode) does NO caching. It is MEASUREMENT-GATED: the default
## production compile path (runner.nim's spawnCompileStable) stays the
## monolithic `nim c` unless measurement is explicitly opted into.
##
## (RFC-0006 Stage R — a content-keyed cross-entrypoint object cache built
## on top of this same driver seam — was implemented, measured end-to-end
## against a real consumer, and subsequently REMOVED: an A/B showed the
## cache didn't pay off there (codegen-bound, not cc-bound; cold runs were
## slower). This module now serves the measurement path only.)
##
## ## The CompileDriver seam
##
## Every effectful step is an injectable proc field, mirroring toolrun.nim's
## `RunProc` idiom: the seam never raises, and the two captured steps return
## `toolexec.RunResult` (the cc phase, whose output goes to the terminal,
## reports per-unit `ok` flags); tests inject synthetic procs so the span-accounting/orchestration logic
## in `runMeasured` is exercised without a slow real `nim c` invocation.
## `newMeasureDriver` builds the real MEASURE-mode seam.
##
## ## Concurrency (matching Nim's own compiler — verified against vendored
## source, Nim 2.2.10)
##
## `compiler/extccomp.nim:877 execCmdsInParallel` calls `std/osproc.
## execProcesses` (`lib/pure/osproc.nim:341`) with `n = conf.numberOfProcessors`,
## which defaults (when unset — the common case, no `--parallelBuild`) to
## `countProcessors()` (`extccomp.nim:883`). `defaultRunCc` below calls that
## SAME `std/osproc.execProcesses` primitive — not a reimplementation — so the
## measured overlap is Nim's actual scheduling: a sliding window of at most
## `concurrency` processes, reaped via `waitpid(-1, ...)` as any one exits and
## immediately replaced by the next pending command (`osproc.nim:398-437`),
## never a fixed batch-of-N. `execProcesses` also runs each command through
## the shell (`poEvalCommand`) — matching Nim's own cc-command invocation,
## which is why replaying the manifest's cc strings this way is a faithful
## reproduction, not a soundness-relevant shell-injection surface (the manifest
## is crisol's own trusted `nim c` output, not external input).
##
## ## Error handling
##
## `runMeasured` aborts on the first phase that fails (non-zero compileOnly,
## any cc unit, or link) and returns `CompileSpans(ok: false, errorMsg: ...)`.
## It never fabricates a span for a phase that did not complete; spans for
## phases that DID complete before the failure are preserved (e.g. a link
## failure still reports real codegen/cc spans).

import std/[monotimes, os, osproc, sequtils, tables, times]  # process-contract-exempt: measure-mode realCompileOnly/cc/link, aligned at A2c — not the entrypoint compile/run children (RFC-0007 §Scope)
import crisol/toolexec  # runTool and its RunResult -- spawn and capture (issue #22)
export RunEnd, RunResult, ran, notRun, ok, describe
import crisol/closure
import crisol/nimargv  # nimCompileArgs -- the one `nim c` argv builder, shared with ccidentity
export nimargv

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  CompileOnlyProc* = proc(entrypoint: string; flags: seq[string];
                          nimcacheDir, outputBinPath: string):
                            RunResult {.closure.}
    ## Runs codegen only. Real impl (`realCompileOnly`): argv-array spawn, no
    ## shell — the same `nimCompileArgs` argv runner.nim's
    ## `spawnCompileStable` uses for the real compile, plus `--compileOnly`.

  CompileUnit* = tuple[basename: string; ccCmd: string]
    ## One entry from the manifest's raw `compile` array (see
    ## `closure.parseCompileManifest`): the generated `.c`'s basename (e.g.
    ## "@mpass_always.nim.c") + its full cc command string.

  CcUnitResult* = object
    basename*:  string
    ok*:        bool
    ccTimeUs*:  int64        ## wall time for this single unit, monotonic clock

  RunCcResult* = object
    ok*:        bool         ## true iff every unit exited 0
    units*:     seq[CcUnitResult]
    ccSpanUs*:  int64        ## overlap-aware wall time of the WHOLE cc phase
                              ## (max end - min start across all units) — NOT
                              ## the sum of per-unit ccTimeUs.

  RunCcProc* = proc(units: seq[CompileUnit]): RunCcResult {.closure.}
    ## Runs every unit's cc command. Real measure-mode impl (`defaultRunCc`,
    ## below): never caches.

  LinkProc* = proc(linkCmd: string): RunResult {.closure.}
    ## Runs the manifest's `linkcmd`. Real impl (`realLink`): shell-evaluates
    ## the string (matches Nim's own `execLinkCmd`, which also shell-invokes it).

  CompileDriver* = object
    ## Closure-field seam object (crisol idiom — mirrors toolrun.RunProc).
    ## `newMeasureDriver` builds the real measure-mode implementation.
    compileOnly*: CompileOnlyProc
    runCc*:       RunCcProc
    link*:        LinkProc

  CompileSpans* = object
    ## Result of one `runMeasured` call.
    ok*:            bool
    errorMsg*:       string     ## meaningful only when ok == false
    codegenSpanUs*:  int64
    ccSpanUs*:       int64
    linkSpanUs*:     int64
    ccUnitTimesUs*:  Table[string, int64]   ## basename -> ccTimeUs

# ---------------------------------------------------------------------------
# Real (measure-mode) seam implementations
# ---------------------------------------------------------------------------

proc runCompileOnly(entrypoint: string; flags: seq[string];
                    nimcacheDir, outputBinPath, workingDir: string): RunResult =
  ## Shared body for `realCompileOnly`/`realCompileOnlyIn`. Spawns
  ## `nim <nimCompileArgs(..., compileOnly = true)>` via an argv array (no
  ## shell), with `workingDir` as the subprocess's cwd (`"" ` = inherit the
  ## calling process's own cwd, osproc's own default), stdout and stderr
  ## merged. Never raises.
  let args = nimCompileArgs(entrypoint, flags, nimcacheDir, outputBinPath,
                            compileOnly = true)
  runTool("nim", args, workingDir, {poUsePath, poStdErrToStdOut}, "",
          NoDeadline, MaxToolOutputBytes)

proc realCompileOnly*(entrypoint: string; flags: seq[string];
                      nimcacheDir, outputBinPath: string): RunResult =
  ## Spawns `nim <nimCompileArgs(..., compileOnly = true)>`, inheriting the
  ## calling process's own cwd. See `runCompileOnly` for the shared contract.
  runCompileOnly(entrypoint, flags, nimcacheDir, outputBinPath, "")

proc realCompileOnlyIn*(workingDir: string): CompileOnlyProc =
  ## Returns a `CompileOnlyProc` that always spawns `nim --compileOnly` with
  ## `workingDir` as the subprocess's cwd — never the calling process's own,
  ## whatever that happens to be. rfc-0007 A2c (issue #17): a root-relative
  ## compile flag (e.g. `--path:src`) is resolved by `nim` against ITS OWN
  ## cwd, so this is `realCompileOnly`'s counterpart to `runner.nim`'s
  ## ChildSpec.cwd fix — a SEPARATE substrate (raw `osproc.startProcess`,
  ## not a `Supervisor`-spawned `ChildSpec`) that must independently pin
  ## `workingDir = projectRoot`, since this driver can also run entirely
  ## in-process (`runMeasured` called directly, as
  ## `test_compiledriver_real.nim` does) with no chdir happening anywhere
  ## in its call chain.
  proc compileOnly(entrypoint: string; flags: seq[string];
                   nimcacheDir, outputBinPath: string): RunResult =
    runCompileOnly(entrypoint, flags, nimcacheDir, outputBinPath, workingDir)
  compileOnly

proc defaultRunCc*(units: seq[CompileUnit];
                   concurrency: int = countProcessors()): RunCcResult =
  ## Real cc-phase execution. Calls `std/osproc.execProcesses` directly — the
  ## exact primitive Nim's own `execCmdsInParallel` calls (see module doc
  ## §Concurrency) — so the sliding-window scheduling matches Nim's, not an
  ## approximation of it. Records, via `std/monotimes`, each unit's own
  ## [start, end) and derives:
  ##   - `ccTimeUs` per unit (end - start for that unit alone)
  ##   - `ccSpanUs` for the whole phase (max end - min start across ALL units
  ##     — overlap-aware: N fully-parallel units of duration D span ≈ D, not
  ##     N*D)
  ## Never raises; a spawn/exit failure is reflected in `ok`/`units[i].ok`.
  if units.len == 0:
    return RunCcResult(ok: true, units: @[], ccSpanUs: 0)

  var starts = newSeq[MonoTime](units.len)
  var ends   = newSeq[MonoTime](units.len)
  var oks    = newSeq[bool](units.len)
  let cmds   = units.mapIt(it.ccCmd)

  let before = proc(idx: int) =
    starts[idx] = getMonoTime()
  let after = proc(idx: int, p: Process) =
    ends[idx] = getMonoTime()
    oks[idx] = p.peekExitCode() == 0

  let n = max(1, concurrency)
  # poParentStreams is the correct choice here, not poStdErrToStdOut: this
  # phase exists to be a faithful reproduction of Nim's own cc phase (see
  # module doc §Concurrency) — real `nim c` lets each cc invocation's
  # stdout/stderr go straight to the terminal the compiler itself was run
  # from, interleaved live across the concurrency window, which is exactly
  # what a human watching a slow parallel compile wants to see. Neither
  # `CcUnitResult` nor `RunCcResult` carries an `output` field (unlike
  # `compileOnly`/`link` above, whose output IS captured because callers
  # inspect it on failure) — nothing here reads cc output, so there is
  # nothing to merge into anything.
  # osproc silently ignores `poStdErrToStdOut` once `poParentStreams` is
  # set (with parent streams the child writes straight to the parent's
  # OS-level handles; there is no pipe for osproc to merge stderr into) —
  # so keeping that flag here just asserted an intent this call never
  # delivered. Dropped rather than acted on: capturing/merging would mean
  # buffering N processes' interleaved output only to discard it, and it
  # would take live cc progress away from the terminal, which is the
  # observable behavior this driver is explicitly designed to preserve.
  discard execProcesses(cmds, {poUsePath, poParentStreams}, n, before, after)

  result.units = newSeq[CcUnitResult](units.len)
  var allOk     = true
  var spanStart = starts[0]
  var spanEnd   = ends[0]
  for i in 0 ..< units.len:
    let dur = (ends[i] - starts[i]).inMicroseconds
    result.units[i] = CcUnitResult(basename: units[i].basename, ok: oks[i], ccTimeUs: dur)
    if not oks[i]: allOk = false
    if starts[i] < spanStart: spanStart = starts[i]
    if ends[i]   > spanEnd:   spanEnd   = ends[i]
  result.ok = allOk
  result.ccSpanUs = (spanEnd - spanStart).inMicroseconds

proc realLink*(linkCmd: string): RunResult =
  ## Shell-evaluates the manifest's `linkcmd` string (matches Nim's own
  ## `execLinkCmd` -> `execExternalProgram`, which also shell-invokes it),
  ## stdout and stderr merged. Never raises.
  runTool(linkCmd, [], "", {poEvalCommand, poStdErrToStdOut, poUsePath}, "",
          NoDeadline, MaxToolOutputBytes)

proc failureText(r: RunResult): string =
  ## What a failed captured step says: the tool's own output when it ran to
  ## an exit, otherwise why there is none.
  case r.ending
  of reExited: r.output
  of reNotStarted, reTimedOut, reIoError, reOverflow, reInterrupted: describe(r)

proc newMeasureDriver*(concurrency: int = countProcessors();
                       workingDir: string = ""): CompileDriver =
  ## The measure-mode `CompileDriver`: real compileOnly/cc/link, no caching.
  ## `workingDir` (rfc-0007 A2c, issue #17) is the cwd `nim --compileOnly`
  ## spawns with — "" inherits the calling process's own cwd (this driver's
  ## pre-A2c behavior); production callers (`measureworker.
  ## runMeasureCompileWorker`) pass `plan.projectRoot` so a root-relative
  ## compile flag resolves identically regardless of where crisol itself
  ## was invoked from. The cc/link phases need no equivalent: both replay
  ## commands the manifest `compileOnly` just wrote, which already carry
  ## whatever paths that (correctly cwd'd) compileOnly step resolved.
  CompileDriver(
    compileOnly: realCompileOnlyIn(workingDir),
    runCc: proc(units: seq[CompileUnit]): RunCcResult = defaultRunCc(units, concurrency),
    link: realLink,
  )

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

proc runMeasured*(driver: CompileDriver; entrypoint: string; flags: seq[string];
                  nimcacheDir, outputBinPath: string): CompileSpans =
  ## Drives one entrypoint through compileOnly -> parse manifest -> runCc ->
  ## link, recording overlap-aware spans + per-unit cc wall-time via
  ## `std/monotimes` (never wall/`Date`). Aborts on the first failing phase —
  ## see module doc §Error handling.
  let binName = outputBinPath.extractFilename

  let t0 = getMonoTime()
  let co = driver.compileOnly(entrypoint, flags, nimcacheDir, outputBinPath)
  let t1 = getMonoTime()
  if not co.ok:
    return CompileSpans(ok: false, errorMsg: "compileOnly failed: " & failureText(co))

  let jsonPath = nimcacheDir / binName & ".json"
  let manifest = parseCompileManifest(jsonPath)   # raises CrisolError on bad JSON

  let units = manifest.compile.mapIt(
    (basename: it.cPath.extractFilename, ccCmd: it.ccCmd))
  let ccResult = driver.runCc(units)
  if not ccResult.ok:
    result = CompileSpans(ok: false, errorMsg: "cc phase failed")
    result.codegenSpanUs = (t1 - t0).inMicroseconds
    result.ccSpanUs      = ccResult.ccSpanUs
    for u in ccResult.units: result.ccUnitTimesUs[u.basename] = u.ccTimeUs
    return result

  let t2 = getMonoTime()
  let linked = driver.link(manifest.linkcmd)
  let t3 = getMonoTime()

  result = CompileSpans(ok: linked.ok)
  result.codegenSpanUs = (t1 - t0).inMicroseconds
  result.ccSpanUs      = ccResult.ccSpanUs
  for u in ccResult.units: result.ccUnitTimesUs[u.basename] = u.ccTimeUs
  if not linked.ok:
    result.errorMsg = "link failed: " & failureText(linked)
  else:
    result.linkSpanUs = (t3 - t2).inMicroseconds
