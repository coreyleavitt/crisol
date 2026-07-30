## test_compileworker_real.nim — RFC-0006 Stage R, R2b1: real live-compile
## integration tests for the CACHE-MODE compile worker
## (`crisol --internal-compile-worker <plan.json>` / `runCompileCacheWorker`)
## and its monolithic escape hatch.
##
## Mirrors test_measureworker_real.nim's precedent (the ONE deliberately-
## budgeted real-compile tier for this worker): no synthetic seams here —
## every test drives the REAL worker (`measureworker.runCompileCacheWorker`)
## against real fixtures, with a real `<stateDir>/objcache/v1/` on disk.
##
## Behaviors covered (see docs/rfc/0006's R2b1 TDD plan):
##
##   3. A real cross-entrypoint HIT: `tests/fixtures/golden_reuse/ep_a.nim`
##      and `ep_b.nim` share 5 of their 6 reusable units (fixture.c, three
##      real stdlib units, and NOT the ORC-tailored `@mfixture_substrate.
##      nim.c`, which genuinely differs per entrypoint — see
##      `tests/unit/test_golden_reuse.nim`'s own oracle). Compiling ep_a
##      into a FRESH stateDir stores 6 objects; compiling ep_b against the
##      SAME stateDir afterward adds exactly ONE more (the tailored-B
##      object) — the other 5 are HITS, proven by (a) the post-ep_a key set
##      being a strict subset of the post-ep_b key set (nothing evicted or
##      replaced) and (b) the count growing by exactly 1, not 6 (which is
##      what zero reuse would look like). This is the most robust available
##      observable without R5's decision-persistence: real files, real
##      counts, no reliance on stderr text.
##   4. Escape hatch: `plan.flags = @["--run"]` is a genuine, deterministic
##      way to make ONLY the cache-mode path's `nim c --compileOnly --run`
##      step fail (`--run` requires a linked binary, which `--compileOnly`
##      never produces — confirmed empirically: exit 1, "execution of an
##      external program failed") while the ESCAPE HATCH's monolithic
##      `nim c --run` (no `--compileOnly`) succeeds outright (confirmed
##      empirically: compiles, links, runs, exit 0). This is an honest,
##      reproducible cache-path-specific failure — NOT filesystem sabotage
##      of `nimcacheDir`/`outputBinPath`/`stateDir`, all of which are
##      symmetrically shared with the monolithic fallback (sabotaging any of
##      them breaks the fallback identically, so they cannot demonstrate the
##      escape hatch actually rescuing the build). `objcache` itself never
##      raises or fails the compile on a broken stateDir (storeObject/
##      lookupObject are documented never-raise, soft-fail primitives), so
##      an unwritable-objcache scenario cannot reach this worker's escape
##      hatch at all — it is absorbed a layer below, silently, which is
##      exercised instead by the "entry unit stays private" test's sibling
##      assertions in test_measureworker_real.nim's own precedent style.
##   5. The entry unit stays private: a real cache-mode run's objcache holds
##      EXACTLY the reusable-set count of objects (manifest compile-unit
##      count minus the entry unit) — never reusable-set-count + 1, which is
##      what a leaked-entry-unit bug would produce.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_compileworker_real.nim

