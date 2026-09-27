## pipe_holder.nim — a tool whose descendant outlives it holding its output
## pipes (R3-12), and a plain hang that reports its pid (R5-19).
##
## Modes, from argv (the caller passes a pid-file path as the second arg):
##
##   hold <pidfile>
##     Print an answer, start ITSELF in `grandchild` mode with this process's
##     own stdin/stdout/stderr (so the grandchild inherits the capture pipes,
##     the way a compiler server or a backgrounded helper does), wait until
##     the grandchild has written its pid, and exit 0. The direct child is
##     gone; the pipes are not at EOF.
##   grandchild <pidfile>
##     Write this process's pid to <pidfile>, then sleep. Writes nothing to
##     the inherited pipes: it only holds them.
##   hang <pidfile>
##     Write this process's pid to <pidfile>, then sleep. Cooperative with
##     SIGTERM (the default action), so a terminated run ends at once.
##   exit
##     Exit 0 immediately (a zombie maker for the observation self-check).
##   fail
##     Exit 64 immediately (a run that ran and failed, R14-D3).
##
## Every sleep is bounded (`LifetimeMs`), so a RED run cannot leak a process
## for longer than that. No `std/posix`: the pid comes from `std/os`.

import std/[os, osproc]

const LifetimeMs = 30_000

proc writePid(path: string) =
  ## Atomic from the reader's side: the file appears whole or not at all.
  let tmp = path & ".tmp"
  writeFile(tmp, $getCurrentProcessId())
  moveFile(tmp, path)

let args = commandLineParams()
let mode = if args.len > 0: args[0] else: ""

case mode
of "hold":
  let pidFile = args[1]
  echo "pipe_holder answer"
  flushFile(stdout)
  let gc = startProcess(getAppFilename(), args = ["grandchild", pidFile],
                        options = {poParentStreams})
  var waited = 0
  while not fileExists(pidFile) and waited < 5_000:
    sleep(10)
    waited += 10
  gc.close()   # the handle only; the grandchild keeps running
  quit(if fileExists(pidFile): 0 else: 2)
of "grandchild", "hang":
  writePid(args[1])
  sleep(LifetimeMs)
  quit(0)
of "exit":
  quit(0)
of "fail":
  quit(64)
else:
  quit(64)
