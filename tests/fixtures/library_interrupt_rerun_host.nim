## library_interrupt_rerun_host.nim — a library host that keeps calling
## `crisol/api.runTests` (`installSignals = true`) after an interrupt, the
## shape an IDE or a watch loop has (R13-D2, R13-L3, R13-D1).
##
## argv: <project root> <mode>
##
## `warm`: one plain run, which stores every result in the local cache.
##
## `intr`: run 1, which the test interrupts while crisol is planning (the
## wrapper `nim` on PATH hangs once in the discovery compile); then run 2,
## in the same environment, with no signal at all. Prints:
##
##   run1 status=<RunStatus> exitCode=<int>
##   betweenShutdown=<bool>  `shutdownRequested()` between the runs
##   run2 status=<RunStatus> exitCode=<int>
##   run2 decision=<CacheDecision>      one line per result
##   fingerprint=<nim fingerprint, one line>
##
## `late`: one run with `--verify-cache` at 100%. Every entry is a cache hit,
## so the main execution runs nothing, and the verify pass, after execute()
## has returned, re-runs the tests; the fixture test signals this host (its
## pid is in <project root>/host.pid) when it runs. Prints:
##
##   late status=<RunStatus> exitCode=<int> interrupted=<bool> results=<int>
##
## Each mode then prints `markerFired=<bool>` (the host's own SIGINT/SIGTERM
## handler saw a signal; crisol's should have taken every one) and exits 0.

when defined(posix):
  import std/[options, os, posix, strutils]
  import crisol/api
  import crisol/nimprobe
  import crisol/signals

  var markerFired {.global, volatile.}: bool

  proc marker(signum: cint) {.noconv.} =
    markerFired = true

  proc installMarker(signum: cint) =
    var sa: Sigaction
    sa.sa_handler = marker
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigaction(signum, sa, nil)

  let args = commandLineParams()
  doAssert args.len == 2, "usage: library_interrupt_rerun_host <project root> <mode>"
  let root = args[0]
  let mode = args[1]
  installMarker(SIGINT)
  installMarker(SIGTERM)
  setCurrentDir(root)

  proc opts(): RunOptions =
    RunOptions(configPath: root / "crisol.kdl", jobs: 1, installSignals: true)

  case mode
  of "warm":
    let rr = runTests(opts())
    echo "warm status=", rr.status, " exitCode=", rr.exitCode
  of "intr":
    let r1 = runTests(opts())
    echo "run1 status=", r1.status, " exitCode=", r1.exitCode
    echo "betweenShutdown=", shutdownRequested().isSome
    let r2 = runTests(opts())
    echo "run2 status=", r2.status, " exitCode=", r2.exitCode
    for r in r2.results:
      echo "run2 decision=", r.cacheDecision
    echo "fingerprint=", cachedNimFingerprint().splitLines().join(" ")
  of "late":
    writeFile(root / "host.pid", $getpid())
    var o = opts()
    o.verifyCache = verifySample(pct = 100)
    let rr = runTests(o)
    removeFile(root / "host.pid")
    echo "late status=", rr.status, " exitCode=", rr.exitCode,
         " interrupted=", rr.interrupted, " results=", rr.results.len
  else:
    doAssert false, "unknown mode " & mode
  echo "markerFired=", markerFired
  flushFile(stdout)
  quit(0)
else:
  quit(64)
