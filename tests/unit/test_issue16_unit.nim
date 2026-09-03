## test_issue16_unit.nim — unit coverage of the pure/injectable edges landed
## for issue #16 (commits 8a1fa0f, c91988f): `closure.ExternalSource`,
## `closure.CompileInputs`, `closure.extractCompileInputs` (the `cc -M`
## header-probe seam), `depgraph.DepGraphEntry.externals` (format 5
## serialize/load/M10-guard), `depgraph.staleExternalObjects`, and
## `closure.isModuleObjectName`.
##
## These are CHARACTERIZATION tests of already-landed behavior — real `cc`
## coverage lives in tests/integration/test_issue16_headers.nim; everything
## here injects a synthetic `ccRun` (crisol/ccprobe.RunProc) or hand-writes
## nimcache-manifest / depgraph JSON, exactly like
## tests/unit/test_closure_warm.nim, tests/unit/test_depgraph_guard.nim, and
## tests/unit/test_soundness_m10.nim.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_issue16_unit.nim

import std/[algorithm, json, os, sets, strutils, tables, unittest]
import crisol/types
import crisol/closure    # ExternalSource, CompileInputs, extractCompileInputs,
                          # isModuleObjectName, buildSourceIndex; re-exports
                          # ccprobe.RunProc/realRun.
import crisol/depgraph    # DepGraph, updateEntry, saveDepGraph,
                          # loadStoredDepGraph, staleExternalObjects,
                          # DepGraphFormatVersion, depgraphPath, flagHash
import crisol/fnv         # chainedContentHash

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc freshRoot(tag: string): string =
  result = getTempDir() / ("crisol_issue16_unit_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc writeManifest(dir, bname: string;
                   compile: seq[tuple[cPath, ccCmd: string]];
                   link: seq[string]) =
  ## Mirrors tests/unit/test_closure_warm.nim's writeManifest, plus a
  ## populated `compile` array (cPath, ccCmd pairs) for the cases that need
  ## one. `depfiles` is always present-but-empty (hasDepfiles must be true —
  ## see closure.analyzeManifest's doc comment).
  let compileArr = newJArray()
  for c in compile:
    let pair = newJArray()
    pair.add newJString(c.cPath)
    pair.add newJString(c.ccCmd)
    compileArr.add pair
  let linkArr = newJArray()
  for o in link: linkArr.add newJString(o)
  let node = newJObject()
  node["compile"]  = compileArr
  node["link"]     = linkArr
  node["linkcmd"]  = newJString("")
  node["depfiles"] = newJArray()
  createDir(dir)
  writeFile(dir / bname & ".json", $node)

type
  ExtProject = object
    ## A synthetic project with one {.compile.}d external (native/add.c,
    ## #including native/add.h and native/other.h) plus a depRoot header
    ## (vendor.h) outside projectRoot entirely.
    root, depRoot, nc, epPath, srcAbs, addH, otherH, vendorH, objAbs: string

proc setupExtProject(tag: string): ExtProject =
  let root    = freshRoot(tag)
  let depRoot = freshRoot(tag & "_dep")
  createDir(root / "native")
  result = ExtProject(
    root:    root,
    depRoot: depRoot,
    nc:      root / "nimcache",
    epPath:  root / "main.nim",
    srcAbs:  root / "native" / "add.c",
    addH:    root / "native" / "add.h",
    otherH:  root / "native" / "other.h",
    vendorH: depRoot / "vendor.h",
  )
  result.objAbs = result.nc / "@mnative@sadd.c.o"
  writeFile(result.epPath, "# main\n")
  writeFile(result.srcAbs, "// add.c\n")
  writeFile(result.addH, "// add.h v1\n")
  writeFile(result.otherH, "// other.h v1\n")
  writeFile(result.vendorH, "// vendor.h v1\n")

proc extCfg(p: ExtProject): Config =
  Config(projectRoot: p.root, stateDir: ".crisol", depRoots: @[p.depRoot])

proc coldCcCmd(p: ExtProject): string =
  ## The manifest `compile` entry's ccCmd for the cold-external case:
  ## ends "... -o <abs nimcache obj> <abs source.c>", carries a -c flag too
  ## (so the "-o"/"-c" stripping assertion is meaningful).
  "gcc -c -I" & (p.root / "native") & " -o " & p.objAbs & " " & p.srcAbs

# ---------------------------------------------------------------------------
# 1-5: extractCompileInputs
# ---------------------------------------------------------------------------

