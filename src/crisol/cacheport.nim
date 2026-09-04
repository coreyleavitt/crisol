## cacheport.nim — RFC-0005 A1: the cache port.
##
## The boundary between the runner and any store — local or remote — is a
## **closure-field object**, not a vtable/`method` dispatch: this matches the
## existing `CacheSeams` idiom exactly (`cachedispatch.nim`, three closure
## fields), stays zero-cost, and keeps adapters as plain data.
##
## This module owns the vocabulary every adapter, tier, trust policy, and
## serializer shares: `CacheVerdict` (get/put/verify all speak ONE enum),
## `Fetched[T]` ("a value exists iff cvOk" — a hit-with-an-error is
## unrepresentable), `StoredEntry` (the on-wire/on-disk shape), `CacheBackend`
## (the adapter contract), `TrustPolicy` (the sign/verify contract; only
## `nonePolicy` ships here — `hmacPolicy`/`ed25519Policy` are `cachetrust.nim`,
## Stage C, the ONLY module importing sello/nimcrypto), `TelemetrySink` (the
## observability contract; only the always-silent default ships here), and
## the pure envelope-byte joiner `envelopeBytes` the trust layer signs/verifies
## over (`canonicalPayload` itself lives in `resultcache.nim`, right beside
## `payloadToJson` which computes it — re-exported here so the port's public
## surface carries it, per RFC-0005's module-ownership table).
##
## Round-3 module split (RFC-0005 "Module layout"): keeping every cache type
## in one file would pull sello + nimcrypto into every importer of the hot
## path and every engine test. `cacheport` is the leaf the rest of the port
## (`cachetier`, `cachewire`, the adapters, `cachetrust`, `cachetelemetry`)
## imports; it imports only `types`, `keys`, and `resultcache`, and
## re-exports them so a module that imports ONLY `cacheport` (as the
## RFC's import DAG intends for `cachetier`/`cachewire`) still has
## `SoundnessKey`, `KeyInputs`, and `CachedResult` in scope.
##
## **`TelemetrySink` is generic over its event type (`TelemetrySink[E]`) —
## a confident deviation from the RFC's inline code sample, which shows
## `TelemetrySink.emit: proc(ev: TelemetryEvent)` grouped under a
## `# cachetelemetry.nim` comment.** That literal shape is impossible here:
## `cachetelemetry.nim` (Stage B2a) needs `CacheVerdict`/`TierVerdict` from
## `cacheport`/`cachetier` to define `TelemetryEvent`, so `cacheport`
## importing `TelemetryEvent` back would cycle — and the RFC's own
## module-ownership TABLE (as opposed to the inline sample) places
## `TelemetrySink` type + `NilSink` in `cacheport.nim` regardless. Making the
## sink generic keeps the type in `cacheport` (satisfying the table), keeps
## the documented import DAG acyclic (satisfying the sample's placement of
## `TelemetryEvent` in `cachetelemetry`), and costs nothing today since A1
## ships no event producer — B2a instantiates `TelemetrySink[TelemetryEvent]`.

import std/[options, sets]
import crisol/types
import crisol/keys
import crisol/resultcache

export types
export keys
export resultcache

# ---------------------------------------------------------------------------
# CacheVerdict — get / put / verify share ONE vocabulary.
# ---------------------------------------------------------------------------

## CacheVerdict/transportVerdicts/integrityVerdicts/trustVerdicts moved to
## crisol/types (RFC-0005 A3b) -- EntrypointResult.cacheLookup rides on
## CacheVerdict and types.nim cannot import this module (cacheport imports
## types) -- same relocation rationale as KeyComponent/KeyDiff (B1c). Still
## in scope here, unqualified, via `import crisol/types` + `export types`
## above.

# ---------------------------------------------------------------------------
# Fetched[T] — "a value exists iff cvOk" (hit-with-an-error unrepresentable).
# ---------------------------------------------------------------------------

type
  Fetched*[T] = object
    case verdict*: CacheVerdict
    of cvOk: value*: T
    else: discard

# ---------------------------------------------------------------------------
# StoredEntry — the on-wire/on-disk shape (RFC-0005 "The port").
# ---------------------------------------------------------------------------

type
  SigAlg* = enum
    ## String on the wire, enum in memory — mirrors resultcache's
    ## `parseOutcome`/`parseStatus` convention.
    saNone = "none"
    saHmacSha256 = "hmac-sha256"
    saEd25519 = "ed25519"

  Attestation* = object
    sigAlg*: SigAlg
    signer*: string
      ## SIGNED. ed25519: base64(pubkey bytes) — the SAME string as the
      ## `pinned-key` config entry; HMAC: the operator-chosen `key-id`
      ## string. Never a hash/truncation (no collision surface).
    signature*: string
      ## Raw bytes, base64 on the wire.
    signedAt*: int64
      ## Unix seconds; informational ONLY — never used in `verify`, never
      ## part of the signed bytes (clock skew across CI runners can never
      ## cause a spurious trust failure).

  StoredEntry* = object
    key*: SoundnessKey
      ## The content address (sole soundness key — unchanged). NOT part of
      ## the wire bytes a `CacheSerializer` encodes/decodes (the address is
      ## always contextual: a filename for local-fs, a URL path for
      ## http/s3, the table key for the `memory`/`memoryBytes` doubles) —
      ## `decode` returns an entry with `key` at its zero value; the
      ## backend that owns the addressing scheme fills it in.
    keyInputs*: Option[KeyInputs]
      ## 0005 writers ALWAYS set it (seeds the explain sidecar on
      ## backfill, Stage B1); decoders tolerate absence (a pre-0005 file).
    result*: CachedResult
      ## The landed rfc-0007 payload, verbatim: the run-phase OBSERVATION
      ## (`Exit` + `Cause` + `Evidence` + `Option[Rusage]` + `durationUs`)
      ## plus protocol records. NO outcome/exitCode/signal is stored.
      ## `result.payloadChecksum` IS the checksum — no duplicate field here.
    storageVersion*: int
      ## `StoredEntry` wire schema (`cachewire.storageFormatVersion`);
      ## mismatch ⇒ `cvVersionSkew`.
    attestation*: Option[Attestation]

