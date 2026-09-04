# RFC-0005 — Distributed result cache, cryptographic trust & cache observability

**Status:** Ready (stage 2 — architect rounds 1, 2 & **3** applied 2026-08-21; FORK-1 (crypto deps) resolved — see §Dependency decision; **FORK-2 (cold-host consult) RESOLVED (a) 2026-09-03 — the post-compile consult ships as stage A2c; see §FORK-2**). **A7-gate re-baseline APPLIED 2026-09-03:** RFC-0007 Stage A (A0–A7) landed in full on main, and this doc is re-baselined on the landed shape — `StoredEntry` freezes on the real `ProcessResult` observation (§The port), the publish gate is recomputed-`outcome` + `evidenceSatisfies` + attempt-1 (§Hard constraints), `--verify-cache` compares observations, never verdicts (§Stage B), and the wire is `crisol/run/v2` (revs 19/20/21 — §Contract impacts). The build is unblocked — FORK-2 resolved (a): the consult lives wherever the key becomes fully known, and key-completion is staged (closure hash is a compile byproduct), so the post-compile consult is the general mechanism and lookupAtPlan its memoized fast path; A2c supplies the missing general case. Source line anchors dated round 3 pre-date the 0007 rewrite; anchors in re-baselined sections are refreshed at HEAD (2026-09-03), the rest are historical — re-grep at slice time.
**Depends on:** RFC-0004 (incremental hermetic execution — the `ExecutionCache`, `SoundnessKey`, `CacheSeams`/`cachedispatch` seam, `RunLedger`, and the publish gate this RFC extends); RFC-0007 Stage A (**landed 2026-09-03** — the `ProcessResult` observation model (`Exit` × `Cause` × `Evidence`), `outcome` as a pure function of (result, policy) recomputed at every trust boundary, the `evidenceSatisfies` named-guarantee cache gate that replaced `isFullyAchieved`, `process/resultjson` as the ONE `ProcessResult`⇄JSON owner, and the `crisol/run/v2` wire); RFC-0006 (persistent per-entrypoint nimcache at `<stateDir>/cache/<slug>-<toolchainFp>/` — a *sibling* of the result cache under the same root; see §Local-fs root)
**Scope owner:** Corey

## Summary

RFC-0004 made crisol an *incremental* engine: a test's outcome is content-addressed by a `SoundnessKey` and served from a local on-disk `ExecutionCache` when its inputs are provably unchanged. That cache is **single-host and single-tenant** — it never crosses the machine that produced it. The same `SoundnessKey` that makes the local cache sound makes it **portable**: equal key ⇒ equal result on any host with the same toolchain *binaries* and the same allowlisted environment values (RFC-0004 folds `nimVersion`/`ccVersion`/libc into the key, and — since commit `17c12e8` — `nimVersion` is the full `nim --version` text plus a content hash of the nim binary, so cross-host reuse is sound by construction, not by luck).

This RFC spends that portability. It does three things, in the architectural class of Bazel Remote Execution's *cache-only* tier, `sccache`, `cargo`'s emerging registry cache, and Nix's binary caches:

1. **Distributed result cache** — a **ports-and-adapters** `CacheBackend` boundary, a multi-tier `TieredCache` (L1 local → L2 shared → L3 …) with backfill-on-hit, and shippable `local-fs` / `http` / `s3` adapters behind a registry. The runner blocks on **none** of it: a remote miss, timeout, or offline backend is *exactly* a local miss — the run proceeds. **Honest scope (round 3):** what a remote tier removes is *execution*. The `SoundnessKey` needs the closure content hash, which crisol learns from the nimcache *after* `nim c`; so a host with no warm `<stateDir>/bin` + depgraph still pays the compile, and today it never consults the cache at all (FORK-2 resolved (a): 0005 adds the post-compile consult — stage A2c — that makes the cold-host case real). Hosts whose binary + depgraph are warm (persistent runners, CI with a restored `<stateDir>`) skip both.
2. **Cryptographic trust** — a `TrustPolicy` port (`none` / HMAC / **ed25519 signed attestation**), verify-on-read and sign-on-publish, so a shared cache served by infrastructure crisol does not control cannot inject a forged "this test passed" result. (REFERENCE.md category 3: *remote but owned* — the boundary is a port; the wire is attested.)
3. **Cache observability** — `explainMiss` (which of the 9 key components changed — *and which env var*, so a surprise miss is *legible*), hit-rate telemetry (a `TelemetrySink` port + summary line + `run/v2` field), and `--verify-cache` (a **post-run** re-execution sample that catches nondeterminism the hermeticity gate structurally cannot). **Observability lands first** (§Stages): it is port-independent and is the earliest *realized* value for a single-host loop.

Everything stays at **entrypoint-binary granularity** and **binary-opaque** identity (MEMORY.md → boundary-granularity-discriminator). This RFC adds *backends, trust, and visibility* to the existing cache; it does **not** add a new content-address key or a new soundness rule, and it does not add any sub-binary control. **`lookupAtPlan`'s decision logic / `shouldStore` / `CacheContext` / `inactiveDecision` keep their semantics**; the publish gate (recomputed `outcome == oPassed` && `evidenceSatisfies` && attempt-1 — rfc-0007 A6a's shape of `shouldStore`) still lives in `shouldStore`, *before* the trust layer ever sees a write. What does change at the seam (round 3, honestly): `CacheSeams`'s three closures are **re-shaped** so the seam derives *inputs* and returns *provenance* (`KeyDerivation` / `CacheLookup` — §Wiring), and `EntrypointResult` gains `cacheTier` + `cacheLookup` (0005 adds no new `CacheDecision` variant — round 3 found `cdmTrustFail` cannot survive the live-result stamp; 0007's `cdmRecomputeMiss` already landed and is simply carried). Distributed *execution* (remote workers) remains a Non-Goal; `--shard` is still the only distribution primitive for *running*.

## Motivation

