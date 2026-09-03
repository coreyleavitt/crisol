## test_rfc0007_a4_signals.nim — rfc-0007 A4: crisol/signals.shutdownRequested()
## and its unification with the Supervisor's `weShutdown` wait event.
##
## Before A4, `crisol/signals` installed its OWN sigaction handler
## (`installSignalHandlers`/`pendingSignal`/`clearSignal`) — a second signal
## mechanism entirely independent of `process/posixcore.nim`'s self-pipe
## handler, which is what `runner.execute()`'s Supervisor actually uses (via
## `initSupervisor(installSignals = true)`, since A2b). A4 retires that
## second mechanism and reshapes `crisol/signals`'s public surface to one
## proc, `shutdownRequested(): Option[ShutdownSignal]`, delegating onto
## `crisol/process.globalShutdownSignal()` — a thin, process-global,
## level-triggered view over the SAME state `next()`'s `weShutdown` event
## reads, both stamped by the ONE handler `posixcore.initPosixCore`
## installs.
##
## All real signal delivery happens inside a FORKED child so the
## process-global flag this module reads is never mutated in the test
## runner's own process (a stray `some` here would be silent, sticky, and
## order-dependent across every other suite sharing this binary).

import std/[options, os, posix, strutils, unittest, monotimes, times]
import crisol/signals
import crisol/process

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(): string =
  let tmp = getTempDir() / ("crisol_test_a4_signals_" & $getpid() & "_" & $epochTime().int)
  createDir(tmp)
  tmp

proc pollShutdownRequested(timeoutMs: int): Option[process.ShutdownSignal] =
  ## Poll shutdownRequested() briefly — self-signal delivery is not
  ## guaranteed synchronous by POSIX, even though it is in practice on
  ## Linux for an unmasked, unblocked signal.
  var waited = 0
  result = shutdownRequested()
  while result.isNone and waited < timeoutMs:
    os.sleep(10)
    waited += 10
    result = shutdownRequested()

# ---------------------------------------------------------------------------
# Suite 1 — shutdownRequested() on its own
# ---------------------------------------------------------------------------

suite "rfc-0007 A4 — crisol/signals.shutdownRequested()":

  test "no signal delivered in this process ⇒ shutdownRequested() is none":
    # A fresh forked child that never installs a Supervisor or signals
    # itself — the process-global flag must read none.
    let root = makeTempRoot()
    defer: removeDir(root)
    let resultFile = root / "result.txt"

    let childPid = fork()
    if childPid == 0:
      writeFile(resultFile, if shutdownRequested().isNone: "1" else: "0")
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      check fileExists(resultFile)
      check readFile(resultFile).strip() == "1"

  test "SIGTERM after initSupervisor(installSignals = true) ⇒ shutdownRequested() carries the real signum":
    let root = makeTempRoot()
    defer: removeDir(root)
    let resultFile = root / "result.txt"

    let childPid = fork()
    if childPid == 0:
      var sv = initSupervisor(installSignals = true)
      discard sv   # keep it alive; only its installed handler matters here
      discard kill(getpid(), SIGTERM)
      let sig = pollShutdownRequested(2000)
      let signum = if sig.isSome: sig.get().signum else: -1
      writeFile(resultFile, $signum)
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      check fileExists(resultFile)
      check readFile(resultFile).strip() == $int(SIGTERM)

  test "installSignals = false ⇒ shutdownRequested() stays none":
    ## `initSupervisor(installSignals = false)` must not install any
    ## handler, so the process-global flag stays unset. (The load-bearing
    ## "installSignals=false installs nothing" fact — that `weShutdown`
    ## never fires for such a Supervisor even when signaled — is pinned by
    ## `tests/conformance/test_conformance.nim`'s installSignals=false
    ## suites; this is that fact's `shutdownRequested()` corollary.)
    let root = makeTempRoot()
    defer: removeDir(root)
    let resultFile = root / "result.txt"

    let childPid = fork()
    if childPid == 0:
      var sv = initSupervisor(installSignals = false)
      discard sv
      writeFile(resultFile, if shutdownRequested().isNone: "1" else: "0")
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      check fileExists(resultFile)
      check readFile(resultFile).strip() == "1"

# ---------------------------------------------------------------------------
# Suite 2 — unification: the SAME signal feeds both weShutdown and
# shutdownRequested() (RFC-0007 §1's "feeding both weShutdown and
# RFC-0003's 128+n" acceptance).
# ---------------------------------------------------------------------------

suite "rfc-0007 A4 — shutdownRequested() and weShutdown observe the same signal":

  test "one SIGTERM delivery: next() reports weShutdown with signum N, and shutdownRequested() reports the same N":
    let root = makeTempRoot()
    defer: removeDir(root)
    let resultFile = root / "result.txt"

    let childPid = fork()
    if childPid == 0:
      var sv = initSupervisor(installSignals = true)
      discard kill(getpid(), SIGTERM)
      let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
      let nextSignum = if ev.kind == weShutdown: ev.signal.signum else: -1

      let sig = pollShutdownRequested(2000)
      let globalSignum = if sig.isSome: sig.get().signum else: -1

      writeFile(resultFile, $nextSignum & "," & $globalSignum)
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      check fileExists(resultFile)
      let parts = readFile(resultFile).strip().split(',')
      check parts[0] == $int(SIGTERM)   # next() saw weShutdown with the real signum
      check parts[1] == $int(SIGTERM)   # shutdownRequested() saw the SAME signum
