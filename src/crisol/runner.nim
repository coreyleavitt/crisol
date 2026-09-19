## runner.nim — supervised compile+run, plan/execute/summarize.
##
## Public API:
##   runEntrypoint*(ep, compileTimeoutMs, runTimeoutMs,
##                  maxOutputBytes): EntrypointResult
##     Compile and run ONE entrypoint; returns a canonical EntrypointResult.
##
##   plan*(config, eps, graph, nimVersion, forceCompile): RunPlan
##     Pure — no subprocess.  Annotates every entrypoint with a CompileDecision.
##     With no graph all entrypoints are annotated cdNeverBuilt.
##
##   execute*(p, config, graph, nimVersion, onResult, ..., recordLedger): seq[EntrypointResult]
##     Effectful.  Runs entrypoints with a bounded-parallel poll-loop scheduler
##     honouring plan.jobs (A4).  Continue-on-failure: one failure never stops
##     the pool.  Results returned in deterministic plan order.
##     After each successful compile, records closure + content-hash in graph.
##     For cdSkipFresh entrypoints: compile phase is skipped entirely.
##     recordLedger=false (RFC-0005 B3a) suppresses ledger attempt rows for
##     this call — the --verify-cache pass's re-runs must not pollute
##     --order/perf-check/--shard history.
##
##   buildVerifyPlan*(entrypoints, indices): RunPlan
##     Pure.  RFC-0005 B3a: builds a synthetic RunPlan (jobs=1, retries=0)
##     from the sampled subset of an already-planned run's entrypoints — no
##     re-discovery, no depgraph mutation.
##
##   summarize*(results): Summary
##     Pure aggregate counts over a result sequence.
##
##   noopResult*(r: EntrypointResult)
##     Exported default for execute's onResult parameter.
##
## Scheduler design (A4; rfc-0007 A2b — supervised through crisol/process):
##   • At most plan.jobs child processes alive at once.
##   • Single-threaded event loop: `sv.next(deadline)` — the ONE wait
##     primitive — blocks until a child exits, a deadline (a slot's own
##     timeout, an armed grace window, or the ~25ms RSS-sample tick) passes,
##     or a shutdown signal arrives. Never a fixed sleep + per-slot poll.
##   • Slot state machine: SlotState (ssIdle/ssLive) × SlotPhase
##     (compiling → running → done, or running → done for cdSkipFresh).
##   • The timeout path, the interrupt path, and exception teardown all
##     route through the SAME requestStop/forceKill/next machinery — see
##     `armExpiredTimeouts`/`escalateExpired`/`finalizeSlot`/`teardownDiscard`.
##   • Spawn failure for one slot never aborts the pool.
##   • Output captured to per-entrypoint temp files; read atomically after
##     completion; bounded by maxOutputBytes.

import std/[envvars, json, monotimes, options, os, sequtils, sets, strutils, tables, tempfiles, times]
import crisol/[types, config, render, depgraph, protocol, planner, scheduler, admission, memprobe, sandbox, cachedispatch, ledger, keys, workerplan, closure, compiledriver, ccprobe]
# rfc-0007 A2b: the runner is supervised entirely through `crisol/process`'s
# Supervisor contract now — `std/posix` and `crisol/spawn` (forkExec/
# forkExecEnvScratch/GracePeriodMs) are GONE from this file; every compile
# and run child goes through ONE spawn path (`sv.spawn`), and every wait/
# kill/reap goes through ONE wait path (`sv.next`/`requestStop`/`forceKill`/
# `reap`). `import crisol/process` unqualified (house convention — see
# tests/support/spawnhelpers.nim, tests/integration/test_rlimits_safe.nim,
# etc.) brings in Supervisor/ChildId/ChildSpec/WaitEvent*/ReapReport/
# combinedSink/initSupervisor/spawn/next/requestStop/forceKill/reap/
# groupRssBytes.
import crisol/process
# RFC-0005 C3c: `shutdownRequested()` -- the process-global, level-triggered
# query the plan-time consult loop below checks per-iteration (B0(c)); the
# SAME state `process`'s own Supervisor/`weShutdown` reads, just a query-only
# view a caller with no Supervisor handle in scope (this loop runs before any
# child is ever spawned) can still consult.
import crisol/signals
# `ptypes.X` stays the qualified spelling for the §2 result-model types
# (Exit/Cause/Phase/…) — unchanged house convention from before A2b, kept so
# this file's existing `ptypes.*` call sites need no renaming.
from crisol/process/types as ptypes import nil
export planner   # re-export the pure plan API (slug/binPath/plan/decideCompile/…)
# M4: re-export the CacheContext bundle + constructors so callers of execute()
# don't need a separate `import crisol/cachedispatch`.
export cachedispatch.CacheContext
export cachedispatch.cacheDisabled
export cachedispatch.cacheEnabled
export cachedispatch.isActive
                 # so consumers that `import crisol/runner` keep their symbols.
                 # ResultCallback was moved to types.nim; it is in scope here via
                 # the types import above, and visible to consumers through the
                 # execute() proc signature (Nim surfaces param/return types on use).

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTmpDir(prefix: string): string =
  ## Create a secure temporary directory.
  ## Returns the created directory path, or raises OSError on failure.
  ##
  ## rfc-0007 C1a: uses `std/tempfiles.createTempDir` — pure Nim (retries an
  ## `existsOrCreateDir` against a randomized name), not a raw `mkdtemp(3)`
  ## FFI — avoiding PID-predictable temp paths (M8's original goal) the same
  ## way on every platform. The prior direct `importc: "mkdtemp", header:
  ## "<stdlib.h>"` declaration compiled and ran fine on Linux, but real
  ## macOS clang reported it as an undeclared function even with
  ## `_DARWIN_C_SOURCE` defined for the translation unit — Apple's actual
  ## header guard for this BSD extension did not yield to that macro in
  ## practice, and chasing the exact guard was strictly worse than not
  ## depending on the raw libc symbol at all.
  createTempDir(prefix, "")

proc readCapped(path: string; maxBytes: int): string =
  ## Read up to maxBytes from path; append a truncation notice if cut short.
  if not fileExists(path): return ""
  let size = getFileSize(path)
  if size == 0: return ""
  let f = open(path, fmRead)
  defer: f.close()
  if size <= int64(maxBytes):
    result = f.readAll()
  else:
    result = newString(maxBytes)
    discard f.readBuffer(addr result[0], maxBytes)
    result.add "\n[...output truncated at " & $maxBytes & " bytes...]"

# ---------------------------------------------------------------------------
# B3/B4: isQuarantined — pure quarantine-decision helper
# ---------------------------------------------------------------------------

proc isQuarantined*(ep: Entrypoint; res: EntrypointResult;
                    qNames: HashSet[string];
                    qPaths: HashSet[TrackedPath]): bool =
  ## Pure: returns true iff this entrypoint's failure contribution should be
  ## downgraded (excluded from exit-1) under the quarantine configuration.
  ##
  ## Two rules are applied in order; either is sufficient. RFC-0009 A3d-ii
  ## splits the single legacy string set into two views of the SAME user
  ## entries, because the two rules match fundamentally different things:
  ##
  ##   B3 (path rule) — FOLDED:
  ##     ep.tp ∈ qPaths  → quarantined.  Matches entire binaries by path
  ##     identity, regardless of outcome or protocol records. `qPaths` is the
  ##     user entries reduced to TrackedPath (config.quarantineTp), so the
  ##     match folds under the project root's policy — `quarantine "Foo.nim"`
  ##     downgrades a failing `foo.nim` on a case-insensitive volume (the live
  ##     soundness bug this closes). A cached pass for a path-quarantined
  ##     binary is also marked (harmless — summarize only suppresses failures).
  ##
  ##   B4 (per-test name rule) — EXACT:
  ##     outcome(res) is a failure AND res.records contains ≥ 1 rsFail record AND
  ##     every rsFail record's name ∈ qNames  → quarantined.
  ##     `qNames` is the raw user entries (config.quarantine): a test-record
  ##     name is NOT a filesystem path and must NOT fold — it is matched by
  ##     exact string equality. If ANY failing record's name is not in qNames,
  ##     the rule does NOT fire. If the entrypoint failed with NO rsFail
  ##     records (opaque binary, exit nonzero without protocol, killed,
  ##     crashed, etc.) this rule does NOT apply — only B3 can downgrade such
  ##     results.
  ##
  ## Two views, one source:
  ##   Both derive from the same `quarantine { … }` KDL block. A user entry is
  ##   whichever it happens to match — a path (B3, via qPaths) or a test name
  ##   (B4, via qNames). A name entry also lands in qPaths as some TrackedPath
  ##   that never matches a real ep.tp (harmless); a path entry also stays in
  ##   qNames verbatim, preserving the legacy "one flat set" match semantics.

  # B3: whole-binary path-match (always checked first; applies to any outcome).
  if ep.tp in qPaths:
    return true

  # B4: per-test name-match.
  # Preconditions: must be a failure with ≥ 1 rsFail record.
  # rfc-0007 §2: derived — there is no stored legacy field.
  if not outcome(res).isFailure:
    return false  # passed result — nothing to downgrade

  # Collect failing records. If none, per-test rule does not apply.
  var failCount = 0
  for rec in res.records:
    if rec.status == rsFail:
      inc failCount
      if rec.name notin qNames:
        return false  # at least one failing record is NOT quarantined → real failure

  # failCount > 0 AND every failing record was in qNames.
  result = failCount > 0

# ---------------------------------------------------------------------------
# code-review r23: decideExit — pure retry/promotion/store-gate decision
# ---------------------------------------------------------------------------

type
  ExitDecision* = object
    ## code-review r23: `decideExit`'s pure output. `execute()`'s live-
    ## completion handler (part of the `handleChildExited` template) used to
    ## inline this policy — retry eligibility, whether a freshly-compiled
    ## binary should be promoted (and discarded again if its closure never
    ## recorded), and the cache-store gate — directly into the event loop,
    ## interleaved with the I/O (ledger append, filesystem copy/remove,
    ## `cache.seams.store`, `onResult`) that acts on it. Splitting the
    ## DECISION out from the ACTION means this value is unit-testable
    ## without a Supervisor, a compile, or a subprocess: build the observed
    ## facts, call `decideExit`, assert on the result.
    retry*:                     bool  ## re-dispatch instead of finalizing (B1).
    recordAsFailure*:           bool  ## failFast should latch anyFailed — only
                                       ## true on a genuine FINAL failure, never
                                       ## on an attempt still eligible for retry.
    promoteBinary*:              bool  ## this attempt's compile produced a
                                       ## binary worth copying to the stable
                                       ## slug-keyed path.
    discardOnUnrecordedClosure*: bool  ## promoteBinary AND the closure failed
                                       ## to record — the stable binary just
                                       ## promoted must be discarded right back
                                       ## out (issue #13.3).
    stampCacheKeyInfo*:          bool  ## cache is active and this attempt is
                                       ## finalizing — the executor should
                                       ## stamp keyDiff/cacheLookup onto the
                                       ## live result.
    attemptStore*:               bool  ## the executor should call
                                       ## `cache.seams.store` — policy,
                                       ## hermeticity, AND closure recording
                                       ## all agree. The FINAL cacheDecision
                                       ## (cdmStored vs cdmKeyMiss) still
                                       ## depends on that call's own outcome,
                                       ## so it is resolved by the executor,
                                       ## not here.
    cacheDecisionIfNotStored*:   CacheDecision  ## what to stamp when
                                       ## `attemptStore` is false — covers
                                       ## cache-inactive (the plan-time
                                       ## structural reason), a store-gate
                                       ## refusal, and the R17 recompute-miss
                                       ## passthrough. Computed correctly on
                                       ## its own terms regardless of
                                       ## `attemptStore`/`retry` (simply
                                       ## unread by the executor when either
                                       ## is true, never wrong-but-unread).

proc decideExit*(
  completedOutcome:      Outcome;
  slotAttempt, maxAttempts: int;
  failFast:               bool;
  compiledThisRun:        bool;
  hasCacheDir:            bool;
  slotClosureRecorded:    bool;
  cacheActive:            bool;
  verdict:                StoreVerdict;
  planTimeCacheDecision:  CacheDecision;
): ExitDecision =
  ## Pure: no I/O, no Supervisor, no filesystem access — every input is a
  ## plain value the caller already holds at the point `finalizeSlot` has
  ## just returned `fkDone` for a slot that is NOT mid-shutdown. Mirrors
  ## execute()'s pre-extraction inline logic field-for-field (see the call
  ## site in the `fkDone` handler) so this refactor changes WHERE the policy
  ## lives, never WHAT it decides.
  ##
  ## B1: "failure eligible for retry" = outcome is NOT oPassed AND NOT
  ## oCompileFailed AND NOT oSpawnError (retrying either is useless — a
  ## compile failure or a fork failure is not transient noise), AND there
  ## are attempts left.  oKilled/oCrashed ARE retried (transient
  ## infrastructure noise).
  result.retry = completedOutcome notin {oPassed, oCompileFailed, oSpawnError} and
                 slotAttempt < maxAttempts
  result.recordAsFailure = not result.retry and failFast and completedOutcome.isFailure

  # R9: promotion (and therefore the closure-recorded reading) only applies
  # once an attempt is finalizing — a still-retryable attempt never reaches
  # this policy at all, matching the pre-extraction control flow where all
  # of this lived inside the `else: # Finalize` branch.
  result.promoteBinary = not result.retry and compiledThisRun and hasCacheDir and
                         completedOutcome notin {oCompileFailed, oSpawnError}
  let closureRecorded = if result.promoteBinary: slotClosureRecorded else: true
  result.discardOnUnrecordedClosure = result.promoteBinary and not closureRecorded

  result.stampCacheKeyInfo = not result.retry and cacheActive
  result.attemptStore = result.stampCacheKeyInfo and verdict.store and closureRecorded
  # `cacheDecisionIfNotStored` stays correct on its own terms regardless of
  # `attemptStore` (never leans on "it's unused in that case" for
  # correctness) — the `not closureRecorded` guard on the middle arm is what
  # makes that true: without it, a genuine pass (verdict.store AND
  # closureRecorded, i.e. `attemptStore` true) would compute the WRONG
  # cdmClosureUnrecorded here, merely happening to go unread.
  result.cacheDecisionIfNotStored =
    if not cacheActive: planTimeCacheDecision
    elif verdict.store and not closureRecorded: cdmClosureUnrecorded  # gate
                                               # said store, but the closure
                                               # never recorded (R9)
    elif verdict.decision == cdmKeyMiss and planTimeCacheDecision == cdmRecomputeMiss:
      cdmRecomputeMiss  # code-review r17: a recompute-invalidated hit whose
                         # rerun failed keeps reporting cdmRecomputeMiss, not
                         # the generic "no entry was ever found" cdmKeyMiss.
    else: verdict.decision

# ---------------------------------------------------------------------------
# ResultCallback (defined in types.nim) and noopResult
# ---------------------------------------------------------------------------

# ResultCallback* is defined in types.nim and re-exported via the types import above.

proc noopResult*(r: EntrypointResult) = discard
  ## Exported default for execute's onResult parameter — never nil, so
  ## optionality is visible in the type rather than hidden in a nil check.

# ---------------------------------------------------------------------------
# B2: ledger append helper
# ---------------------------------------------------------------------------

