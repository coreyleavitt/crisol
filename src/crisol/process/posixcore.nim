## process/posixcore.nim — rfc-0007 §1 shared machinery over a `PosixCore`
## object: fork/exec child window, rlimit readback, self-pipe, poll wait.
##
## Nim has no partial module override (a backend cannot "re-export posix plus
## two procs"), so this is the sharing mechanism the §1 module-layout comment
## specifies: every posix-family backend (today: process/posix.nim; C1b's
## process/darwin.nim later) embeds a `PosixCore` and implements the full §1
## contract surface as mostly one-line delegations onto the procs below.
##
## SAFETY: the child window (between fork() and exec) executes ONLY
## async-signal-safe primitives — the same invariant crisol/spawn.nim used
## to document. The cstring argv/envp arrays, the sink fd, and the readback
## pipe are all built/opened BEFORE fork; the executor is single-threaded
## before and during the spawn loop (RFC-0007 §1 invariant carried from
## RFC-0001).
##
## A2a-i note (superseded): this module was written to NOT touch
## `crisol/spawn.nim` — `runner.nim` still drove `forkExec`/
## `forkExecEnvScratch` directly at that point. A2b migrated `runner.nim`
## onto the Supervisor and deleted `spawn.nim` outright (it had no callers
## left). The RLIMIT_* constants below stayed importc'd here independently
## rather than merged with anything — duplicate `importc` `var`s referencing
## the same C symbol are safe and idiomatic in Nim (no C definition is
## emitted, only a reference through the header).

import std/[options, os, posix, sets, strutils, tables, monotimes, times]
import crisol/process/types

# ---------------------------------------------------------------------------
# rlimit constants missing from std/posix (same set spawn.nim importc's).
# ---------------------------------------------------------------------------

var RLIMIT_CORE   {.importc: "RLIMIT_CORE",   header: "<sys/resource.h>".}: cint
var RLIMIT_FSIZE  {.importc: "RLIMIT_FSIZE",  header: "<sys/resource.h>".}: cint
var RLIMIT_CPU    {.importc: "RLIMIT_CPU",    header: "<sys/resource.h>".}: cint
var RLIMIT_AS     {.importc: "RLIMIT_AS",     header: "<sys/resource.h>".}: cint

# ---------------------------------------------------------------------------
# rfc-0007 B1 (§3): Linux-only syscall/prctl FFI, moved ahead of
# initPosixCore/PosixCore so `initPosixCore` can set PR_SET_CHILD_SUBREAPER
# DELIBERATELY (not merely as `probeSubreaper`'s capability-probe side
# effect) — a Supervisor must be a subreaper by construction. Also used by
# the escapee-kill/orphan-sweep mechanism further down this file
# (discoverAndReapEscapees, nextEvent's orphan sweep). No Nim wrapper exists
# for pidfd_open/pidfd_send_signal (even std/posix's own `syscall` helper is
# `when defined(android)`-only) — importc syscall(2) directly, the same
# duplicate-importc idiom this module's header sanctions.
# ---------------------------------------------------------------------------

when defined(linux):
  proc c_syscall(number: clong): clong {.importc: "syscall", varargs,
                                         header: "<unistd.h>".}
  var SYS_pidfd_open {.importc: "SYS_pidfd_open", header: "<sys/syscall.h>".}: clong
  var SYS_pidfd_send_signal {.importc: "SYS_pidfd_send_signal",
                              header: "<sys/syscall.h>".}: clong

  proc probePidfd(): bool =
    let r = c_syscall(SYS_pidfd_open, clong(getpid()), 0.clong)
    if r < 0: return false
    discard posix.close(cint(r))
    true

  # -------------------------------------------------------------------------
  # rfc-0007 B2 (§1/§3): pidfd + epoll-driven `next`, with timerfd deadlines.
  # `posix/epoll` (a stdlib module living under lib/posix/, not the `std/`
  # namespace) wraps epoll_create1/epoll_ctl/epoll_wait/EpollEvent
  # already (Nim ships it); timerfd has no stdlib wrapper at all, so it is
  # hand-rolled here with the same duplicate-importc idiom the rest of this
  # module uses for RLIMIT_*/flock/prctl. Both are Linux-only kernel
  # mechanisms (no Darwin equivalent) — guarded the same way probePidfd/
  # probeSubreaper are, so `nim check --os:macosx` never even parses this
  # branch.
  # -------------------------------------------------------------------------
  import posix/epoll

  var EPOLL_CLOEXEC {.importc, header: "<sys/epoll.h>".}: cint

  type
    Itimerspec {.importc: "struct itimerspec", header: "<sys/timerfd.h>".} = object
      it_interval: Timespec
      it_value: Timespec

  proc timerfd_create(clockid: ClockId; flags: cint): cint {.
    importc: "timerfd_create", header: "<sys/timerfd.h>".}
  proc timerfd_settime(fd: cint; flags: cint; new_value: ptr Itimerspec;
                        old_value: ptr Itimerspec): cint {.
    importc: "timerfd_settime", header: "<sys/timerfd.h>".}
  var TFD_NONBLOCK {.importc, header: "<sys/timerfd.h>".}: cint
  var TFD_CLOEXEC {.importc, header: "<sys/timerfd.h>".}: cint

  proc forcePollRequested(): bool =
    ## rfc-0007 B2 checklist item 544's env knob: forces `next()` onto the
    ## poll(2) fallback path even on a pidfd-capable host, so the
    ## conformance suite can be proven green under BOTH tiers (see
    ## tests/conformance/test_conformance_timing.nim's B2 suite and this
    ## repo's `./dev test` / CI wiring, which runs tests/conformance a
    ## second time with this set). Read fresh per `initPosixCore` call
    ## (a policy override, not a memoised environment fact like
    ## `capabilities()` — nothing needs it to be process-global).
    let v = getEnv("CRISOL_FORCE_POLL")
    v.len > 0 and v != "0"

  # PR_SET_CHILD_SUBREAPER / PR_GET_CHILD_SUBREAPER: unprivileged since
  # Linux 3.4.
  proc c_prctl(option: cint): cint {.importc: "prctl", varargs,
                                     header: "<sys/prctl.h>".}
  var PR_SET_CHILD_SUBREAPER {.importc, header: "<sys/prctl.h>".}: cint
  var PR_GET_CHILD_SUBREAPER {.importc, header: "<sys/prctl.h>".}: cint

  proc probeSubreaper(): bool =
    ## Set-then-read-back is the real verification (not "the set call
    ## returned 0, therefore assume it worked").
    if c_prctl(PR_SET_CHILD_SUBREAPER, 1.cint) != 0: return false
    var val: cint = -1
    if c_prctl(PR_GET_CHILD_SUBREAPER, addr val) != 0: return false
    val == 1
else:
  proc probePidfd(): bool = false
  proc probeSubreaper(): bool = false

# ---------------------------------------------------------------------------
# PosixCore — the shared state: child registry, self-pipe, act ledger.
# ---------------------------------------------------------------------------

