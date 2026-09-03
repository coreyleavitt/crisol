## test_ioutils.nim — unit tests for ioutils.writeAllFd + ioutils.atomicPublish
##
## TDD: written RED before the implementation exists.
##
## Coverage:
##   1. writeAllFd writes all bytes to a file fd and returns true.
##   2. writeAllFd on a closed/bad fd returns false (error path).
##   3. writeAllFd handles a zero-length string (no-op, returns true).
##   4. writeAllFd via a pipe: simulate the normal full-write path.
##   5. atomicPublish writes content atomically and returns ok=true with an
##      empty error; content round-trips byte-for-byte; no writer-own
##      `.pid.tmp` remains.
##   6. atomicPublish: a second put to the same finalPath replaces the content.
##   7. atomicPublish: a pre-planted tmp file at OUR OWN pid-suffixed path is
##      best-effort removed first, then the put still succeeds (RFC-0006 R1).
##   8. atomicPublish into a NONEXISTENT parent dir -> ok=false and a
##      non-empty error string naming the OS reason (RFC-0006 review R10).
##   9. atomicPublish into an UNWRITABLE (mode 0o500) parent dir -> ok=false
##      and a non-empty error string containing the OS reason (permission
##      denied) (RFC-0006 review R10).
##  10. sanitizeControlBytes: ESC/TAB/DEL -> '?'; '\n' preserved; UTF-8
##      multibyte text (C1-adjacent continuation bytes) unchanged.
##  11. sanitizeControlBytes: the UTF-8 ENCODING of a C1 control (0xC2 followed
##      by 0x80-0x9F) collapses to a single '?'; a bare 0xC2 lead byte NOT
##      followed by a C1-range continuation byte (e.g. U+00A0 NBSP, or a lone
##      trailing 0xC2) is left untouched.

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
# 5. atomicPublish: writes atomically, returns (true, ""), round-trips, no
#    tmp left
# ---------------------------------------------------------------------------

block test_atomicputfile_roundtrip:
  let path = getTempDir() / "crisol_ioutils_test_atomicput.txt"
  defer: (try: removeFile(path) except CatchableError: discard)
  (try: removeFile(path) except CatchableError: discard)

  let data = "atomicPublish payload — first write\n"
  let (ok, error) = atomicPublish(path, data)
  assert ok, "atomicPublish must return ok=true on success"
  assert error.len == 0, "atomicPublish error must be empty on success, got: " & error
  assert fileExists(path), "final file must exist after atomicPublish"
  assert readFile(path) == data, "round-trip mismatch"

  let myPidTmp = path & "." & $posix_mod.getpid() & ".tmp"
  assert not fileExists(myPidTmp), "writer-own .tmp must not exist after rename"

# ---------------------------------------------------------------------------
# 6. atomicPublish: a second put replaces the content
# ---------------------------------------------------------------------------

block test_atomicputfile_replace:
  let path = getTempDir() / "crisol_ioutils_test_atomicput_replace.txt"
  defer: (try: removeFile(path) except CatchableError: discard)
  (try: removeFile(path) except CatchableError: discard)

  assert atomicPublish(path, "version one").ok
  assert readFile(path) == "version one"

  assert atomicPublish(path, "version two — longer than the first").ok
  assert readFile(path) == "version two — longer than the first",
    "second atomicPublish must replace the first content"

# ---------------------------------------------------------------------------
# 7. atomicPublish: a pre-planted OWN-pid tmp is best-effort removed first
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

  let (ok, error) = atomicPublish(path, "fresh content wins")
  assert ok, "atomicPublish must succeed even with a pre-planted own-pid tmp"
  assert error.len == 0, "atomicPublish error must be empty on success, got: " & error
  assert readFile(path) == "fresh content wins"
  assert not fileExists(myPidTmp), "the pid-tmp must not survive a successful put"

# ---------------------------------------------------------------------------
# 8. atomicPublish into a NONEXISTENT parent dir -> ok=false, non-empty
#    error naming the OS reason (RFC-0006 review R10 — the underlying OSError
#    must no longer be swallowed).
# ---------------------------------------------------------------------------

