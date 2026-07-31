## test_nimcache_persistence_real.nim — RFC-0006 nimcache-persistence lever:
## real-compile invariants over execute().
##
## The bug (memory: nimcache-persistence-lever / RFC-0006 handoff): runner.nim
## used to suffix the nimcache dir with the entrypoint's POSITION in the plan
## (`_<pepIdx>`), so a `--changed`/subset run (where the affected set shifts
## run-to-run) gave the SAME entrypoint a DIFFERENT nimcache dir every time,
## forcing a cold recompile even though Nim's own incremental compiler would
## otherwise have reused it. The fix: `cachePath(ep, config, toolchainFp)` is
## a pure function of (ep.path, ep.flags, toolchainFp) — never of plan
## position — and the dir is never wiped on a successful (or run-phase-
## failed) compile, only on an actual compile failure/timeout.
##
## This file proves, with REAL `nim c` invocations (no synthetic driver):
##   1. Reuse: the persistent cache dir survives a forced recompile untouched
##      (a planted marker file survives) and is genuinely populated.
##   2. Soundness: a toolchain-fingerprint change lands on a DIFFERENT, cold
##      cache dir; the old dir (and its marker) is never read or touched.
##   3. Stability across plan position: the SAME entrypoint gets the SAME
##      cache dir whether it is the only entry in a 1-entry plan or the 2nd
##      entry in a 2-entry plan (the concrete `--changed` bug, reproduced end
##      to end through execute(), not just at the pure planner level).
##
## Each test uses its own FRESH temp stateDir (never shared).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_nimcache_persistence_real.nim

import std/[os, strutils, times, unittest]
import std/posix as posix_mod
import crisol/[types, runner]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc makeTempRoot(tag: string): string =
  let tmp = getTempDir() / ("crisol_nimcache_persist_" & tag & "_" &
                            $posix_mod.getpid() & "_" &
                            $int64(epochTime() * 1_000_000))
  createDir(tmp)
  tmp

proc makeCfg(root: string): Config =
  Config(
    projectRoot:        root,
    stateDir:           ".crisol",
    jobs:               1,
    timeoutSecs:        60,
    compileTimeoutSecs: 120,
    maxOutputBytes:     65_536,
  )

proc epFor(path: string): Entrypoint =
  Entrypoint(path: path, group: "default", flags: @[])

proc countCFiles(dir: string): int =
  if not dirExists(dir): return 0
  for path in walkDirRec(dir):
    if path.endsWith(".c"):
      inc result

# ---------------------------------------------------------------------------
# Suite 1 — reuse
# ---------------------------------------------------------------------------

suite "nimcache-persistence — REUSE (real compile)":

  test "persistent cache dir survives a forced recompile, untouched and populated":
    let root = makeTempRoot("reuse")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    let ep  = epFor(fixtureDir() / "pass_always.nim")

    let toolchainFp = toolchainFingerprint("nim-test-v1", "cc-test-v1")
    let expectedCacheDir = cachePath(ep, cfg, toolchainFp)

    var graph = emptyDepGraph()
    let plan1 = plan(cfg, @[ep], graph, nimVersion = "nim-test-v1")
    check plan1.entrypoints[0].edecision == edNeverBuilt

    let results1 = execute(plan1, config = cfg, graph = graph,
                           nimVersion = "nim-test-v1", ccVersion = "cc-test-v1",
                           showProgress = false)
    check results1.len == 1
    check results1[0].outcome == oPassed

    # The stable, toolchain-keyed dir must exist and be genuinely populated
    # (real Nim codegen output — at least one .c file), not just an empty
    # directory left behind by createDir.
    check dirExists(expectedCacheDir)
    check countCFiles(expectedCacheDir) > 0

    # Plant a marker: if the next compile wipes-and-recreates this directory
    # (the old volatile-suffix behavior would have used a DIFFERENT dir every
    # run, so this marker would never even be at risk), the marker is gone.
    let markerPath = expectedCacheDir / "crisol_test_marker.txt"
    writeFile(markerPath, "persisted-from-run-1")

    # Force a second real compile of the SAME entrypoint into the SAME
    # (unchanged) stable path.
    let plan2 = plan(cfg, @[ep], graph, nimVersion = "nim-test-v1",
                     forceCompile = true)
    check plan2.entrypoints[0].edecision == edStale

    let results2 = execute(plan2, config = cfg, graph = graph,
                           nimVersion = "nim-test-v1", ccVersion = "cc-test-v1",
                           showProgress = false)
    check results2.len == 1
    check results2[0].outcome == oPassed

    # REUSE proof: same dir, still exists, marker survived (never wiped on
    # success), and it is still populated with real compiled output.
    check dirExists(expectedCacheDir)
    check fileExists(markerPath)
    check countCFiles(expectedCacheDir) > 0