suite "extractCompileInputs — cold external (cc -M probe derivation)":

  test "cold external: headers = sorted tracked set (system header excluded); files superset; ccRun invoked with -M; headersHash matches; obj is a basename":
    let p = setupExtProject("cold")
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    writeManifest(p.nc, "main",
                 compile = @[(cPath: p.srcAbs, ccCmd: coldCcCmd(p))],
                 link    = @[p.nc / "@mmain.nim.c.o", p.objAbs])

    var callCount = 0
    var capturedCmd = ""
    var capturedArgs: seq[string] = @[]
    let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      inc callCount
      capturedCmd = cmd
      capturedArgs = @args
      # Reports: the source itself (excluded by exact match), a
      # project-relative header, an absolute project header, a dep-root
      # header (outside projectRoot entirely), and a system header.
      let output = p.objAbs & ": " & p.srcAbs & " native/add.h " &
                   p.otherH & " " & p.vendorH & " /usr/include/stdint.h\n"
      (output: output, ok: true)

    let savedCwd = getCurrentDir()
    setCurrentDir(p.root)   # so the relative "native/add.h" resolves against projectRoot
    defer: setCurrentDir(savedCwd)

    let inputs = extractCompileInputs(p.nc, "main", p.epPath, cfg, index, @[], ccRun)

    check callCount == 1
    check capturedCmd == "gcc"
    check "-M" in capturedArgs
    check "-o" notin capturedArgs
    check "-c" notin capturedArgs

    check inputs.externals.len == 1
    let ext = inputs.externals[0]
    check ext.obj == "@mnative@sadd.c.o"
    check ext.source == "native/add.c"

    var expectedHeaders = @["native/add.h", "native/other.h", p.vendorH.normalizedPath]
    expectedHeaders.sort()
    check ext.headers == expectedHeaders
    check "/usr/include/stdint.h" notin ext.headers   # system header excluded

    check ext.headersHash == chainedContentHash(ext.headers, p.root)

    # files ⊇ headers ∪ source
    check "native/add.c" in inputs.files
    for h in ext.headers:
      check h in inputs.files

  test "dedup: the same header reported both relative and absolute appears once":
    let p = setupExtProject("dedup")
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    writeManifest(p.nc, "main",
                 compile = @[(cPath: p.srcAbs, ccCmd: coldCcCmd(p))],
                 link    = @[p.objAbs])

    let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      let output = p.objAbs & ": " & p.srcAbs & " native/add.h " & p.addH & "\n"
      (output: output, ok: true)

    let savedCwd = getCurrentDir()
    setCurrentDir(p.root)
    defer: setCurrentDir(savedCwd)

    let inputs = extractCompileInputs(p.nc, "main", p.epPath, cfg, index, @[], ccRun)
    check inputs.externals.len == 1
    check inputs.externals[0].headers == @["native/add.h"]

  test "rfc-0007 A2c (issue #17): a relative header resolves against config.projectRoot, NOT the calling process's own cwd":
    ## Same relative-header shape as the dedup test above, but the process
    ## cwd is set to an UNRELATED third directory (neither p.root nor its
    ## parent) instead of p.root. Pre-A2c, extractCompileInputs resolved a
    ## relative cc -M header against getCurrentDir() — this would look for
    ## "native/add.h" under the unrelated dir, find nothing tracked, and
    ## silently drop it (index.underAnyRoot is false there). Post-A2c, the
    ## header must still resolve — against cfg.projectRoot — regardless of
    ## where the calling process's cwd happens to be.
    let p = setupExtProject("cwdpin")
    let elsewhere = freshRoot("cwdpin_elsewhere")
    defer: removeDir(elsewhere)
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    writeManifest(p.nc, "main",
                 compile = @[(cPath: p.srcAbs, ccCmd: coldCcCmd(p))],
                 link    = @[p.objAbs])

    let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      let output = p.objAbs & ": " & p.srcAbs & " native/add.h\n"
      (output: output, ok: true)

    let savedCwd = getCurrentDir()
    setCurrentDir(elsewhere)   # deliberately NOT p.root — the bug's exact trigger
    defer: setCurrentDir(savedCwd)

    let inputs = extractCompileInputs(p.nc, "main", p.epPath, cfg, index, @[], ccRun)
    check inputs.externals.len == 1
    check inputs.externals[0].headers == @["native/add.h"]
    check "native/add.h" in inputs.files

