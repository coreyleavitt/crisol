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
## ## VerifyCache constructors (RFC-0005 B3a; make strict-without-enabled unconstructable)
##
##   noVerify()                          → disabled (RunOptions.verifyCache default)
##   verifySample(pct=5, seed=none, strict=false) → enabled; --verify-cache facade
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
import crisol/[types, config, pipeline, jsonout, render, planview, gitdiff, runner, lock,
               sandbox, cachedispatch, cacheregistry, cachetier, cacheport, cachetelemetry,
               resultcache, ccprobe, nimprobe, planner, order, ledger, keys, depgraph, stats,
               compilereport]
# rfc-0007 A2b: `crisol/signals` (the process-global gotSignal flag) is no
# longer needed to drive `interrupted` — `runner.execute`'s OWN Supervisor
# now owns SIGINT/SIGTERM installation for the duration of the call
# (`installSignals` param, threaded from `opts.installSignals` below) and
# reports the real signum it observed via `shutdownSignalOut`, superseding
# `installSignalHandlers`/`clearSignal`/`pendingSignal`. RFC-0005 code-
# review SO2 reintroduces ONE narrow use: `shutdownRequested()` as the
# `abandoned` predicate for the end-of-run deferred-put drain below, the
# SAME "abandon more I/O on a pending shutdown" query the plan-time
# prefetch/consult loops already use (cachetier.nim/runner.nim).
import crisol/signals
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
export cachetelemetry.CacheStats  # RFC-0005 B2b: RunReport.cacheStats's type
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

  VerifyCache* = object
    ## RFC-0005 Stage B `--verify-cache` facade ("Facade (round 3)"): the
    ## determinism backstop re-executes a sample of this run's `cdmHit`
    ## entries and compares fresh observations against the stored ones.
    ## Constructed via `noVerify()` / `verifySample(pct, seed, strict)` — do
    ## NOT construct directly: "strict without enabled" is structurally
    ## unconstructable via the library API, mirroring `RunNarrowing` above.
    ## B3a ships only this data shape + the pure sampler/synthetic-plan
    ## pieces that will consume it; the post-run pass itself is B3b, the CLI
    ## is B3c.
    enabled*: bool         ## false (default, via noVerify()) = no verify pass
    pct*:     int          ## sample percentage of the hit set; see
                           ## types.sampleHitIndices (max(1, pct*hits/100))
    seed*:    Option[int64] ## none() = a per-run default seed (the CALLER
                            ## reports it in the summary line, B3c); some(n)
                            ## reproduces a specific sample (--verify-cache-seed)
    strict*:  bool         ## a divergence set exits 1 (CI gate); meaningless
                           ## when enabled == false — verifySample() is the
                           ## only way to set it true, and it always implies
                           ## enabled == true

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
                                 ## ON by default. RFC-0005 code-review D5: `true`
                                 ## ALSO skips `resolveCacheSecrets`'s env scan +
                                 ## `delEnv` scrub of the `CRISOL_CACHE_*` namespace
                                 ## (a deliberate defense-in-depth measure, `runTests`'s
                                 ## own doc comment below) — a library embedder that
                                 ## opts out of caching entirely sees no host-process
                                 ## environment mutation from this call at all.
    retries*:      int  = -1     ## B1: global retry count override.  -1 = use config.
                                 ## 0 = no retry (override to no-retry regardless of config).
                                 ## N >= 1 = retry up to N times (maxAttempts = N+1).
    failOnFlaky*:  bool = false  ## B1: when true, a flaky-pass (passed after attempt > 1)
                                 ## contributes to exit 1 instead of exit 0.
    strictHygiene*: bool = false ## rfc-0007 A6b: OutcomePolicy.strictHygiene. When true, a
                                 ## would-be pass with an observed escapee (leaked same-pgroup
                                 ## descendant, A6a) derives oFailed instead of oPassed at every
                                 ## reporting boundary (exit code, render, JSON/junit wire,
                                 ## lastrun.json) — never at the cache's own store/read gate,
                                 ## which stays unstrict always. Can only strengthen a config-file
                                 ## `strict-hygiene #true` (true wins), mirroring
                                 ## measureCompileReuse/perfCheckForce below.
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
    ## RFC-0005 A0: per-run NAME=VALUE pins (CLI `--env-pin`, repeatable).
    ## Merged with `Config.envPins` (KDL `env-pin "NAME" "VALUE"`) in
    ## planImpl via `envPinsFrom` -- a pin here overrides a same-named
    ## config pin (CLI wins), mirroring rlimitNofile's override precedence.
    ## Empty by default: nothing pinned unless an operator opts in.
    envPins*:            seq[(string, string)] = @[]
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
    ## RFC-0005 B3a: the --verify-cache facade. Default-constructed =
    ## noVerify() (VerifyCache's zero value: enabled=false, strict=false —
    ## same "zero value IS the disabled state" convention as narrowing*
    ## above). Nothing consumes this yet; B3b wires the post-run pass.
    verifyCache*:         VerifyCache
    ## RFC-0005 B1c: --explain-miss / --explain-miss-verbose (KDL
    ## `explain-miss`; config < CLI). false by default (identical behavior
    ## to RFC-0004). NEITHER field gates the PRODUCER: `EntrypointResult.
    ## keyDiff` is always populated on a genuine cache-miss decision when a
    ## prior sidecar record exists to diff against (B1b's seam, threaded
    ## through runner.nim unconditionally) -- these two fields gate only
    ## the CLI's RENDERING (render.RenderOpts.explainMiss/-Verbose) and the
    ## run/v2 JSON `keyDiff` field's PRESENCE (jsonout.toJson's
    ## `explainMiss` param), both downstream of RunReport, never the
    ## runner/cachedispatch seam itself. explainMissVerbose implies
    ## explainMiss=true (enforced by the CLI when resolving flags into
    ## this struct; a library caller that sets verbose=true without
    ## explain=true gets no output either way — verbose only ever adds
    ## detail to an already-shown block).
    explainMiss*:         bool = false
    explainMissVerbose*:  bool = false
    ## RFC-0005 B2b: --cache-stats (KDL `cache-stats`; config < CLI). false
    ## by default (identical behavior to before this slice: NilSink,
    ## RunReport.cacheStats a zero value). Gates installing a real
    ## InMemorySink for the run's `CacheContext.sink`/`CacheRuntime.sink`
    ## (see `runTests`) -- a run that never opts in collects no telemetry
    ## events and pays for none of the bookkeeping. api.planImpl merges this
    ## into `cfg.cacheStats` (opt-in-only-strengthen, same shape as
    ## explainMiss); `runTests` reads `cfg.cacheStats`, never this raw field
    ## directly, so a config-file-only opt-in is honored identically.
    cacheStats*:          bool = false
    ## RFC-0005 A3c-ii: --no-remote-cache. Drops every configured
    ## `remote-cache` tier for THIS run -- the local ("l1") cache stays
    ## active, so this is strictly weaker than `noCache` (which disables
    ## caching entirely). No KDL equivalent (the RFC's own "Configuration"
    ## flags list carries this as CLI-only; a config-file remote-cache
    ## block describes what a fleet SHOULD use, not a one-run override).
    ## false by default -- identical behavior to before this slice.
    noRemoteCache*:       bool = false

  ResolvedSettings* = object
    ## Slim projection of the resolved Config (NOT the full Config).
    ## Exposed so a consumer can see what configuration was actually used.
    projectRoot*: string
    stateDir*:    string  ## pre-joined to an ABSOLUTE path (projectRoot/stateDir
                          ## resolved); consumers never need to re-join, unlike
                          ## Config.stateDir which is project-root-relative.
    jobs*:        int     ## resolved (never 0)
    timeoutSecs*: int     ## resolved
    strictHygiene*: bool  ## rfc-0007 A6b: resolved OutcomePolicy.strictHygiene (CLI-flag OR
                          ## config-file, opt-in-only-strengthen) — the CLI layer builds the
                          ## real OutcomePolicy for render/JSON/junit from this, so it never
                          ## has to re-run the merge itself.
    explainMiss*: bool    ## RFC-0005 B1c: resolved --explain-miss (CLI flag OR config-file
                          ## `explain-miss #true`, opt-in-only-strengthen — same shape as
                          ## strictHygiene above). The CLI reads THIS, not its own raw flag
                          ## var, when deciding whether to render the miss-explanation block
                          ## or set the run/v2 `keyDiff` field's presence, so a config-file-only
                          ## `--explain-miss` (no CLI flag passed) is honored identically.
    cacheStats*: bool     ## RFC-0005 B2b: resolved --cache-stats (CLI flag OR config-file
                          ## `cache-stats #true`, opt-in-only-strengthen — same shape as
                          ## explainMiss above). The CLI reads THIS when deciding whether to
                          ## render the cache-stats summary line or set the run/v2
                          ## `cacheStats` field's presence.

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
    verifyDivergences*: seq[VerifyDivergence]  ## RFC-0005 B3b: the --verify-cache
                                  ## post-run pass's findings. ALWAYS empty when
                                  ## opts.verifyCache.enabled is false. Deliberately
                                  ## separate from `results` (guard 3, "execute()
                                  ## re-entrancy... three guards") — a verify
                                  ## re-execution is diagnostic, never a substitute
                                  ## observation for the entrypoint's reported outcome.
    verifyCouldNotReexec*: seq[Entrypoint]  ## RFC-0005 code-review SO4: sampled
                                  ## --verify-cache entries whose fresh
                                  ## re-execution produced NO observation at all
                                  ## (fresh run phase pkSkipped/pkSpawnFailed —
                                  ## e.g. the promoted stable binary vanished
                                  ## between the main run and the verify pass).
                                  ## A verify-INFRASTRUCTURE failure, NOT
                                  ## evidence of cache nondeterminism — never
                                  ## included in `verifyDivergences` (so
                                  ## --verify-cache-strict, which gates on
                                  ## `verifyDivergences.len`, never exits 1 for
                                  ## it), never silent (a stderr warning still
                                  ## names each entry — see verifyCachePass).
                                  ## ALWAYS empty when opts.verifyCache.enabled
                                  ## is false, same convention as
                                  ## verifyDivergences above.
    cacheStats*: CacheStats       ## RFC-0005 B2b: `aggregateCacheStats(events, decisions)`
                                  ## over the run's real telemetry (hit/miss/publish/
                                  ## remote-error/verifyFail) and per-result cacheDecisions.
                                  ## A ZERO-VALUE `CacheStats()` (same "always-present,
                                  ## zero-value-is-honest" convention as `verifyFails`) when
                                  ## `cfg.cacheStats` is false — no InMemorySink was ever
                                  ## installed, so there is nothing real to report; the CLI
                                  ## reads `rr.plan.settings.cacheStats` (not this field's
                                  ## "is it all zero?") to decide whether to show it at all.

  VerifyDivergence* = object
    ## RFC-0005 B3b: one --verify-cache mismatch between the observation the
    ## main run SERVED from the cache (a `cdmHit`) and the observation a
    ## fresh, forced-live re-execution of the SAME sampled entry actually
    ## produced. Comparison is structural — `Exit` (`==` over the variant,
    ## `process/types`) and parsed `records` (name/status/msg/tags; per-
    ## record `durationUs` excluded) — and NEVER outcome strings: `outcome`
    ## is a derived, policy-dependent projection, and two distinct
    ## observations can legitimately derive the same verdict, which is
    ## exactly the nondeterminism this pass exists to catch.
    ##
    ## `Cause`/`Evidence`/`rusage`/durations are excluded from the
    ## COMPARISON (authorship, tier and accounting of the fresh attempt
    ## legitimately differ from the stored one) but are carried here in full
    ## — via the complete `Phase` on both sides — for diagnosis.
    ep*:              Entrypoint
    exitDiverged*:    bool
    recordsDiverged*: bool
    storedRun*:       ptypes.Phase       ## the Phase served by the main run (pkCached)
    freshRun*:        ptypes.Phase       ## the Phase the verify pass observed (pkRan)
    storedRecords*:   seq[TestRecord]
    freshRecords*:    seq[TestRecord]

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

