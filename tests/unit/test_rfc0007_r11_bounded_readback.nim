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
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r11_bounded_readback.nim

when defined(posix):
  import std/[posix, unittest, monotimes, times]
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

  when isMainModule:
    echo "test_rfc0007_r11_bounded_readback: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r11_bounded_readback.nim"
    echo "test_rfc0007_r11_bounded_readback: skipped (POSIX-only backend test)"
