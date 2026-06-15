## planview.nim — B6 PLAN-phase rendering (crisol list / run --dry-run)
##
## A single pure rendering path shared by `crisol list` and `run --dry-run`.
## Neither command compiles nor runs anything: they render the output of the
## pure pipeline (discover → applyGates → plan) so the user can inspect WHAT
## would run and HOW each entrypoint would be compiled, before trusting it.
##
## Public API:
##
##   GatedEntry* = tuple[path: string; group: string; reason: string]
##     One discovered-but-gated-out entrypoint with its gate reason.
##
##   renderPlan*(plan: RunPlan; gatedOut: seq[GatedEntry]; opts: RenderOpts): string
##     Pure: human-readable plan listing.  One line per planned entrypoint
##     (path + group + compile-decision label), a gated-out section (path +
##     group + reason), and a summary (N entrypoints across M groups, K gated).
##     Color is injected via opts.color — renderPlan performs no I/O.
##
##   planToJson*(plan: RunPlan; gatedOut: seq[GatedEntry];
##              warnings: seq[ConfigWarning] = @[]): JsonNode
##     Pure: the crisol/plan/v1 document with stable decision strings.
##     S2a/S3: runTimeoutMs and maxJobs are precomputed on PlannedEntrypoint.
##
##   planToJsonString*(plan: RunPlan; gatedOut: seq[GatedEntry];
##                    warnings: seq[ConfigWarning] = @[]): string
##     Pure: compact JSON string of the crisol/plan/v1 document.
##
## Decision labels (human).  A8: reporting reads the single sealed sum
## `edecision` (EntrypointDecision) so `edCached` is representable; the three
## non-cached labels are byte-identical to the legacy CompileDecision labels:
##   edNeverBuilt -> "never built (would compile)"
##   edStale      -> "would compile"
##   edRunFresh   -> "binary fresh — would skip compile"
##   edCached     -> "cached — would skip compile and run"
##
## Decision strings (JSON, stable):
##   edNeverBuilt -> "neverBuilt"
##   edStale      -> "stale"
##   edRunFresh   -> "skipFresh"
##   edCached     -> "cached"
##
## A8 also adds an integer `schemaRevision` (PlanV1Revision) alongside the
## `schema` string, and `loadLastPlan` — a forward/backward-tolerant reader
## symmetric with jsonout.loadLastRun.

import std/[json, options, os, sets]
import crisol/[types, render]

# GatedEntry is defined in types.nim and re-exported from there.

# ---------------------------------------------------------------------------
# Schema-version constant (single source of truth)
# ---------------------------------------------------------------------------

const PlanV1Schema* = "crisol/plan/v1"
  ## Stable schema identifier embedded in every crisol/plan/v1 JSON document.
  ## Import crisol/api (or crisol/planview directly) to reference this constant
  ## rather than duplicating the string literal.

const PlanV1Revision* = 2
  ## Integer minor revision of the crisol/plan/v1 schema (A8).  Additive only:
  ## the `schema` STRING stays "crisol/plan/v1"; this integer is bumped each time
  ## additive optional fields land so a consumer can gate on feature presence
  ## (`schemaRevision >= 2`) without substring-parsing.  Current = max known.
  ##   rev 1 (implicit) — original B6 fields.
  ##   rev 2           — edCached decision string ("cached") representable.
  ## A reader seeing `schemaRevision > PlanV1Revision` treats the file as
  ## no-data (safe cold-start) — it was written by a newer crisol.

# ---------------------------------------------------------------------------
# Stable string / label mappings
# ---------------------------------------------------------------------------

# R2-c: decisionLabel(CompileDecision) and decisionString(CompileDecision) removed —
# dead code since M3; all production call sites use the Ed variants below.
# compileView(pep) still exists in types.nim (live callers: test_plan.nim,
# test_m3_compile_view.nim); it is retained there.

# A8: the plan/run decision is the single sealed sum EntrypointDecision; the
# legacy CompileDecision view cannot represent edCached.  Reporting reads
# `edecision` so "cached" is expressible.  The non-cached strings/labels are
# kept identical to the (removed) CompileDecision mapping so output stays byte-stable.

