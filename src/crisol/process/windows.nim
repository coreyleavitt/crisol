## process/windows.nim — rfc-0007 §1/§3 A2d: the Windows Supervisor backend
## spike. Purpose (A2d bullet): freeze the §1 contract's SIGNATURES against
## real Win32 — not "conformance-green" (that's RFC-0009 territory, Stage D),
## but genuinely functional on the smoke path (spawn a child, observe its
## exit code losslessly, kill a hanging child through the real kill domain)
## with every other surface honestly degraded rather than faked.
##
## What is REAL here:
##   - spawn: CreateProcessW (suspended) + a real Job Object with
##     KILL_ON_JOB_CLOSE, assigned before the child's main thread ever runs,
##     then ResumeThread — a genuine kill-domain guarantee (§3's "Job Object,
##     KILL_ON_JOB_CLOSE, breakaway disabled" row), not a bookkeeping fiction.
##   - next: WaitForMultipleObjects over live child handles (+ the shutdown
##     event when installed) — §1's small-N fallback tier, explicitly
##     sanctioned by the contract text ("WaitForMultipleObjects only as a
##     small-N fallback — its 64-handle cap is a real bound"); a full
##     completion-port `next` is D1a territory, not this spike's.
##   - requestStop: real GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT) — gated
##     on a REAL probed console-topology check, never assumed deliverable.
##   - forceKill: real TerminateJobObject — the guaranteed kill path,
##     independent of console topology; this is what the smoke test proves.
##   - reap: real GetExitCodeProcess (the §2 Windows exit-code/ekNtStatus
##     partition) and real Job accounting rusage (QueryInformationJobObject:
##     JOBOBJECT_BASIC_ACCOUNTING_INFORMATION for CPU time,
##     JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakJobMemoryUsed for
##     maxRssBytes — a genuine peak-RSS analog to POSIX's ru_maxrss, no
##     psapi dependency needed for this one).
##   - capabilities: jobObjectNesting is a REAL functional probe (spawns a
##     throwaway suspended process, never this process itself, and attempts
##     a double Job assignment); ctrlBreakDeliverable is a REAL console
##     probe (GetConsoleCP).
##
## What is HONESTLY DEGRADED (never fabricated — §1's weakest-honest-claim
## rule), and why, per proc:
##   - Limits: Win32 has NO pre-exec child window (no fork/exec split to
##     hook a status pipe into — CreateProcessW hands control straight to
##     the image). Every REQUESTED limit reports `lsUnsupported`
##     unconditionally this spike, regardless of kind — Job Objects CAN
##     express a `lkCpu`/`lkAddressSpace` analog (PerProcessUserTimeLimit /
##     ProcessMemoryLimit) but this spike does not wire them (D1b's job, per
##     §5 "Windows maps Limits to Job basic/extended limits"); `lkFileSize`/
##     `lkOpenFiles`/`lkCore` have NO Windows analog at all, ever
##     (§5: "openFiles has no analog and is reported lsUnsupported").
##   - snapshotTree: returns `@[]` unconditionally — toUnobservable-grade
##     emptiness. A real implementation needs
##     `JobObjectBasicProcessIdList` + a per-pid rssBytes source; D1a's job.
##   - groupRssBytes: returns `none()`. Job accounting's only cheap
##     "memory" figure is PeakJobMemoryUsed — a MONOTONIC peak-since-job-
##     start, not the CURRENT live sum this proc's contract promises (§1:
##     "the group-RSS sum and nothing else", sampled every 25 ms for
##     admission). Reporting a stale peak as "current" would systematically
##     over-report and under-admit — a lie in the conservative direction,
##     still a lie. A true current-sum needs psapi
##     (`GetProcessMemoryInfo`) walked over `JobObjectBasicProcessIdList`'s
##     pid list; D2's job (memprobe wiring).
##   - Evidence.tree / escapees: `toUnobservable` / `@[]` always — the same
##     "no snapshot mechanism wired yet" honesty as above.
##
## FINDING (recorded per the A2d bullet's instruction — no signature change
## needed, but worth stating): §1's forceKill doc says escalated is false
## "when the cooperative step was never attempted (cooperativeUnavailable)".
## On POSIX this branch is dead code (`cooperativeUnavailable` is always
## false there — SIGTERM is always deliverable). Windows is the first
## backend where it actually fires: `forceKill` here computes
## `escalated := stop.isSome AND NOT cooperativeUnavailable`, not
## `stop.isSome` alone (posixcore's simpler rule). The CONTRACT already
## says this (§1); implementing a backend where it is reachable is what
## surfaced it. No signature or doc change required — it validates the
## existing `cooperativeUnavailable` field is wired to exactly the field
## it needs to gate.
##
## `process.nim`'s ladder already points `when defined(windows)` here
## (A2a-i landed the ladder before this module existed); this file makes
## that arm real.

