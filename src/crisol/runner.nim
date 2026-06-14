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

import std/[algorithm, monotimes, options, os, sequtils, sets, times]
import std/posix
import crisol/[types, spawn, signals, render, depgraph, closure, protocol, planner, scheduler, admission, memprobe]
export planner   # re-export the pure plan API (slug/binPath/plan/decideCompile/…)
                 # so consumers that `import crisol/runner` keep their symbols.

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
# ResultCallback and noopResult
# ---------------------------------------------------------------------------

type ResultCallback* = proc(r: EntrypointResult) {.closure.}

proc noopResult*(r: EntrypointResult) = discard
  ## Exported default for execute's onResult parameter — never nil, so
  ## optionality is visible in the type rather than hidden in a nil check.

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
    compOut:         string        # path to compile output file (empty for cdSkipFresh)
    runOut:          string        # path to run output file
    sinkPath:        string        # path to CRISOL_SINK file for run phase (R1)
    binCompiled:     string        # path where nim c wrote the binary (slot-specific dir)
    binFull:         string        # stable slug-keyed path; run and freshness use this
    cacheDir:        string        # actual nimcache dir used (includes pepIdx suffix)
    slotBinDir:      string        # per-slot bin dir (separate from tmpDir for M15 cleanup)
    compiledThisRun: bool          # false for cdSkipFresh slots
    compileSkipped:  bool          # true for cdSkipFresh slots
    token:           SlotToken     # S3: admission token; released on finish or spawn failure

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

proc spawnCompileStable(
  slot:             var Slot;
  pepIdx:           int;
  pep:              PlannedEntrypoint;
  config:           Config;
  compileTimeoutMs: int;
): bool =
  ## Fill slot with a compile child using per-slot isolated paths.
  ##
  ## Both nimcache and the compiled binary go into per-slot (pepIdx-suffixed)
  ## directories to prevent ORC link collisions and write races when the same
  ## entrypoint appears multiple times in one plan.
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
  ## compile-fail and spawn-fail paths.

  let ep = pep.ep
  # R3: resolve entrypoint to absolute path before passing to nim c.
  let epAbs =
    if ep.path.isAbsolute: ep.path
    else: config.projectRoot / ep.path

  let cacheDir    = cachePath(ep, config) & "_" & $pepIdx
  let binDirSlot  = binPath(ep, config) & "_" & $pepIdx
  let bname       = binName(ep)
  let binCompiled = binDirSlot / bname     # compile output + run source

  try:
    createDir(cacheDir)
    createDir(binDirSlot)
  except:
    return false

  # M8: use mkdtemp for temp output files — avoids PID-predictable paths.
  var tmpDir: string
  try:
    tmpDir = makeTmpDir("crisol_slot_")
  except:
    try: removeDir(cacheDir)   except: discard  # M15: clean on failure
    try: removeDir(binDirSlot) except: discard  # M15: clean on failure
    return false

  let compOut = tmpDir / "compile_out.txt"
  let runOut  = tmpDir / "run_out.txt"
  let sinkFile = tmpDir / "sink.ndjson"

  var compArgs = @[
    "nim", "c",
    "--mm:orc",
    "--hints:off",
    "--nimcache:" & cacheDir,
    "-o:" & binCompiled,
  ]
  for flag in ep.flags:
    compArgs.add flag
  compArgs.add epAbs  # R3: absolute path

  let fd = openOutputFile(compOut)
  if fd < 0:
    try: removeDir(tmpDir)     except: discard
    try: removeDir(cacheDir)   except: discard  # M15
    try: removeDir(binDirSlot) except: discard  # M15
    return false

  let pid = forkExec(compArgs, fd)
  discard posix.close(fd)

  if int(pid) < 0:
    try: removeDir(tmpDir)     except: discard
    try: removeDir(cacheDir)   except: discard  # M15
    try: removeDir(binDirSlot) except: discard  # M15
    return false

  slot.pepIdx          = pepIdx
  slot.phase           = spCompiling
  slot.pid             = pid
  slot.deadline        = getMonoTime() + initDuration(milliseconds = compileTimeoutMs)
  slot.t0              = epochTime()
  slot.runTimeoutMs    = effectiveRunTimeoutMs(ep, config)  # S2b: per-entrypoint run budget
  slot.tmpDir          = tmpDir        # M8: temp dir holding output files
  slot.compOut         = compOut
  slot.runOut          = runOut
  slot.sinkPath        = sinkFile      # R1: sink file path for the run phase
  slot.binCompiled     = binCompiled   # per-slot binary (compile output)
  slot.binFull         = binCompiled   # run uses the per-slot binary
  slot.cacheDir        = cacheDir
  slot.slotBinDir      = binDirSlot    # M15: for cleanup on all paths
  slot.compiledThisRun = true
  slot.compileSkipped  = false
  result = true

