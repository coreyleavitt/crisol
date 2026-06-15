## stats.nim — C6: shared statistical primitives (extracted from shard.nim / order.nim)
##
## Provides:
##   median*(vals: seq[int64]): int64
##     Median of a non-empty seq[int64].  Even-length sequences return the
##     integer mean of the two middle elements: (sorted[mid-1] + sorted[mid]) div 2,
##     computed overflow-safely as sorted[mid-1] + (sorted[mid] - sorted[mid-1]) div 2.
##     Odd-length sequences return sorted[mid] unchanged.  Empty input → 0.
##
##   mad*(vals: seq[int64]; med: int64): int64
##     Median Absolute Deviation: median(|xi - med|) over `vals`.
##     Empty input → 0.
##
##   RegressionVerdict* = object
##     regressed*:    bool    ## true iff currentUs > thresholdUs AND sampleFloor met
##     baselineUs*:   int64   ## the median of historyUs (0 when suppressed)
##     thresholdUs*:  int64   ## median + k·MAD floored (0 when suppressed)
##
##   isRegression*(currentUs, historyUs, k, sampleFloor, absFloorMs): RegressionVerdict
##     Pure perf-regression predicate.  Never reads the clock or disk.
##     Algorithm:
##       1. sampleFloor suppression: historyUs.len < sampleFloor → regressed=false.
##       2. med  = median(historyUs)  [true statistical median; even-N = mean of middle pair].
##       3. madUs = max(median(|xi - med|), absFloorMs * 1000).
##          (MAD-zero floor: a perfectly stable test must not trip on scheduler noise.)
##       4. thresholdUs = med + int64(k * float(madUs)).
##       5. regressed = currentUs > thresholdUs.

import std/algorithm

# ---------------------------------------------------------------------------
# median — single exported shared copy (replaces shard.nim + order.nim copies)
# ---------------------------------------------------------------------------

proc median*(vals: seq[int64]): int64 =
  ## Return the true statistical median of a non-empty seq[int64].
  ## Odd-length:  sorted[mid] where mid = len div 2.
  ## Even-length: integer mean of the two middle elements, computed
  ##              overflow-safely as lo + (hi - lo) div 2, where
  ##              lo = sorted[mid-1], hi = sorted[mid], mid = len div 2.
  ## Empty input → 0.
  if vals.len == 0:
    return 0'i64
  var sorted = vals
  sorted.sort()
  let mid = sorted.len div 2
  if (sorted.len and 1) == 1:
    # Odd length: exact middle element.
    sorted[mid]
  else:
    # Even length: mean of the two central elements, overflow-safe.
    let lo = sorted[mid - 1]
    let hi = sorted[mid]
    lo + (hi - lo) div 2

# ---------------------------------------------------------------------------
# mad — median absolute deviation
# ---------------------------------------------------------------------------

proc mad*(vals: seq[int64]; med: int64): int64 =
  ## Median Absolute Deviation of `vals` relative to `med`.
  ## Returns 0 for empty input.
  if vals.len == 0:
    return 0'i64
  var deviations = newSeqOfCap[int64](vals.len)
  for v in vals:
    deviations.add abs(v - med)
  median(deviations)

# ---------------------------------------------------------------------------
# RegressionVerdict
# ---------------------------------------------------------------------------

type
  RegressionVerdict* = object
    ## Result of isRegression.
    regressed*:   bool    ## true iff currentUs > thresholdUs AND sampleFloor met
    baselineUs*:  int64   ## median of historyUs (0 when sampleFloor not met)
    thresholdUs*: int64   ## median + k·MAD-floored (0 when sampleFloor not met)

# ---------------------------------------------------------------------------
# isRegression — pure perf-regression predicate
# ---------------------------------------------------------------------------

proc isRegression*(
  currentUs:   int64;
  historyUs:   seq[int64];
  k:           float;
  sampleFloor: int;
  absFloorMs:  int;
): RegressionVerdict =
  ## Pure perf-regression predicate.  No I/O.
  ##
  ## Parameters:
  ##   currentUs   — wall-clock duration of the current run in microseconds.
  ##   historyUs   — prior runs' durations in microseconds (EXCLUDING current run).
  ##   k           — multiplier on MAD (higher → fewer flags, lower → more sensitive).
  ##   sampleFloor — minimum number of history rows required to flag; below
  ##                 this threshold the verdict is always regressed=false.
  ##   absFloorMs  — minimum MAD in milliseconds (converted to µs internally).
  ##                 Prevents perfectly-stable tests from tripping on tiny jitter.
  ##
  ## Algorithm:
  ##   1. If historyUs.len < sampleFloor → regressed=false (insufficient data).
  ##   2. med     = median(historyUs).
  ##   3. madRaw  = median(|xi - med| for xi in historyUs).
  ##   4. madUs   = max(madRaw, absFloorMs * 1000)  ← MAD-zero floor.
  ##   5. threshold = med + int64(k * float(madUs)).
  ##   6. regressed = currentUs > threshold.

  # Step 1: sample-floor suppression.
  if historyUs.len < sampleFloor:
    return RegressionVerdict(regressed: false, baselineUs: 0'i64, thresholdUs: 0'i64)

  # Step 2: baseline.
  let med = median(historyUs)

  # Step 3: raw MAD.
  let madRaw = mad(historyUs, med)

  # Step 4: MAD-zero floor (convert absFloorMs → µs).
  let absFloorUs = int64(absFloorMs) * 1000'i64
  let madUs = max(madRaw, absFloorUs)

  # Step 5: threshold.
  let threshold = med + int64(k * float(madUs))

  # Step 6: verdict.
  RegressionVerdict(
    regressed:   currentUs > threshold,
    baselineUs:  med,
    thresholdUs: threshold,
  )