type
  ChildState = enum csSpawned, csExited, csReaped

  ChildEntry = object
    pid: Pid
    state: ChildState
    reqLimits: Limits
    achieved: LimitsAchieved
    exit: Exit
    rusage: Option[types.Rusage]
    stop: Option[tuple[reason: KillReason, escalated: bool]]
    killSnapshot: seq[ProcSnapshot]
    pidfd: cint                ## rfc-0007 B2: -1 unless `core.useEpoll` AND
                                ## `pidfd_open` succeeded for this child —
                                ## registered EPOLLIN in `core.epollFd` at
                                ## spawn, closed + EPOLL_CTL_DEL'd at reap
                                ## (the ONLY two touch points; never leaked).

  PosixCore* = object
    nextIdVal: int32
    children: Table[int32, ChildEntry]
    liveCount: int             ## spawned, not yet reaped — the =destroy guard.
    pipeRead, pipeWrite: cint
    installedSignals: bool
    pendingShutdown: seq[ShutdownSignal]
    epollFd: cint               ## rfc-0007 B2: -1 unless `useEpoll`.
    timerFd: cint               ## rfc-0007 B2: -1 unless `useEpoll`.
    useEpoll: bool               ## rfc-0007 B2: decided ONCE at init — Linux
                                  ## + a real pidfd probe + CRISOL_FORCE_POLL
                                  ## unset. Never re-evaluated mid-run.

# ---------------------------------------------------------------------------
# Self-pipe + shutdown signal handler.
#
# sigaction handlers cannot capture state, so the write end lives in a
# module-level global — exactly the "process-global handler must reach a
# per-run Supervisor's pipe" seam §1's lifecycle rules name. One Supervisor
# with installSignals=true is the supported configuration per process.
#
# rfc-0007 A4: the handler ALSO stamps `gShutdownSignum`, a second,
# sticky, async-signal-safe global — the same write(2) syscall that wakes a
# blocked `next()` cannot be "the" state on its own, because it is drained
# per-instance (`PosixCore.pendingShutdown`, consumed edge-triggered, once
# per delivered signal — §1's weShutdown contract) and unreachable from
# outside the owning Supervisor. `gShutdownSignum` is the process-global,
# level-triggered mirror `crisol/signals.shutdownRequested()` reads: ONE
# handler, ONE signal delivery, two consumption models over the same fact
# — never two independent `sigaction` installs racing to overwrite each
# other. This is the seam A4 unifies signals.nim onto for real.
# ---------------------------------------------------------------------------

var gShutdownWriteFd {.global.}: cint = -1
var gShutdownSignum {.global, volatile.}: cint = 0

proc shutdownSigHandler(signum: cint) {.noconv.} =
  ## Async-signal-safe: writes the signal number to the self-pipe (Supervisor
  ## wakeup) and stamps the sticky global (shutdownRequested()). No Nim
  ## runtime, no alloc, no GC — a volatile store and a write(2), nothing else.
  gShutdownSignum = signum
  if gShutdownWriteFd >= 0:
    var b = uint8(signum)
    discard posix.write(gShutdownWriteFd, addr b, 1)

proc globalShutdownSignalCore*(): Option[ShutdownSignal] =
  ## Process-global, level-triggered view of the last shutdown signal any
  ## installSignals=true Supervisor in THIS process has observed (§1's
  ## `shutdownRequested()` seam) — sticky by design: unlike `next()`'s
  ## per-instance `weShutdown` (edge-triggered, consumed once), a caller
  ## with no Supervisor reference at all must still be able to ask "was a
  ## shutdown ever requested here" at any later point.
  let s = gShutdownSignum
  if s != 0: some(ShutdownSignal(signum: int(s)))
  else: none(ShutdownSignal)

proc initPosixCore*(installSignals: bool): PosixCore =
  ## `initSupervisor` can fail (§1) — this raises OSError (a structural
  ## error, never a degraded half-loop) on self-pipe creation failure, which
  ## is realistic at high --jobs fd pressure.
  result = PosixCore(nextIdVal: 0'i32, children: initTable[int32, ChildEntry](),
                      liveCount: 0, pipeRead: -1, pipeWrite: -1,
                      installedSignals: installSignals,
                      epollFd: -1, timerFd: -1, useEpoll: false)
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    raise newException(OSError, "initSupervisor: failed to create self-pipe")
  for fd in fds:
    if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
      raise newException(OSError, "initSupervisor: FD_CLOEXEC failed on self-pipe")
  let flags = fcntl(fds[0], F_GETFL, 0)
  if flags == -1 or fcntl(fds[0], F_SETFL, flags or O_NONBLOCK) == -1:
    discard posix.close(fds[0])
    discard posix.close(fds[1])
    raise newException(OSError, "initSupervisor: O_NONBLOCK failed on self-pipe read end")
  result.pipeRead = fds[0]
  result.pipeWrite = fds[1]
  when defined(linux):
    # rfc-0007 B2 (§1): event-driven `next` — chosen ONCE, here, never
    # re-evaluated mid-run. `probePidfd()` (not `cachedCapabilities()`): a
    # cheap, self-contained, idempotent probe (open+close a pidfd on our own
    # pid) is all this decision needs; consulting the full memoised
    # Capabilities would mean paying for cgroup/flock/wait4Rusage probes
    # (real I/O: mkdir+write under /sys/fs/cgroup, a throwaway fork+wait4)
    # merely to read one unrelated field. `capabilities().pidfd` (reported
    # to callers/wire) and this internal decision are deliberately two
    # separate calls to the SAME underlying mechanism — never made to share
    # a code path, so a future divergence (e.g. `probePidfd` growing an
    # extra check that should NOT gate backend selection) cannot silently
    # couple the two.
    if probePidfd() and not forcePollRequested():
      let efd = epoll_create1(EPOLL_CLOEXEC)
      if efd < 0:
        discard posix.close(result.pipeRead)
        discard posix.close(result.pipeWrite)
        raise newException(OSError, "initSupervisor: epoll_create1 failed")
      let tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK or TFD_CLOEXEC)
      if tfd < 0:
        discard posix.close(efd)
        discard posix.close(result.pipeRead)
        discard posix.close(result.pipeWrite)
        raise newException(OSError, "initSupervisor: timerfd_create failed")
      var pipeEv: EpollEvent
      pipeEv.events = EPOLLIN.uint32
      pipeEv.data.fd = result.pipeRead
      var timerEv: EpollEvent
      timerEv.events = EPOLLIN.uint32
      timerEv.data.fd = tfd
      if epoll_ctl(efd, EPOLL_CTL_ADD, result.pipeRead, addr pipeEv) != 0 or
         epoll_ctl(efd, EPOLL_CTL_ADD, tfd, addr timerEv) != 0:
        discard posix.close(tfd)
        discard posix.close(efd)
        discard posix.close(result.pipeRead)
        discard posix.close(result.pipeWrite)
        raise newException(OSError, "initSupervisor: epoll_ctl registration failed")
      result.epollFd = efd
      result.timerFd = tfd
      result.useEpoll = true
  if installSignals:
    gShutdownWriteFd = fds[1]
    var sa: Sigaction
    sa.sa_handler = shutdownSigHandler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = SA_RESTART
    discard sigaction(SIGINT, sa, nil)
    discard sigaction(SIGTERM, sa, nil)
  when defined(linux):
    # rfc-0007 B1 (§3): a Supervisor IS a subreaper by construction — set
    # DELIBERATELY here, independent of `probeSubreaper`'s capability probe
    # (which may run lazily, before or after this call, memoised once per
    # PROCESS rather than per Supervisor instance). Idempotent with the
    # probe's own set-then-read-back; orphans at any depth reparent to this
    # process from this point on, feeding `discoverAndReapEscapees` and
    # `nextEvent`'s orphan sweep below.
    discard c_prctl(PR_SET_CHILD_SUBREAPER, 1.cint)

proc liveChildCount*(core: PosixCore): int =
  ## Spawned-but-not-reaped count — the `=destroy` Defect guard (§1).
  core.liveCount

