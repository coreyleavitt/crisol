## test_m8_cache_decision.nim — M8: CacheDecision honest distinctions
##
## Asserts the three M8 fixes:
##   (a) miss-stored vs miss-unstored: a passed+stored run produces cdmStored;
##       a non-pass (or blocked) run produces cdmKeyMiss.
##   (b) --no-cache (cdmPolicyDisabled) vs cacheable #false (cdmGroupOptOut):
##       resolveCacheable distinguishes them; shouldStore and lookupAtPlan propagate.
##   (c) resolveCacheable no longer emits cdmHit as a pre-lookup sentinel;
##       the permitted path uses a neutral cdmNotEligible sentinel.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_m8_cache_decision.nim

import std/[options, unittest]
import crisol/[types, sandbox, cachedispatch, resultcache, planner, depgraph]
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshPep(dec: EntrypointDecision = edRunFresh;
              cs: CacheableState = csDefault): PlannedEntrypoint =
  PlannedEntrypoint(
    ep: Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[]),
    edecision: dec,
    cacheable: cs,
  )

let globalOn  = defaultCachePolicy()
let globalOff = CachePolicy(enabled: false)
let isoSpec   = resolveSandbox(hlIsolated)
let fullAchieved = SandboxAchieved(envScrubbed: true, tmpdirIso: true,
                                   rlimitsApplied: true, netIso: false)

type Calls = object
  loadCalls:  int
  keyCalls:   int
  storeCalls: int

proc seamsHit(c: var Calls): CacheSeams =
  let cp = addr c
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; SoundnessKey("mk-" & pep.ep.path),
    load:  proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls
             some(CachedResult(
               run: ptypes.ProcessResult(
                 exit:  ptypes.Exit(kind: ptypes.ekExited, code: 0),
                 cause: ptypes.Cause(by: ptypes.cbProcess),
                 evidence: default(ptypes.Evidence),
                 rusage: none(ptypes.Rusage),
                 durationUs: 100 * 1000,
               ),
               records: @[], cachedAt: 1_700_000_000'i64)),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

proc seamsMiss(c: var Calls): CacheSeams =
  let cp = addr c
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; SoundnessKey("mk-" & pep.ep.path),
    load:  proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls; none(CachedResult),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

# ---------------------------------------------------------------------------
# (a) miss-stored vs miss-unstored
# ---------------------------------------------------------------------------

suite "M8 (a) — miss-stored vs miss-unstored via shouldStore":

  proc passRes(ach: SandboxAchieved = fullAchieved): EntrypointResult =
    EntrypointResult(ep: Entrypoint(path: "p"), outcome: oPassed, achieved: ach)

  proc failRes(): EntrypointResult =
    EntrypointResult(ep: Entrypoint(path: "p"), outcome: oFailed,
                     achieved: fullAchieved)

  test "pass + hermeticity + attempt1 → store=true (will produce cdmStored in runner)":
    ## shouldStore returns store=true; runner stamps cdmStored on the result.
    ## This test verifies the gate decision; the runner.nim integration test
    ## (test_cache_dispatch_boundary) verifies the final stamp.
    let v = shouldStore(passRes(), isoSpec, 1, globalOn)
    check v.store

  test "non-pass outcome → no store, decision=cdmKeyMiss (ran but not stored)":
    let v = shouldStore(failRes(), isoSpec, 1, globalOn)
    check not v.store
    check v.decision == cdmKeyMiss

  test "hermeticity degraded → no store, decision=cdmHermeticityDeg (not cdmKeyMiss)":
    let degraded = SandboxAchieved(envScrubbed: false, tmpdirIso: true,
                                   rlimitsApplied: true, netIso: false)
    let v = shouldStore(passRes(degraded), isoSpec, 1, globalOn)
    check not v.store
    check v.decision == cdmHermeticityDeg

  test "flaky-pass (attempt>1) → no store, decision=cdmFlaky (not cdmKeyMiss)":
    let v = shouldStore(passRes(), isoSpec, 2, globalOn)
    check not v.store
    check v.decision == cdmFlaky

  test "cdmKeyMiss only when non-pass (not degraded, not flaky, not policy)":
    ## Verify cdmKeyMiss is not spuriously produced by other branches.
    ## The only shouldStore path that returns cdmKeyMiss is the non-pass branch.
    let failV = shouldStore(failRes(), isoSpec, 1, globalOn)
    check failV.decision == cdmKeyMiss
    let hermV = shouldStore(passRes(SandboxAchieved(envScrubbed: false,
                                                    tmpdirIso: true,
                                                    rlimitsApplied: true,
                                                    netIso: false)),
                            isoSpec, 1, globalOn)
    check hermV.decision != cdmKeyMiss  # hermeticity degraded, not key-miss

# ---------------------------------------------------------------------------
# (b) --no-cache (cdmPolicyDisabled) vs cacheable #false (cdmGroupOptOut)
# ---------------------------------------------------------------------------

suite "M8 (b) — cdmPolicyDisabled vs cdmGroupOptOut distinction":

  ## resolveCacheable level
  test "csFalse (config opt-out) → cdmGroupOptOut from resolveCacheable":
    let r = resolveCacheable(globalOn, csFalse)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmGroupOptOut  # NOT cdmPolicyDisabled

  test "--no-cache (global off) → cdmPolicyDisabled from resolveCacheable":
    let r = resolveCacheable(globalOff, csDefault)
    check not r.readOk
    check not r.writeOk
    check r.decision == cdmPolicyDisabled  # NOT cdmGroupOptOut

  test "csFalse with global off still → cdmGroupOptOut (csFalse wins on opt-out semantics)":
    ## Even when global is off, csFalse is the tighter constraint and reports cdmGroupOptOut.
    let r = resolveCacheable(globalOff, csFalse)
    check r.decision == cdmGroupOptOut

  ## lookupAtPlan propagation
  test "csFalse → cdmGroupOptOut in lookupAtPlan (not cdmPolicyDisabled)":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csFalse), globalOn, seamsHit(c))
    check look.cacheDecision == cdmGroupOptOut
    check c.loadCalls == 0  # never consulted the cache

  test "--no-cache (globalOff) → cdmPolicyDisabled in lookupAtPlan":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOff, seamsHit(c))
    check look.cacheDecision == cdmPolicyDisabled
    check c.loadCalls == 0

  test "cdmGroupOptOut ≠ cdmPolicyDisabled (they are distinct enum values)":
    check cdmGroupOptOut != cdmPolicyDisabled

  ## shouldStore propagation
  test "csFalse → cdmGroupOptOut from shouldStore (not cdmPolicyDisabled)":
    let r = EntrypointResult(ep: Entrypoint(path: "p"),
                             outcome: oPassed, achieved: fullAchieved)
    let v = shouldStore(r, isoSpec, 1, globalOn, csFalse)
    check not v.store
    check v.decision == cdmGroupOptOut

  test "--no-cache → cdmPolicyDisabled from shouldStore":
    let r = EntrypointResult(ep: Entrypoint(path: "p"),
                             outcome: oPassed, achieved: fullAchieved)
    let v = shouldStore(r, isoSpec, 1, globalOff, csDefault)
    check not v.store
    check v.decision == cdmPolicyDisabled