proc failureLine*(r: EntrypointResult;
                  policy: ptypes.OutcomePolicy = ptypes.DefaultPolicy): string =
  ## Render-grade one-liner for a failing/non-passed result — the digest a
  ## caller building its own UI needs without re-deriving cause/exit detail.
  ## "" for a passing result (outcome(r, policy) == oPassed).
  ## policy: rfc-0007 A6b — a library caller building custom UI under
  ## --strict-hygiene passes the same resolved policy it used elsewhere
  ## (e.g. RunOptions.strictHygiene) so this digest agrees with exitCode.
  ## Defaults to DefaultPolicy so existing callers are unchanged.
  case outcome(r, policy)
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
# VerifyCache constructors — RFC-0005 B3a
# ---------------------------------------------------------------------------

proc noVerify*(): VerifyCache =
  ## No --verify-cache pass (the default).
  VerifyCache(enabled: false, pct: 0, seed: none(int64), strict: false)

proc verifySample*(pct: int = 5; seed: Option[int64] = none(int64);
                   strict: bool = false): VerifyCache =
  ## Enable the --verify-cache pass. `pct` (default 5, matching
  ## --verify-cache-pct's default) is the sample percentage of the hit set;
  ## `pct <= 0` disables sampling regardless of `enabled` (see
  ## types.sampleHitIndices). `seed` none() = a per-run default (the caller
  ## reports it in the summary line); some(n) reproduces one specific
  ## sample. `strict` = a divergence set exits 1 — always paired with
  ## enabled == true here, so "strict without enabled" never arises.
  VerifyCache(enabled: true, pct: pct, seed: seed, strict: strict)

# ---------------------------------------------------------------------------
# --verify-cache post-run pass — RFC-0005 B3b
# ---------------------------------------------------------------------------

proc defaultVerifySeed(): int64 =
  ## RFC-0005 §Stage B: "the seed defaults to a per-run value ... so
  ## coverage broadens across runs in expectation." Reporting the resolved
  ## seed in the summary line is B3c's CLI/config concern; this is only the
  ## resolution `verifyCachePass` needs when the caller hasn't pinned one
  ## via `verifySample(seed = some(n))`.
  int64(epochTime() * 1_000_000.0)

