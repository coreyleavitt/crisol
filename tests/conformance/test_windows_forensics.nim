## test_windows_forensics.nim — rfc-0007 D1a: `snapshotTree` forensics are
## REAL, not a shape the wire happens to carry. The C1b libproc peer of this
## file is test_conformance_forensics.nim; this one is windows-gated rather
## than folded into that shared file because D1a deliberately leaves
## `groupRssBytes` degraded (`none()` — D2's job, the live-sum sampler needs
## psapi walked on a 25ms cadence) while `snapshotTree` becomes real — the
## cross-platform file asserts BOTH are real together, which does not hold
## here yet.
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
  import std/[os, strutils, unittest, monotimes, times]
  import ./helpers

  let rssHogBin = compileFixture("rss_hog")

  suite "rfc-0007 D1a — windows forensics: snapshotTree is real":

    test "rss_hog: snapshotTree reports the child's real pid, image name, and rssBytes":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_forensics_rss")
      let spec = ChildSpec(argv: @[rssHogBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      check sr.ok

      # rss_hog touches ~8 MiB then holds it for 150ms before exiting (same
      # fixture the C1b/C5 forensics tests use) — sample mid-hold, while
      # the allocation and the process are both still live.
      sleep(60)
      let tree = sv.snapshotTree(sr.id)

      let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
      check ev.kind == weChildExited
      discard sv.reap(ev.id)
      removeFile(outPath)

      require tree.len == 1
      check tree[0].pid > 0
      check "rss_hog" in tree[0].command
      check tree[0].rssBytes > 0

  when isMainModule:
    echo "test_windows_forensics done"

else:
  when isMainModule:
    echo "test_windows_forensics: skipped (not windows)"
