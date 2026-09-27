## toolexec.nim — running a short-lived TOOL subprocess and capturing its
## output.
##
## This module owns every `process-contract-exempt` spawn-and-capture in
## `src/`: the `cc`/`ldd`/`nim --version` probes and the `cc -M` dependency
## probe (via `crisol/toolrun`), `git`, `nim --compileOnly`, the measure-mode
## link, the incremental-compile probe. Those are tool invocations, not the
## supervised compile/run children `crisol/process.nim` governs (RFC-0007
## §Scope), but they share one capture discipline, and it lives here once
## (issue #22: five hand-rolled copies shared two silent bugs).
##
## Entry point `runTool`: spawn, feed stdin, drain, wait, and -- on anything
## short of a clean exit -- terminate and reap. The result (`RunResult`) is a
## case object on HOW the run ended (`RunEnd`), and only `reExited` carries an
## exit code and output at all, so a capture from a run that did not finish
## cannot be read by any caller, by mistake or otherwise:
##
## - `reNotStarted` — the spawn itself failed (not on PATH, an OSError).
## - `reTimedOut` — no EOF-and-exit within the deadline.
## - `reIoError` — writing stdin, waiting on or reading a pipe failed, or
##   the child exited while a descendant still held its output open. The
##   capture is incomplete, so it is never reported as a finished run.
## - `reOverflow` — the child wrote more than the caller's byte cap.
## - `reInterrupted` — an interrupt (SIGINT/SIGTERM, a console
##   Ctrl-C/Ctrl-Break) landed in the open interrupt scope and ended the run:
##   the registry killed its tree, or refused it at registration, or the run
##   failed while the interrupt was pending. Its answer is a fact about the
##   interrupt, not the tool, so no caller may keep it (R14-D3, R12-D8).
##
## Every tool inherits crisol's environment minus the `CRISOL_CACHE_*`
## namespace (the remote-cache credentials; `toolEnv`, CR18).
##
## `ok` and `describe` are the two readings every caller shares: "ran to an
## exit and exited 0", and a one-line diagnostic. This module writes nothing
## to the terminal; what a failed run means is the caller's to say.
##
## Invariants the drain holds (all measured, issue #22):
##
## - A short read is never EOF. `streams.readAll` stops at the first read
##   shorter than its buffer, and a Windows pipe read returns as soon as ANY
##   bytes are available, so a child that flushes twice (cl's banner, then its
##   dependency report ~100 ms later) would be captured as its first flush
##   alone, with exit code 0. Only a closed write end ends a pipe.
## - With separate stdout/stderr pipes, both are drained CONCURRENTLY.
##   Draining them in sequence deadlocks: a child that fills the stderr pipe
##   blocks in its own `write`, never finishes stdout, never exits. The
##   budget is small: `osproc.createPipeHandles` calls `CreatePipe` with
##   `nSize = 0`, the Windows default of roughly 4 KB.
## - Readiness is `poll(2)` on POSIX and `PeekNamedPipe` plus a 1 ms sleep on
##   Windows. No threads: `src/` has no threading model.
## - The drain reads the raw handles, never `p.outputStream`/`p.errorStream`
##   (on POSIX those are buffered `FILE*`s that would race it for bytes).
## - The child's stdin is always closed before the drain starts, after
##   `input` is written, so a tool that reads stdin sees EOF rather than
##   waiting out the deadline. `input` is capped at `MaxToolInputBytes`, far
##   below the pipe budget: it is written before anything is drained, and a
##   write the child is not reading must not be able to block.
##
## One deadline budget covers the whole run: the drain and the exit wait
## share it, so a bounded run returns within `timeoutMs + 2 *
## TerminateGraceMs`.
##
## A pipe is at EOF only when EVERY holder of its write end has closed it,
## and a tool's descendants inherit it: a compiler server or a backgrounded
## helper step can keep it open long after the tool itself has exited. So the
## drain also watches the tool's exit, and once the tool has exited it gives
## the pipes `PostExitDrainMs` more to reach EOF. A pipe still open then is
## held by a descendant, and the run ends `reIoError` ("held open"), NOT
## `reExited`: the capture never reached EOF, so nothing shows it is
## complete, and what the holder might still write is unknowable. Killing the
## holder would manufacture an EOF, which proves nothing about the answer
## either, so the run is never upgraded to a finished one after the kill.
##
## A BOUNDED run owns its process tree, so giving up on it ends the whole
## tree, not just the tool (`terminateAndReap`):
##
## - POSIX: the tool is spawned in its own process group (`poDaemon`, which
##   osproc's posix_spawn path turns into `POSIX_SPAWN_SETPGROUP`), and the
##   group is signalled: SIGTERM (+SIGCONT, so a stopped member can act on
##   it), a grace wait, then SIGKILL to the group. The tool is observed
##   exiting WITHOUT being reaped (`waitid(WNOWAIT)`) until the group kill is
##   done: an unreaped leader keeps its pid, and so the group id, from being
##   recycled, so `killpg` can never reach an unrelated group. Residual: a
##   descendant that leaves the group (`setsid`/`setpgid`) is out of reach.
##   The terminal's SIGINT goes to the foreground group, which the tool is
##   no longer in (a tool reading the terminal is stopped by SIGTTIN), so
##   the interrupt reaches it through the registry below instead. If the
##   group could not be set up (a `-d:useFork` build ignores `poDaemon`),
##   termination falls back to the single process.
## - Windows: the tool is assigned to a fresh Job Object right after the
##   spawn, and the job is terminated (`TerminateJobObject`). Not
##   `KILL_ON_JOB_CLOSE`: closing the job after a run that FINISHED must not
##   kill a server the tool legitimately left behind. Residual: osproc
##   offers no suspended spawn, so a descendant the tool starts before the
##   assignment (microseconds after `CreateProcess`) is outside the job. If
##   the job cannot be created or assigned, termination is single-process.
##
## A bounded run's tree is also registered, for its lifetime, in the
## process-global registry `crisol/process/tooltrees` keeps, so that an interrupt
## (SIGINT/SIGTERM, a console Ctrl-C/Ctrl-Break) ends it at once rather than
## leaving it to its deadline, or running on after crisol has exited. The
## registration follows the group or job's creation; on POSIX SIGINT and
## SIGTERM are held blocked from before the spawn until it, so no interrupt
## falls in between (a posix_spawn child starts with an empty signal mask).
## It is cleared before the tool is reaped, so a registered group id is
## always pinned by its unreaped leader. A run the interrupt ended is
## reported `reInterrupted`, whatever the tool's exit looked like: it did not
## finish, it was killed. So is a run that did not succeed while an interrupt
## was pending in the scope (`shutdownRequested`), though the registry never
## reached it: on Windows a console Ctrl-C reaches a tool sharing crisol's
## console directly, and can end it before the handler's sweep (or inside
## the residual window between `CreateProcess` and the job's registration),
## and an unregistered tree (the registry full, no group or job) is not
## killed at all. Its failure is no more a fact about the tool. A run that
## exited 0 is kept: it finished. A spawn that failed stays `reNotStarted`
## (`toolrun.RunProc`'s presence contract; it returns before this check):
## nothing ran for the interrupt to end. This module is the ONE place that reads the scope's signal to
## classify a tool run; callers read the ending (R14-D3).
##
## An UNBOUNDED run (`NoDeadline`: the measure-mode compile and link, the
## incremental-compile probe) runs inside a Supervisor-spawned worker, whose
## termination authority is that Supervisor's process-group kill. A group of
## its own would take it out of that kill domain, so an unbounded run keeps
## the caller's group and is terminated (on overflow or an I/O error only)
## as a single process. The held-pipe check applies to it all the same.
##
## A leaf over std, `crisol/cachesecrets` and `crisol/process/tooltrees` (which
## import no crisol module beyond the std-only `crisol/process/types`):
## `crisol/toolrun` imports it, and toolrun is imported by
## `crisol/closure`, `crisol/depgraph`, `crisol/artifactid` and
## `crisol/ccidentity`, so nothing imported here may reach back into the graph.

