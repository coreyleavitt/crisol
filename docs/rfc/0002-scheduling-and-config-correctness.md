# RFC-0002 — Scheduling & config correctness

**Status:** Implemented — full rfc-flow complete; committed 5c4de13 and pushed 2026-06-13
**Date:** 2026-06-13
**Author:** Corey Leavitt

---

## Summary

Four correctness/capability fixes to the crisol executor and config, surfaced
while shaping amoxtli's test suite for crisol (amoxtli RFC-0015 WS-C). Each
removes a place where a consumer is currently forced to *work around* a crisol
gap:

| # | Feature | The gap today | What it unblocks |
|---|---------|---------------|------------------|
| **A** | Per-group run timeout | `Group.timeoutSecs` is parsed (`config.nim:164`) but **never applied** — the executor uses one global `config.timeoutSecs` (`runner.nim:528-534`). Dead data. | Give a slow integration group a longer budget than a fast unit group. |
| **B** | Memory-aware admission | The scheduler is a fixed worker pool: `jobs = max(1, cpu-2)` (`planner.nim:173`), zero RSS awareness (`runner.nim:633`). On a small/CI box, N parallel cold `nim c` compiles (~400–600 MiB each for a large closure) can OOM. Self-tuning via `memprobe.nim` (probe) + `admission.nim` (`AdmissionController`). | Self-tuning concurrency; deletes the consumer's "measure peak RSS by hand and freeze a static `jobs`" ritual and the CI OOM risk. |
| **C** | Per-group concurrency cap | No way to mark a group as serial / capped. `Group`/`Entrypoint` carry no concurrency field; one flat slot array. | An escape hatch for genuinely-unisolable test files, without serializing the whole suite. |
| **D** | Unknown-config-key diagnostics | Unknown keys are silently dropped (`else: discard` at `config.nim:243` top-level and `:186` group-level). | A typo'd config key fails loudly instead of silently doing nothing. |

All four are small, additive, and independently testable. None changes the
`discover → applyGates → [narrowByDiff] → plan → execute → report` pipeline
shape; they add data to `Group`/`Entrypoint` and one admission predicate to the
poll loop.

---

## Motivation

crisol's leverage is parallelism. But the executor today exposes three blunt
edges and one silent footgun that push complexity back onto every consumer:

1. **Timeouts are one-size-fits-all.** A suite with a 5s unit tier and a 200s
   integration tier must set the *global* timeout to the max, so a hung unit
   test wastes 200s before the runner kills it. The per-group field already
   exists in the schema and the type — it was simply never wired to the
   executor. This is a latent-bug fix, not a new feature.

2. **Concurrency is memory-blind.** Every amoxtli test entrypoint cold-compiles
   the full daemon/fresco closure; peak RSS is dominated by **parallel `nim c`
   compiles**, not test runtime. `cpu-2` is the right *CPU* answer and the wrong
   *memory* answer: on an 8-core/64 GB dev box it underutilizes; on a
   2-core/4 GB CI runner it can OOM. The consumer's only recourse today is to
   measure peak RSS once and freeze a hand-tuned `jobs` number that is stale the
   moment the closure or the box changes. The runner already polls every live
   child every 25ms (`runner.nim:557`) — it is the right place to make
   admission depend on actual available memory.

3. **All-or-nothing parallelism.** crisol has no per-file "serial" annotation,
   so hermeticity is the *only* isolation mechanism. Hermeticity is the correct
   fix for the common case (a fixed temp path is a latent bug regardless of the
   runner), but there will always be a residue of genuinely-unisolable tests
   (a test asserting wall-clock timing, one that must bind a fixed well-known
   port, one exercising a true process-global singleton). For those, the answer
   is a scoped concurrency cap — not rewriting the test to pretend it is
   isolable, and not serializing the entire suite.

4. **Silent misconfiguration.** `flags`, `globs`, `jobs`, `timeout-secs`,
   `gate`, … are matched by name; anything else is `discard`ed. A typo
   (`timeout-sec`, `glob`) silently does nothing — the worst failure mode for a
   config file, because it looks like it worked.

This RFC closes all four against crisol's own PhD-CS bar.

---

## Goals

1. Apply each group's `timeout-secs` to the run phase of its entrypoints,
   falling back to the global timeout when unset (0).
2. Make executor concurrency self-tune to available system memory, so a cold
   full run neither OOMs a small box nor underutilizes a large one — with no
   per-consumer hand-tuning, and a hard progress guarantee (never deadlock).
3. Provide a per-group concurrency cap (`max-jobs`, with `1` = serial group) as
   the escape hatch for genuinely-unisolable entrypoints.
4. Surface unknown config keys as warnings (not silent drops, not hard errors —
   forward-compatibility with newer keys on older crisol must hold).
5. Additive at the config-key level (no new *required* keys; absent keys ⇒
   prior behavior). Memory self-tuning is **enabled by default where the probe
   (incl. cgroup) is available**, degrading to today's fixed-pool behavior where
   it is not. This changes scheduling behavior for existing consumers (e.g.
   amoxtli) on upgrade — strictly safer (prevents OOM), degrades to identical
   where probe absent. Note: `--jobs 1` (or `jobs 1`) already serializes ⇒ B's
   gate is naturally inert (the progress override fires every admit).

