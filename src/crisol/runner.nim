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
## Scheduler design (A4):
##   • At most plan.jobs child processes alive at once.
##   • Single-threaded poll loop: waitpid(WNOHANG) every ~25 ms.
##   • Slot state machine: compiling → running → done  (or running → done for cdSkipFresh).
##   • Fork failure for one slot never aborts the pool.
##   • Output captured to per-entrypoint temp files; read atomically after
##     completion; bounded by maxOutputBytes.

import std/[json, monotimes, options, os, sets, times]
import std/posix
import crisol/[types, config, spawn, signals, render, depgraph, protocol, planner, scheduler, admission, memprobe, sandbox, cachedispatch, ledger, keys, workerplan, closure, compiledriver]
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

proc openOutputFile(path: string): cint =
  ## Open `path` for writing (create / truncate), returning a raw fd with
  ## O_CLOEXEC so the fd is not inherited across unrelated exec calls.
  ## Returns -1 on failure.
  let flags = O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC
  posix.open(path.cstring, flags, Mode(0o600))

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
  ##     res.outcome is a failure AND res.records contains ≥ 1 rsFail record AND
  ##     every rsFail record's name ∈ q  → quarantined.
  ##     If ANY failing record's name is NOT in q, the rule does NOT fire.
  ##     If the entrypoint failed with NO rsFail records (opaque binary, exit
  ##     nonzero without protocol, oTimeout, oSignal, etc.) this rule does NOT
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
  if not res.outcome.isFailure:
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

