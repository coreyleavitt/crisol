## test_cachedispatch.nim — A6: plan-time cache lookup + store gate (RFC-0004 F3).
##
## Unit-level coverage of the pure dispatch logic with MOCKED seams:
##   - lookupAtPlan: edRunFresh hit → edCached + synthesized + cdmHit
##   - lookupAtPlan: edRunFresh miss → edRunFresh + cdmKeyMiss, no synthesis
##   - lookupAtPlan: edNeverBuilt / edStale → cdmNotEligible, cache not consulted
##   - lookupAtPlan: policy disabled → cdmPolicyDisabled, no load called
##   - shouldStore gate: pass+achieved+attempt1 → store; every negative branch
##   - synthesized result carries historical duration + cached flag + records
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cachedispatch.nim

import std/[options, unittest]
import crisol/[types, sandbox, cachedispatch, resultcache, planner, depgraph]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshPep(dec: EntrypointDecision; path = "tests/unit/test_x.nim"): PlannedEntrypoint =
  PlannedEntrypoint(
    ep:        Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: dec,
  )

proc sampleCached(): CachedResult =
  CachedResult(
    outcome:    oPassed,
    exitCode:   0,
    signal:     0,
    durationMs: 4242,
    records:    @[TestRecord(name: "t1", status: rsPass, durationUs: 10,
                             msg: none(string), tags: @[])],
    cachedAt:   1_700_000_000'i64,
  )

# A seam bundle whose load always hits / always misses, recording calls.
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

let onPolicy  = defaultCachePolicy()
let offPolicy = CachePolicy(enabled: false)

# ---------------------------------------------------------------------------
# lookupAtPlan
# ---------------------------------------------------------------------------

suite "lookupAtPlan — promotion + decision":

  test "edRunFresh hit → edCached, synthesized, cdmHit":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, sampleCached()))
    check look.decision == edCached
    check look.cacheDecision == cdmHit
    check look.synthesized.isSome
    let s = look.synthesized.get
    check s.cached
    check s.outcome == oPassed
    check s.durationMs == 4242          # HISTORICAL duration
    check s.compileSkipped              # edCached skips both phases
    check s.records.len == 1
    check c.loadCalls == 1

  test "edRunFresh miss → edRunFresh, cdmKeyMiss, no synthesis":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsMiss(c))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmKeyMiss
    check look.synthesized.isNone
    check c.loadCalls == 1

  test "A8: lookup surfaces inputHash on a hit (key string the hit was served on)":
    var c: Calls
    let pep  = freshPep(edRunFresh)
    let look = lookupAtPlan(pep, onPolicy, seamsHit(c, sampleCached()))
    check look.inputHash == "k-" & pep.ep.path
    # The synthesized result also carries the same inputHash.
    check look.synthesized.get.inputHash == "k-" & pep.ep.path

  test "A8: lookup surfaces inputHash on a miss (run/v1 reports it on misses too)":
    var c: Calls
    let pep  = freshPep(edRunFresh)
    let look = lookupAtPlan(pep, onPolicy, seamsMiss(c))
    check look.inputHash == "k-" & pep.ep.path

  test "A8: not-eligible / policy-disabled lookups carry empty inputHash":
    var c1, c2: Calls
    check lookupAtPlan(freshPep(edNeverBuilt), onPolicy,
                       seamsHit(c1, sampleCached())).inputHash == ""
    check lookupAtPlan(freshPep(edRunFresh), offPolicy,
                       seamsHit(c2, sampleCached())).inputHash == ""

  test "edNeverBuilt → cdmNotEligible, cache NOT consulted":
    var c: Calls
    let look = lookupAtPlan(freshPep(edNeverBuilt), onPolicy, seamsHit(c, sampleCached()))
    check look.decision == edNeverBuilt
    check look.cacheDecision == cdmNotEligible
    check look.synthesized.isNone
    check c.loadCalls == 0               # never touched the cache
    check c.keyCalls == 0

  test "edStale → cdmNotEligible, cache NOT consulted":
    var c: Calls
    let look = lookupAtPlan(freshPep(edStale), onPolicy, seamsHit(c, sampleCached()))
    check look.decision == edStale
    check look.cacheDecision == cdmNotEligible
    check c.loadCalls == 0

  test "policy disabled → cdmPolicyDisabled, load NOT called":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), offPolicy, seamsHit(c, sampleCached()))
    check look.decision == edRunFresh
    check look.cacheDecision == cdmPolicyDisabled
    check look.synthesized.isNone
    check c.loadCalls == 0

