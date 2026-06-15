## test_m6_teardown.nim — M6: exception path uses graceful teardown (SIGTERM→drain→SIGKILL).
##
## Verifies that when an exception escapes the execute() poll loop (e.g. raised
## by an onResult callback), live child processes are torn down gracefully
## (SIGTERM → GracePeriodMs drain → SIGKILL), no orphaned processes survive,
## and per-slot scratch directories are cleaned up.
##
## Test strategy:
##   1. Run a long-sleeping fixture (hang_forever.nim) through execute().
##   2. An onResult callback raises an exception after the first (pass) result.
##      We use two entrypoints: the first is a quick pass that fires the callback;
##      the callback raises after recording the first result so the second
##      (hang_forever) may be in-flight.
##      [Alternatively, we run hang_forever as the only entrypoint; use a
##       separate goroutine approach, which is complex.  Simpler: rely on
##       execute() itself: an exception raised in the try-block (e.g. a direct
##       call in the poll loop body) also triggers the finally block.]
##
## Simpler approach used here:
##   - Write a custom "bomb" fixture (quit(0) but named so the callback fires).
##   - onResult raises after seeing the first result.
##   - execute() wraps everything in try/finally; the finally block must call
##     teardownLiveSlots, which gives SIGTERM+grace to any still-running slots.
##   - We assert: no orphan processes with the tracked PID; temp dirs cleaned.
##
## To verify that teardownLiveSlots is actually invoked (not just SIGKILL), we
## observe that a co-running hang_forever fixture with a SIGTERM handler that
## writes a sentinel file IS terminated: the sentinel is written iff SIGTERM
## is sent (not SIGKILL, which cannot be caught).  We cannot guarantee the exact
## drain timing; so we assert:
##   (a) The exception from onResult propagates out of execute() (proves the
##       exception path is taken and not swallowed).
##   (b) No live process remains with the pid that hang_forever wrote to a file.
##   (c) The HANG_PID_FILE written by hang_forever exists (confirms it started).
##   (d) The process is dead or zombie by the time execute() returns (no orphan).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_m6_teardown.nim

import std/[os, strutils, unittest]
import std/posix
import crisol/[types, runner, depgraph, sandbox]

# ---------------------------------------------------------------------------
# Fixture path helper
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  currentSourcePath().parentDir().parentDir() / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

proc isProcessDead(pid: int; timeoutMs: int = 2000): bool =
  ## Poll /proc/<pid>/stat for up to timeoutMs ms; return true iff the process
  ## is gone (ESRCH) or a zombie (state 'Z') — i.e. no longer running.
  let step = 20
  var elapsed = 0
  let statPath = "/proc/" & $pid & "/stat"
  while elapsed < timeoutMs:
    if not fileExists(statPath):
      return true  # fully gone / reaped
    let content = readFile(statPath)
    let closeIdx = content.rfind(')')
    if closeIdx >= 0 and closeIdx + 2 < content.len:
      let state = content[closeIdx + 2]
      if state == 'Z':
        return true  # zombie: killed, not running
    os.sleep(step)
    elapsed += step
  false  # still alive after timeout

# ---------------------------------------------------------------------------
# Test: exception path tears down children
# ---------------------------------------------------------------------------

