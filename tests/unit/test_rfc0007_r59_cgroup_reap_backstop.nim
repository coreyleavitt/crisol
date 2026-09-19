## test_rfc0007_r59_cgroup_reap_backstop.nim — rfc-0007 code-review finding
## r59: `reapCore`'s cgroup normal-exit reap arm had no killpg backstop and
## no fallback when the leaf read came back empty.
##
## Pre-fix, `reapCore`'s cgroup arm (posixcore.nim) got escapee accounting
## ONLY from `cgroupLeafSurvivors`, and skipped `discoverAndReapEscapees`
## (the pgid/ppid scan) ENTIRELY whenever a leaf existed — unlike
## `forceKillCore`, which r10 already gave a `killpg` backstop. A
## leaf-escaped-but-pgid-visible daemon (a same-uid child that migrated
## itself out of the leaf under delegation's common-ancestor rule, or a
## `cgroup.kill` write that failed at runtime) survived unkilled while the
## report still stamped `kdsCgroup`-or-degraded + `tree=toComplete` +
## `escapees=[]` from a scan that never ran — note the asymmetry against
## `killSnapshotFor` (posixcore.nim), which ALREADY falls back to the pgid
## scan on an empty leaf read.
##
## The fix, in `reapCore`'s cgroup arm:
##   (a) an unconditional `killpg` backstop, mirroring `forceKillCore`'s
##       own r10 fix.
##   (b) `cgroupEscapeeFallbackNeeded` — the pure trigger for also running
##       `discoverAndReapEscapees` (the pgid/ppid scan) and merging its
##       result into `escapees` via `mergeEscapeesByPid` (dedupe-by-pid).
##
## Covered here, unit-level (both pure decision helpers, plus the REAL
## `cgroupLeafSurvivors` empty-vs-nonempty read feeding into the decision,
## via the same fake-`cgroup.procs`-file pattern r12's test already
## established — no real cgroup-v2 delegation needed for any of this):
##   1. `cgroupEscapeeFallbackNeeded`'s full truth table.
##   2. `mergeEscapeesByPid`'s dedupe-by-pid behavior.
##   3. `cgroupLeafSurvivors` against a fake leaf (plain temp dir standing
##      in for a real cgroup-v2 leaf) feeding real empty/nonempty counts
##      into `cgroupEscapeeFallbackNeeded`, tying the two together the way
##      `reapCore` actually does.
##
## What only the CI `cgroup` job can prove: that a REAL delegated leaf, a
## REAL same-uid child that migrates itself out of the leaf (or a REAL
## `cgroup.kill` write failure), and a live `reapCore` call actually
## produce the merged escapees + a killed daemon end-to-end. This repo's
## rootless-container environment has no cgroup-v2 delegation at all (no
## `/sys/fs/cgroup` sibling to place a leaf under), so `cgroupTierUsable`
## is always false here and `reapCore`'s cgroup arm never even engages —
## the same "genuine, currently-unpinned CI-leg gap" posture
## test_rfc0007_r10_cgroup_kill_degrade.nim's own header already documents
## for the sibling `killCgroupLeaf`-write-failure case. This file pins the
## pure decision logic (proven below) and the real leaf-read half of it
## (also proven below); it does NOT and cannot prove the live merge or the
## `killpg` backstop actually reaching a real leaf-escaped daemon.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim

when defined(posix):
  import std/unittest
  import crisol/process/types
  import crisol/process/posixcore

  suite "rfc-0007 r59 — cgroupEscapeeFallbackNeeded: pure trigger, full truth table":

    test "empty leaf + clean exit (no stop requested) -> no fallback (an empty leaf IS honest evidence here)":
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 0, stopRequested = false,
                                         cgroupKillWriteFailed = false) == false

    test "empty leaf + non-clean exit (stop was requested) -> fallback needed (the r59 fix's core case)":
      ## THE regression this finding closes: pre-fix, an empty leaf read on
      ## a killed/stopped slot was silently trusted as "nothing survived" —
      ## exactly the case a same-uid child could have fled the leaf before
      ## this reap's own read.
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 0, stopRequested = true,
                                         cgroupKillWriteFailed = false) == true

    test "non-empty leaf + clean exit + write did not fail -> no fallback":
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 3, stopRequested = false,
                                         cgroupKillWriteFailed = false) == false

    test "non-empty leaf + non-clean exit -> no fallback purely from that (leaf already saw survivors)":
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 2, stopRequested = true,
                                         cgroupKillWriteFailed = false) == false

    test "cgroup.kill write failed -> fallback needed regardless of leaf count or stop state":
      ## The write-failure half is unconditional: the leaf's own teardown
      ## mechanism never fired, so the pgid scan is the only other
      ## observation this reap has, no matter what the leaf read showed.
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 0, stopRequested = false,
                                         cgroupKillWriteFailed = true) == true
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 5, stopRequested = false,
                                         cgroupKillWriteFailed = true) == true
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 5, stopRequested = true,
                                         cgroupKillWriteFailed = true) == true

  suite "rfc-0007 r59 — mergeEscapeesByPid: dedupe-by-pid union":

    test "disjoint pid sets: both are kept":
      let primary = @[ProcSnapshot(pid: 100, ppid: 1, command: "a", rssBytes: 0)]
      let fallback = @[ProcSnapshot(pid: 200, ppid: 1, command: "b", rssBytes: 0)]
      let merged = mergeEscapeesByPid(primary, fallback)
      check merged.len == 2
      check merged[0].pid == 100
      check merged[1].pid == 200

    test "a pid present in both is counted exactly once, primary's copy wins":
      let primary = @[ProcSnapshot(pid: 100, ppid: 1, command: "leaf-view", rssBytes: 10)]
      let fallback = @[ProcSnapshot(pid: 100, ppid: 1, command: "pgid-view", rssBytes: 999)]
      let merged = mergeEscapeesByPid(primary, fallback)
      require merged.len == 1
      check merged[0].pid == 100
      check merged[0].command == "leaf-view"

    test "empty fallback: primary passes through unchanged":
      let primary = @[ProcSnapshot(pid: 7, ppid: 1, command: "x", rssBytes: 0)]
      check mergeEscapeesByPid(primary, @[]) == primary

    test "empty primary: fallback passes through unchanged":
      let fallback = @[ProcSnapshot(pid: 7, ppid: 1, command: "x", rssBytes: 0)]
      check mergeEscapeesByPid(@[], fallback) == fallback

  when defined(linux):
    import std/os

    suite "rfc-0007 r59 — cgroupLeafSurvivors feeding the real fallback decision (fake leaf, r12's pattern)":

      test "an empty cgroup.procs (nothing resident) combined with a non-clean exit triggers the fallback":
        let dir = getTempDir() / ("crisol_r59_empty_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", "")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 0
        check cgroupEscapeeFallbackNeeded(leafEscapees.len, stopRequested = true,
                                           cgroupKillWriteFailed = false) == true

      test "a leaf with real content (our own pid) does not trigger the fallback on its own":
        let dir = getTempDir() / ("crisol_r59_nonempty_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", $getCurrentProcessId() & "\n")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 1
        check cgroupEscapeeFallbackNeeded(leafEscapees.len, stopRequested = true,
                                           cgroupKillWriteFailed = false) == false

  when isMainModule:
    echo "test_rfc0007_r59_cgroup_reap_backstop: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim"
    echo "test_rfc0007_r59_cgroup_reap_backstop: skipped (POSIX-only backend test)"