# ---------------------------------------------------------------------------
# shouldStore gate
# ---------------------------------------------------------------------------

suite "shouldStore — cache-write gate":

  let isoSpec = resolveSandbox(hlIsolated)
  # A fully-achieved hermeticity record for the isolated spec.
  let fullAchieved = SandboxAchieved(envScrubbed: true, tmpdirIso: true,
                                     rlimitsApplied: true, netIso: false)

  proc passResult(ach: SandboxAchieved): EntrypointResult =
    EntrypointResult(ep: Entrypoint(path: "p"), outcome: oPassed, achieved: ach)

  test "pass + fully achieved + attempt 1 → store":
    let v = shouldStore(passResult(fullAchieved), isoSpec, 1, defaultCachePolicy())
    check v.store

  test "policy disabled → no store, cdmPolicyDisabled":
    let v = shouldStore(passResult(fullAchieved), isoSpec, 1, CachePolicy(enabled: false))
    check not v.store
    check v.decision == cdmPolicyDisabled

  test "non-pass outcome → no store":
    var r = passResult(fullAchieved)
    r.outcome = oFailed
    let v = shouldStore(r, isoSpec, 1, defaultCachePolicy())
    check not v.store

  test "hermeticity degraded → no store, cdmHermeticityDeg":
    # envScrub requested by isoSpec but not achieved.
    let degraded = SandboxAchieved(envScrubbed: false, tmpdirIso: true,
                                   rlimitsApplied: true, netIso: false)
    let v = shouldStore(passResult(degraded), isoSpec, 1, defaultCachePolicy())
    check not v.store
    check v.decision == cdmHermeticityDeg

  test "flaky-pass (attempt > 1) → no store, cdmFlaky":
    let v = shouldStore(passResult(fullAchieved), isoSpec, 2, defaultCachePolicy())
    check not v.store
    check v.decision == cdmFlaky

# ---------------------------------------------------------------------------
# realSeams env-value soundness: RFC-0004 §Keys requires names+values in key.
# ---------------------------------------------------------------------------
##
## Regression: before fix, realSeams called hermeticEnvHashForSpec(spec) which
## hashed only env var NAMES.  Two runs with different PATH values got the same
## soundness key — stale cached results could be served.
##
## After fix, realSeams accepts a `parentEnv` snapshot and calls
## hermeticEnvHash(filterEnv(parentEnv, spec, @[])), so values enter the key.

suite "realSeams — env values enter soundness key (RFC-0004 §Keys)":

  test "same spec, different allowlisted value → DIFFERENT soundness keys":
    ## Two env snapshots that differ only in PATH value (both allowlisted).
    ## realSeams must produce different soundness keys for them.
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)

    let env1: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-aaa"),
    ]
    let env2: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/local/bin"), ("TMPDIR", "/tmp/run-bbb"),
    ]

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[]),
      edecision: edRunFresh)

    let seams1 = realSeams(
      stateDir = "/tmp/crisol_state",
      graph = addr g,
      nimVersion = "2.2.10",
      ccVersion = "gcc 13.2.0",
      spec = spec,
      parentEnv = env1,
      protocolMajor = 1,
    )
    let seams2 = realSeams(
      stateDir = "/tmp/crisol_state",
      graph = addr g,
      nimVersion = "2.2.10",
      ccVersion = "gcc 13.2.0",
      spec = spec,
      parentEnv = env2,
      protocolMajor = 1,
    )

    let k1 = seams1.keyOf(pep)
    let k2 = seams2.keyOf(pep)
    check k1 != k2   # soundness: different PATH value must produce different key

  test "same spec, same allowlisted values, different TMPDIR → SAME soundness key":
    ## TMPDIR value must NOT enter the key (per-run random suffix).
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)

    let env1: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-aaa"),
    ]
    let env2: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-zzz"),
    ]

    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[]),
      edecision: edRunFresh)

    let seams1 = realSeams(
      stateDir = "/tmp/crisol_state",
      graph = addr g,
      nimVersion = "2.2.10",
      ccVersion = "gcc 13.2.0",
      spec = spec,
      parentEnv = env1,
      protocolMajor = 1,
    )
    let seams2 = realSeams(
      stateDir = "/tmp/crisol_state",
      graph = addr g,
      nimVersion = "2.2.10",
      ccVersion = "gcc 13.2.0",
      spec = spec,
      parentEnv = env2,
      protocolMajor = 1,
    )

    let k1 = seams1.keyOf(pep)
    let k2 = seams2.keyOf(pep)
    check k1 == k2   # TMPDIR value must NOT enter the key (per-run noise)

