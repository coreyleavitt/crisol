## test_windows_iocp.nim — rfc-0007 D1a: the completion-port `next` primary
## tier is live and correct, not a dormant path alongside the retired
## WaitForMultipleObjects-only tier.
##
## Latency-differential tests are unreliable on hosted CI runners (the C1b
## macOS lesson: CI noise dwarfs a small tick delta) — this asserts the
## FUNCTIONAL property instead, exactly as rfc-0007's D1a slice for the IOCP
## `next` specifies: "a child's exit is delivered promptly (far inside the
## deadline)... and correctness is unchanged (weChildExited -> reap -> right
## Exit)". `pass_fast` exits almost immediately; the deadline below (10s) is
## generous, so a pass well inside a much smaller bound (3s) proves the loop
## woke on the event rather than idling out anything resembling the old
## fixed-tick-only behavior, while staying robust to CI scheduling jitter.
##
## Every OTHER windows conformance spawn in this directory (test_windows_
## smoke, test_windows_ntstatus, test_windows_forensics, test_windows_sinks)
## also drives `next` through this SAME completion-port tier by construction
## (every Supervisor created via `initSupervisor` associates each spawn's Job
## with it) — this file is the one that makes the property explicit and
## pins it with an assertion, not the only place the tier is exercised.
##
## Driven through the real Supervisor (`process.nim`'s selection ladder via
## ./helpers), never the backend module directly — tests/conformance's own
## import-purity rule (test_conformance_import_purity.nim).
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[os, unittest, monotimes, times]
  import ./helpers

  let passFastBin = compileFixture("pass_fast")

  suite "rfc-0007 D1a — completion-port next: prompt and correct":

    test "pass_fast: weChildExited arrives promptly through the IOCP-backed next, exit is correct":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_iocp_passfast")
      let spec = ChildSpec(argv: @[passFastBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let start = getMonoTime()
      let (ev, report) = spawnAndWait(sv, spec, start + initDuration(seconds = 10))
      let elapsedMs = (getMonoTime() - start).inMilliseconds
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0
      check report.killDomain == kdsJobObject

      # "far inside the deadline" — generous headroom over CI noise, still
      # far below the 10s deadline the old poll-tick-only tier would have
      # needed to hit before ever reporting weDeadline.
      check elapsedMs < 3000

  when isMainModule:
    echo "test_windows_iocp done"

else:
  when isMainModule:
    echo "test_windows_iocp: skipped (not windows)"
