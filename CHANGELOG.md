# Changelog

All notable changes to crisol are documented here.

---

## Unreleased

### Fixed — a present-but-empty Content-Length is malformed framing, never an absent header (RFC-0005 review R2-SEC-A)

`httpraw.readResponse` keyed `Content-Length` "presence" on the header's
stripped value being non-empty, so a literally-present-but-empty header
(`Content-Length:` or whitespace-only) was silently reclassified as absent
and read via the EOF-delimited path instead of the present-but-invalid
`toUnreachable` rejection every other malformed value (negative, overflow,
garbage) already gets. Presence is now determined by the header NAME
appearing at all (new pure `httpraw.classifyContentLength`); the
genuinely-absent-header EOF path is unaffected and pinned by unit tests.

### Fixed — secrets are resolved+scrubbed before ANY child spawns (not merely before the cache activates), and `--cache-stats` now distinguishes a trust-rejected/corrupt cache read from a cold miss (RFC-0005 code-review R2-D5a/R2-T8b)

Two confirmed findings from the round-2 re-review of the RFC-0005 build's
code-review fixes:

- **R2-D5a — `runTests()`/`runTestsWith()` now resolve and scrub the
  `CRISOL_CACHE_*` environment BEFORE `planTests`/`planImpl`, not merely
  before the cache activates.** Round-1's D5 fix deferred
  `resolveCacheSecrets()` (the env scan-then-`delEnv`) into
  `productionCacheDeps().buildRuntime`'s own closure, correct in SCOPE (a
  `noCache: true` run still performs zero env mutation) but wrong in
  TIMING: that closure only runs AFTER `planImpl` returns successfully, and
  `planImpl` unconditionally spawns the Nim compiler fingerprint-probe
  child (`buildRunPlan`'s `cachedNimFingerprint()` argument) regardless of
  whether the plan itself later succeeds — so every cache-enabled run's
  probe child inherited the UNSCRUBBED `CRISOL_CACHE_SIGN_KEY`/
  `_HMAC_KEY`/`_TOKEN*` environment. The resolve+scrub now happens once, at
  the very top of `runTestsWith` (still gated on `not opts.noCache` — the
  D5 guarantee is unchanged), strictly before `planImpl` or any child ever
  spawns. `CacheDeps.buildRuntime` gains a fourth parameter,
  `resolvedSecrets: CacheSecrets`, threaded down from that single
  resolution point instead of re-derived inside the closure —
  `productionCacheDeps` no longer touches the environment at all itself.
- **R2-T8b — `cacheStats` now distinguishes a trust-rejected or corrupt
  cache read from a genuine cold miss**, closing the gap the round-1 T8
  finding pinned rather than fixed (see the superseded "Known gap" note
  this entry replaces, below). `CacheStats` gains two additive counters,
  `trustRejects` and `corruptReads` (run/v2 `cacheStats.trustRejects`/
  `.corruptReads`, `schemaRevision` 22 → 23): `aggregateCacheStats` now
  folds `tekMiss.verdicts` (previously discarded — miss COUNT is
  decision-sourced, but the per-tier VERDICT information those events
  carry was simply never folded into any `CacheStats` field) into a count
  of consulted lookups whose per-tier verdicts include at least one
  `types.trustVerdicts` code (`trustRejects`) or `cvCorrupt`
  (`corruptReads`) — both additive to, not separate from, the existing
  `misses` count. `render.renderCacheStats` gains a matching "N misses (M
  trust-rejects, K corrupt-reads)" segment.

### Fixed — -d:ssl is now the default for the produced crisol binary (RFC-0005 code-review L1/T5)