# ---------------------------------------------------------------------------
# M4: CacheContext invariant — inconsistent state is unconstructable
# ---------------------------------------------------------------------------

suite "CacheContext — M4 invariant enforcement":

  test "cacheDisabled: isActive == false, seams.keyOf == nil":
    let ctx = cacheDisabled(resolveSandbox())
    check not ctx.isActive
    check ctx.seams.keyOf == nil
    check not ctx.policy.enabled

  test "cacheEnabled: isActive == true, seams.keyOf != nil, policy.enabled":
    var calls: Calls
    let ctx = cacheEnabled(resolveSandbox(), defaultCachePolicy(), seamsMiss(calls))
    check ctx.isActive
    check ctx.seams.keyOf != nil
    check ctx.policy.enabled

  test "cacheEnabled: keyOf==nil is rejected with doAssert":
    ## An inconsistent bundle (enabled-but-no-keyOf) must be caught at the
    ## construction boundary, not silently treated as disabled.
    var caught = false
    try:
      let _ = cacheEnabled(resolveSandbox(), defaultCachePolicy(), CacheSeams())
    except AssertionDefect:
      caught = true
    check caught

  test "cacheEnabled: policy.enabled==false is rejected with doAssert":
    ## cacheEnabled with an explicitly-off policy is also an inconsistent state;
    ## the caller should use cacheDisabled instead.
    var calls: Calls
    var caught = false
    try:
      let _ = cacheEnabled(resolveSandbox(), CachePolicy(enabled: false), seamsMiss(calls))
    except AssertionDefect:
      caught = true
    check caught

  test "isActive is the single source of truth (not re-derived from fields)":
    ## After construction, isActive must agree with the active field — proving
    ## the invariant is maintained by the constructors, not re-computed.
    let disabled = cacheDisabled(resolveSandbox())
    check not disabled.isActive
    check not disabled.active   # raw field agrees

    var calls: Calls
    let enabled = cacheEnabled(resolveSandbox(), defaultCachePolicy(), seamsMiss(calls))
    check enabled.isActive
    check enabled.active         # raw field agrees

# ---------------------------------------------------------------------------
# L15: inactiveDecision — (isActive=false, edecision) → CacheDecision matrix
# ---------------------------------------------------------------------------

suite "inactiveDecision — inactive-cache decision matrix":

  test "edRunFresh → cdmPolicyDisabled (was cache-eligible; --no-cache suppressed it)":
    check inactiveDecision(edRunFresh) == cdmPolicyDisabled

  test "edNeverBuilt → cdmNotEligible (had to compile; cache never applicable)":
    check inactiveDecision(edNeverBuilt) == cdmNotEligible

  test "edStale → cdmNotEligible (had to recompile; cache never applicable)":
    check inactiveDecision(edStale) == cdmNotEligible

  test "edCached → cdmNotEligible (unreachable on inactive path; safe fallthrough)":
    ## edCached requires a plan-time hit which requires isActive; this branch is
    ## documented as unreachable but must not crash or produce a wrong decision.
    check inactiveDecision(edCached) == cdmNotEligible

echo "test_cachedispatch: done"
