## test_rfc0007_r2_cross_slot_escapee.nim — rfc-0007 code-review finding r2:
## cross-slot escapee kill/misattribution.
##
## `discoverAndReapEscapees`'s candidate filter admitted, via its
## ppid==ownPid arm, a reparented (double-forked) descendant of a
## DIFFERENT, still-running slot whose helper never called
## setpgid/setsid — it kept its OWN slot's pgid the whole time. A fast
## peer slot's reap would SIGKILL that legitimate helper mid-run and
## stamp it into the PEER's escapees evidence instead of the owning
## slot's.
##
## Two entrypoints run concurrently (jobs=2, shared scratch dir):
##   - spawn_reparented_helper.nim ("A", slow): double-forks a grandchild
##     that reparents to crisol but keeps A's own pgid, then waits for the
##     peer's done marker (+ buffer) before exiting — so A's own slot stays
##     registered/live across the peer's ENTIRE run+reap, the precondition
##     the bug needs.
##   - spawn_reparented_helper_peer.nim ("B", fast): writes its done marker
##     and exits immediately — B's reap-phase discoverAndReapEscapees runs
##     while A is still live.
##
## Proof: B's evidence carries NO escapees (the fixed cross-slot exclusion
## keeps B's reap off A's still-live pgid domain) and A's evidence DOES
## carry the escapee (A's own later reap correctly finds and kills its own
## helper via the direct pgid match).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r2_cross_slot_escapee.nim

when defined(linux):
  import std/[options, os, posix, strutils, unittest]
  import crisol/[types, runner, planner, depgraph, sandbox, cachedispatch]
  import crisol/process
  import crisol/process/types as ptypes
  import "../support/testep"

  proc escapeeMechanismsAvailable(): bool =
    ## Same gate test_rfc0007_a6a_escapee_evidence.nim uses: the cross-slot
    ## exclusion this test pins only engages on the real subreaper+pidfd
    ## tier (Linux) — see that test file's own doc comment for why.
    let caps = capabilities()
    caps.subreaper and caps.pidfd

  proc fixtureDir(): string =
    let thisFile = currentSourcePath()
    let testsDir = thisFile.parentDir.parentDir
    testsDir / "fixtures"

  proc killIfMarked(dir, markerName: string) =
    ## Teardown: the helper's grandchild is orphaned by construction (its
    ## immediate parent already exited), so this test process is never its
    ## real parent and cannot wait() it — a direct SIGKILL by pid (read
    ## from the marker the fixture itself writes) is the correct cleanup.
    let markerPath = dir / markerName
    if fileExists(markerPath):
      try:
        let pid = parseInt(readFile(markerPath).strip())
        if pid > 0: discard posix.kill(Pid(pid), SIGKILL)
      except CatchableError:
        discard

  suite "rfc-0007 r2 — cross-slot escapee kill/misattribution":

    test "fast peer's reap never claims the other slot's still-live pgid-preserving helper":
      if not escapeeMechanismsAvailable():
        skip()
      else:
        let isoSpec = resolveSandbox(hlIsolated)
        let dir = getTempDir() / ("crisol_r2_" & $getCurrentProcessId())
        removeDir(dir); createDir(dir)
        defer:
          killIfMarked(dir, "spawn_reparented_helper_g.pid")
          removeDir(dir)

        let slowFixt = dir / "test_r2_slow.nim"
        let fastFixt = dir / "test_r2_fast.nim"
        writeFile(slowFixt, readFile(fixtureDir() / "spawn_reparented_helper.nim"))
        writeFile(fastFixt, readFile(fixtureDir() / "spawn_reparented_helper_peer.nim"))

        let pepSlow = PlannedEntrypoint(
          ep: testEp(extractFilename(slowFixt), group = "unit", flags = @[]),
          edecision: edNeverBuilt, runTimeoutMs: 60_000)
        let pepFast = PlannedEntrypoint(
          ep: testEp(extractFilename(fastFixt), group = "unit", flags = @[]),
          edecision: edNeverBuilt, runTimeoutMs: 60_000)
        let p = RunPlan(entrypoints: @[pepSlow, pepFast], jobs: 2)
        var g = emptyDepGraph()
        let results = execute(
          p, config = Config(projectRoot: dir, stateDir: ".crisol",
                             compileTimeoutSecs: 120, timeoutSecs: 60,
                             trackedRoots: initTrackedRoots(dir, newSeq[tuple[name, native: string]](), ".crisol")),
          graph = g, showProgress = false,
          cache = cacheDisabled(isoSpec)).results
        check results.len == 2

        var slowResult, fastResult: Option[EntrypointResult]
        for r in results:
          if r.ep.tp.display() == "test_r2_slow.nim": slowResult = some(r)
          elif r.ep.tp.display() == "test_r2_fast.nim": fastResult = some(r)
        require slowResult.isSome
        require fastResult.isSome

        let rSlow = slowResult.get
        let rFast = fastResult.get
        require rSlow.run.kind == ptypes.pkRan
        require rFast.run.kind == ptypes.pkRan
        check rSlow.outcome == oPassed
        check rFast.outcome == oPassed

        let evSlow = rSlow.run.res.evidence
        let evFast = rFast.run.res.evidence

        # The r2 bug: this used to be 1 — the peer's fast reap stole A's
        # still-live daemonized helper and stamped it as B's own escapee.
        check evFast.escapees.len == 0
        # A's own later reap correctly discovers and kills its own helper
        # (direct pgid match — unaffected by the fix, this is the positive
        # case the exclusion must not break).
        require evSlow.escapees.len == 1
        check evSlow.escapees[0].pid > 0
        let escapeePid = evSlow.escapees[0].pid
        let rc = posix.kill(Pid(escapeePid), 0.cint)
        check rc == -1
        check errno == ESRCH   # actually reaped, not merely un-waited

  echo "test_rfc0007_r2_cross_slot_escapee: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r2_cross_slot_escapee.nim"
    echo "test_rfc0007_r2_cross_slot_escapee: skipped (POSIX-only backend test)"
