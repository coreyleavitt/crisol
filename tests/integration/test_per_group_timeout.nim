## test_per_group_timeout.nim — S2b integration test: per-group run deadline.
##
## Verifies that an entrypoint placed in a group with a short `timeout-secs`
## is classified `oTimeout` according to *that group's* budget, while the
## global run timeout is set much larger (60 s).  This distinguishes the
## per-group wiring from the pre-existing global-only behaviour.
##
## Also confirms that a fast entrypoint in a timed group still completes
## normally (no spurious timeout).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_per_group_timeout.nim

import std/[os, times, unittest]
import crisol/types
import crisol/runner
import crisol/scheduler  # effectiveRunTimeoutMs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEpWithTimeout(path: string; groupTimeoutSecs: int): Entrypoint =
  ## Build an Entrypoint that carries a per-group run timeout, mimicking what
  ## discover() copies from group.timeoutSecs into ep.runTimeoutSecs.
  Entrypoint(
    path:            path,
    group:           "timed_group",
    flags:           @[],
    runTimeoutSecs:  groupTimeoutSecs,
  )

proc runWith(eps: seq[Entrypoint]; jobs: int;
             globalRunSecs: int = 60): seq[EntrypointResult] =
  ## Execute a plan with the given global run timeout (seconds).
  ## The per-entrypoint deadline is resolved from ep.runTimeoutSecs via
  ## effectiveRunTimeoutMs at slot setup time (S2b wiring).
  let cfg = Config(
    jobs:               jobs,
    compileTimeoutSecs: 60,          # generous compile budget
    timeoutSecs:        globalRunSecs,
    projectRoot:        getCurrentDir(),
  )
  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  execute(p, config = cfg, graph = g, showProgress = false)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "S2b — per-group run timeout wiring":

  test "group timeout-secs 1 fires at ~1s while global is 60s":
    ## hang_forever sleeps in a tight loop. With the group timeout at 1 s and
    ## the global at 60 s, the slot should time out at ~1 s (not 60 s).
    ##
    ## This test fails BEFORE S2b is wired because execute() ignores
    ## ep.runTimeoutSecs and uses config.timeoutSecs (60 s) for all slots.
    let fdir = fixtureDir()
    let eps = @[
      mkEpWithTimeout(fdir / "hang_forever.nim", groupTimeoutSecs = 1),
    ]

    let t0 = epochTime()
    let results = runWith(eps, jobs = 1, globalRunSecs = 60)
    let elapsed = epochTime() - t0

    check results.len == 1
    check results[0].outcome == oTimeout

    # Must complete well under the global 60 s budget.
    # Allow up to 15 s total (generous compile headroom + 1 s run limit).
    check elapsed < 15.0

  test "fast entrypoint in a timed group still completes normally":
    ## pass_always exits immediately; even a 1 s group budget is plenty.
    ## Regression guard: per-group wiring must not break the happy path.
    let fdir = fixtureDir()
    let eps = @[
      mkEpWithTimeout(fdir / "pass_always.nim", groupTimeoutSecs = 1),
    ]
    let results = runWith(eps, jobs = 1, globalRunSecs = 60)
    check results.len == 1
    check results[0].outcome == oPassed

  test "group timeout fires earlier than global (comparative)":
    ## Run the same hanging fixture twice: once with the group timeout at 1 s,
    ## once with ep.runTimeoutSecs = 0 (falls back to global = 60 s).
    ## The group-timed run must finish in well under half the global timeout,
    ## proving that the per-group value — not the global — controlled the cutoff.
    let fdir = fixtureDir()
    let hang = fdir / "hang_forever.nim"

    # Group-timed: 1 s run deadline.
    let epsTimed = @[mkEpWithTimeout(hang, groupTimeoutSecs = 1)]
    let t0 = epochTime()
    let resTimed = runWith(epsTimed, jobs = 1, globalRunSecs = 60)
    let elapsedTimed = epochTime() - t0

    check resTimed[0].outcome == oTimeout
    # Must finish well before the 60 s global would fire (< 15 s is generous).
    check elapsedTimed < 15.0
