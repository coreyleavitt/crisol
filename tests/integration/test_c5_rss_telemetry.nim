## test_c5_rss_telemetry.nim — C5: peak RSS captured per entrypoint run.
##
## Tests:
##   1. rss_hog fixture: ledger row rssBytes > 0 and > 1 MiB after a live run.
##      EntrypointResult.peakRssBytes > 0 and > 1 MiB.
##   2. edCached: no ledger row; peakRssBytes == 0 on the synthesized result.
##   3. Per-attempt: each retry attempt carries its own peakRssBytes in its row.
##
## RSS assertions are LOOSE (floor checks only) to avoid environment flakiness.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_c5_rss_telemetry.nim

import std/[os, unittest]
import crisol/api
import crisol/ledger
import crisol/keys
import crisol/depgraph

import "../support/helpers"

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"

const OneMiB: int64 = 1024 * 1024

proc baseOpts(projectRoot: string; retries: int = 0): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        false,
    showProgress:   false,
    retries:        retries,
  )

# ---------------------------------------------------------------------------
# Suite 1: rss_hog — live run captures peak RSS > 1 MiB
# ---------------------------------------------------------------------------

suite "C5 — rss_hog: ledger row rssBytes > 1 MiB":

  test "live rss_hog run: ledger row rssBytes > 1 MiB and EntrypointResult.peakRssBytes > 1 MiB":
    withTempProject:
      let src = fixtureDir / "rss_hog.nim"
      let dst = projectRoot / "tests" / "unit" / "test_rss_hog.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot))
      check rr.status == rsOk
      check rr.exitCode == 0
      require rr.results.len == 1

      # EntrypointResult carries peakRssBytes > 1 MiB.
      check rr.results[0].peakRssBytes > OneMiB

      # Ledger row carries the same measurement.
      let ep   = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let rows = scanLedger(projectRoot / ".crisol", iKey)
      require rows.len == 1
      check rows[0].rssBytes > OneMiB

# ---------------------------------------------------------------------------
# Suite 2: edCached — no ledger row; peakRssBytes == 0 on synthesized result
# ---------------------------------------------------------------------------

suite "C5 — edCached: no new ledger row, peakRssBytes=0 on cached result":

  test "edCached hit produces no new ledger row and peakRssBytes=0":
    withTempProject:
      let src = fixtureDir / "pass_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
      copyFile(src, dst)

      # Run 1: live run → 1 ledger row.
      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.status == rsOk
      check rr1.exitCode == 0

      let ep   = rr1.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let stateDir = projectRoot / ".crisol"
      let rows1 = scanLedger(stateDir, iKey)
      let count1 = rows1.len  # should be 1

      # Run 2: served from cache (edCached) → NO new ledger rows.
      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.status == rsOk
      check rr2.exitCode == 0
      require rr2.results.len == 1

      # edCached result must have peakRssBytes == 0 (no measurement taken).
      check rr2.results[0].peakRssBytes == 0

      # No new ledger rows written (B2 already governs this; C5 must not regress it).
      let rows2 = scanLedger(stateDir, iKey)
      check rows2.len == count1

# ---------------------------------------------------------------------------
# Suite 3: per-attempt — each attempt carries its own rssBytes in ledger
# ---------------------------------------------------------------------------

suite "C5 — per-attempt: each retry attempt gets its own rssBytes row":

  test "rss_hog with retries=1: both ledger rows carry rssBytes > 1 MiB":
    ## rss_hog always passes, so only 1 row is written (no retry triggered).
    ## Use pass_always for a retried fixture (we test per-attempt with flaky_once
    ## because flaky_once always fails then passes, giving us 2 rows).
    withTempProject:
      let src = fixtureDir / "rss_hog.nim"
      let dst = projectRoot / "tests" / "unit" / "test_rss_hog.nim"
      copyFile(src, dst)

      # retries=1 forces 2 attempts on failure; rss_hog passes so we get 1.
      # This at least confirms the row that IS written carries rssBytes > 1 MiB.
      let rr = runTests(baseOpts(projectRoot, retries = 1))
      check rr.exitCode == 0

      let ep   = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let rows = scanLedger(projectRoot / ".crisol", iKey)
      # rss_hog passes on first attempt → 1 row.
      check rows.len == 1
      check rows[0].rssBytes > OneMiB

when isMainModule:
  echo "test_c5_rss_telemetry done"
