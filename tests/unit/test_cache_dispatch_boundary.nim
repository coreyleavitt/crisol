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

proc cachedPassWithEscapees(durationMs: int64): CachedResult =
  ## RFC-0005 SO1: a stored entry whose payload evidence carries an OBSERVED
  ## escapee -- exactly the shape `cachetier`'s populate-on-hit backfill can
  ## re-store verbatim from a foreign/remote tier (it never re-runs
  ## `shouldStore`), even though the LOCAL publish gate could never have
  ## produced one itself (`evidenceSatisfies` would have refused it at
  ## store time). Constructed directly here for that reason.
  CachedResult(
    run: ptypes.ProcessResult(
      exit:  ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: ptypes.Evidence(
        escapees: @[ptypes.ProcSnapshot(pid: 4242, ppid: 1, command: "leaked",
                                        rssBytes: 1024)]),
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
    # RFC-0005 A2c-ii: edNeverBuilt is NOT eligible for the PLAN-TIME lookup
    # (lookupAtPlan's own edRunFresh-only gate), but IS eligible for the
    # post-compile consult, right after this compile finishes -- the mock
    # cache is genuinely empty at that point (nothing stored yet), so it is
    # a real, consulted MISS: exactly one `load` call, then the live run
    # proceeds and the store gate fires once, same as before this slice.
    check ms.loadCalls == 1

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

# ---------------------------------------------------------------------------
# 6. RFC-0005 C3c (prefetch): cache.prefetch called ONCE at plan time, before
#    any per-entry load, with the edRunFresh + read-permitted candidate key
#    set. TieredCache.resolveProbes' own probe/get-skip mechanics are
#    test_cachetier.nim's job (15); this is execute()'s WIRING of the
#    pre-loop key gather + the cache.prefetch call.
# ---------------------------------------------------------------------------

suite "execute — RFC-0005 C3c: prefetch called once with the candidate key set":

  test "N edRunFresh hits -> prefetch called exactly once, before load, with all N keys":
    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-tests/unit/c3c_bogus_0.nim"] = cachedPass(1)
    ms.store["mk-tests/unit/c3c_bogus_1.nim"] = cachedPass(2)
    ms.store["mk-tests/unit/c3c_bogus_2.nim"] = cachedPass(3)

    var prefetchCalls = 0
    var prefetchedKeyCount = 0
    let spy = proc(keys: openArray[SoundnessKey]; abandoned: proc(): bool {.closure.}) =
      inc prefetchCalls
      prefetchedKeyCount = keys.len

    let peps = @[
      plannedFresh("tests/unit/c3c_bogus_0.nim"),
      plannedFresh("tests/unit/c3c_bogus_1.nim"),
      plannedFresh("tests/unit/c3c_bogus_2.nim"),
    ]
    let p = RunPlan(entrypoints: peps, jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: getTempDir()), graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms), prefetch = spy))

    check results.len == 3
    for r in results: check r.cached   # every entry served from cache -- no live spawn attempted
    check prefetchCalls == 1
    check prefetchedKeyCount == 3
    check ms.loadCalls == 3   # each entry still gets its own per-entry consult after the prefetch

  test "a group-opted-out entry (cacheable #false) is excluded from the candidate key set":
    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-tests/unit/c3c_bogus_a.nim"] = cachedPass(1)
    var prefetchedKeyCount = -1
    let spy = proc(keys: openArray[SoundnessKey]; abandoned: proc(): bool {.closure.}) =
      prefetchedKeyCount = keys.len

    let peps = @[
      plannedFresh("tests/unit/c3c_bogus_a.nim"),
      PlannedEntrypoint(ep: Entrypoint(path: "tests/unit/c3c_bogus_b.nim", group: "unit", flags: @[]),
                        edecision: edRunFresh, runTimeoutMs: 30_000, cacheable: csFalse),
    ]
    let p = RunPlan(entrypoints: peps, jobs: 1)
    var g = emptyDepGraph()
    discard execute(
      p, config = Config(projectRoot: getTempDir()), graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms), prefetch = spy))

    check prefetchedKeyCount == 1   # only the non-opted-out entry made it into the candidate set

  test "cacheDisabled: prefetch is never invoked (cacheActive gates the pre-loop gather)":
    var prefetchCalls = 0
    let spy = proc(keys: openArray[SoundnessKey]; abandoned: proc(): bool {.closure.}) =
      inc prefetchCalls

    let dir = getTempDir() / "crisol_c3c_nocache"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")
    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    var ctx = cacheDisabled(isoSpec)
    ctx.prefetch = spy
    discard execute(p, config = Config(projectRoot: dir, stateDir: ".crisol",
                                       compileTimeoutSecs: 120, timeoutSecs: 60),
                    graph = g, showProgress = false, cache = ctx)
    check prefetchCalls == 0

# ---------------------------------------------------------------------------
# 7. RFC-0005 SO1: serve-time recompute is policy-aware + re-checks evidence
#
# Drives the same real execute() poll-loop as suite 3 (edNeverBuilt on a
# REAL passing fixture, so the post-compile consult -- `consultPostCompile`,
# sharing `consultReal` with `lookupAtPlan` -- is the one exercised here),
# but the mock cache is pre-seeded with an escapee-tainted entry under this
# fixture's OWN key. A served `cdmHit` would skip the run entirely; instead
# the real compile+run happens (a genuinely clean, isolated `quit(0)`, so it
# passes for real and self-heals the entry: `cdmStored`, not `cdmHit`) --
# proof the tainted entry was never served.
# ---------------------------------------------------------------------------

