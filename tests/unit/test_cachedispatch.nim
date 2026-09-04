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

import std/[options, os, sequtils, strutils, unittest]
import crisol/[types, sandbox, cachedispatch, resultcache, planner, depgraph]
import crisol/process/types  # pkCached/pkSkipped (rfc-0007 A1c coherence test)
import crisol/keys           # KeyDiff, KeyComponent (kcFlags/kcHermeticEnv)
import crisol/cacheregistry  # localOnlyCache -- a real CacheRuntime + local root
import crisol/cachelocalfs   # sidecarPath -- raw sidecar file inspection
import crisol/cachetier      # CacheLookup, TierHit -- RFC-0005 B1c PlanLookup.explain tests
import "../support/helpers"  # legacySeams

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

proc legacyKey(pep: PlannedEntrypoint): SoundnessKey = SoundnessKey("k-" & pep.ep.path)

proc seamsHit(c: var Calls; cr: CachedResult): CacheSeams =
  let cp = addr c
  legacySeams(
    keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; legacyKey(pep),
    load = proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls; some(cr),
    store = proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

proc seamsMiss(c: var Calls): CacheSeams =
  let cp = addr c
  legacySeams(
    keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
             inc cp[].keyCalls; legacyKey(pep),
    load = proc(key: SoundnessKey): Option[CachedResult] =
             inc cp[].loadCalls; none(CachedResult),
    store = proc(key: SoundnessKey; res: CachedResult): bool =
             inc cp[].storeCalls; true,
  )

proc seamsMissWithExplain(c: var Calls; explain: seq[KeyDiff]): CacheSeams =
  ## RFC-0005 B1c: a seam whose `load` always misses but returns a caller-
  ## supplied `.explain` -- lets tests assert PlanLookup.explain threading
  ## and the diagnostic-consult call-counting independent of any real
  ## sidecar/backend.
  let cp = addr c
  CacheSeams(
    keyOf: proc(pep: PlannedEntrypoint): KeyInputs =
             inc cp[].keyCalls
             KeyInputs(argv: @[pep.ep.path]),
    load: proc(pep: PlannedEntrypoint; d: KeyDerivation): CacheLookup =
             inc cp[].loadCalls
             CacheLookup(hit: none(TierHit), verdicts: @[], explain: explain),
    store: proc(pep: PlannedEntrypoint; d: KeyDerivation; res: CachedResult): bool =
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
    # RFC-0005 A2b: keyOf now returns KeyInputs; dispatch hashes it
    # (soundnessKey) — inputHash is that hash, not keyOf's legacy literal
    # verbatim. `derive` over the SAME legacy-key mapping is the ground
    # truth for what a given pep's hash must be.
    var c1, c2: Calls
    let pep  = freshPep(edRunFresh)
    let look = lookupAtPlan(pep, onPolicy, seamsHit(c1, sampleCached()))
    let expected = $derive(seamsMiss(c2), pep).key
    check look.inputHash == expected
    # The synthesized result also carries the same inputHash.
    check look.synthesized.get.inputHash == expected

  test "A8: lookup surfaces inputHash on a miss (run/v1 reports it on misses too)":
    var c1, c2: Calls
    let pep  = freshPep(edRunFresh)
    let look = lookupAtPlan(pep, onPolicy, seamsMiss(c1))
    check look.inputHash == $derive(seamsMiss(c2), pep).key

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
# RFC-0005 B1c: PlanLookup.explain threading (l.explain -> PlanLookup.explain)
#
# B1b already covers the SEAM (realSeams' load adapter populating
# CacheLookup.explain -- see "realSeams — explain-miss sidecar" below); this
# covers the layer B1c actually adds: lookupAtPlan copying that CacheLookup.
# explain onto the PlanLookup it returns, so the runner can thread it onto
# the live EntrypointResult's keyDiff field.
# ---------------------------------------------------------------------------

suite "lookupAtPlan — PlanLookup.explain threading (RFC-0005 B1c)":

  test "genuine key miss: PlanLookup.explain carries the seam's CacheLookup.explain verbatim":
    var c: Calls
    let diffs = @[
      KeyDiff(component: kcFlags, prev: "aaaa1111", curr: "bbbb2222"),
      KeyDiff(component: kcHermeticEnv, prev: "cccc3333", curr: "dddd4444",
              envNames: @["TERM"]),
    ]
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsMissWithExplain(c, diffs))
    check look.cacheDecision == cdmKeyMiss
    check look.explain == diffs

  test "genuine key miss with no prior sidecar record: explain is empty (degraded case, not an error)":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsMissWithExplain(c, @[]))
    check look.cacheDecision == cdmKeyMiss
    check look.explain.len == 0

  test "a served hit carries empty explain (nothing to explain)":
    var c: Calls
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, sampleCached()))
    check look.cacheDecision == cdmHit
    check look.explain.len == 0

  test "not-eligible / policy-disabled early returns carry empty explain (seam never consulted)":
    var c1, c2: Calls
    check lookupAtPlan(freshPep(edNeverBuilt), onPolicy,
                       seamsHit(c1, sampleCached())).explain.len == 0
    check lookupAtPlan(freshPep(edRunFresh), offPolicy,
                       seamsHit(c2, sampleCached())).explain.len == 0

  test "cdmRecomputeMiss carries empty explain (an entry WAS found; nothing to diff)":
    var c: Calls
    var badCr = sampleCached()
    badCr.run.exit = Exit(kind: ekExited, code: 1)   # now derives oFailed, not oPassed
    let look = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsHit(c, badCr))
    check look.cacheDecision == cdmRecomputeMiss
    check look.explain.len == 0

