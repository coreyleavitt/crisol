## toolexec.nim — capturing the output of short-lived TOOL subprocesses.
##
## This module owns the capture side of crisol's `process-contract-exempt`
## call sites: `cc`/`ldd` version probes, the `cc -M` dependency probe, `git`,
## `nim --compileOnly`, the measure-mode link, the incremental-compile probe.
## Those are tool invocations, not the supervised compile/run children
## `crisol/process.nim` governs (RFC-0007 §Scope) — but "exempt from the
## process contract" never meant "each module hand-rolls its own capture",
## which is how five copies of the same spawn/read/wait sequence came to share
## two silent bugs (issue #22): output truncated at the child's first flush,
## and a stderr pipe that was created but never drained.
##
## Two primitives, one per spawn shape:
##
## - `drainToEof(stream)` — for a child spawned with `poStdErrToStdOut`. One
##   pipe, so readiness never has to be arbitrated; just read it to the end.
## - `drainBoth(process)` — for a child spawned with SEPARATE stderr. Both
##   pipes are consumed concurrently, because consuming them in sequence
##   deadlocks (see that proc's doc).
##
## CR4 (code review 2026-09-21): neither primitive above bounds how long it
## waits — `drainToEof` blocks on a stream read, `drainBoth` polls with an
## INFINITE timeout on POSIX and spins forever on Windows — and no caller put
## a deadline on the `waitForExit` that follows either. That is sound for a
## child under the RFC-0007 Supervisor (an outer `compileTimeoutMs` plus
## tree-aware kill reaps the whole tree regardless), but `toolrun.realRun`/
## `realRunMerged` and `gitdiff.runGit` run in the HOST PROCESS during
## plan-building, entirely outside the Supervisor — a `git` blocked on a
## credential prompt, or a wedged `cc --version`, hangs the whole invocation
## forever. Three more primitives close that gap, all opt-in (the two above
## are UNCHANGED, so every existing caller keeps its exact prior behaviour):
##
## - `drainToEofDeadline(process, timeoutMs)` / `drainBothDeadline(process,
##   timeoutMs)` — same EOF discipline as their unbounded counterparts (a
##   short read is never mistaken for EOF), but give up and return
##   `timedOut = true` after `timeoutMs` instead of waiting forever. `p` is
##   left ALIVE on a timeout — draining and killing are different
##   responsibilities.
## - `waitForExitDeadline(process, timeoutMs)` — a bounded `waitForExit`,
##   polling `peekExitCode` non-blockingly (same idiom as
##   `tests/support/deadline.nim`, written for issue #22's own tests and
##   promoted to production here).
## - `terminateAndReap(process)` — what a caller calls when either of the
##   above times out: `terminate()`, a bounded wait, then `kill()` and a second
##   bounded wait, so a timed-out caller cannot leak a process AND cannot be
##   blocked by one that ignores SIGTERM (R3-3; the original
##   `terminate()`-then-unbounded-`waitForExit()` shape could be, for the
##   child's entire remaining lifetime). Deliberately NOT a tree-aware
##   kill (`killpg`/Job Objects, `crisol/process`'s machinery) — that belongs
##   to RFC-0007's SUPERVISED children, which this module explicitly is not
##   part of (see below), and the two production callers here spawn simple,
##   non-tree-forming tools.
##
## A std-only leaf on purpose: `crisol/toolrun` imports it, and toolrun is
## itself imported by `crisol/closure`, `crisol/depgraph`, `crisol/artifactid`
## and `crisol/ccidentity`, so anything imported here must not reach back into
## the graph.

import std/[monotimes, os, osproc, streams, times]  # process-contract-exempt: this module IS the tool-invocation capture layer (RFC-0007 §Scope)

when defined(windows):
  import std/winlean

  proc peekNamedPipe(hNamedPipe: Handle; lpBuffer: pointer;
                     nBufferSize: int32; lpBytesRead: ptr int32;
                     lpTotalBytesAvail: ptr int32;
                     lpBytesLeftThisMessage: ptr int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}
else:
  import std/posix  # readiness-only: poll(2) over two subprocess pipes, never file I/O (see module doc)

const DrainChunk = 8192

