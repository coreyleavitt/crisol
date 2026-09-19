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
##  r58 (code-review, High) — the r5(b) skip-grace branch calls
##  `sv.forceKill` on every still-live slot with NO prior `requestStop`.
##  Both backends' "forceKill with no prior stop act recorded" fallback
##  (posixcore.nim's `forceKillCore`, windows.nim's `forceKill`) then
##  records `stop = (krTimeout, escalated: true)` — a FABRICATED timeout,
##  not the true interrupt authorship — because that fallback is meant for
##  a genuinely bare forceKill call, not this reachable "skip-grace during a
##  real interrupt drain" path. Consequences pinned below via the SAME r5(b)
##  double-SIGINT harness: a RUN-phase victim (D) keeps outcome `oKilled`
##  but its wire `Cause.reason` lies "timeout" instead of "interrupt"; a
##  MID-COMPILE victim (new entrypoint C, slow_compile2.nim — a longer,
##  8s `staticExec`-gated compile still genuinely live when A's shorter 3s
##  compile triggers the double SIGINT) is misreported as `oCompileFailed`
##  (types.nim's `outcome` maps compile-phase `cbRunner`+non-`krInterrupt`
##  to a compile failure, never `oKilled`) with a fabricated
##  "[compile timed out]" note (runner.nim's `finalizeSlot`, `spCompiling`
##  branch) instead of the true `oKilled`+"[interrupted]". RED before the
##  fix: D's `run.res.cause.reason` reads `krTimeout` and C's `outcome`
##  reads `compileFailed`.
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
##     r58 additionally: entrypoint C (slow_compile2.nim, an 8s
##     `staticExec`-gated compile — still genuinely mid-compile when A's
##     shorter 3s compile triggers the double SIGINT at ~3s) is a THIRD
##     concurrent sibling (jobs=3), so the same skip-grace forceKill sweep
##     also force-kills a live COMPILING child, not just D's live RUN
##     child. Assert D's `run.res.cause.reason` and C's `outcome` (via
##     `crisol/types.outcome`) directly off the emitted `EntrypointResult`s.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r5_drain_interrupt.nim

