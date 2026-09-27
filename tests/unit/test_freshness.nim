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
##   - decideCompile: cdStale when closure file missing
##   - decideCompile: cdStale when closure content changed
##   - decideCompile: cdSkipFresh when all freshness conditions met
##   - decideCompile: forceCompile + binary present → cdStale
##   - decideCompile: forceCompile + binary absent → cdNeverBuilt
##
## NOT covered here, deliberately (R3-8, round 5, 2026-09-24): nim-version and
## cc-version staleness. `decideCompile` does not decide those — `loadDepGraph`
## does, and tests/unit/test_depgraph.nim owns their assertions. See the moved-out
## note in the decideCompile suite below.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_freshness.nim

import std/[os, sets, strutils, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner
import "../support/testep"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pairsOf(paths: seq[string]): seq[tuple[key: string; nativePath: string]] =
  ## RFC-0009 A5a: closureContentHash now takes (key, nativePath) pairs.
  ## Every path in the suite below is already absolute, so key == nativePath
  ## — this preserves the pre-A5a behavior of chaining the given path itself.
  for p in paths: result.add((key: p, nativePath: p))

proc makeTmpConfig(root: string): Config =
  ## RFC-0009 A3c-ii: `trackedRoots` must be REAL (matching `root`), not the
  ## zero-value/vacuous root -- `decideCompile` (planner.nim) reconstructs
  ## each closure member's content-hash input via `depgraph.closureHashInputs`
  ## (`keyBytes` as the hashed key, content read from `toNative`) against
  ## `config.trackedRoots`, and this file's `recordEntry` helper
  ## must reconstruct the IDENTICAL string at record time for the hash
  ## comparison to ever match (see `recordEntry`, below).
  result = Config(projectRoot: root, stateDir: ".crisol")
  result.trackedRoots = initTrackedRoots(root, @[], "")

proc makeEp(path: string; flags: seq[string] = @[]): Entrypoint =
  testEp(path, group = "unit", flags = flags)

proc makeBin(config: Config; ep: Entrypoint): string =
  ## Create a real (empty) binary file at the stable bin path; return the full
  ## path. RFC-0009 B4a: this MUST use the platform executable extension
  ## (`addFileExt(_, ExeExt)`) so the fixture writes to the SAME path
  ## `decideCompile` now checks for freshness (`stableBinPath`) and that
  ## `promoteCompiledBinary` copies to on a real compile — on Windows the
  ## linker emits `<name>.exe`, so an extensionless fixture binary is invisible
  ## to the freshness check there and every decision diverges. `ExeExt == ""`
  ## on POSIX, so this is byte-identical to the old path there.
  let bdir = binPath(ep, config)
  let bfull = addFileExt(bdir / binName(ep), ExeExt)
  createDir(bdir)
  writeFile(bfull, "")
  bfull

proc recordEntry(graph: var DepGraph; ep: Entrypoint; config: Config;
                 closureFiles: seq[string]; protocolMajor: int) =
  ## Build a depgraph entry for ep using the given closure files (absolute
  ## paths on disk).
  ##
  ## RFC-0009 A3c-ii: `closureFiles` is converted to `HashSet[TrackedPath]`
  ## for STORAGE via `classify`. The content hash must be computed over the
  ## SAME per-member strings `decideCompile` reconstructs at compare time
  ## (`depgraph.closureHashInputs`: `keyBytes` as the hashed key --
  ## byte-identical to `display` for a tag-0/project member, portable
  ## `dep:<name>/<rel>` for a tag>0/dep-root member -- with `toNative` only
  ## as the content-read path; see planner.nim's `decideCompile`) -- NOT the raw absolute
  ## `closureFiles` strings -- or the hash could never match again.
  var closureSet = initHashSet[TrackedPath]()
  for f in closureFiles:
    let pc = classify(f, config.trackedRoots)
    doAssert pc.kind == pcTracked, "test closure file failed to classify: " & f
    closureSet.incl pc.tp
  # RFC-0009 A5a: use the SAME `depgraph.closureHashInputs` derivation
  # production's `recordClosure` uses — the record==recheck proof this
  # suite exists to pin.
  let contentHash = closureContentHash(closureHashInputs(closureSet, config.trackedRoots))
  let fHash = flagHash(ep.flags)
  graph.updateEntry(string(ep.tp.display()), fHash, closureSet, @[], contentHash, protocolMajor)

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
    let h1 = closureContentHash(pairsOf(@[f1, f2]))
    let h2 = closureContentHash(pairsOf(@[f1, f2]))
    check h1 == h2

  test "order of files does not matter (sorted internally)":
    let root = getTempDir() / "crisol_freshness_hash2"
    createDir(root)
    defer: removeDir(root)
    let f1 = root / "a.nim"
    let f2 = root / "b.nim"
    writeFile(f1, "# aaa")
    writeFile(f2, "# bbb")
    let h1 = closureContentHash(pairsOf(@[f1, f2]))
    let h2 = closureContentHash(pairsOf(@[f2, f1]))
    check h1 == h2

  test "changing file content → different hash":
    let root = getTempDir() / "crisol_freshness_hash3"
    createDir(root)
    defer: removeDir(root)
    let f1 = root / "a.nim"
    writeFile(f1, "# original")
    let hBefore = closureContentHash(pairsOf(@[f1]))
    writeFile(f1, "# CHANGED")
    let hAfter = closureContentHash(pairsOf(@[f1]))
    check hBefore != hAfter

  test "empty file list → all-zeros or at least consistent":
    # Empty list → XOR of nothing = 0 → toHex16(0) = "0000000000000000"
    let root = getTempDir() / "crisol_freshness_hash4"
    createDir(root)
    defer: removeDir(root)
    let h = closureContentHash(pairsOf(@[]))
    check h == closureContentHash(pairsOf(@[]))
    check h.len == 16

  test "16 hex chars output":
    let root = getTempDir() / "crisol_freshness_hash5"
    createDir(root)
    defer: removeDir(root)
    let f = root / "x.nim"
    writeFile(f, "hello")
    let h = closureContentHash(pairsOf(@[f]))
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
    let (decision, _) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
    check decision == cdNeverBuilt

  test "binary absent + forceCompile → cdNeverBuilt (not cdStale)":
    let root = getTempDir() / "crisol_decide2"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    let g   = initDepGraph("2.2.10")
    let (decision, _) = decideCompile(ep, g, cfg, true, CrisolProtocolMajor)
    check decision == cdNeverBuilt

  test "binary present, no closure record → cdStale":
    let root = getTempDir() / "crisol_decide3"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    discard makeBin(cfg, ep)
    let g   = initDepGraph("2.2.10")
    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
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

    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
    check decision == cdStale
    check "protocol" in reason

  # MOVED OUT, round 5, 2026-09-24 (R3-8). Two cases used to sit here:
  # "binary present, nim version changed -> cdStale" and its cc-version twin.
  # Both hand-built a DepGraph whose header nimVersion/ccVersion disagreed with
  # the values passed to `decideCompile`, and both are gone because the arms
  # they exercised are gone: `decideCompile` no longer takes `nimVersion` or
  # `ccVersion`, since a graph that came through `depgraph.loadDepGraph` always
  # has a header matching the live toolchain (the loader discards a mismatched
  # graph and re-stamps the header on the success path), so those arms could
  # never fire on any reachable path. Only a hand-built graph -- i.e. only
  # these two tests -- ever reached them.
  #
  # The COVERAGE moved to where the live mechanism is, not away: the
  # dgdNimVersion / dgdCcVersion blocks in tests/unit/test_depgraph.nim assert
  # the loader's discard (mismatched header -> empty graph stamped with the
  # REQUESTED versions, with the discard reason named) and the success path's
  # header re-stamp -- which is the invariant this file's deleted cases were
  # unknowingly asserting the redundant shadow of. Rationale and the mutation
  # proof are at R3-8 in docs/handoff/msvc-selection-layer.md; the end-to-end
  # leg is tests/integration/test_cc_depgraph_liveness.nim.

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
    var closureSet = initHashSet[TrackedPath]()
    for p in [f, missingFile]:
      let pc = classify(p, cfg.trackedRoots)
      doAssert pc.kind == pcTracked, "test closure file failed to classify: " & p
      closureSet.incl pc.tp
    let fHash = flagHash(ep.flags)
    g.updateEntry(string(ep.tp.display()), fHash, closureSet, @[], "aaaaaaaaaaaaaaaa", CrisolProtocolMajor)

    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
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

    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
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

    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
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

    let (decision, reason) = decideCompile(ep, g, cfg, true, CrisolProtocolMajor)
    check decision == cdStale
    check "force" in reason

  test "empty graph (nimVersion='') + binary present → cdStale (no closure record), never cdSkipFresh":
    let root = getTempDir() / "crisol_decide10"
    createDir(root)
    defer: removeDir(root)
    let cfg = makeTmpConfig(root)
    let ep  = makeEp("tests/unit/test_x.nim")
    discard makeBin(cfg, ep)
    let g = emptyDepGraph()  # nimVersion = ""
    # The binary is present, so this is not cdNeverBuilt (that is binary
    # absence, the first case above); the graph holds no closure record for
    # it, so decideCompile's step 2 answers cdStale -- never cdSkipFresh.
    let (decision, reason) = decideCompile(ep, g, cfg, false, CrisolProtocolMajor)
    check decision == cdStale
    check "no closure record" in reason

echo "PASS test_freshness"