proc decisionStringEd*(d: EntrypointDecision): string =
  ## Stable JSON enum string for an EntrypointDecision (A8).  Identical to
  ## decisionString for the three non-cached variants; adds "cached" for edCached.
  case d
  of edNeverBuilt: "neverBuilt"
  of edStale:      "stale"
  of edRunFresh:   "skipFresh"
  of edCached:     "cached"

proc decisionLabelEd*(d: EntrypointDecision): string =
  ## Human-readable plan label for an EntrypointDecision (A8).  The three
  ## non-cached labels match decisionLabel exactly; edCached gets its own.
  case d
  of edNeverBuilt: "never built (would compile)"
  of edStale:      "would compile"
  of edRunFresh:   "binary fresh — would skip compile"
  of edCached:     "cached — would skip compile and run"

# ---------------------------------------------------------------------------
# renderPlan — PURE
# ---------------------------------------------------------------------------

proc renderPlan*(plan: RunPlan; gatedOut: seq[GatedEntry];
                 opts: RenderOpts): string =
  ## Pure: human-readable rendering of the PLAN phase.  No I/O.
  ## Color is emitted iff opts.color.
  let color = opts.color

  var buf = newStringOfCap(2048)

  # 1. Planned entrypoints — one line each.
  var groups: HashSet[string]
  if plan.entrypoints.len > 0:
    buf.add col("Planned entrypoints:", Ansi_Bold, color) & "\n"
    for pep in plan.entrypoints:
      groups.incl pep.ep.group
      # A8: render off `edecision` (the single sealed sum) so edCached is
      # representable.  Colors: yellow = will compile; green = no compile;
      # cyan = fully cached (skips both compile and run).
      let lbl = decisionLabelEd(pep.edecision)
      let labelCol =
        case pep.edecision
        of edNeverBuilt: col(lbl, Ansi_Yellow, color)
        of edStale:      col(lbl, Ansi_Yellow, color)
        of edRunFresh:   col(lbl, Ansi_Green, color)
        of edCached:     col(lbl, Ansi_Cyan, color)
      buf.add "  " & pep.ep.path &
              col("  [" & pep.ep.group & "]", Ansi_Dim, color) &
              "  " & labelCol & "\n"
  else:
    buf.add col("Planned entrypoints: none", Ansi_Dim, color) & "\n"

  # 2. Gated-out entrypoints — one line each, WITH the reason.
  if gatedOut.len > 0:
    buf.add "\n" & col("Gated out (will not run):", Ansi_Bold, color) & "\n"
    for g in gatedOut:
      buf.add "  " & g.path &
              col("  [" & g.group & "]", Ansi_Dim, color) &
              "  " & col("gate-skip: " & g.reason, Ansi_Yellow, color) & "\n"

  # 3. Summary.
  buf.add "\n"
  let summary =
    $plan.entrypoints.len & " entrypoint(s) across " &
    $groups.len & " group(s), " &
    $gatedOut.len & " gated out"
  buf.add col(summary, Ansi_Dim, color) & "\n"

  result = buf

# ---------------------------------------------------------------------------
# planToJson — PURE
# ---------------------------------------------------------------------------

proc warningsToJsonArray*(warns: seq[ConfigWarning]): JsonNode =
  ## Serialize a seq[ConfigWarning] to a JSON array (the "warnings" field shape).
  result = newJArray()
  for w in warns:
    let wNode = newJObject()
    wNode["source"]  = newJString(w.source)
    wNode["context"] = newJString(w.context)
    wNode["key"]     = newJString(w.key)
    wNode["message"] = newJString(w.message)
    result.add wNode

