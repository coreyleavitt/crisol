# RFC-0007 — Execution substrate: process contract, honest results, platform backends

**Status:** Draft (stage 1 — sliced; awaiting `/architect` round 1)
**Depends on:** RFC-0001 (runner), RFC-0002 (scheduling/admission), RFC-0004 (hermetic execution, `SandboxAchieved`, cache gate)
**Precedes:** RFC-0005 *build* (the `StoredEntry` wire freezes on this RFC's result model — see §Contract impacts)
**Followed by:** RFC-0008 (observed inputs — the input observer), RFC-0009 (path identity — `ProjectPath`; prerequisite for Windows green)
**Closes / absorbs:** #18 (landed ahead as a portability fix), #15 (Windows backend = Stage D), #1 (`SlotState`, Stage A2), #17 (compile spawn cwd = `projectRoot`, Stage A2)
**Scope owner:** Corey

## Summary

crisol's executor is correct on Linux and accidental everywhere else: `std/posix` is imported by eleven modules, `runner.nim` runs its own `waitpid`/`killpg` loops, and the result model conflates *what the OS reported* (`exitCode`/`signal`), *who caused it* (`timedOut`), and *what we conclude* (`outcome`) into one stored record. That is why macOS broke on two glibc-isms (#18), why Windows reads as a rewrite (#15), and why a timeout and an OOM-kill are indistinguishable in `run/v1`.

This RFC replaces the accretion with a designed substrate:

1. **One process contract** (`process.nim`) with compile-time-selected backends (`process/posix`, `/linux`, `/darwin`, `/windows`). The executor never sees a `Pid`, a `HANDLE`, `killpg`, or `waitpid`.
2. **An honest result model**: `Exit` (lossless observation) × `Cause` (authorship, asserted only when the runner *knows*) × `Evidence` (what the runner can vouch for), with `Outcome` a **pure function** of the three — serialized, never stored as independent truth.
3. **Guarantees as identity, mechanisms as capabilities.** Kill-domain strength, limits, isolation, and supervision fidelity are probed at startup, degraded when absent, and *reported* in `Evidence` — the RFC-0004 `Achieved` posture promoted to the whole layer. The cache gate reads `Evidence`.
4. **Backends** for Linux upgrades (subreaper, pidfd/event-driven wait, cgroup v2), Darwin, and Windows, all measured by one backend-agnostic conformance suite.

Everything stays at entrypoint-binary granularity and observation-only: crisol enforces nothing it did not enforce before (less, in fact — see §Non-goals, network).

## Motivation

- **#18** — `pipe2`/`execvpe` are glibc, not POSIX. Landed ahead of this RFC as a pure portability fix; the structural lesson (one code path, POSIX not glibc) is §Design 1.
- **#15** — tonalli's Windows legs cannot convert until crisol runs there. Without a seam the port is a rewrite of `runner.nim`; with one it is `process/windows.nim` plus three small `when` branches.
- **Termination honesty** — `oTimeout` is the only runner-authored kill the model can express; `oSignal`+`SIGKILL` cannot say whether the runner, the OOM killer, or the test itself sent it; `oSignal`/`"signaled"` cannot describe a Windows `STATUS_ACCESS_VIOLATION`. Whether a test honored the grace window (died on SIGTERM vs needed SIGKILL) is not recorded anywhere, though it is the first question when protocol records go missing on a timeout.
- **RFC-0005 is about to freeze and sign the wire.** Its `StoredEntry` payload is "byte-identical to today's" result-cache record and its `storageFormatVersion` is statically tied to `resultCacheFormatVersion`. Changing the result model *after* 0005 ships invalidates every distributed, attested entry fleet-wide; changing it *before* costs a local schema bump you were going to pay anyway.
- **Encapsulation debt on Linux today**, independent of any port: raw `open/write/close/rename` hand-rolled in five modules; supervision split between `spawn.nim` and `runner.nim`; `pepIdx == -1` as the slot idle sentinel (#1).

## Identity check

crisol is "one layer up" from the test (MEMORY → boundary-granularity-discriminator) and its value is sound *selection* and trustworthy results (MEMORY → crisol-value-is-selection). The substrate's **guarantees** — kill-domain completeness, termination honesty, requested-vs-achieved reporting — are soundness properties of the result that the selection and cache layers consume; they are identity. The **mechanisms** (cgroups, namespaces, pidfd, Job Objects) are capabilities: probed, reported, never required. Nothing here controls what happens *inside* a test binary.

## Load-bearing property

> **A runner-authored kill is reported as such, end-to-end.** Running a hanging entrypoint through the real entry point (`crisol run --json`) yields `outcome: "killed"`, `cause: {by: "runner", reason: "timeout", escalated: true|false}`, and an `exit` that records what the OS actually reported — and `outcome` is *derived* from `exit × cause × evidence × records` by one pure function, never read from storage.

Slice A1 produces this with today's spawn path (the runner already knows when it killed); every later slice refines the substrate underneath without changing the property. If this property cannot be shown live from slice 1, the RFC is scaffolding around a hole.

## Design

### 1. The process contract

```nim
## process.nim — the ONLY process-lifecycle surface the executor imports.
## Backend selected at compile time:
##   when defined(windows): include process/windows
##   elif defined(linux):   include process/linux      # posix + Linux capabilities
##   elif defined(macosx):  include process/darwin     # posix + kqueue/libproc
##   else:                  include process/posix

type
  StdioSink = object            # by PATH, never by fd: the backend opens it however it must
    stdoutPath, stderrPath: string   # same path ⇒ shared sink (today's dup2-to-one-file)
  Limits = object               # platform-neutral names; per-limit Achieved reported
    addressSpace, cpuSeconds, fileSize, openFiles, processCount: Option[int64]
  KillDomainRequest = enum kdStrongest  # always ask for the strongest the platform has
  ChildSpec = object
    argv: seq[string]
    cwd: string                 # ALWAYS projectRoot for compile AND run children (#17): relative
                                # paths in config `flags` (e.g. `--path:src`) resolve against the
                                # project root, never the invoker's cwd; globs/dep-roots already do
    env: seq[(string, string)]  # EXPLICIT. hlNone builds the parent env explicitly — one code path
    sinks: StdioSink
    limits: Limits
    isolation: SandboxSpec      # RFC-0004 spec (tmpdir, env scrub, chdir, rlimits)
    cooperativeGraceMs: int     # SIGTERM→SIGKILL / CTRL_BREAK→Terminate window

  ChildHandle = object          # opaque; fields are backend-private
  Capabilities = object         # probed ONCE at startup (see §4); rendered in run/v2 `substrate`

proc capabilities*(): Capabilities
proc spawn*(spec: ChildSpec): tuple[handle: ChildHandle; achieved: Achieved; error: string]
proc wait*(handles: openArray[ChildHandle]; deadline: MonoTime): WaitEvent
  ## Event-driven where the platform has it (pidfd+poll | kqueue EVFILT_PROC |
  ## WaitForMultipleObjects); 25 ms poll otherwise. Single-threaded either way.
proc terminate*(h: var ChildHandle; graceMs: int): TerminateReport
  ## cooperative stop → grace → forced kill; records `escalated` and a pre-kill snapshot.
proc reap*(h: var ChildHandle): ProcessResult
proc snapshotTree*(h: ChildHandle): seq[ProcSnapshot]   # /proc | libproc | JobObjectBasicProcessIdList
```

Invariants carried forward from RFC-0001 and restated as the contract's:
- The POSIX child window (between fork/clone and exec) executes only async-signal-safe primitives; the executor is single-threaded before and during the spawn loop.
- `spawn` never inherits the parent environment implicitly; `hlNone` means "the parent's env, explicitly copied", not "whatever `environ` is".
- Output sinks are opened **before** the child exists and handed to it at spawn (no pipe drain, no 64 KB deadlock).
- `terminate` is idempotent and safe to call on an already-exited handle; `reap` is the only place a handle is consumed.

### 2. The result model

```nim
type
  ExitKind* = enum ekExited, ekSignaled, ekNtStatus
  Exit* = object                      ## LOSSLESS observation of how the child ended
    case kind*: ExitKind
    of ekExited:   code*: int         ## WEXITSTATUS / Windows exit code < 0xC0000000
    of ekSignaled: sig*: int; coreDumped*: bool
    of ekNtStatus: status*: uint32    ## Windows crash (STATUS_ACCESS_VIOLATION …)
    symbol*: string                   ## "SIGSEGV" / "STATUS_STACK_OVERFLOW" — cosmetic, from a table
    rusage*: Rusage                   ## maxRssBytes, userCpuUs, sysCpuUs — wait4(2) / Job accounting; never dropped

  CauseBy* = enum cbProcess, cbRunner, cbLimit, cbExternal
  KillReason* = enum krTimeout, krInterrupt, krMemoryPressure, krBudget
  LimitKind* = enum lkCpu, lkFileSize                     ## only the DETERMINISTIC ones
  Cause* = object                     ## AUTHORSHIP — asserted only when the runner knows
    case by*: CauseBy
    of cbProcess:  discard            ## ended on its own
    of cbRunner:   reason*: KillReason; escalated*: bool   ## we sent the kill; escalated = needed the forced step
    of cbLimit:    limit*: LimitKind  ## SIGXCPU/SIGXFSZ; Job limit violations
    of cbExternal: discard            ## a SIGKILL we did not send: OOM killer, operator, unknown

  KillDomainStrength* = enum kdsProcessGroup, kdsProcessGroupSubreaper, kdsCgroup, kdsJobObject
  Evidence* = object                  ## what the runner can VOUCH for
    killDomain*:     KillDomainStrength
    treeReaped*:     bool             ## every pid we observed in the domain is gone
    escapees*:       seq[ProcSnapshot]  ## survivors observed at kill/reap time
    outputComplete*: bool             ## not truncated by the cap
    sandbox*:        SandboxAchieved  ## RFC-0004 A4d, unchanged shape
    killSnapshot*:   seq[ProcSnapshot]  ## tree at the moment of a forced kill (runner-authored only)
    nearAddressSpaceLimit*: bool      ## rusage.maxRss within 5% of Limits.addressSpace — annotation, not a Cause

  ProcessResult* = object             ## ONE shape for the compile phase and the run phase
    exit*: Exit; cause*: Cause; evidence*: Evidence; durationUs*: int64

  EntrypointResult* = object
    ep*: Entrypoint
    compile*: Option[ProcessResult]   ## none when compile was skipped (fresh) or the result was cached
    run*:     Option[ProcessResult]   ## none when never run (compile failed / spawn error / cached)
    spawnError*: string               ## "" unless the OS refused to create the child (phase = whichever is none)
    records*, output*, outputTruncated*, …  # unchanged
    # REMOVED: outcome (derived), exitCode, signal, achieved (now evidence.sandbox), peakRssBytes (now exit.rusage)

  Outcome* = enum oPassed, oFailed, oCrashed, oKilled, oCompileFailed, oSpawnError

proc outcome*(r: EntrypointResult): Outcome =
  ## PURE. Serialized into run/v2 for consumers; never deserialized as truth.
  if r.spawnError.len > 0:                                   oSpawnError
  elif r.compile.isSome and not r.compile.get.exit.isExitZero: oCompileFailed   # incl. compile killed by runner
  elif r.run.isNone:                                         oSpawnError       # defensive: cannot happen post-A1
  elif r.run.get.cause.by == cbRunner:                       oKilled
  elif r.run.get.exit.kind != ekExited:                      oCrashed          # signaled / ntstatus; cause may be limit/external
  elif r.run.get.exit.code == 0 and not r.hasFailRecords:    oPassed
  else:                                                      oFailed
```

Consequences stated plainly:
- **Authorship is from the runner's own action**, never pattern-matched from the signal. On POSIX: "I sent SIGTERM/SIGKILL and the child died of that signal inside my window" ⇒ `cbRunner`. On Windows: `TerminateJobObject` with a runner-chosen exit code ⇒ unambiguous from the raw exit alone. A SIGKILL we did not send is `cbExternal`, and we say so.
- **`RLIMIT_AS` failures are not a `Cause`.** The kernel does not tell us; rusage gives an annotation. No heuristic is dressed as fact.
- **Replayable verdicts.** The cache (RFC-0004 `CachedResult`, RFC-0005 `StoredEntry`) stores the run `ProcessResult` + records; `outcome` is recomputed on load. If derivation rules change, stored observations yield new verdicts without rerunning.
- **Compile and run share one shape.** A compile timeout is `compile.cause = runner(timeout)` and derives to `oCompileFailed`; today it is a separate code path to a separate enum value.
- **Interrupt.** Slots killed by `handleInterrupt` produce results with `run.cause = runner(interrupt)` (⇒ `oKilled`); the run-level `rsInterrupted`/`128+n` exit of RFC-0003 is unchanged.

### 3. Kill domains, termination protocol, supervision

| Platform | Domain | Strength | Cooperative → forced | Wait |
|---|---|---|---|---|
| Linux | pgid; crisol sets `PR_SET_CHILD_SUBREAPER` so orphans at any depth reparent to crisol and are reaped + counted; per-slot cgroup v2 leaf via `clone3(CLONE_INTO_CGROUP)` when delegated (`cgroup.kill` is atomic and airtight; `memory.peak`/`memory.max` give tree accounting and a real `RLIMIT_AS` replacement) | `cgroup` / `processGroup+subreaper` | SIGTERM → SIGKILL | pidfd + poll/epoll (≥ 5.3), 25 ms poll fallback |
| macOS | pgid; escapees via libproc lineage scan at kill/reap | `processGroup` | SIGTERM → SIGKILL | kqueue `EVFILT_PROC NOTE_EXIT` |
| Windows | Job Object, `KILL_ON_JOB_CLOSE`, breakaway disabled, nested-job-safe; `ACTIVE_PROCESS_ZERO` tells us when the whole tree is gone | `jobObject` | `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)` to the child's own console group (`CREATE_NEW_PROCESS_GROUP`) → `TerminateJobObject(runner code)` | completion port / `WaitForMultipleObjects` |

- Before any forced kill the backend takes `snapshotTree` and stores it in `Evidence.killSnapshot`. A timeout stops being "it hung" and becomes "blocked in a 400 MB `nim c` grandchild".
- `killpg` is pid-reuse-safe while the group lives (the pgid holds the pid); pidfd is adopted for the event loop, not as a correctness fix. The 25 ms poll was never a correctness flaw; event-driven wait is adopted because Windows' natural API *is* event-driven and one "wait for the next event before `deadline`" primitive is a cleaner contract than three polls.
- `clone3` is preferred on Linux because `fork` + write-pid-to-`cgroup.procs` has a window where the child exists outside its cgroup; `CLONE_INTO_CGROUP` closes it. The child path stays async-signal-safe in both.

### 4. Capabilities: probed once, degraded, reported

`capabilities()` runs at startup (like `ccprobe`/`nimprobe`), is memoised, and is rendered in `run/v2` under `substrate` and in `plan/v1`. Probes: pidfd, subreaper, cgroup v2 delegation (can we `mkdir` a leaf under our own cgroup and write `cgroup.procs`?), kqueue, Job Object nesting, `flock`, `wait4` rusage. Each guarantee the substrate cannot deliver on this host becomes a degraded `Evidence` field on every result — never an assumption, never a silent drop. **Nothing in this RFC is *required* to be present**; the dev loop (rootless podman: no cgroup delegation, no user-ns) runs the `processGroup+subreaper` tier and says so.

### 5. Hermeticity mechanisms (RFC-0004 F2, restated under the contract)

rlimits remain the floor and are mapped through `Limits`. Linux adds cgroup `memory.max` in place of `RLIMIT_AS` when delegated (reported which one applied). Windows maps `Limits` to Job basic/extended limits; `openFiles` has no analog and is reported unachieved. **No network enforcement anywhere** — see §Non-goals. **No mount/user namespaces** — deferred; `TMPDIR` injection plus RFC-0008's observed inputs cover the soundness case without a second isolation mechanism.

### 6. Escapee policy

The verdict is never changed by hygiene — crisol does not judge test semantics. An observed escapee makes the result **uncacheable** (RFC-0004's not-fully-achieved rule, now `evidence.treeReaped == false`), is surfaced as a first-class warning in render and `run/v2`, and on Linux-with-subreaper is additionally *reaped*. `--strict-hygiene` opts into `oFailed` for consumers who want CI to enforce it. Rejected: fail-by-default (pgid-only macOS would be flakier than Linux for the same suite); report-only (the cache would trust a leaked environment).

### 7. Everything else the port touches

- **`ioutils` becomes the sole owner of raw file primitives** — `exclusiveCreate`, `appendOpen`, `atomicPublish` (`rename` / `MoveFileEx(REPLACE_EXISTING)`), `writeAllFd`. `depgraph`, `jsonout`, `ledger`, `shardedledger`, and `crisol.nim`'s init writer stop hand-rolling `posix.open`.
- **Single-run lock: `flock(LOCK_EX|LOCK_NB)` on POSIX, `LockFileEx` on Windows.** RFC-0001 chose `fcntl F_SETLK` only because `flock` was missing from `std/posix` (a one-line `importc`). `flock` is per-open-file-description, so the classic fcntl hazard (any close of the path by this process drops the lock) disappears.
- **Signals:** `sigaction` flag on POSIX, `SetConsoleCtrlHandler` on Windows, behind `shutdownRequested(): Option[KillReason]`.
- **Rusage into admission:** the per-entrypoint `maxRssBytes` from `wait4` is the measured input RFC-0002's admission estimates today from `/proc` sampling; the ledger row's `rssBytes` becomes the post-exit value (sampling stays as the *live* throttle signal).

## Non-goals

- **Network enforcement**, on any platform. `hlNetwork` remains "network-independence asserted": unachieved-and-reported until RFC-0008's observer exists; macOS Seatbelt (`sandbox_init`, deprecated) and Linux `CLONE_NEWNET` are *not* adopted — enforcement belongs to the CI container, crisol observes.
- **Observed inputs** (files, network, randomness, exec) — RFC-0008. Depends on `Evidence` and the event loop from this RFC.
- **Path identity** (`ProjectPath`, case-folding, drive letters) — RFC-0009. Stage D is conformance-green on Windows only once 0009 lands; Stage D slices do not pretend otherwise.
- Sub-binary control; mount/user namespaces; posix_spawn (cannot set rlimits, needs child-side code for `Achieved`).

## Alternatives considered

- **Additive-only result schema** — keep `oTimeout`/`oSignal`/`signal` and add beside them. Rejected: pre-v1, all consumers owned, and carrying two names for one thing forever is the cruft the ideal does not have; `oSignal` would remain a lie on Windows.
- **Executor as commodity** — seam refactor for portability, stop there. Rejected: leaves `Cause` conflated and kill-domain unreported, so the cache gate trusts results it cannot vouch for.
- **Mechanism-maximal** — require namespaces/cgroups/pidfd. Rejected: degrades silently in the environment crisol is developed in.
- **Keep polling forever** — viable (not a correctness flaw) but three polls vs one event contract; Windows would be the odd one out.
- **`sandbox_init` on macOS** — deprecated, no supported replacement for arbitrary children; and we do not want enforcement from crisol at all.

## Stages & slices

Dependency-correct order. **Stage A precedes the RFC-0005 build.** Stages B–D are independent of 0005 and may interleave with it.

**Fixture inventory (build before the slices that consume them):** `hang_forever` (exists); `crash_segv` (deliberate SIGSEGV); `self_sigkill` (sends itself SIGKILL — `cbExternal`); `term_cooperative` (exits 0 on SIGTERM within grace) and `term_ignores` (ignores SIGTERM — `escalated`); `spawn_grandchild_setsid` (daemonizes a grandchild — escapee); `cpu_burn` for `SIGXCPU` (exists as `rlimit_cpu`); `fsize_overrun` (exists).

**Stage A — result model, contract, seam (Linux; highest architect scrutiny):**
- [ ] **A1a** `Exit`/`Cause`/`Evidence`/`ProcessResult`/`Rusage` types; `outcome(r)` derivation; `EntrypointResult` reshaped (`compile`/`run`/`spawnError`; `outcome`/`exitCode`/`signal`/`achieved`/`peakRssBytes` removed); every consumer (`render`, `jsonout`, `junit`, `order`, `resultcache`, `cachedispatch`, `protocol`, `runner.classifyRunResult`, `crisol.nim`) moved to the derived outcome. Today's `spawn.supervise` returns `Exit` + a runner-kill flag; runner stamps `Cause`. `run/v1` → **`crisol/run/v2`** (`exit`, `cause`, `evidence`, `outcome` string, `substrate` placeholder); junit maps `oKilled`/`oCrashed` → `<error>`. **E2E (load-bearing):** `hang_forever` through `crisol run --json` ⇒ `outcome:"killed"`, `cause:{by:"runner",reason:"timeout"}`, `exit.kind:"signaled"`, `exit.symbol:"SIGKILL"`; `pass_always` ⇒ `"passed"` with `exit.code:0`; `fail_compile` ⇒ `compile.exit.code != 0` and `"compileFailed"`. Cache roundtrip stores `ProcessResult` and recomputes outcome. *Depends on:* nothing.
- [ ] **A1b** Authorship & grace: `escalated` from the SIGTERM→SIGKILL path; `crash_segv` ⇒ `oCrashed`/`cause:process`/`symbol:SIGSEGV`; `self_sigkill` ⇒ `oCrashed`/`cause:external`; `term_cooperative` ⇒ `killed`/`escalated:false`; `term_ignores` ⇒ `escalated:true`; `SIGXCPU` ⇒ `cause:limit(cpu)`; interrupt path stamps `runner(interrupt)`. Render shows cause + escalation. Tested through `execute()` and the CLI.
- [ ] **A2** `process.nim` + `process/posix.nim`: `ChildSpec`/`ChildHandle`/`spawn`/`wait`(poll)/`terminate`/`reap`/`snapshotTree`; `spawn.nim` folded in; `runner.nim` loses `std/posix` (`reapBlocking`, `killAndReap`, `teardownLiveSlots`, `pollSlot` become contract calls); **`Slot` gets `SlotState` (#1)** and a `ChildHandle`; explicit env for `hlNone`; **every `ChildSpec.cwd` = `projectRoot` (#17)** — both `spawnCompileStable` and `compiledriver.realCompileOnly` spawn `nim c` in `projectRoot` (today: the invoker's cwd, so a group `flags "--path:src"` silently fails from a subdirectory `--config ../crisol.kdl` or a library caller with an unrelated cwd; `closure.extractCompileInputs` resolves relative `cc -M` paths against the same directory, so it follows automatically once the compile cwd is fixed — keep the two consistent); README documents that relative paths in `flags` are root-relative. Acceptance pinned by an integration test: a `--path:src` group compiles identically from the project root, from a subdirectory via `--config ../crisol.kdl`, and through the library API with an unrelated cwd. Conformance tests created in `tests/conformance/` (grandchild reap, timeout kill, cooperative vs escalated, output caps, achieved readback, spawn error) and the existing `test_pgroup`/`test_supervise`/`test_sandbox_achieved` migrate there. No behaviour change beyond A1.
- [ ] **A3** `ioutils` sole owner of raw file I/O (`exclusiveCreate`, `appendOpen`, `atomicPublish`, `writeAllFd`); `depgraph`, `jsonout`, `ledger`, `shardedledger`, `crisol.nim` init migrated; `std/posix` import count outside `process/`, `ioutils`, `lock`, `signals`, `memprobe` is **zero** (asserted by a unit test that greps `src/`). Pure consolidation; existing tests are the proof.
- [ ] **A4** `lock.nim` → `flock` (importc); `signals.nim` → `shutdownRequested(): Option[KillReason]`; lock-exclusion conformance test; the "close-any-fd-drops-lock" hazard gets a regression test that opens+closes the lock path from a helper.
- [ ] **A5** `Rusage` via `wait4` into `Exit.rusage`; `ledger` `rssBytes` = post-exit `maxRssBytes`; admission estimate consumes it; `nearAddressSpaceLimit` annotation; `run/v2` renders `rusage`. Tested with the `rlimit_as` fixture (annotation true) and a trivial binary (false).
- [ ] **A6** Kill snapshot + escapee detection (Linux `/proc`, pgid scan): `snapshotTree` before forced kill → `evidence.killSnapshot`; post-reap survivors → `evidence.escapees`, `treeReaped=false` ⇒ cache gate refuses (`evidenceSatisfies(spec, ev)` replaces the bare `isFullyAchieved` call in `shouldStore`), render warning, `--strict-hygiene` ⇒ `oFailed`. Fixture `spawn_grandchild_setsid`. Tested through `execute()` and the cache roundtrip (escapee ⇒ not stored).
- [ ] **A7** `capabilities()` probe (Linux: pidfd, subreaper, cgroup delegation, flock, wait4) rendered in `run/v2.substrate` and `plan/v1`; `Evidence.killDomain` populated from it (currently always `processGroup`). CHANGELOG + schema docs; consumer notice (amoxtli, tonalli) for `run/v2`. **Stage A done ⇒ RFC-0005 build may start.**

**Stage B — Linux capability upgrades (each gated by A7's probe; each reports its tier):**
- [ ] **B1** `PR_SET_CHILD_SUBREAPER`: orphans reparent to crisol; reap loop distinguishes direct children from adopted orphans; escapees are reaped and counted (`killDomain = processGroupSubreaper`). Fixture `spawn_grandchild_setsid` now shows `treeReaped=true` + `escapees` non-empty (observed and handled).
- [ ] **B2** pidfd + `poll`-driven `wait` with timerfd deadlines; 25 ms tick retained only for memory sampling; `wait` falls back to polling when pidfd is absent (probe). Conformance suite green under both (forced via an env knob in tests).
- [ ] **B3** cgroup v2 per-slot leaf when delegated: `clone3(CLONE_PIDFD|CLONE_INTO_CGROUP)`, `cgroup.kill` for terminate, `memory.peak` for rusage/tree accounting, `memory.max` for `Limits.addressSpace` (reported as the mechanism used); `killDomain = cgroup`. Tests self-gate on delegation (like `CRISOL_TIMING_TESTS`) and assert *degradation* where absent.

**Stage C — Darwin backend:**
- [ ] **C1** `process/darwin.nim`: kqueue `EVFILT_PROC` wait, libproc `snapshotTree`, `hlNetwork` unachieved-and-reported, `/proc`-free memprobe degradation confirmed; GitHub Actions `macos-latest` leg running the conformance suite + the full unit suite. tonalli macOS legs convert.

**Stage D — Windows backend (#15; conformance-green requires RFC-0009):**
- [ ] **D1** `process/windows.nim`: `CreateProcess` + Job Object, inherited handles to sinks, completion-port wait, `CTRL_BREAK` → `TerminateJobObject(runner code)`, NTSTATUS symbol table, `Limits` → Job limits (`openFiles` unachieved), `JobObjectBasicProcessIdList` snapshots.
- [ ] **D2** `lock` (`LockFileEx`), `ioutils` (`MoveFileEx`, `CREATE_NEW`), `signals` (`SetConsoleCtrlHandler`), memprobe (`GlobalMemoryStatusEx` + Job accounting). `windows-latest` CI leg running the conformance suite; full-suite green is RFC-0009's acceptance.

## Contract impacts

- **`crisol/run/v2`** replaces `run/v1` (breaking; pre-v1). `plan/v1` gains `substrate`. `loadLastRun` reads v1 as cold-start.
- **`EntrypointResult`** loses `outcome`/`exitCode`/`signal`/`achieved`/`peakRssBytes`; gains `compile`/`run`/`spawnError`; `outcome(r)` is a proc. `signalName` stays as a POSIX convenience over `Exit.symbol`.
- **RFC-0003 exit codes** unchanged: `oKilled`/`oCrashed` are test *results* ⇒ `rsOk`, exit 1; crisol-level SIGINT/SIGTERM ⇒ `rsInterrupted`, `128+n`.
- **RFC-0004** `CachedResult` stores the run `ProcessResult` + records; `shouldStore` gates on `evidenceSatisfies(spec, evidence)`; `hlNetwork` semantic = network-independence asserted (unachieved until RFC-0008).
- **RFC-0005** `StoredEntry` payload = the A1 shape; `storageFormatVersion`/`resultCacheFormatVersion` bump once, here, before anything is signed. Its publish gate reads `Evidence`.
- **JUnit:** `oKilled`/`oCrashed` → `<error>` with `cause` in the message.
- **RFC-0001** Implementation Decisions table: `fcntl F_SETLK` → `flock`; poll loop → event-driven where available; process-group placement → kill-domain ladder.

## Risks accepted

- macOS/Windows backends are CI-only to develop (no host Nim; podman is Linux).
- cgroup/namespace paths are dark in the rootless-podman dev loop; the Linux CI leg needs a delegated cgroup (or the tests assert degradation, which they do) — the same dark-code failure mode #12 had, mitigated by probe-reported tiers and self-gated tests.
- `run/v2` breaks amoxtli/tonalli JSON consumers once; both are Corey's and are updated in one commit each.
