## test_closure_searchpath.nim — issue #8: @p closure resolution must not
## depend on guessing the search-path root.
##
## The bug: closure.nim resolved `@p`-mangled nimcache `link` entries by
## trying a fixed list of "tracked roots" (projectRoot, projectRoot/src,
## each depRoot, depRoot/src). Any module reached through some OTHER
## `--path` entry — e.g. a `tests/config.nims` doing
## `switch("path", thisDir())` so `tests/sub/x.nim` can
## `import support/helper` — has no candidate root, so it silently drops
## out of the closure. That breaks `--changed` selection for that module.
##
## This test drives a REAL compile through execute() with EXACTLY that
## amoxtli mechanism (a `tests/config.nims` adding `tests/` to the Nim
## search path), then asserts the closure records the search-path-resolved
## file, and that narrow.selectByDiff actually selects the entrypoint on a
## change to it.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_closure_searchpath.nim

import std/[os, sets, tables, times, unittest]
import std/posix as posix_mod
import crisol/[types, runner, depgraph, narrow]

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_closure_searchpath_" & tag & "_" &
                           $posix_mod.getpid() & "_" &
                           $int64(epochTime() * 1_000_000))
  createDir(result)

proc makeCfg(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
         timeoutSecs: 60, compileTimeoutSecs: 120, maxOutputBytes: 65_536)

suite "closure records search-path (@p, non-tracked-root) deps (issue #8)":

  test "tests/config.nims path-adds tests/ so support/helper resolves via search path, and is recorded":
    let root = makeTempRoot("main")
    defer: removeDir(root)

    # tests/support/helper.nim
    createDir(root / "tests" / "support")
    writeFile(root / "tests" / "support" / "helper.nim",
              "proc helperValue*(): int = 42\n")

    # tests/sub/test_uses_helper.nim — imports support/helper via SEARCH PATH,
    # not relatively (it does NOT live under tests/, so `import support/helper`
    # can only resolve if tests/ is on the Nim search path).
    createDir(root / "tests" / "sub")
    writeFile(root / "tests" / "sub" / "test_uses_helper.nim", """
import support/helper
doAssert helperValue() == 42
""")

    # tests/config.nims — amoxtli's exact mechanism: add thisDir() (tests/)
    # to the search path. Nim loads config.nims/nim.cfg from the project
    # file's directory AND its parent directories, so this should apply to
    # tests/sub/test_uses_helper.nim too.
    writeFile(root / "tests" / "config.nims", """
switch("path", thisDir())
""")

    let cfg = makeCfg(root)
    let ep = Entrypoint(path: "tests/sub/test_uses_helper.nim",
                        group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    # (1) the search-path-resolved dep must be in the closure.
    check "tests/support/helper.nim" in closure
    check "tests/sub/test_uses_helper.nim" in closure

    # (2) load-bearing consequence: a change to the search-path dep must
    # select the entrypoint via selectByDiff.
    let changed = toHashSet(["tests/support/helper.nim"])
    let selection = selectByDiff(@[ep], changed, loaded, root)
    check selection.len == 1
    if selection.len == 1:
      check selection[0].ep.path == ep.path
      check selection[0].reason == srClosureHit
