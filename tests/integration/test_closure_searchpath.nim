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

suite "closure records @p bodies with leading '..' (S1: shortest-relative-path / realpath-canonicalized)":

  test "trigger A: in-root relative import shorter from a --path root is recorded":
    ## projectRoot has src/, lib/x.nim, tests/unit/deep/t.nim; t.nim imports
    ## ../../../lib/x (relative to itself). Compiled with --path:<root>/src,
    ## the SHORTEST relative path to lib/x.nim is from src/ ("../lib/x.nim",
    ## one ".."), not from the entrypoint's own directory ("../../../lib/x.nim",
    ## three ".."), so Nim mangles this as an @p body with a leading "..":
    ## @p..@slib@sx.nim. Pre-fix, lookup's whole-body suffix match never
    ## matches (the indexed path never ends with ".../../lib/x.nim"), so
    ## lib/x.nim silently drops out of the closure.
    let root = makeTempRoot("triggerA")
    defer: removeDir(root)

    createDir(root / "src")
    createDir(root / "lib")
    createDir(root / "tests" / "unit" / "deep")
    writeFile(root / "lib" / "x.nim", "proc xValue*(): int = 5\n")
    writeFile(root / "tests" / "unit" / "deep" / "t.nim", """
import ../../../lib/x
doAssert xValue() == 5
""")

    var cfg = makeCfg(root)
    let ep = Entrypoint(path: "tests/unit/deep/t.nim", group: "default",
                        flags: @["--path:" & (root / "src")])

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

    check "lib/x.nim" in closure
    check "tests/unit/deep/t.nim" in closure

  test "trigger B: a symlinked dep-root's realpath-relative @p body is recorded at its lexical path":
    ## <temp>/cas/dep/src/dep.nim lives OUTSIDE the project root; root/_deps/dep
    ## is a symlink to it, configured as a depRoot, and put on the search path
    ## via --path:_deps/dep/src. Because the compiler canonicalizes (realpath)
    ## the resolved source file, the shortest-relative-path computation runs
    ## against the REALPATH, not the symlinked lexical path, producing a
    ## `..`-laden, realpath-relative @p body (this repo's own nkdl nimcache
    ## manifests show exactly this shape for milpa's `_deps/*` -> CAS symlinks).
    ## The closure must record the LEXICAL project-relative path,
    ## "_deps/dep/src/dep.nim", not the realpath.
    let root = makeTempRoot("triggerB")
    defer: removeDir(root)
    let cas = makeTempRoot("triggerB_cas")
    defer: removeDir(cas)

    createDir(cas / "dep" / "src")
    writeFile(cas / "dep" / "src" / "dep.nim", "proc depValue*(): int = 7\n")

    createDir(root / "_deps")
    createSymlink(cas / "dep", root / "_deps" / "dep")

    # The entrypoint is nested deep under root so that Nim's shortest-path
    # mangling picks the @p (search-path-root-relative) candidate over the
    # @m (entrypoint-dir-relative) one: both candidates are realpath-relative
    # and share the same common ancestor (the temp dir housing both `root`
    # and `cas`), so whichever starting directory is SHALLOWER below that
    # ancestor wins. depRootPath/src (`root/_deps/dep/src`, 4 components
    # below root's parent) is far shallower than a deeply-nested entrypoint
    # dir, so @p wins here — reproducing the real shape observed in this
    # repo's own nkdl nimcache manifests (`.crisol/ledger/artifacts/*.ndjson`
    # contain `"@p..@s..@shome@scorey@s.cache@smilpa@s...@ssrc@sgrammar.nim.c"`).
    createDir(root / "tests" / "a" / "b" / "c" / "d" / "e" / "f" / "g" / "h")
    writeFile(root / "tests" / "a" / "b" / "c" / "d" / "e" / "f" / "g" / "h" /
              "test_uses_dep.nim", """
import dep
doAssert depValue() == 7
""")

    var cfg = makeCfg(root)
    cfg.depRoots = @[root / "_deps" / "dep"]
    let epPath = "tests/a/b/c/d/e/f/g/h/test_uses_dep.nim"
    let ep = Entrypoint(path: epPath, group: "default",
                        flags: @["--path:" & (root / "_deps" / "dep" / "src")])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "trigger B compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check "_deps/dep/src/dep.nim" in closure
    check epPath in closure
