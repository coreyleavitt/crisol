# RFC-0005 — Distributed result cache, cryptographic trust & cache observability

**Status:** Draft (stage 2 — architect round 1 applied; **one open fork awaiting Corey: crypto-dependency strategy** — see §Open forks)
**Depends on:** RFC-0004 (incremental hermetic execution — the `ExecutionCache`, `SoundnessKey`, `CacheSeams`/`cachedispatch` seam, `RunLedger`, and the `isFullyAchieved && attempt-1` publish gate this RFC extends)
**Scope owner:** Corey

## Summary

RFC-0004 made crisol an *incremental* engine: a test's outcome is content-addressed by a `SoundnessKey` and served from a local on-disk `ExecutionCache` when its inputs are provably unchanged. That cache is **single-host and single-tenant** — it never crosses the machine that produced it. The dominant remaining cost is the *cold* host: every CI runner, every fresh clone, every teammate re-runs work some *other* host already proved. The same `SoundnessKey` that makes the local cache sound makes it **portable** — equal key ⇒ equal result, on any host with the same toolchain (RFC-0004 already folds `nimVersion`/`ccVersion`/libc into the key precisely so cross-host reuse is sound by construction, not by luck).

This RFC spends that portability. It does three things, in the architectural class of Bazel Remote Execution's *cache-only* tier, `sccache`, `cargo`'s emerging registry cache, and Nix's binary caches:

1. **Distributed result cache** — a **ports-and-adapters** `CacheBackend` boundary, a multi-tier `TieredCache` (L1 local → L2 shared → L3 …) with populate-on-hit backfill, and shippable `local-fs` / `http` / `s3` adapters behind a registry. The runner blocks on **none** of it: a remote miss, timeout, or offline backend is *exactly* a local miss — the run proceeds.
2. **Cryptographic trust** — a `TrustPolicy` port (`none` / HMAC / **ed25519 signed attestation**), verify-on-read and sign-on-publish, so a shared cache served by infrastructure crisol does not control cannot inject a forged "this test passed" result. (REFERENCE.md category 3: *remote but owned* — the boundary is a port; the wire is attested.)
3. **Cache observability** — `explainMiss` (which of the 9 key components changed, so a surprise miss is *legible*), hit-rate telemetry (a `TelemetrySink` port + summary line + `run/v1` field), and `--verify-cache` (a **post-run** re-execution sample that catches nondeterminism the hermeticity gate structurally cannot).

Everything stays at **entrypoint-binary granularity** and **binary-opaque** identity (MEMORY.md → boundary-granularity-discriminator). This RFC adds *backends, trust, and visibility* to the existing cache; it does **not** add a new content-address key or a new soundness rule, and it does not add any sub-binary control. **`lookupAtPlan` / `shouldStore` / `CacheContext` / `inactiveDecision` keep their existing semantics** — the publish gate (`isFullyAchieved && attempt-1 pass`) still lives in `shouldStore`, *before* the trust layer ever sees a write. (`LoadProc`'s adapter and `CacheDecision` grow additively — see §Wiring; this is round-1's correction to an over-strong "byte-for-byte unchanged" claim.) Distributed *execution* (remote workers) remains a Non-Goal; `--shard` is still the only distribution primitive for *running*.

## Motivation