## Observability

- `crisol list` / `--dry-run` plan output (`renderPlan` + `crisol/plan/v1`)
  exposes each entrypoint's resolved `effectiveRunTimeoutSecs` and its group
  `maxJobs`. Implementation: `PlannedEntrypoint` gains a resolved
  `runTimeoutSecs` field (populated where the plan is built, from
  `effectiveRunTimeoutMs`); `maxJobs` is read from the entrypoint's `Group` via
  the `Config` already available to `planToJson`. Existing golden tests
  (`test_planview.nim`, `test_jsonout.nim`) will need their fixtures updated when
  these fields are added — call this out in the slice that adds them.
- When B holds idle slots memory-blocked for >~5s, the progress line shows a
  "memory-throttled" signal so a throttled run doesn't look hung.
- `compileSkipped` is emitted in `crisol/run/v1` per-entrypoint (the field
  already exists on `EntrypointResult` but `toJson` never wrote it — completing
  the schema). Assigned to **S2a** (the first slice that touches output schemas).
  Additionally, `crisol/run/v1` gains a top-level `memThrottledSlots: int`
  (count of slots that were ever memory-blocked), so a `--json` consumer can
  distinguish "slow because memory-throttled" from "slow because flaky." The
  `AdmissionController` already holds the state to compute it.
- Config key naming rationale: `jobs` (global target) vs `max-jobs` (per-group
  cap) — coherent; memory keys (`mem-*-mb`) use MB for human readability, while
  `max-output-bytes` uses bytes (document the distinction).

## Non-Goals

- **Per-group *compile* timeout.** Only the run timeout (`timeout-secs`) is
  per-group here; compile timeout stays global. (Compile cost is bounded by the
  memory admission work in B anyway.)
- **Cross-group mutual exclusion / global "run alone" semantics.** `max-jobs`
  caps concurrency *within* a group; it does not guarantee a capped entrypoint
  runs alone relative to *other* groups. Not in v1. Documented workaround: put
  all mutually-exclusive files in ONE group with `max-jobs 1`. A global
  "run-alone" level is a separate larger feature.
- **Non-Linux memory probing.** The memory probe reads `/proc` and `/sys/fs/cgroup`
  (Linux). crisol is already POSIX/Linux-centric (`waitpid`/`killpg`/poll loop).
  On a platform where the probe returns `none`, admission cleanly degrades to
  today's fixed `jobs` pool — memory awareness is best-effort, never
  load-bearing for correctness.
- **A strict/fail-on-unknown-key config mode.** D warns; a `--strict-config`
  flag can come later if wanted.
- **CLI flags for the memory keys.** `mem-budget-mb`, `mem-aware`, and the seed
  overrides are config-file-only in v1 (set in `crisol.kdl`, or a CI-specific
  file via `--config`). Existing `--jobs`/`--timeout` mirror their keys, but
  the memory knobs are CI-environment settings better captured in a committed
  config than a flag; a `--mem-budget-mb` flag can be added later if a concrete
  need appears. (Judgment call — flagged in the round-2 report.)
- **User-facing config-key documentation.** The `config.nim` header comment is
  the authoritative reference for the new keys in v1; README / `crisol help
  config` updates are out of scope.

---

## Design

### Feature A — per-group run timeout

`Group.timeoutSecs` already exists (`types.nim:23`, `0 = inherit global`). It is
parsed but never reaches the executor because `Entrypoint`
(`types.nim:56-63`) carries no timeout and `execute()` reads only
`config.timeoutSecs` (`runner.nim:532-534`).

**Resolution is data-driven, computed once, at the boundary where group → file:**

- Add `runTimeoutSecs*: int` to `Entrypoint` (`0 = inherit global`). It does
  **not** participate in the depgraph key (the key is `(path, flagHash)`), so
  freshness/impact selection are unaffected.
- `discover()` (`discover.nim:204`, where each `Entrypoint` is minted from its
  `Group`) copies `group.timeoutSecs` into `ep.runTimeoutSecs`.
- Add `runTimeoutMs: int` to the `Slot` type; set it at slot setup time
  (`spawnCompileStable` / `spawnRunDirect`) from `effectiveRunTimeoutMs(ep,
  config)`. `pollSlot` reads `slot.runTimeoutMs` when transitioning
  `spCompiling → spRunning`, removing the global `runTimeoutMs` parameter from
  `pollSlot`. This ensures the per-entrypoint deadline reaches the
  compile→run transition inside `pollSlot`, not only the outer call sites.

A tiny pure helper `effectiveRunTimeoutMs(ep, config): int` keeps the
fallback logic unit-testable in isolation.

`slot.runTimeoutMs` is a stored *duration*, consumed only by `spawnRun` to set
`slot.deadline = now + runTimeoutMs` at the moment of the `spCompiling →
spRunning` transition. It is never used to check a deadline during
`spCompiling` (that phase is bounded by the global compile timeout). Therefore
the run deadline anchors at **run start**: a long compile does not consume the
run budget.

The `clean` subsystem and depgraph key are unaffected — `runTimeoutSecs` is
execution metadata, not a compilation dimension, and does not feed the
`(path, flagHash)` key or the slug.

