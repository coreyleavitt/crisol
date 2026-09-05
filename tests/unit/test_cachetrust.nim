## test_cachetrust.nim — RFC-0005 C4: boundary tests for `cachetrust.hmacPolicy`.
##
## Coverage:
##   1. Roundtrip: `sign` attaches a `hmac-sha256` `Attestation`; `verify`
##      -> `cvOk`.
##   2. Tamper: the underlying `result` changes AFTER signing (the signed
##      envelope's recomputed payload hash no longer matches) -> `verify`
##      -> `cvTrustBadSignature` (mirrors the RFC's E2E-2 "flip one payload
##      byte and recompute payloadChecksum" -- the wire-level integrity
##      checksum is a `cachewire`/`resultcache` concern, orthogonal to this
##      module; here the ANALOGOUS trust-layer effect of a changed payload
##      is exercised directly against `TrustPolicy.verify`).
##   3. Unattested entry (`attestation.isNone`) -> `cvTrustNoAttestation`.
##   4. Wrong `sigAlg` on the attestation -> `cvTrustUnknownAlg`.
##   5. Wrong `key-id` (attested `signer` != the policy's configured
##      `keyId`) -> `cvTrustSignerMismatch`.
##   6. Wrong secret (same `keyId`, different HMAC key) -> `cvTrustBadSignature`.
##   7. Malformed base64 `signature` -> `cvTrustBadSignature`, never a raise.
##   8. `nonePolicy` (regression, `cacheport.nim`) stays `cvOk` unconditionally
##      -- hmacPolicy must not be the ONLY policy exercised by this file.
##
## `cvCorrupt` (bare tamper, checksum NOT fixed) is NOT this module's
## concern -- it is `cachewire`/`resultcache`'s decode-time integrity gate,
## which runs BEFORE any `StoredEntry` reaches `TrustPolicy.verify` at all
## (see `test_cachewire.nim`/`test_cachetier.nim`'s localFs section, and
## `test_api.nim`'s E2E-2 for the full on-disk tamper proof).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cachetrust.nim

import std/[options]
import crisol/cacheport
import crisol/cachetrust
import crisol/cachewire       # storageFormatVersion
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Helpers (mirrors test_cachetier.nim's sampleCachedResult/sampleEntry)
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

# ---------------------------------------------------------------------------
# 1. Roundtrip
# ---------------------------------------------------------------------------

block test_hmac_roundtrip:
  let policy = hmacPolicy("s3cr3t", "ci-2026")
  var e = sampleEntry(SoundnessKey("1111111111111111"))
  policy.sign(e)
  assert e.attestation.isSome
  let att = e.attestation.get
  assert att.sigAlg == saHmacSha256
  assert att.signer == "ci-2026"
  assert att.signature.len > 0
  assert policy.verify(e) == cvOk

# ---------------------------------------------------------------------------
# 2. Tamper after signing -> cvTrustBadSignature
# ---------------------------------------------------------------------------

block test_hmac_tamper_after_sign_is_bad_signature:
  let policy = hmacPolicy("s3cr3t", "ci-2026")
  var e = sampleEntry(SoundnessKey("2222222222222222"), exitCode = 0)
  policy.sign(e)
  assert policy.verify(e) == cvOk
  # Mutate the payload the attestation was computed over WITHOUT re-signing
  # (mirrors the RFC's "flip a payload byte" -- the recomputed hash inside
  # `verify` no longer matches what `sign` bound into the envelope).
  e.result.run.exit.code = 1
  assert policy.verify(e) == cvTrustBadSignature

# ---------------------------------------------------------------------------
# 3. Unattested entry -> cvTrustNoAttestation
# ---------------------------------------------------------------------------

block test_hmac_no_attestation:
  let policy = hmacPolicy("s3cr3t", "ci-2026")
  let e = sampleEntry(SoundnessKey("3333333333333333"))
  assert e.attestation.isNone
  assert policy.verify(e) == cvTrustNoAttestation

# ---------------------------------------------------------------------------
# 4. Wrong sigAlg -> cvTrustUnknownAlg
# ---------------------------------------------------------------------------

block test_hmac_wrong_sigalg:
  let policy = hmacPolicy("s3cr3t", "ci-2026")
  var e = sampleEntry(SoundnessKey("4444444444444444"))
  e.attestation = some(Attestation(sigAlg: saEd25519, signer: "ci-2026",
                                   signature: "irrelevant", signedAt: 0))
  assert policy.verify(e) == cvTrustUnknownAlg

# ---------------------------------------------------------------------------
# 5. Wrong key-id -> cvTrustSignerMismatch
# ---------------------------------------------------------------------------

block test_hmac_wrong_keyid_is_signer_mismatch:
  let signer = hmacPolicy("s3cr3t", "ci-2026")
  let verifier = hmacPolicy("s3cr3t", "other-key-id")
  var e = sampleEntry(SoundnessKey("5555555555555555"))
  signer.sign(e)
  assert verifier.verify(e) == cvTrustSignerMismatch

# ---------------------------------------------------------------------------
# 6. Wrong secret (same key-id) -> cvTrustBadSignature
# ---------------------------------------------------------------------------

block test_hmac_wrong_secret_is_bad_signature:
  let signer = hmacPolicy("s3cr3t", "ci-2026")
  let verifier = hmacPolicy("different-secret", "ci-2026")
  var e = sampleEntry(SoundnessKey("6666666666666666"))
  signer.sign(e)
  assert verifier.verify(e) == cvTrustBadSignature

# ---------------------------------------------------------------------------
# 7. Malformed base64 signature -> cvTrustBadSignature, never a raise
# ---------------------------------------------------------------------------

block test_hmac_malformed_signature_never_raises:
  let policy = hmacPolicy("s3cr3t", "ci-2026")
  var e = sampleEntry(SoundnessKey("7777777777777777"))
  e.attestation = some(Attestation(sigAlg: saHmacSha256, signer: "ci-2026",
                                   signature: "!!!not-base64!!!", signedAt: 0))
  assert policy.verify(e) == cvTrustBadSignature

# ---------------------------------------------------------------------------
# 8. nonePolicy regression -- unconditional cvOk
# ---------------------------------------------------------------------------

block test_none_policy_unconditional_ok:
  let policy = nonePolicy()
  let e = sampleEntry(SoundnessKey("8888888888888888"))
  assert e.attestation.isNone
  assert policy.verify(e) == cvOk

echo "test_cachetrust: all blocks passed"
