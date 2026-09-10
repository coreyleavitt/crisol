## test_windows_containment.nim — rfc-0007 D1b-iii: the breakaway-containment
## proof + real ppid resolution, proven end-to-end through the real
## Supervisor. This is the LAST D1b sub-slice — it closes the two D1a
## honest-stub items `process/windows.nim`'s module header used to carry:
## `snapshotOnePid`'s `ppid = -1` ("not resolved this tier"), and
## `Evidence.escapees: @[]` ("breakaway/DETACHED_PROCESS discovery is D1b's
## job", i.e. genuinely undiscovered, not yet proven correct).
##
## Two load-bearing properties made live here, together, because the second
## depends on the same fixture as the first:
##   1. Breakaway is denied ⇒ the Job is a COMPLETE containment domain ⇒
##      `escapees == @[]` is HONEST, not a stub. `breakaway_attempt.nim`
##      actively ATTEMPTS `CREATE_BREAKAWAY_FROM_JOB` for a grandchild it
##      spawns — crisol's `spawnChild` never sets
##      `JOB_OBJECT_LIMIT_BREAKAWAY_OK`, so that attempt fails, the fixture
##      retries without breakaway, and the grandchild stays IN the Job. This
##      file asserts the grandchild shows up in `snapshotTree` (it did NOT
##      escape) and that `reap`'s `escapees` is still `@[]` after the whole
##      Job is force-killed — nothing to find because nothing ever left.
##   2. `ppid` is really resolved (no longer always `-1`), via
##      `CreateToolhelp32Snapshot` (`buildPpidMap`, process/windows.nim) —
##      proven by finding a real, nonzero ppid link between two members of
##      the SAME Job (the grandchild's ppid names the fixture's own pid),
##      never a hard-coded pid.
##
## Driven through the real Supervisor (process.nim's selection ladder via
## ./helpers, never the backend module directly — tests/conformance's own
## import-purity rule, test_conformance_import_purity.nim). Mirrors
## test_windows_coopstop.nim's `waitForMarker`/`driveToExit` shape: this
## needs a MID-FLIGHT interaction (snapshotTree while the child and its
## grandchild are still running), so it does not use
## `helpers.spawnAndWait`.
##
## Compile-time gated to `defined(windows)` (mirrors every other
## `test_windows_*.nim` file): the `else` branch must still compile and
## exit cleanly on Linux/macOS, since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file under tests/ regardless of host
## platform.

when defined(windows):
  import std/[os, sequtils, unittest, monotimes, times]
  import ./helpers

  let baBin = compileFixture("breakaway_attempt")

  proc waitForMarker(sv: var Supervisor; markerPath: string; deadline: MonoTime) =
    ## Polls `next` on short (50ms) deadlines, ignoring whatever it returns
    ## (only `weDeadline` is expected before the marker appears — no other
    ## child is in flight), until the fixture's ready-marker file exists.
    ## Mirrors test_windows_coopstop.nim exactly.
    while not fileExists(markerPath):
      doAssert getMonoTime() < deadline,
        "timed out waiting for ready marker: " & markerPath
      discard sv.next(getMonoTime() + initDuration(milliseconds = 50))

  proc driveToExit(sv: var Supervisor; deadline: MonoTime): WaitEvent =
    ## Drives `next` past any intermediate events until the child's exit is
    ## reported (level-triggered `weChildExited`, §1).
    result = sv.next(deadline)
    while result.kind != weChildExited:
      doAssert getMonoTime() < deadline, "timed out waiting for weChildExited"
      result = sv.next(deadline)

  suite "rfc-0007 D1b-iii — windows containment / ppid forensics":

    test "breakaway_attempt: grandchild stays contained; ppid resolved; escapees == @[]":
      var sv = initSupervisor(installSignals = false)
      let markerPath = tmpOutputFile("win_containment_marker")
      let outPath = tmpOutputFile("win_containment_out")
      let spec = ChildSpec(argv: @[baBin, markerPath], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      doAssert sr.ok, "spawn failed unexpectedly: " & (if sr.ok: "" else: sr.error)

      # The marker appears only after the fixture's breakaway attempt has
      # been resolved (denied, retried without breakaway, resumed) — see
      # breakaway_attempt.nim's header. By the time it exists, the
      # grandchild is up and genuinely contained.
      waitForMarker(sv, markerPath, getMonoTime() + initDuration(seconds = 10))
      removeFile(markerPath)

      let tree = sv.snapshotTree(sr.id)

      # Containment: BOTH the fixture (parent) and the grandchild it tried
      # to break away are in the SAME Job — the grandchild did NOT escape
      # despite attempting breakaway.
      check tree.len >= 2

      # ppid resolution: some entry's ppid genuinely names ANOTHER entry in
      # the same Job — a real, nonzero ppid link between two Job members
      # (the grandchild parented by the fixture). Never hard-coded to a
      # specific pid.
      var linked = false
      for a in tree:
        if a.ppid > 0:
          for b in tree:
            if b.pid == a.ppid:
              linked = true
      check linked

      # ppid resolution is live (not the D1a-era always-`-1` stub) for at
      # least the grandchild.
      check tree.anyIt(it.ppid != -1)

      # Teardown: force-kill the whole Job (parent + contained grandchild
      # together — the guaranteed kill path, independent of console
      # topology) and drive the report.
      sv.forceKill(sr.id)
      let ev = driveToExit(sv, getMonoTime() + initDuration(seconds = 10))
      let report = sv.reap(ev.id)
      removeFile(outPath)

      # Nothing escaped — the containment guarantee holds even under a
      # forced kill of a Job whose sole member actively tried to break away.
      check report.escapees.len == 0
      check report.tree == treeObservationFor(kdsJobObject)

  when isMainModule:
    echo "test_windows_containment done"

else:
  when isMainModule:
    echo "test_windows_containment: skipped (not windows)"
