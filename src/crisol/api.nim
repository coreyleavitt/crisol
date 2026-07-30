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
## From render: render, gateSkipMessages, pathFlagsWarnings, filterRecordsByTag,
##   hasZeroTagMatches, RenderOpts, defaultOpts
## From jsonout: toJsonString, RunV1Schema
## From planview: PlanV1Schema (+ PlanReport-typed facade overloads defined here)
##
## NOT re-exported: Config, Gate, Group, GateState, GateStateEntry, DiscoveredSet,
##   SelectionReason, SelectionResult, RunPlan, persistLastRun, loadLastRun,
##   newCrisolError, newCrisolInterrupted, ANSI internals (col, Ansi_*, etc.),
##   memThrottleActive, formatProgressLine, planview internals (planToJson,
##   decisionStringEd, decisionLabelEd, warningsToJsonArray)

import std/[json, os, sequtils, sets, strutils, times]
import crisol/[types, config, pipeline, jsonout, render, planview, gitdiff, runner, lock, signals,
               sandbox, cachedispatch, ccprobe, planner, order, ledger, keys, depgraph, stats,
               compilereport]

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
export types.EntrypointDecision
export types.CacheDecision
export types.CrisolError
export types.CrisolErrorKind
export types.CrisolInterrupted
export types.ResultCallback
export types.EntrypointResult
export types.HermeticLevel
export types.isFailure
export types.exitCode

# From render — public rendering surface only (NOT ANSI internals, col, etc.)
export render.render
export render.gateSkipMessages
export render.pathFlagsWarnings
export render.filterRecordsByTag
export render.hasZeroTagMatches
export render.RenderOpts
export render.defaultOpts

# From jsonout — schema constant + toJsonString only (NOT persistLastRun, loadLastRun)
export jsonout.toJsonString
export jsonout.RunV1Schema

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
# `system.NimVersion` is the version of the Nim that compiled crisol.  In the
# single-toolchain podman container this is the SAME nim that compiles the test
# entrypoints, so it correctly fingerprints the compiler.  This value is
# threaded into buildRunPlan → loadDepGraph / plan → execute → realSeams so BOTH
# the staleness check (planner.decideCompile) AND the soundness key
# (keys.soundnessKey) observe a real version instead of the empty string.

const crisolNimVersion* = NimVersion
  ## The Nim compiler version crisol was built with (e.g. "2.2.0"), used as the
  ## nim-version fingerprint for depgraph staleness and result-cache soundness.

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
    ## The SAME field equally gates the `objCache` cache-worker path below
    ## (`--internal-compile-worker` dispatches through this same binary) —
    ## an empty workerBinary degrades EITHER path to monolithic compile
    ## (one-shot warn + a structured ConfigWarning), not just measurement.
    workerBinary*:        string = ""
    ## RFC-0006 Stage R, R2b2: --objcache / --no-objcache.
    ## Object cache is ON BY DEFAULT (RFC-0006 review R1/R2/R4 soundness
    ## fixes — object-cache key completeness + fail-safe degradation —
    ## landed and verified green; deliberate opt-OUT decision). This
    ## `objCache*: bool = false` field is the CLI-flag-shaped override
    ## (`--objcache`), independent from the default: it can only STRENGTHEN
    ## an already-true default, never represent it (its false default means
    ## "the flag was not passed", not "objcache is off"). The actual
    ## default-on value lives in the loaded Config (config.docToConfig /
    ## conventionConfig), fed into `configValue` below. Precedence (highest
    ## wins):
    ##   1. noObjCache=true (--no-objcache) → OFF, unconditionally.
    ##   2. objCache=true (--objcache) OR the config-file/default value
    ##      (`objcache #true`, or absent-KDL default) → ON.
    ##   3. otherwise (only reachable via an explicit `objcache #false`
    ##      config block with no CLI override) → OFF.
    ## See `resolveObjCache` (the pure precedence formula, unit-tested
    ## directly) and planImpl, which applies it to cfg.objCache. noObjCache
    ## is INDEPENDENT of noCache (that gates the unrelated result cache).
    ##
    ## measureCompileReuse ALWAYS wins over objCache, regardless of the
    ## precedence above: measurement is an explicit diagnostic that REPLACES
    ## caching for the run it's requested on (a compile slot has exactly one
    ## worker child; the two are mutually exclusive). planImpl suppresses
    ## the resolved objCache value to false whenever measureCompileReuse
    ## ends up true, so spawnCompileStable's own objCache-first branch order
    ## never actually observes both flags on at once — see planImpl and
    ## resolveObjCache's doc for the exact formula.
    objCache*:            bool = false
    noObjCache*:          bool = false

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
    ambiguousPaths*: seq[tuple[path: string; groups: seq[string]]]
                                   ## Issue #3: gskFiles paths that matched more than one
                                   ## candidate group; the first (config order) was used.

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
    compileBlock*:      JsonNode  ## Stage R R5b: the SAME `compile` block persisted to
                                  ## lastrun.json (compilereport.readCompileBlock), exposed here
                                  ## so a caller (e.g. the CLI) can print a human-readable
                                  ## compile/objcache summary line without re-scanning the
                                  ## ledgers. nil when opts.persist is false, or when neither
                                  ## measureCompileReuse nor objCache is enabled (no telemetry).

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