proc spawnRunDirect(
  slot:         var Slot;
  pepIdx:       int;
  pep:          PlannedEntrypoint;
  config:       Config;
): bool =
  ## Fill slot directly with a run child (cdSkipFresh: compile skipped).
  ## Returns false on resource allocation failure.
  ## R1: injects CRISOL_SINK into the child environment via forkExecEnv.
  ## M8: uses mkdtemp for temp output files.
  ## S2b: run deadline set from effectiveRunTimeoutMs(ep, config) — the
  ## per-entrypoint budget — rather than a caller-supplied global value.

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

  # R1: inject CRISOL_SINK into the child's environment via forkExecEnv.
  let pid = forkExecEnv(@[binFull], fd, [("CRISOL_SINK", sinkFile)])
  discard posix.close(fd)

  if int(pid) < 0:
    try: removeDir(tmpDir) except: discard
    return false

  slot.pepIdx          = pepIdx
  slot.phase           = spRunning
  slot.pid             = pid
  slot.deadline        = getMonoTime() + initDuration(milliseconds = rtMs)
  slot.t0              = epochTime()
  slot.runTimeoutMs    = rtMs           # S2b: stored for reference (deadline already set)
  slot.tmpDir          = tmpDir        # M8: temp dir to clean up
  slot.compOut         = ""
  slot.runOut          = runOut
  slot.sinkPath        = sinkFile      # R1: sink file path
  slot.binFull         = binFull
  slot.slotBinDir      = ""
  slot.compiledThisRun = false
  slot.compileSkipped  = true
  result = true

proc spawnRun(
  slot:         var Slot;
  runTimeoutMs: int;
): bool =
  ## Transition a compile-succeeded slot into the running phase.
  ## Spawns the compiled binary as a new child.
  ## Returns false on fork/file-open failure; caller records oSpawnError.
  ## R1: injects CRISOL_SINK into the child's environment via forkExecEnv.

  let fd = openOutputFile(slot.runOut)
  if fd < 0:
    return false

  # R1: inject CRISOL_SINK — slot.sinkPath was set in spawnCompileStable.
  let pid = forkExecEnv(@[slot.binFull], fd, [("CRISOL_SINK", slot.sinkPath)])
  discard posix.close(fd)

  if int(pid) < 0:
    return false

  slot.phase    = spRunning
  slot.pid      = pid
  slot.deadline = getMonoTime() + initDuration(milliseconds = runTimeoutMs)
  result = true

proc cleanupSlotTmp(slot: Slot) =
  ## Remove temp output files (compile and run output captured) and the sink
  ## file.  The per-slot tmpDir is NOT removed here — it is cleaned up by the
  ## execute main loop AFTER the binary has been copied to the stable path.
  if slot.compOut.len > 0:
    try: removeFile(slot.compOut) except: discard
  if slot.runOut.len > 0:
    try: removeFile(slot.runOut) except: discard
  if slot.sinkPath.len > 0:
    try: removeFile(slot.sinkPath) except: discard

proc pollSlot(
  slot:           var Slot;
  results:        var seq[EntrypointResult];
  plan:           RunPlan;
  onResult:       ResultCallback;
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
  ## Records the result in `results[slot.pepIdx]` and calls onResult when done.

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
    cleanupSlotTmp(slot)
    results[slot.pepIdx] = res
    onResult(res)
    return true

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
    onResult(res)
    return true

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
      onResult(res)
      return true
    else:
      # Compile succeeded → transition to running phase.
      # S2b: use the per-entrypoint run budget stored at slot setup time.
      let ok = spawnRun(slot, slot.runTimeoutMs)
      if not ok:
        # Run spawn failed.
        let elapsed = int64((epochTime() - slot.t0) * 1000)
        var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                   output: "fork failed during run phase",
                                   durationMs: elapsed)
        # M15: clean up on run-spawn failure too.
        if slot.cacheDir.len > 0:
          try: removeDir(slot.cacheDir) except: discard
        if slot.slotBinDir.len > 0:
          try: removeDir(slot.slotBinDir) except: discard
        cleanupSlotTmp(slot)
        results[slot.pepIdx] = res
        onResult(res)
        return true
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

    cleanupSlotTmp(slot)
    results[slot.pepIdx] = res
    onResult(res)
    return true

# ---------------------------------------------------------------------------
# execute — bounded-parallel continue-on-failure runner
# ---------------------------------------------------------------------------