proc wait4MaxRss(res: EntrypointResult): tuple[bytes: int64; mechanism: string] =
  ## rfc-0007 A5: pull the run phase's wait4-reaped maxRss, when present.
  ## Distinct from `peakRssBytes`/`rssBytes` (the RFC-0002 sampled group-sum
  ## admission quantity) — this is the per-process max wait4 folds over
  ## reaped descendants at exit (§7 "a new quantity, not a replacement").
  ## ("", 0) when the run phase never produced a live ProcessResult (a
  ## spawn failure, or a skipped phase) or the platform/attempt genuinely
  ## had no rusage to report — never a fabricated non-zero value.
  ##
  ## rfc-0007 B3 note: cgroup `memory.peak` is a tree-accounted figure
  ## wait4 (single-reaped-process only) cannot produce, and is the
  ## documented FUTURE successor to this column — but only additively (a
  ## new, separately-tagged column), never by silently replacing this
  ## wait4 quantity or its "wait4" mechanism tag. Not wired yet; this proc
  ## is unchanged and unconditional across every tier.
  if res.run.kind in {ptypes.pkRan, ptypes.pkCached} and res.run.res.rusage.isSome:
    (res.run.res.rusage.get.maxRssBytes, "wait4")
  else:
    (0'i64, "")

proc appendAttemptRow(led: var Ledger; ep: Entrypoint; attemptNum: int;
                      res: EntrypointResult; inputHash: string;
                      peakRssBytes: int64 = 0;
                      roots: TrackedRoots = TrackedRoots()) =
  ## Append one LedgerRow for a completed live attempt.
  ## Converts durationMs→durationUs; peakRssBytes is the per-slot running max
  ## sampled across poll ticks while the run phase was live (C5).
  ##
  ## `roots` (RFC-0009 A5b-ii): additive, defaults to the zero `TrackedRoots`
  ## — harmless for every entrypoint (always tag-0); the sole caller
  ## threads `config.trackedRoots`.
  let iKey = identityKey(ep, roots)
  let (maxRss, mechanism) = wait4MaxRss(res)  # rfc-0007 A5
  let row = LedgerRow(
    identity:   iKey,
    timestamp:  int64(epochTime() * 1_000_000),  # unix epoch microseconds
    inputHash:  inputHash,
    outcome:    types.outcomeString(outcome(res)),
    attempt:    attemptNum,
    durationUs: res.durationMs * 1000,
    rssBytes:   peakRssBytes,  # C5: peak RSS bytes for this attempt
    maxRssBytes:  maxRss,      # rfc-0007 A5: wait4's per-process max, mechanism-tagged
    rssMechanism: mechanism,
    rowVersion: currentRowVersion,
  )
  append(led, row)

# ---------------------------------------------------------------------------
# Bounded-parallel poll-loop scheduler (A4 + D6)
# ---------------------------------------------------------------------------

type
  SlotPhase = enum
    spCompiling
    spRunning

  SlotState = enum
    ## rfc-0007 A2b (#1): the `pepIdx == -1` idle sentinel dies. A slot is
    ## either idle (no child, available for dispatch) or live (a ChildId is
    ## outstanding with the Supervisor — spawned, not yet reaped). There is
    ## no separate "exited, awaiting reap" state: `next`'s weChildExited is
    ## handled synchronously (reap happens the moment it is observed), so no
    ## slot is ever left holding a stale unreaped exit across iterations.
    ssIdle
    ssLive

  Slot = object
    state:           SlotState      # rfc-0007 A2b: replaces the pepIdx==-1 sentinel
    id:              ChildId        # valid iff state == ssLive; the executor never
                                    # sees a Pid (rfc-0007 A2b) — every wait/kill/reap
                                    # goes through the Supervisor by this token.
    pepIdx:          int           # index into plan.entrypoints; valid iff state == ssLive
    phase:           SlotPhase
    deadline:        MonoTime      # R11: this phase's own timeout deadline
    stopDeadline:    Option[MonoTime]  # rfc-0007 A2b: set the moment a stop act
                                    # (requestStop) is recorded for this slot's live
                                    # child — timeout OR interrupt, same field, same
                                    # machinery (§1 "ONE stop/escalate machinery").
                                    # `none` until stopped; armed to now+GracePeriodMs
                                    # on the FIRST stop act for this child (idempotent —
                                    # a second stop act for the same child never
                                    # re-arms it, mirroring the Supervisor's own
                                    # "first act wins" rule).
    forceKilled:     bool          # rfc-0007 A2b: true once forceKill has been issued
                                    # for this slot's live child — guards against
                                    # re-issuing forceKill every deadline sweep while
                                    # still draining toward weChildExited (forceKill
                                    # is idempotent at the Supervisor layer too; this
                                    # is purely to avoid redundant calls).
    t0:              float         # epochTime() when slot was claimed (for durationMs)
    runTimeoutMs:    int           # per-entrypoint run deadline (ms); set at slot setup
                                   # from effectiveRunTimeoutMs(ep, config).  Consumed only
                                   # at the spCompiling→spRunning transition in pollSlot to
                                   # set the run deadline.  Never checked during spCompiling.
    tmpDir:          string        # per-slot temp dir to clean up after run (empty if none)
    testScratchDir:  string        # A4a: per-entrypoint scratch tmpdir injected as TMPDIR
                                   # in the child env (empty when spec.tmpdir == false).
                                   # Cleaned on ALL exit paths (success/fail/timeout/signal)
                                   # at the same sites as tmpDir.
    compOut:         string        # path to compile output file (empty for cdSkipFresh)
    runOut:          string        # path to run output file
    sinkPath:        string        # path to CRISOL_SINK file for run phase (R1)
    binCompiled:     string        # path where nim c wrote the binary (slot-specific dir)
    binFull:         string        # stable slug-keyed path; run and freshness use this
    cacheDir:        string        # actual nimcache dir used (includes pepIdx suffix)
    slotBinDir:      string        # per-slot bin dir (separate from tmpDir for M15 cleanup)
    compiledThisRun: bool          # false for cdSkipFresh slots
    compileSkipped:  bool          # true for cdSkipFresh slots
    spec:            SandboxSpec   # A6: resolved sandbox spec for the run phase; stored
                                   # at compile-spawn so the compile→run transition
                                   # (transitionToRun) can route through buildRunChildSpec.
    token:           SlotToken     # S3: admission token; released on finish or spawn failure
    attempt:         int          # B0/B1: current attempt number (1-indexed); set by
                                   # claimSlot at slot claim (see its doc comment)
    peakRssBytes:    int64        # C5: running max of procGroupRssBytes across all polls
                                   # while this slot's run phase is live.  Reset to 0 when
                                   # the slot is claimed (before compile or run spawned).
                                   # Updated each poll tick for run-phase (spRunning) slots.
                                   # Read at finalize; threaded into ledger row + EntrypointResult.
    compileProcRes:  Option[ptypes.ProcessResult]  # rfc-0007 A1b: the compile phase's
                                   # captured Exit/Cause/rusage, set the moment a
                                   # this-run compile is reaped successfully so the
                                   # eventual run-phase result can dual-write BOTH
                                   # phases. Reset to none() at every slot claim
                                   # (spawnCompileStable / spawnRunDirect) so a
                                   # reused physical slot never leaks a prior
                                   # occupant's compile observation.
    closureRecorded: bool          # rfc-0005 A2c-i: `recordClosure`'s outcome, captured
                                   # the moment a this-run compile succeeds and transitions
                                   # to its run phase (finalizeSlot, before `transitionToRun`)
                                   # — read back by the post-run promotion/cache-store gate,
                                   # which no longer calls `recordClosure` itself. Reset at
                                   # every slot claim so a reused slot never leaks a prior
                                   # occupant's outcome.
    closureError:    string        # rfc-0005 A2c-i: `recordClosure`'s error message, paired
                                   # with `closureRecorded` (meaningful only when it is false).
    postCompileConsulted: bool     # rfc-0005 A2c-ii: true iff finalizeSlot actually ran the
                                   # post-compile cache consult for THIS compile (cache active,
                                   # group eligible, closure recorded) AND it fell through to a
                                   # real run (miss, recompute-invalidated, or a hit whose binary
                                   # failed to promote) rather than being served as a fkCacheHit.
                                   # Read back by the post-run cache-store gate so a compiling
                                   # entrypoint's live result reports the REAL post-compile
                                   # key/lookup/explain instead of the pre-compile ""/cvOk/[]
                                   # placeholders. Reset at every slot claim.
    postCompileInputHash: string   # rfc-0005 A2c-ii: the post-compile consult's derived key
                                   # string, meaningful only when postCompileConsulted.
    postCompileLookup:    CacheVerdict  # rfc-0005 A2c-ii: the post-compile consult's
                                   # PlanLookup.lookup, meaningful only when postCompileConsulted.
    postCompileExplain:   seq[KeyDiff]  # rfc-0005 A2c-ii: the post-compile consult's
                                   # PlanLookup.explain, meaningful only when postCompileConsulted.

# ---------------------------------------------------------------------------
# rfc-0007 A2b: ONE stop/escalate machinery. The timeout path, the interrupt
# path, and exception teardown all route through requestStop/forceKill/next
# — never their own wait/kill loop. `sv.reap`'s ReapReport IS the honest
# observation (§2); there is no runner-side mirror of Exit/Rusage/stop left
# to maintain, and `classifyCause` is called directly against the report.
# ---------------------------------------------------------------------------

const GracePeriodMs* = 400
  ## Time (ms) to wait after a stop act (requestStop) before escalating to
  ## forceKill. Formerly crisol/spawn.nim's constant; spawn.nim has no
  ## callers left after this rewrite and is deleted (rfc-0007 A2b).

proc toProcessResult(report: ReapReport; limits: ptypes.Limits;
                     durationUs: int64;
                     hermetic: ptypes.HermeticLevel = ptypes.hlNone): ptypes.ProcessResult =
  ## The ONE place a reaped child's ProcessResult is assembled — a straight
  ## map over `ReapReport` (§1's "one report" promise). `cause` consults
  ## `report.stop` FIRST regardless of `report.exit` (§2's authorship rule:
  ## "cbRunner iff ReapReport.stop.isSome") — a child reaped after a stop
  ## act reads cbRunner even if it happened to exit 0 inside the grace
  ## window. `evidence.limits` is the REAL per-limit readback the Supervisor
  ## delivered at reap time (rfc-0007 A5); `killDomain`/`tree`/`escapees`/
  ## `killSnapshot`/`cooperativeUnavailable` are copied VERBATIM from the
  ## ReapReport too (rfc-0007 A6a — reap's "one report" promise, §2) — the
  ## backend already computed the honest values (posixcore's post-reap pgid
  ## scan + `treeObservationFor`); this is the one place they reach the
  ## wire-facing `Evidence` instead of being silently discarded.
  ## `evidence.hermetic` (rfc-0007 A6b) is the ONE runner-authored field —
  ## not backend-observed, so it does not ride ReapReport like the rest.
  ## Callers pass it explicitly; the default `hlNone` (ord 0, the weakest
  ## claim — house rule: a default-initialized Evidence must never encode a
  ## vouch) is exactly right for the THREE compile-phase call sites below,
  ## which never pass this parameter: a compile has no HermeticLevel concept
  ## to begin with (sandboxing is a run-phase-only notion, §5). The run-phase
  ## call site passes `slots[idx].spec.level` — the SandboxSpec resolved for
  ## this entrypoint's run child at transitionToRun (a label, like
  ## killDomain — "the level this ran under", not a proof hlNetwork's
  ## net-isolation was actually achieved; see resolveSandbox/evidenceSatisfies).
  ptypes.ProcessResult(
    exit: report.exit,
    cause: ptypes.classifyCause(report.exit, report.stop, limits, report.limits,
                                report.memoryOomKill, report.limitKilled),
    evidence: ptypes.Evidence(
      killDomain:             report.killDomain,
      tree:                   report.tree,
      escapees:               report.escapees,
      limits:                 report.limits,
      hermetic:               hermetic,
      killSnapshot:           report.killSnapshot,
      cooperativeUnavailable: report.cooperativeUnavailable,
    ),
    rusage: report.rusage,
    durationUs: durationUs,
  )

proc anyLiveSlot(slots: seq[Slot]): bool =
  ## A plain top-level proc (not a nested closure): a nested proc capturing
  ## a `var seq[Slot]` parameter (as `teardownDiscard` needs) triggers Nim's
  ## memory-safety capture check at codegen — an ordinary by-value `seq`
  ## parameter sidesteps it entirely and is reused by every caller (the main
  ## loop's own condition/progress-line/failFast checks, and the exception-
  ## teardown drain).
  for s in slots:
    if s.state == ssLive: return true
  false

proc slotIndexOf(slots: seq[Slot]; id: ChildId): int =
  ## Linear scan over the (small, == jobs) slot array for the live slot
  ## holding `id`. `next` never reports a ChildId this executor did not
  ## spawn, so a live match always exists.
  for i in 0 ..< slots.len:
    if slots[i].state == ssLive and slots[i].id == id:
      return i
  -1

type
  SlotWakeInfo* = object
    ## code-review r15: minimal pure-data view of one Slot's wake-relevant
    ## fields, extracted so `nextDeadline`'s per-slot selection logic
    ## (`slotWakeDeadline`) is unit-testable from outside this module
    ## without constructing a full (private) `Slot`.
    live*:         bool
    forceKilled*:  bool
    stopDeadline*: Option[MonoTime]
    deadline*:     MonoTime

proc slotWakeDeadline*(info: SlotWakeInfo; floor: MonoTime): MonoTime =
  ## Pure per-slot contribution to `nextDeadline`'s min: returns `floor`
  ## (the sample-tick ceiling) unless this slot is live, NOT yet
  ## `forceKilled`, and its own grace/run deadline is earlier than
  ## `floor`.
  ##
  ## code-review r15: a `forceKilled` slot is EXCLUDED here. Its
  ## `stopDeadline` is a moment in the past (that is what triggered the
  ## forceKill) and nothing re-arms it — so, pre-fix, it kept winning this
  ## min against every other slot's future deadline, collapsing
  ## `nextDeadline`'s result to that past instant forever. `next(deadline)`
  ## then returned `weDeadline` immediately on every call: a busy-spin
  ## (full fill-pass + sweep per iteration) that pegs a core for as long as
  ## the child takes to actually die (unbounded against a D-state child).
  ## A `forceKilled` slot's only legitimate next wakeup is its eventual
  ## `weChildExited`; until then the sample tick is its floor, same as an
  ## otherwise-idle poll.
  if not info.live or info.forceKilled: return floor
  let d = if info.stopDeadline.isSome: info.stopDeadline.get else: info.deadline
  if d < floor: d else: floor

proc nextDeadline(slots: seq[Slot]; now: MonoTime; sampleTickMs: int): MonoTime =
  ## §1: "the executor passes min(run deadlines, grace deadlines, sample
  ## tick)". `sampleTickMs` keeps RFC-0002's RSS-sampling cadence unchanged
  ## (§Contract impacts) — it is a CEILING, not a poll interval: `next`
  ## still returns immediately on a real child-exit or shutdown event. The
  ## per-slot selection itself is `slotWakeDeadline` (extracted for unit
  ## testability, code-review r15) — this loop only adapts each `Slot` to
  ## its `SlotWakeInfo` view.
  result = now + initDuration(milliseconds = sampleTickMs)
  for s in slots:
    result = slotWakeDeadline(SlotWakeInfo(live: s.state == ssLive,
                                            forceKilled: s.forceKilled,
                                            stopDeadline: s.stopDeadline,
                                            deadline: s.deadline), result)

proc armExpiredTimeouts(sv: var Supervisor; slots: var seq[Slot]; now: MonoTime) =
  ## Main-loop-only half of the shared machinery: a live, not-yet-stopped
  ## slot whose OWN phase deadline (compile or run timeout) has passed gets
  ## its stop act recorded now. This is the ONLY place krTimeout is
  ## authored — everything downstream (grace, escalation, the eventual
  ## Cause) is identical to the interrupt path from here on, which is
  ## exactly the "three paths become one" acceptance.
  for i in 0 ..< slots.len:
    if slots[i].state == ssLive and slots[i].stopDeadline.isNone and
       now >= slots[i].deadline:
      sv.requestStop(slots[i].id, ptypes.krTimeout)
      slots[i].stopDeadline = some(now + initDuration(milliseconds = GracePeriodMs))

proc escalateExpired(sv: var Supervisor; slots: var seq[Slot]; now: MonoTime) =
  ## Shared by the main loop AND both teardown drains: a slot already in its
  ## grace window (armed by EITHER a timeout or an interrupt stop act — the
  ## two paths converge here) whose window has elapsed gets forceKill.
  ## Non-blocking, idempotent (§1); `forceKilled` just avoids redundant
  ## calls while still draining toward the eventual weChildExited.
  for i in 0 ..< slots.len:
    if slots[i].state == ssLive and slots[i].stopDeadline.isSome and
       now >= slots[i].stopDeadline.get and not slots[i].forceKilled:
      sv.forceKill(slots[i].id)
      slots[i].forceKilled = true

proc cleanupSlotOnTeardown(slot: Slot) =
  ## Full cleanup for a slot whose child is being torn down and will NEVER
  ## reach the downstream promotion/ledger/cache block (a killed COMPILE on
  ## any path, or any slot torn down via the exception path) — unlike
  ## `cleanupSlotTmp` (used by a normal/timeout-killed RUN-phase finalize,
  ## which still needs slotBinDir/cacheDir intact for promotion), this
  ## removes tmpDir/testScratchDir/slotBinDir unconditionally. cacheDir is
  ## wiped only when the slot was mid-compile: nim's own process may have
  ## left a partial/corrupt nimcache; a slot torn down while already
  ## running has a complete, valid, persistent nimcache from its (already
  ## successful) compile phase, and wiping it would defeat nimcache
  ## persistence for the common "interrupt a long test run" case.
  if slot.tmpDir.len > 0:
    try: removeDir(slot.tmpDir) except: discard
  if slot.testScratchDir.len > 0:
    try: removeDir(slot.testScratchDir) except: discard
  if slot.slotBinDir.len > 0:
    try: removeDir(slot.slotBinDir) except: discard
  if slot.phase == spCompiling and slot.cacheDir.len > 0:
    try: removeDir(slot.cacheDir) except: discard

type
  RecordClosureProc* = proc(graph: var DepGraph; config: Config; ep: Entrypoint;
                            nimcacheDir, binaryName: string;
                            protocolMajor: int; index: SourceIndex;
                            ccRun: RunProc): tuple[ok: bool, error: string]
    ## R3a (RFC-0009 A-final-ii-a): injectable seam matching `depgraph.
    ## recordClosure`'s signature, so a test can substitute a synthetic
    ## failure without constructing a genuinely-outside-every-root
    ## Entrypoint (production entrypoints are ALWAYS tag-0 — see
    ## `discover`). `execute*`'s `recordClosureFn` param defaults to the
    ## real `recordClosure` — zero production behavior change.

  ExecCtx* = object
    ## code-review r24: the run-lifetime invariants that finalizeSlot,
    ## spawnCompileStable, spawnRunDirect, and transitionToRun all need but
    ## none of them ever change WITHIN one execute() call — config, the
    ## cache bundle, the injected recordClosure seam, the plan itself, the
    ## derived output-byte cap and compile timeout, the resolved project
    ## root, and the two nimcache-persistence invariants (RFC-0006)
    ## execute() computes once up front (toolchainFp/dupSlugs). Built ONCE
    ## in execute() and passed as a single param instead of each proc
    ## re-threading its own subset of these by hand (the param-list growth
    ## this was written to close). Deliberately NOT a god-object: anything
    ## that varies call-to-call or is mutated in place — sv, slots, idx,
    ## graph, sourceIndex/sourceIndexBuilt, pendingEscapees, attempt,
    ## allowTransition, runTimeoutMs — stays an explicit param at every call
    ## site below; only what is genuinely constant for the life of one
    ## execute() call lives here.
    config*:            Config
    cache*:              CacheContext
    recordClosureFn*:    RecordClosureProc
    plan*:               RunPlan
    maxOutputBytes*:     int
    compileTimeoutMs*:   int
    projectRoot*:        string
    toolchainFp*:        string
    dupSlugs*:           HashSet[string]

type
  FinalizeKind = enum
    fkTransitioned  ## compile succeeded, no stop act — now running; the
                    ## slot stays live (under a NEW ChildId).
    fkOmitted       ## compile raced to success DURING interrupt teardown
                     ## (no stop act was recorded — the Supervisor's atomic
                     ## no-op rule, §1) but the run phase must not start
                     ## mid-shutdown: §2 explicitly names "compile-done-
                     ## run-unstarted" as a real, honestly-omitted state,
                     ## never an auto-continue. The slot goes idle with no
                     ## result and no onResult; the caller leaves its pepIdx
                     ## unfinalized so the emission-set trim below counts it
                     ## in notStarted.
    fkDone          ## a result was produced; the slot goes idle.
    fkCacheHit      ## rfc-0005 A2c-ii: compile succeeded AND the post-compile
                    ## cache consult hit (recomputed outcome oPassed, binary
                    ## promoted to the stable path) — a result was produced
                    ## with NO run child ever spawned; the slot goes idle.
                    ## Terminal like a plan-time edCached hit: never retried,
                    ## no ledger row.

  FinalizeOutcome = object
    case kind: FinalizeKind
    of fkDone, fkCacheHit: res: EntrypointResult
    of fkTransitioned, fkOmitted: discard

proc transitionToRun(sv: var Supervisor; slot: var Slot; runTimeoutMs: int;
                     attempt: int; ctx: ExecCtx): bool
  ## Forward-declared: defined below, alongside spawnCompileStable/
  ## spawnRunDirect (the other two ChildSpec-building spawn sites).

proc cleanupSlotTmp(slot: Slot)
  ## Forward-declared: defined below — removes per-slot temp output files,
  ## the A4a scratch tmpdir, AND the tmpDir itself (code-review r14: every
  ## finalizeSlot path that releases a slot back to ssIdle calls this proc,
  ## making it the single choke point where the tmpDir gets removed);
  ## deliberately narrower than cleanupSlotOnTeardown (see that proc's doc
  ## comment) in that it never touches slotBinDir/cacheDir.

proc promoteCompiledBinary(ep: Entrypoint; config: Config; binCompiled: string): bool
  ## Forward-declared: defined below, alongside spawnCompileStable (the
  ## proc that lays out `binCompiled` in the first place) — copies a
  ## per-slot compiled binary to its stable slug-keyed path. Shared by the
  ## post-run promotion (the pre-existing site) and `finalizeSlot`'s
  ## post-compile cache-hit branch (RFC-0005 A2c-ii), which needs the SAME
  ## promotion to happen right after compile instead of after a run that
  ## never spawns.

proc classifyRunResult(
  ep: Entrypoint; output: string; elapsed: int64; compileSkipped: bool;
): EntrypointResult
  ## Forward-declared: defined below (unchanged from pre-A2b) — the plain
  ## opaque-fallback EntrypointResult construction for a normal run end
  ## with no protocol records.

type
  ExecuteReport* = object
    ## rfc-0007 code-review r7: `execute()`'s single return value — replaces
    ## the FIVE raw `ptr` out-params (`memThrottledOut`, `interruptedOut`,
    ## `notStartedOut`, `shutdownSignalOut`, `lateOrphansReapedOut`) it used
    ## to write run-level facts through. Those pointers made "forgot to pass
    ## one" a silent data loss rather than a compile error — which is
    ## exactly what happened (code-review r33): the failFast early-exit
    ## path `return`ed from inside `execute()`'s own try/while before the
    ## epilogue that wrote them, so `notStartedOut`/`shutdownSignalOut`/
    ## `lateOrphansReapedOut`/`interruptedOut` all silently stayed at the
    ## caller's zero-value locals on a failFast run.
    ##
    ## `execute()` now builds exactly ONE `ExecuteReport` at its single
    ## normal-exit construction point (the very end of the proc body); the
    ## former failFast early-`return` is gone (§ the `break` at the
    ## fail-fast early-exit site below) so EVERY normal-completion path
    ## funnels through that one construction — a future fact this object
    ## grows cannot be dropped by a return path that forgets to populate it,
    ## because there is only the one path left to forget it in, and it is
    ## exercised by every existing test. (An exception unwinding out of
    ## `execute()` still short-circuits this — same as the old ptr-out-param
    ## design, where an exception path also never returned a value; the
    ## `finally` block's teardown/cleanup work is unaffected either way.)
    results*:           seq[EntrypointResult]
    memThrottled*:       int   ## S6b: ac.memThrottledSlots on return.
    interrupted*:        bool  ## rfc-0007 A1e-ii: true iff a SIGINT/SIGTERM
                                ## cut this run short (§2).
    notStarted*:         int   ## rfc-0007 A1e-ii: count of entries OMITTED
                                ## from `results` because their next phase
                                ## never started (§2's emission-set rule; also
                                ## covers the failFast "remaining entrypoints
                                ## never dispatched" case, r33). 0 on a normal,
                                ## non-early-exited completion.
    shutdownSignal*:     int   ## rfc-0007 A2b: the SIGINT/SIGTERM signum this
                                ## call's own Supervisor observed (0 when not
                                ## interrupted).
    lateOrphansReaped*:  int   ## rfc-0007 B1: count of adopted orphans reaped
                                ## via the async waitid(P_ALL, WNOWAIT) sweep
                                ## after their owning slot's result had
                                ## already been emitted (or unattributable).

proc finalizeSlot(
  sv:               var Supervisor;
  slots:            var seq[Slot];
  idx:              int;
  allowTransition:  bool;
  graph:            var DepGraph;
  sourceIndex:      var SourceIndex;
  sourceIndexBuilt: var bool;
  pendingEscapees:  var Table[int32, seq[ptypes.ProcSnapshot]];
  ctx:              ExecCtx;
): FinalizeOutcome =
  ## Called once `next` has reported weChildExited for `slots[idx].id`.
  ## Reaps it (the only place a ChildId is consumed, §1) and either
  ## transitions a successfully-compiled, un-stopped slot into its run
  ## phase (fkTransitioned), produces this pepIdx's EntrypointResult
  ## straight from a post-compile cache hit with no run child ever spawned
  ## (fkCacheHit — RFC-0005 A2c-ii), or produces this pepIdx's
  ## EntrypointResult after a run/kill/spawn-failure (fkDone / fkOmitted).
  ## `allowTransition` is false only during interrupt teardown.
  ##
  ## code-review r24: `plan`/`maxOutputBytes`/`projectRoot`/`config`/`cache`/
  ## `recordClosureFn` — the run-lifetime invariants this proc needs but
  ## never mutates and that never change across a single execute() call —
  ## now arrive together as `ctx: ExecCtx` (see its type doc) instead of six
  ## separate params. Everything else below (`sv`/`slots`/`idx`/
  ## `allowTransition`/`graph`/`sourceIndex`/`sourceIndexBuilt`/
  ## `pendingEscapees`) is per-call or mutated in place and stays explicit.
  ##
  ## rfc-0005 A2c-ii: `ctx.cache` is the SAME `CacheContext` `execute()`
  ## resolves once for the whole run — passed through so the post-compile
  ## consult can run at exactly the point the closure/graph are fresh,
  ## before deciding whether to spawn the run child at all (see the consult
  ## block below).
  ##
  ## rfc-0005 A2c-i: `graph`/`ctx.config`/`sourceIndex`/`sourceIndexBuilt`
  ## exist solely so a successfully-compiled slot can have its closure
  ## extracted and its dependency-graph entry updated RIGHT HERE — before
  ## the run child is spawned — instead of after the entire run completes
  ## (the pre-existing site, now just a reader of `slot.closureRecorded`/
  ## `.closureError`). `sourceIndex`/`sourceIndexBuilt` are `execute`'s own
  ## locals threaded through by `var` so the "built at most once per
  ## `execute` call, only when something actually compiles" invariant
  ## (see `execute`'s doc comment) survives the move unchanged. Pure
  ## sequencing prep for A2c-ii's post-compile cache consult, which will
  ## need the closure/graph available at exactly this point; no cache
  ## lookup happens here.
  ##
  ## rfc-0007 §2: `report.stop` is the SINGLE source of authorship —
  ## `toProcessResult`'s `classifyCause` call already consults it before the
  ## exit itself, so this proc never branches on "was this a timeout or an
  ## interrupt" anywhere: krTimeout and krInterrupt reach the exact same
  ## code from here on.
  # B1 regression fix, part B; r28 re-homed onto ChildSpec.claimOrphans
  # (process/types.nim), declared once at spawn — `spawnCompileStable`'s
  # ChildSpec sets it false so a compile-phase reap never engages
  # reparented-orphan (ppid==ownPid) escapee discovery (it would catch
  # crisol's own compile toolchain, a false positive) — see reap*'s doc
  # comment (process/posix.nim).
  var report  = sv.reap(slots[idx].id)
  let pepIdx  = slots[idx].pepIdx
  let pep     = ctx.plan.entrypoints[pepIdx]
  let elapsed = int64((epochTime() - slots[idx].t0) * 1000)

  # rfc-0007 B1 (§3): splice in any orphan the async waitid sweep staged
  # for THIS slot while it was still live (see `pendingEscapees`'s doc
  # comment at its declaration in `execute`) — folded into the SAME
  # ReapReport.escapees `report` already carries, so every downstream
  # consumer (toProcessResult's Evidence, the cache-store gate, the
  # render warning) sees one unified list, never a second parallel one.
  let slotKey = int32(slots[idx].id)
  if slotKey in pendingEscapees:
    report.escapees.add pendingEscapees[slotKey]
    pendingEscapees.del(slotKey)

  case slots[idx].phase
  of spCompiling:
    if report.stop.isSome:
      # Killed mid-compile — timeout or interrupt, identical shape either way.
      let suffix = case report.stop.get.reason
                   of ptypes.krTimeout:   "\n[compile timed out]"
                   of ptypes.krInterrupt: "\n[interrupted]"
      let output = readCapped(slots[idx].compOut, ctx.maxOutputBytes) & suffix
      var res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                                 compileSkipped: slots[idx].compileSkipped,
                                 attempts: slots[idx].attempt)
      let killedRes = toProcessResult(report, ptypes.Limits(), elapsed * 1000)
      res.compile = ptypes.Phase(kind: ptypes.pkRan, res: killedRes)
      res.run     = ptypes.Phase(kind: ptypes.pkSkipped)
      cleanupSlotOnTeardown(slots[idx])
      slots[idx].state = ssIdle
      return FinalizeOutcome(kind: fkDone, res: res)
    elif not report.exit.isSuccess:
      # Compile failed on its own — not killed.
      let output = readCapped(slots[idx].compOut, ctx.maxOutputBytes)
      var res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed)
      # M15: clean up per-slot cache and bin dirs on an actual compile
      # failure — nim's own output may be partial/corrupt.
      if slots[idx].cacheDir.len > 0:
        try: removeDir(slots[idx].cacheDir) except: discard
      if slots[idx].slotBinDir.len > 0:
        try: removeDir(slots[idx].slotBinDir) except: discard
      cleanupSlotTmp(slots[idx])
      let failedRes = toProcessResult(report, ptypes.Limits(), elapsed * 1000)
      res.compile = ptypes.Phase(kind: ptypes.pkRan, res: failedRes)
      res.run     = ptypes.Phase(kind: ptypes.pkSkipped)
      slots[idx].state = ssIdle
      return FinalizeOutcome(kind: fkDone, res: res)
    else:
      # RFC-0009 B4a: on Windows the C linker appends `.exe` to crisol's
      # extensionless `-o:` compile target (spawnCompileStable's
      # `binCompiled = binDirSlot / bname`, bname from binName() —
      # deliberately extensionless, matching the equally-extensionless
      # `stableBin`/manifest-json naming, which this must NOT touch), so the
      # binary the compiler actually wrote lands at `binCompiled & ".exe"`
      # while the slot still tracks the bare path. Every downstream consumer
      # of `slots[idx].binCompiled`/`binFull` for THIS compile — the
      # post-compile cache-hit promotion just below, `transitionToRun`'s run
      # spawn (which reads `slot.binFull`), and the post-run stable-copy
      # promotion (execute's fkDone handler, which captures `binCompiled`
      # off the slot right after this compile's child exits) — needs the
      # real on-disk path, so resolve it ONCE here, before anything reads
      # either field. `addFileExt` is a no-op when `ExeExt == ""` (POSIX),
      # so this block is inert there — POSIX byte-identical.
      if not fileExists(slots[idx].binCompiled) and
         fileExists(addFileExt(slots[idx].binCompiled, ExeExt)):
        slots[idx].binCompiled = addFileExt(slots[idx].binCompiled, ExeExt)
        slots[idx].binFull     = slots[idx].binCompiled

      # Compile succeeded, no stop act — capture it onto the slot so the
      # eventual run-phase result (below, or a later kill) carries BOTH
      # phases.
      slots[idx].compileProcRes = some(toProcessResult(report, ptypes.Limits(), elapsed * 1000))
      if not allowTransition:
        cleanupSlotOnTeardown(slots[idx])
        slots[idx].state = ssIdle
        return FinalizeOutcome(kind: fkOmitted)

      # rfc-0005 A2c-i: extract this compile's closure and update the
      # dependency graph entry NOW — right after compile finishes, before
      # the run child is spawned — instead of after the whole run
      # completes (the pre-existing site). The post-run promotion/
      # cache-store gate (in `execute`) reads `closureRecorded`/
      # `closureError` back off the slot rather than calling
      # `recordClosure` itself; the WHAT is unchanged, only the WHEN moved.
      if not sourceIndexBuilt:
        sourceIndex = buildSourceIndex(ctx.config)
        sourceIndexBuilt = true
      let rec = ctx.recordClosureFn(graph, ctx.config, pep.ep, slots[idx].cacheDir,
                              binName(pep.ep), CrisolProtocolMajor, sourceIndex,
                              realRunIn(ctx.projectRoot))  # r65: real compile subprocess cwd — ctx.projectRoot, the one canonical value
      slots[idx].closureRecorded = rec.ok
      slots[idx].closureError    = rec.error

      # rfc-0005 A2c-ii: post-compile cache consult. The closure/graph are
      # NOW fresh (just above) — derive this compile's key and consult the
      # cache BEFORE spawning the run child. Only attempted when caching is
      # active AND the closure recorded successfully: an unrecorded/
      # invalidated closure cannot be trusted to derive a correct key (the
      # same reasoning R9's store-gate already applies on the write side,
      # applied here on the read side) — a group opted out of caching, or a
      # globally-disabled policy, is handled by `consultPostCompile`'s own
      # `resolveCacheable` gate exactly like the plan-time path.
      #
      # RFC-0005 SO3 fix: ALSO gated on `slots[idx].attempt == 1`, mirroring
      # `shouldStore`'s own `attempt != 1 ⇒ cdmFlaky` rule on the write side.
      # Without this, a retry (attempt 2+) reaches this same consult every
      # time — `pep.edecision` is immutable across attempts, so
      # `spawnCompileStable` re-dispatches the SAME edNeverBuilt/edStale
      # decision on every attempt — and can hit a pass some OTHER host
      # published to the SAME key between attempt 1 and this attempt,
      # serving `fkCacheHit` (attempts=0, no ledger row, `flaky()`
      # structurally false) and silently masking what may be a genuine
      # local failure. On attempt > 1 the consult is skipped entirely: the
      # compile result falls straight through to `transitionToRun` below,
      # a real run every time, exactly like a cache-inactive run.
      if rec.ok and ctx.cache.isActive() and slots[idx].attempt == 1:
        let look = consultPostCompile(pep, ctx.cache.policy, ctx.cache.seams, ctx.cache.sink,
                                      ctx.cache.spec, ctx.cache.outcomePolicy)
        if look.decision == edCached and look.synthesized.isSome:
          if promoteCompiledBinary(pep.ep, ctx.config, slots[idx].binCompiled):
            # Genuine post-compile hit: the compile really ran (compile =
            # pkRan, replacing synthesize's default pkSkipped — the compile
            # ProcessResult was captured just above onto the slot) while the
            # run phase replays the stored observation (pkCached) verbatim;
            # no run child is ever spawned. Terminal immediately, exactly
            # like a plan-time edCached hit.
            var res = look.synthesized.get
            res.compileSkipped = false
            res.compile        = ptypes.Phase(kind: ptypes.pkRan,
                                              res: slots[idx].compileProcRes.get)
            res.cacheTier       = look.tier
            res.cacheLookup     = look.lookup
            cleanupSlotTmp(slots[idx])
            if slots[idx].slotBinDir.len > 0:
              try: removeDir(slots[idx].slotBinDir) except: discard
            slots[idx].state = ssIdle
            return FinalizeOutcome(kind: fkCacheHit, res: res)
          # Promotion failed: no stable binary would back cdmHit's own
          # invariant (every cdmHit has a stable binary, B3 relies on it) —
          # cannot safely serve this as a hit. Fall through to the normal
          # run path below, exactly like a miss (promoteCompiledBinary
          # already warned to stderr).
        # Miss, recompute-invalidated, or a hit whose promotion failed:
        # stash the REAL post-compile key/lookup/explain so the eventual
        # live result (once the run below completes) reports them honestly
        # instead of the pre-compile ""/cvOk/[] plan-time placeholders.
        slots[idx].postCompileConsulted = true
        slots[idx].postCompileInputHash = look.inputHash
        slots[idx].postCompileLookup    = look.lookup
        slots[idx].postCompileExplain   = look.explain

      let ok = transitionToRun(sv, slots[idx], slots[idx].runTimeoutMs, slots[idx].attempt,
                               ctx)
      if not ok:
        var res = EntrypointResult(ep: pep.ep, output: "fork failed during run phase",
                                   durationMs: elapsed)
        # M15: cacheDir intentionally LEFT ALONE — the compile that produced
        # it already succeeded; this is a run-phase spawn failure, unrelated
        # to the nimcache's validity.
        if slots[idx].slotBinDir.len > 0:
          try: removeDir(slots[idx].slotBinDir) except: discard
        cleanupSlotTmp(slots[idx])
        res.compile = ptypes.Phase(kind: ptypes.pkRan, res: slots[idx].compileProcRes.get)
        res.run     = ptypes.Phase(kind: ptypes.pkSpawnFailed,
                                   spawnError: "fork failed during run phase")
        slots[idx].state = ssIdle
        return FinalizeOutcome(kind: fkDone, res: res)
      return FinalizeOutcome(kind: fkTransitioned)

  of spRunning:
    let compilePhase =
      if slots[idx].compileProcRes.isSome:
        ptypes.Phase(kind: ptypes.pkRan, res: slots[idx].compileProcRes.get)
      else:
        ptypes.Phase(kind: ptypes.pkSkipped)  # cdSkipFresh: no compile this run
    var res: EntrypointResult
    if report.stop.isSome:
      # Killed mid-run (timeout or interrupt) — output only; sink
      # reconciliation for a runner-initiated kill is unchanged/out of
      # scope for this slice (pre-existing behavior).
      let output = readCapped(slots[idx].runOut, ctx.maxOutputBytes)
      res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                             compileSkipped: slots[idx].compileSkipped,
                             attempts: slots[idx].attempt)
    elif report.exit.kind == ptypes.ekSignaled:
      let output   = readCapped(slots[idx].runOut, ctx.maxOutputBytes)
      let sinkData = readSink(slots[idx].sinkPath, ctx.maxOutputBytes)
      res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                             compileSkipped: slots[idx].compileSkipped,
                             records: sinkData.records)
    else:
      let output   = readCapped(slots[idx].runOut, ctx.maxOutputBytes)
      let sinkData = readSink(slots[idx].sinkPath, ctx.maxOutputBytes)
      if sinkData.hasProtocol:
        res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                               compileSkipped: slots[idx].compileSkipped,
                               records: sinkData.records)
      else:
        res = classifyRunResult(pep.ep, output, elapsed, slots[idx].compileSkipped)
    let runRes = toProcessResult(report, slots[idx].spec.limits, elapsed * 1000,
                                 slots[idx].spec.level)  # rfc-0007 A6b
    cleanupSlotTmp(slots[idx])
    res.compile = compilePhase
    res.run     = ptypes.Phase(kind: ptypes.pkRan, res: runRes)
    slots[idx].state = ssIdle
    return FinalizeOutcome(kind: fkDone, res: res)

