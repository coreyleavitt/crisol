# RFC-0003 — Library facade + onboarding + CLI papercuts

**Status:** Draft — stage 1 (RFC + slicing); architect round 2 applied
**Date:** 2026-06-13
**Author:** Corey Leavitt

---

## Summary

Three new-user/consumer-facing improvements, surfaced by an architect pass over
crisol "from the perspective of a new user of the lib." crisol's *internals* are
strong (deep pure pipeline, principled CLI, versioned JSON) but its **adoption
surface** is rough: embedding it as a library means hand-wiring the whole
pipeline, the README says the tool does not exist, and the CLI has papercuts
that read as "unfinished."

| # | Feature | The gap today | What it unblocks |
|---|---------|---------------|------------------|
| **F1** | **Library facade** | No single entry point. The only complete orchestration of `loadConfig → buildRunPlan → execute → summarize → persist` (plus DepGraph threading, advisory lock, signal handlers, `--failed`/`--changed` narrowing) lives **inside the CLI's private `runMain`** (`src/crisol.nim`). A consumer must re-wire ~10 stages and learn ~15 types to embed crisol as a library — which is the entire reason crisol exists (cel, kdl, proptest, fresco, amoxtli all replace hand-rolled runners). | A consumer runs its suite in **one call** — `runTests()` / `planTests()` — instead of a 30-line, 15-type wiring exercise. Gives the project a real, testable public API boundary and a single seam for boundary tests. |
| **F2** | **Onboarding (docs)** | `README.md` says *"Pre-v1. RFC in review. No implementation yet."* — crisol is fully implemented, shipped (RFC-0001 + RFC-0002), and executable. No quickstart, no example `crisol.kdl` in the repo, no CLI/config reference, the memory keys are undocumented. A new user's **first touch** says the thing doesn't exist. | A newcomer goes from zero to a green `crisol run` by following the README; the structured-protocol and impact-analysis features become discoverable instead of source-only. |
| **F3** | **CLI papercuts** | `crisol clean` is implemented but **absent from `--help`**; `--help` prints to **stderr**; `--base` is silently ignored without `--changed`; `-j`/`-t` short forms are undocumented; there is **no `crisol --version`** and no `crisol init`. | The CLI reads as finished and trustworthy; scaffolding (`init`) + version reporting are table-stakes a new user expects. |

All three are additive. **F1 is the architectural core** (a deep facade module);
F2 is documentation; F3 is small CLI polish plus two tiny new verbs
(`--version`, `init`). None changes the
`discover → applyGates → [narrowByDiff] → plan → execute → report` pipeline — F1
*wraps* it, it does not reshape it.

---

## Motivation

crisol was built RFC-first and slice-by-slice, with the **CLI as the only
driver** of the full pipeline. That produced a clean set of pure stages
(`pipeline.buildRunPlan`, `runner.execute`, `config.loadConfig`,
`summarize`, `render`/`jsonout`) — but the *composition* of those stages, with
all the load-bearing plumbing a correct run needs (DepGraph load/thread or every
run cold-compiles; advisory lock or concurrent runs corrupt state; signal
handlers or Ctrl-C orphans child process groups; `--failed`/`--changed` input
assembly), exists **only** as private code inside `src/crisol.nim:runMain`.

The result: the *documented* "library entry point" (`buildRunPlan`) is only the
plan phase. There is no execute-phase facade, so the first real consumer
(amoxtli) and every consumer after it must either (a) shell out to the `crisol`
binary, or (b) re-derive `runMain`'s orchestration by reading CLI source. Both
defeat the point of shipping crisol as a *library*.

Meanwhile the front door is worse than the building: the README actively tells a
newcomer the tool is unimplemented, and the CLI's small rough edges
(`clean` missing from help, no `--version`, help to stderr) compound the
impression that this is a prototype rather than the reviewed, tested tool it is.

This RFC fixes the adoption surface against crisol's own PhD-CS bar: F1 makes
"run a suite" a deep one-call module; F2/F3 make the first five minutes match the
quality of the internals — and **dogfoods the facade by rebuilding the CLI on top
of it**, so the library path is the same path the CLI exercises every run.

---

## Goals

1. **One-call embedding.** A consumer with a `crisol.kdl` can run its full suite
   with `runTests()` and inspect a single structured `RunReport` — no manual
   stage wiring, no DepGraph/lock/signal bookkeeping.
2. **A real public API boundary.** A single module (`crisol/api`) is *the*
   documented, stable library surface; everything else is an implementation
   detail a consumer need not import.
3. **Dogfood, don't duplicate.** The CLI `runMain` becomes a thin shell over the
   facade (arg-parse → options → `planTests`/`runTests` → render → exit). The
   facade is proven by the existing CLI integration tests, and the orchestration
   exists in exactly one place.
4. **A correct, complete README.** A newcomer can install, scaffold, configure,
   and run from the README alone; every config key and CLI verb is documented.
5. **A finished-feeling CLI.** `--version`, `init`, `clean` in `--help`, help to
   stdout, and no silently-ignored flags.

## Non-Goals

- **No new run semantics.** F1 changes *packaging*, not behavior: the same
  discover/plan/execute/report happens. (Two deliberate behavior tweaks are
  scoped under F3 and called out in Open Questions: `--base` without `--changed`
  becoming an error, and `--help` exit/stream.)