### Feature B — memory-aware admission control

**Principle.** Admit a new slot only when the system can be expected to hold one
more concurrent job without exhausting memory — measured against *currently
available* memory, not a fixed budget, so it self-tunes to the box and to
whatever else is running. Always admit at least one slot (progress guarantee),
so a single job larger than the whole budget runs (alone) rather than
deadlocking.

**Three modules, cleanly separated (probe / decision+state / wiring):**

#### B1 — `memprobe.nim` (effectful I/O, Linux-only)

Functions take an injectable `read` proc seam for unit-testability:

- `availableMemBytes(read = readFile): Option[int64]` — computes the available
  budget as the **min of**:
  - (a) `MemAvailable` from `/proc/meminfo`, and
  - (b) the **cgroup limit minus current usage** — cgroup v2
    `/sys/fs/cgroup/memory.max` & `memory.current` (treat literal `max` /
    `0x7ffffffffffff000` as "no limit"), falling back to cgroup v1
    `memory.limit_in_bytes` & `memory.usage_in_bytes`.

  Returns `none` only if neither source is readable. **The cgroup step is
  load-bearing: in a CI container `/proc/meminfo MemAvailable` reports the HOST
  memory, not the container's limit — using it alone re-introduces the OOM
  problem B exists to prevent.**

  With `mem-budget-mb > 0` AND probe `none`, treat the budget as the total
  available so B still works in that configuration. With `mem-budget-mb == 0`
  AND probe `none`, B is inert.

- `procGroupRssBytes(pid, read = readFile): Option[int64]` — sums `VmRSS`
  (conservative upper bound; `RssAnon` would be tighter but VmRSS-sum is the
  safe over-estimate) over all processes in the slot's process group. Invariant:
  `nim c`'s `gcc`/`cc1`/`as`/`ld` children inherit the slot's pgid (child does
  `setpgid(0,0)` then forks; children inherit), so compile RSS hogs ARE counted.
  The `mem-per-job-mb` seed covers any residual undercount.

Both never raise. A `none` from `availableMemBytes` makes B inert globally. On
`procGroupRssBytes == none` in `onSlotFinish`: release `committed` by
`token.reserved` (same as the success path — the reservation is always undone)
and do NOT update `estJobPeak` (no observation was made). The earlier
"treated as `estJobPeak`" phrasing applied only to reservation bookkeeping,
which the token now handles directly.

#### B2 — `admission.nim` (pure decision + mutable controller state)

Replace the flat `admitAnother` function with an `AdmissionController` object
that owns the mutable admission state:

```nim
type
  SlotToken* = object        # opaque reservation handle, returned by admit
    group*:    string        # group this slot belongs to
    reserved*: int64         # bytes reserved in `committed` for this slot

  AdmissionController* = object
    jobsCap*:      int                 # plan.jobs (CPU bound, hard upper limit)
    estJobPeak:    int64               # adaptive global max; seeded by mem-per-job-mb
    safety:        int64               # reserve margin
    committed:     int64               # sum of in-flight reservations
    groupCap:      Table[string, int]  # from Config.groups; only groups WITH a cap
    groupInflight: Table[string, int]
    probe:         proc(): Option[int64]  # injected; availableMemBytes by default
    availSnapshot: Option[int64]          # cached once per fill pass

proc initAdmission*(cfg: Config; plan: RunPlan;
                    probe: proc(): Option[int64] = availableMemBytes): AdmissionController
proc refreshAvail*(ac: var AdmissionController)          # snapshot probe once per fill pass
proc admit*(ac: var AdmissionController; group: string;
            decision: CompileDecision): Option[SlotToken]
proc release*(ac: var AdmissionController; token: SlotToken)        # spawn-failure rollback
proc onSlotFinish*(ac: var AdmissionController; token: SlotToken; rss: Option[int64])
```

`admit` returns `some(token)` iff **group-not-at-cap** AND
(**memory-admits** OR **progress-override**); otherwise `none`. On `some`,
the reservation (`estJobPeak` for a cold compile, `mem-per-run-mb` for
`cdSkipFresh`) is added to `committed` synchronously and recorded in
`token.reserved`, and `groupInflight[group]` is incremented — all before the
next admit in the same fill pass is evaluated. `mem-budget-mb` clamping of the
raw probe value happens inside `refreshAvail`, not at the call site.

The **progress override** fires only when `liveCount == 0` **across all
groups** (global), bypassing ONLY the memory gate — **never the group cap**.
Because the override is global, a memory-blocked group whose own in-flight
count is zero will still wait while *any other* group has a live slot: its
first slot is admitted only once the system is fully idle. This is a bounded
starvation window (the live slots will finish), not a deadlock; v1 accepts it
and does not add per-group progress guarantees.

**`committed` is a forward reservation, released per slot.** `admit` adds
`token.reserved` to `committed`; `onSlotFinish` (or `release` on spawn
failure) subtracts *that same* `token.reserved` — the amount is carried on the
token, never recomputed from a possibly-ratcheted `estJobPeak`, so `committed`
can never go negative. The fill loop admits multiple slots per 25ms pass
against one `availSnapshot`; without per-admit reservation a burst overshoots
the budget before any RSS ramps.

