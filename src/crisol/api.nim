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
##   ResultCallback, EntrypointResult, isFailure, exitCode
## From render: render, gateSkipMessages, pathFlagsWarnings, filterRecordsByTag,
##   hasZeroTagMatches, RenderOpts, defaultOpts
## From jsonout: toJsonString, RunSchema
## From planview: PlanV1Schema (+ PlanReport-typed facade overloads defined here)
##
## NOT re-exported: Config, Gate, Group, GateState, GateStateEntry, DiscoveredSet,
##   SelectionReason, SelectionResult, RunPlan, persistLastRun, loadLastRun,
##   newCrisolError, ANSI internals (col, Ansi_*, etc.),
##   memThrottleActive, formatProgressLine, planview internals (planToJson,
##   decisionStringEd, decisionLabelEd, warningsToJsonArray)

import std/[algorithm, json, options, os, sequtils, sets, strutils, tables, times]
import crisol/[types, config, pipeline, jsonout, render, planview, gitdiff, runner, lock, signals,
               sandbox, cachedispatch, ccprobe, nimprobe, planner, order, ledger, keys, depgraph, stats,
               compilereport]
# rfc-0007 A1c: the §2 result-model facade (Phase/ProcessResult/Exit/Cause/
# Evidence/Rusage/OutcomePolicy) plus the runResult/failureLine digest
# helpers below. `import nil` so nothing unqualified leaks into this
# module's own namespace; the enumerated set is re-exported explicitly.
from crisol/process/types as ptypes import nil

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
export types.ClosureEntry
export types.ClosureReport
export types.CompileDecision
export types.EntrypointDecision
export types.CacheDecision
export types.CrisolError
export types.CrisolErrorKind
export types.ResultCallback
export types.EntrypointResult
export types.HermeticLevel
export types.isFailure
export types.exitCode
export types.outcome
export types.cached
export types.flaky
export types.hasFailRecords

# From process/types — the §2 result-model facade (rfc-0007 A1c), enumerated
# exactly per the RFC's A1c bullet.
export ptypes.Phase
export ptypes.PhaseKind
export ptypes.ProcessResult
export ptypes.Exit
export ptypes.ExitKind
export ptypes.Cause
export ptypes.CauseBy
export ptypes.KillReason
export ptypes.Evidence
export ptypes.TreeObservation
export ptypes.Rusage
export ptypes.LimitsAchieved
export ptypes.OutcomePolicy

# From render — public rendering surface only (NOT ANSI internals, col, etc.)
export render.render
export render.gateSkipMessages
export render.pathFlagsWarnings
export render.filterRecordsByTag
export render.hasZeroTagMatches
export render.RenderOpts
export render.defaultOpts
export render.renderClosure

# From jsonout — schema constant + toJsonString only (NOT persistLastRun, loadLastRun)
export jsonout.toJsonString
export jsonout.RunSchema
export jsonout.closureToJsonString
export jsonout.ClosureV1Schema

# From planview — schema constant only; PlanReport-typed facades are defined below
export planview.PlanV1Schema

# From order — C4: OrderMode enum + parse (CLI/consumer surface)
export order.OrderMode
export order.parseOrderMode

# ---------------------------------------------------------------------------
# Nim-version fingerprint (High finding — soundness seam)
# ---------------------------------------------------------------------------
#
# crisol must fingerprint the Nim compiler so that (1) the depgraph staleness
# check invalidates stale binaries after a compiler upgrade and (2) the
# soundness key invalidates cached test RESULTS after a compiler upgrade.
#
# CACHE IDENTITY now uses `nimprobe.cachedNimFingerprint()` — a RUNTIME probe
# of the nim binary crisol's own compile invocations resolve via PATH (mirrors
# `ccprobe.cachedCcVersion()` for the C compiler) — NOT `crisolNimVersion`
# below. `crisolNimVersion` (= `system.NimVersion`, crisol's OWN compile-time
# Nim version, e.g. "2.2.10") is just a version STRING: two builds of Nim can
# share it while differing in codegen (a stock vs. a locally-patched build),
# which a cache/staleness check keyed on the string alone cannot detect. This
# value is threaded into buildRunPlan → loadDepGraph / plan → execute →
# realSeams so BOTH the staleness check (planner.decideCompile) AND the
# soundness key (keys.soundnessKey) observe the binary-distinguishing
# fingerprint instead of the compile-time string.

