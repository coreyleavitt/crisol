## test_planview.nim — B6 unit tests for renderPlan + planToJson (pure).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_planview.nim

import std/[json, options, strutils, unittest]
import crisol/types
import crisol/render
import crisol/planview
# Note: Config import not needed — planToJson no longer takes Config

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkPep(path: string; group: string; d: CompileDecision;
           reason = "r"; runTimeoutMs = 0; maxJobs = none(int)): PlannedEntrypoint =
  PlannedEntrypoint(
    ep: Entrypoint(path: path, group: group, flags: @[]),
    decision: d, reason: reason,
    runTimeoutMs: runTimeoutMs, maxJobs: maxJobs)

proc samplePlan(): RunPlan =
  RunPlan(
    jobs: 4,
    entrypoints: @[
      mkPep("tests/unit/test_a.nim", "unit", cdNeverBuilt),
      mkPep("tests/unit/test_b.nim", "unit", cdStale),
      mkPep("tests/integration/test_c.nim", "integration", cdSkipFresh),
    ])

proc sampleGated(): seq[GatedEntry] =
  @[("tests/smoke/test_relay.nim", "smoke",
     "env AMOXTLI_OPENROUTER_API_KEY not set").GatedEntry]

# ---------------------------------------------------------------------------
# renderPlan
# ---------------------------------------------------------------------------

suite "renderPlan — pure human listing":

  test "lists each entrypoint path, group, and the right decision label":
    let opts = RenderOpts(color: false, slowestN: 5)
    let s = renderPlan(samplePlan(), sampleGated(), opts)

    # paths present
    check "tests/unit/test_a.nim" in s
    check "tests/unit/test_b.nim" in s
    check "tests/integration/test_c.nim" in s

    # groups present
    check "[unit]" in s
    check "[integration]" in s

    # distinct decision labels (RFC wording)
    check "never built (would compile)" in s
    check "would compile" in s
    check "binary fresh — would skip compile" in s

  test "decision labels are distinct per variant":
    check decisionLabel(cdNeverBuilt) != decisionLabel(cdStale)
    check decisionLabel(cdStale) != decisionLabel(cdSkipFresh)
    check decisionLabel(cdNeverBuilt) != decisionLabel(cdSkipFresh)

  test "gated-out entries appear WITH their reason":
    let opts = RenderOpts(color: false, slowestN: 5)
    let s = renderPlan(samplePlan(), sampleGated(), opts)
    check "tests/smoke/test_relay.nim" in s
    check "[smoke]" in s
    check "env AMOXTLI_OPENROUTER_API_KEY not set" in s

  test "summary reports entrypoint / group / gated counts":
    let opts = RenderOpts(color: false, slowestN: 5)
    let s = renderPlan(samplePlan(), sampleGated(), opts)
    # 3 entrypoints across 2 groups (unit, integration), 1 gated out
    check "3 entrypoint(s) across 2 group(s), 1 gated out" in s

  test "color off → no ANSI escapes; color on → escapes present":
    let plain = renderPlan(samplePlan(), sampleGated(),
                           RenderOpts(color: false, slowestN: 5))
    let colored = renderPlan(samplePlan(), sampleGated(),
                             RenderOpts(color: true, slowestN: 5))
    check "\e[" notin plain
    check "\e[" in colored

  test "empty plan with no gated entries → zero counts, no crash":
    let s = renderPlan(RunPlan(jobs: 1, entrypoints: @[]), @[],
                       RenderOpts(color: false))
    check "0 entrypoint(s) across 0 group(s), 0 gated out" in s

# ---------------------------------------------------------------------------
# planToJson
# ---------------------------------------------------------------------------