proc phaseExit(p: ptypes.Phase): Option[ptypes.Exit] =
  if p.kind in {ptypes.pkRan, ptypes.pkCached}: some(p.res.exit)
  else: none(ptypes.Exit)

proc exitsDiverge(a, b: Option[ptypes.Exit]): bool =
  ## `ptypes.Exit` is imported `import nil` (see the module-doc note on
  ## `ptypes` above) so its custom structural `==` (process/types.nim,
  ## "==(Exit) in process/types" — the RFC's own anchor) is never in scope
  ## unqualified; a plain `a != b` on `Option[Exit]` would silently fall
  ## back to the compiler's builtin case-object comparison (which cannot
  ## even compile for a case object — the `fields` iterator rejects it), so
  ## this calls the qualified `ptypes.`==`` explicitly.
  if a.isSome != b.isSome: return true
  if a.isNone: return false   # both none
  not ptypes.`==`(a.get, b.get)

proc recordsDiverge(a, b: seq[TestRecord]): bool =
  ## RFC-0005 §Stage B: name/status/msg/tags compared; per-record
  ## `durationUs` deliberately excluded (legitimately differs run to run).
  if a.len != b.len: return true
  for i in 0 ..< a.len:
    if a[i].name != b[i].name or a[i].status != b[i].status or
       a[i].msg != b[i].msg or a[i].tags != b[i].tags:
      return true
  false

type
  VerifyPassResult* = tuple
    divergences:    seq[VerifyDivergence]
    couldNotReexec: seq[Entrypoint]
    ## RFC-0005 code-review SO4: entries sampled for --verify-cache whose
    ## fresh re-execution never produced an observation at all (fresh run
    ## phase `pkSkipped`/`pkSpawnFailed` — e.g. the promoted stable binary
    ## vanished between the main run and this verify sub-run, or the verify
    ## sub-run itself got killed). A verify-INFRASTRUCTURE failure, NOT
    ## evidence of cache nondeterminism — never counted in `divergences`
    ## (so --verify-cache-strict, which gates on `divergences.len`, must
    ## never exit 1 for it), never silent (verifyCachePass still warns
    ## on stderr for every entry landing here).

proc verifyCachePass*(results: seq[EntrypointResult];
                     entrypoints: seq[PlannedEntrypoint];
                     vc: VerifyCache; config: Config; graph: var DepGraph;
                     nimVersion, ccVersion: string;
                     sandboxSpec: SandboxSpec;
                     sink: TelemetrySink[TelemetryEvent] = NilSink[TelemetryEvent]()
                     ): VerifyPassResult =
  ## The --verify-cache determinism backstop (RFC-0005 §Stage B). Samples
  ## this run's `cdmHit` entries (seeded sampler, B3a `sampleHitIndices`),
  ## builds a SYNTHETIC plan from them (B3a `buildVerifyPlan` — never a
  ## re-`plan()`), and re-executes that plan with the cache forced OFF (a
  ## verify run must genuinely execute, never re-hit) to compare each fresh
  ## observation against the one served during the main run.
  ##
  ## `execute()` re-entrancy — three guards:
  ##   1. `onResult = noopResult` — no caller callback fires for verify attempts.
  ##   2. `recordLedger = false` — verify re-runs never pollute
  ##      --order/perf-check/--shard ledger history.
  ##   3. Verify results are returned HERE, never merged into the caller's
  ##      `results` / `RunReport.results`.
  ##
  ## Caller contract: must be invoked AFTER `persistLastRun` and BEFORE
  ## `releaseLock` — the binary precondition (`cdmHit` this run implies
  ## `edRunFresh` at plan time, i.e. the binary exists) holds only while the
  ## stateDir lock is held, and lastrun.json must reflect the main run only.
  ##
  ## Exported* (RFC-0005 B2a) so a test can drive this pass directly — with
  ## its own `results`/`entrypoints` built via `runner.execute` + a real
  ## `CacheRuntime`/`InMemorySink` — without needing the `--cache-stats`
  ## surface `runTests*` doesn't install until Stage B2b. `runTests*` also
  ## calls THIS proc directly (not a wrapper) so it can thread
  ## `couldNotReexec` onto `RunReport` alongside `divergences`.
  ##
  ## **RFC-0005 code-review R2-D2:** the `verifyCachePass*` back-compat
  ## FACADE that used to sit here (returning only `.divergences`, this
  ## proc's pre-SO4 return shape) is deleted — the feature was unreleased
  ## when that wrapper was added, so "back-compat" named an obligation that
  ## never existed, and it had zero production callers (`runTests*` always
  ## called this proc, never the wrapper). Both of its test callers
  ## (`test_api.nim`, `test_cachedispatch.nim`) now call THIS proc directly
  ## and project `.divergences` themselves.
  if not vc.enabled: return (divergences: newSeq[VerifyDivergence](), couldNotReexec: newSeq[Entrypoint]())

  let decisions = results.mapIt(it.cacheDecision)
  let seed = vc.seed.get(defaultVerifySeed())
  let indices = sampleHitIndices(decisions, vc.pct, seed)
  if indices.len == 0: return (divergences: newSeq[VerifyDivergence](), couldNotReexec: newSeq[Entrypoint]())

  let verifyPlan = buildVerifyPlan(entrypoints, indices)
  var verifyResults: seq[EntrypointResult]
  try:
    verifyResults = execute(
      verifyPlan,
      config       = config,
      graph        = graph,
      nimVersion   = nimVersion,
      ccVersion    = ccVersion,
      onResult     = noopResult,
      failFast     = false,
      showProgress = false,
      cache        = cacheDisabled(sandboxSpec),
      recordLedger = false,
    )
  except Exception as e:
    # Matches runTests' own defensive posture around the main execute() call
    # (CrisolError is-a Exception — one branch covers both): an unrelated
    # verify-pass failure must never take down an otherwise-successful main
    # run's real results.
    stderr.write("crisol: warning: --verify-cache pass failed: " & e.msg & "\n")
    return (divergences: newSeq[VerifyDivergence](), couldNotReexec: newSeq[Entrypoint]())

  for j, i in indices:
    if j >= verifyResults.len: break   # defensive: an interrupted verify sub-run
    let stored = results[i]
    let fresh  = verifyResults[j]
    let freshExit = phaseExit(fresh.run)

    # RFC-0005 code-review SO4 fix: a stored `cdmHit` always has a real
    # observation (`stored.run.kind` is `pkCached` — `phaseExit` is always
    # `some` for it), so it is ONLY the fresh side that can come back with
    # no observation at all: `fresh.run.kind` in `{pkSkipped,
    # pkSpawnFailed}` (e.g. `spawnRunDirect` failed because the sampled
    # entry's promoted stable binary was missing/unreadable when this
    # verify sub-run tried to reuse it — see buildVerifyPlan's SO5 fix).
    # Before this fix, `exitsDiverge`'s `a.isSome != b.isSome` branch
    # counted that as an EXIT divergence — a verify-INFRASTRUCTURE failure
    # misfiled as evidence of cache nondeterminism, tripping
    # --verify-cache-strict for a reason that has nothing to do with the
    # cache. This never happened at all if the comparison itself never
    # ran, so it is reported in its own category instead.
    if freshExit.isNone:
      result.couldNotReexec.add stored.ep
      stderr.write("crisol: warning: --verify-cache could not re-execute " &
                   stored.ep.path & " (verify sub-run phase: " &
                   $fresh.run.kind & "); not counted as a divergence\n")
      try: stderr.flushFile() except CatchableError: discard
      continue

    let exitDiverged = exitsDiverge(phaseExit(stored.run), freshExit)
    let recDiverged  = recordsDiverge(stored.records, fresh.records)
    if not (exitDiverged or recDiverged): continue

    result.divergences.add VerifyDivergence(
      ep:              stored.ep,
      exitDiverged:    exitDiverged,
      recordsDiverged: recDiverged,
      storedRun:       stored.run,
      freshRun:        fresh.run,
      storedRecords:   stored.records,
      freshRecords:    fresh.records,
    )
    # RFC-0005 B2a: the landed B3c divergence path's telemetry event.
    sink.emit(TelemetryEvent(kind: tekVerifyFail, path: stored.ep.path))

    var what: seq[string]
    if exitDiverged: what.add "exit"
    if recDiverged:  what.add "records"
    stderr.write("crisol: warning: --verify-cache divergence for " &
                 stored.ep.path & " (" & what.join(", ") &
                 " diverged from the cached result)\n")
    try: stderr.flushFile() except CatchableError: discard