proc destroyPosixCore*(core: var PosixCore) =
  ## `=destroy` releases the loop and registry and KILLS NOTHING (§1) —
  ## outstanding children are the executor's to stop and reap. Explicitly
  ## clears the managed collections: a custom `=destroy` on `Supervisor`
  ## replaces (not supplements) the compiler's default field-wise teardown,
  ## so this module stays responsible for its own Table/seq cleanup.
  if core.installedSignals and gShutdownWriteFd == core.pipeWrite:
    gShutdownWriteFd = -1
  if core.pipeRead >= 0: discard posix.close(core.pipeRead)
  if core.pipeWrite >= 0: discard posix.close(core.pipeWrite)
  when defined(linux):
    # rfc-0007 B2: the CORE-level epoll/timerfd fds (never per-child — those
    # are `entry.pidfd`, closed at `reapCore`, which by the =destroy Defect
    # guard above cannot still be outstanding here).
    if core.epollFd >= 0: discard posix.close(core.epollFd)
    if core.timerFd >= 0: discard posix.close(core.timerFd)
  core.children = initTable[int32, ChildEntry]()
  core.pendingShutdown = @[]

# ---------------------------------------------------------------------------
# rlimit readback (child-side, async-signal-safe) — the A4d ceremony shrunk
# to exactly per-limit readback (§1 LimitsAchieved doc comment).
# ---------------------------------------------------------------------------

proc rlimitReadbackOk(res: cint; want: int64): bool =
  var rl: RLimit
  if getrlimit(res, rl) != 0:
    return false
  rl.rlim_cur == clong(want)

const nLimits = ord(LimitKind.high) + 1
  ## Cardinality of LimitKind — the fixed size of the child→parent readback
  ## byte buffer (one byte per kind, at its ordinal offset).

proc applyLimitsChildSide(limits: Limits; achieved: var array[nLimits, uint8]) =
  ## Async-signal-safe: setrlimit + getrlimit read-back only, no heap.
  ## Order: RLIMIT_AS last (spawn.nim's ORDER note — earlier setrlimit calls
  ## must not be constrained by the AS ceiling).
  template applyOne(kind: LimitKind; rlimitConst: cint; hardBumpSecs: int64) =
    if limits.req[kind].isSome:
      let want = limits.req[kind].get()
      var rl: RLimit
      rl.rlim_cur = clong(want)
      rl.rlim_max = clong(want + hardBumpSecs)
      if setrlimit(rlimitConst, rl) == 0 and rlimitReadbackOk(rlimitConst, want):
        achieved[ord(kind)] = uint8(lsApplied)
      else:
        achieved[ord(kind)] = uint8(lsFailed)
    else:
      achieved[ord(kind)] = uint8(lsNotRequested)

  applyOne(lkCore, RLIMIT_CORE, 0)
  applyOne(lkOpenFiles, RLIMIT_NOFILE, 0)
  applyOne(lkFileSize, RLIMIT_FSIZE, 0)
  applyOne(lkCpu, RLIMIT_CPU, 1)        # +1s hard grace so SIGXCPU fires first
  applyOne(lkAddressSpace, RLIMIT_AS, 0)

# ---------------------------------------------------------------------------
# spawn — the fork/exec child window, generalized from ChildSpec.
# ---------------------------------------------------------------------------

