## test_run_many.nim — A3 integration tests for plan/execute/summarize.
##
## Verifies:
##   1. execute() runs ALL entrypoints even when some fail (continue-on-failure).
##   2. Each entrypoint's outcome is correctly classified in the result sequence.
##   3. summarize() counts passed/failed correctly.
##   4. exitCode(summary) returns non-zero when any failed, zero when all passed.
##
## Fixtures used:
##   pass_always   → oPassed
##   fail_always   → oFailed
##   fail_compile  → oCompileFailed
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_run_many.nim

import std/[options, os, unittest]
import crisol/types
import crisol/runner
from crisol/process/types as ptypes import nil

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

## rfc-0007 A1e-i: EntrypointResult.outcome is gone — outcome(r) derives from
## compile/run Phase. These helpers build a hand-fixture Phase pair for the
## "summarize — pure aggregate counts" suite below, which tests the fold
## directly rather than through a live execute() run.
proc ranPhase(exit: ptypes.Exit; cause: ptypes.Cause): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: cause, evidence: default(ptypes.Evidence),
    rusage: none(ptypes.Rusage), durationUs: 0))

const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)
const processCause = ptypes.Cause(by: ptypes.cbProcess)

proc passedResult(ep: Entrypoint): EntrypointResult =
  result = EntrypointResult(ep: ep, compile: skippedPhase,
    run: ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 0), processCause))

proc killedResult(ep: Entrypoint): EntrypointResult =
  result = EntrypointResult(ep: ep, compile: skippedPhase,
    run: ranPhase(ptypes.Exit(kind: ptypes.ekSignaled, sig: 15, coreDumped: false),
                  ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false)))

proc crashedResult(ep: Entrypoint): EntrypointResult =
  result = EntrypointResult(ep: ep, compile: skippedPhase,
    run: ranPhase(ptypes.Exit(kind: ptypes.ekSignaled, sig: 11, coreDumped: false), processCause))

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------

suite "plan — pure annotation of compile decisions":

  test "all entrypoints annotated cdNeverBuilt with empty graph":
    let cfg = Config(jobs: 0)   # jobs=0 → resolved to max(1, cpu-2) by plan() (A4)
    let eps = @[
      Entrypoint(path: "tests/fixtures/pass_always.nim",  group: "g", flags: @[]),
      Entrypoint(path: "tests/fixtures/fail_always.nim",  group: "g", flags: @[]),
    ]
    let p = plan(cfg, eps, emptyDepGraph())
    check p.entrypoints.len == 2
    for pep in p.entrypoints:
      check pep.edecision == edNeverBuilt
    check p.jobs >= 1   # 0 resolved to at least 1 (A4: max(1, cpu-2))

  test "plan is pure — does not run any process":
    ## Build a plan over a non-existent path; if plan tried to compile or stat
    ## the binary it would fail or produce oCompileFailed.  The fact that plan()
    ## returns successfully (without raising) proves no I/O happened.
    let cfg = Config(jobs: 2)
    let eps = @[
      Entrypoint(path: "does_not_exist_at_all.nim", group: "g", flags: @[]),
    ]
    let p = plan(cfg, eps, emptyDepGraph())
    check p.entrypoints.len == 1
    check p.entrypoints[0].edecision == edNeverBuilt
    check p.jobs == 2

  test "jobs resolved: config.jobs > 0 is preserved":
    let cfg = Config(jobs: 4)
    let p = plan(cfg, @[], emptyDepGraph())
    check p.jobs == 4


suite "execute — continue-on-failure aggregation":

  test "all pass → every result is oPassed, summary all-passed":
    let fdir = fixtureDir()
    let cfg = Config(compileTimeoutSecs: 30, timeoutSecs: 10,
                     projectRoot: getCurrentDir())
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "pass_always.nim"),   # run twice; both should pass
    ]
    let p = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 2
    for r in results:
      check outcome(r) == oPassed
    let s = summarize(results)
    check s.total  == 2
    check s.passed == 2
    check s.failed == 0
    check exitCode(s) == 0

  test "mix of pass and fail → ALL run, correct outcomes, non-zero exit":
    let fdir = fixtureDir()
    let cfg = Config(compileTimeoutSecs: 30, timeoutSecs: 10,
                     projectRoot: getCurrentDir())
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
      mkEp(fdir / "fail_compile.nim"),
    ]
    let p = plan(cfg, eps, emptyDepGraph())

    # Collect via onResult callback to verify it fires for every entrypoint.
    var callbackFired = 0
    proc onR(r: EntrypointResult) = inc callbackFired

    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g, onResult = onR)

    # All three entrypoints must have produced a result — continue-on-failure.
    check results.len == 3
    check callbackFired == 3

    # Check individual outcomes in plan order.
    check outcome(results[0]) == oPassed
    check outcome(results[1]) == oFailed
    check outcome(results[2]) == oCompileFailed

    # Summary counts.
    let s = summarize(results)
    check s.total         == 3
    check s.passed        == 1
    check s.failed        == 1
    check s.compileFailed == 1
    check s.counts[oKilled]  == 0
    check s.counts[oCrashed] == 0

    # Non-zero exit when any entrypoint failed.
    check exitCode(s) == 1

  test "all fail → summary correctly tallied, exitCode non-zero":
    let fdir = fixtureDir()
    let cfg = Config(compileTimeoutSecs: 30, timeoutSecs: 10,
                     projectRoot: getCurrentDir())
    let eps = @[
      mkEp(fdir / "fail_always.nim"),
      mkEp(fdir / "fail_always.nim"),
    ]
    let p = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 2
    let s = summarize(results)
    check s.total  == 2
    check s.passed == 0
    check s.failed == 2
    check exitCode(s) == 1


suite "summarize — pure aggregate counts":

  test "empty result sequence":
    let s = summarize(@[])
    check s.total  == 0
    check s.passed == 0
    check s.failed == 0
    check exitCode(s) == 0
    check s.noTestsRan == false

  test "all passed → exitCode 0":
    let ep0 = Entrypoint(path: "x.nim", group: "g", flags: @[])
    let results = @[
      passedResult(ep0),
      passedResult(ep0),
    ]
    let s = summarize(results)
    check s.total  == 2
    check s.passed == 2
    check exitCode(s) == 0

  test "one killed → exitCode 1":
    let ep0 = Entrypoint(path: "x.nim", group: "g", flags: @[])
    let results = @[
      passedResult(ep0),
      killedResult(ep0),
    ]
    let s = summarize(results)
    check s.counts[oKilled] == 1
    check exitCode(s) == 1

  test "one crashed → exitCode 1":
    let ep0 = Entrypoint(path: "x.nim", group: "g", flags: @[])
    let results = @[
      crashedResult(ep0),
    ]
    let s = summarize(results)
    check s.counts[oCrashed] == 1
    check exitCode(s) == 1
