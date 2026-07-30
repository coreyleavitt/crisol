## test_icbaseline.nim — unit tests for icbaseline.nim (RFC-0006 M-IC-baseline).
##
## All I/O is synthetic: tests inject a fake `IcRunProc` seam that returns
## hard-coded (exitCode, output) pairs, and a fake `IcTimeProc` seam that
## returns deterministic synthetic `MonoTime` values, so no real `nim` process
## is spawned and timings are exact (not real-wall-clock-dependent).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_icbaseline.nim

import std/[unittest, monotimes, times]
import crisol/icbaseline

# ---------------------------------------------------------------------------
# Seam helpers
# ---------------------------------------------------------------------------

proc makeRun(results: seq[tuple[exitCode: int, output: string]]): IcRunProc =
  ## Returns a run proc that serves `results` in order, one per call
  ## (call 1 -> results[0], call 2 -> results[1], ...).
  var idx = 0
  result = proc(args: seq[string]): tuple[exitCode: int, output: string] =
    let r = results[idx]
    inc idx
    r

proc makeClock(usValues: seq[int64]): IcTimeProc =
  ## Returns a clock proc that serves synthetic MonoTime values built from
  ## `usValues` (microsecond offsets from MonoTime.low — the only publicly
  ## constructible MonoTime, since `ticks` is private to std/monotimes).
  var idx = 0
  result = proc(): MonoTime =
    let us = usValues[idx]
    inc idx
    MonoTime.low + initDuration(microseconds = us)

# ---------------------------------------------------------------------------
# Behavior 1: both-success path
# ---------------------------------------------------------------------------

suite "probeIncremental — both compiles succeed":

  test "supported && orcCompatible, speedupPct computed from injected timings":
    let run = makeRun(@[
      (exitCode: 0, output: "Hint: rod file cache written [...]"),
      (exitCode: 0, output: "Hint: rod file cache reused [...]")
    ])
    # t0=0, t1=1000 (firstUs=1000); t2=1000, t3=1400 (secondUs=400)
    let clock = makeClock(@[0'i64, 1000'i64, 1000'i64, 1400'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check r.supported
    check r.orcCompatible
    check r.firstUs == 1000
    check r.secondUs == 400
    check r.speedupPct == 60.0
    check r.errorMsg == ""

# ---------------------------------------------------------------------------
# Behavior 2: option-unsupported path
# ---------------------------------------------------------------------------

suite "probeIncremental — --incremental rejected by option parser":

  test "supported=false, orcCompatible=false, speedupPct=0.0":
    let run = makeRun(@[
      (exitCode: 1, output: "Error: invalid command line option: '--incremental'")
    ])
    let clock = makeClock(@[0'i64, 500'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check not r.supported
    check not r.orcCompatible
    check r.speedupPct == 0.0
    check r.errorMsg == "Error: invalid command line option: '--incremental'"

# ---------------------------------------------------------------------------
# Behavior 3: ORC-incompatible path (option accepted, build fails)
# ---------------------------------------------------------------------------

suite "probeIncremental — option accepted, build fails under ORC+IC":

  test "supported=true, orcCompatible=false, errorMsg populated":
    let run = makeRun(@[
      (exitCode: 1, output: "Error: --incremental is not supported with --mm:orc")
    ])
    let clock = makeClock(@[0'i64, 700'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check r.supported
    check not r.orcCompatible
    check r.speedupPct == 0.0
    check r.errorMsg == "Error: --incremental is not supported with --mm:orc"

  test "second (repeat) compile fails after a successful first -> still orcCompatible=false":
    let run = makeRun(@[
      (exitCode: 0, output: "Hint: rod file cache written [...]"),
      (exitCode: 1, output: "Error: internal error: IC corruption")
    ])
    let clock = makeClock(@[0'i64, 1000'i64, 1000'i64, 1900'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check r.supported
    check not r.orcCompatible
    check r.firstUs == 1000
    check r.secondUs == 900
    check r.speedupPct == 0.0
    check r.errorMsg == "Error: internal error: IC corruption"

# ---------------------------------------------------------------------------
# Behavior 4: edge cases — no divide-by-zero
# ---------------------------------------------------------------------------

suite "probeIncremental — edge cases":

  test "firstUs == 0 -> speedupPct == 0.0 (no divide-by-zero)":
    let run = makeRun(@[
      (exitCode: 0, output: "Hint: rod file cache written [...]"),
      (exitCode: 0, output: "Hint: rod file cache reused [...]")
    ])
    let clock = makeClock(@[0'i64, 0'i64, 0'i64, 0'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check r.supported
    check r.orcCompatible
    check r.firstUs == 0
    check r.speedupPct == 0.0

  test "not-both-succeeded (first fails, an accepted-but-failed build) -> speedupPct == 0.0":
    let run = makeRun(@[
      (exitCode: 2, output: "Error: --incremental build failed for other reasons")
    ])
    let clock = makeClock(@[0'i64, 300'i64])
    let r = probeIncremental(run, "entry.nim", "/tmp/nimcache", "/tmp/out", clock)
    check r.supported
    check not r.orcCompatible
    check r.speedupPct == 0.0

when isMainModule:
  echo "All icbaseline tests passed."
