## test_rfc0007_r10_cgroup_kill_degrade.nim — rfc-0007 code-review finding
## r10: cgroup forced-kill was escapable and unvouched-failure-blind.
##
## Two gaps, both closed in process/posixcore.nim:
##   1. `killCgroupLeaf` swallowed every `cgroup.kill` write failure (void
##      return) — callers had no way to know the write did not happen.
##   2. `forceKillCore`'s cgroup arm skipped `killpg` ENTIRELY when a leaf
##      existed — a same-uid child that migrated itself out of the leaf
##      (delegation's common-ancestor rule), or a write that failed at
##      runtime (EACCES/ENOENT), left a SIGTERM-ignoring child with NO
##      kill signal ever sent, while reap still stamped
##      `killDomain = kdsCgroup` — a vouch the mechanism did not honor.
##
## Covered here, unit-level (no real cgroup-v2 delegation required):
##   1. `killCgroupLeaf` now RETURNS the write's real success/failure —
##      proven directly against a genuinely nonexistent leaf path (a
##      `writeFile` into a directory that does not exist fails on ANY
##      posix host, delegated or not). Linux-only (`killCgroupLeaf` itself
##      is `when defined(linux)`-gated in posixcore.nim).
##   2. `killDomainFor` — the pure kill-domain degrade decision extracted
##      specifically so it is testable without a real cgroup at all: the
##      full truth table over (usedCgroup, cgroupKillWriteFailed,
##      subreaper). Platform-independent (plain bools/enum in, enum out),
##      so this half runs on every posix leg, macOS included.
##
## What only the CI `cgroup` job can prove: that a REAL delegated leaf's
## `cgroup.kill` write can be made to fail at runtime and that
## `forceKillCore`/`reapCore` actually thread that failure through to a
## live `ReapReport.killDomain` in an end-to-end spawn/kill/reap. No cheap,
## root-unbypassable fault injection for a KILL-TIME write failure
## (distinct from B3's existing LEAF-CREATION-time sabotage in
## tests/integration/test_rfc0007_b3_cgroup.nim, which turns the leaf into
## an internal cgroup-v2 node so `cgroup.procs` writes get a structural
## EBUSY) was found cheap to construct against a --privileged root
## container — `cgroup.kill` itself has no analogous "always-on,
## unbypassable-by-root" failure mode documented anywhere in this codebase
## (the closest analogues in test_rfc0007_b3_cgroup.nim's own header list
## three EARLIER attempts at a kill/procs-write sabotage that root
## trivially bypassed). This is therefore a genuine, currently-unpinned
## gap at the CI leg: the pure decision logic here is proven, and the
## `killpg` backstop's REACHABILITY for a pgid-visible process is already
## implicitly exercised by every existing cgroup-tier kill test (e.g.
## test_rfc0007_a6a_escapee_evidence.nim's setsid-escapee case), but the
## SPECIFIC "cgroup.kill write fails at runtime -> domain degrades
## honestly" behavioral path has no CI-leg reproduction yet.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r10_cgroup_kill_degrade.nim

when defined(posix):
  import std/unittest
  import crisol/process/types
  import crisol/process/posixcore

  when defined(linux):
    suite "rfc-0007 r10 — killCgroupLeaf: real write-failure return, no delegation required":

      test "a nonexistent leaf path fails the cgroup.kill write and returns false":
        ## Genuine RED against the pre-fix code (which had no return value
        ## at all — this line would not even compile pre-fix). A directory
        ## that was never created has no `cgroup.kill` file to write, on
        ## ANY posix host, root or not — this is a real, deterministic
        ## write failure, not a simulation.
        check killCgroupLeaf("/nonexistent/crisol-r10-leaf-path-should-not-exist") == false

  suite "rfc-0007 r10 — killDomainFor: pure degrade decision, full truth table":

    test "usedCgroup=true, writeFailed=false -> kdsCgroup (the normal, fully-vouched case)":
      check killDomainFor(usedCgroup = true, cgroupKillWriteFailed = false,
                          subreaper = true) == kdsCgroup

    test "usedCgroup=true, writeFailed=true, subreaper=true -> degrades to kdsProcessGroupSubreaper (the r10 fix)":
      ## THE regression this finding closes: pre-fix, a cgroup.kill write
      ## failure was invisible — the domain stayed (falsely) kdsCgroup no
      ## matter what. This is what the fix makes the pure decision do.
      check killDomainFor(usedCgroup = true, cgroupKillWriteFailed = true,
                          subreaper = true) == kdsProcessGroupSubreaper

    test "usedCgroup=true, writeFailed=true, subreaper=false -> degrades to the pre-B1 kdsProcessGroup":
      ## Defensive-only: cgroup and subreaper are always taken together in
      ## production (initPosixCore sets PR_SET_CHILD_SUBREAPER
      ## unconditionally before any leaf can exist), but the pure function
      ## still degrades correctly if that ever changed.
      check killDomainFor(usedCgroup = true, cgroupKillWriteFailed = true,
                          subreaper = false) == kdsProcessGroup

    test "usedCgroup=false, subreaper=true -> kdsProcessGroupSubreaper (unaffected by cgroupKillWriteFailed)":
      check killDomainFor(usedCgroup = false, cgroupKillWriteFailed = false,
                          subreaper = true) == kdsProcessGroupSubreaper
      check killDomainFor(usedCgroup = false, cgroupKillWriteFailed = true,
                          subreaper = true) == kdsProcessGroupSubreaper

    test "usedCgroup=false, subreaper=false -> kdsProcessGroup":
      check killDomainFor(usedCgroup = false, cgroupKillWriteFailed = false,
                          subreaper = false) == kdsProcessGroup

  when isMainModule:
    echo "test_rfc0007_r10_cgroup_kill_degrade: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r10_cgroup_kill_degrade.nim"
    echo "test_rfc0007_r10_cgroup_kill_degrade: skipped (POSIX-only backend test)"
