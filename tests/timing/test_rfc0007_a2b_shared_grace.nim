## test_rfc0007_a2b_shared_grace.nim — rfc-0007 A2b acceptance: interrupt
## teardown of N hung slots completes in ONE shared grace window, not N
## sequential ones.
##
## This is the RUNNER-level counterpart to
## tests/conformance/test_conformance_timing.nim's item-4 case, which
## proves the same property at the raw Supervisor-primitive level (§1
## `requestStop`/`next`/`forceKill`). That test proves the CONTRACT holds;
## this one proves the PRODUCT runner (`execute()`) actually gets the
## benefit — the "three code paths become one" acceptance the A2b bullet
## names explicitly: the interrupt path's teardown must not regress into
## the pre-A2b per-slot wait4/killpg loop's N-sequential-windows shape.
##
## Strategy: N term_ignores.nim entrypoints (SIGTERM is ignored — every one
## MUST be escalated to a forced kill, never dies cooperatively), jobs=N so
## all N run concurrently, a watcher process SIGINTs the test process after
## a generous compile+startup budget, and the wall-clock from execute()'s
## own start to its return is bounded well under N sequential grace windows
## would require.
##
## GATING: quits 0 immediately when CRISOL_TIMING_TESTS is unset/empty —
## see tests/timing/test_rlimits_timing.nim for the full rationale.
##
## Run with:
##   ./dev timing
## or, for this file alone:
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
##     --path:src tests/timing/test_rfc0007_a2b_shared_grace.nim

import std/[os, unittest, monotimes, times]
import std/posix
import crisol/types
import crisol/runner
import crisol/depgraph
import crisol/process/types as ptypes

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

proc fixtureDir(): string =
  currentSourcePath().parentDir().parentDir() / "fixtures"

proc mkEp(path: string; flags: seq[string]): Entrypoint =
  Entrypoint(path: path, group: "timing", flags: flags)

const
  N               = 3
  WatcherDelayMs  = 6_000
    ## Generous budget for N concurrent trivial `nim c` invocations to
    ## finish compiling and for each term_ignores binary to install its
    ## SIG_IGN handler before the signal lands — matches the fixed-delay
    ## convention the rest of tests/timing/ already uses (e.g.
    ## test_rfc0007_a1f_limit_timing.nim's compile-interrupt case).

suite "rfc-0007 A2b — interrupt teardown of N hung slots shares ONE grace window":

  test "3 term_ignores entrypoints, interrupted together, tear down well under N sequential windows":
    let fd = fixtureDir()
    # Distinct flags per copy so each gets its OWN nimcache/binary (the
    # common, non-duplicateSlugs path) — N genuinely independent compiles
    # and N genuinely independent run children, not one binary shared
    # across slots.
    var eps: seq[Entrypoint]
    for i in 0 ..< N:
      eps.add mkEp(fd / "term_ignores.nim", @["-d:CRISOL_A2B_GRACE_" & $i])
    let cfg = Config(jobs: N, compileTimeoutSecs: 60, timeoutSecs: 60)
    let p   = plan(cfg, eps, emptyDepGraph())
    var g   = emptyDepGraph()

    let myPid = getpid()
    let watcherPid = fork()
    check watcherPid >= 0
    if watcherPid == 0:
      # Watcher: NOT an entrypoint child — signals the TEST PROCESS itself,
      # which owns its own Supervisor for this execute() call
      # (installSignals = true, below).
      os.sleep(WatcherDelayMs)
      discard kill(myPid, SIGINT)
      exitnow(0)

    var interrupted = false
    let t0 = getMonoTime()
    let results = execute(p, config = cfg, graph = g,
                          interruptedOut = addr interrupted,
                          installSignals = true)
    let elapsed = getMonoTime() - t0

    var ws: cint = 0
    discard waitpid(watcherPid, ws, 0)

    check interrupted
    check results.len == N
    for r in results:
      # Every entrypoint must have reached its run phase (all N admit
      # immediately under jobs == N) and be attributed as an escalated
      # runner-interrupt kill: term_ignores installs SIG_IGN for SIGTERM as
      # the first line of main, so a cooperative death is not possible —
      # every one of the N MUST be escalated to forceKill.
      check r.run.kind == ptypes.pkRan
      check r.run.res.cause.by == ptypes.cbRunner
      check r.run.res.cause.reason == ptypes.krInterrupt
      check r.run.res.cause.escalated == true

    echo "  observed: ", N, " hung slots interrupted together; execute() ",
         "returned ", elapsed.inMilliseconds, " ms after its own start ",
         "(watcher delay: ", WatcherDelayMs, " ms, grace window: ",
         GracePeriodMs, " ms)"
    # ONE shared grace window, not N sequential ones: N serial
    # (grace + kill-response) cycles would each cost roughly a full
    # GracePeriodMs (term_ignores never dies cooperatively) BEFORE even
    # counting kill/reap latency, pushing total elapsed to
    # WatcherDelayMs + N*GracePeriodMs or worse. A shared window bounds it
    # at WatcherDelayMs + (small constant number of) GracePeriodMs
    # regardless of N. This bound sits well below the N=3 sequential floor
    # (WatcherDelayMs + 3*GracePeriodMs) while tolerating scheduler noise.
    check elapsed < initDuration(milliseconds = WatcherDelayMs + GracePeriodMs * 2)
