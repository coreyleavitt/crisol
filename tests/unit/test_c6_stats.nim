## test_c6_stats.nim — C6: unit tests for stats.nim (median, mad, isRegression)
##
## Coverage:
##   median:
##     1. Empty → 0
##     2. Single element → itself
##     3. Odd count → middle element
##     4. Even count → TRUE statistical median = mean of two middle elements (integer div)
##        (was "lower middle element" — corrected in M2 fix; old upper-middle assertions removed)
##
##   mad:
##     5. Empty → 0
##     6. All same value → 0 (MAD of a constant sequence)
##     7. Diverse values — verify by hand
##
##   isRegression:
##     8.  Below sample-floor → regressed=false regardless of spike
##     9.  Stable history + well-within-threshold → regressed=false
##     10. Stable history + spike beyond threshold → regressed=true
##     11. MAD-zero floor: perfectly stable history, tiny jitter within absFloor → regressed=false
##     12. MAD-zero floor: perfectly stable history, big spike above floored threshold → regressed=true
##     13. Exactly at threshold → regressed=false (strictly greater, not >=)
##     14. One above threshold → regressed=true
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_c6_stats.nim

import crisol/stats

# ---------------------------------------------------------------------------
# median
# ---------------------------------------------------------------------------

block test_median_empty:
  assert median(@[]) == 0'i64, "empty seq → 0"

