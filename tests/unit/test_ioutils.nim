## test_ioutils.nim — unit tests for ioutils.writeAllFd + ioutils.atomicPutFile
##
## TDD: written RED before the implementation exists.
##
## Coverage:
##   1. writeAllFd writes all bytes to a file fd and returns true.
##   2. writeAllFd on a closed/bad fd returns false (error path).
##   3. writeAllFd handles a zero-length string (no-op, returns true).
##   4. writeAllFd via a pipe: simulate the normal full-write path.
##   5. atomicPutFile writes content atomically and returns ok=true with an
##      empty error; content round-trips byte-for-byte; no writer-own
##      `.pid.tmp` remains.
##   6. atomicPutFile: a second put to the same finalPath replaces the content.
##   7. atomicPutFile: a pre-planted tmp file at OUR OWN pid-suffixed path is
##      best-effort removed first, then the put still succeeds (RFC-0006 R1).
##   8. atomicPutFile into a NONEXISTENT parent dir -> ok=false and a
##      non-empty error string naming the OS reason (RFC-0006 review R10).
##   9. atomicPutFile into an UNWRITABLE (mode 0o500) parent dir -> ok=false
##      and a non-empty error string containing the OS reason (permission
##      denied) (RFC-0006 review R10).

import std/[os, strutils]
import std/posix as posix_mod
import crisol/ioutils

# ---------------------------------------------------------------------------
# 1. writeAllFd: round-trip through a real file
# ---------------------------------------------------------------------------

block test_writeallfd_file_roundtrip:
  let path = getTempDir() / "crisol_ioutils_test_roundtrip.txt"
  defer: (try: removeFile(path) except CatchableError: discard)

  let flags = posix_mod.O_CREAT or posix_mod.O_WRONLY or posix_mod.O_TRUNC or
              posix_mod.O_CLOEXEC
  let fd = posix_mod.open(path.cstring, flags, posix_mod.Mode(0o600))
  assert fd >= 0, "failed to open temp file: " & $posix_mod.strerror(posix_mod.errno)

  let data = "hello, world — writeAllFd test payload\n"
  let ok = writeAllFd(fd, data)
  discard posix_mod.close(fd)

  assert ok, "writeAllFd must return true on success"
  let readBack = readFile(path)
  assert readBack == data, "round-trip mismatch: got " & readBack.repr

# ---------------------------------------------------------------------------
# 2. writeAllFd: bad fd returns false
# ---------------------------------------------------------------------------

block test_writeallfd_bad_fd:
  # fd = -1 is always invalid.
  let ok = writeAllFd(-1, "any data")
  assert not ok, "writeAllFd on fd=-1 must return false"

# ---------------------------------------------------------------------------
# 3. writeAllFd: zero-length data returns true (no-op)
# ---------------------------------------------------------------------------

block test_writeallfd_empty:
  let path = getTempDir() / "crisol_ioutils_test_empty.txt"
  defer: (try: removeFile(path) except CatchableError: discard)

  let flags = posix_mod.O_CREAT or posix_mod.O_WRONLY or posix_mod.O_TRUNC or
              posix_mod.O_CLOEXEC
  let fd = posix_mod.open(path.cstring, flags, posix_mod.Mode(0o600))
  assert fd >= 0, "failed to open temp file"

  let ok = writeAllFd(fd, "")
  discard posix_mod.close(fd)

  assert ok, "writeAllFd with empty data must return true"

# ---------------------------------------------------------------------------
# 4. writeAllFd: pipe — verifies the byte-level write path without O_APPEND
## semantics; also confirms EINTR path is exercised by the kernel implicitly
## (we cannot reliably inject EINTR in a unit test without signal trickery,
## but the partial-write loop handles it by contract — the loop itself is the
## unit under test via coverage of the n>0 branch).
# ---------------------------------------------------------------------------

block test_writeallfd_pipe:
  var pipeFds: array[2, cint]
  let rc = posix_mod.pipe(pipeFds)
  assert rc == 0, "pipe() failed"
  let rdFd = pipeFds[0]
  let wrFd = pipeFds[1]

  let payload = "pipe payload test"
  let ok = writeAllFd(wrFd, payload)
  discard posix_mod.close(wrFd)

  assert ok, "writeAllFd to pipe write-end must return true"

  # Read back from the read-end.
  var buf = newString(payload.len)
  let n = posix_mod.read(rdFd, buf.cstring, buf.len)
  discard posix_mod.close(rdFd)

  assert n == payload.len, "pipe read got " & $n & " bytes, expected " & $payload.len
  assert buf == payload, "pipe payload mismatch: " & buf.repr

# ---------------------------------------------------------------------------
# 5. atomicPutFile: writes atomically, returns (true, ""), round-trips, no
#    tmp left
# ---------------------------------------------------------------------------

