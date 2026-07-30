## test_icbaseline_real.nim — RFC-0006 M-IC-baseline: ONE real live-compile
## integration test.
##
## Everything else in test_icbaseline.nim (unit) exercises `probeIncremental`
## with a synthetic `IcRunProc`/`IcTimeProc` seam. This is the single
## deliberately-budgeted exception (mirrors ccprobe/compiledriver precedent):
## drive `realIcRun` against the REAL toolchain's `nim c --mm:orc
## --incremental` for `tests/fixtures/pass_always.nim` (the smallest/fastest
## fixture in the suite), into a fresh temp nimcache + temp bin.
##
## This is an EVALUATION probe, not an assertion that IC works — Nim's
## `--incremental` is perennially experimental under `--mm:orc` and must be
## empirically tested, never assumed. So this test asserts only that the
## result is WELL-FORMED (booleans consistent, timings non-negative, no
## crash/hang) and PRINTS the empirical verdict so it's visible in the test
## log / CI output — the actual supported/orcCompatible/timing verdict is a
## decision-gate input for RFC-0006, recorded here rather than assumed.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_icbaseline_real.nim

import std/[os, unittest]
import crisol/icbaseline

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root
let fixture = projectRoot / "tests" / "fixtures" / "pass_always.nim"

suite "probeIncremental — real toolchain probe (pass_always fixture)":

  test "terminates quickly and yields a well-formed, internally-consistent result":
    let workDir      = getTempDir() / "crisol_test_icbaseline_real_" & $getCurrentProcessId()
    let nimcacheDir  = workDir / "nimcache"
    let outputBinPath = workDir / "pass_always_ic"
    removeDir(workDir)
    createDir(nimcacheDir)

    let r = probeIncremental(realIcRun, fixture, nimcacheDir, outputBinPath)

    echo "=== M-IC-baseline empirical verdict ==="
    echo "  supported     = ", r.supported
    echo "  orcCompatible = ", r.orcCompatible
    echo "  firstUs       = ", r.firstUs
    echo "  secondUs      = ", r.secondUs
    echo "  speedupPct    = ", r.speedupPct
    echo "  errorMsg      = ", r.errorMsg
    echo "========================================"

    # Well-formedness only — NOT a hard assertion that IC works under ORC.
    check r.firstUs >= 0
    check r.secondUs >= 0

    if not r.supported:
      # Option rejected outright: no meaningful timings, no ORC claim.
      check not r.orcCompatible
      check r.speedupPct == 0.0
      check r.errorMsg.len > 0
    elif not r.orcCompatible:
      # Option accepted but a build failed under --mm:orc --incremental.
      check r.speedupPct == 0.0
      check r.errorMsg.len > 0
    else:
      # Both compiles genuinely succeeded: timings are real and the
      # produced binary is the real pass_always fixture.
      check r.errorMsg == ""
      check fileExists(outputBinPath)

    removeDir(workDir)

when isMainModule:
  echo "All icbaseline real-compile tests passed."
