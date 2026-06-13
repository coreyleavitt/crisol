## test_pgroup.nim — integration spike A2a
##
## Proves that killpg(pgid, SIGKILL) reaps a grandchild spawned by the child
## in the same process group.  No grandchild must survive as an orphan.
##
## Mechanism under test (from the RFC):
##   1. Parent fork()s child.
##   2. Child calls setpgid(0,0) → becomes leader of its own process group.
##   3. Child fork()s grandchild (inherits pgid; does NOT call setpgid again).
##   4. Grandchild writes its pid to a temp file, then sleeps 30 s, then would
##      write a SURVIVED marker (must never be reached if killed correctly).
##   5. Parent calls killpg(childPgid, SIGKILL).
##   6. Parent waitpid()s child.
##   7. Parent asserts grandchild is dead or zombie (not running).
##   8. Assert the SURVIVED marker was never written.
##
## Note on zombie reaping: after killpg, the grandchild's parent (the child)
## is already dead, so the grandchild is reparented to init.  init will reap
## it eventually, but until then the grandchild exists as a zombie.  A zombie
## IS dead — it has been killed and cannot execute any more code — but it still
## has a /proc entry.  kill(zombie, 0) returns 0 (not ESRCH), so ESRCH is NOT
## the right liveness probe here.  Instead we read /proc/<pid>/stat and check
## that the process is in state Z (zombie) or absent entirely.  The primary
## safety assertion is the absent SURVIVED marker file.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_pgroup.nim

import std/[os, strutils, unittest]
import std/posix

# ---------------------------------------------------------------------------
# Tiny POSIX helpers
# ---------------------------------------------------------------------------

proc writeIntToFile(path: string; val: int) =
  ## Write a decimal integer + newline to a file.
  ## Uses only low-level POSIX IO — acceptable in test Nim code throughout.
  let s = $val & "\n"
  let fd = open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
  if fd < 0: quit("open failed in child: " & path, 1)
  discard write(fd, cast[pointer](s.cstring), s.len)
  discard close(fd)

proc readIntFromFile(path: string): int =
  parseInt(readFile(path).strip())

proc pollForFile(path: string; timeoutMs: int): bool =
  ## Poll until the file appears, bounded by timeoutMs.
  let step = 10
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc grandchildDeadOrZombie(pid: Pid; timeoutMs: int): bool =
  ## Poll until the grandchild is either:
  ##   (a) gone from /proc (ESRCH — fully reaped by init), or
  ##   (b) a zombie (state 'Z' in /proc/<pid>/stat — killed but not yet
  ##       reaped by init, which is fine: a zombie executes no more code).
  ## Both states confirm the grandchild was killed.
  let step = 20
  var elapsed = 0
  let statPath = "/proc/" & $int(pid) & "/stat"
  while elapsed < timeoutMs:
    if not fileExists(statPath):
      return true  # fully gone
    # /proc/<pid>/stat: "pid (comm) state ..." — state is the 3rd field
    let content = readFile(statPath)
    # Find closing ')' of comm field, then state char follows
    let closeIdx = content.rfind(')')
    if closeIdx >= 0 and closeIdx + 2 < content.len:
      let state = content[closeIdx + 2]
      if state == 'Z':
        return true  # zombie — killed, not running
    os.sleep(step)
    elapsed += step
  false

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "process-group kill — grandchild reap":

  test "killpg reaps grandchild; grandchild never reaches SURVIVED marker":
    let tmpDir       = getTempDir()
    let gcPidFile    = tmpDir / "crisol_pgroup_gc_pid.txt"
    let survivedFile = tmpDir / "crisol_pgroup_survived.txt"

    if fileExists(gcPidFile):    removeFile(gcPidFile)
    if fileExists(survivedFile): removeFile(survivedFile)

    # -----------------------------------------------------------------------
    # fork() the child
    # -----------------------------------------------------------------------
    let childPid = fork()
    check childPid >= 0

    if childPid == 0:
      # =====================================================================
      # CHILD process
      # =====================================================================
      # Step 2: become leader of a new process group (pgid == our pid)
      if setpgid(Pid(0), Pid(0)) != 0:
        quit("setpgid failed in child", 1)

      # Step 3: fork the grandchild
      let gcPid = fork()
      if gcPid < 0:
        quit("fork grandchild failed", 1)

      if gcPid == 0:
        # ==================================================================
        # GRANDCHILD process
        # Inherits pgid from child (does NOT call setpgid).
        # ==================================================================
        writeIntToFile(gcPidFile, int(getpid()))

        # Long sleep — parent kills us before we finish.
        discard posix.sleep(cint(30))

        # Only reached if we were NOT killed:
        writeIntToFile(survivedFile, int(getpid()))
        quit(0)

      # Child sleeps while grandchild runs; both are in the same pgroup.
      discard posix.sleep(cint(30))
      quit(0)
      # =====================================================================

    # -----------------------------------------------------------------------
    # PARENT process
    # -----------------------------------------------------------------------
    # childPid == pgid (setpgid(0,0) makes pgid == pid)
    let childPgid = childPid

    # Wait for grandchild to announce its pid (up to 3 s)
    check pollForFile(gcPidFile, 3000)
    let grandchildPid = Pid(readIntFromFile(gcPidFile))
    check int(grandchildPid) > 0

    # Step 5: kill the entire process group — child AND grandchild
    check killpg(childPgid, SIGKILL) == 0

    # Step 6: reap the child (so it does not remain a zombie under us)
    var wstatus: cint = 0
    discard waitpid(childPid, wstatus, 0)

    # Step 7: grandchild is now reparented to init; wait for it to be dead
    # or zombie (up to 2 s).
    let killed = grandchildDeadOrZombie(grandchildPid, 2000)
    check killed

    # Step 8: the SURVIVED marker must never have been written
    # (a running-but-killed process cannot write a file)
    check not fileExists(survivedFile)

    # Cleanup
    if fileExists(gcPidFile):    removeFile(gcPidFile)
    if fileExists(survivedFile): removeFile(survivedFile)