# ---------------------------------------------------------------------------
# H2 — PlanReport-typed facade overloads for planview procs
# ---------------------------------------------------------------------------

proc toRunPlan(report: PlanReport): RunPlan =
  ## Private helper: reconstruct a RunPlan from the inlined PlanReport fields.
  RunPlan(entrypoints: report.entrypoints, jobs: report.jobs)

proc planToJsonString*(report: PlanReport; substrate: ptypes.Capabilities = ptypes.Capabilities()): string =
  ## Facade: serialize the plan to crisol/plan/v1 JSON from a PlanReport.
  ## PlanReport carries its own warnings; no separate warnings param needed.
  ## substrate: rfc-0007 A7 — threads through to planview.planToJsonString
  ## unchanged; defaults to an all-false Capabilities() for callers that
  ## never populate it for real (see planview.planToJson's doc comment).
  planview.planToJsonString(report.toRunPlan, report.gatedOut, report.warnings, substrate)

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

proc envPinsFrom*(cfg: Config; opts: RunOptions): seq[(string, string)] =
  ## RFC-0005 A0: pure projection merging `Config.envPins` (KDL) with
  ## `RunOptions.envPins` (CLI/library `--env-pin`) into the final pin set
  ## `resolveSandbox` receives.  A CLI pin overrides a same-named config pin
  ## (`sandbox.overrideByName`'s override side); a config-only pin passes
  ## through unchanged. Extracted (like `rlimitOverridesFrom` above) so the
  ## merge is independently unit-testable without a real run.
  overrideByName(cfg.envPins, opts.envPins)

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
  # rfc-0007 A6b: CLI/library --strict-hygiene can only strengthen a
  # config-file setting (true wins), mirroring measureCompileReuse above.
  if opts.strictHygiene: cfg.strictHygiene = true
  # RFC-0005 B1c: CLI/library --explain-miss (or --explain-miss-verbose,
  # which the CLI resolves into opts.explainMiss too) can only strengthen a
  # config-file `explain-miss #true` setting (true wins), mirroring
  # strictHygiene/measureCompileReuse above.
  if opts.explainMiss: cfg.explainMiss = true
  # RFC-0005 B2b: CLI/library --cache-stats can only strengthen a
  # config-file `cache-stats #true` setting, same shape as explainMiss above.
  if opts.cacheStats: cfg.cacheStats = true
  if opts.workerBinary.len > 0: cfg.workerBinary = opts.workerBinary
  # Fix 1: RunOptions.rlimitNofile, when set, overrides Config.rlimitNofile.
  if opts.rlimitNofile.isSome: cfg.rlimitNofile = opts.rlimitNofile
  # RFC-0005 A0: merge CLI/library --env-pin into the config-declared pins
  # (CLI wins on a name collision); resolveSandbox reads cfg.envPins below.
  cfg.envPins = envPinsFrom(cfg, opts)

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
    strictHygiene: cfg.strictHygiene,  # rfc-0007 A6b
    explainMiss:   cfg.explainMiss,    # RFC-0005 B1c
    cacheStats:    cfg.cacheStats,     # RFC-0005 B2b
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
# CacheDeps — the test-injection seam for runTestsWith (RFC-0005 A3b)
# ---------------------------------------------------------------------------

type
  CacheDeps* = object
    ## RFC-0005 "Test injection without a facade leak": `RunOptions.
    ## cacheRuntime: Option[CacheRuntime]` was rejected (round 3) because it
    ## would leak `cacheport`'s whole type graph into the CONTRACTED
    ## `crisol/api` facade. Instead `runTestsWith*(opts, deps: CacheDeps)`
    ## is an internal, documented-uncontracted entry point; `runTests*`
    ## (below) is the public facade and always builds `productionCacheDeps()`.
    ##
    ## **A3b interim shape (judgment call, recorded):** the RFC's inline
    ## sketch gives `CacheDeps`'s END-STATE shape as `{registry:
    ## BackendRegistry, secrets: CacheSecrets, sink: TelemetrySink}`, fed
    ## into `configuredCache(cfg, stateDir, reg, secrets, sink)`. Neither
    ## `configuredCache` nor `CacheSecrets` exist yet — both are A3c/C-dep
    ## (the KDL remote-tier parse + trust-secret env resolution), and A3b's
    ## own bullet scope names only types.nim/cachedispatch.nim/runner.nim/
    ## jsonout.nim/api.nim — `cacheregistry.nim` (where `configuredCache`
    ## would live) is out of scope this slice. A3b's actual need — E2E-A-
    ## trust's "two `memory` tiers + a mock `TrustPolicy` through
    ## `runTestsWith`" — only requires a seam that can hand back an
    ## arbitrary, fully-built `CacheRuntime` once `stateDir`/`maxEntries`
    ## are known (post-plan; `runTests` cannot resolve them any earlier
    ## today either — see the `localOnlyCache` call site this replaces).
    ## `buildRuntime` is that narrowest seam: a test closes over pre-built
    ## `memory://` backends + a mock policy and returns the SAME
    ## `CacheRuntime` value on every call, so a warm second `runTestsWith`
    ## call sees what the first one stored (the backends' own `Table`
    ## state — not `rt` identity — is what persists; see `cachememory.nim`).
    ##
    ## **A3c-ii reshape (recorded):** `buildRuntime` now takes `cfg:
    ## CacheConfig` (the run's resolved `Config.cache`, i.e. the parsed
    ## `remote-cache "<name>" { }` blocks) as its first argument, so
    ## `productionCacheDeps` (below) can wire the REAL `configuredCache`
    ## into the production path. The RFC's end-state sketch also threads a
    ## `registry: BackendRegistry` field on `CacheDeps` itself; that is NOT
    ## added here — `productionCacheDeps`'s closure captures
    ## `productionRegistry()` directly (a fresh, cheap-to-build value; no
    ## state to share across calls), and a test wanting a different
    ## registry (e.g. one more scheme than `productionRegistry` ships)
    ## overrides `buildRuntime` wholesale, exactly as A3b's mock-policy test
    ## already does — a `registry` field with a single caller (this same
    ## closure) would be indirection with no consumer. `secrets:
    ## CacheSecrets` is likewise NOT added as a `CacheDeps` FIELD: a test
    ## wanting different secrets overrides `buildRuntime` wholesale (as
    ## A3b's mock-policy test already does), so a `secrets` field on
    ## `CacheDeps` itself would be a second way to reach the same one call
    ## site. `http`/`s3` credentials (`httpTokens`) arrive in C3b the same
    ## way.
    ##
    ## **RFC-0005 code-review R2-D5a reshape:** `buildRuntime` now takes a
    ## fourth argument, `resolvedSecrets: CacheSecrets`, handed to it by
    ## `runTestsWith` at the call site rather than resolved inside the
    ## closure. Round-1's D5 fix made `productionCacheDeps`'s closure call
    ## `resolveCacheSecrets()` itself, lazily, so a `noCache: true` run paid
    ## no env-scan/scrub cost — but that closure only runs AFTER
    ## `planImpl`, which unconditionally spawns the Nim fingerprint-probe
    ## child (`buildRunPlan`'s `cachedNimFingerprint()` argument, evaluated
    ## before `buildRunPlan` itself, let alone before `buildRuntime`) — so
    ## every cache-enabled run's probe child inherited the UNSCRUBBED
    ## `CRISOL_CACHE_*` namespace regardless. `runTestsWith` now resolves
    ## and scrubs ONCE, at its own top, still gated on `not opts.noCache`
    ## (the D5 guarantee is unchanged — see its own comment there), and
    ## passes the result down through this parameter. `productionCacheDeps`
    ## (below) no longer calls `resolveCacheSecrets` at all — it just wires
    ## whatever it is handed into `configuredCache`. A test double that
    ## wants its OWN fixed secrets (the C3b/C6 http/s3 suites, the trust
    ## E2E suites) names this parameter `resolvedSecrets` too but never
    ## reads it — it closes over its own `secrets` local instead, exactly
    ## as before this reshape.
    buildRuntime*: proc(cfg: CacheConfig; stateDir: string; maxEntries: int;
                        resolvedSecrets: CacheSecrets): CacheRuntime {.closure.}