const crisolNimVersion* = NimVersion
  ## The Nim compiler version crisol was built with (e.g. "2.2.0").
  ## DISPLAY/METADATA ONLY — kept for consumers wanting the human-readable
  ## version string (e.g. logs). NOT fed into cache identity; see
  ## `nimprobe.cachedNimFingerprint()` for the runtime, binary-distinguishing
  ## fingerprint used by depgraph staleness / SoundnessKey / toolchainFingerprint.

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
    noCache*:      bool = false  ## RFC-0004 F3: --no-cache → do NOT read and do NOT
                                 ## write the result cache (full bypass).  Caching is
                                 ## ON by default.
    retries*:      int  = -1     ## B1: global retry count override.  -1 = use config.
                                 ## 0 = no retry (override to no-retry regardless of config).
                                 ## N >= 1 = retry up to N times (maxAttempts = N+1).
    failOnFlaky*:  bool = false  ## B1: when true, a flaky-pass (passed after attempt > 1)
                                 ## contributes to exit 1 instead of exit 0.
    ## Tier 2 — tuning
    jobs*:         int = 0        ## <= 0 → config/built-in default (no error,
                                  ## unlike CLI which rejects --jobs < 1)
    timeoutSecs*:  int = 0        ## <= 0 → config/built-in default
    onResult*:     ResultCallback = nil ## per-entrypoint callback; nil = noop
    ## C2: Shard selection (last step of selection, after narrowing).
    ## shardK == 0 means no sharding.  When > 0, must satisfy 1 <= shardK <= shardN.
    shardK*:       int = 0   ## shard index (1-indexed); 0 = no sharding
    shardN*:       int = 1   ## total shard count; only used when shardK > 0
    ## C4: History-based execution order (applied after shard, before plan).
    ## omNone (default) = no reorder; pipeline parity with pre-C4 behavior.
    order*:        OrderMode = omNone
    ## Tier 3 — host-lifecycle
    manageLock*:         bool = true   ## advisory inter-process lock
    installSignals*:     bool = false  ## LIBRARY DEFAULT OFF; true replaces host handlers
    persist*:            bool = true   ## write lastrun.json
    showProgress*:       bool = false  ## stderr-only progress line
    progressIntervalMs*: int  = 30_000
    ## C6: --perf-check CLI override.
    ## Precedence (highest wins):
    ##   1. perfCheckForce=true → force perf-check ON (use config policy or moderate preset).
    ##   2. Config block present with sensitivity≠none → enabled (parsed into cfg.perfCheck).
    ##   3. perfCheckForce=false AND no config block (or sensitivity=none) → disabled.
    perfCheckForce*:     bool = false  ## CLI --perf-check: force perf-check ON
    ## RFC-0004 hermeticity-level control (--hermetic none|isolated|network).
    ## Default hlIsolated preserves prior behavior (env allowlist + isolated tmpdir
    ## + config-declared rlimits, no net isolation).  hlNone disables the hermetic
    ## scrub/rlimits entirely; hlNetwork requests net-ns isolation (currently
    ## DEGRADES — net-ns unshare is not wired — so such runs are not cached).
    hermeticLevel*:      HermeticLevel = hlIsolated
    ## Fix 1: per-run override for RLIMIT_NOFILE (max open fds) in the hermetic
    ## sandbox. none (default) = use Config.rlimitNofile if set, else
    ## sandbox.DefaultRlimitNofile (1024). Set explicitly can only strengthen
    ## a config-file value (wins when some), mirroring jobs/timeoutSecs/retries
    ## precedence below in planImpl — lets a library caller raise the ceiling
    ## for one run without editing crisol.kdl.
    rlimitNofile*:       Option[int64] = none(int64)
    ## RFC-0006 M-artifact-identity PASS (b2): --measure-compile-reuse.
    ## false (default) → compile slots run plain `nim c`, byte-for-byte
    ## unchanged from before this pass. true → compile slots run the
    ## `--internal-measure-compile` measurement worker instead (same
    ## runnable binary produced; additionally writes ArtifactRows). This
    ## can only strengthen (opt IN), never override a config-file `false`
    ## with `false` — see planImpl.
    measureCompileReuse*: bool = false
    ## Absolute path to a binary whose `main()` dispatches the
    ## `--internal-measure-compile` token — required for measureCompileReuse's
    ## self-reexec worker to be sound (see Config.workerBinary in types.nim
    ## for the full rationale). "" (default) = no sound worker; the CLI sets
    ## this to its own getAppFilename(); a library consumer embedding crisol
    ## (e.g. calling runTests()/planTests() from its own binary) MUST set
    ## this explicitly to get measurement — leaving it unset is always safe
    ## (degrades to monolithic compile, never fork-bombs).
    workerBinary*:        string = ""

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
    adHocPaths*:     seq[string]   ## Issue #3 / RFC-0001:409: gskFiles paths that
                                   ## matched no candidate group (ran ad-hoc, global flags).

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
    interrupted*:       bool  ## rfc-0007 A1e-ii: true iff a SIGINT/SIGTERM cut this
                              ## run short. CrisolInterrupted is retired — this bool
                              ## (status == rsInterrupted, in lockstep) is the
                              ## replacement signal; results/summary are populated
                              ## with §2's emission set rather than left empty, and
                              ## lastrun.json is deliberately never persisted for
                              ## this run (an entrypoint never observed must not
                              ## silently leave the --failed selection).
    zeroRunnableReason*: ZeroRunnableReason
    compileBlock*:      JsonNode  ## the SAME `compile` block persisted to
                                  ## lastrun.json (compilereport.readCompileBlock), exposed here
                                  ## so a caller (e.g. the CLI) can print a human-readable
                                  ## compile summary line without re-scanning the
                                  ## ledgers. nil when opts.persist is false, or when
                                  ## measureCompileReuse is not enabled (no telemetry).