**The double-count is intentional.** While a slot lives, its real RSS is
*already* reflected in the probe (`MemAvailable` / cgroup `current` have
fallen), *and* its `token.reserved` still sits in `committed`. The admission
predicate `availSnapshot - committed - safety >= reserved` therefore guards
pessimistically by up to one reservation per in-flight slot during ramp-up —
deliberate conservatism, not a bug. Do NOT subtract live-slot
`procGroupRssBytes` from `committed` to "correct" it; that reintroduces the
burst overshoot. At `onSlotFinish` the slot's RSS has already landed in the
probe and `committed` drops by `token.reserved`, returning to correct steady
state.

**`cdSkipFresh` slots** use a much smaller run-peak estimate (new
`mem-per-run-mb`, default ~64 MiB) instead of `estJobPeak`, because warm slots
skip the compile phase entirely — else incremental runs get falsely serialized.
`admit` takes a `decision: CompileDecision` parameter to select the right
estimate.

**`estJobPeak` adaptivity:** updated in `onSlotFinish` (and may sample live
slots) as `max(observed, estJobPeak)`. Global (not per-group) for v1 — a global
max is conservative (over-estimates cheap jobs ⇒ slightly fewer slots) and
simpler; per-group is a future internal field requiring no interface change.

Updates are **monotonic non-decreasing** (`max(observed, estJobPeak)`), so a
low-RSS `cdSkipFresh` completion never lowers the estimate — a mixed batch
with early fresh-run completions cannot open a window that over-admits cold
compiles. **Known limitation:** because the max only ratchets up, a single
outlier compile (e.g. one entrypoint pulling a huge optional closure) raises
`estJobPeak` for the remainder of the run, over-serializing subsequent cheap
slots on a memory-constrained box. v1 accepts this; the documented workaround
is to isolate the heavy entrypoint in its own group (a future per-group
`estJobPeak` is an internal change needing no interface change). A floor of
the `mem-per-job-mb` seed is kept so the estimate never collapses below the
seed.

**Built-in default seed** for `estJobPeak` when `mem-per-job-mb == 0` is
**512 MiB** (matching the RFC's own "400–600 MiB cold `nim c`" characterization).
A non-zero default is required; seeding at zero disables the burst guard on the
first batch and makes the S6b serialization test unreliable.

#### B3 — `runner.nim` wiring (effectful)

`execute` constructs `var ac = initAdmission(config, plan)`, then per fill pass:

1. Call `ac.refreshAvail()` once at the top of the pass.
2. For each candidate slot, call `let tok = ac.admit(group, pep.decision)`.
   If `tok.isNone`, the candidate is not admitted this pass (its entrypoint
   stays pending; `nextEp` is **not** advanced past an un-admitted entry).
3. On `tok.isSome`, attempt the spawn. **On spawn success**, store the token on
   the slot (`slot.token = tok.get`). **On spawn failure**, call
   `ac.release(tok.get)` so the reservation and `groupInflight` roll back —
   there is no separate `onSlotStart` confirm step.
4. At slot completion, capture `slot.pid` and `slot.token` **before** clearing
   the slot (alongside the existing pre-clear `completedIdx`/`slotCacheDir`
   captures), then call
   `ac.onSlotFinish(slot.token, procGroupRssBytes(slot.pid))`.

Add `token: SlotToken` to the `Slot` type. `execute` no longer holds
`estJobPeak`, `committed`, or group tables as locals — all admission state
lives in `ac`. **Interrupt path:** entrypoints dequeued-but-not-yet-admitted
have no child; `handleInterrupt` is a correct no-op for them (they are
abandoned without an error result, standard interrupt semantics).

**Config keys** (all optional):

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `mem-budget-mb` | int | 0 | Cap available memory at this value (CI determinism). `0` = use probe raw. |
| `mem-per-job-mb` | int | 0 | Seed `estJobPeak` before any job observed. `0` = 512 MiB built-in. |
| `mem-per-run-mb` | int | 0 | Skip-fresh run estimate. `0` = 64 MiB built-in. |
| `mem-aware` | bool | true¹ | Kill switch; off ⇒ today's fixed-pool behavior exactly. |

¹ Default on when the probe (incl. cgroup) is available; default off otherwise.

`mem-budget-mb` (CI cap) and `mem-aware` (kill switch) are the primary
consumer surface; `mem-per-job-mb` / `mem-per-run-mb` are **advanced tuning
seeds** for the adaptive estimator's first-run behavior (rarely set — the
estimator adapts after the first observation). Documented as advanced in the
schema comment so the "no hand-tuning" promise holds for the common case.

When the probe yields `none` (and `mem-budget-mb == 0`), B is inert and the loop
behaves as today. Because a slot begins in `spCompiling` and compiles are the
RSS hogs, gating at fill naturally throttles *concurrent compiles* — the right
phase — without a separate compile-specific mechanism.

### Feature C — per-group concurrency cap

