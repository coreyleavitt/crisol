## test_signal.nim — A6/R2 integration tests for signal handling.
##
## All signal delivery happens inside forked CHILD processes so the test
## runner itself is never killed.
##
## Tests:
##   1. SIGINT to execute() → child exits 130 (128+2); no leaked grandchildren.
##   2. Normal run with signal handlers installed → completes correctly.
##
## Coordination for test 1:
##   - A temp file path is communicated to the fixture via the HANG_PID_FILE
##     env var.  hang_with_pid.nim writes its PID there before sleeping.
##   - Parent polls for the file, then signals the child that is running
##     execute().
##   - Parent asserts child exit status 130 and that the hung process is dead.

import std/[os, strutils, times, unittest]
import std/posix
import crisol/types
import crisol/runner
import crisol/depgraph
import crisol/sandbox

# A6: live run path is hermetic by default; allowlist HANG_PID_FILE so the
# hang_with_pid fixture can announce its grandchild PID to the parent.
let hangSpec = resolveSandbox(passthroughs = @["HANG_PID_FILE"])

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pollForFile(path: string; timeoutMs: int): bool =
  let step = 50
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc processDeadOrZombie(pid: Pid; timeoutMs: int): bool =
  ## Returns true once the process is dead or a zombie (no longer executing).
  let step = 30
  var elapsed = 0
  let statPath = "/proc/" & $int(pid) & "/stat"
  while elapsed < timeoutMs:
    if not fileExists(statPath):
      return true
    let content = readFile(statPath)
    let closeIdx = content.rfind(')')
    if closeIdx >= 0 and closeIdx + 2 < content.len:
      if content[closeIdx + 2] == 'Z':
        return true
    os.sleep(step)
    elapsed += step
  false

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

# ---------------------------------------------------------------------------
# Suite 1: SIGINT interrupts execute() and kills all children
# ---------------------------------------------------------------------------

suite "signal handling — SIGINT kills pool and exits 130":

  test "SIGINT to execute() child: exits 130, grandchild processes cleaned up":
    ## Strategy:
    ##   1. Parent forks a child that installs signal handlers and runs execute()
    ##      over hang_with_pid.nim.
    ##   2. hang_with_pid.nim writes its PID to a temp file before sleeping.
    ##   3. Parent polls for the PID file (up to 60 s — enough for compile + run).
    ##   4. Parent sends SIGINT to the child (the execute() process).
    ##   5. Assert child exits with status 130 (128 + SIGINT=2).
    ##   6. Assert the hang_with_pid process is dead or zombie (no leak).

    let tmpDir    = getTempDir() / ("crisol_sig_test_" & $int(getpid()))
    let pidFile   = tmpDir / "hang_pid.txt"

    createDir(tmpDir)
    defer:
      try: removeDir(tmpDir) except: discard

    if fileExists(pidFile): removeFile(pidFile)

    # -----------------------------------------------------------------------
    # Fork the child that will run execute().
    # -----------------------------------------------------------------------
    let childPid = fork()
    check childPid >= 0

    if childPid == 0:
      # =====================================================================
      # CHILD process: install signal handlers, run execute() over
      # hang_with_pid.nim, then exit 0 if unexpectedly completed.
      # =====================================================================

      # Tell hang_with_pid where to write its PID.
      putEnv("HANG_PID_FILE", pidFile)

      let fdir = fixtureDir()
      let eps  = @[mkEp(fdir / "hang_with_pid.nim")]
      let cfg  = Config(jobs: 1, compileTimeoutSecs: 60, timeoutSecs: 60)
      let p    = plan(cfg, eps, emptyDepGraph())

      try:
        var g = emptyDepGraph()
        # rfc-0007 A1e-ii: CrisolInterrupted is retired — execute() returns
        # NORMALLY on SIGINT/SIGTERM now; `interruptedOut` is the real signal.
        # rfc-0007 A2b: `installSignals = true` makes THIS execute() call's
        # own Supervisor own SIGINT/SIGTERM installation for its duration —
        # replacing the old crisol/signals.installSignalHandlers() ceremony
        # this test used to run itself; `shutdownSignalOut` carries the real
        # signum, replacing signals.pendingSignal().
        var interrupted = false
        var shutdownSignum = 0
        discard execute(p, config = cfg, graph = g, cache = cacheDisabled(hangSpec),
                        interruptedOut = addr interrupted,
                        shutdownSignalOut = addr shutdownSignum,
                        installSignals = true)
        if interrupted:
          # Correct path: exit 128 + signum so parent can verify.
          exitnow(cint(128 + shutdownSignum))
        else:
          # execute() returned normally WITHOUT being interrupted (shouldn't
          # happen with a hung fixture) — exit 0, parent sees this as a
          # test failure.
          exitnow(0)
      except:
        exitnow(cint(1))
      # =====================================================================

    # -----------------------------------------------------------------------
    # PARENT: wait for hang_with_pid to announce itself, then signal the child.
    # -----------------------------------------------------------------------

    # Poll up to 60 s for hang_with_pid to write its PID file.
    # (This covers: compile time for hang_with_pid.nim + process startup.)
    let appeared = pollForFile(pidFile, 60_000)
    check appeared

    if not appeared:
      # Safety: kill child before checking so the test doesn't hang.
      discard kill(childPid, SIGKILL)
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      fail()

    # Read the PID of the hung grandchild.
    let gcPid = Pid(parseInt(readFile(pidFile).strip()))
    check int(gcPid) > 0

    # Send SIGINT to the child (execute() process).
    check kill(childPid, SIGINT) == 0

    # Wait for the child to exit (up to 10 s — drain + kill should be quick).
    var wstatus: cint = 0
    let deadline = epochTime() + 10.0
    var reaped = false
    while epochTime() < deadline:
      let r = waitpid(childPid, wstatus, WNOHANG)
      if r == childPid:
        reaped = true
        break
      os.sleep(100)

    check reaped

    # Verify exit status 130 (128 + SIGINT=2).
    if reaped:
      let exitedNormally = WIFEXITED(wstatus)
      let exitStatus = if exitedNormally: int(WEXITSTATUS(wstatus)) else: -1
      check exitedNormally
      check exitStatus == 130

    # Verify the hang_with_pid grandchild is dead (no leak).
    let gcDead = processDeadOrZombie(gcPid, 3_000)
    check gcDead


# ---------------------------------------------------------------------------
# Suite 2: normal run with signal handlers installed completes correctly
# ---------------------------------------------------------------------------

suite "signal handling — normal run with handlers installed":

  test "pass_always.nim succeeds even when signal handlers are installed":
    ## Regression: installing signal handlers (rfc-0007 A2b: execute()'s own
    ## Supervisor, via installSignals = true) must not interfere with a
    ## normal run that completes without any signal.

    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "pass_always.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 30)
    let p    = plan(cfg, eps, emptyDepGraph())

    var g = emptyDepGraph()
    # rfc-0007 A1e-ii: no CrisolInterrupted to catch any more — a plain call.
    let results = execute(p, config = cfg, graph = g, installSignals = true)

    check results.len == 1
    check results[0].outcome == oPassed

  test "fail_always.nim fails even when signal handlers are installed":
    ## A failing entrypoint still reports oFailed; signal handlers don't
    ## suppress normal failures.

    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "fail_always.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 30)
    let p    = plan(cfg, eps, emptyDepGraph())

    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g, installSignals = true)

    check results.len == 1
    check results[0].outcome == oFailed
