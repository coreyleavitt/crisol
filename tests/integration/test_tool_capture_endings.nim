## test_tool_capture_endings.nim — R9-D5/S4/S5 (round-9 review): a tool
## capture that did not finish is never reported as a finished one.
##
## `toolexec.capture` ends a run one of five ways (`RunEnd`), and only
## `reExited` carries a capture at all. Pinned here against real child
## processes:
##
##   * a pipe that fails mid-capture (its handle closed out from under the
##     drain: POLLNVAL/EBADF on POSIX, PeekNamedPipe's invalid-handle error on
##     Windows) ends `reIoError`. The drain loops this replaced treated that
##     as end of output and returned the partial capture as a complete run
##     with the child's real exit code.
##   * a child that writes more than the byte cap ends `reOverflow`, and is
##     killed rather than read to the end.
##   * CONTROL: the same child under a cap it fits ends `reExited` with its
##     whole output.
##
## The pipe-failure case needs the child's handle before the drain starts,
## which only the module-private `capture` offers, so this file INCLUDES
## `crisol/toolexec` (white-box) rather than importing it.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_tool_capture_endings.nim

import std/[os, osproc, unittest]
include crisol/toolexec
import ../fixtures/two_burst_output

when defined(windows):
  import std/winlean
else:
  # `ioutils.closeFd` is crisol's own raw-fd close, so this test stays out of
  # the std/posix sweep (tests/conformance/test_rfc9_bucket_inventory.nim):
  # its only POSIX need is closing one fd, which is not a posix-bucket use.
  import crisol/ioutils

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin" / "r9endings"
  cacheDir   = fixtureDir / "nimcache" / "r9endings"

let burstBin = block:
  createDir(binDir)
  let b = binDir / "two_burst_output".addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --nimcache:" &
                          (cacheDir / "two_burst_output") & " -o:" & b & " " &
                          (fixtureDir / "two_burst_output.nim"))
  doAssert rc == 0, "two_burst_output compile failed:\n" & o
  b

template withBurstEnv(outBytes, errBytes, delayMs: int; body: untyped) =
  putEnv("CRISOL_BURST_BYTES", $outBytes)
  putEnv("CRISOL_BURST_STDERR_BYTES", $errBytes)
  putEnv("CRISOL_BURST_DELAY_MS", $delayMs)
  try:
    body
  finally:
    delEnv("CRISOL_BURST_BYTES")
    delEnv("CRISOL_BURST_STDERR_BYTES")
    delEnv("CRISOL_BURST_DELAY_MS")

suite "R9 — a capture that did not finish is not a finished run":

  test "a stdout pipe that fails mid-capture ends reIoError, never reExited":
    withBurstEnv(1024, 0, 500):
      let p = startProcess(burstBin, options = {poUsePath})
      defer: p.close()
      # Invalidate the read end before the drain reaches it. The child keeps
      # running and exits 0 on its own; only the capture is broken.
      when defined(windows):
        discard closeHandle(Handle(p.outputHandle))
      else:
        closeFd(cint(p.outputHandle))
      var tree = noTree()
      let t = capture(p, true, tree, 10_000, MaxToolOutputBytes)
      checkpoint("ending: " & describe(t))
      check t.ending == reIoError

  test "a child that writes past the byte cap ends reOverflow":
    withBurstEnv(4096, 0, 0):
      let t = runTool(burstBin, [], "", {poUsePath}, "", 10_000, 1024)
      checkpoint("ending: " & describe(t))
      check t.ending == reOverflow

  test "CONTROL the same child under a cap it fits ends reExited with all of its output":
    withBurstEnv(4096, 0, 0):
      let t = runTool(burstBin, [], "", {poUsePath}, "", 10_000,
                      BurstBanner.len + 4096)
      check t.ending == reExited
      if t.ending == reExited:
        check t.exitCode == 0
        check t.output == BurstBanner & burstPayload(4096)

when isMainModule:
  echo "test_tool_capture_endings done"