- Add `maxJobs*: Option[int]` to `Group` (`none` = no cap, `some(1)` = serial,
  `some(N)` = cap at N). **Encoding is `Option[int]`, not a `0`-sentinel** — `0`
  is a meaningful "uncapped" value and `Option` makes absent/present explicit at
  the type level. This deliberately diverges from the legacy `0 = inherit`
  sentinel on `timeoutSecs`, establishing the correct encoding for new policy
  fields. `max-jobs` must be `>= 1`; `max-jobs 0` is a config **error**
  (`cfgErr`), not "uncapped" — absence (`none`) is the only way to express
  uncapped. `parseGroup` raises on `0` or negative.
- Parse `max-jobs` in `parseGroup` (`config.nim:156-186`) into `some(int)`.
- **`maxJobs` is NOT carried onto `Entrypoint`.** It is an admission *policy*, a
  group property. `AdmissionController.groupCap` is initialized from
  `Config.groups` directly. (By contrast, `runTimeoutSecs` belongs on
  `Entrypoint` because it is a per-work-item execution parameter — A and C are
  not symmetric.)
- The per-group gate composes inside `admit` (`group-not-at-cap ∧ memory-admits
  ∧ progress-override-on-mem-only`); no separate table in `execute`.

Both `Group.timeoutSecs` (`int`, `0 = inherit`) and `Group.maxJobs`
(`Option[int]`, `none = uncapped`) get an inline doc comment in `types.nim`
naming their absent-encoding and why they differ (`0` is meaningless for a
timeout but meaningful — "uncapped" — for a job count), so a reader of
`types.nim` need not consult the RFC.

A genuinely-unisolable file is carved into its own one-glob group with
`max-jobs 1`. A file lives in exactly one group, so no double-run. For mutually
exclusive files across groups, the workaround is to place all such files in one
group with `max-jobs 1`; a global "run-alone" level is a separate larger feature.
This reuses the existing group/glob abstraction — no new per-file config schema.

**Composition with B:** S3 builds `AdmissionController` with group-cap-only
`admit`; S6b extends `admit` with the memory predicate. Both live in
`admission.nim` — the "sequence C before B" framing is superseded.

### Feature D — unknown-config-key diagnostics

- `docToConfig`/`parseGroup` accumulate unrecognized node names into a
  `seq[ConfigWarning]` instead of `discard`ing them (`config.nim:243`, `:186`).
  Note: `gate` is a **leaf node** (one string arg), not a sub-block — there is
  no gate child-block to descend into; warn on an unknown key that appears where
  a gate/known key is expected at group level.
- `loadConfig` returns **`(Config, seq[ConfigWarning])`** (tuple). `ConfigWarning`
  is a named object isomorphic to the wire schema, so the human message is
  composed once at the warning site (not duplicated between stderr and JSON):

  ```nim
  type ConfigWarning* = object
    source*:  string   # config file path; "" = convention fallback
    context*: string   # "top-level" or the group name
    key*:     string   # the unrecognized node name
    message*: string   # composed once where the warning is raised
  ```

  This keeps diagnostic state out of the `Config` type that the
  planner/executor don't need. Warnings thread from `loadConfig` → `pipeline`/CLI.
  Stderr emission and the JSON `"warnings"` array both render the
  already-composed `message`.

- **Migration:** changing `loadConfig`'s return type is a compile-time-breaking
  change for every call site (in-tree: `crisol.nim` CLI, `clean.nim`, and
  `test_config.nim` helpers — ~5 sites). All are updated in S1 to destructure
  the tuple. This is acceptable: crisol has no external API consumers of
  `loadConfig` (build-time tooling, assume-no-consumers).

- Warnings thread explicitly: `loadConfig` → a CLI local → passed into both
  `planToJson` (for `list --json`) and `toJson` (for `run --json`). Give
  `RunPlanView` a `warnings: seq[ConfigWarning]` field so the single
  `buildRunPlan` boundary carries them to both renderers rather than re-plumbing
  each call site.
- The CLI prints warnings to stderr as
  `warning: unknown config key '<k>' in <context> (ignored)`. Warn, never fail
  — a newer config on an older crisol must still run. (Corollary: RFC-0002's
  new keys will themselves warn on a pre-RFC-0002 binary that has D — correct
  behavior.)
- **Warnings reach `--json`:** a top-level `"warnings": [{"source","context","key","message"}]`
  array is added to BOTH `crisol/plan/v1` and `crisol/run/v1` schemas. Stderr
  emission is additional (not a replacement).
- Pure-testable: feed a `KdlDoc`/parsed config with a typo'd key, assert the
  warning list contains it and the valid keys still parse.

---

## Slices (TDD-sized, dependency-ordered)

Each leaves `crisol`'s own suite green and is independently testable.

- [ ] **S1 (D) — unknown-key warnings.** Decide `(Config, seq[ConfigWarning])`
  tuple return shape and wire warnings through `loadConfig` → CLI/JSON schemas
  (add `"warnings"` array to `crisol/plan/v1` and `crisol/run/v1` here or note
  as part of D). RED: a config with `timeout-sec` (typo) yields one warning
  naming it; a clean config yields none; the typo'd key does not break parsing
  of valid siblings. *Smallest; independent; good warm-up.*

