## test_r7_probe_presence_contract.nim — R7-S1 (round-7 review): the half of
## `toolrun.RunProc`'s contract that `ccidentity.ccIdentity` now rests on.
##
## `ccIdentity` tells an ABSENT candidate driver from one that was spawned and
## exited non-zero by whether it produced any output: `runViaOsproc` returns
## `""` on every path that did not run the command to completion (spawn
## failure -- "not on PATH" -- an OSError, a CR4 timeout), so non-empty output
## with `ok = false` can only come from a process that ran and exited
## non-zero. `RunProc` itself cannot say so (its `tuple[output, ok]` shape is
## destructured across `closure`/`artifactid`/`nimprobe`), so the property is
## pinned here, against the real primitive, on every platform:
##   * a command that does not exist        -> ("", false)
##   * a command that runs and exits 1      -> (non-empty, false)
##   * a command that runs and exits 0      -> (non-empty, true)
## If a future change made spawn failure return text (an error string, say),
## every absent Windows candidate would read as a present-and-failing driver
## and every host would refuse to publish; this file goes red first.
##
## The spawned command is the Nim compiler running this test
## (`getCurrentCompilerExe()`), which exists on every leg.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r7_probe_presence_contract.nim

import std/[os, strutils, unittest]
import crisol/toolrun

suite "toolrun.realRunMerged — output is non-empty only if the command ran":

  test "a command that is not on PATH: empty output, not ok":
    let (output, ok) = realRunMerged("crisol-r7-no-such-driver-xyzzy", [])
    check not ok
    check output == ""

  test "a command that ran and exited non-zero: its output, not ok":
    let (output, ok) = realRunMerged(getCurrentCompilerExe(),
                                     ["c", "--hints:off",
                                      "crisol_r7_no_such_source_xyzzy.nim"])
    checkpoint("output = " & output)
    check not ok
    check output.strip.len > 0

  test "CONTROL a command that ran and exited 0: its output, ok":
    let (output, ok) = realRunMerged(getCurrentCompilerExe(), ["--version"])
    check ok
    check "Nim Compiler" in output
