## test_cachetier.nim — RFC-0005 A1/A3a: `TieredCache` `lookup`/`put`,
## boundary-tested over the `memory`/`memoryBytes` doubles (`cachememory.nim`)
## AND, from A2a, the real `local-fs` backend (`cachelocalfs.nim`) — the
## RFC's "the localFs backend must pass the SAME boundary suite as
## memory/memoryBytes" requirement. Grows in place — A1 shipped the
## single-tier engine; A3a lifts that restriction and adds the general
## N-tier waterfall, backfill-on-hit + the verified-bit rule, the put rule,
## the per-tier circuit breaker, the deferred-put drain, and
## `cacheregistry`'s `BackendRegistry`, per RFC-0005's fixture/test-file
## inventory ("one `test_cachetier.nim` across A1/A3a").
##
## Coverage:
##   1. roundtrip: put then lookup returns a hit, `verified == true`
##      (nonePolicy) — over all three backends (memory/memoryBytes/localFs).
##   2. miss: lookup on an absent key -> hit none, verdicts == [(tier,
##      cvMiss)], worst == cvMiss — over all three backends.
##   3. storageVersion mismatch -> cvVersionSkew, via memory/memoryBytes AND
##      localFs (a caller-supplied `StoredEntry.storageVersion` survives
##      `put` on all three — `memoryBytes`/`localFs`'s `encode` writes
##      exactly what it is given, and `memory`'s `put` only ever recomputes
##      `payloadChecksum`, never `storageVersion`). Checksum-recompute
##      mismatch (`cvCorrupt`) is NOT representable through any backend's
##      `put` (all three faithfully mirror `resultcache.storeCached`'s
##      contract and unconditionally recompute `payloadChecksum` at write
##      time) — `localFs` uniquely CAN exercise it by tampering the file
##      directly on disk (below), the same on-disk-tamper pattern
##      `test_resultcache.nim` already uses.
##   4. `probe` is nil on all three backends (`canProbe == false`) — no
##      producer yet (Stage C3c).
##   5. RFC-0005 A3a: the multi-tier waterfall — miss falls through, first
##      hit wins with no fall-through, all-miss, and `put`'s fan-out to
##      every tier (A1's `doAssert`-refused-second-tier tests are GONE:
##      multi-tier is now the real, tested behavior).
##   6. the controllable mock `TrustPolicy` + trust rejection on an
##      intermediate tier continues the waterfall (never aborts), recording
##      the SPECIFIC trust code, not a generic miss.
##   7. the verified-bit backfill rule, exhaustive 2x2x2 (source verified x
##      destination verifyTrust x single-/multi-upstream-tier ordering).
##   8. the put rule, exhaustive 2x2 (attested x destination verifyTrust),
##      via `tc.put` directly (a fresh publish, not a backfill).
##   9. the per-tier circuit breaker: trips on first offline/timeout, stays
##      dead the rest of the run (proven by call-counting, not a clock —
##      see `cachetier.nim`'s module doc), never trips on a plain miss, is
##      per-tier independent, and short-circuits a backfill target tripped
##      earlier in the SAME lookup call.
##   10. the deferred-put drain (`drainPending`): flushes a caller-owned
##       queue, and respects a total attempt budget.
##   10b. RFC-0005 A3c-ii: `putLocal` — the synchronous, tier-0-only half of
##       the deferred-put split (put rule + breaker, scoped to tier 0);
##       paired with `drainPending` for the remote tiers.
##   11. `tekBackfillErr`'s producer (`cachetelemetry.backfillErrEvents`
##       over `CacheLookup.backfillVerdicts`) + its fold into
##       `aggregateCacheStats.remoteErrors`.
##   12. `cacheregistry`: `BackendRegistry`/`buildBackend` resolves by URL
##       scheme; `productionRegistry` has no `memory://`; `testRegistry`
##       adds `memory://`/`memorybytes://` and keeps `file://`; an unknown
##       scheme resolves to `none`.
##   13. localFs-specific (A2a): checksum tamper on disk -> cvCorrupt; a
##      pre-0005 file (RFC-0004 shape, no envelope keys) decodes; offline
##      semantics (missing root, non-autoCreate; a FILE blocking the root —
##      ENOTDIR, regardless of autoCreate) -> cvOffline on get AND put;
##      autoCreate creates the root on demand and a fresh get on it is a
##      clean miss, never offline; the soft cap skips a new-key put once the
##      version dir is at capacity, rate-limited stderr warning included.
##      13i (B1b-prereq regression): `localFsBackend` and the legacy
##      resultcache helpers (`loadCachedAt`/`storeCachedAt`/
##      `gcResultCacheAt`) agree on ONE version dir for a shared root — an
##      entry `localFsBackend.put` writes is visible to `loadCachedAt` AND
##      actually walked (and evictable) by `gcResultCacheAt`; a
##      `storeCachedAt` entry is visible to `localFsBackend.get` — the
##      A2a-era divergence this fixes.
##   14. RFC-0005 A3c-ii: `cacheregistry.configuredCache` — builds a real
##      multi-tier `TieredCache` from `CacheConfig.remotes`; no-remotes ->
##      `localOnlyCache`-equivalent; rejects an `"l1"`-named remote, a
##      `file://` root inside `stateDir` (equal OR nested), and an
##      unresolvable scheme, each as `CrisolError(cekConfig)`; resolves
##      `verify-trust`'s default to `false` (no `cache-trust` parser before
##      C4) while honoring an explicit override; the built tier is exercised
##      live through the real file backend.

import std/[json, options, os, strutils, tables]
import crisol/types
import crisol/keys
import crisol/cacheport
import crisol/cachewire
import crisol/cachetier
import crisol/cachememory
import crisol/cachelocalfs
import crisol/cachetelemetry  # RFC-0005 A3a: backfillErrEvents/aggregateCacheStats wiring
import crisol/cacheregistry   # RFC-0005 A3a: BackendRegistry/buildBackend
import crisol/resultcache
import crisol/depgraph  # fnv1a64/toHex16 -- recompute a matching checksum by hand (6b)
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc sampleProcessResult(exitCode: int = 0): ptypes.ProcessResult =
  ptypes.ProcessResult(
    exit:  ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
    cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: ptypes.Evidence(
      killDomain: ptypes.kdsProcessGroup,
      tree:       ptypes.toComplete,
      escapees:   @[],
      limits:     default(ptypes.LimitsAchieved),
      hermetic:   ptypes.hlIsolated,
      killSnapshot: @[],
      cooperativeUnavailable: false,
    ),
    rusage: none(ptypes.Rusage),
    durationUs: 42_000,
  )

proc sampleCachedResult(exitCode: int = 0): CachedResult =
  CachedResult(
    run: sampleProcessResult(exitCode),
    records: @[],
    cachedAt: 1_700_001_000'i64,
    payloadChecksum: "",
  )

