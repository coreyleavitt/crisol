## process/windows.nim — rfc-0007 §1/§3: the Windows Supervisor backend.
## Born as the A2d spike (§1 contract SIGNATURES frozen against real Win32,
## smoke-path only); D1a made the core real: completion-port `next`,
## `snapshotTree` forensics, and the `ekNtStatus` producer proof — "conformance
## SMOKE green" per the RFC's D1a bullet, not RFC-0009's full-suite parity.
##
## What is REAL here:
##   - spawn: CreateProcessW (suspended) + a real Job Object with
##     KILL_ON_JOB_CLOSE, assigned before the child's main thread ever runs,
##     then ResumeThread — a genuine kill-domain guarantee (§3's "Job Object,
##     KILL_ON_JOB_CLOSE, breakaway disabled" row), not a bookkeeping fiction.
##     Inherited handles to sinks (STARTF_USESTDHANDLES + bInheritHandle) —
##     real since the A2d spike, proven end-to-end by D1a's sink test.
##   - next (D1a): PRIMARY tier is GetQueuedCompletionStatus on a completion
##     port shared across every spawn (created once in initSupervisor;
##     initSupervisor raises if creation fails, per §1's own "completion-port
##     creation" among its documented fatal cases — mirrors posixcore's fatal
##     epoll_create1). Each Job is associated with it at spawn
##     (SetInformationJobObject, JobObjectAssociateCompletionPortInformation)
##     — non-fatal on a per-child basis if that association fails. Detection
##     itself is a uniform sweep (GetExitCodeProcess over every still-spawned
##     child, every iteration) decoupled from whichever primitive woke the
##     loop — a completion message is NEVER a second reap path, same
##     discipline as the epoll/kqueue arms (posixcore's pollSweepChildren is
##     the direct peer); this is also why an association failure degrades
##     honestly to the same <=25ms poll-tick bound instead of needing a
##     second parallel wait call. WaitForMultipleObjects (the A2d spike's
##     only tier) is retired as dead weight now that the sweep subsumes its
##     job.
##   - requestStop: real GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT) — gated
##     on a REAL probed console-topology check, never assumed deliverable.
##     Takes a real `killSnapshot` (D1a: snapshotJob) at this, the first
##     stop act.
##   - forceKill: real TerminateJobObject — the guaranteed kill path,
##     independent of console topology; this is what the smoke test proves.
##     Refreshes `killSnapshot` (D1a), taken BEFORE the kill fires.
##   - reap: real GetExitCodeProcess (the §2 Windows exit-code/ekNtStatus
##     partition — D1a's access-violation fixture is its producer proof) and
##     real Job accounting rusage (QueryInformationJobObject:
##     JOBOBJECT_BASIC_ACCOUNTING_INFORMATION for CPU time,
##     JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakJobMemoryUsed for
##     maxRssBytes). `tree` is `treeObservationFor(kdsJobObject)` == toComplete
##     (D1a) — a Job Object sees every process in it by construction, so this
##     is no longer the honest-but-conservative `toUnobservable` the A2d
##     spike hardcoded before snapshotTree existed to back the stronger claim.
##   - snapshotTree (D1a): real, via JobObjectBasicProcessIdList (the pid
##     list) + psapi GetProcessMemoryInfo (per-pid rssBytes, the RSS analog
##     every other tier's forensics report) + QueryFullProcessImageNameW
##     (command/image name). `ppid` is not resolved this tier (D1b/D2 —
##     needs Toolhelp32Snapshot) — `-1`, an honest "not determined", never a
##     fabricated `0` (a real, reserved pid on Windows).
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
##     unconditionally — Job Objects CAN express a `lkCpu`/`lkAddressSpace`
##     analog (PerProcessUserTimeLimit / ProcessMemoryLimit) but this module
##     does not wire them yet (D1b's job, per §5 "Windows maps Limits to Job
##     basic/extended limits"); `lkFileSize`/`lkOpenFiles`/`lkCore` have NO
##     Windows analog at all, ever (§5: "openFiles has no analog and is
##     reported lsUnsupported").
##   - groupRssBytes: returns `none()`. Job accounting's only cheap "memory"
##     figure is PeakJobMemoryUsed — a MONOTONIC peak-since-job-start, not
##     the CURRENT live sum this proc's contract promises (§1: "the
##     group-RSS sum and nothing else", sampled every 25 ms for admission).
##     Reporting a stale peak as "current" would systematically over-report
##     and under-admit — a lie in the conservative direction, still a lie.
##     A true current-sum needs psapi walked over the SAME
##     JobObjectBasicProcessIdList pid list snapshotTree now uses; D2's job
##     (memprobe wiring).
##   - Evidence.escapees: `@[]` always — breakaway/DETACHED_PROCESS discovery
##     is D1b's job (the escapee fixtures land there); `tree` is real (above).
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
  maxJobPids = 256
    ## rfc-0007 D1a: bounds JOBOBJECT_BASIC_PROCESS_ID_LIST's pid buffer
    ## below — must precede that type (used as its array length).

