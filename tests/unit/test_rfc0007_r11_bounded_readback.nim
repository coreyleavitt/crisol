## test_rfc0007_r11_bounded_readback.nim — rfc-0007 code-review finding r11:
## `spawnChild`'s parent-side status-pipe readback used a raw, UNBOUNDED
## blocking `read(2)` loop. A child stalled in its pre-exec window
## (external SIGSTOP, a hung `cgroup.procs` open) would wedge the entire
## single-threaded Supervisor loop forever — unrecoverable even by SIGINT,
## since `read(2)` restarts under the `SA_RESTART` flag installed at
## signal-handler setup.
##
## The fix (`readPipeBounded`, process/posixcore.nim) replaces the raw read
## loop with a `poll(2)`-bounded one: `poll(2)` is NOT restarted by
## `SA_RESTART`, so a deadline (and a signal) can always end the wait.
## `spawnChild` uses a 10s production deadline; this test drives the SAME
## helper with a short, injectable deadline so it proves the bound for real
## without a slow test.
##
## `readPipeBounded` did not exist pre-fix — there is no pre-fix code path
## to RED this against directly (the raw loop it replaced had no bound at
## all, by construction; the only honest way to demonstrate that would be
## to actually hang the test suite). This file instead proves the NEW
## code's two load-bearing properties directly:
##   1. A normal, fast write still succeeds and returns the exact bytes.
##   2. A silent write end (held open, nothing written) returns within the
##      injected deadline, `timedOut == true`, WITHOUT blocking past it —
##      proven by an upper-bound wall-clock assertion around the call.
##
## rfc-0007 code-review finding r70 extends this file (per the finding's
## own instruction: "extend the existing r11 injected-deadline test"):
## `spawnChild`'s two status-pipe reads (this achieved-bytes readback, and
## the cgroup-join byte read that follows it) used to each pass
## `readPipeBounded` a FRESH `statusPipeDeadlineMs` — a doubled budget (up
## to 2x the documented bound before a doubly-stalled child was ever
## killed), even though the ORIGINAL r11 doc comment already claimed a
## single combined total. The fix shares ONE `readDeadline` (computed once
## before the first read) across both calls via `remainingMs(deadline)`
## (posixcore.nim, exported for exactly this test) — proven below at the
## SAME `readPipeBounded`-level seam this file already uses, by simulating
## spawnChild's own two-call, one-shared-deadline pattern directly (no real
## fork/exec needed — the property under test is the ARITHMETIC/SHARING,
## which does not depend on what is on the other end of the pipe).
##
## What this file does NOT and cannot prove: `spawnChild`'s actual
## second-read-timeout KILL behavior (r70 point (c) — a child stalled
## BETWEEN the two status-pipe writes is now killed via
## `killStalledPreExecChild`, the exact same teardown the first-read
## timeout already used, and already NOT independently tested here or
## anywhere else in this suite even for the first-read case — see the
## module doc comment above: no pre-fix test exercises `spawnChild`'s live
## kill path at all, only `readPipeBounded` directly). Reproducing it for
## real needs an external SIGSTOP delivered to the freshly-forked child
## strictly between its two pipe writes, which requires a pid this
## single-threaded caller cannot observe until `spawnChild` itself
## returns — no seam exists for it short of adding a new injectable-
## deadline parameter to `spawnChild`'s own public signature (out of
## scope here). Honestly unpinned at the live-spawn level; covered only by
## the STRUCTURAL fact that both timeout arms in `spawnChild` now call the
## exact same `killStalledPreExecChild`, so a fix proven for one arm's
## code path is definitionally the same code for the other.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r11_bounded_readback.nim

