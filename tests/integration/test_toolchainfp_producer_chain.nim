## test_toolchainfp_producer_chain.nim — L1 (liveness): the `toolchainFp`
## PRODUCER chain, observed end to end from a real measured run.
##
## THE FINDING. `toolchainFp` (W9l) stamps every ArtifactRow/CompileCostRow
## with the toolchain its numbers were measured under, and compilereport
## partitions its segments on it. Only that CONSUMER was tested, and only from
## hand-built rows: blanking the producer, replacing it with a constant, or
## dropping the field at any hop left every suite green. A severed chain means
## rows from two different compilers silently pool into one segment -- the
## under-invalidation direction.
##
## THE CHAIN (every hop below is severable, and each has a red test here or in
## the two unit/integration files named):
##
##   1. api.runTestsWith: `ccVer = $ccProbe(ctx)`, `nimVer = cachedNimFingerprint()`
##      -> `execute(nimVersion = nimVer, toolchain = impl.toolchain)`
##   2. runner.execute: `toolchainFingerprint(nimVersion, toolchain.identity)`
##      -> `ExecCtx.toolchainFp`
##   3. runner.writeWorkerPlan -> buildCompileWorkerPlan(..., ctx.toolchainFp)
##      -> `MeasurePlan.toolchainFp`
##   4. workerplan.toJson -> plan.json -> parseMeasurePlan (the process
##      boundary; also pinned by tests/unit/test_workerplan.nim)
##   5. measureworker: `ArtifactRow.toolchainFp` / `CompileCostRow.toolchainFp`
##      = `plan.toolchainFp` (also pinned by test_measureworker_real.nim)
##   6. artifactledger / compilecost row encode -> scan
##   7. compilereport.readCompileBlock -> `segments[].toolchainFp` (consumer)
##
## WHAT THIS FILE PINS. Suite 1 drives hops 1-7 through `runTestsWith` with the
## C-toolchain identity injected via `RunDeps.ccProbe`:
## the fingerprint is non-empty, equals `toolchainFingerprint` over the real nim
## identity and the injected cc identity, VARIES when only the cc identity
## varies, and survives onto both row streams and the persisted compile block.
## The default-probe case pins it to the real host toolchain. Suite 2 varies the
## NIM identity, which `runTestsWith` exposes no seam for, by calling
## `runner.execute` directly (hops 2-6).
##
## The measure-worker is a self-reexec of the `crisol` CLI, so -- exactly as
## test_measure_compile_gate.nim documents -- a real `crisol` binary is built
## once and injected via `workerBinary`.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_toolchainfp_producer_chain.nim

import std/[json, os, osproc, unittest]
import crisol/api
import crisol/runcore        # runTestsWith/productionRunDeps/RunDeps (uncontracted)
import crisol/pipeline       # ccProbeContextOf
import crisol/types
import crisol/depgraph
import crisol/runner
import crisol/planner        # toolchainFingerprint -- the expected value's derivation
import crisol/ccidentity     # CcFingerprint/CcProbeContext
import "../support/ccprobes" # cachedCcVersion
import crisol/config         # loadConfig
import crisol/nimprobe       # cachedNimFingerprint
import crisol/artifactledger
import crisol/compilecost
import crisol/paths          # initTrackedRoots (suite 2 config)
import "../support/helpers"  # withTempProject
import "../support/testep"
import "../support/ccfake"   # knownHalf
import "../support/driversite"  # R12-D4: execute/verifyCachePass take a RunToolchain

let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root.

proc buildCrisolBinary(): string =
  ## The worker host: see test_measure_compile_gate.nim's `buildCrisolBinary`
  ## for why a library call cannot be its own measure-worker. A private output
  ## path so a concurrently-running gate test never races this build. The
  ## name carries the platform's executable extension (`crisol.exe` on
  ## Windows), which `-o:` does not add to a name given without one.
  result = getTempDir() / "crisol_test_toolchainfp_chain_bin" / addFileExt("crisol", ExeExt)
  createDir(result.parentDir)
  let cmd = "nim c --hints:off --warnings:off -d:release --mm:orc -o:" &
            result.quoteShell & " " & (repoRoot / "src" / "crisol.nim").quoteShell
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "failed to build crisol binary: " & output
  doAssert fileExists(result), "crisol binary not produced at " & result

