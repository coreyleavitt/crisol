## test_rfc0007_r5_drain_interrupt.nim — rfc-0007 code-review r5 (High):
## interrupt drain defects in the `weShutdown` handler's pre-shutdown drain
## loop (runner.nim, the `while drainBudget > 0` loop inside `of weShutdown:`).
##
## Two independent defects, two suites below:
##
##  r5(a) — the drain loop calls `handleChildExited` BEFORE `shuttingDown` is
##  set true, so a COMPILE child that happened to already exit (successfully)
##  the instant the interrupt arrived gets `allowTransition = not shuttingDown
##  = true` — the FULL post-compile pipeline, including spawning a brand new
##  RUN child, which is then immediately interrupt-killed and reported
##  `oKilled`. The RFC's §2 contract says compile-done-run-unstarted must be
##  honestly OMITTED (counted in `notStarted`, never emitted) — `fkOmitted`
##  exists for exactly this and is unreachable from the drain window.
##
##  r5(b) — the SAME loop's `else: break` fires identically on a genuine
##  weDeadline (nothing more ready) and on a SECOND real weShutdown (a second
##  Ctrl-C observed while still draining the first) — losing the documented
##  second-interrupt contract (process/types.nim's WaitEventKind doc): a
##  second interrupt during the drain must skip the grace window and
##  force-kill every live slot immediately, not fall through to the normal
##  graced requestStop path.
##
## Strategy — an injected `recordClosureFn` (execute()'s R3a seam, RFC-0009
## A-final-ii-a) turns the razor-thin real-world race each defect depends on
## into a deterministic, generously-margined one:
##   - r5(a): entrypoint A (pass_fast.nim, trivial/fast compile) is hooked so
##     that the MOMENT its own compile succeeds — synchronously, inside
##     finalizeSlot, well before any interrupt exists — it sleeps several
##     real seconds and THEN sends itself a real SIGINT. Entrypoint B
##     (slow_compile.nim, a `staticExec("sleep 3")`-gated compile) is
##     dispatched concurrently (jobs=2): its compile is GUARANTEED to finish
##     for real, in the background, sometime during A's sleep — so by the
##     time A's sleep ends and the SIGINT is finally sent, B's compile has
##     ALREADY exited but crisol's single-threaded loop has had no chance to
##     notice (it was blocked the whole time inside A's synchronous hook).
##     The very next `next()` call is EXACTLY the drain-loop scenario the
##     finding describes. Assert: B never appears in the emitted results
##     (never transitioned, never spawned a run child) and is counted in
##     notStarted — RED before the fix (B currently DOES transition, runs,
##     gets killed, and IS emitted as oKilled).
##   - r5(b): entrypoint A (slow_compile.nim here — its OWN 3s compile floor
##     gives sibling entrypoint D time to fully compile AND transition to its
##     run phase before A's hook ever fires) is hooked to send itself TWO
##     real SIGINTs back to back (a tiny sleep apart) the moment its compile
##     succeeds. Both signals are queued (process/posixcore.nim's
##     `pendingShutdown` is a seq, drained one per `next()` call, checked
##     BEFORE child-exit sweeping) before crisol's loop ever calls `next()`
##     again — so the drain loop's own FIRST zero-wait poll already observes
##     the SECOND signal, exactly the "second Ctrl-C during the drain"
##     scenario. Entrypoint D (term_ignores.nim) is live and RUNNING
##     throughout, ignoring SIGTERM — its actual death is only ever caused by
##     SIGKILL, so the elapsed wall-clock time from the second SIGINT to D's
##     result is an honest, non-racy proxy for WHICH path was taken: a graced
##     requestStop (bug) leaves D alive until GracePeriodMs (400ms) elapses
##     and `escalateExpired` force-kills it (~400-450ms observed); an
##     immediate forceKill (fix) kills it right away (well under 250ms).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r5_drain_interrupt.nim

