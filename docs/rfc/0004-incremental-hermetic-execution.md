# RFC-0004 — Incremental, hermetic, observable execution

**Status:** Implemented — closed: 27-slice build, review to floor (3 rounds, 0 critical/high), merged to main; follow-ons reconciled
**Depends on:** RFC-0001 (runner + impact analysis), RFC-0002 (scheduling + config), RFC-0003 (library facade)
**Scope owner:** Corey

## Summary

crisol already computes, per test entrypoint, a **`closureHash`** — an FNV-1a fold over the *contents* of every source file the entrypoint transitively imports (extracted from the Nim compiler's own nimcache JSON). Today that hash is spent only on **compile**-avoidance (`cdSkipFresh`). This RFC spends the same machinery on **execution**: it turns crisol from a *selection* tool (run the affected) into an *incremental* engine (skip the provably-unchanged), in the architectural class of `cargo-nextest`, Bazel/Buck2 `test`, and `go test` caching — while staying strictly a **layer-3 runner** (assertion-agnostic, binary-opaque; see `MEMORY.md` → boundary-granularity-discriminator).

Everything here operates at **entrypoint-binary granularity**. Sub-binary control (per-test selection/retry) is a Non-Goal — that is the layer-2-crossing concern (candidate #4) we deliberately exclude.

## Motivation

- A no-op `crisol run` today recompiles-skips but **re-runs every test**. The dominant cost on a clean tree is re-running passing tests whose inputs did not change.
- crisol's `--changed` narrows *what is selected*; it does nothing for the default full run, and nothing to skip an entrypoint that *would* be selected but is provably unchanged.
- crisol has **no retry, no flake handling, no OS-level isolation, no CI-native output, no historical telemetry**. These are table-stakes for `nextest`/Bazel-class runners and are all layer-3, runner concerns — they accrue to *every* consumer suite lib (std/unittest via `unittest_shim`, proptest, any future suite lib) at once.
- The unifying observation: **caching, retry, prioritization, and telemetry all want one persistent store** keyed on test identity and input fingerprint. Build that substrate once; everything else is a tenant.

## The spine (dependency order)

```
F1  results-history store  ──┬──────────────┬───────────────┬──────────────┐
   (ExecutionCache +         │              │               │              │
    RunLedger, two modules)  │              │               │              │
F2  hermetic execution ──► F3 caching     F4 reliability   F5 CI ergo     F6 observability
   (defines the env         (gated on      (flake ledger,  (JUnit, shard, (telemetry,
    fingerprint that         F2's *achieved* retry,         prioritize     perf-regression
    makes F3 sound)          hermeticity)   quarantine)     from history)  from history)
```

**Soundness coupling (the load-bearing invariant):** a result cache is sound only if a test's outcome is a pure function of its captured inputs. Ambient env, scratch filesystem, wall-clock, resource ceilings, and network are uncaptured inputs. **F2 makes the input set explicit and bounded** (env allowlist, isolated tmpdir/cwd, *config-declared* resource limits); **F3 caching is therefore only offered when F2's hermetic environment was actually achieved** (not merely requested — see Degradation). **Honesty about the limit (round 2):** caching assumes determinism *given the captured inputs*. The retry rule (F4) detects only *observed* flakiness (a pass on attempt > 1); a test that is nondeterministic but happens to pass on attempt 1 will still be cached. Groups with known nondeterminism (deliberate unseeded randomness, real-time dependence, in-place golden-file mutation) **must** set `cacheable #false` — this is a documented *consumer* contract, not something crisol can police.

## Keys: identity vs soundness (read this before F1)

Two distinct keys, kept separate (round 1 fix — the original single XOR-folded "fingerprint" conflated three concerns and reintroduced a self-cancelling hash). Both are `distinct string` types declared in **`types.nim`** (the shared-types home everything already imports, so neither store nor planner gains a new dependency edge):

```nim
type
  IdentityKey*  = distinct string   ## (path, flagHash) — stable locator; the RunLedger primary key
  SoundnessKey* = distinct string   ## chained-FNV content fingerprint; the ExecutionCache key
```

- **Identity key** = `(entrypoint path, flagHash)` — stable across env/version changes. A test's history is indexed by *who it is*, not by a point in content-space.
- **Soundness key** (the cache key) = a **chained FNV-1a** fold (NOT XOR — XOR is commutative and self-inverse, so `A ⊕ A = 0`; `depgraph.closureContentHash` already abandoned XOR for exactly this reason) over, in fixed order with a NUL separator between each, with **each variable-length component placed last within its own per-component `fnv1a64` call** so embedded NUL bytes in binary fixture content cannot alias a separator (round 2 — preserve this argument order in any refactor):
  1. `closureContentHash` — **read from `DepGraphEntry.closureHash`** for the entrypoint. (`planner.decideCompile` recomputes-and-validates this at plan time before returning `cdSkipFresh`, so the graph value is already proven current for the only entrypoints eligible for a cache hit. Do not recompute in the key path.)
  2. `flagHash` — compile flags (existing).
  3. `nimVersion` — Nim compiler version (existing).
  4. `ccVersion` — C compiler + libc version (`cc --version` first line ⊕ `ldd --version` first line). Captures the toolchain/runtime that `nimVersion` alone misses (a `glibc` upgrade can change stdlib behavior). **Effectful** — probed once at startup, cached, and injected (mockable) into key derivation; see slice A2-pre.
  5. `fixtureHash` — content-hash of the per-group `fixtures` glob set (golden/testdata files NOT in the Nim import closure). Empty-glob ⇒ sentinel constant. **Read-only fixtures only** — a test that mutates a golden file in place must set `cacheable #false`.
  6. `argvHash` — the exact `argv` the binary is invoked with.
  7. `rlimitHash` — the **requested, config-declared** rlimit tuple (`RLIMIT_AS`, `RLIMIT_CPU`, `RLIMIT_FSIZE`, `RLIMIT_NOFILE`), hashed at *plan time* from config constants (NOT what the kernel ultimately clamps to — see the cache gate, which voids the write if the achieved sandbox ≠ requested). A pass under one ceiling is not a pass under another, so the ceiling is an input.
  8. `hermeticEnvHash` — the env allowlist *names and values* (excluding `TMPDIR`, whose value carries a per-run random `mkdtemp` suffix and must not enter the key).
  9. `protocolMajor` — NDJSON protocol major version.
- **Derivation lives in `keys.nim`** (imports `types` + `depgraph`; sits one import above the stores and below the planner — no cycle). `RunLedger` stores the soundness key as an **opaque `string`** (it never interprets it), so `ledger.nim` does not depend on `keys.nim`.
- **Wire/JSON name:** in `crisol/run/v1` output and the API surface this value is called **`inputHash`** ("the hash of this test's inputs") — `SoundnessKey` is the internal Nim identifier only.
- **Schema version is NOT in either key.** `resultCacheFormatVersion` / `historyFormatVersion` live in each store file's header and are checked at deserialization (discard-on-mismatch), exactly as `DepGraphFormatVersion` already works. Mixing it into the key would cold-bust every entry whose *data* is still compatible.

## Features

### F1 — Results-history store (the substrate): two modules, not one

Round 1 fix — the original "two access patterns, one home" framing hid a real structural split. These are two modules with different access patterns, write patterns, and GC strategies; F1 is the coordinator that imports and wires both.

**`ExecutionCache` (`resultcache.nim`)** — content-addressed key-value: `SoundnessKey → CachedResult`.
- `CachedResult` = `(outcome, exitCode, signal, durationMs, records, cachedAt: int64, payloadChecksum)`.
- **On-disk layout:** one file per key — `<stateDir>/cache/v<fmt>/<soundnessKey>.json`. A directory of per-key files is naturally concurrent-safe across CI-matrix invocations: two invocations storing *different* keys never conflict; two storing the *same* key are idempotent (same inputs ⇒ same result) so last-writer-wins via `rename(2)` is correct.
- **Integrity:** each file carries `payloadChecksum` (FNV over the serialized payload). Checksum mismatch ⇒ treat as a **miss**, not an error. Stale `.tmp` files removed before write (existing depgraph pattern).
- **Interim soft cap (round 2 — GC is deferred to A1c, far out):** until A1c lands, on write, if the cache directory exceeds `maxCacheEntries` (default 10 000, configurable), skip the write and warn. This bounds inode/directory growth without blocking execution. (A 200-entrypoint suite × many `flagHash` branches × weeks easily exceeds 100 K files otherwise — `ext4` `readdir`/`unlink` degrade past ~100 K dir entries.)

**`RunLedger` (`ledger.nim`)** — append-only time-series, primary key = identity `(path, name?)`.
- Row = `(timestamp, inputHash, outcome, attempt, durationUs, rssBytes, rowVersion)`.
- **Storage = per-process shard files (round 2 — replaces the original single-file `O_APPEND` design, which was unsound here).** Each `crisol` invocation writes its rows to its own shard `<stateDir>/ledger/<pid>-<bootId>.ndjson`; reads concatenate all shards. *Rationale:* POSIX guarantees inter-process append atomicity only for **pipes**, not regular files — on rootless-podman overlayfs and WSL2 (crisol's actual platforms) concurrent multi-invocation `O_APPEND` to one file tears rows. Per-process shards eliminate cross-process contention entirely (no shared file), isolate corruption (a torn row in one shard never poisons another), need no lock, and match crisol's hand-rolled hardened-IO aesthetic with **no new dependency**. (SQLite/WAL was considered and rejected: it solves concurrency/range-scan/recovery but adds a `libsqlite3` toolchain dependency and is over-engineered for a history queried once per run at hundreds-of-rows scale. Reopen only if ledger scale ever dwarfs that.) The in-process writer remains the single-threaded `execute()` poll loop; rows are written with a raw `posix.write` partial-write loop (not buffered `writeLine`).
- **Corruption-resilient reads (round 2):** a malformed row (parse error, truncated final line, unknown `rowVersion`) is **skipped with a warning**; it never aborts the scan. A `historyFormatVersion` mismatch in a shard header triggers discard of that shard (consistent with `ExecutionCache` whole-file discard).
- Range-scan by identity over time (for `--order`, balanced sharding, perf-regression). Knows nothing about cache-key semantics — it stores `inputHash` as opaque data.

**GC (deferred slice A1c):** `crisol clean` extends to prune the cache (age/size-bounded LRU) and **compact the ledger shards** into a single segment (also the moment O(N) read cost is bounded); `clean --all` removes both. GC coordinates with active runs through the existing `lock.nim` (`fcntl F_SETLK` idiom): it refuses to evict/compact entries written in the current epoch while a run lock is held. (Before A1c, `crisol clean` simply `removeDir`s the store directories.)

### F2 — Hermetic execution (the soundness precondition)

A resolved `Sandbox` spec, threaded into the existing `forkExec` child path (which already does async-signal-safe `setpgid`/`dup2`/`close`/`execvp` and builds the full `envp` pre-fork). Hermeticity **levels** (monotone — each is a strict superset of the one below):

- `none` — today's behavior (full env inherited, parent cwd, no limits).
- `isolated` *(renamed from `resource`; **the default** — see Resolved defaults)* — in the forked child, before `execvp`, async-signal-safe:
  - **rlimits** — **config-declared constants only** (round 1 fix: never seed `RLIMIT_AS` from the dynamic admission estimate — it varies run-to-run, poisoning the cache key, and a 512 MiB default will SIGSEGV Nim's ORC GC before `main`). `RLIMIT_CORE = 0`, `RLIMIT_NOFILE`, `RLIMIT_FSIZE` (≥ `maxOutputBytes`) are safe deterministic defaults. `RLIMIT_CPU` (wall-timeout backstop) and `RLIMIT_AS` (memory ceiling) default **unset**; when configured they are constants that enter `rlimitHash`, with a documented safe minimum for `RLIMIT_AS` (well above ORC's own arena needs). Verify each `RLIMIT_*` constant is in Nim's `std/posix` bindings; `importc` any that are missing.
  - **isolated tmpdir** — a per-entrypoint scratch dir (a *second* tmpdir beside the existing per-slot `crisol_slot_*` dir; the `Slot` struct grows a `testScratchDir` field, cleaned on all paths); `TMPDIR` points at it; removed after. `chdir` into it is **opt-in, default off** (round 1 fix: a default `chdir` silently breaks tests that open fixtures at compile-time-relative paths).
  - **env allowlist** — child receives only an allowlisted env. The allowlist *defines the env input set* and is what `hermeticEnvHash` hashes (excluding `TMPDIR`'s per-run value). **Default allowlist (published, not "generous"):** `PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_*`, `TERM`, `TZ`, `TMPDIR`, plus Nim/runtime: `NIMBLE_DIR`, `NIM_CONFIG_DIR`. Configurable passthroughs append to this set. **crisol-injected vars (`CRISOL_SINK`, `CRISOL_ATTEMPT`, `TMPDIR`) are appended *after* the allowlist filter and are never scrubbed** (round 2 — they are not user-controllable passthroughs; the filter must not drop them). The `CRISOL_SINK` socket/path must live under the scratch tmpdir so `RLIMIT_FSIZE`/`RLIMIT_NOFILE` don't strangle structured output.
- `network` *(opt-in only)* — adds `unshare(CLONE_NEWNET)` + loopback to `isolated`. Requires user-namespace/`CAP_NET_ADMIN`; **expected to degrade on standard rootless-podman** (no `CAP_NET_ADMIN`, user-ns often disabled) — that is the designed-for path, and its tests assert *degradation*, not success.

**Degradation & the achieved-vs-requested distinction (round 1 + 2):** like the existing mem-probe, an unavailable control no-ops and is reported; it never hard-fails the run. crisol tracks what was actually delivered in a concrete record:

```nim
type SandboxAchieved* = object
  envScrubbed*:     bool   ## allowlist actually applied
  tmpdirIso*:       bool   ## isolated TMPDIR actually created
  rlimitsApplied*:  bool   ## config-declared rlimits actually set (getrlimit-readback confirmed)
  netIso*:          bool   ## CLONE_NEWNET actually applied

proc isFullyAchieved*(spec: SandboxSpec; got: SandboxAchieved): bool =
  ## Cache gate: true iff every requested control was delivered.
  (not spec.envScrub  or got.envScrubbed)    and
  (not spec.tmpdir    or got.tmpdirIso)      and
  (not spec.rlimits   or got.rlimitsApplied) and
  (not spec.netIso    or got.netIso)
```

`SandboxAchieved` is carried on `EntrypointResult` (one field; the reporting layer reads it directly). **The F3 cache gate keys on *achieved* hermeticity:** if `isFullyAchieved` is false, the run still happens but its result is **not written to the cache** (with a warning), because the key would claim isolation the run didn't get.

- **How "achieved" is observed (round 2 — slice A4d):** the child runs in a post-fork address space and cannot write the parent's heap, so achieved-status flows back over a **pre-fork pipe**: the child performs each control, and (async-signal-safe) `write(2)`s a small status word to the pipe before `execvpe`; the parent reads it and populates `SandboxAchieved`. `rlimitsApplied` is confirmed by a `getrlimit` read-back of the soft limit (so the hash/gate reflect what the kernel accepted). **Residual limit:** a cgroup ceiling *below* the rlimit (e.g. podman `--memory`) is invisible to `getrlimit` and undetectable — documented; such environments need `cacheable #false` for memory-sensitive groups.

**Out of scope for F2:** chroot / bind-mount / tmpfs root filesystem isolation — Non-Goal, future RFC.

### F3 — Incremental execution / result caching

- crisol's plan/run decision is **one sealed sum** (round 2 fix — two orthogonal enums `CompileDecision × ExecutionDecision` would make illegal states like `(cdNeverBuilt, edCached)` representable; `edCached` *requires* a fresh binary, so the domain is not a product):

```nim
type EntrypointDecision* = enum
  edNeverBuilt   ## no binary; compile + run
  edStale        ## binary stale; compile + run
  edRunFresh     ## binary fresh; skip compile, run
  edCached       ## binary fresh AND result cached; skip both (freshness implied)
```

  The execute loop branches on this single field; illegal combinations are unrepresentable. (External consumers that want the old compile view recover it: `edNeverBuilt→cdNeverBuilt`, `edStale→cdStale`, `edRunFresh|edCached→cdSkipFresh`.)
- At plan time, for each runnable `edRunFresh` entrypoint, derive its soundness key; on a cache hit (and policy permitting), set `edCached` (skip *both* compile and run) and synthesize the `EntrypointResult` from cache.
- **Synthesized results (round 1):** served with their **historical timestamps** (`cachedAt` distinguishes store-time from now); the `ResultCallback` for an `edCached` entrypoint fires at **plan time, before** live results, so streaming consumers see deterministic ordering. `--changed` is unaffected: an entrypoint whose closure actually changed has a different `closureHash` ⇒ different soundness key ⇒ guaranteed miss (cache and impact-analysis read the same content, so they cannot disagree).
- On completion of a non-cached entrypoint, **store** its result under the key — **only if** (a) hermeticity was *achieved* (`isFullyAchieved`) and (b) it passed on **attempt 1** (round 1: never cache a flaky-pass from attempt > 1, or it freezes as PASS forever and the ledger gets one useless sample).
- **Admission (round 1):** `edCached` entrypoints are synthesized at plan time, **bypass the admission controller entirely**, and never occupy a `liveCount`/`committed` slot (they spawn nothing).
- **Policy:** cache **passes** in v1; `cache-failures` is a later additive opt-in.
- **Observability is structural, not bolted-on (round 2):** `EntrypointResult` carries a `CacheDecision` enum, always populated, so "why didn't this cache?" is answerable without `strace`:

```nim
type CacheDecision* = enum
  cdhHit              ## served from cache
  cdmKeyMiss          ## no entry for this soundnessKey (a fresh run)
  cdmHermeticityDeg   ## hermeticity degraded; gate blocked the write
  cdmPolicyDisabled   ## --no-cache or cacheable #false
  cdmFlaky            ## flaky-pass (attempt > 1); not stored
  cdmNotEligible      ## edNeverBuilt/edStale; cache not consulted
```

  Serialized in `crisol/run/v1`; shown in `--verbose` render (`[CACHED]` for hits, `[MISS: hermeticity degraded]` etc. otherwise).
- **Controls:** `--no-cache` = **do not read and do not write** the cache (full bypass; documented unambiguously), distinct from and orthogonal to `--force-compile` (which forces compilation). Per-group `cacheable` is **tri-state**: `#false` = never cache (absolute, overrides everything), `#true` = cache if global policy + hermeticity gate permit, `#default` = inherit global. Precedence: `#false` → hermeticity-gate → global default. **Caching is on by default** (see Resolved defaults).
- **Reporting:** additive — `edCached` in `crisol/plan/v1`; `cached` flag + `inputHash` + `cacheDecision` in `crisol/run/v1`; `[CACHED]` label in human render.

### F4 — Reliability (retry · flake ledger · quarantine)

- **`CRISOL_ATTEMPT` (slice B0):** crisol injects the 1-indexed attempt number into the child env (after the allowlist filter, like `CRISOL_SINK`). Enables deterministic flaky-test fixtures and lets a consumer observe its own retry.
- **Retry** *(entrypoint-level — boundary-clean)*: on failure, rerun the whole binary up to `retries N` (`--retries N`, per-group override). A pass on attempt > 1 is a **flaky-pass** (counts as pass by default; `--fail-on-flaky` to fail — round 1/2 rename from the opaque `--retries-strict`/`--no-flaky-pass`). Cached passes are never retried; fresh fails are; a flaky-pass is **never** cached. *Implementation note (round 2):* the `execute()` dispatcher is currently 1:1 on plan index (`dispatched[]`, `lwm`); re-dispatch for retry requires threading an attempt counter rather than marking `dispatched` terminal — pick this architecture in B1 before writing B0's test.
- **Flake ledger**: each attempt appends a row (carrying `attempt`) to a `RunLedger` shard; flake-rate per identity is queryable.
- **Quarantine** *(reporting-layer — boundary-clean)*: config-declared `quarantine { "tests/integration/test_x.nim" }`. A quarantined entrypoint's failure is **reported but excluded from the exit-1 decision**. Per-test quarantine downgrades an entrypoint's contribution when its *only* failing records are quarantined names — this *reads* records crisol already receives; it never *controls* what the binary runs. Quarantine status is **not** part of the soundness key (a reporting concern): a cached pass for a now-quarantined test still serves `[CACHED]`, with quarantine applied to the synthesized result post-lookup.

### F5 — CI ergonomics (JUnit · shard · prioritize)

- **JUnit XML**: `--junit <path>` — entrypoints→`<testsuite>`, records→`<testcase>` (opaque binaries → one case/suite). All character data (names, classnames, messages, captured output) is escaped through **one well-tested escape proc** (round 1 — arbitrary Nim test names contain `< & > " '`; unescaped output is schema-invalid). Covered by a **table-driven adversarial test** (round 2 — *not* a property test: proptest is not a crisol dependency and adding it via `milpa add` for one escape proc isn't worth it; ~20 adversarial inputs cover the same ground). Cached cases carry `cached="true"`; `time` reflects the **original** run duration, not the current invocation.
- **Sharding**: `--shard k/n` — a **stable, complete, disjoint** partition of the entrypoint set, applied as the **last step of selection** (round 1 — after `--changed` narrowing and gate filtering, before plan). Default partition by stable path-hash; when `RunLedger` history exists, **balance by historical duration** (greedy bin-pack). Each CI runner runs one shard.
- **Prioritization**: `--order <recent-fail|duration|none>` — schedule order to minimize time-to-first-failure (APFD), driven by the ledger. Generalizes `--failed`; changes order only, never the selected set.
- **Cold-start fallbacks are deterministic (round 2):** with an empty ledger, `--order` falls back to **stable lexicographic path order** and balanced sharding falls back to **path-hash partition** — both stable across invocations. The ordering step always runs *after* shard assignment, so shard membership is stable regardless of the `--order` fallback (preserves the stable/complete/disjoint guarantee even when both subsystems are cold).

### F6 — Observability (telemetry · perf-regression)

- **Telemetry persistence**: per-test `durationUs` (already in records) and per-entrypoint duration + peak RSS (crisol *samples* RSS for admission today and discards it) appended to the ledger as a time-series. `edCached` results contribute **no fresh measurement** (excluded from telemetry and regression — round 1, else current==historical by construction).
- **Perf-regression detection**: flag identities whose current duration exceeds a robust historical baseline — `median + k·MAD`. Configured as **one named policy block** (round 2 — not three orphan scalars):

```kdl
perf-check {
    sensitivity "moderate"   // none | conservative | moderate | aggressive  → preset (k, sample-floor, abs-floor-ms)
    // power users may override individually:
    // k 3.0; sample-floor 10; abs-floor-ms 5
}
```

  `moderate` = `(k=3.0, sample-floor=10, abs-floor-ms=5)`. Round-1 robustness rules stand: detection **suppressed below the sample-floor**; the MAD-zero degenerate case uses `MAD ← max(MAD, absFloorMs)` so a perfectly-stable test isn't tripped by scheduler noise. Reported in render + a `regressions` array in `crisol/run/v1`.
- **OTel span export**: noted as future; not in v1.

## Non-Goals

- **Candidate #4 — coverage-guided per-test impact analysis**, and **any sub-binary control** (per-test selection, per-test retry, per-test sharding). These require crisol to drive selection *inside* the binary, coupling it to each suite lib — a layer-2 crossing. Explicitly excluded; would be its own RFC with a generalized, still-opt-in selection protocol.
- Filesystem-root isolation (chroot/bind/tmpfs) beyond the per-entrypoint scratch tmpdir.
- Non-Linux hermeticity (degrades gracefully, like the mem-probe).
- Benchmarking (a standing crisol Non-Goal).
- Distributed *execution* (remote workers); `--shard` enables external orchestration, but crisol stays single-host.
- SQLite (or any embedded DB) for the store in v1 — see F1 rationale; revisit only if ledger scale demands indexed range-scans.
- Caching **failures** in v1 (pass-caching first; fail-caching is a later additive opt-in).

## CI deployment (cross-run reuse)

Cross-run cache/history reuse in ephemeral CI is a **deployment concern**, not a crisol feature — but it must be ergonomic, so the contract is explicit (round 2):
- **Persist one directory:** `<stateDir>/` (contains `cache/v<fmt>/` and `ledger/`). Restore it before `crisol run`, save it after, as a CI cache layer.
- **Version skew is safe-by-construction:** a restored cache from a different crisol/Nim/cc version simply produces key-misses (different soundness keys) — no manual invalidation needed. A ledger shard with a mismatched `historyFormatVersion` header is discarded with a warning (an upgrade costs history, not correctness).
- **Branch-safe:** the cache is collision-free by key (different `flagHash`/closure ⇒ different files); ledger history is additive across branches. No per-branch invalidation logic required.

## Resolved defaults (decisions, not forks)

All original forks resolved. Governing principle (Corey, round 1): **crisol has no consumers yet — default to the strongest *sound* configuration, not the most conservative.**

1. **Default hermeticity = `isolated`.** Soundness substrate always active; the published default allowlist bounds the env input set. (`chdir`-into-scratch and `network` remain **opt-in** — correctness/capability constraints, not migration concessions.)
2. **Caching = on by default.** Sound because hermeticity is `isolated` and the gate keys on *achieved* hermeticity.
3. **Cache key = input-hash**, reusing `DepGraphEntry.closureHash` augmented with `ccVersion`/libc (an independently-compiled-but-source-identical binary is the same input equivalence class; binary-bytes hashing fights Nim's path-embedding).

A consumer needing looser behavior opts out explicitly (`--hermetic none`, `--no-cache`, per-group `cacheable #false`).

## Stages & slices

Dependency-correct order (rounds 1 & 2). **Stage A:** A2-pre → A3 → A5 → A2 → A1a → A1b → A4a → A4b → A4c → A4d → A6 → A7 → A8 → A9.

**Fixture inventory (prerequisite for the A4/B integration slices):** a binary that overruns `RLIMIT_FSIZE`; one that exhausts `RLIMIT_NOFILE`; one that attempts `RLIMIT_AS` allocation **above a documented safe minimum** (so it doesn't crash the crisol process group); one that reads an unlisted env var and reports it; one that reads `TMPDIR`; a `network`-touching binary whose test asserts **degradation** (rootless podman has no `CAP_NET_ADMIN`); a deterministically-flaky binary keyed on `CRISOL_ATTEMPT`. Build these before the slices that consume them.

**Stage A — engine core (highest architect scrutiny):**
- [ ] **A2-pre** cc/libc version probe (`cc --version`, `ldd --version`): run once at startup, cache, expose a mockable seam. Effectful; tested via injection.
- [ ] **A3** `Sandbox` spec resolution from config + flags (level, env allowlist, tmpdir/cwd policy, config-declared rlimits) → `SandboxSpec`. Pure resolution, tested.
- [ ] **A5** env allowlist/scrub in spawn — modify `forkExecEnv` to filter to the allowlist (then append crisol-injected vars) rather than copy parent env; `hermeticEnvHash` derivation. Integration-tested: unlisted var absent in-child; injected vars present; hash stable; `TMPDIR` excluded from hash.
- [ ] **A2** soundness-key + identity-key derivation in `keys.nim` (chained FNV; `hermeticEnvHash` and `ccVersion` injected as params so the proc is pure/testable). Vectors-tested, incl. XOR-cancellation and NUL-in-fixture negative cases.
- [ ] **A1a** `ExecutionCache` store: per-key files, schema-versioned header, atomic write, checksum, `.tmp` cleanup, interim soft-cap, roundtrip, version/checksum-mismatch → miss. Pure module, boundary-tested.
- [ ] **A1b** `RunLedger` store: per-process shard files, raw `posix.write` append loop, identity range-scan across shards, corruption-resilient reads (skip bad rows), roundtrip. Boundary-tested incl. a concurrent-invocation test (no torn rows) and a torn-row-skip test.
- [ ] **A4a** isolated tmpdir + `TMPDIR` injection + opt-in `chdir` (`Slot.testScratchDir`, cleaned all paths). Integration-tested: child sees scratch `TMPDIR`; removed after; default cwd unchanged.
- [ ] **A4b** safe rlimits (`RLIMIT_CORE=0`, `RLIMIT_NOFILE`, `RLIMIT_FSIZE`); verify constant availability in Nim posix. Integration-tested with fixtures (deterministic kills).
- [ ] **A4c** timing/privilege-sensitive rlimits (`RLIMIT_CPU`, `RLIMIT_AS`, constants only), self-gated conditional skip (`if getEnv("CRISOL_TIMING_TESTS") == "": quit(0)`). Tested; `RLIMIT_AS` fixture uses the documented safe minimum.
- [ ] **A4d** `SandboxAchieved` IPC: pre-fork status pipe; child writes achieved-status async-signal-safe before `execvpe`; parent populates `SandboxAchieved` (incl. `getrlimit` read-back). Integration-tested incl. a forced-degradation case.
- [ ] **A6** cache lookup at plan → `edCached` (+ dispatch in `execute()`); gate via `isFullyAchieved`; admission bypass; `CacheDecision` populated. Boundary-tested via `crisol/api` (store + key proc mocked). *Depends on A4d.*
- [ ] **A7** cache store on attempt-1 pass under achieved hermeticity; second run hits. Integration-tested (run-twice → cached); concurrent-process disclaimer documented.
- [ ] **A8** cache reporting: `edCached` in plan/v1, `cached`/`inputHash`/`cacheDecision` in run/v1 + render; **`schemaRevision` integer** added; `loadLastRun` **and `loadLastPlan`** tolerate old+new and treat `schemaRevision > max` as safe cold-start (warn). Tested.
- [ ] **A9** cache controls: `--no-cache` (no read/no write), `--force-compile` orthogonality, per-group tri-state `cacheable`, `--changed`×warm-cache interaction. Tested.
- [ ] **A1c** *(deferred — after C5)* GC: cache LRU (age/size) + ledger shard compaction + `crisol clean` integration + run-lock coordination. Tested.

**Stage B — reliability:**
- [ ] **B0** `CRISOL_ATTEMPT` env injection in spawn. Tested (child observes attempt number).
- [ ] **B1** entrypoint retry up to N + flaky-pass outcome + exit policy + never-cache-flaky-pass; restructure the `execute()` dispatcher for re-dispatch. Integration-tested with the `CRISOL_ATTEMPT` fixture.
- [ ] **B2** flake-ledger append (`attempt`) + flake-rate query. Tested. (Depends on B1, A1b.)
- [ ] **B3** config-declared quarantine: failure reported, excluded from exit-1; render shows quarantined. Tested.
- [ ] **B4** per-test quarantine via records (reconciliation downgrade; requires protocol records). Tested.

**Stage C — CI ergonomics + observability:**
- [ ] **C0** extend `crisol clean` to know the new store dirs (`--all` removes both). Boundary-tested.
- [ ] **C1** JUnit XML emitter (`--junit`) incl. the shared escape proc + table-driven adversarial test + `cached`/`time` semantics. Schema-valid. Tested.
- [ ] **C2** `--shard k/n` stable/complete/disjoint partition (pure fn), placed last in selection. Tested incl. `--shard`×`--changed` and cold-start determinism.
- [ ] **C3** duration-balanced sharding from ledger, hash fallback. Tested.
- [ ] **C4** `--order` history-based prioritization (pure order fn) incl. cold-start lexicographic fallback. Tested.
- [ ] **C5** per-test/per-entrypoint telemetry persistence to ledger. Tested.
- [ ] **C6** perf-regression detection (`perf-check` policy block; k=3 default, sample-floor, MAD-zero floor; cdCached excluded) + report. Tested.

## Contract impacts

- **Exit codes** unchanged (0/1/2/3/128+n). Flaky-pass → 0 (unless `--fail-on-flaky`); quarantined failure → excluded from the 1 decision.
- **Schemas**: `crisol/run/v1` and `crisol/plan/v1` gain **additive** fields (`cached`, `inputHash`, `cacheDecision`, `regressions`, `edCached`). Keep the `crisol/run/v1` *string* and add an integer **`schemaRevision`** (bumped per additive release); additive optional fields carry a defined absence-default (`cached:false`) so old consumers tolerate them — a minor revision, not a `v2`. (Considered and rejected encoding the minor in the string as `v1.<n>`: a separate integer is more machine-friendly for a consumer gating on feature presence — `schemaRevision >= 2` beats substring-parsing.) An old crisol reading `schemaRevision > CURRENT_MAX` treats the file as no-data (safe cold-start, warn). `loadLastRun` and `loadLastPlan` both handle this symmetrically.
- **CLI additions**: `--no-cache` (no read/write), `--retries N`, `--fail-on-flaky`, `--junit <path>`, `--shard k/n`, `--order <…>`, `--perf-check`, `--hermetic <none|isolated|network>`. Config additions: tri-state `cacheable`, `retries`, `quarantine { … }`, `hermetic` (level), `fixtures { … }` (globs feeding `fixtureHash`), `perf-check { sensitivity }`, `maxCacheEntries`. All additive.
- **Library facade** (`crisol/api`): `RunOptions` gains the corresponding fields; `RunReport`/`EntrypointResult` gain `cached`/`inputHash`/`cacheDecision`/`flaky`/`quarantined`/`regression`/`sandboxAchieved`. Additive.
