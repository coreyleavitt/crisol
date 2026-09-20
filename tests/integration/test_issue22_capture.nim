## tests/integration/test_issue22_capture.nim — issue #22.
##
## A child process's output must be captured IN FULL. `streams.readAll` stops
## at the first read shorter than its 1024-byte buffer, and a pipe read returns
## as soon as any bytes are available — so a child that flushes twice is
## captured as if it had written only its first flush, with a success exit
## code. Nothing in the returned value distinguishes that from a child that
## genuinely said little.
##
## These tests drive PRODUCTION capture seams (`ccprobe.realRun` is the default
## `RunProc` every dependency probe runs through), not a test-local copy of the
## spawn code — the point is that the shipped path is complete, not that a
## drain loop written for the test is.
##
## Sizing: see `tests/fixtures/two_burst_output.nim`'s header. `PayloadBytes`
## stays under Nim's ~4 KB default pipe buffer (`CreatePipe` with `nSize = 0`,
## osproc.nim:664) so that a truncating capture FAILS these assertions rather
## than wedging the fixture mid-write and hanging the suite. It still has to
## clear `readAll`'s 1024-byte chunk, which the 18-byte banner already
## guarantees — the payload size only has to make the loss unmistakable.

import std/[os, osproc, strutils, unittest]
import crisol/[ccprobe, icbaseline]
import ../fixtures/two_burst_output
import ../support/deadline

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin"
  cacheDir   = fixtureDir / "nimcache"
  srcDir     = currentSourcePath().parentDir().parentDir().parentDir() / "src"
  PayloadBytes = 2048

proc compileFixture(name: string): string =
  ## Mirrors tests/conformance/helpers.nim's fixture build — fixtures are
  ## small, so staleness tracking would cost more than the rebuild. Called
  ## exactly once per run here; see `burstBin` below for why.
  createDir(binDir)
  let src = fixtureDir / (name & ".nim")
  # `.exe` explicitly on Windows: an extensionless output there is not
  # spawnable, and letting the spawn fail instead would surface as an empty
  # capture — indistinguishable from the very truncation these tests assert
  # against.
  let bin = binDir / name.addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & (cacheDir / name) &
                          " -o:" & bin & " " & src)
  doAssert rc == 0, name & " compile failed:\n" & o
  doAssert fileExists(bin), name & " compiled but produced no binary at " & bin
  bin

# Compiled ONCE per run, not per test: on Windows, relinking over an `.exe`
# this process has already spawned fails with a sharing violation (LNK1104),
# which would surface as a compile error in the middle of a test whose subject
# is something else entirely.
let burstBin = compileFixture("two_burst_output")

let captureProbeBin = block:
  let b = binDir / "capture_probe".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "capture_probe", b, srcDir)
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

suite "issue #22 — child output is captured in full":

  test "realRun returns the payload a two-burst child writes after its banner":
    withBurstEnv(PayloadBytes, 0, 150):
      let (output, ok) = realRun(burstBin, [])
      check ok
      # The load-bearing assertion: the SECOND burst survived. A truncating
      # capture returns the banner alone and still reports ok.
      check output.endsWith(burstPayload(PayloadBytes))
      # Ordering and exactness: banner first, payload entire, nothing extra.
      check output.startsWith(BurstBanner)
      check output.len == BurstBanner.len + PayloadBytes

  test "realIcRun returns both bursts when the child's streams are merged":
    # icbaseline spawns with poStdErrToStdOut, so stdout and stderr share one
    # pipe and one capture. Distinct payload sizes keep the assertion honest:
    # equal-sized payloads are byte-identical (both are the same a-z pattern),
    # so a length check alone could pass while one of them was dropped.
    const OutBytes = 1024
    const ErrBytes = 512
    withBurstEnv(OutBytes, ErrBytes, 150):
      let (exitCode, output) = realIcRun(@[burstBin])
      check exitCode == 0
      check output == BurstBanner & BurstBanner &
                      burstPayload(OutBytes) & burstPayload(ErrBytes)

  test "a child whose stderr overruns the pipe buffer neither wedges the probe nor loses its stdout":
    # `realRun` spawns with SEPARATE stderr and returns only stdout. Dropping
    # those bytes is a choice; not READING them is a bug — the pipe fills, the
    # child blocks inside its own `write`, never finishes stdout, never exits,
    # and the stdout read never returns. Same defect `gitdiff` had, same fix
    # (`toolexec.drainBoth`), asserted here at the seam issue #21's MSVC
    # dependency probe will run through.
    const OutBytes = 64
    const ErrBytes = 256 * 1024
    withBurstEnv(OutBytes, ErrBytes, 0):
      let (finished, line) = runWithDeadline(captureProbeBin, @[burstBin], 60_000)
      check finished                    # RED: the probe wedges and is killed
      if finished:
        check line.contains("outLen=" & $(BurstBanner.len + OutBytes))
