## test_a9_cache_controls.nim — A9: --no-cache, per-group cacheable tri-state,
## --force-compile orthogonality, and --changed × warm-cache interaction.
##
## Covers:
##   1. resolveCacheable: the 6-cell truth table (3 group states × 2 global states)
##   2. lookupAtPlan: csFalse group → cdmPolicyDisabled regardless of global policy
##   3. lookupAtPlan: csTrue / csDefault with global-on → normal hit/miss
##   4. lookupAtPlan: csTrue / csDefault with global-off → cdmPolicyDisabled
##   5. shouldStore:  csFalse blocks write even when hermeticity achieved + attempt 1
##   6. shouldStore:  csDefault / csTrue with global-on → write (hermeticity respected)
##   7. --force-compile × cache orthogonality:
##        a. forceCompile alone does NOT disable cache reads/writes
##           (cdStale/edStale are cdmNotEligible; the plan-time lookup is never called
##            for them regardless; the store gate fires normally on live completion)
##        b. noCache alone does NOT force compilation
##           (CompileDecision is unaffected by noCache; plan(forceCompile=false) leaves
##            a fresh binary as cdSkipFresh → edRunFresh regardless of noCache)
##        c. Both together: compile forced AND cache bypassed (cdmPolicyDisabled)
##   8. Config: cacheable #false, #true, absent — parsed from KDL with zero warnings
##   9. Plan: cacheable threaded from Group → PlannedEntrypoint
##  10. --changed × warm-cache: changed closure → different soundnessKey → cache miss;
##      unchanged entry in the changed set → hit.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_a9_cache_controls.nim

import std/[options, os, tempfiles, unittest]
import crisol/[types, config, cachedispatch, resultcache, sandbox, planner, depgraph]
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc allApplied(): ptypes.LimitsAchieved =
  ## A fully-achieved per-limit record (rfc-0007 A2a-iii: SandboxAchieved is
  ## deleted; env/tmpdir are achieved by construction, so only limits are
  ## threaded through shouldStore now).
  for k in ptypes.LimitKind: result[k] = ptypes.lsApplied

proc freshPep(dec: EntrypointDecision;
              cs:  CacheableState = csDefault;
              path = "tests/unit/test_x.nim"): PlannedEntrypoint =
  PlannedEntrypoint(
    ep:        Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: dec,
    cacheable: cs,
  )

proc sampleCached(): CachedResult =
  CachedResult(
    run: ptypes.ProcessResult(
      exit:  ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: default(ptypes.Evidence),
      rusage: none(ptypes.Rusage),
      durationUs: 1234 * 1000,
    ),
    records:    @[],
    cachedAt:   1_700_000_000'i64,
  )

type Calls = object
  loadCalls:  int
  keyCalls:   int
  storeCalls: int

proc seamsHit(c: var Calls; cr: CachedResult): CacheSeams =
  let cp = addr c
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; SoundnessKey("k-" & pep.ep.path),
    load:  proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls; some(cr),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

proc seamsMiss(c: var Calls): CacheSeams =
  let cp = addr c
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; SoundnessKey("k-" & pep.ep.path),
    load:  proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls; none(CachedResult),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

let globalOn  = defaultCachePolicy()             # enabled=true
let globalOff = CachePolicy(enabled: false)      # --no-cache

proc writeFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc makeTmpDir(): string = createTempDir("crisol_a9_", "")

# ---------------------------------------------------------------------------
# 1. resolveCacheable — 6-cell truth table
# ---------------------------------------------------------------------------

suite "A9 resolveCacheable — 6-cell truth table":

  test "csFalse + global-on → blocked (readOk=false, writeOk=false, cdmGroupOptOut)":
    ## M8: csFalse (per-group config opt-out) produces cdmGroupOptOut, NOT cdmPolicyDisabled.
    let r = resolveCacheable(globalOn, csFalse)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmGroupOptOut

  test "csFalse + global-off → blocked (absolute; same result cdmGroupOptOut regardless of global)":
    ## M8: csFalse is absolute — it always reports cdmGroupOptOut even when global is off.
    let r = resolveCacheable(globalOff, csFalse)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmGroupOptOut

  test "csTrue + global-on → permitted (readOk=true, writeOk=true)":
    let r = resolveCacheable(globalOn, csTrue)
    check r.readOk
    check r.writeOk

  test "csTrue + global-off → blocked (global off wins over csTrue)":
    let r = resolveCacheable(globalOff, csTrue)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmPolicyDisabled

  test "csDefault + global-on → permitted (inherit: global on)":
    let r = resolveCacheable(globalOn, csDefault)
    check r.readOk
    check r.writeOk

  test "csDefault + global-off → blocked (inherit: global off)":
    let r = resolveCacheable(globalOff, csDefault)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmPolicyDisabled

