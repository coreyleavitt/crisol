# RFC-0001 — crisol test runner

**Status:** Draft — revised after architecture review rounds 1 and 2 (ready for implementation)
**Date:** 2026-06-12
**Author:** Corey Leavitt

---

## Summary

crisol is a host-side, out-of-process, assertion-agnostic Nim test runner and impact-analysis tool. It discovers test entrypoints, compiles and runs them in parallel with per-entrypoint isolated nimcaches, aggregates results continue-on-failure, and — given a git diff — selects only the entrypoints whose source-dependency closure intersects the changed files. An optional thin in-process `crisol/report` module lets test binaries emit structured per-test results; binaries that skip it fall back to exit-code + captured output. crisol is never compiled into consumer production binaries.

crisol is a **library first, CLI second**: the core is a pure `discover → applyGates → [narrowByDiff] → plan → execute → report` pipeline with the CLI as a thin shell over it.

---

## Motivation

### Five duplicate serial runners

Five projects in this ecosystem hand-roll essentially the same primitive runner:

| Project | Pattern |
|---|---|
| amoxtli (`lib/cel`) | `nimble exec nim c -r …` list, serial |
| amoxtli (`lib/kdl`) | same |
| proptest | same |
| fresco | same |
| amoxtli itself | `./dev test` calls a shell loop of `nimble exec …` |

Every one of these runners: fails fast on the first entrypoint failure (hides all subsequent results), runs serially, has no parallelism, and maintains a MANUAL manifest. The manual-manifest problem has already caused concrete coverage loss in amoxtli: **9 test files exist on disk but are absent from the runner manifest — they are never executed.**

### The Nim ecosystem gap

`testament` is the Nim compiler's own test framework. It carries heavy compiler-internal assumptions, special `.cfg`-file conventions, and test-template coupling that makes it awkward to use for application-level test suites that don't test the compiler. `nimble test` runs a single `[task]` defined in the nimble file — it provides no discovery, no parallelism, no continue-on-failure, and no selective execution. There is no widely-adopted general-purpose Nim test runner in the ecosystem.

**Prior art note:** community frameworks exist — notably `balls` (née `testes`) — but they are framework-plus-runner packages coupled to their own assertion DSLs and macro styles. None is an assertion-agnostic out-of-process orchestrator, and none offers change-based test selection. crisol deliberately occupies the orchestration niche and leaves assertions to std/unittest (or anything else).

### amoxtli's concrete pain

amoxtli's full suite is approximately 165 entrypoints. Per-entrypoint nimcache isolation is **mandatory** (a shared `--nimcache` is unsound under `--mm:orc`: multiple entrypoints sharing a cache can produce nondeterministic link failures because one entrypoint's `=destroy` instantiations or generic specialisations collide with another's `.c.o` artifacts). Running all 165 entrypoints serially is slow. CI cold-compiles every entrypoint on every run because nimcache artifacts are not cached between runs. The first failure stops the run, hiding every other broken entrypoint.

Additionally, amoxtli's tier-3 smoke tests require a real API key and network access; they must not run as part of the default `./dev test` path. There is currently no mechanism to express this grouping — it is enforced only by convention and a separate `./dev smoke` target.

---

## Goals

1. Discover test entrypoints automatically from glob patterns (no manual manifest).
2. Compile and run each entrypoint in an isolated per-entrypoint nimcache.
3. Run entrypoints in parallel, bounded by a configurable job count, with per-entrypoint timeouts and clean signal handling.
4. Continue-on-failure: run every entrypoint; aggregate and report all results; exit non-zero if any failed.
5. Support named groups with per-group globs, compile flags, and gating conditions.
6. Given a git diff, select only the entrypoints whose source-dependency closure intersects the changed files.
7. Skip recompilation entirely when an entrypoint's binary is provably fresh against that same closure — a bare `crisol run` on an unchanged tree compiles nothing.
8. Provide an optional thin in-process reporting protocol so test binaries can emit structured per-test pass/fail/skip/timing records.
9. Provide a std/unittest integration shim implementing the protocol.
10. Expose the core as a clean library API (pure planning separated from effectful execution) consumable by sibling libs and by crisol's own CLI.
11. Serve as a first-class amoxtli dependency, handling its per-entrypoint nimcache, `-d:amoxtliTesting`, tier grouping, and docker execution context.
12. Dogfood: crisol's own tests run under crisol once the orchestrator works (with a permanent serial fallback runner — see Testing Strategy).

## Non-Goals

- crisol is NOT an assertion or expectation library. std/unittest remains untouched.
- crisol is NOT a property-testing library. proptest is a CONSUMER that runs as a test binary under crisol.
- crisol is NEVER compiled into a consumer's production binary. It is build-time tooling only.
- crisol does NOT fix amoxtli's uuid7 monotonicity flake (B4: `src/daemon/memory/ids.nim` lacks a within-millisecond counter). That is amoxtli domain code, tracked separately in amoxtli.
- crisol does NOT replace std/unittest or proptest's internal assertion machinery.
- crisol does NOT provide a built-in benchmarking framework.

---

## Architecture

### Pipeline + an optional seam

```
┌────────────────────────────────────────────────────────────────────┐
│  HOST PROCESS — crisol (always out-of-process)                     │
│                                                                    │
│   discover ──▶ applyGates ──▶ [narrowByDiff] ──▶ plan ──▶ execute ──▶ summarize ──▶ render │
│   (pure)       (pure)          (pure, --changed   (pure)  (effectful)  (pure)        (pure) │
│      ▲                          only)               ▲                                       │
│   config                                         impact analysis: persisted dep-closure graph│
│   (parsed)                                       (selection is pure; graph extraction is    │
│                                                   effectful, runs after successful compile)  │
│                                        │ reads sink file per entrypoint                     │
└───────────────────────────────────────┼────────────────────────────────────────────────────┘
                           │ (optional: env-passed sink path)
┌──────────────────────────▼─────────────────────────────────────────┐
│  TEST BINARY — compiled from consumer's test entrypoint            │
│                                                                    │
│  consumer test code                                                │
│  + optionally: import crisol/report   ← thin in-process emitter   │
│    or: import crisol/unittest_shim    ← one-line drop-in           │
│                                                                    │
│  Binaries without crisol/report: exit-code + output fallback       │
└────────────────────────────────────────────────────────────────────┘
```

### Library API (the core contract)

crisol is consumed as a library by sibling libs and by its own CLI. The decision/I-O split is structural: planning is pure and unit-testable with zero I/O; execution is the only effectful stage.

```nim
type
  Gate* = object
    env*: string                      # env var; gate passes iff set AND non-empty (trimmed)

  Group* = object
    name*: string
    globs*: seq[string]
    flags*: seq[string]               # compile flags
    optIn*: bool                      # true = only runs when explicitly requested
    gate*: Option[Gate]
    timeoutSecs*: int                 # 0 = inherit global

  Config* = object
    groups*: seq[Group]
    jobs*: int                        # 0 = max(1, countProcessors() - 2)
    timeoutSecs*: int                 # per-entrypoint run timeout (default 300)
    compileTimeoutSecs*: int          # per-entrypoint compile timeout (default 600)
    maxOutputBytes*: int              # per-entrypoint output cap (default 10 MiB)
    stateDir*: string                 # default ".crisol" at project root
    depRoots*: seq[string]            # optional additional source roots beyond the project root
                                      # whose .nim files are included in closure tracking
                                      # (e.g. a sibling lib under active co-development)
    projectRoot*: string              # set by loadConfig (config file's directory, or fallback
                                      # root per config-discovery rules); hand-set in tests

  GroupSelectionKind* = enum gskDefault, gskNamed, gskAll
  GroupSelection* = object            # mirrors --group/--all-groups exactly; an empty
    case kind*: GroupSelectionKind    # name list can't be confused with "defaults"
    of gskNamed: names*: seq[string]
    else: discard

  Entrypoint* = object
    path*: string                     # project-root-relative
    group*: string
    flags*: seq[string]               # merged: global ++ group (group last-wins)
    # cache/binary locations are DERIVED via nimcacheDir()/binPath(), never stored —
    # a hand-built Entrypoint can't carry a corrupt slug, and the slug scheme can
    # change without migrating serialized state

  CompileDecision* = enum
    cdNeverBuilt,                     # no binary exists at the keyed path
    cdStale,                          # binary exists but source/dep/flags/version changed
    cdSkipFresh                       # binary provably current — all freshness conditions met
    # The executor treats decision != cdSkipFresh as "compile". list/--dry-run render each
    # variant distinctly so the user can see WHY a compile is (or is not) triggered.

  PlannedEntrypoint* = object
    ep*: Entrypoint
    decision*: CompileDecision
    reason*: string                   # supplementary human-readable detail; surfaced by list/--dry-run

  RunPlan* = object
    entrypoints*: seq[PlannedEntrypoint]
    jobs*: int                        # resolved by plan(); never 0

  TestStatus* = enum tsPass, tsFail, tsSkip

  TestRecord* = object
    name*: string
    status*: TestStatus
    durationUs*: int64
    msg*: Option[string]              # failure message or skip reason
    tags*: seq[string]

  Outcome* = enum
    oPassed, oFailed, oCompileFailed, oTimeout, oSignal

  EntrypointResult* = object
    ep*: Entrypoint
    outcome*: Outcome
    signal*: int                      # POSIX signal number when outcome == oSignal
    records*: seq[TestRecord]         # empty when the protocol was not used
    output*: string                   # captured stdout+stderr; file-backed during run,
                                      # materialized into the result bounded by maxOutputBytes.
                                      # Common case is tiny; the cap is a safety valve.
                                      # render reads failing entrypoints' output from file.
                                      # Worst-case aggregate: N × maxOutputBytes (known bound).
    outputTruncated*: bool            # maxOutputBytes cap hit
    compileSkipped*: bool             # cdSkipFresh: nim c was not invoked
    durationUs*: int64

  Summary* = object                   # raw counts — constructible in tests, no strings
    total*, passed*, failed*: int
    compileFailed*, timedOut*, signaled*: int
    noTestsRan*: bool                 # e.g. every entrypoint failed to compile
    slowest*: seq[tuple[path: string, durationUs: int64]]
    failedEntrypoints*: seq[tuple[path: string, group: string]]
      # (path, group) pairs — a file can run under multiple groups/flag-sets, so path
      # alone is not a unique identity; --failed uses both fields to key the re-run

  ReportFormat* = enum rfHuman, rfJson
    # adding a variant is a minor version: source-compatible, consumers recompile

  DepGraph* = object                  # OPAQUE. Internally: (path, flagHash) → closure
    ...                               # + per-file hashes. Constructed only via loadGraph/
                                      # graph-update during execution; encoding never leaks.

  GateState* = object                 # OPAQUE. Snapshot of gate env vars captured once
    ...                               # by loadGateState; never re-reads the environment.

  DiscoveredSet* = distinct seq[Entrypoint]
    # Returned exclusively by discover(); consumed exclusively by applyGates().
    # The distinct type enforces gate-application by type — silently skipping
    # applyGates() is a compile error, not a runtime surprise.

  ResultCallback* = proc(r: EntrypointResult) {.closure.}

  CrisolErrorKind* = enum cekConfig, cekEnvironment, cekInternal
  CrisolError* = object of CatchableError
    kind*: CrisolErrorKind            # maps to exit codes: config/env → 3, internal → 2

# Effectful setup (thin, explicit — the library exposes everything its own CLI needs):
proc loadConfig*(startDir: string): Config
  # Walk-up discovery; conventions fallback. Sets config.projectRoot to the config
  # file's directory (or the fallback root per config-discovery rules — nearest .git
  # dir if present, else cwd). Hand-constructible in tests: set config.projectRoot directly.
proc loadGraph*(stateDir: string): DepGraph
  # Absent/empty file → empty graph (returns empty, logs warning on malformed/unreadable
  # input — does NOT raise; the graph is a derived cache, so a corrupt file → conservative
  # full run, not a crash).
proc changedFiles*(projectRoot: string; base: Option[string]): HashSet[string]
  # Shells out to `git diff --no-renames --name-only`. Returns paths normalized to
  # project-root-relative, matching Entrypoint.path and dep-graph keys. All three path
  # spaces (entrypoints, dep-graph entries, changed-file results) share one coordinate
  # system: project-root-relative. Raises CrisolError(cekEnvironment) when git is missing
  # or projectRoot is not a git repository.
proc loadGateState*(config: Config): GateState
  # Effectful: reads each group's gate env var exactly once and snapshots the result.
  # Tests use initGateState instead — never touching the real environment.
proc initGateState*(vars: openArray[(string, string)]): GateState
  # Test constructor: builds a GateState snapshot from explicit name/value pairs.
  # Internal representation stays opaque. Use this in tests; never loadGateState.

# Pure planning (discover reads the file tree; everything downstream is pure):
proc discover*(config: Config;
               selection = GroupSelection(kind: gskDefault)): DiscoveredSet
  # NO gateCheck param — discover is pure file-tree enumeration; it does NOT consult gates.
  # gskDefault excludes optIn groups; gskNamed/gskAll bypass optIn. Gates are applied separately.
  # Root is derived from config.projectRoot (set by loadConfig, or hand-set in tests).
proc toDiscoveredSet*(eps: seq[Entrypoint]): DiscoveredSet
  # Exported test constructor — lets unit tests build a DiscoveredSet without going through
  # discover(). This is the only wrapper; no other stage has a bypass constructor.
proc applyGates*(eps: DiscoveredSet; config: Config;
                 state: GateState): tuple[run: seq[Entrypoint]; gatedOut: seq[tuple[group: string; reason: string]]]
  # PURE: returns runnable entrypoints plus suppressed groups with human-readable reasons,
  # e.g. reason = "env AMOXTLI_OPENROUTER_API_KEY not set".
  # The gatedOut list lets `list --all-groups` annotate gate-suppressed groups without
  # re-consulting Config. Tests pass a hand-built GateState — never touching the environment.
proc plan*(config: Config; eps: seq[Entrypoint]; graph: DepGraph): RunPlan
  # validates (duplicate paths, identical-flag overlap), resolves jobs,
  # annotates CompileDecision per entrypoint (empty graph → all cdNeverBuilt/cdStale)
proc narrowByDiff*(eps: seq[Entrypoint]; changed: HashSet[string]; graph: DepGraph): seq[Entrypoint]
  # PURE: keeps only entrypoints whose closure (from graph) intersects changed.
  # Conservative fallback: absent/partial graph, any missing closure file, or any
  # uncertainty → keep the entrypoint. Operates on seq[Entrypoint], NOT RunPlan.

# Effectful execution:
proc execute*(p: RunPlan; onResult: ResultCallback = noopResult): seq[EntrypointResult]

# Pure over results:
proc summarize*(results: seq[EntrypointResult]): Summary
proc render*(results: seq[EntrypointResult]; fmt: ReportFormat): string
  # takes the full result sequence so B4 can produce slowest-N, per-test failure messages,
  # and skip reasons — counts alone (Summary) are insufficient for rich output.
  # render computes the Summary internally for the headline line.
proc toJson*(results: seq[EntrypointResult]): JsonNode
  # Single serialization path: both render(results, rfJson) and the lastrun.json write go
  # through toJson. summarize is called internally — not re-implemented — so headline
  # counts never diverge from the record data. MANDATE: render must call summarize, not
  # re-implement count logic.
proc noopResult*(r: EntrypointResult) = discard
  # Exported default for execute's onResult parameter — never nil, so optionality is
  # visible in the type rather than hidden in a nil check inside execute.

# Derived-path and convenience helpers:
proc nimcacheDir*(ep: Entrypoint; stateDir: string): string
proc binPath*(ep: Entrypoint; stateDir: string): string
proc signalName*(n: int): string      # 11 → "SIGSEGV"; consumers never import posix for this
```

