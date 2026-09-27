## tool_interrupt_driver.nim — a small crisol-like process that runs one
## bounded tool through `toolexec.runTool` and is interrupted mid-run
## (R11-L4). The test signals it and checks how it ends.
##
## argv: <mode> <tool binary> <pid file>
##
##   supervised
##     Create a Supervisor with `installSignals = true` (the handler a real
##     `crisol run` has installed while it executes), then run
##     `<tool> hang <pid file>` with a 20 s deadline. When runTool returns,
##     print its ending, and exit 128 + the shutdown signal the Supervisor
##     observed (0 if none). A tool that is not ended by the interrupt holds
##     this process for the whole deadline.
##   scope
##     Open an interrupt scope with no Supervisor (`tooltrees.
##     enterInterruptScope`, what the CLI does around its whole invocation,
##     and `runTestsWith` with `installSignals` before it plans) and run the
##     same tool. When runTool returns, print its ending, and exit 128 + the
##     signal the scope's leave answers (0 if none): the handler does not
##     exit the process on a first signal.

import std/[options, os, osproc]
import crisol/[process, signals, toolexec]
import crisol/process/tooltrees
when defined(posix):
  import std/posix  # exitnow

const ToolDeadlineMs = 20_000

let args = commandLineParams()
doAssert args.len == 3, "usage: tool_interrupt_driver <mode> <tool> <pidfile>"
let (mode, tool, pidFile) = (args[0], args[1], args[2])

case mode
of "supervised":
  var sv = initSupervisor(installSignals = true)
  let r = runTool(tool, ["hang", pidFile], "", {}, "", ToolDeadlineMs,
                  MaxToolOutputBytes)
  echo "ending: ", r.ending, ": ", describe(r)
  flushFile(stdout)
  let sig = shutdownRequested()
  let code = if sig.isSome: 128 + sig.get.signum else: 0
  discard sv
  when defined(posix):
    exitnow(cint(code))   # quit() saturates 130/143 to int8 on POSIX
  else:
    quit(code)
of "scope":
  enterInterruptScope()
  let r = runTool(tool, ["hang", pidFile], "", {}, "", ToolDeadlineMs,
                  MaxToolOutputBytes)
  echo "ending: ", r.ending, ": ", describe(r)
  flushFile(stdout)
  let sig = leaveInterruptScope()   # the scope's verdict (R14-S1)
  let code = if sig.isSome: 128 + sig.get.signum else: 0
  when defined(posix):
    exitnow(cint(code))   # quit() saturates 130/143 to int8 on POSIX
  else:
    quit(code)
else:
  quit(64)