proc sampleEntry(key: SoundnessKey; exitCode = 0): StoredEntry =
  StoredEntry(
    key:            key,
    keyInputs:      none(KeyInputs),
    result:         sampleCachedResult(exitCode),
    storageVersion: storageFormatVersion,
    attestation:    none(Attestation),
  )

proc oneTier(backend: CacheBackend; name = "l1"): TieredCache =
  TieredCache(tiers: @[Tier(name: name, backend: backend, backfillOnHit: false,
                            verifyTrust: false)],
              trust: nonePolicy())

type DoubleKind = enum dkMemory, dkMemoryBytes, dkLocalFs

proc freshLocalFsRoot(name: string): string =
  ## A fresh, empty directory each call — mirrors `test_resultcache.nim`'s
  ## `freshStateDir` convention. `localFsBackend` needs a real directory to
  ## roundtrip through (the tracer property: a StoredEntry survives an
  ## actual filesystem, not just an in-memory double).
  result = getTempDir() / ("crisol_cachelocalfs_" & name)
  removeDir(result)
  createDir(result)

proc makeBackend(kind: DoubleKind; root = ""): CacheBackend =
  case kind
  of dkMemory: memory()
  of dkMemoryBytes: memoryBytes(jsonCacheSerializer())
  of dkLocalFs: localFsBackend(root, autoCreate = true, maxEntries = 0)

# ---------------------------------------------------------------------------
# 1/2. roundtrip + miss, over all three backends
# ---------------------------------------------------------------------------

for kind in [dkMemory, dkMemoryBytes, dkLocalFs]:
  block:
    let root = if kind == dkLocalFs: freshLocalFsRoot("roundtrip_" & $kind) else: ""
    var tc = oneTier(makeBackend(kind, root))
    let key = SoundnessKey("1111000022220000")
    let entry = sampleEntry(key, exitCode = 5)

    let putVerdicts = tc.put(entry)
    assert putVerdicts.len == 1
    assert putVerdicts[0].tier == "l1"
    assert putVerdicts[0].verdict == cvOk

    let l = tc.lookup(key)
    assert l.hit.isSome, "put then lookup must hit (" & $kind & ")"
    assert l.hit.get.result.run.exit.code == 5
    assert l.hit.get.tier == "l1"
    assert l.hit.get.verified == true, "nonePolicy.verify is unconditionally cvOk"
    assert l.verdicts == @[(tier: "l1", verdict: cvOk)]
    assert worst(l) == cvOk

    let missLookup = tc.lookup(SoundnessKey("deadbeefdeadbeef"))
    assert missLookup.hit.isNone
    assert missLookup.verdicts == @[(tier: "l1", verdict: cvMiss)]
    assert worst(missLookup) == cvMiss

# ---------------------------------------------------------------------------
# 3. storageVersion mismatch -> cvVersionSkew, over both doubles
# ---------------------------------------------------------------------------

block test_storage_version_mismatch_memory:
  var tc = oneTier(memory())
  let key = SoundnessKey("4444eeee5555ffff")
  discard tc.put(sampleEntry(key, exitCode = 2))

  let fetched = tc.tiers[0].backend.get(key)
  assert fetched.verdict == cvOk
  var bad = fetched.value
  bad.storageVersion = storageFormatVersion + 1
  discard tc.tiers[0].backend.put(bad)

  let l = tc.lookup(key)
  assert l.hit.isNone
  assert l.verdicts == @[(tier: "l1", verdict: cvVersionSkew)]
  assert worst(l) == cvVersionSkew

block test_storage_version_mismatch_memory_bytes:
  var tc = oneTier(memoryBytes(jsonCacheSerializer()))
  let key = SoundnessKey("5555111166662222")
  var bad = sampleEntry(key, exitCode = 2)
  bad.storageVersion = storageFormatVersion + 1
  discard tc.put(bad)

  let l = tc.lookup(key)
  assert l.hit.isNone
  assert l.verdicts == @[(tier: "l1", verdict: cvVersionSkew)]
  assert worst(l) == cvVersionSkew

block test_storage_version_mismatch_localfs:
  let root = freshLocalFsRoot("skew")
  var tc = oneTier(localFsBackend(root, autoCreate = true, maxEntries = 0))
  let key = SoundnessKey("6666222277773333")
  var bad = sampleEntry(key, exitCode = 2)
  bad.storageVersion = storageFormatVersion + 1
  discard tc.put(bad)

  let l = tc.lookup(key)
  assert l.hit.isNone
  assert l.verdicts == @[(tier: "l1", verdict: cvVersionSkew)]
  assert worst(l) == cvVersionSkew

# ---------------------------------------------------------------------------
# 4. probe is nil on all three backends — no producer yet (Stage C3c)
# ---------------------------------------------------------------------------

block test_probe_is_nil_on_all_backends:
  assert not canProbe(memory())
  assert not canProbe(memoryBytes(jsonCacheSerializer()))
  assert not canProbe(localFsBackend(freshLocalFsRoot("probe"), autoCreate = true, maxEntries = 0))

# ---------------------------------------------------------------------------
# 5. RFC-0005 A3a: the multi-tier waterfall (A1's single-tier restriction
#    lifted -- replaced by the real N-tier engine).
# ---------------------------------------------------------------------------

proc twoTier(b0, b1: CacheBackend; backfill0 = false; verifyTrust0 = false;
             verifyTrust1 = false; trust = nonePolicy()): TieredCache =
  TieredCache(
    tiers: @[
      Tier(name: "l1", backend: b0, backfillOnHit: backfill0, verifyTrust: verifyTrust0),
      Tier(name: "l2", backend: b1, backfillOnHit: false, verifyTrust: verifyTrust1),
    ],
    trust: trust,
  )

block test_multi_tier_lookup_falls_through_on_miss:
  var tc = twoTier(memory(), memory())
  let key = SoundnessKey("2020202020202020")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 4))  # only l2 has it

  let l = tc.lookup(key)
  assert l.hit.isSome, "a miss on l1 must fall through to l2"
  assert l.hit.get.tier == "l2"
  assert l.hit.get.result.run.exit.code == 4
  assert l.verdicts == @[(tier: "l1", verdict: cvMiss), (tier: "l2", verdict: cvOk)]
  assert worst(l) == cvMiss, "a real miss upstream stays attributable even though l2 served"

block test_multi_tier_first_hit_wins_no_fallthrough:
  var tc = twoTier(memory(), memory())
  let key = SoundnessKey("3030303030303030")
  discard tc.tiers[0].backend.put(sampleEntry(key, exitCode = 1))
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 9))  # must never be consulted

  let l = tc.lookup(key)
  assert l.hit.get.tier == "l1"
  assert l.hit.get.result.run.exit.code == 1
  assert l.verdicts == @[(tier: "l1", verdict: cvOk)], "l2 must not even be consulted once l1 hits"

