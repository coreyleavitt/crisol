## test_measure_compile_gate.nim — RFC-0006 M-artifact-identity, PASS (b2):
## integration tests wiring the measurement worker into runner.nim's compile
## slot, gated by Config.measureCompileReuse.
##
## PASS (b1) (tests/integration/test_measureworker_real.nim) already proves
## the worker itself is correct in isolation (real compile, ArtifactRow
## fields, unwritable-stateDir robustness). This file proves the WIRING:
## that spawnCompileStable actually dispatches to the worker when the gate
## is on, and leaves the monolithic `nim c` path untouched when it's off.
##
## ## Why the ON-path tests spawn the REAL `crisol` binary (not a library call)
##
## The RFC's own mechanism (docs/rfc/0006-cross-entrypoint-compile-reuse.md,
## "crisol re-execs ITSELF") has runner.nim forkExec `getAppFilename()` — the
## PATH OF THE CURRENTLY RUNNING PROCESS — as the worker's argv[0]. That is
## only a valid self-reexec when the running process genuinely IS the
## `crisol` CLI binary (whose runMain special-cases InternalMeasureCompileToken
## before normal subcommand dispatch — crisol.nim:247). Verified empirically:
## invoking runner.execute() from an ordinary `nim r`-compiled unittest
## binary makes `getAppFilename()` point at THAT TEST BINARY, so the
## "worker" child re-runs the whole unittest suite (ignoring the
## `--internal-measure-compile` argv it doesn't parse) instead of dispatching
## to `runMeasureCompileWorker` — an unbounded self-recursive spawn that
## exhausts the compile-phase watchdog (SIGKILL) rather than compiling
## anything. So: OFF-path testing (behavior 1) stays a plain library call
## (it never spawns a worker at all — no self-reexec assumption in play).
## ON-path testing (behaviors 3-4) instead shells out to the REAL compiled
## `crisol` binary and drives it through its actual CLI surface, exactly
## matching the one host process for which the RFC's mechanism is sound.
##
## NOTE (flagged upstream, not fixed here — outside this pass's scope): this
## same self-reexec assumption means `measureCompileReuse` is NOT currently
## safe for a consumer that embeds crisol purely as a LIBRARY (calls
## api.runTests() in-process without a separate `crisol` subprocess in the
## loop, e.g. amoxtli per CLAUDE.md) — that host process's own
## `getAppFilename()` would point at ITS binary, not crisol's, and the same
## runaway-recursion failure mode would occur in production. RunOptions.
## measureCompileReuse is wired through per this pass's spec either way; the
## gap is a genuine RFC-level mechanism question (e.g. an explicit,
## injectable worker-binary path defaulting to today's getAppFilename()
## behavior) left for the RFC owner to resolve, not silently patched here.
##
## Uses the pass_always.nim fixture (the same fixture test_measureworker_real
## and test_compiledriver_real already pinned at 4 reusable units + 1 entry
## unit under --mm:orc).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_measure_compile_gate.nim