proc teardownDiscard(sv: var Supervisor; slots: var seq[Slot]) =
  ## rfc-0007 A2b: exception-path teardown — the `finally:` safety net for
  ## the normal AND exception paths (a no-op when every slot is already
  ## idle, which is always true on a normal/interrupted completion — the
  ## interrupt path above already drained to zero live slots). Shares the
  ## EXACT SAME requestStop/escalateExpired/next machinery as
  ## `teardownAllLive`, but authors nothing: `reap`'s ReapReport is
  ## discarded outright, never fed through `classifyCause`. There is no
  ## honest KillReason for "our own code raised" (§2 forbids reasons
  ## without producers) — `krTimeout` is used purely as the mechanical
  ## value `requestStop`'s signature requires; it is never read back into
  ## any Phase/Cause/output.
  let now0 = getMonoTime()
  for i in 0 ..< slots.len:
    if slots[i].state == ssLive:
      sv.requestStop(slots[i].id, ptypes.krTimeout)
      if slots[i].stopDeadline.isNone:
        slots[i].stopDeadline = some(now0 + initDuration(milliseconds = GracePeriodMs))

  while anyLiveSlot(slots):
    let now = getMonoTime()
    escalateExpired(sv, slots, now)
    let deadline = nextDeadline(slots, now, GracePeriodMs)
    let ev = sv.next(deadline)
    case ev.kind
    of weChildExited:
      let idx = slotIndexOf(slots, ev.id)
      discard sv.reap(slots[idx].id)   # DISCARDED — no Phase, no Cause, no onResult; never authors an escapee here.
        # r28: this used to force the conservative (no orphan-claim) scan
        # unconditionally, regardless of the slot's own phase — that
        # per-call override no longer exists; containment intent rides the
        # slot's own ChildSpec.claimOrphans now (false for a compiling
        # slot, true for a running one, same as every other reap site).
        # The report is discarded either way, so no Phase/Cause/output
        # observes the difference; a run-phase slot torn down here now
        # gets the same real orphan-kill cleanup a normal run reap would.
      cleanupSlotOnTeardown(slots[idx])
      slots[idx].state = ssIdle
    of weDeadline:
      discard
    of weShutdown:
      for i in 0 ..< slots.len:
        if slots[i].state == ssLive:
          sv.forceKill(slots[i].id)
          slots[i].forceKilled = true
    of weOrphanReaped:
      discard

proc classifyRunResult(
  ep: Entrypoint; output: string; elapsed: int64; compileSkipped: bool;
): EntrypointResult =
  ## rfc-0007 A1e-i: what used to select a legacy Outcome/exitCode/signal
  ## value is now just the plain opaque-fallback construction — `outcome(r)`
  ## derives pass/fail from the res.compile/res.run Phase set right after this
  ## returns (below, at the call site), never from a value computed here.
  EntrypointResult(ep: ep, output: output, durationMs: elapsed,
                   compileSkipped: compileSkipped)

