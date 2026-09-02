## test_B3_quarantine_summary.nim — B3 unit tests: summarize bucketing + exitCode
##
## Covers:
##   1. Quarantined FAILED result → Summary.quarantined=1, failed=0
##   2. Quarantined compileFailed → quarantined=1, compileFailed=0
##   3. Quarantined killed       → quarantined=1, counts[oKilled]=0
##   4. Quarantined crashed      → quarantined=1, counts[oCrashed]=0
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

import std/[options, unittest]
import crisol/types
import crisol/runner  # for summarize
from crisol/process/types as ptypes import nil

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

## rfc-0007 A1e-i: outcome is derived from compile/run Phase, not stored —
## each helper below builds the Phase pair that derives the outcome its name
## promises, so these tests still discriminate by failure KIND, not just by
## "some failure or other" (quarantine doesn't care which kind, but the test
## names — and the exercised summarize() case arms — do).
const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)

proc ranPhase(exit: ptypes.Exit; cause: ptypes.Cause): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: cause, evidence: default(ptypes.Evidence),
    rusage: none(ptypes.Rusage), durationUs: 0))

proc quarFail(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 1),
                        ptypes.Cause(by: ptypes.cbProcess))

proc quarCompileFail(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 1),
                            ptypes.Cause(by: ptypes.cbProcess))
  result.run = skippedPhase

proc quarKilled(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekSignaled, sig: 15, coreDumped: false),
                        ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false))

proc quarCrashed(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekSignaled, sig: 11, coreDumped: false),
                        ptypes.Cause(by: ptypes.cbProcess))

proc quarSpawn(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = skippedPhase
  result.run = ptypes.Phase(kind: ptypes.pkSpawnFailed, spawnError: "test")

proc quarPass(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), quarantined: true)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 0),
                        ptypes.Cause(by: ptypes.cbProcess))

proc plainFail(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path))
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 1),
                        ptypes.Cause(by: ptypes.cbProcess))

proc plainPass(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path))
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 0),
                        ptypes.Cause(by: ptypes.cbProcess))

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

  test "quarantined killed → quarantined=1, counts[oKilled]=0":
    let s = summarize(@[quarKilled("tests/a.nim")])
    check s.quarantined == 1
    check s.counts[oKilled] == 0
    check s.total       == 1

  test "quarantined crashed → quarantined=1, counts[oCrashed]=0":
    let s = summarize(@[quarCrashed("tests/a.nim")])
    check s.quarantined == 1
    check s.counts[oCrashed] == 0
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
    ## rfc-0007 A1e-i: flaky(r) derives from outcome(r)==oPassed and attempts>1
    ## — there is no stored `flaky` field to stamp directly any more.
    var flakyPass = EntrypointResult(ep: makeEp("tests/c.nim"), attempts: 2)
    flakyPass.compile = skippedPhase
    flakyPass.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 0),
                             ptypes.Cause(by: ptypes.cbProcess))
    check flaky(flakyPass)
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
