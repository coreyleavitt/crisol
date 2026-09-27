## test_toolrun_endings.nim — R10-L4/D2 (round-10 review): the
## `toolrun.RunProc` layer's real runners never report a run that did not
## finish as one that did, and feed stdin when asked.
##
## `toolrun` used to translate `toolexec`'s ending into its own result type,
## one arm per ending; mapping the overflow (or I/O-error) arm to a finished
## run with exit code 0 left every test green. The translation is gone
## (`RunResult` is `toolexec`'s own type), and this pins the property at the
## seam the probes actually call:
##
##   * a child that writes past `MaxToolOutputBytes` ends `reOverflow` through
##     `realRun` and `realRunMerged` alike, and is not `ok`.
##   * `realRunWithStdinIn` hands the child its input, then EOF.
##   * with no input, stdin is still closed: a child that reads it to EOF
##     answers instead of waiting out the deadline.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_toolrun_endings.nim

import std/[os, osproc, strutils, unittest]
import crisol/[toolexec, toolrun]
import ../fixtures/two_burst_output

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin" / "r10toolrun"
  cacheDir   = fixtureDir / "nimcache" / "r10toolrun"

proc buildFixture(name: string): string =
  createDir(binDir)
  result = binDir / name.addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --nimcache:" &
                          (cacheDir / name) & " -o:" & result & " " &
                          (fixtureDir / name & ".nim"))
  doAssert rc == 0, name & " compile failed:\n" & o

let burstBin = buildFixture("two_burst_output")
let echoBin = buildFixture("stdin_echo")

template withBurstBytes(outBytes: int; body: untyped) =
  putEnv("CRISOL_BURST_BYTES", $outBytes)
  putEnv("CRISOL_BURST_STDERR_BYTES", "0")
  putEnv("CRISOL_BURST_DELAY_MS", "0")
  try:
    body
  finally:
    delEnv("CRISOL_BURST_BYTES")
    delEnv("CRISOL_BURST_STDERR_BYTES")
    delEnv("CRISOL_BURST_DELAY_MS")

suite "R10 — toolrun's real runners report every ending as it happened":

  test "realRun: a child past the output cap is reOverflow, never a finished run":
    withBurstBytes(MaxToolOutputBytes + 1):
      let r = realRun(burstBin, [])
      checkpoint("ending: " & describe(r))
      check r.ending == reOverflow   # RED under the mutant: reExited, exit 0
      check not r.ok
      check "exceeded" in describe(r)

  test "realRunMerged: a child past the output cap is reOverflow, never a finished run":
    withBurstBytes(MaxToolOutputBytes + 1):
      let r = realRunMerged(burstBin, [])
      checkpoint("ending: " & describe(r))
      check r.ending == reOverflow
      check not r.ok

  test "realRunWithStdinIn feeds the child its input, then EOF":
    let r = realRunWithStdinIn("", "discard\n")(echoBin, [])
    checkpoint("ending: " & describe(r))
    check r.ok
    if r.ending == reExited:
      check r.output == "[stdin:discard\n]"

  test "with no input the child's stdin is closed, not left open":
    let r = realRun(echoBin, [])
    checkpoint("ending: " & describe(r))
    check r.ok   # an open stdin: reTimedOut after ToolProbeTimeoutMs
    if r.ending == reExited:
      check r.output == "[stdin:]"

when isMainModule:
  echo "test_toolrun_endings done"