proc warnMeasureCompileReuseNoWorkerOnce() =
  ## One-shot (per process, not per entrypoint) warning for the degraded-mode
  ## fallback in spawnCompileStable: measureCompileReuse was requested but no
  ## workerBinary is configured. spawnCompileStable runs once per compile
  ## slot — potentially hundreds of times in a single invocation — so this
  ## must not spam; the `{.global.}` var idiom (matching ledger.nim's
  ## bootId/shardSeq pattern) gives it process-lifetime-once semantics.
  var warned {.global.}: bool = false
  if not warned:
    stderr.write("crisol: warning: measure-compile-reuse requested but no " &
                 "worker binary configured; compiling monolithically " &
                 "(measurement skipped)\n")
    warned = true

proc buildCompileWorkerPlan(ep: Entrypoint; epAbs, cacheDir, binCompiled: string;
                             config: Config; projectRoot: string): MeasurePlan =
  ## Plan construction for the compile-slot measurement worker
  ## (`config.measureCompileReuse`).
  ##
  ## configHash = flagHash(ep.flags), computed PER-ENTRYPOINT — this MUST
  ## collide with appendAttemptRow's identityKey(ep, roots) (this file,
  ## ~line 213) or ArtifactRows silently orphan from the RunLedger's
  ## IdentityKey (measureworker.nim's own documented contract).
  ##
  ## r65: `projectRoot` is threaded in by the caller (`ctx.projectRoot`) —
  ## this proc has no `ExecCtx` of its own to read, but must still use the
  ## SAME already-canonicalized value every other spawn/finalize site uses,
  ## never re-derive its own via `config.projectRoot.absolutePath.normalizedPath`
  ## (that re-derivation is cwd-dependent and used to silently diverge from
  ## `ctx.projectRoot` whenever the invoking process's cwd differed from the
  ## resolve-time cwd).
  MeasurePlan(
    # Source the entrypoint's identity from its TrackedPath, serialized to
    # the worker via the display() accessor (a deliberate string wire — the
    # worker consumes a plain path and reconstructs its own TrackedPath, see
    # measureworker.nim). This preserves the collision with
    # appendAttemptRow's identityKey(ep, roots) noted above.
    entrypointPath:    string(ep.tp.display()),
    entrypointAbsPath: epAbs,
    flags:             ep.flags,
    nimcacheDir:       cacheDir,
    outputBinPath:     binCompiled,
    groupId:           ep.group,
    configHash:        flagHash(ep.flags),
    stateDir:          stateDirOf(config),
    projectRoot:       projectRoot,
  )

proc dirHasEntries(dir: string): bool =
  ## True iff `dir` exists and contains at least one directory entry.  Used
  ## by `spawnCompileStable` to decide, BEFORE `createDir(cacheDir)` runs,
  ## whether this compile is landing in a genuinely fresh nimcache directory
  ## or a warm-but-unrecorded one (issue #16 slice 1b, rule 2 of
  ## `bustStaleExternalObjects`).
  if not dirExists(dir): return false
  for _ in walkDir(dir):
    return true
  false

proc bustStaleExternalObjects(cacheDir: string; ep: Entrypoint; graph: DepGraph;
                              config: Config; hadPriorContent: bool) =
  ## Issue #16 slice 1b. Nim's own external-object cache (`extccomp.nim`:
  ## `footprint` = sha1 of source content + OS + CPU + cc name + cc command,
  ## NEVER the headers it `#include`s; `addExternalFileToCompile` marks an
  ## external Cached — skips recompiling it — iff `fileExists(obj)` and that
  ## footprint is unchanged) ignores headers entirely. So after a
  ## header-only edit, crisol's own closure hash correctly goes stale and the
  ## entrypoint recompiles, but Nim's cache still considers the external
  ## itself unchanged and would happily relink the STALE object sitting in
  ## the persistent nimcache — silently serving output that does not reflect
  ## the header edit. Deleting the object (no `.sha1`-file surgery needed) is
  ## what forces Nim to recompile it; this must happen BEFORE `nim c` is
  ## spawned, which is why this is called from `spawnCompileStable` right
  ## after the pre-compile `createDir`/`removeFile` housekeeping.
  ##
  ## Two rules:
  ##
  ## 1. A depgraph entry exists for `(ep.tp.display(), flagHash(ep.flags))`: delete
  ##    exactly the objects `depgraph.staleExternalObjects` flags, using the
  ##    entry's recorded per-external header hashes — precise, per-external.
  ##
  ## 2. No entry exists, but `cacheDir` already held content before this
  ##    compile (`hadPriorContent`, computed by the caller BEFORE
  ##    `createDir(cacheDir)` — see `dirHasEntries`): a warm nimcache with no
  ##    matching record (a depgraph format-version discard, a `crisol clean`
  ##    GC, or an entry invalidated by a previous failed `recordClosure`).
  ##    With no header record to compare against, crisol cannot know
  ##    PRECISELY which external objects are stale, so it conservatively
  ##    colds EVERY foreign (non-module) object directly in `cacheDir` —
  ##    anything `closure.isModuleObjectName` does NOT recognize as a Nim
  ##    module object — forcing Nim to recompile every external. This lets
  ##    the next `extractCompileInputs` see a fresh `compile` entry for each
  ##    one and re-derive its headers via `cc -M`, instead of failing closed
  ##    for want of a carried-forward header record.
  ##
  ## Fails closed: a deletion that raises (the object exists but cannot be
  ## removed) propagates to the caller, which treats it like any other
  ## pre-compile setup failure (`oSpawnError`) — a stale external object
  ## that cannot be evicted must never be linked into a binary crisol then
  ## reports on. `removeFile` on an already-absent object is a no-op, so
  ## only a genuinely broken state directory reaches this path.
  let key = entryKey(ep.tp, ep.flags)
  if key in graph.entries:
    for obj in staleExternalObjects(graph, string(ep.tp.display()), ep.flags, config.trackedRoots):
      removeFile(cacheDir / obj)
  elif hadPriorContent:
    for kind, path in walkDir(cacheDir):
      if kind != pcFile: continue
      let base = path.extractFilename
      if not base.endsWith(".o"): continue
      if isModuleObjectName(base): continue
      removeFile(path)

proc promoteCompiledBinary(ep: Entrypoint; config: Config; binCompiled: string): bool =
  ## Copy a per-slot compiled binary to its stable slug-keyed path (what
  ## `decideCompile` checks on future runs) and mark it executable. A no-op
  ## (returns true) when there is nothing to promote — `binCompiled` empty,
  ## or already the stable path itself. On any copy/chmod failure, warns to
  ## stderr and removes whatever partial file landed at the stable path
  ## (never leave a binary no depgraph entry describes, issue #13.3),
  ## returning false so the caller can treat "no stable binary" as the
  ## honest outcome — this is exactly what a genuine post-compile cache hit
  ## (RFC-0005 A2c-ii) requires before it can be served: `cdmHit` relies on
  ## a stable binary existing at rest.
  let stableBinDir = binPath(ep, config)
  # RFC-0009 B4a: route through `stableBinPath` (not `stableBinDir / bname`)
  # so the promotion target agrees with decideCompile's freshness check and
  # spawnRunDirect's spawn target on every platform — see its doc comment.
  let stableBin    = stableBinPath(ep, config)
  if binCompiled.len == 0 or binCompiled == stableBin:
    return true
  try:
    createDir(stableBinDir)
    copyFile(binCompiled, stableBin)
    setFilePermissions(stableBin, {fpUserRead, fpUserWrite, fpUserExec,
                                   fpGroupRead, fpGroupExec,
                                   fpOthersRead, fpOthersExec})
    true
  except CatchableError as e:
    # Promotion failed partway (e.g. copyFile succeeded but
    # setFilePermissions did not) — whatever landed at stableBin has
    # unknown/partial content and no depgraph entry describes it either
    # way; discard it so the next run starts from cdNeverBuilt instead of
    # trusting it. Not exercisable under test as root (chmod-based faults
    # do not fail for root); this is untested hardening.
    stderr.write("crisol: warning: " & string(ep.tp.display()) &
                 ": could not promote its compiled binary (" &
                 e.msg & "); the previous binary was discarded\n")
    try: stderr.flushFile() except CatchableError: discard
    try: removeFile(stableBin) except CatchableError: discard
    false

proc enterLive(slot: var Slot; id: ChildId; phase: SlotPhase; deadline: MonoTime) =
  ## code-review r25: the "entering a live phase" bookkeeping every site
  ## that puts a slot's child-identity/deadline into effect needs — a new
  ## ChildId, this phase's own deadline, and clean stop/kill state for it.
  ## Shared by `claimSlot` (below, for a genuinely NEW occupant) AND
  ## `transitionToRun`'s in-place compile→run handoff, which calls this
  ## directly and must NOT touch anything else on the slot — pepIdx, paths,
  ## spec, and every compile-bookkeeping field all carry over from the SAME
  ## occupant's just-finished compile phase.
  ## rfc-0007 code-review r6: `t0` resets HERE, at every phase entry — a run
  ## phase's `t0` must be the run's own spawn instant, not an inherited
  ## compile-spawn instant (the bug this closed: `finalizeSlot`'s `elapsed`,
  ## derived from `t0`, was silently folding compile time into every
  ## recompiled run's reported duration before `transitionToRun` reset it).
  slot.id           = id
  slot.phase        = phase
  slot.deadline     = deadline
  slot.stopDeadline = none(MonoTime)
  slot.forceKilled  = false
  slot.t0           = epochTime()

proc claimSlot(
  id:              ChildId; pepIdx, attempt: int; phase: SlotPhase; deadline: MonoTime;
  runTimeoutMs:    int;
  tmpDir, testScratchDir, compOut, runOut, sinkPath,
  binCompiled, binFull, cacheDir, slotBinDir: string;
  compiledThisRun, compileSkipped: bool;
  spec:            SandboxSpec;
): Slot =
  ## code-review r25: the ONE place a physical slot is claimed by a brand
  ## new occupant — `spawnCompileStable` (a compiling entrypoint) and
  ## `spawnRunDirect` (cdSkipFresh) both build their slot state through
  ## this constructor instead of each hand-assigning the same ~20 fields
  ## (a prior version of this file had exactly that: three near-identical
  ## reset blocks, one per slot-claim site, kept in sync only by hand). A
  ## field added to `Slot` in the future defaults correctly at every claim
  ## site by construction — there is only one place left to forget it.
  ##
  ## Every per-occupant field a new claim must NOT inherit from whatever
  ## entrypoint previously lived in this physical slot is named here,
  ## explicitly — including `binCompiled`/`cacheDir` for a cdSkipFresh
  ## claim (spawnRunDirect passes ""), which the pre-refactor code silently
  ## left at the PREVIOUS occupant's values; harmless only because every
  ## downstream reader happens to gate on `compiledThisRun` first, an
  ## accidental-not-structural safety this constructor now makes explicit.
  ##
  ## `attempt`/`peakRssBytes` are part of the claim (not the dispatch
  ## loop's own side channel): every claim starts attempt-numbered and with
  ## a freshly-zeroed RSS peak, by construction. `token` is deliberately
  ## left at its zero value — S3's admission token is stamped by the
  ## dispatch loop only once the spawn this claim represents has actually
  ## succeeded (see execute()'s fill pass), same as before this refactor.
  result.state           = ssLive
  result.pepIdx          = pepIdx
  result.attempt         = attempt
  result.peakRssBytes    = 0
  result.runTimeoutMs    = runTimeoutMs
  result.tmpDir          = tmpDir
  result.testScratchDir  = testScratchDir
  result.compOut         = compOut
  result.runOut          = runOut
  result.sinkPath        = sinkPath
  result.binCompiled     = binCompiled
  result.binFull         = binFull
  result.cacheDir        = cacheDir
  result.slotBinDir      = slotBinDir
  result.compiledThisRun = compiledThisRun
  result.compileSkipped  = compileSkipped
  result.spec            = spec
  result.compileProcRes  = none(ptypes.ProcessResult)
  result.closureRecorded = false
  result.closureError    = ""
  result.postCompileConsulted = false
  result.postCompileInputHash = ""
  result.postCompileLookup    = cvOk
  result.postCompileExplain   = @[]
  enterLive(result, id, phase, deadline)

proc spawnCompileStable(
  sv:               var Supervisor;
  slot:             var Slot;
  pepIdx, attempt:  int;
  pep:              PlannedEntrypoint;
  graph:            DepGraph;
  ctx:              ExecCtx;
): bool =
  ## Fill slot with a compile child.
  ##
  ## code-review r24: `config`/`compileTimeoutMs`/`spec`/`toolchainFp`/
  ## `dupSlugs` — every run-lifetime invariant this proc used to take as
  ## its own param — now arrive together as `ctx: ExecCtx` (see its type
  ## doc); `spec` is `ctx.cache.spec`, the same SandboxSpec the whole run
  ## resolves once. `pepIdx`/`attempt`/`pep`/`graph` are per-call and stay
  ## explicit — `graph` in particular is READ here (bustStaleExternalObjects)
  ## but mutated only inside `finalizeSlot`'s closure-recording step, so a
  ## stale snapshot here would be a real bug, not a style nit.
  ##
  ## nimcache (RFC-0006 nimcache-persistence): the COMMON case (this
  ## entrypoint's slug appears exactly once in the plan) uses the STABLE,
  ## toolchain-fingerprinted `cachePath(ep, config, toolchainFp)` — a pure
  ## function of (ep.tp, ep.flags, toolchainFp), never of plan position —
  ## so Nim's own incremental compile can reuse it run-to-run (this is the
  ## fix: previously every cacheDir was suffixed with `_<pepIdx>`, the
  ## entrypoint's POSITION in the plan, which shifts on `--changed`/subset
  ## runs and forced a cold recompile every time). It is never deleted on a
  ## successful (or run-phase-failed) compile — only on a compile FAILURE or
  ## timeout, where Nim's own output may be partial/corrupt (see pollSlot).
  ##
  ## The RARE case — this slug is scheduled at ≥2 positions in the SAME plan
  ## (duplicateSlugs) — falls back to the OLD pepIdx-suffixed dir, which is
  ## deliberately volatile: it exists only to prevent two concurrent slots
  ## from racing on one nimcache write, never to persist.
  ##
  ## The compiled binary always goes into a per-slot (pepIdx-suffixed)
  ## directory (binDirSlot) — this is pure scratch, always cleaned up after
  ## the stable slug-keyed copy (binPath) is made by the execute main loop,
  ## and is unaffected by the nimcache-persistence change.
  ##
  ## The slot runs the binary from its per-slot location (binCompiled == binFull
  ## during this run).  After the run completes, the execute main loop copies
  ## binCompiled to the STABLE slug-keyed path (binFull will be reset there),
  ## and records freshness.  decideCompile checks the stable path on future runs.
  ##
  ## M8: temp output files live inside a mkdtemp-created directory (unpredictable
  ## name) instead of PID-predictable paths.
  ## R3: ep path is resolved to absolute before passing to nim c.
  ## M15: cacheDir and binDirSlot are tracked in slot so they can be cleaned on
  ## compile-fail and spawn-fail paths (see pollSlot for the precise rules
  ## under nimcache-persistence: cacheDir is wiped ONLY when nim's own compile
  ## process actually ran and failed/timed out — never on a pre-compile setup
  ## failure or a post-compile run-spawn failure, both of which leave a prior
  ## persistent nimcache untouched-and-valid).
  let config           = ctx.config
  let spec             = ctx.cache.spec
  let toolchainFp      = ctx.toolchainFp
  let dupSlugs         = ctx.dupSlugs
  let compileTimeoutMs = ctx.compileTimeoutMs

  let ep = pep.ep
  # R3: resolve entrypoint to absolute path before passing to nim c.
  let epAbs = toNative(ep.tp, config.trackedRoots)

  let epSlug = epSlug(ep, config.trackedRoots)
  let cacheDir =
    if epSlug in dupSlugs:
      # Rare: same (path, flags) scheduled twice in this plan — keep the old
      # volatile per-slot suffix so two concurrent slots never race on one
      # nimcache write. Also toolchain-keyed for consistency, though this
      # dir is transient and never meant to persist.
      cachePath(ep, config, toolchainFp) & "_" & $pepIdx
    else:
      # Common case: stable, persistent nimcache — the fix.
      cachePath(ep, config, toolchainFp)
  let binDirSlot  = binPath(ep, config) & "_" & $pepIdx
  let bname       = binName(ep)
  let binCompiled = binDirSlot / bname     # compile output + run source

  # Issue #16 slice 1b: "did cacheDir already hold content" must be observed
  # BEFORE createDir(cacheDir) below (which would otherwise make a fresh dir
  # indistinguishable from a warm one) — see bustStaleExternalObjects's rule
  # 2 and dirHasEntries's doc comment.
  let hadPriorCacheContent = dirHasEntries(cacheDir)

  try:
    createDir(cacheDir)
    createDir(binDirSlot)
    # Issue #11: the compiler runs with -d:nimBetterRun (see
    # compiledriver.nimCompileArgs), which also enables Nim's own
    # "nothing changed, skip the compile" short-circuit. That short-circuit
    # requires the `-o:` target to already exist — and its change detection
    # does NOT cover `{.compile.}`d C sources, so a surviving per-slot binary
    # (e.g. left behind by a crash before the post-copy cleanup below) could
    # be served stale after a C-source edit. Remove any pre-existing target
    # here so the short-circuit's precondition is false by construction at
    # the moment the compiler is spawned, not by a distant cleanup.
    removeFile(binCompiled)
    # Issue #16: bust any external object Nim's own cache would otherwise
    # serve stale because a header it #includes changed — see
    # bustStaleExternalObjects's doc comment. Must run BEFORE forkExec
    # below; a failed eviction is a pre-compile setup failure like the
    # createDir/removeFile calls above (return false, oSpawnError).
    bustStaleExternalObjects(cacheDir, ep, graph, config, hadPriorCacheContent)
  except:
    return false

  # M8: use mkdtemp for temp output files — avoids PID-predictable paths.
  var tmpDir: string
  try:
    tmpDir = makeTmpDir("crisol_slot_")
  except:
    # M15: clean up the scratch bin dir. cacheDir is deliberately left alone:
    # nim c never ran this attempt (mkdtemp failed before forkExec), so any
    # content in cacheDir is a valid PERSISTENT nimcache from a prior run —
    # wiping it here would destroy good state over an unrelated tmp-dir
    # allocation failure.
    try: removeDir(binDirSlot) except: discard
    return false

  let compOut = tmpDir / "compile_out.txt"
  let runOut  = tmpDir / "run_out.txt"
  let sinkFile = tmpDir / "sink.ndjson"

  # config.workerBinary (NOT getAppFilename()) is always the worker's argv[0]
  # below, for BOTH worker branches: getAppFilename() returns the CURRENTLY
  # RUNNING process's binary, which is only a sound worker host when that
  # process itself dispatches the relevant internal token (true of the
  # crisol CLI, never guaranteed of an arbitrary library host — see
  # Config.workerBinary's doc in types.nim). An empty workerBinary always
  # falls through to the monolithic path rather than guessing with
  # getAppFilename().
  template monolithicCompArgs(): seq[string] =
    # R3: epAbs is the absolute entrypoint path. compiledriver.nimCompileArgs
    # is the single argv-assembly proc shared with the measure-mode compile
    # path (issue #11: it also injects -d:nimBetterRun so the nimcache
    # manifest carries `depfiles`, which closure.extractClosure needs).
    @["nim"] & nimCompileArgs(epAbs, ep.flags, cacheDir, binCompiled)

  # review Q6: the measureCompileReuse worker branch below builds a
  # MeasurePlan, writes it to a per-slot plan.json, and launches
  # `<workerBinary> <token> <planPath>`. Kept as a hygienic template (same
  # pattern as `monolithicCompArgs` above) so the write+cleanup logic has a
  # single home.
  template writeWorkerPlan(planFilename: string; token: string): seq[string] =
    let mplan = buildCompileWorkerPlan(ep, epAbs, cacheDir, binCompiled, config, ctx.projectRoot)
    let planPath = tmpDir / planFilename
    try:
      writeFile(planPath, $toJson(mplan))
    except:
      # M15: cacheDir intentionally NOT wiped — nim c never ran this attempt
      # (plan write failed before forkExec); see the mkdtemp-failure comment
      # above for why a persistent nimcache must survive an unrelated
      # pre-compile I/O error.
      try: removeDir(tmpDir)     except: discard
      try: removeDir(binDirSlot) except: discard
      return false
    @[config.workerBinary, token, planPath]

  var compArgs: seq[string]
  if config.measureCompileReuse and config.workerBinary.len > 0:
    # RFC-0006 M-artifact-identity PASS (b2): the slot's ONE compile child
    # becomes the measurement worker (`<workerBinary> --internal-measure-compile
    # <plan.json>`) instead of a direct `nim c` invocation. The worker
    # produces the SAME runnable binary at `binCompiled` either way, so
    # everything downstream of this branch is unaffected.
    compArgs = writeWorkerPlan("measure_plan.json", InternalMeasureCompileToken)
  else:
    if config.measureCompileReuse:
      # measureCompileReuse was requested but no sound worker binary is
      # configured (library host that never set RunOptions.workerBinary).
      # NEVER call getAppFilename() here — that would re-exec the CURRENTLY
      # RUNNING process (the library host's own binary, not crisol), which
      # ignores --internal-measure-compile and just re-runs the host program
      # again → unbounded recursive fork, only stopped by the compile
      # watchdog. Degrade to the monolithic `nim c` path instead (measurement
      # skipped); warn once per process, not once per entrypoint (this runs
      # per compile slot, potentially hundreds of times per invocation).
      warnMeasureCompileReuseNoWorkerOnce()
    compArgs = monolithicCompArgs()

  # rfc-0007 A2b: ONE spawn path. ChildSpec.env is ALWAYS explicit (§1) — the
  # compile phase stays unsandboxed (A6), so this is the parent env copied
  # verbatim (filterEnv's envScrub:false branch), never "whatever environ
  # is" by implicit fork() inheritance.
  # rfc-0007 A2c (#17): cwd is ALWAYS config.projectRoot — never "" (the
  # invoking crisol process's own cwd, which may be a subdirectory reached
  # via `--config ../crisol.kdl`, or entirely unrelated when driven through
  # the library API). A root-relative compile flag (e.g. `--path:src`) is
  # resolved by `nim` against ITS OWN cwd, so this is the ONE place that
  # guarantees a `--path:src` group compiles identically no matter where
  # crisol itself was invoked from. r65: reads `ctx.projectRoot` (the ONE
  # canonicalized value, computed once in `execute`) — never re-derives its
  # own via `config.projectRoot.absolutePath.normalizedPath`.
  let childSpec = ChildSpec(
    argv:   compArgs,
    cwd:    ctx.projectRoot,
    env:    filterEnv(toSeq(envPairs()), SandboxSpec(envScrub: false), @[]),
    sinks:  combinedSink(compOut),
    limits: ptypes.Limits(),  # compile is unsandboxed — no limits requested
    # r28: compile toolchain transients (`nim` -> `cc`/`gcc`) can
    # transiently reparent to crisol mid-compile — never a test escapee,
    # so this spawn is exempt from reparented-orphan claiming at reap
    # (see ChildSpec.claimOrphans' doc comment, process/types.nim).
    claimOrphans: false,
  )
  let sr = sv.spawn(childSpec)
  if not sr.ok:
    # M15: cacheDir intentionally NOT wiped — nim c never ran this attempt
    # (spawn itself failed); see the mkdtemp-failure comment above.
    try: removeDir(tmpDir)     except: discard
    try: removeDir(binDirSlot) except: discard
    return false

  # code-review r25: ONE constructor builds the entire fresh slot state —
  # see claimSlot's doc comment for why the ~20 fields below are no longer
  # hand-assigned at this (or any other) claim site. testScratchDir is ""
  # here (populated only when spec.tmpdir=true, on the run-phase side of a
  # later transitionToRun); binCompiled/binFull are both the per-slot
  # compile output — the execute() main loop copies it to the stable
  # slug-keyed path once the run completes.
  slot = claimSlot(
    id = sr.id, pepIdx = pepIdx, attempt = attempt, phase = spCompiling,
    deadline = getMonoTime() + initDuration(milliseconds = compileTimeoutMs),
    runTimeoutMs = effectiveRunTimeoutMs(ep, config),  # S2b: per-entrypoint run budget
    tmpDir = tmpDir, testScratchDir = "",
    compOut = compOut, runOut = runOut, sinkPath = sinkFile,
    binCompiled = binCompiled, binFull = binCompiled,
    cacheDir = cacheDir, slotBinDir = binDirSlot,
    compiledThisRun = true, compileSkipped = false,
    spec = spec,
  )
  result = true