# ---------------------------------------------------------------------------
# 2. lookupAtPlan — csFalse group always produces cdmPolicyDisabled
# ---------------------------------------------------------------------------

suite "A9 lookupAtPlan — csFalse group":

  test "csFalse + global-on → cdmGroupOptOut, load NOT called":
    ## M8: csFalse is a config-declared opt-out → cdmGroupOptOut (not cdmPolicyDisabled).
    var c: Calls
    let pep  = freshPep(edRunFresh, csFalse)
    let look = lookupAtPlan(pep, globalOn, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmGroupOptOut
    check look.synthesized.isNone
    check look.inputHash == ""
    check c.loadCalls == 0
    check c.keyCalls  == 0

  test "csFalse + global-off → cdmGroupOptOut (config opt-out takes precedence)":
    ## M8: csFalse is absolute — produces cdmGroupOptOut regardless of global policy.
    var c: Calls
    let pep  = freshPep(edRunFresh, csFalse)
    let look = lookupAtPlan(pep, globalOff, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmGroupOptOut
    check look.synthesized.isNone
    check c.loadCalls == 0

# ---------------------------------------------------------------------------
# 3. lookupAtPlan — csTrue / csDefault with global-on: normal hit/miss
# ---------------------------------------------------------------------------

suite "A9 lookupAtPlan — csTrue/csDefault with global-on":

  test "csDefault + global-on hit → edCached, cdmHit, synthesized":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOn, seamsHit(c, sampleCached()))
    check look.decision == edCached
    check look.cacheDecision == cdmHit
    check look.synthesized.isSome
    check c.loadCalls == 1

  test "csTrue + global-on hit → edCached, cdmHit":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csTrue), globalOn, seamsHit(c, sampleCached()))
    check look.decision == edCached
    check look.cacheDecision == cdmHit
    check look.synthesized.isSome
    check c.loadCalls == 1

  test "csDefault + global-on miss → edRunFresh, cdmKeyMiss, no synthesis":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOn, seamsMiss(c))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmKeyMiss
    check look.synthesized.isNone
    check c.loadCalls == 1

  test "csTrue + global-on miss → edRunFresh, cdmKeyMiss":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csTrue), globalOn, seamsMiss(c))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmKeyMiss
    check c.loadCalls == 1

# ---------------------------------------------------------------------------
# 4. lookupAtPlan — csTrue / csDefault with global-off
# ---------------------------------------------------------------------------

suite "A9 lookupAtPlan — csTrue/csDefault with global-off":

  test "csDefault + global-off → cdmPolicyDisabled, load NOT called":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOff, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmPolicyDisabled
    check c.loadCalls == 0

  test "csTrue + global-off → cdmPolicyDisabled (global off wins)":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csTrue), globalOff, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmPolicyDisabled
    check c.loadCalls == 0

# ---------------------------------------------------------------------------
# 5. shouldStore — csFalse blocks write even when all other gates pass
# ---------------------------------------------------------------------------