**Pipeline-ordering contract (invariant):** the pure pipeline is `discover → applyGates → narrowByDiff (only if --changed) → plan → execute`. This ordering is an invariant, not a suggestion: `applyGates` MUST precede `plan`; `narrowByDiff` (when used) runs between `applyGates` and `plan`; `plan` is always the final pure step before `execute`. Entrypoints already in a `RunPlan` are never re-gated or re-narrowed. The advisory lock (see §State directory) is acquired before `plan` is called, so freshness verdicts in `plan` are computed against stable, non-racing state.

**Error policy (library consumers):** per-entrypoint failures are *data*, never exceptions — they live in `EntrypointResult.outcome`. Exceptions are reserved for structural failure: pure stages raise `CrisolError(kind: cekConfig)` on bad config/unknown group/overlapping identical-flag globs; effectful procs raise `cekEnvironment` (nim/git missing, temp dir creation failed, lock held) or `cekInternal` (invariant violation). The CLI maps `kind` onto its exit-code taxonomy; library consumers catch one exception type and switch on `kind`. `changedFiles` raises `CrisolError(cekEnvironment)` when git is missing or the cwd is not a git repository. `loadGraph` on a malformed or unreadable depgraph file does NOT crash — it logs a warning and returns an empty `DepGraph` (conservative full run; the graph is a derived cache).

Gate state is captured once by `loadGateState` (effectful, reads env vars) and applied by the pure `applyGates` filter; tests use `initGateState`, never touching the real environment. `discover` derives the project root from `config.projectRoot` (set by `loadConfig`; hand-set in tests) — there is no separate `root` parameter. The `DiscoveredSet` distinct type enforces that `applyGates` is called between `discover` and downstream stages; skipping it is a compile error. `onResult` defaults to an exported `noopResult` proc — never `nil` — so the optionality is visible in the type, not in a hidden nil check. `crisol list` and `--dry-run` are the plan phase with execution skipped — they fall out of this split for free, and because `CompileDecision` is annotated at plan time, both also show per-entrypoint "would compile" / "never built" / "binary fresh — would skip compile". (A standalone public `compile` proc is deliberately deferred: v1.1's `--check` will promote the internal compile stage to public API additively.)

### Layer 1 — Executor (out-of-process)

1. **Compiles** each entrypoint with `nim c`, using an isolated `--nimcache` directory per (entrypoint, flag-set) and `--out` into `.crisol/bin/<slug>/`. Compile flags (including consumer-specific ones like `-d:amoxtliTesting`) are injected from group config. Entrypoints the plan marked `cdSkipFresh` skip this step entirely (see Compile Avoidance).
2. **Runs** the compiled binary with a fresh sink path in `CRISOL_SINK` and a fresh per-entrypoint temp dir in `CRISOL_TMPDIR`. After the binary exits it reads the sink file (if present) for structured records; otherwise falls back to exit-code + captured output.
3. **Parallelises** with a bounded job pool (`--jobs N`, default `max(1, cpu-2)`). The `cpu-2` default reserves headroom for I/O and the crisol process itself — measured per-compile peak RAM is approximately 141 MiB (not ~1 GB as a naive estimate might suggest), so RAM pressure is rarely the binding constraint; I/O bandwidth typically is.
4. **Aggregates** continue-on-failure: every entrypoint runs regardless of other failures.

**Concurrency mechanism (decided):** each child is spawned via raw `std/posix` fork+exec (see Process lifecycle below) and supervised by a poll loop (`waitpid` with `WNOHANG`, ~25–50 ms interval). A poll loop — not `threadpool` + blocking wait — because timeout enforcement and process-group kill require non-blocking supervision of live children. Durations are measured with a monotonic clock from spawn to observed exit (poll latency affects slot release, not correctness). Slice A2a verifies the fork+setpgid+killpg mechanism before A4 generalises to the full pool.

**Output capture:** each child's stdout+stderr is redirected to a per-entrypoint temp file — never buffered unbounded in memory — and printed atomically after the entrypoint completes. No interleaving by construction. Capture is bounded by `max_output_bytes` (default 10 MiB, configurable) covering both compile output and runtime output; on hitting the cap the writer stops persisting, a sentinel line is appended, and the result carries `outputTruncated` — a runaway logger can't fill the disk.

**stdin:** test binaries (and compiler invocations) always run with stdin redirected from `/dev/null`. A test that accidentally reads stdin fails fast instead of hanging until the timeout reaps it.

**Compiler noise:** crisol injects `--hints:off` as the first global flag (group flags come later and may re-enable). Warnings stay on. Compile output is captured like runtime output and shown for failing entrypoints; a passing entrypoint's compile chatter is not printed.

**Process lifecycle (timeouts, signals, orphans):**

- Every spawned process (compiler and test binary) is placed in its own POSIX process group. **Decided mechanism (verified on Nim 2.2/Linux, grandchild reap confirmed):** crisol spawns every child via raw `std/posix`: `fork()`, then in the child `setpgid(0, 0)` (new process group == pid), `dup2` stdin from `/dev/null` and stdout+stderr to the per-entrypoint temp output file, then `execvp`. The parent records the child pid, which equals the pgid. `osproc` is rejected for this role: `useProcessAuxSpawn` excludes Linux (no `posix_spawn` path), and parent-side `setpgid(pid, pid)` after `startProcess` returns `EACCES` because the child has already `execve`'d. All required primitives (`fork`, `setpgid`, `dup2`, `execvp`, `killpg`) are present in `std/posix`. This fork+dup2-to-file approach also solves output redirection at spawn time, avoiding osproc's pipe-drain deadlock at the 64 KB pipe-buffer limit. **Async-signal-safety constraint (invariant):** the child path between `fork()` and `execvp()` must call ONLY libc-level async-signal-safe primitives (`setpgid`, `dup2`, `execvp`) — no Nim heap allocation, no GC, no exception machinery, no string construction; implemented as a `{.raises: [].}` sequence. This is sound precisely because crisol's executor is a **single-threaded poll loop that starts no Nim threads or threadpool before the spawn loop**, so no background thread holds a lock at fork time. Both halves — libc-only child path AND single-threaded executor — are invariants; violating either breaks the safety argument. `killpg` reaps grandchildren (empirically confirmed in A2a's regression test).
- A raw-fork failure for a single entrypoint is classified as that entrypoint's `oCompileFailed` (or `oFailed` for the run phase) — it never crashes the pool. Global preconditions (nim missing entirely) are still exit 3 before any spawn.
- Per-entrypoint **run timeout** (`timeout_secs`, default 300, per-group override, `--timeout` CLI override) and **compile timeout** (`compile_timeout_secs`, default 600). On expiry: SIGTERM to the process group, 5 s grace, then SIGKILL. Outcome is reported as `timeout`, distinct from failure.
- A `nim c` invocation killed by timeout or signal leaves its nimcache partially written; crisol **deletes that entrypoint's nimcache dir** before the next compile of it (the dir is per-(entrypoint, flag-set), so deletion is cheap and surgical). A half-written cache must never feed a later link.
- A binary killed by a signal (SIGSEGV, SIGABRT, …) is reported as `signal: <name>`, distinct from test failure; contributes to exit code 1.
- On SIGINT/SIGTERM to crisol itself: the poll loop performs cleanup (SIGTERM to all live child process groups, 5 s grace, SIGKILL stragglers, delete all temp sink files and temp dirs — best-effort; a SIGKILL before cleanup leaks dirs). After cleanup, crisol reinstates the default handler for the received signal and `raise`s it, so the parent process sees a signal-killed child rather than a synthetic `exit(128+N)`. **Handler discipline:** the signal handler only sets an atomic flag — Nim's runtime (ORC included) is not async-signal-safe, so all kill/cleanup/re-raise work runs in the poll loop's next iteration in normal context. On startup, crisol reaps stale `crisol-<pid>` temp dirs whose PID is no longer alive.
- **Progress during long/hung runs:** the poll loop emits a "still running" line to stderr approximately every 30 seconds listing in-flight entrypoints by path; suppressed under `--json`. This is critical at amoxtli's 165-entrypoint scale — a single hung entrypoint would otherwise produce silence for up to the timeout period.

