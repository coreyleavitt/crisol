## test_windows_coopstop.nim — rfc-0007 D1b-i: the real per-child CTRL_BREAK
## deliverability probe, proven end-to-end through the real Supervisor.
##
## Before this slice, `process/windows.nim`'s `cooperativeUnavailable` was a
## SUPERVISOR-GLOBAL stub (`not sv.consoleAttached`) — wrong at per-child
## granularity and with no live `true` producer anywhere in the suite. This
## file drives BOTH branches of the real probe (`consoleHasPid`, gated on
## `GetConsoleProcessList`) through the real `Supervisor` (process.nim's
## selection ladder via ./helpers, never the backend module directly —
## tests/conformance's own import-purity rule,
## test_conformance_import_purity.nim):
##   - `ctrl_break_handler` — attached to the console, so CTRL_BREAK is
##     genuinely deliverable: `requestStop` sends it, the fixture's handler
##     catches it and exits 0, `cooperativeUnavailable` stays false and
##     nothing escalates.
##   - `detach_console` — calls `FreeConsole` before it is ever probed, so
##     it is absent from `GetConsoleProcessList`: `requestStop` records
##     `cooperativeUnavailable: true` and sends no CTRL_BREAK at all, and
##     the only way to end it is `forceKill`.
##
## The classified `Outcome` is asserted through crisol/types.outcome(), the
## SAME pure derivation every trust boundary calls — not a hand-rolled
## predicate (mirrors test_windows_ntstatus.nim exactly).
##
## Needs a MID-FLIGHT interaction (requestStop while the child is still
## running), so this does NOT use `helpers.spawnAndWait` (runs a spec to
## completion with no stop act ever sent) — it drives `spawn`/`next`/
## `requestStop`/`forceKill`/`reap` directly, polling `next` on short
## deadlines (ignoring non-terminal events) until the fixture's ready
## marker file appears, exactly the shape `spawn_pgroup_child`'s driving
## test uses at the file-polling level, but through the Supervisor's own
## `next` instead of a bare `os.sleep` loop.
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim
## and test_windows_ntstatus.nim): the `else` branch must still compile and
## exit cleanly on Linux/macOS, since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file under tests/ regardless of host
## platform.

when defined(windows):
  import std/[options, os, unittest, monotimes, times]
  import ./helpers
  import crisol/types
  import crisol/process/types as ptypes

  let ctrlBreakBin = compileFixture("ctrl_break_handler")
  let detachBin    = compileFixture("detach_console")

  proc waitForMarker(sv: var Supervisor; markerPath: string; deadline: MonoTime) =
    ## Polls `next` on short (50ms) deadlines, ignoring whatever it returns
    ## (only `weDeadline` is expected before the marker appears — no other
    ## child is in flight), until the fixture's ready-marker file exists.
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

  proc outcomeFor(epPath: string; report: ReapReport): Outcome =
    ## Drives the REAL production outcome() derivation (crisol/types) over a
    ## minimal, honestly-populated EntrypointResult — exactly the shape the
    ## runner itself builds — not a hand-rolled equivalent (mirrors
    ## test_windows_ntstatus.nim).
    let ep = Entrypoint(path: epPath, group: "test", flags: @[])
    let cause = classifyCause(report.exit, report.stop, Limits(), report.limits)
    let evidence = Evidence(
      killDomain: report.killDomain,
      tree: treeObservationFor(report.killDomain),
      escapees: report.escapees,
      limits: report.limits,
      hermetic: hlNone,
      killSnapshot: report.killSnapshot,
      cooperativeUnavailable: report.cooperativeUnavailable,
    )
    let res = ProcessResult(exit: report.exit, cause: cause, evidence: evidence,
                             rusage: report.rusage, durationUs: 0)
    let r = EntrypointResult(ep: ep, compile: Phase(kind: pkSkipped),
                             run: Phase(kind: pkRan, res: res))
    outcome(r)

  suite "rfc-0007 D1b-i — windows cooperative stop / cooperativeUnavailable":

    test "ctrl_break_handler: attached child accepts CTRL_BREAK, not escalated":
      var sv = initSupervisor(installSignals = false)
      let markerPath = tmpOutputFile("win_coopstop_ok_marker")
      let outPath = tmpOutputFile("win_coopstop_ok_out")
      let spec = ChildSpec(argv: @[ctrlBreakBin, markerPath], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      doAssert sr.ok, "spawn failed unexpectedly: " & (if sr.ok: "" else: sr.error)

      waitForMarker(sv, markerPath, getMonoTime() + initDuration(seconds = 10))
      sv.requestStop(sr.id, krTimeout)

      let ev = driveToExit(sv, getMonoTime() + initDuration(seconds = 10))
      let report = sv.reap(ev.id)
      removeFile(markerPath)
      removeFile(outPath)

      check report.stop.isSome
      check report.stop.get.escalated == false
      check report.cooperativeUnavailable == false

      let cause = classifyCause(report.exit, report.stop, Limits(), report.limits)
      check cause.by == cbRunner

      check outcomeFor("tests/fixtures/ctrl_break_handler.nim", report) == oKilled

    test "detach_console: FreeConsole => cooperativeUnavailable, forced kill":
      var sv = initSupervisor(installSignals = false)
      let markerPath = tmpOutputFile("win_coopstop_detach_marker")
      let outPath = tmpOutputFile("win_coopstop_detach_out")
      let spec = ChildSpec(argv: @[detachBin, markerPath], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      doAssert sr.ok, "spawn failed unexpectedly: " & (if sr.ok: "" else: sr.error)

      waitForMarker(sv, markerPath, getMonoTime() + initDuration(seconds = 10))
      sv.requestStop(sr.id, krTimeout)   # probe finds it off-console: no ctrl event sent
      sv.forceKill(sr.id)

      let ev = driveToExit(sv, getMonoTime() + initDuration(seconds = 10))
      let report = sv.reap(ev.id)
      removeFile(markerPath)
      removeFile(outPath)

      check report.cooperativeUnavailable == true
      check report.stop.isSome
      check report.stop.get.escalated == false   # nothing to escalate from

      check outcomeFor("tests/fixtures/detach_console.nim", report) == oKilled

  when isMainModule:
    echo "test_windows_coopstop done"

else:
  when isMainModule:
    echo "test_windows_coopstop: skipped (not windows)"