let crisolBin = buildCrisolBinary()

# ---------------------------------------------------------------------------
# Suite 1 helpers -- the api layer, cc identity injected
# ---------------------------------------------------------------------------

proc gccFingerprint(): CcFingerprint =
  CcFingerprint(compiler: knownHalf("gcc 13.2.0", "1111111111111111"),
                runtime:  knownHalf("glibc 2.38", "2222222222222222"))

proc clangFingerprint(): CcFingerprint =
  ## Differs from `gccFingerprint` in the compiler half ONLY, so a producer
  ## that folds the cc identity to anything constant collapses the two.
  CcFingerprint(compiler: knownHalf("clang 17.0.6", "3333333333333333"),
                runtime:  knownHalf("glibc 2.38", "2222222222222222"))

proc measuredOpts(projectRoot: string): RunOptions =
  RunOptions(
    configPath:          projectRoot / "crisol.kdl",
    installSignals:      false,
    showProgress:        false,
    persist:             true,   # compileBlock is only built on a persisted run
    noCache:             true,   # keep the result cache out of the picture
    measureCompileReuse: true,
    workerBinary:        crisolBin,
  )

type ChainObservation = object
  artifactFps: seq[string]   # hop 5/6: every ArtifactRow's toolchainFp
  costFps:     seq[string]   # hop 5/6: every CompileCostRow's toolchainFp
  segmentFps:  seq[string]   # hop 7:   every compile-block segment's toolchainFp
  ctx:         CcProbeContext # the probe context the run's configuration gives

proc observe(rr: RunReport; stateDir: string): ChainObservation =
  for r in scanArtifactLedger(stateDir): result.artifactFps.add r.toolchainFp
  for r in scanCompileCostLedger(stateDir): result.costFps.add r.toolchainFp
  let cb = rr.compileBlock
  if cb != nil and cb.hasKey("segments"):
    for seg in cb["segments"]: result.segmentFps.add seg["toolchainFp"].getStr

proc measuredRun(probe: proc(ctx: CcProbeContext): CcFingerprint {.closure.}): ChainObservation =
  ## One real measured run in a fresh temp project; `probe == nil` means the
  ## production probe (the real memoised host probe `productionRunDeps`
  ## installs).
  withTempProject:
    writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    var deps = productionRunDeps()
    if probe != nil:
      # The fingerprint is injected; the site is the host's real one, since
      # the measure worker resolves each generated C unit's driver against
      # it to key the artifact rows this file observes.
      deps.ccProbe = proc(ctx: CcProbeContext): ToolchainProbe =
        ToolchainProbe(fp: probe(ctx), site: cachedToolchainProbe(ctx).site)
    let rr = runTestsWith(measuredOpts(projectRoot), deps)
    doAssert rr.status == rsOk, "run failed: " & $rr.status
    doAssert rr.results.len == 1 and rr.results[0].outcome == oPassed
    result = observe(rr, projectRoot / ".crisol")
    result.ctx = ccProbeContextOf(loadConfig(projectRoot / "crisol.kdl")[0])

template checkAllHopsCarry(obs: ChainObservation; expected: string) =
  ## Every hop that can carry the value does, and carries THIS one. The len
  ## guards keep a vacuous (zero-row) run from passing the loops.
  ##
  ## A template, not a proc: unittest's `check` marks the ENCLOSING test
  ## failed only when it expands inside the test body. Inside a top-level
  ## proc it has no test to mark, so a failed hop printed "Check failed" and
  ## then `[OK]`, and only the exit code went red (R11-L5).
  let hopsObs = obs
  let hopsExpected = expected
  check hopsExpected.len > 0
  check hopsObs.artifactFps.len > 0
  check hopsObs.costFps.len == 1
  check hopsObs.segmentFps.len >= 1
  for fp in hopsObs.artifactFps: check fp == hopsExpected
  for fp in hopsObs.costFps:     check fp == hopsExpected
  for fp in hopsObs.segmentFps:  check fp == hopsExpected

# ---------------------------------------------------------------------------

