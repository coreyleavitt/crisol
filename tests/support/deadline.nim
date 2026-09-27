## tests/support/deadline.nim — running a fixture under a wall-clock deadline.
##
## Issue #22's stderr cases assert that a capture does NOT deadlock. That
## cannot be asserted from inside the process that would be deadlocked, so the
## call under test runs in a small driver fixture and the deadline lives out
## here. `finished = false` is the shape a wedged driver produces.
##
## Not a `test_*.nim` file, so crisol.nimble's self-discovering test task never
## tries to run it directly.

import std/[os, osproc, streams, strutils]

proc compileFixtureWithSrc*(fixtureDir, cacheDir, name, outBin, srcDir: string) =
  ## Build `tests/fixtures/<name>.nim` with the package path on `--path`, which
  ## the driver fixtures need because they import `crisol/*`. `.exe` is applied
  ## by the caller via `addFileExt(ExeExt)`.
  let (o, rc) = execCmdEx("nim c --mm:orc --path:" & srcDir &
                          " --nimcache:" & (cacheDir / name) &
                          " -o:" & outBin & " " & (fixtureDir / name & ".nim"))
  doAssert rc == 0, name & " compile failed:\n" & o
  doAssert fileExists(outBin), name & " produced no binary at " & outBin

proc runWithDeadline*(bin: string; args: seq[string]; ms: int):
    tuple[finished: bool; line: string] =
  ## Spawn `bin`, and give up on it after `ms` milliseconds. The child is
  ## killed on the timeout path so a RED run cannot leave a process behind.
  ##
  ## The driver fixtures print one short line, well inside the pipe buffer, so
  ## it is still queued and readable after the child exits.
  let p = startProcess(bin, args = args, options = {poUsePath})
  defer: p.close()
  var waited = 0
  while waited < ms and p.peekExitCode() == -1:
    sleep(25)
    waited += 25
  if p.peekExitCode() == -1:
    p.terminate()
    discard p.waitForExit()
    return (finished: false, line: "")
  # The child has exited, so every write end is closed and a zero-length
  # read is genuine EOF. A local loop rather than `crisol/toolexec`: this
  # harness is the independent check on that module, so it must not share it.
  var output = ""
  var buf = newString(4096)
  let s = p.outputStream
  while true:
    let n = s.readData(addr buf[0], buf.len)
    if n <= 0: break
    output.add buf[0 ..< n]
  (finished: true, line: output.strip())
