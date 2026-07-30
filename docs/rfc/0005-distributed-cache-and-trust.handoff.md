# RFC-0005 — Distributed result cache + cryptographic trust & cache observability — handoff

- **Stage:** 2 (architect rounds) — RFC doc + slices DRAFTED + **round 1 APPLIED** (`0005-distributed-cache-and-trust.md`; slices A1/A2a/A2b/A3/A4, B1–B3, C0/C-dep/C1a/C1/C2/C3/C4/C5a/C5b/C5c/C6). **BLOCKED on FORK-1 (crypto deps) — awaiting Corey** (asked, user wants to clarify the options first).
- **Resume:** resolve FORK-1 (crypto-dependency strategy — see Open forks), then Stage 2 round 2: `/architect docs/rfc/0005-distributed-cache-and-trust.md round 2` (round 2 of 2 required before any /tdd). Stages A+B are unblocked regardless of FORK-1.
- **Artifact:** this RFC = `docs/rfc/0005-*.md` + this handoff (per /rfc-flow convention; NO GitHub issue — #2 was an /architect-Step-6 leak, closed).  •  **Prereq (do first, independent):** issue #1 (`SlotState` enum dispatch hardening) — a legit standalone refactor issue.
- **Origin:** came from `/architect` feature-frontier exploration (codebase mode) after RFC-0004 shipped (commit `87994fc`, branch `rfc-0004-incremental-hermetic-execution`, pushed — PR not yet opened/merged).

## DECIDED DESIGN (Corey's selections — locked)
Architect ran 4 competing interface designs (Minimal / Flexible / Ergonomic / Ports-and-Adapters). Corey chose, with full over-engineering risk disclosed:
1. **Architecture = FULL FLEXIBLE** (not the hybrid I recommended) — pluggable registry + multi-tier + pluggable serializer/telemetry, BUT executed at the bar = built on the Ports design's clean boundary contract + **phased green migration**, with the Flexible agent's self-corrections folded in.
2. **Trust = ed25519 signed attestation NOW** (not just HMAC) — ports for none/HMAC/ed25519; verify-on-read; sign-on-publish.
3. **Scope = A + core B together** (matched my rec) — remote cache + miss-explanation + hit-rate + `--verify-cache`; defer dashboards/attestation-dashboards.

### Architecture (ports-and-adapters, dispatch UNCHANGED)
- **`CacheBackend` port** — closure-field object (zero-cost, matches existing `CacheSeams` idiom, NOT vtable/method): `get(key)→Option[StoredEntry]`, `put(StoredEntry)→bool`, optional `list`/`delete`. NEVER raises; `none`/`false` on miss/corrupt/version-mismatch/timeout/offline.
- **`StoredEntry` wire type** — `{key: SoundnessKey, keyInputs: KeyInputs (for explain; adapters MAY omit on disk), result: CachedResult, payloadChecksum, formatVersion, attestation: Option[Attestation]}`. `Attestation = {sigAlg, signer, signature, signedAt}`.
- **`TrustPolicy` port** — `verify(entry)→bool` (on-read), `sign(var entry)` (on-put). Adapters: `nonePolicy` / `tokenPolicy`(HMAC-SHA256) / `signedPolicy`(**ed25519**, sign-on-put, verify-against-pinned-pubkeys). Sigstore/Rekor adapter STUBBED behind `when defined(crisolSigstore)`.
- **`TieredCache`** — composes `seq[TierConfig{backend, populateOnHit, requireTrust}]` L1→L2→L3. `get`: waterfall, verify-trust on requireTrust tiers (fail→try next, never serve bad entry), populate-on-hit backfill earlier tiers **— backfill must respect the STRICTEST trust policy of any tier that will serve the entry** (correctness subtlety). `put`: sign once, write all tiers best-effort. Remote tiers wrap their own deadline; L1 sync no-timeout.
- **`BackendRegistry`** — `registerBackend(name, factory)`; adapters = one file + one registration. Ship: `memory`(test), `local-fs`, `http`, `s3`; `crisol-server` future.
- **`CacheSerializer` port** — JSON only ships (msgpack deferred but port exists). **`TelemetrySink` port** — NilSink default; LogSink/InMemorySink(tests).
- **Wiring:** `realSeams(tc: TieredCache, ...)` builds `CacheSeams.load`=`tc.get` / `store`=`tc.put`. **`lookupAtPlan`/`shouldStore`/`CacheContext`/`inactiveDecision` byte-for-byte UNCHANGED.** Publish gate unchanged (`isFullyAchieved && attempt-1 pass` in `shouldStore`, before trust layer ever sees a write).

### Core B (observability/trust UX)
- **Miss-explanation:** `explainMiss(prev, curr: KeyInputs)→seq[MissDiff]` (PURE; diffs the 9 components). Mechanism: write a `KeyInputs` SIDECAR keyed by the **identity** key (stable locator; soundness key changed = the miss) so a miss can name which of {closureContentHash, flagHash, nimVersion, ccVersion, fixtureHash, argv, rlimitConfig, hermeticEnvHash, protocolMajor} changed. `--explain-miss` flag + degrades gracefully if no sidecar (older writer).
- **Hit-rate telemetry:** summary line (L1 hits / remote hits / misses / total / % / wall-saved / published) + `run/v1` field. Aggregate existing `CacheDecision` (already per-result; RFC-0004 made it 8 honest variants incl `cdmStored`/`cdmGroupOptOut`/`cdmHit`).
- **`--verify-cache`:** re-run sampled cache hits, compare to cached result, flag nondeterminism the hermeticity gate can't catch. **Runs as a POST-RUN BACKGROUND re-check, NOT in the hot path** (self-review correction). Never evicts (human decision); emits a verify-fail telemetry event.
- Config (KDL `cache { remote "name" { backend / trust { ... } / scope-group } telemetry { hit-rate / explain-miss / verify-cache-pct } }`) + flags `--no-remote-cache`, `--explain-miss`, `--verify-cache`. CLI/env override config. **Secure-by-default**: read tokened; publish requires write-scoped credential (never a `--publish` flag).

### Hard constraints (every slice respects)
Soundness key = SOLE content address; only `isFullyAchieved && attempt-1 pass` may PUBLISH; local L1 stays, run NEVER blocks on remote (timeout/offline → miss, proceed); ports-and-adapters so tests use in-memory backend (NO network in suite); entrypoint-granularity / binary-opaque identity preserved (see [[boundary-granularity-discriminator]]).

### Deferred (explicit non-goals for 0005)
History dashboards / OTEL export (follow-on); full Sigstore/Rekor (ed25519 ships, Sigstore stub); msgpack serializer; distributed *execution* (still `--shard`); any per-test/sub-binary feature.

### Self-review corrections to BAKE IN (from the Flexible agent's own critique)
1. `CacheSerializer` port present but JSON-only ships (don't build msgpack speculatively).
2. `SigstorePolicy` type locked but impl behind a build guard (no shipping empty stub).
3. `--verify-cache` = post-run background re-check, NOT hot-path latency.
4. Per-tier trust backfill: enforce backfill only when source trust ≥ destination tier's policy (strictest wins).
5. Reconcile the remote-fetch "future" with the runner's ACTUAL concurrency model — do NOT hand-roll a competing async primitive (the runner is fork/poll-loop based; remote I/O likely a bounded background thread or sync-with-deadline).

## Implementation Path / candidate stages (refine into slices in the RFC doc)
- **Prereq:** issue #1 `SlotState` (separate, first).
- **Stage A — port skeleton (green throughout):** A1 port types (`cacheport.nim`: CacheBackend/StoredEntry/TrustPolicy/TieredCache) + in-memory adapter, roundtrip test. A2 wrap local-fs as first adapter; `realSeams` → single-tier TieredCache; ALL existing tests green. A3 point `gcResultCache`/`cleanOrphans` at `backend.list/delete`.
- **Stage B — observability:** B1 `KeyInputs` sidecar + `explainMiss` (pure) + `--explain-miss`. B2 hit-rate telemetry (TelemetrySink, summary line, run/v1 field). B3 `--verify-cache` (background re-exec compare).
- **Stage C — remote + trust:** C1 HTTP/S3 adapter + BackendRegistry (in-process fake-server test). C2 TieredCache L1+L2 wiring in api.nim, config (KDL `cache { remote }`), populate-on-hit + strictest-trust backfill. C3 TrustPolicy port: none/HMAC. C4 ed25519 signedPolicy (sign/verify/tamper-reject/pinned-keys). C5 secure-by-default token scopes + offline-tolerance hardening.
(Sequence A→B→C so each leaves the suite green; B can interleave; C is the network-touching tail.)

## Testing strategy
Boundary tests at the port via in-memory adapter (tier waterfall / populate-on-hit / trust verify+reject / miss→next-tier / offline→miss / publish gate). `explainMiss` pure → exhaustive KeyInputs-diff. ed25519 sign/verify roundtrip + tamper-reject + strictest-trust backfill. `--verify-cache` divergence via nondeterministic stub. Fold old `loadCached`/`storeCached` direct tests into the local-fs adapter boundary tests. **No network/disk-hot-path in the suite.**

## Process reminders (carried from RFC-0004)
- Build/test ONLY via `./dev` (podman); `./dev test` EXIT code UNRELIABLE — grep for `[FAILED]`/nimble-exception excluding `fail_always`/`fail_compile`; report `[OK]` count. `./dev check` for type-check. See [[dev-test-verification-gotchas]].
- Serial sonnet subagents for slices, ONE `./dev` builder at a time (concurrent-./dev race bit us in RFC-0004). Don't run my verification concurrently with a building agent.
- Commit/push ONLY when Corey asks; commit msg ends `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` (global hook strips it; verify `git log -1 --format=%B | grep -i Co-Authored-By` empty). No worktree isolation ([[git-hooks-worktree-isolation]]). No milpa.
- [[no-fake-forks-soundness]]: don't dress first-principles-correct (esp. soundness/security) decisions as forks.

## Architect round 1 — DONE (applied to RFC doc)
4 lenses (depth/breadth/design/feasibility) ran. ~25 clear-best fixes applied. Convergent central fix: `TieredCache.get`→`getWithProvenance` returning `TierHit{result,tierName,tierIndex,verified}` (3 lenses independently); sink moved off TieredCache onto the realSeams adapter; `CacheDecision += cdmTrustFail`; `EntrypointResult += cacheTier`. Trust: signer-in-signed-envelope + recompute-checksum-on-read + signedAt-never-signed; multi-signer/rotation/HMAC-caveat documented. verify-cache: cacheDisabled+retries0+synthetic-plan+user-visible+strict-flag. Backfill: real `verified` bit, A3 tested via injected mock policy (nonePolicy can't exercise the security case). Naming: KeyComponent/kc, backfill-on-hit/verify-trust. Config: URL-scheme selects adapter (dropped redundant `backend`). Added: remote-error telemetry, operator/deployment section, Alternatives-considered, secrets-in-records non-goal, path-keyed sidecar (so flag-change misses are explained). Re-slice: A2→A2a/A2b(atomic, updates test_cachedispatch+test_api callers), C5→C5a/b/c, +C-dep +C1a, HttpFetcher seam.

## Open forks (awaiting Corey)
- **FORK-1 (crypto deps) — BLOCKS STAGE C ONLY; A+B proceed.** Nim stdlib has NO SHA-256/HMAC/ed25519; crisol deps = only `nkdl`.
  - **VERIFIED this session:** `nimcrypto` (pure Nim, no FFI; `hmac.nim`+`sha2.nim`) is already in milpa CAS (`sha256:03ace9e6…`) — HMAC-SHA256/SHA-256 is a clean pure-Nim `milpa add`. **No pure-Nim ed25519 exists** anywhere (CAS or ecosystem): only FFI wrappers around orlp's C — `niv/ed25519.nim`, `MerosCrypto/mc_ed25519` (archived 2021). `adelq/nim-ecdsa` is pure-Nim but ECDSA, not EdDSA.
  - **EMERGING SHAPE (Corey leaning in; NOT yet locked — I asked, awaiting final yes):** ship **HMAC-only trust (pure nimcrypto) in 0005**, covers near-term closed-CI; **defer ed25519 `signedPolicy` to a follow-on** (slot in behind the existing `TrustPolicy` port = zero architecture change).
  - **KEY TECHNICAL INSIGHT (drives the follow-on shape):** sign & verify are independent impls of RFC 8032 → split them. **Verification touches NO secret → no constant-time requirement at all → fully ownable + Wycheproof-testable to a high bar → pure-Nim verifier ships to ALL consumers (the common read path = 100% pure-Nim, no FFI), and fills a real ecosystem gap.** **Signing** holds the secret scalar → CT-sensitive + carries the unaudited-crypto trust tax → use an **FFI signer adapter (libsodium) behind a build flag** (e.g. `-d:crisolLibsodium`), OR build pure-Nim signer with the CT pragma toolkit if Corey wants the yak.
  - **CT-in-Nim is achievable (corrected a misstatement):** the cc-optimizer CT risk is shared by careful-C-via-FFI too (libsodium's edge is maturity/CT-validated-build/asm, not language). Nim-specific surface closes with `{.push checks:off.}` + stack-only fixed `array[uint64]` (no seq/string/GC → orc moot) + arithmetic-masked CT selects + `{.emit.}`/volatile barriers + `{.noinline.}`. Residual = cross-µarch dudect validation (research-grade tail) + social trust tax — both SIGNING-ONLY.
  - **Possible follow-on:** standalone `nim-ed25519` yak project (pure-Nim verifier to Wycheproof bar + optional pragma-hardened signer + FFI fallback adapter). Separate from crisol.
- **Resume after FORK-1 locks:** finalize Stage C slices per the decision (if HMAC-only: C-dep = just `milpa add nimcrypto`; drop C5a/b/c to follow-on; decide S3 auth — MinIO/unsigned-first vs SigV4), then `/architect docs/rfc/0005-distributed-cache-and-trust.md round 2` (round 2 of 2 required before /tdd).
