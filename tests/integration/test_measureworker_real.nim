## test_measureworker_real.nim — RFC-0006 M-artifact-identity, PASS (b1): ONE
## real live-compile integration test for the measurement-worker binary.
##
## Everything in tests/unit/test_measureworker.nim exercises plan parsing and
## the env-injection helper with no real `nim`/`cc` invocation. This is the
## single deliberately-budgeted exception (mirrors compiledriver/artifactid
## precedent — see test_compiledriver_real.nim / test_artifactid_real.nim):
## drive the REAL `crisol --internal-measure-compile <plan.json>` worker,
## through the actual CLI dispatch (`runMain`), against
## `tests/fixtures/pass_always.nim` (the smallest/fastest real fixture in the
## suite — already proven by test_compiledriver_real.nim to produce 4
## reusable units + 1 entry unit under --mm:orc), and prove:
##
##   1. A runnable binary is produced.
##   2. Exactly the reusable-set count of ArtifactRows are written to the
##      artifact ledger under a temp stateDir, and the entry unit
##      (@mpass_always.nim.c) is NOT among them.
##   3. Each recorded row's keyHash matches an independently-recomputed
##      artifactid.artifactKeyHash over the same inputs; sizeBytes is
##      positive and matches the real file size; ccTimeUs is positive;
##      groupId/configHash are carried through from the plan.
##   3b. Every ArtifactRow AND the CompileCostRow carry the plan's
##      toolchainFp verbatim (W9l / L1: the worker's hop of the toolchain
##      fingerprint producer chain).
##   4. An unwritable stateDir (a FILE sitting where the ledger needs a
##      directory) does NOT fail the compile: exit 0, binary still built,
##      zero rows recorded, a warning on stderr.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_measureworker_real.nim

import std/[json, os, osproc, sets, strutils, tables, unittest]
import crisol           # imports runMain
import crisol/types
import crisol/workerplan
import crisol/artifactledger
import crisol/compilecost
import crisol/artifactid
import crisol/closure
import crisol/paths      # CR3: TrackedRoots, to recompute the same way the
                          # real worker's `measureworker.planRoots` does
from crisol/ccidentity import CcProbeContext, cachedToolchainProbe
                          # R10-S6: the plan's driver site, learned the way
                          # the parent (`runner.execute`) learns it
