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
## A std-only leaf on purpose: `crisol/ccprobe` is itself a leaf that
## `crisol/closure` and `crisol/artifactid` depend on, so anything ccprobe
## imports must not reach back into the graph.

import std/[os, osproc, streams]  # process-contract-exempt: this module IS the tool-invocation capture layer (RFC-0007 §Scope)

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