proc spawnChild*(core: var PosixCore; spec: ChildSpec): SpawnResult =
  if spec.argv.len == 0:
    return SpawnResult(ok: false, error: "empty argv")

  # Resolve the executable in the PARENT (see spawn.nim's execve note: PATH
  # walking stays out of the async-signal-safe child window).
  let exePath = findExe(spec.argv[0])
  if exePath.len == 0:
    return SpawnResult(ok: false, error: "executable not found: " & spec.argv[0])

  var cargs = newSeq[cstring](spec.argv.len + 1)
  for i, s in spec.argv: cargs[i] = s.cstring
  cargs[spec.argv.len] = nil

  var envStrings = newSeq[string](spec.env.len)
  for i, pair in spec.env: envStrings[i] = pair[0] & "=" & pair[1]
  var cenv = newSeq[cstring](envStrings.len + 1)
  for i in 0 ..< envStrings.len: cenv[i] = envStrings[i].cstring
  cenv[envStrings.len] = nil

  # Sinks are opened BEFORE the child exists, by path (§1) — no pipe drain,
  # no 64 KB deadlock. ONE combined stdout+stderr sink.
  let sinkFd = posix.open(spec.sinks.path.cstring,
                           O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
  if sinkFd < 0:
    return SpawnResult(ok: false, error: "failed to open sink: " & spec.sinks.path)

  let nullFd = posix.open("/dev/null".cstring, O_RDONLY)
  if nullFd < 0:
    discard posix.close(sinkFd)
    return SpawnResult(ok: false, error: "failed to open /dev/null")

  # Pre-fork readback pipe: the child writes 5 achieved-bytes (one per
  # LimitKind, in enum order) before execve; EOF ⇒ child died before writing.
  var statusPipe: array[2, cint]
  if posix.pipe(statusPipe) != 0:
    discard posix.close(sinkFd)
    discard posix.close(nullFd)
    return SpawnResult(ok: false, error: "failed to create readback pipe")
  for fd in statusPipe:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  let pipeRead = statusPipe[0]
  let pipeWrite = statusPipe[1]

  let cwdCstr = spec.cwd.cstring     # points into spec.cwd; live until after fork
  let exeCstr = exePath.cstring
  let doChdir = spec.cwd.len > 0

  let childPid = fork()
  if childPid < 0:
    discard posix.close(sinkFd)
    discard posix.close(nullFd)
    discard posix.close(pipeRead)
    discard posix.close(pipeWrite)
    return SpawnResult(ok: false, error: "fork failed")

  if childPid == 0:
    # =========================================================================
    # CHILD — only async-signal-safe operations from here to execve/_exit.
    # =========================================================================
    discard posix.close(pipeRead)
    discard setpgid(Pid(0), Pid(0))
    discard dup2(nullFd, cint(STDIN_FILENO))
    discard posix.close(nullFd)
    discard dup2(sinkFd, cint(STDOUT_FILENO))
    discard dup2(sinkFd, cint(STDERR_FILENO))

    if doChdir:
      discard posix.chdir(cwdCstr)

    var achieved: array[nLimits, uint8]
    applyLimitsChildSide(spec.limits, achieved)

    var off = 0
    while off < achieved.len:
      let n = posix.write(pipeWrite, addr achieved[off], achieved.len - off)
      if n > 0: off += int(n)
      elif n < 0 and errno == EINTR: continue
      else: break
    discard posix.close(pipeWrite)

    discard execve(exeCstr, cast[cstringArray](addr cargs[0]),
                   cast[cstringArray](addr cenv[0]))
    discard posix.write(cint(STDERR_FILENO), "_exit(127)\n".cstring, 11)
    exitnow(127)
    # =========================================================================

  # PARENT.
  discard posix.close(nullFd)
  discard posix.close(sinkFd)
  discard posix.close(pipeWrite)
  discard setpgid(childPid, childPid)

  var pidfd: cint = -1
  when defined(linux):
    # rfc-0007 B2: pidfd_open on our OWN just-forked child is valid
    # immediately (no reap-vs-open race — the child cannot have been reaped
    # by anything else yet, it isn't registered anywhere until this proc
    # returns). A failure here (EMFILE, or a non-useEpoll core) is never
    # fatal to the spawn: `pidfd` stays -1 and `pollSweepChildren`'s WNOHANG
    # sweep — which runs every `nextEvent` iteration regardless of backend —
    # is the honest, already-correct fallback observer for this one child.
    if core.useEpoll:
      let raw = c_syscall(SYS_pidfd_open, clong(childPid), 0.clong)
      if raw >= 0:
        let candidate = cint(raw)
        var ev: EpollEvent
        ev.events = EPOLLIN.uint32
        ev.data.fd = candidate
        if epoll_ctl(core.epollFd, EPOLL_CTL_ADD, candidate, addr ev) == 0:
          pidfd = candidate
        else:
          discard posix.close(candidate)   # stays -1 — WNOHANG sweep covers it

  var rbuf: array[nLimits, uint8]
  var got = 0
  while got < rbuf.len:
    let n = posix.read(pipeRead, addr rbuf[got], rbuf.len - got)
    if n > 0: got += int(n)
    elif n == 0: break            # EOF — child died before writing
    elif errno == EINTR: continue
    else: break
  discard posix.close(pipeRead)

  var achieved: LimitsAchieved
  if got == rbuf.len:
    for lk in LimitKind:
      achieved[lk] = LimitStatus(rbuf[ord(lk)])
  else:
    # Honest degradation: a REQUESTED limit whose readback never arrived is
    # `lsFailed` (we cannot vouch it applied), never fabricated as applied
    # and never silently downgraded to lsNotRequested (that would be a lie
    # in the other direction — claiming nothing was asked for).
    for lk in LimitKind:
      achieved[lk] = if spec.limits.req[lk].isSome: lsFailed else: lsNotRequested

  let id = core.nextIdVal
  inc core.nextIdVal
  core.children[id] = ChildEntry(pid: childPid, state: csSpawned,
                                  reqLimits: spec.limits, achieved: achieved,
                                  pidfd: pidfd)
  inc core.liveCount
  SpawnResult(ok: true, id: ChildId(id))

# ---------------------------------------------------------------------------
# /proc forensics — snapshotTree (kill/reap forensics) and groupRssBytes (the
# live sampler). Same pgid-scan mechanism, two cadences/shapes (§1 §7):
# groupRssBytes is memprobe.procGroupRssBytes' algorithm re-homed; A2b wires
# memprobe/admission to call through the Supervisor instead of duplicating it.
# ---------------------------------------------------------------------------

proc parseStatLine*(content: string): tuple[ppid, pgrp: int; comm: string; starttime: int64] =
  ## /proc/<pid>/stat: "pid (comm) state ppid pgrp ... starttime ...". comm
  ## may itself contain spaces/parens, so split on the LAST ')' (same
  ## technique test_pgroup.nim already uses for the same reason). Exported
  ## (rfc-0007 B1) so its field-counting is unit-testable directly — see
  ## tests/unit/test_rfc0007_b1_stat_parsing.nim.
  ##
  ## Field numbering (man proc(5), 1-indexed): 1 pid, 2 comm, 3 state,
  ## 4 ppid, 5 pgrp, ..., 22 starttime. The post-')' remainder's tokens
  ## start at field 3 (state), so token index `k` is field `3 + k`;
  ## starttime (field 22) is token index 19 — the 20th token after comm.
  let openIdx = content.find('(')
  let closeIdx = content.rfind(')')
  let comm = if openIdx >= 0 and closeIdx > openIdx: content[openIdx + 1 ..< closeIdx]
             else: ""
  var ppid = -1
  var pgrp = -1
  var starttime = int64(-1)
  if closeIdx >= 0 and closeIdx + 2 < content.len:
    let rest = content[closeIdx + 2 .. ^1]
    let parts = rest.splitWhitespace()
    if parts.len >= 3:
      try: ppid = parseInt(parts[1])
      except ValueError: discard
      try: pgrp = parseInt(parts[2])
      except ValueError: discard
    if parts.len >= 20:
      try: starttime = parseBiggestInt(parts[19])
      except ValueError: discard
  (ppid, pgrp, comm, starttime)

proc readVmRssBytes(pid: int): int64 =
  try:
    let content = readFile("/proc/" & $pid & "/status")
    for line in content.splitLines():
      if line.startsWith("VmRSS:"):
        let parts = line.splitWhitespace()
        if parts.len >= 2:
          return int64(parseBiggestInt(parts[1])) * 1024
  except CatchableError:
    discard
  0'i64

type
  ProcStatInfo = object
    ## One /proc walk's raw yield per live pid — the shared source both
    ## `scanProcessGroup` (pgid-only, pre-B1 tier) and B1's
    ## `discoverAndReapEscapees`/orphan sweep fold over, so the two never
    ## drift onto separate readings of the same instant.
    pid, ppid, pgrp: int
    comm: string
    starttime: int64

proc walkProcTable(): seq[ProcStatInfo] =
  result = @[]
  try:
    for kind, path in walkDir("/proc"):
      if kind != pcDir: continue
      var pid: int
      try: pid = parseInt(path.extractFilename)
      except ValueError: continue
      try:
        let stat = readFile(path / "stat")
        let (ppid, pgrp, comm, starttime) = parseStatLine(stat)
        result.add ProcStatInfo(pid: pid, ppid: ppid, pgrp: pgrp, comm: comm,
                                starttime: starttime)
      except CatchableError:
        discard   # vanished between enumeration and read — skip it
  except CatchableError:
    discard         # /proc unreadable — empty snapshot, never fabricated

proc scanProcessGroup*(pgid: Pid): seq[ProcSnapshot] =
  ## Walk /proc, keep every pid whose pgrp == pgid. pgid-only tier — a
  ## setsid escape is invisible (§3); on the (non-Linux) tier where B1's
  ## subreaper mechanism never engages, `reapCore` reports
  ## `tree = treeObservationFor(kdsProcessGroup)` (always `toUnobservable`)
  ## regardless of what a given scan finds — observability is a property
  ## of the mechanism, not the scan.
  result = @[]
  for info in walkProcTable():
    if info.pgrp == int(pgid):
      result.add ProcSnapshot(pid: info.pid, ppid: info.ppid, command: info.comm,
                               rssBytes: readVmRssBytes(info.pid))

proc snapshotTreeCore*(core: PosixCore; id: ChildId): seq[ProcSnapshot] =
  let idx = int32(id)
  if idx notin core.children or core.children[idx].state == csReaped:
    doAssert false, "snapshotTree: unknown or consumed ChildId " & $id
  scanProcessGroup(core.children[idx].pid)

proc groupRssBytesCore*(core: PosixCore; id: ChildId): Option[int64] =
  let idx = int32(id)
  if idx notin core.children or core.children[idx].state == csReaped:
    doAssert false, "groupRssBytes: unknown or consumed ChildId " & $id
  var total: int64 = 0
  for snap in scanProcessGroup(core.children[idx].pid):
    total += snap.rssBytes
  some(total)

# ---------------------------------------------------------------------------
# next — the ONE wait primitive. Event-driven via pidfd+epoll+timerfd when
# `core.useEpoll` (rfc-0007 B2); poll(2) on the self-pipe with a 25ms tick
# otherwise (non-Linux, or CRISOL_FORCE_POLL) — the ORIGINAL, still-live
# fallback tier this file shipped with, unchanged in shape. Ready exits are
# ALWAYS drained before weDeadline in both tiers; the self-pipe is checked on
# every loop iteration, and a signal wakes `next` immediately instead of
# waiting out a fixed sleep (§1 shutdown-wakeup rule), regardless of which
# backend is blocking underneath.
# ---------------------------------------------------------------------------

proc decodeExit(wstatus: cint): Exit =
  if WIFEXITED(wstatus):
    Exit(kind: ekExited, code: int(WEXITSTATUS(wstatus)))
  elif WIFSIGNALED(wstatus):
    let coreDumped = (wstatus and 0x80) != 0   # WCOREDUMP — stable glibc ABI bit
    Exit(kind: ekSignaled, sig: int(WTERMSIG(wstatus)), coreDumped: coreDumped)
  else:
    Exit(kind: ekExited, code: 0)   # unreachable: never waited with WUNTRACED

proc decodeRusage(ru: posix.Rusage): types.Rusage =
  types.Rusage(
    maxRssBytes: int64(ru.ru_maxrss) * 1024,
    userCpuUs:   int64(ru.ru_utime.tv_sec) * 1_000_000 + int64(ru.ru_utime.tv_usec),
    sysCpuUs:    int64(ru.ru_stime.tv_sec) * 1_000_000 + int64(ru.ru_stime.tv_usec),
  )

proc drainSelfPipe(core: var PosixCore) =
  var buf: array[64, uint8]
  while true:
    let n = posix.read(core.pipeRead, addr buf[0], buf.len)
    if n <= 0: break
    for i in 0 ..< n:
      core.pendingShutdown.add ShutdownSignal(signum: int(buf[i]))

proc pollSweepChildren(core: var PosixCore): Option[int32] =
  ## One WNOHANG sweep; captures + decodes the FIRST newly-exited child.
  for id, entry in core.children.mpairs:
    if entry.state != csSpawned: continue
    var wstatus: cint = 0
    var ru: posix.Rusage
    let r = wait4(entry.pid, addr wstatus, WNOHANG, addr ru)
    if r == entry.pid:
      entry.exit = decodeExit(wstatus)
      entry.rusage = some(decodeRusage(ru))
      entry.state = csExited
      return some(id)
  none(int32)

when defined(linux):
  var P_ALL {.importc, header: "<sys/wait.h>".}: cint

  proc sweepAdoptedOrphan(core: var PosixCore): Option[WaitEvent] =
    ## rfc-0007 B1 (§3): beside the registered-child wait set above, peek
    ## for ANY exited child via `waitid(P_ALL, WNOWAIT)` — the ONLY way an
    ## ADOPTED orphan (reparented via PR_SET_CHILD_SUBREAPER, never in the
    ## spawn registry at all) is discovered: a naive `waitpid(-1)` loop
    ## would consume it blind, with no chance to attribute it to anything
    ## first. `WNOWAIT` leaves the zombie waitable — its pgid can still be
    ## read from /proc before this proc reaps it for real.
    ##
    ## `pollSweepChildren`, above this in `nextEvent`'s call order, already
    ## drains every registered exit it can SEE as of the top of this
    ## iteration — but a registered child that exits in the gap between
    ## `pollSweepChildren` returning "nothing yet" and this call's own
    ## `waitid(P_ALL, ...)` running is still findable here (`P_ALL` matches
    ## ANY exited child, registered or not). The own-pid check right after
    ## `orphanPid` below handles exactly that race by re-attributing it as
    ## the registered slot's normal exit, not an orphan — see its comment
    ## (B1 regression fix). Genuinely unregistered descendants (the ones
    ## this proc exists for) never match that check and fall through to
    ## the pgrp-based attribution as before. (A registered slot that is
    ## still ALIVE cannot match either path: `WEXITED` only matches
    ## children that have already terminated.)
    # Zeroing first is the portable way to detect "nothing ready" under
    # WNOHANG: POSIX only guarantees `si_pid` is set when a child WAS
    # found, not that it is zeroed when none was.
    var info: SigInfo
    zeroMem(addr info, sizeof(info))
    let rc = waitid(P_ALL, Id(0), info, WEXITED or WNOWAIT or WNOHANG)
    if rc != 0 or info.si_pid == 0:
      # ECHILD (no children of ANY kind right now) or WNOHANG-empty —
      # either way, nothing to report this call.
      return none(WaitEvent)
    let orphanPid = int(info.si_pid)
    # B1 regression fix: this `waitid(P_ALL, WNOWAIT)` races `pollSweep-
    # Children`'s per-pid `wait4(WNOHANG)` for a REGISTERED slot's OWN
    # exit — if that slot's process transitions from alive to exited in
    # the (nanosecond) gap between pollSweepChildren's loop finishing and
    # THIS call starting, this call — not pollSweepChildren's — is the one
    # that observes it (`P_ALL` matches ANY exited child, registered or
    # not; the docstring's "by construction never a registered pid" claim
    # above holds only for state as of the top of THIS `nextEvent`
    # iteration, not for a fresh exit landing in the gap between the two
    # checks within it). Left unhandled: the registered slot's own reap
    # gets stolen here (the `wait4` below consumes it for good) while its
    # `core.children` entry never leaves `csSpawned` — every future
    # `pollSweepChildren` attempt on that pid then returns ECHILD (already
    # reaped) forever, and the slot never reports `weChildExited`: a
    # permanent event-loop livelock (the `a2b_shared_grace` hang this
    # comment was written to fix). Checked BEFORE the pgrp-based orphan/
    # escapee attribution below, by the OWN pid (not pgrp): if `orphanPid`
    # IS some live registered slot's own pid, this is that slot's normal
    # exit, not an orphan at all — handle it exactly like
    # `pollSweepChildren` would and report `weChildExited` instead.
    for cid, e in core.children.pairs:
      if e.state == csSpawned and int(e.pid) == orphanPid:
        var wstatus: cint
        var ru: posix.Rusage
        discard wait4(Pid(orphanPid), addr wstatus, 0.cint, addr ru)  # the real reap
        var updated = e
        updated.exit = decodeExit(wstatus)
        updated.rusage = some(decodeRusage(ru))
        updated.state = csExited
        core.children[cid] = updated
        return some(WaitEvent(kind: weChildExited, id: ChildId(cid)))
    # Attribution BEFORE reap (§3): pgid, read while the zombie still
    # exists (WNOWAIT did not consume it).
    var ppid = -1
    var pgrp = -1
    var comm = ""
    try:
      let stat = readFile("/proc/" & $orphanPid & "/stat")
      let parsed = parseStatLine(stat)
      ppid = parsed.ppid
      pgrp = parsed.pgrp
      comm = parsed.comm
    except CatchableError:
      discard   # raced by something else reading it — attribution stays
                # honestly empty; the reap below still clears the zombie.
    let rss = readVmRssBytes(orphanPid)   # 0 for a zombie — honest, not fabricated
    var ownedBy = none(ChildId)
    for cid, e in core.children.pairs:
      if e.state == csSpawned and int(e.pid) == pgrp:
        ownedBy = some(ChildId(cid))
        break
    var wstatus: cint
    var ru: posix.Rusage
    discard wait4(Pid(orphanPid), addr wstatus, 0.cint, addr ru)  # the real reap
    let snap = ProcSnapshot(pid: orphanPid, ppid: ppid, command: comm, rssBytes: rss)
    return some(WaitEvent(kind: weOrphanReaped, orphan: snap, ownedBy: ownedBy))
else:
  proc sweepAdoptedOrphan(core: var PosixCore): Option[WaitEvent] = none(WaitEvent)

proc pollBlock(core: PosixCore; now: MonoTime; deadline: MonoTime) =
  ## The original (pre-B2) blocking step, unchanged: poll(2) on the
  ## self-pipe, bounded to a 25ms tick (never past it — the top of
  ## `nextEvent`'s loop re-checks everything regardless of why this
  ## returned). Live on two tiers: every non-Linux backend this file backs
  ## (no epoll/pidfd there at all), AND Linux with `CRISOL_FORCE_POLL` set
  ## or `probePidfd()` false — the RFC's "falls back to polling when pidfd
  ## is absent" requirement, proven by running the conformance suite with
  ## the knob forced (tests/conformance/test_conformance_timing.nim's B2
  ## suite).
  let remainMs = (deadline - now).inMilliseconds
  let tickMs = cint(min(25'i64, max(1'i64, remainMs)))
  var pfd: TPollfd
  pfd.fd = core.pipeRead
  pfd.events = POLLIN
  discard poll(addr pfd, 1, tickMs)