const CrisolCacheSecretPrefix = "CRISOL_CACHE_"
  ## RFC-0005 C4 "Secrets come from the environment... are then removed
  ## from the process environment": mirrors `sandbox.nim`'s own
  ## `CrisolCachePrefix` constant (the child-env scrub) — kept as a
  ## SEPARATE local constant rather than importing `sandbox`'s (which is
  ## private/unexported there) since the two scrubs are independent
  ## concerns run at different times (process env once here, vs. every
  ## spawned child's env in `filterEnv`) and this module already imports
  ## `sandbox` for its public surface only.

const CrisolCacheTokenPrefix = "CRISOL_CACHE_TOKEN"
  ## RFC-0005 C3b: `$CRISOL_CACHE_TOKEN` (bare) and `$CRISOL_CACHE_TOKEN_
  ## <TIER>` (suffixed) both start with this. Matched with a plain
  ## `startsWith` (not `==`/an underscore-boundary check) so the bare name
  ## itself and every suffixed variant are both caught by ONE scan.

proc resolveCacheSecrets(): CacheSecrets =
  ## RFC-0005 C4/C5a/C3b "resolved once in api.nim from env, then delEnv'd":
  ## reads every secret this slice knows about ($CRISOL_CACHE_HMAC_KEY,
  ## $CRISOL_CACHE_SIGN_KEY, $CRISOL_CACHE_TOKEN[_<TIER>]), THEN scrubs the
  ## WHOLE `CRISOL_CACHE_*` namespace from the process environment — not
  ## merely the vars just read — so a var this slice does not yet consume
  ## can never reach a `--hermetic none` child's full-parent-env
  ## passthrough either (`sandbox.filterEnv`'s own tail strips the SAME
  ## prefix a second time, unconditionally, at every hermeticity level —
  ## belt and suspenders: this proc's scrub means there is nothing left to
  ## strip by the time a child spawns; `filterEnv`'s own scrub covers any
  ## process that reads the environment before this proc ever runs).
  ## Secrets live only in the `CacheSecrets` value returned here (and
  ## whatever closure captures it) from this point on — no cache module
  ## ever calls `getEnv`.
  ##
  ## **`$CRISOL_CACHE_TOKEN[_<TIER>]` capture (RFC-0005 C3b), a genuine
  ## ordering constraint, not a style choice:** this proc runs BEFORE the
  ## KDL config is even parsed (`productionCacheDeps()` is called at
  ## `runTests`'s own call site, ahead of `runTestsWith` -> `planImpl` ->
  ## `loadConfig`), so the configured remote-cache tier NAMES do not exist
  ## yet — there is no `tierName -> token` lookup to build. Every
  ## `CRISOL_CACHE_TOKEN*` var is instead captured HERE, keyed by its own
  ## raw env-var SUFFIX (`""` for the bare name, `"MIRROR"` for `_MIRROR`),
  ## before the unconditional scrub below deletes it from the process env.
  ## `cacheregistry.httpTokenFor` re-derives a configured tier's expected
  ## suffix from its NAME (upper-cased, `-`->`_`) once `configuredCache`
  ## actually has one, and looks it up in this already-captured table —
  ## so the value survives the scrub even though the name it will
  ## eventually be requested under is not known here.
  let hmacKey = getEnv("CRISOL_CACHE_HMAC_KEY")
  # RFC-0005 C5a: $CRISOL_CACHE_SIGN_KEY (base64 of the 32-byte ed25519
  # seed) is captured here as the RAW STRING (not yet decoded to a
  # `sello.Seed`) -- see `CacheSecrets.signSeedB64`'s doc comment
  # (`cacheregistry.nim`) for why: the actual base64 -> `Seed` decode
  # happens fresh, on demand, inside `buildTrustPolicy`'s "ed25519" branch.
  let signSeedB64 = getEnv("CRISOL_CACHE_SIGN_KEY")
  let bareToken = getEnv("CRISOL_CACHE_TOKEN")
  var httpTokens: Table[string, string]
  for name in toSeq(envPairs()).mapIt(it.key):
    if name.startsWith(CrisolCacheTokenPrefix & "_"):
      httpTokens[name[(CrisolCacheTokenPrefix.len + 1) .. ^1]] = getEnv(name)
  result = CacheSecrets(
    hmacKey:          if hmacKey.len > 0: some(hmacKey) else: none(string),
    signSeedB64:      signSeedB64,
    defaultHttpToken: if bareToken.len > 0: some(bareToken) else: none(string),
    httpTokens:       httpTokens,
  )
  for name in toSeq(envPairs()).mapIt(it.key):
    if name.startsWith(CrisolCacheSecretPrefix):
      delEnv(name)

