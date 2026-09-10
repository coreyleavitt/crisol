## test_windows_ioutils.nim — rfc-0007 D2a-4: windows ioutils backend (CRT
## int-fd API over CreateFileW) — live conformance.
##
## Drives the real `crisol/ioutils` public procs on the windows leg to prove
## the CRT/Win32 backend behaves like the posix one it stands in for:
##
##   1. exclusiveCreate exclusivity — a second exclusiveCreate on the same
##      path fails, with alreadyExists=true.
##   2. _O_BINARY (no CRLF translation) — THE critical case: a missing
##      _O_BINARY on the _open_osfhandle flags would silently corrupt every
##      ledger/JSON write via CRLF translation. Writes "a\nb" and asserts
##      the file is EXACTLY 3 bytes on read-back (a text-mode fd would have
##      written "a\r\nb" = 4 bytes).
##   3. appendOpen appends rather than truncates on a second open of the
##      same path.
##   4. noFollow refuses a reparse point (symlink) at the path — best
##      effort: windows symlink creation typically needs an elevated/
##      developer-mode privilege the CI runner may not have, so this case
##      is SKIPPED (logged, not failed) when creation itself fails.
##
## Compile-time gated to `defined(windows)` (mirrors the other
## `test_windows_*.nim` files): the `else` branch still compiles and exits
## cleanly on Linux/macOS, since crisol.nimble's self-discovering test task
## finds every `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[os, unittest]
  import crisol/ioutils

  suite "rfc-0007 D2a-4 — windows ioutils (CRT int-fd backend)":

    test "exclusiveCreate: second create on the same path fails, alreadyExists=true":
      let path = getTempDir() / "crisol_win_ioutils_exclusive.txt"
      (try: removeFile(path) except CatchableError: discard)
      defer: (try: removeFile(path) except CatchableError: discard)

      let (fd1, err1, exists1) = exclusiveCreate(path)
      check fd1 >= 0
      check err1.len == 0
      check not exists1
      closeFd(fd1)

      let (fd2, err2, exists2) = exclusiveCreate(path)
      check fd2 == -1
      check err2.len > 0
      check exists2

    test "_O_BINARY: writeAllFd through createOverwrite writes exactly 3 bytes (no CRLF translation)":
      let path = getTempDir() / "crisol_win_ioutils_binary.txt"
      defer: (try: removeFile(path) except CatchableError: discard)

      let (fd, err, _) = createOverwrite(path)
      check fd >= 0
      check err.len == 0
      check writeAllFd(fd, "a\nb")
      closeFd(fd)

      let raw = readFile(path)
      check raw.len == 3
      check raw == "a\nb"

    test "appendOpen: a second open appends rather than truncates":
      let path = getTempDir() / "crisol_win_ioutils_append.txt"
      (try: removeFile(path) except CatchableError: discard)
      defer: (try: removeFile(path) except CatchableError: discard)

      block:
        let (fd, err, _) = createOverwrite(path)
        check fd >= 0
        check err.len == 0
        check writeAllFd(fd, "X")
        closeFd(fd)

      block:
        let (fd, err) = appendOpen(path)
        check fd >= 0
        check err.len == 0
        check writeAllFd(fd, "Y")
        closeFd(fd)

      check readFile(path) == "XY"

    test "noFollow refuses a reparse point (best-effort; skipped if this runner can't create one)":
      let target = getTempDir() / "crisol_win_ioutils_nofollow_target.txt"
      let link   = getTempDir() / "crisol_win_ioutils_nofollow_link.txt"
      writeFile(target, "target content")
      (try: removeFile(link) except CatchableError: discard)
      defer:
        (try: removeFile(link) except CatchableError: discard)
        (try: removeFile(target) except CatchableError: discard)

      var linked = false
      try:
        createSymlink(target, link)
        linked = true
      except CatchableError as e:
        echo "test_windows_ioutils: skipping noFollow-reparse-point case — " &
             "could not create a symlink on this runner (" & e.msg & ")"

      if linked:
        let (fd, err, alreadyExists) = createOverwrite(link, noFollow = true)
        check fd == -1
        check err.len > 0
        check alreadyExists
        check readFile(target) == "target content"

  when isMainModule:
    echo "test_windows_ioutils done"

else:
  when isMainModule:
    echo "test_windows_ioutils: skipped (not windows)"