import std/[options, os, tables, monotimes, times]
import std/winlean
import crisol/process/types

export types

# ---------------------------------------------------------------------------
# Win32 surface missing from std/winlean: Job Objects, console-ctrl events,
# and the shutdown-wakeup event. Hand-rolled ABI structs + importc, no
# `header` pragma — same no-header convention winlean.nim itself uses, so
# `nim check --os:windows` resolves everything from Nim source alone (§1's
# "checkable per platform from any host" promise), never a MinGW header path.
# ---------------------------------------------------------------------------

type
  JOBOBJECT_BASIC_LIMIT_INFORMATION = object
    perProcessUserTimeLimit: int64      # LARGE_INTEGER, 100ns units
    perJobUserTimeLimit: int64
    limitFlags: int32                   # DWORD
    minimumWorkingSetSize: uint         # SIZE_T
    maximumWorkingSetSize: uint
    activeProcessLimit: int32
    affinity: uint                      # ULONG_PTR
    priorityClass: int32
    schedulingClass: int32

  IO_COUNTERS = object
    readOperationCount, writeOperationCount, otherOperationCount: uint64
    readTransferCount, writeTransferCount, otherTransferCount: uint64

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION = object
    basicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION
    ioInfo: IO_COUNTERS
    processMemoryLimit: uint            # SIZE_T
    jobMemoryLimit: uint
    peakProcessMemoryUsed: uint
    peakJobMemoryUsed: uint

  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = object
    totalUserTime: int64                # LARGE_INTEGER, 100ns units
    totalKernelTime: int64
    thisPeriodTotalUserTime: int64
    thisPeriodTotalKernelTime: int64
    totalPageFaultCount: int32
    totalProcesses: int32
    activeProcesses: int32
    totalTerminatedProcesses: int32

const
  jicBasicAccounting = 1'i32
  jicExtendedLimit    = 9'i32
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE  = 0x00002000'i32
  CREATE_SUSPENDED                    = 0x00000004'i32
  CREATE_NEW_PROCESS_GROUP            = 0x00000200'i32
  CTRL_C_EVENT                        = 0'i32
  CTRL_BREAK_EVENT                    = 1'i32
  jobForceKillExitCode                = 0x4B494C4C'i32
    ## ASCII "KILL", < 0xC0000000 so it lands in `ekExited` (§2's Windows
    ## exit partition) — disambiguated from a genuine same-code exit by
    ## `Cause`, not by the code itself (§2's documented heuristic).

proc createJobObjectW(lpJobAttributes: ptr SECURITY_ATTRIBUTES;
                       lpName: WideCString): Handle
  {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
proc assignProcessToJobObject(hJob, hProcess: Handle): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}
proc setInformationJobObject(hJob: Handle; jobObjectInfoClass: int32;
                              lpJobObjectInfo: pointer;
                              cbJobObjectInfoLength: int32): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "SetInformationJobObject".}
