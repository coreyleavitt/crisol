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

import std/[os, sets, json, strutils, unittest, options]
import crisol/types
import crisol/paths
import crisol/closure

proc projTp(rel: string; roots: TrackedRoots): TrackedPath =
  ## RFC-0009 A4b test helper: build the expected project (tag-0) closure
  ## member the SAME way production spells one — `fromCanonical` on a
  ## project-relative rel string.
  fromCanonical(rel, roots).get

proc depTp(absPath: string; roots: TrackedRoots): TrackedPath =
  ## RFC-0009 A4b test helper: build the expected dep-root closure member
  ## by classifying its real absolute path — the same soundness gate
  ## production uses (`index.tracked`/`classify`).
  classify(absPath, roots).tp

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
  node["depfiles"] = newJArray()
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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet([
      projTp("tests/t.nim", cfg.trackedRoots),
      projTp("lib/foo/src/foo.nim", cfg.trackedRoots),
      projTp("lib/bar/src/bar/util.nim", cfg.trackedRoots),
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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/util.nim", cfg.trackedRoots) in cl
    check projTp("src/myutil.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("src/util.nim", cfg.trackedRoots)])

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("vendor/foo.nim", cfg.trackedRoots)])

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots)])

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
    var cfg = Config(projectRoot: projRoot, stateDir: ".crisol",
                     depRoots: @[depRootPath])
    cfg.trackedRoots = initTrackedRoots(projRoot, @[(name: "dep", native: depRootPath)], ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    let expected = depRootPath / "src" / "dep.nim"
    let expectedTp = depTp(expected, cfg.trackedRoots)
    check expectedTp in cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), expectedTp])

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("lib/x.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([projTp("tests/unit/deep/t.nim", cfg.trackedRoots), projTp("lib/x.nim", cfg.trackedRoots)])

  test "decoy sanity: a leading-.. body still enforces the basename boundary":
    ## Stripping leading ".."/"."/""'" components from the body must not
    ## loosen the basename match: a decoy with a different basename
    ## (zx.nim) or a different extension (x.nims — indexed under the
    ## basename "x.nims" since D4/issue #11, but that is a DIFFERENT
    ## basename than "x.nim") must never resolve for body "../x.nim"; only
    ## the real src/x.nim match does.
    let root = freshRoot("decoy")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "lib")
    createDir(root / "other")
    createDir(root / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "lib" / "zx.nim", "# decoy basename\n")
    writeFile(root / "other" / "x.nims", "# decoy extension, indexed under a different basename\n")
    writeFile(root / "src" / "x.nim", "# real\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@sx.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/x.nim", cfg.trackedRoots) in cl
    check projTp("lib/zx.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("src/x.nim", cfg.trackedRoots)])

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("lib#1:2/w.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("lib#1:2/w.nim", cfg.trackedRoots)])

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/shared.nim", cfg.trackedRoots) in cl
    check projTp("lib/shared.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([
      projTp("tests/t.nim", cfg.trackedRoots),
      projTp("src/shared.nim", cfg.trackedRoots),
      projTp("lib/shared.nim", cfg.trackedRoots),
    ])

  test "a non-dot state dir (Config.stateDir with no leading dot) is still pruned, by absolute path — not by name convention":
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
    var cfg = Config(projectRoot: root, stateDir: "state", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), "state")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/shared.nim", cfg.trackedRoots) in cl
    check projTp("state/shared.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("src/shared.nim", cfg.trackedRoots)])

  test "a nonexistent depRoot in config.depRoots is tolerated — no raise, in-root resolution unaffected":
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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[missingDepRoot])
    cfg.trackedRoots = initTrackedRoots(root, @[(name: "dep", native: missingDepRoot)], ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("src/x.nim", cfg.trackedRoots)])

  test "a .nim SYMLINK FILE inside the project (pcLinkToFile) is indexed under its lexical path; a realpath-relative body resolves to it":
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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("lib/dep.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("lib/dep.nim", cfg.trackedRoots)])

  test "an @m body carrying a realpath through a symlinked depRoot is retained via classify's realAbs match (RFC-0009 A4a)":
    ## Reproduces the shape a shallow entrypoint (`tests/t.nim`, one level
    ## below root) produces for a module reached through a symlinked
    ## depRoot: Nim's mangler prefers `@m` (entrypointDir-relative) whenever
    ## it is not STRICTLY longer than the `@p` (search-path-relative)
    ## candidate, and — because the resolved source is realpath-
    ## canonicalized — the `@m` body itself carries `..` components up to a
    ## common ancestor and back down into the symlink's REAL target
    ## (confirmed empirically against a real `nim c` run of this exact
    ## fixture shape: `@m..@s..@s<casDir>@sdep@ssrc@sdep.nim.c.o`). The body
    ## here is computed with `relativePath` exactly as Nim's mangler does
    ## (shortest relative path from the entrypoint's directory, which
    ## carries no symlink of its own, to the dep's REAL path), so
    ## `(epDir / body).normalizedPath` lands EXACTLY on the dep's real path.
    ##
    ## RFC-0009 A4a: this is exactly under-selection bug #2 the slice fixes.
    ## Pre-A4a, `underAnyRoot`'s manual lexical-only string match did NOT
    ## consider a dep root's realAbs, so this realpath candidate looked
    ## "outside every tracked root" and had to be recovered via an exact
    ## `index.lookupByReal` match at the dep root's LEXICAL spelling
    ## ("_deps/dep/src/dep.nim", since depRootPath happens to be nested
    ## inside the project here). Post-A4a, `index.tracked`/`classify`
    ## matches the dep root's `realAbs` DIRECTLY (the `d.realAbs` prefix
    ## check in `classify`'s dep loop) — the candidate is recognized as
    ## tracked (and dep-tagged) on the FIRST pass, so the old `byReal`
    ## recovery path is never reached for this case. The member is still
    ## retained (no under-selection: the soundness property this test
    ## guards is unchanged) — only its SPELLING changes, from the old
    ## project-relative-looking recovered string to the dep-tagged member's
    ## corrected-D5 spelling, its ABSOLUTE native path (`toNative`) — see
    ## `closureMemberSpelling`'s doc comment in closure.nim for why a
    ## dep-root member must spell as absolute for `depgraph.recordClosure`'s
    ## downstream `classify` round-trip to stay sound.
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

    # Realpath-relative @m body, computed exactly as Nim's mangler does:
    # the shortest relative path from the entrypoint's (real) directory to
    # the dep's REAL (symlink-resolved) path.
    let realDepNim = expandFilename(outside / "dep" / "src" / "dep.nim")
    let realEpDir = expandFilename(root / "tests")
    let mangledBody = relativePath(realDepNim, realEpDir).replace($DirSep, "@s")
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / ("@m" & mangledBody & ".c.o"),
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol",
                     depRoots: @[depRootPath])
    cfg.trackedRoots = initTrackedRoots(root, @[(name: "dep", native: depRootPath)], ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    # RFC-0009 A4a: the symlinked-depRoot member is RETAINED — that retention
    # is the soundness property this test proves (a realpath through a
    # symlinked dep root is kept, not dropped by the under-root filter). Its
    # exact SPELLING is platform-dependent and deliberately NOT pinned:
    #   - where the realpath-relative @m candidate keeps the volume's real
    #     prefix, it matches the dep root's realAbs directly and spells
    #     dep-absolute (via toNative) — e.g. the Linux temp volume.
    #   - where the volume expands a symlinked temp prefix (macOS
    #     /var → /private/var, [[rfc0009-macos-test-gotchas]]), the lexical
    #     candidate misses realAbs, so the member is recovered through the
    #     index as its under-project symlink path and spells project-relative.
    # Both are correct retentions; asserting one absolute spelling is
    # volume-dependent and fails on macOS. Assert retention volume-independently.
    #
    # RFC-0009 A4b: cl is now HashSet[TrackedPath]. Retain the SAME
    # volume-independent assertion: exactly 2 members (entrypoint + dep),
    # and the non-entrypoint member's WIRE spelling (project-relative
    # `display` when recovered project-tagged, absolute `toNative` when
    # matched dep-tagged — the same branch closure.nim's own
    # `closureMemberSpelling` takes) ends with "dep/src/dep.nim" either way.
    let epTp = projTp("tests/t.nim", cfg.trackedRoots)
    check epTp in cl
    check cl.len == 2
    var depMember: TrackedPath
    var foundDep = false
    for m in cl:
      if m != epTp:
        depMember = m
        foundDep = true
    check foundDep
    let depSpelling =
      if isProject(depMember): display(depMember)
      else: toNative(depMember, cfg.trackedRoots)
    check depSpelling.endsWith("dep/src/dep.nim")

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
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("tests/foo.nim", cfg.trackedRoots) in cl
    check projTp("other/foo.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp("tests/foo.nim", cfg.trackedRoots)])

  test "an @m body escaping every tracked root, with no dep-root of its own, is NOT unioned against the whole index (untracked out-of-root import)":
    ## `root/tests/t.nim` imports an UNTRACKED out-of-root module via
    ## `../../other/lib` (two ".." from tests/ escapes `root` entirely, into
    ## a sibling directory that is neither projectRoot nor any configured
    ## depRoot). Pre-fix, `resolveMangledAll`'s @m fallback unioned
    ## `index.lookup(body)` — a SUFFIX match — against the whole index once
    ## the plain candidate escaped every tracked root; an unrelated in-tree
    ## decoy `root/src/other/lib.nim` shares the suffix "other/lib.nim" and
    ## was wrongly pulled into the closure even though it has nothing to do
    ## with the untracked import. The fix replaces the suffix fallback with
    ## an EXACT realpath lookup (`byReal`), so an untracked import with no
    ## indexed file at its own realpath resolves to nothing extra: only the
    ## (out-of-root, therefore filtered) plain candidate is produced, and the
    ## decoy is never selected.
    let root = freshRoot("f1_untracked")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src" / "other")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / "src" / "other" / "lib.nim", "# decoy, in-tree but unrelated\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@m..@s..@sother@slib.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/other/lib.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots)])

  test "an @m body computed from a symlinked entrypoint directory's REALPATH resolves via byReal to the lexical in-root path":
    ## `root/a/b/tests` is a SYMLINK to a SHALLOW outside directory `st`
    ## (a direct sibling of `root`, NOT nested under it) holding `t.nim` —
    ## the entrypoint directory's LEXICAL depth (4 components below `root`'s
    ## parent) differs from its REAL depth (1 component below the same
    ## parent). Nim computes the @m body relative to the REAL entrypoint
    ## directory (`st`); naively joining that body onto the LEXICAL epDir
    ## (as the pre-fix code did) does NOT cancel out correctly when the
    ## depths differ, landing on a bogus, nonexistent, but still
    ## textually-in-root path — silently dropping `src/foo.nim` from the
    ## closure (and leaving `isEntryStale` permanently confused by a
    ## recorded-but-nonexistent path) while a garbage entry pollutes the
    ## closure instead. The fix detects that `expandFilename(epDir) !=
    ## epDir` and resolves the body from the REAL epDir, recovering the file
    ## at its LEXICAL path via `byReal`.
    let root = freshRoot("f2_symlinked_epdir")
    defer: removeDir(root)
    let stDir = freshRoot("f2_symlinked_epdir_st")
    defer: removeDir(stDir)

    createDir(root / "a" / "b")
    createDir(root / "src")
    writeFile(root / "src" / "foo.nim", "# foo\n")
    writeFile(stDir / "t.nim", "# ep\n")
    createSymlink(stDir, root / "a" / "b" / "tests")

    let ep = root / "a" / "b" / "tests" / "t.nim"
    let nc = root / "nimcache"

    # Body computed from the REAL entrypoint directory (`st`), exactly as
    # Nim's mangler does — the shortest relative path from realpath(epDir)
    # to the target, with leading ".." components as needed. `st` and
    # `root` are siblings, so this body carries just one leading "..".
    let realFoo = expandFilename(root / "src" / "foo.nim")
    let realSt = expandFilename(stDir)
    let mangledBody = relativePath(realFoo, realSt).replace($DirSep, "@s")

    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / ("@m" & mangledBody & ".c.o"),
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("src/foo.nim", cfg.trackedRoots) in cl
    check projTp("a/b/tests/t.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([projTp("a/b/tests/t.nim", cfg.trackedRoots), projTp("src/foo.nim", cfg.trackedRoots)])

  test "a symlinked entrypoint FILE's @m body resolves via the file's real directory, not its (non-symlinked) containing directory's":
    ## `root/tests/t.nim` is a SYMLINK to the real file `root/other/t.nim`;
    ## `root/tests` itself is an ORDINARY directory (no symlink on any of
    ## its own path components). Nim's `@m` base is
    ## `parentDir(realpath(ENTRYPOINT FILE))`, i.e. `root/other` — NOT
    ## `realpath` of the entrypoint's (already-non-symlinked) containing
    ## directory, `root/tests`. Pre-fix, `resolveMangledAll` computed
    ## `realEpDir` from `expandFilename(epDir)` (epDir = `root/tests`),
    ## which is unaffected by a symlink on the FILE component alone, so it
    ## equals `epDir` and the code wrongly took case 1 (lexical == real),
    ## recording the bogus, nonexistent sibling `tests/helper.nim` for an
    ## @m body of plain "helper.nim" — the real dependency is
    ## `other/helper.nim`. `closureContentHash` then raises on the missing
    ## file on every subsequent run, permanently invalidating the entry.
    let root = freshRoot("symlinked_ep_file")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "other")
    writeFile(root / "other" / "helper.nim", "# helper, real sibling\n")
    writeFile(root / "other" / "t.nim", "# ep, real file\n")
    createSymlink(root / "other" / "t.nim", root / "tests" / "t.nim")

    let ep = root / "tests" / "t.nim"      # lexical, symlinked FILE
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@mhelper.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("other/helper.nim", cfg.trackedRoots) in cl
    check projTp("tests/helper.nim", cfg.trackedRoots) notin cl

  test "case-2 miss (neither realCandidate nor the lexical candidate is indexed/exists) keeps realCandidate, not a bogus lexical sibling":
    ## Same symlinked-entrypoint-DIRECTORY shape as the byReal-recovery test
    ## above, but the @m body names a module that has NO file anywhere on
    ## disk (e.g. a dependency deleted since the index was built) — so
    ## BOTH `index.lookupByReal(realCandidate)` misses (nothing indexed at
    ## that realpath) AND the lexical candidate does not exist on disk
    ## either. The old unconditional "fall back to the lexical candidate"
    ## rule would add `a/b/ghost.nim` — a nonexistent path that is still
    ## textually INSIDE `root` (so `extractClosure`'s under-tracked-root
    ## filter would NOT catch it) — permanently breaking
    ## `closureContentHash` on every later run. The fix keeps `realCandidate`
    ## itself instead: it lies OUTSIDE `root` (a sibling temp dir), so
    ## `extractClosure`'s ordinary under-tracked-root filter correctly drops
    ## it, exactly like any other untracked out-of-root import.
    let root = freshRoot("case2_miss")
    defer: removeDir(root)
    let st = freshRoot("case2_miss_st")
    defer: removeDir(st)

    createDir(root / "a" / "b")
    writeFile(st / "t.nim", "# ep\n")
    createSymlink(st, root / "a" / "b" / "tests")

    let ep = root / "a" / "b" / "tests" / "t.nim"
    let nc = root / "nimcache"

    # A single ".." from the real entrypoint dir (`st`) to a module that
    # was never written anywhere — no indexed file at its realpath, and no
    # lexical file at root/a/b/ghost.nim either.
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@m..@sghost.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp("a/b/ghost.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("a/b/tests/t.nim", cfg.trackedRoots)])

suite "SourceIndex — @p/@n roots-existence fallback for a file under a pruned dot-dir":

  test "an @p body whose file lives under a pruned dot-dir INSIDE a tracked root resolves via the roots existence-check fallback":
    ## `root/.hidden/cas/dep/src/dep.nim` lives INSIDE projectRoot, but under
    ## a DOT-DIR — `walkForIndex` prunes dot-dirs for WALK COST, so this file
    ## is never indexed and `index.lookup` (a pure index lookup) necessarily
    ## misses. It is nonetheless *tracked* (it lives under projectRoot by
    ## construction), so `resolveMangledAll`'s @p/@n branch must recover it
    ## via the roots existence-check fallback: strip the body's leading
    ## ""/"."/".." components (the same `strippedSuffix` helper `lookup`
    ## uses) and join the remainder onto each of `index.roots`, keeping any
    ## candidate that exists on disk.
    let root = freshRoot("dotdir_fallback")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / ".hidden" / "cas" / "dep" / "src")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(root / ".hidden" / "cas" / "dep" / "src" / "dep.nim", "# dep\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@s..@s.hidden@scas@sdep@ssrc@sdep.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp(".hidden/cas/dep/src/dep.nim", cfg.trackedRoots) in cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), projTp(".hidden/cas/dep/src/dep.nim", cfg.trackedRoots)])

  test "negative pin: the same pruned-dot-dir @p body resolves to nothing when the file is absent (no fabricated path)":
    ## Same body/shape as above, but `root/.hidden/cas/dep/src/dep.nim` is
    ## never written. The roots existence-check fallback must not fabricate
    ## a candidate that fails `fileExists`/`symlinkExists` — a body that
    ## resolves to nothing anywhere on disk stays excluded, exactly like an
    ## ordinary index miss.
    let root = freshRoot("dotdir_fallback_negative")
    defer: removeDir(root)
    createDir(root / "tests")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    # NOTE: root/.hidden/cas/dep/src/dep.nim intentionally not created.
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@s..@s.hidden@scas@sdep@ssrc@sdep.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    check projTp(".hidden/cas/dep/src/dep.nim", cfg.trackedRoots) notin cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots)])

  test "dep-root variant: the roots existence-check fallback also tries a configured depRoot, not just projectRoot":
    ## `depRoot/.hidden/extra.nim` lives OUTSIDE projectRoot, under a pruned
    ## dot-dir inside a configured depRoot. The fallback must join the
    ## stripped suffix onto EVERY entry of `index.roots` — projectRoot AND
    ## each depRoot — so this resolves via the depRoot candidate even though
    ## projectRoot/.hidden/extra.nim does not exist: only trying projectRoot
    ## (not iterating every root) would miss it entirely. Since the resolved
    ## path is not under projectRoot, `toProjectRelative` reports it
    ## absolute (the same depRoot convention used elsewhere in this file).
    let root = freshRoot("dotdir_fallback_deproot")
    defer: removeDir(root)
    let depRoot = freshRoot("dotdir_fallback_deproot_dep")
    defer: removeDir(depRoot)
    createDir(root / "tests")
    createDir(depRoot / ".hidden")
    let ep = root / "tests" / "t.nim"
    writeFile(ep, "# ep\n")
    writeFile(depRoot / ".hidden" / "extra.nim", "# extra\n")
    let nc = root / "nimcache"
    writeManifest(nc, "t", compile = @[], link = @[
      nc / "@mt.nim.c.o",
      nc / "@p..@s.hidden@sextra.nim.c.o",
    ])
    var cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[depRoot])
    cfg.trackedRoots = initTrackedRoots(root, @[(name: "dep", native: depRoot)], ".crisol")
    let cl = extractClosure(nc, "t", ep, cfg)
    let expected = (depRoot / ".hidden" / "extra.nim").normalizedPath
    let expectedTp = depTp(expected, cfg.trackedRoots)
    check expectedTp in cl
    check cl == toHashSet([projTp("tests/t.nim", cfg.trackedRoots), expectedTp])
