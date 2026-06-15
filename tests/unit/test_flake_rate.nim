## test_flake_rate.nim — B2: pure flake-rate computation tests.
##
## Tests computeFlakeRate purely over synthetic seq[LedgerRow] — no I/O,
## no stateDir required.  These tests are the unit-testable core of B2's
## flakiness metric.
##
## Coverage:
##   1. Empty rows → 0.0
##   2. All-pass, same inputHash → 0.0 (no failures)
##   3. All-fail, same inputHash → 0.0 (no passes — consistent failures are not flaky)
##   4. Mixed pass+fail, same inputHash → 1.0 (1/1 buckets flaky)
##   5. Two inputHashes: one mixed, one all-pass → 0.5 (1/2 buckets)
##   6. "" inputHash bucket: fail+pass with empty inputHash → flaky (1.0)
##   7. "" inputHash bucket: both-fail with empty inputHash → 0.0
##   8. isFlaky / flakeRate wrappers via a real stateDir + scanLedger

import std/[os]
import crisol/types
import crisol/ledger

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeRow(inputHash: string; outcome: string; attempt: int = 1): LedgerRow =
  LedgerRow(
    identity:   IdentityKey("tests/unit/test_x.nim::"),
    timestamp:  1000i64,
    inputHash:  inputHash,
    outcome:    outcome,
    attempt:    attempt,
    durationUs: 5000i64,
    rssBytes:   0i64,
    rowVersion: currentRowVersion,
  )

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_flake_" & name)
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# 1. Empty rows → 0.0
# ---------------------------------------------------------------------------

block test_empty:
  let rate = computeFlakeRate(@[])
  assert rate == 0.0, "empty: expected 0.0, got " & $rate

# ---------------------------------------------------------------------------
# 2. All-pass, same inputHash → 0.0
# ---------------------------------------------------------------------------

block test_all_pass:
  let rows = @[
    makeRow("abc123", "passed", 1),
    makeRow("abc123", "passed", 2),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 0.0, "all-pass: expected 0.0, got " & $rate

# ---------------------------------------------------------------------------
# 3. All-fail, same inputHash → 0.0
# ---------------------------------------------------------------------------

block test_all_fail:
  let rows = @[
    makeRow("abc123", "exitNonZero", 1),
    makeRow("abc123", "exitNonZero", 2),
    makeRow("abc123", "exitNonZero", 3),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 0.0, "all-fail: expected 0.0, got " & $rate

# ---------------------------------------------------------------------------
# 4. Mixed pass+fail, same inputHash → 1.0 (1/1 buckets flaky)
# ---------------------------------------------------------------------------

block test_mixed_same_hash:
  # Typical flaky-once scenario: fail attempt 1, pass attempt 2, same build.
  let rows = @[
    makeRow("abc123", "exitNonZero", 1),
    makeRow("abc123", "passed",      2),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 1.0, "mixed-same-hash: expected 1.0, got " & $rate

# ---------------------------------------------------------------------------
# 5. Two inputHashes: one mixed, one all-pass → 0.5
# ---------------------------------------------------------------------------

block test_two_hashes_one_flaky:
  let rows = @[
    makeRow("hash_A", "exitNonZero", 1),   # hash_A: flaky
    makeRow("hash_A", "passed",      2),
    makeRow("hash_B", "passed",      1),   # hash_B: clean
    makeRow("hash_B", "passed",      1),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 0.5, "two-hashes: expected 0.5, got " & $rate

# ---------------------------------------------------------------------------
# 6. "" inputHash bucket: fail+pass → flaky (1.0)
# ---------------------------------------------------------------------------

block test_empty_hash_mixed:
  # "" inputHash = cache not consulted; still registers as flaky.
  let rows = @[
    makeRow("", "exitNonZero", 1),
    makeRow("", "passed",      2),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 1.0, "empty-hash-mixed: expected 1.0, got " & $rate

# ---------------------------------------------------------------------------
# 7. "" inputHash bucket: both fail → 0.0
# ---------------------------------------------------------------------------

block test_empty_hash_all_fail:
  let rows = @[
    makeRow("", "exitNonZero", 1),
    makeRow("", "exitNonZero", 2),
  ]
  let rate = computeFlakeRate(rows)
  assert rate == 0.0, "empty-hash-all-fail: expected 0.0, got " & $rate

# ---------------------------------------------------------------------------
# 8. isFlaky / flakeRate I/O wrappers with a real stateDir
# ---------------------------------------------------------------------------

block test_io_wrappers:
  let sd = freshStateDir("io_wrappers")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_io.nim::")

  # No rows yet → isFlaky = false, flakeRate = 0.0
  assert not isFlaky(sd, ident), "io: no rows → expected not flaky"
  let r0 = flakeRate(sd, ident)
  assert r0 == 0.0, "io: no rows → expected 0.0, got " & $r0

  # Write fail row then pass row (same inputHash → flaky).
  var led = openLedger(sd)
  let rowFail = LedgerRow(
    identity:   ident,
    timestamp:  1000i64,
    inputHash:  "deadbeef",
    outcome:    "exitNonZero",
    attempt:    1,
    durationUs: 5000i64,
    rssBytes:   0i64,
    rowVersion: currentRowVersion,
  )
  let rowPass = LedgerRow(
    identity:   ident,
    timestamp:  2000i64,
    inputHash:  "deadbeef",
    outcome:    "passed",
    attempt:    2,
    durationUs: 3000i64,
    rssBytes:   0i64,
    rowVersion: currentRowVersion,
  )
  append(led, rowFail)
  append(led, rowPass)
  closeLedger(led)

  assert isFlaky(sd, ident), "io: fail+pass same hash → expected flaky"
  let r1 = flakeRate(sd, ident)
  assert r1 == 1.0, "io: fail+pass same hash → expected 1.0, got " & $r1

when isMainModule:
  echo "test_flake_rate done"
