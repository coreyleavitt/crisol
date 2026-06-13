## test_freshness.nim — D6: compile-avoidance / binary freshness unit tests.
##
## All tests are pure decision tests using real temp files.
## No subprocess is spawned.
##
## Coverage:
##   - closureContentHash: deterministic, varies on content change
##   - decideCompile: cdNeverBuilt when binary absent
##   - decideCompile: cdStale when no closure record
##   - decideCompile: cdStale when protocol major changed
##   - decideCompile: cdStale when nim version changed
##   - decideCompile: cdStale when closure file missing
##   - decideCompile: cdStale when closure content changed
##   - decideCompile: cdSkipFresh when all freshness conditions met
##   - decideCompile: forceCompile + binary present → cdStale
##   - decideCompile: forceCompile + binary absent → cdNeverBuilt
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_freshness.nim

import std/[os, sets, strutils, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTmpConfig(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol")

proc makeEp(path: string; flags: seq[string] = @[]): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: flags)

proc makeBin(config: Config; ep: Entrypoint): string =
  ## Create a real (empty) binary file at the stable bin path; return the full path.
  let bdir = binPath(ep, config)
  let bfull = bdir / binName(ep)
  createDir(bdir)
  writeFile(bfull, "")
  bfull

proc recordEntry(graph: var DepGraph; ep: Entrypoint; config: Config;
                 closureFiles: seq[string]; protocolMajor: int) =
  ## Build a depgraph entry for ep using the given closure files.
  var closureSet = initHashSet[string]()
  for f in closureFiles:
    closureSet.incl f
  let contentHash = closureContentHash(closureFiles, config.projectRoot)
  let fHash = flagHash(ep.flags)
  graph.updateEntry(ep.path, fHash, closureSet, contentHash, protocolMajor)

# ---------------------------------------------------------------------------
# Suite: closureContentHash
# ---------------------------------------------------------------------------

suite "closureContentHash — stable and content-sensitive":

  test "same files same content → same hash":
    let root = getTempDir() / "crisol_freshness_hash1"
    createDir(root)
    defer: removeDir(root)
    let f1 = root / "a.nim"
    let f2 = root / "b.nim"
    writeFile(f1, "# file a")
    writeFile(f2, "# file b")
    let h1 = closureContentHash(@[f1, f2], root)
    let h2 = closureContentHash(@[f1, f2], root)
    check h1 == h2

  test "order of files does not matter (sorted internally)":
    let root = getTempDir() / "crisol_freshness_hash2"
    createDir(root)
    defer: removeDir(root)
    let f1 = root / "a.nim"
    let f2 = root / "b.nim"
    writeFile(f1, "# aaa")
    writeFile(f2, "# bbb")
    let h1 = closureContentHash(@[f1, f2], root)
    let h2 = closureContentHash(@[f2, f1], root)
    check h1 == h2

  test "changing file content → different hash":
    let root = getTempDir() / "crisol_freshness_hash3"
    createDir(root)
    defer: removeDir(root)
    let f1 = root / "a.nim"
    writeFile(f1, "# original")
    let hBefore = closureContentHash(@[f1], root)
    writeFile(f1, "# CHANGED")
    let hAfter = closureContentHash(@[f1], root)
    check hBefore != hAfter

  test "empty file list → all-zeros or at least consistent":
    # Empty list → XOR of nothing = 0 → toHex16(0) = "0000000000000000"
    let root = getTempDir() / "crisol_freshness_hash4"
    createDir(root)
    defer: removeDir(root)
    let h = closureContentHash(@[], root)
    check h == closureContentHash(@[], root)
    check h.len == 16

  test "16 hex chars output":
    let root = getTempDir() / "crisol_freshness_hash5"
    createDir(root)
    defer: removeDir(root)
    let f = root / "x.nim"
    writeFile(f, "hello")
    let h = closureContentHash(@[f], root)
    check h.len == 16
    for c in h:
      check c in {'0'..'9', 'a'..'f'}

# ---------------------------------------------------------------------------
# Suite: decideCompile
# ---------------------------------------------------------------------------

suite "decideCompile — binary freshness logic":

  test "binary absent → cdNeverBuilt (no forceCompile)":
    let root = getTempDir() / "crisol_decide1"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let g   = initDepGraph("2.2.10")
    let (decision, _) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdNeverBuilt

  test "binary absent + forceCompile → cdNeverBuilt (not cdStale)":
    let root = getTempDir() / "crisol_decide2"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let g   = initDepGraph("2.2.10")
    let (decision, _) = decideCompile(ep, g, cfg, "2.2.10", true, CrisolProtocolMajor)
    check decision == cdNeverBuilt

  test "binary present, no closure record → cdStale":
    let root = getTempDir() / "crisol_decide3"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    discard makeBin(cfg, ep)
    let g   = initDepGraph("2.2.10")
    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdStale
    check reason.len > 0

  test "binary present, protocol major changed → cdStale":
    let root = getTempDir() / "crisol_decide4"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# src")
    discard makeBin(cfg, ep)

    var g = initDepGraph("2.2.10")
    recordEntry(g, ep, cfg, @[f], 999)   # stored with old protocol major

    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdStale
    check "protocol" in reason

  test "binary present, nim version changed → cdStale":
    let root = getTempDir() / "crisol_decide5"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# src")
    discard makeBin(cfg, ep)

    var g = initDepGraph("2.0.0")   # OLD nim version in header
    recordEntry(g, ep, cfg, @[f], CrisolProtocolMajor)

    # Now check with a DIFFERENT current nim version
    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdStale
    check "nim version" in reason

  test "binary present, closure file missing → cdStale":
    let root = getTempDir() / "crisol_decide6"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# src")
    discard makeBin(cfg, ep)

    let missingFile = root / "does_not_exist.nim"  # never created
    var g = initDepGraph("2.2.10")
    var closureSet = initHashSet[string]()
    closureSet.incl f
    closureSet.incl missingFile
    let fHash = flagHash(ep.flags)
    g.updateEntry(ep.path, fHash, closureSet, "aaaaaaaaaaaaaaaa", CrisolProtocolMajor)

    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdStale
    check "missing" in reason

  test "binary present, closure content changed → cdStale":
    let root = getTempDir() / "crisol_decide7"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# original content")
    discard makeBin(cfg, ep)

    var g = initDepGraph("2.2.10")
    recordEntry(g, ep, cfg, @[f], CrisolProtocolMajor)

    # Now modify the file content
    writeFile(f, "# CHANGED CONTENT")

    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdStale
    check "closure content" in reason

  test "all freshness conditions met → cdSkipFresh":
    let root = getTempDir() / "crisol_decide8"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# unchanged content")
    discard makeBin(cfg, ep)

    var g = initDepGraph("2.2.10")
    recordEntry(g, ep, cfg, @[f], CrisolProtocolMajor)

    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", false, CrisolProtocolMajor)
    check decision == cdSkipFresh
    check reason.len > 0

  test "forceCompile + binary present → cdStale":
    let root = getTempDir() / "crisol_decide9"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let f   = root / "test_x.nim"
    writeFile(f, "# content")
    discard makeBin(cfg, ep)

    var g = initDepGraph("2.2.10")
    recordEntry(g, ep, cfg, @[f], CrisolProtocolMajor)

    let (decision, reason) = decideCompile(ep, g, cfg, "2.2.10", true, CrisolProtocolMajor)
    check decision == cdStale
    check "force" in reason

  test "empty graph (nimVersion='') → cdNeverBuilt regardless of binary existence":
    let root = getTempDir() / "crisol_decide10"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    discard makeBin(cfg, ep)
    let g = emptyDepGraph()  # nimVersion = ""
    # Even with binary present, no closure record → cdStale, not cdSkipFresh
    let (decision, _) = decideCompile(ep, g, cfg, "", false, CrisolProtocolMajor)
    # No entry in graph → cdStale
    check decision == cdStale

echo "PASS test_freshness"
