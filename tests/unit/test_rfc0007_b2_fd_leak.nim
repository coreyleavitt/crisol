## test_rfc0007_b2_fd_leak.nim — rfc-0007 B2: spawning and reaping many
## children through the pidfd+epoll backend never leaks a pidfd or an epoll
## registration. Each spawned child gets its own `pidfd_open` fd, registered
## in the Supervisor's epoll set (posixcore's `initPosixCore`/`spawnChild`);
## `reapCore` is the only place a `ChildId` is consumed (§1), so it is also
## the only correct place to `EPOLL_CTL_DEL` + close that pidfd — a miss
## there leaks one fd per spawn, growing without bound at high `--jobs`
## across a long run (exactly the fd-exhaustion failure mode `initPosixCore`'s
## own doc comment already names).
##
## Linux-only: `/proc/self/fd` is the introspection mechanism (no portable
## equivalent), and pidfd/epoll are Linux-only mechanisms in the first place
## — this test is inert (not merely skipped) on any other backend, since
## there is nothing pidfd-shaped to leak there.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_b2_fd_leak.nim

import std/[os, osproc, unittest, monotimes, times]
import crisol/process

when defined(linux):
  proc openFdCount(): int =
    result = 0
    for kind, path in walkDir("/proc/self/fd"):
      inc result

  let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  let binDir = fixtureDir / "bin"
  let bin = block:
    createDir(binDir)
    let src = fixtureDir / "pass_always.nim"
    let outBin = binDir / "pass_always"
    let cache = fixtureDir / "nimcache" / "pass_always"
    let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & outBin & " " & src)
    doAssert rc == 0, "pass_always compile failed:\n" & o
    outBin

  suite "rfc-0007 B2 — no pidfd/epoll fd leak across many spawn+reap cycles":

    test "30 sequential spawn+reap cycles leave the fd count essentially unchanged":
      var sv = initSupervisor(installSignals = false)
      let outPath = getTempDir() / ("crisol_b2_fdleak_" & $getCurrentProcessId() & ".txt")

      # One warm-up cycle first: `capabilities()`'s own probes (cgroup mkdir/
      # write, a throwaway fork+wait4, flock on a tempfile) run lazily on
      # first use and can themselves transiently touch fds — settle that
      # before taking the baseline so the assertion is about THIS loop's
      # behavior, not the process's one-time startup cost.
      proc spawnAndReapOnce() =
        let spec = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                              sinks: combinedSink(outPath))
        let sr = sv.spawn(spec)
        check sr.ok
        let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
        check ev.kind == weChildExited
        discard sv.reap(ev.id)

      spawnAndReapOnce()
      let before = openFdCount()
      for i in 0 ..< 30:
        spawnAndReapOnce()
      let after = openFdCount()
      echo "  observed: fd count ", before, " -> ", after, " across 30 spawn+reap cycles"
      # A small constant slack (never O(N)): a per-cycle leak of even one fd
      # would show up as +30 here, not +0..2.
      check after <= before + 2
      removeFile(outPath)

when isMainModule:
  echo "test_rfc0007_b2_fd_leak: done"