# ---------------------------------------------------------------------------
# RFC-0005 B1c (coordinator ruling): the diagnostic consult for a
# recompiling (non-edRunFresh) entrypoint, gated on `explainDiag`.
#
# A flag change is the LOAD-BEARING explain-miss scenario (RFC line 375's
# "your flags changed") but a flag change NEVER produces edRunFresh
# (planner.slug hashes ALL flags into the bin dir), so without this
# diagnostic consult explainMiss could never explain the single most
# common real-world miss. The consult is READ-ONLY: it must never change
# `decision`/`cacheDecision`/`synthesized` — only `explain`.
# ---------------------------------------------------------------------------

suite "lookupAtPlan — diagnostic consult for non-edRunFresh entrypoints (RFC-0005 B1c ruling)":

  test "edNeverBuilt + explainDiag=true: consults the seam, carries explain, cacheDecision UNCHANGED":
    var c: Calls
    let diffs = @[KeyDiff(component: kcFlags, prev: "aaaa1111", curr: "bbbb2222")]
    let look = lookupAtPlan(freshPep(edNeverBuilt), onPolicy,
                            seamsMissWithExplain(c, diffs), explainDiag = true)
    check look.decision == edNeverBuilt        # UNCHANGED: no promotion
    check look.cacheDecision == cdmNotEligible  # UNCHANGED: A2c's job, not this diagnostic
    check look.synthesized.isNone               # UNCHANGED: never served from cache
    check look.explain == diffs                 # the diagnostic DID run
    check c.loadCalls == 1
    check c.keyCalls == 1

  test "edStale + explainDiag=true: same diagnostic consult, same non-promotion guarantee":
    var c: Calls
    let diffs = @[KeyDiff(component: kcHermeticEnv, prev: "x", curr: "y", envNames: @["TERM"])]
    let look = lookupAtPlan(freshPep(edStale), onPolicy,
                            seamsMissWithExplain(c, diffs), explainDiag = true)
    check look.decision == edStale
    check look.cacheDecision == cdmNotEligible
    check look.explain == diffs
    check c.loadCalls == 1

  test "edNeverBuilt + explainDiag=true, no prior sidecar record: explain empty, still no promotion":
    var c: Calls
    let look = lookupAtPlan(freshPep(edNeverBuilt), onPolicy,
                            seamsMissWithExplain(c, @[]), explainDiag = true)
    check look.cacheDecision == cdmNotEligible
    check look.explain.len == 0
    check c.loadCalls == 1   # the seam WAS asked; it just had nothing to diff against

  test "edNeverBuilt + explainDiag=false (default): the seam is NEVER consulted -- zero I/O waste":
    ## The exact regression this test exists to catch: without --explain-miss
    ## the diagnostic consult must not run at all (not merely produce no
    ## OUTPUT) -- one spurious backend `get` per recompiling entrypoint per
    ## run would be pure I/O waste, and on a future remote tier a pointless
    ## network round-trip at plan time. Call-counting seams make "did we
    ## even ask" observable, not just "was the answer empty".
    var c: Calls
    let look = lookupAtPlan(freshPep(edNeverBuilt), onPolicy,
                            seamsMissWithExplain(c, @[KeyDiff(component: kcFlags,
                                                              prev: "a", curr: "b")]))
    check look.explain.len == 0   # discarded -- never even fetched
    check c.loadCalls == 0        # THE regression guard: zero backend calls
    check c.keyCalls == 0

  test "edStale + explainDiag=false (default): same zero-I/O guarantee":
    var c: Calls
    discard lookupAtPlan(freshPep(edStale), onPolicy, seamsMissWithExplain(c, @[]))
    check c.loadCalls == 0
    check c.keyCalls == 0

  test "edRunFresh is unaffected by explainDiag (the normal path already consults unconditionally)":
    ## explainDiag only gates the NON-edRunFresh branch; the edRunFresh path
    ## already calls seams.load unconditionally (B1b) regardless of this flag.
    var c1, c2: Calls
    let diffs = @[KeyDiff(component: kcFlags, prev: "a", curr: "b")]
    let lookOff = lookupAtPlan(freshPep(edRunFresh), onPolicy, seamsMissWithExplain(c1, diffs))
    let lookOn  = lookupAtPlan(freshPep(edRunFresh), onPolicy,
                               seamsMissWithExplain(c2, diffs), explainDiag = true)
    check lookOff.explain == diffs
    check lookOn.explain == diffs
    check c1.loadCalls == 1
    check c2.loadCalls == 1

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

    # RFC-0005 A2b: keyOfProc(ctx, graph) is what the key-derivation tests
    # call directly — no CacheRuntime/backend needed to exercise key logic.
    let ctx1 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
                          spec = spec, parentEnv = env1, protocolMajor = 1)
    let ctx2 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
                          spec = spec, parentEnv = env2, protocolMajor = 1)
    let keyOf1 = keyOfProc(ctx1, addr g)
    let keyOf2 = keyOfProc(ctx2, addr g)

    let k1 = keyOf1(pep)
    let k2 = keyOf2(pep)
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

    let ctx1 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
                          spec = spec, parentEnv = env1, protocolMajor = 1)
    let ctx2 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
                          spec = spec, parentEnv = env2, protocolMajor = 1)
    let keyOf1 = keyOfProc(ctx1, addr g)
    let keyOf2 = keyOfProc(ctx2, addr g)

    let k1 = keyOf1(pep)
    let k2 = keyOf2(pep)
    check k1 == k2   # TMPDIR value must NOT enter the key (per-run noise)