import std/[monotimes, options, os, osproc, streams, strtabs, times]  # process-contract-exempt: this module IS the tool-invocation capture layer (RFC-0007 §Scope)
import crisol/cachesecrets  # isCacheSecretName -- the one CRISOL_CACHE_* name test (toolEnv)
import crisol/process/tooltrees  # the live bounded-tree registry an interrupt kills (R11-L4)

when defined(windows):
  import std/winlean

  proc peekNamedPipe(hNamedPipe: Handle; lpBuffer: pointer;
                     nBufferSize: int32; lpBytesRead: ptr int32;
                     lpTotalBytesAvail: ptr int32;
                     lpBytesLeftThisMessage: ptr int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

  const ErrorBrokenPipe = 109'i32   # ERROR_BROKEN_PIPE; winlean does not export it

  proc createJobObjectW(lpJobAttributes: pointer; lpName: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
  proc assignProcessToJobObject(hJob, hProcess: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(hJob: Handle; uExitCode: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}
else:
  import std/posix  # poll(2) over subprocess pipes, waitid(2) and killpg(2) on the child; never file I/O (see module doc)

  var idtypePid {.importc: "P_PID", header: "<sys/wait.h>".}: cint
    ## `waitid`'s "one pid" selector. std/posix declares it only for some
    ## targets (not linux-amd64), so it is taken from the C header directly.

type
  RunEnd* = enum
    reExited      ## every pipe reached EOF and the child exited; the capture
                  ## is complete and the exit code is real
    reNotStarted  ## the spawn failed; nothing ran
    reTimedOut    ## no EOF-and-exit within the deadline; the child was killed
    reIoError     ## writing stdin, waiting on or reading a pipe failed, or
                  ## the pipes were still held open (by a descendant)
                  ## `PostExitDrainMs` after the child exited; the child
                  ## (and, on a bounded run, its tree) was killed
    reOverflow    ## the capture exceeded the byte cap; the child was killed
    reInterrupted ## an interrupt in the open scope ended the run (the
                  ## registry killed or refused its tree), or it failed while
                  ## one was pending; what it answered says nothing about the
                  ## tool (module doc)

  RunResult* = object
    ## The outcome of one tool run. Only `reExited` has an exit code and
    ## output: whatever a run that did not finish printed is dropped, never
    ## handed to a caller that might parse it.
    case ending*: RunEnd
    of reExited:
      exitCode*:  int
      output*:    string  ## stdout; with `poStdErrToStdOut`, both streams interleaved
      errOutput*: string  ## stderr on a separate-stream spawn; "" when merged
    of reNotStarted, reTimedOut, reIoError, reOverflow, reInterrupted:
      detail*:    string  ## why, for diagnostics

proc ran*(exitCode: int; output, errOutput: string): RunResult =
  ## A run that exited. For real runners and test fakes alike.
  RunResult(ending: reExited, exitCode: exitCode, output: output,
            errOutput: errOutput)

proc notRun*(ending: RunEnd; detail: string): RunResult =
  ## A run that did not finish. `ending` must not be `reExited`.
  case ending
  of reExited: raiseAssert "notRun is for endings other than reExited"
  of reNotStarted: RunResult(ending: reNotStarted, detail: detail)
  of reTimedOut:   RunResult(ending: reTimedOut, detail: detail)
  of reIoError:    RunResult(ending: reIoError, detail: detail)
  of reOverflow:   RunResult(ending: reOverflow, detail: detail)
  of reInterrupted: RunResult(ending: reInterrupted, detail: detail)

proc ok*(r: RunResult): bool =
  ## The command ran to an exit and exited 0.
  r.ending == reExited and r.exitCode == 0

proc describe*(r: RunResult): string =
  ## One line for a diagnostic: the exit code, or why there is none.
  case r.ending
  of reExited: "exited " & $r.exitCode
  of reNotStarted, reTimedOut, reIoError, reOverflow, reInterrupted: r.detail

const
  NoDeadline* = -1
    ## `timeoutMs` for a run that may take as long as it takes (the measure
    ## path's `nim --compileOnly` and link, the incremental-compile probe).
    ## Their wait is unbounded by design; the byte cap still applies.

  MaxToolOutputBytes* = 64 * 1024 * 1024
    ## Byte cap for one run's capture, both streams together. Far above any
    ## real tool output here (a dependency report is tens of KB, a
    ## `git diff --name-only` of a very large change a few MB); a child past
    ## it is misbehaving, and its capture is refused rather than grown.

  MaxToolInputBytes* = 1024
    ## Cap on `runTool`'s `input`. The whole of it is written before the
    ## drain starts, so it must fit the pipe budget (about 4 KB on Windows,
    ## see the module doc) whether or not the child reads it; the one caller
    ## that feeds stdin writes a single line of Nim.

  TerminateGraceMs* = 2_000
    ## How long `terminateAndReap` waits after `terminate()`, and again after
    ## `kill()`. Exported so a test can derive the worst-case bound of a
    ## bounded run (`timeoutMs + 2 * TerminateGraceMs`) from the source.

  PostExitDrainMs* = 1_000
    ## How long the drain keeps waiting for EOF once the child has exited.
    ## A child's own pipe ends are closed by the time its exit is visible
    ## (the kernel closes a dying process's handles before it reports the
    ## exit, on both platforms), so what is left is at most one pipe buffer
    ## of already-written bytes, read in well under a millisecond: past this
    ## bound the pipe is held by a descendant. Exported so a test can derive
    ## the held-pipe path's bound from the source.

  DrainChunk = 8192
  ExitPollMs = 10
  ExitCheckMs = 50
    ## The longest the POSIX drain blocks in `poll(2)` before checking again
    ## whether the child has exited: a descendant-held pipe raises no event.

proc elapsedMs(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

proc leftMs(start: MonoTime; timeoutMs: int): int64 =
  ## Milliseconds of the budget still unspent; `high(int64)` when unbounded.
  if timeoutMs == NoDeadline: high(int64)
  else: timeoutMs.int64 - elapsedMs(start)

type
  DrainEnd = enum deEof, deTimedOut, deIoError, deOverflow, deHeldOpen

  TreeOutcome = enum
    ## What an interrupt did to a tree, as `forget` settled it (R15-D9: two
    ## bools held these three states, and a fourth, "the handle was taken
    ## but the tree not interrupted", that no path can reach).
    toUntouched
      ## No interrupt reached the tree (so far). The caller keeps it and
      ## (Windows) its job handle.
    toKilledAtRegistration
      ## An interrupt was pending when the tree was registered, and killed
      ## it at once. The caller still owns the job handle and closes it.
    toSlotTaken
      ## An interrupt took the tree's registry slot and killed it. The job
      ## handle went with the slot: the one case `release` must not close
      ## it (R13-D3).

  ToolTree = object
    ## What `terminateAndReap` can reach beyond the child itself: the
    ## child's process group (POSIX), or the Job Object it was assigned to
    ## (Windows), and its slot in the `tooltrees` registry. The zero value
    ## (`noTree()`) is "the child alone".
    when defined(windows):
      job: Handle
    else:
      pgid: Pid
    reg: Registration     ## `rkUnregistered` (the zero value) until
                          ## `register`, and once `forget` has settled it
    fate: TreeOutcome  ## what an interrupt did to the tree

proc exitObserved(p: Process): bool =
  ## Whether `p` has exited, WITHOUT reaping it on POSIX (`waitid` with
  ## `WNOWAIT`): an unreaped child keeps its pid, and with it its process
  ## group id, from being recycled while `terminateAndReap` may still signal
  ## that group. On Windows the process handle, not a wait, pins the pid, so
  ## `peekExitCode` is safe. Never raises.
  when defined(windows):
    try: p.peekExitCode() != -1
    except OSError: false
  else:
    var info: SigInfo
    let rc = waitid(idtypePid, Id(p.processID), info,
                    WEXITED or WNOHANG or WNOWAIT)
    if rc != 0: return errno == ECHILD   # already reaped: long gone
    info.si_pid == Pid(p.processID)

proc noTree(): ToolTree =
  ## The child alone: termination is single-process.
  ToolTree()

proc interrupted(t: ToolTree): bool =
  ## Whether an interrupt killed the tree, at its registration or by taking
  ## its slot.
  t.fate != toUntouched

proc treeId(t: ToolTree): int =
  ## The registry's id for `t`: the group id or the job handle; 0 for none.
  when defined(windows): int(t.job)
  else: int(t.pgid)

proc register(t: var ToolTree) =
  ## Enter `t` in the live-tree registry, so an interrupt can end it.
  if treeId(t) != 0: t.reg = registerTool(treeId(t))

proc forget(t: var ToolTree) =
  ## Settle `t`'s registration; idempotent. Called before the tool is reaped
  ## (see the module doc). Records what an interrupt did to the tree
  ## (`TreeOutcome`): whether it killed it, and whether it did so by taking
  ## the slot, in which case (Windows) the job handle now belongs to the
  ## interrupt path. A tree killed at its registration keeps its handle:
  ## the caller closes it.
  case t.reg.kind
  of rkOwned:
    if not unregisterTool(t.reg.slot, treeId(t)):
      t.fate = toSlotTaken
  of rkKilledNow:
    t.fate = toKilledAtRegistration
  of rkUnregistered:
    discard
  t.reg = Registration()

proc ownTree(p: Process): ToolTree =
  ## The tree a bounded run may end: `p`'s own process group when the spawn
  ## really made it a group leader (`poDaemon`; a `-d:useFork` build ignores
  ## that, and then this is the child alone), or a fresh Job Object `p` has
  ## been assigned to. Never raises; a failure leaves the child alone.
  when defined(windows):
    let job = createJobObjectW(nil, nil)
    if job == 0: return noTree()
    let h = openProcess(PROCESS_SET_QUOTA or PROCESS_TERMINATE, 0,
                        DWORD(p.processID))
    if h == 0:
      discard closeHandle(job)
      return noTree()
    let assigned = assignProcessToJobObject(job, h) != 0
    discard closeHandle(h)
    if not assigned:
      discard closeHandle(job)
      return noTree()
    ToolTree(job: job)
  else:
    let pid = Pid(p.processID)
    if getpgid(pid) == pid: ToolTree(pgid: pid)
    else: noTree()

proc release(t: var ToolTree) =
  ## Settle the registration and close the job handle, unless an interrupt
  ## took it with the slot (`toSlotTaken`). Without `KILL_ON_JOB_CLOSE`
  ## closing ends nothing: a run that finished leaves whatever it started
  ## alone.
  forget(t)
  when defined(windows):
    if t.job != 0 and t.fate != toSlotTaken:
      discard closeHandle(t.job)
      t.job = 0

proc drain(p: Process; separate: bool; start: MonoTime; timeoutMs, maxBytes: int;
           bufs: var array[2, string]; detail: var string): DrainEnd =
  ## Read `p`'s stdout (and, when `separate`, its stderr) until every pipe
  ## reaches EOF, the budget is spent, a pipe operation fails, the capture
  ## passes `maxBytes`, or the pipes are still open `PostExitDrainMs` after
  ## `p` exited (`deHeldOpen`: a descendant holds them). The only exit that
  ## yields a complete capture is `deEof`.
  const heldDetail = "its output was still held open " & $PostExitDrainMs &
                     "ms after it exited, by a process it started; the " &
                     "capture never reached its end"
  var buf = newString(DrainChunk)
  var total = 0
  var exited = false
  var exitedAt: MonoTime

  when defined(windows):
    let handles = [Handle(p.outputHandle), Handle(p.errorHandle)]
    var open = [true, separate]
    while open[0] or open[1]:
      if not exited and exitObserved(p):
        exited = true
        exitedAt = getMonoTime()
      if exited and elapsedMs(exitedAt) >= PostExitDrainMs.int64:
        detail = heldDetail
        return deHeldOpen
      if leftMs(start, timeoutMs) <= 0: return deTimedOut
      var progressed = false
      for i in 0 .. 1:
        if not open[i]: continue
        var avail: int32 = 0
        if peekNamedPipe(handles[i], nil, 0, nil, addr avail, nil) == 0:
          let err = osLastError()
          if err.int32 == ErrorBrokenPipe or err.int32 == ERROR_HANDLE_EOF:
            open[i] = false   # the write end is closed: genuine EOF
            continue
          detail = "PeekNamedPipe failed: " & osErrorMsg(err)
          return deIoError
        if avail == 0: continue
        var got: int32 = 0
        let want = int32(min(avail.int, buf.len))
        if winlean.readFile(handles[i], addr buf[0], want, addr got, nil) == 0:
          let err = osLastError()
          detail = "ReadFile failed: " & osErrorMsg(err)
          return deIoError
        if got == 0:
          # Bytes were reported available and none came back: the pipe is not
          # in a state this loop understands. Never read as EOF.
          detail = "ReadFile returned no data from a pipe reporting " &
                   $avail & " available bytes"
          return deIoError
        total += got.int
        if total > maxBytes:
          detail = "output exceeded " & $maxBytes & " bytes"
          return deOverflow
        bufs[i].add buf[0 ..< got.int]
        progressed = true
      if not progressed and (open[0] or open[1]):
        sleep(1)
    deEof
  else:
    var fds: array[2, TPollfd]
    fds[0] = TPollfd(fd: cint(p.outputHandle), events: POLLIN, revents: 0)
    fds[1] = TPollfd(fd: if separate: cint(p.errorHandle) else: -1,
                     events: POLLIN, revents: 0)
    var open = if separate: 2 else: 1
    while open > 0:
      if not exited and exitObserved(p):
        exited = true
        exitedAt = getMonoTime()
      let heldLeft = if exited: PostExitDrainMs.int64 - elapsedMs(exitedAt)
                     else: ExitCheckMs.int64
      if heldLeft <= 0:
        detail = heldDetail
        return deHeldOpen
      let left = leftMs(start, timeoutMs)
      if left <= 0: return deTimedOut
      let pr = poll(addr fds[0], Tnfds(2), cint(min(left, heldLeft)))
      if pr < 0:
        if errno == EINTR: continue
        detail = "poll failed: " & $strerror(errno)
        return deIoError
      if pr == 0: continue   # a deadline tick with nothing ready
      for i in 0 .. 1:
        if fds[i].fd < 0: continue   # poll(2) ignores a negative fd
        if (fds[i].revents and
            (POLLIN or POLLHUP or POLLERR or POLLNVAL)) == 0: continue
        let n = read(fds[i].fd, addr buf[0], buf.len)
        if n < 0:
          if errno == EINTR or errno == EAGAIN: continue
          detail = "read failed: " & $strerror(errno)
          return deIoError
        if n == 0:
          fds[i].fd = -1   # the write end is closed: genuine EOF
          dec open
          continue
        total += n
        if total > maxBytes:
          detail = "output exceeded " & $maxBytes & " bytes"
          return deOverflow
        bufs[i].add buf[0 ..< n]
    deEof

proc waitForExitDeadline(p: Process; tree: var ToolTree;
                         timeoutMs: int): tuple[exitCode: int; timedOut: bool] =
  ## Wait until the child has exited or `timeoutMs` elapses, then reap it,
  ## clearing `tree`'s registry slot first. Checks at least once, so a child
  ## that has already exited is seen even with no budget left. `p` is left
  ## alive (and registered) on a timeout.
  let start = getMonoTime()
  while true:
    if exitObserved(p):
      forget(tree)
      let code = p.peekExitCode()
      if code != -1: return (exitCode: code, timedOut: false)
    if elapsedMs(start) >= timeoutMs.int64: return (exitCode: -1, timedOut: true)
    sleep(ExitPollMs)

proc waitExited(p: Process; timeoutMs: int): bool =
  ## Poll `exitObserved` until `p` has exited or `timeoutMs` elapses. Checks
  ## at least once. Does not reap on POSIX.
  let start = getMonoTime()
  while true:
    if exitObserved(p): return true
    if elapsedMs(start) >= timeoutMs.int64: return false
    sleep(ExitPollMs)

proc terminateAndReap(p: Process; tree: var ToolTree) =
  ## Give up on `p` and, when `tree` reaches past it, on everything it
  ## started: TERM, a bounded wait, KILL (SIGKILL, `TerminateProcess` and
  ## `TerminateJobObject` cannot be ignored), a second bounded wait, and
  ## only then the reap. `terminate()` alone is SIGTERM on POSIX, which a
  ## child that traps TERM or is wedged in D-state ignores (measured: an
  ## unbounded wait after it returned at the child's own 45 s lifetime).
  ##
  ## POSIX group: SIGTERM and SIGCONT to the group, a grace wait for `p`,
  ## then SIGKILL to the group ALWAYS -- the grace wait watches `p` alone,
  ## and a descendant that ignores TERM must not outlive it. `p` stays
  ## unreaped until after that last signal (see `exitObserved`), so the
  ## group id cannot have been recycled. Windows job: `TerminateJobObject`
  ## ends every member at once.
  ##
  ## The reap is last: `peekExitCode` (`waitpid(WNOHANG)` on POSIX) once `p`
  ## has exited, after `tree`'s registry slot is cleared. If even SIGKILL
  ## leaves `p` running (D-state), this returns anyway: a leaked zombie is
  ## preferred over hanging the invocation.
  when defined(windows):
    if tree.job != 0:
      discard terminateJobObject(tree.job, 1)
    else:
      try: p.terminate()
      except CatchableError: discard
    if not waitExited(p, TerminateGraceMs):
      try: p.kill()
      except CatchableError: discard
      discard waitExited(p, TerminateGraceMs)
  else:
    if tree.pgid != 0:
      discard killpg(tree.pgid, SIGTERM)
      discard killpg(tree.pgid, SIGCONT)
      let exited = waitExited(p, TerminateGraceMs)
      discard killpg(tree.pgid, SIGKILL)
      if not exited: discard waitExited(p, TerminateGraceMs)
    else:
      try: p.terminate()
      except CatchableError: discard
      if not waitExited(p, TerminateGraceMs):
        try: p.kill()
        except CatchableError: discard
        discard waitExited(p, TerminateGraceMs)
  forget(tree)
  try:
    discard p.peekExitCode()   # the reap; on Windows, cached state only
  except CatchableError:
    discard

proc capture(p: Process; separate: bool; tree: var ToolTree;
             timeoutMs, maxBytes: int): RunResult =
  ## Drain a child `runTool` already spawned, then wait for its exit, all
  ## within `timeoutMs` (or `NoDeadline`) from this call. `separate` says
  ## whether `p` has its own stderr pipe (spawned WITHOUT `poStdErrToStdOut`).
  ## On any ending but `reExited` the child (and `tree`) is terminated and
  ## the child reaped before this returns. Does not close `p`. Never raises.
  doAssert timeoutMs == NoDeadline or timeoutMs >= 0
  let start = getMonoTime()
  var bufs: array[2, string]
  var detail = ""
  var ended: DrainEnd
  try:
    ended = drain(p, separate, start, timeoutMs, maxBytes, bufs, detail)
  except CatchableError as e:
    ended = deIoError
    detail = "capture failed: " & e.msg

  case ended
  of deEof:
    try:
      if timeoutMs == NoDeadline:
        ran(p.waitForExit(), move bufs[0], move bufs[1])
      else:
        let (code, timedOut) =
          waitForExitDeadline(p, tree, int(max(leftMs(start, timeoutMs), 0'i64)))
        if timedOut:
          terminateAndReap(p, tree)
          notRun(reTimedOut, "closed its output but did not exit within " &
                             $timeoutMs & "ms")
        else:
          ran(code, move bufs[0], move bufs[1])
    except CatchableError as e:
      terminateAndReap(p, tree)
      notRun(reIoError, "waiting for its exit failed: " & e.msg)
  of deTimedOut:
    terminateAndReap(p, tree)
    notRun(reTimedOut, "did not answer within " & $timeoutMs & "ms")
  of deIoError:
    terminateAndReap(p, tree)
    notRun(reIoError, detail)
  of deOverflow:
    terminateAndReap(p, tree)
    notRun(reOverflow, detail)
  of deHeldOpen:
    terminateAndReap(p, tree)
    let code = try: p.peekExitCode() except CatchableError: -1
    notRun(reIoError, "exited " & $code & ", but " & detail)

proc toolEnv(): StringTableRef =
  ## The environment a tool is spawned with: crisol's own, minus every
  ## `CRISOL_CACHE_*` variable (CR18). The remote-cache credentials are
  ## env-borne, and a cache-enabled run removes them from crisol's own
  ## environment before its first child, but a `--no-cache` run, `plan`,
  ## `clean` and a library caller do not, and no tool reads them: a PATH-
  ## resolved `cc`, `vccexe` or `git` has no business holding a write
  ## credential. `nil` (inherit unchanged) when there is nothing to remove,
  ## so the common case spawns exactly as before.
  var found = false
  for k, _ in envPairs():
    if isCacheSecretName(k):
      found = true
      break
  if not found: return nil
  result = newStringTable(when defined(windows): modeCaseInsensitive
                          else: modeCaseSensitive)
  for k, v in envPairs():
    if not isCacheSecretName(k): result[k] = v

proc feedStdin(p: Process; input: string): string =
  ## Write `input` to `p`'s stdin and close it. Returns "" on success, or why
  ## it failed (the child exited before reading, say). Never raises.
  try:
    let s = p.inputStream
    if input.len > 0:
      s.write(input)
      s.flush()
    s.close()   # EOF; `osproc.close` tolerates the stream already closed
    ""
  except CatchableError as e:
    "writing its stdin failed: " & e.msg

proc runTool*(cmd: string; args: openArray[string]; workingDir: string;
              options: set[ProcessOption]; input: string;
              timeoutMs, maxBytes: int): RunResult =
  ## Spawn `cmd` with `args` (`startProcess`'s own semantics for `options`
  ## and `workingDir`; `""` inherits the caller's cwd), write `input` to its
  ## stdin and close it (`""` closes it at once), and capture the run. A
  ## spawn with `poStdErrToStdOut` has one pipe; any other has two, drained
  ## concurrently. `poParentStreams` is not supported (there is nothing to
  ## capture). A failed stdin write ends the run `reIoError`: the child did
  ## not get its whole input, so its answer is not an answer to it. A bounded
  ## run (any `timeoutMs` but `NoDeadline`) owns its process tree; see the
  ## module doc. The child's environment is crisol's minus `CRISOL_CACHE_*`
  ## (`toolEnv`). Never raises; a failed spawn is `reNotStarted`, and leaves
  ## crisol's own cwd where it was (R12-L1). A run an interrupt ended, or
  ## that failed while one was pending, is `reInterrupted` (module doc).
  doAssert poParentStreams notin options, "runTool captures output; poParentStreams has none"
  doAssert input.len <= MaxToolInputBytes, "runTool input exceeds MaxToolInputBytes"
  let bounded = timeoutMs != NoDeadline
  var argSeq = newSeq[string](args.len)
  for i, a in args: argSeq[i] = a
  var spawnOpts = options
  when defined(posix):
    # Its own process group, so the tree can be ended (see the module doc).
    # Not on Windows, where `poDaemon` means CREATE_NO_WINDOW instead.
    if bounded: spawnOpts.incl poDaemon
    # SIGINT/SIGTERM held from before the spawn until the group is
    # registered, so an interrupt cannot fall between the two; one that
    # arrives meanwhile is delivered at the unblock, and finds it registered.
    var interrupts, prevMask: Sigset
    if bounded:
      discard sigemptyset(interrupts)
      discard sigaddset(interrupts, SIGINT)
      discard sigaddset(interrupts, SIGTERM)
      discard pthread_sigmask(SIG_BLOCK, interrupts, prevMask)
  template unblockInterrupts() =
    when defined(posix):
      if bounded: discard pthread_sigmask(SIG_SETMASK, prevMask, interrupts)
  # R12-L1. On POSIX, osproc's posix_spawn path gives the child its cwd by
  # moving THIS process into `workingDir` for the spawn, and moves it back
  # only when the spawn succeeds. A spawn that fails (a tool not on PATH, a
  # relative command path that does not resolve from `workingDir`) left
  # crisol inside `workingDir`, and the cc probe deletes its scratch dir
  # right after: every later `getCurrentDir` raised. So the caller's cwd is
  # read here and put back on every path out of `startProcess` that raises,
  # osproc's own restore included. crisol spawns tools from one thread, so
  # nothing else observes the cwd while it is moved (osproc moves it for a
  # successful spawn too). Windows passes the directory to `CreateProcess`
  # and never moves the parent.
  var callerCwd = ""
  when defined(posix):
    if workingDir.len > 0:
      try:
        callerCwd = getCurrentDir()
      except CatchableError as e:
        # osproc reads it too, before it moves anything, and would fail the
        # same way.
        unblockInterrupts()
        return notRun(reNotStarted, "could not start `" & cmd &
                      "`: crisol's own working directory is unreadable: " & e.msg)
  var p: Process
  try:
    p = startProcess(cmd, workingDir = workingDir, args = argSeq,
                     env = toolEnv(), options = spawnOpts)
  except CatchableError as e:
    unblockInterrupts()
    var restored = ""
    if callerCwd.len > 0:
      try:
        setCurrentDir(callerCwd)
      except CatchableError as e2:
        restored = "; crisol's working directory could not be restored to " &
                   callerCwd & ": " & e2.msg
    return notRun(reNotStarted, "could not start `" & cmd & "`: " & e.msg & restored)
  defer: p.close()
  var tree = if bounded: ownTree(p) else: noTree()
  register(tree)
  unblockInterrupts()
  defer: release(tree)
  let fed = feedStdin(p, input)
  result = capture(p, poStdErrToStdOut notin options, tree, timeoutMs,
                   maxBytes)
  forget(tree)
  if tree.interrupted:
    result = notRun(reInterrupted, "was interrupted: crisol received a " &
                                   "shutdown signal and killed its process tree")
  elif shutdownRequested().isSome and not result.ok:
    result = notRun(reInterrupted, "was interrupted: it did not succeed (" &
                                   describe(result) & ") after crisol " &
                                   "received a shutdown signal")
  elif fed.len > 0 and result.ending == reExited:
    result = notRun(reIoError, fed)
  if result.ending != reExited:
    result.detail = "`" & cmd & "` " & result.detail
