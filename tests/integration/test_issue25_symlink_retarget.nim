## test_issue25_symlink_retarget.nim — issue #25: a repointed directory link
## on a Nim import path must not serve a stale compile or a stale cached
## result.
##
## A test imports `vend/m` where `vend` is a directory link to `libs/a`. Nim
## canonicalizes every module it opens to its realpath, so the closure records
## `libs/a/m.nim` and never names `vend`. Before the fix, repointing `vend` to
## `libs/b` left every recorded member unchanged on disk: `decideCompile`
## found the closure hash intact and skipped the compile, the plan-time cache
## lookup served the cached PASS, and even `--no-cache` ran the stale binary.
## The closure record now carries every link the resolution crossed (its path
## and its resolved target), and the compile-skip check re-resolves each one.
##
## The link is a junction on Windows and a symlink elsewhere
## (`tests/support/dirlink.nim`), so the case runs on every platform without
## symlink privilege.
##
## What each platform proves. On POSIX, Nim records `libs/a/m.nim`, so the
## first suite's repoint cases fail without the link check (the defect as
## reported). On Windows, Nim's own path canonicalization does not resolve a
## junction: the closure holds `vend/m.nim` as written and the member hash
## alone already sees the repoint, so those cases pass either way there.
## The second suite is what Windows adds: the index walk must see the
## junction as a link, record it with its resolved target (`t:libs/a`), and
## `entryDrift`/`isEntryStale` must see it move. The two CONTROL cases guard
## against over-invalidation on both.
##
## The third suite (R12-S1) puts the link where the index walk once never
## looked: inside a dot-directory, inside a `nimcache`-named directory, and
## inside a dep root declared by a path relative to the project. Each case
## checks the recorded link in the dependency graph, which fails without
## the fix on every platform, and then the repoint, which fails without it
## on POSIX (on Windows the member hash already sees it, as above). No case
## is POSIX-only.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue25_symlink_retarget.nim

import std/[json, options, os, strutils, tables, unittest]
import crisol
import crisol/[config, depgraph, paths]
import ../support/capture
import ../support/dirlink

const ProjectKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const ModA = "proc mval*(): int = 111\n"
const ModB = "proc mval*(): int = 222\n"

const UsesVend = """
import ../../vend/m
doAssert mval() == 111
"""

proc newProject(tag: string): string =
  ## `libs/a/m.nim` (111), `libs/b/m.nim` (222), `vend -> libs/a`, and one
  ## test that imports through `vend` and expects 111.
  result = getTempDir() / ("crisol_issue25_" & tag & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDirLink(result / "vend")
    removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / "libs" / "a")
  createDir(result / "libs" / "b")
  writeFile(result / "crisol.kdl", ProjectKdl)
  writeFile(result / "libs" / "a" / "m.nim", ModA)
  writeFile(result / "libs" / "b" / "m.nim", ModB)
  writeFile(result / "tests" / "unit" / "test_uses_vend.nim", UsesVend)
  createDirLink(result / "libs" / "a", result / "vend")

proc dispose(root: string) =
  removeDirLink(root / "vend")
  removeDir(root)

proc repoint(root, target: string) =
  removeDirLink(root / "vend")
  createDirLink(root / target, root / "vend")

proc runJson(root: string; extra: seq[string] = @[]): tuple[code: int, doc: JsonNode] =
  var code = 0
  let output = captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl", "--jobs", "1",
                     "--json"] & extra))
  checkpoint(output)
  (code: code, doc: parseJson(output.strip()))

proc only(doc: JsonNode): JsonNode =
  doAssert doc["entrypoints"].len == 1, $doc
  doc["entrypoints"][0]