proc queryInformationJobObject(hJob: Handle; jobObjectInfoClass: int32;
                                lpJobObjectInfo: pointer;
                                cbJobObjectInfoLength: int32;
                                lpReturnLength: ptr int32): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "QueryInformationJobObject".}
proc terminateJobObjectW(hJob: Handle; uExitCode: int32): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}
proc generateConsoleCtrlEvent(dwCtrlEvent, dwProcessGroupId: int32): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "GenerateConsoleCtrlEvent".}
proc getConsoleCP(): int32
  {.stdcall, dynlib: "kernel32", importc: "GetConsoleCP".}
proc resetEventW(hEvent: Handle): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "ResetEvent".}

type ConsoleCtrlHandlerProc = proc (dwCtrlType: int32): WINBOOL {.stdcall.}
proc setConsoleCtrlHandler(handlerRoutine: ConsoleCtrlHandlerProc;
                            add: WINBOOL): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "SetConsoleCtrlHandler".}

# ---------------------------------------------------------------------------
# Shutdown wakeup — a manual-reset Event standing in for posixcore's
# self-pipe (§1's handler↔Supervisor seam). `SetConsoleCtrlHandler`'s
# callback runs on a SEPARATE OS thread the system creates for it (documented
# Win32 behavior) — it cannot capture per-Supervisor state any more than a
# POSIX signal handler can, so the same "process-global write reaching a
# per-run Supervisor's wakeup" pattern applies, with `SetEvent` in place of
# `write(2)`. One Supervisor with installSignals=true per process, same
# documented constraint as posixcore.
# ---------------------------------------------------------------------------

var gShutdownEventHandle {.global.}: Handle = 0
var gShutdownSignum {.global.}: int32 = 0

proc ctrlHandlerProc(dwCtrlType: int32): WINBOOL {.stdcall.} =
  case dwCtrlType
  of CTRL_C_EVENT:
    gShutdownSignum = 2   # SIGINT's number — RFC-0003's 128+n rule (§1 doc)
  of CTRL_BREAK_EVENT:
    gShutdownSignum = 15  # SIGTERM's number
  else:
    return 0'i32          # CTRL_CLOSE/LOGOFF/SHUTDOWN: not this spike's concern
  if gShutdownEventHandle != 0:
    discard setEvent(gShutdownEventHandle)
  return 1'i32

# ---------------------------------------------------------------------------
# Supervisor — mirrors posix.nim's shape (deep module, private fields, the
# same lifecycle rules) without a separate "core" split: unlike the posix
# family, nothing else shares this backend's machinery yet (§1 module-layout
# comment's sharing mechanism is POSIX-specific — there is exactly one
# Windows backend).
# ---------------------------------------------------------------------------

type
  ChildState = enum wcsSpawned, wcsExited, wcsReaped

  ChildEntry = object
    hProcess, hJob: Handle
    pid: int32
    state: ChildState
    reqLimits: Limits
    achieved: LimitsAchieved
    exit: Exit
    rusage: Option[Rusage]
    stop: Option[tuple[reason: KillReason, escalated: bool]]
    cooperativeUnavailable: bool

  Supervisor* = object       ## deep module: owns the wait set, the shutdown
    nextIdVal: int32          ## wakeup, and the child registry (§1). Fields
    children: Table[int32, ChildEntry]  ## backend-private.
    liveCount: int
    installedSignals: bool
    shutdownEvent: Handle
    consoleAttached: bool      ## real probe (GetConsoleCP), cached (§4)
    capsCache: Capabilities    ## computed once in initSupervisor (§4)

proc `=copy`*(dst: var Supervisor; src: Supervisor) {.error:
  "Supervisor is non-copyable — one owner per event-loop fd (rfc-0007 §1); " &
  "pass by `var`/return it, never copy.".}

