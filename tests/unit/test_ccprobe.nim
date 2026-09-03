## test_ccprobe.nim — unit tests for ccprobe.nim (RFC-0004, A2-pre).
##
## All I/O is synthetic: tests inject a fake `run` seam that returns
## hard-coded strings, so no real `cc` or `ldd` process is spawned.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_ccprobe.nim

import std/[os, unittest, strutils]
import crisol/ccprobe

# ---------------------------------------------------------------------------
# Seam helpers
# ---------------------------------------------------------------------------

proc makeRun(ccOut: string, ccOk: bool,
             lddOut: string, lddOk: bool): RunProc =
  ## Returns a run proc that serves synthetic output keyed by command name.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cc":
      (output: ccOut, ok: ccOk)
    of "ldd":
      (output: lddOut, ok: lddOk)
    else:
      (output: "", ok: false)

# ---------------------------------------------------------------------------
# Suite 1: normal operation — both probes succeed
# ---------------------------------------------------------------------------

suite "ccVersion — both probes succeed":

  test "combines cc first line and ldd first line with '|' separator":
    let run = makeRun(
      "gcc (GCC) 13.2.0\nCopyright (C) ...",  true,
      "ldd (GNU libc) 2.38\nCopyright (C) ...", true)
    let v = ccVersion(run)
    check v == "gcc (GCC) 13.2.0|ldd (GNU libc) 2.38"

  test "takes only the FIRST line of multi-line compiler banner":
    let ccBanner = "cc (Ubuntu 12.3.0-1ubuntu1~22.04) 12.3.0\n" &
                   "Copyright (C) 2022 Free Software Foundation, Inc.\n" &
                   "This is free software; see the source for copying conditions."
    let lddBanner = "ldd (Ubuntu GLIBC 2.35-0ubuntu3.7) 2.35\n" &
                    "Copyright (C) 2022 Free Software Foundation, Inc."
    let run = makeRun(ccBanner, true, lddBanner, true)
    let v = ccVersion(run)
    check v == "cc (Ubuntu 12.3.0-1ubuntu1~22.04) 12.3.0|ldd (Ubuntu GLIBC 2.35-0ubuntu3.7) 2.35"

  test "trims trailing whitespace and newlines from each first line":
    let run = makeRun(
      "gcc (GCC) 13.2.0  \n",  true,
      "ldd (GNU libc) 2.38  \n", true)
    let v = ccVersion(run)
    check v == "gcc (GCC) 13.2.0|ldd (GNU libc) 2.38"
    check not v.endsWith(" ")
    check not v.endsWith("\n")

  test "trims leading whitespace from each first line":
    let run = makeRun(
      "  gcc (GCC) 13.2.0\n",  true,
      "  ldd (GNU libc) 2.38\n", true)
    let v = ccVersion(run)
    check v == "gcc (GCC) 13.2.0|ldd (GNU libc) 2.38"

# ---------------------------------------------------------------------------
# Suite 2: graceful degradation when probes fail
# ---------------------------------------------------------------------------

suite "ccVersion — probe failures yield sentinels":

  test "cc probe failure (ok=false) substitutes CcSentinel, ldd succeeds":
    let run = makeRun("", false, "ldd (GNU libc) 2.38", true)
    let v = ccVersion(run)
    check v == CcSentinel & "|ldd (GNU libc) 2.38"
    check v.len > 0

  test "ldd probe failure (non-glibc/missing, ok=false) substitutes LddSentinel, cc succeeds":
    let run = makeRun("gcc (GCC) 13.2.0", true, "", false)
    let v = ccVersion(run)
    check v == "gcc (GCC) 13.2.0|" & LddSentinel
    check v.len > 0

  test "both probes fail → both sentinels, still a stable non-empty string":
    let run = makeRun("", false, "", false)
    let v = ccVersion(run)
    check v == CcSentinel & "|" & LddSentinel
    check v.len > 0

  test "cc probe succeeds but returns empty output → CcSentinel substituted":
    let run = makeRun("", true, "ldd (GNU libc) 2.38", true)
    let v = ccVersion(run)
    check v == CcSentinel & "|ldd (GNU libc) 2.38"

  test "ldd probe succeeds but returns empty output → LddSentinel substituted":
    let run = makeRun("gcc (GCC) 13.2.0", true, "", true)
    let v = ccVersion(run)
    check v == "gcc (GCC) 13.2.0|" & LddSentinel