# ---------------------------------------------------------------------------
# rfc-0007 A1c: result-model digest helpers — so a library consumer doesn't
# hand-roll the same Phase-variant case expression render.nim/junit.nim do.
# ---------------------------------------------------------------------------

proc runResult*(r: EntrypointResult): Option[ptypes.ProcessResult] =
  ## Absorbs the Phase variant check: `some()` iff the run phase carries a
  ## real ProcessResult observation — `pkRan` (a live run this invocation)
  ## OR `pkCached` (rfc-0007 A1d-ii: a cache hit now replays the REAL stored
  ## observation, not a fabricated stand-in — see cachedispatch.synthesize).
  ## `none()` for pkSkipped/pkSpawnFailed — no observation to hand back.
  if r.run.kind in {ptypes.pkRan, ptypes.pkCached}: some(r.run.res)
  else: none(ptypes.ProcessResult)

proc failureLine*(r: EntrypointResult): string =
  ## Render-grade one-liner for a failing/non-passed result — the digest a
  ## caller building its own UI needs without re-deriving cause/exit detail.
  ## "" for a passing result (outcome(r) == oPassed).
  case outcome(r)
  of oPassed:
    ""
  of oFailed:
    let rr = runResult(r)
    let code = if rr.isSome and rr.get.exit.kind == ptypes.ekExited: rr.get.exit.code else: 0
    "exit " & $code
  of oCompileFailed:
    "compile failed"
  of oSpawnError:
    "spawn error"
  of oKilled:
    let rr = runResult(r)
    if rr.isSome: "killed: " & ptypes.causeLabel(rr.get.cause)
    else: "killed"
  of oCrashed:
    let rr = runResult(r)
    if rr.isSome: "crashed: " & ptypes.symbol(rr.get.exit)
    else: "crashed"

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

proc shouldReportCompileBlock*(measureCompileReuse: bool): bool =
  ## R14-T6 (code review): the pure predicate gating whether runTests() even
  ## ATTEMPTS to read/report the `compile` block at all (extracted so the
  ## exact boolean expression is independently unit-testable without a real
  ## compile). Even when this returns true, the actual `compile` field can
  ## still end up absent if no telemetry was ever written this run (see
  ## compilereport.buildCompileBlock's own nil-when-empty contract) — this
  ## predicate only answers "should we even look", not "is there data".
  measureCompileReuse

proc rlimitOverridesFrom*(cfg: Config): RlimitOverrides =
  ## Fix 1: pure projection of Config's rlimit-override fields into the
  ## RlimitOverrides bundle resolveSandbox expects. Extracted (like
  ## shouldReportCompileBlock above) so the Config → SandboxSpec wiring is
  ## independently unit-testable without a real run. Currently only
  ## limitNofile is config-plumbed; the other RlimitOverrides fields stay
  ## none here (resolveSandbox applies its own safe built-in defaults).
  RlimitOverrides(limitNofile: cfg.rlimitNofile)

