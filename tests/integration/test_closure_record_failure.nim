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
## RFC-0009 A-final-ii-a (R3b): the recording failure is injected via
## `execute()`'s `recordClosureFn` seam (`runner.RecordClosureProc`) rather
## than by building an Entrypoint OUTSIDE every tracked root. Production
## entrypoints are ALWAYS tag-0 (`discover` never emits one outside the
## project root — an outside path surfaces only via `adHocPaths`, never as
## a real `Entrypoint`; the `pcOutside` arm downstream is defensive/
## unreachable), so the outside-root shape this test used to build to force
## an empty extracted closure was never a real production shape. A VALID
## tag-0 entrypoint drives the fault at its true boundary — recordClosure's
## returned `(ok: false, ...)` — portable across every leg, no outside-root
## Entrypoint required.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_closure_record_failure.nim

import std/[options, os, sets, tables, times, unittest]
import crisol/[types, runner, depgraph, planner, sandbox, cachedispatch, resultcache, closure, ccprobe]
import "../support/helpers"  # legacySeams
import "../support/testep"

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_closure_record_" & tag & "_" &
                           $getCurrentProcessId() & "_" &
                           $int64(epochTime() * 1_000_000))
  createDir(result)

proc makeCfg(root: string): Config =
  result = Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
         timeoutSecs: 60, compileTimeoutSecs: 120, maxOutputBytes: 65_536)
  # trackedRoots MUST match projectRoot (real production configs always
  # build both from the same root).
  result.trackedRoots = initTrackedRoots(root, @[], "")

proc failingRecordClosure(graph: var DepGraph; config: Config; ep: Entrypoint;
                          nimcacheDir, binaryName: string;
                          protocolMajor: int; index: SourceIndex;
                          ccRun: RunProc): tuple[ok: bool, error: string] =
  ## R3a/R3b seam injection: the compile always succeeds (it's a real
  ## `pass_always.nim` compile+run under the tracked project root); this
  ## proc is substituted for the real `depgraph.recordClosure` via
  ## `execute()`'s `recordClosureFn` param so the POST-compile recording
  ## step fails deterministically, exercising issue #5/#13.3's recovery
  ## policy without any outside-root Entrypoint.
  ##
  ## Mirrors the real `recordClosure`'s `except CatchableError` branch
  ## (invalidate + persist the graph on a recording failure) — that
  ## invalidation is `recordClosure`'s OWN responsibility, not the
  ## runner's (the runner only reads `closureRecorded`/`closureError`
  ## back off the slot to decide the stable-binary discard, issue #13.3
  ## D5), so a substitute seam must replicate it to keep the "either the
  ## on-disk entry matches the stable binary, or there is no stable
  ## binary" invariant this test exercises.
  let fHash = flagHash(ep.flags)
  graph.invalidateEntry(string(ep.tp.display()), fHash)
  discard saveDepGraph(graph, config)
  (false, "injected recording failure")

suite "closure recording failure after a successful compile (issue #5)":

  test "the previous entry is invalidated, so the next plan recompiles":
    let root = makeTempRoot("invalidate")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    let epNative = root / "pass_always.nim"
    writeFile(epNative, "quit(0)\n")
    # A VALID tag-0 entrypoint under the tracked project root (R3b) — the
    # injected `recordClosureFn` seam (below) drives the fault, not an
    # outside-root Entrypoint (unreachable in production; see module doc).
    let ep    = testEp("pass_always.nim", group = "default", flags = @[])
    check ep.tp.display().len > 0   # sanity: a real tag-0 tp, not the defensive zero value
    let fHash = flagHash(ep.flags)
    let key   = (string(ep.tp.display()), fHash)

    # Seed a FRESH-looking prior entry: an existing file, its current content
    # hash, current protocol major. Under the old writer this entry survived
    # the failed recording and made run 2 cdSkipFresh.
    var graph = initDepGraph("")
    # RFC-0009 A3c-ii: `DepGraphEntry.closure` is `HashSet[TrackedPath]` --
    # this closure is pure bait (a fresh-looking prior entry the retry must
    # discard), never read back for content, so it just needs to be SOME
    # non-empty TrackedPath under the tracked project root.
    let seededClosure = [fromCanonical("bait.nim", cfg.trackedRoots).get].toHashSet
    graph.updateEntry(string(ep.tp.display()), fHash, seededClosure,
                      closureContentHash(@[(key: string(ep.tp.display()), nativePath: epNative)]),
                      CrisolProtocolMajor)
    createDir(root / ".crisol")
    doAssert saveDepGraph(graph, cfg)

    let plan1 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan1.entrypoints[0].edecision == edNeverBuilt
    let r1 = execute(plan1, config = cfg, graph = graph,
                     nimVersion = "", showProgress = false,
                     recordClosureFn = failingRecordClosure).results
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
  legacySeams(
    keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
             SoundnessKey("mk-" & string(pep.ep.tp.display())),
    load = proc(key: SoundnessKey): Option[CachedResult] = none(CachedResult),
    store = proc(key: SoundnessKey; res: CachedResult): bool =
             inc ms.storeCalls; true,
  )

suite "closure recording failure blocks the result-cache store (issue #5, R9)":

  test "with caching ACTIVE, a failed closure recording must not store a dead entry":
    let root = makeTempRoot("nostorewithcache")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    writeFile(root / "pass_always.nim", "quit(0)\n")
    # Same VALID tag-0 entrypoint shape as above: closure recording fails
    # via the injected `recordClosureFn` seam, not an outside-root path.
    let ep = testEp("pass_always.nim", group = "default", flags = @[])
    check ep.tp.display().len > 0
    var graph = initDepGraph("")
    createDir(root / ".crisol")
    doAssert saveDepGraph(graph, cfg)

    let plan1 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan1.entrypoints[0].edecision == edNeverBuilt

    let ms = MockCacheState()
    let cache = cacheEnabled(resolveSandbox(hlIsolated), defaultCachePolicy(),
                             mockStoreOnlySeams(ms))
    let r1 = execute(plan1, config = cfg, graph = graph,
                     nimVersion = "", showProgress = false, cache = cache,
                     recordClosureFn = failingRecordClosure).results

    check r1.len == 1
    check r1[0].outcome == oPassed          # compile + run still succeeded

    # The store seam must NEVER have been called: a passing run whose
    # closure could not be recorded must not be written to the cache.
    check ms.storeCalls == 0
    # And the live result must be stamped with the dedicated variant so a
    # `--json` reader can tell WHY the store didn't happen (R9).
    check r1[0].cacheDecision == cdmClosureUnrecorded
    check not r1[0].cached
