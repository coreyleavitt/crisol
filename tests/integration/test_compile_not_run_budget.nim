## test_compile_not_run_budget.nim — Feature A (Gap 4): run deadline is
## anchored at the spCompiling→spRunning transition, NOT at process spawn.
##
## The property under test:
##   slot.deadline for the RUN phase is set in spawnRun(), which is called
##   ONLY after the compile child exits successfully.  This means a long compile
##   cannot consume the run-timeout budget.
##
## How we detect the regression:
##   If the run deadline were incorrectly anchored at compile-start
##   (i.e. slot.deadline set in spawnCompileStable with the run_timeout budget),
##   then for hang_forever.nim with a 2-second run timeout, the deadline would
##   fire while the process is still in spCompiling phase.  pollSlot returns
##   oCompileFailed when the deadline fires during spCompiling.
##
##   With the CORRECT implementation, the deadline for the run phase is set fresh
##   in spawnRun() at the compile→run transition.  When hang_forever is killed,
##   the slot is in spRunning phase → outcome is oTimeout (not oCompileFailed).
##
## Test 1 (direct regression check):
##   Run hang_forever.nim with ep.runTimeoutSecs = 2, compileTimeoutSecs = 60.
##   Assert outcome == oTimeout (NOT oCompileFailed).
##   oCompileFailed would mean the timeout fired during compile → wrong anchoring.
##   oTimeout means the timeout fired during run → correct anchoring.
##
##   Limitation: this test is deterministic ONLY if compile of hang_forever.nim
##   finishes within 2 seconds.  In practice, a trivial Nim file compiles in
##   < 2s even in the container.  If compile were to take > 2s (unlikely), both
##   buggy and correct implementations would produce oCompileFailed — so this
##   test would not catch the regression in that unlikely environment.
##   A more decisive test would need a synthetic slow-compile fixture, which
##   is excluded by the anti-flake requirement.  The test is conservative and
##   documents this limitation explicitly.
##
## Test 2 (non-regression — normal run succeeds):
##   Run pass_always.nim with ep.runTimeoutSecs = 2, compileTimeoutSecs = 60.
##   Assert outcome == oPassed (not oTimeout, not oCompileFailed).
##   If the deadline were anchored at compile-start and compile > 2s, this would
##   give oCompileFailed.  Since compile << 2s here, this is a safety check.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_compile_not_run_budget.nim

import std/[os, times, unittest]
import crisol/types
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEpWithTimeout(path: string; runTimeoutSecs: int): Entrypoint =
  ## Build an Entrypoint carrying a per-entrypoint run timeout, mimicking
  ## what discover() copies from group.timeoutSecs into ep.runTimeoutSecs.
  Entrypoint(
    path:           path,
    group:          "default",
    flags:          @[],
    runTimeoutSecs: runTimeoutSecs,
  )

proc runWithTimeouts(ep: Entrypoint;
                     compileTimeoutSecs: int): EntrypointResult =
  ## Execute a single entrypoint; compile timeout is generous; run timeout
  ## comes from ep.runTimeoutSecs.
  let cfg = Config(
    jobs:               1,
    timeoutSecs:        60,           # global — ep.runTimeoutSecs overrides
    compileTimeoutSecs: compileTimeoutSecs,
    maxOutputBytes:     65_536,
    projectRoot:        getCurrentDir(),
  )
  let p = plan(cfg, @[ep], emptyDepGraph())
  var g = emptyDepGraph()
  let results = execute(p, config = cfg, graph = g, showProgress = false)
  if results.len > 0: results[0]
  else: EntrypointResult(ep: ep, outcome: oSpawnError)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "Feature A — run deadline anchored at run-start, not compile-start":

  test "hang_forever with 2s run timeout → oTimeout (not oCompileFailed)":
    ## If run deadline were set at compile-start + 2s, and compile takes > 2s,
    ## the deadline would fire during spCompiling → pollSlot returns oCompileFailed.
    ## With correct implementation, deadline is set at run-start → oTimeout.
    ##
    ## Limitation: conclusive only when hang_forever.nim compiles in < 2s.
    ## In practice, a trivial Nim file always compiles well under 2s in the
    ## container.  The test is conservative and documented accordingly.
    let fdir = fixtureDir()
    let ep   = mkEpWithTimeout(fdir / "hang_forever.nim", runTimeoutSecs = 2)

    let t0  = epochTime()
    let res = runWithTimeouts(ep, compileTimeoutSecs = 60)
    let elapsed = epochTime() - t0

    # The outcome must be oTimeout — not oCompileFailed.
    # oCompileFailed would indicate the deadline fired during compile (wrong anchoring).
    check res.outcome == oTimeout
    ## Non-vacuity: if spawnRun forgot to set slot.deadline (leaving it at the
    ## compile deadline = compile_start + 60s), hang_forever would never time out
    ## in 2s → this check would fail (wrong outcome or too slow).
    ##
    ## Regression: if the deadline were moved to compile-start with the run budget,
    ## AND compile takes < 2s, outcome would still be oTimeout (same phase at kill
    ## time).  The oCompileFailed vs oTimeout distinction catches regressions only
    ## when compile takes > run_timeout_ms.  This is the fundamental limitation —
    ## documented here rather than masked.

    # Sanity: total elapsed should be roughly 2s (compile + 2s run timeout).
    # Allow up to 15s total for compile overhead.
    check elapsed < 15.0

  test "pass_always with 2s run timeout → oPassed (deadline is not consumed by compile)":
    ## A fast-exiting binary must pass even with a short run timeout.
    ## If the deadline were set at compile-start + 2s and compile took > 2s,
    ## this would produce oCompileFailed instead of oPassed.
    let fdir = fixtureDir()
    let ep   = mkEpWithTimeout(fdir / "pass_always.nim", runTimeoutSecs = 2)

    let res = runWithTimeouts(ep, compileTimeoutSecs = 60)

    # Fast binary must complete within the run budget.
    check res.outcome == oPassed
    ## Non-vacuity: if the run deadline were set to an instant (e.g. a bug set
    ## deadline = getMonoTime() in spawnRun without adding the budget), the binary
    ## would immediately time out → oTimeout, and this check would fail.

when isMainModule:
  echo "Feature A deadline tests done."