import std/[json, os, osproc, sets, strutils, unittest]
import crisol/types
import crisol/keys
import crisol/workerplan
import crisol/cacheworker
import crisol/closure
import crisol/objcache
import crisol/objcachestats
import crisol/artifactledger

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root (mirrors
  # test_measureworker_real.nim's idiom).

let goldenDir     = projectRoot / "tests" / "fixtures" / "golden_reuse"
let passAlwaysFix = projectRoot / "tests" / "fixtures" / "pass_always.nim"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshWorkDir(tag: string): string =
  result = getTempDir() / "crisol_test_compileworker_real_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc objcacheKeys(stateDir: string): HashSet[string] =
  ## The set of stored objcache keyHashes (one per committed `<keyHash>.o`)
  ## under `stateDir`, read directly off disk — an independent observation,
  ## not routed through `objcache.lookupObject`/`storeObject` (mirrors
  ## test_measureworker_real.nim's direct-ledger-scan idiom).
  result = initHashSet[string]()
  let verDir = stateDir / "objcache" / objCacheDirName()
  if not dirExists(verDir): return
  for kind, path in walkDir(verDir):
    if kind == pcFile and path.endsWith(".o"):
      result.incl path.extractFilename[0 ..< ^2]   # strip ".o"

proc buildGoldenPlan(workDir, epName, stateDir: string): MeasurePlan =
  let nimcacheDir = workDir / (epName & "_nimcache")
  let binDir      = workDir / (epName & "_bin")
  createDir(nimcacheDir)
  createDir(binDir)
  MeasurePlan(
    entrypointPath:    "tests/fixtures/golden_reuse" / (epName & ".nim"),
    entrypointAbsPath: goldenDir / (epName & ".nim"),
    # fixture_ffi.nim's companion fixture.h lives in golden_reuse/include/,
    # reachable only via an explicit -I (see fixture_ffi.nim's module doc);
    # the fixture dir itself is auto-added by nim, this extra -I is not.
    flags:             @["--passC:-I" & (goldenDir / "include")],
    nimcacheDir:       nimcacheDir,
    outputBinPath:     binDir / epName,
    groupId:           "golden",
    configHash:        "golden-r2b1",
    stateDir:          stateDir,
  )

proc buildPassAlwaysPlan(workDir: string): MeasurePlan =
  let nimcacheDir = workDir / "nimcache"
  let binDir      = workDir / "bin"
  createDir(nimcacheDir)
  createDir(binDir)
  MeasurePlan(
    entrypointPath:    "tests/fixtures/pass_always.nim",
    entrypointAbsPath: passAlwaysFix,
    flags:             @[],
    nimcacheDir:       nimcacheDir,
    outputBinPath:     binDir / "pass_always",
    groupId:           "unit",
    configHash:        "pa-r2b1",
    stateDir:          workDir / "state",
  )

proc writePlan(plan: MeasurePlan; path: string): string =
  writeFile(path, $toJson(plan))
  path

# ===========================================================================
# Behavior 3 — real cross-entrypoint HIT (golden_reuse fixture)
# ===========================================================================

suite "runCompileCacheWorker — real cross-entrypoint HIT (golden_reuse ep_a/ep_b)":

  test "ep_a then ep_b against the SAME stateDir: 6 objects after ep_a, 7 after ep_b (only +1 new — the tailored unit; the other 5 are hits)":
    let workDir = freshWorkDir("hit")
    defer: removeDir(workDir)
    let stateDir = workDir / "state"

    let planA = buildGoldenPlan(workDir, "ep_a", stateDir)
    let planB = buildGoldenPlan(workDir, "ep_b", stateDir)

    let codeA = runCompileCacheWorker(writePlan(planA, workDir / "plan_a.json"))
    check codeA == 0
    check fileExists(planA.outputBinPath)
    let (_, exitA) = execCmdEx(planA.outputBinPath)
    check exitA == 3   # ep_a: substrateA() (1) + int(fixtureDouble(1)) (2) == 3

    let keysAfterA = objcacheKeys(stateDir)
    # 6 reusable units: fixture.c, @psystem@sexceptions, @pstd@sprivate@sdigitsutils,
    # @psystem@sdollars, @psystem, @mfixture_substrate (ORC-tailored-A).
    check keysAfterA.len == 6

    let codeB = runCompileCacheWorker(writePlan(planB, workDir / "plan_b.json"))
    check codeB == 0
    check fileExists(planB.outputBinPath)
    let (_, exitB) = execCmdEx(planB.outputBinPath)
    check exitB == 4   # ep_b: substrateB() (2) + int(fixtureDouble(1)) (2) == 4

    let keysAfterB = objcacheKeys(stateDir)
    check keysAfterB.len == 7   # +1 only: the ORC-tailored-B unit; 5 were real HITs

    # Nothing evicted or replaced by ep_b's run — pure additive reuse.
    for k in keysAfterA:
      check k in keysAfterB

# ===========================================================================
# Behavior R5a — realized objcache hit/miss telemetry is PERSISTED
# (objcachestats.nim / measureworker.recordObjCacheStatsRow), one row per
# successful cache-mode compile.
# ===========================================================================

suite "runCompileCacheWorker — objcachestats realized telemetry (R5a)":

  test "ep_a then ep_b against the SAME stateDir: one ObjCacheStatsRow per compile; ep_b's row shows real hits + reusedBytes > 0":
    let workDir = freshWorkDir("stats")
    defer: removeDir(workDir)
    let stateDir = workDir / "state"

    let planA = buildGoldenPlan(workDir, "ep_a", stateDir)
    let planB = buildGoldenPlan(workDir, "ep_b", stateDir)

    let codeA = runCompileCacheWorker(writePlan(planA, workDir / "plan_a.json"))
    check codeA == 0
    let codeB = runCompileCacheWorker(writePlan(planB, workDir / "plan_b.json"))
    check codeB == 0

    let rows = scanObjCacheStatsLedger(stateDir)
    check rows.len == 2   # one row per compile

    let identA = identityKey(planA.entrypointPath, planA.configHash)
    let identB = identityKey(planB.entrypointPath, planB.configHash)

    var rowA, rowB: ObjCacheStatsRow
    var sawA, sawB = false
    for r in rows:
      if r.entrypointIdentity == identA:
        rowA = r; sawA = true
      elif r.entrypointIdentity == identB:
        rowB = r; sawB = true
    check sawA
    check sawB

    # ep_a: a FRESH cache — every reusable unit is a miss that gets stored;
    # the entry unit is always non-cacheable (ocdDisabled).
    check rowA.hits == 0
    check rowA.misses == 6
    check rowA.stored == 6
    check rowA.disabled == 1
    check rowA.reusedBytes == 0
    check rowA.groupId == planA.groupId
    check rowA.configHash == planA.configHash
    check rowA.rowVersion == currentObjCacheStatsRowVersion

    # ep_b: 5 of its 6 reusable units are real HITs against ep_a's cache;
    # only the ORC-tailored-B unit is a genuine miss+store. The entry unit
    # is again non-cacheable.
    check rowB.hits == 5
    check rowB.misses == 1
    check rowB.stored == 1
    check rowB.disabled == 1
    check rowB.reusedBytes > 0   # real bytes copied from the cache

    # Invariant: every processed unit lands in exactly one bucket.
    check rowA.hits + rowA.misses + rowA.disabled == 7   # 6 reusable + 1 entry
    check rowB.hits + rowB.misses + rowB.disabled == 7

  test "a stats-recording failure (unwritable objcachestats dir) does NOT fail the compile":
    let workDir = freshWorkDir("stats_unwritable")
    defer: removeDir(workDir)
    var plan = buildPassAlwaysPlan(workDir)
    # Sabotage: put a REGULAR FILE where the objcache-stats ledger needs to
    # mkdir a directory ("ledger" as a file, not a dir) — mirrors
    # test_measureworker_real.nim's "unwritable stateDir" sabotage idiom.
    let badStateDir = workDir / "unwritable_state"
    createDir(badStateDir)
    writeFile(badStateDir / "ledger", "not a directory")
    plan.stateDir = badStateDir
    let planPath = writePlan(plan, workDir / "plan.json")

    let code = runCompileCacheWorker(planPath)
    check code == 0   # compile succeeded; stats-recording failure must not propagate

    check fileExists(plan.outputBinPath)
    let (_, exitCode) = execCmdEx(plan.outputBinPath)
    check exitCode == 0   # pass_always.nim is literally `quit(0)`

    # No row could have been written (the ledger dir could not be created).
    let rows = scanObjCacheStatsLedger(plan.stateDir)
    check rows.len == 0

# ===========================================================================
# Behavior 4 — escape hatch: a cache-path-specific failure still builds the
# binary via the monolithic fallback.
# ===========================================================================

suite "runCompileCacheWorker — escape hatch (cache-path failure -> monolithic fallback)":

  test "plan.flags=['--run'] breaks ONLY --compileOnly (spans.ok=false); worker falls back to monolithic 'nim c --run' and succeeds":
    ## Empirically confirmed (see module doc): `nim c --compileOnly --run`
    ## exits 1 ("execution of an external program failed" — --compileOnly
    ## never links, so --run has nothing to execute), while a monolithic
    ## `nim c --run` (no --compileOnly) compiles, links, AND runs
    ## successfully. This is a real, deterministic, cache-path-only failure:
    ## it fails inside runMeasured's FIRST phase (driver.compileOnly), before
    ## any objcache/keyOf logic ever runs, and does NOT depend on sabotaging
    ## any path shared with the monolithic fallback.
    let workDir = freshWorkDir("escape")
    defer: removeDir(workDir)
    var plan = buildPassAlwaysPlan(workDir)
    plan.flags = @["--run"]
    let planPath = writePlan(plan, workDir / "plan.json")

    let code = runCompileCacheWorker(planPath)
    check code == 0   # the escape hatch rescued the build

    check fileExists(plan.outputBinPath)
    let (_, exitCode) = execCmdEx(plan.outputBinPath)
    check exitCode == 0   # pass_always.nim is literally `quit(0)`

    # The cache path never got far enough to store anything (it failed at
    # compileOnly, before any unit was ever compiled or keyed).
    let keys = objcacheKeys(plan.stateDir)
    check keys.len == 0

# ===========================================================================
# Behavior 5 — the entry unit stays private
# ===========================================================================

suite "runCompileCacheWorker — the entry unit stays private (real cache run, pass_always fixture)":

  test "objcache stores EXACTLY the reusable-set count of objects; the entry unit is never among them":
    let workDir = freshWorkDir("private")
    defer: removeDir(workDir)
    let plan = buildPassAlwaysPlan(workDir)
    let planPath = writePlan(plan, workDir / "plan.json")

    let code = runCompileCacheWorker(planPath)
    check code == 0
    check fileExists(plan.outputBinPath)

    let manifestPath = plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json"
    let manifest = parseCompileManifest(manifestPath)
    let entryBasename = "@mpass_always.nim.c"

    var expectedReusable = 0
    for pair in manifest.compile:
      if pair.cPath.extractFilename != entryBasename:
        inc expectedReusable
    check expectedReusable == 4   # pinned by test_compiledriver_real.nim's own probe of this fixture

    let keys = objcacheKeys(plan.stateDir)
    check keys.len == expectedReusable   # NOT expectedReusable + 1 (would mean the entry leaked in)

# ===========================================================================
# Behavior R16 (R9-revert) — a cache-mode run writes ObjCacheStatsRows
# (realized hitRate) but NEVER ArtifactRows (potential rTime). R9 had the
# cache worker also emit ArtifactRows so a SINGLE `--objcache` run could
# populate both sides of the M-report's drift comparison; R16 found that a
# cache HIT does no compilation, so its ArtifactRow recorded `ccTimeUs=0` —
# skewing the cc-time-weighted potential-rTime and permanently polluting the
# append-only artifact ledger (it is scanned cumulatively across all future
# runs, so the pollution never self-heals). The fix is to revert: the
# artifact ledger stays a MEASURE-worker-only stream (`runMeasureCompileWorker`
# / `recordArtifactRows`), and the drift comparison becomes a CROSS-RUN
# correlation instead — a measure-mode run's `compile.segments[].rTime`
# against a later cache-mode run's `compile.objcache.segments[].hitRate`,
# joined by (groupId, configHash). See compilereport.nim's module doc
# ("Drift tie-in") for the reworded, honest framing.
# ===========================================================================

suite "runCompileCacheWorker — R16: cache-mode compiles write ObjCacheStatsRows but NEVER ArtifactRows":

  test "ep_a then ep_b against the SAME stateDir: objcache-stats rows exist for both identities; the artifact ledger stays EMPTY":
    let workDir = freshWorkDir("r16")
    defer: removeDir(workDir)
    let stateDir = workDir / "state"

    let planA = buildGoldenPlan(workDir, "ep_a", stateDir)
    let planB = buildGoldenPlan(workDir, "ep_b", stateDir)

    let codeA = runCompileCacheWorker(writePlan(planA, workDir / "plan_a.json"))
    check codeA == 0
    let codeB = runCompileCacheWorker(writePlan(planB, workDir / "plan_b.json"))
    check codeB == 0

    let artifactRows = scanArtifactLedger(stateDir)
    let statsRows     = scanObjCacheStatsLedger(stateDir)

    # R16: the cache worker must NEVER write to the artifact ledger — that
    # stream stays measure-worker-only (recordArtifactRows is called ONLY
    # from runMeasureCompileWorker after this revert).
    check artifactRows.len == 0
    check statsRows.len == 2

    let identA = identityKey(planA.entrypointPath, planA.configHash)
    let identB = identityKey(planB.entrypointPath, planB.configHash)

    var statsIdentities: HashSet[string]
    for r in statsRows: statsIdentities.incl $r.entrypointIdentity
    check $identA in statsIdentities
    check $identB in statsIdentities

when isMainModule:
  echo "All compileworker real-worker tests passed."