when defined(linux):
  proc epollBlock(core: PosixCore; now: MonoTime; deadline: MonoTime) =
    ## rfc-0007 B2: the event-driven blocking step. Two independent, both
    ## genuinely load-bearing bounds compose here:
    ##   - `core.timerFd` is (re-)armed to the EXACT caller `deadline` on
    ##     every pass, so a deadline nearer than 25ms away still wakes
    ##     `epoll_wait` via a real registered event rather than merely
    ##     being inferred from a rounded ms timeout — this is what keeps
    ##     tight windows (term_ignores' 300ms grace, a runner slot's own
    ##     imminent timeout) exact rather than rounded up to the next tick.
    ##   - `epoll_wait`'s OWN ms timeout is separately capped at 25ms so the
    ##     orphan sweep / RSS-sample ceiling still runs even when the
    ##     caller's deadline is far away (conformance's 5s/10s deadlines) —
    ##     the same cadence the pre-B2 poll(2) tick provided.
    ## A registered child's pidfd becoming readable wakes this EARLY — the
    ## actual latency win over the pre-B2 "wait out up to 25ms, then poll"
    ## shape (proven by test_conformance_timing.nim's B2 latency case). The
    ## returned event list is deliberately NOT inspected: `nextEvent`'s own
    ## loop top unconditionally re-drains self-pipe / pollSweepChildren /
    ## sweepAdoptedOrphan on every iteration regardless of which fd(s) woke
    ## it — exactly what the old poll(2) step already did — so a spurious or
    ## coalesced epoll wakeup is harmless, and the actual wait4() reap stays
    ## the SAME single code path (pollSweepChildren) for both backends: a
    ## registered child's exit is never observed-and-reaped via the pidfd
    ## event itself, only woken by it, so there is no second reap path to
    ## race the waitid(P_ALL, WNOWAIT) orphan sweep against (lesson from B1).
    var spec: Itimerspec
    zeroMem(addr spec, sizeof(spec))
    let remainingNs = max(0'i64, (deadline - now).inNanoseconds)
    spec.it_value.tv_sec = posix.Time(remainingNs div 1_000_000_000)
    spec.it_value.tv_nsec = clong(remainingNs mod 1_000_000_000)
    if remainingNs == 0:
      spec.it_value.tv_nsec = 1   # 0 would DISARM (timerfd_settime semantics)
    discard timerfd_settime(core.timerFd, 0.cint, addr spec, nil)
    let remainMs = (deadline - now).inMilliseconds
    let waitMs = cint(min(25'i64, max(1'i64, remainMs)))
    var events: array[8, EpollEvent]
    discard epoll_wait(core.epollFd, addr events[0], cint(events.len), waitMs)