proc appendAttemptRow(led: var Ledger; ep: Entrypoint; attemptNum: int;
                      res: EntrypointResult; inputHash: string;
                      peakRssBytes: int64 = 0) =
  ## Append one LedgerRow for a completed live attempt.
  ## Converts durationMs→durationUs; peakRssBytes is the per-slot running max
  ## sampled across poll ticks while the run phase was live (C5).
  let iKey = identityKey(ep.path, flagHash(ep.flags))
  let row = LedgerRow(
    identity:   iKey,
    timestamp:  int64(epochTime() * 1_000_000),  # unix epoch microseconds
    inputHash:  inputHash,
    outcome:    types.outcomeString(res.outcome),
    attempt:    attemptNum,
    durationUs: res.durationMs * 1000,
    rssBytes:   peakRssBytes,  # C5: peak RSS bytes for this attempt
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

  Slot = object
    ## One concurrent execution slot.  Empty when pepIdx == -1.
    pepIdx:          int           # index into plan.entrypoints; -1 = idle
    phase:           SlotPhase
    pid:             Pid           # live child pid (== pgid)
    deadline:        MonoTime      # R11: monotonic deadline for current phase
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
    achieved:        SandboxAchieved  # A4d/A6: hermeticity actually delivered by the
                                      # run child (set at the spawnRun* call); copied
                                      # onto the EntrypointResult and used by the
                                      # cache-store gate (isFullyAchieved).
    spec:            SandboxSpec   # A6: resolved sandbox spec for the run phase; stored
                                   # at compile-spawn so the compile→run transition
                                   # (spawnRun) can route through forkExecEnvScratch.
    token:           SlotToken     # S3: admission token; released on finish or spawn failure
    attempt:         int          # B0/B1: current attempt number (1-indexed); set at dispatch
    peakRssBytes:    int64        # C5: running max of procGroupRssBytes across all polls
                                   # while this slot's run phase is live.  Reset to 0 when
                                   # the slot is claimed (before compile or run spawned).
                                   # Updated each poll tick for run-phase (spRunning) slots.
                                   # Read at finalize; threaded into ledger row + EntrypointResult.

proc reapBlocking(pid: Pid) =
  ## Blocking waitpid that retries on EINTR — consistent with supervise's
  ## post-SIGKILL reap.  Ensures a child killed during interrupt/exception
  ## teardown is collected even if a signal interrupts the wait.
  var ws: cint = 0
  while true:
    let r = waitpid(pid, ws, 0)
    if r >= Pid(0) or errno != EINTR: break

proc killAndReap(pid: Pid) =
  ## M11: Send SIGTERM to the process group, wait up to GracePeriodMs, then
  ## escalate to SIGKILL and do a blocking reap.
  ## Safe to call when the process may already be dead.
  discard killpg(pid, SIGTERM)
  let graceDeadline = getMonoTime() + initDuration(milliseconds = GracePeriodMs)
  while getMonoTime() < graceDeadline:
    var ws: cint = 0
    let r = waitpid(pid, ws, WNOHANG)
    if r == pid:
      return  # exited cleanly during grace
    os.sleep(20)
  # Escalate to SIGKILL and reap.
  discard killpg(pid, SIGKILL)
  reapBlocking(pid)

proc teardownLiveSlots(slots: var seq[Slot]) =
  ## M6: Graceful shutdown of all live slots — shared by handleInterrupt and the
  ## exception finally path.  Mirrors the three-phase approach used in the
  ## supervise helper and in handleInterrupt (SIGTERM → grace drain → SIGKILL),
  ## so test children can flush output/protocol records before being killed.
  ##
  ## Phase 1: SIGTERM all live process groups.
  for s in slots:
    if s.pepIdx != -1:
      discard killpg(s.pid, SIGTERM)

  ## Phase 2: drain up to GracePeriodMs with WNOHANG polls.
  ## Track per-slot reaped state so Phase 3 never re-signals an already-reaped pid
  ## (in a container with pid/pgid reuse, a SIGKILL could hit an unrelated process).
  var reapedInGrace = newSeq[bool](slots.len)
  let drainDeadline = getMonoTime() + initDuration(milliseconds = GracePeriodMs)
  while getMonoTime() < drainDeadline:
    var allDead = true
    for i in 0 ..< slots.len:
      if slots[i].pepIdx == -1: continue  # idle or already reap-tracked
      if reapedInGrace[i]: continue       # reaped this grace window — skip
      var ws: cint = 0
      let r = waitpid(slots[i].pid, ws, WNOHANG)
      if r == Pid(0):
        allDead = false                   # still alive; keep draining
      elif r > Pid(0):
        reapedInGrace[i] = true           # exited cleanly during grace; do NOT SIGKILL
    if allDead: break
    os.sleep(20)

  ## Phase 3: SIGKILL any that survived the grace window, then reap all.
  ## Slots reaped in Phase 2 are SKIPPED — their pid is gone (possibly reused).
  for i in 0 ..< slots.len:
    if slots[i].pepIdx == -1: continue
    if reapedInGrace[i]: continue  # R2-2: already reaped in Phase 2; do not SIGKILL
    var ws: cint = 0
    let r = waitpid(slots[i].pid, ws, WNOHANG)
    if r == Pid(0):
      discard killpg(slots[i].pid, SIGKILL)
      reapBlocking(slots[i].pid)
    # else: exited between Phase 2 end and Phase 3 check — already reaped, no SIGKILL

  ## Phase 4: cleanup temp dirs and clear slot so loops are idempotent on
  ## double-invocation (e.g. interrupt path marks slots idle before finally runs).
  for i in 0 ..< slots.len:
    if slots[i].pepIdx == -1: continue   # already idle (or never live)
    if slots[i].tmpDir.len > 0:
      try: removeDir(slots[i].tmpDir) except: discard
    if slots[i].testScratchDir.len > 0:
      try: removeDir(slots[i].testScratchDir) except: discard
    if slots[i].slotBinDir.len > 0:
      try: removeDir(slots[i].slotBinDir) except: discard
    # nimcache-persistence: only wipe cacheDir when the slot was interrupted
    # WHILE COMPILING — nim's own process was killed mid-write and may have
    # left a partial/corrupt nimcache. A slot interrupted during spRunning
    # already has a complete, valid, persistent nimcache from its (already
    # successful) compile phase; wiping it on every Ctrl-C would silently
    # defeat persistence for the common "interrupt a long test run" case.
    if slots[i].phase == spCompiling and slots[i].cacheDir.len > 0:
      try: removeDir(slots[i].cacheDir) except: discard
    slots[i].pepIdx = -1  # mark idle so a second call is a no-op

proc classifyRunResult(
  exitCode: int; signal: int; timedOut: bool;
  ep: Entrypoint; output: string; elapsed: int64; compileSkipped: bool;
): EntrypointResult =
  if timedOut:
    EntrypointResult(ep: ep, outcome: oTimeout, signal: int(SIGKILL),
                     output: output, durationMs: elapsed,
                     compileSkipped: compileSkipped)
  elif signal != 0:
    EntrypointResult(ep: ep, outcome: oSignal, signal: signal,
                     output: output, durationMs: elapsed,
                     compileSkipped: compileSkipped)
  elif exitCode == 0:
    EntrypointResult(ep: ep, outcome: oPassed, exitCode: 0,
                     output: output, durationMs: elapsed,
                     compileSkipped: compileSkipped)
  else:
    EntrypointResult(ep: ep, outcome: oFailed, exitCode: exitCode,
                     output: output, durationMs: elapsed,
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
  )

proc spawnCompileStable(
  slot:             var Slot;
  pepIdx:           int;
  pep:              PlannedEntrypoint;
  config:           Config;
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

  let fd = openOutputFile(compOut)
  if fd < 0:
    # M15: cacheDir intentionally NOT wiped — nim c never ran this attempt
    # (compile-output fd open failed before forkExec); see the mkdtemp-
    # failure comment above.
    try: removeDir(tmpDir)     except: discard
    try: removeDir(binDirSlot) except: discard
    return false

  let pid = forkExec(compArgs, fd)
  discard posix.close(fd)

  if int(pid) < 0:
    # M15: cacheDir intentionally NOT wiped — forkExec itself failed, so
    # nim c never ran this attempt; see the mkdtemp-failure comment above.
    try: removeDir(tmpDir)     except: discard
    try: removeDir(binDirSlot) except: discard
    return false

  slot.pepIdx          = pepIdx
  slot.phase           = spCompiling
  slot.pid             = pid
  slot.deadline        = getMonoTime() + initDuration(milliseconds = compileTimeoutMs)
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
  slot.spec            = spec          # A6: stored for the compile→run transition (spawnRun)
  result = true

proc spawnRunDirect(
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
  ## A6: routes through forkExecEnvScratch — the single spec-driven spawn entry
  ##     — so the LIVE run path actually applies hermeticity (env scrub, isolated
  ##     TMPDIR, rlimits) and reports SandboxAchieved over the A4d status pipe.
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

  let fd = openOutputFile(runOut)
  if fd < 0:
    try: removeDir(tmpDir) except: discard
    return false

  # A6: spec-driven spawn.  CRISOL_SINK and CRISOL_ATTEMPT are injected
  # (after the allowlist filter); the scratch tmpdir + TMPDIR injection +
  # rlimits are handled by spec.
  var scratchDir: string
  let (pid, achieved) = forkExecEnvScratch(
    @[binFull], fd,
    [("CRISOL_SINK", sinkFile), ("CRISOL_ATTEMPT", $attempt)],
    spec, scratchDir)
  discard posix.close(fd)

  if int(pid) < 0:
    try: removeDir(tmpDir) except: discard
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  slot.pepIdx          = pepIdx
  slot.phase           = spRunning
  slot.pid             = pid
  slot.deadline        = getMonoTime() + initDuration(milliseconds = rtMs)
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
  slot.achieved        = achieved      # A4d/A6: hermeticity delivered by this run
  result = true

proc spawnRun(
  slot:         var Slot;
  runTimeoutMs: int;
  attempt:      int;
): bool =
  ## Transition a compile-succeeded slot into the running phase.
  ## Spawns the compiled binary as a new child.
  ## Returns false on fork/file-open failure; caller records oSpawnError.
  ## R1: injects CRISOL_SINK into the child's environment.
  ## B0: injects CRISOL_ATTEMPT=attempt (1-indexed) into the child environment.
  ## A6: routes through forkExecEnvScratch (spec stored on the slot) so the run
  ##     phase of a freshly-compiled entrypoint gets the same hermeticity as the
  ##     skip-fresh path, and reports SandboxAchieved for the cache-store gate.

  let fd = openOutputFile(slot.runOut)
  if fd < 0:
    return false

  # R1: inject CRISOL_SINK — slot.sinkPath was set in spawnCompileStable.
  # B0: inject CRISOL_ATTEMPT (1-indexed).
  var scratchDir: string
  let (pid, achieved) = forkExecEnvScratch(
    @[slot.binFull], fd,
    [("CRISOL_SINK", slot.sinkPath), ("CRISOL_ATTEMPT", $attempt)],
    slot.spec, scratchDir)
  discard posix.close(fd)

  if int(pid) < 0:
    if scratchDir.len > 0:
      try: removeDir(scratchDir) except: discard
    return false

  slot.phase          = spRunning
  slot.pid            = pid
  slot.deadline       = getMonoTime() + initDuration(milliseconds = runTimeoutMs)
  slot.testScratchDir = scratchDir   # A4a/A6: cleaned on all exit paths
  slot.achieved       = achieved     # A4d/A6: hermeticity delivered by this run
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

proc pollSlot(
  slot:           var Slot;
  results:        var seq[EntrypointResult];
  plan:           RunPlan;
  maxOutputBytes: int;
): bool =
  ## Poll a live slot with waitpid(WNOHANG).
  ## Returns true if the slot is now idle (completed or errored) — caller
  ## should clear slot.pepIdx and may fill it with a new entrypoint.
  ##
  ## S2b: the global runTimeoutMs parameter has been removed.  The per-
  ## entrypoint run deadline is read from slot.runTimeoutMs (set at slot
  ## setup time by spawnCompileStable / spawnRunDirect via
  ## effectiveRunTimeoutMs) when transitioning spCompiling → spRunning.
  ##
  ## B1: onResult is NOT called here.  The execute loop decides whether to
  ## retry (failure + attempts remaining) or finalize (pass or exhausted).
  ## onResult is called ONCE by the execute loop after that decision.
  ##
  ## Records the result in `results[slot.pepIdx]`; execute loop calls onResult.

  var wstatus: cint = 0
  var r: Pid
  # R10: retry waitpid on EINTR.
  while true:
    r = waitpid(slot.pid, wstatus, WNOHANG)
    if r >= Pid(0) or errno != EINTR:
      break

  # R11: monotonic deadline comparison.
  let timedOut = getMonoTime() >= slot.deadline

  # Check for timeout first: kill and reap, then process as timed out.
  if timedOut and r != slot.pid:
    killAndReap(slot.pid)
    # After kill, wstatus is meaningless; synthesize the timeout result.
    let pep    = plan.entrypoints[slot.pepIdx]
    let elapsed = int64((epochTime() - slot.t0) * 1000)
    let output =
      if slot.phase == spCompiling:
        readCapped(slot.compOut, maxOutputBytes) & "\n[compile timed out]"
      else:
        readCapped(slot.runOut, maxOutputBytes)
    let outcome =
      if slot.phase == spCompiling: oCompileFailed
      else:                         oTimeout
    var res = EntrypointResult(ep: pep.ep, outcome: outcome,
                               signal: int(SIGKILL), output: output,
                               durationMs: elapsed,
                               compileSkipped: slot.compileSkipped)
    # M15: clean up per-slot bin dir on timeout during compile.
    if slot.phase == spCompiling and slot.slotBinDir.len > 0:
      try: removeDir(slot.slotBinDir) except: discard
    # nimcache-persistence: a compile killed mid-run (SIGKILL on timeout) can
    # leave a partial/corrupt nimcache (interrupted .c/.json manifest write) —
    # the same "corrupt partial cache must not persist" rule as an outright
    # compile failure below, so wipe it here too. A run-phase timeout leaves
    # cacheDir alone: the compile that produced it already succeeded.
    if slot.phase == spCompiling and slot.cacheDir.len > 0:
      try: removeDir(slot.cacheDir) except: discard
    cleanupSlotTmp(slot)
    results[slot.pepIdx] = res
    return true  # execute loop calls onResult after retry decision

  if r == 0:
    # Child still running, no timeout yet.
    return false

  if r < Pid(0):
    # R10: EINTR is now retried above; this branch is only ECHILD (truly no child).
    let pep    = plan.entrypoints[slot.pepIdx]
    let elapsed = int64((epochTime() - slot.t0) * 1000)
    var res = EntrypointResult(ep: pep.ep, outcome: oFailed, exitCode: 1,
                               output: "waitpid error (ECHILD)",
                               durationMs: elapsed,
                               compileSkipped: slot.compileSkipped)
    cleanupSlotTmp(slot)
    results[slot.pepIdx] = res
    return true  # execute loop calls onResult after retry decision

  # r == slot.pid: child has exited.
  let exitedCode   = if WIFEXITED(wstatus):   int(WEXITSTATUS(wstatus)) else: 0
  let sigNum       = if WIFSIGNALED(wstatus): int(WTERMSIG(wstatus))    else: 0
  let pep          = plan.entrypoints[slot.pepIdx]

  case slot.phase
  of spCompiling:
    if exitedCode != 0 or sigNum != 0:
      # Compile failed.
      let output  = readCapped(slot.compOut, maxOutputBytes)
      let elapsed = int64((epochTime() - slot.t0) * 1000)
      var res = EntrypointResult(ep: pep.ep, outcome: oCompileFailed,
                                 exitCode: exitedCode, signal: sigNum,
                                 output: output, durationMs: elapsed)
      # M15: clean up per-slot cache and bin dirs on compile failure.
      if slot.cacheDir.len > 0:
        try: removeDir(slot.cacheDir) except: discard
      if slot.slotBinDir.len > 0:
        try: removeDir(slot.slotBinDir) except: discard
      cleanupSlotTmp(slot)
      results[slot.pepIdx] = res
      return true  # execute loop calls onResult after retry decision
    else:
      # Compile succeeded → transition to running phase.
      # S2b: use the per-entrypoint run budget stored at slot setup time.
      # B0: pass the attempt counter stored on the slot.
      let ok = spawnRun(slot, slot.runTimeoutMs, slot.attempt)
      if not ok:
        # Run spawn failed.
        let elapsed = int64((epochTime() - slot.t0) * 1000)
        var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                   output: "fork failed during run phase",
                                   durationMs: elapsed)
        # M15: clean up the scratch bin dir only. cacheDir is intentionally
        # LEFT ALONE here — the compile that produced it already succeeded
        # (we are past the exitedCode/sigNum check above); this is a run-
        # phase fork failure, unrelated to the nimcache's validity. Wiping a
        # good persistent nimcache over an unrelated run-spawn failure would
        # defeat nimcache-persistence for no reason.
        if slot.slotBinDir.len > 0:
          try: removeDir(slot.slotBinDir) except: discard
        cleanupSlotTmp(slot)
        results[slot.pepIdx] = res
        return true  # execute loop calls onResult after retry decision
      # Slot is now in spRunning; not yet done.
      return false

  of spRunning:
    let output  = readCapped(slot.runOut, maxOutputBytes)
    let elapsed = int64((epochTime() - slot.t0) * 1000)

    # R1: Precedence rule — oTimeout/oSignal/oSpawnError are decided by the
    # executor (above).  Here the process exited normally; apply the OR-rule.
    # Only read the sink and reconcile when the process exited (not signaled).
    var res: EntrypointResult
    if sigNum != 0:
      # Killed by signal — oSignal takes precedence; no sink reconciliation.
      res = EntrypointResult(ep: pep.ep, outcome: oSignal, signal: sigNum,
                             output: output, durationMs: elapsed,
                             compileSkipped: slot.compileSkipped)
    else:
      # Normal exit — read the sink and apply the OR-rule (R1).
      let sinkData = readSink(slot.sinkPath, maxOutputBytes)
      if sinkData.hasProtocol:
        # Structured protocol: reconcile exit code + fail records.
        let outcome = reconcile(sinkData.records, exitedCode)
        res = EntrypointResult(ep: pep.ep, outcome: outcome,
                               exitCode: exitedCode, output: output,
                               durationMs: elapsed,
                               compileSkipped: slot.compileSkipped,
                               records: sinkData.records)
      else:
        # Opaque fallback: use exit-code-only classification.
        res = classifyRunResult(exitedCode, 0, false,
                                pep.ep, output, elapsed, slot.compileSkipped)

    # A4d/A6: carry the hermeticity actually achieved by this run so the
    # execute loop's cache-store gate can apply isFullyAchieved.
    res.achieved = slot.achieved
    cleanupSlotTmp(slot)
    results[slot.pepIdx] = res
    return true  # execute loop calls onResult after retry decision

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
  ## Results are returned in deterministic plan order (index == pepIdx).

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

  # Slots array: nJobs concurrent slots; idle when pepIdx == -1.
  var slots = newSeq[Slot](nJobs)
  for s in slots.mitems:
    s.pepIdx = -1

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

  # ---------------------------------------------------------------------------
  # R2/A6: Signal-interrupt helper — calls teardownLiveSlots (TERM→drain→KILL),
  # then raises CrisolInterrupted.  teardownLiveSlots marks all slots idle so
  # the finally block is a no-op for the interrupt path (MED-1).
  # ---------------------------------------------------------------------------
  template handleInterrupt(signo: cint) =
    teardownLiveSlots(slots)
    raise newCrisolInterrupted(signo)

  # ---------------------------------------------------------------------------
  # M12: wrap entire dispatch loop in try/finally so any exception (e.g. from
  # an onResult callback) still group-kills + reaps + cleans all live slots.
  # ---------------------------------------------------------------------------
  try:
    while done < n:
      # -----------------------------------------------------------------------
      # A6/R2: check for pending signal before doing any other work this iteration.
      # -----------------------------------------------------------------------
      let sig = pendingSignal()
      if sig != 0:
        handleInterrupt(sig)

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
        if s.pepIdx == -1: inc idleCountBefore
        else:              inc liveCountBefore
      var dispatchedThisPass = false

      inc passId  # new fill pass: admit will refresh the snapshot on its first call

      # L5: `isInFlight` hoisted above the per-slot loop so it is defined ONCE
      # per fill pass rather than re-allocating a closure env on each of the
      # nJobs iterations.  All captured variables (slots) remain in scope here.
      proc isInFlight(j: int): bool {.closure.} =
        for s in slots:
          if s.pepIdx == j: return true
        false

      for i in 0 ..< nJobs:
        if slots[i].pepIdx != -1: continue  # slot busy
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
            let ok = spawnRunDirect(slots[i], pepIdx, pep, config, cache.spec, attemptNum)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                         output: "fork or file-open failed for skip-fresh run",
                                         durationMs: 0,
                                         compileSkipped: true,
                                         attempts: attemptNum)
              result[pepIdx] = res
              onResult(res)
              finalized[pepIdx] = true
              anyFailed = true
              inc done
            else:
              slots[i].token = tok.get  # S3: store token for onSlotFinish
          else:
            # Normal compile + run using stable slug-keyed paths.
            let ok = spawnCompileStable(slots[i], pepIdx, pep, config, compileTimeoutMs,
                                        cache.spec, toolchainFp, dupSlugs)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              # Fork/resource failure: record oSpawnError immediately.
              var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                         output: "fork or file-open failed before compile",
                                         durationMs: 0,
                                         attempts: attemptNum)
              result[pepIdx] = res
              onResult(res)
              finalized[pepIdx] = true
              anyFailed = true
              inc done
              # Slot remains idle (pepIdx == -1); loop continues.
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
      # Poll all live slots.
      # -----------------------------------------------------------------------
      for i in 0 ..< nJobs:
        if slots[i].pepIdx == -1: continue  # idle

        let compiledThisRun = slots[i].compiledThisRun
        let slotPepIdx      = slots[i].pepIdx
        let slotCacheDir    = slots[i].cacheDir       # capture before slot cleared
        let slotBinCompiled = slots[i].binCompiled    # capture before slot cleared
        let slotBinDir      = slots[i].slotBinDir     # per-slot bin dir (M15)
        let slotToken       = slots[i].token          # S3: capture before slot cleared
        let slotPid         = int(slots[i].pid)       # S6b: capture pid before slot cleared
        let slotAttempt     = slots[i].attempt        # B0/B1: current attempt number

        # C5: pre-poll RSS sampling for already-running slots.
        # Sample BEFORE pollSlot so the child is definitely live (WNOHANG inside
        # pollSlot may reap it; RSS is 0 after reap for a vanished pgroup).
        # Compile-phase slots are excluded — the Nim compiler's VmRSS is not
        # meaningful as test-binary telemetry.
        if slots[i].phase == spRunning:
          let rssNow = procGroupRssBytes(slotPid)
          if rssNow.isSome:
            slots[i].peakRssBytes = max(slots[i].peakRssBytes, rssNow.get)

        let finished = pollSlot(slots[i], result, p, maxOutputBytes)

        # C5: post-poll RSS sample for slots that JUST transitioned to spRunning
        # (compile finished this tick → spawnRun ran inside pollSlot → slot is now
        # spRunning but we did NOT sample before because it was spCompiling).
        # Also catches any remaining RSS if the child ran fast but is still live.
        if not finished and slots[i].phase == spRunning:
          let pidNow = int(slots[i].pid)  # pid updated by spawnRun
          let rssNow = procGroupRssBytes(pidNow)
          if rssNow.isSome:
            slots[i].peakRssBytes = max(slots[i].peakRssBytes, rssNow.get)

        if finished:
          # Capture the completed pepIdx and peak RSS before clearing the slot.
          let completedIdx   = slotPepIdx
          let slotPeakRss    = slots[i].peakRssBytes  # C5: captured before slot cleared
          slots[i].pepIdx = -1
          # S6b: feed real RSS into onSlotFinish so estJobPeak adapts.
          # Admission uses a finish-time sample (not the tracked peak) so its
          # behavior is unaffected by C5's sampling.
          ac.onSlotFinish(slotToken, procGroupRssBytes(slotPid))

          let completedOutcome = result[completedIdx].outcome
          let maxAttempts = p.entrypoints[completedIdx].retries + 1  # B1

          # C5: stamp peak RSS onto the EntrypointResult for observability.
          result[completedIdx].peakRssBytes = slotPeakRss

          # B2: append one ledger row per live attempt — including intermediate
          # failed attempts that will be retried.  inputHash for intermediate
          # attempts uses the plan-time key (may be ""); the final attempt's
          # inputHash will be stamped later by the cache-store gate if caching
          # is active, but for observability we record the plan-time key here
          # (consistent: the build identity is the same across all attempts).
          if ledgerActive:
            appendAttemptRow(led, p.entrypoints[completedIdx].ep, slotAttempt,
                             result[completedIdx], inputHashes[completedIdx],
                             slotPeakRss)

          # B1: retry decision — re-dispatch if the result is a failure AND we
          # have remaining attempts.  Compile failures and spawn errors are NOT
          # retried (retrying a compile failure is useless; only run failures
          # benefit from retry).  oTimeout and oSignal ARE retried (transient
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
            # attempts[completedIdx] was already incremented when the re-dispatch
            # was initiated in the fill scan; no change needed here.
            # (The slot.attempt field will be set correctly on the re-dispatch.)
            discard  # slot cleared above; fill scan will re-dispatch

          else:
            # Finalize: pass or exhausted retries.
            inc done
            finalized[completedIdx] = true

            # B1: stamp attempts and flaky onto the final result.
            result[completedIdx].attempts = slotAttempt
            result[completedIdx].flaky    = (completedOutcome == oPassed and slotAttempt > 1)
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
                # Copy per-slot binary to the stable slug-keyed location.
                # The stable binary is what decideCompile checks on future runs.
                if slotBinCompiled.len > 0 and slotBinCompiled != stableBin:
                  try:
                    createDir(stableBinDir)
                    copyFile(slotBinCompiled, stableBin)
                    setFilePermissions(stableBin, {fpUserRead, fpUserWrite, fpUserExec,
                                                   fpGroupRead, fpGroupExec,
                                                   fpOthersRead, fpOthersExec})
                  except:
                    discard  # non-fatal

                # Record the closure — recovery policy lives in recordClosure
                # (see DepGraphEntry.closure, invariant NONEMPTY-CLOSURE, and
                # recordClosure's doc comment in depgraph.nim).
                ensureSourceIndex()
                let rec = recordClosure(graph, config, ep,
                                        slotCacheDir, bname, CrisolProtocolMajor,
                                        sourceIndex)
                closureRecorded = rec.ok
                if not rec.ok:
                  stderr.write("crisol: warning: " & ep.path & ": could not record its " &
                               "source closure (" & rec.error & "); dependency record " &
                               "invalidated — it will be recompiled and force-selected " &
                               "next run\n")
                  try: stderr.flushFile() except CatchableError: discard

            # Clean up the per-slot bin dir after stable copy (M15).
            # pollSlot already cleaned this on compile-fail; only clean here on success.
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
              let verdict = shouldStore(result[completedIdx], cache.spec, slotAttempt, cache.policy,
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

      # -----------------------------------------------------------------------
      # failFast early-exit: if no slots are live and we would not dispatch any
      # more work, break now — remaining entrypoints were never started.
      # Return only entries from finalized[] so summarize sees only ran
      # entrypoints (non-contiguous with skip-ahead).
      # -----------------------------------------------------------------------
      if failFast and anyFailed:
        let anyLiveNow = block:
          var found = false
          for s in slots:
            if s.pepIdx != -1:
              found = true
              break
          found
        if not anyLiveNow:
          # H1: with skip-ahead, finalized indices may be non-contiguous; emit only
          # entries actually completed (never-dispatched entries are omitted).
          var ran: seq[EntrypointResult]
          for j in 0 ..< n:
            if finalized[j]: ran.add(result[j])
          result = ran
          return

      # Avoid busy-spinning when all slots are live.
      # Only sleep when there are live children (done < n and all slots busy or
      # queue is drained).  If we just freed a slot and the queue has work, the
      # next iteration will fill it immediately without sleeping.
      let anyLive = block:
        var found = false
        for s in slots:
          if s.pepIdx != -1:
            found = true
            break
        found

      # -----------------------------------------------------------------------
      # Progress line: emit to stderr ~every progressIntervalMs when showProgress.
      # Lists in-flight entrypoints and how long each has been running.
      # -----------------------------------------------------------------------
      if showProgress and anyLive:
        let nowProgress = epochTime()
        let msSinceProgress = int64((nowProgress - lastProgressAt) * 1000)
        if msSinceProgress >= int64(progressIntervalMs):
          var inFlight: seq[(string, int64)]
          for s in slots:
            if s.pepIdx != -1:
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

      if anyLive:
        os.sleep(pollIntervalMs)

  finally:
    # M12/M6: handles the exception path (e.g. an onResult callback raised) AND
    # the normal/early-return path (no-ops when all slots are already idle).
    # teardownLiveSlots gives children SIGTERM → GracePeriodMs drain → SIGKILL
    # so they can flush output/protocol records before being killed (M6 fix).
    # The interrupt path (handleInterrupt) already called teardownLiveSlots and
    # marked all slots idle, so this call is a no-op for it (MED-1).
    # S6b: always write memThrottledSlots (normal, early-return, and exception paths).
    # B2: close the ledger shard on all exit paths (normal, early-return, exception).
    teardownLiveSlots(slots)
    if ledgerActive:
      closeLedger(led)
    if memThrottledOut != nil:
      memThrottledOut[] = ac.memThrottledSlots

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
    result = EntrypointResult(ep: ep, outcome: oSpawnError,
                              output: "execute returned no results")

# ---------------------------------------------------------------------------
# summarize — pure aggregate counts
# ---------------------------------------------------------------------------

proc summarize*(results: seq[EntrypointResult]): Summary =
  ## Pure: fold a result sequence into aggregate counts.
  ##
  ## B3: a quarantined FAILURE is excluded from all exit-contributing buckets
  ## (failed/compileFailed/timedOut/signaled/spawnErrors) and counted in
  ## Summary.quarantined instead.  A quarantined PASS counts normally in
  ## `passed` — quarantine only suppresses the failure; it's harmless on pass.
  result.total = results.len
  for r in results:
    if r.quarantined and r.outcome.isFailure:
      # B3: quarantined failure — report it but exclude from exit-1 buckets.
      inc result.quarantined
    else:
      case r.outcome
      of oPassed:        inc result.passed
      of oFailed:        inc result.failed
      of oCompileFailed: inc result.compileFailed
      of oTimeout:       inc result.timedOut
      of oSignal:        inc result.signaled
      of oSpawnError:    inc result.spawnErrors
    if r.flaky: inc result.flaky  # B1: count flaky-passes
  result.noTestsRan = result.passed == 0 and result.total > 0
