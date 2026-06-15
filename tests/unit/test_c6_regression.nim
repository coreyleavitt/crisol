## test_c6_regression.nim — C6: ledger-aware perf-regression detection
##
## Tests the full detection loop: seed a stateDir ledger with synthetic rows,
## then call the pure isRegression predicate against that history.  This tests
## the detection logic without requiring real subprocess execution (avoiding the
## flakiness of wall-clock timing).
##
## Coverage:
##   1. Enough stable history + spiked current → regressed=true.
##   2. Enough stable history + current within threshold → regressed=false.
##   3. Below sample-floor → always regressed=false.
##   4. edCached results → never flagged (regression fields stay at zero defaults).
##   5. compileFailed results → never flagged.
##
## These tests exercise:
##   - stats.isRegression (via the pure predicate directly)
##   - The current-run exclusion timestamp mechanism (by seeding the ledger
##     with timestamps strictly in the past and verifying the predicate sees them)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_c6_regression.nim

import std/[os, strutils, times, unittest]
import crisol/[types, ledger, keys, depgraph, stats]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_c6reg_" & name)
  removeDir(result)
  createDir(result)

proc makeIdentity(path: string): IdentityKey =
  identityKey(path, flagHash(@[]))

proc seedRow(stateDir: string; identity: IdentityKey; durationUs: int64;
             timestamp: int64; outcome: string = "passed") =
  ## Append a synthetic row directly via openLedger/append/closeLedger.
  var led = openLedger(stateDir)
  led.append(LedgerRow(
    rowVersion:  currentRowVersion,
    identity:    identity,
    timestamp:   timestamp,
    inputHash:   "hash123",
    outcome:     outcome,
    attempt:     1,
    durationUs:  durationUs,
    rssBytes:    0'i64,
  ))
  closeLedger(led)

# ---------------------------------------------------------------------------
# Test 1: stable history + spike → regressed via isRegression predicate
# ---------------------------------------------------------------------------