proc `=destroy`*(sv: var Supervisor) =
  ## Releases the wait set and registry and KILLS NOTHING — outstanding
  ## children are the executor's to stop and reap (§1). Debug-build Defect
  ## on live children mirrors posix.nim's lifecycle rule.
  when not defined(release) and not defined(danger):
    doAssert sv.liveCount == 0,
      "Supervisor destroyed with live children — stop and reap them first (rfc-0007 §1)"
  if sv.installedSignals and gShutdownEventHandle == sv.shutdownEvent:
    gShutdownEventHandle = 0
  if sv.shutdownEvent != 0:
    discard closeHandle(sv.shutdownEvent)
  sv.children = initTable[int32, ChildEntry]()

# ---------------------------------------------------------------------------
# capabilities() probe — real where cheap and safe, honestly false where
# this spike does not implement the mechanism (§4: "nothing in this RFC is
# required to be present").
# ---------------------------------------------------------------------------

proc probeJobObjectNesting(): bool =
  ## A REAL, side-effect-contained functional probe: nested Job Objects (a
  ## process already in one Job being assigned to a second) are rejected
  ## pre-Windows-8/Server-2012 and allowed from Windows 8/Server 2012
  ## onward. Rather than infer this from the OS version (an indirect,
  ## undocumented-boundary claim), spawn a throwaway SUSPENDED child
  ## process — never this process itself: assigning our own runner process
  ## to a Job we then close would risk killing OURSELVES via
  ## KILL_ON_JOB_CLOSE — and attempt the double-assign. Every handle is
  ## closed and the child terminated before returning, on every path;
  ## any unexpected failure degrades to `false`, never raises.
  result = false
  try:
    let comspec = getEnv("COMSPEC", "cmd.exe")
    var si: STARTUPINFO
    si.cb = sizeof(si).int32
    var pi: PROCESS_INFORMATION
    var cmdWide = newWideCString(quoteShellWindows(comspec) & " /c exit")
    let flags: int32 = CREATE_SUSPENDED or CREATE_NO_WINDOW
    let ok = createProcessW(nil, cmdWide, nil, nil, 0'i32, flags,
                             nil, nil, si, pi)
    if ok == 0'i32: return false
    defer:
      discard terminateProcess(pi.hProcess, 0)
      discard closeHandle(pi.hThread)
      discard closeHandle(pi.hProcess)
    let job1 = createJobObjectW(nil, nil)
    if job1 == 0: return false
    defer: discard closeHandle(job1)
    if assignProcessToJobObject(job1, pi.hProcess) == 0'i32: return false
    let job2 = createJobObjectW(nil, nil)
    if job2 == 0: return false
    defer: discard closeHandle(job2)
    result = assignProcessToJobObject(job2, pi.hProcess) != 0'i32
  except CatchableError:
    result = false

proc capabilities*(sv: Supervisor): Capabilities =
  ## Probed once, memoised (§4) — computed eagerly in `initSupervisor`
  ## (this getter takes `sv: Supervisor`, not `var`, per the §1 signature;
  ## unlike posixcore's cheap/pure `capabilitiesCore`, `jobObjectNesting`'s
  ## probe spawns a process, so it is genuinely memoised, not just cheap to
  ## recompute).
  sv.capsCache

