## test_closure_record_failure.nim — issue #5 (writer hole): a compile that
## SUCCEEDS but whose closure cannot be recorded must not leave the previous
## depgraph entry in place.
##
## The stable binary is copied before the closure is extracted, so if
## extraction fails and the runner merely swallows the error, nothing
## recompiles next run and the PREVIOUS entry — arbitrarily stale — keeps
## being served as fresh. A reader cannot tell that entry from a valid one.
##
## Issue #13.3 (D5) strengthened this further: the runner now also discards
## the stable binary it just promoted whenever `recordClosure` reports
## `not ok`, for either failure mode (extraction failure here, or a
## depgraph persist failure) — so the invariant is "either the on-disk
## depgraph entry matches the stable binary, or there is no stable binary",
## never a binary the depgraph does not describe. The first test below
## reflects that: after the recording failure, the next plan is
## `edNeverBuilt` (no binary at all), not merely `edStale` (binary present,
## entry missing).
##
## Real-compile drive through execute(). The recording failure is induced the
## one way it can arise without a mock: the entrypoint lives OUTSIDE every
## tracked root, so its extracted closure is empty and updateEntry refuses it
## (cekInternal). The graph is pre-seeded with a fresh-looking entry for the
## same key — exactly what the old `except: discard` would have preserved.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_closure_record_failure.nim

import std/[options, os, sets, tables, times, unittest]
import std/posix as posix_mod
import crisol/[types, runner, depgraph, planner, sandbox, cachedispatch, resultcache]

proc fixtureDir(): string =
  currentSourcePath().parentDir.parentDir / "fixtures"

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_closure_record_" & tag & "_" &
                           $posix_mod.getpid() & "_" &
                           $int64(epochTime() * 1_000_000))
  createDir(result)

proc makeCfg(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
         timeoutSecs: 60, compileTimeoutSecs: 120, maxOutputBytes: 65_536)

suite "closure recording failure after a successful compile (issue #5)":

  test "the previous entry is invalidated, so the next plan recompiles":
    let root = makeTempRoot("invalidate")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    # Entrypoint OUTSIDE projectRoot (and no depRoots): its closure filters
    # to the empty set, which updateEntry refuses.
    let ep    = Entrypoint(path: fixtureDir() / "pass_always.nim",
                           group: "default", flags: @[])
    let fHash = flagHash(ep.flags)
    let key   = (ep.path, fHash)

    # Seed a FRESH-looking prior entry: an existing file, its current content
    # hash, current protocol major. Under the old writer this entry survived
    # the failed recording and made run 2 cdSkipFresh.
    var graph = initDepGraph("")
    let seededClosure = toHashSet([ep.path])
    graph.updateEntry(ep.path, fHash, seededClosure,
                      closureContentHash(@[ep.path], root), CrisolProtocolMajor)
    createDir(root / ".crisol")
    doAssert saveDepGraph(graph, cfg)

    let plan1 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan1.entrypoints[0].edecision == edNeverBuilt
    let r1 = execute(plan1, config = cfg, graph = graph,
                     nimVersion = "", showProgress = false)
    check r1.len == 1
    check r1[0].outcome == oPassed            # compile + run succeeded

    # Recording failed → the seeded entry must be GONE, in memory and on disk.
    check key notin graph.entries
    check key notin loadDepGraph(cfg, "").entries

    # And the next plan must recompile rather than trust the stale entry.
    # Issue #13.3 (D5) broadened the runner's recovery: on ANY recordClosure
    # failure (not only a persist failure) the stable binary just promoted
    # this run is discarded too, so no binary describes this key at all —
    # the next plan sees edNeverBuilt, not edStale ("no closure record" only
    # applies when a binary exists but no entry backs it).
    let plan2 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan2.entrypoints[0].edecision == edNeverBuilt
    check plan2.entrypoints[0].reason == "binary absent (first run or cache cleared)"

# ---------------------------------------------------------------------------
# R9: a result whose closure was NOT recorded must NOT be stored in the
# result cache either — a dead entry (closureContentHash "") that a later
# lookup could never find (lookup needs edRunFresh, which needs an entry).
# ---------------------------------------------------------------------------

type MockCacheState = ref object
  storeCalls: int

proc mockStoreOnlySeams(ms: MockCacheState): CacheSeams =
  ## keyOf/load are never expected to be hit by this scenario (edNeverBuilt
  ## is not plan-time cache-eligible); store is the seam under test.
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): SoundnessKey =
             SoundnessKey("mk-" & pep.ep.path),
    load:  proc(key: SoundnessKey): Option[CachedResult] = none(CachedResult),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             inc ms.storeCalls; true,
  )

suite "closure recording failure blocks the result-cache store (issue #5, R9)":

  test "with caching ACTIVE, a failed closure recording must not store a dead entry":
    let root = makeTempRoot("nostorewithcache")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    # Same out-of-root scenario as above: closure recording fails.
    let ep = Entrypoint(path: fixtureDir() / "pass_always.nim",
                        group: "default", flags: @[])
    var graph = initDepGraph("")
    createDir(root / ".crisol")
    doAssert saveDepGraph(graph, cfg)

    let plan1 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan1.entrypoints[0].edecision == edNeverBuilt

    let ms = MockCacheState()
    let cache = cacheEnabled(resolveSandbox(hlIsolated), defaultCachePolicy(),
                             mockStoreOnlySeams(ms))
    let r1 = execute(plan1, config = cfg, graph = graph,
                     nimVersion = "", showProgress = false, cache = cache)

    check r1.len == 1
    check r1[0].outcome == oPassed          # compile + run still succeeded

    # The store seam must NEVER have been called: a passing run whose
    # closure could not be recorded must not be written to the cache.
    check ms.storeCalls == 0
    # And the live result must be stamped with the dedicated variant so a
    # `--json` reader can tell WHY the store didn't happen (R9).
    check r1[0].cacheDecision == cdmClosureUnrecorded
    check not r1[0].cached