# ---------------------------------------------------------------------------
# CacheBackend — the adapter contract.
# ---------------------------------------------------------------------------

type
  BackendGetProc* = proc(key: SoundnessKey): Fetched[StoredEntry] {.closure.}
    ## NEVER raises.
  BackendPutProc* = proc(entry: StoredEntry): CacheVerdict {.closure.}
    ## Best-effort; NEVER raises; `cvOk` on success.
  BackendProbeProc* = proc(keys: openArray[SoundnessKey]): Fetched[HashSet[SoundnessKey]] {.closure.}
    ## Optional bulk-existence check (nil ⇒ per-key `get`).

  CacheBackend* = object
    scheme*: string
      ## Adapter kind: "file" | "http" | "s3" | "memory" | "memorybytes"
      ## (registry id) — NOT the deployer's tier label (that's `Tier.name`).
    get*: BackendGetProc
    put*: BackendPutProc
    probe*: BackendProbeProc
      ## Nil-able capability — checked in exactly ONE place (Stage C3c
      ## prefetch). Neither test double sets it in A1.

proc canProbe*(b: CacheBackend): bool {.inline.} =
  b.probe != nil

# ---------------------------------------------------------------------------
# TrustPolicy — the port (RFC-0005 "TrustPolicy — the port").
# ---------------------------------------------------------------------------

type
  VerifyProc* = proc(entry: StoredEntry): CacheVerdict {.closure.}
    ## On-read; `cvOk` ⇒ entry may be served; else one of `trustVerdicts`.
  SignProc* = proc(entry: var StoredEntry) {.closure.}
    ## On-put; sets `entry.attestation` (no-op if no secret held).

  TrustPolicy* = object
    name*: string
      ## "none" | "hmac" | "ed25519".
    verify*: VerifyProc
    sign*: SignProc

proc nonePolicy*(): TrustPolicy =
  ## The default policy: `verify` unconditionally `cvOk` (trust is opt-in —
  ## a purely-local single-tier cache pays nothing), `sign` a no-op.
  TrustPolicy(
    name: "none",
    verify: proc(entry: StoredEntry): CacheVerdict = cvOk,
    sign: proc(entry: var StoredEntry) = discard,
  )

# ---------------------------------------------------------------------------
# TelemetrySink — the observability contract (see the module doc comment
# above for why this is generic in A1).
# ---------------------------------------------------------------------------

type
  TelemetrySink*[E] = object
    emit*: proc(ev: E) {.closure.}

proc NilSink*[E](): TelemetrySink[E] =
  ## The default sink: discards every event. Silent by construction — a
  ## purely-local run pays nothing for observability it never asked for.
  TelemetrySink[E](emit: proc(ev: E) = discard)

# ---------------------------------------------------------------------------
# canonicalPayload / envelopeBytes — integrity vs. trust (RFC-0005
# "Integrity vs. trust — two layers, two hashes, one canonical payload").
# ---------------------------------------------------------------------------

# `canonicalPayload*` is `resultcache.canonicalPayload` — defined there
# (beside `payloadToJson`, which it wraps) and re-exported here via
# `export resultcache` above, so it is reachable both as
# `crisol/resultcache.canonicalPayload` (today's callers) and as
# `crisol/cacheport.canonicalPayload` (the port's advertised surface).

proc envelopeBytes*(tag: string; key: SoundnessKey; payloadHashHex: string;
                     storageVersion: int; signer: string): string =
  ## The exact NUL-delimited byte sequence a `TrustPolicy.sign`/`verify`
  ## implementation signs/verifies (reusing `keys.nim`'s convention: every
  ## variable-width field is NUL-delimited so it cannot alias a neighbor).
  ## Pure and shared by sign and verify — one function, so they cannot
  ## disagree.
  ##
  ## `payloadHashHex` is the CALLER-supplied, already-recomputed
  ## cryptographic (SHA-256) hex digest of `canonicalPayload(result)` — this
  ## proc stays crypto-free by construction: Stage A ships zero SHA-256
  ## dependency; that arrives with the trust policies in Stage C
  ## (`cachetrust.nim`, the ONLY module importing nimcrypto/sello).
  tag & "\x00" & $key & "\x00" & payloadHashHex & "\x00" & $storageVersion & "\x00" & signer