block test_atomicputfile_nonexistent_dir_reports_error:
  let missingDir = getTempDir() / "crisol_ioutils_test_no_such_dir_xyz"
  (try: removeDir(missingDir) except CatchableError: discard)
  let path = missingDir / "target.txt"

  let (ok, error) = atomicPublish(path, "should never land")
  assert not ok, "atomicPublish into a nonexistent dir must return ok=false"
  assert error.len > 0,
    "atomicPublish must report a NON-EMPTY error naming the OS reason, got empty string"
  assert not fileExists(path), "no file may be created on a create-temp-file failure"

# ---------------------------------------------------------------------------
# 9. atomicPublish into an UNWRITABLE parent dir -> ok=false, non-empty error
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

    let (ok, error) = atomicPublish(path, "should never land")
    assert not ok, "atomicPublish into an unwritable dir must return ok=false"
    assert error.len > 0,
      "atomicPublish must report a NON-EMPTY error naming the OS reason, got empty string"
    assert not fileExists(path), "no file may be created on a create-temp-file failure"

# ---------------------------------------------------------------------------
# 10. sanitizeControlBytes: control/ANSI injection guard for untrusted-origin
#     text — see crisol/ioutils.nim's doc comment for the threat model.
# ---------------------------------------------------------------------------

block test_sanitizecontrolbytes_esc_replaced:
  let s = "\e[31mred\e[0m"
  assert sanitizeControlBytes(s) == "?[31mred?[0m",
    "ESC (0x1b) must be replaced with '?'"

block test_sanitizecontrolbytes_tab_replaced:
  assert sanitizeControlBytes("a\tb") == "a?b", "TAB (0x09) must be replaced with '?'"

block test_sanitizecontrolbytes_del_replaced:
  assert sanitizeControlBytes("a\x7fb") == "a?b", "DEL (0x7f) must be replaced with '?'"

block test_sanitizecontrolbytes_newline_preserved:
  let s = "line one\nline two\n"
  assert sanitizeControlBytes(s) == s, "'\\n' must be preserved unchanged"

block test_sanitizecontrolbytes_mixed_multiline:
  # A multi-line, caret-block-shaped message (like nkdl's formatError output)
  # with a control byte embedded in one line: line structure survives, only
  # the control byte on that line is replaced.
  let s = "error: bad token\n  --> file.kdl:2:5\n2 | \tglobs \"x\"\n  |  ^\n"
  let want = "error: bad token\n  --> file.kdl:2:5\n2 | ?globs \"x\"\n  |  ^\n"
  assert sanitizeControlBytes(s) == want,
    "multi-line text must sanitize each line's control bytes while keeping '\\n' boundaries"

block test_sanitizecontrolbytes_plain_text_unchanged:
  let s = "unknown config key 'foo' in unit (ignored)"
  assert sanitizeControlBytes(s) == s, "plain text with no control bytes must be unchanged"

block test_sanitizecontrolbytes_utf8_multibyte_unchanged:
  # UTF-8 multibyte text (e.g. non-ASCII test names/paths) must survive
  # untouched — the C1 range (0x80-0x9f) is deliberately not treated as a
  # control range because those bytes are ordinary UTF-8 continuation bytes.
  let s = "caf\xc3\xa9 — \xe6\xb5\x8b\xe8\xaf\x95"   # "café — 测试"
  assert sanitizeControlBytes(s) == s, "UTF-8 multibyte text must be unchanged"

# ---------------------------------------------------------------------------
# 11. sanitizeControlBytes: the UTF-8 ENCODING of a C1 control (0xC2 0x80-0x9F)
#     is a live ANSI-injection vector (xterm in UTF-8 mode decodes 0xC2 0x9B
#     to U+009B = CSI) and must be neutralized; a bare 0xC2 lead byte NOT
#     forming that 2-byte sequence is an ordinary UTF-8 continuation and must
#     survive untouched.
# ---------------------------------------------------------------------------

block test_sanitizecontrolbytes_utf8_encoded_c1_replaced:
  # 0xC2 0x9B is the UTF-8 encoding of U+009B (CSI) — nkdl's `\u{9b}` string
  # escape can carry this through a config group name.
  assert sanitizeControlBytes("a\xc2\x9bb") == "a?b",
    "UTF-8-encoded C1 control (0xC2 0x9B) must collapse to a single '?'"

block test_sanitizecontrolbytes_utf8_non_c2_lead_unchanged:
  # 0xC3 0xA9 is "é" (U+00E9) — not a C1-control encoding; must be untouched.
  let s = "caf\xc3\xa9"
  assert sanitizeControlBytes(s) == s,
    "a non-0xC2 UTF-8 lead byte must be left alone"