type
  JOBOBJECT_BASIC_PROCESS_ID_LIST = object
    ## rfc-0007 D1a: QueryInformationJobObject class 3 — the pid list
    ## `snapshotTree` forensics need. `processIdList` is a fixed-capacity
    ## stand-in for the real ABI's flexible array member (`ULONG_PTR[1]`,
    ## C's "however many fit past here"); `maxJobPids` bounds it the same
    ## documented way `next`'s WaitForMultipleObjects bounds at
    ## MAXIMUM_WAIT_OBJECTS (§1's small-N-fallback pattern) — the OS reports
    ## the true count in `numberOfProcessIdsInList`/`numberOfAssignedProcesses`
    ## regardless of whether it fit.
    numberOfAssignedProcesses: int32    # DWORD
    numberOfProcessIdsInList: int32     # DWORD
    processIdList: array[maxJobPids, uint]  # ULONG_PTR[]

  JOBOBJECT_ASSOCIATE_COMPLETION_PORT = object
    ## rfc-0007 D1a: SetInformationJobObject class 7. `completionKey` is
    ## echoed back verbatim in `GetQueuedCompletionStatus`'s
    ## `lpCompletionKey` — this backend uses the Job handle's own value so a
    ## message can be traced to which spawn's Job posted it (never decoded
    ## in `nextEvent`: the message is a wakeup only, see that proc's header).
    completionKey: pointer              # PVOID
    completionPort: Handle              # HANDLE

  PROCESS_MEMORY_COUNTERS = object
    ## rfc-0007 D1a: psapi's GetProcessMemoryInfo — `workingSetSize` is the
    ## RSS analog `snapshotTree` forensics need (real, per-pid, over the
    ## Job's pid list — NOT `groupRssBytes`'s live-sum sampler, which stays
    ## D2's job; see this module's header).
    cb: int32                           # DWORD
    pageFaultCount: int32
    peakWorkingSetSize: uint            # SIZE_T
    workingSetSize: uint
    quotaPeakPagedPoolUsage: uint
    quotaPagedPoolUsage: uint
    quotaPeakNonPagedPoolUsage: uint
    quotaNonPagedPoolUsage: uint
    pagefileUsage: uint
    peakPagefileUsage: uint

const
  jicBasicAccounting = 1'i32
  jicBasicProcessIdList = 3'i32
  jicAssociateCompletionPort = 7'i32
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
proc getProcessMemoryInfo(hProcess: Handle; ppsmemCounters: ptr PROCESS_MEMORY_COUNTERS;
                           cb: int32): WINBOOL
  {.stdcall, dynlib: "psapi", importc: "GetProcessMemoryInfo".}
