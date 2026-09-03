# RFC-0007 — Execution substrate: process contract, honest results, platform backends

**Status:** In-progress — stage 3 slice grind (A0–A1b landed 2026-09-02, A1c underway; architect rounds 1–2 applied 2026-08-23)
**Depends on:** RFC-0001 (runner), RFC-0002 (scheduling/admission), RFC-0004 (hermetic execution, `SandboxAchieved`, cache gate)
**Precedes:** RFC-0005 *build* (the `StoredEntry` wire freezes on this RFC's result model — see §Contract impacts)
**Followed by:** RFC-0008 (observed inputs — the input observer), RFC-0009 (path identity — `ProjectPath`; prerequisite for Windows green)
**Closes / absorbs:** #18 (landed ahead as a portability fix), #15 (Windows backend = Stage D), #1 (`SlotState`, Stage A2), #17 (compile spawn cwd = `projectRoot`, Stage A2)
**Scope owner:** Corey

## Summary

crisol's executor is correct on Linux and accidental everywhere else: `std/posix` is imported by ten modules, `runner.nim` runs its own `waitpid`/`killpg` loops, and the result model conflates *what the OS reported* (`exitCode`/`signal`), *who caused it* (`timedOut`), and *what we conclude* (`outcome`) into one stored record. That is why macOS broke on two glibc-isms (#18), why Windows reads as a rewrite (#15), and why a timeout and an OOM-kill are indistinguishable in `run/v1`.

This RFC replaces the accretion with a designed substrate:

1. **One process contract** (`process.nim` re-exporting a compile-time-selected backend *module*: `process/posix`, `/linux`, `/darwin`, `/windows`) built around a `Supervisor` that owns the event loop. The executor never sees a `Pid`, a `HANDLE`, `killpg`, or `waitpid`.
2. **An honest result model**: `Exit` (lossless observation) × `Cause` (authorship, asserted only from the runner's own recorded acts) × `Evidence` (what the runner can vouch for, including "cannot observe"), with `Outcome` a **pure function** of result × policy — serialized as advisory, recomputed at every crisol trust boundary, never read from storage as truth.
3. **Guarantees as identity, mechanisms as capabilities.** Kill-domain strength, limits, isolation, and supervision fidelity are probed at startup, degraded when absent, and *reported* in `Evidence` — the RFC-0004 `Achieved` posture promoted to the whole layer. The cache gate reads `Evidence`.
4. **Backends** for Linux upgrades (subreaper, pidfd/event-driven wait, cgroup v2), Darwin, and Windows, all measured by one backend-agnostic conformance suite, each backend `nim check`-able per platform from any host.

Everything stays at entrypoint-binary granularity and observation-only: crisol enforces nothing it did not enforce before (less, in fact — see §Non-goals, network).

## Motivation

- **#18** — `pipe2`/`execvpe` are glibc, not POSIX. Landed ahead of this RFC as a pure portability fix; the structural lesson (one code path, POSIX not glibc) is §Design 1.
- **#15** — tonalli's Windows legs cannot convert until crisol runs there. Without a seam the port is a rewrite of `runner.nim`; with one it is `process/windows.nim` plus three small `when` branches.
- **Termination honesty** — `oTimeout` is the only runner-authored kill the model can express; `oSignal`+`SIGKILL` cannot say whether the runner, the OOM killer, or the test itself sent it; `oSignal`/`"signaled"` cannot describe a Windows `STATUS_ACCESS_VIOLATION`. Whether a test honored the grace window (died on SIGTERM vs needed SIGKILL) is not recorded anywhere, though it is the first question when protocol records go missing on a timeout. Worse: the current timeout path *fabricates* the observation — `killAndReap` discards the reaped wait status on both its paths and `pollSlot` synthesizes `signal: SIGKILL` unconditionally, even when the child died on SIGTERM (or exited 0) inside the grace window.
- **RFC-0005 is about to freeze and sign the wire.** Its `StoredEntry` payload is "byte-identical to today's" result-cache record and its `storageFormatVersion` is statically tied to `resultCacheFormatVersion`. Changing the result model *after* 0005 ships invalidates every distributed, attested entry fleet-wide; changing it *before* costs a local schema bump you were going to pay anyway.
- **Encapsulation debt on Linux today**, independent of any port: raw `open/write/close/rename` hand-rolled in five modules; supervision split between `spawn.nim` and `runner.nim` (with `spawn.supervise` dead code — zero callers in `src/`); `pepIdx == -1` as the slot idle sentinel (#1).

## Identity check

crisol is "one layer up" from the test (MEMORY → boundary-granularity-discriminator) and its value is sound *selection* and trustworthy results (MEMORY → crisol-value-is-selection). The substrate's **guarantees** — kill-domain completeness, termination honesty, requested-vs-achieved reporting — are soundness properties of the result that the selection and cache layers consume; they are identity. The **mechanisms** (cgroups, namespaces, pidfd, Job Objects) are capabilities: probed, reported, never required. Nothing here controls what happens *inside* a test binary.

## Load-bearing property

> **A runner-authored kill is reported as such, end-to-end.** Running a hanging entrypoint through the real entry point (`crisol run --json`) yields `outcome: "killed"`, `cause: {by: "runner", reason: "timeout", escalated: false}`, and an `exit` that records what the OS actually reported — for `hang_forever` (default signal dispositions) that is `exit.kind: "signaled"`, symbol `SIGTERM`, because it dies inside the grace window; a SIGTERM-ignoring fixture earns `SIGKILL`/`escalated: true` (the typical case — `escalated` is defined observably in §1 as "the forced step was recorded before the backend observed an exit", so the rare SIGTERM-death-during-forceKill honestly reads `escalated: true` too). `outcome` is *derived* from the result × policy by one pure, total function — never read from storage.

The producer surgery is named, because "the runner already knows when it killed" is only half-true today: authorship is live (`pollSlot`'s timeout branch), but the *observation* is discarded — `killAndReap`/`reapBlocking` throw away the reaped `wstatus` and the result is synthesized. Slice A1b reworks that path to capture the real status and the escalation bit; `spawn.supervise` (no `src/` callers) is deleted, not adapted. Every later slice refines the substrate underneath without changing the property. If this property cannot be shown live — with the honest SIGTERM, not the synthesized SIGKILL — from the first E2E slice, the RFC is scaffolding around a hole. To keep the property on the **real wire** from that first slice, A1b additively emits advisory `exit`/`cause` nodes into `run/v1` (rev bump; readers are unknown-tolerant by design) — the v1→v2 reshape stays in A1d, but the honest observation is publicly visible from the slice that produces it.

## Design

### 1. The process contract

```nim
## process.nim — the ONLY process-lifecycle surface the executor imports.
## Re-exports the backend MODULE selected at compile time:
##   when defined(windows): import process/windows as backend
##   elif defined(linux):   import process/linux    # posix + Linux capabilities
##   elif defined(macosx):  import process/darwin   # posix + kqueue/libproc overrides
##   else:                  import process/posix
##   export backend
## Real modules, not `include`: platform-neutral types live in process/types.nim,
## and each backend is a self-contained module that `nim check --os:<x>`s from any
## host — signatures get per-platform compiler checking; the conformance suite
## checks behaviour. (`include` would reduce the contract to doc comments.)
## Sharing mechanism (Nim has no partial module override — a backend cannot
## "re-export posix plus two procs"): process/posixcore.nim holds the shared
## machinery (fork/exec child window, rlimit readback, self-pipe, poll wait)
## over a PosixCore object; each posix-family backend embeds PosixCore in its
## own Supervisor and implements the full contract surface, mostly one-line
## delegations. `macosx` maps to process/posix until C1b births process/darwin.

type
  Supervisor* = object       ## deep module: owns the event loop (pidfd/epoll |
                             ## kqueue | completion port), the shutdown-signal
                             ## wakeup, and the child registry. Fields backend-private.
  ChildId* = distinct int32  ## stable token, valid spawn..reap. The fd/HANDLE never
                             ## leaves the backend, so copies are inert and the
                             ## consume-once invariant is enforceable.

  StdioSink* = object        ## by PATH, never by fd: the backend opens it however
    path*: string            ## it must. ONE combined stdout+stderr sink — nothing
                             ## in crisol ever splits the streams (runner, junit,
                             ## render, protocol all consume combined output); a
                             ## split arm would be a dark variant with zero
                             ## producers, cut by the round-1 rule. Sharing is
                             ## STRUCTURAL (same sink object), not path-equality
                             ## (case-folding aliases are RFC-0009 territory).
                             ## Constructor `combinedSink(path)` — call sites
                             ## never build the object literally.
    ## stdin is always /dev/null | NUL — contract invariant, not an option.

  LimitKind* = enum          ## ONE vocabulary for limits: requested, achieved, and
    lkAddressSpace, lkCpu,   ## Cause.cbLimit all index by it (B3 adds lkMemory).
    lkFileSize, lkOpenFiles, ## Adding a limit = one enum value; every case/loop
    lkCore                   ## over LimitKind is compiler-forced; readback, serde,
                             ## and the Windows Job mapping become loops, not five
                             ## copied stanzas.
  Limits* = object           ## the SINGLE home for resource limits; SandboxSpec no
                             ## longer carries rlimits. Enum-indexed, not five
                             ## parallel fields — a transposed assignment cannot
                             ## compile-through. Dot-sugar templates (`limits.cpu`)
                             ## restore field ergonomics where wanted.
    req*: array[LimitKind, Option[int64]]

  ChildSpec* = object
    argv*: seq[string]
    cwd*: string             ## resolved by the RUNNER before spawn: the sandbox
                             ## scratch dir when isolation demands chdir, else
                             ## projectRoot (#17) — relative paths in config `flags`
                             ## (e.g. `--path:src`) resolve against the project root,
                             ## never the invoker's cwd. ONE cwd mechanism.
    env*: seq[(string, string)]  ## EXPLICIT, always. The runner resolves env scrub +
                             ## TMPDIR injection into this list; hlNone = the parent
                             ## env explicitly copied. Env/tmpdir "achieved" is thus
                             ## true by construction — only limits need readback.
    sinks*: StdioSink
    limits*: Limits

  LimitStatus* = enum lsNotRequested, lsUnsupported, lsFailed, lsApplied
    ## ord 0 is the WEAKEST claim — the house rule for every evidence enum (§2):
    ## a default-initialized value must never encode a vouch. lsNotRequested
    ## exists because the requested/achieved JOIN ("requested AND applied") is
    ## what cbLimit and the cache gate consume — no consumer hand-rolls it from
    ## two structs, and an unrequested limit is never stamped with a lie.
  LimitsAchieved* = array[LimitKind, LimitStatus]
    ## per-limit, replacing today's single aggregate bit; POSIX: child-side
    ## setrlimit readback (the existing status-pipe ceremony, shrunk to exactly
    ## this); Windows: parent-computed from Job limits — the different meaning
    ## is documented, not papered over. Delivered in ReapReport (below), not
    ## SpawnResult — nothing consumes achieved-ness before the result.

  SpawnResult* = object      ## a real sum type, not tuple-with-empty-string
    case ok*: bool
    of true:  id*: ChildId
    of false: error*: string

  ShutdownSignal* = object   ## carries the signal identity RFC-0003's 128+n needs
    signum*: int             ## SIGINT/SIGTERM; Windows maps CTRL_C/CTRL_BREAK to
                             ## the corresponding POSIX numbers for the exit rule.
                             ## No `reason` field: a one-value enum is a dark value
                             ## (the round-1 rule), and the shutdown→krInterrupt
                             ## stamp is the RUNNER's act at the moment it stops
                             ## slots, not part of the signal's identity.

  ProcSnapshot* = object     ## WIRE TYPE (Evidence.killSnapshot/escapees; 0005-signed)
    pid*, ppid*: int
    command*: string         ## comm / image name
    rssBytes*: int64         ## doubles as the live sampling quantity (snapshotTree)

  WaitEventKind* = enum weChildExited, weOrphanReaped, weDeadline, weShutdown
  WaitEvent* = object
    case kind*: WaitEventKind
    of weChildExited:  id*: ChildId       ## exited, not yet reaped. LEVEL-TRIGGERED:
                                          ## reported again on every `next` until
                                          ## reaped — a lost event cannot wedge a slot.
    of weOrphanReaped: orphan*: ProcSnapshot; ownedBy*: Option[ChildId]
                                          ## subreaper tier only (B1): an adopted
                                          ## orphan died. §3's pgid attribution is
                                          ## DELIVERED, not computed-then-discarded;
                                          ## `none` = honestly unattributable.
    of weShutdown:     signal*: ShutdownSignal  ## the shutdown signal is IN the wait
                                          ## set (self-pipe/signalfd | ctrl-handler
                                          ## event object) — interrupt latency is an
                                          ## event, not a poll interval. EDGE-
                                          ## triggered, once per delivered signal
                                          ## (level-triggered would starve the
                                          ## teardown loop's own `next` calls); a
                                          ## SECOND interrupt during teardown means
                                          ## "skip grace, forceKill now" (A2b).
    of weDeadline:     discard

proc initSupervisor*(): Supervisor
proc capabilities*(sv: Supervisor): Capabilities  ## probed once, memoised (§4)
proc spawn*(sv: var Supervisor; spec: ChildSpec): SpawnResult
proc next*(sv: var Supervisor; deadline: MonoTime): WaitEvent
  ## The ONE wait primitive. Event-driven where the platform has it (pidfd+epoll |
  ## kqueue EVFILT_PROC | completion port; WaitForMultipleObjects only as a small-N
  ## fallback — its 64-handle cap is a real bound); 25 ms poll otherwise.
  ## Single-threaded either way; EINTR-transparent. The executor passes min(run
  ## deadlines, grace deadlines, sample tick). Ready child exits are ALWAYS
  ## drained before weDeadline is reported — a spec-level narrowing of the
  ## authorship race (§2) no backend may skip. On weDeadline the executor's
  ## pattern is "sweep every armed deadline that has passed", never per-wakeup
  ## cause-guessing.
proc requestStop*(sv: var Supervisor; id: ChildId; reason: KillReason)
  ## Cooperative stop (SIGTERM to the domain | CTRL_BREAK). NON-BLOCKING and
  ## idempotent: grace is a deadline the EXECUTOR arms, not a sleep the backend
  ## takes — N hung slots tear down in one shared grace window, never N serial
  ## ones. The act is recorded ATOMICALLY against exit observation in the child
  ## registry: if the backend has already observed this child's exit, the call
  ## is a no-op that records NOTHING — ReapReport.stop is therefore the single,
  ## ordered authorship ledger, and the misattribution race shrinks from the
  ## executor's poll granularity to the true kernel window (signal already in
  ## flight when the exit lands). First act wins: a slot already in its timeout
  ## grace window hit by interrupt teardown keeps krTimeout. Takes snapshotTree
  ## at the FIRST stop act (→ ReapReport.killSnapshot) — the common timeout dies
  ## on SIGTERM inside grace, and the "blocked in a 400 MB nim c grandchild"
  ## diagnostic must exist on that path, not only on escalation.
proc forceKill*(sv: var Supervisor; id: ChildId)
  ## Forced kill (SIGKILL to the domain | TerminateJobObject(runner-chosen code)).
  ## Refreshes the killSnapshot. Non-blocking, idempotent, same atomic no-op rule
  ## as requestStop when the exit is already observed. `escalated` := forceKill
  ## was recorded before the backend observed the exit — an OBSERVABLE definition
  ## ("was actually needed" is unknowable); the corner where the child died on
  ## SIGTERM in the same instant reads escalated:true with exit=SIGTERM, accepted
  ## and honest. When the cooperative step was never attempted
  ## (cooperativeUnavailable, §3), escalated is false — nothing to escalate FROM.
proc reap*(sv: var Supervisor; id: ChildId): ReapReport
  ## The only place a ChildId is consumed. Precondition: weChildExited was
  ## reported for this id — Defect otherwise; the executor never blocks here.
  ## Everything the backend observed comes back in ONE report, and the promise is
  ## kept honest: LimitsAchieved, killDomain, and cooperativeUnavailable ride in
  ## the report — never in SpawnResult, never in side channels the runner merges.
proc snapshotTree*(sv: Supervisor; id: ChildId): seq[ProcSnapshot]
  ## /proc | libproc | JobObjectBasicProcessIdList — kill/reap FORENSICS only
  ## (0005-signed wire records). rssBytes populated on every tier that can read
  ## it (/proc status | libproc | Job accounting) — never zero-filled.
proc groupRssBytes*(sv: Supervisor; id: ChildId): Option[int64]
  ## The live memory SAMPLER (25 ms cadence): the group-RSS sum and nothing else —
  ## no comm strings, no per-tick seq churn. memprobe/admission route through
  ## this (which un-degrades Darwin and Windows admission sampling), and the wire
  ## type above never feels sampler pressure. Two roles, two cadences, two procs.

type
  ReapReport* = object       ## the ONE report: the backend's complete observation
                             ## record for this child, INCLUDING its act ledger
    exit*: Exit
    rusage*: Option[Rusage]  ## wait4 | Job accounting; `none` only where the
                             ## platform genuinely cannot say — never zero-filled
    stop*: Option[tuple[reason: KillReason, escalated: bool]]
                             ## THE authorship record — `some` iff a stop act was
                             ## recorded before the backend observed the exit
                             ## (requestStop above). Cause(cbRunner) is a pure map
                             ## over this; the load-bearing fact has ONE owner,
                             ## the Supervisor, which owns stop-vs-exit ordering.
    killDomain*: KillDomainStrength  ## the PER-SPAWN achieved domain — a cgroup
                             ## leaf mkdir can fail after a green probe
    limits*: LimitsAchieved  ## per-limit readback, delivered at reap
    killSnapshot*: seq[ProcSnapshot]  ## taken at the first stop act, refreshed at
                             ## forceKill; empty iff no stop act — documented rule,
                             ## not a conflation of "none taken" with "tree empty"
    tree*: TreeObservation   ## §2 — observability of the domain, honest "cannot see"
    escapees*: seq[ProcSnapshot]  ## survivors observed at kill/reap time
    cooperativeUnavailable*: bool  ## Windows: the cooperative stop could not be
                             ## delivered (console topology, §3)
```

Invariants carried forward from RFC-0001 and restated as the contract's:
- The POSIX child window (between fork/clone and exec) executes only async-signal-safe primitives; the executor is single-threaded before and during the spawn loop.
- `spawn` never inherits the parent environment implicitly; `hlNone` means "the parent's env, explicitly copied", not "whatever `environ` is".
- Output sinks are opened **before** the child exists and handed to it at spawn (no pipe drain, no 64 KB deadlock); stdin is `/dev/null`/`NUL`.
- `requestStop`/`forceKill` are idempotent and safe on an already-exited child; `reap` is the only place a `ChildId` is consumed.
- The cooperative grace window is a runner constant (today 400 ms); a config surface is deferred until a consumer asks.

Lifecycle and misuse rules (part of the freeze, not implementation detail):
- `Supervisor` is **non-copyable** (`=copy` errored) — one owner per event-loop fd; an accidental value copy would mean two owners and a double-close. `=destroy` releases the loop and registry and **kills nothing** — outstanding children are the executor's to stop and reap; destroying with live children is a Defect in debug builds.
- `initSupervisor` **can fail** (epoll/self-pipe/completion-port creation; fd exhaustion is realistic at high `--jobs`) and raises a structural error — never a degraded half-loop. `initSupervisor(installSignals = false)`: when true, the Supervisor owns handler installation (`sigaction` | `SetConsoleCtrlHandler`) wired to its own wakeup; `shutdownRequested()` remains a thin view over the same state for library callers that opt out (RFC-0003's re-entry rule unchanged). This is the handler↔Supervisor seam — the process-global handler must reach a per-run Supervisor's pipe, and ownership is decided here, not discovered in A4.
- `ChildId` values are **monotonic and never reused** within a Supervisor's lifetime — a stale copy can never address a later child (the pid-reuse disease at one remove, closed by construction).
- `requestStop`/`forceKill`/`snapshotTree` on a **consumed** id: Defect (programming error), never a silent no-op. On a live child whose exit is already observed: the atomic no-op rule above.
- The **unkillable child** (SIGKILL'd but in uninterruptible D-state — NFS/fuse): `weChildExited` may never arrive, and crisol **never fabricates an `Exit`** — that fabrication is today's disease. The slot stays live, the run does not complete, and the condition is surfaced as a diagnostic; accepted as the honest behavior for a kernel-wedged process.

**Scope.** The contract manages the entrypoint **compile** and **run** children — the processes whose results crisol vouches for. Short-lived tool invocations via `std/osproc` (git, `ccprobe`/`nimprobe` probes, measure-mode `realCompileOnly`/cc/link in `compiledriver`, `gitdiff`, `icbaseline`, `measureworker`, `workerplan`) are **out of scope**: they carry no `Evidence` claims and join no kill domain. Each such import site is annotated `# process-contract-exempt`, and A3's grep test asserts the annotation, so the boundary is visible instead of accidental. Folding measure-mode into the contract is future work, deliberately not this RFC.

### 2. The result model

```nim
type
  ExitKind* = enum ekExited, ekSignaled, ekNtStatus
  Exit* = object                      ## LOSSLESS observation of how the child ended
    case kind*: ExitKind              ## — and nothing else
    of ekExited:   code*: int         ## WEXITSTATUS / Windows exit code < 0xC0000000
    of ekSignaled: sig*: int; coreDumped*: bool
    of ekNtStatus: status*: uint32    ## Windows crash (STATUS_ACCESS_VIOLATION …)
  ## symbol(e: Exit): string — "SIGSEGV" / "STATUS_STACK_OVERFLOW" — is a PROC over
  ## a table, serialized at render time; derived data is never stored (same rule as
  ## outcome). isSuccess(e) = e.kind == ekExited and e.code == 0.

  Rusage* = object                    ## accounting: a FOURTH axis, not part of Exit
    maxRssBytes*, userCpuUs*, sysCpuUs*: int64

  CauseBy* = enum cbProcess, cbRunner, cbLimit, cbExternal
  KillReason* = enum krTimeout, krInterrupt
    ## ONLY reasons with named producers exist. The wire is additive: enums
    ## serialize as strings and readers pass unknown values through, so future
    ## reasons (and B3's lkMemory) are cheap — dead values would be forever.
  ## LimitKind is defined in §1 — ONE vocabulary for the whole limit domain. The
  ## DETERMINISTIC subset a Cause may cite is the named constant
  ## DeterministicLimits = {lkCpu, lkFileSize} (B3 adds lkMemory WITH its
  ## producer, cgroup memory.events); citing any other kind in cbLimit is a bug
  ## by construction.
  Cause* = object                     ## AUTHORSHIP — from the runner's recorded acts
    case by*: CauseBy
    of cbProcess:  discard            ## ended on its own
    of cbRunner:   reason*: KillReason; escalated*: bool
    of cbLimit:    limit*: LimitKind  ## asserted ONLY when that limit was requested
                                      ## and achieved for this child
    of cbExternal: discard            ## a kill we did not send and cannot attribute

  KillDomainStrength* = enum kdsProcessGroup, kdsProcessGroupSubreaper, kdsCgroup, kdsJobObject
    ## a LABEL for the mechanism, never an ordered ladder: jobObject vs cgroup are
    ## incomparable cross-platform artifacts. Nothing may compare these by ord —
    ## the cache gate consumes named guarantees (§6), not enum positions.

  TreeObservation* = enum   ## OBSERVABILITY of the kill domain — one axis only
    toUnobservable   ## ord 0 = the WEAKEST claim (house rule: a default-
                     ## initialized evidence value must never encode a vouch).
                     ## This tier cannot see the whole domain (pgid-only: a
                     ## setsid escape is invisible) — an honest "cannot vouch".
                     ## A pgid-only tier may NEVER report toComplete: "every pid
                     ## I saw is gone" is vacuous when the scan cannot see.
    toComplete       ## the domain is fully observable at this tier (subreaper |
                     ## cgroup | jobObject) and every pid in it was seen to end.
  ## Survivors are NOT a third enum value: `escapees.len > 0` is the separate,
  ## orthogonal fact the cache gate reads (§6) — B1 can honestly report
  ## toComplete WITH escapees (observed, killed, reaped, counted) without the
  ## two axes fighting over one field.

  Evidence* = object                  ## what the runner can VOUCH for. The
                                      ## backend-observed fields are copied
                                      ## VERBATIM from ReapReport (reap's one-
                                      ## report promise); only `hermetic` is
                                      ## runner-authored.
    killDomain*: KillDomainStrength   ## per-spawn achieved (from ReapReport)
    tree*: TreeObservation
    escapees*: seq[ProcSnapshot]
    limits*: LimitsAchieved           ## per-limit (§1), replacing the aggregate bit
    hermetic*: HermeticLevel          ## the level this ran under. SandboxAchieved
                                      ## is DELETED (§5): env/tmpdir are achieved
                                      ## by construction (§1 ChildSpec), rlimits
                                      ## moved to `limits`, netIso was never wired
                                      ## — network stays asserted-not-enforced,
                                      ## so hlNetwork runs remain uncacheable
                                      ## until RFC-0008 observes (§6). An object
                                      ## of constants would be a dark mechanism.
    killSnapshot*: seq[ProcSnapshot]  ## tree at the first stop act (§1)
    cooperativeUnavailable*: bool     ## from ReapReport — without this bit
                                      ## `escalated` degrades into noise (§3)

  ProcessResult* = object             ## ONE shape for the compile and run phases
    exit*: Exit
    cause*: Cause
    evidence*: Evidence
    rusage*: Option[Rusage]           ## never serialized zero-filled as observation
    durationUs*: int64

  PhaseKind* = enum pkSkipped, pkSpawnFailed, pkRan, pkCached
  Phase* = object     ## illegal states unrepresentable — the house rule
    case kind*: PhaseKind             ## (types.nim's EntrypointDecision comment);
    of pkSkipped:      discard        ## no Option × Option × sentinel-string
    of pkSpawnFailed:  spawnError*: string  ## phase identity by construction
    of pkRan, pkCached: res*: ProcessResult ## pkCached = the STORED observation
                                      ## replayed on a cache hit — the derivation
                                      ## below is identical over both, which is what
                                      ## makes verdicts genuinely replayable.
                                      ## Compile-phase pkCached is representable but
                                      ## UNREACHABLE by construction (compile
                                      ## results are never independently cached);
                                      ## the derivation deliberately treats it as
                                      ## pkRan — the house rule's one bend, visible.

  EntrypointResult* = object
    ep*: Entrypoint
    compile*, run*: Phase
    records*, output*, outputTruncated*: …          # unchanged (output and its
                                      # truncation are entrypoint-level facts about
                                      # the shared sink, so they stay here — no
                                      # duplicate `outputComplete` in Evidence)
    attempts*, quarantined*: …        # attempts is an observation; quarantined
                                      # stays STORED because deriving it needs the
                                      # Config overlay, not the result — the one
                                      # deliberate exemption from the derived-field
                                      # rule, stated so the asymmetry reads as a
                                      # choice, not an accident
    # REMOVED: outcome (derived), exitCode, signal, achieved (→ evidence),
    #          peakRssBytes (→ rusage + ledger, §7), cached (≡ run.kind ==
    #          pkCached — a second copy of the Phase discriminator), flaky
    #          (derived: passed-under-POLICY with attempts > 1 — a stored bool
    #          over a policy-dependent quantity would contradict recomputation;
    #          `flaky(r, policy)` is a proc, the wire serializes it derived)

  Outcome* = enum oPassed, oFailed, oCrashed, oKilled, oCompileFailed, oSpawnError

type OutcomePolicy* = object          ## policy is a VALUE, not a positional bool
  strictHygiene*: bool                ## (`outcome(r, true)` — true *what?*); one
                                      ## field today, additive forever; the const
                                      ## DefaultPolicy = OutcomePolicy()

proc outcome*(r: EntrypointResult; policy = DefaultPolicy): Outcome =
  ## PURE over (result, policy). Serialized into run/v2 as ADVISORY for external
  ## consumers; recomputed at every crisol trust boundary (cache load, render,
  ## exit-code derivation). Total case expressions — every arm compiler-forced.
  ## NAMING DURING THE DUAL-WRITE WINDOW (A1a–A1e): this proc is born
  ## `deriveOutcome` — while the legacy `outcome` FIELD exists, `r.outcome`
  ## binds to the field, so a "migrated" consumer written against the proc
  ## would silently read stale data; A1e-i renames deriveOutcome → outcome
  ## (both the removal and the rename are compiler-enumerated).
  case r.compile.kind
  of pkSpawnFailed: return oSpawnError
  of pkRan, pkCached:
    let c = r.compile.res
    if c.cause.by == cbRunner and c.cause.reason == krInterrupt:
      return oKilled                  ## Ctrl-C mid-compile is not a compile failure
    if c.cause.by != cbProcess or not c.exit.isSuccess:
      return oCompileFailed           ## incl. compile timeout — the cause is
                                      ## consulted, so a cooperative exit-0 inside a
                                      ## compile-kill grace window cannot masquerade
                                      ## as a good compile
  of pkSkipped: discard               ## fresh — nothing to prove
  case r.run.kind
  of pkSpawnFailed: oSpawnError
  of pkSkipped:     oSpawnError       ## unreachable in any EMITTED result: a good
                                      ## compile is always followed by a run phase,
                                      ## and interrupt emission OMITS entries whose
                                      ## next phase never started (§2 interrupt
                                      ## bullet — there is no representable "run
                                      ## never started" lie); derives loudly
                                      ## rather than lying quietly
  of pkRan, pkCached:
    let p = r.run.res
    if p.cause.by == cbRunner:  oKilled
    elif p.exit.kind != ekExited: oCrashed   ## signaled/ntstatus; cause may be
                                             ## limit or external
    elif p.exit.code == 0 and not r.hasFailRecords:
      if policy.strictHygiene and p.evidence.escapees.len > 0: oFailed
      else: oPassed
    else: oFailed

proc classifyCause*(exit: Exit;
                    stop: Option[tuple[reason: KillReason, escalated: bool]];
                    limits: Limits; achieved: LimitsAchieved): Cause
  ## The SECOND pure function — the authorship/heuristic bullets below AS CODE,
  ## with one home: defined in A1a, table-tested beside `outcome` with the
  ## documented misattributions pinned as cases, never re-smeared inline into
  ## the executor. The requested-AND-achieved join for cbLimit lives here, once.

proc hasFailRecords*(r: EntrypointResult): bool
  ## true iff any PARSED protocol record is a failure. A truncated/corrupt
  ## stream NEVER fabricates a failure (the reader stays conservative —
  ## RFC-0001's contract); precedence is unchanged: runner-authored kills and
  ## non-zero exits dominate records, so protocol.reconcile's executor-
  ## precedence rule is subsumed by the derivation above.
```

Consequences stated plainly:
- **Authorship has ONE owner: the Supervisor's act ledger.** The precise rule: `cbRunner` iff `ReapReport.stop.isSome` — a stop act was recorded before *the backend* observed the exit; `requestStop`/`forceKill` record atomically against exit observation (§1), so "before an exit was observed" is by-the-backend, well-defined, and checked inside the call rather than reconstructed from executor bookkeeping. This makes cooperative termination attributable — a child that traps SIGTERM and exits 0 inside the grace window is `cbRunner(timeout, escalated: false)` ⇒ `oKilled`, *not* a pass; without this rule, any test with a SIGTERM handler could convert a timeout into a reported pass, a soundness hole in the load-bearing property itself. The residual race shrinks to the true kernel window — the signal already in flight when the exit lands — misattributing in one direction only (a genuine finish reported as killed), documented as accepted; `next` draining ready exits before `weDeadline` (§1) is the spec-level narrowing, and nobody may later claim the window is closed.
- **Signals we did not send are classified, and the classification is a documented heuristic, not knowledge.** Default-disposition crash signals (SIGSEGV, SIGABRT, SIGFPE, …) ⇒ `cbProcess`; a SIGKILL we did not send ⇒ `cbExternal` (OOM killer, operator, unknown — we say so); `SIGXCPU`/`SIGXFSZ` ⇒ `cbLimit` **only when the runner actually requested and achieved that limit for this child**, else `cbExternal`. Known misattributions (an operator's `kill -SEGV` reads as `cbProcess`; an external SIGTERM inside our grace window reads as `cbRunner`) are stated here rather than dressed as certainty. All of this is `classifyCause` — one proc, one table test.
- **The Windows exit partition is the same kind of documented heuristic.** `ekExited` vs `ekNtStatus` splits at `0xC0000000` — classification, not knowledge (a child can `ExitProcess(0xC0000005)`); the runner-chosen `TerminateJobObject` code lands in the `ekExited` range, and a genuine exit of the same code is disambiguated by `Cause`, not by the code — stated with the same honesty as the signal heuristic.
- **Unknown enum values: tolerance is for non-deriving consumers only.** External JSON readers pass unknown strings through. crisol's OWN typed readers (`resultjson` feeding the cache and 0005 `StoredEntry`s) must inhabit Nim enums to run the total derivation: an unparseable `cause`/`exit`/`evidence` enum is a STRUCTURAL parse failure ⇒ cache miss, entry unusable, rerun — never a default-valued lie. (This is the oracle A1a's fuzz test asserts.)
- **The sink is read on every run end.** Killed/signaled ends parse the sink best-effort like any other end (today the signaled path skips reconciliation entirely — the Motivation's "records go missing on a timeout" is partly self-inflicted); for killed/non-`ekExited` ends the records are diagnostic only and never affect the verdict (precedence unchanged — `hasFailRecords` above).
- **`RLIMIT_AS` failures are not a `Cause`.** Under rlimits the kernel does not tell us, and RSS-vs-address-space comparisons are wrong-dimensioned (ORC reserves large VA with small RSS) — no near-limit heuristic is dressed as fact. The cgroup tier is different: `memory.max` + `memory.events::oom_kill` is deterministic kernel testimony, so **B3 adds `lkMemory`, asserted iff `memory.max` was applied and `oom_kill > 0`** — observation, not pattern-matching. B3 also documents that the same over-limit test *changes failure mode* between tiers (ENOMEM under `RLIMIT_AS`, SIGKILL under `memory.max`) and reports which mechanism applied.
- **Replayable verdicts.** The cache (RFC-0004 `CachedResult`, RFC-0005 `StoredEntry`) stores the run `ProcessResult` + records; a hit replays it as `run = Phase(kind: pkCached, res: stored)` and `outcome` is recomputed — the derivation is identical over `pkRan`/`pkCached`, so if derivation rules change, stored observations yield new verdicts without rerunning. The cache always stores the observation and derives **unstrict**; `--strict-hygiene` is a policy input at the call sites (runner, summarize). Two rules close the traps this opens: (i) **pass-only store carries forward** — today's gate stores only `oPassed` results, and this RFC does not change that; (ii) at read time, **a hit whose recomputed outcome is not `oPassed` is treated as a miss and rerun** — a derivation or policy change must never serve a fail from cache forever with no rerun path. And honesty about today: since escapee-bearing entries are uncacheable (§6), no *currently storable* entry can flip under the one policy that exists — the mechanism buys future policy divergence, not present behavior, said out loud rather than dressed as a live feature.
- **Compile and run share one shape.** A compile timeout is `compile.cause = runner(timeout)` ⇒ `oCompileFailed`; a compile interrupted by Ctrl-C is `runner(interrupt)` ⇒ `oKilled` — it never pollutes compile-failure counts, failed-first ordering, or flaky history.
- **Interrupt produces partial results — fully specified.** Ctrl-C stops being a results-shredder: in-flight slots are stopped through the same requestStop/grace/forceKill machinery as timeouts, their results carry `run.cause = runner(interrupt)` (⇒ `oKilled`), completed results are kept, and `run/v2` **is emitted** with a top-level `interrupted: true` marker — a partial run must be distinguishable from a complete one *on the wire*. The **emission set**: an entry appears iff its last-started phase is `pkRan`/`pkCached`/`pkSpawnFailed`; entries whose next phase never started (queued, or compile-done-run-unstarted) are *omitted* and counted in `summary.notStarted` — there is no representable "run never started" state and no lie to fill it with. Interrupt-killed results **never enter the ledger** — a test that merely happened to be in flight at Ctrl-C must not become "flaky", gain failed-first priority, or skew shard/perf medians; the ledger row would be indistinguishable noise. **`lastrun.json` is not persisted on interrupt** — invariant: an entrypoint that was never observed must never silently leave the `--failed` selection, so the last *complete* run stays the anchor (resuming an interrupted run via `--failed` is deliberately not a feature). stdout JSON and junit are emitted; the process exit stays RFC-0003's `128+n`. Library facade: `CrisolInterrupted` is **retired** — `execute()` returns normally with `RunReport.interrupted: Option[ShutdownSignal]` set, `results`/`summary` populated with the emission set, and `onResult` fired for interrupt-killed finals like any other completion. This amends RFC-0003's "results and summary are empty on interrupt" — the empty report was an artifact of teardown discarding observations, which is exactly the disease this RFC treats. (§Contract impacts.)
- **Retry/flakiness is preserved under the mapping** `oTimeout → oKilled(krTimeout)`, `oSignal → oCrashed`: retry eligibility is unchanged in semantics; `runner(interrupt)` results are never retried. When `attempts > 1`, `compile`/`run` carry the **final** attempt's phases (per-attempt rows remain in the ledger); `attempts`/`quarantined` and the rev-2/rev-3 wire fields (`cacheDecision`, `flaky` — both serialized derived now) carry into `run/v2`; the cache's attempt-1-only `shouldStore` gate is untouched. One asymmetry the new model makes visible and deliberately does not change: an externally-killed *compile* (`cbExternal`, e.g. OOM) derives `oCompileFailed` and is never retried, while the identical kill in the run phase (`oCrashed`) is retry-eligible — expanding compile retry is out of scope, recorded here so it reads as a choice, not an oversight.
- **`Summary` reshapes with the enum — as a derived array, not renamed fields**: `counts: array[Outcome, int]` (plus `flaky`/`quarantined`/`noTestsRan`/`notStarted`) replaces the hand-maintained counters; `exitCode(s: Summary)` folds `isFailure` over the array (the pattern `outcomestrings` already demonstrates), so a future `Outcome` value costs zero Summary edits; `run/v2`'s `summary` node serializes explicit names (`killed`, `crashed`, …) from the array.
- **Ledger history stays classified.** Persisted rows store outcome strings; `isFailureOutcomeString` continues to classify the legacy `"timedOut"`/`"signaled"` strings alongside `"killed"`/`"crashed"` so failed-first ordering and flaky detection do not silently forget exactly the entrypoints that were misbehaving. No ledger version bump.

### 3. Kill domains, termination protocol, supervision

| Platform | Domain | Strength | Cooperative → forced | Wait |
|---|---|---|---|---|
| Linux | pgid; crisol sets `PR_SET_CHILD_SUBREAPER` so orphans at any depth reparent to crisol and are reaped + counted; per-slot cgroup v2 leaf via `clone3(CLONE_INTO_CGROUP)` when delegated (`cgroup.kill` is atomic and airtight; `memory.peak`/`memory.max` give tree accounting and a real `RLIMIT_AS` replacement) | `cgroup` / `processGroup+subreaper` | SIGTERM → SIGKILL | pidfd + poll/epoll (≥ 5.3), 25 ms poll fallback |
| macOS | pgid; escapees via libproc lineage scan at kill/reap — structurally blind to a setsid'd, reparented daemon, so `tree = toUnobservable` on that tier, never a false `toComplete` | `processGroup` | SIGTERM → SIGKILL | kqueue `EVFILT_PROC NOTE_EXIT` |
| Windows | Job Object, `KILL_ON_JOB_CLOSE`, breakaway disabled, nested-job-safe; `ACTIVE_PROCESS_ZERO` tells us when the whole tree is gone | `jobObject` | `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)` → `TerminateJobObject(runner code)` — **contingent on console topology**: delivery requires the child attached to a console and `CREATE_NEW_PROCESS_GROUP`; a detached/GUI/`FreeConsole`d child never receives it, and a console-less crisol cannot send it. Deliverability is probed (§4) and recorded per-result (`evidence.cooperativeUnavailable`) so `escalated` stays meaningful instead of degrading to always-true noise | completion port / `WaitForMultipleObjects` (small-N fallback; 64-handle cap) |

- The backend takes `snapshotTree` at the **first stop act** and refreshes it at forced kill (§1), storing it in `Evidence.killSnapshot`. A timeout stops being "it hung" and becomes "blocked in a 400 MB `nim c` grandchild" — including in the common case where the child dies cooperatively inside the grace window and no forced kill ever happens.
- `killpg` is pid-reuse-safe while the group lives (the pgid holds the pid); pidfd is adopted for the event loop, not as a correctness fix. The 25 ms poll was never a correctness flaw for *waiting* — though its timeout branch is where today's status fabrication lives, which A1b fixes independently of the event loop. Event-driven wait is adopted because Windows' natural API *is* event-driven and one "wait for the next event before `deadline`" primitive is a cleaner contract than three polls; it narrows (not closes) the authorship race window of §2.
- `clone3` is preferred on Linux because `fork` + write-pid-to-`cgroup.procs` has a window where the child exists outside its cgroup; `CLONE_INTO_CGROUP` closes it. The child path stays async-signal-safe in both.
- **Subreaper mechanics (B1) are specified, not assumed.** Adopted orphans have no pidfd and are not in the spawn registry, so the event loop pairs the pidfd set with SIGCHLD + a `waitid(P_ALL, WNOWAIT)` sweep: peek, read `/proc/<pid>/stat` for pgid while the zombie still exists (attribution to a slot's domain), then reap — a naive `waitpid(-1)` loop cannot attribute. *Live* escapees (a still-running setsid daemon) have left the pgid, so the only safe kill handle is `pidfd_open` on the snapshot pid plus a `/proc/<pid>/stat` starttime identity check before the kill — killing by raw snapshot pid is exactly the pid-reuse race the pgid design avoids elsewhere. An adopted orphan that dies *after* its owning slot's result was reaped and emitted is counted and logged at run level, never retro-fitted into an emitted result — the owning result already carried its escapees, so no cached entry goes stale.

### 4. Capabilities: probed once, degraded, reported

`capabilities()` runs at startup (like `ccprobe`/`nimprobe`), is memoised, and is rendered in `run/v2` under `substrate` and in `plan/v1`. Probes are **per-mechanism-file, not per-feature-family**: pidfd; subreaper; cgroup v2 delegation (`mkdir` a leaf + write `cgroup.procs`) *and separately* `cgroup.kill` (≥ 5.14) *and* `memory.peak` (≥ 5.19) — a delegated 5.15 LTS host must probe green for delegation and red for the files it lacks, not fail per-file at spawn time; kqueue; Job Object nesting; CTRL_BREAK deliverability (console topology); `flock`; `wait4` rusage. C1/D1 extend the probe set and the `substrate` rendering for their platforms — a macOS/Windows `substrate` node is that platform's, never a Linux-shaped placeholder. Each guarantee the substrate cannot deliver on this host becomes a degraded `Evidence` field on every result — never an assumption, never a silent drop. The probe gates *attempts*; `Evidence.killDomain` reports the **per-spawn achieved** domain, because a leaf can fail to materialize after a green probe. **Nothing in this RFC is *required* to be present**; the dev loop (rootless podman: no cgroup delegation, no user-ns) runs the `processGroup+subreaper` tier and says so.

The `Capabilities` shape is itself wire (`run/v2.substrate`, `plan/v1`) and is sketched now, not discovered at A7: a flat object of per-mechanism booleans — `pidfd`, `subreaper`, `cgroupDelegation`, `cgroupKill`, `memoryPeak`, `kqueue`, `jobObjectNesting`, `ctrlBreakDeliverable`, `flock`, `wait4Rusage` — with platform-inapplicable fields simply **absent** from the serialized node (the enums-as-strings/unknown-tolerant rules apply; a macOS node carries `kqueue`, never greyed-out cgroup fields).

### 5. Hermeticity mechanisms (RFC-0004 F2, restated under the contract)

rlimits remain the floor, mapped through `Limits` — the single home; `SandboxSpec` sheds its rlimit fields, its env/tmpdir/cwd content is resolved by the runner into `ChildSpec.env`/`cwd` before spawn (achieved-by-construction; the child-side status pipe shrinks to per-limit readback), and **`SandboxAchieved` is deleted outright** — every field is obsolete (`rlimitsApplied` → `LimitsAchieved`; env/tmpdir true by construction; `netIso` never wired and never-goal), and `Evidence.hermetic` carries the level (§2). The re-homing changes the SoundnessKey's fold-input shape (`keys.nim` serializes the config-declared rlimits): deliberate, and free — the `resultCacheFormatVersion` bump discards all entries anyway (A2a-iii names `keys.nim`). Linux adds cgroup `memory.max` in place of `RLIMIT_AS` when delegated (the mechanism used is reported). Windows maps `Limits` to Job basic/extended limits; `openFiles` has no analog and is reported `lsUnsupported`. **No network enforcement anywhere** — see §Non-goals. **No mount/user namespaces** — deferred; `TMPDIR` injection plus RFC-0008's observed inputs cover the soundness case without a second isolation mechanism.

### 6. Escapee policy

The verdict is never changed by hygiene — crisol does not judge test semantics. The cache gate consumes **named guarantees**, not enum ordinals: `evidenceSatisfies(spec, ev)` asks "were escapees observed?", "was the tree observable at this tier?", "were the requested limits achieved?" — never `killDomain >= kdsX`. The rules (observability and survivors are separate axes — §2 `TreeObservation`):
- `escapees.len > 0` ⇒ **uncacheable** (RFC-0004's not-fully-achieved rule — leaked side effects already happened, even where the escapees were then reaped), a first-class warning in render and `run/v2`; on Linux-with-subreaper the escapees are additionally *reaped* (B1: `tree = toComplete` AND uncacheable — the axes do not fight).
- `tree == toUnobservable` (escapees empty) ⇒ **cacheable, with the tier recorded** in `Evidence` (and thus in the 0005 `StoredEntry`, whose trust layer can filter on it later). This preserves today's de-facto behavior — pgid-only Linux caches results it cannot fully police — while replacing the false vouch (`treeReaped: true` fabricated on a blind tier) with the honest label. Refusing to cache on unobservable tiers was rejected: it would kill caching on exactly the tiers crisol is developed on, for no soundness gain over labeling.
- Per-limit statuses follow the same posture: `lsFailed` ⇒ **uncacheable** (the mechanism exists here and broke — the same class as an observed escapee); `lsUnsupported` ⇒ **cacheable, with the label** (the tier cannot — the same class as `toUnobservable`; a Windows config requesting `openFiles` must not permanently kill caching there); `lsNotRequested` is vacuous. This weakens "requested limits were achieved" to "…or were impossible on this tier, and the entry says so" — deliberate, consistent with the `toUnobservable` precedent, filterable by the 0005 trust layer.
- `hlNetwork` runs remain **uncacheable** until RFC-0008's observer exists — network independence is asserted, never observed or enforced (§5); caching on a bare assertion is the one thing the gate must not do. (Today's behavior, preserved explicitly.)
- `--strict-hygiene` opts into `oFailed` for would-be passes with observed escapees (a policy input to `outcome`, §2; the cache stores unstrict).
Rejected: fail-by-default (pgid-only macOS would be flakier than Linux for the same suite); report-only (the cache would trust a leaked environment); a third `TreeObservation` value for escapees (conflates two axes and makes B1's honest "complete, with reaped escapees" unrepresentable).

### 7. Everything else the port touches

- **`ioutils` becomes the sole owner of raw file primitives** — `exclusiveCreate`, `appendOpen`, `atomicPublish` (`rename` / `MoveFileEx(REPLACE_EXISTING)`), `writeAllFd`. `depgraph`, `jsonout`, `ledger`, `shardedledger`, and `crisol.nim`'s init writer stop hand-rolling `posix.open`.
- **Single-run lock: `flock(LOCK_EX|LOCK_NB)` on POSIX, `LockFileEx` on Windows.** RFC-0001 chose `fcntl F_SETLK` only because `flock` was missing from `std/posix` (a one-line `importc`). `flock` is per-open-file-description, so the classic fcntl hazard (any close of the path by this process drops the lock) disappears.
- **Signals:** `sigaction` flag on POSIX, `SetConsoleCtrlHandler` on Windows, behind `shutdownRequested(): Option[ShutdownSignal]` — the signal *identity* survives, because RFC-0003's `128+n` needs `n`, and the Supervisor's `weShutdown` event carries the same value.
- **Rusage is a new quantity, not a replacement.** `wait4`'s `ru_maxrss` is a per-process max (folded over reaped descendants), while `memprobe.procGroupRssBytes` — the value admission estimates and the ledger's `rssBytes` consume today — is a *simultaneous tree sum*. They are different quantities, and for exactly the workloads admission exists for (`nim c` + cc children) the per-process max undercounts. So: the sampled group-sum **remains** the ledger/admission quantity; `wait4` maxRss lands in `ProcessResult.rusage` and a new, mechanism-tagged ledger column; the cgroup tier's `memory.peak` (a true tree peak, B3) is what eventually supersedes sampling, explicitly and tagged, never silently. Sampling itself routes through the contract — `groupRssBytes(sv, id)` (§1), whose posix implementation *is* today's memprobe pgid scan re-homed — because the executor no longer holds a `Pid` to hand memprobe (A2b owns the rewiring; RFC-0002's quantity and cadence are unchanged — §Contract impacts).

## Non-goals

- **Network enforcement**, on any platform. `hlNetwork` remains "network-independence asserted": unachieved-and-reported until RFC-0008's observer exists; macOS Seatbelt (`sandbox_init`, deprecated) and Linux `CLONE_NEWNET` are *not* adopted — enforcement belongs to the CI container, crisol observes.
- **Observed inputs** (files, network, randomness, exec) — RFC-0008. Depends on `Evidence` and the event loop from this RFC.
- **Path identity** (`ProjectPath`, case-folding, drive letters) — RFC-0009. Stage D is conformance-green on Windows only once 0009 lands; Stage D slices do not pretend otherwise.
- Sub-binary control; mount/user namespaces; posix_spawn (cannot set rlimits, needs child-side code for achieved readback); a config surface for the grace window; folding osproc tool invocations into the contract.

## Alternatives considered

- **Additive-only result schema** — keep `oTimeout`/`oSignal`/`signal` and add beside them. Rejected: pre-v1, all consumers owned, and carrying two names for one thing forever is the cruft the ideal does not have; `oSignal` would remain a lie on Windows.
- **Stateless free-function contract** (`wait(handles, deadline)`, blocking `terminate(h, graceMs)`) — the shape of a first draft of this RFC. Rejected: a free `wait` has nowhere to keep an epoll set, a kqueue fd, or a completion port (all require registration state that outlives one call), so every backend except today's Linux poll loop would smuggle module-global state — the N=1 freeze in person; and a blocking per-handle grace serializes interrupt teardown (N × 400 ms) where today's drain is concurrent, while splitting the result across `TerminateReport` + `ProcessResult` for the runner to merge. The `Supervisor` owns the loop; grace is an executor deadline; `reap` returns one complete report.
- **`include`-based backend selection** — rejected: the "contract" degrades to doc comments above a `when`/`include` block, verified by nothing, and backends cannot be `nim check`ed per platform from Linux CI — the exact dark-code failure mode this RFC is trying to retire.
- **Executor as commodity** — seam refactor for portability, stop there. Rejected: leaves `Cause` conflated and kill-domain unreported, so the cache gate trusts results it cannot vouch for.
- **Mechanism-maximal** — require namespaces/cgroups/pidfd. Rejected: degrades silently in the environment crisol is developed in.
- **Keep polling forever** — viable (not a correctness flaw) but three polls vs one event contract; Windows would be the odd one out.
- **`sandbox_init` on macOS** — deprecated, no supported replacement for arbitrary children; and we do not want enforcement from crisol at all.
- **Uncacheable-when-unobservable** (strict tree gate) — rejected in §6: labels beat refusals when the tier simply cannot see.

## Stages & slices

Dependency-correct order: **A0 → A1a…A1f → A2a-i/ii/iii → A2d → A2b → A2c → A3…A7 (+ A7-gate)** — the cross-platform spike (A2d) runs *before* the runner consumes the contract (A2b), so signature fixes land against shims, not against a fresh rewrite. **Stage A precedes the RFC-0005 build.** Stages B–D are independent of 0005 and may interleave with it. The A1 ladder exists because the field *removal* is whole-program-atomic in Nim — no single agent can hold the full blast radius (11 `src/` modules read `.outcome`; ~52 test files pin old fields/strings — measured), so production happens additively and removal is one compiler-enumerated sweep.

**Fixture inventory (build before the slices that consume them):** `hang_forever` (exists; dies on SIGTERM — the *honest* A1 expectation); `crash_segv` (deliberate SIGSEGV; `coreDumped` is pinned **false** on the default path — `RLIMIT_CORE=0` under the default sandbox — and documented tier-dependent, never asserted true anywhere); `self_sigkill` (sends itself SIGKILL — `cbExternal`); `term_cooperative` (traps SIGTERM, exits 0 within grace — `cbRunner`, `oKilled`, *not* a pass); `term_ignores` (ignores SIGTERM — `escalated: true`, SIGKILL); `spawn_grandchild` (leaks a same-pgroup grandchild and exits 0 — the OBSERVABLE escapee a pgid scan can actually see: A6a/A6b's driver); `spawn_grandchild_setsid` (daemonizes via setsid — INVISIBLE to a pgid scan by construction, the same blindness §3 documents for macOS: it pins the honest `toUnobservable` label at A6a and flips to observed-and-reaped at B1); `pass_fast` (writes a completion marker file — the SIGINT E2E's synchronization point); `cpu_burn` for `SIGXCPU` (exists as `rlimit_cpu`); `fsize_overrun` (exists; consumed by A1f's `lkFileSize` cases). Windows variants (Stage D): an access-violation crasher (**D1a** — the `ekNtStatus` producer proof), a CTRL_BREAK-handler fixture, a Job-breakaway attempt, and a `DETACHED_PROCESS`/`FreeConsole` fixture (**D1b** — the only producer of `cooperativeUnavailable: true`). Grace-window fixtures are timing tests: they run under the same serial gating as `CRISOL_TIMING_TESTS`.

**Interim evidence population (the honest defaults per rung — no agent invents, nothing fabricates):** until A2a-iii, `limits` fans today's aggregate `rlimitsApplied` bit uniformly over the *requested* kinds (unrequested = `lsNotRequested`); until A6a, `tree = toUnobservable` and `escapees`/`killSnapshot` empty; until A7, `killDomain = kdsProcessGroup` (the actual mechanism today, not a placeholder). Every default is the WEAKEST claim (the ord-0 rule, §2) — a result serialized or cached in any window never vouches for more than its rung can see. A1f's `cbLimit` precondition consequently runs on the aggregate approximation until A2a-iii re-pins it per-limit.

**Stage A0 — CI baseline (first; everything after runs under it):**
- [x] **A0 — Linux CI + honest exit codes.** ✅ 4b16d32+d836fb0, CI run 33659482378 (meta step, full leg, serial timing leg all green).  A Linux workflow running the existing suite with REAL exit-code propagation (the `./dev test` grep trap is the known hazard), verified by a **named mechanism**: a meta-test step runs the harness over a committed deliberately-failing dummy and asserts a nonzero exit reaches the workflow step, then skips the dummy in the real leg. A second, SERIAL job runs with `CRISOL_TIMING_TESTS=1` so timing/grace conformance is never dark in CI. *This repo has no CI today; the riskiest surgery in this RFC must not run before this exists.*

**Stage A — result model, contract, seam (Linux; highest architect scrutiny):**
- [x] **A1a — types + derivation + serde (no consumers).** ✅ 3fb7b2d, CI 33663693135.  `Exit`/`Rusage`/`Cause`/`Evidence`/`ProcessResult`/`Phase`/`OutcomePolicy` types; `symbol`/`isSuccess`/`hasFailRecords` helpers; `deriveOutcome(r, policy)` (named so the legacy `outcome` FIELD cannot shadow it during the window — §2) with an exhaustive derivation-table unit test (every `PhaseKind × cause × exit` cell); `classifyCause` with its own table test (documented misattributions pinned as cases); `resultjson.nim` as the ONE owner of `ProcessResult`⇄JSON both directions (enums as strings; unknown-tolerant pass-through for external readers, STRUCTURAL failure ⇒ cache miss for crisol's own — the fuzz test's oracle; roundtrip test) — used later by run/v2, resultcache, and the 0005 `StoredEntry` so the format exists once, not three times. Window rule: `Outcome` carries BOTH value sets (`oTimeout`/`oSignal` legacy + `oKilled`/`oCrashed` new) until A1e-i; `outcomeString`/`isFailure`/the Summary case stay total over the union. Nothing consumes yet. *Depends on:* A0.
- [x] **A1b — the honest producer (load-bearing).** ✅ fd99d45+a23b757, CI 33669237828.  Rework the live kill path: `killAndReap`/`reapBlocking` capture and return the reaped `wstatus` (as `Exit`) + the stop record; `teardownLiveSlots`' three waitpid sites capture too (observations recorded even where not yet emitted — attribution/emission is A1e-ii); `waitpid` → `wait4` at the reap sites (`rusage` populated from day one, never zero-filled; `wait4` needs an `importc` + rusage FFI struct — precedent: `spawn.nim`'s RLIMIT importcs); `pollSlot` stamps `Cause` via `classifyCause` from the recorded acts; the sink is read on every run end (§2). Runner **dual-writes** the new `compile`/`run` phases alongside the legacy fields, with a dual-write COHERENCE check (debug-gated postcondition or test helper asserting legacy and new fields agree under the documented mapping, exercised across the whole existing suite; deleted in A1e-i — without it, a regression in the new fields hides behind green legacy assertions). `jsonout` additively emits advisory `exit`/`cause` nodes into `run/v1` (rev bump; readers unknown-tolerant) so the property is on the real wire from this slice. **E2E (through `crisol run --json`):** `hang_forever` ⇒ legacy `outcome:"timedOut"` still present AND `cause:{by:"runner",reason:"timeout",escalated:false}`, `exit.kind:"signaled"`, symbol `SIGTERM`; `term_ignores` ⇒ `escalated:true`, symbol `SIGKILL`; `pass_always` ⇒ `exit.code:0`. (`spawn.supervise` deletion moves to A2a-i — five integration harnesses still call it and migrate there once, not twice.)
- [x] **A1c — consumers I (in-process).** `render`, `crisol.nim`, `order`, `junit` (`oKilled`/`oCrashed` → `<error>` with cause), `protocol.nim` (`reconcile` shrinks to a records-only predicate feeding `hasFailRecords`; the executor-precedence rule is subsumed by the derivation — §2), `api.nim` facade with the re-export set ENUMERATED (`Outcome`, `Phase`/`PhaseKind`, `ProcessResult`, `Exit`/`ExitKind`, `Cause`/`CauseBy`/`KillReason`, `Evidence`/`TreeObservation`, `Rusage`, `LimitsAchieved`, `OutcomePolicy`) plus two digest helpers so consumers don't hand-roll the same case expression (`runResult(r): Option[ProcessResult]` absorbing the variant check; `failureLine(r): string` for render-grade one-liners), `runner.isQuarantined`, retry-eligibility mapping, `Summary` reshaped to the derived `counts` array — ADDITIVELY: legacy `timedOut`/`signaled` counters dual-counted until A1e-i, because `jsonout` still reads them until A1d-i. All consumers read `deriveOutcome`. ✅ d65b64c; CI 33675878742 green.
- [x] **A1d-i — the wire.** `jsonout`: `run/v1` → **`crisol/run/v2`**, with a COMPLETE v1→v2 field-mapping table produced in the slice (kept / renamed / derived-now / dropped, for every v1 field): `exit`, `cause`, `evidence`, advisory `outcome` string, reshaped `summary` (+`notStarted`), top-level `interrupted`; **no `substrate` key until A7** — absence is the honest placeholder, its A7 appearance is additive; `cacheDecision` carried (the field's real name — not `cacheMode`), `flaky` serialized derived, `inputHash`/per-phase `durationUs` dispositioned in the table; the top-level compile-telemetry object renames to `compileStats` (the name `compile` now belongs to the per-entrypoint phase node); rev-integer scheme carried over, continuing v1's counter (RFC-0008 extends v2, not v3 it). `planview`/`loadLastRun` (v1 read as cold-start); the 7 `run/v1`-pinning test files migrate here. ✅ 7a89f7e; CI 33682085174 green.
- [x] **A1d-ii — cache replay.** `resultcache` stores `ProcessResult` + records via `resultjson`; hits replay as `pkCached` and recompute outcome — the hit-path E2E pins that the replayed run/v2 entry carries `cause`, `evidence.tree`, and `rusage` BYTE-EQUAL to the stored observation (fields the legacy shim cannot fabricate), not merely the outcome string; recomputed-not-`oPassed` hits are treated as misses and rerun (§2); pass-only store carried forward; `cachedispatch`; `outcomestrings` with the ledger legacy-string compat rule; `shard`. ✅ a3ccf20; CI 33688311952 green.
- [x] **A1e-i — removal.** Delete the `outcome`/`exitCode`/`signal`/`achieved`/`peakRssBytes`/`cached`/`flaky` fields, the legacy `Outcome` values, the legacy Summary counters, the dual-write and its coherence check; rename `deriveOutcome` → `outcome`; let the compiler enumerate stragglers (the rename too); migrate the ~52 pinning test files via a SANCTIONED scripted sweep (sed pass + compiler loop, not hand-editing); grep-test asserts the old names are gone from `src/`. ✅ b832ace; CI 33695334162 green.
- [x] **A1e-ii — interrupt partial results.** Teardown routes through capture-and-record → `krInterrupt` attribution and §2's emission rules (emission set, `interrupted` marker, `notStarted`, NO ledger rows, NO `lastrun.json` persist); `api.nim` reworked (`CrisolInterrupted` retired; `RunReport.interrupted`; `onResult` fires for killed finals) and `crisol.nim`'s early-return branch reworked (both discard points die — each could silently regress alone). **SIGINT E2E (serial, timing-gated):** run `crisol run --json` as a child, jobs≥2, over {`pass_fast` (marker file), `hang_forever`}; wait for the marker, SIGINT the process; assert exit 130, stdout parses as run/v2 with `interrupted:true`, the `pass_fast` entry `outcome:"passed"`, the `hang_forever` entry `cause:{by:"runner",reason:"interrupt"}`, `summary.killed ≥ 1` ∧ `summary.passed ≥ 1`, and no ledger rows for the killed entry. A second case pins SIGTERM ⇒ 143. ✅ db5ee39; CI 33701282507 green.
- [x] **A1f — authorship breadth.** `crash_segv` ⇒ `oCrashed`/`cbProcess`/symbol `SIGSEGV` (+ `coreDumped` observed honestly: pinned false only where `/proc/sys/kernel/core_pattern` is not a pipe handler — pipe-based handlers such as systemd-coredump set WCOREDUMP despite `RLIMIT_CORE=0`, core(5); amended from "pinned false on the default path" per A1f empirical finding); `self_sigkill` ⇒ `oCrashed`/`cbExternal`; `term_cooperative` ⇒ `oKilled`/`cbRunner`/`escalated:false` with `exit.kind:"exited"`, `code:0` (the soundness case); `SIGXCPU` ⇒ `cbLimit(lkCpu)` *only with the limit requested*, else `cbExternal` (both tested); `fsize_overrun` ⇒ the same requested/unrequested pair for `lkFileSize`; compile-interrupt ⇒ `oKilled`. Render shows cause + escalation. Tested through `execute()` and the CLI. (Precondition runs on the aggregate approximation until A2a-iii — see the interim table.) ✅ 43ddfe1; CI 33705238209 green.
- [x] **A2a-i — the backend, extracted.** `process/types.nim`, `process/posixcore.nim` (shared machinery over `PosixCore` — §1 sharing mechanism), `process/posix.nim` (`Supervisor`, `ChildId`, the full §1 surface incl. `groupRssBytes`; shutdown wakeup integrated into `next` per the §1 lifecycle rules), **`process.nim` selection ladder + shell `process/linux.nim`** (`import posix; export posix`) so §1's ladder is real from day one and B1–B3 have a home; `spawn.nim` folded in and `spawn.supervise` DELETED here; the 5 spawn-importing integration tests migrate once (`test_scratch_tmpdir`, `test_env_scrub_integration`, `test_rlimits_safe`, `test_rlimits_timing`, `test_sandbox_achieved`); `test_pgroup` (raw `std/posix` mechanism spike) is rewritten as a conformance case. Runner untouched (imports shims). (`test_signal`/`test_m6_teardown` exercise runner-level teardown and migrate at A2b, not here.) ✅ 60adb90; CI 33709442688 green.
- [x] **A2a-ii — the conformance suite.** `tests/conformance/` (spawn/exit, timeout kill, cooperative vs escalated, shared grace window, output caps, achieved readback, spawn error, level-triggered re-report, **shutdown wakeup**: a signal delivered while blocked in `next` returns `weShutdown` well before the deadline) — importing **`process.nim`**, never a backend directly, so every later backend lands under the same suite automatically; wired into `./dev test` and the A0 workflow (timing cases in the serial leg). Honest note: until A2b the product runner does not execute the Supervisor — bounded, and stated, not implied green. ✅ 4593c74; CI 33711499981 green.
- [x] **A2a-iii — the Limits re-home.** `SandboxSpec` sheds rlimits into the single `Limits` home (`core` included; the §1 enum-indexed shape); **`SandboxAchieved` deleted** (§5); per-limit `LimitsAchieved` from the existing readback, loop-driven over `LimitKind` (no five copied stanzas); `keys.nim` consumes the new home — the SoundnessKey fold-input change is deliberate and free under the format bump (§5); `config.nim`/`api.nim` rlimit plumbing follows the shape. ✅ e56da9c; CI 33714820056 green.
- [x] **A2d — cross-platform contract spike (N=3 BEFORE the runner consumes the contract).** A `windows-latest` CI leg that *compiles* a skeleton `process/windows.nim` implementing every contract signature against real Win32 (CreateProcess + Job Object + wait) and runs one spawn/exit-code/kill smoke test; a `macos-latest` leg compiling `process/posix` + running the conformance suite's poll-fallback subset. Purpose: the contract freezes against **three** backends' realities before A2b rebuilds the runner on it — the known churn points (no pre-exec child window for readback, CTRL_BREAK topology, sink handle inheritance, orphan events) surface as signature fixes against SHIMS, not against a fresh runner rewrite. Conformance-green is *not* required (that stays gated on RFC-0009). ✅ a8dfe5c (+2 fixes); CI 33718516001 all four legs green.
- [x] **A2b — the runner on the contract.** ✅ 96a0598, CI 33724921934 (all four legs). `runner.nim` supervision rewritten onto `Supervisor`: `Slot` gets `SlotState` (#1) + `ChildId`; grace and timeouts become executor deadlines; **the timeout path, the interrupt path, and exception teardown share one stop/escalate machinery** (three code paths become one — this is the acceptance, pinned by a conformance test that interrupt teardown of N hung slots completes in one shared grace window). Exception teardown shares the machinery but records NO results — observations are discarded and the exception propagates, so its stop acts never author a serialized `Cause` (there is no honest `KillReason` for it, and §2 forbids reasons without producers). Second-interrupt ⇒ skip-grace-forceKill-now honored (§1 `weShutdown`); explicit env for `hlNone`; memprobe/admission sampling re-routed through `groupRssBytes(sv, id)` — the executor holds no `Pid`, and memprobe's pgid scan becomes the posix backend's implementation (RFC-0002 quantity/cadence unchanged — §Contract impacts); `test_signal`/`test_m6_teardown` migrate; `std/posix` leaves `runner.nim`.
- [x] **A2c — cwd = projectRoot (#17).** ✅ 4fb6652, CI 33730831175 (all four legs). Every `ChildSpec.cwd` = `projectRoot` for run children AND both compile substrates — `spawnCompileStable` (contract) and `compiledriver.realCompileOnly` (osproc `workingDir`; a different substrate, aligned deliberately); `closure.extractCompileInputs` resolves relative `cc -M` paths against the same root. Acceptance: a `--path:src` group compiles identically from the project root, from a subdirectory via `--config ../crisol.kdl`, and through the library API with an unrelated cwd. README documents root-relative `flags`.
- [x] **A3** ✅ 38650b3, CI 33736788089 (all four legs). `ioutils` sole owner of raw file I/O (`exclusiveCreate`, `appendOpen`, `atomicPublish`, `writeAllFd`); `depgraph`, `jsonout`, `ledger`, `shardedledger`, `crisol.nim` init migrated; `std/posix` import count outside `process/`, `ioutils`, `lock`, `signals` is **zero**, and every `std/osproc` import site carries the `# process-contract-exempt` marker — both asserted by a unit test that greps `src/`. (`memprobe` reads `/proc` as files and imports neither.) Pure consolidation; existing tests are the proof.
- [x] **A4** `lock.nim` → `flock` (importc); `signals.nim` → `shutdownRequested(): Option[ShutdownSignal]` (signum only — §1; feeding both `weShutdown` and RFC-0003's `128+n`); the handler↔Supervisor wiring per §1 (`initSupervisor(installSignals)`; library mode opts out); lock-exclusion conformance test; the "close-any-fd-drops-lock" hazard gets a regression test that opens+closes the lock path from a helper. ✅ 25b39d2; CI 33740407097 all four legs green (handler↔Supervisor wiring landed at A2b/96a0598; A4 unified `signals.nim` onto the Supervisor's handler via a sticky signum global; close-any-fd regression RED on fcntl, green on flock).
- [x] **A5** Rusage surfacing: `run/v2` renders `rusage`; `ledger` gains a mechanism-tagged post-exit `maxRss` column (the sampled group-sum **stays** the admission quantity — §7); CLI-level assertions that `rusage` reaches `crisol run --json` for a trivial binary AND that a limits-configured group shows per-limit `evidence.limits` statuses on the wire (the per-limit shape's first CLI-level pin). ✅ 5371220; CI 33743713445 all four legs green (rusage already live from A1b — pinned; per-limit statuses were declared-but-dead in the wire shape, now wired from `ReapReport.limits`; ledger `maxRssBytes`+`rssMechanism` columns, additive compat).
- [x] **A6a — escapee observation.** killSnapshot at the first stop act (§1) → `evidence.killSnapshot`, with `rssBytes` populated from `/proc/<pid>/status` (never zero-filled on a 0005-signed wire type); post-reap pgid scan → `escapees` + honest `tree`; `evidenceSatisfies(spec, ev)` (named guarantees, incl. the per-limit rules — §6) replaces the bare `isFullyAchieved` call in `shouldStore` — **observed escapee (`escapees.len > 0`) ⇒ not stored**; render warning. Fixtures: `spawn_grandchild` drives the escapee path (a pgid scan can SEE it); `spawn_grandchild_setsid` pins the honest `toUnobservable`-and-cacheable-with-label path (invisible to a pgid scan by construction — B1 is where it flips). Tested through `execute()`, the cache roundtrip, and a CLI-level warning assertion. ✅ eba223c; CI 33750230464 all four legs green (escapee-cached regression proven RED at CLI level; `tree` derived from kill-domain mechanism via `treeObservationFor`, not scan outcome; `Evidence.hermetic` producer folded into A6b).
- [x] **A6b — `--strict-hygiene`.** `OutcomePolicy` threaded through the `outcome` call sites (cache stores/derives unstrict); the `RunOptions` field and the KDL config key land with the CLI flag (config parity is the house convention); CLI test asserts `crisol run --strict-hygiene` exits 1 on the `spawn_grandchild` fixture. ✅ addf324; CI 33755142663 all four legs green (policy applied at reporting boundaries only — cache/scheduling stay unstrict; also landed the folded-in `Evidence.hermetic` producer from A6a's flag: run phase stamps `spec.level`, compile phases stay `hlNone`).
- [x] **A7 — capabilities (code).** `capabilities()` probe (Linux set, per-file: pidfd, subreaper, cgroup delegation, `cgroup.kill`, `memory.peak`, flock, wait4) rendered in `run/v2.substrate` and `plan/v1` — the acceptance **pins expected values per known tier** (Linux CI leg: `pidfd:true`, `wait4Rusage:true`, `flock:true`; rootless-podman dev tier: `subreaper:true`, `cgroupDelegation:false`), so an inert always-false probe fails here, not at B2 when its first consumer arrives; `Evidence.killDomain` = per-spawn achieved (currently always `processGroup`). ✅ 030f328; CI 33760087338 all four legs green (all probes real — previously hardcoded literals; mutation check proves the pins catch an inert probe; CRISOL_TIER=ci-linux tier pins run in CI).
- [x] **A7-gate (Corey-owned, non-TDD; blocks the 0005 build):** re-baseline the RFC-0005 doc + handoff on the A1 shape (`StoredEntry` payload rewritten; the stale `#1 SlotState` prereq struck; serialization/signing/publish-gate slices re-audited against `ProcessResult`/`Evidence`; `--verify-cache` compares observations — `Exit` + records — not outcome strings); **amoxtli's `run/v2` consumer green against real `crisol run --json` output** — the wire is exercised by a real consumer before it freezes; CHANGELOG + consumer notice covering the JSON break and the full library-API break (`api.nim` re-export set, the enum rename, `CrisolInterrupted` retired, `RunV1Schema` → `RunV2Schema`); README/API-doc sweep (schema name, outcome vocabulary, exit-code table wording, interrupt paragraph, `--strict-hygiene`). **Stage A done ⇒ RFC-0005 build may start.** ✅ executed 2026-09-03 (Corey-directed, three agents): 0005 re-baseline 7c15e5c (FORK-2 untouched, now the sole 0005-build blocker); amoxtli consumer on run/v2 rev 18, green via the new binary (amoxtli cbf9a76b); CHANGELOG consumer notice + README sweep b2945a7 (note: the constant landed as `RunSchema`, unversioned).

**Stage B — Linux capability upgrades (each gated by A7's probe; each reports its tier):**
- [ ] **B1** `PR_SET_CHILD_SUBREAPER` with the §3 mechanics: SIGCHLD + `waitid(P_ALL, WNOWAIT)` sweep beside the wait set, pgid attribution via `/proc/<pid>/stat` before reap, `weOrphanReaped` events (with `ownedBy` delivered — §1); live escapees killed via `pidfd_open` + starttime identity check; `killDomain = processGroupSubreaper`. Fixture `spawn_grandchild_setsid` now shows `tree = toComplete` with `escapees` non-empty (observed, killed, reaped, counted — and per §6 still uncacheable: the axes are separate).
- [ ] **B2** pidfd + epoll-driven `next` with timerfd deadlines; 25 ms tick retained only for memory sampling; falls back to polling when pidfd is absent (probe). Conformance suite green under both (forced via an env knob in tests).
- [ ] **B3** cgroup v2 per-slot leaf when delegated. **First checklist item: the CI leg that actually has delegation** (e.g. a `systemd-run --user --scope`-wrapped or privileged-container job), proven by a canary test that *fails* if the probe reports delegation absent — the backend code does not merge before an environment that executes it exists (the #12 lesson, applied in advance; rootless podman runs only the degradation branch). Then: `clone3(CLONE_PIDFD|CLONE_INTO_CGROUP)`, `cgroup.kill` for forced kill, `memory.peak` for tree accounting (the tagged successor to sampling, §7), `memory.max` for `Limits.req[lkAddressSpace]` (mechanism reported; the ENOMEM→SIGKILL failure-mode change documented); **adds `lkMemory`, asserted only when the child's own `Exit` is `ekSignaled(SIGKILL)` ∧ `oom_kill > 0`** — a grandchild's OOM kill that the test tolerated (child exited on its own) is recorded as an `Evidence`-level count, never as `Cause`: authorship of an ending that did not happen would contradict `Exit`; `killDomain = cgroup`. Tests self-gate on delegation and assert *degradation* where absent; a green-probe/failed-leaf **fault-injection conformance test** (delegation probed green, leaf mkdir forced to fail — e.g. read-only leaf parent) asserts the spawn proceeds on the fallback tier and the *result* carries the degraded `killDomain` — the per-spawn-achieved motivation (§4), exercised, not just stated.

**Stage C — Darwin backend (leg exists since A2d):**
- [ ] **C1a** `process/posix` green on the `macos-latest` leg via the poll fallback: full conformance suite + full unit suite (near-zero new code — this proves the CI loop before behavior work starts).
- [ ] **C1b** `process/darwin.nim` born as a THIN DELEGATION module over `posixcore` (§1 sharing mechanism — Nim has no partial module override): its own `Supervisor` embedding `PosixCore`; kqueue `EVFILT_PROC` `next`; libproc `snapshotTree`/`groupRssBytes` with rssBytes — admission sampling routes through the contract, so Darwin is *not* resigned to degradation; the `process.nim` ladder flips `macosx` from posix to darwin here; `capabilities()` gains the darwin probes and `substrate` renders them; `hlNetwork` unachieved-and-reported; setsid escapees honestly `toUnobservable` (§3). tonalli macOS legs convert.

**Stage D — Windows backend (#15; conformance-green requires RFC-0009; leg + skeleton exist since A2d):**
- [ ] **D1a** `process/windows.nim` core: `CreateProcess` + Job Object spawn, inherited handles to sinks, completion-port `next`, `reap` with exit codes + `ekNtStatus` symbol table, Job accounting rusage. The access-violation fixture lands HERE — it is `ekNtStatus`'s producer proof, not serde-only coverage. Conformance smoke green.
- [ ] **D1b** Kill domain + cooperative stop: `KILL_ON_JOB_CLOSE`, breakaway disabled, `CTRL_BREAK` gated on the probed deliverability (undeliverable ⇒ `evidence.cooperativeUnavailable`, straight to `TerminateJobObject(runner code)`) → forced kill; `Limits` → Job limits (`lkOpenFiles` = `lsUnsupported`; `LimitsAchieved` parent-computed, meaning documented); `JobObjectBasicProcessIdList` snapshots; Windows fixture variants (CTRL_BREAK handler, breakaway attempt, and the `DETACHED_PROCESS`/`FreeConsole` fixture — the only live producer of `cooperativeUnavailable: true`, asserted with `escalated` not degraded to noise); `capabilities()`/`substrate` extended.
- [ ] **D2** `lock` (`LockFileEx`), `ioutils` (`MoveFileEx`, `CREATE_NEW`), `signals` (`SetConsoleCtrlHandler` → `ShutdownSignal`), memprobe (Job accounting via `groupRssBytes` + `GlobalMemoryStatusEx`). `windows-latest` full conformance leg. **This slice owns test/fixture portability** (35 test files under `tests/` import `std/posix` today, incl. 2 fixtures — measured; RFC-0009 owns only path identity, not de-POSIXing the suite) — the A3 grep-assert extends to `tests/` for Windows-relevant usage; full-suite green remains RFC-0009's acceptance. When Stage D is re-cut for execution, split D2a (production: lock/ioutils/signals/memprobe) from D2b (the test-suite sweep).

## Contract impacts

- **`crisol/run/v2`** replaces `run/v1` (breaking; pre-v1); the rev-integer scheme carries over, continuing v1's counter (RFC-0008 extends v2). Top-level `interrupted` + `summary.notStarted` make a partial run distinguishable on the wire; the compile-telemetry object renames to `compileStats` (the `compile` name now belongs to the phase node); A1d-i owes the complete v1→v2 field table. `plan/v1` gains `substrate` (A7). `loadLastRun` reads v1 as cold-start. Enums serialize as strings; NON-DERIVING readers tolerate unknown values (additive growth without a version bump); crisol's own typed readers treat an unparseable enum as a structural failure ⇒ cache miss (§2).
- **`EntrypointResult`** loses `outcome`/`exitCode`/`signal`/`achieved`/`peakRssBytes`/`cached`/`flaky`; gains `compile`/`run` as `Phase` variants (spawn failure carries its phase by construction; a cache hit is `pkCached` around the stored observation); `outcome(r, policy)`, `flaky(r, policy)`, `symbol(e)`/`isSuccess(e)` are procs (`signalName` stays as a POSIX convenience over `symbol`). **This is a library-API break** — `api.nim`'s enumerated re-export set (A1c) plus the retired `CrisolInterrupted` — covered by the A7-gate consumer notice alongside the JSON break.
- **`Summary`** reshapes to the derived `counts: array[Outcome, int]` (+`notStarted`); wire names stay explicit (`killed`/`crashed`); `exitCode(Summary)` folds `isFailure` under the same RFC-0003 rule.
- **RFC-0003 exit codes** unchanged: `oKilled`/`oCrashed` are test *results* ⇒ `rsOk`, exit 1; crisol-level SIGINT/SIGTERM ⇒ `rsInterrupted`, `128+n` (SIGINT 130 and SIGTERM 143 both pinned). **Report semantics amended, fully:** on interrupt, `execute` returns normally — `CrisolInterrupted` retired — with `RunReport.interrupted: Option[ShutdownSignal]`, `results`/`summary` populated with §2's emission set, and `onResult` fired for killed finals; the CLI emits stdout JSON + junit but persists **no** `lastrun.json` and appends **no** ledger rows (§2's invariants: `--failed` anchors to the last complete run; ledger history stays noise-free). RFC-0003's "results and summary are empty on interrupt" paragraph amends accordingly — the empty report was teardown discarding observations, not a designed contract. Flagged for Corey's veto in round-1 notes; the RFC's §2 interrupt claim is unimplementable without it.
- **RFC-0004** `CachedResult` stores the run `ProcessResult` + records; `shouldStore` gates on `evidenceSatisfies(spec, evidence)` (named guarantees; observed escapees refuse, unobservable tiers store-with-label, `lsFailed` refuses, `lsUnsupported` stores-with-label — §6); pass-only store carried forward and recomputed-not-pass hits rerun (§2); `hlNetwork` = network-independence asserted, runs uncacheable until RFC-0008 (§6); `SandboxAchieved` deleted (§5).
- **RFC-0002** admission is UNCHANGED in quantity and cadence: the sampled group-RSS tree sum stays the estimate and the ledger's `rssBytes`. What changes is the primitive — the executor holds `ChildId`s, not `Pid`s, so sampling routes through `groupRssBytes(sv, id)` (memprobe's pgid scan re-homed as the posix backend's implementation, A2b), and the fill loop's 25 ms pass becomes the sample-tick deadline under event wait (B2). RFC-0002's pid-keyed `onSlotFinish`/`procGroupRssBytes` wording updates accordingly.
- **RFC-0005** `StoredEntry` payload = the A1 shape via `resultjson`; `storageFormatVersion`/`resultCacheFormatVersion` bump once, here, before anything is signed; its publish gate reads `Evidence` (including `TreeObservation` and `killDomain`, so the trust layer can filter by tier). A7 re-baselines the 0005 doc + handoff before its build starts.
- **Ledger:** rows keep outcome strings; legacy `"timedOut"`/`"signaled"` remain classified by `isFailureOutcomeString` (history stays warm); new mechanism-tagged post-exit `maxRss` column beside the sampled `rssBytes` (whose semantics do not change).
- **JUnit:** `oKilled`/`oCrashed` → `<error>` with `cause` in the message.
- **RFC-0001** Implementation Decisions table: `fcntl F_SETLK` → `flock`; poll loop → event-driven where available; process-group placement → kill-domain ladder; `spawn.supervise` retired (dead code). Prose amendments: the "5 s grace" wording corrected to the 400 ms constant; the interrupt "delete all temp sink files … re-raise" paragraph amended (partial results, above); the reader-contract's executor-precedence rule subsumed by the pure derivation (§2 `hasFailRecords`).

## Risks accepted

- macOS/Windows backends are CI-only to develop (no host Nim; podman is Linux); A2d's early legs + the posix-plus-overrides structure (C1) and skeleton-first sequencing (D1) keep each CI-iterated slice small.
- cgroup paths are dark in the rootless-podman dev loop; B3's leg-first rule (a delegated-cgroup CI job with a canary that fails on absent delegation) is the mitigation — code that cannot execute anywhere does not merge.
- `run/v2` + the `Outcome` library API break amoxtli/tonalli once; both are Corey's, updated in one commit each, and amoxtli's consumer is exercised against real output *before* the 0005 freeze (A7).
- The A1 ladder dual-writes legacy and new fields for a few slices; the removal slice (A1e) deletes the duplication and the compiler enumerates every straggler. Bounded, deliberate, short-lived.
- The interrupt partial-results amendment changes documented RFC-0003 behavior (empty report → partial report). Exit codes are untouched; consumers that only read the exit code see no change.
- A cache hit whose recomputed outcome is no longer a pass reruns rather than being served forever (§2); the cost is a cold entry after a derivation change — accepted as the honest option.
- The unkillable D-state child (§1) leaves its slot live rather than fabricating an `Exit`; the run stalls honestly. Vanishingly rare and kernel-owned; accepted.
