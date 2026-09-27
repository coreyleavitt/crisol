## test_tool_interrupt.nim — an interrupted crisol ends the bounded tool it
## is running (R11-L4).
##
## A bounded tool runs in a tree of its own (its own process group on POSIX,
## a Job Object on Windows), so the terminal's SIGINT no longer reaches it.
## Before the fix, Ctrl-C or SIGTERM during planning killed crisol through
## Nim's default handler and left the tool running to its own end (measured:
## a `nim` that slept 25 s in the discovery compile outlived crisol), and
## with a Supervisor's handler installed the interrupt waited the tool's
## whole deadline out. Pinned here:
##
##   * the registry's kill path (both platforms): `killLiveTools` ends a tool
##     `runTool` is running, `runTool` returns at once, and it reports the
##     run `reInterrupted`, never as an exit (R12-D8: it was `reIoError`);
##   * POSIX, the registry's refusal (R14-D3): a bounded tool started after
##     an interrupt landed in the open scope is killed at its registration
##     and reported `reInterrupted`; an unregistered (`NoDeadline`) run that
##     fails while the interrupt is pending is `reInterrupted` too, one that
##     exits 0 is still a finished run, and outside an interrupt a failing
##     run is an ordinary exit. The interrupt is a real SIGINT to this
##     process, caught by the scope's handler;
##   * POSIX, a Supervisor with `installSignals = true` live: SIGINT/SIGTERM
##     end the tool at once, not at its deadline;
##   * POSIX, an interrupt scope with no Supervisor (`enterInterruptScope`,
##     what the CLI opens around its invocation; R12-D3 folded the old
##     separate exit-at-once handler into it): SIGINT/SIGTERM kill the tool,
##     `runTool` returns interrupted, and the scope's owner exits 130/143;
##   * POSIX, the real CLI interrupted in its discovery compile (a `nim`
##     wrapper that hangs on the stdin compile): crisol exits 130/143
##     promptly, the tool is gone, and, since R12-D3 unwinds an interrupted
##     run instead of exiting from the handler, the probe has removed its
##     own scratch directory; a stale one (left by a run that was killed
##     outright) is reclaimed by the next run, while a fresh one (a
##     concurrent run's live probe) is kept.
##
##   * POSIX, the real CLI blocked where it never reads the interrupt (an
##     open(2) of a FIFO `--junit` report): the first signal is recorded,
##     and a second one ends the process at once with 128 + the signal
##     (R13-D5);
##   * Windows, bounded tools refused at registration after an interrupt
##     (played by the handler's own body, `deliverInterrupt`) close their
##     job handles (R13-D3: each one leaked).
##
## Windows: the console control handler is not exercised here (a
## `GenerateConsoleCtrlEvent` needs a shared console the container run does
## not give); the job-kill path it calls is, by the first suite.
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_tool_interrupt.nim

import std/[monotimes, options, os, osproc, streams, strtabs, strutils, times,
            typedthreads, unittest]
import crisol/toolexec
import crisol/process/tooltrees

when defined(windows):
  import std/winlean
else:
  import std/posix

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  repoRoot   = currentSourcePath().parentDir().parentDir().parentDir()
  binDir     = fixtureDir / "bin" / "toolintr"
  cacheDir   = fixtureDir / "nimcache" / "toolintr"
  ToolDeadlineMs = 20_000
    ## The tool's own deadline (and the driver's). An interrupted run must
    ## end far inside it.
  PromptMs = 5_000
    ## How long an interrupt may take to end things. Well under the deadline
    ## and under the ~14 s the unfixed Supervisor path waited.
  DeathWaitMs = 3_000
  PidWaitMs = 60_000
    ## How long the tool may take to start (the CLI plans first).

static:
  doAssert PromptMs < ToolDeadlineMs div 2

proc buildFixture(name: string): string =
  createDir(binDir)
  result = binDir / name.addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --warnings:off --path:" &
                          (repoRoot / "src") & " --nimcache:" &
                          (cacheDir / name) & " -o:" & result & " " &
                          (fixtureDir / name & ".nim"))
  doAssert rc == 0, name & " compile failed:\n" & o

let holderBin = buildFixture("pipe_holder")
let driverBin = buildFixture("tool_interrupt_driver")

proc freshPidFile(tag: string): string =
  result = getTempDir() / ("crisol_toolintr_" & $getCurrentProcessId() &
                           "_" & tag & ".pid")
  removeFile(result)
  removeFile(result & ".tmp")