proc drainToEof*(s: Stream): string =
  ## Read `s` until it genuinely reaches EOF.
  ##
  ## NOT `streams.readAll` (issue #22). `readAll` reads in 1024-byte chunks and
  ## stops at the first read SHORTER than that buffer, treating it as EOF. On
  ## POSIX that happens to be sound, because `osproc.outputStream` hands back a
  ## buffered C `FILE*` (`osproc.nim`'s `createStream`) whose `fread` loops
  ## until the request is satisfied or the pipe truly ends. On Windows it is
  ## not: `osproc.outputStream` returns a raw-handle stream whose `hsReadData`
  ## calls `winlean.readFile` directly, and a pipe read returns as soon as ANY
  ## bytes are available — so a child that flushes twice (a banner now, its
  ## real payload a moment later, exactly what `cl.exe` does) is captured as if
  ## it had written only the first flush, with exit code 0 and nothing in the
  ## result to say otherwise. Short-but-valid output is indistinguishable from
  ## a child that genuinely said little, which is what made it survive so long.
  ##
  ## Draining to EOF *before* `waitForExit` is also what keeps a child that
  ## outruns the pipe buffer from wedging. That budget is far smaller than the
  ## usual 64 KB folklore: `osproc.createPipeHandles` calls `CreatePipe` with
  ## `nSize = 0`, i.e. the Windows system default of roughly 4 KB — well under
  ## a real dependency report.
  ##
  ## Only sound for a child whose stderr is MERGED into this stream
  ## (`poStdErrToStdOut`). With a separate stderr pipe, use `drainBoth`.
  var buf = newString(DrainChunk)
  while true:
    let n = s.readData(addr buf[0], buf.len)
    if n <= 0: break
    result.add buf[0 ..< n]

proc drainBoth*(p: Process): tuple[output, errOutput: string] =
  ## Consume `p`'s stdout AND stderr concurrently, each to its own EOF.
  ##
  ## Sequential draining — read stdout to EOF, then read stderr — looks
  ## harmless and is a deadlock. A child that fills the stderr pipe blocks
  ## inside its own `write`; blocked there, it never finishes writing stdout
  ## and never exits, so the stdout read never returns and the stderr read is
  ## never reached. The pipe budget is small (see `drainToEof`), and the
  ## classic trigger is mundane: `git` under `core.autocrlf` emits one "LF will
  ## be replaced by CRLF" warning PER FILE, so a large checkout is orders of
  ## magnitude past it.
  ##
  ## Implemented by reading whichever pipe has bytes ready, never by blocking
  ## on one while the other fills: `poll(2)` on POSIX, `PeekNamedPipe` on
  ## Windows. Deliberately NOT threads — `src/` has no threading model, and a
  ## tool-invocation side channel is the wrong place to introduce one.
  ##
  ## Reads the raw handles rather than `p.outputStream`/`p.errorStream`, so a
  ## caller must not mix this with those streams for the same process: the
  ## POSIX streams are buffered `FILE*`s and would race this for the same
  ## bytes.
  var bufs: array[2, string]
  var open = [true, true]
  var buf = newString(DrainChunk)

  when defined(windows):
    let handles = [Handle(p.outputHandle), Handle(p.errorHandle)]
    while open[0] or open[1]:
      var progressed = false
      for i in 0 .. 1:
        if not open[i]: continue
        var avail: int32 = 0
        if peekNamedPipe(handles[i], nil, 0, nil, addr avail, nil) == 0:
          # The write end is gone (ERROR_BROKEN_PIPE) — or the handle is no
          # longer peekable, which for our own pipes means the same thing.
          open[i] = false
          continue
        if avail > 0:
          var got: int32 = 0
          let want = int32(min(avail.int, buf.len))
          if winlean.readFile(handles[i], addr buf[0], want, addr got, nil) == 0 or
             got == 0:
            open[i] = false
          else:
            bufs[i].add buf[0 ..< got.int]
            progressed = true
      if not progressed and (open[0] or open[1]):
        # Both pipes are open and empty: the child is working. A short sleep
        # keeps this from spinning; the tools involved run for milliseconds to
        # seconds, so the granularity costs nothing.
        sleep(1)
  else:
    var fds: array[2, TPollfd]
    fds[0] = TPollfd(fd: cint(p.outputHandle), events: POLLIN, revents: 0)
    fds[1] = TPollfd(fd: cint(p.errorHandle), events: POLLIN, revents: 0)
    while open[0] or open[1]:
      if poll(addr fds[0], Tnfds(2), -1) < 0:
        if errno == EINTR: continue
        break   # cannot wait on these fds any more; return what was read
      for i in 0 .. 1:
        if not open[i]: continue
        if (fds[i].revents and
            (POLLIN or POLLHUP or POLLERR or POLLNVAL)) == 0: continue
        let n = read(fds[i].fd, addr buf[0], buf.len)
        if n < 0 and errno == EINTR: continue
        if n <= 0:
          open[i] = false
          fds[i].fd = -1   # poll(2) ignores a negative fd
        else:
          bufs[i].add buf[0 ..< n]

  (output: bufs[0], errOutput: bufs[1])

