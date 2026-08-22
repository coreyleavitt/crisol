## test_parse_compile_manifest.nim — unit tests for closure.parseCompileManifest
## (RFC-0006 §File scoping / "Manifest access").
##
## `parseCompileManifest` is the shared low-level nimcache-JSON reader factored
## out of `extractClosure`. Unlike `extractClosure`, it does NO filtering: it
## returns the RAW `compile` array (every (cPath, ccCmd) pair, stdlib/nimble
## included) plus the `linkcmd` string. RFC-0006's M/R stages consume this raw
## shape; `extractClosure` becomes a filter over it (see test_closure.nim,
## which proves that refactor is behavior-preserving).
##
## All I/O here is a tiny synthetic JSON fixture written to a temp dir — no
## real `nim c` invocation.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_parse_compile_manifest.nim

import std/[os, unittest]
import crisol/closure
import crisol/types

# ---------------------------------------------------------------------------
# Helper: write a synthetic manifest JSON, return its path.
# ---------------------------------------------------------------------------

proc writeManifest(dir: string; content: string): string =
  createDir(dir)
  result = dir / "synthetic.json"
  writeFile(result, content)

let tmpRoot = getTempDir() / "crisol_test_parse_manifest_" & $getCurrentProcessId()

# ---------------------------------------------------------------------------
# Suite 1: raw, unfiltered compile array + linkcmd
# ---------------------------------------------------------------------------

suite "parseCompileManifest — raw unfiltered read":

  test "returns compile pairs in file order, including stdlib/nimble paths":
    let json = """
    {
      "compile": [
        ["/opt/nim/lib/@psystem.nim.c", "gcc -c /opt/nim/lib/@psystem.nim.c -o /opt/nim/lib/@psystem.nim.c.o"],
        ["/proj/nimcache/@mmain.nim.c", "gcc -c /proj/nimcache/@mmain.nim.c -o /proj/nimcache/@mmain.nim.c.o"]
      ],
      "linkcmd": "gcc -o /proj/bin/main /proj/nimcache/@mmain.nim.c.o /opt/nim/lib/@psystem.nim.c.o"
    }
    """
    let path = writeManifest(tmpRoot / "t1", json)
    let manifest = parseCompileManifest(path)

    check manifest.compile.len == 2
    # Order preserved — first entry is the stdlib path (NOT filtered out).
    check manifest.compile[0].cPath == "/opt/nim/lib/@psystem.nim.c"
    check manifest.compile[0].ccCmd == "gcc -c /opt/nim/lib/@psystem.nim.c -o /opt/nim/lib/@psystem.nim.c.o"
    check manifest.compile[1].cPath == "/proj/nimcache/@mmain.nim.c"
    check manifest.compile[1].ccCmd == "gcc -c /proj/nimcache/@mmain.nim.c -o /proj/nimcache/@mmain.nim.c.o"
    check manifest.linkcmd == "gcc -o /proj/bin/main /proj/nimcache/@mmain.nim.c.o /opt/nim/lib/@psystem.nim.c.o"

  test "link array is returned raw: every object path, externals included":
    let json = """
    {
      "compile": [],
      "link": ["/proj/nimcache/@mmain.nim.c.o", "/opt/nim/lib/@psystem.nim.c.o", "/opt/vendor/libfoo.o"],
      "linkcmd": "gcc -o /proj/bin/main"
    }
    """
    let path = writeManifest(tmpRoot / "t_link", json)
    let manifest = parseCompileManifest(path)
    check manifest.compile.len == 0
    check manifest.link == @["/proj/nimcache/@mmain.nim.c.o",
                             "/opt/nim/lib/@psystem.nim.c.o",
                             "/opt/vendor/libfoo.o"]

  test "missing link array yields an empty link seq, not an error":
    let json = """{ "compile": [], "linkcmd": "" }"""
    let path = writeManifest(tmpRoot / "t_nolink", json)
    check parseCompileManifest(path).link.len == 0

  test "empty compile array yields empty result, linkcmd still read":
    let json = """{"compile": [], "linkcmd": "gcc -o /proj/bin/main"}"""
    let path = writeManifest(tmpRoot / "t2", json)
    let manifest = parseCompileManifest(path)

    check manifest.compile.len == 0
    check manifest.linkcmd == "gcc -o /proj/bin/main"

  test "missing linkcmd field yields empty string, not an error":
    let json = """{"compile": [["/a.c", "cc /a.c"]]}"""
    let path = writeManifest(tmpRoot / "t3", json)
    let manifest = parseCompileManifest(path)

    check manifest.compile.len == 1
    check manifest.linkcmd == ""

  test "entries with empty cPath are skipped (matches extractClosure's prior guard)":
    let json = """
    {
      "compile": [
        ["", "cc "],
        ["/b.c", "cc /b.c"]
      ],
      "linkcmd": ""
    }
    """
    let path = writeManifest(tmpRoot / "t4", json)
    let manifest = parseCompileManifest(path)

    check manifest.compile.len == 1
    check manifest.compile[0].cPath == "/b.c"

# ---------------------------------------------------------------------------
# Suite 2: error handling (mirrors extractClosure's existing contract)
# ---------------------------------------------------------------------------

suite "parseCompileManifest — error handling":

  test "missing JSON file raises CrisolError cekEnvironment":
    let bogus = tmpRoot / "does_not_exist.json"
    try:
      discard parseCompileManifest(bogus)
      fail()
    except CrisolError as e:
      check e.kind == cekEnvironment

  test "unparseable JSON raises CrisolError cekEnvironment":
    let path = writeManifest(tmpRoot / "t5", "{ not valid json ")
    try:
      discard parseCompileManifest(path)
      fail()
    except CrisolError as e:
      check e.kind == cekEnvironment

  test "JSON with no 'compile' array raises CrisolError cekEnvironment":
    let path = writeManifest(tmpRoot / "t6", """{"linkcmd": "gcc -o x"}""")
    try:
      discard parseCompileManifest(path)
      fail()
    except CrisolError as e:
      check e.kind == cekEnvironment

when isMainModule:
  echo "All parseCompileManifest tests passed."
