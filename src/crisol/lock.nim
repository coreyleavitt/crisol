## lock.nim — C4/rfc-0007 A4: advisory lock on `.crisol/lock` via flock(2).
##
## Each crisol `run` or `clean` invocation acquires an exclusive lock on
## `.crisol/lock` before doing any state-mutating work (compiling, pruning).
## Read-only commands (`list`, `--dry-run`) do NOT acquire the lock.
##
## Lock mechanism:
##   - open(lockFile, O_CREAT|O_RDWR, 0o644)
##   - flock(fd, LOCK_EX or LOCK_NB)  — non-blocking exclusive lock.
##   - LOCK_NB makes flock non-blocking: returns -1 with errno = EWOULDBLOCK
##     (== EAGAIN on Linux) if another process holds the lock.
##   - Lock releases automatically on process death (kernel drops all
##     open-file-description locks when the last fd referencing that
##     description closes, which process exit always does).
##   - releaseLock() closes the fd explicitly on normal exit.
##
## Why flock(2), not fcntl(2) F_SETLK (RFC-0007 §7):
##   fcntl POSIX record locks are associated with the pair (process, inode):
##   closing ANY file descriptor this process holds open on the locked file
##   — even one opened for a completely unrelated purpose, and even while
##   the "real" locking fd stays open — silently drops every lock the
##   process holds on that inode. That is a live footgun the moment any
##   other code in the same binary opens the lock path for any reason
##   (stat, read, a future diagnostic dump, ...).
##
##   flock(2) locks are associated with the OPEN FILE DESCRIPTION instead:
##   only closing the SAME fd (or its dup()s) releases the lock an
##   unrelated open+close of the same path is inert. `flock` is not
##   declared in Nim's std/posix (the reason RFC-0001 picked F_SETLK
##   originally), so it is importc'd directly here — a one-line binding,
##   the same pattern posixcore.nim uses for the RLIMIT_* constants.
##
## tests/integration/test_clean.nim's "crisol advisory lock" suite pins
## exclusion (contention → cekEnvironment, exit 3) and auto-release on
## process death; its "close-any-fd hazard" test is the regression that
## fails under fcntl and passes under flock.

import std/os
import std/posix
import crisol/types   # CrisolError, CrisolErrorKind, newCrisolError

type
  LockHandle* = object
    ## Opaque handle returned by acquireLock.
    ## Keep alive for the duration of the lock; close to release.
    fd*: cint   ## open file descriptor; -1 means not held

# flock(2) is BSD/Linux, not POSIX, and absent from std/posix — importc it
# directly, same pattern as posixcore.nim's RLIMIT_* constants. Values are
# stable across glibc/musl/macOS (bsd/sys/file.h origin).
proc c_flock(fd: cint; operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}
var LOCK_EX {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
var LOCK_NB {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint

proc acquireLock*(stateDir: string): LockHandle =
  ## Acquire an exclusive advisory write lock on `<stateDir>/lock`.
  ##
  ## Creates stateDir and the lock file if absent.
  ## Returns a LockHandle whose `fd >= 0` on success.
  ##
  ## Raises CrisolError(cekEnvironment) on contention (another process holds the
  ## lock) — the CLI maps this to exit 3 with the message:
  ##   "another crisol run is in progress for this project"
  ##
  ## Raises CrisolError(cekEnvironment) on any OS error.

  # Ensure the state directory exists.
  try:
    createDir(stateDir)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "could not create state dir '" & stateDir & "': " & e.msg)

  let lockPath = stateDir / "lock"

  # O_CREAT | O_RDWR | O_CLOEXEC
  let flags = O_CREAT or O_RDWR or O_CLOEXEC
  let fd = posix.open(lockPath.cstring, flags, Mode(0o644))
  if fd < 0:
    raise newCrisolError(cekEnvironment,
      "could not open lock file '" & lockPath & "'")

  let rc = c_flock(fd, LOCK_EX or LOCK_NB)
  if rc < 0:
    let e = errno
    discard posix.close(fd)
    if e == EAGAIN:   # EWOULDBLOCK == EAGAIN on Linux
      raise newCrisolError(cekEnvironment,
        "another crisol run is in progress for this project — " &
        "wait for it to finish or check for stale processes (exit 3)")
    else:
      raise newCrisolError(cekEnvironment,
        "flock LOCK_EX failed on '" & lockPath & "': errno " & $e)

  result = LockHandle(fd: fd)

proc releaseLock*(handle: var LockHandle) =
  ## Release the advisory lock by closing the fd.
  ## Idempotent: sets handle.fd = -1 after close so a double-release is a no-op.
  ## The lock also releases automatically on process death.
  if handle.fd >= 0:
    discard posix.close(handle.fd)
    handle.fd = -1
