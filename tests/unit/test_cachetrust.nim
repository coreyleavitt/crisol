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
## RFC-0005 C5a adds:
##   9.  ed25519 roundtrip: `sign` attaches an `ed25519` `Attestation` whose
##       `signer` is `base64(toBytes(pk))`; `verify` -> `cvOk` against the
##       pinned set.
##   10. No-seed verify-only mode: a policy built with `none(Seed)` (no
##       signing secret held) still verifies an entry signed by a DIFFERENT
##       policy that shares the same pinned public key, and its OWN `sign`
##       is a documented no-op (never sets an attestation).
##
## RFC-0005 C5b adds the ed25519 rejection matrix:
##   11. Unattested entry -> `cvTrustNoAttestation` (mirrors HMAC's #3).
##   12. Tamper after signing (payload changes, attestation does not) ->
##       `cvTrustBadSignature` (mirrors HMAC's #2).
##   13. Valid signature from a signer whose public key is NOT in the
##       verifier's pinned set -> `cvTrustUnpinnedSigner`.
##   14. Wrong `sigAlg` on the attestation -> `cvTrustUnknownAlg` (mirrors
##       HMAC's #4).
##   15. Forged `signer` field (naming a key that IS pinned) on an
##       attestation actually produced by a DIFFERENT key -> resolves to
##       `cvTrustBadSignature`, NOT `cvTrustSignerMismatch`. This is a
##       deliberate architectural fact, not a gap: `cvTrustSignerMismatch`
##       is this module's verdict for HMAC's single-active-secret model
##       (attested `signer` label != the one configured `keyId`, RFC-0005
##       "signer derivation is pinned" + this file's own module doc,
##       above). ed25519's pinned-SET model has no analogous state --
##       `envelopeBytes` binds `signer` into the signed bytes themselves
##       (RFC-0005 "Including signer binds the claimed identity to the
##       verifying key, defeating key-confusion"), so ANY forged `signer`
##       is either not in the pinned set at all (`cvTrustUnpinnedSigner`,
##       #13) or names a real pinned key whose public key then fails to
##       validate a signature it never produced (`cvTrustBadSignature`,
##       tested here as #15). `ed25519Policy.verify` (`cachetrust.nim`)
##       has no `cvTrustSignerMismatch` return path at all -- confirmed by
##       reading its full body, not merely by this test's silence.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cachetrust.nim

import std/[base64, options]
import crisol/cacheport
import crisol/cachetrust
import crisol/cachewire       # storageFormatVersion
import crisol/process/types as ptypes
import sello                  # RFC-0005 C5a: test-only fixture construction
                               # (Seed/Keypair/PublicKey) -- cachetrust.nim
                               # stays the only PRODUCTION module importing
                               # sello; this test file reaches for the raw
                               # constructors the same way
                               # test_cdep_crypto_smoke.nim already does.

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

# ---------------------------------------------------------------------------
# ed25519 fixtures (RFC-0005 C5a)
# ---------------------------------------------------------------------------

const FixedSeedBytesA: array[32, byte] = [
  byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]

proc pubKeyFor(seedBytes: array[32, byte]): PublicKey =
  keypair(toSeed(seedBytes)).public

# ---------------------------------------------------------------------------
# 9. ed25519 roundtrip
# ---------------------------------------------------------------------------

block test_ed25519_roundtrip:
  let pk = pubKeyFor(FixedSeedBytesA)
  let policy = ed25519Policy(some(toSeed(FixedSeedBytesA)), @[pk])
  var e = sampleEntry(SoundnessKey("9999999999999999"))
  policy.sign(e)
  assert e.attestation.isSome
  let att = e.attestation.get
  assert att.sigAlg == saEd25519
  assert att.signer == base64.encode(toBytes(pk))
  assert att.signature.len > 0
  assert policy.verify(e) == cvOk

# ---------------------------------------------------------------------------
# 10. No-seed verify-only mode
# ---------------------------------------------------------------------------

block test_ed25519_no_seed_verify_only:
  let pk = pubKeyFor(FixedSeedBytesA)
  let signer = ed25519Policy(some(toSeed(FixedSeedBytesA)), @[pk])
  var e = sampleEntry(SoundnessKey("aaaaaaaaaaaaaaaa"))
  signer.sign(e)
  assert e.attestation.isSome

  # A read-only consumer -- no seed of its own, only the pinned public key --
  # can still verify what `signer` produced (RFC-0005 "no-seed verify-only
  # mode").
  let verifier = ed25519Policy(none(Seed), @[pk])
  assert verifier.verify(e) == cvOk

  # `sign` on a verify-only policy is a documented no-op (RFC-0005
  # `TrustPolicy` port doc: "no-op if no secret held") -- never sets an
  # attestation.
  var e2 = sampleEntry(SoundnessKey("bbbbbbbbbbbbbbbb"))
  verifier.sign(e2)
  assert e2.attestation.isNone

# ---------------------------------------------------------------------------
# RFC-0005 C5b -- ed25519 rejection matrix
# ---------------------------------------------------------------------------

