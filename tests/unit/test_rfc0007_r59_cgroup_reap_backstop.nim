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
## The ORIGINAL fix, in `reapCore`'s cgroup arm:
##   (a) an unconditional `killpg` backstop, mirroring `forceKillCore`'s
##       own r10 fix.
##   (b) `cgroupEscapeeFallbackNeeded` — the pure trigger for also running
##       `discoverAndReapEscapees` (the pgid/ppid scan) and merging its
##       result into `escapees` via `mergeEscapeesByPid` (dedupe-by-pid).
##
## rfc-0007 code-review r71 (triple-lens-convergent) found (a) itself was a
## pid-reuse hazard: by the time `reapCore`'s cgroup arm runs,
## `entry.state == csExited` ALWAYS (the proc's own leading `doAssert`
## enforces it) — the leader's zombie is already `wait4`-consumed, so its
## pid is recyclable, and crisol's own `setpgid(child, child)` means a
## wrapped pid landing on the NEXT spawned slot's child turns this
## `killpg` into a kill of an unrelated sibling (or any unrelated same-uid
## process group). (a) is DELETED outright — the raw, non-identity-checked
## kill this file used to pin is gone. The invisible-survivor case now
## routes ONLY through (b), `discoverAndReapEscapees`'s identity-checked
## fallback (`pidfd_open` + starttime re-verify before ever killing
## anything — the discipline the rest of this file's kill paths already
## use). To keep closing the hole `killpg` used to cover without it,
## `cgroupEscapeeFallbackNeeded`'s trigger is WIDENED: an empty leaf read
## (`leafEscapeeCount == 0`) now triggers the fallback UNCONDITIONALLY,
## not just when `stopRequested` — `cgroupLeafSurvivors` cannot tell "the
## leaf genuinely holds nothing" from "something already fled it" (see
## that proc's own doc comment), and r71 named the ORIGINAL r59 scenario
## itself (a leaf-evaded daemon) as reachable on a perfectly CLEAN exit,
## not only a stopped/killed one — the old `stopRequested` gate on the
## empty-leaf case was never sound. `stopRequested` alone (independent of
## leaf count) also now triggers on its own: a forced/stopped teardown is
## exactly the case a same-uid child could have fled the leaf onto the
## pgid before this reap's own leaf read, whether or not that read
## happened to still come back non-empty. New trigger:
## `stopRequested or leafEscapeeCount == 0 or cgroupKillWriteFailed` — the
## ONLY remaining fast path (no extra scan) is a demonstrably NON-empty
## leaf read on a clean, non-stopped, non-write-failed exit. Accepted
## cost, documented honestly: most single-process, no-descendant spawns
## have an EMPTY leaf by the time `reapCore` runs regardless of whether
## anything escaped (the leader itself already left), so this fast path
## covers only slots with genuine surviving leaf descendants — the
## bounded O(nprocs) `discoverAndReapEscapees` scan now runs far more
## often than pre-r71. Correctness (never a raw, non-identity-checked
## kill) was judged to dominate that cost.
##
## Covered here, unit-level (both pure decision helpers, plus the REAL
## `cgroupLeafSurvivors` empty-vs-nonempty read feeding into the decision,
## via the same fake-`cgroup.procs`-file pattern r12's test already
## established — no real cgroup-v2 delegation needed for any of this):
##   1. `cgroupEscapeeFallbackNeeded`'s full truth table (r71: updated).
##   2. `mergeEscapeesByPid`'s dedupe-by-pid behavior.
##   3. `cgroupLeafSurvivors` against a fake leaf (plain temp dir standing
##      in for a real cgroup-v2 leaf) feeding real empty/nonempty counts
##      into `cgroupEscapeeFallbackNeeded`, tying the two together the way
##      `reapCore` actually does.
##
## What only the CI `cgroup` job can prove: that a REAL delegated leaf, a
## REAL same-uid child that migrates itself out of the leaf (or a REAL
## `cgroup.kill` write failure), and a live `reapCore` call actually
## produce the merged escapees + a killed daemon end-to-end via the
## identity-checked pgid scan. This repo's rootless-container environment
## has no cgroup-v2 delegation at all (no `/sys/fs/cgroup` sibling to
## place a leaf under), so `cgroupTierUsable` is always false here and
## `reapCore`'s cgroup arm never even engages — the same "genuine,
## currently-unpinned CI-leg gap" posture
## test_rfc0007_r10_cgroup_kill_degrade.nim's own header already documents
## for the sibling `killCgroupLeaf`-write-failure case. This file pins the
## pure decision logic (proven below) and the real leaf-read half of it
## (also proven below); it does NOT and cannot prove the live merge
## actually reaching a real leaf-escaped daemon end-to-end.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim

when defined(posix):
  import std/unittest
  import crisol/process/types
  import crisol/process/posixcore

  suite "rfc-0007 r59 — cgroupEscapeeFallbackNeeded: pure trigger, full truth table":

    test "r71: empty leaf + clean exit (no stop requested) -> fallback NOW needed (an empty leaf is NOT honest evidence -- the raw killpg backstop this used to lean on is deleted)":
      ## rfc-0007 code-review r71 flips this row. Pre-r71, an empty leaf +
      ## clean exit trusted the leaf read and relied on the unconditional
      ## `killpg` in `reapCore` as the (unsafe, pid-reuse-hazardous)
      ## backstop for exactly this case -- the r59 finding's ORIGINAL
      ## leaf-evaded-daemon scenario is reachable on a perfectly CLEAN
      ## exit, not only a stopped one. With `killpg` deleted outright,
      ## this row must now route through the identity-checked
      ## `discoverAndReapEscapees` scan instead, or the daemon goes
      ## unkilled and unreported entirely.
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 0, stopRequested = false,
                                         cgroupKillWriteFailed = false) == true

    test "empty leaf + non-clean exit (stop was requested) -> fallback needed (the r59 fix's core case, unchanged by r71)":
      ## THE regression the r59 finding closed: pre-fix, an empty leaf read on
      ## a killed/stopped slot was silently trusted as "nothing survived" —
      ## exactly the case a same-uid child could have fled the leaf before
      ## this reap's own read.
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 0, stopRequested = true,
                                         cgroupKillWriteFailed = false) == true

    test "non-empty leaf + clean exit + write did not fail -> no fallback (the ONLY remaining fast path)":
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 3, stopRequested = false,
                                         cgroupKillWriteFailed = false) == false

    test "r71: non-empty leaf + non-clean exit -> fallback NOW needed too (a stopped/killed slot pays the scan cost even when the leaf already showed survivors)":
      ## rfc-0007 code-review r71 flips this row. Pre-r71, a non-empty leaf
      ## read was trusted on its own even under a forced/stopped teardown
      ## ("leaf already saw survivors"). r71 widens `stopRequested` to
      ## trigger unconditionally (independent of leaf count): a
      ## forced/stopped teardown is exactly the case a same-uid child
      ## could ALSO have fled the leaf onto the pgid, whether or not the
      ## leaf read happened to still show other, unrelated survivors —
      ## the leaf seeing SOME escapees is not proof it saw ALL of them.
      check cgroupEscapeeFallbackNeeded(leafEscapeeCount = 2, stopRequested = true,
                                         cgroupKillWriteFailed = false) == true

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

      test "r71: an empty cgroup.procs on a CLEAN exit (no stop requested) ALSO triggers the fallback -- the scenario the deleted killpg backstop used to cover":
        ## The real-leaf-read counterpart to the r71 pure-logic row above:
        ## this is the ORIGINAL r59 scenario (a leaf-evaded daemon) on a
        ## perfectly clean exit, proven against a REAL `cgroupLeafSurvivors`
        ## empty read rather than a bare `leafEscapeeCount = 0` literal.
        let dir = getTempDir() / ("crisol_r71_empty_clean_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", "")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 0
        check cgroupEscapeeFallbackNeeded(leafEscapees.len, stopRequested = false,
                                           cgroupKillWriteFailed = false) == true

      test "a leaf with real content (our own pid), on a CLEAN exit, does not trigger the fallback on its own (the only remaining fast path)":
        ## r71: `stopRequested` was changed to `true` here pre-r71's own
        ## widened rule would have flipped this test regardless of leaf
        ## content, so `stopRequested = false` is now load-bearing for
        ## actually exercising the fast path (non-empty leaf AND no stop
        ## AND no write failure) rather than the `stopRequested`-alone row
        ## already covered by the pure-logic suite above.
        let dir = getTempDir() / ("crisol_r59_nonempty_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", $getCurrentProcessId() & "\n")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 1
        check cgroupEscapeeFallbackNeeded(leafEscapees.len, stopRequested = false,
                                           cgroupKillWriteFailed = false) == false

  when isMainModule:
    echo "test_rfc0007_r59_cgroup_reap_backstop: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim"
    echo "test_rfc0007_r59_cgroup_reap_backstop: skipped (POSIX-only backend test)"