proc readPid(path: string): int =
  if not fileExists(path): return -1
  try: parseInt(readFile(path).strip()) except ValueError: -1

proc waitPid(path: string; waitMs: int): int =
  let start = getMonoTime()
  while (getMonoTime() - start).inMilliseconds < waitMs:
    let pid = readPid(path)
    if pid > 0: return pid
    sleep(20)
  -1

when defined(linux):
  proc procState(pid: int): string =
    ## `/proc/<pid>/stat`'s state letter, or "" when the pid is gone.
    let st = try: readFile("/proc" / $pid / "stat") except IOError: ""
    if st.len == 0: return ""
    let afterComm = st.rfind(')')
    if afterComm < 0: return "?"
    let fields = st[afterComm + 1 .. ^1].splitWhitespace()
    if fields.len > 0: fields[0] else: "?"

proc toolGone(pid: int; waitMs: int): bool =
  ## True once `pid` is no longer running (gone, or a zombie awaiting a
  ## reap), within `waitMs`.
  when defined(windows):
    let h = openProcess(SYNCHRONIZE, 0, DWORD(pid))
    if h == 0: return true
    defer: discard closeHandle(h)
    waitForSingleObject(h, DWORD(waitMs)) == WAIT_OBJECT_0
  elif defined(linux):
    let start = getMonoTime()
    while true:
      let s = procState(pid)
      if s == "" or s == "Z": return true
      if (getMonoTime() - start).inMilliseconds >= waitMs: return false
      sleep(20)
  else:
    # No /proc: a zombie reads as alive here, which only errs towards red.
    let start = getMonoTime()
    while true:
      if posix.kill(Pid(pid), 0) != 0 and errno == ESRCH: return true
      if (getMonoTime() - start).inMilliseconds >= waitMs: return false
      sleep(20)

proc waitExit(p: Process; waitMs: int): int =
  ## `p`'s exit code within `waitMs`, or -1 (and `p` killed) past it.
  let start = getMonoTime()
  while (getMonoTime() - start).inMilliseconds < waitMs:
    let c = p.peekExitCode()
    if c != -1: return c
    sleep(20)
  p.kill()
  discard p.waitForExit()
  -1

# ---------------------------------------------------------------------------
# The registry's kill path, without a signal: a second thread plays the
# handler. It keeps calling `killLiveTools` until the run returns, so it
# cannot fire before `runTool` has registered the tool and miss it.
# ---------------------------------------------------------------------------

var killerDone: bool

proc killer(pidFile: string) {.thread.} =
  while readPid(pidFile) <= 0 and not atomicLoadN(addr killerDone, ATOMIC_SEQ_CST):
    sleep(10)
  while not atomicLoadN(addr killerDone, ATOMIC_SEQ_CST):
    killLiveTools()
    sleep(50)

suite "R11-L4 — the live tool registry's kill path":

  test "killLiveTools ends a running tool at once, and runTool reports it interrupted":
    let pidFile = freshPidFile("registry")
    atomicStoreN(addr killerDone, false, ATOMIC_SEQ_CST)
    var th: Thread[string]
    createThread(th, killer, pidFile)
    let t0 = getMonoTime()
    let r = runTool(holderBin, ["hang", pidFile], "", {}, "", ToolDeadlineMs,
                    MaxToolOutputBytes)
    let elapsedMs = (getMonoTime() - t0).inMilliseconds
    atomicStoreN(addr killerDone, true, ATOMIC_SEQ_CST)
    joinThread(th)
    checkpoint("ending: " & describe(r) & " after " & $elapsedMs & "ms")
    check elapsedMs < PromptMs
    check r.ending == reInterrupted
    check "interrupted" in describe(r)
    let pid = readPid(pidFile)
    check pid > 0
    if pid > 0: check toolGone(pid, DeathWaitMs)
    removeFile(pidFile)

  test "a run the registry did not interrupt is unaffected":
    let r = runTool(holderBin, ["exit"], "", {}, "", ToolDeadlineMs,
                    MaxToolOutputBytes)
    check r.ending == reExited
    check r.exitCode == 0

