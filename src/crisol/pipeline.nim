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

import std/[os, sequtils, sets]
import crisol/[types, discover, depgraph, planner, narrow, shard, order]

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
  shardK:       int = 0;          ## C2: shard index (1-indexed); 0 = no sharding
  shardN:       int = 1;          ## C2: total shard count; only used when shardK > 0
  order:        OrderMode = omNone; ## C4: history-based execution order; omNone = no reorder
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
  ##   nimVersion   — Nim version string for freshness checks; the api boundary
  ##                  threads the real compiler version (api.crisolNimVersion =
  ##                  system.NimVersion).  "" disables (test/cold-start only).
  ##   forceCompile — when true, skip freshness checks (recompile everything).
  ##   shardK       — C2: shard index (1-indexed, 1..shardN); 0 = no sharding.
  ##   shardN       — C2: total shard count; only used when shardK > 0.
  ##   order        — C4: history-based execution order mode (default omNone = no reorder).
  ##                  Applied AFTER the shard step so shard membership is stable.
  ##                  With omNone the pipeline is byte-for-byte identical to the
  ##                  pre-C4 pipeline (no ledger reads, no reordering).
  ##
  ## When both useFailed and useChanged are true, the UNION of both narrowed
  ## sets is used (conservative: an entrypoint runs if EITHER criterion selects it).
  ##
  ## When shardK > 0, the shard step is applied LAST (after --failed/--changed
  ## narrowing) so --shard composes with --changed: diff narrows first, then the
  ## shard partitions the narrowed set.
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

  # C3: Shard step — LAST step of selection, AFTER narrowing and BEFORE plan.
  # Applied only when shardK > 0 (i.e. --shard was passed).
  # Composes with --changed: diff narrows first, shard partitions the result.
  # Uses ledger-aware balanced sharding (LPT bin-pack) when history exists;
  # falls back to C2 path-hash partition on cold start (no ledger rows).
  if shardK > 0:
    let resolvedStateDir = cfg.projectRoot / cfg.stateDir
    runnable = shardWithHistory(runnable, shardK, shardN, resolvedStateDir)

  # C4: Order step — AFTER shard (shard membership is stable), BEFORE plan.
  # Applied only when order != omNone.  With omNone (default) this block is
  # entirely skipped: zero I/O, no reordering, pipeline parity with pre-C4.
  # The ordering step always runs after shard assignment so shard membership
  # is stable regardless of the --order fallback (RFC §F5 line 159).
  if order != omNone:
    let resolvedStateDir = cfg.projectRoot / cfg.stateDir
    runnable = orderByHistory(runnable, order, resolvedStateDir)

  let runPlan = plan(cfg, runnable, graph, nimVersion, forceCompile)
  RunPlanView(
    plan:     runPlan,
    gatedOut: gatedEntries,
    runnable: runnable.len,
    graph:    graph,
    warnings: warnings,
  )
