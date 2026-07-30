## expectations.nim — golden_reuse fixture's pinned closed-form expectations
## (RFC-0006 M-golden-fixture — the measurement's own test oracle).
##
## This module records, as consts, what a human hand-verified about the REAL
## compiler output committed under `generated/ep_a/` and `generated/ep_b/`:
## which reusable-set basenames are byte-identical across both entrypoints
## (after the fixed 4-line per-slot header is stripped) versus which one is
## genuinely ORC-tailored (differs even after stripping), plus each unit's
## real committed byte size. `test_golden_reuse.nim` re-derives these facts
## independently from the committed files and asserts they match — so this
## module is not "trust me", it is a pinned prediction the test checks.
##
## ## Why this is a CURATED subset, not the full real reusable set
##
## `ep_a.json`/`ep_b.json` are the REAL, UNMODIFIED nimcache manifests — the
## real reusable set (everything `parseCompileManifest` returns minus the
## entry unit) also includes `@psystem.nim.c` and `@psystem@sexceptions.nim.c`
## (confirmed real, byte-identical-after-strip across ep_a/ep_b when this
## fixture was generated — see `docs/rfc/0006-...` M-golden-fixture slice
## report). Their content is deliberately NOT committed (186KB/15KB — the
## slice's "keep it small" constraint) since the four basenames below already
## exercise every assertion this oracle needs: a genuinely shared vendor C
## file, a genuinely shared small stdlib module, and a genuinely ORC-tailored
## module. `test_golden_reuse.nim` still asserts the FULL real reusable set
## (from the untouched JSON) is a strict superset of this curated set, so the
## curation is visible and honest, not silently narrowing the manifest.
##
## ## Synthetic cc-time weights
##
## RFC-0006's `r_time` is **cc-time-weighted**, but committing real cc
## timings would be non-reproducible (machine-dependent) and is not needed
## to prove the CONCEPT (the closed-form arithmetic, and that r_time and
## r_size are genuinely different computations that can diverge). So
## `ccWeightUs` below is a deliberately synthetic, deterministic per-basename
## weight ("as-if" cc microseconds) — NOT measured, and NOT proportional to
## byte size: the tailored unit (`@mfixture_substrate.nim.c`, under 1/5th of
## the curated set's bytes) is assigned HALF the total weight, so `r_time`
## and `r_size` diverge (0.5 vs ~0.82, computed in the test — see
## `expectedRSize`/`expectedRTime` below). This is the exact trap RFC-0006's
## Motivation section names: a size-weighted ratio can answer a different
## question than a time-weighted one. Real per-unit cc timing is
## `compiledriver.CcUnitResult.ccTimeUs` (M-driver, already built); this
## fixture just needs *a* weight to make the r_time arithmetic closed-form.

import std/[sequtils, tables]

const
  ## The entry unit's basename for each entrypoint (`@m<entrypointBasename>.
  ## nim.c` per RFC-0006 §File scoping) — excluded from the reusable set.
  entryBasenameA* = "@mep_a.nim.c"
  entryBasenameB* = "@mep_b.nim.c"

  ## Real basenames present in the manifest's reusable set that this fixture
  ## does NOT commit `.c` content for (see module doc above) — used only to
  ## assert the full real reusable set is a strict superset of the curated
  ## set below, never to read file content.
  uncommittedRealReusableBasenames* = [
    "@psystem.nim.c",
    "@psystem@sexceptions.nim.c",
  ]

  ## Curated reusable-set basenames this oracle commits `.c` content for and
  ## verifies. Present in BOTH ep_a.json and ep_b.json (same manifest shape
  ## for both — only @mfixture_substrate.nim.c's CONTENT differs).
  sharedIdenticalBasenames* = [
    "fixture.c",                            # vendor {.compile.} C source —
                                             # literally the same file on
                                             # disk for both entrypoints.
    "@pstd@sprivate@sdigitsutils.nim.c",    # small real stdlib module,
                                             # identical after header-strip.
    "@psystem@sdollars.nim.c",              # ditto.
  ]
  ## The ORC-tailored unit: same basename, same source module, but ep_a
  ## reaches only `substrateA` and ep_b reaches only `substrateB` (verified:
  ## `grep`'d symbol names in the committed .c differ per entrypoint), so
  ## the generated .c differs even after header-strip.
  tailoredBasenames* = ["@mfixture_substrate.nim.c"]

  ## Real, committed byte sizes for the curated set. `test_golden_reuse.nim`
  ## asserts these match `getFileSize` on the actual committed files — this
  ## table is a pinned prediction, not an assumption.
  sizeBytes* = {
    "fixture.c": 247,
    "@pstd@sprivate@sdigitsutils.nim.c": 5589,
    "@psystem@sdollars.nim.c": 3301,
    "@mfixture_substrate.nim.c": 1964,
  }.toTable

  ## Synthetic per-unit cc-time weights — see module doc above.
  ccWeightUs* = {
    "fixture.c": 20,
    "@pstd@sprivate@sdigitsutils.nim.c": 100,
    "@psystem@sdollars.nim.c": 80,
    "@mfixture_substrate.nim.c": 200,
  }.toTable

# ---------------------------------------------------------------------------
# Closed-form r_size / r_time, derived purely from the tables above.
#
# Both ratios are computed the same way: sum the per-unit quantity (bytes or
# weight) over BOTH entrypoints' reusable sets (bytesTotal/weightTotal), vs.
# the subset of that sum contributed by basenames in `sharedIdenticalBasenames`
# (bytesShared/weightShared) — every reusable unit is counted once per
# entrypoint that carries a copy of it, matching RFC-0006's "artifactsTotal /
# artifactsShared ... derived from the raw counts" idiom (M-report).
# ---------------------------------------------------------------------------

proc sumWeights(basenames: openArray[string]; weights: Table[string, int]): int =
  for b in basenames:
    result += weights[b]

const
  reusableBasenamesAll = sharedIdenticalBasenames.toSeq & tailoredBasenames.toSeq

  bytesPerEntrypointTotal*  = sumWeights(reusableBasenamesAll, sizeBytes)
  bytesPerEntrypointShared* = sumWeights(sharedIdenticalBasenames, sizeBytes)

  weightPerEntrypointTotal*  = sumWeights(reusableBasenamesAll, ccWeightUs)
  weightPerEntrypointShared* = sumWeights(sharedIdenticalBasenames, ccWeightUs)

  ## Two entrypoints -> every reusable unit is compiled twice; the shared
  ## ones twice with identical content, the tailored one twice with
  ## divergent content. Both count toward the total; only the shared ones
  ## count toward the numerator.
  bytesTotalAll*  = bytesPerEntrypointTotal * 2
  bytesSharedAll* = bytesPerEntrypointShared * 2

  weightTotalAll*  = weightPerEntrypointTotal * 2
  weightSharedAll* = weightPerEntrypointShared * 2

  expectedRSize* = bytesSharedAll.float / bytesTotalAll.float
  expectedRTime* = weightSharedAll.float / weightTotalAll.float