proc productionCacheDeps*(): CacheDeps =
  ## The real dependency: RFC-0005 A3c-ii/C4/C3b's `configuredCache`, via
  ## `productionRegistry()` (RFC-0005 C3b: `file`/`http`/`https`/`s3`, the
  ## latter three over `httpraw.rawHttpFetcher()`, `productionRegistry`'s
  ## own default), and a `NilSink` (the run's real sink, when
  ## `--cache-stats` is on, is installed by `runTestsWith` AFTER
  ## `buildRuntime` returns, exactly as it already did for `localOnlyCache`
  ## before this slice).
  ##
  ## **RFC-0005 code-review R2-D5a: no longer resolves `CacheSecrets`
  ## itself, eagerly OR lazily.** Round-1's D5 fix deferred
  ## `resolveCacheSecrets()` into this closure so a `noCache: true` run
  ## never paid its env-scan/scrub cost — correct in isolation, but it left
  ## the scrub running AFTER `planImpl`, which unconditionally spawns the
  ## Nim fingerprint-probe child (`cachedNimFingerprint()`, evaluated as a
  ## `buildRunPlan` argument before `buildRunPlan` itself runs, let alone
  ## before this closure) — so that child inherited the unscrubbed
  ## `CRISOL_CACHE_*` namespace on every cache-enabled run regardless. The
  ## resolve+scrub now happens ONCE, at the very top of `runTestsWith`
  ## (still gated on `not opts.noCache` — the D5 guarantee is unchanged),
  ## strictly before `planImpl`/any child ever spawns; the resolved
  ## `CacheSecrets` value is threaded down through `buildRuntime`'s new
  ## `resolvedSecrets` parameter instead of being re-derived here.
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int;
                              resolvedSecrets: CacheSecrets): CacheRuntime =
    configuredCache(cfg, stateDir, maxEntries, productionRegistry(), resolvedSecrets, NilSink[TelemetryEvent]()))

# ---------------------------------------------------------------------------
# runTestsWith — full run facade; catches-and-encodes structural failures.
# INTERNAL / documented-uncontracted (RFC-0005 A3b) — `deps` reaches into
# cache-module internals a `crisol/api` consumer should never need to import;
# `runTests` (below) is the public, opts-only facade.
# ---------------------------------------------------------------------------

