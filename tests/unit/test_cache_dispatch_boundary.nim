## test_cache_dispatch_boundary.nim — A6: cache dispatch wiring through execute().
##
## Drives the REAL execute() poll-loop with MOCKED cache seams to prove the
## plan-time dispatch behavior, end to end, without touching the on-disk cache:
##
##   1. HIT  — an edRunFresh entrypoint whose mock cache has an entry is served
##             from cache: NO process is spawned (the binary path is bogus — a
##             live spawn would surface oSpawnError), the synthesized result is
##             returned in plan order, its ResultCallback fires, and the result
##             carries cached=true / cdmHit / the historical duration.
##   2. ADMISSION BYPASS — the cached entry occupies no slot: with jobs=1 and a
##             cached entry FIRST, a live miss SECOND still runs (the cached one
##             never held the single slot).
##   3. MISS + STORE — an edRunFresh miss on a real passing fixture runs live and
##             the store seam is invoked exactly once (gated on pass+achieved+attempt1).
##   4. NO-CACHE — empty seams (keyOf==nil): the entry runs live, store never called.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cache_dispatch_boundary.nim

import std/[options, os, tables, unittest]
import crisol/[types, runner, planner, depgraph, sandbox, cachedispatch, resultcache]
import crisol/process/types as ptypes
import "../support/helpers"  # legacySeams

# ---------------------------------------------------------------------------
# Mock seam construction
# ---------------------------------------------------------------------------

type MockState = ref object
  store: Table[string, CachedResult]   # key string → cached
  storeCalls: int
  loadCalls:  int

proc mockSeams(ms: MockState): CacheSeams =
  legacySeams(
    keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
             SoundnessKey("mk-" & pep.ep.path),
    load = proc(key: SoundnessKey): Option[CachedResult] =
             inc ms.loadCalls
             if ($key) in ms.store: some(ms.store[$key])
             else: none(CachedResult),
    store = proc(key: SoundnessKey; res: CachedResult): bool =
             inc ms.storeCalls
             ms.store[$key] = res
             true,
  )

proc cachedPass(durationMs: int64): CachedResult =
  CachedResult(
    run: ptypes.ProcessResult(
      exit:  ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: default(ptypes.Evidence),
      rusage: none(ptypes.Rusage),
      durationUs: durationMs * 1000,
    ),
    records: @[], cachedAt: 1_700_000_000'i64)

proc plannedFresh(path: string): PlannedEntrypoint =
  ## An edRunFresh planned entrypoint (binary fresh; eligible for cache).
  PlannedEntrypoint(
    ep:        Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: edRunFresh,
    runTimeoutMs: 30_000,
  )

let isoSpec = resolveSandbox(hlIsolated)

# ---------------------------------------------------------------------------
# 1. HIT — served from cache, no spawn
# ---------------------------------------------------------------------------

suite "execute — cache HIT served at plan time":

  test "edRunFresh hit → synthesized result, no spawn, callback fired":
    let ms = MockState(store: initTable[string, CachedResult]())
    # Seed the cache for the bogus-binary entrypoint.
    ms.store["mk-tests/unit/test_bogus.nim"] = cachedPass(9999)

    let pep = plannedFresh("tests/unit/test_bogus.nim")
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    var fired: seq[EntrypointResult]
    let cb = proc(r: EntrypointResult) {.closure.} = fired.add r

    let results = execute(
      p, config = Config(projectRoot: getTempDir()), graph = g,
      onResult = cb, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms)))

    check results.len == 1
    check results[0].outcome == oPassed         # NOT oSpawnError → never spawned the bogus bin
    check results[0].cached
    check results[0].cacheDecision == cdmHit
    check results[0].durationMs == 9999          # historical
    check fired.len == 1                          # callback fired exactly once
    check fired[0].cached
    check ms.storeCalls == 0                       # a hit never stores

# ---------------------------------------------------------------------------
# 2. ADMISSION BYPASS — cached entry holds no slot
# ---------------------------------------------------------------------------

suite "execute — cached entry bypasses admission":

  test "jobs=1, cached FIRST + live-miss SECOND: both produced":
    # The cached entry must NOT consume the single live slot.  If it did, and a
    # live miss were also dispatched, we'd deadlock / mis-order.  We use a real
    # passing fixture for the live second entry.
    let dir = getTempDir() / "crisol_a6_bypass"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_live.nim"
    writeFile(fixt, "quit(0)\n")

    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-cached_entry.nim"] = cachedPass(111)

    let cachedPep = plannedFresh("cached_entry.nim")
    # The live entry is edNeverBuilt so it compiles+runs the real fixture.
    let livePep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)

    let p = RunPlan(entrypoints: @[cachedPep, livePep], jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms)))

    check results.len == 2
    check results[0].cached                        # index 0: served from cache
    check results[0].cacheDecision == cdmHit
    check results[1].outcome == oPassed            # index 1: ran live and passed
    check not results[1].cached

# ---------------------------------------------------------------------------
# 3. MISS + STORE — live run, store seam invoked once
# ---------------------------------------------------------------------------