suite "L1 — toolchainFp producer chain, api layer (cc identity injected)":

  test "the fingerprint is derived from nim + the injected cc identity and reaches rows AND the compile block":
    let obs = measuredRun(proc(ctx: CcProbeContext): CcFingerprint = gccFingerprint())
    checkAllHopsCarry(obs,
      toolchainFingerprint(cachedNimFingerprint(), $gccFingerprint()))

  test "a different cc identity yields a different fingerprint at every hop (no constant fold)":
    ## The differential partner of the case above: same project, same nim,
    ## the ONLY difference is the compiler half of the injected identity.
    let gcc   = measuredRun(proc(ctx: CcProbeContext): CcFingerprint = gccFingerprint())
    let clang = measuredRun(proc(ctx: CcProbeContext): CcFingerprint = clangFingerprint())
    let clangExpected = toolchainFingerprint(cachedNimFingerprint(), $clangFingerprint())
    checkAllHopsCarry(clang, clangExpected)
    require gcc.artifactFps.len > 0 and clang.artifactFps.len > 0
    require gcc.costFps.len > 0 and clang.costFps.len > 0
    require gcc.segmentFps.len > 0 and clang.segmentFps.len > 0
    check gcc.artifactFps[0] != clang.artifactFps[0]
    check gcc.costFps[0]     != clang.costFps[0]
    check gcc.segmentFps[0]  != clang.segmentFps[0]

  test "the default probe stamps the REAL host toolchain identity":
    ## Pins the production path (no injected probe) to the real nim + cc
    ## identity, so the value is not merely self-consistent but the host's.
    let obs = measuredRun(nil)
    checkAllHopsCarry(obs,
      toolchainFingerprint(cachedNimFingerprint(), cachedCcVersion(obs.ctx)))

# ---------------------------------------------------------------------------
# Suite 2 -- the runner layer, nim identity varied
# ---------------------------------------------------------------------------

proc freshStateDir(tag: string): string =
  result = getTempDir() / "crisol_test_toolchainfp_chain_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc executeMeasured(stateDir, nimVersion, ccVersion: string): ChainObservation =
  ## `runner.execute` directly (hops 2-6), with the worker injected the same
  ## way test_measure_compile_gate.nim's library-path case does.
  let ep = testEp("tests" / "fixtures" / "pass_always.nim", group = "test", flags = @[])
  let cfg = Config(
    projectRoot:         repoRoot,
    trackedRoots:        initTrackedRoots(repoRoot, newSeq[tuple[name, native: string]](), stateDir),
    stateDir:            stateDir,
    timeoutSecs:         60,
    compileTimeoutSecs:  300,
    maxOutputBytes:      65_536,
    jobs:                1,
    measureCompileReuse: true,
    workerBinary:        crisolBin,
  )
  var graph = initDepGraph("")
  let p = plan(cfg, @[ep], graph, false)
  let results = execute(p, config = cfg, graph = graph, nimVersion = nimVersion,
                        toolchain = fakeToolchain(ccVersion, hostSite(cfg)),
                        showProgress = false).results
  doAssert results.len == 1 and results[0].outcome == oPassed
  for r in scanArtifactLedger(stateDir): result.artifactFps.add r.toolchainFp
  for r in scanCompileCostLedger(stateDir): result.costFps.add r.toolchainFp

suite "L1 — toolchainFp producer chain, runner layer (nim identity varied)":

  test "execute() threads toolchainFingerprint(nimVersion, ccVersion) to both row streams; nim alone moves it":
    let dirA = freshStateDir("nimA")
    let dirB = freshStateDir("nimB")
    defer:
      removeDir(dirA)
      removeDir(dirB)
    let a = executeMeasured(dirA, "nim-identity-A", "cc-identity-X")
    let b = executeMeasured(dirB, "nim-identity-B", "cc-identity-X")
    let expectedA = toolchainFingerprint("nim-identity-A", fakeToolchain("cc-identity-X").identity)
    let expectedB = toolchainFingerprint("nim-identity-B", fakeToolchain("cc-identity-X").identity)
    check expectedA != expectedB   # fixture sanity: the inputs really differ
    for (obs, expected) in [(a, expectedA), (b, expectedB)]:
      check obs.artifactFps.len > 0
      check obs.costFps.len == 1
      for fp in obs.artifactFps: check fp == expected
      for fp in obs.costFps:     check fp == expected

when isMainModule:
  echo "test_toolchainfp_producer_chain done"