block test_multi_tier_miss_on_all_tiers:
  var tc = twoTier(memory(), memory())
  let l = tc.lookup(SoundnessKey("4040404040404040"))
  assert l.hit.isNone
  assert l.verdicts == @[(tier: "l1", verdict: cvMiss), (tier: "l2", verdict: cvMiss)]
  assert worst(l) == cvMiss

block test_multi_tier_put_fans_out_to_all_tiers:
  var tc = twoTier(memory(), memory())
  let key = SoundnessKey("5050505050505050")
  let vs = tc.put(sampleEntry(key, exitCode = 7))
  assert vs == @[(tier: "l1", verdict: cvOk), (tier: "l2", verdict: cvOk)]
  assert tc.tiers[0].backend.get(key).verdict == cvOk
  assert tc.tiers[1].backend.get(key).verdict == cvOk

# ---------------------------------------------------------------------------
# 6. RFC-0005 A3a: the controllable mock TrustPolicy + trust rejection
#    continues the waterfall (never aborts the search).
# ---------------------------------------------------------------------------

proc mockPolicy(verifyResult: CacheVerdict; attest: bool): TrustPolicy =
  ## `nonePolicy.verify` is UNCONDITIONALLY `cvOk`, so the security-
  ## meaningful reject cases (RFC "the security-meaningful cases cannot be
  ## exercised until a policy that can reject exists") need a controllable
  ## double: `verify` returns whatever the test wants; `sign` attaches an
  ## `Attestation` iff `attest` (a no-op otherwise, exactly like
  ## `nonePolicy.sign`).
  TrustPolicy(
    name: "mock",
    verify: proc(entry: StoredEntry): CacheVerdict = verifyResult,
    sign: proc(entry: var StoredEntry) =
      if attest:
        entry.attestation = some(Attestation(sigAlg: saHmacSha256, signer: "mock-signer",
                                              signature: "sig", signedAt: 0)),
  )

block test_trust_reject_on_intermediate_tier_continues_waterfall:
  var tc = twoTier(memory(), memory(), verifyTrust0 = true,
                    trust = mockPolicy(cvTrustBadSignature, attest = false))
  let key = SoundnessKey("6060606060606060")
  discard tc.tiers[0].backend.put(sampleEntry(key, exitCode = 2))
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 3))

  let l = tc.lookup(key)
  assert l.hit.isSome, "l2 does not verifyTrust, so it still serves despite the mock's reject verdict"
  assert l.hit.get.tier == "l2"
  assert l.hit.get.result.run.exit.code == 3
  assert l.hit.get.verified == false, "verify ran (and rejected) even on l2's non-verifyTrust read"
  assert l.verdicts == @[(tier: "l1", verdict: cvTrustBadSignature), (tier: "l2", verdict: cvOk)],
    "l1's specific trust code is recorded, not a generic miss -- and the search continues"

# ---------------------------------------------------------------------------
# 7. RFC-0005 A3a: the verified-bit backfill rule -- exhaustive 2x2x2
#    (source verified in {T,F} x destination verifyTrust in {T,F} x
#    single-upstream-tier vs multiple-upstream-tier ordering).
# ---------------------------------------------------------------------------

proc backfillSetup(destVerifyTrust: bool; policy: TrustPolicy): TieredCache =
  TieredCache(
    tiers: @[
      Tier(name: "l1", backend: memory(), backfillOnHit: true, verifyTrust: destVerifyTrust),
      Tier(name: "l2", backend: memory(), backfillOnHit: false, verifyTrust: false),
    ],
    trust: policy,
  )

block test_backfill_verified_true_dest_verifytrust_true_backfills:
  var tc = backfillSetup(destVerifyTrust = true, policy = mockPolicy(cvOk, attest = true))
  let key = SoundnessKey("7070707070707070")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 1))

  let l = tc.lookup(key)
  assert l.hit.get.verified == true
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOk)]
  assert tc.tiers[0].backend.get(key).verdict == cvOk, "a verified hit may backfill a verifyTrust tier"

block test_backfill_verified_true_dest_verifytrust_false_backfills:
  var tc = backfillSetup(destVerifyTrust = false, policy = mockPolicy(cvOk, attest = true))
  let key = SoundnessKey("8080808080808080")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 1))

  let l = tc.lookup(key)
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOk)]
  assert tc.tiers[0].backend.get(key).verdict == cvOk

block test_backfill_verified_false_dest_verifytrust_true_is_skipped:
  var tc = backfillSetup(destVerifyTrust = true, policy = mockPolicy(cvTrustBadSignature, attest = false))
  let key = SoundnessKey("9090909090909090")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 1))

  let l = tc.lookup(key)
  assert l.hit.isSome, "l2 itself has verifyTrust=false, so the hit still serves"
  assert l.hit.get.verified == false
  assert l.backfillVerdicts.len == 0,
    "an unverified entry must NOT populate a verifyTrust destination tier"
  assert tc.tiers[0].backend.get(key).verdict == cvMiss, "l1 must remain empty"

block test_backfill_verified_false_dest_verifytrust_false_still_backfills:
  var tc = backfillSetup(destVerifyTrust = false, policy = mockPolicy(cvTrustBadSignature, attest = false))
  let key = SoundnessKey("a0a0a0a0a0a0a0a0")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 1))

  let l = tc.lookup(key)
  assert l.hit.get.verified == false
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOk)],
    "an unverified entry MAY populate a tier that does not verify trust"
  assert tc.tiers[0].backend.get(key).verdict == cvOk

block test_backfill_multiple_upstream_tiers_all_qualify_in_order:
  var tc = TieredCache(
    tiers: @[
      Tier(name: "l1", backend: memory(), backfillOnHit: true, verifyTrust: false),
      Tier(name: "l2", backend: memory(), backfillOnHit: true, verifyTrust: true),
      Tier(name: "l3", backend: memory(), backfillOnHit: false, verifyTrust: false),
    ],
    trust: mockPolicy(cvOk, attest = true),
  )
  let key = SoundnessKey("b0b0b0b0b0b0b0b0")
  discard tc.tiers[2].backend.put(sampleEntry(key, exitCode = 5))  # only l3 (the served tier) has it

  let l = tc.lookup(key)
  assert l.hit.get.tier == "l3"
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOk), (tier: "l2", verdict: cvOk)],
    "every qualifying upstream tier backfills, in tier order -- not just the immediate neighbor"
  assert tc.tiers[0].backend.get(key).verdict == cvOk
  assert tc.tiers[1].backend.get(key).verdict == cvOk

# ---------------------------------------------------------------------------
# 8. RFC-0005 A3a: the put rule -- exhaustive 2x2 (attested x destination
#    verifyTrust), via tc.put directly (a fresh publish, not a backfill).
# ---------------------------------------------------------------------------