suite "execute — cache MISS stores on attempt-1 pass":

  test "edRunFresh miss on a real fixture → live run + store called once":
    let dir = getTempDir() / "crisol_a6_miss"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let ms = MockState(store: initTable[string, CachedResult]())
    # edNeverBuilt so the binary is actually built+run; we mock the seam so the
    # store gate fires.  (edRunFresh would need a pre-built binary.)
    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms)))

    check results.len == 1
    check results[0].outcome == oPassed
    check not results[0].cached
    # A real isolated run on this host should achieve hermeticity → stored once.
    check ms.storeCalls == 1
    check ms.loadCalls == 0     # edNeverBuilt is not eligible for plan-time lookup

# ---------------------------------------------------------------------------
# 4. NO-CACHE — empty seams: live run, never stores
# ---------------------------------------------------------------------------

suite "execute — no-cache full bypass":

  test "empty seams (keyOf==nil): runs live, store never called":
    let dir = getTempDir() / "crisol_a6_nocache"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheDisabled(isoSpec))

    check results.len == 1
    check results[0].outcome == oPassed
    check not results[0].cached
    check results[0].cacheDecision == cdmNotEligible

# ---------------------------------------------------------------------------
# 5. DEGRADED HERMETICITY — not cached
# ---------------------------------------------------------------------------

suite "execute — degraded hermeticity blocks the store":

  test "hlNetwork (netIso never wired) → achieved != requested → store NOT called":
    let dir = getTempDir() / "crisol_a6_degraded"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let ms = MockState(store: initTable[string, CachedResult]())
    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    # hlNetwork requests netIso, but unshare(CLONE_NEWNET) is not wired in spawn,
    # so evidenceSatisfies is false → the cache-store gate blocks the write.
    let netSpec = resolveSandbox(hlNetwork)
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(netSpec, defaultCachePolicy(), mockSeams(ms)))

    check results.len == 1
    check results[0].outcome == oPassed
    check ms.storeCalls == 0                           # degraded ⇒ NOT stored
    check results[0].cacheDecision == cdmHermeticityDeg

# ---------------------------------------------------------------------------
# R2-1: no-cache discrimination — cdmPolicyDisabled vs cdmNotEligible
# ---------------------------------------------------------------------------
## When caching is DISABLED (cacheDisabled spec), the per-result cacheDecision
## must distinguish:
##   edRunFresh  → cdmPolicyDisabled  (would have been cache-eligible but suppressed)
##   edNeverBuilt/edStale → cdmNotEligible (had to be compiled; caching never applied)
##
## Before the R2-1 fix both branches returned cdmNotEligible (degenerate if/else).

suite "R2-1 — no-cache cacheDecision discrimination":

  test "cacheDisabled + edNeverBuilt → cdmNotEligible (compiled, cache never applicable)":
    ## edNeverBuilt must compile+run; cache was never consulted → notEligible.
    ## This already passed before the fix (both branches were notEligible), but
    ## we keep it to anchor the negative case.
    let dir = getTempDir() / "crisol_r21_neverblt"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheDisabled(isoSpec))

    check results.len == 1
    check results[0].cacheDecision == cdmNotEligible

  test "cacheDisabled + edRunFresh → cdmPolicyDisabled (binary ready; policy suppressed cache)":
    ## An edRunFresh entry already has its binary built — it was cache-eligible but
    ## --no-cache suppressed the lookup.  Must report cdmPolicyDisabled, not notEligible.
    ## The binary for a bogus path is never spawned because cacheDisabled hits the
    ## early-continue branch that sets cacheDecision WITHOUT running the entrypoint.
    ## However, with cacheDisabled the edRunFresh entry DOES get dispatched (run-only).
    ## We need a real binary: create a one-shot script fixture and use edRunFresh.
    ## Strategy: write the binary manually (tiny ELF via a nim compile inside dev).
    ## Simpler: construct a RunPlan directly with edRunFresh pointing at a pre-compiled
    ## pass_always binary, i.e. re-use the fixtures dir's compiled binary.
    ##
    ## Cleanest approach: run pass_always via edNeverBuilt first (to compile), then
    ## build a second plan with edRunFresh pointing at the known binary path so it
    ## runs without recompiling, under cacheDisabled.  Uses Config.projectRoot + stateDir
    ## to derive the stable binPath.
    let dir  = getTempDir() / "crisol_r21_runfresh"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    ## Step 1: compile+run via edNeverBuilt so the stable binary is in place.
    let cfg = Config(projectRoot: dir, stateDir: ".crisol",
                     compileTimeoutSecs: 120, timeoutSecs: 60)
    let pep0 = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p0 = RunPlan(entrypoints: @[pep0], jobs: 1)
    var g0 = emptyDepGraph()
    discard execute(p0, config = cfg, graph = g0,
                    showProgress = false, cache = cacheDisabled(isoSpec))

    ## Step 2: re-plan with the same entrypoint; plan() will see the binary exists
    ## and emit edRunFresh (or edSkipFresh).  We manually force edRunFresh to be
    ## explicit about the decision under test, using the stable binPath.
    let pep1 = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edRunFresh, runTimeoutMs: 60_000)
    let p1 = RunPlan(entrypoints: @[pep1], jobs: 1)
    var g1 = emptyDepGraph()
    let results = execute(p1, config = cfg, graph = g1,
                          showProgress = false, cache = cacheDisabled(isoSpec))

    check results.len == 1
    check results[0].outcome == oPassed
    # R2-1: this was cdmNotEligible before the fix; must be cdmPolicyDisabled after.
    check results[0].cacheDecision == cdmPolicyDisabled

echo "test_cache_dispatch_boundary: done"
