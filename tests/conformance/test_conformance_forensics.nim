## test_conformance_forensics.nim — rfc-0007 C1b: process-group forensics
## (`groupRssBytes` / `snapshotTree`) are REAL on every backend this suite
## proves against, not merely a shape the wire happens to carry.
##
## Before C1b, macOS routed through `process/posix.nim`'s generic poll/`/proc`
## fallback — macOS has no `/proc` at all, so `walkProcTable`/`readVmRssBytes`
## returned honestly empty/zero there (never fabricated, but never REAL
## either). This pins the live values every platform this suite runs on must
## now produce: Linux via `/proc` (unchanged), Darwin via libproc
## (`process/posixcore.nim`'s `when defined(macosx):` branches, born this
## slice).
##
## Driven through the real Supervisor (`process.nim`'s selection ladder),
## never a backend module directly — tests/conformance's own import-purity
## rule (test_conformance_import_purity.nim).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_conformance_forensics.nim

import std/[os, strutils, unittest, monotimes, times, options]
import ./helpers

let rssHogBin = compileFixture("rss_hog")

suite "conformance — process forensics: groupRssBytes/snapshotTree are real":

  test "rss_hog: live RSS sample is plausible and the tree carries the child's real command":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("forensics_rss")
    let spec = ChildSpec(argv: @[rssHogBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok

    # rss_hog touches ~8 MiB then holds it (see rss_hog.nim) before exiting
    # (the same fixture C5's ledger-rssBytes test uses). Poll-until-plausible
    # rather than sampling once after a fixed delay: on a noisy CI runner the
    # child's pages are not necessarily resident — nor is the child even
    # scheduled into the process-group scan — by any fixed instant (the
    # 2026-09-10 macOS flake, where a single 60ms sample saw <1 MiB and an
    # empty tree). The fixture's hold is wide enough that a good sample is
    # available within this bounded window on any backend.
    var rss = sv.groupRssBytes(sr.id)
    var tree = sv.snapshotTree(sr.id)
    let sampleDeadline = getMonoTime() + initDuration(milliseconds = 1200)
    while getMonoTime() < sampleDeadline and
          not (rss.isSome and rss.get > 1 * 1024 * 1024 and
               tree.len == 1 and "rss_hog" in tree[0].command):
      sleep(25)
      rss = sv.groupRssBytes(sr.id)
      tree = sv.snapshotTree(sr.id)

    let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    discard sv.reap(ev.id)
    removeFile(outPath)

    check rss.isSome
    check rss.get > 1 * 1024 * 1024   # > 1 MiB — plausible for an 8 MiB touch, never fabricated
    require tree.len == 1
    check "rss_hog" in tree[0].command
    check tree[0].rssBytes > 0

when isMainModule:
  echo "test_conformance_forensics done"