proc oneVerifyingTier(verifyTrust: bool; policy: TrustPolicy): TieredCache =
  TieredCache(tiers: @[Tier(name: "l1", backend: memory(), backfillOnHit: false,
                            verifyTrust: verifyTrust)],
              trust: policy)

block test_put_rule_attested_true_dest_verifytrust_true_writes:
  var tc = oneVerifyingTier(verifyTrust = true, policy = mockPolicy(cvOk, attest = true))
  let vs = tc.put(sampleEntry(SoundnessKey("c0c0c0c0c0c0c0c0")))
  assert vs == @[(tier: "l1", verdict: cvOk)]

block test_put_rule_attested_true_dest_verifytrust_false_writes:
  var tc = oneVerifyingTier(verifyTrust = false, policy = mockPolicy(cvOk, attest = true))
  let vs = tc.put(sampleEntry(SoundnessKey("d0d0d0d0d0d0d0d0")))
  assert vs == @[(tier: "l1", verdict: cvOk)]

block test_put_rule_attested_false_dest_verifytrust_true_refuses:
  var tc = oneVerifyingTier(verifyTrust = true, policy = mockPolicy(cvOk, attest = false))
  let key = SoundnessKey("e0e0e0e0e0e0e0e0")
  let vs = tc.put(sampleEntry(key))
  assert vs == @[(tier: "l1", verdict: cvUnauthorized)],
    "no write credential (no attestation) must refuse a verifyTrust tier"
  assert tc.tiers[0].backend.get(key).verdict == cvMiss, "a refused write must never land"

block test_put_rule_attested_false_dest_verifytrust_false_writes:
  var tc = oneVerifyingTier(verifyTrust = false, policy = mockPolicy(cvOk, attest = false))
  let vs = tc.put(sampleEntry(SoundnessKey("f0f0f0f0f0f0f0f0")))
  assert vs == @[(tier: "l1", verdict: cvOk)],
    "a non-verifyTrust tier accepts an unattested write (matches nonePolicy's own roundtrip test)"

# ---------------------------------------------------------------------------
# 9. RFC-0005 A3a: the per-tier circuit breaker (a permanent-for-the-run
#    latch -- no clock: see cachetier.nim's module doc for why).
# ---------------------------------------------------------------------------

proc countingBackend(getResults: seq[CacheVerdict] = @[];
                      putResults: seq[CacheVerdict] = @[]): tuple[backend: CacheBackend, getCalls, putCalls: ref int] =
  ## A scripted double: call N returns `Results[N]` (clamped to the last
  ## entry once exhausted), counting calls so a test can prove a tripped
  ## tier's backend is NEVER invoked again -- the "fake clock" property
  ## from the RFC's stage-list bullet, proven by call-counting rather than
  ## by an injected timestamp (no elapsed-time decision exists to fake).
  var getIdx = 0
  var putIdx = 0
  let getCalls = new(int)
  let putCalls = new(int)
  let backend = CacheBackend(
    scheme: "counting",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      inc getCalls[]
      let v = getResults[min(getIdx, getResults.len - 1)]
      inc getIdx
      Fetched[StoredEntry](verdict: v)
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      inc putCalls[]
      let v = putResults[min(putIdx, putResults.len - 1)]
      inc putIdx
      v
    ,
    probe: nil,
  )
  (backend, getCalls, putCalls)

block test_circuit_breaker_trips_on_first_offline_and_stays_dead:
  let (backend, getCalls, _) = countingBackend(getResults = @[cvOffline, cvOk, cvOk, cvOk])
  var tc = oneTier(backend)
  let key = SoundnessKey("1111111111111111")

  discard tc.lookup(key)
  assert getCalls[] == 1

  for _ in 0 ..< 3:
    let l = tc.lookup(key)
    assert l.verdicts == @[(tier: "l1", verdict: cvOffline)]
  assert getCalls[] == 1,
    "a tripped tier must never be consulted again, even though the double would now return cvOk"

block test_circuit_breaker_trips_on_timeout:
  let (backend, getCalls, _) = countingBackend(getResults = @[cvTimeout, cvOk])
  var tc = oneTier(backend)
  let key = SoundnessKey("2222222222222222")
  discard tc.lookup(key)
  discard tc.lookup(key)
  assert getCalls[] == 1

block test_circuit_breaker_does_not_trip_on_a_plain_miss:
  let (backend, getCalls, _) = countingBackend(getResults = @[cvMiss, cvMiss])
  var tc = oneTier(backend)
  let key = SoundnessKey("3333333333333333")
  discard tc.lookup(key)
  discard tc.lookup(key)
  assert getCalls[] == 2, "a cold miss must not trip the breaker -- only offline/timeout does"

block test_circuit_breaker_is_per_tier_independent:
  let (b0, get0, _) = countingBackend(getResults = @[cvOffline])
  let (b1, get1, _) = countingBackend(getResults = @[cvOk])
  var tc = twoTier(b0, b1)
  let key = SoundnessKey("4444444444444444")

  let l = tc.lookup(key)
  assert l.hit.isSome
  assert l.hit.get.tier == "l2"
  assert get0[] == 1
  assert get1[] == 1

  discard tc.lookup(key)
  assert get0[] == 1, "l1 stays tripped"
  assert get1[] == 2, "l2 (never tripped) keeps being consulted normally"

block test_circuit_breaker_trips_on_put_and_stays_dead:
  let (backend, _, putCalls) = countingBackend(putResults = @[cvOffline, cvOk])
  var tc = oneTier(backend)
  let entry = sampleEntry(SoundnessKey("5555555555555555"))
  discard tc.put(entry)
  assert putCalls[] == 1
  discard tc.put(entry)
  assert putCalls[] == 1, "a tripped tier's put must never be attempted again"

block test_circuit_breaker_short_circuits_a_backfill_target:
  let (b0, _, put0) = countingBackend(getResults = @[cvOffline], putResults = @[cvOk])
  var tc = twoTier(b0, memory(), backfill0 = true)
  let key = SoundnessKey("6666666666666666")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 2))

  let l = tc.lookup(key)  # l1.get trips the breaker THIS call; l2 serves; backfill to l1 follows
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOffline)],
    "a tier tripped earlier in the SAME lookup call must short-circuit its own backfill write too"
  assert put0[] == 0, "a tripped tier's backend.put must never be reached by backfill either"

# ---------------------------------------------------------------------------
# 10. RFC-0005 A3a/B0: deferred-put drain -- a budget-bounded fold over a
#     caller-owned queue of previously-unpublished entries.
# ---------------------------------------------------------------------------

