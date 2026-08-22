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

import std/[os, sets, tables, times, unittest, json, strutils]
import std/posix as posix_mod
import crisol/[types, runner, depgraph, narrow, planner]

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

suite "closure records @p bodies with leading '..' (shortest-relative-path / realpath-canonicalized)":

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

  test "trigger C: a symlinked dep-root's realpath-relative @m body (shallow entrypoint) is recorded at its lexical path":
    ## Same physical layout as trigger B (a depRoot reached through a
    ## symlink into an outside "CAS" dir, put on the search path via
    ## --path:_deps/dep/src, imported as `import dep`), but the entrypoint
    ## is SHALLOW (root/tests/t.nim, one level below root) instead of nested
    ## 8-9 levels deep. Nim's mangler always tries the entrypoint-dir-relative
    ## candidate (`@m<relpath-from-epDir>`) first and only switches to the
    ## search-path-relative candidate (`@p<relpath-from-searchRoot>`) when
    ## that is STRICTLY shorter; with a shallow entrypoint dir, `@m`'s
    ## relative path (a couple of ".." components up to the temp dir, then
    ## down into the CAS) is not longer than `@p`'s, so the compiler emits
    ## `@m` here — confirmed empirically against this exact fixture shape
    ## (`@m..@s..@s<casDirName>@sdep@ssrc@sdep.nim.c.o`).  Because the `@m`
    ## body is computed from realpath(epDir) to the realpath-canonicalized
    ## source, `(epDir / body).normalizedPath` resolves to the dep's REAL
    ## path (through the CAS), which is NOT under any tracked root — so the
    ## dep must be recovered via the index fallback, not the plain
    ## `@m` candidate.
    let root = makeTempRoot("triggerC")
    defer: removeDir(root)
    let cas = makeTempRoot("triggerC_cas")
    defer: removeDir(cas)

    createDir(cas / "dep" / "src")
    writeFile(cas / "dep" / "src" / "dep.nim", "proc depValue*(): int = 7\n")

    createDir(root / "_deps")
    createSymlink(cas / "dep", root / "_deps" / "dep")

    # Shallow entrypoint: root/tests/t.nim, one level below root — NOT
    # nested like trigger B.
    createDir(root / "tests")
    writeFile(root / "tests" / "t.nim", """
import dep
doAssert depValue() == 7
""")

    var cfg = makeCfg(root)
    cfg.depRoots = @[root / "_deps" / "dep"]
    let epPath = "tests/t.nim"
    let ep = Entrypoint(path: epPath, group: "default",
                        flags: @["--path:" & (root / "_deps" / "dep" / "src")])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "trigger C compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    # Sanity-pin the mangled shape this fixture actually produces, so a
    # future Nim upgrade that changes the mangling heuristic fails loudly
    # here rather than silently testing the wrong branch (@p instead of @m).
    let cacheDir = cachePath(ep, cfg)
    let manifestPath = cacheDir / binName(ep) & ".json"
    check fileExists(manifestPath)
    if fileExists(manifestPath):
      let manifest = parseFile(manifestPath)
      var sawMangledDep = false
      var mangledSeen = ""
      for node in manifest{"link"}:
        let base = node.getStr("").extractFilename
        if base.startsWith("@m") and base.endsWith("dep.nim.c.o"):
          sawMangledDep = true
          mangledSeen = base
      echo "trigger C observed mangled dep entry: ", mangledSeen
      check sawMangledDep

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check "_deps/dep/src/dep.nim" in closure
    check epPath in closure

