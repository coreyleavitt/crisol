## crisol/api.nim — the public library boundary (F1, RFC-0003).
##
## This module is THE contracted library surface.  Import only this module
## to embed crisol as a library; all other crisol modules are implementation
## details (importable but uncontracted).
##
## ## Entry points
##
##   planTests*(opts): PlanReport
##     Pure plan phase.  Raises CrisolError on structural problems (bad config,
##     unknown group, etc.).  No lock, no subprocess execution.
##
##   runTests*(opts): RunReport
##     Full run.  Returns outcomes; never raises for expected conditions.
##     Structural problems are encoded in RunReport.status / .error.
##
## ## Selection constructors (hide GroupSelection discriminated-union syntax)
##
##   defaultGroups()             → gskDefault (excludes opt-in groups)
##   namedGroups(names…)         → gskNamed
##   allGroups()                 → gskAll (includes opt-in; gates still apply)
##   filesSelection(paths…)      → gskFiles
##
## ## Narrowing constructors (make baseRef-without-narrowing unconstructable)
##
##   noNarrowing()               → nkNone (run all)
##   failedOnly()                → nkFailed
##   changedOnly(baseRef="")     → nkChanged; "" = working tree vs HEAD
##   failedOrChanged(baseRef="") → nkFailedOrChanged (UNION; wider, not narrower)
##
## ## Public re-exports (selective — see H1)
##
## From types: GroupSelection, GroupSelectionKind, PlannedEntrypoint, Entrypoint,
##   Outcome (+ oPassed/oFailed/etc values), TestRecord, RecordStatus, Summary,
##   GatedEntry, ConfigWarning, CompileDecision, CrisolError, CrisolErrorKind,
##   CrisolInterrupted, ResultCallback, EntrypointResult, isFailure, exitCode
## From render: render, gateSkipMessages, filterRecordsByTag, hasZeroTagMatches,
##   RenderOpts, defaultOpts
## From jsonout: toJsonString, RunV1Schema
## From planview: PlanV1Schema (+ PlanReport-typed facade overloads defined here)
##
## NOT re-exported: Config, Gate, Group, GateState, GateStateEntry, DiscoveredSet,
##   SelectionReason, SelectionResult, RunPlan, persistLastRun, loadLastRun,
##   newCrisolError, newCrisolInterrupted, ANSI internals (col, Ansi_*, etc.),
##   memThrottleActive, formatProgressLine, planview internals (planToJson,
##   decisionLabel, decisionString, warningsToJsonArray)

import std/[os, sets]
import crisol/[types, config, pipeline, jsonout, render, planview, gitdiff, runner, lock, signals]

# ---------------------------------------------------------------------------
# Selective re-exports (H1)
# ---------------------------------------------------------------------------
#
# Nim enum fields cannot be individually re-exported; exporting the type
# brings its fields along.  We use the `export module.Symbol` form to
# selectively re-export only the named types/procs from each module.

# From types — only the public surface types and their helpers
export types.GroupSelection
export types.GroupSelectionKind
export types.PlannedEntrypoint
export types.Entrypoint
export types.Outcome
export types.TestRecord
export types.RecordStatus
export types.Summary
export types.GatedEntry
export types.ConfigWarning
export types.CompileDecision
export types.CrisolError
export types.CrisolErrorKind
export types.CrisolInterrupted
export types.ResultCallback
export types.EntrypointResult
export types.isFailure
export types.exitCode

# From render — public rendering surface only (NOT ANSI internals, col, etc.)
export render.render
export render.gateSkipMessages
export render.filterRecordsByTag
export render.hasZeroTagMatches
export render.RenderOpts
export render.defaultOpts

# From jsonout — schema constant + toJsonString only (NOT persistLastRun, loadLastRun)
export jsonout.toJsonString
export jsonout.RunV1Schema

# From planview — schema constant only; PlanReport-typed facades are defined below
export planview.PlanV1Schema

# ---------------------------------------------------------------------------
# Public types (F1 — api-owned)
# ---------------------------------------------------------------------------