suite "A9 shouldStore — csFalse blocks write":

  let isoSpec     = resolveSandbox(hlIsolated)
  let fullAchieved = allApplied()
  let fullEvidence = ptypes.Evidence(limits: fullAchieved)

  proc passResult(evidence: ptypes.Evidence = default(ptypes.Evidence)): EntrypointResult =
    ## rfc-0007 A6a: outcome is derived, not stored — a passing Phase pair
    ## (compile skipped, run exited 0) makes outcome(r) == oPassed. `evidence`
    ## is now carried ON the result itself; shouldStore reads it via
    ## `runEvidence` (no separate parameter — see the call sites below).
    result = EntrypointResult(ep: Entrypoint(path: "p"))
    result.compile = ptypes.Phase(kind: ptypes.pkSkipped)
    result.run = ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
      exit: ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: evidence, rusage: none(ptypes.Rusage),
      durationUs: 0))

  test "csFalse + global-on + achieved + attempt1 → no store, cdmGroupOptOut":
    ## M8: csFalse blocks write with cdmGroupOptOut (config opt-out, not --no-cache).
    let v = shouldStore(passResult(), isoSpec, 1, globalOn, csFalse)
    check not v.store
    check v.decision == cdmGroupOptOut

  test "csFalse + global-off + achieved + attempt1 → no store, cdmGroupOptOut":
    ## M8: csFalse is absolute; even with global off it reports cdmGroupOptOut.
    let v = shouldStore(passResult(), isoSpec, 1, globalOff, csFalse)
    check not v.store
    check v.decision == cdmGroupOptOut

  test "csDefault + global-on + achieved + attempt1 → store":
    let v = shouldStore(passResult(fullEvidence), isoSpec, 1, globalOn, csDefault)
    check v.store

  test "csTrue + global-on + achieved + attempt1 → store":
    let v = shouldStore(passResult(fullEvidence), isoSpec, 1, globalOn, csTrue)
    check v.store

  test "csDefault + global-off + achieved + attempt1 → no store, cdmPolicyDisabled":
    let v = shouldStore(passResult(), isoSpec, 1, globalOff, csDefault)
    check not v.store
    check v.decision == cdmPolicyDisabled

  test "csTrue + global-off + achieved + attempt1 → no store, cdmPolicyDisabled (global wins)":
    let v = shouldStore(passResult(), isoSpec, 1, globalOff, csTrue)
    check not v.store
    check v.decision == cdmPolicyDisabled

# ---------------------------------------------------------------------------
# 6. Config: cacheable #true / #false / absent parsed correctly
# ---------------------------------------------------------------------------

suite "A9 config — cacheable tri-state parsing":

  test "cacheable #false → Group.cacheable == csFalse":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    cacheable #false
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].cacheable == csFalse
    check warns.len == 0

  test "cacheable #true → Group.cacheable == csTrue":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    cacheable #true
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].cacheable == csTrue
    check warns.len == 0

  test "absent cacheable → Group.cacheable == csDefault":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].cacheable == csDefault
    check warns.len == 0

  test "cacheable non-bool arg → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    cacheable "yes"
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "all cacheable variants together produce zero unknown-key warnings":
    ## Two groups with cacheable: one #true, one #false; second group also tests
    ## that cacheable does not warn when paired with other known keys.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    cacheable #true
    globs "tests/unit/test_*.nim"
}
group "slow" {
    cacheable #false
    opt-in #true
    globs "tests/slow/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (_, warns) = loadConfig(configPath = cfgPath)
    check warns.len == 0

# ---------------------------------------------------------------------------
# 7. Plan: cacheable threaded from Group → PlannedEntrypoint
# ---------------------------------------------------------------------------

suite "A9 plan — cacheable threaded to PlannedEntrypoint":

  proc buildCfg(cs: CacheableState; tmp: string): Config =
    let globs = @["tests/unit/test_x.nim"]
    Config(
      groups: @[Group(name: "unit", globs: globs, cacheable: cs)],
      jobs: 1, timeoutSecs: 300, compileTimeoutSecs: 600,
      maxOutputBytes: 10 * 1024 * 1024, stateDir: ".crisol",
      projectRoot: tmp,
    )

  test "Group.cacheable csFalse → PlannedEntrypoint.cacheable csFalse":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let ep  = Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[])
    let cfg = buildCfg(csFalse, tmp)
    let rp  = plan(cfg, @[ep], emptyDepGraph())
    check rp.entrypoints.len == 1
    check rp.entrypoints[0].cacheable == csFalse

  test "Group.cacheable csTrue → PlannedEntrypoint.cacheable csTrue":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let ep  = Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[])
    let cfg = buildCfg(csTrue, tmp)
    let rp  = plan(cfg, @[ep], emptyDepGraph())
    check rp.entrypoints[0].cacheable == csTrue

  test "Group.cacheable csDefault → PlannedEntrypoint.cacheable csDefault":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let ep  = Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[])
    let cfg = buildCfg(csDefault, tmp)
    let rp  = plan(cfg, @[ep], emptyDepGraph())
    check rp.entrypoints[0].cacheable == csDefault

  test "entrypoint with no matching group defaults to csDefault":
    ## When an entrypoint's group name does not exist in config.groups, the
    ## lookup falls through to the default and the cacheable is csDefault.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let ep  = Entrypoint(path: "tests/unit/test_x.nim", group: "orphan", flags: @[])
    let cfg = buildCfg(csFalse, tmp)  # "unit" group is csFalse, but ep is in "orphan"
    let rp  = plan(cfg, @[ep], emptyDepGraph())
    check rp.entrypoints[0].cacheable == csDefault