- **The warm host's work is re-proved elsewhere.** RFC-0004's cache is keyed by content, so a result computed on host A is *valid* on host B — but B can't see A's `<stateDir>/cache/`. CI runners are the acute case: N matrix shards, each re-running the full unchanged suite. A shared L2 turns "first runner pays, rest reuse" into the default — for the *run* phase unconditionally, and for the compile phase wherever `<stateDir>/bin` + depgraph are warm (§Summary, §FORK-2).
- **A shared cache is an attack surface the local cache never was.** The moment a result crosses a trust boundary (a teammate's upload, an S3 bucket, a CI artifact store), "this entrypoint passed" becomes a claim crisol must *verify*, not assume. A forged pass is a silent test-suite bypass. RFC-0004's gate guarantees crisol only *publishes* sound results; it says nothing about whether a result crisol *reads back* was published by crisol under that gate. Trust closes that gap.
- **The cache is currently a black box when it misses.** A developer who expects a hit and gets a miss has no way to ask *why* — which of `{closureContentHash, flagHash, nimVersion, ccVersion, fixtureHash, argv, limits, hermeticEnvHash, protocolMajor}` moved (rfc-0007 A2a-iii re-homed the rlimit component as `limits: Limits`), and for the env component *which variable*. "Why did my whole suite re-run after a `glibc` bump?" should be a one-flag answer, not a `strace` session.
- **The soundness gate is necessary but not sufficient for determinism.** `evidenceSatisfies` proves the *environment* was hermetic (and escapee-free, with every requested limit applied-or-honestly-unsupported); it cannot prove the *binary* is deterministic given that environment (RFC-0004 §"Honesty about the limit"). A test that reads `/dev/urandom` and happens to pass on attempt 1 caches a coin-flip. `--verify-cache` is the empirical backstop: re-run a sample, compare, surface divergence.
- **The unifying observation:** the local cache, the remote cache, and the verifier all want the *same* `(key → entry)` contract. Define that contract as a port once; local-fs, http, s3, and the in-memory test double are all just tenants. The runner's hot path depends on the *port*, never on a backend.

## The spine (dependency order)

```
A  CacheBackend port + seam re-shape  ──►  B  observability  ──►  C  trust, then remote
   (StoredEntry wire + ONE serializer,       (--verify-cache,        (crypto dep → HMAC/ed25519
    local-fs root, KeyContext/KeyDerivation/   explainMiss + sidecar,  policies (E2E-2 over file://)
    CacheLookup seam, CacheRuntime)            hit-rate)               → http/s3 adapters → wiring)
```

**Build order is value-arrival order, not dependency order (round 3).** Dependencies, honestly: `--verify-cache` (B3) depends on *nothing* in A; `explainMiss` + the sidecar (B1) depend only on the seam re-shape (A2b) — not on tiers or the registry; hit-rate (B2) is a fold over `EntrypointResult.cacheDecision` today and gains per-tier fields when A3 lands. So the slice order is **B3 → A1 → A2a → A2b → B1 → B2 → A3a → A3b → A3c → C**, and observability is usable on a single host before any remote tier exists. (Carving observability into its own RFC was considered and rejected: it reuses this RFC's types and fixture inventory and a separate RFC buys a review cycle for no boundary gain.)

**The load-bearing refactor is A2b, and it is mostly plumbing.** `realSeams` today closes over `loadCached`/`storeCached` directly (`cachedispatch.nim:369`, closures at `:449-452`). Stage A re-expresses that *same* local behavior as a single-tier `TieredCache` over a `local-fs` `CacheBackend` adapter, and re-shapes the three seam closures once (§Wiring). The observable behavior is identical; the change touches `cachedispatch.nim`, `api.nim`, and **every `CacheSeams`/`LoadProc` literal in the suite** — still the same 4 files at HEAD 2026-09-03 (`test_cachedispatch.nim`, `test_cache_dispatch_boundary.nim`, `test_a9_cache_controls.nim`, `test_m8_cache_decision.nim`; 10 `CacheSeams(` literals — the 0007 sweep touched all of them, so re-grep exact sites at slice time: `grep -n "CacheSeams(" tests/unit/`) — updated atomically in A2b via a one-line test helper. Nothing downstream of the seam (`lookupAtPlan`'s decision logic, `shouldStore`, the `execute()` dispatch) changes shape.

**Soundness coupling (unchanged, restated):** the `SoundnessKey` remains the **sole content address**. A backend is a *transport* for `(key, CachedResult)`; it never participates in key derivation, never relaxes the gate. Only an entry that passed `shouldStore` (recomputed `outcome(res) == oPassed`, `evidenceSatisfies` over the run's own `Evidence`, attempt-1) is ever handed to a backend's `put`. Trust verification happens *on read*, after transport, before the entry is allowed to satisfy a lookup — a backend that returns a tampered or unsigned entry on a trust-requiring tier yields a **miss**, never a served result. Read-side symmetry (rfc-0007 A1d-ii, landed): even a transport- and trust-clean entry is served only if its **recomputed** outcome is `oPassed` — `lookupAtPlan` derives `outcome` over the replayed observation, and a not-passed recompute is `cdmRecomputeMiss`, rerun live. The tiered lookup inherits this rule unchanged: trust and integrity gate *transport*; the recompute gates *serving*.

## Key portability — what is and is not in the key (round 3, load-bearing)

Everything in `KeyInputs` is host-independent **except the allowlisted environment values**. Verified against HEAD: the argv component is the machine-independent surrogate `<slug>/<binName>` (`cachedispatch.nim:429-436`); closure paths are project-relative (`closure.nim:36-39`); `nimVersion` is `nim --version` text + nim-binary hash (`nimprobe.nim`); `ccVersion` is the cc/ldd fingerprint; no stateDir/projectRoot/cwd enters the key. **But** `hermeticEnvHash` hashes *name=value* of every allowlisted variable that reaches the child (`sandbox.nim:271-306`), and the default allowlist is `HOME LANG LOGNAME NIM_CONFIG_DIR NIMBLE_DIR PATH TERM TMPDIR TZ USER` + `LC_*` (`sandbox.nim:19-38`; TMPDIR is name-only). RFC-0004 chose names+values deliberately (an allowlisted var is one tests may depend on ⇒ its value is a real input; "cross-host reuse is achieved by pinning the env, not by omitting values" — `sandbox.nim:260-262`). Consequences, stated plainly:

- **Same-image CI runners match** (identical `HOME`/`PATH`/`USER`/…). **A laptop and a CI runner, or two differently-provisioned runners, never match** until their allowlisted values agree. Under `--hermetic none` the *entire* env is hashed, so even same-host hits are luck.
- RFC-0004's "configurable passthroughs" never shipped as a KDL/CLI knob (`resolveSandbox` is called with no passthroughs — `api.nim:606-607`), and nothing in 0005 as of round 2 produced env parity. **Slice A0 ships the producer:** `env-pin` (repeatable KDL `env-pin "NAME" "VALUE"` + `--env-pin NAME=VALUE` + `RunOptions.envPins`) — the pinned value is injected into the child env in `filterEnv`'s tail *and* hashed as the pinned value, so pinned variables are key-stable across hosts. **Defaults are unchanged in 0005** (pinning `HOME`/`PATH`/`USER` by default is a hermeticity tightening that could break consumers that exec host tools or read `$USER`; promote defaults in a follow-on once amoxtli data is in). The operator guide tells a team exactly which variables to pin for cross-host hits, and `--explain-miss` names the offending variable (§Stage B).
- `dep-roots` closure entries are stored as absolute paths (`closure.nim:73-83` fallback, `depgraph.nim:130` folds the path string) — projects using `dep-roots` at different absolute locations never share keys. Documented in the operator guide; fixing it (hash as `<depRootIdx>/<relative>`) is a follow-on.
- A0 adds the invariance test: `keyOf` is invariant under {stateDir, projectRoot, cwd, TMPDIR value, pinned vars} and varies only on unpinned allowlisted values.

## The port: `CacheBackend` and `StoredEntry` (read this before Stage A)

The boundary is a **closure-field object**, not a vtable or `method` dispatch — this matches the existing `CacheSeams` idiom exactly (`cachedispatch.nim:102`, three closure fields), stays zero-cost, and keeps adapters as plain data. Closure fields are declared via `XxxProc` aliases, as every seam in the repo does (`KeyOfProc`, `FileReaderProc`, `RunCcProc`, `BinHashProc`, `IcRunProc`).

**Module layout (round 3 — one concern per module, flat names like `resultcache`/`cachedispatch`/`shardedledger`).** The round-2 plan put ~22 types in one `cacheport.nim`; that would make every importer of the hot path and every engine test pull sello + nimcrypto. Split, with this import DAG (checked against the existing `depgraph → config`, `resultcache → depgraph`, `cachedispatch → planner` edges — no cycles):

| module | owns | imports |
|---|---|---|
| `cacheport.nim` | `CacheVerdict` + sets, `Fetched[T]`, `StoredEntry`/`SigAlg`/`Attestation`, `CacheBackend`, `TrustPolicy` type + `nonePolicy`, `TelemetrySink` type + `NilSink`, `canonicalPayload`/`envelopeBytes` | `types`, `keys`, `resultcache` |
| `cachetier.nim` | `Tier`, `TieredCache`, `TierHit`, `TierVerdict`, `CacheLookup`, `lookup`/`put`, backfill + put rules, circuit breaker | `cacheport` |
| `cachewire.nim` | the JSON `CacheSerializer` (the ONE on-disk/on-wire format), `HttpRequest`/`HttpReply`/`HttpFetcher` | `cacheport` |
| `cachememory.nim`, `cachelocalfs.nim`, `cachehttp.nim`, `caches3.nim` | one adapter each | `cacheport`, `cachewire` |
| `cachetrust.nim` | `hmacPolicy`, `ed25519Policy` — the ONLY module importing sello/nimcrypto | `cacheport` |
| `cachetelemetry.nim` | `TelemetryEvent` (variant), `InMemorySink`, summary sink, `CacheStats` aggregation | `cacheport`, `cachetier` |
| `cacheregistry.nim` | `BackendRegistry`, `productionRegistry`/`testRegistry`, `CacheRuntime`, `CacheSecrets`, `localOnlyCache`/`configuredCache` | all of the above; imported by `api` only |
| `keys.nim` (existing) | `KeyComponent`, `KeyDiff`, `explainMiss` — a pure diff over `KeyInputs`, which `keys.nim` owns | — |
| `types.nim` (existing) | `CacheConfig`/`RemoteTier`/`TrustConfig` (parsed KDL; `config.nim` must not import the cache modules — `depgraph → config` would cycle) | — |

`cachedispatch` imports `cacheport` + `cachetier`; `runner` is untouched by the port.

```nim
type
  CacheVerdict* = enum     ## get / put / verify share ONE vocabulary; ordered weakest→strongest for aggregation
    cvOk, cvMiss, cvOffline, cvTimeout, cvVersionSkew, cvCorrupt, cvUnauthorized,
    cvTrustNoAttestation, cvTrustUnknownAlg, cvTrustUnpinnedSigner, cvTrustSignerMismatch, cvTrustBadSignature

  Fetched*[T] = object     ## a value exists iff cvOk — "hit with an error" is unrepresentable
    case verdict*: CacheVerdict
    of cvOk: value*: T
    else:    discard

  StoredEntry* = object
    key*:            SoundnessKey      ## the content address (sole soundness key — unchanged)
    keyInputs*:      Option[KeyInputs] ## 0005 writers ALWAYS set it (seeds the explain sidecar on backfill); decoders tolerate absence (pre-0005 file)
    result*:         CachedResult      ## the landed rfc-0007 payload, verbatim: {run: ProcessResult, records, cachedAt,
                                       ## payloadChecksum} — the run-phase OBSERVATION (Exit + Cause + Evidence +
                                       ## Option[Rusage] + durationUs) plus protocol records; NO outcome/exitCode/signal
                                       ## is stored (§Stored observation). Its own payloadChecksum field is THE checksum
                                       ## — no duplicate here
    storageVersion*: int               ## StoredEntry wire schema (storageFormatVersion); mismatch ⇒ cvVersionSkew
    attestation*:    Option[Attestation]

  SigAlg* = enum           ## string on the wire, enum in memory (mirrors resultcache's parseOutcome/parseStatus)
    saNone = "none", saHmacSha256 = "hmac-sha256", saEd25519 = "ed25519"

  Attestation* = object
    sigAlg*:    SigAlg
    signer*:    string   ## SIGNED. ed25519: base64(pubkey bytes) — the SAME string as the `pinned-key` config entry;
                         ## HMAC: the operator-chosen `key-id` string. Never a hash/truncation (no collision surface).
    signature*: string   ## raw bytes, base64 on the wire
    signedAt*:  int64    ## unix seconds; informational ONLY — never used in verify, never in the signed bytes

  BackendGetProc*   = proc(key: SoundnessKey): Fetched[StoredEntry] {.closure.}              ## NEVER raises
  BackendPutProc*   = proc(entry: StoredEntry): CacheVerdict {.closure.}                      ## best-effort; NEVER raises; cvOk on success
  BackendProbeProc* = proc(keys: openArray[SoundnessKey]): Fetched[HashSet[SoundnessKey]] {.closure.}
                                                                                              ## optional bulk-existence (nil ⇒ per-key get)
  CacheBackend* = object
    scheme*: string            ## adapter kind: "file" | "http" | "s3" | "memory" (registry id); NOT the deployer's tier label
    get*:    BackendGetProc
    put*:    BackendPutProc
    probe*:  BackendProbeProc  ## nil-able capability — checked in exactly ONE place (C3c prefetch)

const transportVerdicts* = {cvOffline, cvTimeout, cvUnauthorized}
const integrityVerdicts* = {cvVersionSkew, cvCorrupt}
const trustVerdicts*     = {cvTrustNoAttestation .. cvTrustBadSignature}
proc canProbe*(b: CacheBackend): bool {.inline.} = b.probe != nil
```

### Stored observation, derived verdict (A7-gate re-baseline, 2026-09-03)

`StoredEntry.result` is the landed RFC-0007 `CachedResult`: **the run-phase `ProcessResult` — `Exit` (lossless end: exited/signaled/ntstatus), `Cause` (authorship, asserted only from the runner's own recorded acts), `Evidence` (`killDomain`/`tree`/`escapees`/`limits: LimitsAchieved`/`hermetic`/`killSnapshot`/`cooperativeUnavailable`), `Option[Rusage]`, `durationUs` — plus the protocol `records`, `cachedAt`, and `payloadChecksum`.** The payload's `run` node is `process/resultjson.toJson`'s wire, verbatim — the ONE `ProcessResult`⇄JSON owner; `cachewire`'s serializer wraps it and never re-derives its shape. Rules that bind every 0005 layer:

- **Outcome is ADVISORY, never payload.** `outcome(r, policy)` is a pure function of (observation, policy), recomputed at every trust boundary — cache load (`lookupAtPlan`), render, exit-code derivation. It is never stored in a `StoredEntry`, never signed as a verdict, and never read back from storage as truth. A remote hit that clears transport, integrity, and trust is *still* only served if its recomputed outcome is `oPassed` (`cdmRecomputeMiss` otherwise — rerun live). Nothing in 0005 may compare, hash, or gate on an outcome/exitCode/signal-shaped projection of the payload; what is signed and compared is the observation.
- **The trust layer filters on NAMED guarantees from `Evidence`, never enum ordinals** (the §6 rule of 0007, inherited): "were escapees observed?" (`escapees.len > 0` ⇒ the entry was never stored — `evidenceSatisfies` already refused it at the producer; a decoder finding one in a remote entry treats the entry as ineligible, same class as a failed gate), "was the tree observable at this tier?" (`tree == toUnobservable` ⇒ cacheable **with the honest label** — the label travels in the entry and a consumer's policy may filter on it later), "were requested limits achieved?" (per-limit: `lsFailed` ⇒ uncacheable, never published; `lsUnsupported` ⇒ cacheable with the label; `lsNotRequested` vacuous). `hlNetwork` runs are uncacheable until RFC-0008 observes (network stays asserted-not-enforced — no network enforcement anywhere, locked). No comparison of `killDomain`/`tree` by `ord` anywhere in the cache or trust modules.

**The total-function contract is the whole point.** `get`/`put` **never raise** and never block the run unboundedly: a miss, a corrupt payload, a version mismatch, a failed trust check, a network timeout, an offline backend, and an unauthorized write are **all** surfaced as a non-`cvOk` verdict to the *control* path — the runner's hot path cannot tell a remote outage from a cache miss, by design ("run never blocks on remote" falls out of the type). **But the verdict carries *why*** so the observability layer can distinguish a clean miss from an adapter failure (a typo'd S3 URL must not masquerade as a cold cache). Remote adapters wrap their own per-call deadline internally (**default 2000 ms**, hardcoded in 0005 — see B0); the L1 local tier is synchronous with no timeout. **`CacheVerdict` is ordered by diagnostic strength** (declaration order, `cvMiss` weakest) — an aggregate over several tiers reports the *strongest* code, and — round 3 — the per-tier verdicts are kept alongside the aggregate (`CacheLookup.verdicts`) so a tier that rejects 100 % of reads is attributable even when a later tier serves the hit.

**Round-3 removals:** `list`/`delete` are gone from the port — `list(): seq[SoundnessKey]` cannot carry `cachedAt`, so it could not drive `gcResultCache` (LRU-by-`cachedAt`, `resultcache.nim:406-468`); remote eviction is a Non-Goal; the only bulk consumer is the C3c prefetch, which is exactly `probe`. `BackendConfig.settings: Table[string,string]` + `settingGet/settingInt` are gone — the codebase's config layer is typed at parse time with `cfgErr` + unknown-key warnings (`config.nim:149-201`); factories take the typed `RemoteTier` (§Registry). `CacheBackend.name` split into `scheme` (adapter) vs `Tier.name` (deployer label). `StoredEntry.payloadChecksum` dropped (duplicated `CachedResult.payloadChecksum`, `resultcache.nim:98`); `formatVersion` renamed `storageVersion` (collided by name with the payload header's `formatVersion`).

### One format, everywhere (round 3 — replaces "local-fs bypasses the serializer / strips attestation")

Round 2 had the `local-fs` adapter call `storeCached`/`loadCached` directly and *strip* the attestation for `verify-trust:false` tiers, "so Stage A is format-identical to RFC-0004." Round 3 found that makes E2E-2 impossible: a `file://` L2 with `verify-trust #true` would have nowhere to put an attestation. The rule now:

- **There is exactly one on-disk/on-wire encoding of `StoredEntry`, produced by the JSON `CacheSerializer` in `cachewire.nim`, and every adapter — `local-fs` included — uses it.** The encoding is the landed L1 file (the RFC-0004 layout whose payload is now the real `ProcessResult` observation — rfc-0007 A1d-ii) **plus optional top-level keys** `"keyInputs"`, `"attestation"`, and `"storage": {"version": N}`; `header`/`payloadChecksum`/`payload` are byte-identical to today. `loadCached` reads only those three keys (`resultcache.nim:278-289`), so **a pre-0005 crisol reads a 0005 L1 file unchanged**, `resultCacheFormatVersion` stays **3** (the landed rfc-0007 value: v2 = real-`ProcessResult` payload, v3 = the `Limits` re-home key change), and Stage A is behavior-identical — *format-compatible*, not format-identical.
- `storeCached`/`loadCached` **become** the serializer's file I/O (refactored to take a *root*, §Local-fs root; `payloadToJson`/`payloadFromJson` exported). There is no double encode: the serializer *is* the code path. `canonicalPayload(res) = $payloadToJson(res)` is exported and `loadCached` calls the shared helper, so "one proc, shared by writer, reader, integrity, trust" is literally true.
- The `memory` double is `Table[SoundnessKey, StoredEntry]` (objects) **and** a `memoryBytes` double (`Table[SoundnessKey, string]` through the serializer) runs the same boundary suite — so the wire shape is exercised in Stage A, before `StoredEntry` freezes, not first in C1.

### Local-fs root (round 3, fresh fact from RFC-0006)

`resultcache.nim` path helpers take a *stateDir* and append `cache/v<resultCacheFormatVersion>/<key>.json` (`:160-164`); RFC-0006 (commit `c17a1ca`) put the persistent nimcaches at `<stateDir>/cache/<slug>-<toolchainFp>/` — **siblings** under the same `<stateDir>/cache/` root, which `clean.nim`'s `pruneDir` already disambiguates via `isResultCacheRootName` (`clean.nim:63-92`). So "L1 = `<stateDir>/cache`" was ambiguous and a `file://<dir>` tier wrapping `loadCached(dir)` would write `<dir>/cache/v<N>/` (an operator-visible extra level). Rules:

- `resultcache.nim` helpers take a **result-cache root**: `loadCachedAt(root, key)` / `storeCachedAt(root, key, res, maxEntries)` / `gcResultCacheAt(root, …)` store at `<root>/v<N>/<key>.json`; `loadCached(stateDir, …) = loadCachedAt(stateDir / "cache", …)` keeps every existing caller (`clean.nim:219`, `test_resultcache*.nim`, `test_a1c_gc.nim`, `test_c0_clean_stores.nim`) behavior-identical.
- **L1 is never a URL**: `localOnlyCache(stateDir)` builds `localFsBackend(root = stateDir / "cache", autoCreate = true, maxEntries = <landed max-cache-entries>)`, tier name pinned **`"l1"`** (a configured remote named `l1` is a config error). A configured `file://<dir>` tier has `root = <dir>` ⇒ entries at `<dir>/v<N>/`, `autoCreate = false`, `maxEntries = 0` (the interim 10 000 soft cap is an O(n) `walkDir` per store, `resultcache.nim:281-294` — wrong for a shared NFS tier); a `file://` root inside `<stateDir>` is rejected (it would be pruned by `clean`).
- **Offline semantics for `file://`:** a missing or non-directory root on a non-`autoCreate` tier ⇒ `cvOffline` on get/put (the offline fixture in the suite is a regular *file* at the URL path — `ENOTDIR`; `chmod` is unusable because `./dev` runs as root in-container). `storeCached`'s per-failure stderr warning (`resultcache.nim:361`) is rate-limited to once per run per tier so a full disk during N backfills does not emit N lines.
- Sidecars (§Stage B) live in **`<root>/v<N>/inputs/`** — outside `countCacheEntries`'s `*.json` glob and `gcResultCache`'s LRU walk (both non-recursive), so they are neither counted against the cap nor evicted first. The nimcache slug dirs are **not the cache port's business**.
- NFS note: `atomicPutFile`'s `<pid>.tmp` (`ioutils.nim:109`) can collide across *hosts*; O_EXCL fails closed ⇒ `put` returns `cvUnauthorized`-class false, acceptable. A `file://` L2 on a hung NFS mount has no deadline (local-fs is synchronous by spec) — documented in the operator guide.

### Integrity vs. trust — two layers, two hashes, one canonical payload (round-1 + round-2 fix, round-3 tightened)

`CachedResult.payloadChecksum` and `Attestation.signature` are **not** redundant — they guard different transport layers — and they are *not* the same hash: FNV-1a-64 is a 64-bit non-cryptographic hash, trivially second-preimage-able by an attacker with free-form bytes to play with (`records[].msg` is arbitrary text). The rule, spec-level and non-negotiable:

1. **The canonical payload is `payloadToJson(result)` (`resultcache.nim:170`; its `run` node is `resultjson.toJson`, verbatim) — one proc, shared by writer, reader, integrity, and trust.** The serializer's `decode` deserializes `result` via `payloadFromJson`, re-serializes via `payloadToJson`, recomputes `FNV(canonical)` and asserts it equals the stored `payloadChecksum` — **before** the entry is eligible to be served or trust-verified. Mismatch ⇒ `cvCorrupt`. It also checks the embedded `resultCacheFormatVersion` (`loadCached`'s header check, `resultcache.nim:282`) ⇒ mismatch is `cvVersionSkew`; the outer `storageVersion` covers the envelope shape only. A structurally-unparseable stored observation — a `run` node whose enum strings do not inhabit the Nim enums (`resultjson.fromJson` fails) — is `cvCorrupt` too, never a default-valued lie (rfc-0007 §2's own-reader posture, already enforced by `loadCached` today).
2. **The signed envelope binds a *cryptographic* hash of the recomputed canonical payload, the key, the storage version, the signer — and a domain-separation tag (round 3).** The bytes ed25519/HMAC sign are exactly
   ```
   envelope(key, result, storageVersion, signer) =
     "crisol-cache-attest-v1" & "\0" & key.string & "\0" & hex(SHA256(canonical(result))) & "\0" & $storageVersion & "\0" & signer
   ```
   — NUL-delimited between *every* field (reusing `keys.nim`'s convention and its rule: variable-width fields are ambiguous unless delimited). The constant prefix means a CI ed25519 key reused elsewhere cannot produce a cross-protocol signature that verifies here. The SHA-256 is **recomputed** by both signer and verifier from the canonical payload (never stored, never trusted from the wire), so Stage A stays crypto-free: SHA-256 enters only with the trust policies (C4, via nimcrypto); `envelopeBytes(tag, key, payloadHashHex, storageVersion, signer)` is a pure NUL-joiner that takes the hash as input. Including `signer` binds the claimed identity to the verifying key, defeating key-confusion. `signedAt` is **never** signed and **never** consulted by `verify` (clock skew across CI runners can never cause a spurious trust failure).
3. **Version coupling (round 3):** the URL/key carries only `storageVersion` and `SoundnessKey` excludes schema by design, so a `resultCacheFormatVersion` bump *without* a `storageVersion` bump would make a mixed fleet thrash one key with mutually-`cvVersionSkew` payloads. Rule: **any `resultCacheFormatVersion` bump MUST bump `storageFormatVersion`**, enforced by a `static: doAssert` in `cachewire.nim` tying the two constants.

A forger who swaps the payload but leaves `payloadChecksum` stale is caught at step 1; one who fixes the checksum too is caught at step 2 (no valid signature over the new hash). **E2E-2 therefore flips a payload byte *and recomputes `payloadChecksum`*** (the test owns the FNV helper) so it exercises step 2; the bare byte-flip is the negative control (`cvCorrupt`, integrity not trust).

**Honest correction to the idempotency argument (round 2).** The canonical payload includes `run.durationUs`, `run.rusage`, per-record `durationUs`, and `cachedAt` — wall-clock/accounting values that differ across hosts and runs — so "equal key ⇒ equal payload bytes" is **false**; two publishers of the same key mint two *different, equally valid* signed entries. The idempotency claim needs only the weaker, true statement: **equal key ⇒ semantically-equivalent result, and any entry that passes integrity + trust is a sound result for that key — so last-writer-wins among validly-attested entries is sound.** The timing fields are deliberately *kept inside* the signed payload (a signed subset would leave `run.durationUs`, which feeds `wall-time-saved` and shard balancing, tamperable for no gain).

### `TieredCache` — the composition, with provenance

`lookup` must NOT discard which tier hit, whether trust passed, or what each tier said — telemetry, `run/v2` provenance, the 100 %-error diagnostic, and the backfill rule all need it.

```nim
type
  Tier* = object                 ## (was TierConfig — `*Config` means parsed-KDL in this codebase)
    name*:          string       ## deployer label: "l1" (pinned) | the KDL remote-cache name
    backend*:       CacheBackend
    backfillOnHit*: bool         ## write to THIS tier when a DOWNSTREAM tier serves the hit
    verifyTrust*:   bool         ## reject entries READ from this tier that fail TrustPolicy; also: PUT here only attested entries

  TieredCache* = object          ## a PURE lookup engine — no TelemetrySink field (that lives on CacheRuntime)
    tiers*:  seq[Tier]           ## L1 → L2 → L3, searched in order
    trust*:  TrustPolicy         ## ONE policy per cache — shared by every verifyTrust tier

  TierHit* = object
    result*:   CachedResult
    tier*:     string            ## which tier served it (run/v2 provenance + telemetry)
    verified*: bool              ## true iff the entry PASSED trust verification (NOT merely "the tier didn't require it")

  TierVerdict* = tuple[tier: string; verdict: CacheVerdict]
  CacheLookup* = object
    hit*:      Option[TierHit]
    verdicts*: seq[TierVerdict]  ## one per tier CONSULTED, in search order (cvOk for the serving tier)
  proc worst*(l: CacheLookup): CacheVerdict   ## strongest over verdicts; cvMiss when empty

proc lookup*(tc: var TieredCache; key: SoundnessKey): CacheLookup
proc put*(tc: var TieredCache; entry: StoredEntry): seq[TierVerdict]   ## one per tier (feeds published / remote-error telemetry)
```

- **`lookup` (waterfall):** search tiers in order. On a tier `get`, run `tc.trust.verify(entry)`; if the tier has `verifyTrust` and the verdict is in `trustVerdicts`, **treat as a miss on that tier and continue** (never serve a failed entry, never abort; that tier's verdict is the specific trust code). Track the served entry's `verified` bit = *did it actually pass `verify`* (run for the bit even on non-`verifyTrust` tiers, where the verdict is advisory — one local computation over bytes already in hand, no I/O). On the first servable hit, **backfill** earlier `backfillOnHit` tiers subject to the rule below. **`verified` is a meaningful trust signal only when `tc.trust.name != "none"`** — under `nonePolicy` it is trivially `true`; `run/v2`/`--cache-stats` omit it under `nonePolicy`. It travels to `EntrypointResult` as part of `cacheLookup` (§Wiring), not as a separate field.
- **`put` (fan-out):** the entry has *already* cleared `shouldStore`'s gate. Sign **once** via `tc.trust.sign` (if the policy holds a secret). Then the **put rule (round 3, mirrors backfill):** **write to tier `t` only if `entry.attestation.isSome OR not t.verifyTrust`** — a pinned-keys-only consumer (no signing secret) must never overwrite CI's valid signed object with an unverifiable one (last-writer-wins would otherwise let any read-only consumer DoS the shared cache into 100 % misses); a skipped tier returns `cvUnauthorized` ("no write credential") so `cacheStats.published` stays honest. Every tier receives the full `StoredEntry` in the one format. Returns per-tier verdicts so telemetry can count remote write failures.
- **One `TrustPolicy` per `TieredCache`, by design (round 2).** A backfilled entry is re-stored *with the attestation it arrived with*; that attestation is valid at the destination only if the destination applies the *same* policy. Per-tier policies would make backfill into a `verifyTrust` tier impossible (can't re-sign without the secret) or rejected-on-read. So trust is **cache-global**: the KDL `cache-trust {}` block is top-level (§Configuration), every configured remote shares it. Per-tier policies are a follow-on.
- **Per-tier circuit breaker (round 3, B0).** On a tier's first `cvOffline`/`cvTimeout` in a run, the tier is marked dead for the rest of the run: subsequent `get`/`put`/`probe` return `cvOffline` immediately, one stderr line is emitted, and the tier counts in `cacheStats.remoteErrors`. Total dead wall-clock per run per tier ≤ one deadline — "never blocks" holds by construction (deadline + breaker), not by a deferred mechanism. ~10 lines in `cachetier`, memory-testable with a fake clock.
- **Deferred remote puts (round 3, B0).** Remote `put`s do **not** run inside the poll loop at every live finalize (they would stall dispatch up to one deadline per stored entry on a slow-but-alive remote). The L1 put is synchronous at finalize (as today); entries destined for remote tiers are queued and **flushed at the end-of-run join point** (after the poll loop drains, before `persistLastRun`), under the breaker and a total budget. A crash mid-run loses queued remote puts — acceptable (L1 is already written; the next run re-publishes on its own `cdmStored`s only, so the loss is warmth, never correctness).

**The `verified`-bit backfill rule — the one real correctness subtlety, enforceable.** `verifyTrust` is a *tier* predicate; it is NOT an entry's trust level. Backfill must key on the served entry's actual `verified` bit:

> **Backfill tier `t` only if `hit.verified OR not t.verifyTrust`.**

i.e. an unverified entry may populate only tiers that don't verify trust; a verified entry may populate any tier. This is three lines and is exhaustively boundary-tested across the 2×2×2 matrix (`source verified ∈ {T,F}` × `destination verifyTrust ∈ {T,F}` × tier ordering), **plus the put rule's 2×2** (`attested` × `verifyTrust`). **Because `nonePolicy.verify` always returns `cvOk`, the security-meaningful cases cannot be exercised until a policy that can reject exists — so A3a tests the structural rules with an injected controllable mock `TrustPolicy` (two lines, since `TrustPolicy` is a closure-field object), and C4/C5 add the real-policy interaction tests.**

### `TrustPolicy` — the port

```nim
type
  VerifyProc* = proc(entry: StoredEntry): CacheVerdict {.closure.}   ## on-read; cvOk ⇒ entry may be served; else one of trustVerdicts
  SignProc*   = proc(entry: var StoredEntry) {.closure.}              ## on-put; sets entry.attestation (no-op if no secret held)
  TrustPolicy* = object
    name*:   string        ## "none" | "hmac" | "ed25519"
    verify*: VerifyProc
    sign*:   SignProc

proc nonePolicy*(): TrustPolicy                                        ## verify ⇒ cvOk; sign ⇒ no-op
proc hmacPolicy*(secret: sink string; keyId: string): TrustPolicy      ## HMAC-SHA256 (nimcrypto) over the envelope; signer = keyId
proc ed25519Policy*(signSeed: Option[sello.Seed]; pinned: seq[PublicKey]): TrustPolicy
                                                                       ## ed25519 (sello): sign iff a seed is given; verify against pinned
```

- **Verdicts, not booleans:** `verify` returns a `CacheVerdict` so a trust rejection is as *legible* as a miss — "no attestation" vs "unpinned signer" vs "bad signature" flow through the same verdict channel into `--cache-stats` and the 100 %-error warning; no parallel enum.
- **The signed envelope is canonical, explicit, and recompute-bound** (§Integrity): `envelopeBytes` is pure and shared by sign and verify (one function ⇒ they cannot disagree).
- **`verify` is total and fail-closed:** a missing attestation (`cvTrustNoAttestation`), unparseable/wrong `sigAlg` (`cvTrustUnknownAlg`), unknown/unpinned `signer` (`cvTrustUnpinnedSigner`), signer-mismatch (`cvTrustSignerMismatch`), or bad signature (`cvTrustBadSignature`) all reject. `nonePolicy.verify` is unconditionally `cvOk` — trust is *opt-in*, so a purely-local single-tier cache pays nothing.
- **`signer` derivation is pinned.** ed25519: `signer = base64(toBytes(pk))` — byte-identical to the `pinned-key` config string, so `verify` is a string-set membership test and rotation is a seq add/remove. HMAC: `signer = keyId`, an operator-chosen label (`key-id` in config) — there is exactly one active secret; `signer` is carried for provenance and bound into the MAC, never derived from secret bytes.
- **No `dispose` (round 3).** sello's `Seed`/`Keypair` are move-only (`=copy {.error.}`) **and carry `=destroy` wipes** (`sello/signing.nim`: "performs the same wipe automatically at scope exit"); under ORC the `Keypair` captured in the `sign` closure is destroyed when the `CacheRuntime` drops at the end of `runTests`. An explicit `dispose` duplicated that, and "wiping" an HMAC `string` that `getEnv` already copied is not achievable — the round-2 `dispose` plumbing is deleted. `api.nim` decodes `$CRISOL_CACHE_SIGN_KEY` straight into a `sello.Seed` and `move`s it into `ed25519Policy`, which builds `keypair(seed)` once inside the closure environment; `PublicKey` is copyable. HMAC secret lifetime is process lifetime, stated honestly. **The closure-captures-move-only-`Keypair` interaction is compile-verified in C-dep's smoke test** before C5a is written.
- **Multi-signer = multi-trust-domain (documented constraint).** Pinning a public key means *trusting that signer ran `shouldStore` honestly under a compatible config*. Two parties sharing one L2 and pinning each other's keys form one trust domain by construction. **Pin only keys whose `shouldStore` discipline you trust.** crisol guarantees the signature genuinely came from a pinned signer; it cannot vouch for that signer's hermeticity config.
- **HMAC vs ed25519 — both ship; the choice is the deployer's threat model, with a sharp caveat.** HMAC (`hmacPolicy`) is symmetric: simplest when every trusted party shares one CI secret; **anyone who can verify can forge.** Appropriate ONLY when (a) the CI is fully trusted — *no untrusted PR builds* — and (b) the secret is not readable by test binaries. ed25519 (`ed25519Policy`) is asymmetric: publishers hold a secret, everyone else pins only public keys, so a read-only consumer cannot forge — the right default for an open or multi-party cache.
- **Secrets come from the environment, are resolved once in `api.nim`, are then *removed from the process environment* (round 3), and are injected — the cache modules never read env.** `$CRISOL_CACHE_SIGN_KEY` (base64 of the 32-byte ed25519 seed), `$CRISOL_CACHE_HMAC_KEY`, `$CRISOL_CACHE_TOKEN` / `$CRISOL_CACHE_TOKEN_<TIER>` (http bearer tokens; `<TIER>` = the KDL tier name upper-cased with `-`→`_`). None is in the default allowlist, but **"keep them out of the allowlist" is not sufficient: under `--hermetic none` the scrub is disabled and the whole parent env reaches test binaries** (`sandbox.nim`'s `filterEnv` — `spawn.nim` itself was deleted by 0007 A2b; the runner now passes the full parent env into `ChildSpec.env` under `hlNone`), and `evidenceSatisfies` does not refuse `hlNone` (nothing requested ⇒ nothing failed) so such runs also publish. So `api.nim` `delEnv`s every `CRISOL_CACHE_*` variable immediately after building `CacheSecrets` (secrets live only in closure memory), `filterEnv`'s tail strips `CRISOL_CACHE_*` unconditionally at every hermeticity level, and C3b asserts the child env never contains them under `hlNone`.
- **Misconfiguration is a config error, not a silent dead tier.** `configuredCache` rejects: `policy "ed25519"` with zero `pinned-key`s; `policy "hmac"` with no `$CRISOL_CACHE_HMAC_KEY`; an *explicit* `verify-trust #true` under `policy "none"`; unsigned `s3://` without a verifying policy. **Default (round 3): `verify-trust := (cache-trust.policy != "none")`** — so a `remote-cache` with no `cache-trust` block (E2E-1) is valid and unverified, and a configured policy verifies by default.
- **Sigstore/Rekor** is the natural next tier; its `SigstorePolicy` type is named and locked behind `when defined(crisolSigstore)` — **no empty stub ships**. Follow-on.

### `BackendRegistry`, serializer, telemetry — and where each lives

```nim
# cachewire.nim
type CacheSerializer* = object   ## StoredEntry ⇄ bytes; JSON-only ships (msgpack deferred, port exists)
  encode*: proc(e: StoredEntry): string {.closure.}
  decode*: proc(s: string): Fetched[StoredEntry] {.closure.}   ## cvCorrupt / cvVersionSkew distinguishable (C1 needs both)

# cachetelemetry.nim
type
  TelemetryEventKind* = enum tekHit, tekMiss, tekRemoteErr, tekPublish, tekBackfillErr, tekVerifyFail
  TelemetryEvent* = object       ## variant — the codebase idiom for kind-dependent fields (GroupSelection, types.nim:282)
    case kind*: TelemetryEventKind
    of tekHit:         tier*: string; durationMs*: int64
    of tekMiss:        verdicts*: seq[TierVerdict]
    of tekRemoteErr, tekBackfillErr:   putTier*: string; putVerdict*: CacheVerdict
    of tekPublish:     publishedTo*: string
    of tekVerifyFail:  path*: string
  TelemetrySink* = object        ## NilSink default; summary sink (--cache-stats) + InMemorySink (tests)
    emit*: proc(ev: TelemetryEvent) {.closure.}

# cacheregistry.nim
type BackendFactory* = proc(tier: RemoteTier; token: string): CacheBackend {.closure.}   ## typed config in, adapter out
proc registerBackend*(reg: var BackendRegistry; scheme: string; factory: BackendFactory)
proc buildBackend*(reg: BackendRegistry; tier: RemoteTier; token: string): Option[CacheBackend]
  ## resolves the adapter by URL SCHEME (file/http/https/s3)
proc productionRegistry*(fetcher = productionFetcher()): BackendRegistry   ## file (A2a), http/https (C1), s3 (C2) — NO memory
proc testRegistry*(fetcher: HttpFetcher): BackendRegistry                   ## productionRegistry(fetcher) + memory:// + memoryBytes://
```

- **Registry resolves by URL scheme**: `s3://…`→s3, `https://…`→http, `file://…`→local-fs. `buildBackend` is a pure function of `(RemoteTier, token)`; factories capture nothing else. Adding a transport = one file + one `registerBackend(scheme, factory)`. **`memory://` is registered only by `testRegistry()`**: a typo'd `memory://` URL in production KDL must be a config error, not a silently-empty per-process tier. The registry is **parameterized by the `HttpFetcher`** so E2E-3 drives the real KDL → `configuredCache` path with the fake fetcher (round 3 — the round-2 plan had no injection point that exercised the config path).
- **`CacheSerializer` is consumed by every adapter** (§One format). The port exists so msgpack is a later adapter (Corey's locked Full-Flexible decision); only JSON ships.
- **`TelemetrySink` lives on `CacheRuntime`, NOT on `TieredCache`.** `TieredCache` is a pure lookup engine, testable with no sink. The `realSeams.load`/`store` adapters own telemetry emission — the translation layer between the internal `lookup` and the external `CacheSeams`, which is exactly where an observation of the call belongs. **`cacheStats`, `cacheTier` and `cacheLookup` never carry backend URLs, credentials, or signer identifiers** — only aggregate counts, verdict names and the deployer-chosen tier label (`run/v2` is routinely archived as a CI artifact).

### Wiring — what changes at the seam (and what doesn't)

```nim
type
  KeyContext* = object           ## everything keyOf closes over except the live graph (round 3 — realSeams had 8 positional params)
    nimVersion*, ccVersion*: string
    spec*:            SandboxSpec
    hermeticEnvHash*: string     ## = hermeticEnvHash(filterEnv(parentEnv, spec, @[])) with env-pins applied — computed ONCE
    protocolMajor*:   int
  proc keyContext*(nimVersion, ccVersion: string; spec: SandboxSpec;
                   parentEnv: openArray[(string, string)]; envPins: openArray[(string, string)];
                   protocolMajor: int): KeyContext

  KeyDerivation* = object        ## the seam derives INPUTS; dispatch hashes them (pure, keys.nim)
    inputs*: KeyInputs
    key*:    SoundnessKey        ## = soundnessKey(inputs)

  KeyOfProc*  = proc(pep: PlannedEntrypoint): KeyInputs {.closure.}                               ## WAS → SoundnessKey
  LoadProc*   = proc(pep: PlannedEntrypoint; d: KeyDerivation): CacheLookup {.closure.}           ## WAS (key) → Option[CachedResult]
  StoreProc*  = proc(pep: PlannedEntrypoint; d: KeyDerivation; res: CachedResult): bool {.closure.} ## WAS (key, res) → bool
  CacheSeams* = object           ## still exactly three closures
    keyOf*: KeyOfProc; load*: LoadProc; store*: StoreProc

  CacheRuntime* = object         ## the cache-side bundle realSeams/api receive (one place for growth; no dispose)
    cache*: TieredCache
    sink*:  TelemetrySink

proc derive*(seams: CacheSeams; pep: PlannedEntrypoint): KeyDerivation   ## inputs = seams.keyOf(pep); key = soundnessKey(inputs)
proc keyOfProc*(ctx: KeyContext; graph: ptr DepGraph): KeyOfProc         ## what the 4 key-derivation tests call
proc realSeams*(ctx: KeyContext; graph: ptr DepGraph; rt: CacheRuntime): CacheSeams =
  CacheSeams(
    keyOf: keyOfProc(ctx, graph),
    load:  proc(pep: PlannedEntrypoint; d: KeyDerivation): CacheLookup =
             let l = rt.cache.lookup(d.key)
             if l.hit.isSome:
               rt.sink.emit(TelemetryEvent(kind: tekHit, tier: l.hit.get.tier, durationMs: l.hit.get.result.run.durationUs div 1000))
               # backfill-seeded sidecar + per-tier verdicts handled here (tier 0 = local-fs)
             else:
               rt.sink.emit(TelemetryEvent(kind: tekMiss, verdicts: l.verdicts))
             l,
    store: proc(pep: PlannedEntrypoint; d: KeyDerivation; res: CachedResult): bool =
             let vs = rt.cache.put(StoredEntry(key: d.key, keyInputs: some(d.inputs), result: res, storageVersion: storageFormatVersion))
             for (tier, v) in vs:
               if v == cvOk: rt.sink.emit(TelemetryEvent(kind: tekPublish, publishedTo: tier))
               elif v in transportVerdicts: rt.sink.emit(TelemetryEvent(kind: tekRemoteErr, putTier: tier, putVerdict: v))
             vs.anyIt(it.verdict == cvOk),   # L1 synchronous; remote puts queued (§TieredCache) — the fold sees the L1 verdict now
  )
```

**Why the seam re-shapes (round 3 — three lenses independently):** the round-2 text declared `StoreProc` "unchanged" (`(key, res)`) and then wrote `toStoredEntry(key, res, keyInputsFor(...))` and a *path-keyed* sidecar — but neither `KeyInputs` nor `ep.path` is recoverable from a `SoundnessKey` (a one-way FNV fold, `keys.nim:112-161`); `keyOf` derived the inputs and discarded them (`cachedispatch.nim:404-414`). A closure-local memo `Table[key → inputs]` was considered (no shape change) and rejected: hidden state keyed by the very value it explains. The clean design: **the seam derives *inputs*, dispatch hashes them** (`soundnessKey(inputs)` is already a pure proc in `keys.nim`), and `load`/`store` receive the `PlannedEntrypoint` (the runner has it at both call sites — `runner.nim:992`, `:1335`) plus the derivation — so the sidecar has its path, the wire entry has its inputs, and `explainMiss` has its `curr`. `lookupAtPlan` calls `derive` once and stamps `d.key` as `inputHash`.

**The provenance thread (round 3 — corrected against the real stamp sites).** `lookupAtPlan` → `PlanLookup += tier: string, lookup: CacheVerdict` (the serving tier; `worst(l)` on a miss) → two stamp sites in `runner.nim` (anchors refreshed at HEAD 2026-09-03, post-A2b): the **hit stamp** (the plan-lookup loop at `:1307-1330`, where `look.synthesized` is stamped — `synth.cacheTier = look.tier`) and the **live stamp** (a new per-index `lookups[i]` seq next to `inputHashes[i]`, stamped wherever `inputHashes[completedIdx]` lands today — `:1443`/`:1597` ⇒ `result[i].cacheLookup`). New `EntrypointResult` fields, additive: **`cacheTier: string`** (`""` unless served) and **`cacheLookup: CacheVerdict`** (`cvOk` on hit; `cvMiss`/`cvOffline`/a trust code on a consulted miss; `cvOk` also when not consulted — the wire renders it as a string, absent when not consulted). **`cdmTrustFail` is dropped:** round 3 found the live stamp overwrites the plan-time decision with `shouldStore`'s verdict — a trust-rejected entry that runs live and passes is (correctly) re-published as `cdmStored`, so a `CacheDecision` variant could never be observed on the result. The trust rejection is carried by `cacheLookup` instead, independent of the store verdict; E2E-2 asserts `cacheLookup == "trustBadSignature" and cacheDecision == cdmStored` and notes the re-publish as intended self-healing of a tampered entry. `jsonout.nim` renders `cacheTier`/`cacheLookup` on `crisol/run/v2` under `schemaRevision` **19** (the current revision is 18 — rev 16 was the v2 cutover, 17 added `recomputeMiss`, 18 the `substrate` node).

**What does not change:** `CacheSeams`'s three-closure shape (re-typed, not re-shaped), `lookupAtPlan`'s decision logic (a hit is a hit; a miss is a miss), `shouldStore`, `CacheContext`, `inactiveDecision`, `cacheEnabled`/`cacheDisabled`, the `EntrypointDecision` sum (FORK-2 (a): the poll loop changes, the plan-time sum does not). A purely-local run (the default) builds `CacheRuntime{cache: TieredCache{@[l1Tier], nonePolicy()}, sink: NilSink}` via `localOnlyCache` — behaviorally identical to RFC-0004.

**Test injection without a facade leak (round 3).** The round-2 `RunOptions.cacheRuntime: Option[CacheRuntime]` would have leaked `cacheport`'s whole type graph into the contracted `crisol/api` facade (a consumer could only construct it by importing uncontracted internals; amoxtli uses no Nim API — it parses `run/v2` JSON). Removed from 0005. Instead `api.nim` exposes an **internal, documented-uncontracted** `runTestsWith*(opts: RunOptions; deps: CacheDeps): RunReport` where `CacheDeps = {registry: BackendRegistry, secrets: CacheSecrets, sink: TelemetrySink}`; `runTests` calls it with `productionRegistry()`, env-resolved secrets and the flag-chosen sink. E2E tests inject `testRegistry(fakeFetcher)` + fixture secrets through it. Library-level injection can return as a follow-on once the port has survived Stage C.

### Construction ergonomics — factories keep `api.nim` thin

```nim
# types.nim — parsed KDL lives next to PerfCheckConfig/ReuseCheckConfig (config.nim cannot import the cache modules)
type
  RemoteTier* = object
    name*, url*: string
    endpoint*: Option[string]; pathStyle*: Option[bool]        # s3 only
    verifyTrust*: Option[bool]                                  # absent ⇒ policy != "none"
    backfillOnHit*: bool = true
  TrustConfig* = object
    policy*: string = "none"; pinnedKeys*: seq[string]; keyId*: string
  CacheConfig* = object
    remotes*: seq[RemoteTier]; trust*: TrustConfig
    cacheStats*, explainMiss*: bool; verifyCachePct*: int = 5
    envPins*: seq[(string, string)]

# cacheregistry.nim
type CacheSecrets* = object      ## resolved ONCE in api.nim from env (then delEnv'd); never inside the cache modules
  signSeed*:   Option[sello.Seed]        ## $CRISOL_CACHE_SIGN_KEY (base64-decoded, moved)
  hmacKey*:    Option[string]            ## $CRISOL_CACHE_HMAC_KEY
  httpTokens*: Table[string, string]     ## tier name → $CRISOL_CACHE_TOKEN[_<TIER>]

proc localOnlyCache*(stateDir: string; maxEntries: int): CacheRuntime
  ## single-tier local-fs ("l1"), nonePolicy, NilSink. The default for every run with no remote configured.
proc configuredCache*(cfg: CacheConfig; stateDir: string; reg: BackendRegistry;
                      secrets: CacheSecrets; sink: TelemetrySink): CacheRuntime
  ## build tiers from the parsed KDL; returns localOnlyCache if no remote tier. Resolves the cache-global trust
  ## policy + per-tier credentials; REJECTS unverifiable trust config (raises CrisolError(cekConfig) ⇒ exit 3 via
  ## the existing planImpl catch — so it is invoked INSIDE the plan try, BEFORE acquireLock, api.nim:527-546).
```

## Stage B — observability (port-independent; lands first)

### Miss-explanation — `explainMiss`

```nim
# keys.nim
type KeyComponent* = enum   ## names WHICH of the 9 key inputs differs
  kcClosure, kcFlags, kcNimVersion, kcCcVersion, kcFixtures, kcArgv, kcLimits, kcHermeticEnv, kcProtocol
type KeyDiff* = object
  component*: KeyComponent
  prev*, curr*: string
  envNames*: seq[string]     ## kcHermeticEnv only: the variable NAMES whose value/presence differs (never values)

proc explainMiss*(prev, curr: KeyInputs; prevEnv, currEnv: seq[(string, string)]): seq[KeyDiff]   ## PURE
```

A miss is *legible* only if you can recover the *previous* inputs for the *same test*. Mechanism: tier 0 (the local-fs L1 — **never** a shared `file://` L2, which must not host per-host history) writes a **sidecar keyed by PATH** at `<root>/v<N>/inputs/<fnv(path)>.json` — *not* by `identityKey(path, flagHash)`: keying by the full identity key would make a flag change (the most common deliberate miss) produce a *different* sidecar ⇒ "no prior inputs" instead of "your flags changed". The sidecar stores a small map `flagHash → {inputs: KeyInputs, envDigest: seq[(name, hash16(value))]}` (most-recent-per-flagHash, pruned on write). **`envDigest` is what makes the dominant cross-host miss legible (round 3):** `hermeticEnvHash` is one FNV over all names+values, so without per-name digests `kcHermeticEnv` would render as `a1b2… ≠ c3d4…` with no variable named — precisely the miss §Key portability predicts. Values are never stored. On a miss, the `load` adapter reads the path's sidecar, picks the most-recent prior record, diffs against `curr`, and attaches `seq[KeyDiff]` to the lookup; `--explain-miss` renders them. Absent any sidecar (older writer, first-ever run) it **degrades gracefully** to "no prior inputs recorded."

**Rendering (round 3, fresh fact #2):** `kcNimVersion` prev/curr are now multi-line `nim --version` text + `|` + binary hash; `kcCcVersion` likewise; `kcClosure`/`kcFlags` are opaque hashes. The renderer is component-aware: first line of the version text + 8-hex of the binary hash ("compiler binary differs"); `argv` joined; `limits` diffed per `LimitKind` (the enum-indexed `Limits.req` — rfc-0007 A2a-iii); `kcHermeticEnv` lists `envNames`; opaque hashes render as "changed (`a1b2…` → `c3d4…`)". Full values only under `--explain-miss-verbose`.

**Honest scope:** `explainMiss` needs *local history* — informative on persistent dev machines and self-hosted runners; an ephemeral CI runner has nothing to diff against. The remote tier does not help here (a remote miss means *no entry for the current key*, and the remote is not path-indexed). What the remote *does* do: every `StoredEntry` carries `keyInputs`, and a backfill-on-hit **seeds the local sidecar** from it — so a fresh host's *next* miss on that path is explainable. Cross-host explanation of a remote miss is an explicit Non-Goal.

Sidecar mechanics, pinned: it is a **local-fs-adapter implementation detail, not a `CacheBackend` contract** (the `memory` double does not exercise it; B1 tests it via the local-fs boundary suite). Serialize via hand-written `keyInputsToJson`/`keyInputsFromJson` in `cachewire.nim` following `resultcache.nim`'s `payloadToJson` pattern; **do not** reach for `std/jsonutils`. Sidecar content is **portable** (equal identity ⇒ equal `KeyInputs` on any host), so a backfill may legitimately write it. Sidecars live under `inputs/` (outside the entry cap and LRU — §Local-fs root); `gcResultCache` prunes `inputs/` records whose path no longer has any live entry (B1 owns this, inside the existing walk). Rename-collision (a path reused by a different entrypoint) overwrites the stale sidecar on next `put`. Two crisol processes on one stateDir cannot race the sidecar — `runTests` holds the whole-run lock (`flock(LOCK_EX|LOCK_NB)` since rfc-0007 A4 replaced `fcntl F_SETLK`; `lock.nim`). The KDL `explain-miss` key is parsed in B1 (config < CLI).

### Hit-rate telemetry

A `TelemetrySink` aggregates events emitted by the `realSeams` adapters (hit + tier, miss + per-tier verdicts, remote-error, backfill-error, publish). At run end crisol emits one summary line — **L1 hits / remote hits / misses / remote-errors / total / hit-% / wall-time-saved / published / verifyFails** — and a structured `cacheStats` object in `crisol/run/v2`. **`total` = lookups actually consulted** (hit + keyMiss + recomputeMiss + stored + hermeticityDegraded + flaky + closureUnrecorded + trust-rejected); a separate **`notConsulted`** (notEligible / groupOptOut / policyDisabled — `inactiveDecision`, `cachedispatch.nim:341`) keeps `hitPct` from being diluted by `cacheable #false` groups. `remote-errors` makes a misconfigured remote (100 % `cvUnauthorized`/`cvTimeout`/`cvOffline`) diagnosable instead of masquerading as a cold cache; crisol additionally writes a **stderr warning when a configured remote tier errored on every call** in a run — where "errored" includes the trust codes and `cvCorrupt` (a tier that rejects 100 % of reads is as dead as one that times out), attributed per tier via `CacheLookup.verdicts` even when a later tier served. `wall-time-saved` sums served `cdmHit` entries' historical durations (`run.durationUs`, rendered as ms). Default sink `NilSink`; `--cache-stats` installs the summary sink; `InMemorySink` is the test double. **Output channels (round 3):** in `--json` mode the run/v2 document owns stdout (amoxtli `parseJson`s it verbatim; its v2 consumer is exercised against real output in 0007's A7-gate), so every human summary/explain line goes to **stderr** in `--json` mode and to stdout otherwise; the structured data lives in `cacheStats`/per-result fields. There is no `--quiet`; warnings (100 %-error, verifyFail) are unconditional stderr.

### `--verify-cache` — the determinism backstop

`evidenceSatisfies` proves hermeticity, not determinism. `--verify-cache` (sample size `--verify-cache-pct N`, default 5; KDL `verify-cache-pct`) re-executes a sample of entrypoints that were served `cdmHit` this run and **compares observations, never verdicts** (A7-gate re-baseline): the fresh attempt's `Exit` (structural equality over the variant — `==`(Exit) in `process/types`) and its parsed `records` (name/status/msg/tags; per-record `durationUs` excluded) against the stored `ProcessResult.exit` + `records`, byte-honest. `outcome` strings are never compared — outcome is a derived, policy-dependent projection, and two distinct observations can derive the same verdict, which is exactly the nondeterminism this pass exists to surface. `Cause`, `Evidence`, `rusage` and durations are excluded from the comparison (authorship, tier and accounting of the *fresh* attempt legitimately differ) but are reported alongside a divergence for diagnosis. On divergence it reports. It is a **post-run pass**, never in the hot path: the run completes and reports on cached results immediately; verification is a trailing pass. Hard requirements:

- **No cache writes during verify.** The verify pass is constructed with `cache = cacheDisabled(spec)` so `shouldStore`/`put` are never reached — it cannot overwrite the entry it is checking, reset LRU age, or re-publish a divergent result.
- **Single attempt.** `retries` is per-`PlannedEntrypoint` (`types.nim:369`; `runner.nim:1224` `maxAttempts = pep.retries + 1`), not a run knob — the pass sets **`pep.retries = 0`** on each synthetic entry. A retry would mask the very flakiness verify exists to find.
- **Synthetic plan, not a re-`plan()`.** The pass builds a `RunPlan` directly from the sampled subset of the first run's `PlanReport.entrypoints` (already-available `PlannedEntrypoint` values, selected by `EntrypointResult.cacheDecision == cdmHit` and paired by index), `jobs = 1` for determinism; it does not re-discover entrypoints or mutate/save the depgraph. (Round 3 correction: `edecision` is never written back after plan — the promotion lives only in `PlanLookup.decision` — so no reset is needed; the sampled entries are still `edRunFresh` and dispatch to `spawnRunDirect`, asserted.) **Binary precondition:** a `cdmHit` this run implies `edRunFresh` at plan ⇒ `<stateDir>/bin/<slug>/<bin>` existed (`planner.nim:177`) and the stateDir lock is held for the whole run, so `clean` cannot remove it — the pass runs **before `releaseLock`, after `persistLastRun`** (lastrun.json must reflect the main run only; `--failed` narrowing reads it). Under FORK-2 (a)'s post-compile consult, a hit may precede the stable-binary copy — the consult copies the binary before synthesizing, preserving this invariant.
- **`execute()` re-entrancy is confirmed but leaky without three guards (round 3):** (1) `execute` fires `onResult` for every result (`runner.nim:1360`) — the pass passes a no-op (`onVerify` is a follow-on); (2) `appendAttemptRow` fires on every live attempt (`:1229-1237`) — verify re-runs would pollute `--order failed-first`/`medianDur`, perf-check history and `--shard` LPT samples ⇒ `execute()` gains `recordLedger: bool = true`, `false` for the pass; (3) verify results are never merged into `RunReport.results` — they live only in `RunReport.verifyDivergences`. `failFast = false`. The pass re-opens a fresh ledger shard name (`ledger.nim:141-146`, per-process `shardSeq`) — fine.
- **Sampling:** seeded PRNG; the seed defaults to a per-run value (reported in the summary line) so coverage broadens across runs in expectation, and `--verify-cache-seed N` reproduces a specific sample. `max(1, pct·hits/100)` entries are sampled whenever `pct > 0` and there is at least one hit.
- **Isolated telemetry.** A fresh/filtered sink so verify events don't double-count into the main run's `cacheStats`.
- **Divergence is user-visible, not swallowed:** a `verifyFail` produces a **stderr warning even under `NilSink`**, a `verifyFails` count in `cacheStats`, and the human render names the entrypoint. `--verify-cache-strict` makes a divergence set exit code 1 (CI gate) and **requires `--verify-cache`** (exit `ExitEnvironment` otherwise, same shape as `--base` requiring `--changed`, `crisol.nim:~723`). It **never evicts**.
- **Facade (round 3):** `RunOptions.verifyCache: VerifyCache` — an object `{enabled, pct = 5, seed: Option[int64], strict}` built via `noVerify()` / `verifySample(pct, seed, strict)` so "strict without enabled" is unconstructable (the `RunNarrowing` constructor idiom, `api.nim:151-156`).

**Concurrency reconciliation (load-bearing).** crisol's runner is a single-threaded fork/poll loop (`execute()`), *not* an async runtime. `--verify-cache` introduces no competing primitive: it runs *after* the main poll loop drains, as a second bounded `execute()` over the sampled subset. Remote backend I/O (Stage C) follows the same discipline — see **B0**.

### B0 — remote-I/O concurrency and the deadline mechanism (design slice; round 3 rewrite)

Facts: (1) `runner.nim:966-1010` runs the cache-consultation loop **serially, before** dispatch — N remote lookups without mitigation is N × deadline of dead wall-clock at the front of every run; (2) `std/httpclient`'s `timeout` bounds only post-connect `recv`s; `newConnection` calls `net.dial`, which has **no timeout** — DNS + TCP connect to a black-holed host hangs indefinitely; (3) **TLS on `std/net` has no deadline either** (round 3): `wrapConnectedSocket` calls `SSL_connect` on a *blocking* fd (`net.nim:856-880`) — a server that accepts TCP and stalls the handshake hangs the run; and `SSL_ERROR_WANT_READ/WRITE` on non-blocking sockets raise unless `socketError(async=true)` is used, which the high-level `recv`/`readLine` paths do not expose — a hand-rolled non-blocking TLS state machine is far beyond a "minimal client"; (4) a `select`-drained concurrent lookup pass needs a *second*, incremental HTTP state machine plus a new port capability — a round, not a slice. Decisions:

- **(a)** The production `HttpFetcher` is a minimal raw-`std/net` HTTP/1.1 client — `Socket.connect(host, port, timeout)` (non-blocking connect + poll, `net.nim:2126`), **`SO_RCVTIMEO`/`SO_SNDTIMEO` set to the deadline remainder before `wrapConnectedSocket` and before each `recv`** (the only way to bound the blocking SSL path), `Content-Length` framing plus chunked-response decoding, TLS via `wrapConnectedSocket` under `-d:ssl`, **no redirect following**, a **body size cap** (default 8 MiB — `records[].msg` is unbounded test output; `maxOutputBytes` is 10 MiB per entrypoint), `EINTR` ⇒ transport failure (`select` is never restarted under `SA_RESTART`). Residual: synchronous DNS resolution inside `connect` (bounded by the resolver's own timeout, documented).
- **(b)** Default per-call deadline **2000 ms** (connect + TLS + response), hardcoded in 0005 (a KDL knob is a follow-on).
- **(c) Plan-time lookups: circuit breaker + probe, not a select loop.** The per-tier **circuit breaker** (§TieredCache) bounds the *offline* case to one deadline per tier per run. For the *alive* case, when a tier `canProbe` the key set is resolved **once** at plan time (`probe(keys)` — s3 via a ListObjectsV2 prefix listing under `<ver>/`, a `<Key>`-extraction over the response, no general XML parser; http has no standard bulk-existence so `probe = nil`) and `lookup` consults the probe result before any per-key `get`; without `probe`, per-key `get`s are sequential and each bounded by the deadline — N × RTT on a slow-but-alive remote, **stated honestly** in the operator guide. The **select-drained concurrent pass is deferred** (§Non-Goals, §Alternatives). The prefetch loop checks `shutdownRequested()` per iteration and abandons the prefetch on a pending shutdown (re-baseline: `pendingSignal()` and `CrisolInterrupted` were retired by 0007 A2b/A1e-ii — the Supervisor owns signal delivery via `weShutdown`, `signals.shutdownRequested()` is the level-triggered mirror, and `execute()` returns a partial report instead of raising; an abandoned prefetch degrades to per-key misses and the run proceeds into the normal interrupt path).
- **(d) Deferred remote puts** (§TieredCache): remote writes leave the poll loop and flush at the end-of-run join point under the breaker and a total budget.
- **(e)** `execute()` re-entrancy for B3 confirmed with the three guards above. Written rationale lands in the RFC + `cachetier` doc comment; no functional code in B0.

## Stage C — trust first, then the network-touching tail

> **Crypto dependencies (FORK-1, resolved 2026-08-21; C-dep simplified round 3 — see §Dependency decision).** **ed25519 via [sello](https://github.com/coreyleavitt/sello)** — `v0.4.0` is tagged and pushed and already exports `Seed`/`Keypair`/`toSeed`/`keypair`/`sign`/`verify`/`PublicKey`/`toBytes`/`wipe` (pure Nim by default; libsodium only under `-d:selloLibsodium`), so crisol pins **`v0.4.0` by git ref** — no local-path pin, no `./dev` sibling-mount machinery — and bumps to `v0.5.0` when Corey tags it. **HMAC-SHA256 + SHA-256 via nimcrypto `v0.7.3`** (pure Nim, already in the milpa CAS as sello's own dependency). **Both `hmacPolicy` and `ed25519Policy` ship.** Initial S3 is **unsigned/MinIO path-style** (no SigV4) — authenticated S3 (SigV4, reusing the nimcrypto HMAC) is a follow-on. No Dockerfile delta for crypto; C1a's `libssl-dev` remains for TLS only.

**Order (round 3): trust before transports.** Trust has zero network dependency, unsigned `s3` is *unusable* without a verifying policy (§Secure-by-default), and `configuredCache` cannot wire `policy "hmac"` before `hmacPolicy` exists — so C-dep → C4 (E2E-2 over `file://`) → C5 → then http/s3. And the trust-*reject* path is live from Stage A: A3b runs a mock-policy E2E through `runTests` (two `memory` tiers + the controllable mock returning `cvTrustBadSignature` ⇒ live execution, `cacheLookup == trustBadSignature`, the rejected entry never served).

- **`HttpFetcher` transport seam (round 3 shape):**
  ```nim
  HttpRequest* = object
    meth*, url*: string; headers*: seq[(string, string)]; body*: string   # named fields — no three positional same-typed strings
  TransportOutcome* = enum toOk, toTimeout, toUnreachable
  HttpReply* = object
    case transport*: TransportOutcome
    of toOk: status*: int; headers*: seq[(string, string)]; body*: string
    else:    discard
  HttpFetcher* = proc(req: HttpRequest): HttpReply {.closure.}
  ```
  — `toTimeout`/`toUnreachable` are the **only** transport-failure signals (⇒ `cvTimeout`/`cvOffline`), so the adapter's mapping falls out of the seam's own total-function contract. Production wires the raw-`std/net` client from B0 (C1b); tests wire a pure in-memory proc — **no socket in the suite** for the adapters. HTTPS needs OpenSSL in the podman image — slice **C1a** adds `libssl-dev` to the Dockerfile + `-d:ssl` (in a project `config.nims` — `nim.cfg` is milpa-generated) and verifies the build *before* adapter logic.
- **Adapters:** `local-fs` (Stage A), then `http` (GET/PUT over a content-addressed URL `<base>/<storageFormatVersion>/<soundnessKey>`, `Content-Type: application/json`, `Authorization: Bearer <token>` when configured, deadline, total-function) with a **pinned status table (round 3):** 200 ⇒ decode; 404/410 ⇒ `cvMiss`; 401/403 ⇒ `cvUnauthorized`; 408/429/5xx ⇒ `cvOffline` (transient, trips the breaker); 3xx ⇒ `cvOffline` + one-time stderr hint ("remote redirected; use the final URL"); 2xx with wrong `Content-Type` / undecodable / oversized body ⇒ `cvCorrupt`; PUT 2xx ⇒ `cvOk`, 409/412 ⇒ best-effort non-ok (first publisher wins, documented), 413 ⇒ `cvCorrupt`; a `put` pre-check skips entries over the body cap. **No HEAD** (conditional GET is folded in; nothing calls HEAD). `s3` (same contract over the S3 object API; settings `endpoint` — absent ⇒ AWS default host, present ⇒ e.g. `http://minio.local:9000` — and `path-style` — default `#true` when `endpoint` is set; `probe` via ListObjectsV2 prefix listing). **`storageFormatVersion` is a NEW integer covering the `StoredEntry` wire shape — distinct from RFC-0004's `resultCacheFormatVersion` and coupled to it by the §Integrity rule.** Because the version is a URL path segment, **a format bump is transparent to a mixed fleet**: old binaries keep reading/writing `<base>/<N>/…`, new ones `<base>/<N+1>/…`; the old prefix is cleaned by a backend lifecycle rule once the fleet has rolled (operator guide). The in-process **fake server** double (configurable status/headers/body/size per call; validates method/Content-Type/auth header) catches real-server mismatches.
- **Concurrent PUT idempotency:** the wire key is `<storageFormatVersion>/<soundnessKey>` only; two publishers may mint different-but-equally-valid attested entries for one key; last-writer-wins among entries that pass integrity + trust is sound (§Integrity). The put rule guarantees an *unattested* entry never overwrites an attested one on a `verifyTrust` tier.
- **`TieredCache` wiring in `api.nim`** via `configuredCache`; backfill-on-hit + `verified`-bit rule active. `--no-remote-cache` drops all non-L1 tiers (local cache still active). (The `file://` two-tier path lands in **A3c**; C3 extends the same wiring to http/s3 and the trust block.)
- **Ledger staleness under high hit rates (resolved, documented).** `appendAttemptRow` fires only on live execution; a `cdmHit` never refreshes the ledger, so `--shard`'s LPT balancing reads older duration samples as hit rates rise. Shard *correctness* is unaffected; an unchanged test's duration is stable, so the degradation is marginal. 0005 **accepts this** (the ledger records executions, not cache events). If ledger pruning ever evicts a cached test's last sample, `durationOf` may fall back to the hit's `CachedResult.run.durationUs` at plan time — a follow-on. Clock-skew corollary: a skewed publisher's `cachedAt` would drive L1 age-GC after backfill ⇒ `gcResultCache` orders LRU by local file mtime, not payload `cachedAt` (B1, same walk).

### Secure-by-default (a soundness/security stance, not a fork — [[no-fake-forks-soundness]])

**Reading** a remote tier needs only a read-scoped credential; **publishing** requires a *write-scoped* credential, and there is **no `--publish` flag** — you publish iff you hold a write credential (`cvUnauthorized` `put` → no-op, run still serves reads). This makes "poison the shared cache from a dev laptop" structurally impossible. The publish gate (recomputed pass && `evidenceSatisfies` && attempt-1) is *upstream* of credentials — credentials gate *transport*, the gate decides *storability*; an entry must clear both. Signing/read keys come from **environment**, never config files, and are removed from the process env once resolved (§TrustPolicy).

**Unsigned S3/MinIO has no transport-level write authorization.** Without SigV4 no credential is ever transmitted, so the IAM read/write split does not exist for this adapter; anyone who can reach the bucket can PUT. Therefore: **a verifying tier with a non-`none` policy is a hard requirement whenever the unsigned-`s3` adapter is used** (`configuredCache` rejects `s3://` + `policy "none"` / explicit `verify-trust #false`), and in that mode **the signing key *is* the effective write credential**: an unattested or foreign-signed object is never served (and — put rule — never written by crisol itself), so poisoning degrades to storage litter, which is the bucket/network ACL's job. The IAM-policy story applies only to the SigV4 follow-on.

### Configuration (round 3 — flat top-level grammar, matching the landed config and RFC-0006 D6)

The landed KDL grammar is **flat scalars** (`max-cache-entries`, `cache-max-age-days`, `ledger-max-age-days`, `rlimit-nofile` — `config.nim:505-527`) plus **1-deep blocks** (`group "unit" { }`, `perf-check { }`, `reuse-check { }`), with **config key == CLI flag name** (`retries`, `jobs`, `rlimit-nofile`). RFC-0006 round 2 (D6) explicitly chose flat scalars "to match LANDED resultcache, NOT the unlanded 0005 block." A nested `cache { remote … trust … telemetry … }` would be the first 2-deep block, would break key==flag naming, and would leave two cache knobs flat and the rest nested — the one wrong answer. So:

```kdl
remote-cache "team-s3" {            // a named tier appended after local L1; repeatable (modelled on `group`)
    url "s3://ci-cache/crisol"      // SCHEME selects the adapter
    endpoint "http://minio.local:9000"   // s3 only; absent ⇒ AWS default host
    path-style #true                // s3 only; default #true iff endpoint set
    verify-trust #true              // default: (cache-trust.policy != "none")
    backfill-on-hit #true
}
remote-cache "mirror" {
    url "https://cache.example.com/crisol"   // http: bearer token from $CRISOL_CACHE_TOKEN_MIRROR (or $CRISOL_CACHE_TOKEN)
}
cache-trust {                       // CACHE-GLOBAL (one policy per TieredCache); optional, default none
    policy "ed25519"                // none | hmac | ed25519
    pinned-key "…base64…"           // repeatable; ed25519 verifies against this set (signer == this string)
    // key-id "ci-2026"             // hmac only: the operator-chosen signer label
}
cache-stats #true                   // ↔ --cache-stats
explain-miss #true                  // ↔ --explain-miss
verify-cache-pct 5                  // ↔ --verify-cache-pct
env-pin "TERM" "dumb"               // repeatable; ↔ --env-pin NAME=VALUE (§Key portability)
```

Flags: `--no-remote-cache`, `--explain-miss`, `--explain-miss-verbose`, `--verify-cache`, `--verify-cache-pct N`, `--verify-cache-seed N`, `--verify-cache-strict` (requires `--verify-cache`), `--cache-stats`, `--env-pin NAME=VALUE` (repeatable). CLI > env > config. Flag grammar matches `src/crisol.nim`'s existing parser (bare booleans + required-value flags). `file://` URLs follow crisol's POSIX-only execution model. An older crisol reading a config with these keys only *warns* on unknown top-level nodes (`config.nim:533`) — graceful. Each slice that adds a key/flag also updates `usage()` (`crisol.nim:138-220`) and `config.nim`'s header KDL reference.

### Remote cache deployment (operator guide)

- **Toolchain identity (round 3):** all hosts sharing an L2 must run the **same nim build artifact** (the key includes a content hash of the nim binary — two distro packages of "2.2.10" never match) and the same cc + libc. Pin the toolchain image. `--explain-miss` names `kcNimVersion`/`kcCcVersion` when this is the cause.
- **Environment parity (round 3):** cross-host hits require equal values for every allowlisted variable (`HOME LANG LOGNAME NIM_CONFIG_DIR NIMBLE_DIR PATH TERM TZ USER LC_*`). Same-image CI runners match by construction; for laptop↔CI or heterogeneous runners, `env-pin` the ones that differ (typically `USER`, `LOGNAME`, `TERM`, `TZ`, `LANG`, and `PATH`/`HOME` if they differ). `--explain-miss` lists the offending names. `dep-roots` at different absolute locations never share keys (follow-on).
- **S3 (unsigned/MinIO, what ships in 0005):** create a bucket; restrict reachability by network/bucket policy (the *only* transport-level control); **configure `cache-trust` with a verifying policy** (required); give publishers the signing secret, consumers only the pinned public keys. **Local dev:** `podman run -p 9000:9000 minio/minio server /data`, `url "s3://crisol/cache"`, `endpoint "http://localhost:9000"`. The **SigV4 follow-on** adds the IAM story: a **read** policy (`s3:GetObject`, `s3:ListBucket` on the prefix) for consumers; a **write** policy (adds `s3:PutObject`) for publishers; creds via standard `AWS_*` env.
- **http:** any content-addressed blob store that accepts `GET`/`PUT` on `<base>/<storageFormatVersion>/<key>`; read-only consumers get a read token (or none, for a public read mirror), publishers a write token, via `$CRISOL_CACHE_TOKEN[_<TIER>]`. Redirects are not followed — configure the final URL.
- **Latency:** with `probe` (s3) one listing per run; without (http) one bounded round-trip per consulted entrypoint on a slow-alive remote; an offline remote costs one deadline per run (breaker). Remote writes flush at end of run.
- **Multi-project buckets:** one project's entry served to another with *identical* `SoundnessKey` inputs is **sound by construction**. Nonetheless give each project its own URL prefix (`s3://bucket/<project>`) as operational hygiene: separate write credentials, rotation/deletion/lifecycle blast radius.
- **ed25519 keys:** the secret is a **32-byte seed** (RFC 8032; sello's `keypair(seed)` derives the public key) — generate with `head -c 32 /dev/urandom | base64`, or extract from an OpenSSL key (`openssl genpkey -algorithm ed25519 -outform DER | tail -c 32 | base64`). The seed goes in the publisher's `$CRISOL_CACHE_SIGN_KEY` (CI secret); the public key(s) go in every consumer's `pinned-key` config. **Never** add `$CRISOL_CACHE_SIGN_KEY` (or `$CRISOL_CACHE_HMAC_KEY`, `$CRISOL_CACHE_TOKEN*`) to any env passthrough; crisol strips `CRISOL_CACHE_*` from child envs at every hermeticity level anyway.
- **Key rotation:** add the new public key to `pinned-key` alongside the old (dual-pinned window), cut publishers over, then drop the old key. Entries signed with the dropped key become misses (self-healing: re-run re-publishes). **ed25519 rotation is incremental; HMAC rotation is a full cold-cache event.**
- **Format bumps:** transparent to a mixed fleet (version is a URL path segment); once rolled, add a lifecycle/expiry rule for `<base>/<old-N>/`.
- **Compromise / poison response:** crisol has no `put`-time poisoning path (the gate + put rule), but a storage-layer compromise is purged **backend-side** (delete the object), or globally via key rotation. A `crisol cache <delete|stat|push>` CLI is a **deferred follow-on** — documented so operators know the manual path.
- **Concurrency one-liners:** two `crisol run`s on one project/host ⇒ exit 3 via the stateDir lock (unchanged); two projects on one host sharing a `file://` L2 ⇒ safe by `<key>.<pid>.tmp` + `rename` (NFSv3+ required for `O_EXCL`); CI matrix shards sharing one L2 publish disjoint subsets; a `file://` L2 on a hung NFS mount has no deadline (use http/s3 for anything non-local).
- **`--shard` × remote:** shard selection determines which entrypoints *reach* the cache lookup; the cache is keyed by `SoundnessKey`, so any shard can hit any entry. A full-coverage warm-up requires a full run or all shards completing.
- **Backup / sizing / monitoring:** an L2 is a cache — never back it up; ~1–5 KB per entry × (entrypoints × distinct keys per toolchain/flag set); a 30-day lifecycle/TTL is a sane default; archive `cacheStats` from run/v2 and alert on `remoteErrors == total`.

## FORK-2 (RESOLVED — (a), 2026-09-03) — the cold-host consult

**Finding (round 3, five lenses; anchors refreshed at HEAD 2026-09-03).** `lookupAtPlan` consults the cache only for `edRunFresh` (`cachedispatch.nim` `lookupAtPlan`'s first guard); `edRunFresh` requires the stable binary to exist *and* a fresh depgraph entry (`planner.nim:166-181` — "binary absent ⇒ cdNeverBuilt"; `:232` — "with an empty graph, every entrypoint is cdNeverBuilt"); and the key's `closureContentHash` is extracted from the nimcache *after* `nim c` (`closure.nim`, the post-run `recordClosure` block at `runner.nim:1528-1551`). So a genuinely cold host (no `<stateDir>/bin`, no depgraph — fresh clone, fresh CI runner, empty `CRISOL_STATE_DIR`) **never consults L1 or L2**, compiles and runs everything, and publishes. The round-2 E2E-1 "passes" only because "delete L1" leaves `bin/` + depgraph intact — it proves the multi-tier waterfall, not host-independence. As specified through round 2, the remote tier serves only hosts that already hold a fresh binary + graph but lack the L1 entry. The locked "dispatch UNCHANGED" item in the handoff was accepted on the belief that cold hosts would hit; that belief was wrong — hence an escalation, not an edit.

**Option (a) — ship the post-compile consult in 0005 (stage A2c, 3 sub-slices).** At the compile→run transition (post-A2b: the spCompiling→spRunning promotion in the poll loop / `transitionToRun`), *before* the run child is spawned: extract the closure from the slot's nimcache + update the graph entry (move the post-run `recordClosure` block at `runner.nim:1528-1551` to run for compiled slots first — a behavior-preserving reorder, A2c-i), derive `d = derive(seams, pep)` from the now-fresh graph and call `seams.load` (A2c-ii, memory seams); on hit: copy the binary to the stable path (preserving the "every `cdmHit` has a stable binary" invariant B3 relies on), synthesize — re-baseline: `run = Phase(pkCached, stored)` **and `compile = Phase(pkRan, compileRes)`** (the compile genuinely ran; `cached` is no longer a stored field, it ≡ `run.kind == pkCached`; `compileSkipped = false`, `cacheDecision = cdmHit`, `cacheTier`; the recompute rule applies here too — a not-passed recompute is `cdmRecomputeMiss` and the run child spawns) — finalize without spawning the run, write no ledger attempt row (the ledger records executions; the RFC-0006 compile-cost row is still written); on miss: spawn the run child as today; trust codes flow to `cacheLookup`. `EntrypointDecision` stays a plan-time sum (the result fields already represent "compiled, run skipped"). A2c-iii = the real cold-host E2E-1 (below). C3c's prefetch must also cover these post-compile keys (`probe` once at plan time over *all* eligible keys; nil-probe tiers pay one bounded GET per compiled entrypoint on that slot's path). Cost: runner hot-path surgery (the poll loop, freshly rewritten onto the Supervisor in 0007 A2b), overlap with RFC-0006's compile machinery, ~3 slices. Payoff: the CI-matrix headline becomes true for the *run* phase on a truly cold host; compile is still paid (the key is a compile byproduct) — and per MEMORY amoxtli is compile-bound, so the realized win there is modest until RFC-0006's nimcache reuse is itself shareable (out of scope).

**Option (b) — rescope 0005 honestly; open the post-compile consult as its own small RFC.** Keep dispatch untouched; the Summary/Motivation already state the honest scope (applied in round 3 regardless of this fork); E2E-1 becomes the "lost-L1, warm-bin" test plus an explicit "cold stateDir ⇒ `cdmNotEligible`, remote never read" negative assertion so nobody mistakes it for cross-host proof; Non-Goals gains "cold-host consult". The follow-on RFC gets its own design pass on the runner's compile→run transition.

**Recommendation:** **(a)**. The liveness standing order is exactly this case — a mechanism whose producer is not on a named slice ships green-but-inert; the post-compile consult *is* the producer of the RFC's load-bearing property, it is first-principles correct (a hit never needs a run; the post-compile key equals the store-key by construction), and its soundness is the same gate. The cost is real (runner surgery) and it is Corey's risk call because it reverses a locked item, so it is surfaced rather than applied. **E2E-1 under (a):** Run 1 in project P1 / stateDir S1 (live, `cdmStored`, entry in L1+L2). Run 2 in a *copy* of the project at P2 with `CRISOL_STATE_DIR=S2`, different cwd: `compileSkipped == false`, `cacheDecision == cdmHit`, `cacheTier == "l2"`, `attempts == 0`, binary now present in `S2/bin`, S2's L1 backfilled. Run 3 in P2/S2: `cacheTier == "l1"`, `compileSkipped == true`. Secondary: delete `S2/cache/v<N>/` only ⇒ `cacheTier == "l2"` again. **Under (b):** the secondary assertion is E2E-1 entire, plus the negative cold-stateDir assertion.

## Hard constraints (every slice respects)

- **`SoundnessKey` = sole content address.** No backend, tier, trust policy, or serializer participates in key derivation. The 9-component `KeyInputs` is untouched by 0005 (0007 A2a-iii already re-homed the rlimit component as `limits: Limits` under `resultCacheFormatVersion` 3; A0's `env-pin` changes the *values* the existing component hashes, not the components).
- **Only a recomputed pass that satisfies the evidence gate on attempt 1 may PUBLISH.** `shouldStore` = `outcome(res) == oPassed` && `evidenceSatisfies(spec, runEvidence(res))` && attempt-1 (rfc-0007 A6a: named guarantees, never enum ordinals — observed escapee ⇒ not stored; `lsFailed` limit ⇒ not stored; `lsUnsupported` ⇒ stored with the honest label; requested `netIso` (`hlNetwork`) ⇒ never stored until RFC-0008 observes). `shouldStore` is unchanged by 0005 and runs *before* `put`; the trust layer only *signs* what the gate already approved; the put rule additionally refuses unattested writes to verifying tiers.
- **Run NEVER blocks on remote.** Deadline per call + per-tier circuit breaker + deferred remote puts; timeout/offline/miss are indistinguishable to the *control* path; verdicts feed observability only.
- **No network or hot-path disk in the test suite.** Boundary tests use the `memory`/`memoryBytes` adapters; http/s3 test against the injected in-memory `HttpFetcher`/fake server; C1b's loopback listener is the single sanctioned socket. `--verify-cache` runs off the hot path.
- **Entrypoint-granularity / binary-opaque identity preserved** ([[boundary-granularity-discriminator]]). No per-test/sub-binary anything; trust signs the opaque `(key, payload-hash)`.
- **`lookupAtPlan`'s decision logic / `shouldStore` / `CacheContext` / `inactiveDecision` unchanged.** The seam re-types to `KeyDerivation`/`CacheLookup`; additive: `EntrypointResult += cacheTier, cacheLookup`; no new `CacheDecision` variant from 0005 (0007's `cdmRecomputeMiss` is carried). (The poll loop changes only under FORK-2 (a).)
- **One on-disk/on-wire format** (`CacheSerializer`), backward-readable by RFC-0004 readers; `resultCacheFormatVersion` bump ⇒ `storageFormatVersion` bump (static assert).
- **Secrets never in config files; resolved once in `api.nim`, then removed from the process env; `CRISOL_CACHE_*` stripped from every child env at every hermeticity level; the cache modules never read env.**
- **A shipped mechanism has a producer slice.** Every flag, KDL key, telemetry event, fixture, and latency mitigation named in this RFC is assigned to a slice in §Stages & slices; "documented optimization" is not a slice.

## Non-Goals (explicit for 0005)

- **Distributed *execution*** (remote workers). `--shard` remains the only run-distribution primitive.
- **Cold-host *compile* reuse.** The key is a compile byproduct; a truly cold host always compiles. (0005 ships the post-compile *run* consult — FORK-2 resolved (a).)
- **Default env pinning** (`HOME`/`PATH`/`USER`…): the `env-pin` knob ships; defaults stay RFC-0004's. **`dep-roots` absolute-path portability** — follow-on.
- **Full Sigstore/Rekor.** ed25519 ships; `SigstorePolicy` type-locked behind `when defined(crisolSigstore)` — no stub.
- **msgpack (or any non-JSON) serializer.** The port exists; only JSON ships.
- **A `crisol cache` introspection/purge CLI.** Poison cleanup is backend-side or via rotation (documented).
- **`TestRecord.msg` redaction before remote publish** (documented consumer contract): crisol is binary-opaque and does **not** filter captured test output before shipping `CachedResult.records` to a shared tier. Teams whose test output may contain secrets/PII must set `cacheable #false`, omit a remote tier for those groups, or not emit sensitive data. (A future `obfuscate-records` tier option is noted, deferred.)
- **History dashboards / OTel span export.** Telemetry is a `TelemetrySink` + summary line + `run/v2` field; rich sinks follow on.
- **Remote-tier eviction/TTL/GC.** A backend concern (S3 lifecycle, server TTL); `--verify-cache` never evicts; local GC stays RFC-0004 A1c (local-fs-internal; `list`/`delete` are not on the port).
- **Select-drained concurrent remote lookups / a configurable remote deadline / SigV4 S3** (follow-on slices; see §Alternatives).
- **Negative-cache / bloom filter for misses** (deferred; see §Alternatives).
- **Cross-host `explainMiss`** (explaining a *remote* miss): the remote is not path-indexed; B1's sidecar explains same-host misses, seeded from remote hits on backfill.
- **Ledger rows for cache hits** (shard-balance freshness under high hit rates): accepted staleness, documented in §Stage C.
- **Per-tier trust policies** (trust is cache-global; per-tier would require backfill to re-sign).
- **Library-level `RunOptions.cacheRuntime` injection** (follow-on once the port survives Stage C; tests use the internal `runTestsWith`).
- **Any per-test / sub-binary feature** (standing crisol Non-Goal).

## Alternatives considered

- **Negative-cache / bloom filter for known-misses.** Would eliminate the per-miss remote round-trip on a cold suite. Deferred: `probe` collapses N lookups to one call where the backend supports it, and the deadline + breaker bound the worst case; a bloom filter adds staleness/complexity for a marginal gain. Reopen if large-suite cold-start latency proves dominant.
- **Select-drained concurrent lookup pass (round 2's B0 (c)).** Rejected for 0005 (round 3): needs a second, incremental HTTP state machine, a new port capability, and a non-blocking TLS path `std/net` does not expose — a round, not a slice. Breaker + probe + honest per-key latency replace it; revisit with measurements.
- **Conditional GET (ETag / `If-None-Match`).** The content-addressed URL makes the key its own ETag; no separate design axis — not implemented in 0005 (nothing calls it), noted for the http adapter.
- **Content-addressed dedup / payload compression over the wire.** The `SoundnessKey` already deduplicates; gzip is an adapter-internal `Content-Encoding` concern, deferred.
- **Single shared integrity-or-trust mechanism.** Rejected: FNV guards *untrusted* tiers where no signature exists; the two layers guard different transports and are reconciled by the recompute-bound canonical hash.
- **Dual on-disk format for local-fs (bare RFC-0004 file for `verify-trust:false`, `StoredEntry` for `verify-trust:true`).** Rejected (round 3): two codecs for one adapter; the superset-with-optional-keys format is backward-readable and single.
- **Closure-local `key → KeyInputs` memo in `realSeams` to avoid re-typing the seam.** Rejected (round 3): hidden state keyed by the value it explains; the seam re-type is one atomic slice and gives the wire entry, the sidecar, and `explainMiss` their inputs honestly.
- **`RunOptions.cacheRuntime` for test injection.** Rejected (round 3): leaks internals into the contracted facade before they have survived Stage C.

## Stages & slices

**Order (round 3): B3 → A0 → A1 → A2a → A2b → B1 → B2a/B2b → A3a → A3b → A3c → [A2c under FORK-2 (a)] → C-dep → C4 → C5a/b/c → C1a → C1 → C1b → C2 → C3a/C3b → C3c → C6.** Every slice leaves the suite green; each is one `/tdd` vertical slice (one agent, one commit). Prereq CLEARED (A7-gate re-baseline): **issue #1** (`SlotState`) landed inside RFC-0007 A2b (commit `96a0598`) — no standalone prereq remains. **Pre-flight before A1 (round 3):** `milpa verify` currently fails (`LOCK-DEP-IDENTITY-INVALID`, stale epoch-1 identity; `_deps/nkdl` is a dangling absolute symlink to the old CAS layout) — run `milpa fetch`, which re-links `_deps/*` as *relative* symlinks; `./dev` must then mount `$PROJECT_DIR` at `$PROJECT_DIR` (`--volume "$PROJECT_DIR:$PROJECT_DIR" --workdir "$PROJECT_DIR"`) so relative CAS links resolve in-container (its "symlinks use ABSOLUTE host paths" comment is now false).

**Definition of done — end-to-end, through `runTests`/the CLI, not a passing unit suite:**
- **E2E-B (observability; lands across B1/B2b/B3):** run 1 live; run 2 with `--cache-stats` shows 1 L1 hit / 0 misses; change a flag, run 3 with `--explain-miss` prints `kcFlags` with prev/curr; change an allowlisted env var, run 4 prints `kcHermeticEnv` naming the variable; `--verify-cache --verify-cache-pct 100` on the nondeterministic fixture reports a divergence and `--verify-cache-strict` exits 1; deterministic fixture ⇒ no event; `--json` keeps stdout parseable.
- **E2E-1 (two-tier `file://`; lands in A3c — form depends on FORK-2, see there):** under (a) the cold-host three-run sequence with a second stateDir/project copy; under (b) the lost-L1 sequence plus the negative cold-stateDir assertion. Both: offline variant (`url` → a regular *file* at the path ⇒ `ENOTDIR` ⇒ run proceeds live, `cacheLookup == "offline"`, the 100 %-error warning fires). Zero network, zero crypto.
- **E2E-A-trust (mock policy; lands in A3b):** two `memory` tiers via `runTestsWith`, mock `TrustPolicy` returning `cvTrustBadSignature` ⇒ live execution, `cacheLookup == "trustBadSignature"`, `cacheDecision == cdmStored`, the rejected entry never served.
- **E2E-2 (a forged entry is never served; lands in C4, repeated in C5b):** two `file://` tiers, `cache-trust { policy "hmac" key-id "t" }`, secret via env, L2 verifying (default). Run 1 publishes an attested entry to L2. **Flip one payload byte in the L2 file and recompute `payloadChecksum`**; delete `S/cache/v<N>/` only. Run 2: `verify` fails ⇒ miss ⇒ live ⇒ `cacheLookup == "trustBadSignature"`, `cacheDecision == cdmStored` (self-heal re-publish), `cacheStats` distinguishes it from a cold miss. Negative control: bare byte-flip ⇒ `cacheLookup == "corrupt"`. C5b repeats under ed25519 with an unpinned second signer (`"trustUnpinnedSigner"`). Also: a no-secret consumer run against the verifying L2 ⇒ `published == 0` for that tier (put rule).
- **E2E-3 (remote over the wire; lands in C3b):** `http`/`s3` remote configured in KDL, driven through `runTestsWith(testRegistry(fakeFetcher))` — hit / miss / offline (breaker trips once) / unauthorized-put / oversized-body paths; `--no-remote-cache` reverts to local-only.

**Fixture/double inventory (built in the slice that first consumes each):** `memory` + `memoryBytes` backends (A1); the controllable mock `TrustPolicy` (A3a); the `ENOTDIR` offline fixture (A3c); the **nondeterministic fixture** (passes attempt 1, diverges on re-run — the inverse of `tests/fixtures/flaky_once.nim`) (B3); the configurable **fake server** behind `HttpFetcher` (status/headers/body/size per call; validates method/Content-Type/auth; `toUnreachable`/`toTimeout` on demand) + a large-`records[]` fixture (C1); the **ed25519 keypair fixture** (fixed 32-byte seeds through sello's `keypair(seed)`: signer + a *second, unpinned* key) (C5a); a `CacheSecrets` env-scrub assertion helper (C3b). Test files grow in place — one `test_cachetier.nim` across A1/A3a, one `test_cachelocalfs.nim` across A2a/B1, one `test_cachetrust.nim` across C4/C5a/b/c, one `test_cachehttp.nim` across C1/C6 — each new test file is a full `nim r` compile in `./dev test`, and sello's field arithmetic is not cheap to compile.

**Stage B first — `--verify-cache` (zero port dependency):**
- [x] **B3a** *(`api.nim` + `runner.nim` + `types.nim`)* pure sampler (seeded, `max(1, …)`) + synthetic-plan builder (`RunPlan(entrypoints: sampled, jobs: 1)`, `pep.retries = 0`) + `execute(recordLedger = false)` knob + `VerifyCache` options object. Unit-tested (sampler vectors; synthetic plan shape; ledger untouched). ✅ 93fe3d1; CI 33807007899 all four legs green (sampleHitIndices in types.nim by the pure-derivation family; buildVerifyPlan in runner.nim beside execute; VerifyCache in api.nim per the RunNarrowing precedent — zero value == noVerify, strict-without-enabled unconstructable; recordLedger gates only the row append).
- [x] **B3b** *(`api.nim` + fixture + integration test)* the post-run pass: `cache = cacheDisabled`, no-op `onResult`, isolated sink, placement after `persistLastRun` and before `releaseLock`, `RunReport.verifyDivergences`, `tekVerifyFail` ⇒ stderr even under `NilSink`. Nondeterministic fixture ⇒ divergence; deterministic ⇒ none; sampled entries take `spawnRunDirect` (asserted). ✅ 4cda363; CI 33813331127 all four legs green (VerifyDivergence carries full stored+fresh Phases for diagnosis; Exit compared via explicit ptypes.== — the generic Option fallback was a real trap; nondeterministic counter-file fixture proves genuine re-execution; lastrun.json untouched by the pass, asserted; tekVerifyFail sink event staged to B2, stderr warning live now).
- [x] **B3c** ✅ 58a9419, CI run 33818574764 green (all four legs) *(`crisol.nim` + `config.nim` + `jsonout.nim`)* `--verify-cache`, `--verify-cache-pct N`, `--verify-cache-seed N`, `--verify-cache-strict` (requires `--verify-cache`, `ExitEnvironment` otherwise), KDL `verify-cache-pct`, `verifyFails` in run/v2 (`schemaRevision` 19 — see A3b for the shared bump), `usage()` + config header. E2E-B verify half.

**Stage A — port skeleton → seam re-shape → end-to-end spine (green throughout):**
- [x] **A0** ✅ f34c1ac, CI run 33823689010 green (all four legs) *(`sandbox.nim` + `config.nim` + `types.nim` + `crisol.nim` + `api.nim`)* `env-pin`: KDL `env-pin "NAME" "VALUE"` (repeatable) + `--env-pin NAME=VALUE` + `RunOptions.envPins`; pins injected in `filterEnv`'s tail and hashed as pinned; `CRISOL_CACHE_*` stripped unconditionally in the same tail. **Key-portability invariance test:** `keyOf` invariant under {stateDir, projectRoot, cwd, TMPDIR value, pinned vars}, varies on an unpinned allowlisted value. `usage()` + header.
- [x] **A1** ✅ 657cbc6, CI run 33828005524 green (all four legs) *(`cacheport.nim` + `cachetier.nim` + `cachewire.nim` + `cachememory.nim` + `resultcache.nim` exports)* port types (`CacheVerdict`+sets, `Fetched`, `StoredEntry`/`SigAlg`/`Attestation`, `CacheBackend`+procs, `TrustPolicy`+`nonePolicy`, `TelemetrySink`+`NilSink`, `canonicalPayload`/`envelopeBytes`), the JSON `CacheSerializer` (superset format, `storageFormatVersion`, FNV recompute ⇒ `cvCorrupt`, embedded `resultCacheFormatVersion` ⇒ `cvVersionSkew`, `keyInputs{To,From}Json`, the static version-coupling assert), `Tier`/`TieredCache`/`TierHit`/`CacheLookup` with single-tier `lookup`/`put`, `memory` + `memoryBytes` doubles. `payloadToJson`/`payloadFromJson`/`canonicalPayload` exported from `resultcache.nim` (`loadCached` calls the shared helper). Boundary-tested over both doubles: roundtrip, miss ⇒ `cvMiss`, checksum-recompute mismatch ⇒ `cvCorrupt`, storage/payload version mismatch ⇒ `cvVersionSkew`, pre-0005 file (no optional keys) decodes.
- [x] **A2a** ✅ 79f7c22, CI run 33831931801 green (all four legs) *(`resultcache.nim` + `cachelocalfs.nim` + `clean.nim:219` caller + `test_resultcache*.nim`/`test_a1c_gc.nim`/`test_c0_clean_stores.nim`)* root-taking helpers (`loadCachedAt`/`storeCachedAt`/`gcResultCacheAt`; stateDir forms delegate); `localFsBackend(root, autoCreate, maxEntries)` over the serializer; offline semantics (`ENOTDIR` ⇒ `cvOffline`); rate-limited store warning. Satisfies the *same* boundary suite as `memory`/`memoryBytes` + the offline case. No `realSeams`/`api` change yet — suite green.
- [x] **A2b** ✅ ea96cc1, CI run 33836393867 green (all four legs) *(atomic: `cachedispatch.nim` + `api.nim` + `cacheregistry.nim` + `tests/support/helpers.nim` + the 4 test files listed in §The spine)* `KeyContext`/`keyContext`/`keyOfProc`; `KeyOfProc → KeyInputs`, `LoadProc`/`StoreProc` → `(pep, KeyDerivation[, res])`, `derive`; `CacheLookup` return; `CacheRuntime{cache, sink}`; `realSeams(ctx, graph, rt)`; `lookupAtPlan` calls `derive` + stamps `d.key`; `api.nim` builds `keyContext(...)` once + `localOnlyCache(stateDir, maxCacheEntries)`; the runner's two call sites pass `pep` + derivation; a test helper wraps the 9 old-shape literals. ALL existing RFC-0004 cache tests green.
- [ ] **B1** *(`keys.nim` + `cachelocalfs.nim` + `cachewire.nim` + `cachedispatch.nim` adapter + `crisol.nim` + `config.nim` + `types.nim` + render)* — split as **B1a** ✅ 99f7add, CI run 33839492789 green (all four legs) — pure `explainMiss` (+`envDigest` names) in `keys.nim`, exhaustively vector-tested (each of 9 components; flag-change; env-name; multi-component; no-diff); **B1b** ✅ 4df3cad (+ 16197ea localFsBackend v-dir fix), CI run 33845701136 green (all four legs) — the path-keyed sidecar under `inputs/` (tier 0 only; seeded on backfill; pruned in `gcResultCache`'s walk; mtime-ordered LRU) + `CacheLookup.explain` attached on miss — local-fs boundary suite; **B1c** `--explain-miss`/`--explain-miss-verbose` + KDL `explain-miss` + component-aware render (multi-line nimVersion rule) + `usage()`/header. E2E-B explain half.
- [ ] **B2a** *(`cachetelemetry.nim` + `cachedispatch.nim` adapter)* `tekHit/tekMiss/tekRemoteErr/tekBackfillErr/tekPublish` emitted by the `realSeams` adapters; `CacheStats` aggregation (L1/remote/miss/remote-errors incl. trust codes/total/notConsulted/%/wall-saved/published/verifyFails) — via `InMemorySink`. **B2b** *(`api.nim` + `jsonout.nim` + `crisol.nim` + `config.nim`)* `RunReport.cacheStats` + run/v2 `cacheStats` (`schemaRevision` 21 — renumbered, see §Contract impacts) + `--cache-stats` + KDL `cache-stats` + summary line (stderr in `--json` mode) + the per-tier 100 %-error warning + `usage()`/header. E2E-B stats half.
- [ ] **A3a** *(`cachetier.nim` only)* multi-tier `lookup`: waterfall + backfill-on-hit + **`verified`-bit backfill rule** + **put rule** + per-tier `verdicts` + `worst` + **circuit breaker** (fake clock) + deferred-put queue, via two `memory` tiers and the **controllable mock `TrustPolicy`**. Exhaustive 2×2×2 backfill matrix + 2×2 put matrix. `cacheregistry.nim`: `BackendRegistry` + scheme-resolved `buildBackend(RemoteTier, token)`; `productionRegistry(fetcher)` (file) / `testRegistry(fetcher)` (+memory/memoryBytes).
- [ ] **A3b** *(`types.nim` + `cachedispatch.nim` + `runner.nim` + `jsonout.nim` + `api.nim`)* `PlanLookup += tier, lookup`; `EntrypointResult += cacheTier, cacheLookup` threaded to the hit stamp (`runner.nim:995-1007`) and the live stamp (`:1326-1356`, new `lookups[i]`); `jsonout` render + `schemaRevision` 19 doc-comment entry; internal `runTestsWith(opts, CacheDeps)`. **E2E-A-trust** through `runTestsWith` with two `memory` tiers + the mock policy.
- [ ] **A3c** *(`types.nim` + `config.nim` + `cacheregistry.nim` + `api.nim` + `crisol.nim` + test_config + E2E-1)* — split as **A3c-i** `CacheConfig`/`RemoteTier` parse (`remote-cache "<name>" { url / verify-trust / backfill-on-hit }` modelled on `parseGroup`; `n.children` makes it trivial) + `test_config`; **A3c-ii** minimal `configuredCache` for the `file` scheme (`verify-trust` default rule; reject `l1` name, root-inside-stateDir) invoked inside the plan `try` before the lock + `--no-remote-cache` + `usage()`/header + **E2E-1** (form per FORK-2).
- [ ] **A2c** *(FORK-2 (a) only — `runner.nim` poll loop (`transitionToRun`) + `closure`/graph update reorder + E2E-1 cold-host form)* — A2c-i behavior-preserving reorder (closure extraction + graph update right after compile), A2c-ii post-compile `derive`+`load` with memory seams (hit ⇒ copy stable binary, synthesize `compile = pkRan` + `run = pkCached`, no run child; miss ⇒ spawn the run child), A2c-iii the three-run cold-host E2E-1.

**Stage C — trust first (file://, zero network), then the network-touching tail:**
- [ ] **C-dep** *(`milpa.kdl` + smoke test)* `milpa add sello --git https://github.com/coreyleavitt/sello.git --ref v0.4.0` + `milpa add nimcrypto --git https://github.com/cheatfate/nimcrypto.git --ref v0.7.3` (bump sello to `v0.5.0` when tagged). No Dockerfile delta (both pure Nim). **Compile-smoke test** against known vectors: RFC 4231 HMAC-SHA256 case; an RFC 8032 §7.1 ed25519 sign/verify vector; **and a closure capturing a `sello.Keypair` built from a fixed seed, invoked twice** (the move-only-capture spike). Gate for C4/C5.
- [ ] **C4** *(`cachetrust.nim` + `cacheregistry.nim` + `config.nim`/`types.nim` for `cache-trust` + E2E-2)* `hmacPolicy` (HMAC-SHA256 via nimcrypto) + the shared `envelope` with its SHA-256 and domain tag; verify-on-read reject-on-fail with granular verdicts; sign-on-put; `cache-trust { policy / key-id }` parse + rejections (hmac without secret; explicit `verify-trust #true` under none); `CacheSecrets` resolved in `api.nim` + `delEnv`. Boundary-tested: HMAC roundtrip; tamper+checksum-fix ⇒ `cvTrustBadSignature`; bare tamper ⇒ `cvCorrupt`; unattested on a verifying tier ⇒ `cvTrustNoAttestation`; wrong `key-id` ⇒ `cvTrustSignerMismatch`; put rule with the real policy. **E2E-2** as acceptance.
- [ ] **C5a** ed25519 `ed25519Policy` via sello (`Option[Seed]` moved in → `keypair` built inside the closure; `kp.sign(envelope)`; `pk.verify` against the pinned set, `signer == base64(pk)`) — sign/verify happy path + no-seed verify-only; `pinned-key` parse + zero-pinned rejection; `SigstorePolicy` type-locked behind `when defined(crisolSigstore)`. (Keypair fixture built here.) **C5b** rejection cases: tamper ⇒ `cvTrustBadSignature`, unpinned ⇒ `cvTrustUnpinnedSigner`, signer-mismatch ⇒ `cvTrustSignerMismatch`, unknown alg ⇒ `cvTrustUnknownAlg`; E2E-2 repeated under ed25519 with the unpinned second key. **C5c** ed25519 × backfill/put rules (the A3a mock replaced by the real policy).
- [ ] **C1a** Dockerfile `libssl-dev` + `-d:ssl` in a project `config.nims`; verify the image builds and `wrapConnectedSocket` links. No adapter logic.
- [ ] **C1** *(`cachehttp.nim` + fake server)* `http` adapter via injected `HttpFetcher` (GET/PUT, `<base>/<storageFormatVersion>/<key>`, `Content-Type`, bearer header, the pinned status table, body cap, put pre-check, total-function) over the A1 serializer. Tested against the fake server (no socket).
- [ ] **C1b** *(`httpraw.nim`)* production `HttpFetcher` — split as **C1b-i** plaintext GET/PUT + Content-Length + connect/recv timeouts + `SO_RCVTIMEO`/`SO_SNDTIMEO` + body cap + EINTR, with **the single sanctioned socket test**: one in-process loopback listener on an ephemeral 127.0.0.1 port covering a 200, a 404, a connect-timeout to a non-listening port, and "TCP accept then silent server ⇒ deadline fires"; **C1b-ii** chunked decoder (pure, vector-tested); **C1b-iii** TLS under `-d:ssl` (manual/out-of-suite).
- [ ] **C2** *(`caches3.nim`)* `s3` adapter (same contract; unsigned/MinIO path-style only; `endpoint`/`path-style`; `probe` via ListObjectsV2 `<Key>` extraction). Tested against the fake (S3 codec + listing).
- [ ] **C3a** *(config)* extend A3c-i: per-remote `endpoint`/`path-style`, scheme validation against `knownCacheSchemes` in `types.nim` (`memory://` ⇒ config error), unsigned-`s3`-without-verifying-policy rejection. **C3b** *(wiring)* `configuredCache` for http/s3 + per-tier tokens + CLI/env override + the child-env `CRISOL_CACHE_*` scrub assertion under `hlNone`. **E2E-3** as acceptance through `runTestsWith(testRegistry(fake))`.
- [ ] **C3c** *(prefetch)* plan-time `probe` when `canProbe` (resolved once; `lookup` consults the probe set before per-key `get`s); per-key bounded `get`s otherwise; `shutdownRequested()` checked in the loop (B0 (c)). Acceptance: call-counting `memory`/fake backend over N synthetic entrypoints ⇒ `probe` 1× and `get` ≤ |keys ∩ probed| (probe branch); N bounded `get`s, breaker trips after the first `cvOffline` ⇒ total wall ≤ one deadline + ε (offline branch).
- [ ] **C6** secure-by-default credential scopes end-to-end: read vs write tokens; publish iff write-credentialed (`cvUnauthorized` `put` ⇒ no-op, reads still serve); secrets from env only. Tested against the auth-validating fake server (folds into `test_cachehttp.nim`).

(Remote GC/TTL out of scope; local GC stays RFC-0004 A1c inside the local-fs adapter.)

## Testing strategy

Boundary tests at the `CacheBackend` port via `memory`/`memoryBytes`: waterfall, backfill-on-hit, **`verified`-bit backfill** (exhaustive 2×2×2, via the controllable mock policy), **put rule** (2×2), trust verify+reject, miss→next-tier, offline→`cvOffline` + breaker, the publish gate (unchanged — re-assert `shouldStore` still gates `put`). `explainMiss` pure ⇒ exhaustive `KeyInputs`-diff vectors incl. flag-change and env-name cases. ed25519 sign/verify roundtrip + tamper + unpinned + signer-mismatch + backfill/put interaction. `--verify-cache` divergence via the nondeterministic fixture; determinism ⇒ no event; ledger untouched. http/s3 against the injected in-memory `HttpFetcher`/fake server — **no real network, no hot-path disk**. RFC-0004's direct `loadCached`/`storeCached` tests fold into the `local-fs` adapter's boundary suite. C1b's loopback test is the single sanctioned socket. Per [[dev-test-verification-gotchas]]: `./dev test` EXIT is unreliable — grep output (and have every E2E test emit an explicit success marker), excluding the expected-failure fixtures. Suite-runtime discipline: grow test files in place (§Fixture inventory) — each new file is a full compile.

## Contract impacts

- **Schemas:** `crisol/run/v2` gains, additively: per-result `cacheTier` + `cacheLookup` (rev **19**, A3b; B3c's `verifyFails` rides the same rev), per-result `keyDiff[]` present only under `--explain-miss` (rev **20**, B1c — renumbered from 21: revisions are monotonic in landing order and B1 lands before B2), `cacheStats` `{l1Hits, remoteHits, misses, remoteErrors, total, notConsulted, hitPct, wallSavedMs, published, verifyFails}` (rev **21**, B2b — renumbered from 20). Each rev is appended to `jsonout.nim`'s documented list (the current revision is **18** — 16 = the v2 cutover, 17 = `recomputeMiss`, 18 = the `substrate` node). **No new `CacheDecision` variant from 0005** (0007's `cdmRecomputeMiss` is carried on the wire as `"recomputeMiss"`). amoxtli keeps `cacheDecision` as a free string and flags `newerSchema`, and its `run/v2` consumer is exercised against real `crisol run --json` output in 0007's A7-gate — additive fields are safe. No `v3`.
- **CLI additions:** `--no-remote-cache`, `--explain-miss`, `--explain-miss-verbose`, `--verify-cache`, `--verify-cache-pct N`, `--verify-cache-seed N`, `--verify-cache-strict`, `--cache-stats`, `--env-pin NAME=VALUE`. All additive; default is identical to RFC-0004. In `--json` mode all human lines go to stderr.
- **Config additions (flat, top-level):** `remote-cache "<name>" { url / endpoint / path-style / verify-trust / backfill-on-hit }` (repeatable), `cache-trust { policy / pinned-key / key-id }`, `cache-stats`, `explain-miss`, `verify-cache-pct`, `env-pin`. Additive; absent ⇒ single-tier local. Parsed types live in `types.nim`.
- **Env:** `$CRISOL_CACHE_SIGN_KEY` (ed25519 seed, base64), `$CRISOL_CACHE_HMAC_KEY`, `$CRISOL_CACHE_TOKEN` / `$CRISOL_CACHE_TOKEN_<TIER>` — resolved once in `api.nim` into `CacheSecrets`, then `delEnv`'d; `CRISOL_CACHE_*` stripped from every child env. Secrets never in config files. (`AWS_*` arrives with the SigV4 follow-on.)
- **New wire-format axis:** `storageFormatVersion` (the `StoredEntry` envelope) — distinct from and coupled to `resultCacheFormatVersion` (static assert). The on-disk L1 file is a backward-readable superset of RFC-0004's.
- **`realSeams` signature** becomes `realSeams(ctx: KeyContext; graph: ptr DepGraph; rt: CacheRuntime)`; **`KeyOfProc` returns `KeyInputs`; `LoadProc`/`StoreProc` take `(pep, KeyDerivation[, res])`; `LoadProc` returns `CacheLookup`** (internal plumbing; the 4 test files update atomically in A2b via a helper). `CacheSeams`'s three-closure shape, `lookupAtPlan`'s decision logic, `shouldStore`, `CacheContext`, `inactiveDecision` unchanged. `execute()` gains `recordLedger: bool = true`. (The runner's compile→run transition changes only under FORK-2 (a).)
- **Library facade** (`crisol/api`): `RunOptions` gains `noRemoteCache`, `explainMiss`, `cacheStats`, `verifyCache: VerifyCache` (constructor-built), `envPins`; `RunReport` gains `cacheStats` + `verifyDivergences`; `EntrypointResult` gains `cacheTier` + `cacheLookup`. Additive. **No `RunOptions.cacheRuntime`** (internal `runTestsWith` instead).

## Dependency decision (FORK-1 — RESOLVED 2026-08-21; C-dep simplified round 3)

**Context.** Nim's stdlib has no SHA-256, no HMAC, and no ed25519; crisol depended only on `nkdl`. At round 1 the ecosystem had no pure-Nim ed25519, so "ed25519 NOW" implied an FFI + Dockerfile + unaudited-C trust tax. That premise changed: **sello** (Corey's sibling library) provides pure-Nim ed25519 sign + verify with zero runtime dependencies, validated against RFC 8032/Wycheproof/NIST CAVP/libsodium-differential suites.

**Decision (Corey, 2026-08-21):**
- **(b) ed25519 source = sello** — pure Nim, no FFI, no Dockerfile delta. **Round 3:** `v0.4.0` is already tagged and pushed with the full needed surface, so crisol pins **`v0.4.0` by git ref** (janus already pins sello this way) and bumps to `v0.5.0` when Corey tags it; the round-2 `local="../sello"` pin + generic `./dev` sibling-mount is retired (a local pin is needed only if the C-dep smoke test finds v0.4.0 insufficient).
- **(a) HMAC-SHA256 source = nimcrypto `v0.7.3`** (pure Nim; already in the milpa CAS as sello's own dependency). `hmacPolicy` ships alongside `ed25519Policy`. An in-house HMAC-SHA256 may replace nimcrypto later behind the same call sites — sello deliberately does **not** export a hash.
- **(c) Initial S3 = unsigned/MinIO path-style** (no SigV4). Authenticated S3 via SigV4 is a follow-on reusing the C-dep HMAC-SHA256; the `http` adapter with a bearer token covers authenticated remotes in 0005.

**Consequences:** crisol's dependency set becomes `nkdl` + `sello` + `nimcrypto`. Slice C-dep is two `milpa add` lines + a smoke test. C4 before C5 (HMAC is the simpler policy and exercises the shared canonical envelope first). **Open forks: FORK-2 only.**