proc runTestsWith*(opts: RunOptions; deps: CacheDeps): RunReport =
  ## Full run facade.  Returns outcomes; never raises for expected conditions.
  ## Structural problems are encoded in RunReport.status / .error / .exitCode.
  ##
  ## Flow on rsOk path:
  ##   [acquireLock if opts.manageLock]
  ##   → planTests(opts) (CATCHES CrisolError → rsStructural)
  ##   → zero-runnable mapping (per RFC-0003 error table)
  ##   → execute (installSignals = opts.installSignals) → summarize
  ##   → [persistLastRun if opts.persist]
  ##   → map exitCode (0 all-passed / 1 any-failure)
  ##
  ## Lock released explicitly on EVERY exit branch (success / structural / interrupt).
  ## rfc-0007 A1e-ii: SIGINT/SIGTERM → rsInterrupted, `interrupted: true`,
  ##   exitCode = 128 + signum. CrisolInterrupted is retired — execute()
  ##   returns normally with §2's emission set: `results`/`summary` are
  ##   populated (not empty), `onResult` already fired for every killed
  ##   final, and lastrun.json is deliberately never persisted for this run.
  ## rfc-0007 A2b: signal installation and capture are now entirely owned by
  ## `execute`'s OWN per-call Supervisor (`installSignals = opts.installSignals`
  ## below) — there is no process-global flag left to clear/stale-check at
  ## entry (each call's Supervisor starts with an empty pending-shutdown
  ## queue), so the old `clearSignal()` ceremony has no counterpart here.

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

  # RFC-0005 code-review R2-D5a: resolve + scrub `CRISOL_CACHE_*` FIRST —
  # strictly before `planImpl` (and therefore before ITS unconditional Nim
  # fingerprint-probe child spawn, `buildRunPlan`'s `cachedNimFingerprint()`
  # argument) and before ANY other child this call could ever spawn. The
  # round-1 D5 fix deferred the resolve+scrub into `productionCacheDeps`'s
  # `buildRuntime` closure, which only runs below, AFTER `planImpl` returns
  # successfully — so the probe child inherited the unscrubbed namespace on
  # every cache-enabled run. Gated on `not opts.noCache`, exactly as D5
  # requires: a `noCache: true` caller performs ZERO env mutation (see the
  # "noCache: true -> CRISOL_CACHE_* env is left untouched" test) — env is
  # resolved and scrubbed before planTests or any child ever spawns.
  var secrets: CacheSecrets
  if not opts.noCache:
    secrets = resolveCacheSecrets()

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

  # RFC-0005 A3c-ii: build the run's CacheRuntime (configuredCache, or
  # localOnlyCache when no remote tier is configured) HERE — still inside
  # the plan's structural-failure boundary, BEFORE acquireLock — so a
  # rejected remote-cache config (an "l1"-named remote, a file:// root
  # inside stateDir, an unresolvable scheme) is a plan-time exit 3, exactly
  # like a bad group/glob, never a lock-then-fail (RFC: configuredCache "is
  # invoked INSIDE the plan try, BEFORE acquireLock"). `rt` stays nil
  # (`CacheRuntime`'s ref zero value) when `opts.noCache` is set — nothing
  # below ever dereferences it on that path. `maxCacheEntries` mirrors
  # clean.nim's own resolution of the SAME config field (0 = use
  # DefaultMaxCacheEntries) so the live store path's soft cap and `clean`'s
  # GC target agree — one knob, one resolution rule, both readers of it.
  var rt: CacheRuntime
  if not opts.noCache:
    let maxCacheEntries =
      if cfg.maxCacheEntries > 0: cfg.maxCacheEntries
      else: DefaultMaxCacheEntries
    # RFC-0005 A3c-ii: --no-remote-cache drops every configured remote tier
    # for this run — the local ("l1") cache stays active (configuredCache
    # degrades to its localOnlyCache-equivalent path when `remotes` is empty).
    let effectiveCacheCfg =
      if opts.noRemoteCache: CacheConfig(remotes: @[])
      else: cfg.cache
    try:
      # R2-D5a: `secrets` was already resolved (+ scrubbed) above, before
      # `planImpl` — this is a plain pass-through, not a new resolution.
      rt = deps.buildRuntime(effectiveCacheCfg, pr.settings.stateDir, maxCacheEntries, secrets)
    except CrisolError as e:
      let code = if e.kind == cekInternal: 2 else: 3
      return structuralResultWithPlan(e.msg, code, pr)

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
                              rlimits = rlimitOverridesFrom(cfg),
                              envPins = cfg.envPins)
  # nimcache-persistence (RFC-0006): the SAME ccVersion/nimVersion probes
  # already used by RFC-0004's SoundnessKey (via realSeams below) are reused
  # here — folded into execute()'s toolchain fingerprint, which keys the
  # persistent nimcache path. One probe each, two consumers; never diverge.
  # nimVer is the RUNTIME fingerprint (nimprobe.cachedNimFingerprint) — not
  # crisolNimVersion — so a stock->patched compiler swap at the same version
  # STRING is soundly distinguished; see the module-doc note above.
  let ccVer  = cachedCcVersion()
  let nimVer = cachedNimFingerprint()
  # RFC-0005 B2b: --cache-stats installs a REAL InMemorySink in place of the
  # default NilSink so the run's hit/miss/publish/remote-error/verifyFail
  # events are actually collected. `cfg.cacheStats` is the RESOLVED value
  # (CLI flag OR config-file `cache-stats #true`, already merged above) —
  # reading it here, not opts.cacheStats directly, matches explainMiss's own
  # precedent. `nil` (not installed) when the run never asked for telemetry:
  # NilSink stays free, exactly as before this slice. `RunReport.cacheStats`
  # stays the documented zero value on this path — see the `cacheStats`
  # local built from `statsSink` (not `warnSink` below) further down.
  let statsSink = if cfg.cacheStats: newInMemorySink() else: nil
  # RFC-0005 code-review L2: the RFC-pinned per-tier 100%-error/breaker
  # stderr warning ("Hit-rate telemetry") is UNCONDITIONAL — it must fire on
  # a default run too, not only under --cache-stats. `erroredTiers` folds
  # over collected events, so it needs a REAL sink even when `statsSink`
  # above is `nil`. `warnSink` reuses `statsSink`'s own collector when
  # `--cache-stats` already installed one (same events, no double
  # collection, no double warning) and falls back to a fresh, cheap
  # `InMemorySink` dedicated ONLY to this fold otherwise -- `RunReport.
  # cacheStats`/the run/v2 `cacheStats` object stay wired to `statsSink`
  # specifically (see the `cacheStats` local below), so this does not
  # disturb their documented "zero value / absent when --cache-stats is
  # off" contract.
  let warnSink = if statsSink != nil: statsSink else: newInMemorySink()
  let cacheCtx =
    if opts.noCache:
      var ctx = cacheDisabled(spec)   # fully off; spec still governs sandbox hermeticity
      ctx.sink = warnSink.sink()
      ctx
    else:
      # RFC-0005 A2b: keyContext built once (the key-derivation closure's
      # captured state). `rt` (RFC-0005 A3c-ii: `configuredCache`/
      # `localOnlyCache` via `deps.buildRuntime` — production: a single-tier
      # "l1" TieredCache over the local-fs backend when no remote is
      # configured, behaviorally identical to RFC-0004's direct
      # loadCached/storeCached; tests: an injected multi-tier double, see
      # CacheDeps's doc comment) was already built above, BEFORE the lock.
      let keyCtx = keyContext(
        nimVersion    = nimVer,
        ccVersion     = ccVer,
        spec          = spec,
        parentEnv     = toSeq(envPairs()),
        protocolMajor = CrisolProtocolMajor,
      )
      # RFC-0005 B2b/L2: override BEFORE realSeams closes over `rt` —
      # realSeams' own store closure reads `rt.sink` (its embedded copy),
      # so the swap must happen here, not on the CacheContext built below
      # (that sink only reaches lookupAtPlan's hit/miss emission, the READ
      # side). Unconditional (`warnSink`, not `if statsSink != nil`) since
      # L2: the per-tier error warning needs real events collected on
      # every run, not only under --cache-stats.
      rt.sink = warnSink.sink()
      cacheEnabled(spec,
        CachePolicy(enabled: true),
        realSeams(keyCtx, addr graph, rt),
        rt.sink,          # RFC-0005 B2a/L2: always `warnSink` now (statsSink's own
                          # collector when --cache-stats is on, else a dedicated one)
        realPrefetch(rt), # RFC-0005 C3c: resolves each canProbe tier's key-existence set once
        # RFC-0005 SO1 fix: the run's resolved reporting policy, threaded to
        # the cache's serve-side recompute (lookupAtPlan/consultPostCompile)
        # so a strict-hygiene run never serves what it would itself report
        # as failed — see CacheContext.outcomePolicy's own doc comment
        # (cachedispatch.nim) and the `let policy = ...` comment further
        # down this proc for why this is built here too, ahead of execute().
        outcomePolicy = ptypes.OutcomePolicy(strictHygiene: cfg.strictHygiene))

  # rfc-0007 A1e-ii: CrisolInterrupted is retired — `interrupted`/`notStartedCount`
  # are written by execute() itself (via ptr out-params) rather than caught as
  # an exception; a SIGINT/SIGTERM no longer unwinds this call at all.
  var interrupted     = false
  var notStartedCount = 0
  var shutdownSignum  = 0  # rfc-0007 A2b: the real signum execute()'s own Supervisor observed

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
      shutdownSignalOut  = addr shutdownSignum,
      installSignals     = opts.installSignals,
      cache              = cacheCtx,
      explainMiss        = cfg.explainMiss,  # RFC-0005 B1c: resolved (CLI OR config,
                                              # already merged by planImpl above)
    )
  except CrisolError as e:
    releaseLock(lockHandle)
    let code = if e.kind == cekInternal: 2 else: 3
    return structuralResultWithPlan(e.msg, code, pr)
  except Exception as e:
    releaseLock(lockHandle)
    return structuralResultWithPlan("unexpected error during execute: " & e.msg, 2, pr)

  # RFC-0005 B0/A3c-ii: flush queued remote puts at the end-of-run join
  # point — after the poll loop drains (execute() just returned), before
  # persistLastRun (RFC "Deferred remote puts"). `rt.pending` is empty for
  # the common single-tier (no remote configured) run — `realSeams.store`
  # only ever queues an entry when a remote tier actually exists — so this
  # is a no-op there, never touching `drainPending` at all. `rt` is nil only
  # when `opts.noCache` is set, in which case `rt.pending` is unreachable
  # (guarded by the same condition here).
  #
  # RFC-0005 code-review SO2: `not interrupted` mirrors the `persistLastRun`
  # gate further down this proc verbatim — an interrupted run's `results`
  # is an honest PARTIAL set (§2), so queuing MORE network I/O for entries
  # this run never even finished observing is the wrong thing to do on the
  # way out, exactly like persisting would be. `abandoned` covers the
  # OTHER half of SO2: a shutdown signal that arrives DURING this drain
  # itself, on an otherwise-uninterrupted run (`interrupted == false` —
  # execute() already returned normally) — `signals.shutdownRequested()` is
  # the SAME process-global, level-triggered query the plan-time
  # prefetch/consult loops already use for exactly this "abandon more I/O
  # on a pending shutdown" purpose (cachetier.nim's own doc comment).
  if not opts.noCache and not interrupted and rt.pending.len > 0:
    let flushVerdicts = rt.cache.drainPending(rt.pending, DefaultDeferredPutBudget,
      abandoned = proc(): bool = signals.shutdownRequested().isSome)
    for v in flushVerdicts:
      # Tier "l1" was already accounted for synchronously at finalize
      # (cachedispatch.realSeams.store's own tekPublish/tekRemoteErr) —
      # drainPending's full fan-out re-puts to it too (idempotent — last-
      # writer-wins among validly-attested entries is sound, RFC
      # "Integrity") but must not be double-counted in telemetry here.
      if v.tier == "l1": continue
      if v.verdict == cvOk:
        rt.sink.emit(TelemetryEvent(kind: tekPublish, publishedTo: v.tier))
      elif v.verdict in transportVerdicts:
        rt.sink.emit(TelemetryEvent(kind: tekRemoteErr, putTier: v.tier,
                                    putVerdict: v.verdict))
    rt.pending.setLen(0)

  # rfc-0007 A6b: the ONE resolved OutcomePolicy for this run, built from
  # cfg.strictHygiene (CLI flag OR config-file, already merged by planImpl
  # above) — recomputed at every REPORTING trust boundary from here on
  # (summarize -> exit code; render/JSON/junit/lastrun.json below via
  # rr.plan.settings.strictHygiene). RFC-0005 SO1 fix: the cache's SERVE-side
  # recompute (cachedispatch.lookupAtPlan/consultPostCompile) ALSO reads this
  # same resolved value now — see the `cacheEnabled(..., outcomePolicy = ...)`
  # call further up this proc, which builds an equal `OutcomePolicy` from the
  # same `cfg.strictHygiene` BEFORE `execute()` runs (this `policy` local is
  # built too late for that call site, hence the duplicate construction, not
  # a second independent resolution). The STORE gate
  # (cachedispatch.shouldStore) and live scheduling decisions (retry
  # eligibility, quarantine matching, ledger rows) still deliberately never
  # see it — they stay DefaultPolicy (unstrict), matching the cache's
  # "publishes unstrict" rule (RFC-0007 §2).
  let policy = ptypes.OutcomePolicy(strictHygiene: cfg.strictHygiene)
  var s = summarize(results, policy)
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
                   reuseAlerts = reuseAlerts, policy = policy)

  # RFC-0005 B3b: the --verify-cache post-run pass. Placement is load-
  # bearing (RFC "Binary precondition... the pass runs before releaseLock,
  # after persistLastRun") — strictly AFTER persistLastRun above (so
  # lastrun.json reflects the main run only; --failed narrowing reads it)
  # and strictly BEFORE releaseLock below (the stateDir lock is still held,
  # so `clean` cannot remove the stable binary a sampled `cdmHit` entry's
  # synthetic plan depends on). Never runs on an interrupted run: a partial
  # `results`/`pr.entrypoints` pairing would break the index alignment
  # `buildVerifyPlan`/sampling relies on.
  # RFC-0005 code-review SO4/R2-D2: calls `verifyCachePass` for its FULL
  # `VerifyPassResult` (not just `.divergences`) so `couldNotReexec` is
  # available to thread onto `RunReport` below, alongside `divergences` —
  # the round-1 `verifyCachePass*` back-compat wrapper that hid this tuple
  # behind a `seq[VerifyDivergence]`-only return is deleted (R2-D2: it had
  # no compat obligation and zero production callers).
  let verifyPassResult =
    if opts.verifyCache.enabled and not interrupted:
      verifyCachePass(results, pr.entrypoints, opts.verifyCache, cfg, graph,
                      nimVer, ccVer, spec, cacheCtx.sink)
    else: (divergences: newSeq[VerifyDivergence](), couldNotReexec: newSeq[Entrypoint]())
  let verifyDivergences    = verifyPassResult.divergences
  let verifyCouldNotReexec = verifyPassResult.couldNotReexec

  # RFC-0005 B2b: aggregate the run's real telemetry (hit/miss/publish/
  # remote-error events, PLUS verifyCachePass's tekVerifyFail above, since
  # both were emitted through the SAME statsSink) against this run's actual
  # per-result cacheDecisions. A zero-value CacheStats() when statsSink was
  # never installed (`cfg.cacheStats == false`) -- nothing was collected.
  # RFC-0005 C-dep rider: paired with cacheTier so the fold can be
  # tier-granular (l1Hits vs remoteHits) instead of folding every hit into
  # l1Hits -- see cachetelemetry.DecisionTier / aggregateCacheStats.
  let cacheStats =
    if statsSink != nil:
      aggregateCacheStats(statsSink.events,
                          results.mapIt((decision: it.cacheDecision, tier: it.cacheTier)))
    else: CacheStats()

  # RFC-0005 B2b/L2: "crisol additionally writes a stderr warning when a
  # configured remote tier errored on every call in a run" (RFC "Hit-rate
  # telemetry") is UNCONDITIONAL, per the RFC's own wording -- not gated on
  # --cache-stats. `warnSink` (built above) always has real events
  # regardless of `cfg.cacheStats`, so this loop is no longer conditional
  # on `statsSink`. Unconditional stderr like every other warning in this
  # codebase (no --quiet exists) — writes to stderr in BOTH --json and
  # human modes (run/v2 owns stdout in --json mode). See
  # cachetelemetry.erroredTiers's doc for the scope note on "remote" vs.
  # today's single "l1" tier. When --cache-stats IS on, `warnSink` and
  # `statsSink` are the SAME `InMemorySink` instance (see `warnSink`'s own
  # doc comment above) — this fold sees the SAME event list `cacheStats`
  # above was aggregated from, never a second, independently-collected
  # copy, so a tripped tier is reported here exactly once.
  for terr in erroredTiers(warnSink.events):
    stderr.write("crisol: warning: " & tierErrorWarning(terr) & "\n")

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
    exitCode:          if interrupted: 128 + shutdownSignum
                        else: exitCode(s, opts.failOnFlaky),  # B1: flaky-pass gating
    compileBlock:      compileBlock,
    interrupted:       interrupted,
    verifyDivergences: verifyDivergences,
    verifyCouldNotReexec: verifyCouldNotReexec,  # RFC-0005 code-review SO4
    cacheStats:        cacheStats,  # RFC-0005 B2b
  )

