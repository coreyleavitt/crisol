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

import std/[base64, options, tables, times]
import nimcrypto
import sello
import crisol/cacheport

# RFC-0005 C5a: re-exported so a caller that imports THIS module (e.g.
# `cacheregistry.nim`'s `buildTrustPolicy`, which builds `seq[PublicKey]`
# from parsed `pinned-key` strings) can name these two types without
# itself gaining an `import sello` line -- this module stays the ONLY one
# with a bare `import sello`/`import nimcrypto` (module doc, above). Only
# the two wire-shaped types a consumer actually needs to hold (a moved-in
# seed, a pinned public key) are re-exported -- not the whole `sello`
# surface (x25519, ristretto, `Keypair`/`Signature` construction all stay
# internal to this module).
export sello.Seed
export sello.PublicKey

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

# ---------------------------------------------------------------------------
# Config/secret decode helpers (RFC-0005 C5a) -- pure base64 <-> sello-type
# conversions, `none` on malformed/empty input, NEVER raises. Both are
# called from `cacheregistry.buildTrustPolicy`'s "ed25519" branch: `secrets.
# signSeedB64` (raw, from `$CRISOL_CACHE_SIGN_KEY`, resolved in `api.nim`)
# is decoded fresh on every call via `decodeSignSeedB64`; each of `trust.
# pinnedKeys` (raw, from KDL `pinned-key`) is decoded via
# `decodePinnedKeyB64`, malformed -> a config error there. These helpers
# only parse -- they never decide whether a `none` is fatal.
# ---------------------------------------------------------------------------

proc decodeSignSeedB64*(b64: string): Option[Seed] =
  ## `$CRISOL_CACHE_SIGN_KEY` (base64 of the 32-byte ed25519 seed) -> `Seed`.
  ## `none` on empty input, malformed base64, or a decoded length != 32.
  if b64.len == 0: return none(Seed)
  var raw: string
  try:
    raw = base64.decode(b64)
  except ValueError:
    return none(Seed)
  if raw.len != 32: return none(Seed)
  var bytes: array[32, byte]
  for i in 0 ..< 32: bytes[i] = byte(raw[i])
  some(toSeed(bytes))

proc decodePinnedKeyB64*(b64: string): Option[PublicKey] =
  ## A `pinned-key` config string (base64 of a 32-byte ed25519 public key)
  ## -> `PublicKey`. `none` on malformed base64 or a decoded length != 32.
  var raw: string
  try:
    raw = base64.decode(b64)
  except ValueError:
    return none(PublicKey)
  if raw.len != 32: return none(PublicKey)
  var bytes: array[32, byte]
  for i in 0 ..< 32: bytes[i] = byte(raw[i])
  some(toPublicKey(bytes))

# ---------------------------------------------------------------------------
# ed25519Policy (RFC-0005 C5a)
# ---------------------------------------------------------------------------

proc ed25519Policy*(signSeed: sink Option[Seed]; pinned: seq[PublicKey]): TrustPolicy =
  ## ed25519 (sello) over the SAME shared envelope `hmacPolicy` signs (RFC-
  ## 0005 "TrustPolicy — the port"). `signSeed` is MOVED in (`Option[Seed]`,
  ## `sink` — this module's own `keypair(seed)` call is the only place a
  ## `Keypair` gets built, ONCE, here, inside this closure's environment;
  ## the C-dep smoke test's move-only-capture spike is exactly this shape).
  ## `none(Seed)` yields a VERIFY-ONLY policy (RFC-0005 "no-seed verify-only
  ## mode": a read-only consumer with no `$CRISOL_CACHE_SIGN_KEY` can still
  ## verify against `pinned`) — its `sign` is then a documented no-op,
  ## mirroring the port's own "no-op if no secret held" note.
  ##
  ## `signer` derivation is pinned (RFC-0005 "signer derivation is
  ## pinned"): `signer = base64(toBytes(pk))`, byte-identical to the
  ## `pinned-key` config string — so `verify` is a plain lookup against a
  ## table keyed by that exact string (built ONCE, here, at construction;
  ## rotation is a seq add/remove in config, never a code change).
  var pinnedByString = initTable[string, PublicKey]()
  for pk in pinned:
    pinnedByString[base64.encode(toBytes(pk))] = pk

  var seedOpt = signSeed
  var kp = none(Keypair)
  var signerB64 = ""
  if seedOpt.isSome:
    var built = keypair(move(seedOpt.get()))
    signerB64 = base64.encode(toBytes(built.public))
    kp = some(move(built))

  TrustPolicy(
    name: "ed25519",
    sign: proc(entry: var StoredEntry) =
      if kp.isNone: return  # verify-only participant: no secret held, no-op
      let envelope = envelopeBytes(EnvelopeTagV1, entry.key, payloadHashHex(entry.result),
                                    entry.storageVersion, signerB64)
      let sig = kp.get.sign(envelope)
      entry.attestation = some(Attestation(
        sigAlg:    saEd25519,
        signer:    signerB64,
        signature: base64.encode(toBytes(sig)),
        signedAt:  getTime().toUnix(),
      )),
    verify: proc(entry: StoredEntry): CacheVerdict =
      if entry.attestation.isNone: return cvTrustNoAttestation
      let att = entry.attestation.get
      if att.sigAlg != saEd25519: return cvTrustUnknownAlg
      if not pinnedByString.hasKey(att.signer): return cvTrustUnpinnedSigner
      let pk = pinnedByString[att.signer]

      var rawSig: string
      try:
        rawSig = base64.decode(att.signature)
      except ValueError:
        return cvTrustBadSignature  # malformed signature -- fail closed, never raise
      if rawSig.len != 64: return cvTrustBadSignature
      var sigBytes: array[64, byte]
      for i in 0 ..< 64: sigBytes[i] = byte(rawSig[i])

      let envelope = envelopeBytes(EnvelopeTagV1, entry.key, payloadHashHex(entry.result),
                                    entry.storageVersion, att.signer)
      if not pk.verify(envelope, toSignature(sigBytes)): return cvTrustBadSignature

      cvOk,
  )

# ---------------------------------------------------------------------------
# SigstorePolicy (RFC-0005 "Sigstore/Rekor is the natural next tier") --
# type NAMED and LOCKED behind `-d:crisolSigstore`; NO empty stub ships in a
# default build. This whole block compiles out entirely unless that define
# is passed -- a default `./dev check`/`./dev test` never sees it.
# ---------------------------------------------------------------------------

when defined(crisolSigstore):
  type
    SigstorePolicy* = object
      ## Reserved name for the Sigstore/Rekor follow-on trust policy.
      ## Deliberately empty: no fields, no `verify`/`sign` wiring, no
      ## constructor -- a real implementation is future work; this exists
      ## only so that work has an agreed-on type name to build against,
      ## per RFC-0005's explicit "no empty stub ships" instruction (this
      ## type is invisible to every build that does not pass
      ## `-d:crisolSigstore`).