# ---------------------------------------------------------------------------
# CR4 — deadline-bounded variants + termination (production, non-Supervisor
# tool invocations: toolrun.runViaOsproc, gitdiff.runGit)
# ---------------------------------------------------------------------------

proc elapsedMs(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

proc drainToEofDeadline*(p: Process; timeoutMs: int):
    tuple[output: string; timedOut: bool] =
  ## Like `drainToEof`, but gives up after `timeoutMs` milliseconds rather
  ## than waiting for genuine EOF forever. Only sound for a child whose
  ## stderr is MERGED into stdout (`poStdErrToStdOut`) — same precondition as
  ## `drainToEof`.
  ##
  ## Same EOF discipline as `drainToEof`: a read of `0 < n < buf.len` bytes is
  ## NEVER treated as end of output (issue #22) — only a genuine `n <= 0`
  ## (closed pipe) ends the loop before the deadline. The only difference
  ## from `drainToEof` is HOW readiness is waited for: a BOUNDED wait
  ## (`poll` with a real timeout on POSIX; `PeekNamedPipe` plus a
  ## deadline-capped `sleep(1)` spin on Windows, the same idiom `drainBoth`
  ## already uses there) instead of an unbounded one.
  ##
  ## On `timedOut = true`, `p` is left ALIVE with its pipe undrained further
  ## — draining and killing are different responsibilities. The caller must
  ## terminate and reap it (`terminateAndReap`); whatever was captured before
  ## the deadline is still returned in `output`, for diagnostics.
  var buf = newString(DrainChunk)
  var output = ""
  let start = getMonoTime()
  when defined(windows):
    let handle = Handle(p.outputHandle)
    while true:
      let left = timeoutMs.int64 - elapsedMs(start)
      if left <= 0: return (output: output, timedOut: true)
      var avail: int32 = 0
      if peekNamedPipe(handle, nil, 0, nil, addr avail, nil) == 0:
        break   # write end gone: genuine EOF
      if avail > 0:
        var got: int32 = 0
        let want = int32(min(avail.int, buf.len))
        if winlean.readFile(handle, addr buf[0], want, addr got, nil) == 0 or
           got == 0:
          break
        output.add buf[0 ..< got.int]
      else:
        sleep(1)
  else:
    var fds: array[1, TPollfd]
    fds[0] = TPollfd(fd: cint(p.outputHandle), events: POLLIN, revents: 0)
    while true:
      let left = timeoutMs.int64 - elapsedMs(start)
      if left <= 0: return (output: output, timedOut: true)
      let waitMs = cint(min(left, int64(high(int32))))
      let pr = poll(addr fds[0], Tnfds(1), waitMs)
      if pr < 0:
        if errno == EINTR: continue
        break   # cannot wait on this fd any more; return what was read
      if pr == 0: continue   # deadline tick with nothing ready — recheck `left`
      if (fds[0].revents and (POLLIN or POLLHUP or POLLERR or POLLNVAL)) == 0:
        continue
      let n = read(fds[0].fd, addr buf[0], buf.len)
      if n < 0 and errno == EINTR: continue
      if n <= 0: break
      output.add buf[0 ..< n]
  (output: output, timedOut: false)

proc drainBothDeadline*(p: Process; timeoutMs: int):
    tuple[output, errOutput: string; timedOut: bool] =
  ## Like `drainBoth`, but gives up after `timeoutMs` milliseconds rather
  ## than an infinite `poll(-1)` (POSIX) / unbounded spin (Windows). Same
  ## concurrent-drain discipline as `drainBoth` — neither stream can starve
  ## the other while waiting, so the #22 deadlock is not reintroduced — the
  ## only difference is that the wait itself is bounded.
  ##
  ## Partial output collected before the deadline is still returned in
  ## `output`/`errOutput` (for diagnostics) even when `timedOut = true`. `p`
  ## is left ALIVE on a timeout; see `terminateAndReap`.
  var bufs: array[2, string]
  var open = [true, true]
  var buf = newString(DrainChunk)
  let start = getMonoTime()

  when defined(windows):
    let handles = [Handle(p.outputHandle), Handle(p.errorHandle)]
    while open[0] or open[1]:
      let left = timeoutMs.int64 - elapsedMs(start)
      if left <= 0:
        return (output: bufs[0], errOutput: bufs[1], timedOut: true)
      var progressed = false
      for i in 0 .. 1:
        if not open[i]: continue
        var avail: int32 = 0
        if peekNamedPipe(handles[i], nil, 0, nil, addr avail, nil) == 0:
          open[i] = false
          continue
        if avail > 0:
          var got: int32 = 0
          let want = int32(min(avail.int, buf.len))
          if winlean.readFile(handles[i], addr buf[0], want, addr got, nil) == 0 or
             got == 0:
            open[i] = false
          else:
            bufs[i].add buf[0 ..< got.int]
            progressed = true
      if not progressed and (open[0] or open[1]):
        sleep(1)
  else:
    var fds: array[2, TPollfd]
    fds[0] = TPollfd(fd: cint(p.outputHandle), events: POLLIN, revents: 0)
    fds[1] = TPollfd(fd: cint(p.errorHandle), events: POLLIN, revents: 0)
    while open[0] or open[1]:
      let left = timeoutMs.int64 - elapsedMs(start)
      if left <= 0:
        return (output: bufs[0], errOutput: bufs[1], timedOut: true)
      let waitMs = cint(min(left, int64(high(int32))))
      let pr = poll(addr fds[0], Tnfds(2), waitMs)
      if pr < 0:
        if errno == EINTR: continue
        break   # cannot wait on these fds any more; return what was read
      if pr == 0: continue   # deadline tick with nothing ready — recheck `left`
      for i in 0 .. 1:
        if not open[i]: continue
        if (fds[i].revents and
            (POLLIN or POLLHUP or POLLERR or POLLNVAL)) == 0: continue
        let n = read(fds[i].fd, addr buf[0], buf.len)
        if n < 0 and errno == EINTR: continue
        if n <= 0:
          open[i] = false
          fds[i].fd = -1   # poll(2) ignores a negative fd
        else:
          bufs[i].add buf[0 ..< n]

  (output: bufs[0], errOutput: bufs[1], timedOut: false)

proc waitForExitDeadline*(p: Process; timeoutMs: int; pollMs: int = 10):
    tuple[exitCode: int; timedOut: bool] =
  ## A bounded `waitForExit`: polls `p.peekExitCode()` (non-blocking) every
  ## `pollMs` until the child reports an exit code or `timeoutMs` elapses.
  ## Same idiom as `tests/support/deadline.nim`'s `runWithDeadline`, written
  ## for issue #22's own tests — this is that mechanism, promoted to
  ## production now that `toolexec` has production callers that need it
  ## (CR4).
  ##
  ## Meaningful only AFTER a drain has reached genuine EOF (or already given
  ## up): a child that has not yet closed its pipes has, by definition, not
  ## exited either. On `timedOut = true`, `p` is left ALIVE — a bare
  ## `peekExitCode` never reaps the way `waitForExit` does, so the caller
  ## must still call `terminateAndReap`.
  let start = getMonoTime()
  while elapsedMs(start) < timeoutMs.int64:
    let code = p.peekExitCode()
    if code != -1: return (exitCode: code, timedOut: false)
    sleep(pollMs)
  (exitCode: -1, timedOut: true)

const TerminateGraceMs* = 2_000
  ## R3-3: how long `terminateAndReap` waits for a SIGTERM to be honored before
  ## escalating to `kill()`, and again after it. Generous relative to what a
  ## cooperative tool needs to unwind (these are `cc --version`-class probes,
  ## not compile children), and small relative to the drain deadline it backs up
  ## (`toolrun.ToolProbeTimeoutMs`).
  ##
  ## WHAT THE WORST CASE ACTUALLY IS (R4-L3). This doc used to claim "roughly
  ## the drain deadline plus two grace periods", i.e. ~14 s. That is only the
  ## path where the drain TIMES OUT; the true composite bound of one
  ## `toolrun.runViaOsproc` probe is TWICE the drain deadline plus two grace
  ## periods — `2 * ToolProbeTimeoutMs + 2 * TerminateGraceMs` = 24 s — because
  ## the drain has a second exit:
  ##   - `drainToEofDeadline`/`drainBothDeadline` can consume the full
  ##     `ToolProbeTimeoutMs` and then leave via an ERROR path with
  ##     `timedOut = false` — `poll` returning < 0 with errno != EINTR on
  ##     POSIX, `peekNamedPipe` == 0 on Windows, both `break` out of the loop
  ##     and fall through to the `(output, timedOut: false)` return;   up to 10 s
  ##   - so `runViaOsproc` does NOT give up there, and calls
  ##     `waitForExitDeadline` with the FULL `ToolProbeTimeoutMs` again
  ##     (`toolrun.nim`, the `waitTimedOut` arm);                     up to 10 s
  ##   - which, on timing out, calls `terminateAndReap`: grace, `kill()`,
  ##     grace.                                                            2×2 s
  ## Still bounded, which is the property that matters, but a caller (or a
  ## test) sizing a bound off 14 s would be wrong by 10 s. `tests/integration/
  ## test_r3_terminate_escalation.nim` computes its ceiling from this constant
  ## and `ToolProbeTimeoutMs` for exactly that reason — which is also the
  ## reason this constant is EXPORTED at all: it has no production consumer
  ## outside this module, and the export earns its keep only by keeping that
  ## test's bound from silently desynchronising from the implementation's.

proc terminateAndReap*(p: Process) =
  ## Give up on `p`: terminate it and reap it, so a timed-out caller cannot
  ## leak a process. Grew out of `tests/support/deadline.nim`'s
  ## `runWithDeadline`, written for issue #22's own tests; that helper's
  ## `p.terminate(); discard p.waitForExit()` was promoted to production here
  ## and then had to be escalated — see ESCALATION below for why the bare form
  ## was not enough.
  ##
  ## Deliberately SINGLE-PROCESS, NOT a process-TREE kill: the
  ## `killpg`/Job-Object machinery in `crisol/process` belongs to RFC-0007's
  ## SUPERVISED compile/run children, which this module explicitly is not
  ## part of (see module doc) — reaching into it would both violate that
  ## boundary and pull `crisol/process` into what is meant to stay a std-only
  ## leaf. `ccidentity`'s driver/version probes and `git` are simple tools that
  ## do not fork their own subtrees in the cases this fix covers, so a single
  ## `terminate()` is proportionate; a future caller that spawns a
  ## tree-forming tool through this path would need its own tree-aware kill,
  ## not a silent broadening of this one.
  ##
  ## ESCALATION (R3-3, round-3 review). `terminate()` followed by an UNBOUNDED
  ## `waitForExit()` was the original shape, and it handed the hang straight
  ## back: on POSIX `terminate()` is SIGTERM alone, so a driver that traps TERM
  ## -- or one wedged in D-state -- ignored the deadline entirely. Measured on a
  ## `cc` shim doing `trap "" TERM; echo banner; sleep 45`: the caller printed
  ## its `giving up` warning and then returned after 45006 ms instead of ~10000.
  ## For the motivating case (a `git` blocked on a credential prompt, in the
  ## host process before the Supervisor exists) that wait is unbounded in
  ## principle, which defeats the whole point of the deadline above it.
  ##
  ## So: bounded wait, then `kill()` (SIGKILL on POSIX, `TerminateProcess` on
  ## Windows -- unignorable on both), then a second bounded wait. This escalates
  ## on the SAME process and is NOT the process-TREE broadening the paragraph
  ## above rules out; that reasoning is untouched.
  ##
  ## If even SIGKILL leaves it unreaped (D-state), we give up and return rather
  ## than block. That leaks a zombie until crisol exits, which is deliberately
  ## chosen over hanging the invocation: these are short-lived host-process tool
  ## probes, and an unkillable one is a host problem the caller cannot fix by
  ## waiting longer.
  try:
    p.terminate()
  except CatchableError:
    discard
  if waitForExitDeadline(p, TerminateGraceMs).timedOut:
    try:
      p.kill()
    except CatchableError:
      discard
    discard waitForExitDeadline(p, TerminateGraceMs)