suite "issue #25 — a repointed directory link on an import path":

  test "a plain run after the repoint recompiles and reports the real failure":
    let root = newProject("plain")
    defer: dispose(root)
    let r1 = runJson(root)
    require r1.code == 0
    check only(r1.doc)["outcome"].getStr == "passed"
    repoint(root, "libs/b")
    let r2 = runJson(root)
    check only(r2.doc)["compileSkipped"].getBool == false  # RED: true
    check only(r2.doc)["cached"].getBool == false          # RED: true
    check only(r2.doc)["outcome"].getStr != "passed"       # RED: passed
    check r2.code != 0

  test "--no-cache after the repoint does not reuse the stale binary":
    let root = newProject("nocache")
    defer: dispose(root)
    let r1 = runJson(root, @["--no-cache"])
    require r1.code == 0
    repoint(root, "libs/b")
    let r2 = runJson(root, @["--no-cache"])
    check only(r2.doc)["compileSkipped"].getBool == false  # RED: true
    check only(r2.doc)["outcome"].getStr != "passed"       # RED: passed

  test "repointing back recompiles again and passes":
    let root = newProject("back")
    defer: dispose(root)
    require runJson(root).code == 0
    repoint(root, "libs/b")
    discard runJson(root)
    repoint(root, "libs/a")
    let r3 = runJson(root)
    check only(r3.doc)["outcome"].getStr == "passed"
    check r3.code == 0

  test "a link crossed BEFORE another link on the import path is tracked too":
    # `vend -> libs/a` and `libs/a/sub -> x/sub`: the member is recorded as
    # `x/sub/m.nim`, whose real ancestry never mentions `libs/a`. `vend`
    # is reached through the location of `libs/a/sub` instead.
    let root = newProject("nested")
    defer:
      removeDirLink(root / "libs" / "a" / "sub")
      dispose(root)
    createDir(root / "x" / "sub")
    createDir(root / "libs" / "b" / "sub")
    writeFile(root / "x" / "sub" / "m.nim", ModA)
    writeFile(root / "libs" / "b" / "sub" / "m.nim", ModB)
    createDirLink(root / "x" / "sub", root / "libs" / "a" / "sub")
    writeFile(root / "tests" / "unit" / "test_uses_vend.nim",
              "import ../../vend/sub/m\ndoAssert mval() == 111\n")
    require runJson(root).code == 0
    repoint(root, "libs/b")
    let r2 = runJson(root)
    check only(r2.doc)["compileSkipped"].getBool == false
    check only(r2.doc)["outcome"].getStr != "passed"

  test "CONTROL repointing a link the test never crossed keeps the skip":
    let root = newProject("unrelated")
    defer:
      removeDirLink(root / "other")
      dispose(root)
    createDir(root / "elsewhere")
    createDirLink(root / "libs" / "b", root / "other")
    require runJson(root).code == 0
    removeDirLink(root / "other")
    createDirLink(root / "elsewhere", root / "other")
    let r2 = runJson(root)
    check only(r2.doc)["compileSkipped"].getBool == true
    check only(r2.doc)["cached"].getBool == true

  test "CONTROL an unchanged link keeps the compile skip and the cache hit":
    let root = newProject("control")
    defer: dispose(root)
    require runJson(root).code == 0
    let r2 = runJson(root)
    check only(r2.doc)["compileSkipped"].getBool == true
    check only(r2.doc)["cached"].getBool == true
    check only(r2.doc)["outcome"].getStr == "passed"

suite "issue #25 — the recorded links in the dependency graph":

  test "the entry records the link, isEntryStale sees the repoint, a bad link drops the entry":
    let root = newProject("graph")
    defer: dispose(root)
    require runJson(root, @["--no-cache"]).code == 0
    let (cfg, _) = loadConfig(root / "crisol.kdl")
    let gpath = depgraphPath(cfg)
    let doc = parseFile(gpath)
    check doc["header"]["formatVersion"].getInt == 10
    let entryNode = doc["entries"][0]
    check entryNode["closure"].len == 2
    check entryNode["links"].len == 1
    check entryNode["links"][0]["path"].getStr == "vend"
    check entryNode["links"][0]["target"].getStr == "t:libs/a"

    var discarded: DepGraphDiscard
    let graph = loadStoredDepGraph(cfg, discarded)
    require graph.entries.len == 1
    var key: (string, string)
    for k in graph.entries.keys: key = k
    check not isEntryStale(graph, key, cfg.trackedRoots)
    repoint(root, "libs/b")
    check isEntryStale(graph, key, cfg.trackedRoots)
    for k, e in graph.entries.pairs:
      let d = entryDrift(e, cfg.trackedRoots)
      check d.isSome and d.get.kind == dkMoved and
        string(d.get.path.display) == "vend"

    # A link that cannot be read back drops the whole entry (recompile),
    # never just the link (which would exempt the entry from the check).
    entryNode["links"][0]["target"] = newJInt(5)
    writeFile(gpath, $doc)
    let dropped = loadStoredDepGraph(cfg, discarded)
    check dropped.entries.len == 0