proc queryFullProcessImageNameW(hProcess: Handle; dwFlags: int32;
                                 lpExeName: WideCString; lpdwSize: var int32): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "QueryFullProcessImageNameW".}

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
    killSnapshot: seq[ProcSnapshot]  ## rfc-0007 D1a: taken at the first stop
                                     ## act, refreshed at forceKill (§1) —
                                     ## real now that snapshotTree is wired.

  Supervisor* = object       ## deep module: owns the wait set, the shutdown
    nextIdVal: int32          ## wakeup, and the child registry (§1). Fields
    children: Table[int32, ChildEntry]  ## backend-private.
    liveCount: int
    installedSignals: bool
    shutdownEvent: Handle
    completionPort: Handle     ## rfc-0007 D1a: the shared IOCP `next` blocks
                               ## on (primary tier) — every spawned child's
                               ## Job is associated with it (spawnChild).
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
  if sv.completionPort != 0:
    discard closeHandle(sv.completionPort)
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
  ##
  ## rfc-0007 D1a: also creates the ONE completion port `next` blocks on
  ## (§1 explicitly lists "completion-port creation" among initSupervisor's
  ## documented failure modes, alongside epoll/self-pipe) — a genuine
  ## structural failure here (not a per-child degrade), mirroring
  ## posixcore's fatal `epoll_create1`. Per-child association (spawnChild)
  ## degrades non-fatally instead — see `nextEvent`'s sweep.
  var ev: Handle = 0
  if installSignals:
    ev = createEvent(nil, 1'i32, 0'i32, nil)
    if ev == 0:
      raise newException(OSError, "initSupervisor: CreateEventW failed for shutdown wakeup")
  let iocp = createIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0)
  if iocp == 0:
    if ev != 0: discard closeHandle(ev)
    raise newException(OSError, "initSupervisor: CreateIoCompletionPort failed")
  let consoleAttached = getConsoleCP() != 0'i32
  result = Supervisor(nextIdVal: 0'i32, children: initTable[int32, ChildEntry](),
                       liveCount: 0, installedSignals: installSignals,
                       shutdownEvent: ev, completionPort: iocp,
                       consoleAttached: consoleAttached)
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

  # rfc-0007 D1a: associate this Job with the shared completion port so
  # `nextEvent`'s primary tier wakes on this child's exit. NON-FATAL on
  # failure (unlike KILL_ON_JOB_CLOSE above) — same discipline as
  # posixcore's per-child pidfd_open/epoll_ctl registration: the kill
  # domain (Job Object) does not depend on it, and `nextEvent`'s sweep
  # still finds this child within one poll tick (<=25ms) either way.
  if sv.completionPort != 0:
    var assoc = JOBOBJECT_ASSOCIATE_COMPLETION_PORT(
      completionKey: cast[pointer](hJob), completionPort: sv.completionPort)
    discard setInformationJobObject(hJob, jicAssociateCompletionPort,
                                     addr assoc, int32(sizeof(assoc)))

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
# next — rfc-0007 D1a: a completion-port PRIMARY tier (GetQueuedCompletionStatus
# over the shared IOCP every spawned child's Job is associated with,
# spawnChild), with a poll-tick sweep as the always-present detector (never
# a second wait primitive) — see sweepExitedChildren below for why this
# mirrors posixcore's pidfd/epoll pattern rather than keeping a parallel
# WaitForMultipleObjects call.
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