block test_drain_pending_flushes_every_entry_with_no_budget:
  var tc = oneTier(memory())
  let entries = @[sampleEntry(SoundnessKey("7777000000000001"), exitCode = 1),
                  sampleEntry(SoundnessKey("7777000000000002"), exitCode = 2)]
  let vs = tc.drainPending(entries)
  assert vs == @[(tier: "l1", verdict: cvOk), (tier: "l1", verdict: cvOk)]
  assert tc.tiers[0].backend.get(entries[0].key).verdict == cvOk
  assert tc.tiers[0].backend.get(entries[1].key).verdict == cvOk

block test_drain_pending_respects_a_total_budget:
  let (backend, _, putCalls) = countingBackend(putResults = @[cvOk, cvOk, cvOk])
  var tc = oneTier(backend)
  let entries = @[sampleEntry(SoundnessKey("8888000000000001")),
                  sampleEntry(SoundnessKey("8888000000000002")),
                  sampleEntry(SoundnessKey("8888000000000003"))]
  let vs = tc.drainPending(entries, budget = 2)
  assert vs.len == 2
  assert putCalls[] == 2, "the third queued entry must never be attempted once the budget is spent"

# ---------------------------------------------------------------------------
# 10b. RFC-0005 A3c-ii: `putLocal` — the SYNCHRONOUS half of the deferred-put
#      split. Writes ONLY tier 0 ("l1"); tiers 1..N are untouched (the
#      caller's job to queue + `drainPending` later).
# ---------------------------------------------------------------------------

block test_put_local_writes_only_tier_zero:
  let l1 = memory()
  let remote = memory()
  var tc = twoTier(l1, remote)
  let entry = sampleEntry(SoundnessKey("a1a1000000000001"), exitCode = 3)
  let v = tc.putLocal(entry)
  assert v == (tier: "l1", verdict: cvOk)
  assert tc.tiers[0].backend.get(entry.key).verdict == cvOk
  assert tc.tiers[1].backend.get(entry.key).verdict == cvMiss,
    "putLocal must never reach a downstream (remote) tier"

block test_put_local_then_drain_pending_reaches_remote_too:
  var tc = twoTier(memory(), memory())
  let entry = sampleEntry(SoundnessKey("a1a1000000000002"), exitCode = 4)
  discard tc.putLocal(entry)
  assert tc.tiers[1].backend.get(entry.key).verdict == cvMiss, "not yet -- still queued by the caller"
  let vs = tc.drainPending(@[entry])
  assert vs == @[(tier: "l1", verdict: cvOk), (tier: "l2", verdict: cvOk)]
  assert tc.tiers[1].backend.get(entry.key).verdict == cvOk, "the deferred flush publishes to the remote tier"

block test_put_local_respects_the_put_rule:
  ## An unattested entry must never land on a verifyTrust tier -- same put
  ## rule `put` enforces, just scoped to tier 0 here.
  var tc = twoTier(memory(), memory(), verifyTrust0 = true,
                    trust = mockPolicy(cvOk, attest = false))
  let entry = sampleEntry(SoundnessKey("a1a1000000000003"))
  let v = tc.putLocal(entry)
  assert v == (tier: "l1", verdict: cvUnauthorized)
  assert tc.tiers[0].backend.get(entry.key).verdict == cvMiss, "the unauthorized write must not have landed"

block test_put_local_respects_the_circuit_breaker:
  let (backend, _, putCalls) = countingBackend(putResults = @[cvOffline])
  var tc = oneTier(backend)
  let entry = sampleEntry(SoundnessKey("a1a1000000000004"))
  discard tc.putLocal(entry)
  assert putCalls[] == 1
  let v = tc.putLocal(entry)
  assert v == (tier: "l1", verdict: cvOffline)
  assert putCalls[] == 1, "a tripped l1 must never be attempted again by putLocal either"

# ---------------------------------------------------------------------------
# 11. RFC-0005 A3a coordinator ruling: tekBackfillErr's producer
#     (`cachetelemetry.backfillErrEvents`, over `CacheLookup.backfillVerdicts`)
#     + its fold into `aggregateCacheStats.remoteErrors`.
# ---------------------------------------------------------------------------

block test_backfill_err_events_and_stats:
  let (b0, _, put0) = countingBackend(getResults = @[cvMiss], putResults = @[cvOffline])
  var tc = twoTier(b0, memory(), backfill0 = true)
  let key = SoundnessKey("9999000000000001")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 4))

  let l = tc.lookup(key)
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOffline)]
  assert put0[] == 1

  let events = backfillErrEvents(l)
  assert events.len == 1
  assert events[0].kind == tekBackfillErr
  assert events[0].putTier == "l1"
  assert events[0].putVerdict == cvOffline

  let stats = aggregateCacheStats(events, @[(cdmHit, "l1")])
  assert stats.remoteErrors == 1

block test_backfill_err_events_is_empty_on_a_successful_backfill:
  var tc = twoTier(memory(), memory(), backfill0 = true)
  let key = SoundnessKey("9999000000000002")
  discard tc.tiers[1].backend.put(sampleEntry(key, exitCode = 4))
  let l = tc.lookup(key)
  assert l.backfillVerdicts == @[(tier: "l1", verdict: cvOk)]
  assert backfillErrEvents(l).len == 0

# ---------------------------------------------------------------------------
# 12. RFC-0005 A3a: cacheregistry — BackendRegistry + buildBackend +
#     productionRegistry/testRegistry (scheme-resolved factories).
# ---------------------------------------------------------------------------

block test_registry_resolves_file_scheme:
  let root = freshLocalFsRoot("registry_file")
  let reg = productionRegistry()
  let tier = RemoteTier(name: "team", url: "file://" & root)
  let backend = reg.buildBackend(tier, token = "")
  assert backend.isSome
  let key = SoundnessKey("aaaa111122223333")
  assert backend.get.put(sampleEntry(key, exitCode = 6)) == cvOk
  assert backend.get.get(key).verdict == cvOk

block test_production_registry_has_no_memory_scheme:
  let reg = productionRegistry()
  let tier = RemoteTier(name: "oops", url: "memory://whatever")
  assert reg.buildBackend(tier, token = "").isNone,
    "a typo'd memory:// URL in production must be a config error, not a silent tier"

block test_test_registry_adds_memory_and_memorybytes_and_keeps_file:
  let reg = testRegistry()
  assert reg.buildBackend(RemoteTier(name: "m", url: "memory://x"), token = "").isSome
  assert reg.buildBackend(RemoteTier(name: "mb", url: "memorybytes://x"), token = "").isSome
  let root = freshLocalFsRoot("registry_test_file")
  assert reg.buildBackend(RemoteTier(name: "f", url: "file://" & root), token = "").isSome

block test_registry_unknown_scheme_is_none:
  let reg = testRegistry()
  assert reg.buildBackend(RemoteTier(name: "x", url: "s3://bucket/key"), token = "").isNone