# ---------------------------------------------------------------------------
# runTests — the public, opts-only facade (RFC-0005 A3b)
# ---------------------------------------------------------------------------

proc runTests*(opts: RunOptions = RunOptions()): RunReport =
  ## Full run facade.  Returns outcomes; never raises for expected conditions.
  ## Thin wrapper over `runTestsWith` with `productionCacheDeps()` — the
  ## real dependency (`cacheregistry.localOnlyCache`, unchanged behavior).
  ## See `runTestsWith`'s doc comment for the full flow; see `CacheDeps`'s
  ## for why the split exists.
  ##
  ## **Deliberate defense-in-depth (RFC-0005 C4, scope unchanged by D5,
  ## TIMING corrected by code-review R2-D5a):** whenever the cache actually
  ## activates (`opts.noCache == false`, the default), `runTestsWith` (this
  ## call's callee) resolves `$CRISOL_CACHE_HMAC_KEY`/
  ## `$CRISOL_CACHE_SIGN_KEY`/`$CRISOL_CACHE_TOKEN[_<TIER>]` from the
  ## process environment ONCE and then `delEnv`'s the WHOLE `CRISOL_CACHE_*`
  ## namespace (`resolveCacheSecrets`, this module) — a write credential
  ## must never linger in the process environment for a later, unrelated
  ## child to inherit. D5's fix is scope, not removal: this scrub is
  ## skipped entirely under `opts.noCache: true` (see `RunOptions.noCache`'s
  ## own doc comment) rather than running unconditionally regardless of
  ## whether caching was ever going to touch the network at all. **R2-D5a:
  ## the resolve+scrub itself now happens at the very TOP of `runTestsWith`
  ## — before `planTests`/`planImpl` and therefore before the Nim
  ## fingerprint-probe child `planImpl` unconditionally spawns — not
  ## merely before `productionCacheDeps().buildRuntime` (round-1 D5's
  ## placement, which left that probe child inheriting unscrubbed secrets
  ## on every cache-enabled run).** See `runTestsWith`'s own comment at its
  ## call site for the full rationale.
  runTestsWith(opts, productionCacheDeps())