type
  RunStatus* = enum
    rsOk          ## run completed; inspect `summary` for pass/fail
    rsStructural  ## config/env problem (bad config/globs, lock held,
                  ## --failed with no prior run, --changed outside a git repo,
                  ## unknown group); see `error`
    rsInterrupted ## SIGINT/SIGTERM during the run; exitCode = 128 + signum

  NarrowingKind* = enum
    nkNone            ## run all (no narrowing)
    nkFailed          ## re-run only entrypoints that failed in the last run
    nkChanged         ## run only entrypoints whose closure ∩ diff ≠ ∅
    nkFailedOrChanged ## UNION of nkFailed and nkChanged (wider, not narrower)

  RunNarrowing* = object
    ## Describes how to narrow the set of entrypoints that will run.
    ## Constructed via the narrowing constructors (noNarrowing, failedOnly, …)
    ## — do NOT construct directly: base-ref-without-narrowing is structurally
    ## unconstructable via the library API.
    kind*:    NarrowingKind  ## nkNone / nkFailed / nkChanged / nkFailedOrChanged
    baseRef*: string          ## "" → working tree vs HEAD; only meaningful when
                              ## kind includes nkChanged

  RunOptions* = object
    ## All options accepted by planTests / runTests.
    ##
    ## Tier 1 — everyday selection
    configPath*:   string = ""
    startDir*:     string = ""   ## walk-up origin when configPath==""; "" → cwd
    selection*:    GroupSelection ## default-constructed = gskDefault
    narrowing*:    RunNarrowing   ## default-constructed = noNarrowing()
    forceCompile*: bool = false
    failFast*:     bool = false
    ## Tier 2 — tuning
    jobs*:         int = 0        ## <= 0 → config/built-in default (no error,
                                  ## unlike CLI which rejects --jobs < 1)
    timeoutSecs*:  int = 0        ## <= 0 → config/built-in default
    onResult*:     ResultCallback = nil ## per-entrypoint callback; nil = noop
    ## Tier 3 — host-lifecycle
    manageLock*:         bool = true   ## advisory inter-process lock
    installSignals*:     bool = false  ## LIBRARY DEFAULT OFF; true replaces host handlers
    persist*:            bool = true   ## write lastrun.json
    showProgress*:       bool = false  ## stderr-only progress line
    progressIntervalMs*: int  = 30_000

  ResolvedSettings* = object
    ## Slim projection of the resolved Config (NOT the full Config).
    ## Exposed so a consumer can see what configuration was actually used.
    projectRoot*: string
    stateDir*:    string  ## pre-joined to an ABSOLUTE path (projectRoot/stateDir
                          ## resolved); consumers never need to re-join, unlike
                          ## Config.stateDir which is project-root-relative.
    jobs*:        int     ## resolved (never 0)
    timeoutSecs*: int     ## resolved

  PlanReport* = object
    ## Output of planTests().  plan-phase result; no DepGraph or full Config.
    ## PlanReport inlines the RunPlan fields directly (entrypoints, jobs) to
    ## kill the rr.plan.plan stutter that a nested RunPlan would produce.
    entrypoints*: seq[PlannedEntrypoint]  ## inlined from RunPlan
    jobs*:        int                     ## resolved (never 0); from RunPlan
    gatedOut*:    seq[GatedEntry]
    warnings*:    seq[ConfigWarning]
    settings*:    ResolvedSettings

  ZeroRunnableReason* = enum
    zrkNone           ## not a zero-runnable outcome (normal run)
    zrkChangedClean   ## changed-narrowing, nothing in diff
    zrkFailedNone     ## failed-narrowing, nothing previously failed
    zrkAllGated       ## all discovered entrypoints gated out

  RunReport* = object
    ## Output of runTests().  Encodes ALL outcomes; never raises for expected
    ## conditions — structural problems are on .status / .error / .exitCode.
    plan*:              PlanReport
    summary*:           Summary
    results*:           seq[EntrypointResult]
    memThrottledSlots*: int   ## # entrypoints delayed >=once by mem-aware scheduling; 0 if inactive
    status*:            RunStatus
    exitCode*:          int   ## ALWAYS set: 0/1 (rsOk), 3 (rsStructural; 2 internal), 128+n (rsInterrupted)
    error*:             string ## non-empty iff status == rsStructural
    zeroRunnableReason*: ZeroRunnableReason

