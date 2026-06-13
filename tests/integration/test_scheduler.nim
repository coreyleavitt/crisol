## test_scheduler.nim — A4 integration tests for the bounded-parallel scheduler.
##
## Verifies:
##   1. Parallel == serial invariant: jobs=1 and jobs=4 yield IDENTICAL aggregated
##      outcomes (same multiset of Outcome values in plan order).
##   2. Per-slot timeout under load: hang_forever gets oTimeout while the pool
##      continues running and completing other entrypoints.
##   3. Bounded concurrency (correctness invariant): with jobs=1 the pool still
##      produces correct results — regression guard against off-by-one in the
##      slot-filling logic.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_scheduler.nim

import std/[math, os, times, unittest]
import crisol/types
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

proc outcomes(results: seq[EntrypointResult]): seq[Outcome] =
  ## Extract outcomes in result order (== plan order).
  for r in results: result.add r.outcome

proc runPlan(eps: seq[Entrypoint]; jobs: int;
             compMs: int = 30_000; runMs: int = 10_000): seq[EntrypointResult] =
  ## Build a plan with the given job count and execute it.
  ## Timeouts are passed via Config (seconds); ms→s rounds UP so a sub-second
  ## run timeout (e.g. 1_500 ms) keeps at least 1 s of slack.
  let cfg = Config(
    jobs:               jobs,
    compileTimeoutSecs: max(1, int(ceil(compMs / 1000))),
    timeoutSecs:        max(1, int(ceil(runMs / 1000))),
    projectRoot:        getCurrentDir(),
  )
  let p   = plan(cfg, eps, emptyDepGraph())
  var g   = emptyDepGraph()
  execute(p, config = cfg, graph = g)

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------

suite "scheduler — parallel == serial invariant":

  test "jobs=1 and jobs=4 produce identical outcomes for pass/fail/compile-fail mix":
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
      mkEp(fdir / "fail_compile.nim"),
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
    ]

    let serial   = runPlan(eps, jobs = 1)
    let parallel = runPlan(eps, jobs = 4)

    check serial.len   == eps.len
    check parallel.len == eps.len

    # Results must be in plan order and match for every slot.
    for i in 0 ..< eps.len:
      check serial[i].outcome == parallel[i].outcome

  test "jobs=1 and jobs=2 produce identical outcomes (edge: jobs < fixtures)":
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
    ]
    let r1 = runPlan(eps, jobs = 1)
    let r2 = runPlan(eps, jobs = 2)
    check r1.len == r2.len
    for i in 0 ..< r1.len:
      check r1[i].outcome == r2[i].outcome

  test "single entrypoint — jobs=4 works with fewer entrypoints than slots":
    let fdir = fixtureDir()
    let eps = @[mkEp(fdir / "pass_always.nim")]
    let results = runPlan(eps, jobs = 4)
    check results.len == 1
    check results[0].outcome == oPassed

  test "empty plan — execute returns empty sequence":
    let results = runPlan(@[], jobs = 4)
    check results.len == 0


suite "scheduler — per-slot timeout under load":

  test "hang_forever times out; pool completes other entrypoints":
    ## With jobs >= 2, a hung entrypoint must time out without blocking others.
    ## We set a short run timeout so the test stays fast.
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "hang_forever.nim"),   # will time out
      mkEp(fdir / "pass_always.nim"),    # must still complete
      mkEp(fdir / "fail_always.nim"),    # must still complete
    ]

    let runTimeoutMs = 1_500  # 1.5 s run timeout for hang_forever
    let t0 = epochTime()
    let results = runPlan(eps, jobs = 3,
                          compMs = 30_000, runMs = runTimeoutMs)
    let elapsed = epochTime() - t0

    check results.len == 3

    # hang_forever should be oTimeout.
    check results[0].outcome == oTimeout

    # Others should complete with their normal outcomes.
    check results[1].outcome == oPassed
    check results[2].outcome == oFailed

    # The pool total wall time should be well within compile + timeout + slack.
    # Worst case: compile time for hang_forever (~few seconds) + 1.5s run timeout.
    # We allow 60 s total (generous; any real issue will be much worse).
    check elapsed < 60.0

  test "oTimeout reported even when hang_forever is the only slot":
    ## Regression: ensure timeout works correctly with jobs=1.
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "hang_forever.nim")]
    let t0   = epochTime()
    let res  = runPlan(eps, jobs = 1, compMs = 30_000, runMs = 1_500)
    let elapsed = epochTime() - t0
    check res.len == 1
    check res[0].outcome == oTimeout
    check elapsed < 60.0


suite "scheduler — correctness / bounded concurrency":

  test "jobs=1: sequential execution still produces correct outcomes":
    ## If the slot-filling logic has an off-by-one (e.g. never re-fills after
    ## completion), this test will see fewer than 3 results or wrong outcomes.
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
      mkEp(fdir / "fail_compile.nim"),
    ]
    let results = runPlan(eps, jobs = 1)
    check results.len == 3
    check results[0].outcome == oPassed
    check results[1].outcome == oFailed
    check results[2].outcome == oCompileFailed

  test "continue-on-failure: all entrypoints run even after early failures (jobs=2)":
    ## Ensure a compile failure in the first batch does not drain the queue.
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "fail_compile.nim"),
      mkEp(fdir / "fail_compile.nim"),
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "pass_always.nim"),
    ]
    let results = runPlan(eps, jobs = 2)
    check results.len == 4
    check results[0].outcome == oCompileFailed
    check results[1].outcome == oCompileFailed
    check results[2].outcome == oPassed
    check results[3].outcome == oPassed

  test "results are in plan order regardless of completion order (jobs=4)":
    ## pass_always compiles and runs fast; fail_compile returns quickly too.
    ## With jobs=4 they all run in parallel; results must still be plan-ordered.
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_compile.nim"),
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
    ]
    let results = runPlan(eps, jobs = 4)
    check results.len == 4
    check results[0].outcome == oPassed
    check results[1].outcome == oCompileFailed
    check results[2].outcome == oPassed
    check results[3].outcome == oFailed

  test "summarize over parallel results counts correctly":
    let fdir = fixtureDir()
    let eps = @[
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "pass_always.nim"),
      mkEp(fdir / "fail_always.nim"),
      mkEp(fdir / "fail_compile.nim"),
    ]
    let results = runPlan(eps, jobs = 4)
    let s = summarize(results)
    check s.total        == 4
    check s.passed       == 2
    check s.failed       == 1
    check s.compileFailed == 1
    check exitCode(s)    == 1