# ---------------------------------------------------------------------------
# Suite 3: determinism
# ---------------------------------------------------------------------------

suite "ccVersion — determinism":

  test "same inputs → identical output (pure function of injected output)":
    let run = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    let v1 = ccVersion(run)
    let v2 = ccVersion(run)
    check v1 == v2

  test "different cc version output → different fingerprint":
    let run1 = makeRun("gcc (GCC) 12.0.0", true, "ldd (GNU libc) 2.38", true)
    let run2 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    check ccVersion(run1) != ccVersion(run2)

  test "different ldd version output → different fingerprint":
    let run1 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.35", true)
    let run2 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    check ccVersion(run1) != ccVersion(run2)

  test "output with only whitespace/newline lines → sentinel substituted":
    ## A probe that returns only blank lines should be treated as empty output.
    let run = makeRun("   \n  \n", true, "ldd (GNU libc) 2.38", true)
    let v = ccVersion(run)
    check v == CcSentinel & "|ldd (GNU libc) 2.38"

# ---------------------------------------------------------------------------
# Suite 4: realRun — arg safety (no shell interpretation, M9 fix)
# ---------------------------------------------------------------------------
##
## Verifies that realRun does NOT pass args through a shell (i.e. does NOT use
## execCmdEx with join-on-space).  The discriminator: run
##   /bin/sh -c 'echo $#' -- "one two"
## With a correct execv-style call, sh receives exactly ONE positional parameter
## ("one two" as a single atom) and prints "1".
## With the old shell-join (execCmdEx), the shell command becomes:
##   /bin/sh -c echo $# -- one two
## which runs `echo` as the -c script and counts 4 positional params, printing "4".

suite "realRun — execv-style, no shell splitting":

  test "arg containing a space arrives as ONE argument, not split by shell":
    ## M9: realRun must use startProcess (no poEvalCommand), not execCmdEx.
    ## If realRun still uses execCmdEx (join-on-space), this test fails because
    ## sh would count 4 positional params instead of 1.
    let (output, ok) = realRun("/bin/sh", ["-c", "echo $#", "--", "one two"])
    check ok
    let trimmed = output.strip()
    check trimmed == "1"

  test "realRun returns ok=true for a command that exits 0":
    let (_, ok) = realRun("/bin/true", [])
    check ok

  test "realRun returns ok=false for a command that exits non-zero":
    let (_, ok) = realRun("/bin/false", [])
    check not ok

  test "realRun captures stdout output":
    let (output, ok) = realRun("/bin/echo", ["hello"])
    check ok
    check output.strip() == "hello"

# ---------------------------------------------------------------------------
# Suite 5: realRunIn — rfc-0007 A2c (issue #17): the returned RunProc always
# spawns its subprocess with the GIVEN workingDir, regardless of the calling
# process's own cwd.
# ---------------------------------------------------------------------------

suite "realRunIn — subprocess cwd is the given workingDir, not the caller's":

  test "the subprocess sees workingDir as its cwd even when the caller's cwd differs":
    let target = getTempDir() / "crisol_ccprobe_realrunin_target"
    createDir(target)
    defer: removeDir(target)

    let savedCwd = getCurrentDir()
    setCurrentDir(getTempDir())   # deliberately NOT `target`
    defer: setCurrentDir(savedCwd)

    let run = realRunIn(target)
    let (output, ok) = run("/bin/pwd", [])
    check ok
    check output.strip() == target.absolutePath.normalizedPath

  test "workingDir = \"\" behaves exactly like realRun (inherits the caller's cwd)":
    let run = realRunIn("")
    let (output, ok) = run("/bin/echo", ["hello"])
    check ok
    check output.strip() == "hello"

when isMainModule:
  echo "All ccprobe tests passed."