# ---------------------------------------------------------------------------
# Suite 2 — soundness
# ---------------------------------------------------------------------------

suite "nimcache-persistence — SOUNDNESS (toolchain change ⇒ cold, no stale reuse)":

  test "a toolchain-fingerprint change lands on a fresh dir; the old dir is never read":
    let root = makeTempRoot("soundness")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    let ep  = epFor(fixtureDir() / "pass_always.nim")

    let oldCacheDir = cachePath(ep, cfg, toolchainFingerprint("nim-v1", "cc-OLD"))
    let newCacheDir = cachePath(ep, cfg, toolchainFingerprint("nim-v1", "cc-NEW"))
    check oldCacheDir != newCacheDir  ## precondition: the fingerprint really changes the path

    var graph = emptyDepGraph()
    let plan1 = plan(cfg, @[ep], graph, nimVersion = "nim-v1")
    let results1 = execute(plan1, config = cfg, graph = graph,
                           nimVersion = "nim-v1", ccVersion = "cc-OLD",
                           showProgress = false)
    check results1[0].outcome == oPassed
    check dirExists(oldCacheDir)

    # Sentinel marks this as "the old toolchain's object". If the new
    # (post-upgrade) compile ever reused this directory or its contents,
    # the sentinel would be visible from the new dir's perspective too —
    # it is not, because the two dirs are disjoint by construction.
    let sentinelPath = oldCacheDir / "SENTINEL_OLD_TOOLCHAIN.marker"
    writeFile(sentinelPath, "built-by-cc-OLD")

    # Simulate a toolchain upgrade: same source, same nimVersion, DIFFERENT
    # ccVersion. Force the recompile (decideCompile does not itself gate on
    # ccVersion — the nimcache-persistence fix's job is only to make sure a
    # compile that DOES happen under a new toolchain never reuses the old
    # object; the compile-skip decision is orthogonal and untouched here).
    let plan2 = plan(cfg, @[ep], graph, nimVersion = "nim-v1", forceCompile = true)
    let results2 = execute(plan2, config = cfg, graph = graph,
                           nimVersion = "nim-v1", ccVersion = "cc-NEW",
                           showProgress = false)
    check results2[0].outcome == oPassed

    # The new compile used a DIFFERENT, COLD directory:
    check dirExists(newCacheDir)
    check countCFiles(newCacheDir) > 0
    # ...and never touched/read the old one:
    check fileExists(sentinelPath)              ## old dir + sentinel untouched
    check not fileExists(newCacheDir / "SENTINEL_OLD_TOOLCHAIN.marker")

# ---------------------------------------------------------------------------
# Suite 3 — stable across plan position (the concrete --changed bug)
# ---------------------------------------------------------------------------

