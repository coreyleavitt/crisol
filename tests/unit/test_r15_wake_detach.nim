## test_r15_wake_detach.nim — `tooltrees.detachInterruptWake` returns only
## once no handler still holds the wake it detached (R15-S6).
##
## The handler reads the attached wake, then sets it (Windows: `SetEvent` on
## the Supervisor's event; POSIX: a byte to its self-pipe). The Supervisor
## detaches the wake, then closes it. A handler that read the wake just
## before the detach used it after the close: `SetEvent` on a closed handle,
## or on whatever object the handle value names by then (a `write(2)` to a
## recycled fd on POSIX). On Windows the handler runs on a thread of its own,
## so the window is real.
##
## Built with `-d:crisolWakeRaceProbe` (test_r15_wake_detach.nim.cfg), which
## pauses the handler between the read and the use. A second thread plays
## the handler (`deliverInterrupt`); the main thread detaches while it is
## paused. The detach must wait for it: once it returns, the wake has
## already been set.
##
## Run with:
##   nim r --hints:off --warnings:off --path:src tests/unit/test_r15_wake_detach.nim

import std/[os, typedthreads, unittest]
import crisol/process/tooltrees

when defined(windows):
  import std/winlean
else:
  import std/posix

proc playHandler() {.thread.} =
  deliverInterrupt(2)

suite "R15-S6 — detach waits out a handler that holds the wake":

  test "a wake read before the detach lands before the detach returns":
    enterInterruptScope()
    when defined(windows):
      let ev = createEvent(nil, 1'i32, 0'i32, nil)
      doAssert ev != 0
      check attachInterruptWake(ev)
    else:
      var fds: array[2, cint]
      doAssert posix.pipe(fds) == 0
      let fl = fcntl(fds[0], F_GETFL, 0)
      doAssert fcntl(fds[0], F_SETFL, fl or O_NONBLOCK) == 0
      check attachInterruptWake(fds[1])
    atomicStoreN(addr gWakeProbePauseMs, 500, ATOMIC_SEQ_CST)
    var th: Thread[void]
    createThread(th, playHandler)
    var waited = 0
    while atomicLoadN(addr gWakeProbePaused, ATOMIC_SEQ_CST) == 0 and waited < 5_000:
      sleep(1)
      inc waited
    check atomicLoadN(addr gWakeProbePaused, ATOMIC_SEQ_CST) == 1
    detachInterruptWake()
    # The detach is the Supervisor's last word before it closes the wake.
    when defined(windows):
      check waitForSingleObject(ev, 0) == WAIT_OBJECT_0
    else:
      var b: uint8
      check posix.read(fds[0], addr b, 1) == 1
    joinThread(th)
    atomicStoreN(addr gWakeProbePauseMs, 0, ATOMIC_SEQ_CST)
    when defined(windows):
      discard closeHandle(ev)
    else:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
    discard leaveInterruptScope()