block test_atomicputfile_roundtrip:
  let path = getTempDir() / "crisol_ioutils_test_atomicput.txt"
  defer: (try: removeFile(path) except CatchableError: discard)
  (try: removeFile(path) except CatchableError: discard)

  let data = "atomicPutFile payload — first write\n"
  let (ok, error) = atomicPutFile(path, data)
  assert ok, "atomicPutFile must return ok=true on success"
  assert error.len == 0, "atomicPutFile error must be empty on success, got: " & error
  assert fileExists(path), "final file must exist after atomicPutFile"
  assert readFile(path) == data, "round-trip mismatch"

  let myPidTmp = path & "." & $posix_mod.getpid() & ".tmp"
  assert not fileExists(myPidTmp), "writer-own .tmp must not exist after rename"

# ---------------------------------------------------------------------------
# 6. atomicPutFile: a second put replaces the content
# ---------------------------------------------------------------------------

block test_atomicputfile_replace:
  let path = getTempDir() / "crisol_ioutils_test_atomicput_replace.txt"
  defer: (try: removeFile(path) except CatchableError: discard)
  (try: removeFile(path) except CatchableError: discard)

  assert atomicPutFile(path, "version one").ok
  assert readFile(path) == "version one"

  assert atomicPutFile(path, "version two — longer than the first").ok
  assert readFile(path) == "version two — longer than the first",
    "second atomicPutFile must replace the first content"

# ---------------------------------------------------------------------------
# 7. atomicPutFile: a pre-planted OWN-pid tmp is best-effort removed first
# ---------------------------------------------------------------------------

block test_atomicputfile_preplanted_own_tmp:
  let path = getTempDir() / "crisol_ioutils_test_atomicput_preplanted.txt"
  let myPidTmp = path & "." & $posix_mod.getpid() & ".tmp"
  defer:
    (try: removeFile(path) except CatchableError: discard)
    (try: removeFile(myPidTmp) except CatchableError: discard)
  (try: removeFile(path) except CatchableError: discard)

  # Plant a leftover tmp under OUR OWN pid-suffixed name (as if a previous
  # attempt in this same process crashed mid-write before rename).
  writeFile(myPidTmp, "stale leftover from a previous attempt in this pid")

  let (ok, error) = atomicPutFile(path, "fresh content wins")
  assert ok, "atomicPutFile must succeed even with a pre-planted own-pid tmp"
  assert error.len == 0, "atomicPutFile error must be empty on success, got: " & error
  assert readFile(path) == "fresh content wins"
  assert not fileExists(myPidTmp), "the pid-tmp must not survive a successful put"

# ---------------------------------------------------------------------------
# 8. atomicPutFile into a NONEXISTENT parent dir -> ok=false, non-empty
#    error naming the OS reason (RFC-0006 review R10 — the underlying OSError
#    must no longer be swallowed).
# ---------------------------------------------------------------------------

block test_atomicputfile_nonexistent_dir_reports_error:
  let missingDir = getTempDir() / "crisol_ioutils_test_no_such_dir_xyz"
  (try: removeDir(missingDir) except CatchableError: discard)
  let path = missingDir / "target.txt"

  let (ok, error) = atomicPutFile(path, "should never land")
  assert not ok, "atomicPutFile into a nonexistent dir must return ok=false"
  assert error.len > 0,
    "atomicPutFile must report a NON-EMPTY error naming the OS reason, got empty string"
  assert not fileExists(path), "no file may be created on a create-temp-file failure"

# ---------------------------------------------------------------------------
# 9. atomicPutFile into an UNWRITABLE parent dir -> ok=false, non-empty error
#    string containing the OS reason (permission denied) (RFC-0006 review
#    R10). Skipped when running as root — root bypasses permission bits, so
#    this specific failure mode cannot be exercised as root.
# ---------------------------------------------------------------------------

block test_atomicputfile_unwritable_dir_reports_error:
  if posix_mod.geteuid() == 0:
    echo "test_ioutils: skipping unwritable-dir case (running as root)"
  else:
    let roDir = getTempDir() / "crisol_ioutils_test_readonly_dir"
    (try: removeDir(roDir) except CatchableError: discard)
    createDir(roDir)
    setFilePermissions(roDir, {fpUserRead, fpUserExec})
    defer:
      setFilePermissions(roDir, {fpUserRead, fpUserWrite, fpUserExec})
      (try: removeDir(roDir) except CatchableError: discard)
    let path = roDir / "target.txt"

    let (ok, error) = atomicPutFile(path, "should never land")
    assert not ok, "atomicPutFile into an unwritable dir must return ok=false"
    assert error.len > 0,
      "atomicPutFile must report a NON-EMPTY error naming the OS reason, got empty string"
    assert not fileExists(path), "no file may be created on a create-temp-file failure"

echo "test_ioutils: all blocks passed"