block test_sanitizecontrolbytes_utf8_c2_non_c1_unchanged:
  # 0xC2 0xA0 is U+00A0 (NBSP) — 0xA0 is outside the 0x80-0x9F C1 range, so
  # this 0xC2-led sequence must be left alone.
  let s = "\xc2\xa0"
  assert sanitizeControlBytes(s) == s,
    "0xC2 followed by a non-C1-range byte (e.g. NBSP) must be left alone"

block test_sanitizecontrolbytes_lone_trailing_c2_unchanged:
  # A lone 0xC2 with nothing after it (truncated/malformed UTF-8) must not
  # be touched — there is no following byte to form the 2-byte sequence.
  let s = "trailing\xc2"
  assert sanitizeControlBytes(s) == s,
    "a lone trailing 0xC2 byte must be left alone"

# ---------------------------------------------------------------------------
# 12. exclusiveCreate: fresh path succeeds; a path that already exists fails
#     with alreadyExists=true (RFC-0007 A3).
# ---------------------------------------------------------------------------

block test_exclusivecreate_fresh_path_succeeds:
  let path = getTempDir() / "crisol_ioutils_test_exclusivecreate.txt"
  (try: removeFile(path) except CatchableError: discard)
  defer: (try: removeFile(path) except CatchableError: discard)

  let (fd, error, alreadyExists) = exclusiveCreate(path)
  assert fd >= 0, "exclusiveCreate on a fresh path must return fd >= 0, error: " & error
  assert error.len == 0
  assert not alreadyExists
  assert writeAllFd(fd, "payload")
  closeFd(fd)
  assert readFile(path) == "payload"

block test_exclusivecreate_existing_path_reports_alreadyexists:
  let path = getTempDir() / "crisol_ioutils_test_exclusivecreate_exists.txt"
  writeFile(path, "pre-existing")
  defer: (try: removeFile(path) except CatchableError: discard)

  let (fd, error, alreadyExists) = exclusiveCreate(path)
  assert fd < 0, "exclusiveCreate on an existing path must fail"
  assert error.len > 0, "exclusiveCreate must report a non-empty OS reason"
  assert alreadyExists, "exclusiveCreate on an existing path must set alreadyExists=true"
  assert readFile(path) == "pre-existing", "existing content must survive a failed exclusiveCreate"

# ---------------------------------------------------------------------------
# 13. createOverwrite: fresh path succeeds; an existing regular file is
#     truncated and replaced (RFC-0007 A3).
# ---------------------------------------------------------------------------

block test_createoverwrite_replaces_existing_content:
  let path = getTempDir() / "crisol_ioutils_test_createoverwrite.txt"
  writeFile(path, "old content — long enough to prove truncation happened")
  defer: (try: removeFile(path) except CatchableError: discard)

  let (fd, error, alreadyExists) = createOverwrite(path)
  assert fd >= 0, "createOverwrite on an existing regular file must succeed, error: " & error
  assert error.len == 0
  assert not alreadyExists
  assert writeAllFd(fd, "new")
  closeFd(fd)
  assert readFile(path) == "new", "createOverwrite must truncate the prior content"

block test_createoverwrite_nofollow_refuses_symlink:
  let target = getTempDir() / "crisol_ioutils_test_createoverwrite_target.txt"
  let link   = getTempDir() / "crisol_ioutils_test_createoverwrite_link.txt"
  writeFile(target, "target content")
  (try: removeFile(link) except CatchableError: discard)
  createSymlink(target, link)
  defer:
    (try: removeFile(link) except CatchableError: discard)
    (try: removeFile(target) except CatchableError: discard)

  let (fd, error, alreadyExists) = createOverwrite(link, noFollow = true)
  assert fd < 0, "createOverwrite(noFollow=true) must refuse to follow a symlink"
  assert error.len > 0
  assert alreadyExists, "a refused symlink must report alreadyExists=true"
  assert readFile(target) == "target content", "the symlink target must be untouched"

# ---------------------------------------------------------------------------
# 14. appendOpen: creates on first open, appends on a second open of the
#     same path (RFC-0007 A3 — the ledger/shardedledger shard-open primitive).
# ---------------------------------------------------------------------------

