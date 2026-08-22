## test_planview.nim — B6 unit tests for renderPlan + planToJson (pure).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_planview.nim

import std/[json, monotimes, options, os, strutils, unittest]
import crisol/types
import crisol/render
import crisol/planview
# Note: Config import not needed — planToJson no longer takes Config

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkPep(path: string; group: string; d: CompileDecision;
           reason = "r"; runTimeoutMs = 0; maxJobs = none(int)): PlannedEntrypoint =
  ## M3: `decision` field removed; derive edecision from d.
  PlannedEntrypoint(
    ep: Entrypoint(path: path, group: group, flags: @[]),
    reason: reason,
    edecision: (case d
                of cdNeverBuilt: edNeverBuilt
                of cdStale: edStale
                of cdSkipFresh: edRunFresh),
    runTimeoutMs: runTimeoutMs, maxJobs: maxJobs)

proc mkPepEd(path: string; group: string; ed: EntrypointDecision;
             reason = "r"): PlannedEntrypoint =
  ## Build a PlannedEntrypoint by EntrypointDecision directly (A8 — for edCached
  ## which has no CompileDecision counterpart).  M3: `decision` field removed.
  PlannedEntrypoint(
    ep: Entrypoint(path: path, group: group, flags: @[]),
    edecision: ed, reason: reason)

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

  test "decision labels are distinct per variant (Ed variants)":
    ## R2-c: decisionLabel(CompileDecision) removed; use decisionLabelEd.
    check decisionLabelEd(edNeverBuilt) != decisionLabelEd(edStale)
    check decisionLabelEd(edStale) != decisionLabelEd(edRunFresh)
    check decisionLabelEd(edNeverBuilt) != decisionLabelEd(edRunFresh)

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

  test "decision strings are stable enums, not ordinals (Ed variants)":
    ## R2-c: decisionString(CompileDecision) removed; use decisionStringEd.
    check decisionStringEd(edNeverBuilt) == "neverBuilt"
    check decisionStringEd(edStale) == "stale"
    check decisionStringEd(edRunFresh) == "skipFresh"

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

# ---------------------------------------------------------------------------
# A8 — edCached decision, schemaRevision, decision migration to edecision
# ---------------------------------------------------------------------------

suite "planview A8 — edCached + schemaRevision":

  test "plan/v1 carries an integer schemaRevision alongside the schema string":
    let j = planToJson(samplePlan(), sampleGated())
    check j.hasKey("schema")
    check j["schema"].getStr == "crisol/plan/v1"
    check j.hasKey("schemaRevision")
    check j["schemaRevision"].kind == JInt
    check j["schemaRevision"].getInt == PlanV1Revision
    # The current revision is at least 2 (bumped for the additive edCached field).
    check PlanV1Revision >= 2

  test "decisionStringEd maps edCached to stable 'cached' string":
    check decisionStringEd(edNeverBuilt) == "neverBuilt"
    check decisionStringEd(edStale)      == "stale"
    check decisionStringEd(edRunFresh)   == "skipFresh"
    check decisionStringEd(edCached)     == "cached"

  test "decisionLabelEd gives a distinct human label for edCached":
    check decisionLabelEd(edCached) != decisionLabelEd(edRunFresh)
    check decisionLabelEd(edCached) != decisionLabelEd(edNeverBuilt)
    check decisionLabelEd(edCached) != decisionLabelEd(edStale)
    check "cached" in decisionLabelEd(edCached).toLowerAscii

  test "plan/v1 decision string reflects edCached when promoted":
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPepEd("tests/unit/test_cached.nim", "unit", edCached),
      ])
    let j = planToJson(plan, @[])
    check j["entrypoints"][0]["decision"].getStr == "cached"

  test "plan/v1 decision strings for non-cached entries stay stable":
    ## Migration to edecision must not change output for the existing decisions.
    let j = planToJson(samplePlan(), sampleGated())
    let eps = j["entrypoints"]
    check eps[0]["decision"].getStr == "neverBuilt"
    check eps[1]["decision"].getStr == "stale"
    check eps[2]["decision"].getStr == "skipFresh"

  test "renderPlan shows a cached label for an edCached entrypoint":
    let plan = RunPlan(
      jobs: 1,
      entrypoints: @[
        mkPepEd("tests/unit/test_cached.nim", "unit", edCached),
      ])
    let s = renderPlan(plan, @[], RenderOpts(color: false, slowestN: 5))
    check "tests/unit/test_cached.nim" in s
    check "cached" in s.toLowerAscii

  test "issue #10: a leg's row shows its effective flags between group and decision":
    ## The same path under two groups with different flags is two legs; the
    ## human listing must let a reader tell them apart without consulting the
    ## config, so each row carries the leg's effective flags (in compile order)
    ## after the group.  Rows with no flags keep the original two-column form.
    var legA = mkPep("tests/unit/test_probe.nim", "unit-a", cdNeverBuilt)
    legA.ep.flags = @["-d:common", "-d:legA"]
    var legB = mkPep("tests/unit/test_probe.nim", "unit-b", cdStale)
    legB.ep.flags = @["-d:common", "-d:legB"]
    let plan = RunPlan(jobs: 1, entrypoints: @[
      legA, legB, mkPep("tests/unit/test_plain.nim", "unit", cdSkipFresh)])
    let s = renderPlan(plan, @[], RenderOpts(color: false, slowestN: 5))
    check "  tests/unit/test_probe.nim  [unit-a]  -d:common -d:legA  never built (would compile)\n" in s
    check "  tests/unit/test_probe.nim  [unit-b]  -d:common -d:legB  would compile\n" in s
    check "  tests/unit/test_plain.nim  [unit]  binary fresh — would skip compile\n" in s

  test "renderPlan human output for non-cached decisions stays stable":
    let s = renderPlan(samplePlan(), sampleGated(),
                       RenderOpts(color: false, slowestN: 5))
    check "never built (would compile)" in s
    check "would compile" in s
    check "binary fresh — would skip compile" in s