proc nextEvent*(core: var PosixCore; deadline: MonoTime): WaitEvent =
  while true:
    core.drainSelfPipe()
    if core.pendingShutdown.len > 0:
      let sig = core.pendingShutdown[0]
      core.pendingShutdown = core.pendingShutdown[1 .. ^1]
      return WaitEvent(kind: weShutdown, signal: sig)

    # LEVEL-TRIGGERED: any child already in csExited is re-reported every
    # call until reaped — a lost event cannot wedge a slot (§1).
    for id, entry in core.children.pairs:
      if entry.state == csExited:
        return WaitEvent(kind: weChildExited, id: ChildId(id))

    let found = pollSweepChildren(core)
    if found.isSome:
      return WaitEvent(kind: weChildExited, id: ChildId(found.get))

    # rfc-0007 B1 (§3): the orphan sweep — LOWEST priority, checked only
    # once every registered exit above has been drained (so it can never
    # race a registered slot's own reap; see sweepAdoptedOrphan's doc).
    let orphanEvent = sweepAdoptedOrphan(core)
    if orphanEvent.isSome:
      return orphanEvent.get

    let now = getMonoTime()
    if now >= deadline:
      return WaitEvent(kind: weDeadline)

    when defined(linux):
      if core.useEpoll:
        epollBlock(core, now, deadline)
      else:
        pollBlock(core, now, deadline)
    else:
      pollBlock(core, now, deadline)
    # Result ignored either way — the top of the loop re-checks everything
    # (self-pipe, exited-but-unreaped, and a fresh WNOHANG sweep).

# ---------------------------------------------------------------------------
# requestStop / forceKill — non-blocking, idempotent, atomic-against-exit-
# observation act recording (§1).
# ---------------------------------------------------------------------------

proc requireLive(core: PosixCore; id: ChildId): int32 =
  let idx = int32(id)
  if idx notin core.children or core.children[idx].state == csReaped:
    doAssert false, "misuse: ChildId " & $id & " is unknown or already consumed"
  idx

proc requestStopCore*(core: var PosixCore; id: ChildId; reason: KillReason) =
  let idx = requireLive(core, id)
  var entry = core.children[idx]
  if entry.state == csExited:
    return   # exit already observed — atomic no-op, records nothing (§1)
  if entry.stop.isSome:
    return   # first act wins
  entry.killSnapshot = scanProcessGroup(entry.pid)   # taken at the FIRST stop act
  entry.stop = some((reason: reason, escalated: false))
  discard killpg(entry.pid, SIGTERM)
  core.children[idx] = entry

proc forceKillCore*(core: var PosixCore; id: ChildId) =
  let idx = requireLive(core, id)
  var entry = core.children[idx]
  if entry.state == csExited:
    return   # atomic no-op — same rule as requestStop
  entry.killSnapshot = scanProcessGroup(entry.pid)   # refreshed at forced kill
  discard killpg(entry.pid, SIGKILL)
  if entry.stop.isSome:
    entry.stop = some((reason: entry.stop.get.reason, escalated: true))
  else:
    # forceKill with no prior requestStop (a direct/skip-grace call — the
    # executor's real usage always calls requestStop first, per A2b's
    # second-interrupt rule; this arm is the documented defensive fallback,
    # §1 leaves forceKill with no `reason` parameter, so krTimeout is the
    # least-surprising default for a direct force).
    entry.stop = some((reason: krTimeout, escalated: true))
  core.children[idx] = entry

# ---------------------------------------------------------------------------
# rfc-0007 B1 (§3): the subreaper-tier escapee kill+reap mechanism —
# reapCore's owning-slot discovery of LIVE + reparented descendants, killed
# via pidfd_open + a starttime identity check (pid-reuse-safe), then reaped.
# ---------------------------------------------------------------------------

proc cachedCapabilities*(): Capabilities
  ## Forward declaration — the real probe/memo lives in the capabilities
  ## section below (this proc predates that section textually so
  ## `reapCore` can consult it for the achieved killDomain).

