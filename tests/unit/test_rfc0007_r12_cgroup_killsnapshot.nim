## test_rfc0007_r12_cgroup_killsnapshot.nim — rfc-0007 code-review finding
## r12: `killSnapshot` on a cgroup-tier slot used the WEAKER pgid-only
## `scanProcessGroup(entry.pid)` even when `entry.cgroupLeaf` was
## non-empty — so a setsid escapee the tier CAN see through its leaf
## (`cgroupLeafSurvivors` lists it, `cgroup.kill` kills it, reap stamps
## `tree=toComplete`) was absent from `killSnapshot`: internally
## inconsistent evidence on exactly the tier that vouches completeness.
##
## The fix, `killSnapshotFor(pid, cgroupLeaf)` (process/posixcore.nim,
## consumed by both `requestStopCore` and `forceKillCore`), prefers
## `cgroupLeafSurvivors(cgroupLeaf)` whenever a leaf is given, falling back
## to `scanProcessGroup(pid)` only when the leaf read comes back empty.
##
## `cgroupLeafSurvivors` reads `<leaf>/cgroup.procs` as a PLAIN TEXT FILE —
## it does no cgroupfs-specific syscalls and needs no real cgroup-v2
## mount — so both arms of `killSnapshotFor` are provable here directly,
## on any Linux host, with a plain temp directory standing in for a leaf:
## no real cgroup-v2 delegation required. Only the CI `cgroup` job proves
## this against a REAL delegated leaf end-to-end (a setsid escapee that a
## live spawn/stop/reap cycle actually threads through `killSnapshot`).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r12_cgroup_killsnapshot.nim

when defined(linux):
  import std/[os, posix, unittest]
  import crisol/process/types
  import crisol/process/posixcore

  suite "rfc-0007 r12 — killSnapshotFor: leaf-priority when the leaf has real content":

    test "a leaf with our own pid in cgroup.procs is preferred over the pgid scan":
      let dir = getTempDir() / ("crisol_r12_leaf_" & $getpid())
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "cgroup.procs", $getpid() & "\n")

      let snap = killSnapshotFor(Pid(getpid()), dir)
      require snap.len == 1
      check snap[0].pid == getpid()
      # command comes from a real /proc/<pid>/stat read on our own live
      # process — proves this went through cgroupLeafSurvivors's real
      # per-pid enrichment, not a bare pid-only stub.
      check snap[0].command.len > 0

  suite "rfc-0007 r12 — killSnapshotFor: falls back to the pgid scan when the leaf is unreadable/empty":

    test "a leaf path that does not exist at all falls back to scanProcessGroup":
      let missingDir = getTempDir() / ("crisol_r12_missing_" & $getpid())
      removeDir(missingDir)   # ensure it genuinely does not exist

      let viaFallback = killSnapshotFor(Pid(getpid()), missingDir)
      let viaDirectScan = scanProcessGroup(Pid(getpid()))
      # Both computed back-to-back against the same live, quiescent test
      # process — no children forked in between — so they must agree
      # exactly when the fallback really did engage scanProcessGroup.
      check viaFallback.len == viaDirectScan.len
      for i in 0 ..< viaFallback.len:
        check viaFallback[i].pid == viaDirectScan[i].pid

    test "cgroupLeaf empty string (the non-cgroup-tier case) always uses the pgid scan directly":
      let viaEmpty = killSnapshotFor(Pid(getpid()), "")
      let viaDirectScan = scanProcessGroup(Pid(getpid()))
      check viaEmpty.len == viaDirectScan.len

  when isMainModule:
    echo "test_rfc0007_r12_cgroup_killsnapshot: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r12_cgroup_killsnapshot.nim"
    echo "test_rfc0007_r12_cgroup_killsnapshot: skipped (linux-only cgroup mechanism)"