proc planImpl(opts: RunOptions): PlanImplResult =
  ## Internal plan phase shared by planTests and runTests.
  ## Raises CrisolError on any structural problem.

  # 1. Load config.
  var (cfg, cfgWarnings) = loadConfig(configPath = opts.configPath,
                                      startDir   = opts.startDir)

  # 2. Apply jobs / timeout / retries overrides.
  if opts.jobs > 0:        cfg.jobs        = opts.jobs
  if opts.timeoutSecs > 0: cfg.timeoutSecs = opts.timeoutSecs
  if opts.retries >= 0:    cfg.retries     = opts.retries  # B1: -1 = use config
  # RFC-0006 M-artifact-identity PASS (b2): CLI/library --measure-compile-reuse
  # can only strengthen a config-file setting (true wins), mirroring perfCheckForce.
  if opts.measureCompileReuse: cfg.measureCompileReuse = true
  if opts.workerBinary.len > 0: cfg.workerBinary = opts.workerBinary
  # Fix 1: RunOptions.rlimitNofile, when set, overrides Config.rlimitNofile.
  if opts.rlimitNofile.isSome: cfg.rlimitNofile = opts.rlimitNofile

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
    nimVersion   = cachedNimFingerprint(),
    forceCompile = opts.forceCompile,
    warnings     = cfgWarnings,
    shardK       = opts.shardK,
    shardN       = opts.shardN,
    order        = opts.order,   # C4: history-based prioritization
  )

  # Code-review R13: an explicit --measure-compile-reuse request
  # that will silently degrade to the monolithic compile path (no
  # workerBinary configured) must be visible in the STRUCTURED warnings
  # channel, not merely runner.nim's one-shot stderr write
  # (warnMeasureCompileReuseNoWorkerOnce) — a CI
  # consumer whose stderr is swallowed sees a completely silent no-op of a
  # feature it explicitly asked for (compileBlock simply absent from the
  # report, indistinguishable from "nobody asked"). Reuses the EXISTING
  # ConfigWarning shape (no types.nim change): its fields (source/context/
  # key/message) are generic enough to carry a resolved-config runtime
  # warning, not only a config-file-parse warning.
  var warnings = pv.warnings
  if cfg.workerBinary.len == 0:
    if cfg.measureCompileReuse:
      warnings.add ConfigWarning(
        source:  "",
        context: "measure-compile-reuse",
        key:     "workerBinary",
        message: "measure-compile-reuse requested but no worker binary is " &
                 "configured; not honored this run -- compiling " &
                 "monolithically (measurement skipped). Set " &
                 "RunOptions.workerBinary to a binary that dispatches " &
                 "--internal-measure-compile to get measurement.",
      )

  # 5. Project into PlanReport.
  let resolvedStateDir = stateDirOf(cfg)
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
    warnings:    warnings,
    settings:    settings,
    adHocPaths:     pv.adHocPaths,
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
# closureReport — issue #9 slice A: read-only depgraph projection
# ---------------------------------------------------------------------------