- **No async / streaming API.** crisol runs synchronously; `runTests()` returns
  when the run completes. Live per-entrypoint observation stays via the existing
  `onResult` callback.
- **No config-model redesign.** The `opt-in` vs `gate` vs `--group` distinction
  and the `timeout-secs 0 = inherit` / `max-jobs absent = uncapped` encodings are
  **documented** here (F2), not changed (that was architect-candidate #4, out of
  scope).
- **No published registry / packaging changes.** Still milpa local-path pinned.
- **Not compiled into consumers' production binaries** — unchanged; build-time
  tooling only.
- **`clean`, `init`, `--version` are CLI-only verbs** with no library facade in
  this RFC — the facade covers the `run`/`list` (plan→execute) pipeline only. A
  programmatic `cleanTests()` maintenance entry is a plausible future addition,
  noted but out of scope.
- **API stability is a convention**, not compiler-enforced. Nim cannot make
  `runner`/`pipeline`/`config` un-importable; `crisol/api` is THE contracted
  surface by documentation + CHANGELOG discipline, and the others become
  "importable but uncontracted."

---

## F1 — Library facade

### Design

A new module **`src/crisol/api.nim`** is the public library surface — two deep
entry points, a small set of report/option types, and selection/narrowing
constructors. It **returns** outcomes (it does not raise for expected conditions)
so embedding is exception-free for the common path.

**`planToJsonString` Config dependency removed.** `pipeline.plan()` annotates
each `PlannedEntrypoint` with a precomputed `runTimeoutMs: int` and `maxJobs:
Option[int]` (computed in the same place `decision`/`reason` are already set),
so `planToJson`/`planToJsonString` no longer need the full `Config` — their
signatures drop the `Config` parameter. This is what allows `PlanReport` to
expose no `Config` AND lets the thin shell render plan JSON from `PlanReport`
alone. Without this annotation, the dogfood thin shell cannot call
`planToJsonString` (it has no `cfg`).

```nim
## crisol/api.nim — the public library boundary.

type
  RunStatus* = enum
    rsOk            ## run completed; inspect `summary` for pass/fail
    rsStructural    ## config/env problem (bad config/globs, lock held,
                    ## --failed with no prior run, --changed outside a git repo,
                    ## unknown group); see `error`
    rsInterrupted   ## SIGINT/SIGTERM during the run; exitCode = 128 + signum

  RunNarrowing* = object               ## api-owned; constructed via narrowing constructors below
    kind*:    NarrowingKind             ## enum: nkNone / nkFailed / nkChanged / nkFailedOrChanged
    baseRef*: string                    ## "" → working tree vs HEAD (staged + unstaged); only meaningful when kind includes nkChanged

  RunOptions* = object
    ## Tier 1 — everyday selection
    configPath*:   string = ""
    startDir*:     string = ""        ## walk-up origin when configPath==""; "" → cwd
    selection*:    GroupSelection      ## default-constructed = gskDefault; use the constructors below
    narrowing*:    RunNarrowing        ## default-constructed = noNarrowing(); use the narrowing constructors below
    forceCompile*: bool = false
    failFast*:     bool = false
    ## Tier 2 — tuning
    jobs*:         int = 0             ## <= 0 → config/built-in default; unlike the CLI (which rejects --jobs < 1), the library treats any jobs <= 0 as "use the resolved default" and does not error — an intentional library-ergonomics difference
    timeoutSecs*:  int = 0             ## <= 0 → config/built-in default
    onResult*:     ResultCallback = nil ## per-entrypoint callback; redirectable progress seam
    ## Tier 3 — host-lifecycle (safe LIBRARY defaults; the CLI overrides them)
    manageLock*:      bool = true      ## advisory inter-process lock; does NOT guard same-process re-entrancy
    installSignals*:  bool = false     ## LIBRARY DEFAULT OFF — true REPLACES the host's SIGINT/SIGTERM handlers
    persist*:         bool = true      ## write lastrun.json; persist:false makes a later narrowing nkFailed read STALE data
    showProgress*:    bool = false     ## stderr-only, non-redirectable; use onResult for redirectable progress
    progressIntervalMs*: int = 30_000

  ResolvedSettings* = object           ## slim projection of the resolved Config (NOT the full Config)
    projectRoot*: string
    stateDir*:    string               ## pre-joined to an ABSOLUTE path (projectRoot/stateDir resolved); consumers never need to re-join — unlike Config.stateDir which is project-root-relative
    jobs*:        int                  ## resolved (never 0)
    timeoutSecs*: int                  ## resolved

  PlanReport* = object                 ## plan-phase result; no DepGraph and no full Config exposed
    entrypoints*: seq[PlannedEntrypoint] ## inlined from RunPlan (kills the rr.plan.plan stutter); RunPlan stays an internal pipeline type
    jobs*:        int                    ## resolved (from RunPlan; inlined here for the same slim-projection reason ResolvedSettings avoids exposing Config)
    gatedOut*:    seq[GatedEntry]
    warnings*:    seq[ConfigWarning]
    settings*:    ResolvedSettings

  RunReport* = object
    plan*:              PlanReport      ## composed, not duplicated
    summary*:           Summary
    results*:           seq[EntrypointResult]
    memThrottledSlots*: int             ## # entrypoints delayed >=once by mem-aware scheduling; 0 if inactive
    status*:            RunStatus
    exitCode*:          int             ## ALWAYS set: 0/1 (rsOk), 3 (rsStructural; 2 for internal), 128+n (rsInterrupted)
    error*:             string          ## non-empty iff status == rsStructural

## Selection constructors — hide the GroupSelection discriminated-union syntax.
proc defaultGroups*(): GroupSelection                  ## gskDefault (excludes opt-in groups)
proc namedGroups*(names: varargs[string]): GroupSelection
proc allGroups*(): GroupSelection                      ## includes opt-in (gates still apply)
proc filesSelection*(paths: varargs[string]): GroupSelection

## Narrowing constructors — make baseRef-without-narrowing structurally unconstructable via the library API.
proc noNarrowing*(): RunNarrowing                      ## default; nkNone (run all)
proc failedOnly*(): RunNarrowing                       ## nkFailed
proc changedOnly*(baseRef: string = ""): RunNarrowing  ## nkChanged; "" → working tree vs HEAD
proc failedOrChanged*(baseRef: string = ""): RunNarrowing  ## nkFailedOrChanged; UNION (wider, not narrower)

proc planTests*(opts: RunOptions = RunOptions()): PlanReport
  ## loadConfig(opts.configPath, opts.startDir) -> apply jobs/timeout overrides ->
  ## assemble narrowing inputs (loadLastRun if opts.narrowing.kind includes nkFailed;
  ## changedFiles(opts.narrowing.baseRef) if kind includes nkChanged; UNION for
  ## nkFailedOrChanged) -> buildRunPlan. RAISES CrisolError on a structural problem
  ## (bad config, unknown group, --failed with no prior run, --changed outside a git
  ## repo). No lock, no exec.
  ## (Inspect/dry-run path: structural problems are exceptional here and raise.)

proc runTests*(opts: RunOptions = RunOptions()): RunReport
  ## Calls planTests internally and CATCHES-AND-ENCODES structural failures onto
  ## the RunReport (status rsStructural, exitCode 3/2, error set) — it does NOT
  ## raise for expected conditions. On rsOk: clearSignal -> [install handlers if
  ## installSignals] -> [acquire lock if manageLock] -> execute -> summarize ->
  ## [persistLastRun if persist] -> map exitCode (0 all-passed / 1 any-failure).
  ## Zero-runnable mapping: nkChanged-clean-tree / nkFailed-no-matches /
  ## all-gated-out -> rsOk, exitCode 0; "no entrypoints matched" (bad globs/empty)
  ## -> rsStructural, exit 3. SIGINT/SIGTERM -> clean drain, lock released
  ## explicitly, status rsInterrupted, exitCode 128+signum. Only a genuine,
  ## unexpected panic propagates.
```

