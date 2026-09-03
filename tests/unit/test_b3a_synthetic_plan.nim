## test_b3a_synthetic_plan.nim — RFC-0005 B3a: --verify-cache synthetic plan.
##
## `buildVerifyPlan` builds a `RunPlan` directly from the sampled subset of
## an already-planned run's `PlannedEntrypoint` values (RFC-0005 §Stage B
## "Synthetic plan, not a re-`plan()`"): no re-discovery, no depgraph
## mutation/save — just jobs=1 and pep.retries=0 on the sampled entries, in
## the order the sample indices were given.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_b3a_synthetic_plan.nim

import crisol/types
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pep(path: string; retries: int): PlannedEntrypoint =
  PlannedEntrypoint(
    ep: Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: edRunFresh,
    reason: "cached",
    retries: retries,
  )

# ---------------------------------------------------------------------------
# 1. shape: jobs = 1, retries reset to 0, entrypoints subset in index order
# ---------------------------------------------------------------------------

block test_shape:
  let plan = @[
    pep("tests/unit/test_a.nim", retries = 3),
    pep("tests/unit/test_b.nim", retries = 2),
    pep("tests/unit/test_c.nim", retries = 5),
    pep("tests/unit/test_d.nim", retries = 1),
  ]
  let indices = @[0, 2]

  let vp = buildVerifyPlan(plan, indices)

  assert vp.jobs == 1, "synthetic plan must run jobs=1 for determinism"
  assert vp.entrypoints.len == 2, "synthetic plan must contain exactly the sampled subset"
  assert vp.entrypoints[0].ep.path == "tests/unit/test_a.nim"
  assert vp.entrypoints[1].ep.path == "tests/unit/test_c.nim"
  for e in vp.entrypoints:
    assert e.retries == 0, "verify pass must set pep.retries = 0 (single attempt, no masking of flakiness)"

# ---------------------------------------------------------------------------
# 2. original plan is untouched (pure — no mutation of the input seq)
# ---------------------------------------------------------------------------

block test_no_mutation_of_source:
  let plan = @[pep("tests/unit/test_a.nim", retries = 3)]
  let vp = buildVerifyPlan(plan, @[0])
  assert plan[0].retries == 3, "buildVerifyPlan must not mutate the caller's PlannedEntrypoint seq"
  assert vp.entrypoints[0].retries == 0

# ---------------------------------------------------------------------------
# 3. non-retries fields carried through unchanged (edecision, cacheable, ep)
# ---------------------------------------------------------------------------

block test_fields_preserved:
  var p = pep("tests/unit/test_a.nim", retries = 4)
  p.cacheable = csTrue
  let vp = buildVerifyPlan(@[p], @[0])
  assert vp.entrypoints[0].edecision == edRunFresh
  assert vp.entrypoints[0].cacheable == csTrue
  assert vp.entrypoints[0].ep.path == "tests/unit/test_a.nim"

# ---------------------------------------------------------------------------
# 4. empty sample -> empty synthetic plan (still jobs = 1)
# ---------------------------------------------------------------------------

block test_empty_sample:
  let plan = @[pep("tests/unit/test_a.nim", retries = 1)]
  let vp = buildVerifyPlan(plan, @[])
  assert vp.entrypoints.len == 0
  assert vp.jobs == 1

echo "test_b3a_synthetic_plan: OK"
