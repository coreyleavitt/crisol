## test_tooltrees.nim — the interrupt scope's contracts in
## `crisol/process/tooltrees` (R13-D3, R13-D4, R13-D5, R14-D5, R14-S1).
##
## The handler's body is driven through `deliverInterrupt`, the same body the
## POSIX signal handler and the Windows console handler thread run, so no
## real signal reaches this process. Pinned:
##
##   * the scope's verdict (R14-S1): the outermost `leaveInterruptScope`
##     swaps the record out and answers it; an inner leave answers it and
##     leaves it for the outer one;
##   * outside a scope nothing is pending (R14-S1): a stamp that lands after
##     the outermost leave (a Windows console handler still running after
##     its removal) is not read by `shutdownRequested`, does not make
##     `registerTool` kill a tree, and is cleared by the next scope;
##   * one reader (R14-D5): `crisol/signals.shutdownRequested` is
##     `tooltrees.shutdownRequested`;
##   * the registration's three answers (R13-D3), with real process groups
##     on POSIX: owned, and false from `unregisterTool` only when an
##     interrupt took the slot; unregistered when the registry is full;
##     killed now when an interrupt is pending; and the zero value is an
##     unregistered tree, never a slot (R15-D4);
##   * one wake at a time (R13-D4): `attachInterruptWake` refuses a second;
##   * the escape (R13-D5), in a child process (this binary again, with
##     `--escape-child=<mode>`): with no Supervisor wake
##     attached the scope's second signal ends the process with 128 + n; with
##     one attached the second is the Supervisor's and the third ends it;
##     POSIX, it SIGKILLs every Supervisor child's process group before it
##     exits (R15-S2; `--escape-child=group:<pid file>`).
##
## Run with:
##   nim r --hints:off --warnings:off --path:src tests/unit/test_tooltrees.nim

import std/[options, os, osproc, strutils, unittest]
import crisol/toolexec
import crisol/process/tooltrees
import crisol/signals as sigs

when defined(windows):
  import std/winlean

const
  EscapeChildArg = "--escape-child="
    ## The child's argument (ahead of unittest's own filters): its mode.
  FakeTree = 999_999_996
    ## A tree id no process group or handle has: registering it kills
    ## nothing, and a kill aimed at it fails harmlessly.

proc fakeWake(n: int): auto =
  ## A wake that is never written to or set unless a signal is pending.
  when defined(windows): Handle(n)
  else: cint(n)

# The escape needs a process of its own: the child is this binary again.
let escapeMode =
  if paramCount() >= 1 and paramStr(1).startsWith(EscapeChildArg):
    paramStr(1)[EscapeChildArg.len .. ^1]
  else: ""
when defined(posix):
  import std/posix
  import crisol/process

  const GroupEscape = "group:"
    ## R15-S2: the escape child's mode that spawns a Supervisor child first;
    ## the rest of the argument is the file the child writes its pid to.

  proc readPidFile(path: string): int =
    let s = try: readFile(path) except IOError: ""
    if not s.endsWith('\n'): return -1
    try: parseInt(s.strip()) except ValueError: -1

  if escapeMode.startsWith(GroupEscape):
    # A Supervisor with the handler installed (its wake attached, as in a
    # real run) spawns a child in a process group of its own; then three
    # signals: the third is the escape.
    let pidFile = escapeMode[GroupEscape.len .. ^1]
    var sv = initSupervisor(installSignals = true)
    let r = sv.spawn(ChildSpec(
      argv: @["sh", "-c", "echo $$ > '" & pidFile & "'; exec sleep 60"],
      env: @[("PATH", getEnv("PATH"))],
      sinks: StdioSink(path: pidFile & ".sink")))
    doAssert r.ok, r.error
    var pid = -1
    for _ in 0 ..< 500:
      pid = readPidFile(pidFile)
      if pid > 0: break
      sleep(10)
    doAssert pid > 0, "the Supervisor child never wrote its pid"
    for (n, sig) in [(1, 2), (2, 15), (3, 15)]:
      deliverInterrupt(sig)
      stdout.write("survived " & $n & "\n")
      stdout.flushFile()
    quit(0)

if escapeMode.len > 0:
  enterInterruptScope()
  if escapeMode == "supervised":
    doAssert attachInterruptWake(fakeWake(1000))
  for (n, sig) in [(1, 2), (2, 15), (3, 15)]:
    deliverInterrupt(sig)
    stdout.write("survived " & $n & "\n")
    stdout.flushFile()
  quit(0)

suite "R14-S1 — the outermost leave answers the scope's signal":

  test "outside a scope nothing is pending":
    check shutdownRequested().isNone

  test "a scope with no signal answers none":
    enterInterruptScope()
    check shutdownRequested().isNone
    check leaveInterruptScope().isNone

  test "the outermost leave swaps the signal out and answers it":
    enterInterruptScope()
    deliverInterrupt(15)
    check shutdownRequested().isSome
    check shutdownRequested().get.signum == 15
    let verdict = leaveInterruptScope()
    check verdict.isSome
    if verdict.isSome: check verdict.get.signum == 15
    check shutdownRequested().isNone

  test "an inner leave answers the signal and leaves the record to the outer one":
    enterInterruptScope()
    enterInterruptScope()
    deliverInterrupt(2)
    let inner = leaveInterruptScope()
    check inner.isSome
    check shutdownRequested().isSome
    let outer = leaveInterruptScope()
    check outer.isSome
    if outer.isSome: check outer.get.signum == 2
    check shutdownRequested().isNone

  test "a stamp after the outermost leave is not read, kills nothing, and is cleared by the next scope":
    # A late Windows console handler: it runs after the handler's removal
    # and stamps the record with no scope open.
    deliverInterrupt(2)
    check shutdownRequested().isNone
    let reg = registerTool(FakeTree)
    check reg.kind == rkOwned
    if reg.kind == rkOwned:
      check unregisterTool(reg.slot, FakeTree)
    enterInterruptScope()
    check shutdownRequested().isNone
    check leaveInterruptScope().isNone