- [ ] **S2a (A, pure) — timeout resolution.** `Entrypoint.runTimeoutSecs` +
  `discover` populates it from `group.timeoutSecs` + `effectiveRunTimeoutMs`
  helper. Also wire `compileSkipped` and `memThrottledSlots` field emission
  into `crisol/run/v1` and the resolved `runTimeoutSecs`/`maxJobs` into
  `crisol/plan/v1` (update `test_planview.nim`/`test_jsonout.nim` goldens).
  RED (pure): helper returns group value when >0, else global, else built-in
  default. Independent of S1.
- [ ] **S2b (A, wiring) — per-group deadline.** `Slot.runTimeoutMs` field set
  at spawn; `pollSlot` reads it for the compile→run transition (remove the
  global `runTimeoutMs` param from `pollSlot` and update both in-`execute` call
  sites). RED (integration): an entrypoint in a group with `timeout-secs 1`
  that sleeps 5s is classified `oTimeout` at ~1s while the global timeout is
  far larger. **Note:** S2b edits the `execute` fill/poll loop (≈ runner.nim
  lines 630–733); S6b edits the same region and must rebase on S2b.

- [ ] **S3 (C) — per-group `max-jobs`.** `Group.maxJobs: Option[int]` + parse
  `max-jobs` into `some(int)` + build `AdmissionController` with **group-cap-only**
  `admit` + wire into `execute`. RED (parse): `max-jobs 1` → `Group.maxJobs ==
  some(1)`. RED (behavioral): create a shared-overlap-file fixture — child
  processes append `{pid}\t{start}` / `{end}` lines to a file path passed via
  `CRISOL_TEST_OVERLAP_FILE`; with `max-jobs 1`, assert no interval overlap; without
  the cap, overlap occurs. (Fixture must be created as part of this slice.)
  The overlap fixture binary must: (a) **sleep a fixed 150ms** between writing
  its `start` and `end` lines, so concurrently-dispatched slots reliably overlap
  in wall time even on a single-core container (without the sleep, instant-exit
  children never demonstrate overlap → false green); (b) write each line as a
  **single `write(2)` syscall** to an `O_APPEND`-opened file (line < PIPE_BUF, so
  atomic across processes — no interleave corruption), OR write per-PID
  side-files merged by the harness. The fixture lives in `tests/fixtures/`.
  **`admit` contract this slice:** returns `some(token)` iff
  `groupInflight[group] < groupCap` (or no cap); `decision` is accepted but
  ignored until S5. The S5 RED step MUST confirm its memory case goes RED against
  this group-cap-only `admit` before adding the predicate.

- [ ] **S4 (B) — `memprobe.nim`.** `availableMemBytes` (incl. cgroup v2 and
  v1 fallback) + `procGroupRssBytes`, **both with an injectable `read` proc param
  from day one**. Unit tests feed synthetic `/proc/meminfo`, `/sys/fs/cgroup/*`,
  `/proc/<pid>/status` fixtures via the seam. Add a `when defined(linux)` /
  path-guarded real-read smoke asserting `> 0` on Linux / graceful `none` when
  paths are absent. The real-read smoke must do more than assert
  `availableMemBytes > 0` (which passes off host `MemAvailable` even if the
  cgroup branch silently regressed): separately read the real
  `/sys/fs/cgroup/memory.max` via the seam and assert it is either a positive
  integer (limited container) or the literal `"max"` (unlimited) — proving the
  cgroup code path ran. Inside the `./dev` podman container `memory.max` is
  typically `"max"`, so the probe correctly falls back to `MemAvailable`; the
  test must tolerate both.

- [ ] **S5 (B) — pure admission logic in `admission.nim`.** Extend `admit` with
  the memory predicate (pure-ish over the controller). RED table of cases:
  under-budget admits; over-budget refuses; `liveCount == 0` progress override
  admits despite memory (but NOT past group cap); group-cap still enforced
  independent of override; `committedHeadroom` reservation blocks a burst within
  a single fill pass; `cdSkipFresh` decision uses `mem-per-run-mb` estimate
  rather than `estJobPeak`; `liveCount >= jobsCap` refuses regardless of memory.
  Include a RED case proving the memory gate (not just the progress override)
  blocks: with `liveCount >= 1` and `committed + reserved > availSnapshot`,
  `admit` returns `none`. This guards against a vacuous test where every slot is
  admitted via the `liveCount == 0` override.

- [ ] **S6a (B) — config parsing.** Parse and round-trip `mem-budget-mb`,
  `mem-per-job-mb`, `mem-per-run-mb`, `mem-aware`. RED: round-trip each key;
  assert defaults (512 MiB seed when `mem-per-job-mb == 0`, 64 MiB when
  `mem-per-run-mb == 0`).

