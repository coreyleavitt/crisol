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
##   execute*(p, config, graph, nimVersion, onResult, ...): seq[EntrypointResult]
##     Effectful.  Runs entrypoints with a bounded-parallel poll-loop scheduler
##     honouring plan.jobs (A4).  Continue-on-failure: one failure never stops
##     the pool.  Results returned in deterministic plan order.
##     After each successful compile, records closure + content-hash in graph.
##     For cdSkipFresh entrypoints: compile phase is skipped entirely.
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

import std/[envvars, json, monotimes, options, os, sequtils, sets, strutils, tables, times]
import crisol/[types, config, render, depgraph, protocol, planner, scheduler, admission, memprobe, sandbox, cachedispatch, ledger, keys, workerplan, closure, compiledriver]
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

proc mkdtemp(tmpl: cstring): cstring
  {.importc: "mkdtemp", header: "<stdlib.h>".}
  ## POSIX mkdtemp(3): create a secure temp dir from a template ending in
  ## XXXXXX. Modifies the template in-place and returns it on success, or
  ## nil on error. rfc-0007 A2b: this used to come in via `import std/
  ## posix`; declared directly now that `std/posix` has left this file
  ## (raw libc import, not a posix-module dependency — see spawn.nim's
  ## former identical declaration, now dead code removed with that file).