block test_median_single:
  assert median(@[42'i64]) == 42'i64, "single element → itself"

block test_median_odd:
  # Sorted: [1, 3, 5, 7, 9]; middle = index 2 = 5
  assert median(@[9'i64, 1'i64, 5'i64, 3'i64, 7'i64]) == 5'i64, "odd count → middle"

block test_median_even:
  # M2 fix: true statistical median = mean of the two middle elements (integer div).
  # Sorted: [1, 2, 3, 4]; mid=2; (sorted[1]+sorted[2]) div 2 = (2+3) div 2 = 2.
  # OLD (upper-middle, WRONG): sorted[2] = 3. This assertion is RED before the fix.
  assert median(@[4'i64, 1'i64, 3'i64, 2'i64]) == 2'i64, "even 4-element → true median (2+3)/2 = 2"

block test_median_even2:
  # M2 fix: [10, 20] → (10+20) div 2 = 15.
  # OLD (upper-middle, WRONG): sorted[1] = 20. This assertion is RED before the fix.
  assert median(@[20'i64, 10'i64]) == 15'i64, "even 2-element → true median (10+20)/2 = 15"

# ---------------------------------------------------------------------------
# mad
# ---------------------------------------------------------------------------

block test_mad_empty:
  assert mad(@[], 0'i64) == 0'i64, "empty → 0"

block test_mad_constant:
  # All same value → all deviations = 0 → mad = 0
  let v = @[100'i64, 100'i64, 100'i64]
  assert mad(v, median(v)) == 0'i64, "constant seq → mad 0"

block test_mad_diverse:
  # vals = [1, 3, 5, 7, 9], median = 5
  # deviations = |1-5|=4, |3-5|=2, |5-5|=0, |7-5|=2, |9-5|=4
  # sorted deviations = [0, 2, 2, 4, 4]; median index 2 = 2
  let v = @[1'i64, 3'i64, 5'i64, 7'i64, 9'i64]
  let med = median(v)
  assert med == 5'i64, "diverse median"
  assert mad(v, med) == 2'i64, "diverse mad = 2"

# ---------------------------------------------------------------------------
# isRegression
# ---------------------------------------------------------------------------

block test_below_sample_floor:
  # 5 history rows but sampleFloor=10 → no flag.
  let hist = @[1000'i64, 1100'i64, 1200'i64, 1050'i64, 1150'i64]
  let v = isRegression(
    currentUs   = 9_000_000'i64,  # absurd spike — doesn't matter
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert not v.regressed, "below sampleFloor → regressed=false"
  assert v.baselineUs == 0'i64, "below sampleFloor → baselineUs=0"
  assert v.thresholdUs == 0'i64, "below sampleFloor → thresholdUs=0"

block test_within_threshold:
  # Stable history around 100_000 µs.
  # median = 100_000, mad = 0, floored to absFloor = 5*1000=5_000
  # threshold = 100_000 + 3.0 * 5_000 = 115_000
  # current = 110_000 < 115_000 → not regressed
  let hist = @[100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 110_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert not v.regressed, "within threshold → regressed=false"
  assert v.baselineUs == 100_000'i64, "baseline = median"
  assert v.thresholdUs == 115_000'i64, "threshold = 100_000 + 3.0*5_000"

block test_spike_beyond_threshold:
  # Same stable history; spike to 200_000 → exceeds threshold 115_000.
  let hist = @[100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 200_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert v.regressed, "spike → regressed=true"
  assert v.baselineUs == 100_000'i64, "baseline = median"
  assert v.thresholdUs == 115_000'i64, "threshold = 100_000 + 3.0*5_000"

block test_mad_zero_floor_tiny_jitter:
  # Perfectly stable at 50_000 µs.  absFloorMs=5 → floor=5_000µs.
  # threshold = 50_000 + 3.0 * 5_000 = 65_000
  # current = 60_000 < 65_000 → not regressed.
  let hist = @[50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64,
               50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64]
  let v = isRegression(
    currentUs   = 60_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert not v.regressed, "MAD-zero floor: tiny jitter → not regressed"

block test_mad_zero_floor_big_spike:
  # Perfectly stable at 50_000 µs; big spike to 200_000.
  # threshold = 65_000; 200_000 > 65_000 → regressed.
  let hist = @[50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64,
               50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64, 50_000'i64]
  let v = isRegression(
    currentUs   = 200_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert v.regressed, "MAD-zero floor: big spike → regressed=true"

block test_exactly_at_threshold:
  # current == threshold → NOT regressed (strict >).
  # Stable at 100_000; threshold = 115_000; current = 115_000.
  let hist = @[100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 115_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert not v.regressed, "exactly at threshold → regressed=false (strict >)"

block test_one_above_threshold:
  # current = threshold + 1 → regressed.
  let hist = @[100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64, 100_000'i64, 100_000'i64,
               100_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 115_001'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert v.regressed, "one above threshold → regressed=true"

block test_noisy_history:
  # M2 fix: 10-element history → even-length true median = mean of middle pair.
  # hist µs: 80k, 90k, 95k, 100k, 105k, 110k, 120k, 85k, 95k, 100k
  # Sorted: 80k, 85k, 90k, 95k, 95k, 100k, 100k, 105k, 110k, 120k
  # len=10, mid=5; true median = (sorted[4]+sorted[5]) div 2 = (95k+100k) div 2 = 97500
  # deviations from 97500:
  #   |80k-97500|=17500, |85k-97500|=12500, |90k-97500|=7500, |95k-97500|=2500,
  #   |95k-97500|=2500, |100k-97500|=2500, |100k-97500|=2500, |105k-97500|=7500,
  #   |110k-97500|=12500, |120k-97500|=22500
  # sorted deviations (10-element even): 2500,2500,2500,2500,7500,7500,12500,12500,17500,22500
  # MAD (even) = (sorted[4]+sorted[5]) div 2 = (7500+7500) div 2 = 7500
  # absFloor = 5ms = 5k; max(7500, 5000) = 7500
  # threshold = 97500 + 3.0*7500 = 97500 + 22500 = 120000
  # current = 125k > 120k → REGRESSED (M2 fix changes this verdict from false to true)
  let hist = @[80_000'i64, 90_000'i64, 95_000'i64, 100_000'i64, 105_000'i64,
               110_000'i64, 120_000'i64, 85_000'i64, 95_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 125_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert v.regressed, "noisy history: 125k > 120k threshold → regressed (M2 fix: true median 97500)"
  assert v.baselineUs == 97_500'i64, "noisy: baseline = true median 97500"
  assert v.thresholdUs == 120_000'i64, "noisy: threshold = 97500 + 3.0*7500 = 120000"

block test_noisy_history_spike:
  # Same history; spike to 200k > 120k → regressed (unchanged by M2 fix).
  let hist = @[80_000'i64, 90_000'i64, 95_000'i64, 100_000'i64, 105_000'i64,
               110_000'i64, 120_000'i64, 85_000'i64, 95_000'i64, 100_000'i64]
  let v = isRegression(
    currentUs   = 200_000'i64,
    historyUs   = hist,
    k           = 3.0,
    sampleFloor = 10,
    absFloorMs  = 5,
  )
  assert v.regressed, "noisy history spike: 200k > 120k → regressed"

echo "test_c6_stats: all assertions passed"