proc buildRunChildSpec(
  binFull:       string;
  runOut:        string;
  sinkFile:      string;
  spec:          SandboxSpec;
  attempt:       int;
  projectRoot:   string;
  outScratchDir: var string;
): ChildSpec =
  ## rfc-0007 A2b: the SINGLE ChildSpec-building path for a run child —
  ## shared by `spawnRunDirect` (cdSkipFresh) and `transitionToRun` (a
  ## freshly-compiled entrypoint), replacing crisol/spawn.nim's
  ## `forkExecEnvScratch`. The scratch tmpdir (when `spec.tmpdir`) is
  ## created HERE, in the runner, before spawn — the Supervisor's
  ## `spawnChild` no longer owns any scratch/env resolution (§1: `cwd`/
  ## `env` are resolved by the RUNNER before spawn). May raise (mkdtemp
  ## failure) — callers catch and treat it as a spawn failure, same as
  ## before.
  outScratchDir = ""
  var injected = @[("CRISOL_SINK", sinkFile), ("CRISOL_ATTEMPT", $attempt)]
  if spec.tmpdir:
    let scratch = makeTmpDir("crisol_scratch_")
    outScratchDir = scratch
    injected.add(("TMPDIR", scratch))
  # rfc-0007 A2b "explicit env for hlNone": ChildSpec.env is ALWAYS explicit
  # now (§1) — filterEnv already implements exactly this contract (envScrub
  # false = the parent env explicitly copied, never implicit inheritance).
  let env = filterEnv(toSeq(envPairs()), spec, injected)
  # rfc-0007 A2c (#17): cwd is `projectRoot` by default — ONLY overridden by
  # an explicit `chdirIntoScratch` opt-in (the test's own isolated scratch
  # dir takes precedence over projectRoot, same rule as before this slice;
  # the change is what the "otherwise" branch resolves to: it used to be ""
  # (inherit the crisol process's own cwd), now it is always projectRoot).
  let cwd = if spec.chdirIntoScratch and outScratchDir.len > 0: outScratchDir else: projectRoot
  ChildSpec(argv: @[binFull], cwd: cwd, env: env, sinks: combinedSink(runOut),
            limits: spec.limits)

proc spawnRunDirect(
  sv:           var Supervisor;
  slot:         var Slot;
  pepIdx:       int;
  pep:          PlannedEntrypoint;
  attempt:      int;
  ctx:          ExecCtx;
): bool =
  ## Fill slot directly with a run child (cdSkipFresh: compile skipped).
  ## Returns false on resource allocation failure.
  ## R1: injects CRISOL_SINK into the child environment.
  ## B0: injects CRISOL_ATTEMPT=attempt (1-indexed) into the child environment.
  ## rfc-0007 A2b: routes through `sv.spawn` + `buildRunChildSpec` — the
  ## single spec-driven spawn entry — so the LIVE run path actually applies
  ## hermeticity (env scrub, isolated TMPDIR, rlimits) and reports per-limit
  ## LimitsAchieved via the Supervisor's own status-pipe readback (§1),
  ## delivered in ReapReport at reap time (finalizeSlot), not here.
  ## M8: uses mkdtemp for temp output files.
  ## S2b: run deadline set from effectiveRunTimeoutMs(ep, config).
  ## code-review r24: `config`/`spec` arrive via `ctx: ExecCtx` now (see its
  ## type doc) — `pepIdx`/`pep`/`attempt` are per-call and stay explicit.
  let config = ctx.config
  let spec   = ctx.cache.spec

  let ep = pep.ep
  # RFC-0009 B4a: the stable binary's real on-disk name (with the platform
  # executable extension on Windows) — see `stableBinPath`'s doc comment;
  # this must agree with promoteCompiledBinary's copy target and
  # decideCompile's freshness check, or a cdSkipFresh run spawns a path
  # nothing was ever written to.
  let binFull = stableBinPath(ep, config)
  let rtMs = effectiveRunTimeoutMs(ep, config)  # S2b: per-entrypoint run budget

  # M8: use mkdtemp for temp output directory.
  var tmpDir: string
  try:
    tmpDir = makeTmpDir("crisol_run_")
  except:
    return false

  let runOut   = tmpDir / "run_out.txt"
  let sinkFile = tmpDir / "sink.ndjson"

  var scratchDir: string
  var childSpec: ChildSpec
  try:
    childSpec = buildRunChildSpec(binFull, runOut, sinkFile, spec, attempt,
                                  ctx.projectRoot, scratchDir)  # r65: ctx.projectRoot — the one canonical value, never re-derived
  except:
    try: removeDir(tmpDir) except: discard
    return false

  let sr = sv.spawn(childSpec)
  if not sr.ok:
    try: removeDir(tmpDir) except: discard
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  # code-review r25: same constructor as spawnCompileStable's claim — see
  # claimSlot's doc comment. binCompiled/cacheDir are explicitly "" here (a
  # cdSkipFresh claim has neither): before this fix they were simply never
  # assigned in this proc, silently leaving whatever a PREVIOUS occupant of
  # this physical slot had left there — harmless only by accident, because
  # every downstream reader happens to gate on compiledThisRun (false here)
  # before ever looking at them.
  slot = claimSlot(
    id = sr.id, pepIdx = pepIdx, attempt = attempt, phase = spRunning,
    deadline = getMonoTime() + initDuration(milliseconds = rtMs),
    runTimeoutMs = rtMs,  # S2b: stored for reference (deadline already set)
    tmpDir = tmpDir, testScratchDir = scratchDir,
    compOut = "", runOut = runOut, sinkPath = sinkFile,
    binCompiled = "", binFull = binFull,
    cacheDir = "", slotBinDir = "",
    compiledThisRun = false, compileSkipped = true,
    spec = spec,  # A2b: carried so groupRssBytes callers and a later kill
                  # have the same spec context
  )
  result = true

proc transitionToRun(sv: var Supervisor; slot: var Slot; runTimeoutMs: int;
                     attempt: int; ctx: ExecCtx): bool =
  ## rfc-0007 A2b: transition a compile-succeeded, un-stopped slot into its
  ## running phase — spawns the compiled binary as a NEW child (a fresh
  ## ChildId; the compile child's id was already consumed by `reap` before
  ## this is called). Returns false on spawn failure; caller records
  ## oSpawnError. Formerly `spawnRun`.
  ## R1: injects CRISOL_SINK into the child's environment.
  ## B0: injects CRISOL_ATTEMPT=attempt (1-indexed) into the child environment.
  ## code-review r24: `projectRoot` arrives via `ctx: ExecCtx` now.
  ## code-review r25: this is the THIRD slot-claim site, but a DELIBERATELY
  ## PARTIAL one — the same occupant's compile phase already set pepIdx/
  ## paths/spec/compile-bookkeeping just above (finalizeSlot), and those
  ## must carry over untouched into the run phase; only `enterLive`'s
  ## shared "entering a live phase" subset applies here, never `claimSlot`
  ## (which would wrongly wipe them as though a NEW occupant had arrived).

  var scratchDir: string
  var childSpec: ChildSpec
  try:
    childSpec = buildRunChildSpec(slot.binFull, slot.runOut, slot.sinkPath,
                                  slot.spec, attempt, ctx.projectRoot, scratchDir)
  except:
    return false

  let sr = sv.spawn(childSpec)
  if not sr.ok:
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  enterLive(slot, sr.id, spRunning, getMonoTime() + initDuration(milliseconds = runTimeoutMs))
  slot.testScratchDir  = scratchDir   # A4a/A6: cleaned on all exit paths
  result = true

proc cleanupSlotTmp(slot: Slot) =
  ## Remove temp output files (compile and run output captured), the sink
  ## file, the A4a per-entrypoint scratch tmpdir (testScratchDir), and the
  ## per-slot tmpDir itself.
  ##
  ## code-review r14: this proc is called from every finalizeSlot path that
  ## releases a slot back to ssIdle without going through
  ## cleanupSlotOnTeardown — compile-own-failure, the post-compile cache
  ## hit, run-spawn-fail, and normal run completion — making it the single
  ## choke point where the tmpDir created by spawnCompileStable's/
  ## spawnRunDirect's mkdtemp gets removed, so no release path can leak it.
  ## (Previously the dir itself was left for a caller to remove and only
  ## the shuttingDown teardown branch in `execute` actually did — every
  ## OTHER release path leaked one crisol_slot_*/crisol_run_* dir per
  ## entrypoint per run.) Safe to call unconditionally: the NEXT claim on
  ## this slot (spawnCompileStable/spawnRunDirect) always mkdtemps a fresh
  ## tmpDir before the slot goes live again, so this never races a reused
  ## slot's new directory.
  if slot.compOut.len > 0:
    try: removeFile(slot.compOut) except: discard
  if slot.runOut.len > 0:
    try: removeFile(slot.runOut) except: discard
  if slot.sinkPath.len > 0:
    try: removeFile(slot.sinkPath) except: discard
  # A4a: remove the per-entrypoint scratch tmpdir on all exit paths.
  if slot.testScratchDir.len > 0:
    try: removeDir(slot.testScratchDir) except: discard
  if slot.tmpDir.len > 0:
    try: removeDir(slot.tmpDir) except: discard

# ---------------------------------------------------------------------------
# RFC-0005 B3a: --verify-cache synthetic plan builder
# ---------------------------------------------------------------------------

proc buildVerifyPlan*(entrypoints: seq[PlannedEntrypoint];
                      indices: seq[int]): RunPlan =
  ## Build a `RunPlan` DIRECTLY from the sampled subset of an already-planned
  ## run's `PlannedEntrypoint` values (RFC-0005 §Stage B "Synthetic plan, not
  ## a re-`plan()`") — no re-discovery, no depgraph mutation/save. `indices`
  ## is normally `sampleHitIndices`'s output (types.nim), but this proc takes
  ## plain indices so it stays independently shape-testable.
  ##
  ## `jobs = 1` (determinism — the RFC requires the verify pass to run
  ## serially) and each sampled entry's `retries` is forced to 0 (single
  ## attempt: a retry would mask the very flakiness verify exists to find).
  ##
  ## RFC-0005 code-review SO5 fix: `edecision` is ALSO forced to
  ## `edRunFresh` here, overriding whatever the MAIN run's plan actually
  ## carried for this entry. A plan-time cache hit's `edecision` genuinely
  ## already IS `edRunFresh` (the promotion to `edCached` lives only in
  ## `PlanLookup.decision`, never written back to `edecision`) — but a
  ## `cdmHit` can ALSO come from `finalizeSlot`'s POST-COMPILE cache consult
  ## (RFC-0005 A2c-ii), and such an entry's `edecision` at plan time is
  ## `edNeverBuilt`/`edStale` (that is WHY the consult had to run: the plan
  ## didn't know about the hit until after compiling). Left unforced,
  ## `execute()`'s own dispatch (`if pep.edecision == edRunFresh:
  ## spawnRunDirect else: spawnCompileStable`) would route such an entry
  ## through `spawnCompileStable` in THIS diagnostic-only verify sub-run —
  ## a genuine recompile whose `finalizeSlot` calls `recordClosure`, which
  ## unconditionally calls `saveDepGraph` (depgraph.nim) and PERSISTS the
  ## mutation to disk — exactly the "no depgraph mutation/save" contract
  ## this proc's own doc line (above) promises but did not, before this
  ## fix, actually keep for post-compile-consult-originated hits.
  ##
  ## The override is sound because every `cdmHit` entry — from EITHER a
  ## plan-time hit or a post-compile consult hit — already has a stable
  ## binary at `binPath(ep, config)/binName(ep)` by construction (see
  ## `finalizeSlot`'s A2c-ii promotion path, and `verifyCachePass`'s own
  ## "Binary precondition" doc note: "`cdmHit` this run implies `edRunFresh`
  ## at plan time, i.e. the binary exists" — true for the ORIGINAL hit;
  ## this override makes it true for the SYNTHETIC one too). Forcing
  ## `edRunFresh` makes every sampled entry dispatch to `spawnRunDirect`
  ## (cdSkipFresh: reuse the already-promoted stable binary, no recompile
  ## at all) exactly like a plan-time hit always did — `spawnCompileStable`,
  ## and therefore `recordClosure`/`saveDepGraph`, are never reached from
  ## this pass, period.
  ##
  ## Every other `PlannedEntrypoint` field is carried through unchanged.
  ##
  ## Pure: never mutates `entrypoints` (the caller's original plan/report) —
  ## the override lands only on the synthetic copy `e`, never written back.
  result = RunPlan(jobs: 1)
  for i in indices:
    var e = entrypoints[i]
    e.retries = 0
    e.edecision = edRunFresh   # SO5 fix: always reuse the promoted stable
                               # binary; never recompile in a verify pass.
    result.entrypoints.add e

# ---------------------------------------------------------------------------
# execute — bounded-parallel continue-on-failure runner
# ---------------------------------------------------------------------------