`src/crisol.nim.cfg` (Nim's per-mainfile config) supplies `--define:ssl` to
every `nimble build`/`./dev build`, so `https://` remote-cache tiers work in
the shipped binary instead of silently latching the circuit breaker. A binary
built WITHOUT `-d:ssl` now rejects a configured `https://` remote-cache tier
as a hard config error (in both `validate()` and `configuredCache`) instead
of presenting a silent dead tier. TLS certificate verification (self-signed
rejection) is now proven by an automated in-suite test
(`tests/unit/ssl/test_https_reject_selfsigned.nim`) rather than a manual
script, and CI asserts the produced binary carries the TLS symbols.

### Fixed — --verify-cache no longer misfiles a dead verify sub-run as nondeterminism, and never recompiles/persists the depgraph for a post-compile-consult hit (RFC-0005 code-review SO4/SO5)

Two confirmed findings from the RFC-0005 build's code-review:

- **SO4 — a verify sub-run that never produced an observation (fresh run
  phase `pkSkipped`/`pkSpawnFailed` — e.g. the sampled entry's promoted
  stable binary vanished between the main run and the verify pass) is no
  longer counted as an exit divergence.** `api.verifyCachePass`'s internal
  comparison previously ran `exitsDiverge` unconditionally; since a stored
  `cdmHit` always has an observation but a dead verify sub-run does not,
  `exitsDiverge`'s `isSome != isSome` branch turned every such case into a
  false "exit diverged" — a verify-INFRASTRUCTURE failure misfiled as cache
  nondeterminism, tripping `--verify-cache-strict` for a reason unrelated
  to the cache. Such entries are now excluded from `RunReport.
  verifyDivergences` entirely and instead land in a new
  `RunReport.verifyCouldNotReexec: seq[Entrypoint]` field — never silent
  (a distinct stderr warning still names the entrypoint) and never
  strict-mode-triggering (`--verify-cache-strict` gates on
  `verifyDivergences.len`, unaffected by this new field). No wire/schema
  change: `run/v2`'s `verifyFails` count simply becomes more accurate
  (excludes what was never a real comparison); `RunSchemaRevision` stays
  22 (an existing field's CONTENT corrected, not a new field — same
  precedent as rfc-0007 A5/A6a's "no rev bump" entries in jsonout.nim's own
  schema history).
- **SO5 — the verify pass no longer recompiles (and therefore never
  persists the depgraph) for a sampled hit that came from the POST-COMPILE
  cache consult (RFC-0005 A2c-ii) rather than a plan-time hit.**
  `runner.buildVerifyPlan`'s synthetic plan carried such an entry's
  ORIGINAL `edecision` (`edNeverBuilt`/`edStale` — that is why the
  post-compile consult had to run in the first place) unchanged, so
  `execute()`'s dispatch sent it through `spawnCompileStable` in the
  diagnostic-only verify sub-run: a genuine recompile whose `finalizeSlot`
  calls `recordClosure`, which unconditionally calls `saveDepGraph` and
  persists the mutation to disk — violating the pass's own "no depgraph
  mutation/save" contract. Fixed by forcing every sampled entry's
  `edecision` to `edRunFresh` in `buildVerifyPlan`, unconditionally: every
  `cdmHit` (plan-time or post-compile) already has a stable binary
  promoted by the time the verify pass runs, so this makes every sampled
  entry dispatch through `spawnRunDirect` (reuse the stable binary, no
  recompile at all) instead — the cleaner of the two options considered,
  since it removes the recompile itself rather than merely suppressing its
  side effect.

**Fixed (round-2 re-review, RFC-0005 code-review R2-T8b):** the gap noted
here in round 1 — `cacheStats` could not distinguish a trust-rejected/
corrupt cache read from a genuine cold miss, despite the RFC's own E2E-2
acceptance text claiming otherwise — is closed. See this changelog's own
"secrets are resolved+scrubbed before ANY child spawns... R2-D5a/R2-T8b"
entry, above, for the fix (`CacheStats.trustRejects`/`.corruptReads`,
`schemaRevision` 23). `tests/unit/test_api.nim`'s E2E-2 suite now asserts
distinguishability directly (a tamper case reads a nonzero counter; a
genuine cold-miss case reads zero) rather than pinning the gap.

### Fixed — end-of-run drain honors interruption, the per-tier error warning is unconditional, local vs. remote put failures are counted honestly, and `noCache` no longer touches the host environment (RFC-0005 code-review SO2/L2/D1/D5)

Four confirmed findings from the RFC-0005 build's code-review:

- **SO2 — the end-of-run deferred-put drain (`api.runTestsWith`) now skips
  entirely on an interrupted run**, mirroring the `persistLastRun` gate:
  queuing more network I/O for entries an interrupted run never finished
  observing was the wrong thing to do on the way out. `cachetier.
  drainPending` also gained its own injected `abandoned` predicate
  (mirroring `resolveProbes`'s existing discipline), checked between puts
  and wired in production to `signals.shutdownRequested().isSome` — so a
  shutdown signal that arrives *during* the drain itself, on an otherwise-
  uninterrupted run, stops it too.
- **L2 — the RFC-pinned per-tier 100%-error/breaker stderr warning now
  fires on every run, not only under `--cache-stats`.** Previously
  `erroredTiers`'s sole caller was gated behind `if statsSink != nil`,
  which is `nil` unless `--cache-stats` is on, so a default run with a
  dead cache tier warned about nothing. `api.runTestsWith` now always
  installs a cheap `InMemorySink` (`warnSink`) dedicated to this fold —
  reusing `--cache-stats`'s own collector when it is already installed (no
  duplicate collection, no duplicate warning), or a fresh throwaway one
  otherwise. `RunReport.cacheStats`/the run/v2 `cacheStats` object are
  unaffected: they stay the documented zero value / absent whenever
  `--cache-stats` is off.
- **D1 — a local ("l1") put/backfill failure is no longer folded into
  `remoteErrors`.** `cachetelemetry.CacheStats` gains an additive
  `localErrors` field (run/v2 `cacheStats.localErrors`, `schemaRevision`
  21 → 22); `aggregateCacheStats` now attributes a
  `tekRemoteErr`/`tekBackfillErr` event by its `putTier` — `"l1"` counts
  toward `localErrors`, any other (configured `remote-cache`) tier still
  counts toward `remoteErrors`, unchanged. Before this fix a purely local
  fault (e.g. an unwritable cache root) on a run with ZERO remote tiers
  configured could still report a nonzero `remoteErrors` and render "N
  remote-errors" — dishonest, since "remote" implies a configured remote
  tier exists. `render.renderCacheStats` gained a matching `"N
  local-errors"` segment.
- **D5 — `runTests()` no longer scrubs the `CRISOL_CACHE_*` environment
  under `opts.noCache: true`.** `resolveCacheSecrets()` (the env
  scan-then-`delEnv` of the whole `CRISOL_CACHE_*` namespace) now runs
  lazily, inside `productionCacheDeps().buildRuntime`'s own closure,
  rather than eagerly in `productionCacheDeps()` itself — `runTestsWith`
  only ever calls `buildRuntime` when the cache actually activates, so a
  library embedder that opts out of caching entirely no longer sees an
  undocumented host-process environment mutation from `runTests()`. The
  cache-enabled scrub itself is unchanged (still runs exactly once per
  real run) and is now documented explicitly, in both `runTests`'s and
  `RunOptions.noCache`'s doc comments, as deliberate defense-in-depth.

### Fixed — cache serve-path hardening: policy-aware recompute, an evidence re-check on read, and an attempt-gated post-compile consult (RFC-0005 code-review SO1/SO3)

Two confirmed findings from the RFC-0005 build's code-review, both closed
without adding a new `CacheDecision` variant:

- **SO1 — serve-time recompute now reads the run's OWN resolved
  `OutcomePolicy`, not a fixed unstrict default, and re-checks
  `evidenceSatisfies` on the stored observation.** Previously
  `lookupAtPlan`/`consultPostCompile` (via their shared `consultReal`)
  recomputed a cache hit's outcome under `DefaultPolicy` regardless of
  `--strict-hygiene`, so a strict-hygiene run could serve an entry it
  would itself go on to report as failed. Worse, the read side never
  re-ran the same named-guarantee check (`evidenceSatisfies`) the publish
  gate (`shouldStore`) already applies — a foreign/backfilled entry
  (`cachetier`'s populate-on-hit re-stores a fetched remote entry
  verbatim, never through `shouldStore`) could carry an OBSERVED escapee
  and still serve as `cdmHit` forever, even though "observed escapee ⇒
  uncacheable" is meant to be absolute. Both are now enforced at
  `consultReal`: a recompute under the run's resolved policy that is not
  `oPassed`, OR a failing `evidenceSatisfies` re-check, is `cdmRecomputeMiss`
  — the same honest "found it, but it doesn't hold up" outcome the recompute
  rule already used. The run's resolved policy is threaded through a new
  `CacheContext.outcomePolicy` field (default `DefaultPolicy`, so every
  pre-existing caller is unaffected); the STORE side (`shouldStore`) stays
  policy-unconditional, matching RFC-0007 §2's "the cache publishes
  unstrict" rule — only serving became policy-aware.
- **SO3 — the post-compile consult (`consultPostCompile`, RFC-0005 A2c-ii)
  is now gated on the slot's attempt number being 1**, mirroring
  `shouldStore`'s existing `attempt != 1 ⇒ cdmFlaky` rule on the write
  side. `edNeverBuilt`/`edStale` retries always recompile (the
  entrypoint's `edecision` never changes across attempts), so a retry's
  finalize previously re-ran the SAME post-compile consult every attempt
  — a pass published to the same key by another host between attempts
  could serve a `fkCacheHit` and silently mask a genuine local failure
  (reporting `attempts=0`, no ledger row, `flaky()` structurally false).
  On attempt > 1 the consult is now skipped entirely; the compile always
  falls through to a real run.

### BREAKING CHANGE — secure-by-default cache config: unsigned `http://` and cleartext bearer tokens now rejected; a malformed cache-trust sign key is now a config error

Four RFC-0005 security-review findings, closed as hard config-time
rejections (never a silent downgrade):

- **Unsigned `http://` remote-cache tiers now require a verifying
  `cache-trust` policy**, symmetric with the existing unsigned-`s3://`
  rule: an `http://` tier whose effective `verify-trust` resolves `false`
  (policy `"none"`, or an explicit `verify-trust #false`) is a config
  error — an unkeyed FNV-1a-64 checksum is attacker-computable and a
  `"none"` trust policy serves anything requested of it (read-side
  spoofing/MITM). `https://` under policy `"none"` is unaffected —
  **not** an error, but now emits a one-line config warning: TLS
  authenticates the channel, not the content, so the server operator is
  fully trusted. Both rejections are enforced in `config.validate` (the
  KDL-facing error) **and independently** in `cacheregistry.
  configuredCache`, so a programmatic `CacheConfig` built by an embedder
  cannot bypass either check by skipping KDL parsing — this closes the
  same gap for the pre-existing unsigned-`s3://` rule, which previously
  lived in `config.validate` only.
- **A resolvable bearer token for a plaintext `http://` tier is now a
  config error.** `$CRISOL_CACHE_TOKEN` / `$CRISOL_CACHE_TOKEN_<TIER>` are
  write credentials; sending one in cleartext is rejected outright,
  before any request is made. `https://` tiers are unaffected. The error
  names the tier and the env var shape, never the token value.
- **A present-but-malformed `$CRISOL_CACHE_SIGN_KEY` (invalid base64, or a
  decoded length other than 32 bytes) is now a config error**, instead of
  silently degrading the configured `ed25519` policy to verify-only —
  previously every subsequent `put` became a silent `cvUnauthorized`
  no-op with no diagnostic. An *absent* key is unchanged: a genuine
  verify-only (read-only) participant remains a legitimate deployment.

### Fixed — `httpraw.nim`: a present-but-invalid `Content-Length` is now a transport error, never a served body

A response header `Content-Length: -1` parsed via `parseInt` and collided,
by VALUE, with the `-1` sentinel `readResponse` used internally to mean
"header absent" — silently reclassifying malformed framing as an
EOF-delimited body read to completion instead of the transport failure it
actually is. The same collision let an overflowing (`Content-Length:
99999999999999999999`) or garbage (`Content-Length: abc`) value fall
through the same way, since `parseInt`'s `ValueError` was caught and mapped
back onto that same `-1`.

`readResponse` now decides "bounded vs. EOF-delimited" from a structural
`hasContentLength` flag — never from comparing the parsed value against a
sentinel — and a present-but-not-a-valid-non-negative-integer header
(negative, overflowing, or garbage) now returns `toUnreachable` before any
body is read, the same classification already used for a connection that
closes before a validly-declared `Content-Length` is fully delivered.

### BREAKING CHANGE — run/v1 → run/v2 on the wire; the library result model rebuilt on the process contract (rfc-0007 Stage A, 2026-09-03)

Stage A of RFC-0007 replaces crisol's stored, advisory result fields with
one platform-neutral observation model — a per-phase `ProcessResult`
carrying `Exit` (lossless: how the child ended), `Cause` (authorship: who
ended it), `Evidence` (what the runner can vouch for) and `Rusage` — and
derives every reported verdict from that observation at each trust
boundary instead of trusting a stored field.  Both the JSON wire and the
library API break.  Consumers of `crisol run --json` / `lastrun.json` and
library embedders are both affected; migration guidance for each is below.

**The JSON wire: `crisol/run/v1` → `crisol/run/v2`.**  The `schema` string
changes; `schemaRevision` continues its integer scheme (v1 ended at 15, v2
spans 16–18).  The complete per-field v1→v2 mapping table lives at the top
of `src/crisol/jsonout.nim`; the substance:

- Each entrypoint gains two **Phase nodes**, `compile` and `run` — the same
  shape for both (`kind`: `"skipped"`/`"spawnFailed"`/`"ran"`/`"cached"`;
  when ran/cached: `exit`, `cause`, `evidence`, `rusage`, `durationUs`).
  A compile timeout/kill is now visible on the wire exactly like a run
  timeout/kill.  `evidence` carries the real per-limit achieved statuses,
  the kill-domain/tree observation, observed escapees, the kill-time
  process snapshot, and the hermetic level the child ran under; `rusage`
  is wait4's `maxRssBytes`/`userCpuUs`/`sysCpuUs`.
- The per-entrypoint `outcome` string keeps its key and value domain but is
  now **derived from the observation** at emission time: a runner-authored
  kill reads `"killed"` (never `"timedOut"`) and an uncommanded fatal
  signal reads `"crashed"` (never `"signaled"`) — those two legacy strings
  no longer appear on any live wire.
- `summary` drops its scalar `passed`/`failed`/`compileFailed`/`timedOut`/
  `signaled`/`spawnErrors` counters for a `counts` object keyed by outcome
  string (`passed`, `exitNonZero`, `compileFailed`, `spawnError`, `killed`,
  `crashed`), and gains `flaky` and `notStarted` (entries omitted because
  an interrupt arrived before their next phase started).
- Top level: `compile` (the telemetry block) is **renamed `compileStats`**,
  freeing `compile` for the phase node; `interrupted` (bool) is added; and
  rev 18 adds `substrate` — the process backend's probed capability
  snapshot, platform-shaped (a Linux node carries `pidfd`/`subreaper`/
  `cgroupDelegation`/`cgroupKill`/`memoryPeak`/`flock`/`wait4Rusage`;
  inapplicable fields are absent, never `false`).

**Migrating from run/v1** (old key → new source):

- `entrypoints[].exitCode` → `run.exit.code` when `run.exit.kind == "exited"`
- `entrypoints[].signal` → `run.exit.sig` when `run.exit.kind == "signaled"`
- `entrypoints[].durationMs` → per-phase `compile.durationUs` /
  `run.durationUs` (microseconds; sum them for the old combined figure)
- `entrypoints[].peakRssBytes` → dropped, no successor key
  (`run.rusage.maxRssBytes` is the related wait4 figure)
- rev-15's flat advisory `entrypoints[].exit`/`cause` → absorbed into the
  `run` phase node, real rather than advisory
- `summary.passed`/`failed`/`spawnErrors` → `summary.counts["passed"]` /
  `["exitNonZero"]` / `["spawnError"]`; `summary.timedOut`/`signaled` →
  `counts["killed"]` / `counts["crashed"]` (new, honest attribution)
- `compile` (top level) → `compileStats`

A `lastrun.json` written by run/v1 is read as **no data** (cold start, no
error): the first `--failed` after upgrading exits 3 until a fresh run
writes a v2 file.  `crisol/plan/v1` keeps its schema string but bumps
`schemaRevision` 3 → 4: `crisol list --json` / `run --dry-run --json` gain
the same top-level `substrate` node (additive; older readers unaffected).

**The library API break** (import surface: `crisol/api`):

- **`Outcome` loses `oTimeout` and `oSignal`.**  Their replacements carry
  the honest attribution: `oKilled` (a runner-authored kill — timeout or
  interrupt; `cause.by == cbRunner`) and `oCrashed` (the process
  ended on a signal/NT status the runner did not send).
  `outcomeString`/`isFailure` stay total over the remaining six values.
- **`EntrypointResult` loses its stored `outcome`, `exitCode`, `signal`,
  `achieved`, `peakRssBytes`, `cached`, and `flaky` fields.**  It now
  carries `compile`/`run: Phase`, and everything is derived: `outcome(r,
  policy)`, `cached(r)`, `flaky(r, policy)`, `hasFailRecords(r)`,
  `runResult(r)` (`Option[ProcessResult]` — absorbs the Phase variant
  check), and `failureLine(r, policy)` (render-grade one-liner).  `Summary`
  likewise drops `timedOut`/`signaled` for the `counts` array (indexed by
  `Outcome`) plus `notStarted`.
- **`CrisolInterrupted` is retired.**  A SIGINT/SIGTERM no longer raises:
  `runTests` returns normally with `RunReport.interrupted == true`
  (`status == rsInterrupted`, in lockstep), `exitCode == 128 + n` per
  RFC-0003, and `results`/`summary` populated with the honest partial
  emission set — entrypoints that completed plus those killed at shutdown
  (`oKilled`, cause "runner interrupt"); never-started entries are omitted
  and counted in `summary.notStarted` — instead of being lost.  `lastrun.json` is deliberately never persisted for an interrupted
  run, so `--failed` keeps anchoring on the last complete run.  The CLI
  binary now genuinely exits 130/143 — previously Nim's `quit()` saturated
  every code above 127 to 127 before it reached the real `exit()`.
- **`api.RunV1Schema` → `api.RunSchema`** (value `"crisol/run/v2"`).  The
  constant is deliberately unversioned: future RFCs extend v2 additively.
- **`crisol/api` re-exports the result-model facade:** `Phase`, `PhaseKind`,
  `ProcessResult`, `Exit`, `ExitKind`, `Cause`, `CauseBy`, `KillReason`,
  `Evidence`, `TreeObservation`, `Rusage`, `LimitsAchieved`,
  `OutcomePolicy` (all from `crisol/process/types`), plus the derived
  accessors above.
- **`runner.execute()` (uncontracted but embedded by some consumers)**
  gains `installSignals` (this call's own Supervisor installs and owns
  SIGINT/SIGTERM for the duration; library default off), plus the out
  parameters `interruptedOut`, `notStartedOut`, and `shutdownSignalOut`
  (the observed signum RFC-0003's `128+n` needs); it no longer raises
  `CrisolInterrupted`.  `crisol/signals`' `installSignalHandlers`/
  `pendingSignal`/`clearSignal` are gone — the sticky observability query
  `shutdownRequested(): Option[ShutdownSignal]` replaces them.
- **`crisol/spawn.nim` is deleted.**  Spawn/wait/kill live behind
  `crisol/process`'s Supervisor contract (backend ladder over
  `process/posixcore`/`posix`/`linux`/`windows`).  `spawn` was never part
  of the contracted `api` surface, but anything importing it directly must
  move to `crisol/process`.
- **`resultCacheFormatVersion` 1 → 3** (two bumps: the payload now stores
  the real run-phase `ProcessResult` and replays it byte-equal on a hit;
  the soundness-key fold shape changed with the limits re-home).  Existing
  cached results are discarded on upgrade (version-partitioned directory +
  header mismatch = miss); budget one full rerun of previously cached
  entrypoints.  Compile avoidance and the depgraph are unaffected.
- Children (compile and run) now spawn with **`projectRoot` as their working
  directory**, never the invoking shell's cwd (issue #17) — a root-relative
  compile flag such as `--path:src` now resolves identically from any
  invocation directory.  A test that read files relative to the crisol
  process's own cwd was already unsound; it now consistently sees
  `projectRoot` (isolated runs still chdir into their scratch dir).

**Added — `--strict-hygiene`** (CLI), `strict-hygiene #true` (crisol.kdl),
`RunOptions.strictHygiene` (library).  A would-be pass with an observed
escapee — a leaked same-process-group descendant still running at reap
time — is reported as a failure at every reporting boundary (exit code,
render, JSON/JUnit wire, `lastrun.json`).  Off by default: the escapee is
still visible (`[ESCAPEE]` tag, `evidence.escapees` on the wire) but does
not fail the run.  The CLI flag can only strengthen a config-file value
(true wins).  The result cache always stores and derives **unstrict**, so
flipping the flag never invalidates or poisons cached results — strictness
is re-applied at read-back time.

### ci: Linux CI baseline — honest exit codes, meta-test mechanism, serial timing leg (rfc-0007 slice A0)

crisol had no CI. `.github/workflows/ci.yml` now runs the suite on every push
to `main` and every pull request, two jobs (`test`, `timing`) each invoking
the toolchain image directly via `docker run` (not a `container:` job) so the
repo can be bind-mounted at `/workspace`, matching the paths baked into golden
fixtures and absolute-path-sensitive unit tests. `ci/fetch-deps.sh` reads
`milpa.lock` (the single source of truth) and clones the locked commit of
each dep straight from its git remote into `_deps/`, since CI has no milpa
CAS to symlink from.

**The nimble `test` task now honors `CRISOL_TEST_DIRS`** (colon-separated),
overriding the default `["tests/unit", "tests/integration"]` dir list. It
also now runs every discovered file to completion even after an earlier one
fails — no more truncation at the first failing file — and prints a
`FAILED: N file(s)` / `OK: N file(s)` summary.

**Load-bearing finding:** nimble 0.22.2's custom-task dispatch does not
propagate a failing task into a nonzero *process* exit code — a failing
task surfaces internally as `NimbleError` (`object of CatchableError`),
which nimble's own top-level handler displays but never turns into a
nonzero `exitCode` (only `NimbleQuit`, `object of Defect`, does that, and
it is unreachable from inside a task body). `nimble test` therefore always
exits 0 regardless of what the task itself does, `quit(1)` included —
confirmed by reading nimble's source and reproduced with a two-line
throwaway task. `ci/run-tests.sh` works around this: the `test` task writes
an explicit `OK`/`FAIL` marker file as its last action, and the wrapper
script — not bare `nimble test` — is what `./dev test`, `./dev timing`, and
every CI step now actually invoke; it derives the real exit code from the
marker and treats a missing marker as failure (fail-closed).

The mechanism is proven mechanically, not just asserted: `tests/meta/`
holds a single always-failing dummy (`test_fail_dummy.nim`), deliberately
outside the default `CRISOL_TEST_DIRS`, that only a CI meta-step (pointing
`CRISOL_TEST_DIRS` at `tests/meta`) ever runs — the meta-step requires that
run to fail, i.e. it asserts the *absence* of the historical "exit 0 on a
real failure" bug.

The six timing/rlimits-sensitive integration tests (`test_headofline`,
`test_mem_throttle`, `test_compile_not_run_budget`, `test_per_group_timeout`,
`test_max_jobs_overlap`, `test_rlimits_timing`) move from
`tests/integration/` to `tests/timing/` — they are deadline- and
scheduling-sensitive and flake under concurrent host load. `tests/timing/`
is outside the default dirs, so `./dev test` / a normal `nimble test` never
runs them; CI's `timing` job runs them serially and alone
(`CRISOL_TIMING_TESTS=1 CRISOL_TEST_DIRS=tests/timing`), never sharing a
runner with `test`. `./dev timing` gives the same leg locally.

Nim's compile cache (`~/.cache/nim`, redirected to `.ci-nimcache/` via
`XDG_CACHE_HOME`) is cached across CI runs with `actions/cache@v4`, keyed on
`milpa.lock` + `crisol.nimble`.

### BREAKING CHANGE — dependency graph format 5: the headers a `{.compile.}`d source `#include`s are tracked compile inputs; one-time full recompile (issue #16)

**Prior behaviour:** a `{.compile.}`d C/C++ source was in the closure
(format 4, issue #11) but nothing it `#include`d was.  A header-only edit was
invisible twice over: crisol neither recompiled the entrypoint nor selected
it under `--changed`, and Nim's own external-object cache — keyed on the
source's content and the cc command, never on headers — would have relinked
the stale object even if crisol had recompiled.

**New behaviour:** after a successful compile crisol derives a `cc -M` probe
from the exact compile command the nimcache manifest records for each
single-path external, keeps every reported header that resolves under a
tracked root (system headers are excluded by the same gate as every other
closure path), and folds those headers into the entrypoint's closure — so
the closure content hash, `--changed` selection and `crisol closure` all see
them.  Each entry now also records one record per external (source, object
basename, sorted header set, header content hash).  An external Nim served
from its own object cache — no compile command in the manifest this round —
carries its header set forward from the previous record; with no record to
carry, extraction fails closed (the entry is invalidated and the entrypoint
recompiles and is force-selected until it succeeds).

Before spawning `nim c`, the runner evicts from the persistent nimcache
every external object whose recorded header set no longer hashes to its
stored hash (a missing or unreadable header counts as changed), so Nim
recompiles exactly those objects.  A warm nimcache with no depgraph entry at
all (format discard, `crisol clean` GC, an invalidated record) has every
non-module object evicted so the next compile rediscovers headers through
`cc -M` instead of failing closed.  A failed eviction is a pre-compile setup
failure (`oSpawnError`), never a silently linked stale object.  Unchanged
headers evict nothing and recompile nothing.

`DepGraphFormatVersion` is now 5: an existing `.crisol/depgraph` is discarded
on first load and the **next run recompiles every entrypoint once**.  A v4
closure cannot be healed in place — it is missing whatever headers its
externals include, and its persisted manifest carries no compile command for
a cached external to re-derive them from.

**Not covered (by design):** `gorge` (a shell command, not a file input);
headers outside every tracked root (system and toolchain headers — a
toolchain change is keyed by the nimcache's toolchain fingerprint, not by
the closure).

**Migration:** nothing to do; budget one full-suite compile after upgrading.

### spawn: portable POSIX in place of two glibc-isms; macOS builds again (issue #18)

`spawn.nim` called `pipe2(O_CLOEXEC)` and `execvpe(3)`, both absent from
Darwin's libc, so crisol did not compile on macOS.  The status pipe is now
`pipe(2)` followed by `FD_CLOEXEC` on both ends — equivalent to `pipe2`
because crisol's executor is single-threaded by invariant, so no other thread
can fork between the two calls — and the child execs with POSIX `execve(2)`
on a path the **parent** resolves with `findExe` (PATH search iff the name has
no `/`, exactly `execvp`'s rule; `argv[0]` is preserved).  Resolving before
fork also keeps the async-signal-safe child window free of any PATH walking.
One behavioural consequence: a program that cannot be resolved is now a spawn
error at the call site rather than a child that `_exit(127)`s.  One code
path, no `when defined(linux)` — Linux CI exercises exactly what macOS runs.

### `crisol clean` dependency-graph GC now works on real graphs; failed persists can no longer leave a stale binary behind; load guard rejects relative `..` escapes (issues #12, #13)

**`clean` GC was dark (#12).**  `cleanOrphans` loaded the graph with
`loadDepGraph(config, "")`, and the loader discards the whole graph whenever
the stored Nim fingerprint differs from the requested one — so on every real
graph (always stamped with the probed fingerprint) `clean` saw zero entries,
dropped nothing and reported `0 depgraph entry(ies)`.  The loader is now
split by concern: `loadStoredDepGraph(config, discarded)` returns the graph
exactly as persisted (format check + tamper guard, header preserved) and
`loadDepGraph(config, nimVersion, discarded)` is that plus the freshness
view (fingerprint mismatch → empty graph with `dgdNimVersion` provenance, as
before).  `clean` uses the stored view, drops entries for deleted
entrypoints, saves only when it dropped something and always writes the
header back unchanged — the next `run` still compares against the real
fingerprint.

**A failed depgraph write no longer strands a binary (#13.3).**  The stable
binary was promoted before the depgraph was persisted and `saveDepGraph`
swallowed write errors, so a failed write left the OLD closure record on
disk next to the NEW binary; reverting the edit that caused the recompile
made the record hash fresh again and the binary built from the edited
sources was served.  `saveDepGraph` now returns `bool`; `recordClosure`
reports a failed persist as a recording failure (`dependency graph could not
be persisted`); and the runner discards the stable binary whenever the
closure could not be recorded for any reason (and whenever promotion itself
fails, instead of ignoring it), so the next run starts from `cdNeverBuilt`.
Invariant on disk after every compile: either the depgraph entry describes
the stable binary, or there is no stable binary.  `clean` reports `0`
dropped if its own save fails.

**Load guard covers relative paths (#13.1).**  The on-disk guard that drops
closure paths outside the tracked roots only examined absolute paths; a
tampered graph could carry `../../etc/passwd` and `closureContentHash` would
read it.  Every path is now resolved against the project root, normalized
and required to land under the project root or a `dep-roots` entry; kept
paths are stored verbatim.  No symlink resolution is applied (#13.2,
decided against): the closure extractor's tracking policy is lexical — a
symlinked source inside a tracked root is recorded at its lexical path and
hashed through the link — so a realpath-resolving loader would drop every
such file, break the stored hash and recompile those projects on every run,
for no added defence (a tampered graph yields a hash, never content).  This
is pinned by test.

**Migration:** none — the graph format is unchanged (v4).  A `clean` after
upgrading will drop the entries that earlier versions silently kept.

### BREAKING CHANGE — dependency graph format 4: closures cover every compile input; one-time full recompile (issue #11)

**Prior behaviour:** the per-entrypoint source closure named Nim *module*
sources only (decoded from the nimcache manifest's `link` array).  Three
classes of real compile inputs never produce a module object and were
therefore invisible: files pulled in with `include`, `staticRead`/`slurp`
targets, and `{.compile.}`d C/C++/ObjC sources (plus `{.link.}`ed prebuilt
objects and the entrypoint's `nim.cfg`/`config.nims`).  Editing any of them
neither recompiled the entrypoint (the closure content hash never saw the
file) nor selected it under `--changed` — false-fresh plus under-selection,
the same class of hole as issue #5 through a different door.

**New behaviour:** crisol compiles every entrypoint with `-d:nimBetterRun`
(injected by the single argv builder `compiledriver.nimCompileArgs`; not part
of the entrypoint's flags, so identities, slugs and `--failed`/`--changed`
keys are unchanged).  Under that define Nim writes a `depfiles` array into
the nimcache manifest — every file the compiler opened: modules, `include`d
files, `staticRead`/`slurp` targets, `nim.cfg`/`config.nims` — and
`extractClosure` unions it into the closure under the same tracked-root gate
as modules.  `{.compile.}`d sources are recovered from their `link` object
(Nim mangles the full source path into the object name, so this survives
warm recompiles where the `compile` array omits cached externals) and
`{.link.}`ed prebuilt objects by their raw path.  The per-run source index
now covers every regular file under a tracked root, not only `.nim`, so a
C source reached through `--path` resolves like a module.

`DepGraphFormatVersion` is now 4: an existing `.crisol/depgraph` is discarded
on first load and the **next run recompiles every entrypoint once** under
the new define.  A v3 closure cannot be healed in place — a closure missing
an input hash-matches itself forever, and its persisted nimcache manifest
(compiled without the define) carries no `depfiles` to re-derive from.

**Fail-closed cases (reported on stderr; the entry is invalidated so the
entrypoint is recompiled and force-selected every run until fixed):** the
tuple form `{.compile: ("pattern*.c", "$1.o").}` — Nim erases the source
path from the object name, so the source cannot be tracked; use the
single-path `{.compile: "file.c".}` form.  A `link` entry that is not an
absolute path (`--noAbsolutePaths`) is likewise unattributable.  A manifest
with no `depfiles` key at all (an entrypoint compiled by a Nim that does not
honour the define) is refused rather than trusted.

**Not covered (by design):** `gorge` runs a shell command, not a file input.
The C headers `#include`d by a `{.compile.}`d source were not tracked by
format 4 — see the format 5 entry above (issue #16).

**Migration:** nothing to do; budget one full-suite compile after upgrading.

### Fixed — report bodies no longer print raw control bytes from config/binary-origin text (issue #14)

Diagnostics were already routed through `sanitizeControlBytes`; the human
report BODIES were not. `crisol list` / `run --dry-run` plan rows (path,
group, flags, gate reason), the `run` report (entrypoint path, protocol
record names and messages, slowest-N sections) and `crisol closure` (path,
group, closure file paths) now sanitize each such field at the render layer,
so a group named `"x\u{1b}[2Jy"` or a test named with a TAB can no longer
emit ANSI/control bytes on stdout. The sink is deliberately not the place:
crisol's own color codes must pass through. The raw captured output tail of
a failing/opaque binary is not sanitized — it is the binary's own output and
may legitimately be colored. JSON output was already safe (std/json escapes).

### BREAKING CHANGE — an explicit path owned by several groups now runs every leg (issue #10)

**Prior behaviour:** `crisol run <path>` / `crisol list <path>` where `<path>`
matched the globs of more than one configured group resolved to the
**first-declared** group only, and printed
`crisol: path "..." matches multiple groups (a, b); using "a"` on stderr.

**New behaviour:** the path runs once **per** owning group — one entrypoint
("leg") per group, each under that group's effective flags — exactly what
default discovery yields for that file. Nothing is reported as ambiguous;
the plan listing shows each leg. `--group <name>` alongside the path narrows
the candidate owners (unchanged). A path matched by no group is still ad hoc
(global flags + the RFC-0001:409 warning, unchanged).

**Rationale:** a group denotes (globs × flags), and an entrypoint's identity is
(path, flags). The same file under two flag-sets is two distinct entrypoints —
separately compiled, cached, reported and impact-selected. Naming the file
selects the file; silently keeping one leg and dropping the rest turned a
matrix into a hidden choice (`crisol run tests/unit/test_x.nim` "passed" while
the orc leg never ran). Running every leg is the only reading under which an
explicit path and `crisol run` agree on what that file's tests are.

**Migration:** to run one leg of a multi-group file, add `--group <name>`.
Library embedders: `DiscoveredSet`/`PlanReport`/`ClosureReport` lose
`ambiguousPaths`, the `AmbiguousPath` type is gone, and
`render.pathFlagsWarnings` no longer takes it (`pathFlagsWarnings(adHocPaths,
withinGroups)`).

### Fixed — positional glob selectors now inherit group flags; repeated selectors do not double-schedule

`crisol run 'tests/unit/test_*.nim'` matched the glob as a literal string
against each group's globs, so it never attributed to a group and ran every
file ad hoc with global flags only (the issue #3 flag drop surviving for glob
selectors). Selectors are now expanded to concrete files first and each file
is attributed to its owning group(s); a selector matching nothing on disk is
still reported as before. Discovery also dedups by entrypoint identity
(path, group), so naming a file twice — or a path plus a glob covering it —
schedules each leg once.

### Changed — plan/v1 rev 3 and run/v1 rev 14 carry each leg's `flags` (issue #10)

Every entrypoint object in `crisol list --json` / `run --dry-run --json`
(`crisol/plan/v1`, `schemaRevision` 2 → 3) and in `crisol run --json` /
`lastrun.json` (`crisol/run/v1`, 13 → 14) gains `"flags": [...]` — the
effective, ordered compile-flag list (global then group) that identifies the
leg; always present, empty array when none. The human `crisol list` row is
now `path  [group]  <flags>  decision` (flags omitted when empty). Additive;
older readers are unaffected.

### BREAKING CHANGE — `--base` without `--changed` is now an error (exit 3)

**Prior behaviour:** `crisol run --base <ref>` without `--changed` emitted a
warning to stderr and then ran normally (exit 0), silently ignoring the base
ref.

**New behaviour:** `crisol run --base <ref>` without `--changed` exits
immediately with code 3 and an error message:

```
crisol: error: --base requires --changed (a base ref without impact selection has no effect)
```

**Rationale:** `--base` is meaningful only when combined with `--changed`
(impact selection via git diff).  Supplying `--base` alone is always a
mistake; a silent no-op masked the error and produced a confusing full run.

**Migration:** If you shell out to `bin/crisol` and pass `--base` without
`--changed`, add `--changed` or remove `--base`.  amoxtli shells out to
`bin/crisol` and is directly affected — update its invocation before
upgrading.

### BREAKING CHANGE — dependency graph format 3: one-time full recompile (issue #5)

**Prior behaviour:** the per-entrypoint source closure was derived from the
nimcache manifest's `compile` array.  That array is Nim's per-invocation C
work list — complete only on a cold nimcache, partial on a warm recompile,
and empty when an edit changes no generated C.  The first incremental
recompile therefore persisted a truncated or empty closure, after which the
entrypoint could never go stale: compile avoidance, the result cache and
`--changed` selection all reported it fresh forever (masked-red incident).

**New behaviour:** the closure is derived from the manifest's `link` array,
which is complete on every compile.  `DepGraphFormatVersion` is now 3: an
existing `.crisol/depgraph` written by an older crisol is discarded on first
load, so the **next run recompiles every entrypoint once** and re-records
trustworthy closures.  Entries written by the old extractor cannot be healed
in place — a truncated closure hash-matches itself forever — which is why the
whole graph is discarded rather than migrated.

**Also:** an empty closure is never recorded (it is a crisol defect, reported
on stderr); when a compile succeeds but its closure cannot be recorded, the
entrypoint's dependency record is invalidated so it is recompiled and
force-selected next run instead of serving the previous, stale record.
Entrypoints outside `projectRoot`/`dep-roots` (library-API callers only) now
warn and recompile every run instead of being silently fresh forever. A
result whose closure could not be recorded is also NOT written to the result
cache (reported as `cacheDecision` `"closureUnrecorded"` in `--json`).

**Migration:** nothing to do; budget one full-suite compile after upgrading.

### Changed — search-path-resolved modules are now in closures (issue #8)

**Prior behaviour:** a module the compiler resolved through any nim search
path other than `projectRoot`, `projectRoot/src`, or a configured `dep-roots`
entry (+`/src`) — e.g. shared test helpers made importable by a
`tests/config.nims` `switch("path", thisDir())`, or a first-party library on
`--path:lib/x/src` — was silently absent from every closure.  Editing such a
module re-selected nothing under `--changed` and never invalidated the
compiled binary.

**New behaviour:** crisol builds a per-run index of every `.nim` file under
`projectRoot` (dot-directories, `nimcache`, the state dir, and symlinked
directories are skipped) plus each `dep-roots` entry, and resolves a
search-path-relative module to every indexed file that ends with that
relative path.  No configuration is needed for in-tree helpers; `dep-roots`
remains the opt-in for out-of-tree content (e.g. `_deps/<x>` symlinks into a
content store).  Closures may grow (they are now complete), so expect a
one-time recompile of entrypoints whose closure gained members.

### Fixed

- **closure:** `@p`/`@n` bodies with leading `..` components — the shape Nim
  emits when the shortest relative path to a module runs from a `--path`
  root that isn't the module's ancestor (e.g. an in-root `../lib/x` import
  that is shorter measured from `--path:src` than from the importing file),
  or when a search-path root is reached through a symlink and Nim
  realpath-canonicalizes the resolved source (e.g. a milpa `_deps/<dep>`
  symlink into the CAS) — are now resolved.  Previously `SourceIndex.lookup`
  suffix-matched the *whole, unstripped* body against indexed absolute
  paths, so any body containing `..` matched nothing and the module silently
  dropped out of the closure (unsound: an edit to that file would not
  re-select the entrypoint under `--changed`).  The index now records each
  file's realpath alongside its lexical path, and `lookup` strips every
  leading `""`/`"."`/`".."` component before matching against either — a
  pure widening of the match, so still sound under the R7 over-selection
  policy.  The reported/recorded path remains the lexical one.  A follow-up
  found this still missed a related shape: a realpath-relative `@p`/`@n`
  body whose file lives under a directory `walkForIndex` prunes for WALK
  COST (a dot-dir or a `nimcache` dir) *inside* a tracked root — e.g. a
  milpa `_deps/<dep>` symlink whose target sits under a dot-dir inside
  projectRoot itself, rather than in an external CAS, with no `dep-roots`
  entry naming that dot-dir directly.  The compiler resolves and
  realpath-canonicalizes the import fine (the symlink is on the search
  path), but nothing under the pruned directory was ever indexed, so
  `SourceIndex.lookup` misses and the module silently dropped out of the
  closure.  That pruning is a walk-cost decision, not a tracking decision:
  when `lookup` returns no match at all, `resolveMangledAll`'s `@p`/`@n`
  branch now falls back to an existence check — the same stripped suffix
  joined onto each of `index.roots` in turn, keeping whichever candidate(s)
  exist on disk (`fileExists`/`symlinkExists`).  Sound (every candidate is
  under a tracked root by construction, and nothing is fabricated when no
  candidate exists), and consistent with the R7 over-selection policy when
  more than one root matches.
- **closure:** an `@m`-mangled `link` entry (Nim's entrypoint-directory-
  relative candidate, the mangler's default choice whenever it is not
  strictly longer than the `@p`/`@n` search-path-relative one) can *also*
  carry a realpath through a symlinked dep-root when the entrypoint is
  shallow enough for `@m` to still win — e.g. a depth-1 entrypoint
  importing a module via a milpa `_deps/<dep>` symlink into the CAS.
  Previously `resolveMangledAll` resolved `@m` bodies with a single
  `(entrypointDir / body).normalizedPath` candidate; when that candidate
  fell outside every tracked root (the realpath-through-symlink case) the
  under-tracked-root filter silently dropped it, so the dep was absent from
  the closure and an edit to it never re-selected the entrypoint under
  `--changed` (unsound).  A first fix (commit 38e094e) recovered the
  candidate by unioning it against `@p`/`@n`'s SUFFIX-based `SourceIndex`
  lookup, but review found that fallback over-selects: an `@m` body that
  escapes every tracked root because it names a genuinely UNTRACKED,
  out-of-root import (no dep-root of its own) could still suffix-match an
  unrelated same-basename/same-suffix decoy elsewhere in the tree, wrongly
  pulling it into the closure and churning `closureHash`/`--changed`
  selection.  `SourceIndex` now also indexes every file by its realpath
  (`byReal`), and the `@m` fallback resolves through an EXACT realpath
  match (`lookupByReal`) instead of a suffix scan: a genuine
  symlinked-dep-root escape has an indexed file at that exact realpath and
  is recovered at its lexical path, while an untracked import has none and
  correctly adds nothing.  Separately, when the entrypoint's OWN directory
  is itself reached through a symlink whose lexical path depth differs from
  its real path depth, the compiler computes the `@m` body from the real
  directory; joining that body onto the lexical directory (the prior
  behaviour in all cases) could land on a bogus, nonexistent path instead of
  the real dependency.  `resolveMangledAll` now detects that case
  (`expandFilename(epDir) != epDir`) and resolves the body from the real
  entrypoint directory instead, via the same exact-realpath lookup.  A
  follow-up review round found `expandFilename(epDir)` itself insufficient:
  Nim's `@m` base is `parentDir(realpath(ENTRYPOINT FILE))`, not `realpath`
  of the entrypoint's *directory* — a symlinked entrypoint FILE sitting
  inside an otherwise ordinary, non-symlinked directory (crisol's own
  discovery admits such entrypoints) left `expandFilename(epDir) == epDir`,
  so the code wrongly took the lexical-candidate branch and recorded a
  bogus, nonexistent sibling — `closureContentHash` then raised on the
  missing file on every subsequent run, permanently invalidating the entry
  (a perpetual "could not record its source closure … force-selected"
  warning, precision lost for that entrypoint).  `realEpDir` is now computed
  from `parentDir(expandFilename(entrypointPath))` (falling back to
  `expandFilename(epDir)`, then `epDir`, on an `OSError`), which subsumes
  the symlinked-directory case too.  Also, the real-candidate branch's
  fallback (when `lookupByReal` misses — e.g. a dependency deleted since the
  index was built) no longer falls back to the lexical candidate
  unconditionally: that candidate is not what the compiler actually saw in
  this branch, and could itself be a bogus-but-in-root path.  It is now used
  only when it exists on disk (`fileExists`/`symlinkExists`); otherwise the
  real candidate itself is kept and left to `extractClosure`'s ordinary
  under-tracked-root filter, exactly like any other out-of-root import.
- **closure:** `decodeBody` now decodes Nim's `@c` (`:`) and `@h` (`#`)
  mangling escapes in addition to `@s` and `@@`; a module path containing a
  colon or hash character previously failed to decode correctly.
- **depgraph:** a discarded depgraph (recorded `nimVersion` differs from the
  current compiler fingerprint, or `formatVersion` differs from
  `DepGraphFormatVersion`) now surfaces as a structured warning in
  `run`/`list`/`closure` output and JSON, instead of silently falling back
  to an empty graph.  Previously, after a Nim upgrade, `crisol closure --all`
  reported `recorded:false` for every entrypoint with exit 0 —
  indistinguishable from "never ran" — and `run`/`list` silently
  recompiled and force-selected everything with no explanation.
- **closure:** a positional `<entrypoint>` path whose only match was
  discovered but GATED OUT (e.g. an unset `gate` env var) now prints the
  (empty-`entries`) report and exits 0, matching `run`'s `zrkAllGated`
  contract for the identical selection.  Previously it was treated the same
  as "matched no discovered entrypoint at all" and exited 3 — a gated-out
  entrypoint is a legitimate discovery result, not a configuration error.
  `ClosureReport` gained a `gatedOut` field (mirroring `PlanReport.gatedOut`)
  to distinguish the two cases; `crisol/closure/v1` JSON now serializes it
  too (schema revision bumped to 2), mirroring `crisol/plan/v1`'s existing
  `gatedOut` array.
- **run:** the zero-runnable "no entrypoints matched" branch (exit 3) now
  populates `RunReport.plan`, so its plan-phase config warnings (including
  the depgraph-discard warning) reach stderr (and `RunReport.plan.warnings`
  for library consumers) instead of being silently dropped. Previously that
  branch built a bare `RunReport` without `plan`, so the CLI's
  `for w in rr.plan.warnings` loop had nothing to iterate.
- **closure:** a positional `<entrypoint>` selection whose only match was
  discovered but GATED OUT now prints the gate-skip diagnostic
  (`skipped group "..." — ...`) to **stdout** in human (non-JSON) mode,
  mirroring `run`'s `zrkAllGated` case exactly (both the destination and the
  wording). Previously `renderClosure` only walked `.entries` and ignored
  `.gatedOut` entirely, so a fully-gated selection exited 0 and printed
  nothing — a silent, empty-looking success indistinguishable from an error
  swallowed upstream; a first fix routed the line to stderr, which was
  itself a parity gap against `run`'s stdout placement, now closed. `--json`
  mode is unaffected: `crisol/closure/v1` already serializes `gatedOut`, and
  nothing but the JSON document is written to stdout.
- **security:** untrusted-origin diagnostic text reaching stdout/stderr is
  now sanitized through ONE shared primitive,
  `ioutils.sanitizeControlBytes` (`depgraph.nim`'s `sanitizeOneSegment`
  delegates to it as well).
  Coverage is broadened well past `ConfigWarning.message` and the ad-hoc /
  ambiguous-path warning lines (already covered) to every other DIAGNOSTIC
  write of untrusted-origin text: every `CrisolError.msg` (including config
  parse errors, which embed nkdl's raw offending source line — an
  unsanitized ESC or other control byte in a `crisol.kdl` comment or string
  previously reached the terminal/CI log raw), `RunReport.error`,
  `gateSkipMessages` lines (group names / gate env-var names read back out
  of config), and JUnit-report write-error messages. Report BODIES —
  `render`/`renderPlan`/`renderClosure`'s own columns (entrypoint paths,
  group names) — are NOT sanitized; only the diagnostics listed above are.
  Sanitization is applied PER LINE
  (control bytes replaced with `'?'`; `'\n'` itself is preserved) so
  legitimately multi-line text — a config error's caret block — keeps its
  line structure; bytes 0x80-0x9f are left alone since they are ordinary
  UTF-8 continuation bytes, not interpretable C1 controls.

### Added

- `crisol closure <entrypoint>... [--json]` / `crisol closure --all [--json]` —
  read-only depgraph introspection (issue #9).  Emits one entry per planned
  entrypoint × group/flag-set: `path`, `group`, `flagHash`, `recorded`,
  sorted `closure`, `closureHash`; JSON schema `crisol/closure/v1`
  (revision 1).  Uses crisol's own config, discovery, group-flag resolution
  and depgraph loader (including the nim-version probe), so downstream
  tools never re-implement them.  No lock, no compile.
- `crisol closure` now accepts `--config <path>` / `--config=<path>`, matching
  `run`/`list`/`clean`.  Previously `closure` always walked up from the
  current directory for `crisol.kdl`, ignoring any explicit config override.
- `crisol closure` now prints the same ad-hoc / ambiguous path diagnostics
  `run`/`list` print (`crisol: path "..." matched no configured group; using
  global flags` / `crisol: path "..." matches multiple groups (...); using
  "..."`) to stderr when a positional `<entrypoint>` argument matches no
  configured group's globs, or matches more than one.  `ClosureReport`
  gained `adHocPaths`/`ambiguousPaths` fields (populated by
  `api.closureReport()`) to carry this; the `crisol/closure/v1` JSON
  document is unchanged (revision stays 1) — `crisol/plan/v1` does not
  serialize the equivalent `DiscoveredSet` fields either, so closure/v1
  stays symmetric with it and reports the same information as stderr text.
- `crisol closure <entrypoint>...` now exits 3 with `crisol: no entrypoints
  matched — check config/globs` when a given path matches no discovered
  entrypoint, matching `run`'s behaviour.  Previously it silently printed an
  empty report and exited 0, indistinguishable from a legitimate empty
  `--all` result.  `crisol closure --all` with zero discovered entrypoints is
  unaffected: it still exits 0 with an empty `entries` array.
- `crisol clean --config <path>` — `clean` now accepts `--config <path>` so it
  honours a project's custom `state-dir` setting.  Previously `clean` always
  used the default `.crisol/` directory regardless of config.
- `crisol --version` / `-V` — prints `crisol <version>` and exits 0.
- `crisol init [path] [--force]` — writes a canonical starter `crisol.kdl` to
  `path` (default `./crisol.kdl`); refuses to overwrite without `--force`.
- `--help` / `-h` now writes usage to **stdout** and exits 0.  (Previously
  printed to stderr with a non-zero code in some paths.)
- `clean` subcommand and `-j` / `-t` short forms documented in `--help` output.