- [ ] **S6b (B) — wire probe + adaptive `estJobPeak` into `execute`.** Construct
  `AdmissionController` in `execute` (`initAdmission`); call `admit` /
  `release` / `onSlotFinish` at the right points; adaptive `estJobPeak`
  updates from `procGroupRssBytes`. RED: with tiny `mem-budget-mb`, reuse the S3
  overlap fixture and assert observed concurrency collapses to 1 (serialized) and
  the run still completes. With `mem-aware #false` (or probe `none`), assert
  concurrency returns to `jobs`. Assert *serialization/throughput*, never absolute
  RSS (non-deterministic). 512 MiB built-in seed makes this reliable.
  **Arithmetic:** set `mem-budget-mb` to any value in `[1, 511]` (below the
  512 MiB built-in `estJobPeak`) with `safety = 0`; the first slot admits via the
  `liveCount == 0` override, every subsequent slot is blocked by the memory gate
  (`avail - committed - safety >= reserved` is false once one `estJobPeak` is
  reserved) → exactly serial. Assert interval non-overlap via the S3 fixture, not
  absolute RSS. **Scope:** S6b is the heaviest slice (three callsites + token
  plumbing + adaptive `estJobPeak` update + pre-clear `slot.pid`/`slot.token`
  capture). If it does not land in one clean RED→GREEN→REFACTOR cycle, split the
  adaptive-`estJobPeak` update into a trailing S6c; the wiring (admit/release/
  onSlotFinish plumbing) and the adaptive update are separable.

- [ ] **S7 (composition) — A+B+C+fail-fast integration.** A `max-jobs 1` group
  + a multi-entry group + tiny `mem-budget-mb` + fail-fast: assert group cap holds,
  memory serializes the other group, fail-fast drains live slots without deadlock,
  and per-group timeouts are honored. Reuses the S3 overlap fixture.

**Order rationale:** S1, S2a, and S2b are independent of each other and of S3+.
S2a (pure timeout resolution) and S2b (wiring into `execute`) are split because
S2b edits the `execute` fill/poll loop — the same region that S6b will later
extend with the memory predicate; S2b must land before S6b to give S6b a clean
rebase surface. S3 establishes `AdmissionController` with group-cap logic; S4→S5
build the probe and pure admission predicate bottom-up. S6a decouples config
parsing from wiring; S6b wires everything together and depends on
S3+S4+S5+S6a+S2b. S7 is the composition integration test and depends on all
prior slices.

---

## Testing strategy

crisol's own tests run under its serial fallback runner (RFC-0001 Testing
Strategy) until the orchestrator changes are green, then under crisol. New
tests follow the existing split:

- **Pure unit tests** (with injected inputs): `effectiveRunTimeoutMs`,
  `AdmissionController.admit`/`release`/`onSlotFinish`, config-warning
  accumulation, `AdmissionController` burst/progress/group-cap cases.
- **Probe unit tests** (injected `read` seam): `availableMemBytes` and
  `procGroupRssBytes` fed synthetic `/proc/meminfo`, `/sys/fs/cgroup/*`, and
  `/proc/<pid>/status` fixtures. The injectable `read` seam is established in S4
  from day one; probe tests never touch the real filesystem except in the
  guarded real-read smoke (`when defined(linux)` / path-present guard).
- **Integration tests** asserting **observable outcomes** (never wall-clock RSS
  numbers): timeout classification (`oTimeout` enum), `max-jobs` serialization
  and absence-of-overlap via the **shared-overlap-file fixture** (children append
  `{pid}\t{start}` / `{end}` via `CRISOL_TEST_OVERLAP_FILE`; the harness asserts
  interval non-overlap), memory-budget serialization (observed concurrency via the
  same fixture), and the **S7 A+B+C+fail-fast composition test** (group cap
  holds, memory serializes, fail-fast drains, no deadlock, per-group timeouts
  honored).

**Bootstrap coverage map.** Pure/unit slices (S1, S2a, S4, S5, S6a) run under
the RFC-0001 serial fallback runner via `./dev test`. Integration slices that
exercise `execute` itself (S2b, S3, S6b, S7) run directly via `./dev run nim r
tests/integration/<file>` — the fallback runner does **not** cover them
(it would call the very `execute` under test). Dogfood switchover to crisol-
runs-crisol happens only after S7 is green.

---

## Cross-repo impact (amoxtli RFC-0015)

This RFC directly simplifies amoxtli RFC-0015 WS-C:

- **Deletes** WS-C's "measure peak RSS with `/usr/bin/time -v` and freeze a
  static `jobs` in `crisol.kdl`" step — replaced by `mem-aware` (default on when
  probe available, so amoxtli gets self-tuning without setting any keys) + an
  optional `mem-budget-mb` in CI.
- **Removes** the §4 CI OOM risk and the "pin `--jobs` low in CI" workaround:
  CI sets `mem-budget-mb` to the runner's RAM minus headroom and lets admission
  self-limit.
- **Provides** the `max-jobs 1` escape hatch named in WS-C as the fallback for
  `test_mcp_sse` if its per-test-local refactor proves structurally hard (the
  hermeticity work in WS-C still stands — those fixed-temp-path bugs are real
  regardless of the runner).
- **Lets** the integration group take a longer `timeout-secs` than unit
  (Feature A), as RFC-0015 §4 wanted once the per-group-timeout bug was fixed.

Adoption is a separate amoxtli change: bump the `milpa.kdl` crisol pin to the
post-RFC HEAD, then set the new keys in `crisol.kdl`. (Note: the current pin
`71e8719` is not on crisol `main` (`8ff9112`); reconcile to the new HEAD when
bumping.)

