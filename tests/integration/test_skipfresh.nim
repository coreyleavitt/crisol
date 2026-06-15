## test_skipfresh.nim — D6: integration test for compile-avoidance (skip-fresh).
##
## Uses the pass_always.nim fixture.
## Run 1: binary absent → cdNeverBuilt, compile+run → oPassed, graph saved.
## Run 2: binary present, graph fresh → cdSkipFresh, compile skipped, run → oPassed,
##         result.compileSkipped = true.
## Also verifies forceCompile overrides freshness → cdStale on second run.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_skipfresh.nim

import std/[os, sets, tables, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

proc makeIsolatedConfig(root: string): Config =
  ## Build a Config that uses an isolated stateDir under `root`.
  Config(
    projectRoot:        root,
    stateDir:           ".crisol_skipfresh_test",
    timeoutSecs:        60,
    compileTimeoutSecs: 120,
    maxOutputBytes:     65_536,
    jobs:               1,
  )

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "skip-fresh — compile avoidance integration":

  test "run 1: binary absent → cdNeverBuilt, compileSkipped=false, oPassed":
    let tmpRoot = getTempDir() / "crisol_skipfresh_1"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = mkEp(fixtureDir() / "pass_always.nim")
    let cfg = makeIsolatedConfig(tmpRoot)

    # First run: empty graph, binary does not exist yet.
    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    check p.entrypoints.len == 1
    check p.entrypoints[0].edecision == edNeverBuilt

    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "",
                          showProgress = false)
    check results.len == 1
    check results[0].outcome == oPassed
    check results[0].compileSkipped == false

    # After execute, the depgraph should have been saved and should now have
    # an entry for this ep.
    let graphAfter = loadDepGraph(cfg, "")
    let fHash = flagHash(ep.flags)
    let key = (ep.path, fHash)
    check key in graphAfter.entries

  test "run 2: binary present, graph fresh → cdSkipFresh, compileSkipped=true, oPassed":
    let tmpRoot = getTempDir() / "crisol_skipfresh_2"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = mkEp(fixtureDir() / "pass_always.nim")
    let cfg = makeIsolatedConfig(tmpRoot)

    # Run 1: compile and record.
    var graph1 = initDepGraph("")
    let p1 = plan(cfg, @[ep], graph1, "", false)
    let results1 = execute(p1, config = cfg, graph = graph1,
                           nimVersion = "",
                           showProgress = false)
    check results1.len == 1
    check results1[0].outcome == oPassed

    # Run 2: load saved graph, plan should give cdSkipFresh.
    let graph2 = loadDepGraph(cfg, "")
    let fHash = flagHash(ep.flags)
    check (ep.path, fHash) in graph2.entries

    var graph2Mut = graph2
    let p2 = plan(cfg, @[ep], graph2Mut, "", false)
    check p2.entrypoints.len == 1
    check p2.entrypoints[0].edecision == edRunFresh

    let results2 = execute(p2, config = cfg, graph = graph2Mut,
                           nimVersion = "",
                           showProgress = false)
    check results2.len == 1
    check results2[0].outcome == oPassed
    check results2[0].compileSkipped == true

  test "forceCompile overrides freshness → cdStale on second run":
    let tmpRoot = getTempDir() / "crisol_skipfresh_3"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = mkEp(fixtureDir() / "pass_always.nim")
    let cfg = makeIsolatedConfig(tmpRoot)

    # Run 1: compile and record.
    var graph1 = initDepGraph("")
    let p1 = plan(cfg, @[ep], graph1, "", false)
    let results1 = execute(p1, config = cfg, graph = graph1,
                           nimVersion = "",
                           showProgress = false)
    check results1[0].outcome == oPassed

    # Run 2 with forceCompile=true: must be cdStale (not cdSkipFresh).
    let graph2 = loadDepGraph(cfg, "")
    var graph2Mut = graph2
    let p2 = plan(cfg, @[ep], graph2Mut, "", true)   # forceCompile=true
    check p2.entrypoints.len == 1
    check p2.entrypoints[0].edecision == edStale

    let results2 = execute(p2, config = cfg, graph = graph2Mut,
                           nimVersion = "",
                           showProgress = false)
    check results2.len == 1
    check results2[0].outcome == oPassed
    check results2[0].compileSkipped == false

  test "two entrypoints: mix of cdNeverBuilt and cdSkipFresh":
    ## Run a second pass_always alongside a fresh one to confirm
    ## mixed-decision pools work correctly.
    let tmpRoot = getTempDir() / "crisol_skipfresh_4"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep1 = mkEp(fixtureDir() / "pass_always.nim")
    let ep2 = Entrypoint(path: fixtureDir() / "pass_always.nim",
                         group: "test2",
                         flags: @["-d:skiptest"])  # different flags → different slug

    let cfg = makeIsolatedConfig(tmpRoot)

    # Run 1 for ep1 only.
    var graph1 = initDepGraph("")
    let p1 = plan(cfg, @[ep1], graph1, "", false)
    let r1 = execute(p1, config = cfg, graph = graph1,
                     nimVersion = "", showProgress = false)
    check r1[0].outcome == oPassed

    # Run 2: ep1 should be fresh, ep2 should be never-built.
    let graph2 = loadDepGraph(cfg, "")
    var graph2Mut = graph2
    let p2 = plan(cfg, @[ep1, ep2], graph2Mut, "", false)
    check p2.entrypoints[0].edecision == edRunFresh
    check p2.entrypoints[1].edecision == edNeverBuilt

    let r2 = execute(p2, config = cfg, graph = graph2Mut,
                     nimVersion = "", showProgress = false)
    check r2.len == 2
    check r2[0].outcome == oPassed
    check r2[0].compileSkipped == true
    check r2[1].outcome == oPassed   # ep2 compiled fresh (fail_compile would be oCompileFailed)
    check r2[1].compileSkipped == false