# ---------------------------------------------------------------------------
# (c) resolveCacheable never emits cdmHit as a pre-lookup sentinel
# ---------------------------------------------------------------------------

suite "M8 (c) — resolveCacheable pre-lookup sentinel is neutral, not cdmHit":

  test "permitted path (global on + not csFalse) returns neutral sentinel, not cdmHit":
    ## Before M8: CacheableResolution.decision was set to cdmHit on the
    ## permitted path — semantically wrong (no lookup has occurred yet).
    ## After M8: it is cdmNotEligible (neutral sentinel; 'decision' field
    ## is only meaningful when readOk/writeOk is false).
    let r = resolveCacheable(globalOn, csDefault)
    check r.readOk    # permitted
    check r.writeOk
    check r.decision != cdmHit  # cdmHit must NOT appear before any lookup

  test "permitted path sentinel is cdmNotEligible (neutral ord 0)":
    let r = resolveCacheable(globalOn, csDefault)
    check r.decision == cdmNotEligible

  test "permitted path with csTrue is also neutral":
    let r = resolveCacheable(globalOn, csTrue)
    check r.readOk
    check r.writeOk
    check r.decision != cdmHit

  test "cdmHit only appears as a result of a real cache lookup (in lookupAtPlan)":
    ## After a real HIT through lookupAtPlan, cdmHit is correct.
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOn, seamsHit(c))
    check look.decision == edCached
    check look.cacheDecision == cdmHit  # correct: a real hit occurred
    check c.loadCalls == 1

  test "a MISS does NOT produce cdmHit":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh, csDefault), globalOn, seamsMiss(c))
    check look.cacheDecision != cdmHit
    check look.cacheDecision == cdmKeyMiss  # correct: miss, not yet stored

echo "test_m8_cache_decision: done"
