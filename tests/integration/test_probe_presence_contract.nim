## test_probe_presence_contract.nim — R7-S1 (round-7 review): the half of
## `toolrun.RunProc`'s contract that `ccidentity.ccIdentity` rests on.
##
## `ccIdentity` tells an ABSENT candidate driver from one that was spawned and
## failed by the run's ending: `reNotStarted` only when nothing was spawned.
## Pinned here against the real runner, on every platform:
##   * a command that does not exist    -> reNotStarted
##   * a command that runs and exits 1  -> reExited, non-zero exit, its output
##   * a command that runs and exits 0  -> reExited, exit 0, its output
## If a spawn failure were ever reported as a run, every absent Windows
## candidate would read as a present-and-failing driver and every host would
## refuse to publish; this file goes red first.
##
## The spawned command is the Nim compiler running this test
## (`getCurrentCompilerExe()`), which exists on every leg.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_probe_presence_contract.nim

import std/[os, strutils, unittest]
import crisol/toolrun

suite "toolrun.realRunMerged — reNotStarted only if nothing was spawned":

  test "a command that is not on PATH: not started":
    let r = realRunMerged("crisol-r7-no-such-driver-xyzzy", [])
    check r.ending == reNotStarted
    check not r.ok

  test "a command that ran and exited non-zero: ran, its exit code and output":
    let r = realRunMerged(getCurrentCompilerExe(),
                          ["c", "--hints:off", "crisol_r7_no_such_source_xyzzy.nim"])
    check r.ending == reExited
    if r.ending == reExited:
      checkpoint("output = " & r.output)
      check r.exitCode != 0
      check r.output.strip.len > 0
    check not r.ok

  test "CONTROL a command that ran and exited 0: ran, its output, ok":
    let r = realRunMerged(getCurrentCompilerExe(), ["--version"])
    check r.ok
    if r.ending == reExited:
      check "Nim Compiler" in r.output
