## test_B3_quarantine_summary.nim — B3 unit tests: summarize bucketing + exitCode
##
## Covers:
##   1. Quarantined FAILED result → Summary.quarantined=1, failed=0
##   2. Quarantined compileFailed → quarantined=1, compileFailed=0
##   3. Quarantined timedOut     → quarantined=1, timedOut=0
##   4. Quarantined signaled     → quarantined=1, signaled=0
##   5. Quarantined spawnError   → quarantined=1, spawnErrors=0
##   6. Quarantined PASSED result → passed=1, quarantined=0 (pass is benign)
##   7. exitCode 0 when the only failure is quarantined
##   8. exitCode 1 when a non-quarantined entrypoint also fails
##   9. total counts quarantined entrypoints regardless of outcome
##  10. Mixed: quarantined fail + non-quarantined pass → quarantined=1, failed=0, passed=1
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_B3_quarantine_summary.nim

import std/[unittest]
import crisol/types
import crisol/runner  # for summarize

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

proc quarFail(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oFailed,
                   exitCode: 1, quarantined: true)

proc quarCompileFail(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oCompileFailed,
                   exitCode: 1, quarantined: true)

proc quarTimeout(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oTimeout, quarantined: true)

proc quarSignal(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oSignal, signal: 11, quarantined: true)

proc quarSpawn(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oSpawnError, quarantined: true)

proc quarPass(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oPassed,
                   exitCode: 0, quarantined: true)

proc plainFail(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oFailed, exitCode: 1)

proc plainPass(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oPassed, exitCode: 0)

# ---------------------------------------------------------------------------

suite "B3 summarize — quarantine bucketing":

  test "quarantined oFailed → quarantined=1, failed=0":
    let s = summarize(@[quarFail("tests/a.nim")])
    check s.quarantined == 1
    check s.failed      == 0
    check s.total       == 1

  test "quarantined oCompileFailed → quarantined=1, compileFailed=0":
    let s = summarize(@[quarCompileFail("tests/a.nim")])
    check s.quarantined  == 1
    check s.compileFailed == 0
    check s.total         == 1

  test "quarantined oTimeout → quarantined=1, timedOut=0":
    let s = summarize(@[quarTimeout("tests/a.nim")])
    check s.quarantined == 1
    check s.timedOut    == 0
    check s.total       == 1

  test "quarantined oSignal → quarantined=1, signaled=0":
    let s = summarize(@[quarSignal("tests/a.nim")])
    check s.quarantined == 1
    check s.signaled    == 0
    check s.total       == 1

  test "quarantined oSpawnError → quarantined=1, spawnErrors=0":
    let s = summarize(@[quarSpawn("tests/a.nim")])
    check s.quarantined == 1
    check s.spawnErrors == 0
    check s.total       == 1

  test "quarantined pass is counted as passed, quarantined=0":
    ## A quarantined entrypoint that PASSES still counts as a normal pass.
    ## The quarantined counter is for FAILURES only.
    let s = summarize(@[quarPass("tests/a.nim")])
    check s.passed      == 1
    check s.quarantined == 0
    check s.total       == 1

  test "exitCode 0 when the only failure is quarantined":
    let s = summarize(@[quarFail("tests/a.nim")])
    check exitCode(s) == 0

  test "exitCode 1 when a non-quarantined entrypoint also fails":
    let s = summarize(@[quarFail("tests/a.nim"), plainFail("tests/b.nim")])
    check exitCode(s) == 1

  test "exitCode 1 when quarantined but --fail-on-flaky and a flaky result exists":
    ## Quarantine must not break the flaky exit path.
    let flakyPass = EntrypointResult(ep: makeEp("tests/c.nim"), outcome: oPassed,
                                     exitCode: 0, flaky: true)
    let s = summarize(@[quarFail("tests/a.nim"), flakyPass])
    check exitCode(s, failOnFlaky = true) == 1

  test "total always counts quarantined entrypoints":
    let s = summarize(@[quarFail("tests/a.nim"), quarPass("tests/b.nim"), plainPass("tests/c.nim")])
    check s.total    == 3
    check s.passed   == 2  # the quarPass + plainPass
    check s.quarantined == 1

  test "mixed quarantined fail + non-quarantined pass":
    let s = summarize(@[quarFail("tests/a.nim"), plainPass("tests/b.nim")])
    check s.quarantined == 1
    check s.failed      == 0
    check s.passed      == 1
    check exitCode(s)   == 0

when isMainModule:
  echo "B3 summarize/exitCode quarantine tests passed."
