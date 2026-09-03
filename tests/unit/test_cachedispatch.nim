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
import crisol/process/types  # pkCached/pkSkipped (rfc-0007 A1c coherence test)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshPep(dec: EntrypointDecision; path = "tests/unit/test_x.nim"): PlannedEntrypoint =
  PlannedEntrypoint(
    ep:        Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: dec,
  )

proc sampleProcessResult(exitCode: int = 0): ProcessResult =
  ## A real, non-default observation (rfc-0007 A1d-ii) -- distinct from the
  ## fabricated-shim's constant Cause/default(Evidence)/none(Rusage) so a
  ## coherence check that happened to pass under the OLD interim synthesize
  ## cannot coincidentally pass here too.
  ProcessResult(
    exit:  Exit(kind: ekExited, code: exitCode),
    cause: Cause(by: cbProcess),
    evidence: Evidence(killDomain: kdsProcessGroup, tree: toComplete,
                       escapees: @[], limits: default(LimitsAchieved),
                       hermetic: hlIsolated, killSnapshot: @[],
                       cooperativeUnavailable: false),
    rusage: some(Rusage(maxRssBytes: 2_048_000, userCpuUs: 900, sysCpuUs: 100)),
    durationUs: 4242 * 1000,
  )

proc sampleCached(): CachedResult =
  CachedResult(
    run:      sampleProcessResult(),
    records:  @[TestRecord(name: "t1", status: rsPass, durationUs: 10,
                           msg: none(string), tags: @[])],
    cachedAt: 1_700_000_000'i64,
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
    check cached(s)
    check outcome(s) == oPassed
    check s.durationMs == 4242          # HISTORICAL duration
    check s.compileSkipped              # edCached skips both phases
    check s.records.len == 1
    check c.loadCalls == 1

  test "rfc-0007 A1c: synthesized cache hit derives oPassed (outcome coherence)":
    ## A cache hit never goes through runner.execute's dual-write path, so
    ## without cachedispatch.synthesize populating a minimal `run: Phase`,
    ## outcome(r) would wrongly read `run.kind == pkSkipped` and derive
    ## oSpawnError for what is actually a passing cached result — exactly the
    ## bug every consumer (render/junit/api/isQuarantined/Summary.counts)
    ## would inherit the moment it stopped trusting the legacy `outcome` field.
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, sampleCached()))
    let s = look.synthesized.get
    check outcome(s) == oPassed
    check s.run.kind == pkCached
    check s.compile.kind == pkSkipped

  test "rfc-0007 A1d-ii: the replayed run phase is the REAL stored observation, verbatim":
    ## Unit-level complement to the integration hit-path E2E: cause, evidence,
    ## and rusage are the exact stored values, not the A1c interim's constant
    ## Cause(cbProcess)/default(Evidence)/none(Rusage) fabrication.
    var c: Calls
    let cr = sampleCached()
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, cr))
    let s = look.synthesized.get
    check s.run.res == cr.run                 # byte-for-byte: the WHOLE stored ProcessResult
    check s.run.res.evidence.tree == toComplete    # not the toUnobservable default
    check s.run.res.rusage.isSome                   # not none() (the old shim's fabrication)
    check s.run.res.rusage.get.maxRssBytes == 2_048_000

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

  test "rfc-0007 A1d-ii / §2: recomputed-not-oPassed hit is a MISS, rerun (cdmRecomputeMiss)":
    ## Store a pass, then simulate the stored observation having been
    ## corrupted/replaced with one that no longer derives oPassed (e.g. a
    ## derivation/policy change since the entry was written -- §2's honest
    ## trap-closer: a cache entry existing is NOT enough; deriveOutcome is
    ## recomputed at the trust boundary EVERY time, and a hit that no longer
    ## earns oPassed must be treated exactly like a miss and rerun live.
    var c: Calls
    var badCr = sampleCached()
    badCr.run.exit = Exit(kind: ekExited, code: 1)   # now derives oFailed, not oPassed
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, badCr))
    check look.decision == edRunFresh          # treated as a miss: run it live
    check look.cacheDecision == cdmRecomputeMiss
    check look.synthesized.isNone              # a discarded hit is never served
    check look.inputHash.len > 0               # the cache WAS consulted (A8)
    check c.loadCalls == 1                     # the entry was found; its
                                                # recomputed outcome (not oPassed)
                                                # disqualified it as a hit.