# ---------------------------------------------------------------------------
# A8 — loadLastPlan forward/backward tolerance (symmetric with loadLastRun)
# ---------------------------------------------------------------------------

suite "planview A8 — loadLastPlan tolerance":

  proc uniqueTmpDir(tag: string): string =
    getTempDir() / ("crisol_pv_" & tag & "_" & $getMonoTime().ticks)

  proc makeCfg(projectRoot, stateDir: string): Config =
    Config(projectRoot: projectRoot, stateDir: stateDir, groups: @[],
           jobs: 1, timeoutSecs: 30, compileTimeoutSecs: 60,
           maxOutputBytes: 65536)

  test "absent lastplan.json → found=false, supported=true (cold start)":
    let tmpDir = uniqueTmpDir("absent")
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    let lp = loadLastPlan(makeCfg(tmpDir, ".crisol"))
    check lp.found == false
    check lp.supported == true

  test "old plan doc without schemaRevision is tolerated (found, supported)":
    let tmpDir   = uniqueTmpDir("old")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    # No schemaRevision, no edCached fields — an old document.
    let doc = """{"schema":"crisol/plan/v1","jobs":1,"entrypoints":[],"gatedOut":[]}"""
    writeFile(tmpDir / stateDir / "lastplan.json", doc)
    let lp = loadLastPlan(makeCfg(tmpDir, stateDir))
    check lp.found == true
    check lp.supported == true

  test "new plan doc with schemaRevision == CURRENT is tolerated":
    let tmpDir   = uniqueTmpDir("cur")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    let doc = planToJsonString(samplePlan(), sampleGated())
    writeFile(tmpDir / stateDir / "lastplan.json", doc)
    let lp = loadLastPlan(makeCfg(tmpDir, stateDir))
    check lp.found == true
    check lp.supported == true

  test "schemaRevision > CURRENT_MAX is safe cold-start (found=false, supported=false)":
    let tmpDir   = uniqueTmpDir("future")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    let doc = """{"schema":"crisol/plan/v1","schemaRevision":9999,"jobs":1,"entrypoints":[],"gatedOut":[]}"""
    writeFile(tmpDir / stateDir / "lastplan.json", doc)
    let lp = loadLastPlan(makeCfg(tmpDir, stateDir))
    # Treated as no-data: a future crisol wrote it; we cannot trust the fields.
    check lp.found == false
    check lp.supported == false

  test "wrong schema string raises CrisolError(cekEnvironment)":
    let tmpDir   = uniqueTmpDir("badschema")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    writeFile(tmpDir / stateDir / "lastplan.json",
              """{"schema":"crisol/plan/v99","entrypoints":[]}""")
    var raised = false
    try: discard loadLastPlan(makeCfg(tmpDir, stateDir))
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
    check raised
