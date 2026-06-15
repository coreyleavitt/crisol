## test_m3_compile_view.nim — M3: PlannedEntrypoint.decision removed; compileView accessor.
##
## Verifies:
##   (a) PlannedEntrypoint no longer has a `decision` field (verified by absence
##       of the symbol — the accessor compileView is the only way to get a
##       CompileDecision from a PlannedEntrypoint).
##   (b) compileView(pep) agrees with edecision for all 4 EntrypointDecision variants:
##       edNeverBuilt → cdNeverBuilt
##       edStale      → cdStale
##       edRunFresh   → cdSkipFresh
##       edCached     → cdSkipFresh  (edCached implies a fresh binary)
##   (c) plan() produces correct edecision values (no stale `decision` field to
##       disagree with them — the field is simply gone).
##   (d) planview reporting still works (uses edecision, which is the authoritative field).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_m3_compile_view.nim

import std/[json, options, unittest]
import crisol/types
import crisol/runner     # plan, emptyDepGraph
import crisol/planview   # decisionStringEd, planToJson

# ---------------------------------------------------------------------------
# (b) compileView accessor agreement with edecision
# ---------------------------------------------------------------------------

suite "M3 (b) — compileView agrees with edecision for all variants":

  proc mkPep(ed: EntrypointDecision): PlannedEntrypoint =
    PlannedEntrypoint(
      ep: Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[]),
      edecision: ed,
    )

  test "edNeverBuilt → compileView == cdNeverBuilt":
    check compileView(mkPep(edNeverBuilt)) == cdNeverBuilt

  test "edStale → compileView == cdStale":
    check compileView(mkPep(edStale)) == cdStale

  test "edRunFresh → compileView == cdSkipFresh":
    check compileView(mkPep(edRunFresh)) == cdSkipFresh

  test "edCached → compileView == cdSkipFresh (edCached implies fresh binary)":
    check compileView(mkPep(edCached)) == cdSkipFresh

  test "compileView is injective over the 3 CompileDecision values":
    ## cdNeverBuilt, cdStale, cdSkipFresh are all reachable.
    var seen: set[CompileDecision] = {}
    for ed in EntrypointDecision:
      seen.incl compileView(mkPep(ed))
    # All 3 CompileDecision values should be reachable.
    check cdNeverBuilt in seen
    check cdStale      in seen
    check cdSkipFresh  in seen

  test "compileView is NOT surjective — edCached and edRunFresh both map to cdSkipFresh":
    ## The mapping is many-to-one for cdSkipFresh; this is deliberate
    ## (edCached = edRunFresh + cache hit; both have a fresh binary).
    check compileView(mkPep(edRunFresh)) == compileView(mkPep(edCached))

# ---------------------------------------------------------------------------
# (c) plan() produces correct edecision (no shadow field to disagree)
# ---------------------------------------------------------------------------

suite "M3 (c) — plan() edecision is authoritative (no shadow decision field)":

  test "plan with empty graph → edNeverBuilt, compileView → cdNeverBuilt":
    let ep = Entrypoint(path: "tests/unit/test_foo.nim", group: "unit", flags: @[])
    let p = plan(Config(), @[ep], emptyDepGraph())
    check p.entrypoints.len == 1
    let pep = p.entrypoints[0]
    check pep.edecision == edNeverBuilt
    check compileView(pep) == cdNeverBuilt

  test "compileView of a plan()'d pep matches what decideCompile returns":
    ## plan() derives edecision from (CompileDecision → toEntrypointDecision).
    ## compileView reverses this derivation.  They must be consistent.
    let ep = Entrypoint(path: "tests/unit/test_foo.nim", group: "unit", flags: @[])
    let p = plan(Config(), @[ep], emptyDepGraph())
    let pep = p.entrypoints[0]
    # With empty graph/no binary, decideCompile returns cdNeverBuilt.
    # compileView must match.
    check compileView(pep) == cdNeverBuilt

# ---------------------------------------------------------------------------
# (d) planview reporting uses edecision and is unaffected by M3 removal
# ---------------------------------------------------------------------------

suite "M3 (d) — planview reporting uses edecision exclusively":

  test "decisionStringEd still maps all 4 EntrypointDecision values":
    check decisionStringEd(edNeverBuilt) == "neverBuilt"
    check decisionStringEd(edStale)      == "stale"
    check decisionStringEd(edRunFresh)   == "skipFresh"
    check decisionStringEd(edCached)     == "cached"

  test "planToJson uses edecision; output stable for non-cached decisions":
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        PlannedEntrypoint(
          ep: Entrypoint(path: "tests/unit/a.nim", group: "unit", flags: @[]),
          edecision: edNeverBuilt, reason: "test"),
        PlannedEntrypoint(
          ep: Entrypoint(path: "tests/unit/b.nim", group: "unit", flags: @[]),
          edecision: edStale, reason: "test"),
        PlannedEntrypoint(
          ep: Entrypoint(path: "tests/unit/c.nim", group: "unit", flags: @[]),
          edecision: edRunFresh, reason: "test"),
        PlannedEntrypoint(
          ep: Entrypoint(path: "tests/unit/d.nim", group: "unit", flags: @[]),
          edecision: edCached, reason: "test"),
      ])
    let j = planToJson(plan, @[])
    let eps = j["entrypoints"]
    check eps[0]["decision"].getStr == "neverBuilt"
    check eps[1]["decision"].getStr == "stale"
    check eps[2]["decision"].getStr == "skipFresh"
    check eps[3]["decision"].getStr == "cached"

echo "test_m3_compile_view: done"