proc execute*(
  p:                RunPlan;
  config:           Config = Config();
  graph:            var DepGraph;
  nimVersion:       string = "";
  ccVersion:        string = "";  ## nimcache-persistence: folded with nimVersion into
                                  ## the toolchain fingerprint (planner.toolchainFingerprint)
                                  ## that keys the persistent nimcache path — see spawnCompileStable.
                                  ## "" (default, same convention as nimVersion) disables the
                                  ## fingerprint suffix — used by tests / cold-start callers.
  onResult:         ResultCallback = noopResult;
  failFast:         bool = false;
  showProgress:     bool = true;
  progressIntervalMs: int = 30_000;
  installSignals:   bool = false;  ## rfc-0007 A2b: this call's OWN Supervisor owns
                                    ## SIGINT/SIGTERM installation for its duration
                                    ## (`initSupervisor(installSignals)`, §1) — the
                                    ## seam that used to be the CALLER's job (via
                                    ## crisol/signals.installSignalHandlers before
                                    ## calling execute). Library default stays OFF:
                                    ## a caller that never asks for interrupt
                                    ## handling gets none installed, same as before.
  cache:            CacheContext = cacheDisabled(resolveSandbox());  ## M4: cohesive cache bundle
  recordLedger:     bool = true;  ## RFC-0005 B3a: default true (existing
                                  ## behavior unchanged). false suppresses
                                  ## appendAttemptRow for every attempt this
                                  ## call makes — the --verify-cache pass sets
                                  ## this so its re-runs don't pollute
                                  ## --order/perf-check/--shard ledger history.
                                  ## The ledger shard is still opened/closed
                                  ## as normal (harmless — a fresh, empty
                                  ## per-process shard, per the RFC's
                                  ## `ledger.nim` shardSeq note); only the
                                  ## per-attempt row write is gated.
  explainMiss:      bool = false;  ## RFC-0005 B1c: resolved --explain-miss
                                  ## (CLI OR config, already merged by
                                  ## api.planImpl into cfg.explainMiss before
                                  ## this call). Threaded to lookupAtPlan's
                                  ## `explainDiag` param -- gates ONLY the
                                  ## diagnostic seam consult for a
                                  ## recompiling (non-edRunFresh) entrypoint;
                                  ## the plan-time explain stamping onto
                                  ## `explains[i]` below (and the live-result
                                  ## `keyDiff` stamping further down) stays
                                  ## unconditional, same as B1b's sidecar
                                  ## write -- there is simply nothing to
                                  ## stamp when the seam was never consulted.
  recordClosureFn:  RecordClosureProc = recordClosure;  ## R3a (RFC-0009
                                  ## A-final-ii-a): injectable recordClosure
                                  ## seam. Defaults to the real `recordClosure`
                                  ## -- ZERO production behavior change. Tests
                                  ## inject a synthetic failure to exercise
                                  ## issue #13.3 D5's binary-discard invariant
                                  ## without a genuinely-outside-every-root
                                  ## Entrypoint (production entrypoints are
                                  ## ALWAYS tag-0).
): ExecuteReport =
  ## Effectful.  Runs each planned entrypoint with a bounded-parallel poll-loop
  ## scheduler honouring p.jobs (A4).  At most p.jobs child processes alive at
  ## once; continue-on-failure: one failure never stops the pool.
  ##
  ## M1/S2b: Timeouts and output cap are derived from config internally:
  ##   compileTimeoutMs       = config.compileTimeoutSecs * 1000  (default 600 s)
  ##   per-slot runTimeoutMs  = effectiveRunTimeoutMs(ep, config) — resolves
  ##                            ep.runTimeoutSecs (group), then config.timeoutSecs
  ##                            (global), then 300_000 ms (built-in default).
  ##   maxOutputBytes         = config.maxOutputBytes              (default 10 MiB)
  ##
  ## For cdSkipFresh entrypoints: compile is skipped; the existing binary is
  ## run directly.  compileSkipped=true is set on the resulting EntrypointResult.
  ##
  ## After each successful compile (rfc-0005 A2c-i: right after compile
  ## finishes, before its run child is spawned — no longer after the run
  ## completes), records the closure and content hash in `graph` and saves
  ## the depgraph (single writer, main poll loop).
  ##
  ## failFast=true: once any completed entrypoint has a failure outcome, no NEW
  ## entrypoints are dispatched.  In-flight entrypoints drain to completion.
  ##
  ## rfc-0007 code-review r7: the return value is a single `ExecuteReport`
  ## (see its type doc above) — `.results` plus every run-level fact this
  ## call observed (`interrupted`, `notStarted`, `shutdownSignal`,
  ## `lateOrphansReaped`, `memThrottled`). The five `ptr ... Out` params this
  ## proc used to take are gone; a caller reads fields off the returned
  ## object instead of pre-declaring locals and passing `addr` of each.
  ##
  ## `.results` is returned in deterministic plan order (index == pepIdx) —
  ## EXCEPT on an interrupted OR failFast-early-exited run (rfc-0007 A1e-ii,
  ## §2; r33): entries whose next phase never started are OMITTED entirely
  ## (counted in `.notStarted` instead), so the returned seq is shorter than
  ## `p.entrypoints` and no longer index-aligned to it; relative order among
  ## the entries that ARE returned is preserved.

  # M1: derive timeouts from config, applying defaults for zero values.
  let compileTimeoutMs =
    if config.compileTimeoutSecs > 0: config.compileTimeoutSecs * 1000
    else: 600_000  # default 600 s
  # S2b: the global runTimeoutMs local is removed.  Each slot's run deadline is
  # resolved per-entrypoint via effectiveRunTimeoutMs(ep, config) at slot setup
  # time (spawnCompileStable / spawnRunDirect) and stored in slot.runTimeoutMs.
  let maxOutputBytes =
    if config.maxOutputBytes > 0: config.maxOutputBytes
    else: 10 * 1024 * 1024  # default 10 MiB

  let n     = p.entrypoints.len
  let nJobs = max(1, p.jobs)

  if n == 0:
    return ExecuteReport()  # nothing to run — every fact is legitimately its zero value

  # issue #8: the source index used to resolve @p/@n closure entries is a
  # pure function of the source tree (config.projectRoot + config.depRoots),
  # never of any single entrypoint/compile — build it at most ONCE per
  # execute() call, lazily on the first closure recording, and thread it
  # through every recordClosure call. A run that compiles nothing (every
  # entrypoint fresh or cached) never pays the walk.
  #
  # rfc-0005 A2c-i: the lazy-build check itself now lives inside
  # `finalizeSlot` (recordClosure moved there, right after compile
  # finishes) — these two locals are threaded through by `var` so the
  # "at most once per execute() call" invariant survives the move.
  var sourceIndex: SourceIndex
  var sourceIndexBuilt = false

  # nimcache-persistence (RFC-0006): computed ONCE per execute() call, not
  # per slot/compile — both are pure functions of the plan/toolchain, never
  # of a slot's runtime state.
  #   toolchainFp — folds nimVersion+ccVersion into the persistent nimcache
  #     path (planner.cachePath) so a toolchain upgrade lands on a fresh dir.
  #   dupSlugs    — the rare set of slugs scheduled ≥2× in THIS plan; those
  #     fall back to the old volatile pepIdx-suffixed dir in spawnCompileStable
  #     to avoid two concurrent slots racing on one nimcache write.
  let toolchainFp = toolchainFingerprint(nimVersion, ccVersion)
  let dupSlugs    = duplicateSlugs(p, config.trackedRoots)

  # code-review r24: the run-lifetime invariants above (config, cache,
  # recordClosureFn, the plan, the derived timeout/output-cap, the resolved
  # project root, toolchainFp/dupSlugs) built into ONE ExecCtx — see its
  # type doc. Every slot-lifecycle proc below takes this instead of its own
  # subset of the same six-to-eight params.
  #
  # r65: this is the SOLE derivation of the canonical project root —
  # `absolutePath` is cwd-dependent, so resolving it exactly once here (not
  # per-spawn) is the actual invariant `ExecCtx.projectRoot`'s doc promises.
  # Every other site that needs it reads `ctx.projectRoot` back; none may
  # re-derive their own `config.projectRoot.absolutePath.normalizedPath`.
  let ctx = ExecCtx(
    config:            config,
    cache:              cache,
    recordClosureFn:    recordClosureFn,
    plan:               p,
    maxOutputBytes:     maxOutputBytes,
    compileTimeoutMs:   compileTimeoutMs,
    projectRoot:        config.projectRoot.absolutePath.normalizedPath,  # canon-ok: the run's SINGLE canonical derivation (r65) -- every other site reads ctx.projectRoot
    toolchainFp:        toolchainFp,
    dupSlugs:           dupSlugs,
  )

  # Pre-allocate result slots so we can fill them by index (plan order).
  var results = newSeq[EntrypointResult](n)

  # B2: open the ledger shard for this invocation (if stateDir is set).
  # Guards on empty stateDir — some callers (e.g. runEntrypoint) leave it "".
  # Resolve to absolute path using projectRoot so the ledger dir is co-located
  # with the rest of the state (resultcache, lastrun.json, etc.) regardless of CWD.
  var led: Ledger
  let resolvedLedgerStateDir = stateDirOf(config)
  let ledgerActive = resolvedLedgerStateDir.len > 0
  if ledgerActive:
    led = openLedger(resolvedLedgerStateDir)

  # Slots array: nJobs concurrent slots; idle when state == ssIdle (rfc-0007
  # A2b — replaces the pepIdx==-1 sentinel).
  var slots = newSeq[Slot](nJobs)
  for s in slots.mitems:
    s.state = ssIdle

  # rfc-0007 A2b: ONE Supervisor for this call, owning the event loop and
  # (opt-in) SIGINT/SIGTERM installation for its duration (§1). Every
  # compile/run child spawned below, and every wait/stop/kill/reap, goes
  # through this one instance.
  var sv = initSupervisor(installSignals = installSignals)

  # S6b / M5b: build admission controller.
  # The mem-aware truth table (kill-switch, force-on, auto) is resolved inside
  # initAdmission, not here.  We pass the raw availableMemBytes proc as the
  # candidate probe; initAdmission calls it once to test probe availability and
  # applies cfg.memAware to decide whether to use it, suppress it, or force it on.
  let candidateProbe: proc(): Option[int64] = proc(): Option[int64] = availableMemBytes()
  var ac = initAdmission(config, p, probe = candidateProbe)

  # H1 fix: scan-ahead fill.  Instead of a single monotone cursor that stalls
  # on a cap-blocked head, each idle slot independently scans from the
  # low-water mark (lwm) for the first undispatched entrypoint whose admit
  # succeeds.  Blocked candidates are left pending and retried next pass.
  #
  # B1: `attempts[i]` replaces the old bool `dispatched[i]`.
  #   attempts[i] == 0  → not yet dispatched (first scan skips these)
  #   attempts[i] == k  → currently on attempt k (in-flight or waiting for result)
  #   finalized[i]      → true once the entrypoint is done (pass or exhausted retries)
  #
  # The lwm scan skips finalized entries; re-dispatch entries (waiting for a free
  # slot) are detected by attempts[i] > 0 AND NOT finalized[i].  The fill scan
  # still avoids re-dispatching in-flight entries because the slot's pepIdx == i
  # means some slot is already live for it.
  #
  # lwm is advanced past finalized entries so the inner scan never re-walks them.
  var attempts        = newSeq[int](n)    # B1: 0 = not yet dispatched
  var finalized       = newSeq[bool](n)   # B1: true once done (pass/exhausted)
  var lwm             = 0   # low-water mark: start of undispatched scan
  var done            = 0   # count of completed entrypoints

  # For the lwm/H1 scan: advance lwm only past FINALIZED entries.
  # (An entry with attempts>0 but not finalized may need re-dispatch.)
  template isFullyDone(i: int): bool = finalized[i]

  # -------------------------------------------------------------------------
  # A6: plan-time result-cache lookup (RFC-0004 F3).
  # For each runnable edRunFresh entrypoint, consult the cache.  On a HIT:
  #   - synthesize the EntrypointResult from the CachedResult,
  #   - fire its ResultCallback NOW (plan time, before any live result, for
  #     deterministic streaming order),
  #   - mark it dispatched + done so it BYPASSES the admission controller and
  #     occupies no liveCount slot (it spawns nothing).
  # On a MISS / not-eligible / policy-disabled, the per-index CacheDecision is
  # recorded so the live result can be stamped after it completes.
  #
  # M4: CacheContext.isActive() is the single authority for whether caching is on.
  # seams.keyOf != nil AND policy.enabled are guaranteed-consistent by the
  # CacheContext constructors; we do NOT re-derive the flag from those fields.
  let cacheActive = cache.isActive()
  var cacheDecisions = newSeq[CacheDecision](n)
  var inputHashes    = newSeq[string](n)  # A8: soundnessKey per index ("" if not consulted)
  var explains        = newSeq[seq[KeyDiff]](n)  # RFC-0005 B1c: plan-time miss explanation
                                                  # per index (empty when not consulted, a
                                                  # hit, or no prior sidecar record); stamped
                                                  # onto the live EntrypointResult below.
  var lookups         = newSeq[CacheVerdict](n)  # RFC-0005 A3b: PlanLookup.lookup per index
                                                  # (cvOk zero value if not consulted), next to
                                                  # inputHashes -- stamped onto the live
                                                  # EntrypointResult's cacheLookup wherever
                                                  # inputHashes[completedIdx] lands below.
  # RFC-0005 C3c (prefetch): resolve every canProbe tier's key-existence set
  # ONCE, over every edRunFresh + read-permitted entrypoint's candidate key,
  # BEFORE the per-entry consult loop below -- cache.prefetch (a no-op
  # unless the cache runtime installed `realPrefetch`, see cachedispatch.nim)
  # forwards straight onto `TieredCache.resolveProbes`. Gathering the keys
  # here (not inside `lookupAtPlan`) is the whole point: a probe needs the
  # FULL candidate set up front to be useful, and this loop is the only
  # place that knows it. `derive` is pure (no I/O), so recomputing it here
  # and again inside `lookupAtPlan`'s own consult a few lines down costs one
  # extra hash per eligible entrypoint, not a second lookup.
  if cacheActive:
    var candidateKeys: seq[SoundnessKey] = @[]
    for i in 0 ..< n:
      let pep = p.entrypoints[i]
      if pep.edecision == edRunFresh and resolveCacheable(cache.policy, pep.cacheable).readOk:
        candidateKeys.add derive(cache.seams, pep).key
    cache.prefetch(candidateKeys, proc(): bool = shutdownRequested().isSome)

  for i in 0 ..< n:
    if not cacheActive:
      # No cache: record the structural reason on every entry.  edRunFresh
      # entries are reported policy-disabled when policy was explicitly disabled;
      # otherwise not-eligible (cache not consulted at all).
      let pep = p.entrypoints[i]
      # L15: delegate to the authoritative (isActive=false, edecision) → CacheDecision
      # mapping in cachedispatch.inactiveDecision.  The full decision table lives
      # there with rationale; this call site is the single consumer.
      cacheDecisions[i] = inactiveDecision(pep.edecision)
      continue
    if shutdownRequested().isSome:
      # RFC-0005 B0(c)/C3c: abandon the remaining plan-time consults on a
      # pending interrupt rather than embarking on more (potentially
      # network-bound) cache lookups. Unconsulted entries simply keep their
      # zero-value cacheDecision/inputHash/explain/lookup (cdmNotEligible /
      # "" / empty / cvOk -- "not consulted", see CacheDecision's own doc
      # comment) and proceed to dispatch normally below, where the run's
      # own interrupt handling (the poll loop's weShutdown case) takes over.
      break
    let look = lookupAtPlan(p.entrypoints[i], cache.policy, cache.seams, explainMiss,
                            cache.sink, cache.spec, cache.outcomePolicy)
    cacheDecisions[i] = look.cacheDecision
    inputHashes[i]    = look.inputHash  # A8: stamped onto live miss results below
    explains[i]       = look.explain    # RFC-0005 B1c: stamped onto live miss results below
    lookups[i]        = look.lookup     # RFC-0005 A3b: stamped onto live miss results below
    if look.decision == edCached and look.synthesized.isSome:
      # Served from cache: synthesize, fire callback now, retire the slot.
      # edCached entries are NEVER retried — they are terminal at plan time.
      var synth = look.synthesized.get
      synth.cacheDecision = look.cacheDecision   # cdmHit
      # RFC-0005 A3b: the HIT stamp -- which tier served it + the (cvOk)
      # lookup verdict, straight from PlanLookup (see that type's doc
      # comment for why `tier`/`lookup` are populated the way they are).
      synth.cacheTier   = look.tier
      synth.cacheLookup = look.lookup
      # B3/B4: apply quarantine overlay post-lookup — quarantine is a reporting
      # concern, not part of the soundness/cache key.  Cached results are
      # always passes (only passing results are stored), so the B4 per-test
      # rule naturally no-ops here; the B3 path rule still applies.
      synth.quarantined = isQuarantined(p.entrypoints[i].ep, synth, config.quarantine, config.quarantineTp)
      results[i] = synth
      finalized[i] = true    # B1: mark finalized — edCached never retried
      inc done
      onResult(synth)
  # Advance lwm past any leading run of plan-time-served (cached) entries so the
  # dispatch scan never re-walks them.  (Only finalized entries advance lwm;
  # entries with attempts>0 but not finalized may need re-dispatch.)
  while lwm < n and isFullyDone(lwm):
    inc lwm
  var anyFailed = false # tracks whether a failure has been seen (for failFast)
  var passId: uint = 0  # epoch counter: incremented once per fill pass; threaded into ac.admit

  const pollIntervalMs = 25

  # Progress-line tracking: last time we emitted a progress line.
  var lastProgressAt = epochTime()

  # M4: Memory-throttle signal tracking.
  # throttledSince: Some(t) = when this continuous memory-throttled state began.
  # Set when: idle slots exist, live slots exist, and memory gate blocked a candidate.
  # Cleared when: a fill pass makes dispatch progress OR no longer idle+live+mem-blocked.
  var throttledSince: Option[MonoTime] = none(MonoTime)

  # rfc-0007 A1e-ii: CrisolInterrupted is retired — an interrupt is no longer
  # an exception, it is a HONEST PARTIAL RESULT (§2).  `wasInterrupted` is
  # reported to the caller via the returned ExecuteReport's `.interrupted`
  # field (code-review r7 — folded into the single construction point below).
  var wasInterrupted = false
  var shutdownSignum = 0  # rfc-0007 A2b: the real signum, for ExecuteReport.shutdownSignal

  # rfc-0007 B1 (§3): the run-level late-orphan count (ExecuteReport.lateOrphansReaped)
  # and the per-slot pending-escapee staging table. An adopted orphan
  # discovered via `sv.next`'s async waitid(P_ALL, WNOWAIT) sweep whose
  # `ownedBy` names a slot that is STILL LIVE (not yet reaped/emitted) is
  # staged here, keyed by the raw ChildId ordinal, and spliced into that
  # slot's own evidence.escapees at the point `finalizeSlot` reaps it (see
  # the `pendingEscapees` parameter threaded into `finalizeSlot` below) —
  # never retro-fitted into an ALREADY-emitted result. Everything else
  # (ownedBy none, or the owning slot already gone) is counted here instead.
  var lateOrphansReaped = 0
  var pendingEscapees = initTable[int32, seq[ptypes.ProcSnapshot]]()

  # rfc-0007 A2b: `shuttingDown` is the ONE flag that turns the SAME loop
  # below from normal dispatch into interrupt drain — no separate teardown
  # loop. Once true: no new work is dispatched (the fill pass is skipped
  # entirely), every live slot has already had its stop act recorded, and
  # the loop keeps calling `next` — draining weChildExited/weDeadline/
  # weShutdown exactly as it always did — until no slot is live.
  var shuttingDown = false

  template handleChildExited(childId: ChildId; blockTransition: bool = false) =
        ## rfc-0007 A2b: extracted so the weShutdown handler (below) can drain
        ## any child that ALREADY exited but that this executor simply hadn't
        ## gotten around to noticing yet BEFORE committing remaining live slots
        ## to interrupt teardown — see the drain loop in the weShutdown case.
        ## A TEMPLATE, not a proc: a nested proc capturing the enclosing
        ## proc's `var seq` locals (`results`, or `slots`, same issue hit
        ## earlier) trips Nim's memory-safety capture check at codegen; a
        ## template inlines at each call site instead, sidestepping capture
        ## entirely.
        ##
        ## rfc-0007 code-review r5(a): `blockTransition` — true ONLY for the
        ## weShutdown handler's own pre-`shuttingDown` drain loop below.
        ## `shuttingDown` is still false at that point (it isn't set until
        ## AFTER the drain completes), so `not shuttingDown` alone would
        ## compute `allowTransition = true` for a COMPILE child that raced
        ## to success in that exact window — spawning a brand new run child
        ## after the interrupt was already observed, then killing it and
        ## reporting it `oKilled` instead of honestly omitting it (§2).
        ## A run-phase exit drained here is a genuine completion (the
        ## entire point of the drain) and is unaffected — `allowTransition`
        ## is read only by `finalizeSlot`'s COMPILE-success arm.
        let idx              = slotIndexOf(slots, childId)
        let completedIdx     = slots[idx].pepIdx
        let compiledThisRun  = slots[idx].compiledThisRun
        let slotCacheDir     = slots[idx].cacheDir       # capture before slot cleared
        let slotBinCompiled  = slots[idx].binCompiled    # capture before slot cleared
        let slotBinDir       = slots[idx].slotBinDir     # per-slot bin dir (M15)
        let slotToken        = slots[idx].token          # S3: capture before slot cleared
        let slotAttempt      = slots[idx].attempt        # B0/B1: current attempt number
        let slotClosureRecorded = slots[idx].closureRecorded  # rfc-0005 A2c-i: capture
                                                          # before slot cleared — set at the
                                                          # compile→run transition, read by
                                                          # the post-run promotion/cache-
                                                          # store gate below.
        let slotClosureError    = slots[idx].closureError
        let slotPostCompileConsulted = slots[idx].postCompileConsulted  # rfc-0005
                                                          # A2c-ii: capture before slot
                                                          # cleared — set at the compile→run
                                                          # transition ONLY when the post-
                                                          # compile consult fell through to a
                                                          # real run; read by the post-run
                                                          # cache-store gate below.
        let slotPostCompileInputHash = slots[idx].postCompileInputHash
        let slotPostCompileLookup    = slots[idx].postCompileLookup
        let slotPostCompileExplain   = slots[idx].postCompileExplain

        # S6b/rfc-0007 A2b: sample finish-time RSS BEFORE `finalizeSlot`
        # reaps — reap is the only place a ChildId is consumed (§1), and
        # `groupRssBytes` on an already-reaped id is a Defect. A lingering
        # pgroup member (e.g. an orphaned grandchild) can still be observed
        # at this exact instant — same intent as the pre-A2b finish-time
        # sample; only actually used below once the slot is confirmed to
        # have gone idle (fkDone/fkOmitted), harmless to compute otherwise.
        let finishRss = sv.groupRssBytes(slots[idx].id)

        let fo = finalizeSlot(sv, slots, idx,
                              allowTransition = (not shuttingDown) and not blockTransition,
                              graph = graph,
                              sourceIndex = sourceIndex,
                              sourceIndexBuilt = sourceIndexBuilt,
                              pendingEscapees = pendingEscapees,
                              ctx = ctx)

        case fo.kind
        of fkTransitioned:
          discard  # slot still live under a NEW ChildId — nothing else this tick
        of fkOmitted:
          # rfc-0007 §2: interrupt-teardown race — a compile raced to success
          # with no stop act recorded (the Supervisor's atomic no-op rule,
          # §1). The slot went idle inside finalizeSlot; release admission.
          # `completedIdx` stays unfinalized, so the emission-set trim below
          # counts it in notStarted rather than fabricating a "run never
          # started" lie.
          ac.onSlotFinish(slotToken, finishRss)
        of fkCacheHit:
          # rfc-0005 A2c-ii: a genuine post-compile cache hit — no run child
          # was ever spawned, so this mirrors the plan-time edCached hit
          # block (execute()'s pre-dispatch loop) rather than fkDone's
          # retry/ledger/store-gate machinery: terminal immediately, no
          # ledger row (the ledger records executions), no store (a hit is
          # never re-stored). `shuttingDown` cannot be true here — the
          # consult only runs when `allowTransition` was true, i.e.
          # `not shuttingDown` at the time this compile's finalizeSlot call
          # began.
          ac.onSlotFinish(slotToken, finishRss)
          var res = fo.res
          res.quarantined = isQuarantined(p.entrypoints[completedIdx].ep, res,
                                          config.quarantine, config.quarantineTp)
          results[completedIdx] = res
          finalized[completedIdx] = true
          inc done
          onResult(res)
        of fkDone:
          ac.onSlotFinish(slotToken, finishRss)  # S6b: feed real RSS so estJobPeak adapts
          results[completedIdx] = fo.res

          if shuttingDown:
            # rfc-0007 §2: interrupt-killed finals bypass retry/ledger/cache/
            # promotion entirely — fired through onResult exactly like a
            # live completion. A slot torn down here never reaches the
            # promotion block below, so sweep what finalizeSlot's RUN-phase
            # branch leaves behind (a compile-phase kill already fully
            # cleaned itself via cleanupSlotOnTeardown). tmpDir is NOT
            # swept here — code-review r14: cleanupSlotTmp (called from
            # every finalizeSlot release path, including the RUN-phase one)
            # is now the single choke point that removes it, so it is
            # already gone by the time fkDone reaches this handler.
            if slotBinDir.len > 0:
              try: removeDir(slotBinDir) except: discard
            finalized[completedIdx] = true
            onResult(fo.res)
          else:
            # rfc-0007 §2: retry/flaky/quarantine decisions read the pure
            # derivation — there is no stored legacy field to read instead.
            let completedOutcome = outcome(results[completedIdx])
            let maxAttempts = p.entrypoints[completedIdx].retries + 1  # B1

            # B2: append one ledger row per live attempt — including intermediate
            # failed attempts that will be retried.  inputHash for intermediate
            # attempts uses the plan-time key (may be ""); the final attempt's
            # inputHash will be stamped later by the cache-store gate if caching
            # is active, but for observability we record the plan-time key here
            # (consistent: the build identity is the same across all attempts).
            if ledgerActive and recordLedger:
              appendAttemptRow(led, p.entrypoints[completedIdx].ep, slotAttempt,
                               results[completedIdx], inputHashes[completedIdx],
                               slots[idx].peakRssBytes, config.trackedRoots)

            # A6/A7: the store gate itself (`shouldStore`) is pure and cheap
            # — call it unconditionally so `decideExit` always has a real
            # `StoreVerdict` to reason about. When caching is inactive its
            # result is never actually consulted (`decideExit`'s
            # `cacheDecisionIfNotStored` short-circuits on `cacheActive`
            # before looking at it), so this changes no observable behavior.
            let verdict =
              if cacheActive:
                shouldStore(results[completedIdx], cache.spec, slotAttempt,
                           cache.policy, p.entrypoints[completedIdx].cacheable)
              else:
                StoreVerdict()

            # code-review r23: the retry/promotion/store-gate POLICY itself
            # now lives in `decideExit` (pure, unit-tested directly — see
            # tests/unit/test_rfc0007_r23_exit_decision.nim); everything
            # below is the ACTION side applying its decision.
            let decision = decideExit(
              completedOutcome      = completedOutcome,
              slotAttempt           = slotAttempt,
              maxAttempts           = maxAttempts,
              failFast              = failFast,
              compiledThisRun       = compiledThisRun,
              hasCacheDir           = slotCacheDir.len > 0,
              slotClosureRecorded   = slotClosureRecorded,
              cacheActive           = cacheActive,
              verdict               = verdict,
              planTimeCacheDecision = cacheDecisions[completedIdx],
            )

            if decision.retry:
              # Re-dispatch: the slot is now idle; the fill scan will pick it up.
              # Do NOT inc done; do NOT call onResult (not final yet).
              discard  # slot cleared above; fill scan will re-dispatch

            else:
              # Finalize: pass or exhausted retries.
              inc done
              finalized[completedIdx] = true

              # B1: stamp attempts onto the final result; flaky is derived
              # from attempts (A1e-i: `flaky(r, policy)`, no field to stamp).
              results[completedIdx].attempts = slotAttempt
              # B3/B4: apply quarantine overlay — pure reporting, not cache or execution logic.
              # At the live-finalize site, result[completedIdx] carries the final records
              # (protocol or empty), so the B4 per-test rule has full information.
              results[completedIdx].quarantined =
                isQuarantined(p.entrypoints[completedIdx].ep,
                              results[completedIdx],
                              config.quarantine, config.quarantineTp)

              # Track whether any failure has been recorded (for failFast).
              if decision.recordAsFailure:
                anyFailed = true

              # After run completes for a compiled-this-run slot: copy the binary
              # to the stable slug-keyed path, then consult the closure-recording
              # outcome captured back at the compile→run transition (rfc-0005
              # A2c-i: `finalizeSlot` calls `recordClosure` itself, right after
              # compile finishes and before the run child is spawned — this site
              # only reads `slotClosureRecorded`/`slotClosureError` back).
              if decision.promoteBinary:
                let ep = p.entrypoints[completedIdx].ep
                # RFC-0009 B4a: `stableBinPath` (not `binPath / binName`)
                # so this warning/discard path names the SAME file
                # `promoteCompiledBinary` just wrote — see its doc comment.
                let stableBin = stableBinPath(ep, config)
                # Invariant on exit from this block: either (the depgraph
                # entry on disk matches the stable binary at `stableBin`) or
                # (no stable binary exists at `stableBin`) — NEVER a binary
                # whose provenance the on-disk depgraph does not describe
                # (issue #13.3). A promotion or persist failure below always
                # resolves toward "no stable binary" rather than leaving a
                # binary paired with a stale or absent depgraph entry.
                #
                # Copy per-slot binary to the stable slug-keyed location.
                # The stable binary is what decideCompile checks on future
                # runs. `promoteCompiledBinary` (shared with finalizeSlot's
                # post-compile cache-hit branch, RFC-0005 A2c-ii) already
                # no-ops when `slotBinCompiled` is empty or already equals
                # `stableBin`, and already warns + discards any partial
                # `stableBin` on failure — this site's return value is
                # intentionally unused, matching the pre-extraction
                # behavior exactly (a promotion failure here does not, by
                # itself, block a store; only `discardOnUnrecordedClosure`
                # below does).
                discard promoteCompiledBinary(ep, config, slotBinCompiled)

                if decision.discardOnUnrecordedClosure:
                  # The depgraph entry for this compile is either invalidated
                  # or (on a persist failure) not reliably reflected on disk
                  # at all — either way, the stable binary just promoted
                  # above must not survive to be served by a future run
                  # whose decideCompile can no longer be trusted to agree
                  # with it (issue #13.3).
                  try: removeFile(stableBin) except CatchableError: discard
                  stderr.write("crisol: warning: " & string(ep.tp.display()) & ": could not record its " &
                               "source closure (" & slotClosureError & "); dependency record " &
                               "invalidated and its binary was discarded — it will be " &
                               "recompiled and force-selected next run\n")
                  try: stderr.flushFile() except CatchableError: discard

              # Clean up the per-slot bin dir after stable copy (M15).
              # finalizeSlot already cleaned this on compile-fail; only clean here on success.
              if compiledThisRun and slotBinDir.len > 0:
                try: removeDir(slotBinDir) except: discard

              # rfc-0005 A2c-ii: a compiling (edNeverBuilt/edStale) entrypoint's
              # post-compile consult (finalizeSlot, above) ran a REAL lookup
              # this attempt — overwrite the plan-time ""/cvOk/[] placeholders
              # with what it actually found, so the live result below reports
              # the honest key/lookup/explain instead of "never consulted"
              # (an edRunFresh entrypoint's plan-time lookupAtPlan values are
              # already real and untouched here — this only fires for entries
              # that just compiled).
              if slotPostCompileConsulted:
                inputHashes[completedIdx] = slotPostCompileInputHash
                lookups[completedIdx]     = slotPostCompileLookup
                explains[completedIdx]    = slotPostCompileExplain

              # A6/A7: apply the store-gate decision. ALWAYS stamp the live
              # result's CacheDecision for reporting (A8), whichever arm fires.
              if decision.stampCacheKeyInfo:
                # RFC-0005 B1c/A3b: stamp the plan-time miss explanation and
                # lookup verdict regardless of whether THIS run's result ends
                # up stored — both belong to the fact that this index was
                # CONSULTED, not to the store outcome below. cacheTier stays
                # "" (its zero value) -- a live-run result was never served
                # from a tier, whatever the reason.
                results[completedIdx].keyDiff     = explains[completedIdx]
                results[completedIdx].cacheLookup = lookups[completedIdx]
                if decision.attemptStore:
                  # Re-derive the key from the NOW-updated graph (closureHash
                  # fresh) so a later run's lookup-key matches this store-key.
                  let d   = derive(cache.seams, p.entrypoints[completedIdx])
                  let cr  = toCachedResult(results[completedIdx], epochTime().int64)
                  let stored = cache.seams.store(p.entrypoints[completedIdx], d, cr)
                  # A8: the store-key is the authoritative inputHash for this live run
                  # (the plan-time lookup key was derived before this compile updated
                  # the graph; for an edStale/edNeverBuilt entry there was no plan-time
                  # key at all).  Stamp the freshly-derived key string.
                  results[completedIdx].inputHash = $d.key
                  # M8: cdmStored = fresh run on a miss where the result WAS written.
                  # cdmKeyMiss = fresh run on a miss where the result was NOT stored.
                  # A run/v1 consumer can tell from cacheDecision alone whether a store
                  # happened, without inferring from inputHash presence.
                  results[completedIdx].cacheDecision =
                    if stored: cdmStored else: cdmKeyMiss
                else:
                  # Stamp the plan-time key (set for an edRunFresh miss; "" otherwise)
                  # so a consulted-but-not-stored result still reports its inputHash.
                  results[completedIdx].inputHash = inputHashes[completedIdx]
                  results[completedIdx].cacheDecision = decision.cacheDecisionIfNotStored
              else:
                # Caching inactive: stamp the structural reason recorded at plan time.
                results[completedIdx].cacheDecision = decision.cacheDecisionIfNotStored

              # Fire onResult ONCE with the final result (B1 contract).
              onResult(results[completedIdx])


  # ---------------------------------------------------------------------------
  # M12: wrap entire dispatch loop in try/finally so any exception (e.g. from
  # an onResult callback) still stops + drains + cleans all live slots.
  # ---------------------------------------------------------------------------
  try:
    while (if shuttingDown: anyLiveSlot(slots) else: done < n):
      # -----------------------------------------------------------------------
      # Fill idle slots from the queue.
      # Stop pulling new work when failFast and any failure has been recorded.
      # The availability snapshot is refreshed lazily inside ac.admit on the
      # first call of each fill pass (epoch tracked by passId).
      # -----------------------------------------------------------------------
      # M4: capture throttle counter and live/idle counts before fill pass so
      # we can detect whether memory was the specific blocker after the pass.
      let throttleCountBefore = ac.memThrottledSlots
      var idleCountBefore = 0
      var liveCountBefore = 0
      for s in slots:
        if s.state == ssIdle: inc idleCountBefore
        else:              inc liveCountBefore
      var dispatchedThisPass = false

      inc passId  # new fill pass: admit will refresh the snapshot on its first call

      # L5: `isInFlight` hoisted above the per-slot loop so it is defined ONCE
      # per fill pass rather than re-allocating a closure env on each of the
      # nJobs iterations.  All captured variables (slots) remain in scope here.
      proc isInFlight(j: int): bool {.closure.} =
        for s in slots:
          if s.state == ssLive and s.pepIdx == j: return true
        false

      # code-review r66: the ONE finalize path for a fill-pass spawn failure
      # (fork/file-open failed before any process ever existed — neither
      # `spawnRunDirect` nor `spawnCompileStable` got a child spawned).
      # Previously each of the two call sites below hand-rolled its own
      # finalization — unconditional `anyFailed = true`, no `decideExit`,
      # no `isQuarantined` overlay — while the SAME event class reaching
      # fkDone (this file's `handleChildExited` template, the `fkDone`
      # branch) got the quarantine downgrade. Same event class, two
      # policies. Routed through `decideExit` here for real policy parity
      # (not a re-implementation of it): a spawn failure is never
      # retried/promoted/stored — `oSpawnError` is excluded from retry by
      # decideExit's B1 rule, and `compiledThisRun`/`hasCacheDir` are both
      # false here — so only `recordAsFailure` is read back; the
      # promote/store fields are computed but deliberately unused (there is
      # nothing to promote or store for a process that never spawned).
      # A template, not a proc: mutates `results`/`finalized`/`done`/
      # `anyFailed`, the enclosing proc's own `var seq`/`var` locals — see
      # `handleChildExited`'s doc comment above for why that rules out a
      # nested proc/closure here.
      template finalizeSpawnFailure(pepIdx: int; attemptNum: int; res: EntrypointResult) =
        var spawnFailRes = res
        spawnFailRes.quarantined = isQuarantined(p.entrypoints[pepIdx].ep, spawnFailRes,
                                                 config.quarantine, config.quarantineTp)
        let spawnFailDecision = decideExit(
          completedOutcome      = outcome(spawnFailRes),
          slotAttempt           = attemptNum,
          maxAttempts           = p.entrypoints[pepIdx].retries + 1,
          failFast              = failFast,
          compiledThisRun       = false,
          hasCacheDir           = false,
          slotClosureRecorded   = false,
          cacheActive           = cacheActive,
          verdict               = StoreVerdict(),
          planTimeCacheDecision = cacheDecisions[pepIdx],
        )
        results[pepIdx] = spawnFailRes
        onResult(spawnFailRes)
        finalized[pepIdx] = true
        inc done
        if spawnFailDecision.recordAsFailure:
          anyFailed = true

      for i in 0 ..< nJobs:
        if shuttingDown:            continue  # rfc-0007 A2b: no new work once torn down
        if slots[i].state == ssLive: continue  # slot busy
        if lwm >= n:               continue  # all entries dispatched
        if failFast and anyFailed: continue  # fail-fast: drain only; no new work

        # H1 fix + B1: scan from lwm for the first candidate that:
        #   (a) has not been finalized, AND
        #   (b) is not currently in-flight (some slot already has it), AND
        #   (c) either hasn't been dispatched yet (attempts==0) OR needs re-dispatch
        #       (attempts>0, not finalized, not in any slot = waiting for a free slot), AND
        #   (d) admit() accepts it.
        #
        # "In-flight" detection: iterate over slots checking pepIdx == j.
        # This is O(nJobs × n) in the worst case, but nJobs is typically small
        # (cpu-2) so this is O(n) in practice.

        var pepIdx = -1
        for j in lwm ..< n:
          if finalized[j]: continue          # done; skip
          if isInFlight(j): continue         # already live in a slot; skip
          # Not finalized and not in-flight: eligible for dispatch (first or re-dispatch).
          let candidate = p.entrypoints[j]
          let tok = ac.admit(passId, candidate.ep.group, candidate.edecision)
          if tok.isNone:
            continue  # blocked this pass; try next candidate
          # Found an admissible candidate.
          pepIdx = j
          if attempts[j] == 0:
            # First dispatch: set attempt 1.
            attempts[j] = 1
          else:
            # Re-dispatch (retry): increment attempt counter.
            inc attempts[j]
          # Advance lwm past any leading run of finalized entries.
          # (lwm never skips over entries that may need re-dispatch.)
          while lwm < n and isFullyDone(lwm):
            inc lwm
          dispatchedThisPass = true  # M4: progress was made this pass

          let pep = candidate
          let attemptNum = attempts[j]  # B0: current attempt (1-indexed); claimSlot
                                         # (inside spawnRunDirect/spawnCompileStable) is
                                         # what actually stores this on the slot the
                                         # moment the child spawns — see claimSlot's doc.

          if pep.edecision == edRunFresh:
            # Skip compile: spawn run directly with the existing stable binary.
            # S2b: runTimeoutMs is resolved inside spawnRunDirect from effectiveRunTimeoutMs.
            let ok = spawnRunDirect(sv, slots[i], pepIdx, pep, attemptNum, ctx)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              var res = EntrypointResult(ep: pep.ep,
                                         output: "fork or file-open failed for skip-fresh run",
                                         durationMs: 0,
                                         compileSkipped: true,
                                         attempts: attemptNum)
              # rfc-0007 §2: no process was ever spawned for either phase.
              res.compile = ptypes.Phase(kind: ptypes.pkSkipped)
              res.run     = ptypes.Phase(kind: ptypes.pkSpawnFailed,
                                spawnError: "fork or file-open failed for skip-fresh run")
              finalizeSpawnFailure(pepIdx, attemptNum, res)  # r66: shared quarantine+recordAsFailure policy
            else:
              slots[i].token = tok.get  # S3: store token for onSlotFinish
          else:
            # Normal compile + run using stable slug-keyed paths.
            let ok = spawnCompileStable(sv, slots[i], pepIdx, attemptNum, pep, graph, ctx)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              # Fork/resource failure: record oSpawnError immediately.
              var res = EntrypointResult(ep: pep.ep,
                                         output: "fork or file-open failed before compile",
                                         durationMs: 0,
                                         attempts: attemptNum)
              # rfc-0007 §2: no process was ever spawned for either phase.
              res.compile = ptypes.Phase(kind: ptypes.pkSpawnFailed,
                                spawnError: "fork or file-open failed before compile")
              res.run     = ptypes.Phase(kind: ptypes.pkSkipped)
              finalizeSpawnFailure(pepIdx, attemptNum, res)  # r66: shared quarantine+recordAsFailure policy
              # Slot remains idle (state == ssIdle); loop continues.
            else:
              slots[i].token = tok.get  # S3: store token for onSlotFinish
          break  # this slot has been filled; move to next slot

      # M4: Update memory-throttle tracking state after the fill pass.
      # Throttled state: idle slots exist AND live slots exist AND memory gate
      # specifically blocked a candidate this pass (counter incremented).
      # Progress clears throttled state; so does becoming fully idle or fully busy.
      let memBlockedThisPass = ac.memThrottledSlots > throttleCountBefore
      let isMemThrottled =
        not dispatchedThisPass and
        idleCountBefore > 0 and
        liveCountBefore > 0 and
        memBlockedThisPass
      if isMemThrottled:
        if throttledSince.isNone:
          throttledSince = some(getMonoTime())  # begin timing this throttle episode
        # else: keep the existing start time (continuous throttle)
      else:
        throttledSince = none(MonoTime)  # progress made or not memory-blocked; clear

      # -----------------------------------------------------------------------
      # rfc-0007 A2b: THE ONE WAIT PRIMITIVE. `next` blocks until a child
      # exits, a deadline (a slot's own timeout, an armed grace window, or
      # the ~25ms sample tick) passes, or a shutdown signal arrives — never
      # a fixed sleep plus a per-slot WNOHANG poll. `armExpiredTimeouts`
      # authors the ONLY krTimeout stop acts (main-loop only — never while
      # already shuttingDown, since every live slot was already stopped the
      # moment shutdown began); `escalateExpired` (below, on weDeadline)
      # handles escalation for BOTH timeout- and interrupt-armed grace
      # windows identically — the "three paths become one" acceptance.
      # -----------------------------------------------------------------------
      let preNow = getMonoTime()
      if not shuttingDown:
        armExpiredTimeouts(sv, slots, preNow)
      let deadline = nextDeadline(slots, preNow, pollIntervalMs)
      let ev = sv.next(deadline)
      let now = getMonoTime()  # fresh — `next` may have blocked

      case ev.kind
      of weChildExited:
        handleChildExited(ev.id)
      of weDeadline:
        # rfc-0007 A2b: escalate any slot whose grace window has elapsed —
        # shared by BOTH the timeout path (armed above by
        # armExpiredTimeouts) and the interrupt path (armed by the
        # weShutdown handler below): "three paths become one".
        escalateExpired(sv, slots, now)

        if not shuttingDown:
          # C5: RSS sample tick for every live, running slot — the SAME
          # ~25ms cadence as before (RFC-0002 §Contract impacts: quantity
          # and cadence unchanged; only the primitive changed, `sv.
          # groupRssBytes(id)` instead of memprobe.procGroupRssBytes(pid) —
          # the executor never sees a raw Pid any more, §1). Compile-phase
          # slots are excluded — the Nim compiler's VmRSS is not meaningful
          # as test-binary telemetry.
          for i in 0 ..< slots.len:
            if slots[i].state == ssLive and slots[i].phase == spRunning:
              let rssNow = sv.groupRssBytes(slots[i].id)
              if rssNow.isSome:
                slots[i].peakRssBytes = max(slots[i].peakRssBytes, rssNow.get)

          # -------------------------------------------------------------
          # Progress line: emit to stderr ~every progressIntervalMs when
          # showProgress. Lists in-flight entrypoints and how long each has
          # been running.
          # -------------------------------------------------------------
          if showProgress and anyLiveSlot(slots):
            let nowProgress = epochTime()
            let msSinceProgress = int64((nowProgress - lastProgressAt) * 1000)
            if msSinceProgress >= int64(progressIntervalMs):
              var inFlight: seq[(string, int64)]
              for s in slots:
                if s.state == ssLive:
                  let elapsed = int64((nowProgress - s.t0) * 1000)
                  inFlight.add (string(p.entrypoints[s.pepIdx].ep.tp.display()), elapsed)
              # M4: compute whether the mem-throttle signal should appear.
              let showThrottle = memThrottleActive(throttledSince, getMonoTime(),
                                                   MemThrottleSignalMs)
              let line = formatProgressLine(inFlight, memThrottled = showThrottle)
              if line.len > 0:
                stderr.write(line & "\n")
                try: stderr.flushFile() except: discard
              lastProgressAt = nowProgress

      of weShutdown:
        # rfc-0007 A2b/§1: EDGE-triggered, once per delivered signal. The
        # FIRST interrupt requests a cooperative stop for every live slot
        # (idempotent — a slot already mid-timeout-grace keeps its original
        # krTimeout, §1 "first act wins") and switches the loop above into
        # drain mode. A SECOND interrupt observed while still draining means
        # skip-grace-forceKill-now for every slot still live.
        if not shuttingDown:
          # `next`'s internal priority checks pendingShutdown BEFORE
          # sweeping for a fresh child exit (§1 only promises the drain-
          # before-weDeadline ordering, not before weShutdown) — a child
          # that already exited moments before the signal arrived, but that
          # this executor simply had not yet gotten around to noticing,
          # could otherwise be misattributed as killed by scheduling luck
          # rather than the true kernel-level race §2 accepts. Give the
          # Supervisor a bounded number of immediate (zero-wait) chances —
          # at most one per live slot — to report anything ALREADY ready
          # before any slot is committed to interrupt teardown; each
          # drained exit is processed exactly like a normal completion
          # (full retry/ledger/cache/promotion via handleChildExited),
          # because that is honestly what it is — EXCEPT a compile-phase
          # SUCCESS, which must not transition into a brand new run child
          # this late (r5(a) below): `blockTransition = true` routes it
          # through `fkOmitted` instead (`shuttingDown` is still false
          # here, so the plain `not shuttingDown` finalizeSlot normally
          # reads would wrongly compute `allowTransition = true`).
          #
          # rfc-0007 code-review r5(b): `evReady.kind == weShutdown` here
          # is a SECOND genuine interrupt observed while still draining the
          # first — distinct from weDeadline ("nothing more ready"), which
          # the old code conflated via a single `else: break`. Record it so
          # the post-drain stop act below skips the grace window entirely,
          # matching the "second Ctrl-C" contract (process/types.nim's
          # WaitEventKind doc) instead of silently downgrading to the
          # first-interrupt graced path.
          var drainBudget = slots.len
          var secondShutdownDuringDrain = false
          while drainBudget > 0:
            dec drainBudget
            let evReady = sv.next(getMonoTime())
            case evReady.kind
            of weChildExited:
              handleChildExited(evReady.id, blockTransition = true)
            of weShutdown:
              secondShutdownDuringDrain = true
              break
            else:
              break  # weDeadline: nothing more immediately ready — proceed.

          shuttingDown = true
          wasInterrupted = true
          shutdownSignum = ev.signal.signum
          if secondShutdownDuringDrain:
            # Skip-grace: the second interrupt already arrived before the
            # first one even finished being handled — every live slot goes
            # straight to forceKill, the same treatment a second top-level
            # weShutdown (the `else` branch below) gets once shuttingDown
            # is already true.
            #
            # code-review r58: unlike the top-level `else` branch below
            # (whose live slots already carry a `krInterrupt` stop act from
            # the FIRST weShutdown, §1 first-act-wins), a slot reaching
            # THIS branch has never had `requestStop` called on it — this
            # is the very first stop act any of these slots see. Both
            # backends' "forceKill with no prior stop act recorded"
            # fallback (posixcore.nim's `forceKillCore`, windows.nim's
            # `forceKill`) then defaults `stop.reason` to `krTimeout` —
            # correct for that proc's OWN documented bare-force-kill
            # contract, but wrong here: this kill is authored by a real
            # interrupt, not a timeout. Record the true authorship FIRST
            # via a non-blocking `requestStop` (first-act-wins means it
            # only sets `stop = (krInterrupt, escalated: false)` and, on
            # POSIX, additionally sends SIGTERM — harmless, immediately
            # superseded by the SIGKILL/TerminateJobObject below) so
            # `forceKill`'s OWN "prior stop present" branch preserves
            # `krInterrupt` and only flips `escalated` to true — no new
            # grace window opens (`forceKilled = true` still marks this
            # slot as force-killed, same as before).
            for i in 0 ..< slots.len:
              if slots[i].state == ssLive:
                sv.requestStop(slots[i].id, ptypes.krInterrupt)
                sv.forceKill(slots[i].id)
                slots[i].forceKilled = true
          else:
            for i in 0 ..< slots.len:
              if slots[i].state == ssLive:
                sv.requestStop(slots[i].id, ptypes.krInterrupt)
                if slots[i].stopDeadline.isNone:
                  slots[i].stopDeadline = some(getMonoTime() + initDuration(milliseconds = GracePeriodMs))
        else:
          for i in 0 ..< slots.len:
            if slots[i].state == ssLive:
              sv.forceKill(slots[i].id)
              slots[i].forceKilled = true

      of weOrphanReaped:
        # rfc-0007 B1 (§3): an adopted orphan the async waitid(P_ALL,
        # WNOWAIT) sweep discovered+reaped beside the registered wait set.
        # `ownedBy` was attributed BEFORE the reap (pgid match against a
        # still-live registered slot's domain pgid, §3) — route to that
        # slot's PENDING escapees if it is genuinely still live (unemitted);
        # otherwise (ownedBy none — e.g. a setsid escape — or the owning
        # slot already reaped/emitted) count + log at RUN level. Never
        # retro-fitted into an already-emitted EntrypointResult.
        var routed = false
        if ev.ownedBy.isSome:
          let ownerIdx = slotIndexOf(slots, ev.ownedBy.get)
          if ownerIdx >= 0:
            let key = int32(ev.ownedBy.get)
            pendingEscapees.mgetOrPut(key, @[]).add ev.orphan
            routed = true
        if not routed:
          inc lateOrphansReaped
          stderr.write("crisol: warning: adopted orphan pid " & $ev.orphan.pid &
                       " (" & ev.orphan.command &
                       ") reaped after its owning slot's result was already " &
                       "emitted (or unattributable) — counted, not retro-fitted\n")

      # -----------------------------------------------------------------------
      # failFast early-exit: if no slots are live and we would not dispatch any
      # more work, break now — remaining entrypoints were never started.
      #
      # rfc-0007 code-review r33/r7: this used to `return` directly from here
      # (after hand-filtering to `finalized[]` entries itself, H1) — which
      # skipped the epilogue below the while/finally entirely, silently
      # dropping `notStarted`/`shutdownSignal`/`lateOrphansReaped`/
      # `interrupted` from the caller's ExecuteReport on every failFast run.
      # A plain `break` instead falls through to that SAME epilogue (below
      # the `finally`), which already does exactly this "emit only
      # `finalized[]` entries, count the rest as `notStarted`" trim (§2's
      # emission-set rule covers a failFast early exit exactly as well as an
      # interrupt — both are "some entries' next phase never started") — so
      # the hand-rolled filter here is now redundant and deleted, and every
      # fact the epilogue populates is populated on this path too.
      # -----------------------------------------------------------------------
      if not shuttingDown and failFast and anyFailed and not anyLiveSlot(slots):
        break

  finally:
    # M12/M6/rfc-0007 A2b: handles the exception path (e.g. an onResult
    # callback raised) AND the normal/early-return path (a no-op when every
    # slot is already idle — always true on a normal or interrupted
    # completion: the interrupt path above already drained to zero live
    # slots inside the SAME loop, via the SAME requestStop/escalateExpired/
    # next machinery, before the loop condition let it exit). `teardownDiscard`
    # is the "exception teardown records NOTHING" half of the shared
    # machinery (§2) — never attributes, never fires onResult.
    # B2: close the ledger shard on all exit paths (normal, early-return, exception).
    #
    # rfc-0007 code-review r7: this used to ALSO write `memThrottledOut`
    # here (S6b: "always write memThrottledSlots ... including the
    # exception path") — the one fact of the five that ever reached a
    # caller on an exception unwind, because a `ptr` write survives past
    # the pointee's own stack frame while a return value cannot. Now that
    # every fact travels home as ONE returned `ExecuteReport`, that
    # exception-path delivery is gone for ALL five facts uniformly (an
    # exception unwinding out of `execute()` never produces a return value,
    # same as it never did for `interrupted`/`notStarted`/`shutdownSignal`/
    # `lateOrphansReaped` even under the old ptr design — only
    # `memThrottledOut` was special-cased). No caller (production or test)
    # ever read `memThrottled` after catching an exception from `execute()`
    # — grep confirms zero such use sites — so this is a real but unused
    # capability being retired, not a behavior change any caller depends on.
    # `ac` is declared above the try/while (in this proc's own scope, not
    # the try block's), so `ac.memThrottledSlots` is still readable below,
    # on the normal-return path, without needing the finally-time capture.
    teardownDiscard(sv, slots)
    if ledgerActive:
      closeLedger(led)

  # rfc-0007 A1e-ii: trim `results` to the §2 emission set — entries whose
  # last-started phase is pkRan/pkCached/pkSpawnFailed, i.e. `finalized`.
  # On a normal (non-interrupted, non-failFast-early-exited) completion
  # `done == n` is the while loop's only exit condition, and `done` only
  # ever advances alongside `finalized[i] = true`, so every index is
  # finalized here and this is a transparent reshuffle. On an interrupted
  # run, or a failFast run that broke out early (r33 — see the `break`
  # above), entries never claimed by a slot (queued, or the RFC's
  # "compile-done-run-unstarted" corner) stay unfinalized and are OMITTED
  # here rather than emitted as a fabricated "run never started" lie —
  # counted in `notStarted` instead.
  var notStarted = 0
  var emitted: seq[EntrypointResult]
  for i in 0 ..< n:
    if finalized[i]: emitted.add results[i]
    else: inc notStarted

  # rfc-0007 code-review r7: the SINGLE construction point for this call's
  # `ExecuteReport` — every normal-completion exit from the while loop above
  # (full drain, interrupt-drain, and the failFast early-exit `break`) falls
  # through to exactly here, so every fact below is populated on every one
  # of those paths; there is no other `return` in this proc past the n==0
  # guard that could forget one (r33's bug — a second, earlier construction
  # site that only some paths reached — cannot recur because there is only
  # this one site left).
  result = ExecuteReport(
    results:           emitted,
    memThrottled:      ac.memThrottledSlots,
    interrupted:       wasInterrupted,
    notStarted:        notStarted,
    shutdownSignal:    shutdownSignum,
    lateOrphansReaped: lateOrphansReaped,
  )