proc makeTmpDir(prefix: string): string =
  ## Create a secure temporary directory using mkdtemp(3).
  ## The template must end with exactly 6 'X' characters (POSIX requirement).
  ## Returns the created directory path, or raises IOError on failure.
  ## Using mkdtemp avoids PID-predictable temp paths (M8 fix).
  var tmpl = getTempDir() / (prefix & "XXXXXX")
  # mkdtemp modifies the template in-place.
  var buf = newString(tmpl.len + 1)
  copyMem(addr buf[0], tmpl.cstring, tmpl.len + 1)
  let r = mkdtemp(buf.cstring)
  if r == nil:
    raise newException(IOError, "mkdtemp failed for template: " & tmpl)
  result = $cast[cstring](r)

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
                    q: HashSet[string]): bool =
  ## Pure: returns true iff this entrypoint's failure contribution should be
  ## downgraded (excluded from exit-1) under the quarantine set `q`.
  ##
  ## Two rules are applied in order; either is sufficient:
  ##
  ##   B3 (path rule):
  ##     ep.path ∈ q  → quarantined.  Matches entire binaries by path, regardless
  ##     of outcome or protocol records.  A cached pass for a path-quarantined
  ##     binary is also marked (harmless — summarize only suppresses failures).
  ##
  ##   B4 (per-test name rule):
  ##     outcome(res) is a failure AND res.records contains ≥ 1 rsFail record AND
  ##     every rsFail record's name ∈ q  → quarantined.
  ##     If ANY failing record's name is NOT in q, the rule does NOT fire.
  ##     If the entrypoint failed with NO rsFail records (opaque binary, exit
  ##     nonzero without protocol, killed, crashed, etc.) this rule does NOT
  ##     apply — only the B3 path rule can downgrade such results.
  ##
  ## One flat set:
  ##   The same `q` is matched against both entrypoint paths (B3) and test-record
  ##   names (B4). An entry is whichever it happens to match; there is no ambiguity
  ##   because paths and test names occupy different positions in the decision tree.

  # B3: whole-binary path-match (always checked first; applies to any outcome).
  if ep.path in q:
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
      if rec.name notin q:
        return false  # at least one failing record is NOT quarantined → real failure

  # failCount > 0 AND every failing record was in q.
  result = failCount > 0

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
  if res.run.kind in {ptypes.pkRan, ptypes.pkCached} and res.run.res.rusage.isSome:
    (res.run.res.rusage.get.maxRssBytes, "wait4")
  else:
    (0'i64, "")

proc appendAttemptRow(led: var Ledger; ep: Entrypoint; attemptNum: int;
                      res: EntrypointResult; inputHash: string;
                      peakRssBytes: int64 = 0) =
  ## Append one LedgerRow for a completed live attempt.
  ## Converts durationMs→durationUs; peakRssBytes is the per-slot running max
  ## sampled across poll ticks while the run phase was live (C5).
  let iKey = identityKey(ep.path, flagHash(ep.flags))
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
    attempt:         int          # B0/B1: current attempt number (1-indexed); set at dispatch
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
                     durationUs: int64): ptypes.ProcessResult =
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
  ## `evidence.hermetic` stays the ord-0 default here — it is runner-
  ## authored (not backend-observed) and has no producer yet; a compile-
  ## phase result has no HermeticLevel concept to begin with (sandboxing is
  ## a run-phase-only notion, §5), so threading it through this ONE shared
  ## constructor cleanly is a separate, not-yet-scheduled slice, flagged
  ## rather than silently wired half-right here.
  ptypes.ProcessResult(
    exit: report.exit,
    cause: ptypes.classifyCause(report.exit, report.stop, limits, report.limits),
    evidence: ptypes.Evidence(
      killDomain:             report.killDomain,
      tree:                   report.tree,
      escapees:               report.escapees,
      limits:                 report.limits,
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

proc nextDeadline(slots: seq[Slot]; now: MonoTime; sampleTickMs: int): MonoTime =
  ## §1: "the executor passes min(run deadlines, grace deadlines, sample
  ## tick)". `sampleTickMs` keeps RFC-0002's RSS-sampling cadence unchanged
  ## (§Contract impacts) — it is a CEILING, not a poll interval: `next`
  ## still returns immediately on a real child-exit or shutdown event.
  result = now + initDuration(milliseconds = sampleTickMs)
  for s in slots:
    if s.state == ssLive:
      let d = if s.stopDeadline.isSome: s.stopDeadline.get else: s.deadline
      if d < result: result = d

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

  FinalizeOutcome = object
    case kind: FinalizeKind
    of fkDone: res: EntrypointResult
    of fkTransitioned, fkOmitted: discard

proc transitionToRun(sv: var Supervisor; slot: var Slot; runTimeoutMs: int;
                     attempt: int; projectRoot: string): bool
  ## Forward-declared: defined below, alongside spawnCompileStable/
  ## spawnRunDirect (the other two ChildSpec-building spawn sites).

proc cleanupSlotTmp(slot: Slot)
  ## Forward-declared: defined below (unchanged from pre-A2b) — removes
  ## per-slot temp output files + the A4a scratch tmpdir; deliberately
  ## narrower than cleanupSlotOnTeardown (see that proc's doc comment).

proc classifyRunResult(
  ep: Entrypoint; output: string; elapsed: int64; compileSkipped: bool;
): EntrypointResult
  ## Forward-declared: defined below (unchanged from pre-A2b) — the plain
  ## opaque-fallback EntrypointResult construction for a normal run end
  ## with no protocol records.

proc finalizeSlot(
  sv:              var Supervisor;
  slots:           var seq[Slot];
  idx:             int;
  plan:            RunPlan;
  maxOutputBytes:  int;
  allowTransition: bool;
  projectRoot:     string;
): FinalizeOutcome =
  ## Called once `next` has reported weChildExited for `slots[idx].id`.
  ## Reaps it (the only place a ChildId is consumed, §1) and either
  ## transitions a successfully-compiled, un-stopped slot into its run
  ## phase (fkTransitioned) or produces this pepIdx's EntrypointResult
  ## (fkDone / fkOmitted). `allowTransition` is false only during interrupt
  ## teardown.
  ##
  ## rfc-0007 §2: `report.stop` is the SINGLE source of authorship —
  ## `toProcessResult`'s `classifyCause` call already consults it before the
  ## exit itself, so this proc never branches on "was this a timeout or an
  ## interrupt" anywhere: krTimeout and krInterrupt reach the exact same
  ## code from here on.
  let report  = sv.reap(slots[idx].id)
  let pepIdx  = slots[idx].pepIdx
  let pep     = plan.entrypoints[pepIdx]
  let elapsed = int64((epochTime() - slots[idx].t0) * 1000)

  case slots[idx].phase
  of spCompiling:
    if report.stop.isSome:
      # Killed mid-compile — timeout or interrupt, identical shape either way.
      let suffix = case report.stop.get.reason
                   of ptypes.krTimeout:   "\n[compile timed out]"
                   of ptypes.krInterrupt: "\n[interrupted]"
      let output = readCapped(slots[idx].compOut, maxOutputBytes) & suffix
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
      let output = readCapped(slots[idx].compOut, maxOutputBytes)
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
      # Compile succeeded, no stop act — capture it onto the slot so the
      # eventual run-phase result (below, or a later kill) carries BOTH
      # phases.
      slots[idx].compileProcRes = some(toProcessResult(report, ptypes.Limits(), elapsed * 1000))
      if not allowTransition:
        cleanupSlotOnTeardown(slots[idx])
        slots[idx].state = ssIdle
        return FinalizeOutcome(kind: fkOmitted)
      let ok = transitionToRun(sv, slots[idx], slots[idx].runTimeoutMs, slots[idx].attempt,
                               projectRoot)
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
      let output = readCapped(slots[idx].runOut, maxOutputBytes)
      res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                             compileSkipped: slots[idx].compileSkipped,
                             attempts: slots[idx].attempt)
    elif report.exit.kind == ptypes.ekSignaled:
      let output   = readCapped(slots[idx].runOut, maxOutputBytes)
      let sinkData = readSink(slots[idx].sinkPath, maxOutputBytes)
      res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                             compileSkipped: slots[idx].compileSkipped,
                             records: sinkData.records)
    else:
      let output   = readCapped(slots[idx].runOut, maxOutputBytes)
      let sinkData = readSink(slots[idx].sinkPath, maxOutputBytes)
      if sinkData.hasProtocol:
        res = EntrypointResult(ep: pep.ep, output: output, durationMs: elapsed,
                               compileSkipped: slots[idx].compileSkipped,
                               records: sinkData.records)
      else:
        res = classifyRunResult(pep.ep, output, elapsed, slots[idx].compileSkipped)
    let runRes = toProcessResult(report, slots[idx].spec.limits, elapsed * 1000)
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
      discard sv.reap(slots[idx].id)   # DISCARDED — no Phase, no Cause, no onResult
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
                             config: Config): MeasurePlan =
  ## Plan construction for the compile-slot measurement worker
  ## (`config.measureCompileReuse`).
  ##
  ## configHash = flagHash(ep.flags), computed PER-ENTRYPOINT — this MUST
  ## collide with appendAttemptRow's identityKey(ep.path, flagHash(ep.flags))
  ## (this file, ~line 156) or ArtifactRows silently orphan from the
  ## RunLedger's IdentityKey (measureworker.nim's own documented contract).
  MeasurePlan(
    entrypointPath:    ep.path,
    entrypointAbsPath: epAbs,
    flags:             ep.flags,
    nimcacheDir:       cacheDir,
    outputBinPath:     binCompiled,
    groupId:           ep.group,
    configHash:        flagHash(ep.flags),
    stateDir:          stateDirOf(config),
    projectRoot:       config.projectRoot.absolutePath.normalizedPath,
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
  ## 1. A depgraph entry exists for `(ep.path, flagHash(ep.flags))`: delete
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
  let key = (ep.path, flagHash(ep.flags))
  if key in graph.entries:
    for obj in staleExternalObjects(graph, ep.path, ep.flags, config.projectRoot):
      removeFile(cacheDir / obj)
  elif hadPriorContent:
    for kind, path in walkDir(cacheDir):
      if kind != pcFile: continue
      let base = path.extractFilename
      if not base.endsWith(".o"): continue
      if isModuleObjectName(base): continue
      removeFile(path)

proc spawnCompileStable(
  sv:               var Supervisor;
  slot:             var Slot;
  pepIdx:           int;
  pep:              PlannedEntrypoint;
  config:           Config;
  graph:            DepGraph;
  compileTimeoutMs: int;
  spec:             SandboxSpec;
  toolchainFp:      string;
  dupSlugs:         HashSet[string];
): bool =
  ## Fill slot with a compile child.
  ##
  ## nimcache (RFC-0006 nimcache-persistence): the COMMON case (this
  ## entrypoint's slug appears exactly once in the plan) uses the STABLE,
  ## toolchain-fingerprinted `cachePath(ep, config, toolchainFp)` — a pure
  ## function of (ep.path, ep.flags, toolchainFp), never of plan position —
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

  let ep = pep.ep
  # R3: resolve entrypoint to absolute path before passing to nim c.
  let epAbs =
    if ep.path.isAbsolute: ep.path
    else: config.projectRoot / ep.path

  let epSlug = slug(ep.path, ep.flags)
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
    let mplan = buildCompileWorkerPlan(ep, epAbs, cacheDir, binCompiled, config)
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
  # crisol itself was invoked from.
  let childSpec = ChildSpec(
    argv:   compArgs,
    cwd:    config.projectRoot.absolutePath.normalizedPath,
    env:    filterEnv(toSeq(envPairs()), SandboxSpec(envScrub: false), @[]),
    sinks:  combinedSink(compOut),
    limits: ptypes.Limits(),  # compile is unsandboxed — no limits requested
  )
  let sr = sv.spawn(childSpec)
  if not sr.ok:
    # M15: cacheDir intentionally NOT wiped — nim c never ran this attempt
    # (spawn itself failed); see the mkdtemp-failure comment above.
    try: removeDir(tmpDir)     except: discard
    try: removeDir(binDirSlot) except: discard
    return false

  slot.state           = ssLive
  slot.id              = sr.id
  slot.pepIdx          = pepIdx
  slot.phase           = spCompiling
  slot.deadline        = getMonoTime() + initDuration(milliseconds = compileTimeoutMs)
  slot.stopDeadline    = none(MonoTime)
  slot.forceKilled     = false
  slot.t0              = epochTime()
  slot.runTimeoutMs    = effectiveRunTimeoutMs(ep, config)  # S2b: per-entrypoint run budget
  slot.tmpDir          = tmpDir        # M8: temp dir holding output files
  slot.testScratchDir  = ""            # A4a: populated when spec.tmpdir=true (spec-from-config slice)
  slot.compOut         = compOut
  slot.runOut          = runOut
  slot.sinkPath        = sinkFile      # R1: sink file path for the run phase
  slot.binCompiled     = binCompiled   # per-slot binary (compile output)
  slot.binFull         = binCompiled   # run uses the per-slot binary
  slot.cacheDir        = cacheDir
  slot.slotBinDir      = binDirSlot    # M15: for cleanup on all paths
  slot.compiledThisRun = true
  slot.compileSkipped  = false
  slot.spec            = spec          # A6: stored for the compile→run transition (transitionToRun)
  slot.compileProcRes  = none(ptypes.ProcessResult)  # rfc-0007 A1b: reset on every claim
                                        # so a reused slot never leaks a prior occupant's
                                        # compile observation; finalizeSlot sets this for
                                        # real once THIS compile is reaped.
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
  config:       Config;
  spec:         SandboxSpec;
  attempt:      int;
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

  let ep = pep.ep
  let binFull = binPath(ep, config) / binName(ep)
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
                                  config.projectRoot.absolutePath.normalizedPath, scratchDir)
  except:
    try: removeDir(tmpDir) except: discard
    return false

  let sr = sv.spawn(childSpec)
  if not sr.ok:
    try: removeDir(tmpDir) except: discard
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  slot.state           = ssLive
  slot.id              = sr.id
  slot.pepIdx          = pepIdx
  slot.phase           = spRunning
  slot.deadline        = getMonoTime() + initDuration(milliseconds = rtMs)
  slot.stopDeadline    = none(MonoTime)
  slot.forceKilled     = false
  slot.t0              = epochTime()
  slot.runTimeoutMs    = rtMs           # S2b: stored for reference (deadline already set)
  slot.tmpDir          = tmpDir        # M8: temp dir to clean up
  slot.testScratchDir  = scratchDir    # A4a/A6: per-entrypoint scratch tmpdir (cleaned everywhere)
  slot.compOut         = ""
  slot.runOut          = runOut
  slot.sinkPath        = sinkFile      # R1: sink file path
  slot.binFull         = binFull
  slot.slotBinDir      = ""
  slot.compiledThisRun = false
  slot.compileSkipped  = true
  slot.spec            = spec          # A2b: carried so groupRssBytes callers and a
                                        # later kill have the same spec context
  slot.compileProcRes  = none(ptypes.ProcessResult)  # rfc-0007 A1b: cdSkipFresh —
                                        # no compile happened this run; reset so a
                                        # reused slot never leaks a prior occupant's
                                        # compile observation.
  result = true