when defined(posix):
  import std/[os, posix, unittest, monotimes, times]
  import crisol/process/posixcore

  suite "rfc-0007 r11 — readPipeBounded: a normal fast write still succeeds":

    test "full write already sitting in the pipe reads back exactly, timedOut=false":
      var fds: array[2, cint]
      doAssert posix.pipe(fds) == 0
      let (readFd, writeFd) = (fds[0], fds[1])
      defer:
        discard posix.close(readFd)
        discard posix.close(writeFd)

      let payload: array[5, uint8] = [1'u8, 2, 3, 4, 5]
      let n = posix.write(writeFd, unsafeAddr payload[0], payload.len)
      doAssert n == payload.len

      var buf: array[5, uint8]
      let (got, timedOut) = readPipeBounded(readFd, buf, 2_000)
      check got == 5
      check timedOut == false
      check buf == payload

    test "a short buffer split across two writes still assembles correctly":
      var fds: array[2, cint]
      doAssert posix.pipe(fds) == 0
      let (readFd, writeFd) = (fds[0], fds[1])
      defer:
        discard posix.close(readFd)
        discard posix.close(writeFd)

      var first = [10'u8, 20, 30]
      var second = [40'u8, 50]
      discard posix.write(writeFd, addr first[0], first.len)
      discard posix.write(writeFd, addr second[0], second.len)

      var buf: array[5, uint8]
      let (got, timedOut) = readPipeBounded(readFd, buf, 2_000)
      check got == 5
      check timedOut == false
      check buf == [10'u8, 20, 30, 40, 50]

  suite "rfc-0007 r11 — readPipeBounded: a silent write end times out within the injected deadline":

    test "write end held open, nothing written -> returns within the bound, timedOut=true":
      var fds: array[2, cint]
      doAssert posix.pipe(fds) == 0
      let (readFd, writeFd) = (fds[0], fds[1])
      # writeFd deliberately kept open (not closed) for the duration of the
      # call below — this is exactly the "child stalled pre-exec, pipe
      # never EOFs, nothing ever arrives" scenario the fix targets. Closed
      # only in the defer, after the bounded call has already returned.
      defer:
        discard posix.close(readFd)
        discard posix.close(writeFd)

      var buf: array[5, uint8]
      const deadlineMs = 200   # short, injectable — NOT production's 10s
      let start = getMonoTime()
      let (got, timedOut) = readPipeBounded(readFd, buf, deadlineMs)
      let elapsedMs = (getMonoTime() - start).inMilliseconds

      check timedOut == true
      check got == 0
      # Generous slack (10x the deadline) so this is never flaky under CI
      # scheduling jitter, while still proving the call did NOT block
      # anywhere close to forever — the old raw `read(2)` loop this
      # replaces would still be blocked here indefinitely.
      check elapsedMs < deadlineMs * 10

  suite "rfc-0007 r70 — spawnChild's shared-budget pattern: two stalled reads share ONE deadline, not two":

    test "both status-pipe reads stalled: total elapsed stays near ONE combined budget, not 2x":
      ## Mirrors `spawnChild`'s own r70 pattern exactly: ONE `readDeadline`
      ## computed before the first read, `remainingMs(readDeadline)` (not
      ## a fresh constant) passed to EACH call. Two independent pipes
      ## stand in for the two status-pipe reads `spawnChild` actually
      ## makes on the SAME fd — using two fds here (rather than
      ## sequencing two reads on one) keeps this test's own plumbing
      ## simple without changing what's under test: `readPipeBounded`
      ## does not care which fd it is bounding, only how much budget it
      ## is handed.
      var fds1: array[2, cint]
      var fds2: array[2, cint]
      doAssert posix.pipe(fds1) == 0
      doAssert posix.pipe(fds2) == 0
      let (readFd1, writeFd1) = (fds1[0], fds1[1])
      let (readFd2, writeFd2) = (fds2[0], fds2[1])
      defer:
        discard posix.close(readFd1)
        discard posix.close(writeFd1)
        discard posix.close(readFd2)
        discard posix.close(writeFd2)

      const deadlineMs = 300
      let readDeadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
      let start = getMonoTime()

      var buf1: array[5, uint8]
      let (got1, timedOut1) = readPipeBounded(readFd1, buf1, remainingMs(readDeadline))
      check timedOut1 == true
      check got1 == 0

      var buf2: array[1, uint8]
      let (got2, timedOut2) = readPipeBounded(readFd2, buf2, remainingMs(readDeadline))
      check timedOut2 == true
      check got2 == 0

      let elapsedMs = (getMonoTime() - start).inMilliseconds
      # r70: the fix under test — ONE combined budget across both reads.
      # The pre-fix shape (each call handed a FRESH `statusPipeDeadlineMs`
      # constant instead of `remainingMs(readDeadline)`) would take ~2x
      # `deadlineMs` here. 1.5x leaves headroom for scheduling jitter
      # while still firmly separating the fixed (~1x) shape from the
      # doubled-budget bug this closes — the finding's own suggested bound.
      check elapsedMs < (deadlineMs * 3) div 2

    test "the second call's budget is the REMAINDER of the shared deadline, not a fresh full one":
      ## Proves `remainingMs` directly, isolated from any actual `poll`/
      ## `read` timing: after part of the combined budget has already
      ## elapsed, the remainder handed to a second call is meaningfully
      ## SMALLER than the original total — never the same constant a
      ## pre-fix second call would have received unconditionally.
      ## Budget is deliberately huge relative to the sleep so a slow or
      ## loaded runner (macos CI overshoots os.sleep by whole seconds)
      ## cannot exhaust it before the remainder is sampled -- the assertion
      ## is about MONOTONIC CONSUMPTION, not the sleep's precision.
      const totalMs = 10_000
      let readDeadline = getMonoTime() + initDuration(milliseconds = totalMs)
      os.sleep(50)
      let remainder = remainingMs(readDeadline)
      check remainder > 0
      check remainder < totalMs

    test "remainingMs on an already-passed deadline clamps to 0, never negative":
      let pastDeadline = getMonoTime() - initDuration(milliseconds = 50)
      check remainingMs(pastDeadline) == 0

  when isMainModule:
    echo "test_rfc0007_r11_bounded_readback: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r11_bounded_readback.nim"
    echo "test_rfc0007_r11_bounded_readback: skipped (POSIX-only backend test)"