when defined(posix):
  import std/[options, os, posix, sets, strutils, times, unittest]
  import crisol/types
  import crisol/process/types as ptypes  # r58: Cause/KillReason field access
  import crisol/depgraph
  import crisol/closure   # SourceIndex, buildSourceIndex
  import crisol/ccprobe   # RunProc
  import crisol/runner
  import crisol/cachedispatch  # r35: cacheEnabled/defaultCachePolicy/CacheSeams
  import crisol/sandbox        # r35: resolveSandbox/hlIsolated
  import crisol/resultcache    # r35: CachedResult
  import "../support/testep"
  import "../support/helpers"  # r35: legacySeams

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
        let epC  = mkEp(fdir / "slow_compile2.nim")   # C: r58 — an 8s compile, still
                                                       # genuinely mid-compile (live) when
                                                       # A's 3s compile triggers the
                                                       # double SIGINT — the mid-compile
                                                       # skip-grace victim.
        let epD  = mkEp(fdir / "term_ignores.nim")    # D: live throughout, ignores
                                                       # SIGTERM — only SIGKILL kills it.

        var sigint2At = 0.0
        var dDoneAt   = 0.0
        var dRes, cRes: Option[EntrypointResult]
        proc onRes(r: EntrypointResult) =
          if string(r.ep.tp.display()).endsWith("term_ignores.nim"):
            dDoneAt = epochTime()
            dRes = some(r)
          elif string(r.ep.tp.display()).endsWith("slow_compile2.nim"):
            cRes = some(r)

        let hook = proc(graph: var DepGraph; config: Config; ep: Entrypoint;
                        nimcacheDir, binaryName: string; protocolMajor: int;
                        index: SourceIndex; ccRun: RunProc): tuple[ok: bool, error: string] =
          if string(ep.tp.display()).endsWith("slow_compile.nim"):
            # D has had A's entire 3s+ compile floor to finish compiling and
            # start running (ignoring SIGTERM) — safely established by now.
            # C (slow_compile2.nim, 8s floor) is still genuinely compiling.
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

        let cfg = baseCfg(jobs = 3)
        let p   = plan(cfg, @[epA, epC, epD], emptyDepGraph())
        var g   = emptyDepGraph()
        # rfc-0007 code-review r7: `interruptedOut` ptr param is gone — read
        # `.interrupted` off the returned ExecuteReport instead.
        let execReport = execute(p, config = cfg, graph = g, onResult = onRes,
                                 showProgress = false, progressIntervalMs = 30_000,
                                 installSignals = true, recordClosureFn = hook)
        let interrupted = execReport.interrupted

        let deltaMs = if sigint2At > 0.0 and dDoneAt > 0.0: (dDoneAt - sigint2At) * 1000.0 else: -1.0

        # r58: D's RUN-phase kill authorship — must be the real interrupt,
        # never the skip-grace fallback's fabricated timeout.
        let dReason =
          if dRes.isSome and dRes.get.run.kind == ptypes.pkRan and
             dRes.get.run.res.cause.by == ptypes.cbRunner:
            $dRes.get.run.res.cause.reason
          else: "missing"

        # r58: C's COMPILE-phase outcome — must be oKilled (honest interrupt),
        # never oCompileFailed (the fabricated-timeout misclassification).
        let cOutcome = if cRes.isSome: types.outcomeString(outcome(cRes.get)) else: "missing"

        writeFile(resultFile, $interrupted & "," & formatFloat(deltaMs, ffDecimal, 1) &
                              "," & dReason & "," & cOutcome)
        quit(0)

      let raw = waitChildResult(childPid, resultFile, 30.0)
      check raw.len > 0
      if raw.len > 0:
        let parts = raw.split(',')
        check parts.len == 4
        if parts.len == 4:
          check parts[0] == "true"       # the run really was interrupted
          let deltaMs = parts[1].parseFloat
          check deltaMs >= 0.0           # D actually finished (proves it was
                                          # observed dead at all)
          # Skip-grace forceKill: well under GracePeriodMs (400ms). A graced
          # requestStop against a SIGTERM-ignoring child only dies once
          # escalateExpired's poll notices the 400ms deadline has elapsed —
          # observed ~400-450ms pre-fix, comfortably above this threshold.
          check deltaMs < 250.0
          # r58: skip-grace forceKill must not misauthor the kill reason.
          # D's RUN-phase Cause.reason must be the real interrupt, not the
          # forceKill-with-no-prior-stop fallback's fabricated "timeout".
          check parts[2] == "krInterrupt"
          # r58: C's mid-compile skip-grace kill must derive the honest
          # oKilled outcome, never oCompileFailed (which only the fabricated
          # timeout reason produces — see types.nim's `outcome`).
          check parts[3] == "killed"

  suite "r35 — an interrupted RUN-phase final carries the same already-known facts as a live finalize":
    ## code-review r35 (Low): the `handleChildExited` template's `shuttingDown`
    ## branch (runner.nim, the `fkDone` case) fires `onResult` for an
    ## interrupt-killed final WITHOUT ever running the retry/ledger/cache/
    ## promotion machinery below it (§2 pins that: an interrupted final is
    ## never ledgered or persisted). Pre-fix, it ALSO never stamped the
    ## reporting-only facts that machinery would otherwise apply — leaving a
    ## genuinely-consulted result reading as "cache not eligible"/"not
    ## quarantined" purely because it happened to die mid-run rather than
    ## finish. This suite proves those three facts (cacheDecision/inputHash,
    ## attempts, quarantined) now survive onto the emitted victim.
    ##
    ## Strategy: build a REAL edRunFresh entrypoint (a first pass whose run
    ## phase deliberately times out — the compile still succeeds, so the
    ## closure records and the binary still promotes to the stable path,
    ## exactly like a genuine timeout would in production) so the SECOND
    ## pass's plan-time cache consult is the real `lookupAtPlan` path (a
    ## cache MISS — cdmKeyMiss + a real inputHash), not the structural
    ## `cdmNotEligible` a still-compiling entry gets. A background signaler
    ## process (a second `fork()`, independent of the compile-hook trick the
    ## r5(a)/r5(b) suites use above — an edRunFresh dispatch never compiles,
    ## so there is no compile hook to fire from) delivers the real SIGINT a
    ## fixed, generously-margined delay after the second pass starts, well
    ## inside its `hang.nim` run child's lifetime.

    test "SIGINT mid-run on an edRunFresh entry stamps the real plan-time cacheDecision/inputHash and quarantine overlay":
      let tag        = "crisol_r35_" & $getpid()
      let resultFile = getTempDir() / (tag & "_result")
      if fileExists(resultFile): removeFile(resultFile)
      defer: (try: removeFile(resultFile) except: discard)

      let childPid = fork()
      check childPid >= 0

      if childPid == 0:
        let root = getTempDir() / ("crisol_r35_root_" & $getpid())
        createDir(root)
        createDir(root / ".crisol")
        writeFile(root / "hang.nim", "import os\nwhile true:\n  os.sleep(1000)\n")
        let ep = testEp("hang.nim", group = "default", flags = @[])

        var graph = initDepGraph("")
        doAssert saveDepGraph(graph, Config(projectRoot: root, stateDir: ".crisol"))

        let trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), "")

        # Pass 1: a short run timeout so `hang.nim`'s run child is killed by
        # the ordinary timeout path — compile succeeds either way, so the
        # closure records and the binary promotes to the stable path exactly
        # as decideExit's `promoteBinary` (oKilled is NOT in its exclusion
        # set) already documents.
        let cfg1 = Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
                          timeoutSecs: 1, compileTimeoutSecs: 60,
                          maxOutputBytes: 65_536, trackedRoots: trackedRoots)
        let plan1 = plan(cfg1, @[ep], graph, nimVersion = "")
        check plan1.entrypoints[0].edecision == edNeverBuilt
        discard execute(plan1, config = cfg1, graph = graph, nimVersion = "",
                        showProgress = false)

        # Pass 2 must now see a stable binary + matching closure: edRunFresh.
        let plan2 = plan(cfg1, @[ep], graph, nimVersion = "")
        check plan2.entrypoints[0].edecision == edRunFresh

        # A real, active cache — `load` always misses, so `lookupAtPlan`
        # takes the genuine `cdmKeyMiss` branch (a real consult, a real
        # inputHash) rather than any zero-value placeholder.
        let cache = cacheEnabled(resolveSandbox(hlIsolated), defaultCachePolicy(),
          legacySeams(
            keyOf = proc(pep: PlannedEntrypoint): SoundnessKey =
                     SoundnessKey("r35key-" & string(pep.ep.tp.display())),
            load  = proc(key: SoundnessKey): Option[CachedResult] = none(CachedResult),
            store = proc(key: SoundnessKey; res: CachedResult): bool = true,
          ))

        # B3 whole-binary quarantine, keyed directly off this entrypoint's
        # own TrackedPath — the same identity `isQuarantined` matches against.
        let cfg2 = Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
                          timeoutSecs: 30, compileTimeoutSecs: 60,
                          maxOutputBytes: 65_536, trackedRoots: trackedRoots,
                          quarantineTp: [ep.tp].toHashSet)

        var victim: Option[EntrypointResult]
        proc onRes(r: EntrypointResult) =
          if string(r.ep.tp.display()).endsWith("hang.nim"):
            victim = some(r)

        # Independent signaler: an edRunFresh dispatch never compiles, so
        # there is no compile-success hook to fire the interrupt from (unlike
        # r5(a)/r5(b) above) — a second, unrelated `fork()` sleeps past the
        # point pass 2's single run child is genuinely live, then signals
        # THIS process (captured before forking) directly.
        let selfPid   = posix.getpid()
        let sigPid    = fork()
        check sigPid >= 0
        if sigPid == 0:
          os.sleep(800)
          discard posix.kill(selfPid, cint(SIGINT))
          quit(0)

        let execReport = execute(plan2, config = cfg2, graph = graph, nimVersion = "",
                                 onResult = onRes, showProgress = false,
                                 progressIntervalMs = 30_000, installSignals = true,
                                 cache = cache)
        # Reap the signaler so it doesn't linger as a zombie past this quit(0).
        var wstatus: cint = 0
        discard waitpid(sigPid, wstatus, 0)

        let interrupted = execReport.interrupted
        let hasVictim   = victim.isSome
        let cacheOk     = hasVictim and victim.get.cacheDecision == cdmKeyMiss
        let hashOk      = hasVictim and victim.get.inputHash.len > 0
        let attemptsOk  = hasVictim and victim.get.attempts == 1
        let quarOk      = hasVictim and victim.get.quarantined

        writeFile(resultFile, $interrupted & "," & $hasVictim & "," & $cacheOk &
                              "," & $hashOk & "," & $attemptsOk & "," & $quarOk)
        removeDir(root)
        quit(0)

      let raw = waitChildResult(childPid, resultFile, 30.0)
      check raw.len > 0
      if raw.len > 0:
        let parts = raw.split(',')
        check parts.len == 6
        if parts.len == 6:
          check parts[0] == "true"   # the run really was interrupted
          check parts[1] == "true"   # the victim was actually emitted (never ledgered — just observed via onResult)
          # r35(a): the real plan-time cacheDecision/inputHash survive onto
          # the interrupted final — never left at the cdmNotEligible/""
          # not-consulted zero value despite the genuine consult above.
          check parts[2] == "true"
          check parts[3] == "true"
          # r35(b): the real attempt number (1 — no retry involved here)
          # survives onto the interrupted final.
          check parts[4] == "true"
          # r35(c): the quarantine overlay is applied before onResult fires,
          # exactly like the live-finalize path.
          check parts[5] == "true"

else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/integration/test_rfc0007_r5_drain_interrupt.nim"
    echo "test_rfc0007_r5_drain_interrupt: skipped (POSIX-only backend test)"
