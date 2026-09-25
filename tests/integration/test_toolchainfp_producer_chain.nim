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
##   1. api.runTestsWith: `ccVer = $ccProbe()`, `nimVer = cachedNimFingerprint()`
##      -> `execute(nimVersion = nimVer, ccVersion = ccVer)`
##   2. runner.execute: `toolchainFingerprint(nimVersion, ccVersion)`
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
## C-toolchain identity injected via `api.CcFingerprintProbe` (R5-10's seam):
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
import crisol/api            # runTestsWith/productionCacheDeps/CcFingerprintProbe (uncontracted)
import crisol/types
import crisol/depgraph
import crisol/runner
import crisol/planner        # toolchainFingerprint -- the expected value's derivation
import crisol/ccidentity     # CcFingerprint/CcHalf/CcDigest, cachedCcVersion
import crisol/nimprobe       # cachedNimFingerprint
import crisol/artifactledger
import crisol/compilecost
import crisol/paths          # initTrackedRoots (suite 2 config)
import "../support/helpers"  # withTempProject
import "../support/testep"

let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root.

proc buildCrisolBinary(): string =
  ## The worker host: see test_measure_compile_gate.nim's `buildCrisolBinary`
  ## for why a library call cannot be its own measure-worker. A private output
  ## path so a concurrently-running gate test never races this build.
  result = getTempDir() / "crisol_test_toolchainfp_chain_bin" / "crisol"
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

proc knownHalf(text, hex: string): CcHalf =
  CcHalf(state: cfsKnown, text: text, digest: CcDigest(kind: cdkKnown, hex: hex))

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

proc observe(rr: RunReport; stateDir: string): ChainObservation =
  for r in scanArtifactLedger(stateDir): result.artifactFps.add r.toolchainFp
  for r in scanCompileCostLedger(stateDir): result.costFps.add r.toolchainFp
  let cb = rr.compileBlock
  if cb != nil and cb.hasKey("segments"):
    for seg in cb["segments"]: result.segmentFps.add seg["toolchainFp"].getStr

proc measuredRun(probe: CcFingerprintProbe): ChainObservation =
  ## One real measured run in a fresh temp project; `probe == nil` means the
  ## production default (the real memoised host probe).
  withTempProject:
    writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    let rr =
      if probe == nil: runTestsWith(measuredOpts(projectRoot), productionCacheDeps())
      else: runTestsWith(measuredOpts(projectRoot), productionCacheDeps(), ccProbe = probe)
    doAssert rr.status == rsOk, "run failed: " & $rr.status
    doAssert rr.results.len == 1 and rr.results[0].outcome == oPassed
    result = observe(rr, projectRoot / ".crisol")

proc checkAllHopsCarry(obs: ChainObservation; expected: string) =
  ## Every hop that can carry the value does, and carries THIS one. The len
  ## guards keep a vacuous (zero-row) run from passing the loops.
  check expected.len > 0
  check obs.artifactFps.len > 0
  check obs.costFps.len == 1
  check obs.segmentFps.len >= 1
  for fp in obs.artifactFps: check fp == expected
  for fp in obs.costFps:     check fp == expected
  for fp in obs.segmentFps:  check fp == expected

# ---------------------------------------------------------------------------

suite "L1 — toolchainFp producer chain, api layer (cc identity injected)":

  test "the fingerprint is derived from nim + the injected cc identity and reaches rows AND the compile block":
    let obs = measuredRun(proc(): CcFingerprint = gccFingerprint())
    checkAllHopsCarry(obs,
      toolchainFingerprint(cachedNimFingerprint(), $gccFingerprint()))

  test "a different cc identity yields a different fingerprint at every hop (no constant fold)":
    ## The differential partner of the case above: same project, same nim,
    ## the ONLY difference is the compiler half of the injected identity.
    let gcc   = measuredRun(proc(): CcFingerprint = gccFingerprint())
    let clang = measuredRun(proc(): CcFingerprint = clangFingerprint())
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
      toolchainFingerprint(cachedNimFingerprint(), cachedCcVersion()))

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
  let p = plan(cfg, @[ep], graph, nimVersion, false, ccVersion)
  let results = execute(p, config = cfg, graph = graph, nimVersion = nimVersion,
                        ccVersion = ccVersion, showProgress = false).results
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
    let expectedA = toolchainFingerprint("nim-identity-A", "cc-identity-X")
    let expectedB = toolchainFingerprint("nim-identity-B", "cc-identity-X")
    check expectedA != expectedB   # fixture sanity: the inputs really differ
    for (obs, expected) in [(a, expectedA), (b, expectedB)]:
      check obs.artifactFps.len > 0
      check obs.costFps.len == 1
      for fp in obs.artifactFps: check fp == expected
      for fp in obs.costFps:     check fp == expected
