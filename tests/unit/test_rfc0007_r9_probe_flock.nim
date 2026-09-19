## test_rfc0007_r9_probe_flock.nim — rfc-0007 code-review finding r9:
## `probeFlock` (process/posixcore.nim) opened a FULLY PREDICTABLE path —
## `getTempDir() / "crisol-flock-probe-<pid>"` — with Nim's plain
## `open(path, fmWrite)` (`O_CREAT|O_TRUNC`, no `O_EXCL`/`O_NOFOLLOW`). A
## local attacker in shared `/tmp` could pre-plant ANYTHING at that exact
## name (a regular file, or — where `fs.protected_symlinks` is off, e.g.
## macOS or a hardened-off Linux — a symlink to a victim file) and have it
## silently FOLLOWED and TRUNCATED as the crisol user the moment
## `capabilities()` first probed `flock`.
##
## The fix routes the probe through `ioutils.exclusiveCreate`
## (`O_CREAT|O_EXCL|O_NOFOLLOW`) at an UNPREDICTABLE, randomly-suffixed
## name, so nothing is ever opened at the old fixed path at all.
##
## This test is a genuine RED against the pre-fix code: it pre-creates a
## plain regular file at the OLD fixed predictable path with known
## content, triggers the real probe (via `capabilities()`, memoised once
## per process — this is this process's first and only call), and asserts
## BOTH that the probe still reports `flock: true` (the fix does not
## regress the capability itself) AND that the pre-planted file's content
## survived completely untouched. Pre-fix, the second assertion fails: the
## old `open(path, fmWrite)` truncates the file to empty the instant
## `probeFlock` runs.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r9_probe_flock.nim

when defined(posix):
  import std/[os, posix, unittest]
  import crisol/process

  suite "rfc-0007 r9 — probeFlock never touches the old fixed predictable path":

    test "capabilities().flock still true, AND a file at the OLD fixed path survives untouched":
      let oldFixedPath = getTempDir() / ("crisol-flock-probe-" & $getpid())
      let sentinel = "rfc-0007-r9-sentinel-must-survive-untouched"
      writeFile(oldFixedPath, sentinel)
      defer:
        try: removeFile(oldFixedPath)
        except CatchableError: discard

      # This process's first (and only — memoised) capabilities() call:
      # triggers the real probeFlock.
      let caps = capabilities()
      check caps.flock == true

      # THE regression assertion: pre-fix, probeFlock opened exactly this
      # path with O_CREAT|O_TRUNC (Nim's `open(path, fmWrite)`), silently
      # truncating whatever content was already there — a genuine RED
      # against the old code. Post-fix, probeFlock never opens this path
      # at all (it uses an unpredictable, random-suffixed name instead),
      # so the sentinel content must be byte-for-byte unchanged.
      check readFile(oldFixedPath) == sentinel

  when isMainModule:
    echo "test_rfc0007_r9_probe_flock: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r9_probe_flock.nim"
    echo "test_rfc0007_r9_probe_flock: skipped (POSIX-only backend test)"