when defined(posix):
  import std/[options, os, posix, strutils, times, unittest]
  import crisol/types
  import crisol/depgraph
  import crisol/closure   # SourceIndex, buildSourceIndex
  import crisol/ccprobe   # RunProc
  import crisol/runner
  import "../support/testep"

  proc fixtureDir(): string =
    let thisFile = currentSourcePath()
    thisFile.parentDir.parentDir / "fixtures"

  proc mkEp(path: string): Entrypoint =
    testEp(path.relativePath(getCurrentDir()), group = "test", flags = @[])

  proc baseCfg(jobs: int): Config =
    Config(
      jobs:               jobs,
      compileTimeoutSecs: 60,
      timeoutSecs:        30,
      projectRoot:        getCurrentDir(),
      trackedRoots:       initTrackedRoots(getCurrentDir(), newSeq[tuple[name, native: string]](), ""),
    )

  proc waitChildResult(childPid: Pid; resultFile: string; timeoutSecs: float): string =
    ## Mirrors test_so2_drain_interrupt.nim's own parent-side reap+read
    ## pattern: wait (bounded) for the forked child to exit, then read
    ## whatever it wrote before quitting.
    var wstatus: cint = 0
    let deadline = epochTime() + timeoutSecs
    var reaped = false
    while epochTime() < deadline:
      let r = waitpid(childPid, wstatus, WNOHANG)
      if r == childPid:
        reaped = true
        break
      os.sleep(50)
    if not reaped:
      discard kill(childPid, SIGKILL)
      discard waitpid(childPid, wstatus, 0)
      return ""
    if fileExists(resultFile): readFile(resultFile).strip() else: ""

  suite "rfc-0007 code-review r5(a) — drain never transitions a compile-success into a new run child":

    test "SIGINT racing a just-finished compile: the entry is omitted, never spawned, never killed":
      let tag        = "crisol_r5a_" & $getpid()
      let resultFile = getTempDir() / (tag & "_result")
      if fileExists(resultFile): removeFile(resultFile)
      defer: (try: removeFile(resultFile) except: discard)

      let childPid = fork()
      check childPid >= 0

      if childPid == 0:
        let fdir = fixtureDir()
        let epA  = mkEp(fdir / "pass_fast.nim")      # A: fast — the hook trigger
        let epB  = mkEp(fdir / "slow_compile.nim")   # B: slow, staticExec-gated — the drain target

        var bFinalized = false
        proc onRes(r: EntrypointResult) =
          if string(r.ep.tp.display()).endsWith("slow_compile.nim"):
            bFinalized = true

        let hook = proc(graph: var DepGraph; config: Config; ep: Entrypoint;
                        nimcacheDir, binaryName: string; protocolMajor: int;
                        index: SourceIndex; ccRun: RunProc): tuple[ok: bool, error: string] =
          if string(ep.tp.display()).endsWith("pass_fast.nim"):
            # A's own compile just succeeded — B's slower compile is still
            # running in the background. Sleep well past B's staticExec
            # floor (3s) plus real compiler overhead before signaling, so
            # crisol's single-threaded loop is GUARANTEED to still be
            # blocked here (never having called `next()` again) once B's
            # compile has genuinely exited.
            os.sleep(6000)
            discard posix.kill(posix.getpid(), cint(SIGINT))
          recordClosure(graph, config, ep, nimcacheDir, binaryName, protocolMajor, index, ccRun)

        let cfg = baseCfg(jobs = 2)
        let p   = plan(cfg, @[epA, epB], emptyDepGraph())
        var g   = emptyDepGraph()
        # rfc-0007 code-review r7: `interruptedOut`/`notStartedOut` ptr params
        # are gone — read `.interrupted`/`.notStarted` off the returned
        # ExecuteReport instead.
        let execReport = execute(p, config = cfg, graph = g, onResult = onRes,
                                 showProgress = false, progressIntervalMs = 30_000,
                                 installSignals = true, recordClosureFn = hook)
        let interrupted = execReport.interrupted
        let notStarted  = execReport.notStarted

        writeFile(resultFile, $interrupted & "," & $notStarted & "," & $bFinalized)
        quit(0)

      let raw = waitChildResult(childPid, resultFile, 30.0)
      check raw.len > 0
      if raw.len > 0:
        let parts = raw.split(',')
        check parts.len == 3
        if parts.len == 3:
          check parts[0] == "true"    # the run really was interrupted
          check parts[2] == "false"   # B: never transitioned/finalized —
                                       # honestly omitted, not spawned+killed
          check parts[1].parseInt >= 1  # B (at least) counted in notStarted

  suite "rfc-0007 code-review r5(b) — a second interrupt during the drain skips the grace window":

    test "second SIGINT observed mid-drain: a live SIGTERM-ignoring slot dies immediately, not after the 400ms grace":
      let tag        = "crisol_r5b_" & $getpid()
      let resultFile = getTempDir() / (tag & "_result")
      if fileExists(resultFile): removeFile(resultFile)
      defer: (try: removeFile(resultFile) except: discard)

      let childPid = fork()
      check childPid >= 0

      if childPid == 0:
        let fdir = fixtureDir()
        let epA  = mkEp(fdir / "slow_compile.nim")    # A: the hook trigger — its OWN
                                                       # 3s compile floor buys D time to
                                                       # reach its run phase first.
        let epD  = mkEp(fdir / "term_ignores.nim")    # D: live throughout, ignores
                                                       # SIGTERM — only SIGKILL kills it.

        var sigint2At = 0.0
        var dDoneAt   = 0.0
        proc onRes(r: EntrypointResult) =
          if string(r.ep.tp.display()).endsWith("term_ignores.nim"):
            dDoneAt = epochTime()

        let hook = proc(graph: var DepGraph; config: Config; ep: Entrypoint;
                        nimcacheDir, binaryName: string; protocolMajor: int;
                        index: SourceIndex; ccRun: RunProc): tuple[ok: bool, error: string] =
          if string(ep.tp.display()).endsWith("slow_compile.nim"):
            # D has had A's entire 3s+ compile floor to finish compiling and
            # start running (ignoring SIGTERM) — safely established by now.
            discard posix.kill(posix.getpid(), cint(SIGINT))   # first Ctrl-C
            os.sleep(30)
            sigint2At = epochTime()
            discard posix.kill(posix.getpid(), cint(SIGINT))   # second Ctrl-C,
                                                                 # queued before
                                                                 # this hook
                                                                 # returns —
                                                                 # `next()`'s
                                                                 # very first
                                                                 # drain-loop
                                                                 # poll sees it.
          recordClosure(graph, config, ep, nimcacheDir, binaryName, protocolMajor, index, ccRun)

        let cfg = baseCfg(jobs = 2)
        let p   = plan(cfg, @[epA, epD], emptyDepGraph())
        var g   = emptyDepGraph()
        # rfc-0007 code-review r7: `interruptedOut` ptr param is gone — read
        # `.interrupted` off the returned ExecuteReport instead.
        let execReport = execute(p, config = cfg, graph = g, onResult = onRes,
                                 showProgress = false, progressIntervalMs = 30_000,
                                 installSignals = true, recordClosureFn = hook)
        let interrupted = execReport.interrupted

        let deltaMs = if sigint2At > 0.0 and dDoneAt > 0.0: (dDoneAt - sigint2At) * 1000.0 else: -1.0
        writeFile(resultFile, $interrupted & "," & formatFloat(deltaMs, ffDecimal, 1))
        quit(0)

      let raw = waitChildResult(childPid, resultFile, 30.0)
      check raw.len > 0
      if raw.len > 0:
        let parts = raw.split(',')
        check parts.len == 2
        if parts.len == 2:
          check parts[0] == "true"       # the run really was interrupted
          let deltaMs = parts[1].parseFloat
          check deltaMs >= 0.0           # D actually finished (proves it was
                                          # observed dead at all)
          # Skip-grace forceKill: well under GracePeriodMs (400ms). A graced
          # requestStop against a SIGTERM-ignoring child only dies once
          # escalateExpired's poll notices the 400ms deadline has elapsed —
          # observed ~400-450ms pre-fix, comfortably above this threshold.
          check deltaMs < 250.0
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/integration/test_rfc0007_r5_drain_interrupt.nim"
    echo "test_rfc0007_r5_drain_interrupt: skipped (POSIX-only backend test)"
