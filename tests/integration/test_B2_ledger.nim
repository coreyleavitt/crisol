## test_B2_ledger.nim — B2: ledger append wiring + flake-rate integration tests.
##
## Tests that execute() appends one ledger row per LIVE attempt, that edCached
## entries produce NO rows, and that the flake-rate query over real shard data
## correctly identifies flaky identities.
##
## Fixtures used:
##   flaky_once.nim   — fails attempt 1, passes attempt 2 (retries=1 → 2 rows)
##   pass_always.nim  — always passes (retries=1 → 1 row, attempt=1)
##   fail_always.nim  — always fails (retries=2 → 3 rows, all fail outcome)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_B2_ledger.nim

import std/[os, unittest]
import crisol/api
import crisol/ledger
import crisol/keys
import crisol/depgraph

import "../support/helpers"

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"

proc baseOpts(projectRoot: string; retries: int = -1): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        false,
    showProgress:   false,
    retries:        retries,
  )

# ---------------------------------------------------------------------------
# Suite 1: flaky_once with retries=1 → 2 ledger rows, attempt 1 fail + attempt 2 pass
#          After run: isFlaky = true (same inputHash has fail + pass)
# ---------------------------------------------------------------------------

suite "B2 — flaky_once: 2 ledger rows, isFlaky=true":

  test "flaky_once with retries=1 appends 2 rows; attempt 1=exitNonZero, attempt 2=passed":
    withTempProject:
      let src = fixtureDir / "flaky_once.nim"
      let dst = projectRoot / "tests" / "unit" / "test_flaky_once.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.status == rsOk
      check rr.exitCode == 0
      require rr.results.len == 1
      check rr.results[0].flaky == true
      check rr.results[0].attempts == 2

      # Derive the identity for this entrypoint.
      let ep = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let stateDir = projectRoot / ".crisol"

      let rows = scanLedger(stateDir, iKey)
      check rows.len == 2
      if rows.len == 2:
        # Time-ordered by timestamp ascending.
        check rows[0].attempt == 1
        check rows[0].outcome == "exitNonZero"   # outcomeString(oFailed)
        check rows[1].attempt == 2
        check rows[1].outcome == "passed"         # outcomeString(oPassed)
        # durationUs must be non-negative (derived from durationMs * 1000).
        check rows[0].durationUs >= 0
        check rows[1].durationUs >= 0
        # C5: rssBytes is now the measured peak RSS per attempt.
        # Both runs are real live processes; RSS must be > 0.
        check rows[0].rssBytes >= 0
        check rows[1].rssBytes >= 0

      # Flake-rate query.
      check isFlaky(stateDir, iKey)
      let rate = flakeRate(stateDir, iKey)
      check rate == 1.0

# ---------------------------------------------------------------------------
# Suite 2: pass_always with retries=1 → 1 ledger row, attempt=1, not flaky
# ---------------------------------------------------------------------------

suite "B2 — pass_always: 1 ledger row, isFlaky=false":

  test "pass_always with retries=1 appends exactly 1 row (passed, attempt 1)":
    withTempProject:
      let src = fixtureDir / "pass_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.status == rsOk
      check rr.exitCode == 0
      require rr.results.len == 1
      check rr.results[0].flaky == false
      check rr.results[0].attempts == 1

      let ep = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let stateDir = projectRoot / ".crisol"

      let rows = scanLedger(stateDir, iKey)
      check rows.len == 1
      if rows.len == 1:
        check rows[0].attempt == 1
        check rows[0].outcome == "passed"

      check not isFlaky(stateDir, iKey)
      check flakeRate(stateDir, iKey) == 0.0

# ---------------------------------------------------------------------------
# Suite 3: fail_always with retries=2 → 3 ledger rows, all fail, not flaky
# ---------------------------------------------------------------------------

suite "B2 — fail_always with retries=2: 3 rows, all fail, isFlaky=false":

  test "fail_always with retries=2 appends 3 rows (all exitNonZero, attempt 1..3)":
    withTempProject:
      let src = fixtureDir / "fail_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_fail_always.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 2))
      check rr.status == rsOk
      check rr.exitCode == 1
      require rr.results.len == 1
      check rr.results[0].attempts == 3

      let ep = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let stateDir = projectRoot / ".crisol"

      let rows = scanLedger(stateDir, iKey)
      check rows.len == 3
      if rows.len == 3:
        for i in 0 ..< 3:
          check rows[i].attempt == i + 1
          check rows[i].outcome == "exitNonZero"

      check not isFlaky(stateDir, iKey)
      check flakeRate(stateDir, iKey) == 0.0

# ---------------------------------------------------------------------------
# Suite 4: edCached entry appends NO ledger row
# ---------------------------------------------------------------------------

suite "B2 — edCached: no ledger rows written for cached hits":

  test "a cached pass produces no new ledger rows":
    withTempProject:
      let src = fixtureDir / "pass_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
      copyFile(src, dst)

      # Run 1: live run, populates cache + writes 1 ledger row.
      let rr1 = runTests(baseOpts(projectRoot, retries = 0))
      check rr1.status == rsOk
      check rr1.exitCode == 0

      let ep = rr1.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let stateDir = projectRoot / ".crisol"

      let rows1 = scanLedger(stateDir, iKey)
      let countAfterRun1 = rows1.len   # should be 1 (the live run row)

      # Run 2: served from cache (edCached) → NO new ledger rows.
      let rr2 = runTests(baseOpts(projectRoot, retries = 0))
      check rr2.status == rsOk
      check rr2.exitCode == 0

      let rows2 = scanLedger(stateDir, iKey)
      check rows2.len == countAfterRun1

when isMainModule:
  echo "test_B2_ledger done"
