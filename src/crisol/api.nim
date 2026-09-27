## crisol/api.nim — the public library boundary (F1, RFC-0003).
##
## This module is THE contracted library surface.  Import only this module
## to embed crisol as a library; all other crisol modules are implementation
## details (importable but uncontracted).
##
## The request/report types and the entry points other than `runTests` are
## defined in `crisol/runcore` (the engine) and re-exported here by name;
## `runTests` is defined here. What this module does not re-export from
## runcore is its test seam -- `RunDeps`, `productionRunDeps`,
## `runTestsWith` -- whose types belong to internal modules.
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
## ## VerifyCache constructors (RFC-0005 B3a; make strict-without-enabled unconstructable)
##
##   noVerify()                          → disabled (RunOptions.verifyCache default)
##   verifySample(pct=-1, seed=none, strict=false) → enabled; --verify-cache facade;
##                                          pct=-1 defers to Config.verifyCachePct
##                                          (r29: resolved in planImpl's merge chain)
##
## ## Public re-exports (selective — see H1)
##
## From types: GroupSelection, GroupSelectionKind, PlannedEntrypoint, Entrypoint,
##   Outcome (+ oPassed/oFailed/etc values), TestRecord, RecordStatus, Summary,
##   GatedEntry, ConfigWarning, CompileDecision, CrisolError, CrisolErrorKind,
##   ResultCallback, EntrypointResult, isFailure, exitCode, RlimitOverrides
## From render: render, gateSkipMessages, pathFlagsWarnings, filterRecordsByTag,
##   hasZeroTagMatches, RenderOpts, defaultOpts
## From jsonout: toJsonString, RunSchema
## From planview: PlanV1Schema (+ PlanReport-typed facade overloads from runcore)
## From runcore: the request/report types and their accessors, the
##   selection/narrowing/verify constructors, planTests, closureReport,
##   planToJsonString, renderPlan (the full list is the `export runcore.*`
##   block below)
##
## NOT re-exported: Config, Gate, Group, GateState, GateStateEntry, DiscoveredSet,
##   RunPlan, persistLastRun, loadLastRun,
##   newCrisolError, ANSI internals (col, Ansi_*, etc.),
##   memThrottleActive, formatProgressLine, planview internals (planToJson,
##   decisionStringEd, decisionLabelEd, warningsToJsonArray), runcore's test
##   seam (RunDeps, productionRunDeps, runTestsWith)

import crisol/[types, render, jsonout, planview, cachetelemetry, order]
# The engine: the contracted request/report types and entry points are
# defined there and re-exported below; its test seam (`RunDeps`,
# `productionRunDeps`, `runTestsWith`) is not.
import crisol/runcore
# rfc-0007 A1c: the §2 result-model facade, re-exported explicitly below.
# `import nil` so nothing unqualified leaks into this module's namespace.
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
export types.RlimitOverrides  # code-review r30: RunOptions.rlimits' / Config.rlimits' type
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

# From jsonout — schema constant + toJsonString + RunDocument only (NOT
# persistLastRun, loadLastRun)
export jsonout.toJsonString
export jsonout.RunDocument  # rfc-0007 r8: RunReport.doc's type
export jsonout.RunSchema
export cachetelemetry.CacheStats  # RFC-0005 B2b: RunReport.cacheStats's type
export jsonout.closureToJsonString
export jsonout.ClosureV1Schema

# From planview — schema constant only; the PlanReport-typed facades are runcore's
export planview.PlanV1Schema

# From order — C4: OrderMode enum + parse (CLI/consumer surface)
export order.OrderMode
export order.parseOrderMode

