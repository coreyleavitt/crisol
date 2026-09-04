## test_cachewire.nim — RFC-0005 A1: the JSON `CacheSerializer`.
##
## Coverage:
##   1. roundtrip WITH keyInputs + attestation set.
##   2. roundtrip WITHOUT optional fields (encode omits absent keys).
##   3. checksum-recompute mismatch (tamper payload bytes) -> cvCorrupt.
##   4. embedded resultCacheFormatVersion (header) mismatch -> cvVersionSkew.
##   5. envelope storageFormatVersion (storage.version) mismatch -> cvVersionSkew.
##   6. a pre-0005 file (no keyInputs/attestation/storage keys at all) decodes.
##   7. keyInputsToJson/keyInputsFromJson roundtrip directly (incl. Limits
##      with a mix of some/none, and a non-empty argv).
##   8. envelopeBytes is a pure NUL-delimited joiner.
##   9. decode of garbage bytes -> cvCorrupt (never raises).
##   10. verifyEntryIntegrity directly: ok / corrupt / version-skew.

import std/[json, options]
import crisol/types
import crisol/keys
import crisol/cacheport
import crisol/cachewire
import crisol/resultcache
import crisol/process/types as ptypes
import crisol/depgraph  # fnv1a64/toHex16 — recompute matching checksums by hand

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
    rusage: some(ptypes.Rusage(maxRssBytes: 2048, userCpuUs: 100, sysCpuUs: 20)),
    durationUs: 555_000,
  )

proc sampleCachedResult(exitCode: int = 0): CachedResult =
  CachedResult(
    run: sampleProcessResult(exitCode),
    records: @[
      TestRecord(name: "gamma", status: rsPass, durationUs: 10,
                 msg: none(string), tags: @[]),
    ],
    cachedAt:        1_700_000_100'i64,
    payloadChecksum: "",  # filled by the serializer's encode
  )