const FixedSeedBytesB: array[32, byte] = [
  byte 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17,
  16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

# ---------------------------------------------------------------------------
# 11. Unattested entry -> cvTrustNoAttestation (mirrors HMAC's #3)
# ---------------------------------------------------------------------------

block test_ed25519_no_attestation:
  let pkA = pubKeyFor(FixedSeedBytesA)
  let policy = ed25519Policy(some(toSeed(FixedSeedBytesA)), @[pkA])
  let e = sampleEntry(SoundnessKey("cccccccccccccccc"))
  assert e.attestation.isNone
  assert policy.verify(e) == cvTrustNoAttestation

# ---------------------------------------------------------------------------
# 12. Tamper after signing -> cvTrustBadSignature (mirrors HMAC's #2)
# ---------------------------------------------------------------------------

block test_ed25519_tamper_after_sign_is_bad_signature:
  let pkA = pubKeyFor(FixedSeedBytesA)
  let policy = ed25519Policy(some(toSeed(FixedSeedBytesA)), @[pkA])
  var e = sampleEntry(SoundnessKey("dddddddddddddddd"))
  policy.sign(e)
  assert policy.verify(e) == cvOk
  # Mutate the payload the attestation was computed over WITHOUT re-signing
  # (mirrors the RFC's "flip a payload byte" -- the recomputed SHA-256
  # inside `verify` no longer matches what `sign` bound into the envelope).
  e.result.run.exit.code = 1
  assert policy.verify(e) == cvTrustBadSignature

# ---------------------------------------------------------------------------
# 13. Valid signature, signer's key NOT in the verifier's pinned set
#     -> cvTrustUnpinnedSigner
# ---------------------------------------------------------------------------

block test_ed25519_unpinned_signer:
  let pkA = pubKeyFor(FixedSeedBytesA)
  let pkB = pubKeyFor(FixedSeedBytesB)
  # Signed for real by key B -- a genuinely valid ed25519 attestation --
  # but the verifier below pins ONLY key A (mirrors the RFC's "unpinned
  # second signer" framing; the C5b E2E-2 repeat in test_api.nim is the
  # same shape through the real entry point).
  let signerB = ed25519Policy(some(toSeed(FixedSeedBytesB)), @[pkB])
  var e = sampleEntry(SoundnessKey("eeeeeeeeeeeeeeee"))
  signerB.sign(e)
  assert e.attestation.isSome
  assert e.attestation.get.signer == base64.encode(toBytes(pkB))

  let verifierPinningOnlyA = ed25519Policy(none(Seed), @[pkA])
  assert verifierPinningOnlyA.verify(e) == cvTrustUnpinnedSigner

# ---------------------------------------------------------------------------
# 14. Wrong sigAlg -> cvTrustUnknownAlg (mirrors HMAC's #4)
# ---------------------------------------------------------------------------

block test_ed25519_wrong_sigalg:
  let pkA = pubKeyFor(FixedSeedBytesA)
  let policy = ed25519Policy(some(toSeed(FixedSeedBytesA)), @[pkA])
  var e = sampleEntry(SoundnessKey("ffffffffffffffff"))
  e.attestation = some(Attestation(sigAlg: saHmacSha256, signer: base64.encode(toBytes(pkA)),
                                   signature: "irrelevant", signedAt: 0))
  assert policy.verify(e) == cvTrustUnknownAlg

# ---------------------------------------------------------------------------
# 15. Forged `signer` field naming a PINNED key, signature actually from a
#     DIFFERENT key -> cvTrustBadSignature, NOT cvTrustSignerMismatch
#     (judgment call -- see this file's header doc, item 15, and
#     `cachetrust.nim`'s `ed25519Policy` doc comment for the full
#     first-principles argument: the pinned-SET architecture has no
#     `cvTrustSignerMismatch` state distinct from "unpinned" or "bad
#     signature", because `signer` is bound INTO the signed bytes).
# ---------------------------------------------------------------------------

block test_ed25519_forged_signer_field_is_bad_signature_not_mismatch:
  let pkA = pubKeyFor(FixedSeedBytesA)
  let pkB = pubKeyFor(FixedSeedBytesB)
  # Genuinely signed by key B, over the envelope that (correctly) names B
  # as signer.
  let signerB = ed25519Policy(some(toSeed(FixedSeedBytesB)), @[pkB])
  var e = sampleEntry(SoundnessKey("1010101010101010"))
  signerB.sign(e)
  assert e.attestation.isSome

  # Forge the wire-level `signer` field to claim key A instead (A IS in
  # the verifier's pinned set) -- the signature bytes are untouched, still
  # key B's.
  var forged = e
  forged.attestation.get.signer = base64.encode(toBytes(pkA))

  let verifierPinningA = ed25519Policy(none(Seed), @[pkA])
  # A is pinned, so this is NOT the unpinned-signer path -- but the
  # recomputed envelope (which binds the FORGED signer="A" string) can
  # never validate against a signature key B produced over a DIFFERENT
  # envelope (signer="B"), regardless of which public key is tried.
  assert verifierPinningA.verify(forged) == cvTrustBadSignature

echo "test_cachetrust: all blocks passed"