# ---------------------------------------------------------------------------
# 13. localFs-specific (rfc-0005 A2a)
# ---------------------------------------------------------------------------

proc localFsRootPathNoCreate(name: string): string =
  ## A path under the temp dir that does NOT exist yet — for the "missing
  ## root" cases (as opposed to `freshLocalFsRoot`, which pre-creates the
  ## directory for the roundtrip-style tests above).
  result = getTempDir() / ("crisol_cachelocalfs_nocreate_" & name)
  removeDir(result)

proc versionedEntryPath(root: string; key: SoundnessKey): string =
  ## rfc-0005 B1b-prereq: local-fs entries live at `<root>/v<N>/<key>.json`
  ## where N == resultCacheFormatVersion (resultcache.cacheVersionDirAt),
  ## the SAME dir `gcResultCacheAt`/`loadCachedAt`/`storeCachedAt` use for
  ## this root -- NOT `cachewire.storageFormatVersion` (a different axis:
  ## the StoredEntry wire-envelope version, never a local dir name).
  cacheVersionDirAt(root) / ($key & ".json")

# 6a. checksum tamper on disk -> cvCorrupt. Unlike memory/memoryBytes (whose
# `put` always self-heals the checksum — see the module doc comment), a
# real on-disk file CAN be tampered independently of any backend `put`,
# exactly as `test_resultcache.nim`'s `test_checksum_mismatch` does.
block test_localfs_checksum_tamper_on_disk_is_corrupt:
  let root = freshLocalFsRoot("tamper")
  let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)
  let key = SoundnessKey("7777444488885555")
  assert backend.put(sampleEntry(key, exitCode = 1)) == cvOk

  let path = versionedEntryPath(root, key)
  var node = parseJson(readFile(path))
  node["payload"]["cachedAt"] = newJInt(999_999)  # tamper payload, checksum now stale
  writeFile(path, $node)

  let fetched = backend.get(key)
  assert fetched.verdict == cvCorrupt, "a tampered on-disk entry must be cvCorrupt"

# 6b. a pre-0005 file (RFC-0004 shape: header/payloadChecksum/payload only,
# no keyInputs/attestation/storage keys) decodes -- built purely from the
# exported resultcache codec, exactly as test_cachewire.nim's equivalent
# case, but read through the REAL local-fs backend's get.
block test_localfs_pre_0005_file_decodes:
  let root = freshLocalFsRoot("pre0005")
  let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)
  let key = SoundnessKey("8888666699997777")

  let res = sampleCachedResult(exitCode = 9)
  let payloadNode = payloadToJson(res)
  let checksum = toHex16(fnv1a64(canonicalPayload(res)))
  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)
  let legacyNode = newJObject()
  legacyNode["header"]          = headerNode
  legacyNode["payloadChecksum"] = newJString(checksum)
  legacyNode["payload"]         = payloadNode
  # Deliberately NO "keyInputs", "attestation", or "storage" keys.

  let path = versionedEntryPath(root, key)
  createDir(parentDir(path))
  writeFile(path, $legacyNode)

  let fetched = backend.get(key)
  assert fetched.verdict == cvOk, "a pre-0005 file (RFC-0004 shape) must still decode via local-fs"
  assert fetched.value.keyInputs.isNone
  assert fetched.value.attestation.isNone
  assert fetched.value.storageVersion == storageFormatVersion
  assert fetched.value.result.run.exit.code == 9

# 6c/6d. offline: root entirely missing, autoCreate = false -> cvOffline on
# get AND put (the RFC's other offline condition — "missing ... root on a
# non-autoCreate backend").
block test_localfs_offline_missing_root_get:
  let root = localFsRootPathNoCreate("missing_get")
  let backend = localFsBackend(root, autoCreate = false, maxEntries = 0)
  let fetched = backend.get(SoundnessKey("aaaa0000bbbb0000"))
  assert fetched.verdict == cvOffline, "a missing root with autoCreate=false must be cvOffline on get"

block test_localfs_offline_missing_root_put:
  let root = localFsRootPathNoCreate("missing_put")
  let backend = localFsBackend(root, autoCreate = false, maxEntries = 0)
  let verdict = backend.put(sampleEntry(SoundnessKey("cccc0000dddd0000")))
  assert verdict == cvOffline, "a missing root with autoCreate=false must be cvOffline on put"
  assert not dirExists(root), "a non-autoCreate backend must never conjure the root into existence"

# 6e/6f. offline: a regular FILE sits at the root path (ENOTDIR) -- the
# RFC's designated offline fixture (chmod is unusable: ./dev runs as root
# in-container, so permission bits never block root). Blocked-by-a-file is
# cvOffline REGARDLESS of autoCreate -- autoCreate cannot turn a file into a
# directory.
block test_localfs_offline_file_blocks_root_get:
  let root = getTempDir() / "crisol_cachelocalfs_blocked_get"
  removeFile(root)
  writeFile(root, "i am a file, not a directory")
  defer: removeFile(root)

  let backendNoCreate = localFsBackend(root, autoCreate = false, maxEntries = 0)
  assert backendNoCreate.get(SoundnessKey("eeee0000ffff0000")).verdict == cvOffline

  let backendAutoCreate = localFsBackend(root, autoCreate = true, maxEntries = 0)
  assert backendAutoCreate.get(SoundnessKey("eeee0000ffff0000")).verdict == cvOffline,
    "autoCreate cannot fix a root blocked by a file (ENOTDIR)"

block test_localfs_offline_file_blocks_root_put:
  let root = getTempDir() / "crisol_cachelocalfs_blocked_put"
  removeFile(root)
  writeFile(root, "i am a file, not a directory")
  defer: removeFile(root)

  let backendNoCreate = localFsBackend(root, autoCreate = false, maxEntries = 0)
  assert backendNoCreate.put(sampleEntry(SoundnessKey("1010101020202020"))) == cvOffline

  let backendAutoCreate = localFsBackend(root, autoCreate = true, maxEntries = 0)
  assert backendAutoCreate.put(sampleEntry(SoundnessKey("1010101020202020"))) == cvOffline,
    "autoCreate cannot fix a root blocked by a file (ENOTDIR)"

# 6g. autoCreate=true + a root that does not exist yet: a GET is a clean
# MISS, never cvOffline (autoCreate means "nothing here yet" is not an
# error) -- and get() must not itself create the root (only put() may).
block test_localfs_autocreate_missing_root_get_is_miss:
  let root = localFsRootPathNoCreate("autocreate_miss")
  let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)
  let fetched = backend.get(SoundnessKey("3030303040404040"))
  assert fetched.verdict == cvMiss, "autoCreate + absent root must be a clean miss on get, not offline"
  assert not dirExists(root), "get() must never create the root -- only put() may"