proc sampleLimits(): ptypes.Limits =
  var l: ptypes.Limits
  l.req[ptypes.lkCpu]      = some(30'i64)
  l.req[ptypes.lkFileSize] = none(int64)
  l.req[ptypes.lkAddressSpace] = some(1_000_000'i64)
  l.req[ptypes.lkOpenFiles] = none(int64)
  l.req[ptypes.lkCore]      = some(0'i64)
  l

proc sampleKeyInputs(): KeyInputs =
  KeyInputs(
    closureContentHash: "abc123",
    flagHash:            "flag456",
    nimVersion:          "2.2.10",
    ccVersion:           "gcc-13",
    fixtureHash:         "fx789",
    argv:                @["mybin", "--flag", "value"],
    limits:              sampleLimits(),
    hermeticEnvHash:     "envhash01",
    protocolMajor:       2,
  )

proc sampleAttestation(): Attestation =
  Attestation(
    sigAlg:    saHmacSha256,
    signer:    "ci-key",
    signature: "c2lnbmF0dXJlYnl0ZXM=",
    signedAt:  1_700_000_200'i64,
  )

proc sampleEntry(key: SoundnessKey; exitCode = 0; withOptional = true): StoredEntry =
  StoredEntry(
    key:            key,
    keyInputs:      if withOptional: some(sampleKeyInputs()) else: none(KeyInputs),
    result:         sampleCachedResult(exitCode),
    storageVersion: storageFormatVersion,
    attestation:    if withOptional: some(sampleAttestation()) else: none(Attestation),
  )

# ---------------------------------------------------------------------------
# 1. roundtrip WITH optional fields
# ---------------------------------------------------------------------------

block test_roundtrip_with_optional_fields:
  let ser = jsonCacheSerializer()
  let key = SoundnessKey("aaaa1111bbbb2222")
  let entry = sampleEntry(key, exitCode = 3)

  let bytes = ser.encode(entry)
  let decoded = ser.decode(bytes)
  assert decoded.verdict == cvOk, "roundtrip must decode cvOk"
  var got = decoded.value
  got.key = key  # decode never restores key — contextual, see module doc

  assert got.result.run.exit.code == 3
  assert got.result.records.len == 1
  assert got.result.records[0].name == "gamma"
  assert got.storageVersion == storageFormatVersion
  assert got.keyInputs.isSome
  assert got.keyInputs.get == entry.keyInputs.get
  assert got.attestation.isSome
  assert got.attestation.get.sigAlg == saHmacSha256
  assert got.attestation.get.signer == "ci-key"
  assert got.attestation.get.signature == "c2lnbmF0dXJlYnl0ZXM="
  assert got.attestation.get.signedAt == 1_700_000_200'i64

# ---------------------------------------------------------------------------
# 2. roundtrip WITHOUT optional fields
# ---------------------------------------------------------------------------

block test_roundtrip_without_optional_fields:
  let ser = jsonCacheSerializer()
  let key = SoundnessKey("cccc3333dddd4444")
  let entry = sampleEntry(key, exitCode = 0, withOptional = false)

  let bytes = ser.encode(entry)
  let node = parseJson(bytes)
  assert node{"keyInputs"} == nil, "absent keyInputs must not be written to the wire"
  assert node{"attestation"} == nil, "absent attestation must not be written to the wire"

  let decoded = ser.decode(bytes)
  assert decoded.verdict == cvOk
  assert decoded.value.keyInputs.isNone
  assert decoded.value.attestation.isNone

# ---------------------------------------------------------------------------
# 3. checksum-recompute mismatch -> cvCorrupt
# ---------------------------------------------------------------------------

block test_checksum_mismatch_is_corrupt:
  let ser = jsonCacheSerializer()
  let entry = sampleEntry(SoundnessKey("e1e1e1e1e2e2e2e2"))
  var node = parseJson(ser.encode(entry))
  node["payload"]["cachedAt"] = newJInt(999)  # tamper payload, leave checksum stale
  let decoded = ser.decode($node)
  assert decoded.verdict == cvCorrupt, "tampered payload with stale checksum must be cvCorrupt"

# ---------------------------------------------------------------------------
# 4. embedded resultCacheFormatVersion (header) mismatch -> cvVersionSkew
# ---------------------------------------------------------------------------

block test_header_format_version_mismatch_is_skew:
  let ser = jsonCacheSerializer()
  let entry = sampleEntry(SoundnessKey("f0f0f0f0f1f1f1f1"))
  var node = parseJson(ser.encode(entry))
  node["header"]["formatVersion"] = newJInt(resultCacheFormatVersion + 1)
  let decoded = ser.decode($node)
  assert decoded.verdict == cvVersionSkew, "payload formatVersion mismatch must be cvVersionSkew"

# ---------------------------------------------------------------------------
# 5. envelope storageFormatVersion (storage.version) mismatch -> cvVersionSkew
# ---------------------------------------------------------------------------

block test_storage_version_mismatch_is_skew:
  let ser = jsonCacheSerializer()
  let entry = sampleEntry(SoundnessKey("a2a2a2a2a3a3a3a3"))
  var node = parseJson(ser.encode(entry))
  node["storage"]["version"] = newJInt(storageFormatVersion + 1)
  let decoded = ser.decode($node)
  assert decoded.verdict == cvVersionSkew, "envelope storage.version mismatch must be cvVersionSkew"

# ---------------------------------------------------------------------------
# 6. a pre-0005 file (no keyInputs/attestation/storage keys) decodes
# ---------------------------------------------------------------------------

block test_pre_0005_file_decodes:
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

  let ser = jsonCacheSerializer()
  let decoded = ser.decode($legacyNode)
  assert decoded.verdict == cvOk, "a pre-0005 file (RFC-0004 shape) must still decode"
  assert decoded.value.keyInputs.isNone
  assert decoded.value.attestation.isNone
  assert decoded.value.storageVersion == storageFormatVersion,
    "an absent envelope is compatible by definition -> treated as this reader's storageFormatVersion"
  assert decoded.value.result.run.exit.code == 9

# ---------------------------------------------------------------------------
# 7. keyInputsToJson/keyInputsFromJson roundtrip directly
# ---------------------------------------------------------------------------

block test_key_inputs_roundtrip:
  let inp = sampleKeyInputs()
  let node = keyInputsToJson(inp)
  let back = keyInputsFromJson(node)
  assert back.isSome
  assert back.get == inp
  assert back.get.limits.req[ptypes.lkCpu] == some(30'i64)
  assert back.get.limits.req[ptypes.lkFileSize].isNone
  assert back.get.argv == @["mybin", "--flag", "value"]

# ---------------------------------------------------------------------------
# 8. envelopeBytes is a pure NUL-delimited joiner
# ---------------------------------------------------------------------------

block test_envelope_bytes_is_nul_delimited:
  let key = SoundnessKey("deadbeefdeadbeef")
  let bytes = envelopeBytes("crisol-cache-attest-v1", key, "aa11bb22", 1, "ci-key")
  let expected = "crisol-cache-attest-v1" & "\x00" & "deadbeefdeadbeef" & "\x00" &
                 "aa11bb22" & "\x00" & "1" & "\x00" & "ci-key"
  assert bytes == expected
  # Sign and verify share this exact proc, so they cannot disagree; a
  # different signer must produce different bytes (no accidental collision).
  let bytes2 = envelopeBytes("crisol-cache-attest-v1", key, "aa11bb22", 1, "other-key")
  assert bytes != bytes2

# ---------------------------------------------------------------------------
# 9. garbage bytes -> cvCorrupt, never raises
# ---------------------------------------------------------------------------

block test_garbage_bytes_is_corrupt:
  let ser = jsonCacheSerializer()
  let decoded = ser.decode("not even json {")
  assert decoded.verdict == cvCorrupt

# ---------------------------------------------------------------------------
# 10. verifyEntryIntegrity directly — the shared check `cachememory`'s
#     `memory` double relies on for a LIVE (never-serialized) StoredEntry.
#     Both `memory` and `memoryBytes` self-heal `payloadChecksum` at write
#     time (mirroring `resultcache.storeCached`'s contract), so a corrupted
#     checksum can only ever be produced by tampering with data ALREADY
#     written -- exactly what this direct test proves `verifyEntryIntegrity`
#     catches, independent of any backend.
# ---------------------------------------------------------------------------

block test_verify_entry_integrity_ok:
  var e = sampleEntry(SoundnessKey("0101010102020202"), exitCode = 4, withOptional = false)
  e.result.payloadChecksum = toHex16(fnv1a64(canonicalPayload(e.result)))
  assert verifyEntryIntegrity(e) == cvOk

block test_verify_entry_integrity_corrupt:
  var e = sampleEntry(SoundnessKey("0303030304040404"), exitCode = 4, withOptional = false)
  e.result.payloadChecksum = toHex16(fnv1a64(canonicalPayload(e.result)))
  e.result.payloadChecksum = "ffffffffffffffff"  # tamper AFTER the correct value was computed
  assert verifyEntryIntegrity(e) == cvCorrupt

block test_verify_entry_integrity_version_skew:
  var e = sampleEntry(SoundnessKey("0505050506060606"), exitCode = 4, withOptional = false)
  e.result.payloadChecksum = toHex16(fnv1a64(canonicalPayload(e.result)))
  e.storageVersion = storageFormatVersion + 1
  assert verifyEntryIntegrity(e) == cvVersionSkew

echo "test_cachewire: all blocks passed"