proc reapBounded(pid: Pid) =
  ## B1 regression fix, part A: a SIGKILL target becomes a reapable zombie
  ## essentially immediately, but `discoverAndReapEscapees` runs ON the
  ## single-threaded event-loop thread — an unbounded blocking `wait4(pid,
  ## 0)` here would starve the WHOLE loop (self-pipe/SIGINT wakeup included)
  ## on any target that does not die promptly, turning a 6s interrupt into
  ## a full wall-clock timeout downstream. Bounded, non-blocking WNOHANG
  ## polling instead: try for up to ~300ms total (5ms between tries), then
  ## give up WITHOUT ever blocking. The run-level `sweepAdoptedOrphan`
  ## (nextEvent) is the honest fallback home for a genuine straggler, not
  ## this proc — this bound only guards the pathological case.
  const budgetMs = 300
  const stepMs = 5
  var waited = 0
  while waited < budgetMs:
    var wstatus: cint
    var ru: posix.Rusage
    let r = wait4(pid, addr wstatus, WNOHANG, addr ru)
    if r == pid or r < 0:
      return   # reaped, or ECHILD (not ours to reap) — either way, done
    os.sleep(stepMs)
    waited += stepMs

when defined(linux):
  proc discoverAndReapEscapees(core: PosixCore; excludeIdx: int32; pgid: Pid;
                               caps: Capabilities; runPhase: bool): seq[ProcSnapshot] =
    ## Owning-slot escapees (§3): every /proc entry whose pgrp matches this
    ## slot's domain pgid (same-pgroup survivor, the pre-B1 case) OR whose
    ## ppid is crisol's own pid (reparented via PR_SET_CHILD_SUBREAPER —
    ## covers a setsid escape, invisible to the pgid test alone) —
    ## excluding this process itself and every OTHER still-live registered
    ## slot (their own descendants are none of THIS reap's business; each
    ## slot's own eventual reap claims its own). Only engaged on the real
    ## subreaper+pidfd tier (caps.subreaper and caps.pidfd) — otherwise
    ## falls back to the pre-B1 observe-only pgid scan: without a real
    ## subreaper a reparented-orphan claim would be unfounded, and without
    ## pidfd there is no pid-reuse-safe kill handle.
    ##
    ## B1 regression fix, part B: `runPhase` scopes the ppid==ownPid
    ## (reparented-orphan) half of this discovery to genuine RUN-phase
    ## reaps only. `reapCore` runs for EVERY reap, including compile-phase
    ## ones — and crisol's own compile toolchain (`nim` -> `cc`/`gcc`, both
    ## `# process-contract-exempt`) can transiently reparent to crisol (a
    ## subreaper) mid-compile. Without this guard that toolchain transient
    ## would be misclassified as a test escapee: a normal compile would go
    ## spuriously uncacheable and render a bogus `[ESCAPEE]` warning — test
    ## escapees (spawn_grandchild/spawn_grandchild_setsid) are a RUN-phase
    ## concept only. When `runPhase` is false this falls back to the exact
    ## pre-B1 compile path: pgid-only `scanProcessGroup`, no ppid scan, no
    ## kill. Accepted misattribution window (never unsound, per the RFC's
    ## "named misattribution windows" posture): a concurrent toolchain
    ## transient rarely reparenting during an ACTUAL run reap could still be
    ## counted as that slot's escapee — conservatively uncacheable, that's
    ## all.
    if not runPhase or not (caps.subreaper and caps.pidfd):
      return scanProcessGroup(pgid)
    result = @[]
    var livePids: HashSet[int]
    for cid, e in core.children.pairs:
      if cid != excludeIdx and e.state != csReaped:
        livePids.incl int(e.pid)
    let ownPid = int(getpid())
    var seen: HashSet[int]
    for info in walkProcTable():
      if info.pid == ownPid: continue
      if info.pid in livePids: continue
      if info.pid in seen: continue
      if info.pgrp != int(pgid) and info.ppid != ownPid: continue
      seen.incl info.pid
      let pidfd = cint(c_syscall(SYS_pidfd_open, clong(info.pid), 0.clong))
      if pidfd < 0:
        continue  # already vanished between the walk and here — a genuine
                   # self-death this scan just missed; B1b's orphan sweep
                   # (nextEvent) is the honest home for it, not here.
      # Starttime identity check BEFORE signalling (§3): the pid could have
      # been reused between the /proc walk above and this instant — killing
      # by the raw snapshot pid alone is exactly the race the pgid design
      # avoids everywhere else, so the fd from pidfd_open (bound to the
      # specific process instance) is necessary but re-reading
      # /proc/<pid>/stat is what confirms WHICH instance it is.
      var curStarttime = int64(-1)
      try:
        let stat2 = readFile("/proc/" & $info.pid & "/stat")
        let (_, _, _, st2) = parseStatLine(stat2)
        curStarttime = st2
      except CatchableError:
        discard
      if curStarttime != info.starttime:
        discard posix.close(pidfd)
        continue   # reused (or vanished) — do NOT kill; treat as vanished
      let rss = readVmRssBytes(info.pid)
      discard c_syscall(SYS_pidfd_send_signal, clong(pidfd), clong(cint(SIGKILL)),
                        0.clong, 0.clong)
      discard posix.close(pidfd)
      reapBounded(Pid(info.pid))
        # Bounded, not blocking (part A above): SIGKILL is unblockable, so
        # the target becomes a reapable zombie essentially immediately in
        # practice — `reapBounded` reaps it within a few ms. A failure to
        # reap within the bound (e.g. ECHILD — a same-pgroup descendant
        # several levels down whose OWN immediate parent is a different,
        # still-uncollected orphan, so THIS process is not its real parent)
        # is silently accepted: a documented, accepted misattribution/
        # collection-depth window (the RFC's "named misattribution windows"
        # posture), not a crash — and never a blocked event loop.
      result.add ProcSnapshot(pid: info.pid, ppid: info.ppid, command: info.comm,
                              rssBytes: rss)
else:
  proc discoverAndReapEscapees(core: PosixCore; excludeIdx: int32; pgid: Pid;
                               caps: Capabilities; runPhase: bool): seq[ProcSnapshot] =
    scanProcessGroup(pgid)

# ---------------------------------------------------------------------------
# reap — the only place a ChildId is consumed (§1).
# ---------------------------------------------------------------------------

proc reapCore*(core: var PosixCore; id: ChildId; runPhase: bool): ReapReport =
  ## `runPhase` (B1 regression fix, part B): true iff this reap is for a
  ## genuine RUN-phase child (the executor's `finalizeSlot` passes
  ## `slot.phase == spRunning`) — gates `discoverAndReapEscapees`'s
  ## reparented-orphan (ppid==ownPid) discovery+kill so it never engages on
  ## a compile-phase reap. See that proc's doc comment for why.
  let idx = int32(id)
  if idx notin core.children:
    doAssert false, "reap: unknown ChildId " & $id
  let entry = core.children[idx]
  if entry.state != csExited:
    doAssert false, "reap: weChildExited was never reported for ChildId " & $id
  let caps = cachedCapabilities()
  # rfc-0007 B1 (§3): the owning slot's LIVE + reparented escapees,
  # discovered, killed (pidfd_open + starttime identity check), and reaped
  # — see discoverAndReapEscapees above. `entry.pid` doubles as the domain
  # pgid (spawnChild calls setpgid(childPid, childPid)); the leader itself
  # is already gone from /proc (pollSweepChildren's wait4 already consumed
  # it), so only real survivors/descendants remain in the scan.
  let escapees = discoverAndReapEscapees(core, idx, entry.pid, caps, runPhase)
  # A7/B1 (§4/§3): the per-spawn ACHIEVED domain — kdsProcessGroupSubreaper
  # iff this process is REALLY a subreaper (initPosixCore sets
  # PR_SET_CHILD_SUBREAPER deliberately; the probe's own readback confirms
  # it), else the pre-B1 kdsProcessGroup. `treeObservationFor`
  # (process/types.nim) ties `tree` to this by construction: a subreaper
  # sees the WHOLE descendant tree by construction, so `toComplete` is
  # honest here even when `escapees` is non-empty — tree completeness and
  # "did anything survive" are separate axes (§2/§6).
  let domain = if caps.subreaper: kdsProcessGroupSubreaper else: kdsProcessGroup
  result = ReapReport(
    exit: entry.exit,
    rusage: entry.rusage,
    stop: entry.stop,
    killDomain: domain,
    limits: entry.achieved,
    killSnapshot: entry.killSnapshot,
    tree: treeObservationFor(domain),
    escapees: escapees,
    cooperativeUnavailable: false,   # POSIX: SIGTERM is always deliverable (§3)
  )
  when defined(linux):
    # rfc-0007 B2: reap is the ONLY place a ChildId is consumed (§1) — so it
    # is also the only correct place to release this child's pidfd
    # registration. `entry.pidfd >= 0` iff spawnChild actually registered
    # one (useEpoll AND pidfd_open/epoll_ctl both succeeded); otherwise this
    # is a no-op, same as every other -1-sentinel guard in this file.
    if entry.pidfd >= 0:
      discard epoll_ctl(core.epollFd, EPOLL_CTL_DEL, entry.pidfd, nil)
      discard posix.close(entry.pidfd)
  core.children[idx] = ChildEntry(state: csReaped, pidfd: -1)   # tombstone: pid dropped
  dec core.liveCount