**Environment isolation:** test binaries inherit crisol's environment **minus all `CRISOL_*` variables**, then receive exactly `CRISOL_SINK` and `CRISOL_TMPDIR` injected per invocation. Each entrypoint's `CRISOL_TMPDIR` is a **unique** fresh directory created by crisol before the entrypoint starts — tests writing scratch files never collide across the parallel pool. crisol **removes the directory after the entrypoint completes** (both on normal exit and on signal-driven cleanup, which removes all outstanding temp dirs). **`CRISOL_SINK` self-unset (enforced):** `crisol/report` reads `CRISOL_SINK` once at module init and immediately unsets it from the environment (`putenv("CRISOL_SINK=")` / `unsetenv`), so any subprocess the test `exec`s (notably the dogfood case, crisol-under-crisol) does not inherit it and corrupt the outer run's sink. This is enforced behavior in the emitter, not consumer guidance. Per-group env allowlists/injection are deferred to v1.1.

**Toolchain resolution:** the `nim` binary is resolved from `$NIM` if set, else `PATH`. The resolved path and `nim --version` output are recorded in the dep-graph header; a version change invalidates the entire dep graph (one-time re-scan cost on upgrade — correct behavior). `nim` missing entirely → exit 3.

**Compile-flag precedence:** crisol always spawns `nim` with the project root as working directory, so the consumer's ambient `nim.cfg`/`config.nims` applies first; crisol's global flags come next, then group flags (last wins, standard Nim CLI precedence). crisol always overrides `--nimcache`; consumers must not set it for test builds.

### State directory & cache management

All crisol state lives under `.crisol/` at the project root (gitignored):

```
.crisol/
  bin/<slug>/                  # compiled test binary per (entrypoint, flag-set)
  cache/<slug>/                # per-(entrypoint, flag-set) nimcache
  depgraph                     # persisted dependency closures
  lastrun.json                 # machine-readable result of the most recent run
  lock                         # advisory lock (fcntl F_SETLK)
```

- **Binary placement:** every compile passes `--out:.crisol/bin/<slug>/<basename>`. Without this, `nim c` drops binaries next to the sources — 165 strays in the test tree — and the binary path wouldn't be keyed by flag-set, so two flag variants of one entrypoint would race on a single artifact and a binary built with flags A could satisfy a freshness check for flags B. The keyed path is also what makes compile avoidance (below) sound.
- **Slug scheme:** `<path with / → __>-<hash16>`, e.g. `tests__unit__test_parser-3fa9c2d18b4e7a05/`. The readable prefix is cosmetic; **identity comes from `hash16`** — the full 64-bit FNV-1a over `path & "\0" & flags.join("\x1f")` rendered as a 16-hex-char suffix. Using the full 64 bits is essential: 32 bits (8 hex chars) has a 1-in-4-billion collision probability per pair — a collision yields a shared nimcache or bin dir, which is the exact ORC link corruption crisol exists to prevent. At 64 bits, collision resistance is sufficient (not a security concern). This makes the slug injective over (path, flag-set) even for pathological filenames containing literal `__`, preserving the ORC isolation invariant, and gives a flag change a fresh cache (also makes CI caching safe — see F3). `std/hashes` is explicitly *not* stable across Nim versions/platforms and is never used for keys persisted on disk. Directory creation is idempotent (`createDir` is exist-ok) for parallel safety.
- **`crisol clean`** prunes orphans by **forward computation** — no slug decoding: compute the expected slug set from current discovery over *all* configured groups (opt-in included; gates ignored — a closed gate must not delete caches), then delete every dir under `cache/` and `bin/` not in that set. Clean also **drops depgraph entries whose entrypoint no longer matches any glob** — stale entries are not left to bloat or confuse the conservative fallback. This automatically covers entrypoints no longer matched by any glob *and* stale flag-set variants after a flag change. `crisol clean --all` removes `.crisol/` state entirely (cache, bin, depgraph, lastrun.json).
- **Concurrent invocations:** each run takes an advisory `fcntl` `F_SETLK` lock on `.crisol/lock` before compiling; if held, crisol exits 3 with a clear message. (`flock` is not in `std/posix`; `fcntl` with `F_SETLK` is present and the lock is released automatically on process death.) Two parallel `nim c` into one nimcache dir corrupt each other; fail fast instead. Read-only commands (`list`, `--dry-run`) don't take the lock: depgraph writes are temp-file + `rename(2)`, which is atomic on a same-filesystem POSIX rename, so readers see old or new content, never torn. The lock is held from `execute` entry / before the first compile through depgraph finalization; `plan()` is called after the lock is acquired so freshness verdicts are computed against stable state. All depgraph writes happen in the main poll loop — never from a forked child or parallel worker — ensuring a single writer within a run. Only one run at a time per project root is permitted; two invocations against a shared workspace (e.g. a CI matrix job on one volume) → the second exits 3. Recommend per-job workspaces in CI. Group-scoped locking is not supported in v1. All `.crisol/` contents are reconstructible derived artifacts; out-of-band deletion (`git clean -fdx`) is equivalent to `crisol clean --all` and is safe (next run rebuilds; `--failed` errors cleanly if no prior run).


### Compile avoidance (binary freshness)

Without it, a bare `crisol run` recompiles all ~165 amoxtli entrypoints on every invocation even when nothing changed — at that scale, compilation is the dominant cost and the tool would feel slower than the serial runners it replaces. The dep-closure graph (Layer 2) already holds exactly the data needed to decide "is this binary still valid?", so freshness reuses it rather than introducing a second tracking mechanism.

`plan()` assigns a `CompileDecision` to each entrypoint. An entrypoint is `cdSkipFresh` **iff all of**:

1. The binary exists at `binPath(ep)` (keyed by the (path, flag-set) slug). If not: `cdNeverBuilt`.
2. The depgraph entry for (path, flag-hash) exists and passes **every** invalidation rule: the entrypoint's own content hash is unchanged; every closure file is present and its **content hash** matches the stored hash (ALWAYS hash, never trust mtime for correctness — mtime ONLY serves as a fast-path to skip re-hashing when mtime+size are identical, but any mtime/size mismatch falls through to content hashing, and a hash mismatch or missing file → `cdStale`). If any closure file is missing or any hash differs: `cdStale`.
3. The depgraph header's nim version matches the currently resolved nim version — **a nim upgrade must never run old binaries** (ABI/codegen drift), independent of source freshness. Mismatch → `cdStale`.
4. The `crisol/report` protocol major version recorded in the dep-graph entry is compatible with the current orchestrator (see Protocol versioning). Major mismatch → `cdStale`.

If none of the above stale conditions apply and the binary is present: `cdSkipFresh`. The executor treats `decision != cdSkipFresh` as "compile". `list`/`--dry-run` render each variant (`cdNeverBuilt`, `cdStale`, `cdSkipFresh`) distinctly. `--force-compile` overrides everything to `cdStale` (or `cdNeverBuilt` when the binary is truly absent — the override forces compilation regardless). The decision is made purely at plan time and carried on `PlannedEntrypoint`; `execute` contains no freshness logic. Before Stage D lands, the graph is empty and every entrypoint is `cdNeverBuilt` or `cdStale` — correct, merely slower.

**mtime is not a correctness gate.** Binary mtime vs closure mtime was previously considered as an additional freshness rule and is **removed as unsound**: coarse-mtime filesystems (FAT/exFAT 2-second granularity), container/overlay mounts, and NFS/clock-skew can all produce mtime ≥ newest-closure even for a stale binary. The interrupted-build case that rule targeted is already covered by the content-hash check plus the "delete nimcache dir after a killed compile" rule. mtime is used only as a read-shortcut (skip hashing when mtime+size match), never as a decision gate.