# From runcore — the contracted request/report surface and entry points.
export runcore.crisolNimVersion
export runcore.RunStatus
export runcore.NarrowingKind
export runcore.RunNarrowing
export runcore.VerifyCache
export runcore.RunOptions
export runcore.ResolvedSettings
export runcore.PlanReport
export runcore.ZeroRunnableReason
export runcore.RunReport
export runcore.VerifyDivergence
export runcore.results
export runcore.summary
export runcore.memThrottledSlots
export runcore.lateOrphansReaped
export runcore.interrupted
export runcore.compileBlock
export runcore.reuseAlerts
export runcore.cacheStats
export runcore.trackedRoots
export runcore.runResult
export runcore.failureLine
export runcore.defaultGroups
export runcore.namedGroups
export runcore.allGroups
export runcore.filesSelection
export runcore.noNarrowing
export runcore.failedOnly
export runcore.changedOnly
export runcore.failedOrChanged
export runcore.noVerify
export runcore.verifySample
export runcore.pairVerifySamples
export runcore.VerifyPassResult
export runcore.verifyCachePass
export runcore.planToJsonString
export runcore.renderPlan
export runcore.shouldReportCompileBlock
export runcore.planTests
export runcore.closureReport

# ---------------------------------------------------------------------------
# runTests — the public, opts-only facade (RFC-0005 A3b)
# ---------------------------------------------------------------------------

proc runTests*(opts: RunOptions = RunOptions()): RunReport =
  ## Full run facade.  Returns outcomes; never raises for expected conditions.
  ## Thin wrapper over `runcore.runTestsWith` with `productionRunDeps()` — the
  ## real dependency (`cacheregistry.configuredCache`, which falls back to
  ## `localOnlyCache` when no `remote-cache` block is configured).
  ## See `runTestsWith`'s doc comment for the full flow; see `RunDeps`'s
  ## for why the split exists.
  ##
  ## **Interrupts.** With `opts.installSignals`, crisol owns SIGINT/SIGTERM
  ## (a console Ctrl-C/Ctrl-Break on Windows) for the whole call and puts the
  ## host's own handlers back when it returns. A signal that lands at any
  ## point of the call, planning through reporting, ends it as
  ## `rsInterrupted` with `interrupted` true and exit code 128 + the signal
  ## (130 SIGINT, 143 SIGTERM), keeping whatever plan and results it has.
  ## That report IS the delivery: crisol does not re-raise the signal to the
  ## host's handler, so a host that wants to stop acts on the report. The one
  ## exception is a REPEATED signal, which is the user insisting: with no
  ## test running, the second signal of the call (with tests running, the
  ## third; the second force-kills them) kills crisol's live tools and ends
  ## the host process at once with exit code 128 + the signal. That is the
  ## price of `installSignals`; a host that must never exit this way leaves
  ## it off. The signal is not carried into the next call: a later
  ## `runTests` starts with no interrupt pending. Without
  ## `opts.installSignals` (the default) crisol installs nothing and a signal
  ## goes wherever the host sends it.
  ##
  ## **Deliberate defense-in-depth (RFC-0005 C4, scope unchanged by D5,
  ## TIMING corrected by code-review R2-D5a):** whenever the cache actually
  ## activates (`opts.noCache == false`, the default), `runTestsWith` (this
  ## call's callee) resolves `$CRISOL_CACHE_HMAC_KEY`/
  ## `$CRISOL_CACHE_SIGN_KEY`/`$CRISOL_CACHE_TOKEN[_<TIER>]` from the
  ## process environment ONCE and then `delEnv`'s the WHOLE `CRISOL_CACHE_*`
  ## namespace (`runcore.resolveCacheSecrets`) — a write credential
  ## must never linger in the process environment for a later, unrelated
  ## child to inherit. D5's fix is scope, not removal: this scrub is
  ## skipped entirely under `opts.noCache: true` (see `RunOptions.noCache`'s
  ## own doc comment) rather than running unconditionally regardless of
  ## whether caching was ever going to touch the network at all. **R2-D5a:
  ## the resolve+scrub itself now happens at the very TOP of
  ## `runcore.runTestsBody` (the first act inside `runTestsWith`'s interrupt
  ## scope) — before `planTests`/`planImpl` and therefore before the Nim
  ## fingerprint-probe child `planImpl` unconditionally spawns — not
  ## merely before `productionRunDeps().buildRuntime` (round-1 D5's
  ## placement, which left that probe child inheriting unscrubbed secrets
  ## on every cache-enabled run).** See `runTestsBody`'s own comment at its
  ## call site for the full rationale.
  runTestsWith(opts, productionRunDeps())