proc closureReport*(opts: RunOptions = RunOptions()): ClosureReport =
  ## Read-only depgraph lookup for every entrypoint planImpl(opts) plans.
  ##
  ## Built on the EXISTING plan phase (planImpl) so this does NOT duplicate
  ## discovery/config/group-resolution or the DepGraph loader (which is keyed
  ## on crisol's real Nim compiler fingerprint — a downstream consumer that
  ## hand-rolled this probe would silently see an empty graph on a mismatch).
  ##
  ## Raises CrisolError like planTests (structural problems: bad config,
  ## unknown group, etc.).  No lock, no compile, no test execution; the only
  ## subprocess is the Nim compiler version/fingerprint probe shared with
  ## run/list (needed to key the depgraph lookup — see depgraph.loadDepGraph).
  let impl = planImpl(opts)
  var entries: seq[ClosureEntry]
  for pep in impl.pr.entrypoints:
    let ep    = pep.ep
    let fHash = flagHash(ep.flags)
    let key   = (ep.path, fHash)
    if impl.pv.graph.entries.hasKey(key):
      let ge = impl.pv.graph.entries[key]
      var closureSeq = toSeq(ge.closure)
      closureSeq.sort()
      entries.add ClosureEntry(
        path:        ep.path,
        group:       ep.group,
        flagHash:    fHash,
        recorded:    true,
        closure:     closureSeq,
        closureHash: ge.closureHash,
      )
    else:
      entries.add ClosureEntry(
        path:        ep.path,
        group:       ep.group,
        flagHash:    fHash,
        recorded:    false,
        closure:     @[],
        closureHash: "",
      )
  ClosureReport(
    entries:        entries,
    warnings:       impl.pr.warnings,
    adHocPaths:     impl.pr.adHocPaths,
    gatedOut:       impl.pr.gatedOut,
  )

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
  ## rfc-0007 A1e-ii: SIGINT/SIGTERM → rsInterrupted, `interrupted: true`,
  ##   exitCode = 128 + signum. CrisolInterrupted is retired — execute()
  ##   returns normally with §2's emission set: `results`/`summary` are
  ##   populated (not empty), `onResult` already fired for every killed
  ##   final, and lastrun.json is deliberately never persisted for this run.

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
      return structuralResultWithPlan(
        "no entrypoints matched — check config/globs", 3, pr)

  var graph = pv.graph   # mutable copy for depgraph recording
  let cb    = if opts.onResult != nil: opts.onResult
              else: (proc(r: EntrypointResult) {.closure.} = discard)

  var results: seq[EntrypointResult]
  var memThrottled = 0

  # C6: Resolve the effective PerfCheckConfig.
  #   Precedence: perfCheckForce > config block > absent/disabled.
  #   If perfCheckForce is set AND the config block has no enabled policy,
  #   fall back to the "moderate" preset so the CLI flag is never a no-op.
  let effectivePerfCheck: PerfCheckConfig =
    if cfg.perfCheck.enabled:
      # Config block says enabled (sensitivity ≠ none): use it.
      # perfCheckForce can only strengthen, not weaken, so this wins too.
      cfg.perfCheck
    elif opts.perfCheckForce:
      # CLI --perf-check forces ON; config block absent/none → moderate preset.
      PerfCheckConfig(enabled: true, k: 3.0, sampleFloor: 10, absFloorMs: 5)
    else:
      PerfCheckConfig(enabled: false)

  # C6: Capture run-start timestamp (unix epoch µs) BEFORE execute() appends
  # current-run rows to the ledger.  The detection step will exclude any ledger
  # row whose timestamp >= runStart, ensuring we compare against PRIOR history only.
  let runStartUs: int64 = int64(epochTime() * 1_000_000.0)

  # F2/F3 (A6): resolve hermeticity once (default hlIsolated) and build the
  # result-cache policy + seams.  The seams read the LIVE graph (ptr) so a
  # store-key derived after a compile reflects the fresh closureHash.
  # M4: bundle spec+policy+seams into a CacheContext so the invariant
  # (active iff keyOf!=nil AND policy.enabled) is enforced structurally.
  let spec  = resolveSandbox(level = opts.hermeticLevel,
                              rlimits = rlimitOverridesFrom(cfg))
  # nimcache-persistence (RFC-0006): the SAME ccVersion/nimVersion probes
  # already used by RFC-0004's SoundnessKey (via realSeams below) are reused
  # here — folded into execute()'s toolchain fingerprint, which keys the
  # persistent nimcache path. One probe each, two consumers; never diverge.
  # nimVer is the RUNTIME fingerprint (nimprobe.cachedNimFingerprint) — not
  # crisolNimVersion — so a stock->patched compiler swap at the same version
  # STRING is soundly distinguished; see the module-doc note above.
  let ccVer  = cachedCcVersion()
  let nimVer = cachedNimFingerprint()
  let cacheCtx =
    if opts.noCache:
      cacheDisabled(spec)   # fully off; spec still governs sandbox hermeticity
    else:
      cacheEnabled(spec,
        CachePolicy(enabled: true),
        realSeams(
          stateDir      = pr.settings.stateDir,
          graph         = addr graph,
          nimVersion    = nimVer,
          ccVersion     = ccVer,
          spec          = spec,
          parentEnv     = toSeq(envPairs()),
          protocolMajor = CrisolProtocolMajor,
        ))

  # rfc-0007 A1e-ii: CrisolInterrupted is retired — `interrupted`/`notStartedCount`
  # are written by execute() itself (via ptr out-params) rather than caught as
  # an exception; a SIGINT/SIGTERM no longer unwinds this call at all.
  var interrupted     = false
  var notStartedCount = 0

  try:
    results = execute(
      pv.plan,
      config             = cfg,
      graph              = graph,
      nimVersion         = nimVer,
      ccVersion          = ccVer,
      onResult           = cb,
      failFast           = opts.failFast,
      showProgress       = opts.showProgress,
      progressIntervalMs = opts.progressIntervalMs,
      memThrottledOut    = addr memThrottled,
      interruptedOut     = addr interrupted,
      notStartedOut      = addr notStartedCount,
      cache              = cacheCtx,
    )
  except CrisolError as e:
    releaseLock(lockHandle)
    let code = if e.kind == cekInternal: 2 else: 3
    return structuralResultWithPlan(e.msg, code, pr)
  except Exception as e:
    releaseLock(lockHandle)
    return structuralResultWithPlan("unexpected error during execute: " & e.msg, 2, pr)

  var s = summarize(results)
  # rfc-0007 A1e-ii §2: notStarted is bookkeeping about entries OMITTED from
  # `results` (never a fold over `results` itself), so it is stamped on here
  # rather than inside summarize().
  s.notStarted = notStartedCount

  # C6: Annotate results with regression info (if perf-check is enabled).
  # edCached results are excluded (no fresh measurement; never flag a cache hit).
  # For each fresh result, historyUs = prior durationUs rows from the ledger,
  # filtering out compileFailed rows and rows from the current run (timestamp >= runStart).
  if effectivePerfCheck.enabled:
    let resolvedStateDir = pr.settings.stateDir
    for i in 0 ..< results.len:
      let r = results[i]
      # Skip cached results — no fresh measurement, never flag.
      if cached(r):
        continue
      # Skip compile-failed — no run duration to compare.
      if outcome(r) == oCompileFailed:
        continue
      # Build identity key for this entrypoint.
      let ikey = identityKey(r.ep.path, flagHash(r.ep.flags))
      # Scan the ledger for PRIOR rows (exclude current run by timestamp).
      let allRows = scanLedger(resolvedStateDir, ikey)
      var historyUs: seq[int64]
      for row in allRows:
        # Exclude current-run rows (appended during execute()).
        if row.timestamp >= runStartUs:
          continue
        # Exclude compileFailed rows (their durationUs reflects the compiler, not the run).
        if row.outcome.startsWith("compileFailed"):
          continue
        historyUs.add row.durationUs
      # Run the pure predicate.
      let verdict = isRegression(
        currentUs   = r.durationMs * 1000,  # convert ms → µs for comparison
        historyUs   = historyUs,
        k           = effectivePerfCheck.k,
        sampleFloor = effectivePerfCheck.sampleFloor,
        absFloorMs  = effectivePerfCheck.absFloorMs,
      )
      results[i].regressed      = verdict.regressed
      results[i].perfBaselineUs = verdict.baselineUs
      results[i].perfThresholdUs = verdict.thresholdUs

  # Persist lastrun.json if requested.
  # rfc-0007 A1e-ii §2: NEVER on an interrupted run, regardless of
  # opts.persist (the CLI always passes persist:true) — an entrypoint that
  # was never observed this run must not silently leave the --failed
  # selection, so the last COMPLETE run stays the anchor.
  var compileBlock: JsonNode = nil
  if opts.persist and not interrupted:
    # RFC-0006 M-report pass (a): the segmented `compile` block
    # only carries data when the telemetry stream was actually written
    # this run -- avoids a needless ledger disk scan on every ordinary
    # (measurement-off) run.
    compileBlock =
      if shouldReportCompileBlock(cfg.measureCompileReuse):
        # M-report PASS (b2): thread the SAME runStartUs perf-check captured
        # above (before execute() appended this run's rows) into the
        # compile-cost stream's own current/history split.
        compilereport.readCompileBlock(pr.settings.stateDir, runStartUs)
      else: nil
    # M-report pass (b1): reuse-check alerting is a SEPARATE, default-OFF
    # surface from the (unconditional) `compile` measurement block itself --
    # buildReuseAlerts naturally yields an empty array when cfg.reuseCheck is
    # disabled or compileBlock is nil (measurement off / no telemetry yet).
    let reuseAlerts = compilereport.buildReuseAlerts(compileBlock, cfg.reuseCheck)
    persistLastRun(results, s, cfg, warnings = pr.warnings,
                   memThrottledSlots = memThrottled, compileBlock = compileBlock,
                   reuseAlerts = reuseAlerts)

  releaseLock(lockHandle)

  # rfc-0007 A1e-ii: an interrupted run still returns through this ONE
  # normal-return path (no more early exception-driven return above) — only
  # the status/exitCode/interrupted trio differ; results/summary already
  # carry §2's honest partial emission set.
  RunReport(
    plan:              pr,
    summary:           s,
    results:           results,
    memThrottledSlots: memThrottled,
    status:            if interrupted: rsInterrupted else: rsOk,
    exitCode:          if interrupted: 128 + int(pendingSignal())
                        else: exitCode(s, opts.failOnFlaky),  # B1: flaky-pass gating
    compileBlock:      compileBlock,
    interrupted:       interrupted,
  )