proc shouldReportCompileBlock*(measureCompileReuse, objCache: bool): bool =
  ## R14-T6 (code review): the pure predicate gating whether runTests() even
  ## ATTEMPTS to read/report the `compile` block at all (extracted so the
  ## exact boolean expression is independently unit-testable without a real
  ## compile — a regression flipping `or` -> `and` here would silently drop
  ## the report whenever only ONE of the two flags is set, e.g. a plain
  ## `--objcache` run with measureCompileReuse off). R5b's own fix widened
  ## this from a narrower `measureCompileReuse`-only gate: objCache alone is
  ## enough, because the objcache-stats stream is written independently of
  ## measureCompileReuse (the two compile-slot WORKERS are mutually
  ## exclusive, but the two FEATURES are not — see types.Config.objCache's
  ## doc). Even when this returns true, the actual `compile` field can still
  ## end up absent if no telemetry was ever written this run (see
  ## compilereport.buildCompileBlock's own nil-when-empty contract) — this
  ## predicate only answers "should we even look", not "is there data".
  measureCompileReuse or objCache

proc resolveObjCache*(configValue, optIn, optOut: bool): bool =
  ## RFC-0006 Stage R, R2b2: pure precedence resolution for Config.objCache
  ## from a config-file value (`configValue`) plus RunOptions overrides
  ## (`optIn` = --objcache, `optOut` = --no-objcache). Extracted as a pure
  ## function (rather than inlined in planImpl) so the precedence formula is
  ## independently unit-testable without going through config loading or a
  ## real compile. Precedence (highest wins):
  ##   1. optOut → false, unconditionally (--no-objcache always wins).
  ##   2. optIn or configValue → true (either strengthens ON).
  ##   3. otherwise → false.
  ## This formula is UNCHANGED by the RFC-0006 default-on flip. What changed
  ## is the caller: `configValue` is now `true` by default (config.loadConfig
  ## resolves it that way whenever the KDL `objcache` node is absent — see
  ## config.docToConfig / conventionConfig), so case 2 above is the common
  ## path and case 3 is reachable only via an explicit `objcache #false`
  ## config block with no CLI override.
  ##
  ## NOTE: this formula alone does NOT know about measureCompileReuse.
  ## planImpl (the sole caller) additionally suppresses the result to false
  ## whenever measureCompileReuse resolved true — see planImpl for why
  ## measurement always wins over caching, and this comment for why that
  ## suppression is NOT folded into this function's own signature (kept
  ## pure and single-purpose; the two flags are combined exactly once, at
  ## the call site, where both resolved values already exist).
  (optIn or configValue) and not optOut

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
  # RFC-0006 Stage R, R2b2: resolve objCache precedence (--no-objcache wins).
  #
  # Issue-1 fix: measureCompileReuse ALWAYS suppresses objCache. Before this,
  # objCache defaulting true (the RFC-0006 default-on flip) meant a run that
  # asked ONLY for --measure-compile-reuse still resolved cfg.objCache=true,
  # and runner.spawnCompileStable's branch order (objCache > measure >
  # monolithic) starved measurement of its own worker entirely -- the CACHE
  # worker ran instead, which never writes ArtifactRows/compile.segments.
  # Measurement is an explicit diagnostic that REPLACES caching for the run
  # it's requested on (a compile slot has exactly one worker child), so it
  # must take precedence. Suppressing HERE -- at the resolution layer, before
  # cfg ever reaches spawnCompileStable -- means the two flags are never both
  # "on" by the time the runner looks at them, so runner.nim's own branch
  # order (objCache-first) needs no change and remains correct for the case
  # it now always sees: objCache and measureCompileReuse mutually exclusive.
  cfg.objCache = resolveObjCache(cfg.objCache, opts.objCache, opts.noObjCache) and
                 not cfg.measureCompileReuse

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
    nimVersion   = crisolNimVersion,
    forceCompile = opts.forceCompile,
    warnings     = cfgWarnings,
    shardK       = opts.shardK,
    shardN       = opts.shardN,
    order        = opts.order,   # C4: history-based prioritization
  )

  # Code-review R13: an explicit --objcache / --measure-compile-reuse request
  # that will silently degrade to the monolithic compile path (no
  # workerBinary configured) must be visible in the STRUCTURED warnings
  # channel, not merely runner.nim's one-shot stderr write
  # (warnObjCacheNoWorkerOnce / warnMeasureCompileReuseNoWorkerOnce) — a CI
  # consumer whose stderr is swallowed sees a completely silent no-op of a
  # feature it explicitly asked for (compileBlock simply absent from the
  # report, indistinguishable from "nobody asked"). Reuses the EXISTING
  # ConfigWarning shape (no types.nim change): its fields (source/context/
  # key/message) are generic enough to carry a resolved-config runtime
  # warning, not only a config-file-parse warning. Only ONE of these two
  # fires per run: by this point cfg.objCache has already been suppressed to
  # false whenever cfg.measureCompileReuse is true (Issue-1 fix, above), so
  # the two conditions below are mutually exclusive by construction — computed
  # here from the SAME resolved `cfg` fields runner.nim gates on, so this can
  # never diverge from what actually happens per compile slot.
  var warnings = pv.warnings
  if cfg.workerBinary.len == 0:
    if cfg.objCache:
      warnings.add ConfigWarning(
        source:  "",
        context: "objcache",
        key:     "workerBinary",
        message: "objcache requested (--objcache / config `objcache #true`) " &
                 "but no worker binary is configured; not honored this run " &
                 "-- compiling monolithically (cache skipped). Set " &
                 "RunOptions.workerBinary to a binary that dispatches " &
                 "--internal-compile-worker to get cache reuse.",
      )
    elif cfg.measureCompileReuse:
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

  # Issue-1 fix: BOTH --objcache and --measure-compile-reuse explicitly
  # requested on the SAME run is a contradictory request (a compile slot has
  # exactly one worker child) — measurement wins (see cfg.objCache's
  # suppression above), but the caller who explicitly asked for objcache
  # should be told it was ignored, not left to infer that from an absent
  # "objcache" key in compile.* / an absent objcache/v1 directory. Gated on
  # `opts.objCache`/`opts.measureCompileReuse` (the CALLER'S explicit
  # request), not `cfg.objCache`/`cfg.measureCompileReuse` (the resolved
  # values) — objCache defaulting on (no explicit --objcache) plus an
  # explicit --measure-compile-reuse is NOT a contradiction the caller
  # asked for; it's just the default quietly stepping aside, already covered
  # by the workerBinary warnings above when applicable.
  if opts.objCache and opts.measureCompileReuse:
    warnings.add ConfigWarning(
      source:  "",
      context: "objcache",
      key:     "measure-compile-reuse",
      message: "both --objcache and --measure-compile-reuse were explicitly " &
               "requested; measurement takes precedence for this run -- " &
               "objcache is ignored (measurement is a diagnostic that " &
               "replaces caching, not a mode that composes with it).",
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
    ambiguousPaths: pv.ambiguousPaths,
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
  let spec = resolveSandbox(level = opts.hermeticLevel)
  let cacheCtx =
    if opts.noCache:
      cacheDisabled(spec)   # fully off; spec still governs sandbox hermeticity
    else:
      cacheEnabled(spec,
        CachePolicy(enabled: true),
        realSeams(
          stateDir      = pr.settings.stateDir,
          graph         = addr graph,
          nimVersion    = crisolNimVersion,
          ccVersion     = cachedCcVersion(),
          spec          = spec,
          parentEnv     = toSeq(envPairs()),
          protocolMajor = CrisolProtocolMajor,
        ))

  try:
    results = execute(
      pv.plan,
      config             = cfg,
      graph              = graph,
      nimVersion         = crisolNimVersion,
      onResult           = cb,
      failFast           = opts.failFast,
      showProgress       = opts.showProgress,
      progressIntervalMs = opts.progressIntervalMs,
      memThrottledOut    = addr memThrottled,
      cache              = cacheCtx,
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

  # C6: Annotate results with regression info (if perf-check is enabled).
  # edCached results are excluded (no fresh measurement; never flag a cache hit).
  # For each fresh result, historyUs = prior durationUs rows from the ledger,
  # filtering out compileFailed rows and rows from the current run (timestamp >= runStart).
  if effectivePerfCheck.enabled:
    let resolvedStateDir = pr.settings.stateDir
    for i in 0 ..< results.len:
      let r = results[i]
      # Skip cached results — no fresh measurement, never flag.
      if r.cached:
        continue
      # Skip compile-failed — no run duration to compare.
      if r.outcome == oCompileFailed:
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
  var compileBlock: JsonNode = nil
  if opts.persist:
    # RFC-0006 M-report pass (a) / Stage R R5b: the segmented `compile` block
    # only carries data when EITHER telemetry stream was actually written
    # this run -- avoids a needless ledger disk scan on every ordinary
    # (measurement- and objcache-off) run. R5b: cfg.objCache alone is enough
    # to populate compile.objcache (objcache stats are written independently
    # of measureCompileReuse -- see types.Config.objCache's doc: the two
    # workers are mutually exclusive compile-slot children, not mutually
    # exclusive FEATURES, so a plain --objcache run must still surface its
    # own realized hit/miss telemetry in the report, not just on disk).
    compileBlock =
      if shouldReportCompileBlock(cfg.measureCompileReuse, cfg.objCache):
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

  RunReport(
    plan:              pr,
    summary:           s,
    results:           results,
    memThrottledSlots: memThrottled,
    status:            rsOk,
    exitCode:          exitCode(s, opts.failOnFlaky),  # B1: flaky-pass gating
    compileBlock:      compileBlock,
  )
