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
import crisol/types            # r41: CacheDecision/cvOk
import crisol/cachetelemetry   # r41: notConsultedDecisions — documents the wire-level gap

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

# ---------------------------------------------------------------------------
# Suite 6: r41 — a retried compiling entry's finalizing attempt never itself
# re-consults; the runner-side cache fields it stamps must stay honest, and
# the residual wire-level ambiguity this pins is a documented BLOCKER (the
# coherent close requires jsonout.nim/cachetelemetry.nim, owned elsewhere).
# ---------------------------------------------------------------------------

suite "r41 — a retried compiling entry stamps honest (not fabricated) cache fields":

  test "flaky_once passes on attempt 2: inputHash/cacheLookup stay at their honest zero value, never a stale/fabricated one":
    withTempProject:
      # Caching is ACTIVE by default (api.RunOptions.noCache defaults false).
      let src = fixtureDir / "flaky_once.nim"
      let dst = projectRoot / "tests" / "unit" / "test_flaky_once.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].attempts == 2   # failed attempt 1, passed attempt 2

      # SO3 (runner.nim finalizeSlot): `consultPostCompile` only runs on
      # `attempt == 1` — attempt 1's real consult is discarded (never copied
      # into the reporting arrays) because attempt 1 was a RETRY, not a
      # finalize; attempt 2 (the one that actually finalizes) never consults
      # at all. So the honest state for the FINALIZING attempt is "not
      # really consulted": inputHash stays "", and (r41 fix, runner.nim's
      # `handleChildExited`) `cacheLookup` is only ever stamped from the
      # `lookups[]` array when `inputHash` backs it — here it does not, so
      # `cacheLookup` is left at its Nim zero value `cvOk`, never a
      # leftover/fabricated verdict.
      check rr.results[0].inputHash == ""
      check rr.results[0].cacheLookup == cvOk
      # `cacheDecision` still honestly reports WHY this pass wasn't cached
      # (cdmFlaky: RFC-0004 F3's own M8 distinction, real/intended
      # information this fix must NOT destroy) — the runner-side fields are
      # each individually honest.
      check rr.results[0].cacheDecision == cdmFlaky

      # r41 BLOCKER (documented, not fixed here): `cdmFlaky` is NOT in
      # `notConsultedDecisions` (jsonout.nim's presence gate is keyed
      # SOLELY on `cacheDecision` membership in that set — see its own
      # comment, "cacheLookup: PRESENT only when the cache was actually
      # consulted (cacheDecision not in notConsultedDecisions)"), so the
      # `--json` wire output for THIS exact result still emits a bare
      # `"cacheLookup": "ok"` (cvOk's wire string) next to `"cacheDecision":
      # "flaky"` — indistinguishable on the wire from a genuine hit, even
      # though runner.nim now provably never fabricates the in-memory
      # value. This assertion pins the ROOT CAUSE precisely: cdmFlaky (and,
      # by the same reasoning, a retry-exhausted cdmKeyMiss) can be reached
      # with zero backing consult, which `notConsultedDecisions`'s three-
      # member set does not account for. Closing this for real means either
      # widening `notConsultedDecisions` (cachetelemetry.nim) or gating
      # jsonout's presence check on more than `cacheDecision` alone
      # (jsonout.nim) — both outside runner.nim/render.nim's remit; see the
      # r41 blocker note in this fix's handoff.
      check cdmFlaky notin cachetelemetry.notConsultedDecisions

when isMainModule:
  echo "test_B1_retry done"
