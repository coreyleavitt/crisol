## test_b3a_sampler.nim — RFC-0005 B3a: pure --verify-cache sampler.
##
## `sampleHitIndices` is the seeded, deterministic selection basis for the
## --verify-cache post-run pass (B3b): given the parallel seq of
## EntrypointResult.cacheDecision values for a run, pick a sample of the
## indices whose decision is cdmHit, sized max(1, pct*hits/100), whenever
## pct > 0 and the hit set is non-empty.
##
## Coverage (RFC-0005 Stage B "--verify-cache" + B3a bullet):
##   1. determinism: same (decisions, pct, seed) -> same sample.
##   2. pct scaling: sample size tracks pct*hits/100.
##   3. max(1, ...) floor: a tiny/rounds-to-zero sample still yields 1.
##   4. empty hit set -> empty sample, regardless of pct.
##   5. pct <= 0 -> empty sample, even with hits present.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_b3a_sampler.nim

import std/algorithm
import crisol/types

# ---------------------------------------------------------------------------
# 1. determinism: same seed -> same sample
# ---------------------------------------------------------------------------

block test_determinism:
  let decisions = @[cdmHit, cdmHit, cdmHit, cdmHit, cdmHit,
                     cdmHit, cdmHit, cdmHit, cdmHit, cdmHit]  # 10 hits
  let s1 = sampleHitIndices(decisions, pct = 50, seed = 42'i64)
  let s2 = sampleHitIndices(decisions, pct = 50, seed = 42'i64)
  assert s1 == s2, "same (decisions, pct, seed) must yield the same sample"
  assert s1.len == 5, "50% of 10 hits should sample 5, got " & $s1.len

  # a different seed is not REQUIRED to differ, but the whole vector must
  # still be drawn from the hit set and honor the sample size.
  let s3 = sampleHitIndices(decisions, pct = 50, seed = 7'i64)
  assert s3.len == 5

# ---------------------------------------------------------------------------
# 2. pct scaling
# ---------------------------------------------------------------------------

block test_pct_scaling:
  var decisions: seq[CacheDecision]
  for i in 0 ..< 20: decisions.add cdmHit  # 20 hits

  let s10 = sampleHitIndices(decisions, pct = 10, seed = 1'i64)
  assert s10.len == 2, "10% of 20 hits should sample 2, got " & $s10.len

  let s50 = sampleHitIndices(decisions, pct = 50, seed = 1'i64)
  assert s50.len == 10, "50% of 20 hits should sample 10, got " & $s50.len

  let s100 = sampleHitIndices(decisions, pct = 100, seed = 1'i64)
  assert s100.len == 20, "100% of 20 hits should sample all 20, got " & $s100.len

# ---------------------------------------------------------------------------
# 3. max(1, ...) floor
# ---------------------------------------------------------------------------

block test_max1_floor:
  # a single hit at any pct > 0 always samples exactly that one entry.
  let oneHit = @[cdmHit]
  let s = sampleHitIndices(oneHit, pct = 5, seed = 99'i64)
  assert s == @[0], "single-hit set at pct=5 should still sample the 1 hit, got " & $s

  # pct*hits/100 rounds to 0 (5*3/100 == 0) but the floor forces 1.
  let threeHits = @[cdmHit, cdmHit, cdmHit]
  let s3 = sampleHitIndices(threeHits, pct = 5, seed = 3'i64)
  assert s3.len == 1, "5% of 3 hits rounds to 0; the max(1, ...) floor must force 1, got " & $s3.len

# ---------------------------------------------------------------------------
# 4. empty hit set -> empty sample
# ---------------------------------------------------------------------------

block test_empty_hit_set:
  let decisions = @[cdmKeyMiss, cdmStored, cdmGroupOptOut]  # no cdmHit anywhere
  let s = sampleHitIndices(decisions, pct = 100, seed = 1'i64)
  assert s.len == 0, "no hits in the run -> sample must be empty, got " & $s

# ---------------------------------------------------------------------------
# 5. pct <= 0 -> empty sample even with hits present
# ---------------------------------------------------------------------------

block test_pct_zero_disables:
  let decisions = @[cdmHit, cdmHit, cdmHit]
  let s0 = sampleHitIndices(decisions, pct = 0, seed = 1'i64)
  assert s0.len == 0, "pct=0 must disable sampling regardless of hits, got " & $s0
  let sNeg = sampleHitIndices(decisions, pct = -5, seed = 1'i64)
  assert sNeg.len == 0, "negative pct must disable sampling, got " & $sNeg

# ---------------------------------------------------------------------------
# 6. sample indices always index into the actual hit set, ascending
# ---------------------------------------------------------------------------

block test_indices_are_valid_hits_ascending:
  let decisions = @[cdmHit, cdmKeyMiss, cdmHit, cdmStored, cdmHit, cdmHit]
  # hit indices are {0, 2, 4, 5}
  let s = sampleHitIndices(decisions, pct = 100, seed = 11'i64)
  var sorted = s
  sorted.sort()
  assert s == sorted, "returned indices must be ascending"
  for i in s:
    assert decisions[i] == cdmHit, "sampled index " & $i & " is not a hit"
  assert s == @[0, 2, 4, 5], "pct=100 must sample the entire hit set, got " & $s

echo "test_b3a_sampler: OK"
