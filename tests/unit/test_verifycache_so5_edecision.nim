## test_verifycache_so5_edecision.nim — RFC-0005 code-review SO5:
## buildVerifyPlan forces edRunFresh on every sampled entry.
##
## Companion to tests/unit/test_b3a_synthetic_plan.nim (which is NOT
## touched here -- see this fix's file allowlist), pinning the SPECIFIC
## mechanism SO5's fix relies on: `buildVerifyPlan` must dispatch every
## sampled entry through `execute()`'s `spawnRunDirect` path (reuse the
## already-promoted stable binary), never `spawnCompileStable` (a real
## recompile whose finalizeSlot unconditionally persists the depgraph via
## recordClosure/saveDepGraph -- forbidden during a diagnostic-only verify
## pass). `execute()`'s own dispatch is a plain
## `if pep.edecision == edRunFresh: spawnRunDirect else: spawnCompileStable`
## (runner.nim, unchanged by this fix) -- so pinning `edecision ==
## edRunFresh` on buildVerifyPlan's OUTPUT, regardless of the INPUT
## PlannedEntrypoint's own edecision, is a complete, precise, deterministic
## proof of the fix: it is now compile-time-obviously impossible for a
## sampled entry to reach spawnCompileStable at all.
##
## Why this matters specifically for `edNeverBuilt`/`edStale` inputs: a
## `cdmHit` sampled by `sampleHitIndices` can come from `finalizeSlot`'s
## POST-COMPILE cache consult (RFC-0005 A2c-ii), not just a plan-time hit --
## and a post-compile-consult-originated hit's `PlannedEntrypoint.edecision`
## is genuinely `edNeverBuilt`/`edStale` at plan time (that is WHY the
## consult had to run: the plan didn't know about the hit until after
## compiling). Before this fix, buildVerifyPlan carried that value through
## UNCHANGED, so `execute()`'s dispatch sent such an entry through
## `spawnCompileStable` in the verify sub-run -- a genuine, unwanted
## recompile.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_verifycache_so5_edecision.nim

import crisol/types
import crisol/runner

proc pep(path: string; edecision: EntrypointDecision): PlannedEntrypoint =
  PlannedEntrypoint(
    ep: Entrypoint(path: path, group: "unit", flags: @[]),
    edecision: edecision,
    reason: "cached",
    retries: 2,
  )

# ---------------------------------------------------------------------------
# 1. Every EntrypointDecision input forces edRunFresh on output.
# ---------------------------------------------------------------------------

block test_forces_edrunfresh_regardless_of_input:
  for d in [edNeverBuilt, edStale, edRunFresh, edCached]:
    let plan = @[pep("tests/unit/test_a.nim", d)]
    let vp = buildVerifyPlan(plan, @[0])
    assert vp.entrypoints.len == 1
    assert vp.entrypoints[0].edecision == edRunFresh,
      "buildVerifyPlan must force edRunFresh for edecision=" & $d &
      " (SO5: never dispatch a sampled entry through spawnCompileStable)"

# ---------------------------------------------------------------------------
# 2. The specific SO5 trigger case: a post-compile-consult-originated hit
#    (edNeverBuilt/edStale at plan time) still comes out edRunFresh, AND the
#    caller's own PlannedEntrypoint (the "live" plan/report) is untouched --
#    buildVerifyPlan's existing purity contract, unaffected by this fix.
# ---------------------------------------------------------------------------

block test_post_compile_consult_case_purity_preserved:
  let plan = @[pep("tests/unit/test_cold.nim", edNeverBuilt)]
  let vp = buildVerifyPlan(plan, @[0])
  assert vp.entrypoints[0].edecision == edRunFresh
  assert plan[0].edecision == edNeverBuilt,
    "buildVerifyPlan must never mutate the caller's own PlannedEntrypoint seq"

echo "test_verifycache_so5_edecision: OK"
