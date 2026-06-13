## lock.nim — C4: advisory lock on `.crisol/lock` via fcntl(F_SETLK).
##
## Each crisol `run` or `clean` invocation acquires an exclusive write lock on
## `.crisol/lock` before doing any state-mutating work (compiling, pruning).
## Read-only commands (`list`, `--dry-run`) do NOT acquire the lock.
##
## Lock mechanism:
##   - open(lockFile, O_CREAT|O_RDWR, 0o644)
##   - fcntl(fd, F_SETLK, addr fl)  where fl.l_type = F_WRLCK, l_len = 0 (whole file)
##   - F_SETLK is non-blocking: returns -1 with errno = EACCES or EAGAIN if held.
##   - Lock releases automatically on process death (kernel drops all file locks).
##   - releaseLock() closes the fd explicitly on normal exit.
##
## Rationale for F_SETLK over flock(2):
##   - `flock` is not in Nim's std/posix.
##   - `fcntl F_SETLK` IS present and is the correct POSIX advisory lock.
##   - F_SETLK (non-blocking) → immediate contention detection → exit 3.

import std/os
import std/posix
import crisol/types   # CrisolError, CrisolErrorKind, newCrisolError

type
  LockHandle* = object
    ## Opaque handle returned by acquireLock.
    ## Keep alive for the duration of the lock; close to release.
    fd*: cint   ## open file descriptor; -1 means not held

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

  var fl: Tflock
  fl.l_type   = cshort(F_WRLCK)
  fl.l_whence = cshort(SEEK_SET)
  fl.l_start  = 0
  fl.l_len    = 0   # 0 = whole file

  let rc = fcntl(fd, F_SETLK, addr fl)
  if rc < 0:
    let e = errno
    discard posix.close(fd)
    if e == EACCES or e == EAGAIN:
      raise newCrisolError(cekEnvironment,
        "another crisol run is in progress for this project — " &
        "wait for it to finish or check for stale processes (exit 3)")
    else:
      raise newCrisolError(cekEnvironment,
        "fcntl F_SETLK failed on '" & lockPath & "': errno " & $e)

  result = LockHandle(fd: fd)

proc releaseLock*(handle: LockHandle) =
  ## Release the advisory lock by closing the fd.
  ## Safe to call more than once (subsequent calls are no-ops).
  ## The lock also releases automatically on process death.
  if handle.fd >= 0:
    discard posix.close(handle.fd)