proc linkedProjectIn(tag, parent: string): string =
  ## `newProject`'s layout with the link at `<parent>/vend` instead of
  ## `vend`: a directory the index walk does not index (a dot-directory, a
  ## `nimcache`-named directory). The test imports through it.
  result = newProject(tag)
  removeDirLink(result / "vend")
  createDir(result / parent)
  createDirLink(result / "libs" / "a", result / parent / "vend")
  writeFile(result / "tests" / "unit" / "test_uses_vend.nim",
            "import ../../" & parent & "/vend/m\ndoAssert mval() == 111\n")

template linkedRepointCase(tag, parent: string) =
  ## One run through `<parent>/vend`, a check that the entry recorded that
  ## link, then a repoint to `libs/b` that must recompile and fail. A
  ## template, not a proc: `check` marks the enclosing `test` failed only
  ## when expanded inside it.
  let root = linkedProjectIn(tag, parent)
  defer:
    removeDirLink(root / parent / "vend")
    dispose(root)
  require runJson(root).code == 0
  let (cfg, _) = loadConfig(root / "crisol.kdl")
  let entryNode = parseFile(depgraphPath(cfg))["entries"][0]
  check entryNode["links"].len == 1
  if entryNode["links"].len == 1:
    check entryNode["links"][0]["path"].getStr == parent & "/vend"
    check entryNode["links"][0]["target"].getStr == "t:libs/a"
  removeDirLink(root / parent / "vend")
  createDirLink(root / "libs" / "b", root / parent / "vend")
  let r2 = runJson(root)
  check only(r2.doc)["compileSkipped"].getBool == false
  check only(r2.doc)["cached"].getBool == false
  check only(r2.doc)["outcome"].getStr != "passed"
  check r2.code != 0

suite "issue #25 — a link inside a directory the index walk does not index":
  # The walk skips indexing the files of dot-directories and
  # `nimcache`-named directories, but it must still record the links inside
  # them. Before R12-S1 it skipped those directories outright, so a link
  # there was never recorded and a repoint was served stale (POSIX), and
  # the entry recorded no link at all (every platform).

  test "a link inside a dot-directory is recorded and its repoint recompiles":
    linkedRepointCase("dotdir", ".deps")

  test "a link inside a nimcache-named directory is recorded and its repoint recompiles":
    linkedRepointCase("nimcachedir", "nimcache")

  test "a link inside a relative dep root outside the project is recorded and its repoint recompiles":
    # The link lives outside the project, in a directory declared as a dep
    # root by a RELATIVE path, and the test imports through it by a path
    # that leaves the project. A relative dep root is relative to the
    # project root, never to the working directory; the index walk once
    # joined it onto the working directory, walked nothing, and missed the
    # link. The runs below start from `tests/unit` inside the project, where
    # the relative path names no directory, so the case does not depend on
    # where the test binary itself was started.
    let root = newProject("deprootrel")
    let farmName = root.lastPathPart & "_farm"
    let farm = root.parentDir / farmName
    let startDir = getCurrentDir()
    defer:
      setCurrentDir(startDir)
      removeDirLink(farm / "vend")
      removeDir(farm)
      dispose(root)
    removeDirLink(root / "vend")
    removeDirLink(farm / "vend")
    removeDir(farm)
    createDir(farm)
    createDirLink(root / "libs" / "a", farm / "vend")
    writeFile(root / "crisol.kdl",
              "dep-roots \"../" & farmName & "\" name=\"farm\"\n" & ProjectKdl)
    writeFile(root / "tests" / "unit" / "test_uses_vend.nim",
              "import ../../../" & farmName & "/vend/m\n" &
              "doAssert mval() == 111\n")
    setCurrentDir(root / "tests" / "unit")
    require runJson(root).code == 0
    let (cfg, _) = loadConfig(root / "crisol.kdl")
    let entryNode = parseFile(depgraphPath(cfg))["entries"][0]
    check entryNode["links"].len == 1
    if entryNode["links"].len == 1:
      check entryNode["links"][0]["path"].getStr == "dep:farm/vend"
      check entryNode["links"][0]["target"].getStr == "t:libs/a"
    removeDirLink(farm / "vend")
    createDirLink(root / "libs" / "b", farm / "vend")
    let r2 = runJson(root)
    check only(r2.doc)["compileSkipped"].getBool == false
    check only(r2.doc)["cached"].getBool == false
    check only(r2.doc)["outcome"].getStr != "passed"
    check r2.code != 0

when isMainModule:
  echo "test_issue25_symlink_retarget done"
