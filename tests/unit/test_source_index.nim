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
    ##
    ## The manifest body here is the REALISTIC shape Nim actually emits for
    ## a module reached through a symlinked search-path root: the compiler
    ## canonicalizes (realpath) the resolved source file, so the "shortest
    ## relative path from the search-path root" is computed against the
    ## REALPATH, not the lexical (symlinked) root — yielding a `..`-laden,
    ## realpath-relative body (trigger B). A body with no `..`
    ## at all (the old pin) is a shape Nim never emits for a symlinked root.
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

    # Realpath-relative body: many leading ".." components (the exact count
    # does not matter for the fix — lookup strips ALL leading ".." /"."/""
    # components) followed by the REAL (symlink-resolved) absolute path to
    # outside/src/dep.nim, mangled with @s in place of '/'.
    let realOutsideAbs = outside.expandFilename
    let mangledBody = ("../../../.." & realOutsideAbs & "/src/dep.nim")
                        .replace("/", "@s")
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / ("@p" & mangledBody & ".c.o"),
    ])
    let cfg = Config(projectRoot: projRoot, stateDir: ".crisol",
                     depRoots: @[depRootPath])
    let cl = extractClosure(nc, "t", ep, cfg)
    let expected = depRootPath / "src" / "dep.nim"
    check expected in cl
    check cl == toHashSet(["tests/t.nim", expected])

  test "trigger A: in-root relative import shorter from a --path root (leading .. body)":
    ## `--path:src` importing `../lib/x.nim` — Nim's mangler emits the
    ## SHORTEST relative path from the --path root, which here has a
    ## leading ".." because lib/ is a sibling of src/, not under it. The
    ## body carries no symlink/realpath involvement at all (trigger A is
    ## the plain in-root case; trigger B, above, is the symlinked-root case).
    let root = freshRoot("triggerA")
    defer: removeDir(root)
    createDir(root / "tests" / "unit" / "deep")
    createDir(root / "lib")
    let ep = root / "tests" / "unit" / "deep" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "lib" / "x.nim", "# x\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@slib@sx.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "lib/x.nim" in cl
    check cl == toHashSet(["tests/unit/deep/t.nim", "lib/x.nim"])

  test "decoy sanity: a leading-.. body still enforces the basename boundary":
    ## Stripping leading ".."/"."/""'" components from the body must not
    ## loosen the basename match: a decoy with a different basename
    ## (zx.nim) or a different extension (x.nims — not even indexed) must
    ## never resolve for body "../x.nim"; only the real src/x.nim match does.
    let root = freshRoot("decoy")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "lib")
    createDir(root / "other")
    createDir(root / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "lib" / "zx.nim", "# decoy basename\n")
    writeFile(root / "other" / "x.nims", "# decoy extension, not even indexed\n")
    writeFile(root / "src" / "x.nim", "# real\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@sx.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "src/x.nim" in cl
    check "lib/zx.nim" notin cl
    check cl == toHashSet(["tests/t.nim", "src/x.nim"])

  test "@c (colon) and @h (hash) mangling escapes are decoded in a directory component":
    ## Nim rejects `#`/`:` in a module BASENAME (module names must be plain
    ## identifiers), so `@h`/`@c` never appear inside the basename itself.
    ## What Nim actually emits them for is a DIRECTORY component reached via
    ## a quoted import path, e.g. `import "../lib#1:2/w"` — the mangler
    ## encodes the literal `#`/`:` characters in "lib#1:2" with `@h`/`@c`
    ## while the basename ("w") stays a plain, decodable identifier.
    ##
    ## Both mangling forms that can carry the escapes are exercised here:
    ## `@p` (SourceIndex-based --path resolution) and `@m` (resolved
    ## relative to the entrypoint's own source directory, via a leading
    ## `..` body) — both must decode "lib@h1@c2@sw.nim" to "lib#1:2/w.nim".
    let root = freshRoot("hashcolonescapes")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "lib#1:2")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "lib#1:2" / "w.nim", "# w\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@plib@h1@c2@sw.nim.c.o",
      nc / "@m..@slib@h1@c2@sw.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "lib#1:2/w.nim" in cl
    check cl == toHashSet(["tests/t.nim", "lib#1:2/w.nim"])

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

  test "T2: a non-dot state dir (Config.stateDir with no leading dot) is still pruned, by absolute path — not by name convention":
    ## walkForIndex's state-dir skip is an ABSOLUTE-PATH comparison
    ## (entryAbs == stateDirAbs), applied independently of the "starts with
    ## '.'" dot-dir check. A state dir configured WITHOUT a leading dot (e.g.
    ## Config(stateDir: "state")) must still be excluded from the index. A
    ## decoy file inside it sharing the real module's basename must never
    ## resolve — only the real file (indexed elsewhere) may.
    let root = freshRoot("statedir_nodot")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "state")
    createDir(root / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "state" / "shared.nim", "# decoy in non-dot state dir\n")
    writeFile(root / "src" / "shared.nim", "# real\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@pshared.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: "state", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "src/shared.nim" in cl
    check "state/shared.nim" notin cl
    check cl == toHashSet(["tests/t.nim", "src/shared.nim"])

  test "T2: a nonexistent depRoot in config.depRoots is tolerated — no raise, in-root resolution unaffected":
    let root = freshRoot("deproot_missing")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "src" / "x.nim", "# x\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@px.nim.c.o",
    ])
    let missingDepRoot = root / "_deps" / "does_not_exist"
    check not dirExists(missingDepRoot)
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[missingDepRoot])
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet(["tests/t.nim", "src/x.nim"])

  test "T2: a .nim SYMLINK FILE inside the project (pcLinkToFile) is indexed under its lexical path; a realpath-relative body resolves to it":
    ## root/lib/dep.nim is a FILE symlink (not a symlinked directory)
    ## pointing to a same-named file OUTSIDE the project root. This exercises
    ## the pcLinkToFile branch of walkForIndex specifically — distinct from
    ## the symlinked-depRoot-DIRECTORY case above, which never hits
    ## pcLinkToFile at all (dep.nim there is an ordinary pcFile once the
    ## symlinked directory itself has been walked into). Per the depRoot-
    ## symlink test's doc comment, the compiler mangles @p bodies from the
    ## REALPATH-canonicalized source, so a realistic body here is realpath-
    ## relative; lookup must report the file's LEXICAL project path
    ## (lib/dep.nim), not the untracked outside real path.
    let root = freshRoot("symlinkfile")
    defer: removeDir(root)
    let outside = freshRoot("symlinkfile_outside")
    defer: removeDir(outside)
    createDir(root / "tests")
    createDir(root / "lib")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(outside / "dep.nim", "# outside dep\n")
    createSymlink(outside / "dep.nim", root / "lib" / "dep.nim")

    let nc = root / "nimcache"
    let realOutsideAbs = outside.expandFilename
    let mangledBody = ("../../../.." & realOutsideAbs & "/dep.nim")
                        .replace("/", "@s")
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / ("@p" & mangledBody & ".c.o"),
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "lib/dep.nim" in cl
    check cl == toHashSet(["tests/t.nim", "lib/dep.nim"])

  test "an @m body carrying a realpath through a symlinked depRoot resolves to the lexical depRoot path":
    ## Reproduces the shape a shallow entrypoint (`tests/t.nim`, one level
    ## below root) produces for a module reached through a symlinked
    ## depRoot: Nim's mangler prefers `@m` (entrypointDir-relative) whenever
    ## it is not STRICTLY longer than the `@p` (search-path-relative)
    ## candidate, and — because the resolved source is realpath-
    ## canonicalized — the `@m` body itself carries `..` components up to a
    ## common ancestor and back down into the symlink's REAL target
    ## (confirmed empirically against a real `nim c` run of this exact
    ## fixture shape: `@m..@s..@s<casDir>@sdep@ssrc@sdep.nim.c.o`).
    ## `(epDir / body).normalizedPath` therefore resolves OUTSIDE every
    ## tracked root, so `resolveMangledAll` must fall back to `index.lookup`
    ## to recover it at its LEXICAL depRoot path,
    ## "_deps/dep/src/dep.nim" — exactly like the `@p` case already covered
    ## above, but reached via the `@m` branch instead.
    let root = freshRoot("s3_m_symlink")
    defer: removeDir(root)
    let outside = freshRoot("s3_m_symlink_outside")
    defer: removeDir(outside)

    let depRootPath = root / "_deps" / "dep"
    createDir(root / "tests")
    createDir(root / "_deps")
    createDir(outside / "dep" / "src")
    writeFile(outside / "dep" / "src" / "dep.nim", "# dep\n")
    createSymlink(outside / "dep", depRootPath)

    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"

    # Realpath-relative @m body: leading ".." components up to a common
    # ancestor, then the REAL (symlink-resolved) absolute path to
    # outside/dep/src/dep.nim, mangled with @s in place of '/'. The exact
    # ".." count does not matter — lookup strips ALL leading ".."/"."/""
    # components — but it must be enough to make the plain (epDir / body)
    # candidate resolve outside `root` (it does here: it collapses to the
    # real, non-symlinked `outside/dep/src/dep.nim`).
    let realOutsideAbs = outside.expandFilename
    let mangledBody = ("../../../.." & realOutsideAbs & "/dep/src/dep.nim")
                        .replace("/", "@s")
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / ("@m" & mangledBody & ".c.o"),
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol",
                     depRoots: @[depRootPath])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "_deps/dep/src/dep.nim" in cl
    check cl == toHashSet(["tests/t.nim", "_deps/dep/src/dep.nim"])

  test "negative pin: an in-root @m body is NOT unioned against the index — a same-basename decoy elsewhere is never selected":
    ## The fallback (index.lookup for an @m body) is gated on the plain
    ## `(epDir / body)` candidate escaping every tracked root. An ORDINARY
    ## in-root @m body (no symlink involved: body is just "foo.nim", the
    ## plain candidate is epDir/foo.nim, which IS under projectRoot) must
    ## resolve to ONLY that candidate — never additionally to some unrelated
    ## "other/foo.nim" elsewhere in the tree that happens to share the
    ## basename. Unconditionally unioning `index.lookup` for every @m body
    ## would over-select such decoys; the fallback must not trigger here.
    let root = freshRoot("s3_negative_pin")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "other")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "tests" / "foo.nim", "# real, epDir-relative\n")
    writeFile(root / "other" / "foo.nim", "# decoy, elsewhere in the tree\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@mfoo.nim.c.o",
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "t", ep, cfg)
    check "tests/foo.nim" in cl
    check "other/foo.nim" notin cl
    check cl == toHashSet(["tests/t.nim", "tests/foo.nim"])