proc planToJson*(plan: RunPlan; gatedOut: seq[GatedEntry];
                 warnings: seq[ConfigWarning] = @[]): JsonNode =
  ## Pure: serialize the PLAN phase to the crisol/plan/v1 JsonNode.  No I/O.
  ##
  ## S2a/S3: runTimeoutMs and maxJobs are precomputed fields on PlannedEntrypoint
  ## (set by plan() in planner.nim); no config parameter needed here.

  let entrypointsNode = newJArray()
  for pep in plan.entrypoints:
    let epNode = newJObject()
    epNode["path"]         = newJString(pep.ep.path)
    epNode["group"]        = newJString(pep.ep.group)
    epNode["decision"]     = newJString(decisionStringEd(pep.edecision))
    epNode["reason"]       = newJString(pep.reason)
    epNode["runTimeoutMs"] = newJInt(pep.runTimeoutMs)
    # S3: emit maxJobs; null when the group has no cap.
    if pep.maxJobs.isSome:
      epNode["maxJobs"] = newJInt(pep.maxJobs.get)
    else:
      epNode["maxJobs"] = newJNull()
    entrypointsNode.add epNode

  let gatedNode = newJArray()
  for g in gatedOut:
    let gNode = newJObject()
    gNode["path"]   = newJString(g.path)
    gNode["group"]  = newJString(g.group)
    gNode["reason"] = newJString(g.reason)
    gatedNode.add gNode

  result = newJObject()
  result["schema"]         = newJString(PlanV1Schema)
  result["schemaRevision"] = newJInt(PlanV1Revision)  # A8: additive minor revision
  result["jobs"]           = newJInt(plan.jobs)
  result["entrypoints"]    = entrypointsNode
  result["gatedOut"]       = gatedNode
  result["warnings"]       = warningsToJsonArray(warnings)

proc planToJsonString*(plan: RunPlan; gatedOut: seq[GatedEntry];
                       warnings: seq[ConfigWarning] = @[]): string =
  ## Pure: compact JSON string of the crisol/plan/v1 document.
  $planToJson(plan, gatedOut, warnings)

# ---------------------------------------------------------------------------
# loadLastPlan — A8: forward/backward-tolerant plan reader
# ---------------------------------------------------------------------------
#
# Symmetric counterpart to jsonout.loadLastRun.  The RFC (§Schemas) requires
# loadLastRun AND loadLastPlan to tolerate old+new documents and to treat
# `schemaRevision > CURRENT_MAX` as a safe cold-start (no data) with a warning.
#
# Plans are not yet persisted by any crisol command (plan JSON only goes to
# stdout); this reader exists so a future plan-cache consumer inherits the same
# tolerance contract loadLastRun already provides, and so the over-revision
# cold-start rule is enforced symmetrically across both schemas TODAY.  It reads
# the conventional path <projectRoot>/<stateDir>/lastplan.json; an absent file is
# a normal cold-start (found=false, supported=true).

proc loadLastPlan*(config: Config):
    tuple[found: bool; supported: bool] =
  ## Read <projectRoot>/<stateDir>/lastplan.json with forward/backward tolerance.
  ##
  ## Returns:
  ##   (found: false, supported: true)  — file absent: normal cold-start.
  ##   (found: true,  supported: true)  — file parsed and within CURRENT_MAX.
  ##   (found: false, supported: false) — schemaRevision > PlanV1Revision: a
  ##        FUTURE crisol wrote it; treat as no-data (safe cold-start) and warn.
  ##
  ## Raises CrisolError(cekEnvironment) if the file exists but is malformed JSON
  ## or carries an unrecognized `schema` string — symmetric with loadLastRun.
  let path = config.projectRoot / config.stateDir / "lastplan.json"

  if not fileExists(path):
    return (found: false, supported: true)

  var raw: string
  try:
    raw = readFile(path)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "could not read lastplan.json: " & e.msg)

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    raise newCrisolError(cekEnvironment,
      "lastplan.json is malformed JSON: " & e.msg &
      " — run `crisol list` first")

  if node.kind != JObject or not node.hasKey("schema"):
    raise newCrisolError(cekEnvironment,
      "lastplan.json is missing 'schema' field — run `crisol list` first")
  let schemaVal = node["schema"].getStr("")
  if schemaVal != PlanV1Schema:
    raise newCrisolError(cekEnvironment,
      "stale lastplan.json (schema '" & schemaVal &
      "') — run `crisol list` first")

  # Forward tolerance: an absent schemaRevision is an old (rev-1) document and is
  # fully readable.  A revision GREATER than what we know is from a future crisol
  # whose additive fields we cannot interpret — treat as no-data (cold-start).
  let rev = node.getOrDefault("schemaRevision").getInt(0)
  if rev > PlanV1Revision:
    stderr.write("crisol: warning: lastplan.json schemaRevision " & $rev &
                 " is newer than this crisol understands (max " &
                 $PlanV1Revision & "); ignoring it as cold-start\n")
    return (found: false, supported: false)

  (found: true, supported: true)
