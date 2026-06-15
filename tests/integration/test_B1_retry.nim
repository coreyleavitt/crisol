## test_B1_retry.nim — B1: retry dispatcher + flaky-pass integration tests.
##
## Tests the full retry lifecycle via crisol/api (runTests):
##   1. flaky_once fixture with retries=1 → flaky-pass (final outcome=oPassed,
##      flaky=true, attempts=2, exit 0).
##   2. Same + --fail-on-flaky (failOnFlaky=true) → exit 1.
##   3. always-failing fixture with retries=2 → 3 total attempts, final fail,
##      exit 1.
##   4. always-passing fixture → 1 attempt, not flaky, exit 0.
##   5. Cached pass is NOT retried (edCached is terminal at plan time).
##   6. fail_always with default retries=0 → fails on 1 attempt (no retry).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_B1_retry.nim

import std/[os, unittest]
import crisol/api

import "../support/helpers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"

proc baseOpts(projectRoot: string; retries: int = -1;
              failOnFlaky: bool = false): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        false,   # don't write lastrun.json in tests
    showProgress:   false,
    retries:        retries,
    failOnFlaky:    failOnFlaky,
  )

# ---------------------------------------------------------------------------
# Suite 1: flaky_once with retries=1 → flaky-pass, exit 0
# ---------------------------------------------------------------------------

suite "B1 — flaky_once with retries=1: flaky-pass, exit 0":

  test "flaky_once passes on attempt 2 (retries=1), outcome=oPassed, flaky=true":
    withTempProject:
      # Copy the flaky_once source into the temp project under the unit group.
      let src = fixtureDir / "flaky_once.nim"
      let dst = projectRoot / "tests" / "unit" / "test_flaky_once.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.status == rsOk
      check rr.exitCode == 0            # flaky-pass → exit 0 (no --fail-on-flaky)
      require rr.results.len == 1
      check rr.results[0].outcome  == oPassed
      check rr.results[0].flaky    == true
      check rr.results[0].attempts == 2  # failed attempt 1, passed attempt 2
      check rr.summary.passed == 1
      check rr.summary.failed  == 0
      check rr.summary.flaky   == 1

# ---------------------------------------------------------------------------
# Suite 2: flaky_once + fail-on-flaky → exit 1
# ---------------------------------------------------------------------------

suite "B1 — flaky_once + fail-on-flaky: exit 1":

  test "flaky_once with retries=1 and failOnFlaky=true → exit 1":
    withTempProject:
      let src = fixtureDir / "flaky_once.nim"
      let dst = projectRoot / "tests" / "unit" / "test_flaky_once.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1, failOnFlaky = true))
      check rr.status == rsOk
      check rr.exitCode == 1            # flaky-pass + --fail-on-flaky → exit 1
      require rr.results.len == 1
      check rr.results[0].outcome  == oPassed
      check rr.results[0].flaky    == true
      check rr.results[0].attempts == 2

# ---------------------------------------------------------------------------
# Suite 3: always-failing fixture with retries=2 → 3 attempts, final fail
# ---------------------------------------------------------------------------

suite "B1 — always-failing fixture with retries=2: 3 attempts, exit 1":

  test "fail_always with retries=2 → 3 total attempts, outcome=oFailed, exit 1":
    withTempProject:
      # fail_always.nim always exits with non-zero.
      let src = fixtureDir / "fail_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_fail_always.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 2))
      check rr.status == rsOk
      check rr.exitCode == 1
      require rr.results.len == 1
      # outcome is still oFailed after all attempts exhausted
      check rr.results[0].outcome  == oFailed
      check rr.results[0].flaky    == false
      check rr.results[0].attempts == 3  # 1 initial + 2 retries
      check rr.summary.failed == 1
      check rr.summary.passed == 0

# ---------------------------------------------------------------------------
# Suite 4: always-passing fixture → 1 attempt, not flaky
# ---------------------------------------------------------------------------

suite "B1 — pass_always: 1 attempt, not flaky":

  test "pass_always with retries=1 → passes on attempt 1, not flaky":
    withTempProject:
      let src = fixtureDir / "pass_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.status == rsOk
      check rr.exitCode == 0
      require rr.results.len == 1
      check rr.results[0].outcome  == oPassed
      check rr.results[0].flaky    == false
      check rr.results[0].attempts == 1   # passed first time; no retry triggered
      check rr.summary.passed == 1
      check rr.summary.flaky  == 0

# ---------------------------------------------------------------------------
# Suite 5: fail_always with default retries=0 → 1 attempt (no retry)
# ---------------------------------------------------------------------------

suite "B1 — fail_always with default retries=0: exactly 1 attempt":

  test "fail_always with no --retries → fails on attempt 1, attempts=1":
    withTempProject:
      let src = fixtureDir / "fail_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_fail_always.nim"
      copyFile(src, dst)

      # retries=-1 means "use config" — config has no retries key → 0.
      let rr = runTests(baseOpts(projectRoot, retries = -1))
      check rr.status == rsOk
      check rr.exitCode == 1
      require rr.results.len == 1
      check rr.results[0].outcome  == oFailed
      check rr.results[0].attempts == 1   # no retry
      check rr.summary.failed == 1

when isMainModule:
  echo "test_B1_retry done"
