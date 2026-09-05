## cachetrust.nim — RFC-0005 C4: `hmacPolicy` (HMAC-SHA256, nimcrypto) + the
## trust-side half of the signed envelope. This is the ONLY module
## importing sello/nimcrypto (RFC-0005 "Module layout"); C5a adds
## `ed25519Policy` (sello) beside `hmacPolicy` here without reshaping
## anything in this module — both policies share `payloadHashHex` and
## `EnvelopeTagV1` below.
##
## ## The signed envelope (RFC-0005 "Integrity vs. trust — two layers, two
## hashes, one canonical payload")
##
## Both `sign` and `verify` recompute, from the entry's own `result`/`key`/
## `storageVersion`, the SAME bytes via `cacheport.envelopeBytes` — one
## pure function, so sign and verify cannot disagree:
##
##   envelopeBytes(EnvelopeTagV1, entry.key,
##                 hex(SHA256(canonicalPayload(entry.result))),
##                 entry.storageVersion, signer)
##
## The SHA-256 hash is ALWAYS recomputed from the payload here, never
## stored on or trusted from the wire (Stage A stayed crypto-free by
## construction; this module is where SHA-256 first enters the codebase).
##
## ## `signer` derivation (pinned, RFC-0005 "TrustPolicy — the port")
##
## HMAC: `signer = keyId` — an operator-chosen label (`key-id` in config),
## carried for provenance and bound into the MAC. There is exactly ONE
## active secret for `hmacPolicy`, so an attested `signer` that differs
## from the configured `keyId` is `cvTrustSignerMismatch` — NOT
## `cvTrustUnpinnedSigner`, which names the analogous rejection for a
## PINNED-SET architecture (ed25519, C5a: signer not among several pinned
## public keys). The two verdicts stay distinct so `--cache-stats`/
## `explainMiss` can tell "wrong key-id" apart from "unrecognized signer"
## once both policies ship.
##
## ## Verdicts — `verify` is total and fail-closed
##
##   no attestation        -> cvTrustNoAttestation
##   sigAlg != hmac-sha256  -> cvTrustUnknownAlg
##   signer != keyId        -> cvTrustSignerMismatch
##   MAC does not match     -> cvTrustBadSignature (incl. unparseable
##                             base64 -- a malformed signature is exactly
##                             as fail-closed as a bad MAC, never a raise)
##   otherwise              -> cvOk
##
## `hmacPolicy`'s `verify` NEVER raises (RFC-0005 "verify is total and
## fail-closed"); the MAC comparison uses nimcrypto's `equalMemFull`
## (constant-time over the compared length) rather than string `==`.

import std/[base64, options, times]
import nimcrypto
import crisol/cacheport

const EnvelopeTagV1* = "crisol-cache-attest-v1"
  ## RFC-0005 "Integrity vs. trust": the constant domain-separation prefix
  ## every `TrustPolicy` signs/verifies over. A CI ed25519/HMAC key reused
  ## elsewhere cannot produce a cross-protocol signature that verifies
  ## here. Shared (not duplicated) by C5a's `ed25519Policy`.

proc payloadHashHex(res: CachedResult): string =
  ## The recomputed SHA-256 (lower-case hex) of the canonical payload —
  ## shared by `sign` and `verify` alike; NEVER a stored/wire value (RFC-
  ## 0005 "the SHA-256 is recomputed by both signer and verifier from the
  ## canonical payload, never stored, never trusted from the wire").
  toHex(sha256.digest(canonicalPayload(res)).data, lowercase = true)

proc hmacBytesToSignature(mac: MDigest[256]): string =
  base64.encode(mac.data)

proc hmacPolicy*(secret: sink string; keyId: string): TrustPolicy =
  ## HMAC-SHA256 (nimcrypto) over the shared envelope (RFC-0005 "TrustPolicy
  ## — the port"). `secret` is the raw HMAC key (`$CRISOL_CACHE_HMAC_KEY`,
  ## resolved once in `api.nim` and moved in here — see that module's
  ## `CacheSecrets` resolution); `keyId` is the operator-chosen `key-id`
  ## config label, bound into the envelope as `signer`.
  let key = secret
  TrustPolicy(
    name: "hmac",
    sign: proc(entry: var StoredEntry) =
      let envelope = envelopeBytes(EnvelopeTagV1, entry.key, payloadHashHex(entry.result),
                                    entry.storageVersion, keyId)
      let mac = sha256.hmac(key, envelope)
      # `signedAt` is informational only (RFC-0005 "signedAt is never
      # signed and never consulted by verify") -- never part of the
      # envelope above, never read back below.
      entry.attestation = some(Attestation(
        sigAlg:    saHmacSha256,
        signer:    keyId,
        signature: hmacBytesToSignature(mac),
        signedAt:  getTime().toUnix(),
      )),
    verify: proc(entry: StoredEntry): CacheVerdict =
      if entry.attestation.isNone: return cvTrustNoAttestation
      let att = entry.attestation.get
      if att.sigAlg != saHmacSha256: return cvTrustUnknownAlg
      if att.signer != keyId: return cvTrustSignerMismatch

      let envelope = envelopeBytes(EnvelopeTagV1, entry.key, payloadHashHex(entry.result),
                                    entry.storageVersion, att.signer)
      let expected = sha256.hmac(key, envelope)

      var raw: string
      try:
        raw = base64.decode(att.signature)
      except ValueError:
        return cvTrustBadSignature  # malformed signature -- fail closed, never raise

      var rawBytes = newSeq[byte](raw.len)
      for i in 0 ..< raw.len: rawBytes[i] = byte(raw[i])

      if not equalMemFull(rawBytes, expected.data):
        return cvTrustBadSignature

      cvOk,
  )
