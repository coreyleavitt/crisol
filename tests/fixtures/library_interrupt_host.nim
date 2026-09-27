## library_interrupt_host.nim — a library host that calls `crisol/api.
## runTests` with `installSignals = true` and is interrupted while crisol is
## still planning (R12-D3). The test signals it and checks how it ends.
##
## argv: <project root>
##
## Before the run, the host installs a handler of its own for SIGINT and
## SIGTERM (a marker that records that it fired). It then runs the project
## at <project root> through the public API, and when `runTests` returns it
## prints, one fact per line:
##
##   status=<RunStatus> exitCode=<int> interrupted=<bool>
##   restored=<bool>     both of the host's handlers are back in place
##   markerFired=<bool>  the host's handler saw the signal (crisol did not)
##
## and exits 0. A run that never returns holds this process until the test
## kills it.

when defined(posix):
  import std/[os, posix]
  import crisol/api

  proc sigactionRaw(signum: cint; act: ptr Sigaction; oact: ptr Sigaction): cint
    {.importc: "sigaction", header: "<signal.h>".}
    ## `ptr` parameters, so a NULL `act` is a pure query (std/posix's own
    ## overloads cannot express one).

  var markerFired {.global, volatile.}: bool

  proc marker(signum: cint) {.noconv.} =
    markerFired = true

  proc disposition(signum: cint): pointer =
    var cur: Sigaction
    discard sigactionRaw(signum, nil, addr cur)
    cast[pointer](cur.sa_handler)

  proc installMarker(signum: cint) =
    var sa: Sigaction
    sa.sa_handler = marker
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigactionRaw(signum, addr sa, nil)

  let args = commandLineParams()
  doAssert args.len == 1, "usage: library_interrupt_host <project root>"
  let root = args[0]
  installMarker(SIGINT)
  installMarker(SIGTERM)
  setCurrentDir(root)
  let rr = runTests(RunOptions(configPath: root / "crisol.kdl",
                               jobs: 1,
                               noCache: true,
                               manageLock: false,
                               persist: false,
                               installSignals: true))
  echo "status=", rr.status, " exitCode=", rr.exitCode,
       " interrupted=", rr.interrupted
  echo "restored=", disposition(SIGINT) == cast[pointer](marker) and
                    disposition(SIGTERM) == cast[pointer](marker)
  echo "markerFired=", markerFired
  flushFile(stdout)
  quit(0)
else:
  quit(64)
