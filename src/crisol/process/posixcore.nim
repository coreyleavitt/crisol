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

import std/[options, os, posix, strutils, tables, monotimes, times]
import crisol/process/types

# ---------------------------------------------------------------------------
# rlimit constants missing from std/posix (same set spawn.nim importc's).
# ---------------------------------------------------------------------------

var RLIMIT_CORE   {.importc: "RLIMIT_CORE",   header: "<sys/resource.h>".}: cint
var RLIMIT_FSIZE  {.importc: "RLIMIT_FSIZE",  header: "<sys/resource.h>".}: cint
var RLIMIT_CPU    {.importc: "RLIMIT_CPU",    header: "<sys/resource.h>".}: cint
var RLIMIT_AS     {.importc: "RLIMIT_AS",     header: "<sys/resource.h>".}: cint

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

  PosixCore* = object
    nextIdVal: int32
    children: Table[int32, ChildEntry]
    liveCount: int             ## spawned, not yet reaped — the =destroy guard.
    pipeRead, pipeWrite: cint
    installedSignals: bool
    pendingShutdown: seq[ShutdownSignal]

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
                      installedSignals: installSignals)
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
  if installSignals:
    gShutdownWriteFd = fds[1]
    var sa: Sigaction
    sa.sa_handler = shutdownSigHandler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = SA_RESTART
    discard sigaction(SIGINT, sa, nil)
    discard sigaction(SIGTERM, sa, nil)

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
                                  reqLimits: spec.limits, achieved: achieved)
  inc core.liveCount
  SpawnResult(ok: true, id: ChildId(id))

# ---------------------------------------------------------------------------
# /proc forensics — snapshotTree (kill/reap forensics) and groupRssBytes (the
# live sampler). Same pgid-scan mechanism, two cadences/shapes (§1 §7):
# groupRssBytes is memprobe.procGroupRssBytes' algorithm re-homed; A2b wires
# memprobe/admission to call through the Supervisor instead of duplicating it.
# ---------------------------------------------------------------------------

proc parseStatLine(content: string): tuple[ppid, pgrp: int; comm: string] =
  ## /proc/<pid>/stat: "pid (comm) state ppid pgrp ...". comm may itself
  ## contain spaces/parens, so split on the LAST ')' (same technique
  ## test_pgroup.nim already uses for the same reason).
  let openIdx = content.find('(')
  let closeIdx = content.rfind(')')
  let comm = if openIdx >= 0 and closeIdx > openIdx: content[openIdx + 1 ..< closeIdx]
             else: ""
  var ppid = -1
  var pgrp = -1
  if closeIdx >= 0 and closeIdx + 2 < content.len:
    let rest = content[closeIdx + 2 .. ^1]
    let parts = rest.splitWhitespace()
    if parts.len >= 3:
      try: ppid = parseInt(parts[1])
      except ValueError: discard
      try: pgrp = parseInt(parts[2])
      except ValueError: discard
  (ppid, pgrp, comm)

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

proc scanProcessGroup*(pgid: Pid): seq[ProcSnapshot] =
  ## Walk /proc, keep every pid whose pgrp == pgid. pgid-only tier — a
  ## setsid escape is invisible (§3), which is exactly why `reapCore`
  ## reports `tree = treeObservationFor(kdsProcessGroup)` (A6a: always
  ## `toUnobservable` on this backend) regardless of what a given scan
  ## finds — observability is a property of the mechanism, not the scan.
  result = @[]
  try:
    for kind, path in walkDir("/proc"):
      if kind != pcDir: continue
      var pid: int
      try: pid = parseInt(path.extractFilename)
      except ValueError: continue
      try:
        let stat = readFile(path / "stat")
        let (ppid, pgrp, comm) = parseStatLine(stat)
        if pgrp == int(pgid):
          result.add ProcSnapshot(pid: pid, ppid: ppid, command: comm,
                                   rssBytes: readVmRssBytes(pid))
      except CatchableError:
        discard   # vanished between enumeration and read — skip it
  except CatchableError:
    discard         # /proc unreadable — empty snapshot, never fabricated

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
# next — the ONE wait primitive. Poll-based (25 ms tick, the documented
# fallback tier — pidfd/epoll is B1). Ready exits are ALWAYS drained before
# weDeadline; the self-pipe is checked on every loop iteration, and blocking
# happens via poll(2) on the self-pipe read fd so a signal wakes `next`
# immediately instead of waiting out a fixed sleep (§1 shutdown-wakeup rule).
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

    let now = getMonoTime()
    if now >= deadline:
      return WaitEvent(kind: weDeadline)

    let remainMs = (deadline - now).inMilliseconds
    let tickMs = cint(min(25'i64, max(1'i64, remainMs)))
    var pfd: TPollfd
    pfd.fd = core.pipeRead
    pfd.events = POLLIN
    discard poll(addr pfd, 1, tickMs)
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
# reap — the only place a ChildId is consumed (§1).
# ---------------------------------------------------------------------------

proc reapCore*(core: var PosixCore; id: ChildId): ReapReport =
  let idx = int32(id)
  if idx notin core.children:
    doAssert false, "reap: unknown ChildId " & $id
  let entry = core.children[idx]
  if entry.state != csExited:
    doAssert false, "reap: weChildExited was never reported for ChildId " & $id
  # rfc-0007 A6a (§6): the post-reap pgid scan — ALWAYS performed, not
  # gated on a stop act. `spawn_grandchild` leaks a same-pgroup grandchild
  # while the entrypoint itself exits 0 on its own, no kill involved; the
  # escapee fact must still be caught. `entry.pid` doubles as the pgid
  # (spawnChild calls setpgid(childPid, childPid)) and is still valid here
  # — the leader is gone from /proc (just reaped), so only real survivors
  # remain in the scan.
  let escapees = scanProcessGroup(entry.pid)
  result = ReapReport(
    exit: entry.exit,
    rusage: entry.rusage,
    stop: entry.stop,
    killDomain: kdsProcessGroup,     # interim table: kdsProcessGroup until A7
    limits: entry.achieved,
    killSnapshot: entry.killSnapshot,
    tree: treeObservationFor(kdsProcessGroup),
    escapees: escapees,
    cooperativeUnavailable: false,   # POSIX: SIGTERM is always deliverable (§3)
  )
  core.children[idx] = ChildEntry(state: csReaped)   # tombstone: pid dropped
  dec core.liveCount

# ---------------------------------------------------------------------------
# capabilities — probed once by the caller and memoised there (§4). Honest,
# minimal claims for this slice's poll-based backend: only mechanisms this
# module genuinely provides are true. pidfd/subreaper/cgroup/kqueue/Job
# nesting/CTRL_BREAK are B1-D1 territory and stay false — "nothing in this
# RFC is required to be present" (§4), not a placeholder.
# ---------------------------------------------------------------------------

proc capabilitiesCore*(core: PosixCore): Capabilities =
  Capabilities(
    pidfd: false, subreaper: false, cgroupDelegation: false, cgroupKill: false,
    memoryPeak: false, kqueue: false, jobObjectNesting: false,
    ctrlBreakDeliverable: false,
    flock: true,          # flock(2) is always available on Linux (A4 wires lock.nim)
    wait4Rusage: true,    # wait4 is used at every reap site in this module
  )
