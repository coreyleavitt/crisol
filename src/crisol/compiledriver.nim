## compiledriver.nim — RFC-0006 M-driver: split-compile MEASUREMENT driver.
##
## crisol compiles each entrypoint as one opaque `nim c ... -o:<bin> <ep>`
## (runner.nim:379 builds the nimcache arg, runner.nim:393 forkExec's it).
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
## Every effectful step is an injectable proc field, mirroring ccprobe.nim's
## `RunProc` idiom: the seam never raises, failure surfaces via an `ok` flag,
## and tests inject synthetic procs so the span-accounting/orchestration logic
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

import std/[monotimes, os, osproc, sequtils, streams, tables, times]
import crisol/closure

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  CompileOnlyProc* = proc(entrypoint: string; flags: seq[string];
                          nimcacheDir, outputBinPath: string):
                            tuple[ok: bool; output: string] {.closure.}
    ## Runs codegen only. Real impl (`realCompileOnly`): argv-array spawn, no
    ## shell — mirrors runner.nim's forkExec compile-arg construction
    ## (runner.nim:379-393), plus `--compileOnly`.

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

  LinkProc* = proc(linkCmd: string): tuple[ok: bool; output: string] {.closure.}
    ## Runs the manifest's `linkcmd`. Real impl (`realLink`): shell-evaluates
    ## the string (matches Nim's own `execLinkCmd`, which also shell-invokes it).

  CompileDriver* = object
    ## Closure-field seam object (crisol idiom — mirrors ccprobe.RunProc).
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

proc nimCompileArgs*(entrypoint: string; flags: seq[string];
                     nimcacheDir, outputBinPath: string;
                     compileOnly = false): seq[string] =
  ## Assembles the argv AFTER the `nim` executable for one entrypoint
  ## compile. This is the SINGLE place `nim c` argv is assembled across
  ## BOTH of crisol's compile paths: `runner.nim`'s monolithic production
  ## path (`monolithicCompArgs`) and this module's measure-mode
  ## compile-only path (`realCompileOnly`, below).
  ##
  ## Always injects `-d:nimBetterRun`. That define makes the compiler write
  ## a `depfiles` array into the nimcache manifest
  ## (`<nimcacheDir>/<binaryName>.json`) — `[[absPath, hash], ...]` for
  ## EVERY file `conf.m.fileInfos` records: the main module, every import,
  ## every `include`d file, every `staticRead`/`slurp` target, and
  ## `nim.cfg`/`config.nims` (`compiler/extccomp.nim`
  ## `writeJsonBuildInstructions`, gated on `optRun in conf.globalOptions or
  ## isDefined(conf, "nimBetterRun")`). `closure.extractClosure` unions
  ## `depfiles` into the source closure (issue #11): without this define,
  ## an `include`d file, a `staticRead`/`slurp` input, or a config file is
  ## invisible to crisol — it neither triggers a recompile
  ## (`planner.decideCompile`'s closure content hash only covers closure
  ## files) nor gets selected under `--changed` (`narrow.selectByDiff`
  ## intersects the git diff with the closure).
  ##
  ## The define has one other compiler effect: it also gates Nim's own
  ## "nothing changed, skip the whole compile" short-circuit
  ## (`compiler/main.nim` `commandCompileToC` ->
  ## `changeDetectedViaJsonBuildInstructions`). That short-circuit cannot
  ## fire in crisol's flow regardless of the define: it additionally
  ## requires the `-o:` output binary to still exist at the same path, and
  ## crisol's runner removes any pre-existing `-o:` target immediately
  ## before spawning the compiler (`runner.spawnCompileStable`) and deletes
  ## the per-slot scratch bin dir after copying the produced binary out to
  ## its stable location — so the precondition is false by construction.
  ## This matters: Nim's change detection covers `depfiles` but NOT
  ## `{.compile.}`d C sources, so an accidental short-circuit after a C
  ## edit would serve a stale binary. (`--compileOnly` never produces the
  ## `-o:` target, so the measure path is unaffected either way.)
  ##
  ## Deliberately NOT folded into `Entrypoint.flags`: it is an
  ## implementation-detail define crisol injects on every compile, not a
  ## user- or config-supplied flag, so entrypoint identity
  ## (`planner.slug`/`flagHash`) is unaffected by its presence.
  result = @["c", "--mm:orc", "--hints:off"]
  if compileOnly:
    result.add "--compileOnly"
  result.add "--nimcache:" & nimcacheDir
  result.add "-o:" & outputBinPath
  result.add "-d:nimBetterRun"
  for f in flags:
    result.add f
  result.add entrypoint

proc realCompileOnly*(entrypoint: string; flags: seq[string];
                      nimcacheDir, outputBinPath: string):
                        tuple[ok: bool; output: string] =
  ## Spawns `nim <nimCompileArgs(..., compileOnly = true)>` via an argv
  ## array (no shell). Never raises; failure surfaces as `ok = false`.
  let args = nimCompileArgs(entrypoint, flags, nimcacheDir, outputBinPath,
                            compileOnly = true)
  try:
    let p = startProcess("nim", args = args, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (ok: exitCode == 0, output: output)
  except CatchableError as e:
    result = (ok: false, output: "nim --compileOnly spawn failed: " & e.msg)

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
  discard execProcesses(cmds, {poStdErrToStdOut, poUsePath, poParentStreams},
                        n, before, after)

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

proc realLink*(linkCmd: string): tuple[ok: bool; output: string] =
  ## Shell-evaluates the manifest's `linkcmd` string (matches Nim's own
  ## `execLinkCmd` -> `execExternalProgram`, which also shell-invokes it).
  ## Never raises; failure surfaces as `ok = false`.
  try:
    let p = startProcess(linkCmd, options = {poEvalCommand, poStdErrToStdOut, poUsePath})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (ok: exitCode == 0, output: output)
  except CatchableError as e:
    result = (ok: false, output: "link spawn failed: " & e.msg)

proc newMeasureDriver*(concurrency: int = countProcessors()): CompileDriver =
  ## The measure-mode `CompileDriver`: real compileOnly/cc/link, no caching.
  CompileDriver(
    compileOnly: realCompileOnly,
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
  let (coOk, coOut) = driver.compileOnly(entrypoint, flags, nimcacheDir, outputBinPath)
  let t1 = getMonoTime()
  if not coOk:
    return CompileSpans(ok: false, errorMsg: "compileOnly failed: " & coOut)

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
  let (linkOk, linkOut) = driver.link(manifest.linkcmd)
  let t3 = getMonoTime()

  result = CompileSpans(ok: linkOk)
  result.codegenSpanUs = (t1 - t0).inMicroseconds
  result.ccSpanUs      = ccResult.ccSpanUs
  for u in ccResult.units: result.ccUnitTimesUs[u.basename] = u.ccTimeUs
  if not linkOk:
    result.errorMsg = "link failed: " & linkOut
  else:
    result.linkSpanUs = (t3 - t2).inMicroseconds