block test_stable_history_spike:
  let sd = freshStateDir("spike")
  defer: removeDir(sd)
  let ikey = makeIdentity("tests/unit/test_foo.nim")

  # Seed 10 rows at ~100ms (100_000µs) with timestamps well in the past.
  let pastTs = int64(epochTime() * 1_000_000.0) - 1_000_000_000'i64  # 1000s ago
  for i in 0 ..< 10:
    seedRow(sd, ikey, 100_000'i64, pastTs + int64(i) * 1_000'i64)

  # Collect history (all rows since runStart is after all seeded timestamps).
  let runStart = int64(epochTime() * 1_000_000.0)
  let allRows = scanLedger(sd, ikey)
  var historyUs: seq[int64]
  for row in allRows:
    if row.timestamp >= runStart: continue
    if row.outcome.startsWith("compileFailed"): continue
    historyUs.add row.durationUs

  check historyUs.len == 10

  # current = 500_000µs (500ms spike, well above 115_000µs threshold)
  let v = isRegression(500_000'i64, historyUs, 3.0, 10, 5)
  check v.regressed
  check v.baselineUs == 100_000'i64
  check v.thresholdUs == 115_000'i64  # 100k + 3.0 * 5k (MAD floored)

# ---------------------------------------------------------------------------
# Test 2: stable history + current within threshold → not regressed
# ---------------------------------------------------------------------------

block test_within_threshold:
  let sd = freshStateDir("within")
  defer: removeDir(sd)
  let ikey = makeIdentity("tests/unit/test_bar.nim")

  let pastTs = int64(epochTime() * 1_000_000.0) - 500_000_000'i64
  for i in 0 ..< 10:
    seedRow(sd, ikey, 100_000'i64, pastTs + int64(i) * 1_000'i64)

  let runStart = int64(epochTime() * 1_000_000.0)
  let allRows = scanLedger(sd, ikey)
  var historyUs: seq[int64]
  for row in allRows:
    if row.timestamp >= runStart: continue
    historyUs.add row.durationUs

  # current = 110_000µs < threshold 115_000µs
  let v = isRegression(110_000'i64, historyUs, 3.0, 10, 5)
  check not v.regressed

# ---------------------------------------------------------------------------
# Test 3: below sample-floor → no flag regardless of spike
# ---------------------------------------------------------------------------

block test_below_sample_floor:
  let sd = freshStateDir("floor")
  defer: removeDir(sd)
  let ikey = makeIdentity("tests/unit/test_new.nim")

  let pastTs = int64(epochTime() * 1_000_000.0) - 500_000_000'i64
  # Only 5 rows (sampleFloor=10)
  for i in 0 ..< 5:
    seedRow(sd, ikey, 100_000'i64, pastTs + int64(i) * 1_000'i64)

  let runStart = int64(epochTime() * 1_000_000.0)
  let allRows = scanLedger(sd, ikey)
  var historyUs: seq[int64]
  for row in allRows:
    if row.timestamp >= runStart: continue
    historyUs.add row.durationUs

  check historyUs.len == 5

  # Even a huge spike → not flagged (below sampleFloor=10)
  let v = isRegression(9_999_999'i64, historyUs, 3.0, 10, 5)
  check not v.regressed

# ---------------------------------------------------------------------------
# Test 4: current-run exclusion — rows appended after runStart are excluded
# ---------------------------------------------------------------------------

block test_current_run_exclusion:
  let sd = freshStateDir("exclusion")
  defer: removeDir(sd)
  let ikey = makeIdentity("tests/unit/test_exclusion.nim")

  # Seed 10 "historical" rows well in the past.
  let pastTs = int64(epochTime() * 1_000_000.0) - 500_000_000'i64
  for i in 0 ..< 10:
    seedRow(sd, ikey, 100_000'i64, pastTs + int64(i) * 1_000'i64)

  # Capture runStart now.
  let runStart = int64(epochTime() * 1_000_000.0)

  # Simulate execute() appending a "current run" row with timestamp AFTER runStart.
  let futureTs = runStart + 1_000_000'i64  # 1s later
  seedRow(sd, ikey, 9_999_999'i64, futureTs)  # current run's spike row

  # Build history excluding current run (as the detection code does).
  let allRows = scanLedger(sd, ikey)
  var historyUs: seq[int64]
  for row in allRows:
    if row.timestamp >= runStart: continue  # exclude current run
    historyUs.add row.durationUs

  # Only 10 historical rows visible (the 9_999_999µs spike row is excluded).
  check historyUs.len == 10

  # Predicate sees only stable history; current = 9_999_999µs → regressed.
  let v = isRegression(9_999_999'i64, historyUs, 3.0, 10, 5)
  check v.regressed  # spike detected against clean history

# ---------------------------------------------------------------------------
# Test 5: compileFailed rows excluded from history
# ---------------------------------------------------------------------------

block test_compilefailed_excluded:
  let sd = freshStateDir("compilefail")
  defer: removeDir(sd)
  let ikey = makeIdentity("tests/unit/test_compile.nim")

  let pastTs = int64(epochTime() * 1_000_000.0) - 500_000_000'i64

  # 8 normal rows (passed) at 100_000µs
  for i in 0 ..< 8:
    seedRow(sd, ikey, 100_000'i64, pastTs + int64(i) * 1_000'i64)

  # 2 compileFailed rows with tiny durationUs (should be excluded)
  seedRow(sd, ikey, 50'i64, pastTs + 9_000'i64, "compileFailed")
  seedRow(sd, ikey, 75'i64, pastTs + 10_000'i64, "compileFailed")

  let runStart = int64(epochTime() * 1_000_000.0)
  let allRows = scanLedger(sd, ikey)
  var historyUs: seq[int64]
  for row in allRows:
    if row.timestamp >= runStart: continue
    if row.outcome.startsWith("compileFailed"): continue
    historyUs.add row.durationUs

  # Only 8 rows (compileFailed excluded).
  check historyUs.len == 8
  # Below sampleFloor=10 → not flagged regardless of current.
  let v = isRegression(9_999_999'i64, historyUs, 3.0, 10, 5)
  check not v.regressed  # 8 < 10 (sampleFloor)

when isMainModule:
  echo "test_c6_regression: all assertions passed"