suite "nimcache-persistence — STABLE ACROSS PLAN POSITION (the --changed fix)":

  test "same entrypoint gets the SAME cache dir at index 0 of 1 and index 1 of 2":
    let root = makeTempRoot("position")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    let ep     = epFor(fixtureDir() / "pass_always.nim")
    let decoy  = epFor(fixtureDir() / "env_probe.nim")

    let toolchainFp = toolchainFingerprint("nim-v1", "cc-v1")
    let expectedCacheDir = cachePath(ep, cfg, toolchainFp)

    var graph = emptyDepGraph()

    # Run 1: `ep` alone — position 0 of a 1-entry plan (mimics a `--changed`
    # run that narrows to just this entrypoint).
    let planA = plan(cfg, @[ep], graph, nimVersion = "nim-v1")
    let resultsA = execute(planA, config = cfg, graph = graph,
                           nimVersion = "nim-v1", ccVersion = "cc-v1",
                           showProgress = false)
    check resultsA[0].outcome == oPassed
    check dirExists(expectedCacheDir)

    let markerPath = expectedCacheDir / "crisol_test_position_marker.txt"
    writeFile(markerPath, "written-at-position-0-of-1")

    # Run 2: `ep` is now the SECOND entry (position 1) of a 2-entry plan
    # (mimics a full-suite run, or a differently-narrowed `--changed` set,
    # where this same entrypoint lands at a different index). Force the
    # recompile so spawnCompileStable actually runs again for `ep`.
    let planB = plan(cfg, @[decoy, ep], graph, nimVersion = "nim-v1",
                     forceCompile = true)
    check planB.entrypoints[1].ep.path == ep.path
    let resultsB = execute(planB, config = cfg, graph = graph,
                           nimVersion = "nim-v1", ccVersion = "cc-v1",
                           showProgress = false)
    check resultsB.len == 2
    check resultsB[1].outcome == oPassed  # ep's result, at its plan index (1)

    # THE INVARIANT: identical cache dir, and the run-1 marker survived —
    # proving `ep` was compiled into the SAME persistent directory both
    # times despite occupying a different plan position.
    check dirExists(expectedCacheDir)
    check fileExists(markerPath)

# ---------------------------------------------------------------------------
# Suite 4 — a FAILED compile does not persist a corrupt cache
# ---------------------------------------------------------------------------

suite "nimcache-persistence — a failed compile does not leave a corrupt persisted dir":

  test "oCompileFailed still wipes its (would-be-persistent) cache dir":
    ## Persistence must not come at the cost of the pre-existing M15
    ## guarantee: a compile that actually FAILS must not leave partial/
    ## corrupt output behind under the stable path for a future run to
    ## stumble over.
    let root = makeTempRoot("compilefail")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    let ep  = epFor(fixtureDir() / "fail_compile.nim")

    let toolchainFp = toolchainFingerprint("nim-v1", "cc-v1")
    let expectedCacheDir = cachePath(ep, cfg, toolchainFp)

    var graph = emptyDepGraph()
    let planA = plan(cfg, @[ep], graph, nimVersion = "nim-v1")
    let resultsA = execute(planA, config = cfg, graph = graph,
                           nimVersion = "nim-v1", ccVersion = "cc-v1",
                           showProgress = false)
    check resultsA[0].outcome == oCompileFailed
    check not dirExists(expectedCacheDir)  ## M15: wiped on genuine compile failure

# ---------------------------------------------------------------------------
# Suite 5 — rare concurrent-duplicate (same entrypoint twice in one plan)
# ---------------------------------------------------------------------------

suite "nimcache-persistence — rare same-entrypoint-twice-in-plan duplicate":

  test "a duplicated (path, flags) entry in one plan compiles both copies without racing":
    ## discover() can legitimately place the same file in two groups with
    ## identical flags (cross-group dedup only applies WITHIN a group), so a
    ## plan CAN contain two entries with the same slug. The stable-path fix
    ## must not let two concurrent slots race on writing the SAME persistent
    ## nimcache dir — duplicateSlugs() detects this and spawnCompileStable
    ## falls back to the old volatile pepIdx-suffixed dir for JUST this slug.
    let root = makeTempRoot("dup")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    var cfg2Jobs = cfg
    cfg2Jobs.jobs = 2  ## give both copies a real chance to run concurrently
    let ep  = epFor(fixtureDir() / "pass_always.nim")

    var graph = emptyDepGraph()
    # Build the plan directly with two identical entries — bypassing
    # discover()'s within-group dedup to exercise the rare cross-group
    # duplicate shape end to end.
    let planDup = plan(cfg2Jobs, @[ep, ep], graph, nimVersion = "nim-v1")
    check planDup.entrypoints.len == 2

    let results = execute(planDup, config = cfg2Jobs, graph = graph,
                          nimVersion = "nim-v1", ccVersion = "cc-v1",
                          showProgress = false)
    check results.len == 2
    check results[0].outcome == oPassed
    check results[1].outcome == oPassed

when isMainModule:
  echo "nimcache-persistence real-compile invariants done."
