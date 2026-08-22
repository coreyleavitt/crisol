## test_source_index.nim — issue #8: SourceIndex-based @p/@n resolution.
##
## `extractClosure` resolves `@p`/`@n`-mangled `link` entries against a
## `SourceIndex` (`buildSourceIndex`) rather than a fixed guess-list of
## roots — see closure.nim's top-of-file doc comment and the `@p` doc
## paragraph for the full rationale. These tests drive that resolution
## through `extractClosure`'s 4-arg convenience overload (synthetic
## nimcache manifests only — no real `nim c` here).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_source_index.nim

import std/[os, sets, json, strutils, unittest]
import crisol/types
import crisol/closure

proc writeManifest(dir, bname: string;
                   compile: seq[string]; link: seq[string]) =
  ## `compile` = C file paths (cc command irrelevant); `link` = object paths.
  let compileArr = newJArray()
  for c in compile:
    let pair = newJArray()
    pair.add newJString(c)
    pair.add newJString("gcc -c " & c)
    compileArr.add pair
  let linkArr = newJArray()
  for o in link: linkArr.add newJString(o)
  let node = newJObject()
  node["compile"] = compileArr
  node["link"]    = linkArr
  node["linkcmd"] = newJString("gcc -o bin " & link.join(" "))
  createDir(dir)
  writeFile(dir / bname & ".json", $node)

proc freshRoot(tag: string): string =
  result = getTempDir() / ("crisol_source_index_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "SourceIndex — @p/@n resolution (issue #8)":

  test "first-party lib module resolved via an arbitrary --path, no dep-roots (direct and nested bodies)":
    let root = freshRoot("libpath")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "lib" / "foo" / "src")
    createDir(root / "lib" / "bar" / "src" / "bar")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "lib" / "foo" / "src" / "foo.nim", "# foo\n")
    writeFile(root / "lib" / "bar" / "src" / "bar" / "util.nim", "# util\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@pfoo.nim.c.o",
      nc / "@pbar@sutil.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet([
      "tests/t.nim", "lib/foo/src/foo.nim", "lib/bar/src/bar/util.nim",
    ])

  test "suffix boundary: body util.nim does not match a decoy with a different basename":
    ## root/src/myutil.nim ends with the string "util.nim" but its basename
    ## is "myutil.nim" — the index is keyed by exact basename, so this decoy
    ## must never be a candidate for body "util.nim". root/src/util.nim
    ## (the real basename match) must resolve normally.
    let root = freshRoot("suffix")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "src" / "myutil.nim", "# decoy\n")
    writeFile(root / "src" / "util.nim", "# real\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@putil.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "src/util.nim" in cl
    check "src/myutil.nim" notin cl
    check cl == toHashSet(["tests/t.nim", "src/util.nim"])

  test "@n prefix resolves exactly like @p":
    let root = freshRoot("nprefix")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "vendor")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "vendor" / "foo.nim", "# vendor foo\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@nfoo.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet(["tests/t.nim", "vendor/foo.nim"])

  test "index exclusions: state dir, hidden dir, nimcache dir, and a nested symlinked dir are never candidates":
    let root = freshRoot("excl")
    defer: removeDir(root)
    let outside = freshRoot("excl_outside")
    defer: removeDir(outside)
    createDir(root / "tests")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")

    # (a) planted under the state dir
    createDir(root / ".crisol")
    writeFile(root / ".crisol" / "planted_a.nim", "# a\n")
    # (b) planted under a hidden dir
    createDir(root / ".hidden")
    writeFile(root / ".hidden" / "planted_b.nim", "# b\n")
    # (c) planted under a "nimcache"-named dir
    createDir(root / "nimcache")
    writeFile(root / "nimcache" / "planted_c.nim", "# c\n")
    # (d) planted under a symlinked dir nested inside the project tree
    writeFile(outside / "x.nim", "# x outside\n")
    createSymlink(outside, root / "linked")

    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@pplanted_a.nim.c.o",
      nc / "@pplanted_b.nim.c.o",
      nc / "@pplanted_c.nim.c.o",
      nc / "@px.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet(["tests/t.nim"])

  test "a dep-root that is itself a symlink is walked, resolving to its lexical path":
    ## config.depRoots = @[root/"_deps"/"lib"] where that path is a symlink
    ## to an outside dir containing src/dep.nim. buildSourceIndex must walk
    ## THROUGH the symlinked depRoot (only NESTED symlinked subdirectories
    ## are pruned — see closure.nim's walkForIndex doc comment), recording
    ## the file at the lexical depRoot path (root/_deps/lib/src/dep.nim).
    ## Since that path is not under projectRoot, toProjectRelative reports
    ## it absolute (forward-slash normalised) — the same depRoot convention
    ## tests/unit/test_soundness_r7.nim exercises for an ordinary depRoot.
    let root = freshRoot("deproot_symlink")
    defer: removeDir(root)
    let outside = freshRoot("deproot_outside")
    defer: removeDir(outside)

    let projRoot = root / "proj"
    let depRootPath = root / "_deps" / "lib"
    createDir(projRoot / "tests")
    createDir(root / "_deps")
    createDir(outside / "src")
    writeFile(outside / "src" / "dep.nim", "# dep\n")
    createSymlink(outside, depRootPath)

    let ep = projRoot / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    let nc = projRoot / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@pdep.nim.c.o",
    ])
    let cfg = Config(projectRoot: projRoot, stateDir: ".crisol",
                     depRoots: @[depRootPath])
    let cl = extractClosure(nc, "t", ep, cfg)
    let expected = depRootPath / "src" / "dep.nim"
    check expected in cl
    check cl == toHashSet(["tests/t.nim", expected])

  test "ambiguity pin: a body present under two tracked locations resolves to both (R7 over-selection)":
    let root = freshRoot("ambig")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src")
    createDir(root / "lib")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "src" / "shared.nim", "# src shared\n")
    writeFile(root / "lib" / "shared.nim", "# lib shared\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@pshared.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "src/shared.nim" in cl
    check "lib/shared.nim" in cl
    check cl == toHashSet(["tests/t.nim", "src/shared.nim", "lib/shared.nim"])