proc initSupervisor*(installSignals: bool = true): Supervisor =
  ## Can fail (§1): the shutdown-wakeup Event's creation is this backend's
  ## analog of posixcore's self-pipe — raises a structural OSError, never a
  ## degraded half-loop, on failure. `SetConsoleCtrlHandler` itself is NOT
  ## made fatal on failure (mirrors posixcore's un-checked `sigaction`
  ## calls): a missing ctrl handler degrades `weShutdown` to never firing,
  ## a narrower failure than losing the wait primitive entirely.
  var ev: Handle = 0
  if installSignals:
    ev = createEvent(nil, 1'i32, 0'i32, nil)
    if ev == 0:
      raise newException(OSError, "initSupervisor: CreateEventW failed for shutdown wakeup")
  let consoleAttached = getConsoleCP() != 0'i32
  result = Supervisor(nextIdVal: 0'i32, children: initTable[int32, ChildEntry](),
                       liveCount: 0, installedSignals: installSignals,
                       shutdownEvent: ev, consoleAttached: consoleAttached)
  if installSignals:
    gShutdownEventHandle = ev
    discard setConsoleCtrlHandler(ctrlHandlerProc, 1'i32)
  result.capsCache = Capabilities(
    pidfd: false, subreaper: false, cgroupDelegation: false, cgroupKill: false,
    memoryPeak: false, kqueue: false,
    jobObjectNesting: probeJobObjectNesting(),   # real probe
    ctrlBreakDeliverable: consoleAttached,       # real probe
    flock: false,       # POSIX-named mechanism; Windows uses LockFileEx (A4/D2)
    wait4Rusage: false, # POSIX-named mechanism; this backend gets rusage via
                         # Job accounting instead (real, see reap() below) —
                         # this field means "wait4 the syscall", not "no rusage".
  )

proc capabilities*(): Capabilities =
  ## rfc-0007 A7: the same value `capabilities(sv)` returns, for callers
  ## with no live Supervisor (the plan/list CLI path never spawns anything)
  ## — mirrors posix.nim's parameterless overload. This backend's probe is
  ## genuinely per-Supervisor-instance (`initSupervisor` computes it once,
  ## eagerly), so the standalone accessor spins up a throwaway, signal-
  ## handler-free Supervisor purely to read it; `=destroy` is a no-op here
  ## (no children were ever spawned).
  let sv = initSupervisor(installSignals = false)
  sv.capsCache

# ---------------------------------------------------------------------------
# spawn — CreateProcessW (suspended) + a real Job Object with
# KILL_ON_JOB_CLOSE, assigned before the child's main thread ever runs.
# ---------------------------------------------------------------------------

proc buildCommandLine(argv: seq[string]): string =
  for i, a in argv:
    if i > 0: result.add(' ')
    result.add(quoteShellWindows(a))

proc buildEnvBlock(env: seq[(string, string)]): string =
  ## NUL-separated "KEY=VALUE" strings, double-NUL terminated. ALWAYS built
  ## explicitly (§1 ChildSpec.env doc: "EXPLICIT, always") — an empty `env`
  ## yields a genuinely empty block, never a fallback to CreateProcessW's
  ## nil-environment "inherit the caller's env" behavior, which would
  ## silently violate the contract.
  if env.len == 0:
    return "\0\0"
  result = ""
  for pair in env:
    result.add(pair[0])
    result.add('=')
    result.add(pair[1])
    result.add('\0')
  result.add('\0')

proc honestLimitsAchieved(limits: Limits): LimitsAchieved =
  ## No pre-exec child window on Windows to hook a readback pipe into
  ## (CreateProcessW hands control straight to the image — no fork/exec
  ## split) — the weakest-honest-claim rule (§1 LimitStatus doc) applies:
  ## every REQUESTED limit reports `lsUnsupported` this spike, regardless
  ## of kind. D1b is where Job Object memory/cpu limits actually get
  ## requested and their real per-spawn achievement queried back.
  for lk in LimitKind:
    result[lk] = if limits.req[lk].isSome: lsUnsupported else: lsNotRequested

proc spawnChild(sv: var Supervisor; spec: ChildSpec): SpawnResult =
  if spec.argv.len == 0:
    return SpawnResult(ok: false, error: "empty argv")

  var sa: SECURITY_ATTRIBUTES
  sa.nLength = sizeof(SECURITY_ATTRIBUTES).int32
  sa.lpSecurityDescriptor = nil
  sa.bInheritHandle = 1

  # Sinks by path (§1) — ONE combined stdout+stderr sink, stdin always NUL.
  let sinkHandle = createFileW(newWideCString(spec.sinks.path), GENERIC_WRITE,
                                FILE_SHARE_READ, addr sa, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, 0)
  if sinkHandle == INVALID_HANDLE_VALUE:
    return SpawnResult(ok: false, error: "failed to open sink: " & spec.sinks.path)

  let nullHandle = createFileW(newWideCString("NUL"), GENERIC_READ,
                                FILE_SHARE_READ, addr sa, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, 0)
  if nullHandle == INVALID_HANDLE_VALUE:
    discard closeHandle(sinkHandle)
    return SpawnResult(ok: false, error: "failed to open NUL")

  var si: STARTUPINFO
  si.cb = sizeof(si).int32
  si.dwFlags = STARTF_USESTDHANDLES
  si.hStdInput = nullHandle
  si.hStdOutput = sinkHandle
  si.hStdError = sinkHandle

  var pi: PROCESS_INFORMATION
  var cmdWide = newWideCString(buildCommandLine(spec.argv))
  var envWide = newWideCString(buildEnvBlock(spec.env))
  var wd: cstring = nil
  if spec.cwd.len > 0: wd = spec.cwd.cstring
  var wwd = newWideCString(wd)
  # CREATE_SUSPENDED: the child's main thread never runs until AFTER Job
  # assignment below — no window where an unconfined child could escape the
  # kill domain. CREATE_NEW_PROCESS_GROUP: required for CTRL_BREAK targeting
  # (§3) — the new process group id equals the child's PID.
  let flags: int32 = CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED or
                      CREATE_NEW_PROCESS_GROUP

  let ok = createProcessW(nil, cmdWide, nil, nil, 1'i32, flags,
                           envWide, wwd, si, pi)
  discard closeHandle(sinkHandle)
  discard closeHandle(nullHandle)
  if ok == 0'i32:
    return SpawnResult(ok: false,
      error: "CreateProcessW failed: GetLastError=" & $getLastError())

  let hJob = createJobObjectW(nil, nil)
  if hJob == 0:
    discard terminateProcess(pi.hProcess, 1)
    discard closeHandle(pi.hThread)
    discard closeHandle(pi.hProcess)
    return SpawnResult(ok: false,
      error: "CreateJobObjectW failed: GetLastError=" & $getLastError())

  var limitInfo: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
  limitInfo.basicLimitInformation.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
  if setInformationJobObject(hJob, jicExtendedLimit,
                              addr limitInfo, int32(sizeof(limitInfo))) == 0'i32:
    discard terminateProcess(pi.hProcess, 1)
    discard closeHandle(hJob)
    discard closeHandle(pi.hThread)
    discard closeHandle(pi.hProcess)
    return SpawnResult(ok: false,
      error: "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed: GetLastError=" & $getLastError())

  if assignProcessToJobObject(hJob, pi.hProcess) == 0'i32:
    discard terminateProcess(pi.hProcess, 1)
    discard closeHandle(hJob)
    discard closeHandle(pi.hThread)
    discard closeHandle(pi.hProcess)
    return SpawnResult(ok: false,
      error: "AssignProcessToJobObject failed: GetLastError=" & $getLastError())

  discard resumeThread(pi.hThread)
  discard closeHandle(pi.hThread)

  let id = sv.nextIdVal
  inc sv.nextIdVal
  sv.children[id] = ChildEntry(hProcess: pi.hProcess, hJob: hJob, pid: pi.dwProcessId,
                                state: wcsSpawned, reqLimits: spec.limits,
                                achieved: honestLimitsAchieved(spec.limits))
  inc sv.liveCount
  SpawnResult(ok: true, id: ChildId(id))

proc spawn*(sv: var Supervisor; spec: ChildSpec): SpawnResult =
  spawnChild(sv, spec)

# ---------------------------------------------------------------------------
# next — WaitForMultipleObjects over live child handles (+ the shutdown
# event). §1's documented small-N fallback tier; MAXIMUM_WAIT_OBJECTS (64,
# minus one slot for the shutdown event when installed) is the real,
# accepted bound the contract names.
# ---------------------------------------------------------------------------

proc decodeExitCode(codeRaw: int32): Exit =
  let code = cast[uint32](codeRaw)
  if code >= 0xC0000000'u32:
    Exit(kind: ekNtStatus, status: code)
  else:
    Exit(kind: ekExited, code: int(codeRaw))

proc queryJobAccounting(hJob: Handle): tuple[ru: Rusage; ok: bool] =
  var basic: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
  var retLen: int32
  if queryInformationJobObject(hJob, jicBasicAccounting,
                                addr basic, int32(sizeof(basic)), addr retLen) == 0'i32:
    return (Rusage(), false)
  var peak: int64 = 0
  var ext: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
  if queryInformationJobObject(hJob, jicExtendedLimit,
                                addr ext, int32(sizeof(ext)), addr retLen) != 0'i32:
    peak = int64(ext.peakJobMemoryUsed)
  # 100ns units -> microseconds.
  (Rusage(maxRssBytes: peak,
          userCpuUs: basic.totalUserTime div 10,
          sysCpuUs: basic.totalKernelTime div 10), true)

proc nextEvent(sv: var Supervisor; deadline: MonoTime): WaitEvent =
  while true:
    if sv.installedSignals:
      if waitForSingleObject(sv.shutdownEvent, 0'i32) == WAIT_OBJECT_0:
        discard resetEventW(sv.shutdownEvent)
        return WaitEvent(kind: weShutdown, signal: ShutdownSignal(signum: int(gShutdownSignum)))

    # LEVEL-TRIGGERED (§1): any child already wcsExited is re-reported every
    # call until reaped.
    for id, entry in sv.children.pairs:
      if entry.state == wcsExited:
        return WaitEvent(kind: weChildExited, id: ChildId(id))

    let now0 = getMonoTime()
    if now0 >= deadline:
      return WaitEvent(kind: weDeadline)
    let remainMs = (deadline - now0).inMilliseconds
    let tickMs = int32(min(25'i64, max(1'i64, remainMs)))

    var handles: WOHandleArray
    var ids: seq[int32] = @[]
    if sv.installedSignals:
      handles[0] = sv.shutdownEvent
      ids.add(-1'i32)          # sentinel: index 0 is the shutdown event
    for id, entry in sv.children.pairs:
      if entry.state == wcsSpawned:
        if ids.len >= MAXIMUM_WAIT_OBJECTS: break   # the documented 64-handle bound
        handles[ids.len] = entry.hProcess
        ids.add(id)

    if ids.len == 0:
      # Nothing to wait on at all (no signals installed, no live children) —
      # tick and re-check the deadline; never a busy spin.
      winlean.sleep(tickMs)
      continue

    let waitResult = waitForMultipleObjects(DWORD(ids.len), addr handles,
                                             0'i32, DWORD(tickMs))
    if waitResult >= WAIT_OBJECT_0 and int(waitResult - WAIT_OBJECT_0) < ids.len:
      let cid = ids[int(waitResult - WAIT_OBJECT_0)]
      if cid == -1'i32:
        discard resetEventW(sv.shutdownEvent)
        return WaitEvent(kind: weShutdown, signal: ShutdownSignal(signum: int(gShutdownSignum)))
      else:
        var entry = sv.children[cid]
        var codeRaw: int32
        discard getExitCodeProcess(entry.hProcess, codeRaw)
        entry.exit = decodeExitCode(codeRaw)
        let (ru, ok) = queryJobAccounting(entry.hJob)
        entry.rusage = if ok: some(ru) else: none(Rusage)
        entry.state = wcsExited
        sv.children[cid] = entry
        # Loop back to top — the level-triggered scan reports it.
    # WAIT_TIMEOUT / WAIT_FAILED: loop — top re-checks shutdown, exited
    # children, and the deadline.

proc next*(sv: var Supervisor; deadline: MonoTime): WaitEvent =
  nextEvent(sv, deadline)

# ---------------------------------------------------------------------------
# requestStop / forceKill — non-blocking, idempotent, atomic-against-exit-
# observation act recording (§1), same rule as posixcore.
# ---------------------------------------------------------------------------

proc requireLive(sv: Supervisor; id: ChildId): int32 =
  let idx = int32(id)
  if idx notin sv.children or sv.children[idx].state == wcsReaped:
    doAssert false, "misuse: ChildId " & $id & " is unknown or already consumed"
  idx

proc requestStop*(sv: var Supervisor; id: ChildId; reason: KillReason) =
  ## Cooperative stop: GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT) — gated on
  ## the REAL probed console-topology deliverability (§3/§4), never
  ## assumed. Undeliverable ⇒ `cooperativeUnavailable: true`, recorded now
  ## so `escalated` stays meaningful at forceKill time (see this module's
  ## header finding).
  let idx = requireLive(sv, id)
  var entry = sv.children[idx]
  if entry.state == wcsExited: return   # atomic no-op — exit already observed
  if entry.stop.isSome: return          # first act wins
  entry.cooperativeUnavailable = not sv.consoleAttached
  entry.stop = some((reason: reason, escalated: false))
  if sv.consoleAttached:
    discard generateConsoleCtrlEvent(CTRL_BREAK_EVENT, entry.pid)
  sv.children[idx] = entry

proc forceKill*(sv: var Supervisor; id: ChildId) =
  ## Forced kill: real TerminateJobObject — the guaranteed kill path,
  ## independent of console topology. `escalated` is
  ## `stop.isSome AND NOT cooperativeUnavailable` (this module's header
  ## finding): §1 says escalated is false when the cooperative step was
  ## never attempted — "nothing to escalate FROM" — and on Windows that is
  ## reachable (unlike POSIX, where SIGTERM is always deliverable).
  let idx = requireLive(sv, id)
  var entry = sv.children[idx]
  if entry.state == wcsExited: return   # atomic no-op
  discard terminateJobObjectW(entry.hJob, jobForceKillExitCode)
  if entry.stop.isSome:
    let priorReason = entry.stop.get.reason
    entry.stop = some((reason: priorReason, escalated: not entry.cooperativeUnavailable))
  else:
    entry.cooperativeUnavailable = not sv.consoleAttached
    entry.stop = some((reason: krTimeout, escalated: not entry.cooperativeUnavailable))
  sv.children[idx] = entry

# ---------------------------------------------------------------------------
# reap — the only place a ChildId is consumed (§1).
# ---------------------------------------------------------------------------

proc reap*(sv: var Supervisor; id: ChildId): ReapReport =
  let idx = int32(id)
  if idx notin sv.children:
    doAssert false, "reap: unknown ChildId " & $id
  let entry = sv.children[idx]
  if entry.state != wcsExited:
    doAssert false, "reap: weChildExited was never reported for ChildId " & $id
  result = ReapReport(
    exit: entry.exit,
    rusage: entry.rusage,
    stop: entry.stop,
    killDomain: kdsJobObject,               # real: Job Object + KILL_ON_JOB_CLOSE
    limits: entry.achieved,
    killSnapshot: @[],                      # honest: toUnobservable-grade emptiness
    tree: toUnobservable,
    escapees: @[],
    cooperativeUnavailable: entry.cooperativeUnavailable,
  )
  discard closeHandle(entry.hProcess)
  discard closeHandle(entry.hJob)
  sv.children[idx] = ChildEntry(state: wcsReaped)
  dec sv.liveCount

# ---------------------------------------------------------------------------
# snapshotTree / groupRssBytes — honestly degraded this spike (see module
# header). Real implementations need JobObjectBasicProcessIdList (+ psapi
# for groupRssBytes's current-sum semantics) — D1a/D2 territory.
# ---------------------------------------------------------------------------

proc snapshotTree*(sv: Supervisor; id: ChildId): seq[ProcSnapshot] =
  discard requireLive(sv, id)
  @[]

proc groupRssBytes*(sv: Supervisor; id: ChildId): Option[int64] =
  discard requireLive(sv, id)
  none(int64)
