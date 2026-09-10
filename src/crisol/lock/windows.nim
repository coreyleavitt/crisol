## lock/windows.nim — rfc-0007 D2a-2: advisory lock on `<stateDir>/lock` via
## LockFileEx, the Windows counterpart to lock/posix.nim's flock(2) backend.
##
## Same public interface and error contract as lock/posix.nim (LockHandle,
## acquireLock, releaseLock) — see that module's header for the overall
## lock-file protocol crisol uses it for. This file only covers the Win32
## mechanism.
##
## Mechanism:
##   - CreateFileW(OPEN_ALWAYS) opens (creating if absent) `<stateDir>/lock`.
##   - LockFileEx(LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY) locks
##     a byte range covering the whole file (offset 0, length 0xFFFFFFFF for
##     both the low and high halves) without blocking. Windows allows locking
##     beyond EOF, so this works even on the freshly created empty file.
##   - Byte-range locks are mandatory (not merely advisory like flock) and
##     per-handle: a second LockFileEx on the same range — even from the same
##     process, via a second CreateFileW handle — fails with
##     ERROR_LOCK_VIOLATION. That failure is this backend's contention signal,
##     the analog of posix's EAGAIN/EWOULDBLOCK from flock(LOCK_NB).
##   - The lock also releases automatically on process death: the OS closes
##     every open handle (and drops the locks they hold) when a process
##     exits, matching flock's OFD auto-release that
##     tests/integration/test_clean.nim pins on posix. releaseLock() drops it
##     explicitly (UnlockFileEx + CloseHandle) on the normal-exit path.
##
## LockHandle's zero value (Nim's default object init: hFile == 0) must mean
## "not held" so releaseLock is a safe no-op on a default-constructed handle
## (api.nim relies on this on some paths) — see releaseLock's guard below.

import std/os
import std/winlean
import crisol/types   # CrisolError, CrisolErrorKind, newCrisolError

type
  LockHandle* = object
    ## Opaque handle returned by acquireLock.
    ## Keep alive for the duration of the lock; close to release.
    hFile*: Handle   ## open file handle; 0 or INVALID_HANDLE_VALUE means not held

# ---------------------------------------------------------------------------
# Win32 surface missing from std/winlean: LockFileEx/UnlockFileEx. Hand-rolled
# ABI + importc, no `header` pragma — same no-header convention winlean.nim
# itself uses (and process/windows.nim follows), so `nim check --os:windows`
# resolves everything from Nim source alone, never a MinGW header path.
# ---------------------------------------------------------------------------

const
  LOCKFILE_EXCLUSIVE_LOCK = 0x2'i32
  LOCKFILE_FAIL_IMMEDIATELY = 0x1'i32
  ERROR_LOCK_VIOLATION = 33'i32

proc lockFileEx(hFile: Handle; dwFlags, dwReserved: int32;
                nNumberOfBytesToLockLow, nNumberOfBytesToLockHigh: int32;
                lpOverlapped: ptr OVERLAPPED): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "LockFileEx".}

proc unlockFileEx(hFile: Handle; dwReserved: int32;
                   nNumberOfBytesToUnlockLow, nNumberOfBytesToUnlockHigh: int32;
                   lpOverlapped: ptr OVERLAPPED): WINBOOL
  {.stdcall, dynlib: "kernel32", importc: "UnlockFileEx".}

proc acquireLock*(stateDir: string): LockHandle =
  ## Acquire an exclusive advisory write lock on `<stateDir>/lock`.
  ##
  ## Creates stateDir and the lock file if absent.
  ## Returns a LockHandle whose `hFile` is a valid, open handle on success.
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

  let h = createFileW(newWideCString(lockPath),
    GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
  if h == INVALID_HANDLE_VALUE:
    raise newCrisolError(cekEnvironment,
      "could not open lock file '" & lockPath & "'")

  var overlapped: OVERLAPPED
  let ok = lockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
    0, 0xFFFFFFFF'i32, 0xFFFFFFFF'i32, addr overlapped)
  if ok == 0:
    let e = getLastError()
    discard closeHandle(h)
    if e == ERROR_LOCK_VIOLATION:
      raise newCrisolError(cekEnvironment,
        "another crisol run is in progress for this project — " &
        "wait for it to finish or check for stale processes (exit 3)")
    else:
      raise newCrisolError(cekEnvironment,
        "LockFileEx failed on '" & lockPath & "': GetLastError=" & $e)

  result.hFile = h

proc releaseLock*(handle: var LockHandle) =
  ## Release the advisory lock by unlocking the byte range and closing the
  ## handle. Idempotent: sets handle.hFile = INVALID_HANDLE_VALUE after close
  ## so a double-release is a no-op. A default-constructed handle (hFile ==
  ## 0, Nim's zero value) is also a no-op — it was never opened.
  ## The lock also releases automatically on process death.
  if handle.hFile != 0 and handle.hFile != INVALID_HANDLE_VALUE:
    var overlapped: OVERLAPPED
    discard unlockFileEx(handle.hFile, 0, 0xFFFFFFFF'i32, 0xFFFFFFFF'i32, addr overlapped)
    discard closeHandle(handle.hFile)
    handle.hFile = INVALID_HANDLE_VALUE