suite "planToJson — versioned stable schema":

  test "schema is crisol/plan/v1":
    let j = planToJson(samplePlan(), sampleGated())
    check j["schema"].getStr == "crisol/plan/v1"

  test "entrypoints array has correct length and stable decision strings":
    let j = planToJson(samplePlan(), sampleGated())
    let eps = j["entrypoints"]
    check eps.len == 3
    check eps[0]["path"].getStr == "tests/unit/test_a.nim"
    check eps[0]["group"].getStr == "unit"
    check eps[0]["decision"].getStr == "neverBuilt"
    check eps[1]["decision"].getStr == "stale"
    check eps[2]["decision"].getStr == "skipFresh"

  test "gatedOut array has correct length and a reason on each entry":
    let j = planToJson(samplePlan(), sampleGated())
    let g = j["gatedOut"]
    check g.len == 1
    check g[0]["path"].getStr == "tests/smoke/test_relay.nim"
    check g[0]["group"].getStr == "smoke"
    check g[0]["reason"].getStr == "env AMOXTLI_OPENROUTER_API_KEY not set"

  test "decision strings are stable enums, not ordinals":
    check decisionString(cdNeverBuilt) == "neverBuilt"
    check decisionString(cdStale) == "stale"
    check decisionString(cdSkipFresh) == "skipFresh"

  test "round-trips: planToJsonString parses back to identical structure":
    let s = planToJsonString(samplePlan(), sampleGated())
    let j = parseJson(s)
    check j["schema"].getStr == "crisol/plan/v1"
    check j["entrypoints"].len == 3
    check j["gatedOut"].len == 1

  test "plan/v1 has a top-level warnings array (empty when no warnings)":
    let j = planToJson(samplePlan(), sampleGated())
    check j.hasKey("warnings")
    check j["warnings"].kind == JArray
    check j["warnings"].len == 0

  test "plan/v1 warnings array carries ConfigWarning fields":
    let warn = ConfigWarning(
      source:  "/path/to/crisol.kdl",
      context: "top-level",
      key:     "timeout-sec",
      message: "unknown config key 'timeout-sec' in top-level (ignored)",
    )
    let j = planToJson(samplePlan(), sampleGated(), @[warn])
    check j["warnings"].len == 1
    let w = j["warnings"][0]
    check w["source"].getStr  == "/path/to/crisol.kdl"
    check w["context"].getStr == "top-level"
    check w["key"].getStr     == "timeout-sec"
    check "timeout-sec" in w["message"].getStr

  test "plan/v1 each entrypoint carries runTimeoutSecs (ms) field":
    ## S2a: planToJson exposes the precomputed runTimeoutMs per entrypoint.
    ## The built-in default (300_000 ms) is set by planner.plan() when both
    ## ep.runTimeoutSecs and config.timeoutSecs are 0.
    ## Here we create the PlannedEntrypoint directly with runTimeoutMs: 300_000.
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPep("tests/unit/test_a.nim", "unit", cdNeverBuilt,
              runTimeoutMs = 300_000),
      ])
    let j = planToJson(plan, @[])
    check j["entrypoints"][0].hasKey("runTimeoutMs")
    check j["entrypoints"][0]["runTimeoutMs"].getInt == 300_000

  test "plan/v1 runTimeoutMs reflects ep-level timeout when set":
    ## planToJson uses the precomputed runTimeoutMs; 42_000 = 42 secs * 1000.
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPep("tests/unit/test_a.nim", "unit", cdNeverBuilt,
              runTimeoutMs = 42_000),
      ])
    let j = planToJson(plan, @[])
    check j["entrypoints"][0]["runTimeoutMs"].getInt == 42_000

  test "plan/v1 runTimeoutMs reflects global config timeout when ep is 0":
    ## planToJson uses the precomputed runTimeoutMs; 120_000 = 120 secs * 1000.
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPep("tests/unit/test_a.nim", "unit", cdNeverBuilt,
              runTimeoutMs = 120_000),
      ])
    let j = planToJson(plan, @[])
    check j["entrypoints"][0]["runTimeoutMs"].getInt == 120_000

  test "plan/v1 each entrypoint carries maxJobs field (S3)":
    ## When a group has max-jobs set, the entrypoint's maxJobs is that int.
    ## When absent (none), maxJobs is null in the JSON.
    let plan = RunPlan(
      jobs: 4,
      entrypoints: @[
        mkPep("tests/unit/test_a.nim", "serial", cdNeverBuilt,
              maxJobs = some(1)),
        mkPep("tests/unit/test_b.nim", "free", cdNeverBuilt,
              maxJobs = none(int)),
      ])
    let j = planToJson(plan, @[])
    let eps = j["entrypoints"]
    # serial group → maxJobs is 1
    check eps[0].hasKey("maxJobs")
    check eps[0]["maxJobs"].kind == JInt
    check eps[0]["maxJobs"].getInt == 1
    # free group → maxJobs is null
    check eps[1].hasKey("maxJobs")
    check eps[1]["maxJobs"].kind == JNull

  test "plan/v1 maxJobs is null when group not present in config":
    ## Entrypoints with maxJobs: none(int) emit null in the JSON.
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPep("tests/unit/test_a.nim", "unit", cdNeverBuilt,
              maxJobs = none(int)),
      ])
    let j = planToJson(plan, @[])
    check j["entrypoints"][0]["maxJobs"].kind == JNull