suite "execute — RFC-0005 SO1: escapee evidence forces recompute-miss + real rerun":

  test "unstrict run: escapee entry never served (evidenceSatisfies re-check, not policy)":
    let dir = getTempDir() / "crisol_so1_escapee_a"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-" & fixt] = cachedPassWithEscapees(9999)

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
    check ms.loadCalls == 1                 # the post-compile consult WAS made
    check not results[0].cached             # ... and rejected the tainted hit
    check results[0].outcome == oPassed     # a REAL run of this genuinely clean fixture
    check results[0].cacheDecision == cdmStored   # self-heals the key with real evidence
    check ms.storeCalls == 1

  test "strict-hygiene run: same escapee entry, same recompute-miss":
    let dir = getTempDir() / "crisol_so1_escapee_b"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-" & fixt] = cachedPassWithEscapees(9999)

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let strictPolicy = ptypes.OutcomePolicy(strictHygiene: true)
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms),
                           outcomePolicy = strictPolicy))

    check results.len == 1
    check ms.loadCalls == 1
    check not results[0].cached
    check results[0].outcome == oPassed
    check results[0].cacheDecision == cdmStored
    check ms.storeCalls == 1

  test "guard: a normal clean entry still serves cdmHit under a strict-hygiene run (no regression)":
    let ms = MockState(store: initTable[string, CachedResult]())
    ms.store["mk-tests/unit/test_bogus_clean.nim"] = cachedPass(111)

    let pep = plannedFresh("tests/unit/test_bogus_clean.nim")
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let strictPolicy = ptypes.OutcomePolicy(strictHygiene: true)
    let results = execute(
      p, config = Config(projectRoot: getTempDir()), graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms),
                           outcomePolicy = strictPolicy))

    check results.len == 1
    check results[0].cacheDecision == cdmHit
    check results[0].cached

# ---------------------------------------------------------------------------
# 8. RFC-0005 SO3: post-compile consult is attempt-gated
#
# `edNeverBuilt`/`edStale` retries ALWAYS recompile (edecision is immutable —
# spawnCompileStable dispatches on every attempt, runner.nim's fill-scan),
# so finalizeSlot's spCompiling branch — and therefore its post-compile
# `consultPostCompile` call — runs again on attempt 2+ unless explicitly
# gated. Without the SO3 fix, a pass published to the SAME key by some OTHER
# host between attempt 1 and attempt 2 would be served as a `fkCacheHit`,
# masking what may be a genuine local failure (attempts=0, no ledger row,
# `flaky()` structurally false). `raceSeams` below simulates exactly that
# race deterministically: its `load` is a MISS on the very first call (the
# real attempt-1 consult) and a HIT on every call after — proving the fix
# by proving `load` is never called a SECOND time at all (the attempt-gate
# skips the consult entirely on attempt 2, not merely discards its result).
# ---------------------------------------------------------------------------

type RaceState = ref object
  loadCalls: int
  planted:   bool

proc raceSeams(rs: RaceState; passResult: CachedResult): CacheSeams =
  legacySeams(
    keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
             SoundnessKey("mk-" & pep.ep.path),
    load = proc(key: SoundnessKey): Option[CachedResult] =
             inc rs.loadCalls
             if rs.planted:
               some(passResult)
             else:
               # Simulate a concurrent publish landing between THIS
               # (attempt-1) consult and any later one.
               rs.planted = true
               none(CachedResult),
    store = proc(key: SoundnessKey; res: CachedResult): bool =
             false,   # irrelevant: a failing attempt is never store-eligible
  )

suite "execute — RFC-0005 SO3: post-compile consult attempt-gating":

  test "retry (attempt 2) does NOT consult the cache; a real rerun happens; attempts recorded honestly":
    let dir = getTempDir() / "crisol_so3_retry"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_always_fail.nim"
    writeFile(fixt, "quit(1)\n")   # deterministic failure on EVERY real attempt

    let rs = RaceState()
    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000, retries: 1)  # maxAttempts = 2
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), raceSeams(rs, cachedPass(1))))

    check results.len == 1
    check results[0].attempts == 2         # both attempts genuinely ran -- not masked as a cache hit
    check results[0].outcome == oFailed    # the real, deterministic failure -- never the planted pass
    check not results[0].cached
    check results[0].cacheDecision == cdmKeyMiss   # a real fresh-run miss, never cdmHit
    check rs.loadCalls == 1                 # the post-compile consult ran ONCE (attempt 1) --
                                             # attempt 2's consult was skipped entirely, not just
                                             # ignored: proves the GATE, not merely the recompute rule.

  test "guard: an attempt-1 post-compile hit still serves (no regression)":
    let ms = MockState(store: initTable[string, CachedResult]())

    let dir = getTempDir() / "crisol_so3_guard"
    removeDir(dir); createDir(dir)
    defer: removeDir(dir)
    let fixt = dir / "test_pass.nim"
    writeFile(fixt, "quit(0)\n")

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
      edecision: edNeverBuilt, runTimeoutMs: 60_000)   # retries: 0 (default) -- single attempt
    let p = RunPlan(entrypoints: @[pep], jobs: 1)
    var g = emptyDepGraph()
    # Seed the mock cache under the REAL key this fixture derives (mockSeams'
    # legacyKey is "mk-" & pep.ep.path -- see the module-level mockSeams proc).
    ms.store["mk-" & fixt] = cachedPass(111)
    let results = execute(
      p, config = Config(projectRoot: dir, stateDir: ".crisol",
                         compileTimeoutSecs: 120, timeoutSecs: 60),
      graph = g, showProgress = false,
      cache = cacheEnabled(isoSpec, defaultCachePolicy(), mockSeams(ms)))

    check results.len == 1
    check results[0].cacheDecision == cdmHit
    check results[0].cached
    check ms.loadCalls == 1

echo "test_cache_dispatch_boundary: done"