proc sweepExitedChildren(sv: var Supervisor) =
  ## The ONE detector of "did this child exit" — decoupled from whatever
  ## woke `next` (an IOCP completion message, the fallback poll tick, or a
  ## plain deadline check). Mirrors posixcore's pollSweepChildren: pidfd/
  ## epoll (and here, the Job's completion port) only decide WHEN to look;
  ## a non-blocking readback (waitpid WNOHANG there, GetExitCodeProcess
  ## here) is what's authoritative for WHICH child actually ended — a
  ## completion message is NEVER a second reap path (the B1/C1b lesson,
  ## restated for Windows in this module's header). This is also the
  ## honest fallback for a child whose Job failed completion-port
  ## association in spawnChild: no second wait primitive is needed, the
  ## very next sweep (at most one poll tick, capped 25ms, later) catches
  ## it — the same bound the old WaitForMultipleObjects-only tier gave
  ## every child.
  const STILL_ACTIVE = 259'i32
  for id, entry in sv.children.mpairs:
    if entry.state == wcsSpawned:
      var codeRaw: int32
      if getExitCodeProcess(entry.hProcess, codeRaw) != 0'i32 and codeRaw != STILL_ACTIVE:
        entry.exit = decodeExitCode(codeRaw)
        let (ru, ok) = queryJobAccounting(entry.hJob)
        entry.rusage = if ok: some(ru) else: none(Rusage)
        entry.state = wcsExited