suite "closure does not over-select an unrelated decoy for an untracked out-of-root @m import":

  test "an untracked out-of-root import via a relative '../../' path does not pull in an unrelated in-tree decoy sharing its suffix":
    ## `proj/tests/t.nim` imports `../../other/lib` — a module that lives
    ## OUTSIDE projectRoot entirely (a sibling of `proj`, literally named
    ## "other"), is not configured as (or under) any depRoot, and so has no
    ## tracked root of its own — the exact review-round repro shape.
    ## `proj/src/other/lib.nim` is an UNRELATED in-tree module that happens
    ## to share the suffix "other/lib.nim" with the untracked import's
    ## mangled body ("../../other/lib.nim"). Pre-fix, resolveMangledAll's
    ## @m fallback suffix-matched the escaped body against the whole
    ## SourceIndex once the plain candidate fell outside every tracked root,
    ## wrongly pulling the decoy into the closure. Post-fix (exact-realpath
    ## `byReal` lookup) the decoy must never be selected, and the entrypoint
    ## must still compile and run.
    let parent = makeTempRoot("f1_untracked_decoy")
    defer: removeDir(parent)
    let root = parent / "proj"
    createDir(root)

    # The untracked module actually imported: parent/other/lib.nim, a
    # sibling of `proj` (projectRoot), named "other" — so the compiler's
    # shortest-relative-path @m body is exactly "../../other/lib.nim".
    createDir(parent / "other")
    writeFile(parent / "other" / "lib.nim", "proc libValue*(): int = 9\n")

    # The unrelated in-tree decoy, sharing the suffix "other/lib.nim".
    createDir(root / "src" / "other")
    writeFile(root / "src" / "other" / "lib.nim", "proc libValue*(): int = -1\n")

    createDir(root / "tests")
    writeFile(root / "tests" / "t.nim", """
import ../../other/lib
doAssert libValue() == 9
""")

    let cfg = makeCfg(root)
    let ep = Entrypoint(path: "tests/t.nim", group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "untracked-decoy compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check "src/other/lib.nim" notin closure
    check "tests/t.nim" in closure

suite "closure resolves @m bodies through a symlinked entrypoint FILE by the file's real directory":

  test "a symlinked entrypoint file's @m body is recorded at the real sibling, not a bogus lexical one":
    ## `root/other/t.nim` is the entrypoint's REAL file (imports `helper`,
    ## `root/other/helper.nim`); `root/tests/t.nim` is a SYMLINK to it, and
    ## the CONFIGURED entrypoint is the symlink path `tests/t.nim`. `root/
    ## tests` itself is an ORDINARY directory — no symlink on any of its
    ## own path components, only the FILE inside it is one. Nim's `@m` base
    ## is `parentDir(realpath(ENTRYPOINT FILE))`, i.e. `root/other`, NOT
    ## `realpath` of the entrypoint's (already-non-symlinked) directory —
    ## so the compiler mangles `helper.nim`'s @m body relative to
    ## `root/other`, decoding to the sibling `other/helper.nim`.
    ##
    ## Before the fix, `realEpDir` was computed as `expandFilename(epDir)`
    ## (epDir = `root/tests`, itself no symlink), which is unaffected by a
    ## symlink on the FILE component alone — so the code wrongly took the
    ## case-1 (lexical) branch and recorded the bogus, nonexistent
    ## `tests/helper.nim`. `closureContentHash` then raised on the missing
    ## file on EVERY subsequent run, permanently invalidating the entry
    ## ("could not record its source closure … force-selected" every run,
    ## precision lost for this entrypoint).
    let root = makeTempRoot("r4_1_symlinked_ep_file")
    defer: removeDir(root)

    createDir(root / "other")
    createDir(root / "tests")
    writeFile(root / "other" / "helper.nim", "proc helperValue*(): int = 11\n")
    writeFile(root / "other" / "t.nim", """
import helper
doAssert helperValue() == 11
""")
    createSymlink(root / "other" / "t.nim", root / "tests" / "t.nim")

    let cfg = makeCfg(root)
    let ep = Entrypoint(path: "tests/t.nim", group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "symlinked-entrypoint-file compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    # If recordClosure failed (e.g. closureContentHash raised on the bogus
    # "tests/helper.nim"), the entry is invalidated and removed — its
    # PRESENCE here is direct evidence recording succeeded with no warning.
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check "other/helper.nim" in closure
    check "tests/helper.nim" notin closure

    # A stable, un-invalidated entry must not force a recompile next run.
    let p2 = plan(cfg, @[ep], graph, nimVersion = "")
    check p2.entrypoints[0].edecision == edRunFresh

suite "closure resolves @m bodies through a symlinked entrypoint DIRECTORY via a real compile (case 2)":

  test "src/foo.nim is recorded when the entrypoint's directory is a symlink to a shallower directory inside the project":
    ## `root/a/b/tests` is a SYMLINK to `root/real_tests` (a shallower
    ## sibling of `a`, still inside the project) holding the entrypoint
    ## `t.nim`, which imports `root/src/foo.nim` via a plain relative
    ## import ("../src/foo") — resolved (and @m-mangled) from the
    ## entrypoint FILE's REAL directory (`root/real_tests`), not its
    ## lexical one (`root/a/b/tests`), confirmed empirically against a real
    ## `nim c` of this exact fixture shape (`@m..@ssrc@sfoo.nim.c.o`). This
    ## is the real-compile counterpart of the synthetic (manifest-only) pin
    ## in tests/unit/test_source_index.nim — same case-2 mechanism, driven
    ## through execute() end-to-end instead of a hand-written nimcache JSON.
    let root = makeTempRoot("case2_dir_real_compile")
    defer: removeDir(root)

    createDir(root / "real_tests")
    createDir(root / "src")
    createDir(root / "a" / "b")
    writeFile(root / "src" / "foo.nim", "proc fooValue*(): int = 42\n")
    writeFile(root / "real_tests" / "t.nim", """
import ../src/foo
doAssert fooValue() == 42
""")
    createSymlink(root / "real_tests", root / "a" / "b" / "tests")

    let cfg = makeCfg(root)
    let ep = Entrypoint(path: "a/b/tests/t.nim", group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "symlinked-entrypoint-dir compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check "src/foo.nim" in closure

suite "closure resolves through a projectRoot that is itself a symlinked directory":

  test "config.projectRoot given as a symlink records tests/t.nim, tests/sib.nim, src/foo.nim (project-relative lexical) and a second plan() is edRunFresh":
    ## `config.projectRoot` need not itself be a plain directory — a caller
    ## (e.g. milpa handing crisol a CAS-backed checkout) may pass a SYMLINKED
    ## path as projectRoot directly.  `buildSourceIndex` records its walk
    ## roots from `config.projectRoot.absolutePath` (the LEXICAL path, not
    ## its realpath), so the index — and hence the recorded closure — must
    ## stay expressed relative to the symlinked lexical root the caller gave
    ## us, not the real directory it points at.
    ##
    ## `<tmp>/link_proj` -> `<tmp>/deep/er/real_proj`; the entrypoint
    ## `tests/t.nim` imports a relative sibling `src/foo` (one directory up)
    ## and a same-directory sibling `sib`.
    let parent = makeTempRoot("symlinked_projectroot")
    defer: removeDir(parent)

    let realProj = parent / "deep" / "er" / "real_proj"
    createDir(realProj / "src")
    createDir(realProj / "tests")
    writeFile(realProj / "src" / "foo.nim", "proc fooValue*(): int = 42\n")
    writeFile(realProj / "tests" / "sib.nim", "proc sibValue*(): int = 7\n")
    writeFile(realProj / "tests" / "t.nim", """
import ../src/foo
import sib
doAssert fooValue() == 42
doAssert sibValue() == 7
""")

    let linkProj = parent / "link_proj"
    createSymlink(realProj, linkProj)

    let cfg = makeCfg(linkProj)
    let ep = Entrypoint(path: "tests/t.nim", group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "symlinked-projectRoot compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

    let key = (ep.path, flagHash(ep.flags))
    let loaded = loadDepGraph(cfg, "")
    check key in loaded.entries
    let closure = loaded.entries[key].closure

    check closure == toHashSet(["tests/t.nim", "tests/sib.nim", "src/foo.nim"])

    # A stable, un-invalidated entry must not force a recompile next run.
    let p2 = plan(cfg, @[ep], graph, nimVersion = "")
    check p2.entrypoints[0].edecision == edRunFresh
