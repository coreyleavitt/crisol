## test_rfc0007_a1f_limit_timing.nim — rfc-0007 A1f: the two authorship-
## breadth cases that need real wall-clock time and therefore belong on the
## serial timing leg, not tests/integration/:
##
##   1. SIGXCPU requested+achieved — needs a real CPU burn to trip the
##      kernel's RLIMIT_CPU deterministically (mirrors
##      tests/timing/test_rlimits_timing.nim's own cpu case, but driven
##      through execute() so the assertion is on Cause, not a raw signal
##      number). The requested-vs-unrequested PAIR the RFC bullet asks for:
##      the unrequested half (an external SIGXCPU with no limit requested)
##      is fast/deterministic and lives in
##      tests/integration/test_rfc0007_a1f_authorship.nim instead.
##   2. Compile-interrupt — needs a real multi-second compile
##      (compile_interrupt.nim's `staticExec("sleep 5")`) to give a SIGINT
##      a reliable window to land while `nim c` is still alive.
##
## GATING: quits 0 immediately when CRISOL_TIMING_TESTS is unset/empty —
## see tests/timing/test_rlimits_timing.nim for the full rationale.
##
## Run with:
##   ./dev timing
## or, for this file alone:
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
##     --path:src tests/timing/test_rfc0007_a1f_limit_timing.nim

import std/[options, os, unittest]
import std/posix
import crisol/types
import crisol/runner
import crisol/depgraph
import crisol/sandbox
import crisol/signals
import crisol/process/types as ptypes

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

# ---------------------------------------------------------------------------
# Suite 1 — SIGXCPU requested+achieved (real CPU burn)
# ---------------------------------------------------------------------------

suite "rfc-0007 A1f — SIGXCPU requested+achieved via execute() (timing)":

  test "rlimit_cpu with a 1s RLIMIT_CPU: cbLimit(lkCpu), SIGXCPU":
    ## Generous wall-clock budget (10s) so CI scheduler noise cannot cause a
    ## false timeout — SIGXCPU itself fires within 1-2 CPU-seconds on any
    ## host, well inside that budget.
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "rlimit_cpu.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 10)
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let spec = resolveSandbox(level = hlIsolated,
      rlimits = RlimitOverrides(limitCpu: some(1'i64)))
    let results = execute(p, config = cfg, graph = g, cache = cacheDisabled(spec))

    check results.len == 1
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGXCPU)
    check results[0].run.res.cause.by == ptypes.cbLimit
    check results[0].run.res.cause.limit == ptypes.lkCpu

# ---------------------------------------------------------------------------
# Suite 2 — compile-interrupt
# ---------------------------------------------------------------------------

suite "rfc-0007 A1f — compile-interrupt attributes correctly (timing)":

  test "SIGINT during compile: oKilled, compile.cause runner/interrupt, run phase never started":
    ## compile_interrupt.nim holds `nim c` open ~5-6 real wall-clock seconds
    ## (a compile-time `staticExec("sleep 5")`) — a watcher fork sends SIGINT
    ## to THIS test process 1.5s in, comfortably inside that window, well
    ## before the compile could ever finish on its own. `installSignalHandlers`
    ## + `interruptedOut` is the same in-process mechanism
    ## tests/integration/test_signal.nim's suite 2 already uses for a normal
    ## (non-interrupted) run; here the signal is real and lands mid-compile.
    installSignalHandlers()
    clearSignal()

    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "compile_interrupt.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 60, timeoutSecs: 60)
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()

    let myPid = getpid()
    let watcherPid = fork()
    check watcherPid >= 0
    if watcherPid == 0:
      # Watcher: NOT the entrypoint child — signals the TEST PROCESS itself,
      # which installed the handler above and will observe it inside
      # execute()'s poll loop.
      os.sleep(1500)
      discard kill(myPid, SIGINT)
      exitnow(0)

    var interrupted = false
    let results = execute(p, config = cfg, graph = g, interruptedOut = addr interrupted)

    var ws: cint = 0
    discard waitpid(watcherPid, ws, 0)

    check interrupted
    check results.len == 1  # §2 emission rule: compiling->pkRan is emitted
    check results[0].outcome == oKilled
    check results[0].compile.kind == ptypes.pkRan
    check results[0].compile.res.cause.by == ptypes.cbRunner
    check results[0].compile.res.cause.reason == ptypes.krInterrupt
    check results[0].run.kind == ptypes.pkSkipped  # run phase never started

when isMainModule:
  echo "test_rfc0007_a1f_limit_timing done"
