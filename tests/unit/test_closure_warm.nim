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