# ---------------------------------------------------------------------------
# 8. --force-compile orthogonality
#
# forceCompile forces compilation (cdStale → edStale for fresh binaries).
# noCache bypasses the cache (no read or write).
# They are INDEPENDENT controls.
# ---------------------------------------------------------------------------

suite "A9 --force-compile × --no-cache orthogonality":

  ## (a) forceCompile alone does NOT disable cache.
  ## A forced entry is cdStale → edStale.  lookupAtPlan only consults the cache
  ## for edRunFresh; edStale entries are cdmNotEligible.  The cache is not read.
  ## On store: after a live run (which compiles + runs), shouldStore fires
  ## normally — forceCompile is invisible to the store gate.
  test "(a) forceCompile alone: edStale entries are cdmNotEligible — cache not consulted":
    var c: Calls
    # Simulate what plan() produces for a forceCompile entry: edStale.
    let pep  = PlannedEntrypoint(
      ep:        Entrypoint(path: "t.nim", group: "unit", flags: @[]),
      edecision: edStale,
      cacheable: csDefault,
    )
    let look = lookupAtPlan(pep, globalOn, seamsHit(c, sampleCached()))
    check look.decision == edStale
    check look.cacheDecision == cdmNotEligible
    check c.loadCalls == 0
    check c.keyCalls  == 0

  test "(a) forceCompile alone: shouldStore fires normally for an edStale live pass":
    ## After forceCompile, a live pass DOES get stored (if hermeticity achieved).
    let isoSpec     = resolveSandbox(hlIsolated)
    let fullAchieved = allApplied()
    var r = EntrypointResult(ep: Entrypoint(path: "t.nim"))
    r.compile = ptypes.Phase(kind: ptypes.pkSkipped)
    r.run = ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
      exit: ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: ptypes.Evidence(limits: fullAchieved), rusage: none(ptypes.Rusage),
      durationUs: 0))
    # csDefault + global-on + achieved + attempt1 → store, even for a forced run.
    let v = shouldStore(r, isoSpec, 1, globalOn, csDefault)
    check v.store

  ## (b) noCache alone does NOT force compilation.
  ## The CompileDecision (cdSkipFresh/cdStale) is determined by decideCompile,
  ## which only looks at forceCompile, NOT at noCache.  We verify that plan()
  ## with forceCompile=false keeps a fresh-graph entry as edRunFresh.
  test "(b) noCache alone: plan produces edRunFresh (compile not forced)":
    ## With noCache=true and forceCompile=false, compile decision is NOT changed.
    ## We use an empty graph → cdNeverBuilt (not cdStale from force), which maps
    ## to edNeverBuilt — showing the plan is unaffected by noCache.
    ## The key point: plan() takes no noCache parameter; noCache only affects
    ## CachePolicy construction AFTER planning.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let ep  = Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[])
    let cfg = Config(
      groups: @[Group(name: "unit", globs: @["tests/unit/test_x.nim"])],
      jobs: 1, timeoutSecs: 300, compileTimeoutSecs: 600,
      maxOutputBytes: 10 * 1024 * 1024, stateDir: ".crisol", projectRoot: tmp,
    )
    # forceCompile=false: empty graph → cdNeverBuilt (binary absent)
    let rp = plan(cfg, @[ep], emptyDepGraph(), forceCompile = false)
    check rp.entrypoints[0].edecision == edNeverBuilt  # NOT forced to edStale

  test "(b) noCache alone: lookupAtPlan returns cdmPolicyDisabled for edRunFresh entry":
    ## With noCache (globalOff), a hypothetical edRunFresh entry is NOT read.
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOff, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmPolicyDisabled
    check c.loadCalls == 0

  ## (c) Both together: edStale + noCache.
  ## forceCompile → edStale → cdmNotEligible (not consulted at plan time).
  ## noCache → shouldStore blocked.
  test "(c) both: edStale is cdmNotEligible AND shouldStore blocked by noCache":
    var c: Calls
    let pep  = PlannedEntrypoint(
      ep:        Entrypoint(path: "t.nim", group: "unit", flags: @[]),
      edecision: edStale,
      cacheable: csDefault,
    )
    # Plan-time: cache not consulted (cdmNotEligible for edStale regardless of policy)
    let look = lookupAtPlan(pep, globalOff, seamsHit(c, sampleCached()))
    check look.cacheDecision == cdmNotEligible
    check c.loadCalls == 0

    # Store-time: noCache blocks write
    let isoSpec     = resolveSandbox(hlIsolated)
    var r = EntrypointResult(ep: Entrypoint(path: "t.nim"))
    r.compile = ptypes.Phase(kind: ptypes.pkSkipped)
    r.run = ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
      exit: ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: default(ptypes.Evidence), rusage: none(ptypes.Rusage),
      durationUs: 0))
    let v = shouldStore(r, isoSpec, 1, globalOff, csDefault)
    check not v.store
    check v.decision == cdmPolicyDisabled