import std/[json, os, osproc, streams, strtabs, strutils, times, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner
import crisol/artifactledger
import crisol/keys
import crisol/jsonout  # RunSchemaRevision
import crisol/ledger

# ---------------------------------------------------------------------------
# Helpers — library-call path (behavior 1, OFF; never spawns a worker)
# ---------------------------------------------------------------------------

proc projectRoot(): string =
  # test is at tests/integration/; go up 3 -> project root (mirrors
  # test_measureworker_real.nim's idiom).
  currentSourcePath().parentDir.parentDir.parentDir

const epRelPath = "tests" / "fixtures" / "pass_always.nim"

proc mkEp(): Entrypoint =
  Entrypoint(path: epRelPath, group: "test", flags: @[])

proc freshStateDir(tag: string): string =
  result = getTempDir() / "crisol_test_measure_gate_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc makeConfig(stateDir: string; measureCompileReuse: bool; workerBinary: string = ""): Config =
  Config(
    projectRoot:         projectRoot(),
    stateDir:            stateDir,
    timeoutSecs:         60,
    compileTimeoutSecs:  300,
    maxOutputBytes:      65_536,
    jobs:                1,
    measureCompileReuse: measureCompileReuse,
    workerBinary:        workerBinary,
  )

# ---------------------------------------------------------------------------
# Helpers — real-binary path (behaviors 3-4, ON; self-reexec must be sound)
# ---------------------------------------------------------------------------

proc buildCrisolBinary(): string =
  ## Compile the REAL src/crisol.nim CLI binary once, into an isolated temp
  ## path, so its own `getAppFilename()` genuinely points at a process that
  ## dispatches `--internal-measure-compile` (crisol.nim:247) — the only
  ## sound host for the gate's self-reexec. `nim` is on PATH inside the
  ## ./dev container this test itself already runs in, so this nested
  ## compile stays within the "build only via ./dev" boundary.
  result = getTempDir() / "crisol_test_measure_gate_bin" / "crisol"
  createDir(result.parentDir)
  let cmd = "nim c --hints:off --warnings:off -d:release --mm:orc -o:" &
            result.quoteShell & " " & (projectRoot() / "src" / "crisol.nim").quoteShell
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "failed to build crisol binary for gate tests: " & output
  doAssert fileExists(result), "crisol binary not produced at " & result

let crisolBin = buildCrisolBinary()

proc runCrisolMeasured(stateDir: string; extraArgs: seq[string] = @[]):
                       tuple[exitCode: int; output: string] =
  ## Invoke the real crisol binary's `run` subcommand against the
  ## pass_always fixture, gated ON, with an isolated state dir (via
  ## CRISOL_STATE_DIR — config.stateDirOf's documented override, which wins
  ## over any convention/config-file state-dir so this test never touches
  ## the real project's own .crisol/).
  let p = startProcess(
    crisolBin,
    workingDir = projectRoot(),
    args = @["run", epRelPath, "--measure-compile-reuse", "--jobs", "1"] & extraArgs,
    env = {"CRISOL_STATE_DIR": stateDir, "PATH": getEnv("PATH"), "HOME": getEnv("HOME")}.newStringTable,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  close(p)
  (exitCode: code, output: output)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "measure-compile-reuse gate — runner wiring (RFC-0006 M-artifact-identity b2)":

  test "OFF (default): normal execute() run passes AND writes zero ArtifactRows (nim c path taken)":
    let stateDir = freshStateDir("off")
    defer: removeDir(stateDir)

    let ep  = mkEp()
    let cfg = makeConfig(stateDir, measureCompileReuse = false)
    check cfg.measureCompileReuse == false   # confirms the default-false gate

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    # The monolithic `nim c` path never invokes the measurement worker, so
    # no ArtifactRows are ever written — this is the cleanest OBSERVABLE
    # proof (through the public API) that the gate truly defaults off.
    let rows = scanArtifactLedger(stateDir)
    check rows.len == 0

  test "library-path safety: measureCompileReuse=true with workerBinary UNSET never fork-bombs; falls back to monolithic compile":
    ## The defect this guards against: getAppFilename() returns the CURRENTLY
    ## RUNNING process's binary — here, this very unittest binary — not the
    ## crisol CLI. Before the workerBinary seam, a library host (or any
    ## non-CLI process) with measureCompileReuse=true would re-exec ITSELF as
    ## the "worker", which ignores --internal-measure-compile and just re-runs
    ## the whole host program → unbounded recursive fork, killed only by the
    ## compile watchdog. The fix: with no workerBinary configured, crisol MUST
    ## NOT call getAppFilename() at all — it degrades to the monolithic `nim c`
    ## path (measurement skipped). This test proves the run completes fast and
    ## correctly instead of hanging/forking.
    let stateDir = freshStateDir("lib_no_worker")
    defer: removeDir(stateDir)

    let ep = mkEp()
    let cfg = makeConfig(stateDir, measureCompileReuse = true)
    check cfg.workerBinary.len == 0   # unset by default — the unsafe case

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let t0 = epochTime()
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)
    let elapsed = epochTime() - t0

    check results.len == 1
    check results[0].outcome == oPassed
    check elapsed < 30.0   # a real single-file compile; a fork bomb would hang
                           # until the (300s) compile watchdog fires instead

    # No workerBinary → the monolithic `nim c` path was taken, which never
    # invokes the measurement worker, so no ArtifactRows are written.
    let rows = scanArtifactLedger(stateDir)
    check rows.len == 0

  test "library-path: workerBinary injected -> measurement worker dispatches; ArtifactRows written; identity matches RunLedger":
    ## Proves the seam itself (Config.workerBinary), independent of the CLI:
    ## a plain library call with an explicitly injected worker binary path
    ## gets the SAME measurement behavior as the CLI's --measure-compile-reuse.
    let stateDir = freshStateDir("lib_worker")
    defer: removeDir(stateDir)

    let ep = mkEp()
    var cfg = makeConfig(stateDir, measureCompileReuse = true)
    cfg.workerBinary = crisolBin

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    let expectedIdentity = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanArtifactLedger(stateDir)
    check rows.len > 0
    for r in rows:
      check r.entrypointIdentity == expectedIdentity
      check r.configHash == flagHash(ep.flags)

    let runRows = ledger.scanLedger(stateDir, expectedIdentity)
    check runRows.len > 0

  test "ON: real crisol binary run succeeds AND writes ArtifactRows (identity matches RunLedger's, entry unit excluded)":
    let stateDir = freshStateDir("on_rows")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolMeasured(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    let ep = mkEp()
    let expectedIdentity = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanArtifactLedger(stateDir)
    check rows.len > 0

    let entryBasename = "@mpass_always.nim.c"
    for r in rows:
      check r.entrypointIdentity == expectedIdentity  # collides with RunLedger's own IdentityKey
      check r.artifactBasename != entryBasename        # entry unit stays private (soundness invariant)
      check r.configHash == flagHash(ep.flags)

    check rows.len == 4  # pinned by test_compiledriver_real.nim's own probe of this fixture

    # RunLedger itself recorded the attempt too — proves the SAME run
    # produced both the normal run outcome and the artifact rows.
    let runRows = ledger.scanLedger(stateDir, expectedIdentity)
    check runRows.len > 0

  test "ON but artifact ledger unwritable: run STILL succeeds; zero rows recorded; RunLedger unaffected":
    let stateDir = freshStateDir("on_unwritable")
    defer: removeDir(stateDir)

    # Sabotage ONLY the artifact ledger's own subdirectory — put a REGULAR
    # FILE at "<stateDir>/ledger/artifacts" so createDir() there fails, while
    # leaving "<stateDir>/ledger" itself a normal directory so the runner's
    # OWN RunLedger (a sibling, unrelated subpath) is unaffected — isolating
    # the assertion to "a measurement-layer failure never fails the run" as
    # opposed to a broader, less precise "something in stateDir is broken".
    createDir(stateDir / "ledger")
    writeFile(stateDir / "ledger" / "artifacts", "not a directory")

    let (exitCode, output) = runCrisolMeasured(stateDir)
    check exitCode == 0   # compile + run succeeded despite the sabotage
    if exitCode != 0: echo "crisol run output:\n", output

    let rows = scanArtifactLedger(stateDir)
    check rows.len == 0   # the ledger dir could not be created; no rows possible

    # RunLedger itself (a sibling path, not sabotaged) still recorded the
    # attempt normally — proves the failure was isolated to the measurement
    # layer, not a wholesale stateDir breakage.
    let ep = mkEp()
    let identity = identityKey(ep.path, flagHash(ep.flags))
    let runRows = ledger.scanLedger(stateDir, identity)
    check runRows.len > 0

  test "ON: real crisol binary run persists a plausible 'compile' block in lastrun.json (RFC-0006 M-report pass a)":
    ## End-to-end proof of the M-report pass (a) decision-gate output: a real
    ## measured run (not synthetic rows) produces a lastrun.json whose
    ## compile.segments carry plausible, well-formed numbers.
    let stateDir = freshStateDir("report_a")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolMeasured(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    let lastRunPath = stateDir / "lastrun.json"
    check fileExists(lastRunPath)
    let doc = parseJson(readFile(lastRunPath))
    check doc["schemaRevision"].getInt == RunSchemaRevision

    check doc.hasKey("compileStats")
    let segments = doc["compileStats"]["segments"]
    check segments.kind == JArray
    check segments.len >= 1

    for seg in segments:
      check seg["groupId"].getStr.len > 0
      check seg["rTime"].getFloat >= 0.0
      check seg["rTime"].getFloat <= 1.0
      check seg["rSize"].getFloat >= 0.0
      check seg["rSize"].getFloat <= 1.0
      check seg["artifactsTotal"].getInt > 0
      # pcts sum to ~1 when a cost row exists for the segment (codegen+cc+link
      # were all measured for this compile); tolerate float rounding.
      let pctSum = seg["codegenPct"].getFloat + seg["ccPct"].getFloat +
                   seg["linkPct"].getFloat
      check abs(pctSum - 1.0) < 1e-9

    echo "M-report pass (a) sample compile.segments node:\n", $segments

  test "ON: persisted 'compile' block carries ambientCcacheDetected (bool) and non-empty topUnits (M-report pass b1)":
    let stateDir = freshStateDir("report_b1_fields")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolMeasured(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    let doc = parseJson(readFile(stateDir / "lastrun.json"))
    check doc.hasKey("compileStats")
    let compileBlock = doc["compileStats"]

    check compileBlock.hasKey("ambientCcacheDetected")
    check compileBlock["ambientCcacheDetected"].kind == JBool

    check compileBlock.hasKey("topUnits")
    check compileBlock["topUnits"].kind == JArray
    check compileBlock["topUnits"].len > 0
    for u in compileBlock["topUnits"]:
      check u["basename"].getStr.len > 0
      check u["sizeBytes"].getInt >= 0
      check u["ccTimeUs"].getInt >= 0

    # reuse-check was NOT configured for this run -> reuseAlerts always
    # present but empty (default-off policy, per RFC).
    check doc.hasKey("reuseAlerts")
    check doc["reuseAlerts"].kind == JArray
    check doc["reuseAlerts"].len == 0

  test "ON + reuse-check enabled on a low-sharing (single-entrypoint) run: reuseAlerts is SUPPRESSED because the run is low-confidence (RFC-0006 code-review R7)":
    ## pass_always.nim compiles alone in this run -- every reusable unit's
    ## keyHash is carried by exactly one entrypoint, so every segment's rTime
    ## is 0.0 (no cross-entrypoint sharing at all). Before R7 this asserted
    ## reuseAlerts was non-empty (an alert fired); that was PRECISELY the bug
    ## R7 fixes -- a 1-entrypoint run is exactly the RFC's own motivating
    ## example of a non-representative narrow run ("`--changed`-narrowed
    ## runs ... marked low-confidence (and reuse-check suppressed) unless
    ## the run covers a representative entrypoint count"), so the alert must
    ## now be SUPPRESSED, not fired, even though rTime is well below
    ## alertBelow.
    let stateDir = freshStateDir("report_b1_alerts")
    defer: removeDir(stateDir)

    # docToConfig sets Config.projectRoot to the CONFIG FILE'S OWN directory
    # (config.nim: "projectRoot ... config file's directory"), and discover()
    # walks/resolves entrypoint paths relative to config.projectRoot -- so the
    # temp config must live directly in the real project root (matching
    # `workingDir = projectRoot()` below), not an unrelated scratch dir, or
    # the pass_always.nim fixture path fails to resolve at all.
    let configPath = projectRoot() / ("crisol_test_reusecheck_" & $getCurrentProcessId() & ".kdl")
    defer: removeFile(configPath)
    writeFile(configPath, """
reuse-check {
    alert-below 0.5
}
""")

    let (exitCode, output) = runCrisolMeasured(stateDir, @["--config", configPath])
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    let doc = parseJson(readFile(stateDir / "lastrun.json"))
    check doc.hasKey("reuseAlerts")
    check doc["reuseAlerts"].kind == JArray
    check doc["reuseAlerts"].len == 0   # R7: suppressed -- low-confidence, not "no regressions"

    check doc.hasKey("compileStats")
    for seg in doc["compileStats"]["segments"]:
      check seg.hasKey("lowConfidence")
      check seg["lowConfidence"].getBool == true   # only 1 entrypoint compiled THIS run
      check seg["currentRunEntrypoints"].getInt == 1
      check seg["rTime"].getFloat < 0.5   # the underlying number is still honestly reported

  test "ON, run twice against the same stateDir: second run's 'compile' block carries a well-formed compileRegressions array (M-report pass b2)":
    ## History-accumulation proof: the compile-cost stream is APPEND-ONLY
    ## across runs (compilecost.nim), so a second measured run against the
    ## SAME stateDir has exactly one prior CompileCostRow per entrypoint --
    ## well below computeCompileRegressions' sampleFloor (10), so the guard
    ## must never flag anything here. This test proves the wiring end-to-end
    ## (real compiles, real ledger I/O) without asserting a specific verdict
    ## outcome -- just that the field exists, is well-formed, and the run
    ## never crashes.
    let stateDir = freshStateDir("report_b2")
    defer: removeDir(stateDir)

    let (exitCode1, output1) = runCrisolMeasured(stateDir)
    check exitCode1 == 0
    if exitCode1 != 0: echo "crisol run 1 output:\n", output1

    let (exitCode2, output2) = runCrisolMeasured(stateDir)
    check exitCode2 == 0
    if exitCode2 != 0: echo "crisol run 2 output:\n", output2

    let doc = parseJson(readFile(stateDir / "lastrun.json"))
    check doc["schemaRevision"].getInt == RunSchemaRevision
    check doc.hasKey("compileStats")
    let compileBlock = doc["compileStats"]

    check compileBlock.hasKey("compileRegressions")
    check compileBlock["compileRegressions"].kind == JArray
    # Only 1 prior row per entrypoint at this point -- far below the
    # sample-floor, so nothing should be flagged.
    check compileBlock["compileRegressions"].len == 0

    for r in compileBlock["compileRegressions"]:
      check r["entrypointIdentity"].getStr.len > 0
      check r["groupId"].getStr.len > 0
      check r["configHash"].getStr.len > 0
      check r["currentUs"].getBiggestInt >= 0
      check r["baselineUs"].getBiggestInt >= 0
      check r["thresholdUs"].getBiggestInt >= 0

when isMainModule:
  echo "All measure-compile-reuse gate tests passed."