# ---------------------------------------------------------------------------
# runEntrypoint — compile + run ONE entrypoint (M6: thin wrapper)
# ---------------------------------------------------------------------------

proc runEntrypoint*(
  ep:               Entrypoint;
  compileTimeoutMs: int = 30_000;
  runTimeoutMs:     int = 30_000;
  maxOutputBytes:   int = 65_536;
): EntrypointResult =
  ## Compile and run one .nim source file under supervision.
  ## Returns a canonical EntrypointResult.
  ## M6: thin wrapper around execute() — no duplicate compile+run+classify path.
  ## Uses a temporary Config with the given timeouts; does not record freshness.
  var cfg = Config(
    compileTimeoutSecs: compileTimeoutMs div 1000,
    timeoutSecs:        runTimeoutMs div 1000,
    maxOutputBytes:     maxOutputBytes,
    # Use current dir as projectRoot so a tag-0 ep.tp resolves via toNative.
    # trackedRoots must be populated too -- toNative resolves through it,
    # never through projectRoot directly (RFC-0009 A-final-ii).
    projectRoot:        getCurrentDir(),
    trackedRoots:       initTrackedRoots(getCurrentDir(), newSeq[tuple[name, native: string]](), ""),
  )
  # Ensure non-zero fields so M1 derivation uses them (not defaults).
  if cfg.compileTimeoutSecs == 0: cfg.compileTimeoutSecs = 30
  if cfg.timeoutSecs == 0:        cfg.timeoutSecs = 30
  if cfg.maxOutputBytes == 0:     cfg.maxOutputBytes = 65_536
  let p = plan(cfg, @[ep], emptyDepGraph())
  var g = emptyDepGraph()
  let results = execute(p, config = cfg, graph = g, onResult = noopResult,
                        failFast = false, showProgress = false,
                        progressIntervalMs = 30_000,
                        cache = cacheDisabled(resolveSandbox())).results
  if results.len > 0:
    result = results[0]
  else:
    # rfc-0007 §2: compile/run both stay pkSkipped (the zero-value default)
    # — outcome(r) derives oSpawnError from that, same as before.
    result = EntrypointResult(ep: ep,
                              output: "execute returned no results")