- **The cold host re-proves the warm host's work.** RFC-0004's cache is keyed by content, so a result computed on host A is *valid* on host B — but B can't see A's `<stateDir>/cache/`. CI runners are the acute case: N matrix shards, each cold, each re-running the full unchanged suite. A shared L2 turns "first runner pays, rest reuse" into the default.
- **A shared cache is an attack surface the local cache never was.** The moment a result crosses a trust boundary (a teammate's upload, an S3 bucket, a CI artifact store), "this entrypoint passed" becomes a claim crisol must *verify*, not assume. A forged pass is a silent test-suite bypass. RFC-0004's gate guarantees crisol only *publishes* sound results; it says nothing about whether a result crisol *reads back* was published by crisol under that gate. Trust closes that gap.
- **The cache is currently a black box when it misses.** A developer who expects a hit and gets a miss has no way to ask *why* — which of `{closureContentHash, flagHash, nimVersion, ccVersion, fixtureHash, argv, rlimitConfig, hermeticEnvHash, protocolMajor}` moved. "Why did my whole suite re-run after a `glibc` bump?" should be a one-flag answer, not a `strace` session.
- **The soundness gate is necessary but not sufficient for determinism.** `isFullyAchieved` proves the *environment* was hermetic; it cannot prove the *binary* is deterministic given that environment (RFC-0004 §"Honesty about the limit"). A test that reads `/dev/urandom` and happens to pass on attempt 1 caches a coin-flip. `--verify-cache` is the empirical backstop: re-run a sample, compare, surface divergence.
- **The unifying observation:** the local cache, the remote cache, and the verifier all want the *same* `(key → entry)` contract. Define that contract as a port once; local-fs, http, s3, and the in-memory test double are all just tenants. The runner's hot path depends on the *port*, never on a backend.

## The spine (dependency order)

```
A  CacheBackend port  ──► B  observability  ──► C  remote + trust
   (StoredEntry wire,      (explainMiss,          (crypto dep → http/s3
    TieredCache w/          hit-rate telemetry,    adapters → registry
    provenance, registry,   --verify-cache)        wiring → TrustPolicy:
    in-mem + local-fs)                             none/HMAC/ed25519)
```

**The load-bearing refactor is A, and it is mostly plumbing.** `realSeams` today closes over `loadCached`/`storeCached` directly (`cachedispatch.nim:336`). Stage A re-expresses that *same* local behavior as a single-tier `TieredCache` over a `local-fs` `CacheBackend` adapter. The observable behavior is identical; only the indirection changes — but the change touches `cachedispatch.nim` (the `realSeams` signature), `api.nim` (the call site), and the **direct `realSeams` callers in `tests/unit/test_cachedispatch.nim` and `tests/unit/test_api.nim`**, which must be updated atomically (see slice A2b). B and C are then additive tiers and policies layered onto a boundary that already exists. Nothing downstream of the seam (`lookupAtPlan`, `shouldStore`, the `execute()` dispatch) changes shape.

**Soundness coupling (unchanged, restated):** the `SoundnessKey` remains the **sole content address**. A backend is a *transport* for `(key, CachedResult)`; it never participates in key derivation, never relaxes the gate. Only an entry that passed `shouldStore` (`isFullyAchieved && attempt-1`) is ever handed to a backend's `put`. Trust verification happens *on read*, after transport, before the entry is allowed to satisfy a lookup — a backend that returns a tampered or unsigned entry on a trust-requiring tier yields a **miss**, never a served result.

## The port: `CacheBackend` and `StoredEntry` (read this before Stage A)

The boundary is a **closure-field object**, not a vtable or `method` dispatch — this matches the existing `CacheSeams` idiom exactly (`cachedispatch.nim:102`, three closure fields), stays zero-cost, and keeps adapters as plain data. All declared in a new **`cacheport.nim`** (imports `types` + `resultcache`'s `CachedResult`; sits one import level *below* `cachedispatch`, so `realSeams` composes a backend into the existing seams without any new dependency edge crossing the planner).

```nim
type
  StoredEntry* = object
    key*:             SoundnessKey      ## the content address (sole soundness key — unchanged)
    keyInputs*:       Option[KeyInputs] ## for explainMiss; adapters MAY omit on the wire (see B1)
    result*:          CachedResult      ## the RFC-0004 payload, verbatim
    payloadChecksum*: string            ## FNV over the canonical-serialized result (integrity; see below)
    formatVersion*:   int               ## StoredEntry WIRE schema (storageFormatVersion); mismatch ⇒ miss
    attestation*:     Option[Attestation]

  Attestation* = object
    sigAlg*:    string   ## "none" | "hmac-sha256" | "ed25519"
    signer*:    string   ## key id / pinned-key fingerprint — SIGNED (binds claimed signer to key; see Trust)
    signature*: string   ## raw bytes, base64 on the wire
    signedAt*:  int64    ## unix seconds; informational ONLY — never used in verify, never in the signed bytes

  BackendConfig* = object
    ## ALL backend-specific config flows through here; a factory captures NOTHING
    ## from wiring-time context (keeps buildBackend a pure fn of (name, cfg)).
    url*:      string                 ## e.g. "file://<stateDir>/cache", "s3://bucket/prefix", "https://…"
    settings*: seq[(string, string)]  ## adapter-specific (region, timeout-ms, …)

  CacheError* = enum                  ## why a get/put returned none/false (for telemetry, NOT control flow)
    ceNone, ceMiss, ceTimeout, ceOffline, ceCorrupt, ceVersionSkew, ceTrustFail, ceUnauthorized

  CacheBackend* = object
    name*:   string                                                   ## registry id, telemetry label
    get*:    proc(key: SoundnessKey): BackendGet {.closure.}          ## NEVER raises
    put*:    proc(entry: StoredEntry): BackendPut {.closure.}         ## best-effort; NEVER raises
    list*:   proc(): seq[SoundnessKey] {.closure.}                    ## optional (nil ⇒ GC/prefetch skip)
    delete*: proc(key: SoundnessKey): bool {.closure.}                ## optional (nil ⇒ GC skips this tier)

  BackendGet* = object
    entry*: Option[StoredEntry]
    err*:   CacheError          ## ceNone on a real hit; ceMiss/ceTimeout/… explain a none
  BackendPut* = object
    ok*:    bool
    err*:   CacheError          ## ceNone on success; explains a false
```

**The total-function contract is the whole point.** `get`/`put` **never raise** and never block the run unboundedly: a miss, a corrupt payload, a checksum/format-version mismatch, a failed trust check, a network timeout, an offline backend, and an unauthorized write are **all** surfaced as `none`/`false` to the *control* path — the runner's hot path cannot tell a remote outage from a cache miss, by design ("run never blocks on remote" falls out of the type). **But the `err` field carries *why*** so the observability layer can distinguish a clean miss from an adapter failure (Breadth F2 — a typo'd S3 URL must not masquerade as a cold cache). Remote adapters wrap their own per-call deadline internally; the L1 local tier is synchronous with no timeout.

### Integrity vs. trust — two layers, one canonical hash (round-1 fix)

`payloadChecksum` and `Attestation.signature` are **not** redundant — they guard different transport layers (Design F2) — but they MUST agree on *what* they hash, and the verifier MUST recompute, never trust the stored field (Depth F2). The rule, spec-level and non-negotiable:

1. **Canonical payload hash is recomputed on every read.** An adapter that materializes a `StoredEntry` from bytes (http/s3) MUST: deserialize `result`, re-serialize it via the *same* canonical proc the writer used, recompute `FNV(canonical(result))`, and assert it equals `entry.payloadChecksum` — **before** the entry is eligible to be served or trust-verified. Mismatch ⇒ `BackendGet{none, ceCorrupt}`. (The `local-fs` adapter already does exactly this inside `loadCached` — `resultcache.nim:265`; the wire adapters replicate it.)
2. **The signed envelope binds the recomputed hash, the key, the wire format, and the signer.** The bytes ed25519/HMAC sign are a deterministic serialization of exactly `(key, payloadChecksum, formatVersion, signer)` — where `payloadChecksum` is the value just *recomputed* in step 1, not the field as received. Including `signer` binds the claimed identity to the verifying key, defeating key-confusion (an attacker holding pinned key A cannot mint an entry attributed to signer B). `signedAt` is **never** signed and **never** consulted by `verify` (so clock skew across CI runners can never cause a spurious trust failure — Breadth F3).

This makes the two layers compose cleanly: integrity (FNV) catches bit-rot/in-transit corruption on every tier including untrusted local; trust (signature over the *recomputed* FNV) catches forgery on `requireTrust` tiers. A forger who swaps the payload but leaves `payloadChecksum` stale is caught at step 1; one who fixes the checksum too is caught at step 2 (no valid signature over the new hash).

### `TieredCache` — the composition, with provenance

The central round-1 redesign (Depth F5 + Design F1 + Breadth F11, all independent): `get` must NOT discard which tier hit and whether trust passed — telemetry, `run/v1` provenance, and the backfill rule all need it. So the engine returns a rich `TierHit`, and the thin `LoadProc` adapter in `realSeams` projects it down to the unchanged `Option[CachedResult]`.

```nim
type
  TierConfig* = object
    backend*:       CacheBackend
    backfillOnHit*: bool   ## write to THIS tier when a DOWNSTREAM tier serves the hit (renamed from populateOnHit)
    verifyTrust*:   bool   ## reject entries READ from this tier that fail TrustPolicy (renamed from requireTrust)

  TieredCache* = object    ## a PURE lookup engine — no TelemetrySink field (moved to the realSeams adapter)
    tiers*:  seq[TierConfig]    ## L1 → L2 → L3, searched in order
    trust*:  TrustPolicy

  TierHit* = object
    result*:    CachedResult
    tierName*:  string   ## which tier served it (for run/v1 provenance + telemetry)
    tierIndex*: int      ## 0 = L1, 1 = L2, …
    verified*:  bool     ## true iff the entry PASSED trust verification (NOT merely "the tier didn't require it")

proc getWithProvenance*(tc: TieredCache; key: SoundnessKey): tuple[hit: Option[TierHit]; err: CacheError]
proc put*(tc: TieredCache; entry: StoredEntry): seq[BackendPut]   ## one result per tier (for remoteErrors telemetry)
```

- **`getWithProvenance` (waterfall):** search tiers in order. On a tier `get`, if `verifyTrust`, run `tc.trust.verify(entry)`; **fail ⇒ treat as a miss on that tier and continue** (never serve a failed entry, never abort; the tier's `err` becomes `ceTrustFail`). Track the served entry's `verified` bit = *did it actually pass `verify`* (always run `verify` for the bit even on non-`verifyTrust` tiers where the result is advisory). On the first servable hit, **backfill** earlier `backfillOnHit` tiers subject to the rule below. Returns the `TierHit` and an aggregate `err` explaining a total miss (`ceMiss` if every tier was a clean miss; the strongest failure code otherwise, so 100%-`ceUnauthorized`/`ceTimeout` is diagnosable).
- **`put` (fan-out):** the entry has *already* cleared `shouldStore`'s gate. Sign **once** via `tc.trust.sign` (if the policy signs). The `local-fs` L1 tier (with `verifyTrust:false`) is written via its existing RFC-0004 path which stores only the `CachedResult` — **the attestation is stripped for `verifyTrust:false` tiers** so Stage A is truly format-identical to RFC-0004 and `resultcache.nim`'s on-disk schema is untouched (Depth F8). `verifyTrust:true` tiers receive the full signed `StoredEntry`. Returns per-tier `BackendPut` so telemetry can count remote write failures.

**The `verified`-bit backfill rule (Depth F4 + Feasibility F9 — the one real correctness subtlety, now enforceable).** `verifyTrust` is a *tier* predicate; it is NOT an entry's trust level. Backfill must key on the served entry's actual `verified` bit:

> **Backfill tier `t` only if `hit.verified OR not t.verifyTrust`.**

i.e. an unverified entry may populate only tiers that don't verify trust; a verified entry may populate any tier. This is three lines and is exhaustively boundary-tested across the 2×2×2 matrix (`source verified ∈ {T,F}` × `destination verifyTrust ∈ {T,F}` × tier ordering). **Because `nonePolicy.verify` always returns true, the security-meaningful cases (an *unverified* entry refused at a `verifyTrust:true` destination) cannot be exercised until a policy that can return `false` exists — so A3 tests the structural rule with an injected controllable mock `TrustPolicy` (two lines, since `TrustPolicy` is a closure-field object), and C4/C5 add the real-policy interaction tests** (Feasibility F9).

### `TrustPolicy` — the port

```nim
type
  TrustPolicy* = object
    name*:   string
    verify*: proc(entry: StoredEntry): bool {.closure.}   ## on-read; true ⇒ entry may be served
    sign*:   proc(entry: var StoredEntry)     {.closure.} ## on-put; sets entry.attestation

proc nonePolicy*(): TrustPolicy                                    ## verify ⇒ true; sign ⇒ no-op
proc tokenPolicy*(secret: string): TrustPolicy                     ## HMAC-SHA256 over the signed envelope
proc signedPolicy*(signKey: Option[Ed25519Secret];
                   pinned: seq[Ed25519Public]): TrustPolicy        ## ed25519: sign if we hold the key; verify against pinned set
```

- **The signed envelope is canonical, explicit, and recompute-bound** (see §Integrity vs. trust): the bytes signed are a deterministic serialization of `(key, recomputed-payloadChecksum, formatVersion, signer)`. The canonicalization proc is pure and shared by sign and verify (one function ⇒ they cannot disagree).
- **`verify` is total and fail-closed:** a missing attestation, wrong `sigAlg`, unknown/unpinned `signer`, signer-mismatch, or bad signature all return `false`. A `verifyTrust` tier serving such an entry produces a miss. `nonePolicy.verify` is unconditionally `true` — trust is *opt-in per tier*, so a purely-local single-tier cache pays nothing.
- **Multi-signer = multi-trust-domain (Depth F1, documented constraint).** Pinning a public key means *trusting that signer ran `shouldStore` honestly under a compatible config*. Two parties sharing one L2 and pinning each other's keys form one trust domain by construction; a malicious or misconfigured pinned signer can serve a result for a shared `SoundnessKey`. This is inherent to a shared cache and is the deployer's call — **pin only keys whose `shouldStore` discipline you trust.** crisol's job is to guarantee the signature genuinely came from a pinned signer (which `signer`-in-envelope now does); it cannot vouch for that signer's hermeticity config.
- **HMAC vs ed25519 — both ship; the choice is the deployer's threat model, with a sharp caveat.** HMAC (`tokenPolicy`) is symmetric: simplest when every trusted party shares one CI secret; **anyone who can verify can forge.** It is appropriate ONLY when (a) the CI is fully trusted — *no untrusted PR builds*, since the "secrets in fork PRs" problem exposes the symmetric key to attacker-controlled test code — and (b) the secret is not readable by test binaries. ed25519 (`signedPolicy`) is asymmetric: publishers hold a secret, everyone else pins only public keys, so a read-only consumer (the common case) cannot forge — the right default for an open or multi-party cache.
- **The signing/HMAC secret MUST be excluded from the hermetic env allowlist** (Depth F7). `$CRISOL_CACHE_SIGN_KEY` and any HMAC secret are *not* in RFC-0004's default passthrough set, and a deployer must never add them — otherwise a test binary `getenv`s the signing key and can forge. This is a documented hard constraint on both policies.
- **Sigstore/Rekor** (keyless, transparency-log-backed) is the natural next tier; its `SigstorePolicy` type is named and locked but its implementation lives behind `when defined(crisolSigstore)` — **no empty stub ships** (RFC-0004 self-review correction #2). Follow-on, not 0005 scope.

### `BackendRegistry`, serializer, telemetry — and where each lives

```nim
type CacheSerializer* = object        ## StoredEntry ⇄ bytes; JSON-only ships (msgpack deferred, port exists)
  encode*: proc(e: StoredEntry): string {.closure.}
  decode*: proc(s: string): Option[StoredEntry] {.closure.}

type TelemetrySink* = object          ## NilSink default; LogSink + InMemorySink(tests)
  emit*: proc(ev: TelemetryEvent) {.closure.}

proc registerBackend*(reg: var BackendRegistry; scheme: string;
                      factory: proc(cfg: BackendConfig): CacheBackend {.closure.})
proc buildBackend*(reg: BackendRegistry; cfg: BackendConfig): Option[CacheBackend]
  ## resolves the adapter by URL SCHEME (file/http/https/s3/memory) — see Config
```

- **Registry resolves by URL scheme**, not a redundant `backend` field (Design F5): `s3://…`→s3, `https://…`→http, `file://…`→local-fs, `memory://…`→test double. `buildBackend` is a pure function of `BackendConfig`; factories capture nothing (Feasibility F11). Adding a transport = one file + one `registerBackend(scheme, factory)`.
- **`CacheSerializer` is consumed ONLY by the wire adapters (http/s3).** The `local-fs` adapter calls `storeCached`/`loadCached` directly and **bypasses the serializer** — no double encode/decode on the hot local path (Feasibility F8). The port exists so msgpack is a later adapter (Corey's locked Full-Flexible decision); only JSON ships. (Round-1 design lens flagged this port as shallow; it is retained per the accepted over-engineering trade-off, with the bypass making it zero-cost on the common path.)
- **`TelemetrySink` lives at the `realSeams` adapter, NOT on `TieredCache`** (Design F1/F4). `TieredCache` is a pure lookup engine, testable with no sink. The `realSeams.load` adapter owns telemetry emission and tier-provenance population — it is the translation layer between the internal `getWithProvenance` and the external `CacheSeams.load`, which is exactly where an observation of the call belongs. `InMemorySink` (the test double) is wired at `realSeams`/api construction.

### Wiring — what changes at the seam (and what doesn't)

```nim
proc realSeams*(tc: TieredCache; sink: TelemetrySink; stateDir: string;
                graph: ptr DepGraph; ...): CacheSeams =
  CacheSeams(
    keyOf: <unchanged — derives SoundnessKey from PlannedEntrypoint>,
    load:  proc(key: SoundnessKey): Option[CachedResult] =
             let (hit, err) = tc.getWithProvenance(key)
             if hit.isSome:
               sink.emit(TelemetryEvent(kind: tekHit, tier: hit.get.tierName, durationMs: hit.get.result.durationMs))
               # tier provenance + (if err==ceTrustFail upstream) reach the result via the plan-lookup path
               some(hit.get.result)
             else:
               sink.emit(TelemetryEvent(kind: tekMiss, err: err))
               none(CachedResult),
    store: proc(key: SoundnessKey; res: CachedResult): bool =
             let puts = tc.put(toStoredEntry(key, res, keyInputsFor(...)))
             for p in puts:
               if p.err in {ceUnauthorized, ceTimeout, ceOffline}: sink.emit(TelemetryEvent(kind: tekRemoteErr, err: p.err))
             puts.anyIt(it.ok),
  )
```

`realSeams` gains a `TieredCache` and a `TelemetrySink` parameter; it composes `load`/`store` as thin adapters. **`CacheSeams`'s three-closure shape, `LoadProc`/`StoreProc`'s signatures, `lookupAtPlan`, `shouldStore`, `CacheContext`, `cacheEnabled`/`cacheDisabled` are unchanged.** Two additive deltas (honest correction to the over-strong original claim): (a) `CacheDecision` gains a `cdmTrustFail` variant so a trust-rejected read is distinguishable from a clean key-miss in `run/v1` and `--cache-stats`; (b) `EntrypointResult` gains an optional `cacheTier: string` provenance field (which tier served a `cdmHit`), populated by the adapter. Both are additive under RFC-0004's `schemaRevision` discipline; the *enum's existing variants and `lookupAtPlan`'s logic are untouched*. A purely-local run (the default) builds `TieredCache{tiers: @[localFsTier], trust: nonePolicy()}` + `NilSink` via the `localOnlyCache` factory (below) — behaviorally identical to RFC-0004.

### Construction ergonomics — factories keep `api.nim` thin

To keep `api.nim`'s already-dense `runTests` from absorbing tier/registry/trust/credential assembly (Design F9), construction lives in `cacheport.nim`:

```nim
proc localOnlyCache*(stateDir: string): TieredCache
  ## single-tier local-fs, nonePolicy. The default for every run with no remote configured.
proc configuredCache*(cfg: CacheConfig; stateDir: string; reg: BackendRegistry): TieredCache
  ## build tiers from the parsed KDL `cache` block; returns localOnlyCache if no remote tier. Resolves
  ## trust policy + credentials per tier. api.nim only decides WHICH factory to call.
```

## Stage B — observability (additive on the port)

### Miss-explanation — `explainMiss`

```nim
type KeyComponent* = enum   ## renamed from MissReason — it names WHICH of the 9 key inputs differs (Design F7)
  kcClosure, kcFlags, kcNimVersion, kcCcVersion, kcFixtures, kcArgv,
  kcRlimit, kcHermeticEnv, kcProtocol
type KeyDiff* = object
  component*: KeyComponent
  prev*, curr*: string

proc explainMiss*(prev, curr: KeyInputs): seq[KeyDiff]   ## PURE; diffs the 9 components
```

A miss is *legible* only if you can recover the *previous* inputs for the *same test*. The mechanism: the local tier writes a **`KeyInputs` sidecar keyed by PATH** — *not* `identityKey(path, flagHash)`. Keying by the full identity key would make a flag change (the single most common deliberate miss) produce a *different* sidecar key ⇒ "no prior inputs" instead of the answer "your flags changed" (Depth F6). Keyed by path, the sidecar stores a small map `flagHash → KeyInputs` (most-recent-per-flagHash, pruned on write); on a miss, crisol loads the path's sidecar, picks the most-recent prior `KeyInputs`, and diffs against `curr` — correctly surfacing `kcFlags`. Absent any sidecar (older writer or first-ever run) it **degrades gracefully** to "no prior inputs recorded." `--explain-miss` renders the `KeyDiff`s.

Sidecar mechanics, pinned (Breadth F8, Feasibility F7): it is a **local-fs-adapter implementation detail, not a `CacheBackend` contract** (the `memory` test double does not exercise it; B1 tests it via the local-fs boundary suite). Serialize via hand-written `keyInputsToJson`/`keyInputsFromJson` in `cacheport.nim` following `resultcache.nim`'s `payloadToJson` pattern (`Option[int64]` → absent-on-`none`); **do not** reach for `std/jsonutils` (no new stdlib dep, consistent with the codebase). Sidecar content is **portable** (equal identity ⇒ equal `KeyInputs` on any host), so a backfill may legitimately write it. Sidecar files carry a distinguishable name prefix and are included in the local-fs `list`/`delete` capability so `gcResultCache` (RFC-0004 A1c) prunes them; absent GC they are bounded by the count of distinct paths. Rename-collision (a path reused by a different entrypoint) overwrites the stale sidecar on next `put` — documented, low-impact.

### Hit-rate telemetry

A `TelemetrySink` aggregates events emitted by the `realSeams` adapter (hit + tier, miss + `err`, remote-error, publish). At run end crisol emits one summary line — **L1 hits / remote hits / misses / remote-errors / total / hit-% / wall-time-saved / published** — and a structured `cacheStats` object in `crisol/run/v1`. `remote-errors` (Breadth F2) makes a misconfigured remote (100% `ceUnauthorized`/`ceTimeout`/`ceOffline`) diagnosable instead of masquerading as a cold cache; crisol additionally writes a **stderr warning when a configured remote tier errored on every call** in a run. `wall-time-saved` sums the `durationMs` of served `cdmHit` entries. Default sink `NilSink`; `--cache-stats` installs the summary sink; `InMemorySink` is the test double.

### `--verify-cache` — the determinism backstop

`isFullyAchieved` proves hermeticity, not determinism. `--verify-cache[=PCT]` (default sample 5%) re-executes a random sample of entrypoints that were served `cdmHit` this run, compares the fresh outcome+records to the cached one, and on divergence reports it. It is a **post-run pass**, never in the hot path (self-review correction #3): the run completes and reports on cached results immediately; verification is a trailing pass. Hard requirements (Depth F3 + Feasibility F6 + Breadth F9):

- **No cache writes during verify.** The verify pass is constructed with `cache = cacheDisabled(spec)` so `shouldStore`/`put` are never reached — it cannot overwrite the entry it is checking, reset LRU age, or re-publish a divergent result.
- **`--retries 0` for the verify pass.** A retry would mask the very flakiness verify exists to find (a fail-then-pass would compare pass-vs-cached-pass — no signal). Single attempt makes divergence observable (Depth F9).
- **Synthetic plan, not a re-`plan()`.** The pass builds a `RunPlan` directly from the sampled subset of the first run's `PlanReport.entrypoints` (already-available `PlannedEntrypoint` values), `jobs = 1` for determinism; it does not re-discover entrypoints or mutate/save the depgraph.
- **Isolated telemetry.** A fresh/filtered sink so verify events don't double-count into the main run's `cacheStats`.
- **Divergence is user-visible, not swallowed** (Breadth F9): a `verifyFail` produces a **stderr warning even under `NilSink`**, a `verifyFails` count in the `--cache-stats` summary, and the human render names the entrypoint. `--verify-cache-strict` makes a divergence set exit code 1 (CI gate); default `--verify-cache` reports without failing. It **never evicts** (a divergence is a human signal — "set `cacheable #false`" — not an automatic action).

**Concurrency reconciliation (self-review correction #5 — load-bearing).** crisol's runner is a single-threaded fork/poll loop (`execute()`), *not* an async runtime. `--verify-cache` introduces no competing primitive: it runs *after* the main poll loop drains, as a second bounded `execute()` over the sampled subset. (`execute()` re-entrancy: it re-opens a fresh ledger shard — fine — and the synthetic plan carries only `edRunFresh` entries so no compile/graph-write occurs; C0 verifies these properties before B3 is written.) Remote backend I/O (Stage C) follows the same discipline — a remote `get`/`put` is either a **synchronous call with an internal deadline** (default) or, for opt-in plan-time prefetch, a **bounded worker pool drained at a defined join point** — never an event loop bolted alongside the fork/poll core. C0 pins this with a written rationale before any network code.

## Stage C — remote + trust (the network-touching tail)

> **C depends on a crypto-dependency decision (see §Open forks).** HMAC-SHA256 (C4, and AWS SigV4 for authenticated S3) and ed25519 (C5) are **absent from the Nim stdlib**; crisol currently depends only on `nkdl`. The slices below assume the recommended resolution (nimcrypto for HMAC/SHA-256; a dedicated ed25519 source; initial S3 scoped to unsigned/MinIO). **The exact libraries and the S3-auth scope are the open fork awaiting Corey** — slice ordering and `milpa.kdl`/Dockerfile deltas finalize once chosen.

- **`HttpFetcher` transport seam** (Feasibility F3): the http/s3 adapters take an injected `HttpFetcher = proc(meth, url, body: string; headers: seq[(string,string)]): tuple[status: int; body: string] {.closure.}`. Production wires it to `std/httpclient` (with `-d:ssl`); tests wire a pure in-memory proc — **no socket in the suite** (satisfies the "no real network" hard constraint cleanly, vs. a loopback server). HTTPS needs OpenSSL in the podman image (the base has only gcc/git/Nim) — slice **C1a** adds `libssl-dev` to the Dockerfile + the `-d:ssl` build flag and verifies the build *before* adapter logic.
- **Adapters:** `local-fs` (Stage A, shipped), then `http` (GET/PUT/HEAD over a content-addressed URL `<base>/<storageFormatVersion>/<soundnessKey>`, `Content-Type: application/json`, internal deadline, total-function with `CacheError` on every failure) and `s3` (same contract over the S3 object API). **`storageFormatVersion` is a NEW integer covering the `StoredEntry` wire shape — distinct from RFC-0004's `resultCacheFormatVersion` (the `CachedResult` payload)** (Breadth F10). The in-process **fake server** double (the `memory` backend behind the http/s3 codec) validates method/status/Content-Type/auth-header so C1/C6 catch real-server mismatches.
- **Concurrent PUT idempotency** (Breadth F1): the wire key is `<storageFormatVersion>/<soundnessKey>` only; `signedAt` varies across writes to the same key but is excluded from the signed bytes and from key identity, so last-writer-wins is sound (equal key ⇒ equal payload ⇒ equal signature-over-payload). The S3 adapter relies on S3 last-writer-wins; the http adapter treats a 409/`ceUnauthorized`/duplicate as a best-effort `false` (first publisher wins, swallowed) — documented, not an error.
- **`TieredCache` wiring in `api.nim`** via `configuredCache`; populate-on-hit + `verified`-bit backfill active. `--no-remote-cache` drops all non-L1 tiers (local cache still active).
- **Trust:** `none` → HMAC → ed25519, in that slice order (each independently testable).
- **Plan-time remote prefetch (latency)** (Breadth F14): naïve per-entrypoint serial remote GETs cost one round-trip × N entrypoints; for a 200-test suite at 150 ms that is minutes or an N-wide request burst. Mitigation: at plan time, when a remote tier exposes `list()` (or a bulk-existence endpoint), crisol fetches the key set **once** and resolves lookups locally; otherwise it bounds concurrency via the C0 worker pool with a per-run deadline. A bloom-filter/negative-cache is deferred (documented in §Alternatives). The hot-path "never blocks" guarantee is preserved by the per-call deadline regardless.

### Secure-by-default (a soundness/security stance, not a fork — [[no-fake-forks-soundness]])

**Reading** a remote tier needs only a read-scoped credential; **publishing** requires a *write-scoped* credential, and there is **no `--publish` flag** — you publish iff you hold a write credential (`ceUnauthorized` `put` → no-op `false`, run still serves reads). This makes "poison the shared cache from a dev laptop" structurally impossible. The publish gate (`isFullyAchieved && attempt-1`) is *upstream* of credentials — credentials gate *transport*, the gate decides *storability*; an entry must clear both. Signing/read keys come from **environment**, never config files.

### Configuration

```kdl
cache {
    remote "team-s3" {                 // a named tier appended after local L1
        url "s3://ci-cache/crisol"     // SCHEME selects the adapter; no redundant `backend` field
        trust {
            policy "ed25519"           // none | hmac | ed25519
            pinned-key "…base64…"      // repeatable; verify against this set
            // sign-key from $CRISOL_CACHE_SIGN_KEY (env, never config) when publishing
        }
        verify-trust #true             // this tier's entries must verify (default #true for a configured remote)
        backfill-on-hit #true
    }
    telemetry {
        hit-rate #true
        explain-miss #true
        verify-cache-pct 5
    }
}
```

Flags: `--no-remote-cache`, `--explain-miss`, `--verify-cache[=PCT]`, `--verify-cache-strict`, `--cache-stats`. CLI > env > config.

### Remote cache deployment (operator guide — Breadth F12)

Analogous to RFC-0004's §CI deployment. To stand up a shared cache:
- **S3:** create a bucket; a **read** IAM policy (`s3:GetObject`, `s3:ListBucket` on the prefix) for consumers; a **write** policy (adds `s3:PutObject`) for publishers; supply creds via standard AWS env (`AWS_*`). Read-only consumers get the read policy only — they cannot publish regardless of flags.
- **ed25519 keys:** generate a keypair (e.g. `openssl genpkey -algorithm ed25519`); the secret goes in the publisher's `$CRISOL_CACHE_SIGN_KEY` (CI secret); the public key(s) go in every consumer's `pinned-key` config. **Never** add `$CRISOL_CACHE_SIGN_KEY` to the env allowlist.
- **Key rotation** (Breadth F4): add the new public key to `pinned-key` alongside the old (dual-pinned window), cut publishers over to the new secret, then drop the old public key. Entries signed with the dropped key become misses (self-healing: re-run re-publishes under the new key) — costs cache warmth, never correctness. **ed25519 rotation is incremental; HMAC rotation is a full cold-cache event** (all prior HMACs invalid at once) — a concrete argument for ed25519.
- **Compromise / poison response** (Breadth F5): crisol has no `put`-time poisoning path (the gate), but a storage-layer compromise or a pre-`verify-trust` bad entry is purged **backend-side** (delete the S3 object / HTTP resource), or globally via key rotation (drops every old-key entry on `verify-trust` tiers). `CacheBackend.delete` exists but a `crisol cache <delete|stat|push>` CLI is a **deferred follow-on**, not 0005 scope — documented so operators know the manual path.
- **`--shard` × remote** (Breadth F7): shard selection determines which entrypoints *reach* the cache lookup; the cache is keyed by `SoundnessKey` (not shard membership), so any shard can hit any entry. A full-coverage warm-up requires a full (unsharded) run or all shards completing — documented so "warm cache, still cold for my shard's-complement" is not a surprise.

## Hard constraints (every slice respects)

- **`SoundnessKey` = sole content address.** No backend, tier, trust policy, or serializer participates in key derivation. The 9-component `KeyInputs` is untouched.
- **Only `isFullyAchieved && attempt-1 pass` may PUBLISH.** `shouldStore` is unchanged and runs *before* `put`; the trust layer only *signs* what the gate already approved.
- **Run NEVER blocks on remote.** Timeout/offline/miss are indistinguishable to the *control* path (the `CacheBackend` total-function contract); the `err` field feeds observability only, never control flow.
- **No network or hot-path disk in the test suite.** Boundary tests use the `memory` adapter; http/s3 test against the injected in-memory `HttpFetcher`/fake server. `--verify-cache` runs off the hot path.
- **Entrypoint-granularity / binary-opaque identity preserved** (MEMORY.md → [[boundary-granularity-discriminator]]). No per-test/sub-binary anything; trust/attestation never reaches into test internals (it signs the opaque `(key, payload-hash)`, nothing test-semantic).
- **`lookupAtPlan` / `shouldStore` / `CacheContext` / `inactiveDecision` unchanged.** Additive only: `CacheDecision += cdmTrustFail`; `EntrypointResult += cacheTier`.
- **Secrets never in config files; signing keys never in the env allowlist.**

## Non-Goals (explicit for 0005)

- **Distributed *execution*** (remote workers running tests). `--shard` remains the only run-distribution primitive; crisol distributes the *cache*, not the *work*.
- **Full Sigstore/Rekor.** ed25519 ships; `SigstorePolicy` type-locked behind `when defined(crisolSigstore)` — no stub.
- **msgpack (or any non-JSON) serializer.** The port exists; only JSON ships.
- **A `crisol cache` introspection/purge CLI.** `backend.delete` exists; the CLI surface (push/pull/stat/delete a key) is a follow-on. Poison cleanup is backend-side or via rotation (documented).
- **`TestRecord.msg` redaction before remote publish** (Breadth F6, documented consumer contract): crisol is binary-opaque and does **not** filter captured test output before shipping `CachedResult.records` to a shared tier. Teams whose test output may contain secrets/PII must set `cacheable #false`, omit a remote tier for those groups, or not emit sensitive data. (A future `obfuscate-records` tier option — ship key+outcome+duration, drop messages — is noted as a candidate, deferred.)
- **History dashboards / OTel span export.** Telemetry is a `TelemetrySink` + summary line + `run/v1` field; rich sinks follow on.
- **Remote-tier eviction/TTL.** A backend concern (S3 lifecycle, server TTL); `--verify-cache` never evicts; local GC stays RFC-0004 A1c.
- **Negative-cache / bloom filter for misses** (deferred; see §Alternatives).
- **Any per-test / sub-binary feature** (standing crisol Non-Goal).

## Alternatives considered (Breadth F14)

- **Negative-cache / bloom filter for known-misses.** Would eliminate the per-miss remote round-trip on a cold suite. Deferred: the plan-time `list()` prefetch already collapses N lookups to one call where the backend supports it, and the sync-with-deadline contract bounds the worst case; a bloom filter adds staleness/complexity for a marginal gain over prefetch. Reopen if large-suite cold-start latency proves dominant.
- **Conditional GET (ETag / `If-None-Match`).** Collapses HEAD-then-GET into one round-trip per miss. Folded into the `http` adapter as an internal optimization (the content-addressed URL makes the key its own ETag), not a separate design axis.
- **Content-addressed dedup / payload compression over the wire.** The `SoundnessKey` already deduplicates by content; gzip on the JSON payload is an adapter-internal `Content-Encoding` concern, deferred.
- **Single shared integrity-or-trust mechanism.** Considered collapsing `payloadChecksum` into the signature (drop FNV when signed). Rejected: FNV guards *untrusted* tiers (local L1, `verify-trust:false`) where no signature exists; the two layers guard different transports and are reconciled by the recompute-bound canonical hash (§Integrity vs. trust).

## Stages & slices

**Stage A leaves the suite green at every slice** (port refactor; behavior-identical local path); **B is additive observability** (may interleave once A3 lands); **C is the network-touching tail, gated on the crypto decision.** Prereq: **issue #1** (`SlotState` enum dispatch hardening) lands first, independently.

**Fixture/double inventory (build before consuming slices):** the `memory` `CacheBackend` (`Table[SoundnessKey, StoredEntry]`); a **controllable mock `TrustPolicy`** (verify-returns-configurable — for A3's security-rule tests before real crypto exists); the in-memory **`HttpFetcher`/fake server** (validates method/status/Content-Type/auth — for C1/C6); a **nondeterministic fixture** (passes attempt 1, diverges on re-run — feeds `--verify-cache`); an **ed25519 keypair fixture** (signer secret + its public + a *second, unpinned* public for the reject test) — *built in C5 once the crypto dep is chosen*.

**Stage A — port skeleton (green throughout):**
- [ ] **A1** `cacheport.nim`: all port types (`CacheBackend`/`BackendGet`/`BackendPut`/`CacheError`/`StoredEntry`/`Attestation`/`BackendConfig`/`TierConfig`/`TieredCache`/`TierHit`/`TrustPolicy`/`CacheSerializer`/`TelemetrySink`) + `memory` adapter + `nonePolicy` + `NilSink` + the canonical payload-hash recompute helper. `getWithProvenance`/`put` over a single `memory` tier. Boundary-tested: roundtrip, miss→`(none, ceMiss)`, checksum-recompute-mismatch→`(none, ceCorrupt)`, storageFormatVersion-mismatch→miss. Pure module.
- [ ] **A2a** `local-fs` adapter wrapping `loadCached`/`storeCached` (bypasses `CacheSerializer`; strips attestation for `verify-trust:false`). Satisfies the *same* roundtrip/miss/corrupt boundary suite as `memory`. No `realSeams`/`api` change yet — suite green.
- [ ] **A2b** *(atomic multi-file)* `realSeams` gains `(TieredCache, TelemetrySink)` params, composes `load`/`store` over `tc`; `api.nim` builds `localOnlyCache(stateDir)` + `NilSink`; **update the direct `realSeams` callers in `tests/unit/test_cachedispatch.nim` and `test_api.nim` in the same commit.** ALL existing RFC-0004 cache tests green. (Characterize call sites first — confirmed: those two test files.)
- [ ] **A3** multi-tier `getWithProvenance`: waterfall + `backfill-on-hit` + **`verified`-bit backfill rule**, via two `memory` tiers and the **controllable mock `TrustPolicy`** (so the security case — unverified entry refused at a `verify-trust:true` destination — is actually exercised). `BackendRegistry` + scheme-resolved `buildBackend`. Exhaustive 2×2×2 backfill matrix. Add `cdmTrustFail` to `CacheDecision`; populate `cacheTier`.
- [ ] **A4** point `gcResultCache`/orphan-clean at `backend.list`/`backend.delete` (nil-capability tiers skipped; sidecar files included once B1 lands). Boundary-tested against `memory` + the nil-capability case.

**Stage B — observability (additive; may interleave with A3+):**
- [ ] **B1** path-keyed `KeyInputs` sidecar (local tier, `flagHash→KeyInputs` map) + `keyInputs{To,From}Json` (manual, no jsonutils) + `explainMiss(prev,curr)` (PURE) + `--explain-miss` render + graceful degrade. `explainMiss` exhaustively vector-tested (each of 9 components; flag-change case; multi-component; no-diff); sidecar roundtrip + flag-change-surfaced tested via the local-fs boundary suite.
- [ ] **B2** telemetry: adapter-emitted events aggregated into the summary line (L1/remote/miss/**remote-errors**/%/wall-saved/published) + `cacheStats` in `run/v1` + `--cache-stats` + stderr warning on 100%-remote-error. Tested via `InMemorySink`.
- [ ] **B3** `--verify-cache[=PCT]` + `--verify-cache-strict`: deterministic-seeded sample of `cdmHit` entrypoints, **synthetic `RunPlan` from first-run `PlannedEntrypoint`s**, `cache=cacheDisabled`, `--retries 0`, isolated sink, **post-run**, `verifyFail`→stderr+summary+(strict⇒exit 1), never-evict. Integration-tested with the nondeterministic fixture (divergence⇒signal; deterministic⇒none). (C0 must land first — re-entrancy.)

**Stage C — remote + trust (network-touching tail; gated on §Open forks):**
- [ ] **C0** *(design slice)* pin remote-I/O concurrency: sync-with-deadline default vs. opt-in bounded prefetch pool; verify `execute()` re-entrancy for B3's synthetic-plan pass. Written rationale in RFC + `cacheport` doc comment. No functional code.
- [ ] **C-dep** *(dependency-decision slice — RESOLVE §Open forks FIRST)* add the chosen crypto lib(s) to `milpa.kdl` (+ Dockerfile if FFI/system lib); compile-only smoke test importing the primitives against a known test vector (HMAC-SHA256 + ed25519 sign/verify). Gate for C4/C5.
- [ ] **C1a** Dockerfile `libssl-dev` + `-d:ssl` build flag; verify the image builds and `std/httpclient` links. No adapter logic.
- [ ] **C1** `http` adapter via injected `HttpFetcher` (GET/PUT/HEAD, `<base>/<storageFormatVersion>/<key>`, `Content-Type: application/json`, deadline, total-function `CacheError`) + JSON `CacheSerializer`. Tested against the in-memory fake server (no socket).
- [ ] **C2** `s3` adapter (same contract). **Scope per §Open forks:** unsigned/MinIO path-style first (no SigV4), OR SigV4 (needs C-dep HMAC, reorder after C4). Tested against the fake (S3 codec).
- [ ] **C3** `configuredCache` wiring in `api.nim` + KDL `cache { remote { … } }` parse + CLI/env override. Integration-tested: configured tier participates; `--no-remote-cache` reverts to local-only; offline remote ⇒ miss (`ceOffline` in stats), run proceeds.
- [ ] **C4** `TrustPolicy`: `nonePolicy` + `tokenPolicy` (HMAC-SHA256 via C-dep), canonical signed-envelope `(key,recomputed-checksum,formatVersion,signer)` (shared sign/verify), verify-on-read miss-on-fail, sign-on-put. Boundary-tested: HMAC roundtrip; tamper⇒`ceCorrupt`@step1 / `ceTrustFail`@step2; `verify-trust` tier rejects unsigned.
- [ ] **C5a** ed25519 `signedPolicy` sign/verify happy path + no-key no-op; `SigstorePolicy` type-locked behind `when defined(crisolSigstore)`. (Keypair fixture built here.)
- [ ] **C5b** ed25519 rejection cases: tamper-reject, unpinned-signer-reject, signer-mismatch-reject (shared fixture).
- [ ] **C5c** ed25519 × `verified`-bit backfill interaction (a real-policy unverified entry must not backfill a `verify-trust:true` tier) — the A3 mock replaced by the real policy.
- [ ] **C6** secure-by-default credential scopes: read vs write; publish iff write-credentialed (`ceUnauthorized` `put`⇒no-op, reads still serve); keys from env only. Tested against the auth-validating fake server.

(Sequence A→B→C; B interleaves; C is the only network/crypto stage. Remote GC/TTL out of scope; local GC stays RFC-0004 A1c.)

## Testing strategy

Boundary tests at the `CacheBackend` port via `memory`: waterfall, backfill-on-hit, **`verified`-bit backfill** (exhaustive 2×2×2, via the controllable mock policy — the high-risk case), trust verify+reject, miss→next-tier, offline→miss-with-`ceOffline`, the publish gate (unchanged — re-assert `shouldStore` still gates `put`). `explainMiss` pure ⇒ exhaustive `KeyInputs`-diff vectors incl. the flag-change case. ed25519 sign/verify roundtrip + tamper + unpinned + signer-mismatch + backfill interaction. `--verify-cache` divergence via the nondeterministic fixture; determinism ⇒ no event. http/s3 against the injected in-memory `HttpFetcher`/fake server — **no real network, no hot-path disk**. RFC-0004's direct `loadCached`/`storeCached` tests fold into the `local-fs` adapter's boundary suite. Per [[dev-test-verification-gotchas]]: `./dev test` EXIT is unreliable — grep output (and have B3/C1/C2 tests emit an explicit success marker), excluding the expected-failure fixtures.

## Contract impacts

- **Schemas:** `crisol/run/v1` gains additive `cacheStats` (`{l1Hits, remoteHits, misses, remoteErrors, total, hitPct, wallSavedMs, published, verifyFails}`) and per-result `cacheTier` provenance; `CacheDecision` gains `cdmTrustFail` (additive variant). Behind the existing `schemaRevision` bump (RFC-0004). No `v2`.
- **CLI additions:** `--no-remote-cache`, `--explain-miss`, `--verify-cache[=PCT]`, `--verify-cache-strict`, `--cache-stats`. All additive; default (no flags, no `cache { remote }`) is identical to RFC-0004.
- **Config additions:** `cache { remote "<name>" { url / trust { policy / pinned-key } / verify-trust / backfill-on-hit } telemetry { hit-rate / explain-miss / verify-cache-pct } }`. Additive; absent ⇒ single-tier local.
- **Env:** `$CRISOL_CACHE_SIGN_KEY` (publish; never in the env allowlist), read creds per-backend (adapter-native, e.g. standard AWS env for `s3`). Secrets never in config files.
- **New wire-format axis:** `storageFormatVersion` (the `StoredEntry` wire shape) — distinct from RFC-0004's `resultCacheFormatVersion` (the `CachedResult` payload).
- **`realSeams` signature** gains `(TieredCache, TelemetrySink)` params (internal plumbing; crisol has no consumers; the two direct test callers update atomically in A2b). `CacheSeams`, `LoadProc`, `StoreProc`, `lookupAtPlan`, `shouldStore`, `CacheContext`, `inactiveDecision` unchanged.
- **Library facade** (`crisol/api`): `RunOptions` gains `remoteCache`/`explainMiss`/`verifyCachePct`/`verifyCacheStrict`/`cacheStats`; `RunReport` gains `cacheStats`; `EntrypointResult` gains `cacheTier`. Additive.

## Open forks (awaiting Corey)

**FORK-1 — Crypto-dependency strategy (blocks Stage C only; A and B proceed now).** "ed25519 signed attestation NOW" was selected without the dependency reality surfacing: **Nim's stdlib has no SHA-256, no HMAC, and no ed25519**, and crisol currently depends only on `nkdl`. This is a genuine dependency/risk-appetite call (FFI vs pure-Nim, Dockerfile delta, the milpa+podman/no-host-nim toolchain) that is yours, not a soundness question I should pre-decide. My recommendation, with trade-offs, is in the chat message accompanying this round. The decision sets: (a) HMAC-SHA256 + SHA-256 source, (b) ed25519 source, (c) whether initial S3 is unsigned/MinIO (no SigV4) or authenticated (SigV4 ⇒ reorder C4 before C2). A and B are fully unblocked regardless.