suite "R14-D5 — one reader":

  test "crisol/signals.shutdownRequested is tooltrees.shutdownRequested":
    check sigs.shutdownRequested == tooltrees.shutdownRequested

suite "R13-D3 — the registration's three answers":

  test "the zero value is an unregistered tree, not slot 0 (R15-D4)":
    # R15-D4: the zero value was `rkOwned` slot 0, a slot some other tree
    # may hold; unregistering it would answer false ("the interrupt took
    # the handle") for a tree no interrupt touched.
    check Registration().kind == rkUnregistered

  test "owned: unregisterTool answers true while no interrupt took the slot":
    let reg = registerTool(FakeTree)
    check reg.kind == rkOwned
    if reg.kind == rkOwned:
      check unregisterTool(reg.slot, FakeTree)

  test "a full registry answers rkUnregistered":
    var regs: seq[Registration]
    for i in 0 ..< MaxLiveTools:
      regs.add registerTool(FakeTree - 4 * i)
    let extra = registerTool(FakeTree - 4 * MaxLiveTools)
    check extra.kind == rkUnregistered
    for i, r in regs:
      check r.kind == rkOwned
      if r.kind == rkOwned:
        check unregisterTool(r.slot, FakeTree - 4 * i)

  when defined(posix):
    proc liveGroup(): Process =
      ## A sleeping child that leads a process group of its own.
      startProcess("sleep", args = ["30"], options = {poUsePath, poDaemon})

    proc endedWithin(p: Process; ms: int): bool =
      var waited = 0
      while waited < ms:
        if p.peekExitCode() != -1: return true
        sleep(20)
        waited += 20
      false

    test "killed now: a tree registered while an interrupt is pending is killed at once":
      let p = liveGroup()
      defer: p.close()
      enterInterruptScope()
      deliverInterrupt(2)
      let reg = registerTool(p.processID)
      discard leaveInterruptScope()
      check reg.kind == rkKilledNow
      check endedWithin(p, 5_000)
      if p.peekExitCode() == -1:
        p.kill()
        discard p.waitForExit()

    test "an interrupt takes an owned slot: unregisterTool answers false":
      let p = liveGroup()
      defer: p.close()
      enterInterruptScope()
      let reg = registerTool(p.processID)
      check reg.kind == rkOwned
      deliverInterrupt(2)
      if reg.kind == rkOwned:
        check not unregisterTool(reg.slot, p.processID)
      discard leaveInterruptScope()
      check endedWithin(p, 5_000)
      if p.peekExitCode() == -1:
        p.kill()
        discard p.waitForExit()

suite "R13-D4 — one wake at a time":

  test "attachInterruptWake refuses a second wake until the first detaches":
    enterInterruptScope()
    check attachInterruptWake(fakeWake(1000))
    check not attachInterruptWake(fakeWake(1004))
    detachInterruptWake()
    check attachInterruptWake(fakeWake(1004))
    detachInterruptWake()
    discard leaveInterruptScope()

suite "R13-D5 — a signal past the ones the scope's owner handles ends the process":

  proc escape(mode: string): tuple[code: int; output: string] =
    # `toolexec.runTool`, not osproc's `readAll`: on Windows that truncates
    # the output of a child that has exited.
    let r = runTool(getAppFilename(), [EscapeChildArg & mode], "",
                    {poStdErrToStdOut}, "", 30_000, MaxToolOutputBytes)
    if r.ending != reExited: return (-1, describe(r))
    (r.exitCode, r.output)

  test "no Supervisor attached: the second signal exits 128 + n":
    let (code, output) = escape("scope")
    checkpoint(output)
    check code == 143
    check "survived 1" in output
    check "survived 2" notin output

  when defined(posix):
    proc groupGone(pid: int; waitMs: int): bool =
      ## True once `pid` is no longer running: gone, or (Linux) a zombie
      ## its new parent has yet to reap.
      var waited = 0
      while true:
        when defined(linux):
          let st = try: readFile("/proc/" & $pid & "/stat") except IOError: ""
          let close = st.rfind(')')
          if st.len == 0 or (close >= 0 and st[close + 1 .. ^1].strip().startsWith("Z")):
            return true
        else:
          if posix.kill(Pid(pid), 0) != 0 and errno == ESRCH: return true
        if waited >= waitMs: return false
        sleep(20)
        waited += 20

    test "the escape ends every Supervisor child's process group before it exits (R15-S2)":
      # R15-S2: a compile or test child leads a process group of its own, so
      # nothing the process does at `_exit` reaches it; it outlived the
      # escape and the state lock the exit released.
      let pidFile = getTempDir() / ("crisol_r15s2_" & $getCurrentProcessId() & ".pid")
      removeFile(pidFile)
      defer:
        removeFile(pidFile)
        removeFile(pidFile & ".sink")
      let (code, output) = escape(GroupEscape & pidFile)
      checkpoint(output)
      check code == 143
      check "survived 2" in output
      check "survived 3" notin output
      let pid = readPidFile(pidFile)
      check pid > 0
      if pid > 0:
        let gone = groupGone(pid, 3_000)
        check gone
        if not gone: discard posix.kill(Pid(pid), SIGKILL)

  test "a Supervisor attached: the second is its own, and the third exits 128 + n":
    let (code, output) = escape("supervised")
    checkpoint(output)
    check code == 143
    check "survived 2" in output
    check "survived 3" notin output