suite "extractCompileInputs — cached external (carried-forward headers)":

  test "no matching compile entry, a carried record for the source: headers carried verbatim, ccRun NOT invoked":
    let p = setupExtProject("carried")
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    # No compile entry at all -> hasCcCmd == false for this external.
    writeManifest(p.nc, "main", compile = @[], link = @[p.objAbs])

    var callCount = 0
    let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      inc callCount
      (output: "should never be reached", ok: true)

    let carried = @[ExternalSource(source: "native/add.c", obj: "@mnative@sadd.c.o",
                                   headers: @["native/add.h"], headersHash: "stale-hash-from-last-run")]
    let inputs = extractCompileInputs(p.nc, "main", p.epPath, cfg, index, carried, ccRun)

    check callCount == 0
    check inputs.externals.len == 1
    check inputs.externals[0].headers == @["native/add.h"]
    # headersHash is always FRESHLY computed from the carried headers'
    # current content, never the carried record's own (possibly stale) hash.
    check inputs.externals[0].headersHash == chainedContentHash(@["native/add.h"], p.root)

  test "no matching compile entry, no carried record: raises CrisolError cekEnvironment naming the source":
    let p = setupExtProject("nocarry")
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    writeManifest(p.nc, "main", compile = @[], link = @[p.objAbs])

    var raised = false
    try:
      discard extractCompileInputs(p.nc, "main", p.epPath, cfg, index, @[], realRun)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
      check "native/add.c" in e.msg
    check raised

suite "extractCompileInputs — cc -M probe failure":

  test "ccRun returning ok=false raises CrisolError cekEnvironment":
    let p = setupExtProject("probefail")
    let cfg = extCfg(p)
    let index = buildSourceIndex(cfg)
    writeManifest(p.nc, "main",
                 compile = @[(cPath: p.srcAbs, ccCmd: coldCcCmd(p))],
                 link    = @[p.objAbs])

    let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "", ok: false)

    var raised = false
    try:
      discard extractCompileInputs(p.nc, "main", p.epPath, cfg, index, @[], ccRun)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
    check raised

# ---------------------------------------------------------------------------
# 6-7: depgraph externals — round-trip + M10 load guard
# ---------------------------------------------------------------------------

suite "depgraph — externals round-trip (issue #16, format 5)":

  test "updateEntry with two unsorted externals (unsorted headers) round-trips sorted through save/loadStoredDepGraph":
    let root = freshRoot("dg_roundtrip")
    defer: removeDir(root)
    createDir(root / ".crisol")
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var g = initDepGraph("2.2.10")
    let path = "tests/t.nim"
    let fh = flagHash(@[])
    let closure = toHashSet(["tests/t.nim", "native/add.c", "native/add.h",
                             "native/b.c", "native/a.h", "native/z.h"])
    # Deliberately unsorted input order (b before add) and unsorted headers
    # (z before a) — production sorts both on write (depgraph.toJson).
    let externals = @[
      ExternalSource(source: "native/b.c", obj: "@mnative@sb.c.o",
                     headers: @["native/z.h", "native/a.h"], headersHash: "hashB"),
      ExternalSource(source: "native/add.c", obj: "@mnative@sadd.c.o",
                     headers: @["native/add.h"], headersHash: "hashA"),
    ]
    updateEntry(g, path, fh, closure, "closurehash123", 1, externals)
    doAssert saveDepGraph(g, cfg)

    let raw = readFile(depgraphPath(cfg))
    let node = parseJson(raw)
    check node["header"]["formatVersion"].getInt() == 5

    var discarded: DepGraphDiscard
    let loaded = loadStoredDepGraph(cfg, discarded)
    check discarded.kind == dgdNone
    check loaded.header.formatVersion == 5

    let entry = loaded.entries[(path, fh)]
    check entry.externals.len == 2
    check entry.externals[0].source == "native/add.c"
    check entry.externals[0].headers == @["native/add.h"]
    check entry.externals[0].headersHash == "hashA"
    check entry.externals[1].source == "native/b.c"
    check entry.externals[1].headers == @["native/a.h", "native/z.h"]
    check entry.externals[1].headersHash == "hashB"