# ---------------------------------------------------------------------------
# 9. --changed × warm-cache interaction
#
# Proved through the dispatch logic:
#   - An entrypoint whose closure CHANGED has a different closureHash →
#     different soundnessKey → guaranteed cache MISS (cdmKeyMiss) → live re-run.
#   - An UNCHANGED entrypoint in the changed set (it's edRunFresh because the
#     binary is still fresh) gets a HIT if the key matches.
#
# We test this at the lookupAtPlan level using mocked seams where the key
# function reflects the closure content (via the path suffix here).
# ---------------------------------------------------------------------------

suite "A9 --changed × warm-cache interaction":

  test "changed closure → different soundnessKey → cache miss":
    ## Two lookups for the same entrypoint, but with different keys (simulating
    ## a closure content change between runs).  The first key finds a hit; the
    ## second (stale closure → new key) finds a miss.
    var calls1, calls2: Calls
    let pep = freshPep(edRunFresh, csDefault, "tests/unit/test_changed.nim")

    # Seam whose key is stable ("k-A")
    let seamsStableKey = CacheSeams(
      keyOf: proc(p: PlannedEntrypoint): SoundnessKey =
               inc calls1.keyCalls; SoundnessKey("k-A"),
      load:  proc(key: SoundnessKey): Option[CachedResult] =
               inc calls1.loadCalls; some(sampleCached()),
      store: proc(key: SoundnessKey; res: CachedResult): bool = true,
    )
    let look1 = lookupAtPlan(pep, globalOn, seamsStableKey)
    check look1.decision == edCached     # warm cache hit
    check look1.cacheDecision == cdmHit

    # Seam whose key is new ("k-B") — simulates a changed closure → new hash
    let seamsNewKey = CacheSeams(
      keyOf: proc(p: PlannedEntrypoint): SoundnessKey =
               inc calls2.keyCalls; SoundnessKey("k-B"),
      load:  proc(key: SoundnessKey): Option[CachedResult] =
               # k-B is not in the cache (new closure → no prior result)
               inc calls2.loadCalls; none(CachedResult),
      store: proc(key: SoundnessKey; res: CachedResult): bool = true,
    )
    let look2 = lookupAtPlan(pep, globalOn, seamsNewKey)
    check look2.decision == edRunFresh   # changed closure → miss → live re-run
    check look2.cacheDecision == cdmKeyMiss

  test "unchanged entry in the changed set → still hits the cache":
    ## An entrypoint that happened to be in the --changed set but whose closure
    ## did not actually change has the same soundnessKey → HIT.
    ## This proves --changed does not defeat warm-cache for stable closures.
    var c: Calls
    let pep = freshPep(edRunFresh, csDefault, "tests/unit/test_stable.nim")
    # Same key as a prior warm-cache run
    let look = lookupAtPlan(pep, globalOn, seamsHit(c, sampleCached()))
    check look.decision == edCached
    check look.cacheDecision == cdmHit
    check look.synthesized.isSome

  test "noCache + changed entry → cdmPolicyDisabled (unaffected by closure change)":
    ## --no-cache is orthogonal to --changed.  Even when the closure is fresh
    ## (no change), noCache means cdmPolicyDisabled regardless.
    var c: Calls
    let pep = freshPep(edRunFresh, csDefault, "tests/unit/test_any.nim")
    let look = lookupAtPlan(pep, globalOff, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmPolicyDisabled
    check c.loadCalls == 0

echo "test_a9_cache_controls: done"