# 6h. soft cap: put of a NEW key once the version dir is already at capacity
# is skipped -> cvUnauthorized (the port's generic "write did not land"
# bucket -- see the module doc comment), mirroring
# `test_resultcache.nim`'s `test_soft_cap_skip`. Re-storing an EXISTING key
# at cap still succeeds (replaces, not grows).
block test_localfs_soft_cap_skip:
  let root = freshLocalFsRoot("softcap")
  let backend = localFsBackend(root, autoCreate = true, maxEntries = 2)
  let kA = SoundnessKey("4040404040404040")
  let kB = SoundnessKey("5050505050505050")
  assert backend.put(sampleEntry(kA)) == cvOk
  assert backend.put(sampleEntry(kB)) == cvOk

  let kC = SoundnessKey("6060606060606060")
  let verdict = backend.put(sampleEntry(kC))
  assert verdict == cvUnauthorized, "a put past the soft cap must be skipped, not cvOk"
  assert backend.get(kC).verdict == cvMiss, "a skipped put must not create the entry"

  # existing entries intact
  assert backend.get(kA).verdict == cvOk
  assert backend.get(kB).verdict == cvOk

  # re-storing an EXISTING key at cap still succeeds (replaces, not grows)
  assert backend.put(sampleEntry(kA, exitCode = 9)) == cvOk
  assert backend.get(kA).verdict == cvOk

# 6i. rfc-0005 B1b-prereq regression: `localFsBackend` and the legacy
# `resultcache` helpers must agree on ONE version dir for the SAME root —
# an entry written through one is visible (and, for GC, evictable) through
# the other. This is the exact bug: `cachelocalfs.nim` briefly derived its
# own `v<storageFormatVersion>` dir (a wire-envelope axis, not a local
# path), diverging from `gcResultCacheAt`'s `v<resultCacheFormatVersion>`
# walk, so `crisol clean` silently never saw live production entries.
block test_localfs_and_resultcache_agree_on_one_root:
  let root = freshLocalFsRoot("agreement")
  let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)

  # localFsBackend.put -> visible to loadCachedAt (same root, same version dir).
  let kA = SoundnessKey("a1a1a1a1a1a1a1a1")
  assert backend.put(sampleEntry(kA, exitCode = 3)) == cvOk
  let viaLoad = loadCachedAt(root, kA)
  assert viaLoad.isSome,
    "an entry written by localFsBackend.put must be visible to loadCachedAt"
  assert viaLoad.get.run.exit.code == 3

  # ... AND actually walked/evictable by gcResultCacheAt (GC must see live
  # production entries, not just the legacy resultcache-only directory).
  let evictReport = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 1,
                                     nowSecs = 9_999_999_999'i64)
  assert evictReport.evicted == 1,
    "gcResultCacheAt must walk the SAME dir localFsBackend.put wrote to"
  assert backend.get(kA).verdict == cvMiss,
    "the entry gcResultCacheAt evicted must be gone from localFsBackend's view too"

  # storeCachedAt -> visible to localFsBackend.get (the reverse direction).
  let kB = SoundnessKey("b2b2b2b2b2b2b2b2")
  assert storeCachedAt(root, kB, sampleCachedResult(exitCode = 7))
  let viaBackend = backend.get(kB)
  assert viaBackend.verdict == cvOk,
    "an entry written by storeCachedAt must be visible to localFsBackend.get"
  assert viaBackend.value.result.run.exit.code == 7

# 6j. on this toolchain `os.createDir` raises `IOError`, not `OSError`, when
# a plain FILE already occupies the exact directory path being created (the
# root itself is a real, writable directory -- only the version-dir segment
# is blocked). `localFsBackend.put` must degrade exactly like any other
# createDir failure (cvUnauthorized, rate-limited warning), never crash.
block test_localfs_ioerror_file_blocks_version_dir_put:
  let root = freshLocalFsRoot("blocked_verdir")
  let verDir = cacheVersionDirAt(root)
  writeFile(verDir, "i am a file, not a directory")
  defer: removeFile(verDir)

  let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)
  let verdict = backend.put(sampleEntry(SoundnessKey("7070707070707070")))
  assert verdict == cvUnauthorized,
    "createDir raising IOError (file blocks the version dir) must degrade like OSError, not crash"

# ---------------------------------------------------------------------------
# 14. zero-tier lookup/put is a clean no-op (never raises, never crashes)
# ---------------------------------------------------------------------------

block test_zero_tier_is_clean_noop:
  var tc = TieredCache(tiers: @[], trust: nonePolicy())
  let l = tc.lookup(SoundnessKey("0000000000000000"))
  assert l.hit.isNone
  assert l.verdicts.len == 0
  assert worst(l) == cvMiss
  assert tc.put(sampleEntry(SoundnessKey("0000000000000000"))).len == 0

# ---------------------------------------------------------------------------
# 15. Explain-miss sidecar I/O (RFC-0005 B1b) — cachelocalfs.sidecarPath/
#    readSidecar/writeSidecar directly. A LOCAL-FS implementation detail:
#    the memory/memoryBytes doubles never see this (cachelocalfs.nim's own
#    module doc).
# ---------------------------------------------------------------------------

proc sampleKeyInputsFor(flagHash: string): KeyInputs =
  KeyInputs(
    closureContentHash: "closure-abc",
    flagHash:            flagHash,
    nimVersion:          "2.2.10",
    ccVersion:           "gcc-13",
    fixtureHash:         "",
    argv:                @["mybin"],
    limits:              default(ptypes.Limits),
    hermeticEnvHash:     "envhash-xyz",
    protocolMajor:       1,
  )

proc sampleSidecarEntry(flagHash: string): SidecarEntry =
  SidecarEntry(
    key:       SoundnessKey("sc-" & flagHash),
    inputs:    sampleKeyInputsFor(flagHash),
    envDigest: @[("HOME", "aa11bb22cc33dd44")],
  )

block test_sidecar_path_deterministic_and_path_discriminating:
  let root = freshLocalFsRoot("sidecar_path")
  let p1 = sidecarPath(root, "tests/unit/test_a.nim")
  let p2 = sidecarPath(root, "tests/unit/test_a.nim")
  let p3 = sidecarPath(root, "tests/unit/test_b.nim")
  assert p1 == p2, "sidecarPath must be deterministic for the same (root, path)"
  assert p1 != p3, "different entrypoint paths must map to different sidecar files"
  assert p1.startsWith(root), "sidecar files must live under the given root"

block test_read_sidecar_absent_is_empty_not_error:
  let root = freshLocalFsRoot("sidecar_absent")
  let sc = readSidecar(root, "tests/unit/test_never_written.nim")
  assert sc.order.len == 0
  assert sc.records.len == 0