# ---------------------------------------------------------------------------
# summarize — pure aggregate counts
# ---------------------------------------------------------------------------

proc summarize*(results: seq[EntrypointResult];
                policy: ptypes.OutcomePolicy = ptypes.DefaultPolicy): Summary =
  ## Pure: fold a result sequence into aggregate counts.
  ##
  ## rfc-0007 A6b: `policy` is the ONE place summarize()'s verdict can diverge
  ## from the observation — a REPORTING trust boundary (RFC-0007 §2), threaded
  ## in by the caller (api.runTests) from the resolved --strict-hygiene /
  ## `strict-hygiene` config value. Defaults to DefaultPolicy (unstrict) so
  ## every existing call site (tests, library callers not opting in) is
  ## byte-for-byte unchanged.
  ##
  ## B3: a quarantined FAILURE is excluded from all exit-contributing buckets
  ## (failed/compileFailed/spawnErrors/counts[oKilled]/counts[oCrashed]) and
  ## counted in Summary.quarantined instead.  A quarantined PASS counts
  ## normally in `passed` — quarantine only suppresses the failure; it's
  ## harmless on pass.
  result.total = results.len
  for r in results:
    let o = outcome(r, policy)
    if r.quarantined and o.isFailure:
      # B3: quarantined failure — report it but exclude from exit-1 buckets.
      inc result.quarantined
    else:
      case o
      of oPassed:        inc result.passed
      of oFailed:        inc result.failed
      of oCompileFailed: inc result.compileFailed
      of oSpawnError:    inc result.spawnErrors
      of oKilled, oCrashed:
        discard  ## no scalar counterpart — `counts` (below) is the ONLY
                 ## accounting for the killed/crashed buckets (rfc-0007 §2).
      inc result.counts[o]
    if flaky(r, policy): inc result.flaky  # B1: count flaky-passes
  result.noTestsRan = result.passed == 0 and result.total > 0
