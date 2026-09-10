## test_windows_memprobe.nim — rfc-0007 D2a-1: `groupRssBytes` is a REAL
## live sum on Windows (no longer the `none()` stub D1a left honestly
## degraded), and `globalShutdownSignal()` — the getter `crisol/signals`
## delegates onto — exists and compiles against this backend.
##
## `groupRssBytes` peer of test_conformance_forensics.nim (the cross-
## platform C1b file, which cannot cover Windows until this slice): same
## fixture (`rss_hog`), same poll-until-plausible discipline against CI
## noise (the 2026-09-10 macOS flake documented there applies here too —
## page residency and process-group-scan timing are never guaranteed by a
## fixed delay).
##
## `globalShutdownSignal` gets only a light liveness/compile proof here: a
## fresh process, no CTRL event ever sent, so `isNone` is the entire
## contract this case can honestly exercise. The getter's STAMPED path
## (gShutdownSignum written by ctrlHandlerProc) is already proven live by
## D1b-i's coopstop CTRL_BREAK-to-child tests and by `next()`'s `weShutdown`
## reading the same global — sending a console ctrl event to the test
## process itself would risk killing the test runner, so that path is
## deliberately not re-proven here.
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
  import std/[options, os, unittest, monotimes, times]
  import ./helpers
  import crisol/types
  import crisol/process/types as ptypes

  let rssHogBin = compileFixture("rss_hog")

  suite "rfc-0007 D2a-1 — windows memprobe: groupRssBytes is real, globalShutdownSignal exists":

    test "rss_hog: groupRssBytes live sum is plausible":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_memprobe_rss")
      let spec = ChildSpec(argv: @[rssHogBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      check sr.ok

      # rss_hog touches ~8 MiB then holds it for 1500ms before exiting.
      # Poll-until-plausible rather than sampling once after a fixed delay
      # (see test_conformance_forensics.nim's header for why a fixed delay
      # is unsound on a noisy CI runner).
      var rss = sv.groupRssBytes(sr.id)
      let sampleDeadline = getMonoTime() + initDuration(milliseconds = 1200)
      while getMonoTime() < sampleDeadline and
            not (rss.isSome and rss.get > 1 * 1024 * 1024):
        sleep(25)
        rss = sv.groupRssBytes(sr.id)

      let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
      check ev.kind == weChildExited
      discard sv.reap(ev.id)
      removeFile(outPath)

      check rss.isSome
      check rss.get > 1 * 1024 * 1024   # > 1 MiB — plausible for an 8 MiB touch, never fabricated

    test "globalShutdownSignal: none in a fresh process with no CTRL event sent":
      check globalShutdownSignal().isNone

  when isMainModule:
    echo "test_windows_memprobe done"

else:
  when isMainModule:
    echo "test_windows_memprobe: skipped (not windows)"