# ---------------------------------------------------------------------------
# capabilities — rfc-0007 A7 (§4): EVERY field below is a REAL, live probe
# (attempt the mechanism, verify it worked; never an assumed/hardcoded
# literal) — pidfd/subreaper/cgroup are Linux-only kernel features (prctl(2)
# and pidfd_open(2) do not exist on Darwin), so they are `when defined(linux)`
# gated; this same file is also today's macOS backend (§1 module-layout
# comment: "macosx maps to process/posix until C1b"), and an unconditional
# importc of a Linux-only syscall constant would fail `nim check --os:macosx`
# outright, not just report false at runtime. flock/wait4 are genuinely
# POSIX-portable (both probed for real on any posix target this file backs).
# kqueue/jobObjectNesting/ctrlBreakDeliverable are the OTHER backends' own
# fields (windows.nim/darwin.nim) — always false here, never this module's
# claim to make.
#
# Probed exactly once per process (`cachedCapabilities`, ccprobe/nimprobe's
# `cachedX` idiom) — every real probe below does actual I/O (fork+wait4,
# flock a tempfile, mkdir+write under /sys/fs/cgroup) so re-running it on
# every `capabilities()` call would be wasteful, not merely un-idiomatic.
# ---------------------------------------------------------------------------

when defined(linux):
  # cgroup v2 delegation (§4): "mkdir a leaf + write cgroup.procs" is the
  # RFC's own recipe, tried on THIS process (moved back to its original
  # cgroup and the leaf removed afterward, on every path). A delegated
  # 5.15 LTS host must probe green for delegation and red for the files it
  # lacks — cgroup.kill/memory.peak are only even CHECKED inside a leaf
  # that delegation itself proved writable; never probed independently
  # (never "fail per-file at spawn time" — §4).
  proc ownCgroupV2Path(): string =
    ## Reads /proc/self/cgroup's unified (v2) line: "0::<path>".
    try:
      for line in lines("/proc/self/cgroup"):
        if line.startsWith("0::"):
          return line[3 .. ^1]
    except CatchableError:
      discard
    ""

  proc probeCgroupV2(): tuple[delegation, kill, memoryPeak: bool] =
    result = (delegation: false, kill: false, memoryPeak: false)
    let relPath = ownCgroupV2Path()
    if relPath.len == 0: return
    let base = "/sys/fs/cgroup" & relPath
    let leaf = base / ("crisol-probe-" & $getpid())
    try:
      createDir(leaf)
    except CatchableError:
      return   # not writable here (e.g. rootless podman: read-only cgroupfs)
    try:
      writeFile(leaf / "cgroup.procs", $getpid() & "\n")
      result.delegation = true
      result.kill = fileExists(leaf / "cgroup.kill")
      result.memoryPeak = fileExists(leaf / "memory.peak")
    except CatchableError:
      discard   # mkdir succeeded but the move failed — honestly not delegated
    try: writeFile(base / "cgroup.procs", $getpid() & "\n")   # move back FIRST —
    except CatchableError: discard                             # a non-empty
    try: removeDir(leaf)                                       # cgroup can't rmdir
    except CatchableError: discard
else:
  proc probeCgroupV2(): tuple[delegation, kill, memoryPeak: bool] =
    (delegation: false, kill: false, memoryPeak: false)

# flock(2) is BSD/Linux, not POSIX, and absent from std/posix — same
# duplicate-importc idiom lock.nim already uses (safe: no C definition is
# emitted, only a reference through the header).
proc c_flock(fd: cint; operation: cint): cint {.importc: "flock",
                                                header: "<sys/file.h>".}
var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
var LOCK_UN {.importc, header: "<sys/file.h>".}: cint
var LOCK_NB {.importc, header: "<sys/file.h>".}: cint

proc probeFlock(): bool =
  let path = getTempDir() / ("crisol-flock-probe-" & $getpid())
  try:
    let f = open(path, fmWrite)
    defer:
      close(f)
      try: removeFile(path)
      except CatchableError: discard
    let fd = getFileHandle(f).cint
    if c_flock(fd, LOCK_EX or LOCK_NB) != 0: return false
    discard c_flock(fd, LOCK_UN)
    true
  except CatchableError:
    false

proc probeWait4Rusage(): bool =
  ## A throwaway fork+wait4 (not "wait4 is called elsewhere in this module,
  ## therefore assume true") — some sandboxes filter wait4/rusage collection
  ## via seccomp; this actually exercises the syscall once and checks the
  ## real return value.
  let pid = fork()
  if pid == 0:
    exitnow(0)   # async-signal-safe: no Nim runtime after fork in the child
  elif pid > 0:
    var status: cint
    var ru: posix.Rusage
    let r = wait4(pid, addr status, 0.cint, addr ru)
    r == pid
  else:
    false

proc probeCapabilities*(): Capabilities =
  ## The raw, seam-free probe — real I/O, freely callable (mirrors
  ## `ccprobe.ccVersion` / `nimprobe.nimFingerprint`: the pure-ish real
  ## probe stays exported and un-memoised; `cachedCapabilities` below is
  ## the memoised wrapper every production call site actually uses).
  let cg = probeCgroupV2()
  Capabilities(
    pidfd: probePidfd(),
    subreaper: probeSubreaper(),
    cgroupDelegation: cg.delegation,
    cgroupKill: cg.kill,
    memoryPeak: cg.memoryPeak,
    kqueue: false,              # darwin.nim's field (C1b), never this module's
    jobObjectNesting: false,    # windows.nim's field (Stage D), never this module's
    ctrlBreakDeliverable: false,# windows.nim's field (Stage D), never this module's
    flock: probeFlock(),
    wait4Rusage: probeWait4Rusage(),
  )

var capabilitiesMemo: Option[Capabilities] = none(Capabilities)

proc cachedCapabilities*(): Capabilities =
  ## Probed exactly once per process; every later caller — Supervisor-
  ## backed (`capabilities(sv)`) or not (the plan/list CLI path, which
  ## never spawns anything) — reads the SAME memoised value (§4).
  if capabilitiesMemo.isNone:
    capabilitiesMemo = some(probeCapabilities())
  capabilitiesMemo.get

proc capabilitiesCore*(core: PosixCore): Capabilities =
  cachedCapabilities()