# ---------------------------------------------------------------------------
# realSeams — explain-miss sidecar (RFC-0005 B1b)
# ---------------------------------------------------------------------------
##
## Drives the REAL local-fs seams end to end (localOnlyCache -> realSeams ->
## cachelocalfs), via `derive`/`seams.store`/`seams.load` directly -- the
## tracer property: through the real dispatch + local-fs path, not
## hand-built sidecar fixtures.

proc freshStateDir(tag: string): string =
  result = getTempDir() / ("crisol_b1b_dispatch_" & tag)
  removeDir(result)
  createDir(result)

proc samplePassResult(exitCode = 0): CachedResult =
  CachedResult(
    run: ProcessResult(
      exit:     Exit(kind: ekExited, code: exitCode),
      cause:    Cause(by: cbProcess),
      evidence: default(Evidence),
      rusage:   none(Rusage),
      durationUs: 1000,
    ),
    records: @[], cachedAt: 1_700_000_000'i64)

proc pepAt(path: string; flags: seq[string] = @[]): PlannedEntrypoint =
  PlannedEntrypoint(ep: Entrypoint(path: path, group: "unit", flags: flags),
                    edecision: edRunFresh)

suite "realSeams — explain-miss sidecar (RFC-0005 B1b)":

  test "store then flag-changed lookup -> miss with explain naming kcFlags":
    let sd = freshStateDir("flags")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
                         spec = spec, parentEnv = @[("HOME", "/root"), ("PATH", "/usr/bin")],
                         protocolMajor = 1)
    let seams = realSeams(ctx, addr g, rt)

    let pep1 = pepAt("tests/unit/test_flagchange.nim", @["--flagA"])
    let d1 = derive(seams, pep1)
    check seams.store(pep1, d1, samplePassResult())

    let pep2 = pepAt("tests/unit/test_flagchange.nim", @["--flagB"])
    let d2 = derive(seams, pep2)
    let lookup2 = seams.load(pep2, d2)
    check lookup2.hit.isNone
    check lookup2.explain.anyIt(it.component == kcFlags)

  test "env-value-changed lookup -> miss with explain naming kcHermeticEnv + the var name":
    let sd = freshStateDir("envval")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)

    let ctx1 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                          parentEnv = @[("HOME", "/root"), ("PATH", "/usr/bin")], protocolMajor = 1)
    let ctx2 = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                          parentEnv = @[("HOME", "/root"), ("PATH", "/usr/local/bin")], protocolMajor = 1)
    let seams1 = realSeams(ctx1, addr g, rt)
    let seams2 = realSeams(ctx2, addr g, rt)

    let pep = pepAt("tests/unit/test_envchange.nim")
    let d1 = derive(seams1, pep)
    check seams1.store(pep, d1, samplePassResult())

    let d2 = derive(seams2, pep)
    let lookup2 = seams2.load(pep, d2)
    check lookup2.hit.isNone
    let envDiffs = lookup2.explain.filterIt(it.component == kcHermeticEnv)
    check envDiffs.len == 1
    check "PATH" in envDiffs[0].envNames

  test "first-ever miss (no sidecar) -> empty explain, no error":
    let sd = freshStateDir("firstmiss")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                         parentEnv = @[("HOME", "/root")], protocolMajor = 1)
    let seams = realSeams(ctx, addr g, rt)
    let pep = pepAt("tests/unit/test_neverseen.nim")
    let d = derive(seams, pep)
    let lookup = seams.load(pep, d)
    check lookup.hit.isNone
    check lookup.explain.len == 0

  test "corrupt sidecar JSON -> treated as absent, no crash":
    let sd = freshStateDir("corruptsc")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                         parentEnv = @[("HOME", "/root")], protocolMajor = 1)
    let seams = realSeams(ctx, addr g, rt)
    let pep = pepAt("tests/unit/test_corruptsc.nim")

    let scPath = sidecarPath(rt.localRoot, pep.ep.path)
    createDir(parentDir(scPath))
    writeFile(scPath, "{ broken")

    let d = derive(seams, pep)
    let lookup = seams.load(pep, d)
    check lookup.hit.isNone
    check lookup.explain.len == 0

  test "hit -> no explain attached":
    let sd = freshStateDir("hitnoexplain")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                         parentEnv = @[("HOME", "/root")], protocolMajor = 1)
    let seams = realSeams(ctx, addr g, rt)
    let pep = pepAt("tests/unit/test_hit.nim")
    let d = derive(seams, pep)
    check seams.store(pep, d, samplePassResult())
    let lookup = seams.load(pep, d)
    check lookup.hit.isSome
    check lookup.explain.len == 0

  test "values never persisted: sidecar file never contains a raw env VALUE":
    let sd = freshStateDir("novalues")
    let rt = localOnlyCache(sd, maxEntries = 0)
    var g = emptyDepGraph()
    let spec = resolveSandbox(hlIsolated)
    let sentinel = "sentinel-super-secret-9f8e7d"
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                         parentEnv = @[("HOME", sentinel), ("PATH", "/usr/bin")], protocolMajor = 1)
    let seams = realSeams(ctx, addr g, rt)
    let pep = pepAt("tests/unit/test_novalues.nim")
    let d = derive(seams, pep)
    check seams.store(pep, d, samplePassResult())

    let scPath = sidecarPath(rt.localRoot, pep.ep.path)
    check fileExists(scPath)
    let raw = readFile(scPath)
    check sentinel notin raw

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