block test_appendopen_creates_then_appends:
  let path = getTempDir() / "crisol_ioutils_test_appendopen.txt"
  (try: removeFile(path) except CatchableError: discard)
  defer: (try: removeFile(path) except CatchableError: discard)

  block:
    let (fd, error) = appendOpen(path)
    assert fd >= 0, "appendOpen must create a missing path, error: " & error
    assert writeAllFd(fd, "first\n")
    closeFd(fd)

  block:
    let (fd, error) = appendOpen(path)
    assert fd >= 0, "appendOpen on an existing path must succeed, error: " & error
    assert writeAllFd(fd, "second\n")
    closeFd(fd)

  assert readFile(path) == "first\nsecond\n",
    "a second appendOpen must append, not truncate"

# ---------------------------------------------------------------------------
# 15. readRandomBytes: returns exactly the requested count from a real
#     /dev/urandom (RFC-0007 A3 — the ledger/shardedledger boot-id fallback
#     primitive); zero is a no-op.
# ---------------------------------------------------------------------------

block test_readrandombytes_returns_requested_count:
  let bytes = readRandomBytes(8)
  assert bytes.len == 8, "readRandomBytes(8) on a normal host must return 8 bytes"

block test_readrandombytes_zero_is_empty:
  let bytes = readRandomBytes(0)
  assert bytes.len == 0, "readRandomBytes(0) must return an empty seq"

block test_readrandombytes_two_calls_differ:
  # Not a statistical randomness test — just confirms this isn't reading a
  # fixed/zeroed buffer.
  let a = readRandomBytes(16)
  let b = readRandomBytes(16)
  assert a != b, "two independent readRandomBytes(16) calls must not collide"

# ---------------------------------------------------------------------------
# 16. writeGuardedFile: crisol.nim init's writer primitive (RFC-0007 A3) —
#     exclusive-create by default, overwrite opt-in, symlink always refused.
# ---------------------------------------------------------------------------

block test_writeguardedfile_fresh_path_succeeds:
  let path = getTempDir() / "crisol_ioutils_test_writeguarded.txt"
  (try: removeFile(path) except CatchableError: discard)
  defer: (try: removeFile(path) except CatchableError: discard)

  let (ok, error, alreadyExists) =
    writeGuardedFile(path, "template content\n", 0o644, overwrite = false)
  assert ok, "writeGuardedFile on a fresh path must succeed, error: " & error
  assert error.len == 0
  assert not alreadyExists
  assert readFile(path) == "template content\n"
  assert (getFilePermissions(path) * {fpUserRead, fpUserWrite}) ==
         {fpUserRead, fpUserWrite}, "mode 0o644 must include owner rw"

block test_writeguardedfile_existing_path_without_force_fails:
  let path = getTempDir() / "crisol_ioutils_test_writeguarded_exists.txt"
  writeFile(path, "already here")
  defer: (try: removeFile(path) except CatchableError: discard)

  let (ok, error, alreadyExists) =
    writeGuardedFile(path, "new content", 0o644, overwrite = false)
  assert not ok, "writeGuardedFile without overwrite must refuse an existing path"
  assert error.len > 0
  assert alreadyExists
  assert readFile(path) == "already here", "existing content must survive"

block test_writeguardedfile_overwrite_true_replaces_content:
  let path = getTempDir() / "crisol_ioutils_test_writeguarded_force.txt"
  writeFile(path, "stale template")
  defer: (try: removeFile(path) except CatchableError: discard)

  let (ok, error, alreadyExists) =
    writeGuardedFile(path, "fresh template", 0o644, overwrite = true)
  assert ok, "writeGuardedFile(overwrite=true) must replace an existing file, error: " & error
  assert not alreadyExists
  assert readFile(path) == "fresh template"

block test_writeguardedfile_overwrite_true_still_refuses_symlink:
  let target = getTempDir() / "crisol_ioutils_test_writeguarded_target.txt"
  let link   = getTempDir() / "crisol_ioutils_test_writeguarded_link.txt"
  writeFile(target, "target content")
  (try: removeFile(link) except CatchableError: discard)
  createSymlink(target, link)
  defer:
    (try: removeFile(link) except CatchableError: discard)
    (try: removeFile(target) except CatchableError: discard)

  let (ok, error, alreadyExists) =
    writeGuardedFile(link, "should not land", 0o644, overwrite = true)
  assert not ok, "writeGuardedFile must refuse a symlink even with overwrite=true"
  assert error.len > 0
  assert alreadyExists
  assert readFile(target) == "target content", "the symlink target must be untouched"

echo "test_ioutils: all blocks passed"