# ---------------------------------------------------------------------------
# Selection constructors — hide the GroupSelection discriminated-union syntax
# ---------------------------------------------------------------------------

proc defaultGroups*(): GroupSelection =
  ## Return a GroupSelection that runs all non-opt-in groups.
  GroupSelection(kind: gskDefault)

proc namedGroups*(names: varargs[string]): GroupSelection =
  ## Return a GroupSelection for exactly the named groups.
  var ns: seq[string]
  for n in names: ns.add n
  GroupSelection(kind: gskNamed, names: ns)

proc allGroups*(): GroupSelection =
  ## Return a GroupSelection that includes opt-in groups (gates still apply).
  GroupSelection(kind: gskAll)

proc filesSelection*(paths: varargs[string]): GroupSelection =
  ## Return a GroupSelection restricted to the given paths/globs.
  var ps: seq[string]
  for p in paths: ps.add p
  GroupSelection(kind: gskFiles, paths: ps)

# ---------------------------------------------------------------------------
# Narrowing constructors
# ---------------------------------------------------------------------------

proc noNarrowing*(): RunNarrowing =
  ## No narrowing — all selected entrypoints run.
  RunNarrowing(kind: nkNone, baseRef: "")

proc failedOnly*(): RunNarrowing =
  ## Re-run only entrypoints that failed in the last run (reads lastrun.json).
  RunNarrowing(kind: nkFailed, baseRef: "")

proc changedOnly*(baseRef: string = ""): RunNarrowing =
  ## Run only entrypoints whose dependency closure intersects the git diff.
  ## baseRef="" → working tree vs HEAD (staged + unstaged).
  RunNarrowing(kind: nkChanged, baseRef: baseRef)

proc failedOrChanged*(baseRef: string = ""): RunNarrowing =
  ## UNION of failedOnly and changedOnly — wider, not narrower.
  ## An entrypoint runs if EITHER criterion selects it.
  RunNarrowing(kind: nkFailedOrChanged, baseRef: baseRef)

# ---------------------------------------------------------------------------
# H2 — PlanReport-typed facade overloads for planview procs
# ---------------------------------------------------------------------------

proc toRunPlan(report: PlanReport): RunPlan =
  ## Private helper: reconstruct a RunPlan from the inlined PlanReport fields.
  RunPlan(entrypoints: report.entrypoints, jobs: report.jobs)

proc planToJsonString*(report: PlanReport): string =
  ## Facade: serialize the plan to crisol/plan/v1 JSON from a PlanReport.
  ## PlanReport carries its own warnings; no separate warnings param needed.
  planview.planToJsonString(report.toRunPlan, report.gatedOut, report.warnings)

proc renderPlan*(report: PlanReport; opts: RenderOpts): string =
  ## Facade: human-readable plan rendering from a PlanReport.
  planview.renderPlan(report.toRunPlan, report.gatedOut, opts)

# ---------------------------------------------------------------------------
# planImpl — internal shared plan phase (raises CrisolError on structural problems)
# ---------------------------------------------------------------------------

type PlanImplResult = object
  pr:          PlanReport      ## public projection (returned to callers of planTests)
  cfg:         Config          ## full config (used by runTests to pass to execute)
  pv:          RunPlanView     ## full view (used by runTests for graph + runnable count)
  useFailed:   bool            ## surfaced to avoid recomputation in runTests
  useChanged:  bool

