## pipeline.nim — crisol plan pipeline (R8: internal plan-phase orchestration)
##
## This module is an internal module; the public library entry point is api.nim.
## Given a Config and a GroupSelection it runs the full pure plan phase and
## returns a RunPlanView that api.nim can inspect and feed into execute().
##
## ## Pipeline invariant
##
##   discover(cfg, selection)
##     → applyGates(discovered, cfg, gateState)
##       → [optional narrowing: --failed ∩ failedKeys, --changed ∩ diff]
##         → plan(cfg, runnable, graph, nimVersion, forceCompile)
##
## All steps are pure (no I/O beyond the file-system reads in discover/plan).
## The effectful seams — loadGateState, loadDepGraph — are called here once
## and the results are passed to the pure steps.
##
## ## Public API
##
##   RunPlanView* = object
##     plan*:     RunPlan             ## fully annotated, ready to execute
##     gatedOut*: seq[GatedEntry]     ## discovered-but-gated-out entries
##     runnable*: int                 ## count of entrypoints that will run
##     graph*:    DepGraph            ## the dep graph (may be updated by execute)
##
##   buildRunPlan*(cfg, selection, …): RunPlanView
##     Pure plan phase. No subprocess is spawned. No I/O beyond reading the
##     dep graph and gate env vars. CLI-only concerns (arg parsing, exit code
##     mapping, stdout writing) are NOT present here.

import std/[sequtils, sets]
import crisol/[types, discover, depgraph, planner, narrow]

# ---------------------------------------------------------------------------
# Public result type
# ---------------------------------------------------------------------------

type
  RunPlanView* = object
    ## The output of buildRunPlan.  Passed to the CLI for rendering and
    ## (for `run`) handed to execute() for execution.
    plan*:     RunPlan
    gatedOut*: seq[GatedEntry]
    runnable*: int                 ## count of runnable entrypoints AFTER narrowing
    graph*:    DepGraph            ## caller may mutate (depgraph recording)
    warnings*: seq[ConfigWarning]  ## config warnings (unknown keys etc.) from loadConfig

# ---------------------------------------------------------------------------
# buildRunPlan — the SHARED pure plan phase
# ---------------------------------------------------------------------------

proc buildRunPlan*(
  cfg:          Config;
  selection:    GroupSelection;
  failedKeys:   HashSet[tuple[path, group: string]] = initHashSet[tuple[path, group: string]]();
  useFailed:    bool = false;
  useChanged:   bool = false;
  changed:      HashSet[string] = initHashSet[string]();
  nimVersion:   string = "";
  forceCompile: bool = false;
  warnings:     seq[ConfigWarning] = @[];
): RunPlanView =
  ## Pure plan phase: discover → applyGates → [narrowing] → plan.
  ##
  ## Parameters:
  ##   cfg          — project configuration (not mutated).
  ##   selection    — which groups/paths to discover.
  ##   failedKeys   — (path, group) pairs from the prior run; used when useFailed.
  ##   useFailed    — when true, keep only entrypoints in failedKeys.
  ##   useChanged   — when true, keep only entrypoints whose closure ∩ changed ≠ ∅.
  ##   changed      — set of changed file paths (relative); required when useChanged.
  ##   nimVersion   — Nim version string for freshness checks; "" disables.
  ##   forceCompile — when true, skip freshness checks (recompile everything).
  ##
  ## When both useFailed and useChanged are true, the UNION of both narrowed
  ## sets is used (conservative: an entrypoint runs if EITHER criterion selects it).
  ##
  ## No CLI-only concerns here: no arg parsing, no exit-code logic, no stdout.

  let discovered = discover(cfg, selection)
  let gateState  = loadGateState(cfg)
  let gated      = applyGates(discovered, cfg, gateState)

  # applyGates now returns one GatedEntry (path, group, reason) per gated-out
  # entrypoint, so the rendering list is just its gatedOut field — no need to
  # re-walk the DiscoveredSet via unsafeToSeq (which would leak the gate seam).
  let gatedEntries: seq[GatedEntry] = gated.gatedOut

  # Load the persisted dep graph (D6 freshness; D5 impact selection).
  let graph = loadDepGraph(cfg, nimVersion)

  # Narrowing: applied AFTER applyGates, BEFORE plan (pipeline invariant).
  #
  #   useFailed  → keep only entrypoints whose (path,group) is in failedKeys.
  #   useChanged → keep only entrypoints selected by narrowByDiff (diff ∩
  #                closure, with the conservative fallback taxonomy of D4).
  #   both       → UNION: an entrypoint runs if EITHER criterion includes it
  #                (conservative — intersection could miss a newly broken
  #                 entrypoint absent from the prior run).
  var runnable = gated.run
  if useFailed or useChanged:
    let failedNarrowed =
      if useFailed:
        gated.run.filterIt((path: it.path, group: it.group) in failedKeys)
      else:
        newSeq[Entrypoint]()
    let changedNarrowed =
      if useChanged:
        narrowByDiff(gated.run, changed, graph, cfg.projectRoot)
      else:
        newSeq[Entrypoint]()

    # Union over the two narrowed sets, preserving gated.run input order.
    var keep = initHashSet[tuple[path, group: string]]()
    for ep in failedNarrowed:  keep.incl (path: ep.path, group: ep.group)
    for ep in changedNarrowed: keep.incl (path: ep.path, group: ep.group)
    runnable = gated.run.filterIt((path: it.path, group: it.group) in keep)

  let runPlan = plan(cfg, runnable, graph, nimVersion, forceCompile)
  RunPlanView(
    plan:     runPlan,
    gatedOut: gatedEntries,
    runnable: runnable.len,
    graph:    graph,
    warnings: warnings,
  )
