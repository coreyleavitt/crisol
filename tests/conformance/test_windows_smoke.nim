## test_windows_smoke.nim — rfc-0007 A2d: the Windows cross-platform contract
## spike's smoke test. Proves process/windows.nim's real Win32 surface
## end-to-end on the three things the A2d bullet requires to be "genuinely
## functional" (as opposed to the honestly-degraded rest — see that
## module's header comment for the full list): spawn a child, observe its
## exit code losslessly, and kill a hanging child through the real kill
## domain (Job Object termination).
##
## Conformance-green is NOT required here (RFC-0009 gates that, Stage D) —
## this file is deliberately narrower than test_conformance.nim's nine
## items: it proves the backend is real where the bullet asks for real, and
## nothing more.
##
## Compile-time gated to `defined(windows)` — crisol.nimble's self-
## discovering test task finds every `test_*.nim` file under tests/
## regardless of host platform, so the `else` branch below must compile and
## exit cleanly on Linux/macOS too; only a `windows-latest` CI leg (or a
## real Windows host) ever executes the body. Imports `crisol/process`
## ONLY, via `./helpers` — never a backend module directly (enforced by
## test_conformance_import_purity.nim in this directory, same rule as every
## other file here).

when defined(windows):
  import std/[options, os, unittest, monotimes, times]
  import ./helpers

  let passBin = compileFixture("pass_always")
  let hangBin = compileFixture("hang_forever")

  suite "rfc-0007 A2d — windows smoke: spawn, exit code, Job Object kill":

    test "pass_always: real CreateProcessW spawn, losslessly observed exit code 0":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_smoke_pass")
      let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))
      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0
      check report.stop.isNone
      check report.killDomain == kdsJobObject   # real Job Object, not a placeholder
      removeFile(outPath)

    test "hang_forever: requestStop then a guaranteed Job Object forceKill":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_smoke_hang")
      let spec = ChildSpec(argv: @[hangBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      check sr.ok
      sv.requestStop(sr.id, krTimeout)
      # hang_forever never traps anything — on Windows the cooperative act
      # (CTRL_BREAK) is at best a maybe, gated on a REAL console-topology
      # probe (§3/§4), and may be honestly undeliverable in a CI runner's
      # process tree. This test does not assert which way that probe
      # lands — it proves the GUARANTEED path: force through the real Job
      # Object regardless of console topology.
      var ev = sv.next(getMonoTime() + initDuration(milliseconds = 500))
      if ev.kind != weChildExited:
        sv.forceKill(sr.id)
        ev = sv.next(getMonoTime() + initDuration(seconds = 10))
      check ev.kind == weChildExited   # never weDeadline — Job Object kill is unconditional
      let report = sv.reap(ev.id)
      check report.stop.isSome
      check report.exit.kind == ekExited   # our own runner-chosen code, < 0xC0000000 (§2)
      check report.killDomain == kdsJobObject
      removeFile(outPath)

  when isMainModule:
    echo "test_windows_smoke done"

else:
  when isMainModule:
    echo "test_windows_smoke: skipped (not windows)"