A cheaper stat-only variant (skip when only the entrypoint's *own* file is older than the binary) was considered and **rejected as unsound**: a changed import leaves the entrypoint file untouched while the binary goes stale — the suite would silently green-light old code, the false-confidence failure mode this RFC exists to eliminate. Freshness must be closure-backed, which is why it lands in Stage D (slice D6), not Stage A.

### Config discovery

crisol locates its config file by walking up from the cwd until found; `--config <path>` overrides. The project root is the config file's directory (`config.projectRoot`). If no config file is found and no `--config` is given, crisol falls back to built-in conventions (`tests/unit/test_*.nim`, `tests/integration/test_*.nim` as default groups) rooted at the nearest enclosing `.git` directory if present, or else the cwd — this is NOT an error. Explicit paths on the CLI always work regardless. Only `--changed` requires git: absent git, `changedFiles` raises `cekEnvironment` (exit 3). `crisol run` works on a bare checkout; only impact analysis needs git.

### Layer 2 — Impact analysis

1. Extracts the **source-dependency closure** for each entrypoint — the transitive set of `.nim` files the entrypoint imports under its group's compile flags — **filtered to files under the project root** (plus optional configured `dep_roots`). `dep_roots` is an optional list of additional source roots beyond the project root whose `.nim` files are included in closure tracking — for example, a sibling library under active co-development that is not yet a versioned nimble package. Stdlib and nimble-package paths are excluded from tracking; toolchain changes are handled by the nim-version key instead.
2. Persists the graph keyed by **(entrypoint path, flag-set hash)** — per-group closures are stored and invalidated independently, because `when defined(…)` imports differ per flag set.
3. Given a **git diff**, selects only entrypoints whose closure intersects the changed set.
4. Applies a **conservative fallback** (below).

### Layer 3 — Result/discovery protocol (optional, in-process)

A thin NDJSON record format emitted by test binaries to a sink file (full spec in Result Protocol below). The `crisol/report` module is the in-process emitter. The **std/unittest shim** is a one-line drop-in:

```nim
# before:                          # after:
import std/unittest                import crisol/unittest_shim
```

The shim re-exports std/unittest and registers a protocol-emitting output formatter at import time; existing `suite`/`test` bodies need no changes. Binaries that use neither fall back to: pass iff exit code 0; captured output is the failure message otherwise. (Auto-injecting the shim via compile flags was considered and rejected for v1 — too magical; revisit in v1.1.)

---

## CLI Surface

Groups and paths are separate namespaces — groups are selected with `--group`, positionals are always filesystem paths. This removes the ambiguity of a shared positional.

```
crisol run [<path>...]                  # default (non-opt-in) groups when no args
  --group <name>            # run named group(s) instead of defaults (repeatable)
  --all-groups              # include opt-in groups (gates still apply)
  --changed [--base <ref>]  # impact selection; default base: HEAD
  --dry-run                 # print the selected entrypoints and exit 0; do not run
  --failed                  # re-run only entrypoints that failed in the last run
  --filter-tag <tag>        # reporting-level filter over protocol records
  --fail-fast               # stop on first entrypoint failure (dev-loop opt-in)
  --force-compile           # ignore binary freshness; recompile everything selected
  --jobs <N>                # parallel job cap (default: max(1, cpu-2))
  --timeout <secs>          # per-entrypoint run-timeout override
  --json                    # machine-readable output (schema fixed at B5)

crisol list [<path>...] [--group <name>] [--changed [--base <ref>]] [--json]
                                        # what WOULD run, one per line; no compile/run

crisol clean [--all]                    # prune orphaned caches / wipe all state
```

Notes:

- **Positional paths** always run, *bypassing opt-in* (naming a file is the strongest possible opt-in), but **gates still apply** — a gate is a safety/precondition check, not a convenience filter; `crisol run tests/smoke/test_relay.nim` without the API key skips cleanly with the gate message. A path matching **no** configured group becomes an ad-hoc entrypoint with global flags only, plus a warning — this keeps un-configured files runnable during migration (amoxtli's 9 orphans) without config surgery. A path matching **several** groups is several entrypoints — one per owning group, each under that group's flags (issue #10: a group denotes globs × flags and identity is (path, flags), so naming the file selects the file, never one leg of its matrix); `--group` narrows the candidate owners.
- `--base <ref>` (not `--since`: git's own `--since` takes a *date*; reusing it for a ref invites misuse). Exact git commands (via `changedFiles`; `--no-renames` always present so renames surface as delete+add): no `--base` → `git diff --no-renames --name-only HEAD` (all tracked modifications, staged + unstaged, vs HEAD); `--base <ref>` → `git diff --no-renames --name-only <ref>` (**working tree vs ref** — deliberately includes uncommitted edits; a committed-range diff (`<ref>..HEAD`) would miss them, a false negative, violating the when-in-doubt-run-it bias. Over-selection is safe; under-selection is not). **Trade-off acknowledgment:** working-tree-vs-ref always includes uncommitted edits (correct, conservative), but passing a distant ancestor ref over-selects everything touched on the branch. The conservative bias favors this; a developer wanting a focused re-run can pass `HEAD~N` for a narrower diff window.
- When the dep graph is absent or empty (first run, post-`clean`), `--changed` conservatively selects **everything** and the summary states it explicitly (`dep graph absent — full run`) — selection surprises must be loud, not silent.
- `--filter-tag` filters which protocol records are *surfaced in reporting*; it never changes which entrypoints execute (group selection is the execution axis). Opaque entrypoints (no protocol) always contribute their exit-code outcome to the aggregate regardless of the filter. If zero records carry the tag, crisol prints an explicit warning — including the common cause that the binaries don't emit the protocol.
- `--failed` reads `.crisol/lastrun.json`; errors clearly (exit 3) if no previous run exists. Failed entrypoints are keyed by **(path, group)** — the same file can run under multiple groups with different flag-sets, so path alone is not a unique identity. A recorded (path, group) pair that no longer matches any group is warned about and skipped (partial re-run beats abort); a pair whose flags changed compiles with the *current* flags. Combined `--failed --changed` selects the **union** — either criterion includes (conservative; intersection could miss a newly broken entrypoint absent from the prior run).
- `--dry-run` and `list` are the pure plan phase — selection *and per-entrypoint compile decisions* ("would compile" / "binary fresh") are fully inspectable before trusting them. `list` omits opt-in groups unless `--all-groups`, which annotates every entrypoint with its gate status (`run` / `gate-skip: <reason>`).

**Exit codes:**

- `0` — all selected entrypoints passed (cleanly gate-skipped groups don't fail a run). Also: `--changed` selects zero entrypoints on a clean tree → exit 0 with "nothing affected". All groups gated closed → exit 0 with a clear "all groups gated out" message.
- `1` — one or more entrypoints failed, failed to compile, timed out, or died by signal. If *all* entrypoints failed to compile (`noTestsRan = true`), the summary carries a prominent "no tests ran" warning in human output AND `noTestsRan` is surfaced in `lastrun.json` so CI can distinguish "nothing ran" from "ran and failed" without a separate exit code.
- `2` — crisol internal error (invariant violation, unexpected state). Never expected in normal operation.
- `3` — environment/configuration error: `nim` not found, `git` missing or not a repo under `--changed`, config parse error, unknown group name, lock contention, `--failed` with no prior run, zero entrypoints discovered with no `--changed`/`--failed` (no glob matched — almost always misconfiguration; message: "no entrypoints matched — check config/globs").
- `128 + N` — crisol itself terminated by signal N (after killing children and cleaning up).

---

## Config

Format per Open Q1. Regardless of format, the config expresses:

```
# conceptual — actual syntax per Open Q1

[crisol]
jobs = 4                       # default job count (overridden by --jobs)
timeout_secs = 300             # per-entrypoint run timeout
compile_timeout_secs = 600

[[group]]
name = "unit"
globs = ["tests/unit/test_*.nim"]

[[group]]
name = "integration"
globs = ["tests/integration/test_*.nim"]

[[group]]
name = "smoke"
globs = ["tests/smoke/test_*.nim"]
flags = ["-d:network"]
opt_in = true                  # only runs via --group smoke or --all-groups
timeout_secs = 900

[group.gate]                   # typed object, not a bare string — extensible
env = "AMOXTLI_OPENROUTER_API_KEY"   # must be set AND non-empty (trimmed)
```

- **Polarity:** groups run by default; the exceptional case is marked `opt_in = true`. (The draft's `default = true` required annotating the common case.)
- **Gate semantics:** `env` gates pass iff the variable is set and non-empty after trimming — an exported-but-empty API key skips cleanly rather than launching tests that fail on auth. A failed gate **skips the group cleanly with a message** (never a failure). The gate is a typed sub-object so v1.1 can add `file`/`cmd`/compound gates without a schema break; v1 supports `env` only (conscious scope decision).
- **Glob semantics:** `*`, `?`, and `**` (recursive descent) are supported, implemented over `walkDirRec` with an internal pure matcher (unit-testable; `std/os.walkPattern` lacks `**`). No external glob dependency. The walk does **not** follow directory symlinks (`followFilter` excludes `pcLinkToDir`) — a symlink escaping the project root would break the root-relative path invariant the slug and depgraph keys depend on; the minimum Nim version for this `walkDirRec` API is recorded by spike D1a.
- **Glob overlap:** one file matched by multiple groups yields one entrypoint per *distinct merged flag-set* — running the same tests under different flags is a deliberate, supported pattern (each variant has its own slug/cache/binary/closure), and `plan()` produces independent `PlannedEntrypoint`s for each. `plan()` raises `cekConfig` iff two entries share BOTH the same `path` AND the same resolved (merged) flag-set; identical paths with DISTINCT flag-sets are valid and produce independent planned entrypoints. Running a file twice with the identical flag-set is never intended.
- **Flag merge:** global flags ++ group flags, group last-wins (matches Nim CLI precedence).
- Before C1 finalises the schema, the group/flags/gate model is validated against proptest's and fresco's test patterns (the next consumers) so the schema isn't amoxtli-shaped by accident — formalised as spike C0.

### Entrypoint granularity (consumer guidance)

The entrypoint is crisol's *only* unit — of compilation, parallelism, impact selection, and crash isolation. How a consumer splits test files therefore **is** the granularity knob, and getting it wrong silently forfeits crisol's value:

- **Too coarse** (one mega-file importing everything): `--changed` always selects it, parallelism collapses to one slot, and one SIGSEGV takes down every test in the file. A single entrypoint that transitively imports all project modules defeats impact selection *entirely*.
- **Too fine** (one test per file): per-entrypoint compile+link overhead dominates, and ORC isolation means no cache sharing to amortize it.
- **Recommended grain: one entrypoint per logical module under test** — `tests/unit/test_parser.nim` importing `src/parser.nim` and little else. This matches the natural `import` boundary, so changing `src/parser.nim` selects exactly `test_parser.nim`. As calibration, amoxtli's 165 entrypoints average ~5–15 tests each.
- Compile avoidance shifts the cost curve **toward more, smaller entrypoints**: after the first build, unaffected entrypoints skip `nim c` entirely, so the marginal cost of a finer split falls to near zero while selection precision rises.

This is spec, not a caveat: new consumers (proptest, fresco) adopt this grain from day one.

---

## Impact Analysis

### Dependency source (DECIDED)

The closure is derived from the **Nim compiler's own output** — never a hand-rolled import parser (a missed `when defined(…)` import silently skips a test that should run: false confidence). **Decided mechanism (empirically verified):** extract each entrypoint's source closure from the per-build nimcache JSON — `<nimcache>/<output-binary-name>.json` (the JSON is named after the `-o:` binary, NOT after the project name — **spike D1a correction**), the **`compile` array** — filtered to files under the project root (plus configured `dep_roots`). This folds into the compile step at **zero extra cost**.

> **Update (issues #5, #8, #11 — `src/crisol/closure.nim` is the authority):** the closure is no longer derived from the `compile` array (it is Nim's per-invocation C work list and is partial on a warm nimcache — issue #5). It is the union, under the same tracked-root gate, of: (1) module objects from the manifest's **`link`** array, `@m`/`@p`/`@n` decoded against a per-run index of every regular file under each tracked root (issue #8); (2) the manifest's **`depfiles`** array — every file the compiler opened: modules, `include`d files, `staticRead`/`slurp` targets, `nim.cfg`/`config.nims` — which Nim writes only under `-d:nimBetterRun`, a define crisol injects on every compile via the single argv builder `compiledriver.nimCompileArgs` (not part of entrypoint identity); (3) `{.compile.}`d sources, recovered from their `link` object (Nim mangles the full source path into the object name, so this survives warm recompiles where `compile` omits cached externals), and `{.link.}`ed prebuilt objects by raw path. Unattributable objects (the tuple form `{.compile: (pattern, fmt).}`, non-absolute paths) and a manifest lacking `depfiles` make extraction fail closed: the entry is invalidated and the entrypoint recompiles and is force-selected every run. Not covered by design: `gorge`. The spike notes below are retained as history.

> **Update (issue #16):** the C headers a `{.compile.}`d source `#include`s are tracked too. `closure.extractCompileInputs` (the call `recordClosure` makes; `extractClosure` remains the manifest-only closure) derives, for every single-path external the manifest's `compile` array names, a `cc -M` probe from that external's exact compile command, keeps the reported headers that resolve under a tracked root (system headers are excluded by the same gate as every other closure path), folds them into the closure, and records one `ExternalSource` per external (source, object basename, sorted header set, header content hash) in `DepGraphEntry.externals` (graph format 5). An external Nim served from its own object cache — no `compile` entry this round — carries its header set forward from the previous entry; with no record to carry, extraction fails closed like every other unattributable input. Tracking alone is not enough: Nim's external-object cache keys on the source content and the cc command, never on headers, so it would relink a stale object after a header-only edit. The runner therefore evicts, before spawning `nim c`, every external object whose recorded header set no longer hashes to its stored hash (`depgraph.staleExternalObjects`; a missing or unreadable header counts as changed), and — when a warm nimcache has no depgraph entry at all (format discard, GC, an invalidated record) — every non-module object in the cache directory, so the next compile rediscovers headers through `cc -M`. A failed eviction is a pre-compile setup failure, never a silently linked stale object.


**Verified decode algorithm (empirically confirmed on Nim 2.2.10, spike D1a):** the `compile` array holds `[cFilePath, gccCmd]` pairs where element 0 is the generated `.c` path. The JSON lives at `<nimcache>/<output-binary-name>.json`; crisol locates it from the `-o:` path it passed to `nim c`. To recover each `.nim` source:

1. Take the full path from `compile[][0]` (e.g. `/workspace/.crisol/cache/<slug>/@mdeptest_dep.nim.c`).
2. Take the basename: `@mdeptest_dep.nim.c`.
3. Strip trailing `.c`: `@mdeptest_dep.nim`.
4. Strip the leading mangle prefix and decode the body (`@s` → `/`, `@@` → `@`), then resolve to a candidate absolute path **by prefix**:
   - `@m` → strip `@m`. The decoded body is a path **relative to the entrypoint's source file directory** (not `currentDir`). Candidate = `normalize(parentDir(entrypoint) / body)`.
   - `@p` → strip `@p`. The decoded body is a path **relative to whichever search-path root resolved it** (stdlib lib dir, a nimble pkg dir, OR a project `--path` root such as `src`). crisol does **not** know the resolving root from the mangled name, so it resolves the body against each **tracked root** in turn — `projectRoot`, `projectRoot/src`, and each configured `dep_root` (and `dep_root/src`) — and takes the first that names an existing file. If none exists under a tracked root, the body resolved to stdlib/a nimble package → no candidate.
   - Other prefix → no candidate (conservative).
5. Filter: keep a candidate **iff it is an existing file under `projectRoot` or a configured `dep_root`**; discard everything else. The filter is **path-location based, not mangle-prefix based** — a project module imported via `--path:src` (mangled `@p`) is tracked exactly like one imported relatively (mangled `@m`), because both decode to a real file under a tracked root. Over-inclusion (e.g. a project file that happens to shadow a stdlib name) is safe; silent under-inclusion is the false-confidence failure this whole mechanism exists to prevent.

**Why not exclude `@p` wholesale (D1a soundness correction):** `@p` covers *any* file on Nim's search path — which, under the universal Nim src-layout (`src/<pkg>/…` imported as `import <pkg>/…` with `--path:src`), includes the project's OWN library modules. crisol itself (dogfood) and amoxtli (`src/amoxtli/…`) both import this way, so excluding `@p` would drop the project's library source from every closure. That breaks BOTH downstream mechanisms: (1) `narrowByDiff` would find no closure containing a changed `src/…` file → it would not select the tests that exercise it (under-selection); (2) compile-avoidance content-hashing over the closure would not see the change → it would run a **stale binary**. Both are exactly the silent false-confidence failures this RFC exists to eliminate. Tracking must therefore be by decoded-path-under-tracked-roots, per steps 4–5 above. **Residual constraint (documented):** a project source file is tracked only if it is reachable as `<tracked-root>/<decoded-body>` for one of the tracked roots above; a consumer whose `config.nims` adds an idiosyncratic in-project `--path` dir not under `projectRoot`/`projectRoot/src`/`dep_roots` must list that dir in `dep_roots` (or rely on the conservative full-run fallback). Standard src-layout and flat-layout projects need no configuration.

**Key correction from D1a:** the RFC previously stated `@m` paths are "relative to `currentDir`". Empirically they are relative to the **entrypoint's source directory**. For a flat fixture (`tests/fixtures/deptest_main.nim` importing `./deptest_dep`), the `@m` entry is `@mdeptest_dep.nim` (a bare basename, correct relative to `tests/fixtures/`). For a cross-directory import (`tests/main.nim` importing `../src/mylib`), the `@m` entry is `@m..@ssrc@smylib.nim`, which decodes to `../src/mylib` — correct relative to `tests/`, NOT relative to `/workspace`. Resolving from `currentDir` would produce a wrong path in this case. The `currentDir` JSON field records the CWD of the `nim c` invocation; it confirms that crisol invoked `nim` from the project root (and is stored in the dep-graph header for diagnostic purposes), but it is NOT the base for `@m` path resolution.

**`@p` scope (D1a finding):** `@p` covers ALL files found via Nim's search path: stdlib, nimble packages, AND any in-project `--path:` directories. When crisol compiles tests via `--path:<projectRoot>/src`, modules in `src/` (e.g. `src/crisol/discover.nim`) appear as `@pcrisol@sdiscover.nim.c`. These resolve to `<projectRoot>/src/crisol/discover.nim` — an existing file under a tracked root — and so are **tracked** (NOT excluded), per the path-location filter in steps 4–5. Only `@p` bodies that resolve outside every tracked root (true stdlib/nimble paths) are excluded.

Real observed mangled strings from the D1a spike (ground-truth test vectors for `decodeMangledPath`):
- `@mdeptest_dep.nim.c` (entrypoint dir: `tests/fixtures/`) → `tests/fixtures/deptest_dep.nim`
- `@mdeptest_dep2.nim.c` (entrypoint dir: `tests/fixtures/`) → `tests/fixtures/deptest_dep2.nim`
- `@m..@ssrc@smylib.nim.c` (entrypoint dir: `tmp/proj/tests/`) → `tmp/proj/src/mylib.nim`
- `@psystem.nim.c` → resolves to no tracked root → **excluded** (stdlib)
- `@pstd@sprivate@sdigitsutils.nim.c` → no tracked root → **excluded** (stdlib)
- `@pcrisol@sdiscover.nim.c` (compiled via `--path:src`) → resolves to `<projectRoot>/src/crisol/discover.nim` → **tracked** (existing file under `projectRoot/src`)

`currentDir` **confirmed** = `/workspace` (the CWD of the `nim c` invocation from the project root) — stored in the JSON header, used to confirm correct invocation context in the dep-graph header. `nimexe` is empirically **empty** (`""`) on Nim 2.2.10; dep-graph header's nim version comes from `nim --version` stdout (`Nim Compiler Version 2.2.10 [Linux: amd64]`), never from the JSON.

Sketch of the corrected decode (implemented in `src/crisol/depparse.nim`):
```nim
# element 0 of each compile pair → .c path → .nim source
let base    = cFilePath.extractFilename         # e.g. "@mdeptest_dep.nim.c"
if base.startsWith("@p"): return ""             # library/stdlib — exclude
let noExt   = base[0 .. ^3]                    # strip ".c"  → "@mdeptest_dep.nim"
let noPrefix = noExt[2 .. ^1]                  # strip "@m"  → "deptest_dep.nim"
let decoded = noPrefix
  .replace("@@", "\x00").replace("@s", "/").replace("\x00", "@")
# Resolve relative to the ENTRYPOINT'S SOURCE DIRECTORY:
let nimSrc = (entrypointPath.parentDir / decoded).normalizedPath
```

**`when defined` confirmed (D1a):** compiling `deptest_main.nim` (which has `when defined(extraDep): import ./deptest_extra`) WITHOUT `-d:extraDep` produces `@m` entries for `deptest_main`, `deptest_dep`, `deptest_dep2` only. WITH `-d:extraDep` the `compile` array additionally contains `@mdeptest_extra.nim.c`. This confirms that the dependency set DIFFERS by compile flag — (path, flag-hash) keying is necessary and correct; path-only keying would silently use the wrong closure.

`nim genDepend` was evaluated and **rejected**: it calls `quit(1)` even on success (unusable as a library step), and costs approximately 75% of a full compile with no benefit over the nimcache approach.

Slice D1a is a **verification spike** (not merely documentation): its deliverable is an empirically-verified decode algorithm and the `when defined` multi-flag confirmation committed to this RFC and the Implementation Decisions table. **D1a is complete**: decode algorithm verified and recorded, `decodeMangledPath` extracted to `src/crisol/depparse.nim`, regression tests in `tests/unit/test_depdecode.nim` anchored to literal observed mangled strings, fixture chain `deptest_main/dep/dep2/extra` committed to `tests/fixtures/`. The graph header stores the nim version; unsupported versions fail fast with a clear error.

### Graph persistence and invalidation

Stored at `.crisol/depgraph`. Header: nim binary path, `nim --version` output, schema version. Entries keyed by **(entrypoint path, flag-set hash)**.

Writes are **atomic** (write temp file, rename) and serialized through a single writer within a run; cross-process safety comes from the `.crisol/lock` advisory lock.

An entry is invalidated (entrypoint re-scanned) when:

- The entrypoint's own file hash changed.
- Any file in its recorded closure changed — checked as **mtime+size fast path, content hash on mismatch** — **or is missing**. A deleted closure file is an invalidation trigger, never a silent no-op (this was a hole in the draft: deletion left the entry looking valid).
- The nim version in the header changed (whole-graph invalidation).
- The entry is absent (first run, or cache wiped).

Entries whose entrypoint file no longer exists are **garbage-collected** on each run (no phantom conservative-fallback inclusions).

**Closure extraction timing:** extraction runs ONLY after a SUCCESSFUL compile. On a non-signal compile failure (syntax error, type error, etc.), the dep-graph entry is left untouched — if an entry exists from a prior successful compile it is kept; if absent it remains absent. Either way the conservative fallback applies on the next run (stale or absent → include). A partial or corrupt nimcache JSON from a failed compile is never read for graph extraction.

**Hashing:** one stable algorithm everywhere — 64-bit **FNV-1a** (self-contained, ~10 lines, no dependency) for file-content hashes, flag-set hashes, and slug identity. `std/hashes` is documented as unstable across Nim versions and platforms, which disqualifies it for *any* persisted key; rather than reasoning per-site about which persisted hashes survive which invalidation path, crisol uses the stable hash uniformly. Collision resistance is not a security concern here.

### Selection

`crisol run --changed` computes:

1. `changed_files` = `changedFiles(projectRoot, base)` — shells out to `git diff --no-renames --name-only` (staged + unstaged vs HEAD, or vs `--base <ref>`). `--no-renames` ensures a rename surfaces as old-path-deleted + new-path-added, never a consolidated rename entry that would miss the old path. Results are normalized to project-root-relative paths, sharing one coordinate system with `Entrypoint.path` and dep-graph keys.
2. For each entrypoint `ep`: include `ep` if `closure(ep) ∩ changed_files ≠ ∅`. This logic is implemented by `narrowByDiff(eps, changed, graph)`.
3. Conservative fallback: include `ep` if `closure(ep)` is unknown or stale (per the invalidation rules above), or if `ep`'s own file is in `changed_files`.

Group gates apply *after* selection — a gated group's entrypoints are still skipped cleanly even when the diff touches them (D5 therefore depends on C2).

`git` missing, or cwd not a git repository → `changedFiles` raises `cekEnvironment`, exit 3 with a clear message.

### Untracked-file caveat

`git diff` does not list untracked files. A *new entrypoint* is still safe (no graph entry → conservative fallback). A new untracked *source* file is usually safe too: adding its `import` modifies a tracked file, which shows in the diff. The residual gap: an **untracked file already imported by an earlier uncommitted change, then modified again** — its later modifications are invisible to the diff. Documented mitigation: `git add -N <file>` (intent-to-add) makes untracked files diff-visible; or run without `--changed`.

### Staleness note

The persisted graph describes imports as of the last successful scan, not the current working tree. The common case (changing a file already in a closure) is exact; adding a new import changes the importing file's hash, which triggers invalidation and the conservative fallback. The fallback is deliberately biased: **when in doubt, run the test.**

**Residual risk — nimble dependency upgrades:** impact selection tracks the nim version, project-root files, and configured `dep_roots`. A nimble package dependency upgrade (e.g. bumping a library version in `*.nimble`) is invisible to the closure tracker because nimble-package paths are excluded from tracking. A changed package can alter behavior that existing tests cover, but the dep-graph entry sees no source change and will `cdSkipFresh`. Mitigation: run `crisol clean` (or pass `--force-compile`) after any dependency bump. This is a documented limitation, not a bug — tracking the entire nimble-package closure would make the graph enormous and cross-project.

**Scope — `--changed` is single-repo by design.** `changedFiles` runs `git diff` in `projectRoot`, so `--changed` answers exactly *"given a diff in **this** repo, which of **this** repo's tests are affected?"* `dep_roots` exist for closure-correctness and **compile-avoidance** (the content-hash recompiles a binary whenever any closure file — including a `dep_root` file — changes, regardless of git), **not** for multi-repo change detection. When a `dep_root` resolves *outside* `projectRoot`, its files are stored in the closure by absolute path and intentionally never match a project-repo diff entry; a change there is picked up by content-hash compile-avoidance, not by `--changed` selection. Detecting that a *sibling repository* changed (dependency-upgrade testing) is a non-goal: edit the sibling and run crisol *in that repo*. (The realistic co-development layout keeps `dep_roots` as subdirectories under `projectRoot`, where `git diff --relative` sees them and `--changed` selects normally.)

**Known limitation — ambient nim.cfg/config.nims flags:** a `-d:foo` flag in an ambient `nim.cfg` or `config.nims` alters `when defined(foo)` conditional imports and therefore the actual dep closure, but is NOT included in crisol's flag-set hash (crisol only hashes flags it explicitly knows about from group config). If the ambient config file changes, the dep-graph will NOT auto-invalidate. Mitigation: run `crisol clean` (or `--force-compile`) after editing any ambient nim config file. This is intentional scope — parsing and hashing arbitrary nim.cfg/config.nims is complex and deferred.

---

## Result Protocol

### Record shape

NDJSON. The **first line is a header record** carrying the envelope metadata; subsequent lines are test records:

```json
{"crisol": "sink", "v": 1, "ep": "tests/unit/test_foo.nim", "pid": 12345}
{"name": "parses valid input", "status": "pass", "duration_us": 12400, "tags": ["unit"]}
{"name": "rejects empty string", "status": "fail", "duration_us": 3100, "msg": "expected Error got nil"}
{"name": "skips on windows", "status": "skip", "duration_us": 0, "msg": "windows-only API"}
```

- Header: `crisol` (sentinel), `v` (protocol schema version), `ep` (entrypoint path, advisory/debugging only — aggregation is by sink-file association, so a buggy binary can't mislabel its records), `pid`.
- Test records: `name`, `status` (`"pass"|"fail"|"skip"`), `duration_us` (integer microseconds — integer milliseconds reported 0 for every sub-ms test, defeating the slowest-N list), `msg` (optional on **fail and skip** — skip reasons are reportable), `tags` (optional).
- **Versioning policy:** semver. Patch never changes the schema; minor may add optional fields (readers ignore unknown fields); major may break and requires recompiling consumers. The orchestrator reads any protocol MINOR version ≤ its own as backward-compatible, so cached binaries built with an older `crisol/report` remain valid without recompilation. The orchestrator reads `v` first; on an unsupported higher major version it falls back to opaque exit-code mode with a warning. A crisol MAJOR upgrade that breaks the protocol requires `crisol clean` (residual-risk note, analogous to the nimble-upgrade staleness note). This matters because the orchestrator updates independently of `crisol/report` already compiled into consumer binaries. The freshness check's protocol-major-version condition (compile avoidance item 4) ties directly to this: a cached binary built with an incompatible major version is `cdStale`.

### Transport (resolved Q3)

Sink path passed via `CRISOL_SINK` (absolute path). Unique per entrypoint per run: `<tmp>/crisol-<orchestrator-pid>/<slug>.ndjson`. The orchestrator deletes the whole per-run temp dir on exit — including the signal-handler path — so interrupted runs don't leak sink files. If `CRISOL_SINK` is unset, `crisol/report` is a no-op (safe to leave imported).

### Emitter contract

`crisol/report` writes each record as a single line followed by `flushFile` — no application-level buffering — so a crash loses at most the record being written, never earlier records. The sink fd is opened with `O_CLOEXEC`: a test that forks/execs subprocesses cannot leak the fd to children, so an outliving grandchild can't scribble on the sink — enforced by the emitter, not left to consumer discipline (the env-stripping guidance for `CRISOL_SINK` remains as defense in depth).

### Reader contract

- Parse line-by-line. An unparseable **final** line is treated as truncation (binary died mid-write): discard that line only, keep prior records, note the truncation in the report. An unparseable line *followed by further valid lines* is not truncation — it is reported as a sink-corruption warning (multiple writers, the unsupported case), never silently dropped.
- **Outcome precedence rule:** an entrypoint is `oFailed` if (≥ 1 fail record is present) OR (process exit code ≠ 0). `oTimeout` and `oSignal` take precedence over `oFailed` when the process was reaped by timeout or signal — even if partial records were already written before termination; partial records are retained and reported.
- Sink has valid records AND the binary exited non-zero (or died by signal/timeout) → valid records are kept and reported. Partial results beat none.
- No sink file or empty → opaque fallback: pass iff exit code 0; captured output is the failure message on non-zero exit.

---

## Reporting & Exit Codes

**Summary output (default):**

```
crisol: 3 groups, 42 entrypoints
  [OK]      tests/unit/test_parser.nim          (14 tests, 1.2s)
  [OK]      tests/unit/test_scorer.nim          (8 tests, 0.4s)
  [FAIL]    tests/integration/test_store.nim    (3/5 tests failed, 2.1s)
  [COMPILE] tests/integration/test_wire.nim     (compile failed)
  [TIMEOUT] tests/smoke/test_relay.nim          (exceeded 300s)
  [SIGNAL]  tests/unit/test_arena.nim           (SIGSEGV)
  ...
FAILED: 4 entrypoint(s), 3 test(s) — see above
```

Compile failures, timeouts, and signal deaths are first-class outcome labels — never conflated with assertion failures. Skip reasons (from `msg` on skip records) appear in verbose/failure detail. Stage B4 adds per-test counts, slowest-N list, failure messages, and basic color.

**`--json` output:** the full result object (per-entrypoint results, per-test records where available, summary counts, durations). The schema is **specified and fixed at B5** and versioned under the same semver policy as the protocol — CI integrators can build against it. The same object is persisted as `.crisol/lastrun.json` (powering `--failed`) via the single `toJson` path — no second serializer to drift. The object carries top-level `schema_version` and `crisol_version` fields; reading a `lastrun.json` with an unrecognized schema version yields exit 3 with "stale lastrun.json — run `crisol run` first", never a raw parse error. The B5 schema must include the failed-entrypoint list (`Summary.failedEntrypoints` — as (path, group) pairs) so B7's `--failed` is a pure query, not a schema reopening.

**JSON schema versioning policy:** `schema_version` is the contract key CI gates on — not `crisol_version`. A major version increment signals a breaking change (field removal or type change); CI must handle it explicitly. A minor increment adds new optional fields; consumers that ignore unknown fields handle it transparently. `crisol_version` is informational only.

**Note on `render`:** B4's rich output (slowest-N list, per-test failure messages, skip reasons) cannot be produced from `Summary` counts alone. `render` therefore takes the full `seq[EntrypointResult]` and computes the `Summary` internally; `summarize` remains public for callers that need the headline counts only.

Exit codes: see CLI Surface.

### `lastrun.json` / `--json` schema (v1)

**Implemented in slice B5.** The schema key is `"schema": "crisol/run/v1"`.

```json
{
  "schema":      "crisol/run/v1",
  "summary": {
    "total":         <int>,
    "passed":        <int>,
    "failed":        <int>,
    "compileFailed": <int>,
    "timedOut":      <int>,
    "signaled":      <int>,
    "spawnErrors":   <int>,
    "noTestsRan":    <bool>
  },
  "entrypoints": [
    {
      "path":       "<string>",
      "group":      "<string>",
      "outcome":    "<string>",
      "exitCode":   <int>,
      "signal":     <int | null>,
      "durationMs": <float>,
      "records": [
        {
          "name":       "<string>",
          "status":     "<string>",
          "durationUs": <int>,
          "msg":        "<string | null>",
          "tags":       ["<string>", ...]
        }
      ]
    }
  ]
}
```

**Fixed `outcome` string values** (Nim `Outcome` enum → JSON string):

| Nim enum value  | JSON string       |
|-----------------|-------------------|
| `oPassed`       | `"passed"`        |
| `oFailed`       | `"exitNonZero"`   |
| `oCompileFailed`| `"compileFailed"` |
| `oTimeout`      | `"timedOut"`      |
| `oSignal`       | `"signaled"`      |
| `oSpawnError`   | `"spawnError"`    |

**Fixed `status` string values** (Nim `RecordStatus` enum → JSON string):

| Nim enum value | JSON string |
|----------------|-------------|
| `rsPass`       | `"pass"`    |
| `rsFail`       | `"fail"`    |
| `rsSkip`       | `"skip"`    |

**Notes:**
- `signal` is an integer when `outcome == "signaled"`, `null` otherwise.
- `records` is an empty array when the test binary did not use the structured result protocol (opaque binary).
- `msg` on a record is a string when present, `null` when absent.
- The file is written atomically (temp file + rename) to `<projectRoot>/<stateDir>/lastrun.json` after every run, regardless of `--json`.
- A consumer reading a file with an unrecognized `schema` value should exit 3 with a clear message rather than silently misinterpreting the data.


---

## Stages & Slices

Each slice is independently testable. Spike slices (B3a, D1a, A2a) are timeboxed investigations; their deliverable is a recorded decision in this RFC plus, where noted, a committed test or code artifact.

### Stage A — Orchestrator core

- **A1** Discovery as its own pure module (`crisol/discover`): glob patterns (incl. `**` via the internal matcher) over a fixture tree → `DiscoveredSet`. `discover(config, selection)` derives the project root from `config.projectRoot` — no separate `root` param. `discover` takes NO `gateCheck` param — gate evaluation is not discovery's concern. Gate state is captured by `loadGateState` and applied by the pure `applyGates` filter; tests use `initGateState` (or `toDiscoveredSet` to bypass discover) — never the real environment.
- **A2a** *(Spike + regression test, gates A4)* Spike that forks a child into its own process group via raw `std/posix` (`fork` + child-side `setpgid(0,0)` + `execvp`) and proves `killpg` reaps the entire group including a grandchild the child spawns. **Deliverable:** a committed regression test in `tests/integration/` (green test proving grandchild reap) plus the confirmed mechanism recorded in the Implementation Decisions table. The mechanism is already empirically verified to work; the test anchors it against future regressions.
- **A2b** Compile + run ONE entrypoint supervised, built on the A2a-verified mechanism: output redirected to a temp file at spawn time via `dup2` (with the `max_output_bytes` cap — file-backed during the run, materialized into `EntrypointResult.output` bounded by the cap; `render` reads failing entrypoints' output from file), stdin from `/dev/null`, compile + run timeouts enforced (deadline poll via `waitpid(WNOHANG)`), exit/signal/timeout classified, raw-fork failure classified as a per-entrypoint outcome. A2b may use ad-hoc placeholder types. A2b also creates `tests/fixtures/build.nim` plus the minimal fixtures it needs (`pass_always.nim`, `fail_compile.nim`, `hang_forever.nim`).
- **A3** Run many sequentially; aggregate continue-on-failure; introduce the core types (`Config`, `RunPlan`, `EntrypointResult`) and the `plan`/`execute` split — **explicitly refactoring A2b's placeholder types into the canonical hierarchy** (expected churn, named here so it doesn't surprise); summary; non-zero exit on any failure.
- **A4** Bounded-parallel poll-loop scheduler (`--jobs N`); atomic post-completion output printing; per-slot timeout supervision; per-slot fork-failure containment (a failed spawn marks that entrypoint's outcome, never kills the pool). *Blocked on A2a.*
- **A5** CLI `crisol run [paths]` wired to A1–A4 with `--fail-fast`, `--jobs`, `--timeout`. Config arrives via a `loadConfig()` stub returning convention defaults — C1 later replaces the stub's internals without touching the CLI (explicit: A5 carries hardcoded defaults until C1).
- **A6** Signal handling: SIGINT/SIGTERM → handler sets an atomic flag only (Nim runtime is not async-signal-safe); poll loop performs kill of all child process groups (TERM, drain, KILL), temp-state cleanup, exit `128+N`.

### Stage B — Result protocol + reporting

- **B1** Protocol codec: header + test records; host-side sink reader implementing the full reader contract (truncated-final-line, records+non-zero-exit, opaque fallback).
- **B2** In-process `crisol/report` emitter: open from `CRISOL_SINK`, write header, flush-per-record, no-op when unset.
- **B3a** *Spike:* verify std/unittest's `OutputFormatter`/`addOutputFormatter` API on the target Nim version — exact proc/type names, what `testEnded` exposes, import-time registration ordering. **Recorded finding:** `TestResult` carries no usable duration field; the shim must time each test with a monotonic clock — `getMonoTime()` (or `epochTime()`) around the `testStarted`/`testEnded` hook pair — to populate `duration_us`. Deliverable: confirmed API surface + timing approach recorded in this RFC.

  **B3a confirmed API surface — Nim 2.2.10 (`/opt/nim/2.2.10-patched/lib/pure/unittest.nim`), probe-verified:**

  - `OutputFormatter* = ref object of RootObj` — base type; no fields. Subclass with `ref object of OutputFormatter`.
  - Methods on the base (all `{.base, gcsafe.}`, all dispatch on `formatter: OutputFormatter`):
    - `method suiteStarted*(formatter: OutputFormatter, suiteName: string)`
    - `method testStarted*(formatter: OutputFormatter, testName: string)`
    - `method failureOccurred*(formatter: OutputFormatter, checkpoints: seq[string], stackTrace: string)` — `checkpoints` is never nil; `stackTrace` is non-empty only when failure came from an unhandled exception.
    - `method testEnded*(formatter: OutputFormatter, testResult: TestResult)`
    - `method suiteEnded*(formatter: OutputFormatter)`
  - `proc addOutputFormatter*(formatter: OutputFormatter)` — appends to `formatters: seq[OutputFormatter] {.threadvar.}`.
  - `proc delOutputFormatter*(formatter: OutputFormatter)` — removes by identity.
  - `proc resetOutputFormatters*()` — sets `formatters = @[]`; available since Nim 1.1.
  - `TestResult* = object` fields: `suiteName*: string`, `testName*: string`, `status*: TestStatus`. **No duration or timing field — confirmed on 2.2.10.** `TestStatus` enum: `OK`, `FAILED`, `SKIPPED`.
  - `testStarted` receives only `testName: string`. `testEnded` receives a `TestResult` with `suiteName`, `testName`, `status` — nothing else.
  - **Timing approach (confirmed):** capture `getMonoTime()` (import `std/monotimes`) in `testStarted`; subtract in `testEnded` to get a `Duration` (import `std/times`); call `elapsed.inNanoseconds` for nanosecond precision. `MonoTime` subtraction (`-`) returns `Duration`; `Duration.inNanoseconds` returns `int64`. Store `startTime: MonoTime` on the formatter subtype.
  - **Registration ordering:** `formatters` is a threadvar seq. `ensureInitialized()` is called lazily at the start of every `suite`/`test` template; it auto-registers `defaultConsoleFormatter()` if `formatters.len == 0`. **The shim must call `resetOutputFormatters()` then `addOutputFormatter(crisolFmt)` before any `suite` or `test` runs** — i.e., at module init time (top-level in the shim). This suppresses the default console formatter entirely under crisol. If the user also wants console output, they can add `addOutputFormatter(defaultConsoleFormatter())` after the crisol formatter.
  - Probe compiled and all five hooks fired correctly under `--mm:orc`, Nim 2.2.10.
- **B3** std/unittest shim per the spike: one-line drop-in (`import crisol/unittest_shim` re-exports unittest, registers the formatter).
- **B4** Rich reporting: per-test counts, slowest-N, failure messages, skip reasons, basic color. Color output is emitted only when stdout is a TTY (`isatty(stdout)`) AND the `NO_COLOR` environment variable is unset. Includes the poll-loop "still running" progress line (~every 30s to stderr, suppressed under `--json`) listing in-flight entrypoints — critical for amoxtli's 165-entrypoint runs where a hung entrypoint would otherwise produce silence for up to the timeout.
- **B5** `--json` output + `.crisol/lastrun.json`; schema documented and fixed.
- **B6** `crisol list` + `--dry-run` (plan phase, formatted; `--json` supported).
- **B7** `--failed` (selection from `lastrun.json`; exit 3 when absent).

### Stage C — Groups & config

- **C0** *Spike (timeboxed ~30 min):* read proptest's and fresco's test trees; confirm the group/flags/gate schema covers both or record the gaps (≤3 bullets in this RFC). This was previously an unowned "precondition" — now it's a slice that gates C1. **Acceptance criteria:** C0 passes iff both of the following express cleanly in the schema (or the ≤3 gaps are recorded): (a) proptest running with a per-invocation `-d:propertySeed=…` flag (flag variation per group invocation); (b) fresco gating an integration group on a live-resource env var like `FRESCO_DB_URL` (env gate pattern).
  - **C0 FINDING (PASS — recorded 2026-06-13).** Neither sibling repo is checked out alongside crisol yet (`libs/` contains only `crisol`), so this is a schema-coverage analysis against the two named patterns rather than a direct tree read; re-verify on first proptest/fresco adoption. Result: the current `Group{globs, flags, optIn, gate: Option[Gate], timeoutSecs}` + `Gate{env}` + cross-group entrypoint overlap schema covers **both** patterns:
    - **(b) fresco env gate — covered cleanly.** `Group(gate: some Gate(env: "FRESCO_DB_URL"))`; `loadGateState`/`applyGates` skip the group (with reason in `gatedOut`) unless the var is set and non-empty. Exactly the live-resource pattern. No gap.
    - **(a) proptest per-group seed flag — covered for the static/enumerated case.** `Group.flags` injects `-d:propertySeed=<n>` for every entrypoint in the group; the **same** entrypoint may appear in several groups each with a different seed flag (cross-group overlap → distinct `Entrypoint.flags`, distinct slug/nimcache — verified in A1), so "flag variation per group invocation" expresses directly as N groups (e.g. `prop-seed-1`, `prop-seed-2`). **One recorded caveat (the single gap):** a *fresh random seed regenerated per `crisol run`* is NOT expressible via static config flags (config is static; crisol injects no dynamic/templated flag values in v1). Recommendation: proptest seeds re-randomization from its **own** runtime env inside the test binary (crisol stays seed-agnostic), or a v1.1 flag-template feature (`-d:propertySeed=${seed}`) if host-side seed control is later required. This does not block C1.
- **C1** Config load (format per Open Q1): groups with `opt_in`, typed `gate`, per-group `timeout_secs`; flag merge; validation with structured errors (incl. identical-flag glob overlap); config-file walk-up discovery + `--config`; replaces the A5 stub. *Gated on C0.*
- **C2** `--group` / `--all-groups` selection; convention-based group inference when no config; gate evaluation (clean skip with message).
- **C3** `--filter-tag`: reporting-level record filter + explicit zero-match warning.
- **C4** `crisol clean` (orphan pruning, `--all`) + the `.crisol/lock` advisory lock.

### Stage D — Impact analysis

- **D1a** *(Verification spike — COMPLETE, 2026-06-13)* Empirically verify and record: (1) the exact nimcache JSON `compile`-array key path and the `@m`/`@p`/`@s` path-mangling decode algorithm (see Dependency Source for the verified algorithm); (2) that `currentDir` in the JSON reflects the CWD of the `nim c` invocation, confirming the project-root invocation constraint; (3) that an entrypoint with `when defined(X): import dep` produces DIFFERENT `compile` arrays with vs without `-d:X` (confirming per-(path, flag-hash) keying is necessary); (4) the minimum supported Nim version. **Findings recorded** in §Dependency Source (corrected JSON name formula, corrected `@m` resolution base, `@p` scope, `currentDir` confirmed, `nimexe` empty, `when defined` flag-diff confirmed). `decodeMangledPath` extracted to `src/crisol/depparse.nim`; regression tests in `tests/unit/test_depdecode.nim`. Fixture chain committed: `tests/fixtures/deptest_main.nim`, `deptest_dep.nim`, `deptest_dep2.nim`, `deptest_extra.nim`. `nim genDepend` rejected (see Dependency Source). Minimum verified Nim: 2.2.10 (`Nim Compiler Version 2.2.10 [Linux: amd64]`).
- **D1** Closure extraction for one entrypoint via the chosen mechanism; filtered to project root (+ `dep_roots`).
- **D2** Persist `.crisol/depgraph`: atomic writes, (path, flag-hash) keys, nim-version header, invalidation rules incl. missing-file trigger, deleted-entrypoint GC.
- **D3** `narrowByDiff` — diff ∩ closure selection (pure; synthetic graph + changed-set in tests). An entrypoint is selected if its closure intersects the changed set; conservative fallback for any uncertainty. *D3 and D4 are a pair — D3 covers known closures; D4 covers every uncertainty case.*
- **D4** Conservative fallback — **any** of the following triggers a full-run inclusion regardless of the diff: absent or partial dep graph, unknown closure (no entry for the entrypoint), stale entry (invalidation rules triggered), or the entrypoint's own file in the changed set. When the graph is absent entirely, ALL entrypoints are selected and the summary states it explicitly (`dep graph absent — full run`). The bias is deliberate: absent or partial information always means run it. Over-selection is safe; under-selection is not.
- **D5** CLI `--changed [--base <ref>]`: call `changedFiles(projectRoot, base)` (shells out to `git diff --no-renames --name-only`), feed to `narrowByDiff` (D3+D4 logic), gates still applied after narrowing. *Depends on C1+C2 and all prior D slices.* Non-repo/missing git → `cekEnvironment` exit 3.
- **D6** Compile avoidance: `plan()` annotates `CompileDecision` (`cdNeverBuilt`, `cdStale`, `cdSkipFresh`) from the D2 graph + binary stat (all freshness conditions — see Compile Avoidance; mtime is fast-path only, content hashing is the correctness gate); `execute` honors `decision != cdSkipFresh` as "compile"; `--force-compile`; `list`/`--dry-run` display each decision variant distinctly. Unit-tested purely with a synthetic graph, real content hashes (no fake mtime gates), and a version stamp — no subprocess needed.

### Stage F — amoxtli adoption (acceptance criteria — not TDD slices; work lands in the amoxtli repo)

**Execution context:** crisol's toolchain operations (compilation, test runs) execute **inside the podman/docker dev image**; built binaries may be executed on the host for smoke purposes only. This pins nim-version-key stability: the nim version recorded in the dep-graph header corresponds to the in-container toolchain, not any host nim installation.

- **F1** crisol config for amoxtli: all groups (unit, integration, smoke), ALL entrypoints including the 9 missing ones, `-d:amoxtliTesting`, nimcache under the docker-bound `/dockerhome` path, smoke gated on `AMOXTLI_OPENROUTER_API_KEY`.
- **F2** Wire `./dev test` → `crisol run`; verify result parity (same pass/fail counts); measure parallel speedup.
- **F3** CI nimcache caching across runs. Cache keys MUST include the nim version and the flag-set hash (already encoded in the cache-dir slug) **plus OS and architecture** — the slug encodes nim version and flags but NOT the host ABI; a cache hit from a different OS/arch produces mis-linked binaries. Cache `.crisol/cache/` everywhere (key: nim-version + flag-hash + OS + arch); cache `.crisol/bin/` **only on a homogeneous runner fleet** (same OS/libc/arch). On heterogeneous fleets, cached object files still amortize most of the cost; only linking repeats.

- **F4** *(Dogfood acceptance criterion)* crisol's own test suite runs under crisol — `crisol run` over `tests/unit/` and `tests/integration/` produces a green result. This is in addition to, never replacing, the permanent serial `nimble test` bootstrap task.

(The former Stage E — watch mode and extended DX — is deferred to v1.1 per resolved Q4; see Future Work.)

---

## Implementation Decisions (recorded so TDD sessions don't stall)

| Decision | Choice |
|---|---|
| Process spawning / pool | raw `std/posix` fork+exec + `waitpid(WNOHANG)` poll loop (verified in A2a) |
| Process-group placement | raw `std/posix` fork + child-side `setpgid(0,0)` + `dup2` + `execvp`; group kill via `killpg`. osproc rejected: no Linux `posix_spawn` path (`useProcessAuxSpawn` excludes Linux); parent `setpgid` races exec (EACCES, verified on Nim 2.2/Linux). Grandchild reap via `killpg` empirically confirmed (A2a regression test). **Verification note (A2a):** after `killpg`+`waitpid(child)` the grandchild is reparented to init and briefly lingers as a *zombie*, so a `kill(gpid,0)→ESRCH` probe is insufficient in-container (returns 0 for zombies); the regression test instead asserts `/proc/<gpid>/stat` state is `Z`-or-absent plus the never-written `SURVIVED` marker. |
| Fork/exec async-signal-safety | Child path between `fork()` and `execvp()` uses ONLY libc-level async-signal-safe primitives (`setpgid`, `dup2`, `execvp`); no Nim heap allocation, no GC, no exceptions, no string construction; implemented as `{.raises: [].}` sequence. Sound because executor is single-threaded (no Nim threads/threadpool before spawn loop). Both halves are invariants. |
| Dep-closure source | nimcache JSON `compile` array (`<nimcache>/<output-binary-name>.json`); `@m` entries = project modules (resolved relative to entrypoint source dir, not `currentDir`); `@p` entries = excluded (stdlib + any `--path:` dir); decoder in `src/crisol/depparse.nim`. `nim genDepend` rejected. |
| Dep-graph keying | (entrypoint path, flag-set hash) — empirically required: `when defined(X): import dep` produces different `compile` arrays with/without `-d:X` (D1a confirmed) |
| Nim version source | `nim --version` stdout (e.g. `Nim Compiler Version 2.2.10 [Linux: amd64]`); `nimexe` JSON field is empty on 2.2.10 and unreliable — never used |
| Glob matching | internal pure matcher over `walkDirRec` (`*`, `?`, `**`); directory symlinks not followed |
| JSON | `std/json` for v1; revisit only if profiling demands |
| Hashing (all persisted keys + content) | stable 64-bit FNV-1a (internal, ~10 lines); mtime+size fast path only (never a correctness gate); content hash is the correctness gate; `std/hashes` never persisted |
| Git interaction | shell out to `git diff --no-renames --name-only`; results normalized to project-root-relative; failure → `cekEnvironment` exit 3 |
| Sink path scheme | `<tmp>/crisol-<pid>/<slug>.ndjson`, per-run dir deleted on all exit paths; fd opened `O_CLOEXEC` |
| Nimcache / binary dir scheme | `.crisol/cache/<slug>/` and `.crisol/bin/<slug>/`, slug = `<path-with-__>-<fnv1a16(path, flags)>` (full 64-bit FNV-1a, 16 hex chars) |
| Child stdin | always `/dev/null` |
| Compiler noise | `--hints:off` injected first (overridable by group flags); warnings on |

---

## Testing Strategy

Testing a test runner requires fixtures with known outcomes. Two tiers, plus a bootstrap rule.

### Bootstrap rule (no dogfood circularity)

crisol's nimble file keeps a permanent `test` task that runs the unit suite serially via plain `nim c -r` — forever, not just until dogfooding starts. The dogfood run (crisol running its own suite) is an *additional* invocation and the full-stack integration test; it never replaces the fallback. A regressed orchestrator must not be the only thing able to report its own regression.

### Fixture mini-projects

`tests/fixtures/` contains throwaway Nim entrypoints with predetermined outcomes:

- `pass_always.nim` — one always-passing test.
- `fail_one.nim` — two tests, one passes, one fails.
- `skip_one.nim` — one skipped test (with a skip reason, exercising skip-`msg`).
- `fail_compile.nim` — deliberately does not compile.
- `slow_test.nim` — `sleep(800)` to exercise timing and the slowest-N list.
- `hang_forever.nim` — never exits; exercises the run timeout and process-group kill.
- `crash_signal.nim` — raises SIGSEGV mid-run; exercises signal classification and the truncated-sink reader path.
- `nondeterministic_test.nim` — reads `CRISOL_FIXTURE_FLAKY`; fails/passes by parity. Lives in a subdirectory NOT covered by the default fixture glob (or in an `opt_in` group) so the parallel==serial invariant test can explicitly exclude it or pin its env var. Renamed from `flaky_test.nim` to make the isolation intent obvious.
- `no_protocol.nim` — exits 0 or 1 per `CRISOL_FIXTURE_EXIT`; exercises the opaque fallback.

**Fixture compile cost & the ORC constraint, clarified:** the per-entrypoint nimcache mandate is about *different entrypoints sharing one cache*. The *same* fixture recompiled across test runs may safely reuse *its own* nimcache. Fixtures are therefore pre-compiled once per session into `tests/fixtures/bin/` (gitignored), keyed by source hash. The setup task is a concrete artifact: **`tests/fixtures/build.nim`** (created in slice A2b), a standalone script run as `nim r tests/fixtures/build.nim`, which discovers `tests/fixtures/*.nim` via `walkDir` (no manual manifest — crisol practices what it preaches), compiles each into `bin/` with its own nimcache, and skips sources whose hash is unchanged. The A2b slice also creates the minimal fixtures needed for A2b itself: `pass_always.nim`, `fail_compile.nim`, and `hang_forever.nim`. Verifiable property: running `build.nim` twice is idempotent (second run compiles nothing). The nimble file wires it as the pre-integration step. (`fail_compile.nim` is exempted from the build script — it exists to fail under the orchestrator, not the bootstrap.) The parallel==serial invariant test explicitly excludes `nondeterministic_test.nim` (or pins its env var) to remain valid.

### Tier 1 — Pure unit tests (`tests/unit/`)

- Discovery: glob patterns (incl. `**`) over the fixture tree → exact expected list; gate predicate stubbed.
- Closure math: synthetic dep graph → set-intersection selection, including all conservative-fallback cases (absent entry, stale entry, missing closure file, own-file-changed).
- Protocol codec: round-trip records (header + all statuses + msg-on-skip) through the NDJSON codec; truncated-final-line handling.
- Plan logic: group selection, opt-in/gate polarity, flag merge precedence.
- Config parsing: valid → typed config; invalid → structured errors.

### Tier 2 — Integration tests (`tests/integration/`)

- Orchestrator over fixtures: aggregate result (N passed, M failed, K compile-failed, timeouts, signal deaths); continue-on-failure ran everything; non-zero exit.
- Parallel vs serial: `--jobs 1` vs `--jobs 4` produce identical aggregate results **for the deterministic fixture subset** (flaky fixture excluded or env-pinned — order-dependent fixtures make the unqualified invariant false by construction). Each entrypoint receives a unique `CRISOL_TMPDIR`; fixtures must not share mutable global state.
- Timeout & signals: `hang_forever` → timeout outcome within bound, no orphaned processes after the run (assert via process-group probe); `crash_signal` → signal outcome + truncated-sink records preserved.
- Interrupt: send SIGINT to a running orchestrator mid-parallel-run; assert children are reaped and temp state cleaned.
- Impact analysis: `git init` + commit a fixture tree in a temp dir (D-stage tests must create the repo explicitly); synthetic diff → exactly the affected entrypoints. Non-repo dir → exit 3.
- Protocol round-trip: `fail_one` under the orchestrator → correct per-test records.
- Fallback: `no_protocol` both exit codes → correct aggregate without records.

### Dogfooding

Once Stage A is complete, crisol's own suites also run under crisol. The dogfood run is the integration test for the full stack — in addition to, never instead of, the serial bootstrap task.

---

## Open Questions / Forks

### Q1 — Config format (OPEN — decision needed by Stage C start)

a. **KDL v2** (house style; `lib/kdl` exists in amoxtli and is extractable): rigorous, familiar in-ecosystem; adds a parser dep; unfamiliar outside.
b. **TOML**: broad familiarity; `parsetoml` exists; declarative; well-specified.
c. ~~NimScript~~ — rejected (executable config, compiler-version coupling, not statically analysable).
d. ~~Convention-only in v1~~ — rejected (groups are required by Stage C for amoxtli's tier separation).

**Decision rule:** KDL if `lib/kdl` is extracted as a standalone milpa dep by the time Stage C begins; otherwise TOML. The fork is the extraction timeline — owner's call.

### Q2 — Impact-analysis dependency source (RESOLVED)

Compiler-derived output — never a hand-rolled import parser (a missed conditional import silently skips a test that should run; false confidence is the worst failure mode a selective runner can have). **Decided mechanism:** nimcache JSON `compile` array (see Dependency Source above). `nim genDepend` rejected (calls `quit(1)` on success; ~75% compile cost). D1a is a verification spike that records the empirically-confirmed decode algorithm (not a documentation task — the algorithm details require hands-on verification).

### Q3 — Result-protocol transport (RESOLVED)

Env-passed sink file (`CRISOL_SINK`). Keeps the binary's stdout untouched for humans, no in-flight parsing ambiguity, trivial implementation; temp-file I/O is negligible at test-runner scale. Stdout TAP-like protocol and fd-passing rejected (stdout conflation; fd fragility). **TAP as a payload format** was also considered and rejected: the sink has exactly one consumer (the orchestrator), so TAP's ecosystem interop buys nothing here, and NDJSON carries richer typed fields; a `--tap` *output* format remains possible later without touching the sink protocol.

### Q4 — Watch mode scope (RESOLVED)

Deferred to v1.1. Core value (parallel continue-on-failure + impact selection) doesn't depend on it; amoxtli's immediate need is `./dev test` replacement. Removing it shrinks the v1 review and implementation surface.

---

## Future Work (v1.1+)

Explicitly out of v1, acknowledged so consumers can plan:

- **Watch mode** (`crisol watch`): FS-watcher + debounce + impact-selected re-runs (resolved Q4).
- **JUnit XML output** (`--junit <path>`) and GitHub Actions annotations — CI-native formats beyond `--json`.
- **Sharding** (`--shard <i>/<n>`): deterministic partition of the sorted entrypoint list for multi-machine CI.
- **Compile-only mode** (`--check`): `nim check` sweep without running.
- **`--tap` output format** (sink protocol unaffected).
- **Compound/extended gates** (`file`, `cmd`, `all`/`any`) — the typed gate object is forward-compatible.
- **Per-group env allowlists** (environment isolation beyond CRISOL_* stripping).
- **Auto-injected unittest shim** (zero-import structured output) — rejected for v1 as too magical.
- **Sibling-consumer migrations** (lib/cel, lib/kdl, proptest, fresco) — after amoxtli proves the model; their patterns inform C1 *now* (see Stage C precondition).

---

## Distribution

crisol is consumed via the author's `milpa` dep resolver using a local path pin, consistent with `proptest`, `fresco`, and `lib/kdl`. It is not published to a public Nim package registry initially. v1 distribution scope: local path pin in milpa. Public registry publication is a v2 consideration once the API stabilises.

**API stability:** `crisol/report` and the `crisol/unittest_shim` are public API versioned with crisol under its semver scheme. Minor bumps are source-compatible (no consumer recompile needed); major bumps are not source-compatible and require consumer updates. The orchestrator's Library API (`crisol` module) follows the same policy.

**Migration:** a project can run `crisol` alongside its existing serial `nimble test` during transition — crisol uses its own `.crisol/` nimcaches and state, producing no collision with manual `nim c -r` or `nimble test` runs. Adoption can be group-by-group (add one crisol group, leave the rest in nimble for now). Pre-existing `nimcache/` artifacts from manual builds do not conflict with crisol's per-slug nimcaches.

---

## Out of Scope

- **uuid7 monotonicity flake (amoxtli B4):** `src/daemon/memory/ids.nim` in amoxtli lacks a within-millisecond counter, causing a nondeterministic ordering flake in some session tests. This is amoxtli domain code. It is fixed separately in amoxtli and is not a crisol concern.
- **Assertion/expectation DSL:** std/unittest and proptest handle this.
- **Benchmark / performance regression harness:** separate concern.
- **Public registry publication:** v2.
- **Windows support:** not a target for v1. v1 targets POSIX: Linux including WSL2 is the primary target; macOS should work via the same `fork`/`setpgid`/`fcntl` primitives but is not a tested v1 CI target. Windows is out of scope.
