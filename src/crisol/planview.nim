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
##   planToJson*(plan: RunPlan; gatedOut: seq[GatedEntry]): JsonNode
##     Pure: the crisol/plan/v1 document with stable decision strings.
##
##   planToJsonString*(plan: RunPlan; gatedOut: seq[GatedEntry]): string
##     Pure: compact JSON string of the crisol/plan/v1 document.
##
## Compile-decision labels (human, per RFC line ~290):
##   cdNeverBuilt -> "never built (would compile)"
##   cdStale      -> "would compile"
##   cdSkipFresh  -> "binary fresh — would skip compile"
##
## Compile-decision strings (JSON, stable):
##   cdNeverBuilt -> "neverBuilt"
##   cdStale      -> "stale"
##   cdSkipFresh  -> "skipFresh"

import std/[json, sets]
import crisol/[types, render]

# GatedEntry is defined in types.nim and re-exported from there.

# ---------------------------------------------------------------------------
# Stable string / label mappings
# ---------------------------------------------------------------------------

proc decisionLabel*(d: CompileDecision): string =
  ## Human-readable plan label for a compile decision (RFC wording, distinct
  ## per variant).
  case d
  of cdNeverBuilt: "never built (would compile)"
  of cdStale:      "would compile"
  of cdSkipFresh:  "binary fresh — would skip compile"

proc decisionString*(d: CompileDecision): string =
  ## Stable JSON enum string for a compile decision.
  case d
  of cdNeverBuilt: "neverBuilt"
  of cdStale:      "stale"
  of cdSkipFresh:  "skipFresh"

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
      let labelCol =
        case pep.decision
        of cdNeverBuilt: col(decisionLabel(pep.decision), Ansi_Yellow, color)
        of cdStale:      col(decisionLabel(pep.decision), Ansi_Yellow, color)
        of cdSkipFresh:  col(decisionLabel(pep.decision), Ansi_Green, color)
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

proc planToJson*(plan: RunPlan; gatedOut: seq[GatedEntry]): JsonNode =
  ## Pure: serialize the PLAN phase to the crisol/plan/v1 JsonNode.  No I/O.
  let entrypointsNode = newJArray()
  for pep in plan.entrypoints:
    let epNode = newJObject()
    epNode["path"]     = newJString(pep.ep.path)
    epNode["group"]    = newJString(pep.ep.group)
    epNode["decision"] = newJString(decisionString(pep.decision))
    epNode["reason"]   = newJString(pep.reason)
    entrypointsNode.add epNode

  let gatedNode = newJArray()
  for g in gatedOut:
    let gNode = newJObject()
    gNode["path"]   = newJString(g.path)
    gNode["group"]  = newJString(g.group)
    gNode["reason"] = newJString(g.reason)
    gatedNode.add gNode

  result = newJObject()
  result["schema"]      = newJString("crisol/plan/v1")
  result["jobs"]        = newJInt(plan.jobs)
  result["entrypoints"] = entrypointsNode
  result["gatedOut"]    = gatedNode

proc planToJsonString*(plan: RunPlan; gatedOut: seq[GatedEntry]): string =
  ## Pure: compact JSON string of the crisol/plan/v1 document.
  $planToJson(plan, gatedOut)