proc planImpl(opts: RunOptions): PlanImplResult =
  ## Internal plan phase shared by planTests and runTests.
  ## Raises CrisolError on any structural problem.

  # 1. Load config.
  var (cfg, cfgWarnings) = loadConfig(configPath = opts.configPath,
                                      startDir   = opts.startDir)

  # 2. Apply jobs / timeout overrides.
  if opts.jobs > 0:        cfg.jobs        = opts.jobs
  if opts.timeoutSecs > 0: cfg.timeoutSecs = opts.timeoutSecs

  # 3. Assemble narrowing inputs.
  let useFailed  = opts.narrowing.kind in {nkFailed, nkFailedOrChanged}
  let useChanged = opts.narrowing.kind in {nkChanged, nkFailedOrChanged}

  var failedKeys = initHashSet[tuple[path, group: string]]()
  var changedSet = initHashSet[string]()

  if useFailed:
    let lr = loadLastRun(cfg)
    if not lr.found:
      raise newCrisolError(cekConfig,
        "--failed: no previous run found; run crisol first to record results")
    failedKeys = lr.failed

  if useChanged:
    changedSet = changedFiles(cfg.projectRoot, opts.narrowing.baseRef)

  # 4. Build the run plan.
  let pv = buildRunPlan(
    cfg          = cfg,
    selection    = opts.selection,
    failedKeys   = failedKeys,
    useFailed    = useFailed,
    useChanged   = useChanged,
    changed      = changedSet,
    nimVersion   = "",
    forceCompile = opts.forceCompile,
    warnings     = cfgWarnings,
  )

  # 5. Project into PlanReport.
  let resolvedStateDir = absolutePath(cfg.projectRoot / cfg.stateDir)
  let settings = ResolvedSettings(
    projectRoot: cfg.projectRoot,
    stateDir:    resolvedStateDir,
    jobs:        pv.plan.jobs,
    timeoutSecs: cfg.timeoutSecs,
  )
  let pr = PlanReport(
    entrypoints: pv.plan.entrypoints,
    jobs:        pv.plan.jobs,
    gatedOut:    pv.gatedOut,
    warnings:    pv.warnings,
    settings:    settings,
  )
  PlanImplResult(pr: pr, cfg: cfg, pv: pv, useFailed: useFailed, useChanged: useChanged)

# ---------------------------------------------------------------------------
# planTests — pure plan phase; raises CrisolError on structural problems
# ---------------------------------------------------------------------------

proc planTests*(opts: RunOptions = RunOptions()): PlanReport =
  ## Load config, apply overrides, assemble narrowing inputs, call buildRunPlan.
  ##
  ## This is the inspect/dry-run path: structural problems (bad config, unknown
  ## group, --failed with no prior run, --changed outside a git repo) are
  ## exceptional here and RAISE CrisolError.  No lock, no subprocess execution.
  planImpl(opts).pr

# ---------------------------------------------------------------------------
# runTests — full run facade; catches-and-encodes structural failures
# ---------------------------------------------------------------------------

