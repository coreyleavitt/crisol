## test_cachetier.nim — RFC-0005 A1: `TieredCache` single-tier `lookup`/`put`,
## boundary-tested over BOTH the `memory` and `memoryBytes` doubles
## (`cachememory.nim`). Grows in place through A3a (the multi-tier waterfall
## + backfill + put-rule + circuit-breaker tests), per RFC-0005's
## fixture/test-file inventory.
##
## Coverage:
##   1. roundtrip: put then lookup returns a hit, `verified == true`
##      (nonePolicy) — over both doubles.
##   2. miss: lookup on an absent key -> hit none, verdicts == [(tier,
##      cvMiss)], worst == cvMiss — over both doubles.
##   3. storageVersion mismatch -> cvVersionSkew, via BOTH doubles (a
##      caller-supplied `StoredEntry.storageVersion` survives `put` on
##      both — `memoryBytes`'s `encode` writes exactly what it is given,
##      and `memory`'s `put` only ever recomputes `payloadChecksum`, never
##      `storageVersion`). Checksum-recompute mismatch (`cvCorrupt`) is
##      NOT representable through either double's `put`: both faithfully
##      mirror `resultcache.storeCached`'s contract and unconditionally
##      recompute `payloadChecksum` at write time, so a corrupted checksum
##      can only ever arise from bytes/objects tampered with AFTER a
##      successful write — exactly what `verifyEntryIntegrity`'s own direct
##      unit test (`test_cachewire.nim`) and the wire-level tamper tests
##      there already cover; `cachetier`'s job is only to PROPAGATE
##      whatever verdict `backend.get` returns, which the version-skew
##      cases below already exercise (there is no verdict-specific branch
##      in `lookup` — `cvCorrupt` would take the identical path).
##   4. `probe` is nil on both doubles (`canProbe == false`) — no producer
##      yet (Stage C3c).
##   5. multi-tier configuration is refused loudly (`doAssert`) — A1's
##      documented scope boundary (the general waterfall is Stage A3a).

import std/options
import crisol/types
import crisol/keys
import crisol/cacheport
import crisol/cachewire
import crisol/cachetier
import crisol/cachememory
import crisol/resultcache
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

type DoubleKind = enum dkMemory, dkMemoryBytes

proc makeBackend(kind: DoubleKind): CacheBackend =
  case kind
  of dkMemory: memory()
  of dkMemoryBytes: memoryBytes(jsonCacheSerializer())

# ---------------------------------------------------------------------------
# 1/2. roundtrip + miss, over both doubles
# ---------------------------------------------------------------------------

for kind in [dkMemory, dkMemoryBytes]:
  block:
    var tc = oneTier(makeBackend(kind))
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

# ---------------------------------------------------------------------------
# 4. probe is nil on both doubles — no producer yet (Stage C3c)
# ---------------------------------------------------------------------------

block test_probe_is_nil_on_both_doubles:
  assert not canProbe(memory())
  assert not canProbe(memoryBytes(jsonCacheSerializer()))

# ---------------------------------------------------------------------------
# 5. multi-tier configuration is refused loudly (A1's documented scope
#    boundary — the general waterfall lands in A3a)
# ---------------------------------------------------------------------------

block test_multi_tier_lookup_refused:
  var tc = TieredCache(
    tiers: @[Tier(name: "l1", backend: memory(), backfillOnHit: false, verifyTrust: false),
             Tier(name: "l2", backend: memory(), backfillOnHit: false, verifyTrust: false)],
    trust: nonePolicy(),
  )
  var caught = false
  try:
    discard tc.lookup(SoundnessKey("0000000000000000"))
  except AssertionDefect:
    caught = true
  assert caught, "cachetier A1: a 2-tier TieredCache must refuse lookup, not silently ignore tier[1]"

block test_multi_tier_put_refused:
  var tc = TieredCache(
    tiers: @[Tier(name: "l1", backend: memory(), backfillOnHit: false, verifyTrust: false),
             Tier(name: "l2", backend: memory(), backfillOnHit: false, verifyTrust: false)],
    trust: nonePolicy(),
  )
  var caught = false
  try:
    discard tc.put(sampleEntry(SoundnessKey("0000000000000000")))
  except AssertionDefect:
    caught = true
  assert caught, "cachetier A1: a 2-tier TieredCache must refuse put, not silently write only tier[0]"

# ---------------------------------------------------------------------------
# 6. zero-tier lookup/put is a clean no-op (never raises, never crashes)
# ---------------------------------------------------------------------------

block test_zero_tier_is_clean_noop:
  var tc = TieredCache(tiers: @[], trust: nonePolicy())
  let l = tc.lookup(SoundnessKey("0000000000000000"))
  assert l.hit.isNone
  assert l.verdicts.len == 0
  assert worst(l) == cvMiss
  assert tc.put(sampleEntry(SoundnessKey("0000000000000000"))).len == 0

echo "test_cachetier: all blocks passed"