**Usage (a consumer embedding crisol):**

```nim
import crisol/api

let r = runTests()                                  # zero-config, exception-free
quit r.exitCode

let r2 = runTests(RunOptions(selection: namedGroups("unit"),
                             narrowing: changedOnly("origin/main"),
                             failFast: true))
if r2.status == rsStructural: stderr.writeLine r2.error
for ep in r2.results:
  if ep.outcome != oPassed: echo ep.ep.path, " ", ep.outcome
```

### What it hides

The ~10-step composition currently resident only in `runMain`: config load +
override merge, group-selection assembly, `--failed`/`--changed` input gathering
(incl. the UNION), **DepGraph load/thread/save** (kept entirely internal — never
exposed), advisory-lock lifecycle, signal-handler install + interrupt drain, the
bounded-parallel execute with its memory-throttle out-param, summarization,
`lastrun.json` persistence, and the **full exit-code + zero-runnable taxonomy**.
A consumer sees two procs, eight constructors (four selection + four narrowing),
and four records — none of which expose `Config`, `DepGraph`, `RunPlan`, or
`RunPlanView`. `RunPlan` stays an internal pipeline type; `PlanReport` inlines
its fields directly (`entrypoints`, `jobs`) to kill the `rr.plan.plan` stutter
that would otherwise result from `RunReport` composing `PlanReport` composing
`RunPlan`. This applies the same slim-projection principle used for
`ResolvedSettings` vs `Config`. Entrypoint paths are accessed via
`rr.plan.entrypoints[i].ep.path`.

### Error & exit-code contract (resolves the raise-vs-return ambiguity)

`runMain`'s real exit logic is NOT a clean "structural → CrisolError" split:
several conditions are inline returns, not exceptions. The facade makes the
contract explicit and total:

| Condition | `runTests` result | exitCode |
|---|---|---|
| all selected entrypoints passed | rsOk | 0 |
| any failure / compile-fail / timeout / crashed-by-signal (oSignal) / spawn-error | rsOk | 1 |
| `--changed` on a clean tree (nothing affected) | rsOk | 0 |
| `--failed` matched nothing (but a prior run exists) | rsOk | 0 |
| every selected group gated out | rsOk | 0 |
| **no entrypoints matched** (bad globs / empty discovery) | rsStructural | 3 |
| bad `--config` path / KDL parse error / unknown group | rsStructural | 3 |
| lock held by another process | rsStructural | 3 |
| `--failed` with **no prior run** at all | rsStructural | 3 |
| `--changed` outside a git repo | rsStructural | 3 |
| `baseRef` set without narrowing (CLI-layer check; unconstructable via library API) | rsStructural | 3 |
| crisol internal invariant violation | rsStructural | 2 |
| SIGINT/SIGTERM mid-run | rsInterrupted | 128 + signum |