proc runTests*(opts: RunOptions = RunOptions()): RunReport =
  ## Full run facade.  Returns outcomes; never raises for expected conditions.
  ## Structural problems are encoded in RunReport.status / .error / .exitCode.
  ##
  ## Flow on rsOk path:
  ##   clearSignal() → [installSignalHandlers if opts.installSignals]
  ##   → [acquireLock if opts.manageLock]
  ##   → planTests(opts) (CATCHES CrisolError → rsStructural)
  ##   → zero-runnable mapping (per RFC-0003 error table)
  ##   → execute → summarize
  ##   → [persistLastRun if opts.persist]
  ##   → map exitCode (0 all-passed / 1 any-failure)
  ##
  ## Lock released explicitly on EVERY exit branch (success / structural / interrupt).
  ## SIGINT/SIGTERM → CrisolInterrupted → rsInterrupted, 128+signum,
  ##   results = @[], summary = Summary() (zero-initialized).

  # S2d: clear any stale signal from a prior call so sequential runTests calls
  # are safe.
  clearSignal()

  # S2d: install signal handlers if requested (library default: off).
  if opts.installSignals:
    installSignalHandlers()

  # Helper: build a structural RunReport without raising (pre-plan, no pr available).
  template structuralResult(msg: string; code: int): RunReport =
    RunReport(
      status:   rsStructural,
      exitCode: code,
      error:    msg,
    )

  # Helper: build a structural RunReport with plan populated (post-plan).
  template structuralResultWithPlan(msg: string; code: int; planReport: PlanReport): RunReport =
    RunReport(
      plan:     planReport,
      status:   rsStructural,
      exitCode: code,
      error:    msg,
    )

  # Plan phase: catch CrisolError and encode into RunReport.
  var impl: PlanImplResult
  try:
    impl = planImpl(opts)
  except CrisolError as e:
    let code = if e.kind == cekInternal: 2 else: 3
    return structuralResult(e.msg, code)
  except Exception as e:
    return structuralResult("unexpected error during plan: " & e.msg, 2)

  let pr  = impl.pr   # public projection
  let cfg = impl.cfg  # full config (needed by execute)
  let pv  = impl.pv   # full view (needed for graph + runnable count)

  # Acquire advisory lock if requested.
  var lockHandle: LockHandle   # fd = -1 (default) = not held
  if opts.manageLock:
    try:
      lockHandle = acquireLock(pr.settings.stateDir)
    except CrisolError as e:
      return structuralResultWithPlan(e.msg, 3, pr)

  # Zero-runnable mapping (RFC-0003 error table):
  #   changed-clean-tree / failed-none-matched / all-gated-out → rsOk, exit 0
  #   no-entrypoints-matched (empty discovery, bad globs) → rsStructural, exit 3
  let runnableCount = pv.runnable
  let useFailed     = impl.useFailed
  let useChanged    = impl.useChanged

  if runnableCount == 0:
    if useChanged:
      releaseLock(lockHandle)
      return RunReport(plan: pr, status: rsOk, exitCode: 0,
                       zeroRunnableReason: zrkChangedClean)
    elif useFailed:
      releaseLock(lockHandle)
      return RunReport(plan: pr, status: rsOk, exitCode: 0,
                       zeroRunnableReason: zrkFailedNone)
    elif pr.gatedOut.len > 0:
      releaseLock(lockHandle)
      return RunReport(plan: pr, status: rsOk, exitCode: 0,
                       zeroRunnableReason: zrkAllGated)
    else:
      releaseLock(lockHandle)
      return structuralResult(
        "no entrypoints matched — check config/globs", 3)

  var graph = pv.graph   # mutable copy for depgraph recording
  let cb    = if opts.onResult != nil: opts.onResult
              else: (proc(r: EntrypointResult) {.closure.} = discard)

  var results: seq[EntrypointResult]
  var memThrottled = 0

  try:
    results = execute(
      pv.plan,
      config             = cfg,
      graph              = graph,
      nimVersion         = "",
      onResult           = cb,
      failFast           = opts.failFast,
      showProgress       = opts.showProgress,
      progressIntervalMs = opts.progressIntervalMs,
      memThrottledOut    = addr memThrottled,
    )
  except CrisolInterrupted as e:
    # SIGINT/SIGTERM: release lock and report rsInterrupted.
    # results and summary are empty / zero per RFC.
    releaseLock(lockHandle)
    return RunReport(
      plan:     pr,
      status:   rsInterrupted,
      exitCode: 128 + int(e.signum),
    )
  except CrisolError as e:
    releaseLock(lockHandle)
    let code = if e.kind == cekInternal: 2 else: 3
    return structuralResultWithPlan(e.msg, code, pr)
  except Exception as e:
    releaseLock(lockHandle)
    return structuralResultWithPlan("unexpected error during execute: " & e.msg, 2, pr)

  let s = summarize(results)

  # Persist lastrun.json if requested.
  if opts.persist:
    persistLastRun(results, s, cfg, warnings = pr.warnings,
                   memThrottledSlots = memThrottled)

  releaseLock(lockHandle)

  RunReport(
    plan:              pr,
    summary:           s,
    results:           results,
    memThrottledSlots: memThrottled,
    status:            rsOk,
    exitCode:          exitCode(s),
  )
