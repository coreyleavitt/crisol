## test_closure_warm.nim — issue #5: the closure must survive a WARM recompile.
##
## Nim's nimcache manifest has two arrays:
##   - `compile` — the C-compile WORK LIST for this invocation. Complete only
##     on a cold nimcache; on a warm recompile it holds just the modules whose
##     generated C changed, and is EMPTY when nothing did (comment-only edit).
##   - `link`    — every object the linker consumes. Complete on every compile
##     by construction (extccomp builds it from all of `toCompile`).
##
## extractClosure used to read `compile`, so a warm recompile persisted a
## truncated/empty closure and permanently disabled invalidation (masked-red
## incident, issue #5). The closure MUST be derived from `link`.
##
## Synthetic manifests only — no real `nim c` here. The real-compile
## cold == warm property lives in tests/integration/test_closure.nim.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_closure_warm.nim

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
  result = getTempDir() / ("crisol_closure_warm_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "extractClosure — warm recompile (issue #5)":

  test "compile:[] with a populated link array yields the full closure":
    let root = freshRoot("warm")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src")
    let ep = root / "tests" / "test_ep.nim"
    writeFile(ep, "import ./dep\nimport proj\n")
    writeFile(root / "tests" / "dep.nim", "# dep")
    writeFile(root / "src" / "proj.nim", "# proj via --path:src")
    let nc = root / "nimcache"
    # Exactly what Nim emits when nothing changed: compile empty, link full.
    writeManifest(nc, "test_ep", compile = @[], link = @[
      nc / "@mtest_ep.nim.c.o",
      nc / "@mdep.nim.c.o",
      nc / "@pproj.nim.c.o",
      nc / "@psystem.nim.c.o",          # stdlib: not under a tracked root
      "/opt/vendor/libfoo.o",           # externalToLink: no @m/@p prefix
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "test_ep", ep, cfg)
    check cl == toHashSet(["tests/test_ep.nim", "tests/dep.nim", "src/proj.nim"])

  test "a {.compile.}d C external (@m-mangled, .c.o but not .nim.c.o) yields no phantom entry (R1)":
    ## Real evidence: tests/fixtures/golden_reuse/generated/ep_a/ep_a.json's
    ## `link` array contains `.../@mfixture.c.o` for `fixture_ffi.nim`'s
    ## `{.compile: "fixture.c".}`.  Only a Nim module object is named
    ## `<mangled>.nim.c.o`; an external C/C++ file compiled via `{.compile.}`
    ## is `@m`-mangled too but never carries the `.nim` component, so it must
    ## be excluded — not misread as a module named "fixture".
    let root = freshRoot("extcompile")
    defer: removeDir(root)
    createDir(root / "tests")
    let ep = root / "tests" / "main.nim"
    writeFile(ep, "# main\n")
    writeFile(root / "tests" / "fixture.c", "// vendor C\n")
    let nc = root / "nimcache"
    writeManifest(nc, "main", compile = @[], link = @[
      nc / "@mfixture.c.o",        # {.compile.}d external — must be excluded
      nc / "@mmain.nim.c.o",       # the entrypoint's own module — must be kept
      nc / "@mweird.cpp.o",        # non-Nim, no .nim component — excluded
      "libfoo.a",                  # foreign archive — excluded
      "/opt/x.o",                  # foreign object — excluded
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "main", ep, cfg)
    check cl == toHashSet(["tests/main.nim"])
    check "tests/fixture" notin cl

  test "a module compiled to .cpp or .m (sfCompileToCpp/importobjc) is not silently dropped":
    ## Nim 2.2.10 cgen's `getCFile` picks the module's C file extension
    ## per-module: `.nim.c` ordinarily, `.nim.cpp` when the module has
    ## `{.importcpp.}` symbols (sfCompileToCpp — even under plain `nim c`),
    ## `.nim.m` for `{.importobjc.}`.  `link` then carries `@m<mod>.nim.cpp.o`
    ## / `@m<mod>.nim.m.o` for such modules.  If moduleMangledNameOf only recognised
    ## `.nim.c.o`, these modules would be silently excluded from the closure:
    ## a non-empty closure still results (so the NONEMPTY-CLOSURE guard never
    ## fires), but edits to the dropped module never change closureHash —
    ## a stale binary is served fresh and `--changed` never selects it.
    let root = freshRoot("cppobjc")
    defer: removeDir(root)
    createDir(root / "tests")
    createDir(root / "src")
    let ep = root / "tests" / "main.nim"
    writeFile(ep, "# main\n")
    writeFile(root / "tests" / "cppmod.nim", "# cpp module\n")
    writeFile(root / "tests" / "objcmod.nim", "# objc module\n")
    writeFile(root / "src" / "proj.nim", "# proj via --path:src\n")
    let nc = root / "nimcache"
    writeManifest(nc, "main", compile = @[], link = @[
      nc / "@mmain.nim.c.o",         # ordinary module
      nc / "@mcppmod.nim.cpp.o",     # sfCompileToCpp module
      nc / "@mobjcmod.nim.m.o",      # importobjc module
      nc / "@mfixture.c.o",          # {.compile.}d external — still excluded
      nc / "@pproj.nim.cpp.o",       # @p-mangled cpp module (--path:src)
    ])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    let cl = extractClosure(nc, "main", ep, cfg)
    check cl == toHashSet([
      "tests/main.nim", "tests/cppmod.nim", "tests/objcmod.nim", "src/proj.nim",
    ])

  test "raises cekEnvironment when link is present but empty (R3)":
    let root = freshRoot("emptylink")
    defer: removeDir(root)
    createDir(root / "tests")
    let ep = root / "tests" / "test_ep.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"
    writeManifest(nc, "test_ep", compile = @["some.c"], link = @[])
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    var raised = false
    try:
      discard extractClosure(nc, "test_ep", ep, cfg)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
    check raised

  test "raises cekEnvironment when the link key is missing entirely (R3)":
    let root = freshRoot("nolinkkey")
    defer: removeDir(root)
    createDir(root / "tests")
    let ep = root / "tests" / "test_ep.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"
    createDir(nc)
    let compileArr = newJArray()
    let pair = newJArray()
    pair.add newJString("some.c")
    pair.add newJString("gcc -c some.c")
    compileArr.add pair
    let node = newJObject()
    node["compile"] = compileArr
    # Deliberately no "link" key at all.
    writeFile(nc / "test_ep.json", $node)
    let cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[])
    var raised = false
    try:
      discard extractClosure(nc, "test_ep", ep, cfg)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
    check raised