proc transitionToRun(sv: var Supervisor; slot: var Slot; runTimeoutMs: int;
                     attempt: int; projectRoot: string): bool =
  ## rfc-0007 A2b: transition a compile-succeeded, un-stopped slot into its
  ## running phase — spawns the compiled binary as a NEW child (a fresh
  ## ChildId; the compile child's id was already consumed by `reap` before
  ## this is called). Returns false on spawn failure; caller records
  ## oSpawnError. Formerly `spawnRun`.
  ## R1: injects CRISOL_SINK into the child's environment.
  ## B0: injects CRISOL_ATTEMPT=attempt (1-indexed) into the child environment.

  var scratchDir: string
  var childSpec: ChildSpec
  try:
    childSpec = buildRunChildSpec(slot.binFull, slot.runOut, slot.sinkPath,
                                  slot.spec, attempt, projectRoot, scratchDir)
  except:
    return false

  let sr = sv.spawn(childSpec)
  if not sr.ok:
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  slot.id              = sr.id
  slot.phase           = spRunning
  slot.deadline        = getMonoTime() + initDuration(milliseconds = runTimeoutMs)
  slot.stopDeadline    = none(MonoTime)
  slot.forceKilled     = false
  slot.testScratchDir  = scratchDir   # A4a/A6: cleaned on all exit paths
  result = true

