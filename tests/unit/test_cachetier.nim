## test_cachetier.nim — RFC-0005 A1: `TieredCache` single-tier `lookup`/`put`,
## boundary-tested over the `memory`/`memoryBytes` doubles (`cachememory.nim`)
## AND, from A2a, the real `local-fs` backend (`cachelocalfs.nim`) — the
## RFC's "the localFs backend must pass the SAME boundary suite as
## memory/memoryBytes" requirement. Grows in place through A3a (the
## multi-tier waterfall + backfill + put-rule + circuit-breaker tests), per
## RFC-0005's fixture/test-file inventory.
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
##   5. multi-tier configuration is refused loudly (`doAssert`) — A1's
##      documented scope boundary (the general waterfall is Stage A3a).
##   6. localFs-specific (A2a): checksum tamper on disk -> cvCorrupt; a
##      pre-0005 file (RFC-0004 shape, no envelope keys) decodes; offline
##      semantics (missing root, non-autoCreate; a FILE blocking the root —
##      ENOTDIR, regardless of autoCreate) -> cvOffline on get AND put;
##      autoCreate creates the root on demand and a fresh get on it is a
##      clean miss, never offline; the soft cap skips a new-key put once the
##      version dir is at capacity, rate-limited stderr warning included.

import std/[json, options, os]
import crisol/types
import crisol/keys
import crisol/cacheport
import crisol/cachewire
import crisol/cachetier
import crisol/cachememory
import crisol/cachelocalfs
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
# 6. localFs-specific (rfc-0005 A2a)
# ---------------------------------------------------------------------------

proc localFsRootPathNoCreate(name: string): string =
  ## A path under the temp dir that does NOT exist yet — for the "missing
  ## root" cases (as opposed to `freshLocalFsRoot`, which pre-creates the
  ## directory for the roundtrip-style tests above).
  result = getTempDir() / ("crisol_cachelocalfs_nocreate_" & name)
  removeDir(result)

proc versionedEntryPath(root: string; key: SoundnessKey): string =
  root / ("v" & $storageFormatVersion) / ($key & ".json")

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

# ---------------------------------------------------------------------------
# 7. zero-tier lookup/put is a clean no-op (never raises, never crashes)
# ---------------------------------------------------------------------------

block test_zero_tier_is_clean_noop:
  var tc = TieredCache(tiers: @[], trust: nonePolicy())
  let l = tc.lookup(SoundnessKey("0000000000000000"))
  assert l.hit.isNone
  assert l.verdicts.len == 0
  assert worst(l) == cvMiss
  assert tc.put(sampleEntry(SoundnessKey("0000000000000000"))).len == 0

echo "test_cachetier: all blocks passed"