# ---------------------------------------------------------------------------
# shouldStore gate
# ---------------------------------------------------------------------------

suite "shouldStore — cache-write gate":

  let isoSpec = resolveSandbox(hlIsolated)

  proc allApplied(): LimitsAchieved =
    for k in LimitKind: result[k] = lsApplied

  # A fully-achieved per-limit record for the isolated spec (rfc-0007 A2a-iii:
  # SandboxAchieved is deleted; env/tmpdir are achieved by construction, so
  # only limits are threaded through shouldStore now).
  let fullAchieved = allApplied()
  let fullEvidence = Evidence(limits: fullAchieved)

  proc passResult(evidence: Evidence = default(Evidence)): EntrypointResult =
    ## rfc-0007 A6a: outcome is derived, not stored — a passing Phase pair
    ## makes outcome(r) == oPassed. `evidence` is now carried ON the result
    ## itself; shouldStore reads it via `runEvidence` (no separate parameter).
    result = EntrypointResult(ep: Entrypoint(path: "p"))
    result.compile = Phase(kind: pkSkipped)
    result.run = Phase(kind: pkRan, res: ProcessResult(
      exit: Exit(kind: ekExited, code: 0), cause: Cause(by: cbProcess),
      evidence: evidence, rusage: none(Rusage), durationUs: 0))

  proc failResult(): EntrypointResult =
    result = EntrypointResult(ep: Entrypoint(path: "p"))
    result.compile = Phase(kind: pkSkipped)
    result.run = Phase(kind: pkRan, res: ProcessResult(
      exit: Exit(kind: ekExited, code: 1), cause: Cause(by: cbProcess),
      evidence: default(Evidence), rusage: none(Rusage), durationUs: 0))

  test "pass + fully achieved + attempt 1 → store":
    let v = shouldStore(passResult(fullEvidence), isoSpec, 1, defaultCachePolicy())
    check v.store

  test "policy disabled → no store, cdmPolicyDisabled":
    let v = shouldStore(passResult(fullEvidence), isoSpec, 1, CachePolicy(enabled: false))
    check not v.store
    check v.decision == cdmPolicyDisabled

  test "non-pass outcome → no store":
    let r = failResult()
    let v = shouldStore(r, isoSpec, 1, defaultCachePolicy())
    check not v.store

  test "hermeticity degraded → no store, cdmHermeticityDeg":
    # A requested limit (lkCore, requested by default under hlIsolated) whose
    # kernel readback did not confirm.
    var degraded = allApplied()
    degraded[lkCore] = lsFailed
    let v = shouldStore(passResult(Evidence(limits: degraded)), isoSpec, 1, defaultCachePolicy())
    check not v.store
    check v.decision == cdmHermeticityDeg

  test "flaky-pass (attempt > 1) → no store, cdmFlaky":
    let v = shouldStore(passResult(fullEvidence), isoSpec, 2, defaultCachePolicy())
    check not v.store
    check v.decision == cdmFlaky

  test "observed escapee (rfc-0007 A6a) → no store, cdmHermeticityDeg, even with limits fully achieved":
    ## §6: `escapees.len > 0` is the escapee-specific cache-gate fact, folded
    ## into evidenceSatisfies alongside the limit/netIso checks — a leaked
    ## same-pgroup survivor refuses the store exactly like a degraded limit.
    let leaked = @[ProcSnapshot(pid: 4242, ppid: 1, command: "leaked", rssBytes: 1024)]
    let ev = Evidence(limits: fullAchieved, escapees: leaked)
    let v = shouldStore(passResult(ev), isoSpec, 1, defaultCachePolicy())
    check not v.store
    check v.decision == cdmHermeticityDeg

  test "empty escapees + toUnobservable tree → still stores (the honest-label path)":
    ## The pgid-only tier's de-facto caching behavior is preserved: `tree`
    ## is a separate observability axis and is never itself a store-blocker.
    var ev = Evidence(limits: fullAchieved, escapees: @[])
    ev.tree = toUnobservable
    let v = shouldStore(passResult(ev), isoSpec, 1, defaultCachePolicy())
    check v.store

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