from crisol/headerprobe import siteResolver
import crisol/measureworker   # runMeasureCompileWorker's warning seam (R11-L6)

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root (mirrors
  # test_compiledriver_real.nim's idiom).
let fixture = projectRoot / "tests" / "fixtures" / "pass_always.nim"

proc freshWorkDir(tag: string): string =
  result = getTempDir() / "crisol_test_measureworker_real_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc buildPlan(workDir: string): MeasurePlan =
  let nimcacheDir = workDir / "nimcache"
  let binDir      = workDir / "bin"
  createDir(nimcacheDir)
  createDir(binDir)
  MeasurePlan(
    entrypointPath:    "tests/fixtures/pass_always.nim",   # ep.path convention: project-relative
    entrypointAbsPath: fixture,
    flags:             @[],
    nimcacheDir:       nimcacheDir,
    outputBinPath:     binDir / "pass_always",
    groupId:           "unit",
    configHash:        "test-config-hash",
    stateDir:          workDir / "state",
    projectRoot:       projectRoot,
    # W9l / L1: a distinctive value the worker cannot produce on its own --
    # it must copy this through onto every row, never re-probe or blank it.
    toolchainFp:       "f00dfacecafebeef",
    driverSite:        cachedToolchainProbe(CcProbeContext(projectRoot: projectRoot,
                                                           stateDir: workDir / "state",
                                                           flags: @[])).site,
  )

proc writePlan(plan: MeasurePlan; workDir: string): string =
  result = workDir / "plan.json"
  writeFile(result, $toJson(plan))

suite "crisol --internal-measure-compile — real worker end-to-end (pass_always fixture)":

  test "builds a runnable binary AND writes one ArtifactRow per reusable unit (entry unit excluded)":
    let workDir = freshWorkDir("main")
    let plan = buildPlan(workDir)
    let planPath = writePlan(plan, workDir)

    let code = runMain(@[InternalMeasureCompileToken, planPath])
    check code == 0

    # The binary was actually built and runs.
    check fileExists(addFileExt(plan.outputBinPath, ExeExt))   # the link appends .exe on Windows
    let (_, exitCode) = execCmdEx(addFileExt(plan.outputBinPath, ExeExt))
    check exitCode == 0   # pass_always.nim is literally `quit(0)`

    # Rows were written: one per reusable unit, entry unit excluded.
    let rows = scanArtifactLedger(plan.stateDir)
    check rows.len > 0

    let entryBasename = "@mpass_always.nim.c"
    var basenames: HashSet[string]
    for r in rows:
      check r.artifactBasename != entryBasename
      basenames.incl r.artifactBasename
    check basenames.len == rows.len   # no duplicate basenames recorded

    # Cross-check against the real manifest's own reusable-set count.
    let manifestPath = plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json"
    let manifest = parseCompileManifest(manifestPath)
    var expectedReusable = 0
    for pair in manifest.compile:
      if pair.cPath.extractFilename != entryBasename:
        inc expectedReusable
    check rows.len == expectedReusable
    check expectedReusable == 4   # pinned by test_compiledriver_real.nim's own probe of this fixture

    removeDir(workDir)

  test "recorded rows carry correct keyHash/sizeBytes/ccTimeUs/groupId/configHash":
    let workDir = freshWorkDir("fields")
    let plan = buildPlan(workDir)
    let planPath = writePlan(plan, workDir)

    let code = runMain(@[InternalMeasureCompileToken, planPath])
    check code == 0

    let rows = scanArtifactLedger(plan.stateDir)
    check rows.len > 0

    let manifestPath = plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json"
    let manifest = parseCompileManifest(manifestPath)
    let entryBasename = "@mpass_always.nim.c"
    let knownStrings = @[plan.nimcacheDir, plan.outputBinPath.parentDir()]
    # CR3: the real worker's `recordArtifactRows` now threads a real
    # project-only `TrackedRoots` into `ccIncludeClosure` (`measureworker.
    # planRoots(plan)`) — recompute the SAME way here, or this independent
    # recomputation would silently diverge from what was actually recorded.
    let roots = initTrackedRoots(plan.projectRoot,
                                 newSeq[tuple[name, native: string]](),
                                 plan.stateDir)

    var ccCmdByBasename: Table[string, string]
    var cPathByBasename: Table[string, string]
    for pair in manifest.compile:
      let base = pair.cPath.extractFilename
      if base != entryBasename:
        ccCmdByBasename[base] = pair.ccCmd
        cPathByBasename[base] = pair.cPath

    for r in rows:
      check r.groupId == plan.groupId
      check r.configHash == plan.configHash
      check r.toolchainFp == plan.toolchainFp   # L1: threaded, not re-derived
      check r.sizeBytes > 0
      check r.ccTimeUs > 0
      check r.sizeBytes == getFileSize(cPathByBasename[r.artifactBasename])

      # Independently recompute the key hash the same way the worker did,
      # from the SAME real manifest/cc -M — proves the recorded keyHash is
      # not a placeholder/stub value. R5: artifactKeyHash also folds the
      # normalized cc command (a true PREFIX of Stage-R's stageRKey).
      let rawContent = readFile(cPathByBasename[r.artifactBasename])
      let normalized = normalize(rawContent, knownStrings)
      let normalizedCcCmd = normalize(ccCmdByBasename[r.artifactBasename], knownStrings)
      let closureRes = ccIncludeClosure(ccCmdByBasename[r.artifactBasename],
                                        roots = roots,
                                        driver = siteResolver(plan.driverSite))
      check closureRes.ok
      let expectedKeyHash = artifactKeyHash(normalized, closureRes.contentHash, normalizedCcCmd)
      check r.keyHash == expectedKeyHash

    removeDir(workDir)

  test "writes exactly ONE CompileCostRow with plausible non-negative spans and matching identity":
    let workDir = freshWorkDir("costsplit")
    let plan = buildPlan(workDir)
    let planPath = writePlan(plan, workDir)

    let code = runMain(@[InternalMeasureCompileToken, planPath])
    check code == 0

    let artRows  = scanArtifactLedger(plan.stateDir)
    let costRows = scanCompileCostLedger(plan.stateDir)
    check artRows.len > 0
    check costRows.len == 1

    let row = costRows[0]
    check row.codegenUs >= 0
    check row.ccUs >= 0
    check row.linkUs >= 0
    check row.codegenUs + row.ccUs + row.linkUs > 0   # a real compile took SOME time
    check row.groupId == plan.groupId
    check row.configHash == plan.configHash
    check row.toolchainFp == plan.toolchainFp   # L1: same contract as ArtifactRow
    check row.rowVersion == currentCompileCostRowVersion

    # Identity must match every ArtifactRow's identity for the SAME compile.
    for r in artRows:
      check r.entrypointIdentity == row.entrypointIdentity

    removeDir(workDir)

  test "a measurement-recording failure (unwritable stateDir) does NOT fail the compile":
    let workDir = freshWorkDir("unwritable")
    var plan = buildPlan(workDir)
    # Sabotage: put a REGULAR FILE where the artifact ledger needs to mkdir
    # a directory ("ledger" as a file, not a dir) — this reliably fails
    # createDir() with an OSError regardless of process uid (unlike a
    # permission-bit-based sabotage, which root bypasses inside the ./dev
    # container — see dev's rootless-podman comment).
    let badStateDir = workDir / "unwritable_state"
    createDir(badStateDir)
    writeFile(badStateDir / "ledger", "not a directory")
    plan.stateDir = badStateDir
    let planPath = writePlan(plan, workDir)

    let code = runMain(@[InternalMeasureCompileToken, planPath])
    check code == 0   # compile succeeded; measurement failure must not propagate

    check fileExists(addFileExt(plan.outputBinPath, ExeExt))   # the link appends .exe on Windows
    let (_, exitCode) = execCmdEx(addFileExt(plan.outputBinPath, ExeExt))
    check exitCode == 0

    # No rows could have been written (the ledger dir could not be created).
    let rows = scanArtifactLedger(plan.stateDir)
    check rows.len == 0

    # Same for the compile-cost stream — a sibling shard directory under the
    # same unwritable "ledger" file, so it fails identically and silently.
    let costRows = scanCompileCostLedger(plan.stateDir)
    check costRows.len == 0

    removeDir(workDir)

  test "an unresolved driver skips every unit AND says so on the warning channel the parent relays (R11-L6)":
    let workDir = freshWorkDir("nodriver")
    var plan = buildPlan(workDir)
    plan.driverSite = DriverSite(known: false, why: "lowsC-sentinel: no driver site")
    let planPath = writePlan(plan, workDir)

    var said: seq[string]
    let code = runMeasureCompileWorker(planPath,
                                       proc(line: string) = said.add line)
    check code == 0   # the compile itself succeeded
    check fileExists(addFileExt(plan.outputBinPath, ExeExt))

    # Nothing recorded, and not silently: every unit's refusal names the
    # site's reason, and one summary line says how many units the ledger
    # is missing.
    check scanArtifactLedger(plan.stateDir).len == 0
    let manifest = parseCompileManifest(
      plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json")
    let reusable = manifest.compile.len - 1   # every unit but the entry unit
    check reusable > 0
    var perUnit = 0
    var summary = 0
    for line in said:
      check line.startsWith(MeasureWarningPrefix)
      if "lowsC-sentinel: no driver site" in line: inc perUnit
      if $reusable & " of " & $reusable & " reusable units were not recorded" in line:
        inc summary
    check perUnit == reusable
    check summary == 1

    # What the parent reads back out of the worker's captured output is
    # exactly those lines, and nothing of nim's own.
    let captured = "Hint: some nim chatter\n" & said.join("\n") & "\nmore output\n"
    check measureWorkerWarnings(captured) == said

    removeDir(workDir)

when isMainModule:
  echo "All measureworker real-worker tests passed."