proc cleanupSlotTmp(slot: Slot) =
  ## Remove temp output files (compile and run output captured), the sink
  ## file, and the A4a per-entrypoint scratch tmpdir (testScratchDir).
  ## The per-slot tmpDir is NOT removed here — it is cleaned up by the
  ## execute main loop AFTER the binary has been copied to the stable path.
  if slot.compOut.len > 0:
    try: removeFile(slot.compOut) except: discard
  if slot.runOut.len > 0:
    try: removeFile(slot.runOut) except: discard
  if slot.sinkPath.len > 0:
    try: removeFile(slot.sinkPath) except: discard
  # A4a: remove the per-entrypoint scratch tmpdir on all exit paths.
  if slot.testScratchDir.len > 0:
    try: removeDir(slot.testScratchDir) except: discard

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
  memThrottledOut:  ptr int = nil;  ## S6b: if non-nil, written with ac.memThrottledSlots on return
  interruptedOut:   ptr bool = nil;  ## rfc-0007 A1e-ii: if non-nil, written true iff
                                    ## a SIGINT/SIGTERM cut this run short (§2) —
                                    ## CrisolInterrupted is retired; this is its
                                    ## replacement signal. The raw signal number is
                                    ## written to `shutdownSignalOut` (below), not
                                    ## readable via signals.pendingSignal() any more
                                    ## (rfc-0007 A2b: the Supervisor owns shutdown-
                                    ## signal capture for the duration of this call).
  notStartedOut:    ptr int = nil;  ## rfc-0007 A1e-ii: if non-nil, written with the
                                    ## count of entries OMITTED from the returned
                                    ## seq because their next phase never started
                                    ## (§2's emission-set rule) — 0 on a normal
                                    ## (non-interrupted) completion.
  shutdownSignalOut: ptr int = nil;  ## rfc-0007 A2b: if non-nil, written with the
                                    ## SIGINT/SIGTERM signum this call's own
                                    ## Supervisor observed (0 when not interrupted)
                                    ## — RFC-0003's 128+n needs `n`; §1's
                                    ## ShutdownSignal carries exactly this value.
  installSignals:   bool = false;  ## rfc-0007 A2b: this call's OWN Supervisor owns
                                    ## SIGINT/SIGTERM installation for its duration
                                    ## (`initSupervisor(installSignals)`, §1) — the
                                    ## seam that used to be the CALLER's job (via
                                    ## crisol/signals.installSignalHandlers before
                                    ## calling execute). Library default stays OFF:
                                    ## a caller that never asks for interrupt
                                    ## handling gets none installed, same as before.
  cache:            CacheContext = cacheDisabled(resolveSandbox());  ## M4: cohesive cache bundle
): seq[EntrypointResult] =
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
  ## After each successful compile+run, records the closure and content hash in
  ## `graph` and saves the depgraph (single writer, main poll loop).
  ##
  ## failFast=true: once any completed entrypoint has a failure outcome, no NEW
  ## entrypoints are dispatched.  In-flight entrypoints drain to completion.
  ##
  ## Results are returned in deterministic plan order (index == pepIdx) — EXCEPT
  ## on an interrupted run (rfc-0007 A1e-ii, §2): entries whose next phase never
  ## started are OMITTED entirely (counted in `notStartedOut` instead), so the
  ## returned seq is shorter than `p.entrypoints` and no longer index-aligned
  ## to it; relative order among the entries that ARE returned is preserved.

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
    return @[]

  # issue #8: the source index used to resolve @p/@n closure entries is a
  # pure function of the source tree (config.projectRoot + config.depRoots),
  # never of any single entrypoint/compile — build it at most ONCE per
  # execute() call, lazily on the first closure recording, and thread it
  # through every recordClosure call below. A run that compiles nothing
  # (every entrypoint fresh or cached) never pays the walk.
  var sourceIndex: SourceIndex
  var sourceIndexBuilt = false
  proc ensureSourceIndex() =
    if not sourceIndexBuilt:
      sourceIndex = buildSourceIndex(config)
      sourceIndexBuilt = true

  # nimcache-persistence (RFC-0006): computed ONCE per execute() call, not
  # per slot/compile — both are pure functions of the plan/toolchain, never
  # of a slot's runtime state.
  #   toolchainFp — folds nimVersion+ccVersion into the persistent nimcache
  #     path (planner.cachePath) so a toolchain upgrade lands on a fresh dir.
  #   dupSlugs    — the rare set of slugs scheduled ≥2× in THIS plan; those
  #     fall back to the old volatile pepIdx-suffixed dir in spawnCompileStable
  #     to avoid two concurrent slots racing on one nimcache write.
  let toolchainFp = toolchainFingerprint(nimVersion, ccVersion)
  let dupSlugs    = duplicateSlugs(p)

  # Pre-allocate result slots so we can fill them by index (plan order).
  result = newSeq[EntrypointResult](n)

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
    let look = lookupAtPlan(p.entrypoints[i], cache.policy, cache.seams)
    cacheDecisions[i] = look.cacheDecision
    inputHashes[i]    = look.inputHash  # A8: stamped onto live miss results below
    if look.decision == edCached and look.synthesized.isSome:
      # Served from cache: synthesize, fire callback now, retire the slot.
      # edCached entries are NEVER retried — they are terminal at plan time.
      var synth = look.synthesized.get
      synth.cacheDecision = look.cacheDecision   # cdmHit
      # B3/B4: apply quarantine overlay post-lookup — quarantine is a reporting
      # concern, not part of the soundness/cache key.  Cached results are
      # always passes (only passing results are stored), so the B4 per-test
      # rule naturally no-ops here; the B3 path rule still applies.
      synth.quarantined = isQuarantined(p.entrypoints[i].ep, synth, config.quarantine)
      result[i] = synth
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
  # reported to the caller via `interruptedOut`.
  var wasInterrupted = false
  var shutdownSignum = 0  # rfc-0007 A2b: the real signum, for shutdownSignalOut

  # rfc-0007 A2b: `shuttingDown` is the ONE flag that turns the SAME loop
  # below from normal dispatch into interrupt drain — no separate teardown
  # loop. Once true: no new work is dispatched (the fill pass is skipped
  # entirely), every live slot has already had its stop act recorded, and
  # the loop keeps calling `next` — draining weChildExited/weDeadline/
  # weShutdown exactly as it always did — until no slot is live.
  var shuttingDown = false

  template handleChildExited(childId: ChildId) =
        ## rfc-0007 A2b: extracted so the weShutdown handler (below) can drain
        ## any child that ALREADY exited but that this executor simply hadn't
        ## gotten around to noticing yet BEFORE committing remaining live slots
        ## to interrupt teardown — see the drain loop in the weShutdown case.
        ## A TEMPLATE, not a proc: a nested proc capturing the enclosing
        ## proc's implicit `result` (or a `var seq` parameter, same issue
        ## hit earlier with `slots`) trips Nim's memory-safety capture
        ## check at codegen; a template inlines at each call site instead,
        ## sidestepping capture entirely.
        let idx              = slotIndexOf(slots, childId)
        let completedIdx     = slots[idx].pepIdx
        let compiledThisRun  = slots[idx].compiledThisRun
        let slotCacheDir     = slots[idx].cacheDir       # capture before slot cleared
        let slotBinCompiled  = slots[idx].binCompiled    # capture before slot cleared
        let slotBinDir       = slots[idx].slotBinDir     # per-slot bin dir (M15)
        let slotToken        = slots[idx].token          # S3: capture before slot cleared
        let slotAttempt      = slots[idx].attempt        # B0/B1: current attempt number

        # S6b/rfc-0007 A2b: sample finish-time RSS BEFORE `finalizeSlot`
        # reaps — reap is the only place a ChildId is consumed (§1), and
        # `groupRssBytes` on an already-reaped id is a Defect. A lingering
        # pgroup member (e.g. an orphaned grandchild) can still be observed
        # at this exact instant — same intent as the pre-A2b finish-time
        # sample; only actually used below once the slot is confirmed to
        # have gone idle (fkDone/fkOmitted), harmless to compute otherwise.
        let finishRss = sv.groupRssBytes(slots[idx].id)

        let fo = finalizeSlot(sv, slots, idx, p, maxOutputBytes,
                              allowTransition = not shuttingDown,
                              projectRoot = config.projectRoot.absolutePath.normalizedPath)

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
        of fkDone:
          ac.onSlotFinish(slotToken, finishRss)  # S6b: feed real RSS so estJobPeak adapts
          result[completedIdx] = fo.res

          if shuttingDown:
            # rfc-0007 §2: interrupt-killed finals bypass retry/ledger/cache/
            # promotion entirely — fired through onResult exactly like a
            # live completion. A slot torn down here never reaches the
            # promotion block below, so sweep what finalizeSlot's RUN-phase
            # branch leaves behind (a compile-phase kill already fully
            # cleaned itself via cleanupSlotOnTeardown).
            if slotBinDir.len > 0:
              try: removeDir(slotBinDir) except: discard
            if slots[idx].tmpDir.len > 0:
              try: removeDir(slots[idx].tmpDir) except: discard
            finalized[completedIdx] = true
            onResult(fo.res)
          else:
            # rfc-0007 §2: retry/flaky/quarantine decisions read the pure
            # derivation — there is no stored legacy field to read instead.
            let completedOutcome = outcome(result[completedIdx])
            let maxAttempts = p.entrypoints[completedIdx].retries + 1  # B1

            # B2: append one ledger row per live attempt — including intermediate
            # failed attempts that will be retried.  inputHash for intermediate
            # attempts uses the plan-time key (may be ""); the final attempt's
            # inputHash will be stamped later by the cache-store gate if caching
            # is active, but for observability we record the plan-time key here
            # (consistent: the build identity is the same across all attempts).
            if ledgerActive:
              appendAttemptRow(led, p.entrypoints[completedIdx].ep, slotAttempt,
                               result[completedIdx], inputHashes[completedIdx],
                               slots[idx].peakRssBytes)

            # B1: retry decision — re-dispatch if the result is a failure AND we
            # have remaining attempts.  Compile failures and spawn errors are NOT
            # retried (retrying a compile failure is useless; only run failures
            # benefit from retry).  oKilled and oCrashed ARE retried (transient
            # infrastructure noise).
            #
            # "Failure eligible for retry" = outcome is NOT oPassed AND NOT
            # oCompileFailed AND NOT oSpawnError, AND attempts[completedIdx] < maxAttempts.
            let retryEligible =
              completedOutcome notin {oPassed, oCompileFailed, oSpawnError} and
              slotAttempt < maxAttempts

            if retryEligible:
              # Re-dispatch: the slot is now idle; the fill scan will pick it up.
              # Do NOT inc done; do NOT call onResult (not final yet).
              discard  # slot cleared above; fill scan will re-dispatch

            else:
              # Finalize: pass or exhausted retries.
              inc done
              finalized[completedIdx] = true

              # B1: stamp attempts onto the final result; flaky is derived
              # from attempts (A1e-i: `flaky(r, policy)`, no field to stamp).
              result[completedIdx].attempts = slotAttempt
              # B3/B4: apply quarantine overlay — pure reporting, not cache or execution logic.
              # At the live-finalize site, result[completedIdx] carries the final records
              # (protocol or empty), so the B4 per-test rule has full information.
              result[completedIdx].quarantined =
                isQuarantined(p.entrypoints[completedIdx].ep,
                              result[completedIdx],
                              config.quarantine)

              # Track whether any failure has been recorded (for failFast).
              if failFast and completedOutcome.isFailure:
                anyFailed = true

              # After run completes for a compiled-this-run slot: copy the binary
              # to the stable slug-keyed path, then record freshness in the depgraph.
              # Binary is valid (compile succeeded) whenever outcome is not
              # oCompileFailed or oSpawnError.
              # R9: default true — only a compiled-this-run entry whose closure
              # recording actually failed sets this false; every other path
              # (cache hit, edSkipFresh, etc.) is unaffected by this gate.
              var closureRecorded = true
              if compiledThisRun and slotCacheDir.len > 0:
                if completedOutcome notin {oCompileFailed, oSpawnError}:
                  let ep = p.entrypoints[completedIdx].ep
                  let bname = binName(ep)
                  let stableBinDir = binPath(ep, config)
                  let stableBin    = stableBinDir / bname
                  # Invariant on exit from this block: either (the depgraph
                  # entry on disk matches the stable binary at `stableBin`) or
                  # (no stable binary exists at `stableBin`) — NEVER a binary
                  # whose provenance the on-disk depgraph does not describe
                  # (issue #13.3). A promotion or persist failure below always
                  # resolves toward "no stable binary" rather than leaving a
                  # binary paired with a stale or absent depgraph entry.
                  #
                  # Copy per-slot binary to the stable slug-keyed location.
                  # The stable binary is what decideCompile checks on future runs.
                  if slotBinCompiled.len > 0 and slotBinCompiled != stableBin:
                    try:
                      createDir(stableBinDir)
                      copyFile(slotBinCompiled, stableBin)
                      setFilePermissions(stableBin, {fpUserRead, fpUserWrite, fpUserExec,
                                                     fpGroupRead, fpGroupExec,
                                                     fpOthersRead, fpOthersExec})
                    except CatchableError as e:
                      # Promotion failed partway (e.g. copyFile succeeded but
                      # setFilePermissions did not) — whatever landed at
                      # stableBin has unknown/partial content and no depgraph
                      # entry describes it either way; discard it so the next
                      # run starts from cdNeverBuilt instead of trusting it.
                      # Not exercisable under test as root (chmod-based faults
                      # do not fail for root); this is untested hardening.
                      stderr.write("crisol: warning: " & ep.path &
                                   ": could not promote its compiled binary (" &
                                   e.msg & "); the previous binary was discarded\n")
                      try: stderr.flushFile() except CatchableError: discard
                      try: removeFile(stableBin) except CatchableError: discard

                  # Record the closure — recovery policy lives in recordClosure
                  # (see DepGraphEntry.closure, invariant NONEMPTY-CLOSURE, and
                  # recordClosure's doc comment in depgraph.nim).
                  ensureSourceIndex()
                  let rec = recordClosure(graph, config, ep,
                                          slotCacheDir, bname, CrisolProtocolMajor,
                                          sourceIndex)
                  closureRecorded = rec.ok
                  if not rec.ok:
                    # The depgraph entry for this compile is either invalidated
                    # or (on a persist failure) not reliably reflected on disk
                    # at all — either way, the stable binary just promoted
                    # above must not survive to be served by a future run
                    # whose decideCompile can no longer be trusted to agree
                    # with it (issue #13.3).
                    try: removeFile(stableBin) except CatchableError: discard
                    stderr.write("crisol: warning: " & ep.path & ": could not record its " &
                                 "source closure (" & rec.error & "); dependency record " &
                                 "invalidated and its binary was discarded — it will be " &
                                 "recompiled and force-selected next run\n")
                    try: stderr.flushFile() except CatchableError: discard

              # Clean up the per-slot bin dir after stable copy (M15).
              # finalizeSlot already cleaned this on compile-fail; only clean here on success.
              if compiledThisRun and slotBinDir.len > 0:
                try: removeDir(slotBinDir) except: discard

              # ---------------------------------------------------------------
              # A6/A7: cache-store gate for a freshly-RUN (not cached) result.
              # Store ONLY when (a) policy permits, (b) hermeticity was achieved,
              # and (c) it passed on attempt 1 (not a flaky-pass — never cache
              # flaky: it would freeze the result as PASS forever).
              # ALWAYS stamp the live result's CacheDecision for reporting (A8).
              # ---------------------------------------------------------------
              if cacheActive:
                let verdict = shouldStore(result[completedIdx], cache.spec,
                                          slotAttempt, cache.policy,
                                          p.entrypoints[completedIdx].cacheable)
                # R9: a store is permitted only when BOTH the policy verdict AND
                # the closure recording (above) agree. A result whose closure
                # failed to record must never be stored: keyOf would derive the
                # SoundnessKey from an empty closureContentHash, and the entry
                # could never be looked up again (lookup needs edRunFresh, which
                # needs a depgraph entry) — a permanently dead cache write.
                if verdict.store and closureRecorded:
                  # Re-derive the key from the NOW-updated graph (closureHash fresh)
                  # so a later run's lookup-key matches this store-key.
                  let key = cache.seams.keyOf(p.entrypoints[completedIdx])
                  let cr  = toCachedResult(result[completedIdx], epochTime().int64)
                  let stored = cache.seams.store(key, cr)
                  # A8: the store-key is the authoritative inputHash for this live run
                  # (the plan-time lookup key was derived before this compile updated
                  # the graph; for an edStale/edNeverBuilt entry there was no plan-time
                  # key at all).  Stamp the freshly-derived key string.
                  result[completedIdx].inputHash = $key
                  # M8: cdmStored = fresh run on a miss where the result WAS written.
                  # cdmKeyMiss = fresh run on a miss where the result was NOT stored.
                  # A run/v1 consumer can tell from cacheDecision alone whether a store
                  # happened, without inferring from inputHash presence.
                  result[completedIdx].cacheDecision =
                    if stored: cdmStored else: cdmKeyMiss
                else:
                  # Not stored: either the verdict carries the structural reason, or
                  # (R9) the verdict said store but the closure wasn't recorded — in
                  # which case stamp cdmClosureUnrecorded, a dedicated variant so a
                  # `--json` reader can tell WHY the store didn't happen instead of
                  # this collapsing into the generic cdmKeyMiss.
                  # Stamp the plan-time key (set for an edRunFresh miss; "" otherwise)
                  # so a consulted-but-not-stored result still reports its inputHash.
                  result[completedIdx].inputHash = inputHashes[completedIdx]
                  result[completedIdx].cacheDecision =
                    if verdict.store: cdmClosureUnrecorded   # else-branch ⇒ not closureRecorded
                    else: verdict.decision
              else:
                # Caching inactive: stamp the structural reason recorded at plan time.
                result[completedIdx].cacheDecision = cacheDecisions[completedIdx]

              # Fire onResult ONCE with the final result (B1 contract).
              onResult(result[completedIdx])


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
          let attemptNum = attempts[j]  # B0: current attempt (1-indexed)
          slots[i].attempt = attemptNum # B0: store on slot so spawnRun can read it
          slots[i].peakRssBytes = 0    # C5: reset peak at slot claim (fresh attempt)

          if pep.edecision == edRunFresh:
            # Skip compile: spawn run directly with the existing stable binary.
            # S2b: runTimeoutMs is resolved inside spawnRunDirect from effectiveRunTimeoutMs.
            let ok = spawnRunDirect(sv, slots[i], pepIdx, pep, config, cache.spec, attemptNum)
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
              result[pepIdx] = res
              onResult(res)
              finalized[pepIdx] = true
              anyFailed = true
              inc done
            else:
              slots[i].token = tok.get  # S3: store token for onSlotFinish
          else:
            # Normal compile + run using stable slug-keyed paths.
            let ok = spawnCompileStable(sv, slots[i], pepIdx, pep, config, graph,
                                        compileTimeoutMs, cache.spec, toolchainFp,
                                        dupSlugs)
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
              result[pepIdx] = res
              onResult(res)
              finalized[pepIdx] = true
              anyFailed = true
              inc done
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
                  inFlight.add (p.entrypoints[s.pepIdx].ep.path, elapsed)
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
          # because that is honestly what it is.
          var drainBudget = slots.len
          while drainBudget > 0:
            dec drainBudget
            let evReady = sv.next(getMonoTime())
            if evReady.kind == weChildExited:
              handleChildExited(evReady.id)
            else:
              break  # nothing more immediately ready (weDeadline), or a
                     # second real signal already — either way, proceed.

          shuttingDown = true
          wasInterrupted = true
          shutdownSignum = ev.signal.signum
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
        discard  # subreaper tier only (B1) — not reachable from this backend yet

      # -----------------------------------------------------------------------
      # failFast early-exit: if no slots are live and we would not dispatch any
      # more work, break now — remaining entrypoints were never started.
      # Return only entries from finalized[] so summarize sees only ran
      # entrypoints (non-contiguous with skip-ahead).
      # -----------------------------------------------------------------------
      if not shuttingDown and failFast and anyFailed and not anyLiveSlot(slots):
        # H1: with skip-ahead, finalized indices may be non-contiguous; emit only
        # entries actually completed (never-dispatched entries are omitted).
        var ran: seq[EntrypointResult]
        for j in 0 ..< n:
          if finalized[j]:
            ran.add(result[j])
        result = ran
        return

  finally:
    # M12/M6/rfc-0007 A2b: handles the exception path (e.g. an onResult
    # callback raised) AND the normal/early-return path (a no-op when every
    # slot is already idle — always true on a normal or interrupted
    # completion: the interrupt path above already drained to zero live
    # slots inside the SAME loop, via the SAME requestStop/escalateExpired/
    # next machinery, before the loop condition let it exit). `teardownDiscard`
    # is the "exception teardown records NOTHING" half of the shared
    # machinery (§2) — never attributes, never fires onResult.
    # S6b: always write memThrottledSlots (normal, early-return, and exception paths).
    # B2: close the ledger shard on all exit paths (normal, early-return, exception).
    teardownDiscard(sv, slots)
    if ledgerActive:
      closeLedger(led)
    if memThrottledOut != nil:
      memThrottledOut[] = ac.memThrottledSlots

  # rfc-0007 A1e-ii: trim `result` to the §2 emission set — entries whose
  # last-started phase is pkRan/pkCached/pkSpawnFailed, i.e. `finalized`.
  # On a normal (non-interrupted) completion `done == n` is the while loop's
  # only exit condition, and `done` only ever advances alongside
  # `finalized[i] = true`, so every index is finalized here and this is a
  # transparent reshuffle. On an interrupted run, entries never claimed by a
  # slot (queued, or the RFC's "compile-done-run-unstarted" corner) stay
  # unfinalized and are OMITTED here rather than emitted as a fabricated
  # "run never started" lie — counted in notStartedOut instead.
  var notStarted = 0
  var emitted: seq[EntrypointResult]
  for i in 0 ..< n:
    if finalized[i]: emitted.add result[i]
    else: inc notStarted
  result = emitted

  if interruptedOut != nil:
    interruptedOut[] = wasInterrupted
  if notStartedOut != nil:
    notStartedOut[] = notStarted
  if shutdownSignalOut != nil:
    shutdownSignalOut[] = shutdownSignum

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
    # Use current dir as projectRoot so ep.path can be absolute or CWD-relative.
    projectRoot:        getCurrentDir(),
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
                        cache = cacheDisabled(resolveSandbox()))
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

proc summarize*(results: seq[EntrypointResult]): Summary =
  ## Pure: fold a result sequence into aggregate counts.
  ##
  ## B3: a quarantined FAILURE is excluded from all exit-contributing buckets
  ## (failed/compileFailed/spawnErrors/counts[oKilled]/counts[oCrashed]) and
  ## counted in Summary.quarantined instead.  A quarantined PASS counts
  ## normally in `passed` — quarantine only suppresses the failure; it's
  ## harmless on pass.
  result.total = results.len
  for r in results:
    let o = outcome(r)
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
    if flaky(r): inc result.flaky  # B1: count flaky-passes
  result.noTestsRan = result.passed == 0 and result.total > 0