block test_write_then_read_sidecar_roundtrips:
  let root = freshLocalFsRoot("sidecar_rw")
  let path = "tests/unit/test_rw.nim"
  writeSidecar(root, path, sampleSidecarEntry("flagA"))
  let sc = readSidecar(root, path)
  assert sc.order == @["flagA"]
  assert "flagA" in sc.records
  assert sc.records["flagA"].key == SoundnessKey("sc-flagA")
  assert sc.records["flagA"].envDigest == @[("HOME", "aa11bb22cc33dd44")]

block test_write_sidecar_twice_different_flaghash_keeps_both:
  let root = freshLocalFsRoot("sidecar_two_flags")
  let path = "tests/unit/test_two.nim"
  writeSidecar(root, path, sampleSidecarEntry("flagA"))
  writeSidecar(root, path, sampleSidecarEntry("flagB"))
  let sc = readSidecar(root, path)
  assert sc.order == @["flagA", "flagB"]
  assert sc.records.len == 2

block test_write_sidecar_same_flaghash_replaces:
  let root = freshLocalFsRoot("sidecar_replace")
  let path = "tests/unit/test_replace.nim"
  writeSidecar(root, path, sampleSidecarEntry("flagA"))
  var newer = sampleSidecarEntry("flagA")
  newer.envDigest = @[("HOME", "ffffffffffffffff")]
  writeSidecar(root, path, newer)
  let sc = readSidecar(root, path)
  assert sc.order == @["flagA"], "re-storing the SAME flagHash must not duplicate the record"
  assert sc.records.len == 1
  assert sc.records["flagA"].envDigest == @[("HOME", "ffffffffffffffff")]

block test_write_sidecar_prunes_past_bound:
  let root = freshLocalFsRoot("sidecar_prune")
  let path = "tests/unit/test_prune.nim"
  for i in 0 ..< (DefaultMaxSidecarRecords + 3):
    writeSidecar(root, path, sampleSidecarEntry("flag" & $i))
  let sc = readSidecar(root, path)
  assert sc.order.len == DefaultMaxSidecarRecords, "must stay bounded"
  assert sc.records.len == DefaultMaxSidecarRecords
  assert "flag0" notin sc.records, "the oldest-touched record must have been pruned"

block test_read_sidecar_corrupt_json_is_treated_as_absent:
  let root = freshLocalFsRoot("sidecar_corrupt")
  let path = "tests/unit/test_corrupt.nim"
  # Write a real record first, THEN corrupt the file on disk directly --
  # proves readSidecar degrades gracefully rather than propagating a parse
  # error, exactly like the RFC's "older writer / first-ever run" case.
  writeSidecar(root, path, sampleSidecarEntry("flagA"))
  let p = sidecarPath(root, path)
  writeFile(p, "{ this is not valid json ]]]")
  let sc = readSidecar(root, path)
  assert sc.order.len == 0, "a corrupt sidecar must degrade to empty, never raise"
  assert sc.records.len == 0

# ---------------------------------------------------------------------------
# 14. RFC-0005 A3c-ii: cacheregistry.configuredCache — builds the run's
#     TieredCache from parsed KDL (CacheConfig.remotes) via a BackendRegistry.
#     Rejections raise CrisolError(cekConfig) — the SAME structural-failure
#     channel a bad group/glob already uses (see api.runTestsWith).
# ---------------------------------------------------------------------------

proc freshStateDir14(tag: string): string =
  result = getTempDir() / ("crisol_configuredcache_" & tag)
  removeDir(result)
  createDir(result)

block test_configured_cache_no_remotes_is_local_only:
  let sd = freshStateDir14("noremotes")
  let rt = configuredCache(CacheConfig(remotes: @[]), sd, maxEntries = 0,
                           reg = productionRegistry(), sink = NilSink[TelemetryEvent]())
  assert rt.cache.tiers.len == 1
  assert rt.cache.tiers[0].name == "l1"
  assert rt.localRoot == sd / "cache"

block test_configured_cache_rejects_l1_named_remote:
  let sd = freshStateDir14("l1name")
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "l1",
                                              url: "file://" & freshLocalFsRoot("l1name_remote"))])
  var caught = false
  try:
    discard configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                            sink = NilSink[TelemetryEvent]())
  except CrisolError as e:
    caught = true
    assert e.kind == cekConfig
  assert caught, "a remote named 'l1' must be a config error"

block test_configured_cache_rejects_root_inside_state_dir:
  let sd = freshStateDir14("rootinside")
  let nested = sd / "cache" / "nested"
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "file://" & nested)])
  var caught = false
  try:
    discard configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                            sink = NilSink[TelemetryEvent]())
  except CrisolError as e:
    caught = true
    assert e.kind == cekConfig
  assert caught, "a file:// root inside stateDir must be a config error (would recurse l1)"

block test_configured_cache_rejects_root_equal_to_state_dir:
  let sd = freshStateDir14("rootequal")
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "file://" & sd)])
  var caught = false
  try:
    discard configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                            sink = NilSink[TelemetryEvent]())
  except CrisolError:
    caught = true
  assert caught, "a remote rooted exactly AT stateDir must also be rejected"

block test_configured_cache_rejects_unresolvable_scheme:
  let sd = freshStateDir14("unknownscheme")
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "https://example.com/cache")])
  var caught = false
  try:
    discard configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                            sink = NilSink[TelemetryEvent]())
  except CrisolError as e:
    caught = true
    assert e.kind == cekConfig
  assert caught, "an unregistered scheme (http, not yet shipped) must be a config error, not a silent drop"

block test_configured_cache_builds_a_real_second_tier:
  let sd = freshStateDir14("realtier")
  let remoteRoot = freshLocalFsRoot("configuredcache_remote")
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "file://" & remoteRoot,
                                              backfillOnHit: true)])
  let rt = configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                           sink = NilSink[TelemetryEvent]())
  assert rt.cache.tiers.len == 2
  assert rt.cache.tiers[0].name == "l1"
  assert rt.cache.tiers[1].name == "mirror"
  assert rt.cache.tiers[1].backfillOnHit == true
  assert rt.cache.tiers[1].verifyTrust == false, "no cache-trust block exists yet -- default is false"
  assert rt.localRoot == sd / "cache"
  # Live end to end through the real file backend (both tiers).
  let key = SoundnessKey("c0c0c0c0c0c0c0c0")
  var cache = rt.cache
  let v = cache.put(sampleEntry(key, exitCode = 9))
  assert v == @[(tier: "l1", verdict: cvOk), (tier: "mirror", verdict: cvOk)]

block test_configured_cache_honors_explicit_verify_trust_true:
  let sd = freshStateDir14("verifytrue")
  let remoteRoot = freshLocalFsRoot("configuredcache_verifytrue")
  let cfg = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "file://" & remoteRoot,
                                              verifyTrust: some(true))])
  let rt = configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                           sink = NilSink[TelemetryEvent]())
  assert rt.cache.tiers[1].verifyTrust == true

echo "test_cachetier: all blocks passed"
