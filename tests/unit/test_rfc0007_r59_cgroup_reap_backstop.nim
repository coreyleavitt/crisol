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
## use). r71 WIDENED `cgroupEscapeeFallbackNeeded`'s trigger to
## `stopRequested or leafEscapeeCount == 0 or cgroupKillWriteFailed` — the
## only remaining "skip the scan" cell was a demonstrably non-empty leaf
## read on a clean, non-stopped, non-write-failed exit.
##
## rfc-0007 code-review r79 (round-4 review) found that last surviving
## cell rested on a premise r71's OWN widening had already refuted: a
## leaf-fled, pgid-visible daemon can coexist with genuine leaf residents
## on a perfectly clean exit (the same reasoning r71 used to widen the
## empty-leaf and stopRequested rows to fire unconditionally). And the
## cell bought almost nothing in practice — an empty leaf is the
## OVERWHELMINGLY common case (most single-process, no-descendant spawns
## read an empty leaf by the time `reapCore` runs regardless of whether
## anything escaped, since the leader itself already exited), so the fast
## path fired rarely. r79 deletes `cgroupEscapeeFallbackNeeded` OUTRIGHT
## and runs `discoverAndReapEscapees` + `mergeEscapeesByPid` on EVERY
## cgroup-tier reap, unconditionally — no gate, no truth table, no pure
## trigger left to unit-test. See `reapCore`'s own cgroup-arm comment
## (posixcore.nim) for the full r79 finding, including two honest
## accepted residuals this unconditional scan does NOT close: (1) a
## post-reap identity limit (the starttime re-verify proves
## same-instance-as-the-walk, never ownership of the tree — an unrelated
## same-uid group on a recycled pgid remains killable in principle, the
## same exposure the plain subreaper tier already accepts) and (2) a
## compile-spawn (`claimOrphans = false`) observe-only scope (a
## leaf-evaded daemon from a compile spawn is reported, never killed —
## the deleted `killpg` backstop used to kill it regardless of
## `claimOrphans`; this is a declared, accepted narrowing).
##
## Covered here, unit-level:
##   1. `mergeEscapeesByPid`'s dedupe-by-pid behavior — unchanged by r79,
##      still exercised on every merge since the merge itself is now
##      unconditional rather than gated.
##   2. Source-level pins (r79) proving `cgroupEscapeeFallbackNeeded` is
##      gone and the `discoverAndReapEscapees`/`mergeEscapeesByPid` call
##      sequence in `reapCore`'s cgroup arm is structurally unconditional
##      (no `if` between the leaf-kill reap loop and the fallback call) —
##      the closest thing to a "truth table" left to pin once the truth
##      table itself was deleted for always evaluating to `true`.
##   3. `cgroupLeafSurvivors` against a fake leaf (plain temp dir standing
##      in for a real cgroup-v2 leaf), r12's established pattern — proving
##      the real empty/nonempty leaf read still behaves correctly feeding
##      INTO the now-unconditional merge, even though the read outcome no
##      longer decides whether the merge runs at all.
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
## merge logic and the structural unconditional-invocation shape (both
## proven below); it does NOT and cannot prove the live merge actually
## reaching a real leaf-escaped daemon end-to-end.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim

when defined(posix):
  import std/[os, strutils, unittest]
  import crisol/process/types
  import crisol/process/posixcore

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

  # ---------------------------------------------------------------------
  # rfc-0007 r79 — source-level pins. `cgroupEscapeeFallbackNeeded` (the
  # pure trigger this file used to hold a full truth table for) is
  # deleted outright, and `reapCore`'s cgroup arm now calls
  # `discoverAndReapEscapees`/`mergeEscapeesByPid` UNCONDITIONALLY —
  # there is no runtime decision left to construct inputs for and call.
  # The only thing left to regression-pin is the SOURCE SHAPE itself:
  # the deleted proc must not reappear, and the call site must not grow a
  # new guard around it. Same "grep the source, not the runtime behavior"
  # technique test_rfc7_legacy_names_gone.nim already establishes for a
  # deleted-name regression guard.
  # ---------------------------------------------------------------------

  const CrisolRoot = currentSourcePath().parentDir.parentDir.parentDir
  const PosixCoreSrc = CrisolRoot / "src" / "crisol" / "process" / "posixcore.nim"

  proc posixCoreLines(): seq[string] =
    readFile(PosixCoreSrc).splitLines

  proc firstIndexContaining(lines: seq[string]; needle: string): int =
    for i, line in lines:
      if line.contains(needle): return i
    -1

  suite "rfc-0007 r79 — reapCore's cgroup arm: unconditional fallback invocation (source-level pin)":

    test "cgroupEscapeeFallbackNeeded's proc declaration is gone from posixcore.nim":
      ## r79: deleted outright, not just unused — a regression guard
      ## against a future re-introduction of the gate this file's
      ## now-deleted truth-table suite used to pin.
      let lines = posixCoreLines()
      var declIdx = -1
      for i, line in lines:
        if line.strip.startsWith("proc cgroupEscapeeFallbackNeeded"):
          declIdx = i
          break
      check declIdx == -1

    test "the discoverAndReapEscapees + mergeEscapeesByPid call in reapCore's cgroup arm is NOT guarded by an `if`":
      ## Structural pin: locate the fallback-scan call line and walk
      ## backward over blank/comment lines to the nearest real statement
      ## — pre-r79 that statement was
      ## `if cgroupEscapeeFallbackNeeded(escapees.len, entry.stop.isSome, cgroupKillWriteFailed):`;
      ## post-r79 it must be the unrelated `reapBounded` loop above it (or
      ## any other non-`if` statement), never an `if` gating the call.
      let lines = posixCoreLines()
      let callIdx = firstIndexContaining(lines,
        "discoverAndReapEscapees(core, idx, entry.pid, caps, entry.claimOrphans)")
      require callIdx >= 0
      # There must be exactly ONE such call reachable from reapCore's
      # cgroup arm at this indentation (a second, differently-indented
      # call exists in the `not usedCgroup` arm further down — walking
      # from the FIRST occurrence, which is the cgroup arm's, is correct
      # here since `discoverAndReapEscapees` proper only appears twice in
      # the whole file: once in the cgroup arm's `let pgidEscapees = `
      # form, once as the `not usedCgroup` arm's direct assignment).
      check lines[callIdx].strip.startsWith("let pgidEscapees =")

      var j = callIdx - 1
      while j >= 0 and (lines[j].strip.len == 0 or lines[j].strip.startsWith("#")):
        dec j
      require j >= 0
      let nearestStatement = lines[j].strip
      check not nearestStatement.startsWith("if ")
      check not nearestStatement.startsWith("if(")

  when defined(linux):
    suite "rfc-0007 r59/r79 — cgroupLeafSurvivors feeding the now-unconditional merge (fake leaf, r12's pattern)":

      test "an empty cgroup.procs (nothing resident) reads as zero survivors":
        ## r79: this read no longer DECIDES whether the fallback scan
        ## runs (it always does) — kept to prove `cgroupLeafSurvivors`
        ## itself still reads an empty leaf correctly, since `reapCore`
        ## still uses this read as the PRIMARY (leaf-scoped) half of the
        ## merged `escapees` evidence.
        let dir = getTempDir() / ("crisol_r59_empty_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", "")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 0

      test "a leaf with real content (our own pid) reads as one survivor":
        let dir = getTempDir() / ("crisol_r59_nonempty_" & $getCurrentProcessId())
        removeDir(dir)
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "cgroup.procs", $getCurrentProcessId() & "\n")

        let leafEscapees = cgroupLeafSurvivors(dir)
        check leafEscapees.len == 1
        check leafEscapees[0].pid == getCurrentProcessId()

  when isMainModule:
    echo "test_rfc0007_r59_cgroup_reap_backstop: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim"
    echo "test_rfc0007_r59_cgroup_reap_backstop: skipped (POSIX-only backend test)"