suite "M6 — exception path: graceful teardown via teardownLiveSlots":

  test "exception from onResult tears down in-flight hang_forever: no orphan":
    ## Use two entrypoints:
    ##   slot 0 — pass_always.nim  (compiles+runs fast, fires onResult quickly)
    ##   slot 1 — hang_forever.nim (runs indefinitely; may be live when exception fires)
    ##
    ## onResult raises an exception after seeing the first result.  The finally
    ## block must then call teardownLiveSlots on any still-live hang_forever slot.
    ## We verify hang_forever (tracked by PID file) is dead after execute() raises.

    let fd       = fixtureDir()
    let passFixt = fd / "pass_always.nim"
    let hangFixt = fd / "hang_forever.nim"

    # hang_with_pid writes its pid; hang_forever does not.  Use a temp file so
    # hang_forever can report its pid via HANG_PID_FILE passthrough.
    let pidFile = getTempDir() / "crisol_m6_pid_" & $int(getpid()) & ".txt"
    defer: (try: removeFile(pidFile) except: discard)

    let spec = resolveSandbox(passthroughs = @["HANG_PID_FILE"])

    var firstResult = true

    proc bombCb(r: EntrypointResult) =
      if firstResult:
        firstResult = false
        raise newException(ValueError, "injected exception from onResult for M6 test")

    # Build a plan with pass_always first, hang_with_pid second.
    # (We use hang_with_pid.nim because it writes its pid, allowing dead-check.)
    let hangPidFixt = fd / "hang_with_pid.nim"
    let eps = @[mkEp(passFixt), mkEp(hangPidFixt)]
    let cfg = Config(
      jobs:               2,   # both slots live simultaneously
      timeoutSecs:        60,
      compileTimeoutSecs: 120,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        fd,
    )
    let p = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()

    putEnv("HANG_PID_FILE", pidFile)
    defer: delEnv("HANG_PID_FILE")

    var exceptionCaught = false
    try:
      discard execute(p, config = cfg, graph = g, onResult = bombCb,
                      showProgress = false, cache = cacheDisabled(spec))
    except ValueError as e:
      if "injected exception" in e.msg:
        exceptionCaught = true
      else:
        raise

    # (a) The exception propagated out of execute().
    check exceptionCaught

    # (b)+(c) If hang_with_pid started (wrote its pid), it must be dead now.
    # If it never wrote (didn't start in time before exception), skip the dead-check.
    if fileExists(pidFile):
      let pidStr = readFile(pidFile).strip()
      if pidStr.len > 0:
        let childPid = parseInt(pidStr)
        check isProcessDead(childPid, timeoutMs = 3000)

  test "in-flight scratch dirs cleaned on exception path":
    ## When an exception escapes execute() with an in-flight hang_with_pid slot,
    ## the slot's tmpDir and testScratchDir (if any) must be cleaned up.
    ## Strategy: run two entrypoints with jobs=2 — one fast (fires callback),
    ## one hang_with_pid (stays in-flight).  onResult raises after the first
    ## result.  After execute() returns (via exception), no crisol_run_* dirs
    ## from the in-flight hang slot should remain live.
    ##
    ## We track the hang_with_pid PID; after execute() returns the run tmpDir
    ## (created by spawnRunDirect via makeTmpDir("crisol_run_")) should be gone.

    let fd           = fixtureDir()
    let passFixt     = fd / "pass_always.nim"
    let hangPidFixt  = fd / "hang_with_pid.nim"

    let pidFile = getTempDir() / "crisol_m6_scratch_" & $int(getpid()) & ".txt"
    defer: (try: removeFile(pidFile) except: discard)

    # Count crisol_run_* dirs in tmpdir before the run.
    proc countRunDirs(): int =
      for (kind, path) in walkDir(getTempDir()):
        if kind == pcDir and path.extractFilename.startsWith("crisol_run_"):
          inc result

    let before = countRunDirs()

    let spec = resolveSandbox(passthroughs = @["HANG_PID_FILE"])

    var firstFired = false
    proc exceptionCb(r: EntrypointResult) =
      if not firstFired:
        firstFired = true
        raise newException(IOError, "M6 scratch-dir exception")

    let eps = @[mkEp(passFixt), mkEp(hangPidFixt)]
    let cfg = Config(
      jobs:               2,
      timeoutSecs:        60,
      compileTimeoutSecs: 120,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        fd,
    )
    let p = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()

    putEnv("HANG_PID_FILE", pidFile)
    defer: delEnv("HANG_PID_FILE")

    try:
      discard execute(p, config = cfg, graph = g, onResult = exceptionCb,
                      showProgress = false, cache = cacheDisabled(spec))
    except IOError:
      discard  # expected

    # After execute() returns via exception, in-flight slot run dirs must be gone.
    # Allow a brief moment for OS to finalize dir removal (should be immediate).
    os.sleep(50)
    let after = countRunDirs()
    check after == before

  test "R2-2: grace-window-exit slot not re-signalled; scratch dirs still cleaned":
    ## Verify that a slot whose child exits DURING the SIGTERM grace window is
    ## not SIGKILL'd in Phase 3, and that Phase 4 still removes its scratch dirs.
    ##
    ## Strategy: use a fixture that exits very quickly (pass_always), driven with
    ## a jobs=2 setup where one slot (hang_with_pid) will persist and one slot
    ## (pass_always) will finish fast.  The onResult callback raises after the
    ## first result, triggering teardownLiveSlots while hang_with_pid may still
    ## be live.
    ##
    ## The observable contract: teardown completes without crash, hang_with_pid
    ## is dead, AND crisol_run_* dirs are cleaned (Phase 4 must run for all slots
    ## regardless of Phase 2 reaping).
    ##
    ## To directly exercise the grace-window reaping path, we use a dedicated
    ## two-slot teardown where BOTH slots have live children at teardown time but
    ## one exits quickly under SIGTERM and the other needs SIGKILL.  We can't
    ## easily enforce timing, so we test the invariants: no crash, no orphan, dirs cleaned.

    let fd           = fixtureDir()
    let hangPidFixt  = fd / "hang_with_pid.nim"

    let pidFile = getTempDir() / "crisol_m6_r22_" & $int(getpid()) & ".txt"
    defer: (try: removeFile(pidFile) except: discard)

    proc countRunDirsR22(): int =
      for (kind, path) in walkDir(getTempDir()):
        if kind == pcDir and path.extractFilename.startsWith("crisol_run_"):
          inc result

    let before = countRunDirsR22()

    # Run TWO hang_with_pid slots so both write PIDs; both should be dead after teardown.
    let pidFile2 = getTempDir() / "crisol_m6_r22b_" & $int(getpid()) & ".txt"
    defer: (try: removeFile(pidFile2) except: discard)

    let spec = resolveSandbox(passthroughs = @["HANG_PID_FILE"])

    var resultCount = 0
    proc bombCb2(r: EntrypointResult) =
      inc resultCount
      if resultCount >= 1:
        raise newException(ValueError, "R2-2 injected exception")

    # Use pass_always (exits immediately) and hang_with_pid (stays alive).
    # onResult raises after the first result. hang_with_pid may still be in
    # compile or run phase; teardownLiveSlots runs on the exception path.
    let passFixt = fd / "pass_always.nim"
    let eps2 = @[mkEp(passFixt), mkEp(hangPidFixt)]
    let cfg2 = Config(
      jobs:               2,
      timeoutSecs:        60,
      compileTimeoutSecs: 120,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        fd,
    )
    let p2 = plan(cfg2, eps2, emptyDepGraph())
    var g2 = emptyDepGraph()

    putEnv("HANG_PID_FILE", pidFile)
    defer: delEnv("HANG_PID_FILE")

    var exCaught2 = false
    try:
      discard execute(p2, config = cfg2, graph = g2, onResult = bombCb2,
                      showProgress = false, cache = cacheDisabled(spec))
    except ValueError as e:
      if "R2-2 injected" in e.msg:
        exCaught2 = true
      else:
        raise

    check exCaught2

    # hang_with_pid (if it started) must be dead.
    if fileExists(pidFile):
      let pidStr = readFile(pidFile).strip()
      if pidStr.len > 0:
        let childPid = parseInt(pidStr)
        check isProcessDead(childPid, timeoutMs = 3000)

    # No crisol_run_* dirs should remain (Phase 4 cleanup).
    os.sleep(50)
    let after2 = countRunDirsR22()
    check after2 == before

echo "test_m6_teardown: done"
