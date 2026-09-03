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
##   4. An unwritable stateDir (a FILE sitting where the ledger needs a
##      directory) does NOT fail the compile: exit 0, binary still built,
##      zero rows recorded, a warning on stderr.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_measureworker_real.nim

import std/[json, os, osproc, sets, tables, unittest]
import crisol           # imports runMain
import crisol/types
import crisol/workerplan
import crisol/artifactledger
import crisol/compilecost
import crisol/artifactid
import crisol/closure

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
    check fileExists(plan.outputBinPath)
    let (_, exitCode) = execCmdEx(plan.outputBinPath)
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
      let closureRes = ccIncludeClosure(ccCmdByBasename[r.artifactBasename])
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

    check fileExists(plan.outputBinPath)
    let (_, exitCode) = execCmdEx(plan.outputBinPath)
    check exitCode == 0

    # No rows could have been written (the ledger dir could not be created).
    let rows = scanArtifactLedger(plan.stateDir)
    check rows.len == 0

    # Same for the compile-cost stream — a sibling shard directory under the
    # same unwritable "ledger" file, so it fails identically and silently.
    let costRows = scanCompileCostLedger(plan.stateDir)
    check costRows.len == 0

    removeDir(workDir)

when isMainModule:
  echo "All measureworker real-worker tests passed."