when defined(windows):
  proc getProcessHandleCount(hProcess: Handle; pdwHandleCount: var DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetProcessHandleCount".}

  proc handleCount(): int =
    var n: DWORD
    doAssert getProcessHandleCount(getCurrentProcess(), n) != 0
    int(n)

  suite "R13-D3 — a tool refused after an interrupt keeps no job handle":

    test "bounded tools refused at registration close their job handles":
      # The interrupt is played by the handler's own body (`deliverInterrupt`,
      # what the console handler thread runs): one signal in a scope with no
      # Supervisor attached, so every bounded tool after it is killed at its
      # registration. Before R13-D3 such a tool's job handle was treated as
      # the interrupt path's and never closed: one leaked handle per tool.
      const Runs = 20
      enterInterruptScope()
      deliverInterrupt(2)
      discard runTool(holderBin, ["exit"], "", {}, "", ToolDeadlineMs,
                      MaxToolOutputBytes)   # warm-up: lazy loads settle
      let before = handleCount()
      var interrupted = 0
      for _ in 0 ..< Runs:
        let r = runTool(holderBin, ["exit"], "", {}, "", ToolDeadlineMs,
                        MaxToolOutputBytes)
        if r.ending == reInterrupted: inc interrupted
      let after = handleCount()
      discard leaveInterruptScope()
      checkpoint("handles before " & $before & ", after " & $after)
      check interrupted == Runs
      check after - before < Runs div 4

when defined(posix):
  proc interruptThisProcess() =
    ## Deliver a real SIGINT to this process inside an open interrupt scope,
    ## and wait until the scope's handler has recorded it.
    doAssert posix.kill(getpid(), SIGINT) == 0
    let start = getMonoTime()
    while shutdownRequested().isNone and (getMonoTime() - start).inMilliseconds < PromptMs:
      sleep(5)
    doAssert shutdownRequested().isSome and
             shutdownRequested().get.signum == int(SIGINT),
      "the scope's handler never saw the SIGINT"

  suite "R14-D3 — the registry's refusal, and a run failing under an interrupt":

    test "a bounded tool started after an interrupt is refused at registration: reInterrupted":
      let pidFile = freshPidFile("refused")
      enterInterruptScope()
      interruptThisProcess()
      let t0 = getMonoTime()
      let r = runTool(holderBin, ["hang", pidFile], "", {}, "", ToolDeadlineMs,
                      MaxToolOutputBytes)
      let elapsedMs = (getMonoTime() - t0).inMilliseconds
      discard leaveInterruptScope()
      checkpoint("ending: " & $r.ending & ": " & describe(r) & " after " &
                 $elapsedMs & "ms")
      check elapsedMs < PromptMs
      check r.ending == reInterrupted
      check "interrupted" in describe(r)
      let pid = readPid(pidFile)
      if pid > 0: check toolGone(pid, DeathWaitMs)
      removeFile(pidFile)

    test "an unregistered run that fails while an interrupt is pending is reInterrupted; one that exits 0 is kept":
      enterInterruptScope()
      interruptThisProcess()
      let failed = runTool(holderBin, ["fail"], "", {}, "", NoDeadline,
                           MaxToolOutputBytes)
      let finished = runTool(holderBin, ["exit"], "", {}, "", NoDeadline,
                             MaxToolOutputBytes)
      discard leaveInterruptScope()
      checkpoint("failed: " & $failed.ending & ": " & describe(failed))
      check failed.ending == reInterrupted
      check finished.ending == reExited
      if finished.ending == reExited: check finished.exitCode == 0

    test "outside an interrupt, a failing run is an ordinary exit":
      let r = runTool(holderBin, ["fail"], "", {}, "", ToolDeadlineMs,
                      MaxToolOutputBytes)
      check r.ending == reExited
      if r.ending == reExited: check r.exitCode == 64

when defined(linux):
  proc signalDriver(mode: string; sig: cint): tuple[code: int; afterMs: int64;
                                                    output: string; toolGone: bool] =
    ## Start the driver, signal it once its tool is running, and report how
    ## it ended. Whether the tool is gone is observed BEFORE the driver's
    ## output is read: the tool holds a copy of the driver's output pipe, so
    ## reading that to EOF would wait for the tool itself to end.
    let pidFile = freshPidFile(mode & "_" & $sig)
    let p = startProcess(driverBin, args = [mode, holderBin, pidFile],
                         options = {poStdErrToStdOut})
    defer: p.close()
    let pid = waitPid(pidFile, PidWaitMs)
    doAssert pid > 0, "the tool never started"
    let t0 = getMonoTime()
    discard posix.kill(Pid(p.processID), sig)
    let code = waitExit(p, ToolDeadlineMs + 5_000)
    let afterMs = (getMonoTime() - t0).inMilliseconds
    let gone = toolGone(pid, DeathWaitMs)
    let output = try: p.outputStream.readAll() except CatchableError: ""
    removeFile(pidFile)
    (code, afterMs, output, gone)

  suite "R11-L4 — a signal while a Supervisor's handler is installed":
    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "signal " & $sig & " ends the running tool at once, not at its deadline":
        let (code, afterMs, output, gone) = signalDriver("supervised", sig)
        checkpoint("exit " & $code & " after " & $afterMs & "ms; output: " & output)
        check afterMs < PromptMs
        check code == want
        check "interrupted" in output
        check gone

  suite "R11-L4 — a signal in an interrupt scope with no Supervisor":
    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "signal " & $sig & " kills the running tool and exits " & $want:
        let (code, afterMs, output, gone) = signalDriver("scope", sig)
        checkpoint("exit " & $code & " after " & $afterMs & "ms; output: " & output)
        check afterMs < PromptMs
        check code == want
        check "interrupted" in output
        check gone

  # -------------------------------------------------------------------------
  # The real CLI, interrupted in its discovery compile.
  # -------------------------------------------------------------------------

  let crisolBin = block:
    let b = getTempDir() / "crisol_toolintr_bin" / "crisol"
    createDir(b.parentDir)
    let (o, rc) = execCmdEx("nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                            (getTempDir() / "crisol_toolintr_nimcache") & " -o:" &
                            b & " " & (repoRoot / "src" / "crisol.nim"))
    doAssert rc == 0, "crisol build failed:\n" & o
    b

  let wrapperDir = block:
    ## A `nim` that hangs on the stdin compile (the cc probe's discovery
    ## compile, `-` as the input file) when CRISOL_TEST_HANG_PIDFILE is
    ## set, recording its pid there, and is the real nim otherwise.
    let d = getTempDir() / "crisol_toolintr_wrapper"
    createDir(d)
    let realNim = findExe("nim")
    doAssert realNim.len > 0
    writeFile(d / "nim", "#!/bin/sh\n" &
      "if [ -n \"$CRISOL_TEST_HANG_PIDFILE\" ]; then\n" &
      "  for a in \"$@\"; do\n" &
      "    if [ \"$a\" = \"-\" ]; then\n" &
      "      echo $$ > \"$CRISOL_TEST_HANG_PIDFILE.tmp\"\n" &
      "      mv \"$CRISOL_TEST_HANG_PIDFILE.tmp\" \"$CRISOL_TEST_HANG_PIDFILE\"\n" &
      "      exec sleep 25\n" &
      "    fi\n" &
      "  done\n" &
      "fi\n" &
      "exec " & quoteShell(realNim) & " \"$@\"\n")
    setFilePermissions(d / "nim", {fpUserRead, fpUserWrite, fpUserExec,
                                   fpGroupRead, fpGroupExec, fpOthersRead,
                                   fpOthersExec})
    d

  proc freshProject(tag: string): string =
    result = getTempDir() / ("crisol_toolintr_proj_" & tag & "_" &
                             $getCurrentProcessId())
    removeDir(result)
    createDir(result / "tests" / "unit")
    writeFile(result / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    writeFile(result / "crisol.kdl",
              "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

  proc cliEnv(hangPidFile: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): result[k] = v
    result["PATH"] = wrapperDir & ":" & getEnv("PATH")
    if hangPidFile.len > 0: result["CRISOL_TEST_HANG_PIDFILE"] = hangPidFile

  proc probeDirs(root: string): seq[string] =
    for kind, path in walkDir(root / ".crisol"):
      if kind == pcDir and path.extractFilename.startsWith("ccprobe_"):
        result.add path

  suite "R11-L4 — the CLI interrupted in its discovery compile":
    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "signal " & $sig & " to crisol's group: exit " & $want &
           ", the tool is gone, the probe cleaned up, and a stale probe directory is reclaimed":
        let root = freshProject($sig)
        defer: removeDir(root)
        let pidFile = freshPidFile("cli_" & $sig)
        # Its own group, as a terminal job is: the group signal is what a
        # Ctrl-C delivers, and the tool (in a group of its own) is not in it.
        let p = startProcess(crisolBin, workingDir = root,
                             args = ["run", "--config", root / "crisol.kdl",
                                     "--jobs", "1"],
                             env = cliEnv(pidFile),
                             options = {poStdErrToStdOut, poDaemon})
        defer: p.close()
        let toolPid = waitPid(pidFile, PidWaitMs)
        doAssert toolPid > 0, "the discovery compile never started"
        let t0 = getMonoTime()
        discard killpg(Pid(p.processID), sig)
        let code = waitExit(p, ToolDeadlineMs + 10_000)
        let afterMs = (getMonoTime() - t0).inMilliseconds
        checkpoint("exit " & $code & " after " & $afterMs & "ms")
        check afterMs < PromptMs
        check code == want
        check toolGone(toolPid, DeathWaitMs)
        removeFile(pidFile)

        # The interrupt unwinds the run, so the probe removes its own
        # scratch directory. One left by a run that was killed outright
        # (SIGKILL) is reclaimed by the next run once it is stale.
        let left = probeDirs(root)
        checkpoint("probe directories left: " & $left)
        check left.len == 0
        let stale = getTime() - initDuration(hours = 2)
        let killed = root / ".crisol" / "ccprobe_killed"
        createDir(killed)
        setLastModificationTime(killed, stale)
        let live = root / ".crisol" / "ccprobe_live"
        createDir(live)   # a concurrent run's probe, in progress
        let (o, rc) = execCmdEx(quoteShell(crisolBin) & " run --jobs 1 --config " &
                                quoteShell(root / "crisol.kdl"),
                                env = cliEnv(""), workingDir = root)
        checkpoint("next run: exit " & $rc & "\n" & o)
        check not dirExists(killed)
        check dirExists(live)

  # -------------------------------------------------------------------------
  # R13-D5: a second signal is the escape from a run that does not poll.
  # Once its run is over, crisol opens its `--junit` report for writing; a
  # FIFO with no reader blocks that open(2), which the handler's SA_RESTART
  # resumes after each signal, and nothing on the main path reads the
  # interrupt meanwhile. The first signal is recorded for a graceful unwind
  # that cannot come; the second must end the process at once, 128 + the
  # signal.
  # -------------------------------------------------------------------------

  proc blockedInOpen(pid: int; waitMs: int): bool =
    ## True once `pid` sleeps in the kernel inside an open(2)/openat(2)
    ## (`/proc/<pid>/syscall` names the syscall a blocked task is in).
    let start = getMonoTime()
    while (getMonoTime() - start).inMilliseconds < waitMs:
      let sc = try: readFile("/proc" / $pid / "syscall") except IOError: ""
      let nr = sc.splitWhitespace()
      when defined(amd64):
        const OpenCalls = ["2", "257"]       # open, openat
      else:
        const OpenCalls = ["56"]             # openat (the generic table)
      if nr.len > 0 and nr[0] in OpenCalls and procState(pid) == "S":
        return true
      sleep(20)
    false

  suite "R13-D5 — a second signal ends a run that does not poll":
    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "a second signal " & $sig & " exits " & $want &
           " at once while crisol is blocked opening its report":
        let root = freshProject("fifo_" & $sig)
        defer: removeDir(root)
        let fifo = root / "report.xml"
        doAssert mkfifo(fifo.cstring, Mode(0o600)) == 0
        let p = startProcess(crisolBin, workingDir = root,
                             args = ["run", "--config", root / "crisol.kdl",
                                     "--jobs", "1", "--junit", fifo],
                             env = cliEnv(""),
                             options = {poStdErrToStdOut, poDaemon})
        defer: p.close()
        doAssert blockedInOpen(p.processID, PidWaitMs),
          "crisol never blocked opening the FIFO report"
        discard killpg(Pid(p.processID), sig)
        sleep(300)
        # The first signal is recorded for the unwind, not an exit.
        check p.peekExitCode() == -1
        check blockedInOpen(p.processID, DeathWaitMs)
        let t0 = getMonoTime()
        discard killpg(Pid(p.processID), sig)
        let code = waitExit(p, PromptMs + 5_000)
        let afterMs = (getMonoTime() - t0).inMilliseconds
        checkpoint("exit " & $code & " after " & $afterMs & "ms")
        check afterMs < PromptMs
        check code == want

when isMainModule:
  echo "test_tool_interrupt done"
