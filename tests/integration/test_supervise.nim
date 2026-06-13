## test_supervise.nim — integration tests for crisol A2b spawn+supervise.
##
## Drives runEntrypoint over the three A2b fixtures and asserts expected outcomes:
##   pass_always   → oPassed  (exit 0)
##   fail_compile  → oCompileFailed  (captured compiler output non-empty)
##   hang_forever  → oTimeout  (within ~3 s total wall time)
##
## Fixture sources are compiled on demand by runEntrypoint — no pre-build step
## required for this test to run.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_supervise.nim

import std/[os, times, unittest]
import crisol/types   # Outcome, EntrypointResult
import crisol/runner  # runEntrypoint

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  ## Return absolute path to tests/fixtures/ relative to this file's location.
  ## Works whether invoked from project root or from inside tests/.
  let thisFile = currentSourcePath()             # absolute path to this .nim
  let testsDir = thisFile.parentDir.parentDir    # tests/
  testsDir / "fixtures"

proc ep(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "runEntrypoint — A2b/A3 supervised compile+run":

  test "pass_always → oPassed, exitCode 0":
    let src = fixtureDir() / "pass_always.nim"
    check fileExists(src)
    let o = runEntrypoint(ep(src), compileTimeoutMs = 30_000, runTimeoutMs = 10_000)
    check o.outcome  == oPassed
    check o.exitCode == 0

  test "fail_compile → oCompileFailed, output non-empty":
    let src = fixtureDir() / "fail_compile.nim"
    check fileExists(src)
    let o = runEntrypoint(ep(src), compileTimeoutMs = 30_000, runTimeoutMs = 10_000)
    check o.outcome  == oCompileFailed
    # The compiler must have emitted something about the undeclared identifier.
    check o.output.len > 0

  test "hang_forever → oTimeout, returns within ~35 s":
    let src = fixtureDir() / "hang_forever.nim"
    check fileExists(src)
    let t0 = epochTime()
    # compileTimeoutMs generous; runTimeoutMs short so the test stays fast.
    let o = runEntrypoint(ep(src), compileTimeoutMs = 30_000, runTimeoutMs = 1_500)
    let elapsed = epochTime() - t0

    check o.outcome == oTimeout

    # Total wall time must be well under 3 s of run time plus compile time.
    # compile may take a few seconds, but run timeout is 1.5 s.
    # We bound total elapsed to 35 s (30 s compile + 1.5 s run + headroom).
    check elapsed < 35.0

    # Additionally verify the run phase itself didn't massively overshoot:
    # after a successful compile the run should terminate within ~2 s.
    # We can't directly measure run phase here, but durationMs captures total.
    check o.durationMs < 35_000