proc nextEvent(sv: var Supervisor; deadline: MonoTime): WaitEvent =
  while true:
    if sv.installedSignals:
      if waitForSingleObject(sv.shutdownEvent, 0'i32) == WAIT_OBJECT_0:
        discard resetEventW(sv.shutdownEvent)
        return WaitEvent(kind: weShutdown, signal: ShutdownSignal(signum: int(gShutdownSignum)))

    sweepExitedChildren(sv)

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

    if sv.completionPort != 0:
      # Primary tier (D1a): block on the completion port every live
      # child's Job is associated with (spawnChild). JOB_OBJECT_MSG_
      # EXIT_PROCESS / JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS wake this
      # promptly on exit — but per the epoll/kqueue precedent (B2/C1b),
      # the message is NEVER decoded or trusted as a second reap path:
      # success or timeout, either way control falls through to the
      # sweep above on the next iteration, which is what actually
      # decides what happened. This also transparently covers a child
      # whose Job failed association (spawnChild's non-fatal degrade) —
      # the GQCS call still returns (on its timeout if nothing else),
      # bounding that child's detection at this same poll tick.
      var bytes: DWORD
      var key: ULONG_PTR
      var ov: POVERLAPPED
      discard getQueuedCompletionStatus(sv.completionPort, addr bytes, addr key,
                                         addr ov, DWORD(tickMs))
    else:
      # Structurally unreachable (initSupervisor raises if completion-port
      # creation fails, mirroring posixcore's fatal epoll_create1) — kept
      # as an honest, non-busy poll tick rather than assumed dead code,
      # same defensive discipline as posixcore's own fallback arms.
      winlean.sleep(tickMs)
    # loop back to top — the sweep decides what happened, not this wait.

proc next*(sv: var Supervisor; deadline: MonoTime): WaitEvent =
  nextEvent(sv, deadline)

# ---------------------------------------------------------------------------
# snapshotJob — rfc-0007 D1a: JobObjectBasicProcessIdList (pid list) + psapi
# GetProcessMemoryInfo (per-pid rssBytes) + QueryFullProcessImageNameW
# (command/image name). Shared by snapshotTree (below) and requestStop/
# forceKill's killSnapshot (§1: "taken at the FIRST stop act... refreshed
# at forceKill").
# ---------------------------------------------------------------------------

proc queryJobPids(hJob: Handle): seq[int32] =
  var buf: JOBOBJECT_BASIC_PROCESS_ID_LIST
  var retLen: int32
  if queryInformationJobObject(hJob, jicBasicProcessIdList, addr buf,
                                int32(sizeof(buf)), addr retLen) == 0'i32:
    return @[]
  let n = min(int(buf.numberOfProcessIdsInList), maxJobPids)
  result = newSeq[int32](n)
  for i in 0 ..< n:
    result[i] = int32(buf.processIdList[i])

proc snapshotOnePid(pid: int32): Option[ProcSnapshot] =
  ## `ppid` is NOT resolved this tier — a real answer needs
  ## Toolhelp32Snapshot, beyond D1a's forensics ask (pid + command +
  ## rssBytes). `-1`, the same "could not determine" sentinel posixcore's
  ## own /proc-parse-failure path uses — never a fabricated `0` (pid 0 is
  ## a real, reserved pid on Windows, the System Idle Process, so it is
  ## not a safe stand-in for "unknown").
  let hProc = openProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0'i32, pid)
  if hProc == 0:
    return none(ProcSnapshot)  # exited between the pid-list read and here — honest skip, never fabricated
  defer: discard closeHandle(hProc)
  var command = ""
  var nameBuf = newWideCString(260)
  var sizeInOut = 260'i32
  if queryFullProcessImageNameW(hProc, 0'i32, toWideCString(nameBuf), sizeInOut) != 0'i32:
    command = $(toWideCString(nameBuf), int(sizeInOut))
  var rss: int64 = 0
  var mem: PROCESS_MEMORY_COUNTERS
  mem.cb = int32(sizeof(mem))
  if getProcessMemoryInfo(hProc, addr mem, mem.cb) != 0'i32:
    rss = int64(mem.workingSetSize)
  some(ProcSnapshot(pid: int(pid), ppid: -1, command: command, rssBytes: rss))

proc snapshotJob(hJob: Handle): seq[ProcSnapshot] =
  result = @[]
  for pid in queryJobPids(hJob):
    let snap = snapshotOnePid(pid)
    if snap.isSome: result.add snap.get

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
  ## header finding). Takes `killSnapshot` at this, the FIRST stop act
  ## (§1) — real now that snapshotJob is wired (D1a): the common timeout
  ## dies cooperatively inside grace, and the "what was this child's Job
  ## doing" diagnostic must exist on THAT path, not only at escalation.
  let idx = requireLive(sv, id)
  var entry = sv.children[idx]
  if entry.state == wcsExited: return   # atomic no-op — exit already observed
  if entry.stop.isSome: return          # first act wins
  entry.killSnapshot = snapshotJob(entry.hJob)
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
  ## Refreshes `killSnapshot` (§1) — taken BEFORE TerminateJobObject fires:
  ## a snapshot taken after would only see an already-dying Job.
  let idx = requireLive(sv, id)
  var entry = sv.children[idx]
  if entry.state == wcsExited: return   # atomic no-op
  entry.killSnapshot = snapshotJob(entry.hJob)
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
    killSnapshot: entry.killSnapshot,       # real since D1a (snapshotJob); empty iff no stop act
    tree: treeObservationFor(kdsJobObject), # rfc-0007 D1a: a Job Object sees every
                                             # process in it by construction — toComplete,
                                             # not the toUnobservable the A2d spike hard-
                                             # coded before snapshotTree was real.
    escapees: @[],                          # breakaway/DETACHED_PROCESS discovery is D1b's job
    cooperativeUnavailable: entry.cooperativeUnavailable,
  )
  discard closeHandle(entry.hProcess)
  discard closeHandle(entry.hJob)
  sv.children[idx] = ChildEntry(state: wcsReaped)
  dec sv.liveCount

# ---------------------------------------------------------------------------
# snapshotTree — real since rfc-0007 D1a: JobObjectBasicProcessIdList (pid
# list) + psapi GetProcessMemoryInfo (per-pid rssBytes) + kernel32
# QueryFullProcessImageNameW (command/image name) — see snapshotJob above.
# groupRssBytes stays honestly degraded (see module header): its live-sum
# sampler semantics need psapi walked on a 25ms cadence, D2's job
# (memprobe wiring) — reporting Job accounting's PeakJobMemoryUsed here
# instead would systematically over-report a monotonic peak as a current
# sum, a lie in the conservative direction, still a lie.
# ---------------------------------------------------------------------------

proc snapshotTree*(sv: Supervisor; id: ChildId): seq[ProcSnapshot] =
  let idx = requireLive(sv, id)
  snapshotJob(sv.children[idx].hJob)

proc groupRssBytes*(sv: Supervisor; id: ChildId): Option[int64] =
  discard requireLive(sv, id)
  none(int64)
