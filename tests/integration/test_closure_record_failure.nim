## test_closure_record_failure.nim — issue #5 (writer hole): a compile that
## SUCCEEDS but whose closure cannot be recorded must not leave the previous
## depgraph entry in place.
##
## The stable binary is copied before the closure is extracted, so if
## extraction fails and the runner merely swallows the error, nothing
## recompiles next run and the PREVIOUS entry — arbitrarily stale — keeps
## being served as fresh. A reader cannot tell that entry from a valid one.
##
## Real-compile drive through execute(). The recording failure is induced the
## one way it can arise without a mock: the entrypoint lives OUTSIDE every
## tracked root, so its extracted closure is empty and updateEntry refuses it
## (cekInternal). The graph is pre-seeded with a fresh-looking entry for the
## same key — exactly what the old `except: discard` would have preserved.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_closure_record_failure.nim

import std/[os, sets, tables, times, unittest]
import std/posix as posix_mod
import crisol/[types, runner, depgraph, planner]

proc fixtureDir(): string =
  currentSourcePath().parentDir.parentDir / "fixtures"

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_closure_record_" & tag & "_" &
                           $posix_mod.getpid() & "_" &
                           $int64(epochTime() * 1_000_000))
  createDir(result)

proc makeCfg(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
         timeoutSecs: 60, compileTimeoutSecs: 120, maxOutputBytes: 65_536)

suite "closure recording failure after a successful compile (issue #5)":

  test "the previous entry is invalidated, so the next plan recompiles":
    let root = makeTempRoot("invalidate")
    defer: removeDir(root)
    let cfg = makeCfg(root)
    # Entrypoint OUTSIDE projectRoot (and no depRoots): its closure filters
    # to the empty set, which updateEntry refuses.
    let ep    = Entrypoint(path: fixtureDir() / "pass_always.nim",
                           group: "default", flags: @[])
    let fHash = flagHash(ep.flags)
    let key   = (ep.path, fHash)

    # Seed a FRESH-looking prior entry: an existing file, its current content
    # hash, current protocol major. Under the old writer this entry survived
    # the failed recording and made run 2 cdSkipFresh.
    var graph = initDepGraph("")
    let seededClosure = toHashSet([ep.path])
    graph.updateEntry(ep.path, fHash, seededClosure,
                      closureContentHash(@[ep.path], root), CrisolProtocolMajor)
    createDir(root / ".crisol")
    saveDepGraph(graph, cfg)

    let plan1 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan1.entrypoints[0].edecision == edNeverBuilt
    let r1 = execute(plan1, config = cfg, graph = graph,
                     nimVersion = "", showProgress = false)
    check r1.len == 1
    check r1[0].outcome == oPassed            # compile + run succeeded

    # Recording failed → the seeded entry must be GONE, in memory and on disk.
    check key notin graph.entries
    check key notin loadDepGraph(cfg, "").entries

    # And the next plan must recompile rather than trust the stale entry.
    let plan2 = plan(cfg, @[ep], graph, nimVersion = "")
    check plan2.entrypoints[0].edecision == edStale
    check plan2.entrypoints[0].reason == "no closure record in dep graph"