suite "depgraph — M10 load guard extended to externals (issue #16)":

  test "a source escaping the root drops the whole record; an obj with a path separator drops the whole record; an escaping header drops only that header":
    let root = freshRoot("dg_guard")
    defer: removeDir(root)
    createDir(root / ".crisol")
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    let fh = flagHash(@[])

    let doc = %*{
      "header": {"nimVersion": "2.2.10", "formatVersion": DepGraphFormatVersion},
      "entries": [
        {
          "path": "tests/t.nim", "flagHash": fh,
          "closure": ["tests/t.nim"], "closureHash": "abc", "protocolMajor": 1,
          "externals": [
            # (a) source escapes the tracked root -> record dropped entirely.
            {"source": "../evil.c", "obj": "@mevil.c.o",
             "headers": newSeq[string](), "headersHash": ""},
            # (b) obj carries a path separator -> record dropped entirely.
            {"source": "native/bad.c", "obj": "sub/dir.o",
             "headers": newSeq[string](), "headersHash": ""},
            # (c) one header escapes the root -> only that header is dropped,
            # the record itself is kept.
            {"source": "native/add.c", "obj": "@mnative@sadd.c.o",
             "headers": ["native/add.h", "../evil.h"], "headersHash": "hash1"},
          ]
        }
      ]
    }
    writeFile(depgraphPath(cfg), $doc)

    var discarded: DepGraphDiscard
    let loaded = loadStoredDepGraph(cfg, discarded)
    check discarded.kind == dgdNone
    let entry = loaded.entries[("tests/t.nim", fh)]
    check entry.externals.len == 1
    check entry.externals[0].source == "native/add.c"
    check entry.externals[0].obj == "@mnative@sadd.c.o"
    check entry.externals[0].headers == @["native/add.h"]

# ---------------------------------------------------------------------------
# 8: staleExternalObjects
# ---------------------------------------------------------------------------

suite "staleExternalObjects (issue #16 slice 1b)":

  test "unchanged header content -> empty; an edited header -> only its obj; a deleted header -> that obj":
    let root = freshRoot("stale_content")
    defer: removeDir(root)
    createDir(root / "native")
    createDir(root / ".crisol")
    writeFile(root / "native" / "add.h", "// add.h v1\n")
    writeFile(root / "native" / "other.h", "// other.h v1\n")

    var g = initDepGraph("2.2.10")
    let path = "tests/t.nim"
    let fh = flagHash(@[])
    let hashAdd = chainedContentHash(@["native/add.h"], root)
    let hashOther = chainedContentHash(@["native/other.h"], root)
    let externals = @[
      ExternalSource(source: "native/add.c", obj: "objAdd.o",
                     headers: @["native/add.h"], headersHash: hashAdd),
      ExternalSource(source: "native/other.c", obj: "objOther.o",
                     headers: @["native/other.h"], headersHash: hashOther),
    ]
    updateEntry(g, path, fh, toHashSet(["tests/t.nim"]), "ch", 1, externals)

    check staleExternalObjects(g, path, @[], root).len == 0

    writeFile(root / "native" / "add.h", "// add.h v2 EDITED\n")
    check staleExternalObjects(g, path, @[], root) == @["objAdd.o"]

    writeFile(root / "native" / "add.h", "// add.h v1\n")   # restore
    check staleExternalObjects(g, path, @[], root).len == 0

    removeFile(root / "native" / "other.h")
    check staleExternalObjects(g, path, @[], root) == @["objOther.o"]

  test "headersHash == '' -> always stale regardless of content match; no entry for the key -> empty":
    let root = freshRoot("stale_edge")
    defer: removeDir(root)
    createDir(root / "native")
    createDir(root / ".crisol")
    writeFile(root / "native" / "add.h", "// add.h v1\n")
    writeFile(root / "native" / "other.h", "// other.h v1\n")

    var g = initDepGraph("2.2.10")
    let path = "tests/t.nim"
    let fh = flagHash(@[])
    let hashOther = chainedContentHash(@["native/other.h"], root)
    let externals = @[
      ExternalSource(source: "native/add.c", obj: "objAdd.o",
                     headers: @["native/add.h"], headersHash: ""),
      ExternalSource(source: "native/other.c", obj: "objOther.o",
                     headers: @["native/other.h"], headersHash: hashOther),
    ]
    updateEntry(g, path, fh, toHashSet(["tests/t.nim"]), "ch", 1, externals)

    let stale = staleExternalObjects(g, path, @[], root)
    check "objAdd.o" in stale
    check "objOther.o" notin stale

    check staleExternalObjects(g, "tests/nokey.nim", @[], root).len == 0

# ---------------------------------------------------------------------------
# 9: isModuleObjectName
# ---------------------------------------------------------------------------

suite "isModuleObjectName (issue #16 slice 1b)":

  test "true for a real Nim module object basename ('*.nim.c.o')":
    ## From tests/fixtures/golden_reuse/generated/ep_a/ep_a.json's `link`
    ## array (fixture_substrate.nim's own module object).
    check isModuleObjectName("@mfixture_substrate.nim.c.o")

  test "false for a {.compile.}d external's mangled single-path object":
    check not isModuleObjectName("@mnative@sadd.c.o")

  test "false for a bare foreign object basename":
    check not isModuleObjectName("foo.o")

when isMainModule:
  echo "All test_issue16_unit tests passed."