> **Signal footnote:** a child test binary killed by a signal (`oSignal`) yields rsOk, exit 1 — it is a test *result*. SIGINT/SIGTERM delivered to crisol itself yields rsInterrupted, 128+n (the separate last row above). These are distinct code paths.

`planTests` surfaces the same structural conditions by **raising** `CrisolError`
(its callers are inspect/dry-run paths where an exception is appropriate);
`runTests` wraps `planTests` and converts those into the table above. This
removes the drafted `exitCodeFor` proc entirely — the exit code always lives on
`RunReport.exitCode`. (Implementation note: `loadLastRun`'s `found:false` return
and the zero-runnable branches must be explicitly mapped — they are inline
returns in today's `runMain`, not exceptions.)

**Catch-boundary layering.** `runner.execute()` catches `CrisolError` internally
and converts to exit codes; `runTests`'s outer catch is therefore a
defense-in-depth layer that in practice handles `planTests` + lock +
`persistLastRun` errors. This layering is an otherwise-invisible load-bearing
invariant. Unifying the catch boundary in `runTests` is a plausible future
cleanup, noted out of scope for this RFC.

**`rsInterrupted` partial state.** On `rsInterrupted`, `RunReport.results` is
empty and `summary` is zero-initialized (`execute` raises `CrisolInterrupted`
before returning its results), so consumers must not read summary counts as
authoritative on interrupt.

**`--failed` zero-runnable collapse.** The two `--failed`-matched-nothing
subcases — (a) all prior failures now pass, (b) prior failures refer to
deleted/renamed tests — are intentionally collapsed to one rsOk/0 outcome in
this RFC. A future `RunReport.zeroRunnableReason` enum could distinguish them;
noted, out of scope.

### Facade I/O contract

The facade is **silent on stdout** and writes to **stderr only** for: (a) a
`persistLastRun` failure, and (b) the time-based progress line when
`showProgress:true` (non-redirectable; `onResult` is the redirectable seam).
Config warnings are returned on `RunReport.plan.warnings`/`PlanReport.warnings`, never
printed by the facade. All human/JSON rendering is the caller's choice via the
public re-exports below.

### Concurrency & thread-safety

`runTests`/`planTests` are **not thread-safe** — call from one thread at a time.
`manageLock:true` prevents concurrent **processes** (POSIX `fcntl` advisory lock)
but does NOT guard concurrent in-process calls (same PID re-locks succeed, and
the mutable `DepGraph` would race). `installSignals` and `lastrun.json` are
process-global. Sequential calls are safe: `runTests` calls `clearSignal()` at
entry so a signal handled by a prior call cannot instant-interrupt the next.

### Public surface (re-exports) & lock-release safety

`crisol/api` **re-exports** the rendering/presentation helpers so `import
crisol/api` is sufficient for both consumers and the CLI thin shell:
`render`, `toJsonString` (run/v1), `planToJsonString` (plan/v1),
`gateSkipMessages`, `hasZeroTagMatches`, `filterRecordsByTag`. Note:
`computeColorEnabled` is NOT re-exported — it does not exist as a library proc;
it is a private TTY-detection proc in `src/crisol.nim`. The thin CLI computes
colour itself via `shouldEnableColor(isatty(...))`. Colour/TTY detection is a
CLI concern, not part of the library surface. `gateSkipMessages` accepts
`seq[GatedEntry]` and performs per-group deduplication internally, so the thin
CLI and consumers pass `rr.plan.gatedOut` directly rather than replicating the
dedup loop. Consumers needing to replicate `--filter-tag` on returned `results`
use `filterRecordsByTag` (alongside the already-listed `hasZeroTagMatches`).
This makes the "`crisol/api` is the boundary" claim coherent with the dogfood
(the CLI imports only `api`). **Lock-release safety:** `releaseLock` must be
made **idempotent** via a signature change to `proc releaseLock*(handle: var
LockHandle)` — it sets `handle.fd = -1` after `posix.close` (callers already
hold `var` locals, so no call-site declaration changes). This ensures the
interrupt path / any double-release cannot close a recycled fd. `runTests` must
NOT combine `defer: releaseLock(...)` with explicit releases — use explicit
release on every exit branch (success / structural / interrupt) XOR a single
`defer`, never both; today's `runMain` has defer+explicit = a latent
double-close. This `var`-signature change is a prerequisite step at the start of
S2d.

### Dependency category

**In-process.** `api.nim` is a pure composition over existing modules
(`config`, `pipeline`, `runner`, `gitdiff`, `jsonout`, `render`, `planview`,
`lock`, `signals`). The injected seam (`onResult`) already exists; lock/signal
side effects are opt-out via `manageLock`/`installSignals`.

### Dogfood: CLI on the facade

`src/crisol.nim:runMain` is rebuilt as a thin shell over the **run/list
pipeline**:

```
parse args -> RunOptions (+ CLI-only presentation: --json, --filter-tag, colour, --dry-run routing)
list / --dry-run:  let pr = planTests(opts);  render plan (human|json via re-exports);  quit 0
run:               let rr = runTests(opts);
                   render results (human|json, applying --filter-tag) via re-exports
                   if rr.status == rsStructural: stderr.writeLine rr.error
                   quit rr.exitCode
```

The CLI keeps only **presentation + argument consistency** (arg parsing,
human-vs-`--json`, `--filter-tag` display filtering, `--base`-without-`--changed`
validation, colour/TTY, gate-skip messages, and `showProgress := not jsonMode`).
`--dry-run` is a CLI **routing** flag (call `planTests`), not a `RunOptions`
field. The `clean`, `init`, and `--version` verbs are handled by the CLI
directly — they are **not** part of the facade (see Non-Goals). Existing CLI
integration tests are the regression proof for the dogfood.

---

## F2 — Onboarding (docs)

### Design

1. **Rewrite `README.md`** to cover, for a newcomer, in order:
   - One-paragraph what/why (keep the existing accurate intro + "what it is not").
   - **Correct status** (replace the false "no implementation yet" — it is
     implemented, reviewed under RFC-0001/0002, pre-1.0 but usable).
   - **Install** via milpa local-path pin.
   - **Quickstart**: `crisol init` → `crisol run` → reading results; the minimal
     conventional layout (`tests/unit/test_*.nim`, `tests/integration/test_*.nim`)
     that needs *no* config.
   - **Environment variables**: `CRISOL_SINK` (set automatically by the executor),
     `NO_COLOR` (suppress colour), `FORCE_COLOR` (force colour regardless of TTY).
   - **CLI reference**: every verb (`run`, `list`, `clean`, `init`) and flag,
     including `--version`, `--failed`, `--changed`/`--base`, `--filter-tag`,
     `--json`, `--dry-run`, `--jobs`/`-j`, `--timeout`/`-t`, `--config`,
     `--force-compile`, `--all-groups`/`--group`, `--fail-fast`.
   - **Exit-code table** (0/1/2/3) — the data-vs-structural distinction.
   - **Config reference**: every key (global + per-group), including the
     previously-undocumented memory keys (`mem-budget-mb`, `mem-per-job-mb`,
     `mem-per-run-mb`, `mem-aware`) and the `opt-in` vs `gate` vs `--group`
     selection model and the `timeout-secs 0 = inherit` / `max-jobs absent =
     uncapped` encodings. Complete key checklist for the S7 README author:
     `timeout-secs`, `max-jobs`, `compile-timeout-secs`, `dep-roots`, `state-dir`,
     `max-output-bytes`, `flags`, memory keys. The RFC currently promises "every
     key" — this checklist ensures none are missed.
   - **Library embedding**: the `import crisol/api; let r = runTests()` example.
   - **Structured results — a concrete recipe, not a pointer.** Document BOTH
     paths a test binary uses to emit per-test records: (a) the drop-in — replace
     `import std/unittest` with `import crisol/unittest_shim` (note the
     limitation: the shim hardwires empty tags, so `--filter-tag` is NOT reachable
     via the shim); (b) the raw emitter — `crisol/report`'s `initReport` +
     `emit(TestRecord(tags: @["..."]))` for tagged records. Document that the
     executor sets `CRISOL_SINK` automatically (the consumer does not). Flag
     "`unittest_shim` tag support" as a future enhancement (a feature, out of
     this docs RFC's scope) — without it, `--filter-tag` only works for binaries
     using the raw emitter.

2. **Single source of truth for the example config.** The canonical starter
   `crisol.kdl` is what `crisol init` emits (F3/S6); `crisol init` writes the
   `const initTemplate` defined in the `init` module verbatim, and the README
   embeds the same string, so the S7 parse test (`loadConfig(initTemplate)` →
   zero warnings) guards against drift with no path-fragile README-scraping.

Docs prose is verified by review, but the *testable core* (the canonical config
parses cleanly; `init` output is valid) is a real automated test carried by S6/S7.

---

## F3 — CLI papercuts

### Design

1. **`crisol --version` / `-V`** — prints `crisol <version>`. Version sourced at
   compile time via `staticRead("../crisol.nimble")` + a tiny parse from
   `src/crisol.nim` (`gorge` is dropped entirely — it shells out at compile time
   and is fragile/empty in sandboxed container builds). `staticRead` works
   correctly under BOTH the nimble build AND the bootstrap `nim r --path:src`
   test harness — the `NimblePkgVersion` strdefine is only injected by `nimble`,
   so it would read `"dev"` under the project's own `nim r` test task and make
   the S5 assertion vacuous. A compile-time guard `static: doAssert version.len >
   0 and version[0] in {'0'..'9'}` turns a parse failure into a build error.
   Exit 0.
2. **`crisol init [path] [--force]`** — writes the canonical starter `crisol.kdl`
   (the F2 single-source example) to `path` (default `./crisol.kdl`). Refuses to
   overwrite an existing file (exit 3) unless `--force`. This is the scaffolding
   verb and the home of the canonical example.
3. **`clean` in `usage()`** — document the already-implemented `clean [--all]`
   verb in the help text.
4. **`--help`/`-h` → stdout, exit 0.** Explicit help is not an error: print usage
   to **stdout** and exit **0**. (No-arg invocation remains a usage *error*: usage
   to stderr, exit 3.)
5. **Document short forms.** `-j` (`--jobs`) and `-t` (`--timeout`) appear in the
   usage text.
6. **`--base` without `--changed` → error** (exit 3) instead of a silently-warned
   no-op. (Open Question Q1; lean: error — a base ref with no narrowing is always
   a mistake.)
7. **`FORCE_COLOR` support.** `terminal.shouldEnableColor` must support
   `FORCE_COLOR`: force colour on when the env var is set non-empty, regardless
   of TTY detection — CI table-stakes alongside the existing `NO_COLOR` handling.
   `FORCE_COLOR` and `NO_COLOR` are added to the F2 docs-to-cover list (CLI
   reference / environment variables).

---

## Slices — dependency order (re-cut after architect round 2)

Each item below is one focused behavior (one RED→GREEN→REFACTOR cycle); the
original 7 "features" expand to ~16 cycles. F1 first (facade), then CLI verbs,
then docs.

**Implementation strategy clarification.** S1/S2 are the implementation of
record — `api.nim`'s `planTests`/`runTests` are built greenfield and
boundary-tested there. S3 is therefore **substitution + deletion, NOT
re-implementation**: the old "extract `orchestrateRun` INSIDE `crisol.nim` then
move it" framing is dropped (that would build the orchestration a third time).
S3a rewires `runMain` to call the already-built `api.nim` facade; S3b deletes
the now-dead duplicated inline orchestration.

- [ ] **S1a (F1)** — Move `ResultCallback` type from `runner.nim` to `types.nim`
      so `import crisol/api` exposes the callback type without importing `runner`
      (prerequisite step). Then: `crisol/api.nim` types (`RunOptions`,
      `RunNarrowing`, `ResolvedSettings`, `PlanReport`, `RunReport`, `RunStatus`)
      + selection constructors (`defaultGroups`/`namedGroups`/`allGroups`/
      `filesSelection`) + narrowing constructors (`noNarrowing`/`failedOnly`/
      `changedOnly`/`failedOrChanged`) + `planTests` zero-opts (plans the default
      groups). Public re-exports wired.
      **S1a-prep:** build reusable test helpers `withTempProject(body)` (temp root
      + minimal config + state dir + teardown) and `seedLastRun(projectRoot,
      results)` (via `persistLastRun`) so S1c–S2d do not each reinvent setup.
- [ ] **S1b (F1)** — `planTests` named-group selection.
- [ ] **S1c (F1)** — `planTests` `failedOnly()` narrowing (fixture produced via
      `persistLastRun`, never hand-written JSON) + `--failed` with no prior run →
      raises `CrisolError`.
- [ ] **S1d (F1)** — `planTests` `changedOnly(baseRef)` narrowing (real git-init'd
      temp repo per the existing `test_changed.nim` pattern) + `failedOrChanged`
      UNION narrowing + `noNarrowing()` default. Note: `baseRef`-without-narrowing
      is structurally unconstructable via the narrowing constructors; the CLI maps
      `--base` without `--changed` to a CLI-layer structural error (exit 3).
- [ ] **S1e (F1)** — `planTests` warnings surfaced on `PlanReport`; structural
      raises for bad config / unknown group.
- [ ] **S2a (F1)** — `runTests` happy path: all-pass fixture suite → `rsOk`,
      exitCode 0, populated `results` + `settings`.
- [ ] **S2b (F1)** — `runTests` failure → exitCode 1; `onResult` fires; failFast
      skip semantics.
- [ ] **S2c (F1)** — `runTests` catch-and-encode: structural → `rsStructural`,
      exit 3 (and the zero-runnable mapping table: changed-clean / failed-none /
      all-gated → `rsOk` 0; no-entrypoints-matched → `rsStructural` 3).
- [ ] **S2d (F1)** — Prerequisite: change `releaseLock` signature to `proc
      releaseLock*(handle: var LockHandle)` and set `handle.fd = -1` after
      `posix.close` (callers already hold `var` locals; no call-site declaration
      changes needed). Then: `runTests` interrupt path → `rsInterrupted`, lock
      released explicitly on every exit branch (success / structural / interrupt)
      — do NOT combine `defer: releaseLock(...)` with explicit releases (today's
      `runMain` has defer+explicit = latent double-close); `manageLock:false` path;
      `memThrottledSlots` surfaced; `clearSignal()` at entry guards sequential
      calls.
- [ ] **S3a (F1)** — S3 is **substitution + deletion, NOT re-implementation**:
      `api.nim`'s `planTests`/`runTests` are the implementation of record (built
      and boundary-tested in S1/S2). S3a = rewire `runMain` to route list/run/
      `--dry-run` through the already-built `api.nim` facade. The old
      "extract `orchestrateRun` INSIDE `crisol.nim` then move it" framing is
      dropped — that would build the orchestration a third time. **S3a-prep:**
      before rewiring, add 3 CLI integration tests for the three
      zero-runnable→exit-0 branches (changed-clean-tree, failed-none-matched,
      all-gated-out) — they pass today via `runMain` and are the regression anchor
      proving S3's thin-shell reconstruction preserves their exit codes.
      `gateSkipMessages` in the thin shell calls the re-exported version with
      `rr.plan.gatedOut` directly (no dedup loop in CLI).
      **Contract: all existing CLI integration tests stay green.**
- [ ] **S3b (F1)** — delete the now-dead duplicated inline orchestration from
      `runMain`; demote `pipeline.nim`'s "core library entry point" doc-comment to
      internal. The thin shell keeps only: arg parsing, human-vs-`--json`,
      `--filter-tag` display filtering, `--base`-without-`--changed` validation,
      colour/TTY via `shouldEnableColor(isatty(...))`, gate-skip messages, and
      `showProgress := not jsonMode`. **Contract: all CLI integration tests stay
      green.**
- [ ] **S4 (F3)** — `--help`/`-h` → usage to **stdout**, exit 0; `clean` added to
      `usage()`; `-j`/`-t` documented; `--base` without `--changed` → error
      (exit 3, validated in the CLI arg layer — NOT in the facade).
      **Behavioral reversal (load-bearing):** replace the existing
      `tests/integration/test_changed.nim` test named "`--base` without `--changed`
      warns and runs normally" (which today asserts exit 0) with one asserting exit
      3. This is a behavioral reversal, not incidental cleanup.
      **`crisol clean --config` gap:** `crisol clean` currently hardcodes
      `loadConfig(configPath="")` and rejects unknown flags, so it ignores a
      project's custom `state-dir`. Add `--config <path>` to `clean`'s flag parser
      so it honours a non-default state dir.
      **CHANGELOG.md:** create `CHANGELOG.md` at repo root; its first entry
      documents the `--base`-without-`--changed` change as a breaking CLI change
      with a migration note (amoxtli shells out to `bin/crisol` and is therefore
      affected).
- [ ] **S5 (F3)** — `crisol --version`/`-V`: version read via `staticRead` from
      `crisol.nimble` at compile time (works under `nim r`; `gorge` dropped); add
      `-V` + `version` to the subcommand/flag dispatch. Test asserts the EXACT
      version string (e.g. `crisol 0.1.0`), not merely non-empty, to catch parser
      regressions.
- [ ] **S6 (F3)** — `crisol init [path] [--force]`: writes `const initTemplate`;
      refuses overwrite without `--force`; add `init` to the subcommand dispatch.
- [ ] **S7 (F2)** — README rewrite (status, install, quickstart, CLI reference,
      exit-code table, config reference incl. memory keys + the
      opt-in/gate/`--group` selection model, library-embedding example, the
      structured-results recipe naming the `unittest_shim` tag limitation).
      Tests: `loadConfig(initTemplate)` → zero warnings (single source of truth);
      a schema-version pin assertion using the exported constants `RunV1Schema`
      and `PlanV1Schema` (see below) — NOT duplicated string literals.
      **Schema-version consts:** export `RunV1Schema* = "crisol/run/v1"` from
      `jsonout.nim` and `PlanV1Schema* = "crisol/plan/v1"` from `planview.nim`;
      both the emitters AND the S7 pin test reference these constants so the
      schema string has a single source. Asserting a duplicated string literal in
      the test is not actually drift-proof.

---

## Testing strategy

- **Bootstrap rule unchanged.** New tests live in `tests/unit/` and
  `tests/integration/` and run under the self-discovering serial bootstrap task
  (`nimble test`). The dogfood (S3) must keep that suite green — the bootstrap
  runner is never replaced.
- **Facade boundary tests (S1/S2)** exercise `planTests`/`runTests` directly
  against small fixture suites under `tests/fixtures/`, asserting the
  *observable* report (summary counts, outcomes, exitCode, warnings,
  memThrottledSlots) — not internal call sequences. These replace the need to
  test the pipeline stages individually for composition.
- **CLI regression (S3)** relies on the existing `tests/integration` CLI tests as
  the behavior-preservation proof for the dogfood refactor; add cases only where
  the facade exposes a path the CLI tests don't already cover.
- **CLI verbs (S4–S6)** are tested by invoking `runMain(args)` and asserting exit
  code + emitted text / created file — `runMain` is already a pure
  `seq[string] -> int` entry, so this needs no process spawning.
- **Docs (S7)** verified by review; the canonical-config parse test is the
  automated guard against doc/config drift.
- **Fixture scaffolding (S1a-prep):** `withTempProject(body)` and
  `seedLastRun(projectRoot, results)` helpers are built once (S1a-prep) and
  reused across S1c–S2d so each slice does not reinvent setup.
- **`changedOnly` tests need a real git repo**, not a bare temp dir: git-init a
  temp repo with a commit and a modified tracked file (follow `test_changed.nim`).
- **`failedOnly` fixtures** are produced via `persistLastRun` (correct schema),
  never hand-written JSON (schema drift would make `loadLastRun` raise).
- **Zero-runnable regression anchor (S3a-prep):** before rewiring `runMain`, add
  3 CLI integration tests for the three zero-runnable→exit-0 branches
  (changed-clean-tree, failed-none-matched, all-gated-out). These pass today via
  `runMain` and are the regression anchor proving S3's thin-shell reconstruction
  preserves their exit codes.
- **Multi-cycle slices:** S1/S2 are several RED→GREEN cycles each (≈15–20 cycles
  across S1–S3), not one apiece.

## Observability

No new runtime observability. The facade *surfaces* existing signals
(`warnings`, `memThrottledSlots`, per-entrypoint `outcome`) on the `RunReport`
where today they are only reachable via the CLI's render path.

---

## Resolved decisions (architect round 1)

- **Q1 — `--base` without `--changed` → ERROR** (exit 3 / `rsStructural`).
  Resolved: error. Validated in the CLI arg layer (the CLI maps flags; `--base`
  without `--changed` is caught there and exits 3). At the library level, the
  narrowing constructors make the equivalent condition structurally unconstructable
  (`baseRef` only appears inside `RunNarrowing`, which is only constructable via
  `changedOnly`/`failedOrChanged`). Note the user-visible change (was
  warn-and-continue) in the S4 `CHANGELOG.md` so amoxtli is informed.
- **Q2 — lock/signals defaults.** Resolved: `manageLock` defaults **true** (safe,
  inter-process; documented as NOT guarding same-process re-entrancy);
  `installSignals` defaults **FALSE** for the library (installing process-global
  handlers without consent is hostile — a library must not silently replace a
  host's SIGINT/SIGTERM). The CLI opts in with `installSignals:true`. `runTests`
  calls `clearSignal()` at entry so sequential calls are safe.
- **Q3 — module boundary.** Resolved: new `crisol/api.nim`; the binary stays
  `crisol.nim` as a thin shell. `pipeline.nim`'s "core library entry point"
  doc-comment is demoted in S3b.
- **Q4 — version source.** Resolved: read from `crisol.nimble` at compile time
  via `staticRead("../crisol.nimble")` only — `gorge` dropped (shells out at
  compile time; fragile/empty in sandboxed container builds). NOT the
  `NimblePkgVersion` strdefine (absent under the `nim r` bootstrap harness). A
  compile-time `static: doAssert` on the parsed version string turns parse
  failure into a build error.
- **Q5 — API stability stance.** Resolved: `crisol/api` is the contracted surface
  by convention + CHANGELOG discipline (Nim cannot enforce it); others importable
  but uncontracted. `CHANGELOG.md` is created in S4 (its first entry is the
  `--base`-without-`--changed` breaking change); subsequent breaking changes are
  documented there.

### Flagged judgment calls (round-1 decisions, open to Corey's veto)
- **Return-only `RunReport` (RunStatus enum) instead of the drafted raise-based
  contract** + dropped `exitCodeFor`. Bigger than a tweak — reshapes the facade's
  error model — but it dissolves the raise-vs-return ambiguity (several "structural"
  cases are exit-0/exit-3 inline returns today, not exceptions) and is the
  library-ergonomic choice. `planTests` still raises (inspect path).
- **`installSignals` default flipped to false** (reverses the draft's Q2 lean).
- **`render`/`toJson`/presentation helpers promoted to the public `crisol/api`
  surface** (re-exported) — needed for the dogfood boundary AND for consumers to
  get crisol-format output without re-implementing it.
- **`unittest_shim` cannot emit tags**, so `--filter-tag` is only usable by
  binaries using the raw `report` emitter. Documented as a limitation now;
  shim-tag support deferred to a future feature RFC (not this docs scope).

---

## Changelog

- 2026-06-13 — Draft created (stage 1). Scope = architect new-user candidates
  #1 (facade), #2 (docs), #3 (CLI papercuts). Candidates #4 (config model) and
  #5 (structured-protocol onboarding) deferred; #5's *docs* portion partially
  absorbed by F2's structured-results pointer.
- 2026-06-13 — Architect round 1 applied (4 lenses: depth/breadth/design/
  feasibility). F1 reshaped to a return-only `RunReport` (RunStatus) with a total
  exit-code/zero-runnable taxonomy; dropped `exitCodeFor`; `PlanReport` no longer
  exposes `DepGraph` or full `Config` (slim `ResolvedSettings`); `RunReport`
  composes `PlanReport`; selection constructors added; `installSignals` library
  default → false (+ `clearSignal` at entry); `render`/`toJson`/presentation
  helpers re-exported from `crisol/api`; lock-release made idempotent; added
  Facade-I/O, Concurrency, and stability subsections. Version sourced from the
  nimble file (not `NimblePkgVersion`). F2 structured-results upgraded from a
  pointer to a concrete recipe (naming the `unittest_shim` tag limitation) with a
  `const initTemplate` single-source. Slices re-cut 7 → ~16 (S1a–e, S2a–d,
  S3a/b split per the feasibility finding that S3 is a 490-line big-bang). Q1–Q5
  resolved.
- 2026-06-13 — Architect round 2 applied. Changes: `releaseLock` var-signature +
  no-double-release mandate (S2d prerequisite); `planToJsonString` Config-param
  removed via precomputed `PlannedEntrypoint` fields (`runTimeoutMs`,
  `maxJobs`); `computeColorEnabled` dropped from re-exports (private CLI proc) /
  `filterRecordsByTag` added / `gateSkipMessages` now takes `seq[GatedEntry]`
  directly; `ResultCallback` moved to `types.nim` (S1a); `PlanReport` inlines
  `RunPlan` fields (`entrypoints`, `jobs`) killing `rr.plan.plan` stutter;
  narrowing constructors (`noNarrowing`/`failedOnly`/`changedOnly`/
  `failedOrChanged`) fold `onlyFailed`/`onlyChanged`/`baseRef` out of
  `RunOptions` into `RunNarrowing` (baseRef-without-narrowing structurally
  unconstructable); `staticRead`-only version (`gorge` dropped; compile-time
  `doAssert`; S5 asserts exact version string); S4 gets behavioral-reversal test
  rewrite + `CHANGELOG.md` creation + `clean --config` flag; exit-table signal
  footnote + `rsInterrupted` empty-results note + `jobs<=0` CLI-vs-lib note +
  `stateDir` absolute-path comment + zero-runnable collapse note;
  schema-version consts (`RunV1Schema`, `PlanV1Schema`) exported from emitters;
  `FORCE_COLOR` added to F3 papercuts and F2 docs list; S3 reframed as
  substitution-not-reimplementation + S1a-prep fixture helpers +
  S3a-prep zero-runnable regression anchor; `--fail-fast` and missing config
  keys added to F2 completeness checklist; Slices section clarifying paragraph
  added.