proc execute*(
  p:                RunPlan;
  config:           Config = Config();
  graph:            var DepGraph;
  nimVersion:       string = "";
  onResult:         ResultCallback = noopResult;
  failFast:         bool = false;
  showProgress:     bool = true;
  progressIntervalMs: int = 30_000;
  memThrottledOut:  ptr int = nil;  ## S6b: if non-nil, written with ac.memThrottledSlots on return
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

  # Pre-allocate result slots so we can fill them by index (plan order).
  result = newSeq[EntrypointResult](n)

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
  #   dispatched[i] = true  once entrypoint i has been handed to a slot.
  #   lwm            = smallest index that may still be undispatched; advanced
  #                    eagerly when leading entries are confirmed dispatched, so
  #                    the inner scan never re-walks already-dispatched prefixes.
  var dispatched      = newSeq[bool](n)
  var lwm             = 0   # low-water mark: start of undispatched scan
  var done      = 0     # count of completed entrypoints
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
  # R2/A6: Signal-interrupt helper — TERM→drain→KILL all live slots, cleanup
  # temp dirs, then raise CrisolInterrupted.  Called from the poll loop.
  # ---------------------------------------------------------------------------
  template handleInterrupt(signo: cint) =
    # Phase 1: SIGTERM all live process groups.
    for s in slots:
      if s.pepIdx != -1:
        discard killpg(s.pid, SIGTERM)

    # Phase 2: drain ~GracePeriodMs with WNOHANG polls.
    let drainDeadline = getMonoTime() + initDuration(milliseconds = GracePeriodMs)
    while getMonoTime() < drainDeadline:
      var allDead = true
      for s in slots:
        if s.pepIdx == -1: continue
        var ws: cint = 0
        let r = waitpid(s.pid, ws, WNOHANG)
        if r == Pid(0):
          allDead = false
      if allDead: break
      os.sleep(20)

    # Phase 3: SIGKILL any that survived the grace window, then reap all.
    # Cleanup runs in Phase 4 below; mark each reaped slot idle so the finally
    # block treats them as already-handled (MED-1).
    for i in 0 ..< slots.len:
      if slots[i].pepIdx == -1: continue
      var ws: cint = 0
      let r = waitpid(slots[i].pid, ws, WNOHANG)
      if r == Pid(0):
        discard killpg(slots[i].pid, SIGKILL)
        reapBlocking(slots[i].pid)
      elif r == slots[i].pid:
        discard  # already exited+reaped during the Phase-2 drain (no zombie left)

    # Phase 4: best-effort cleanup of temp dirs, then clear the slot.
    for i in 0 ..< slots.len:
      if slots[i].pepIdx != -1:
        if slots[i].tmpDir.len > 0:
          try: removeDir(slots[i].tmpDir) except: discard
        if slots[i].slotBinDir.len > 0:
          try: removeDir(slots[i].slotBinDir) except: discard
        if slots[i].cacheDir.len > 0:
          try: removeDir(slots[i].cacheDir) except: discard  # MED-2
        # MED-1: this slot's child has been reaped and cleaned; mark it idle so
        # the finally block's loops are no-ops for the interrupt path.
        slots[i].pepIdx = -1

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
      for i in 0 ..< nJobs:
        if slots[i].pepIdx != -1: continue  # slot busy
        if lwm >= n:               continue  # all entries dispatched
        if failFast and anyFailed: continue  # fail-fast: drain only; no new work

        # H1 fix: scan from lwm for the first undispatched entry that admit accepts.
        # Entries whose group is at cap (or memory-blocked) are skipped this pass
        # and retried in a future pass — they are NOT dropped.
        var pepIdx = -1
        for j in lwm ..< n:
          if dispatched[j]: continue
          let candidate = p.entrypoints[j]
          let tok = ac.admit(passId, candidate.ep.group, candidate.decision)
          if tok.isNone:
            continue  # blocked this pass; try next candidate
          # Found an admissible candidate.
          pepIdx = j
          dispatched[j] = true
          dispatchedThisPass = true  # M4: progress was made this pass
          # Advance lwm past any leading run of dispatched entries.
          while lwm < n and dispatched[lwm]:
            inc lwm

          let pep = candidate
          if pep.decision == cdSkipFresh:
            # Skip compile: spawn run directly with the existing stable binary.
            # S2b: runTimeoutMs is resolved inside spawnRunDirect from effectiveRunTimeoutMs.
            let ok = spawnRunDirect(slots[i], pepIdx, pep, config)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                         output: "fork or file-open failed for skip-fresh run",
                                         durationMs: 0,
                                         compileSkipped: true)
              result[pepIdx] = res
              onResult(res)
              anyFailed = true
              inc done
            else:
              slots[i].token = tok.get  # S3: store token for onSlotFinish
          else:
            # Normal compile + run using stable slug-keyed paths.
            let ok = spawnCompileStable(slots[i], pepIdx, pep, config, compileTimeoutMs)
            if not ok:
              ac.release(tok.get)  # S3: rollback admission on spawn failure
              # Fork/resource failure: record oSpawnError immediately.
              var res = EntrypointResult(ep: pep.ep, outcome: oSpawnError,
                                         output: "fork or file-open failed before compile",
                                         durationMs: 0)
              result[pepIdx] = res
              onResult(res)
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

        let finished = pollSlot(slots[i], result, p, onResult,
                                 maxOutputBytes)
        if finished:
          # Capture the completed pepIdx before clearing the slot.
          let completedIdx = slotPepIdx
          slots[i].pepIdx = -1
          # S6b: feed real RSS into onSlotFinish so estJobPeak adapts.
          ac.onSlotFinish(slotToken, procGroupRssBytes(slotPid))
          inc done
          # Track whether any failure has been recorded (for failFast).
          if failFast and result[completedIdx].outcome.isFailure:
            anyFailed = true

          # After run completes for a compiled-this-run slot: copy the binary
          # to the stable slug-keyed path, then record freshness in the depgraph.
          # Binary is valid (compile succeeded) whenever outcome is not
          # oCompileFailed or oSpawnError.
          if compiledThisRun and slotCacheDir.len > 0:
            let outcome = result[completedIdx].outcome
            if outcome notin {oCompileFailed, oSpawnError}:
              let ep = p.entrypoints[completedIdx].ep
              # R3: resolve absolute path for extractClosure.
              let epAbs =
                if ep.path.isAbsolute: ep.path
                else: config.projectRoot / ep.path
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

              try:
                let closureSet = extractClosure(slotCacheDir, bname, epAbs, config)
                var closureSeq: seq[string] = toSeq(closureSet)
                closureSeq.sort()
                let contentHash = closureContentHash(closureSeq, config.projectRoot)
                let fHash = flagHash(ep.flags)
                graph.updateEntry(ep.path, fHash, closureSet, contentHash, CrisolProtocolMajor)
                saveDepGraph(graph, config)
              except:
                discard  # non-fatal; next run will just recompile

          # Clean up the per-slot bin dir after stable copy (M15).
          # pollSlot already cleaned this on compile-fail; only clean here on success.
          if compiledThisRun and slotBinDir.len > 0:
            try: removeDir(slotBinDir) except: discard

      # -----------------------------------------------------------------------
      # failFast early-exit: if no slots are live and we would not dispatch any
      # more work, break now — remaining entrypoints were never started.
      # Return only entries from dispatched[] so summarize sees only ran
      # entrypoints (dispatched indices may be non-contiguous with skip-ahead).
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
          # H1: with skip-ahead, dispatched indices may be non-contiguous; emit only
          # entries actually started (skipped-and-never-dispatched entries are omitted).
          var ran: seq[EntrypointResult]
          for j in 0 ..< n:
            if dispatched[j]: ran.add(result[j])
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
    # M12: handles ONLY the exception path (e.g. an onResult callback raised).
    # Kill + reap + clean all still-live slots so no orphaned children escape.
    # The interrupt path (handleInterrupt) already killed, reaped, cleaned, and
    # cleared its slots before raising CrisolInterrupted, so every slot is idle
    # here and the loops below are no-ops for it (MED-1).
    # S6b: always write memThrottledSlots (normal, early-return, and exception paths).
    if memThrottledOut != nil:
      memThrottledOut[] = ac.memThrottledSlots
    for s in slots:
      if s.pepIdx != -1:
        discard killpg(s.pid, SIGKILL)
        reapBlocking(s.pid)
    for s in slots:
      if s.pepIdx != -1:
        # Clean up temp output files dir (M8).
        if s.tmpDir.len > 0:
          try: removeDir(s.tmpDir) except: discard
        # Clean up per-slot bin dir (M15 — compile-fail/fork-fail/exception paths).
        if s.slotBinDir.len > 0:
          try: removeDir(s.slotBinDir) except: discard
        # Clean up per-slot nimcache dir (MED-2 — leaked on exception path).
        if s.cacheDir.len > 0:
          try: removeDir(s.cacheDir) except: discard

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
  let results = execute(p, cfg, g, "", noopResult, false, false, 30_000)
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
  result.total = results.len
  for r in results:
    case r.outcome
    of oPassed:        inc result.passed
    of oFailed:        inc result.failed
    of oCompileFailed: inc result.compileFailed
    of oTimeout:       inc result.timedOut
    of oSignal:        inc result.signaled
    of oSpawnError:    inc result.spawnErrors
  result.noTestsRan = result.passed == 0 and result.total > 0
