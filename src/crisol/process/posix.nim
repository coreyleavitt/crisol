## process/posix.nim — rfc-0007 §1: the POSIX Supervisor backend.
##
## `macosx` maps here until C1b births `process/darwin.nim` (§1 module-layout
## comment). Everything below is a thin, mostly one-line delegation onto
## `process/posixcore.nim`'s `PosixCore` — the shared machinery every
## posix-family backend embeds (Nim has no partial module override).

import std/options
import std/monotimes
import crisol/process/types
import crisol/process/posixcore

export types

type
  Supervisor* = object       ## deep module: owns the event loop, the
    core: PosixCore          ## shutdown-signal wakeup, and the child
                              ## registry (§1). Fields backend-private.

proc `=copy`*(dst: var Supervisor; src: Supervisor) {.error:
  "Supervisor is non-copyable — one owner per event-loop fd (rfc-0007 §1); " &
  "pass by `var`/return it, never copy.".}

proc `=destroy`*(sv: var Supervisor) =
  ## Releases the loop and registry and KILLS NOTHING — outstanding children
  ## are the executor's to stop and reap (§1). Debug-build Defect on live
  ## children mirrors the contract's lifecycle rule.
  when not defined(release) and not defined(danger):
    doAssert liveChildCount(sv.core) == 0,
      "Supervisor destroyed with live children — stop and reap them first (rfc-0007 §1)"
  destroyPosixCore(sv.core)

proc initSupervisor*(installSignals: bool = true): Supervisor =
  ## Can fail (§1): epoll/self-pipe creation, fd exhaustion at high --jobs —
  ## raises a structural error, never a degraded half-loop. `installSignals`
  ## true (the default): the Supervisor owns `sigaction` installation, wired
  ## to its own self-pipe wakeup — the handler↔Supervisor seam A4 unifies
  ## with `signals.nim`/`shutdownRequested()` for library callers that opt out.
  Supervisor(core: initPosixCore(installSignals))

proc capabilities*(sv: Supervisor): Capabilities =
  ## Probed once by the caller and memoised there (§4).
  capabilitiesCore(sv.core)

proc spawn*(sv: var Supervisor; spec: ChildSpec): SpawnResult =
  spawnChild(sv.core, spec)

proc next*(sv: var Supervisor; deadline: MonoTime): WaitEvent =
  ## The ONE wait primitive (§1). Blocks until a WaitEvent; a signal
  ## delivered while blocked returns `weShutdown` well before `deadline`
  ## (self-pipe). Ready child exits are always drained before `weDeadline`.
  nextEvent(sv.core, deadline)

proc requestStop*(sv: var Supervisor; id: ChildId; reason: KillReason) =
  ## Cooperative stop (SIGTERM to the process group). Non-blocking and
  ## idempotent; Defect on a consumed/unknown id (§1).
  requestStopCore(sv.core, id, reason)

proc forceKill*(sv: var Supervisor; id: ChildId) =
  ## Forced kill (SIGKILL to the process group). Non-blocking, idempotent,
  ## same atomic no-op rule as requestStop (§1).
  forceKillCore(sv.core, id)

proc reap*(sv: var Supervisor; id: ChildId): ReapReport =
  ## The only place a ChildId is consumed (§1). Precondition: `weChildExited`
  ## was reported for this id — Defect otherwise.
  reapCore(sv.core, id)

proc snapshotTree*(sv: Supervisor; id: ChildId): seq[ProcSnapshot] =
  ## Kill/reap FORENSICS only (§1) — never zero-filled where readable.
  snapshotTreeCore(sv.core, id)

proc groupRssBytes*(sv: Supervisor; id: ChildId): Option[int64] =
  ## The live memory SAMPLER (§1/§7) — the group-RSS sum and nothing else.
  groupRssBytesCore(sv.core, id)
