## test_ioutils.nim — unit tests for ioutils.writeAllFd
##
## TDD: written RED before the implementation exists.
##
## Coverage:
##   1. writeAllFd writes all bytes to a file fd and returns true.
##   2. writeAllFd on a closed/bad fd returns false (error path).
##   3. writeAllFd handles a zero-length string (no-op, returns true).
##   4. writeAllFd via a pipe: simulate the normal full-write path.

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

echo "test_ioutils: all blocks passed"