Adoption is tracked under amoxtli RFC-0015 WS-C (specific task: bump the
`milpa.kdl` crisol pin from `71e8719` to the post-RFC HEAD and reconcile). On
upgrade with no config changes, behavior is identical to today — all new keys
are optional with prior-behavior defaults, and `mem-aware` self-tunes only
where the probe is available. The amoxtli bump PR should confirm pin
reconciliation explicitly.

---

## Resolved (round 1)

The following questions from the draft were resolved by the round-1 architect
review and are no longer open:

1. **C — cross-group exclusion:** Not in v1. Workaround: put all mutually-exclusive
   files in one group with `max-jobs 1`. A global "run-alone" level is a separate
   larger feature.
2. **B — `estJobPeak` adaptivity:** Global (single adaptive max) for v1.
   Conservative; per-group is a future internal field requiring no interface change.
3. **B — `committedHeadroom` reservation:** Required and load-bearing. The fill
   loop admits multiple slots per 25ms pass against the same `availableBytes`; per-admit
   reservation prevents burst overshoot before RSS ramps.
4. **B — `mem-aware` default:** Default-on when probe (incl. cgroup) is available;
   default-off (inert) otherwise — self-tuning out of the box with clean degradation.

---

## Round-1 architect revisions

Applied from `.0002-round1-changes.md`:

- **A** — Feature B design restructured around `AdmissionController` in a new
  `admission.nim` module + `memprobe.nim` probe; replaced flat `admitAnother`
  signature with object + lifecycle procs; cgroup-aware `availableMemBytes`.
- **B** — Feature A wiring corrected: `runTimeoutMs` added to `Slot` type;
  `pollSlot` reads it for the compile→run transition, removing the global
  `runTimeoutMs` parameter from `pollSlot`.
- **C** — `maxJobs` removed from `Entrypoint`; encoded as `Option[int]` on
  `Group` (not `0`-sentinel); `AdmissionController.groupCap` initialized from
  `Config.groups` directly; cross-group exclusion closed as not-v1.
- **D** — `gate` corrected to leaf node (no sub-block); `loadConfig` return type
  changed to `(Config, seq[ConfigWarning])` tuple; warnings added to both JSON
  schemas (`crisol/plan/v1`, `crisol/run/v1`).
- **E** — Goal 5 reworded to resolve additive-vs-default-on tension; mem-aware
  default-on-when-probe-works resolved (Q4); observability requirements added
  (plan output, memory-throttled signal, `compileSkipped` schema field); `--jobs 1`
  note added; naming/units rationale documented.
- **F** — Slices re-cut: S6 split into S6a (config parsing) + S6b (wiring); new
  S7 A+B+C+fail-fast composition test added; `CRISOL_TEST_OVERLAP_FILE` fixture
  specified; `mem-per-run-mb` and 512 MiB seed documented; order rationale updated.
- **G** — Testing strategy updated with injectable `read` seam, overlap-file
  fixture, S7 composition test; open questions replaced with "Resolved (round 1)"
  subsection; Summary table Feature B updated to name `memprobe.nim` +
  `admission.nim` + `AdmissionController`; Status line updated.

---

## Round-2 architect revisions

Second architect pass (depth / breadth / design / feasibility). No genuine
forks; all clear-best. Headline changes:

- **Admission interface redesigned** (supersedes round-1's 3-call protocol):
  probe injected at construction and snapshotted per fill pass (`refreshAvail`);
  `admit → Option[SlotToken]`; `release(token)` rolls back on spawn failure;
  `onSlotFinish(token, rss)`. The token carries per-slot `reserved` bytes, fixing
  the missing reservation-release accounting, typing the spawn-failure rollback,
  and preventing double-finish. `onSlotStart` removed.
- **`committed` double-count documented as intentional** (probe already reflects
  live RSS; reservation is a forward pre-ramp guard) so it is not "fixed" away.
- **Progress-override starvation window** stated and accepted (global, bounded,
  not a deadlock). **`estJobPeak` ratchet limitation** documented with the
  per-group-isolation workaround + seed floor; mixed-batch `max` safety stated.
- **Feature A** run deadline explicitly anchored at run-start (long compile does
  not eat run budget). **`max-jobs 0`** defined as a config error.
- **`ConfigWarning`** promoted from tuple to a named object isomorphic to the
  wire schema (message composed once); `loadConfig` call-site migration (~5
  sites) called out; warnings threaded via `RunPlanView.warnings`.
- **Observability completed**: plan-output field placement specified;
  `compileSkipped` assigned to S2a; `memThrottledSlots` added to `run/v1`;
  golden-test impact flagged.
- **Ergonomics**: `mem-per-job-mb`/`mem-per-run-mb` marked advanced seeds;
  Group encoding rationale moved to `types.nim` inline docs. CLI flags for memory
  keys + user docs declared Non-Goals.
- **Slices re-cut**: S2 → S2a (pure) / S2b (wiring, shares `execute` with S6b);
  overlap fixture hardened (150ms sleep + atomic single-`write` append);
  S4 cgroup smoke proves the cgroup branch ran; S5 adds a non-vacuity case for
  the memory gate; S6b arithmetic pinned + optional S6c split; testing-strategy
  bootstrap coverage map added.
