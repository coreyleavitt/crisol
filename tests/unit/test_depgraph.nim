## test_depgraph.nim — TDD tests for D2: depgraph persistence and invalidation.
##
## Tests written FIRST (TDD), then implementation written to make them pass.
##
## Coverage:
##   - Round-trip: build graph, save, load → identical entries + header.
##   - Atomic/valid: after save, on-disk file is valid JSON.
##   - (path,flagHash) keying: same path, two flagHashes → two distinct entries.
##   - Nim-version mismatch → empty: different nim version → empty graph.
##   - Missing-file trigger: isEntryStale with absent closure file → true.
##   - Deleted-entrypoint GC: gcDeletedEntrypoints drops unlisted keys.
##   - Missing file → empty graph: loadDepGraph on missing depgraph → empty, no raise.

import std/[os, sets, json, tables]
import std/posix as posix_mod
import crisol/types
import crisol/depgraph

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTmpConfig(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol")

proc ensureStateDirExists(root: string) =
  createDir(root / ".crisol")

# ---------------------------------------------------------------------------
# Test: flagHash is stable and varies by flag set
# ---------------------------------------------------------------------------

block test_flagHash_stable:
  let h1 = flagHash(@["-d:foo", "-d:bar"])
  let h2 = flagHash(@["-d:foo", "-d:bar"])
  assert h1 == h2, "flagHash must be deterministic: got " & h1 & " vs " & h2

block test_flagHash_sorted:
  ## Same flags in different order → same hash (flags are sorted before hashing)
  let h1 = flagHash(@["-d:foo", "-d:bar"])
  let h2 = flagHash(@["-d:bar", "-d:foo"])
  assert h1 == h2, "flagHash must be order-independent: got " & h1 & " vs " & h2

block test_flagHash_varies:
  let h1 = flagHash(@["-d:foo"])
  let h2 = flagHash(@["-d:bar"])
  assert h1 != h2, "flagHash must differ for different flags"

block test_flagHash_length:
  let h = flagHash(@["-d:foo"])
  assert h.len == 16, "flagHash must be 16 hex chars, got len=" & $h.len

# ---------------------------------------------------------------------------
# Test: round-trip — build graph, save, load → identical entries + header
# ---------------------------------------------------------------------------

block test_round_trip:
  let root = getTempDir() / "crisol_depgraph_roundtrip"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")

  let fh1 = flagHash(@["-d:foo"])
  var closure1 = initHashSet[string]()
  closure1.incl "tests/unit/test_foo.nim"
  closure1.incl "src/crisol/foo.nim"

  updateEntry(g, "tests/unit/test_foo.nim", fh1, closure1)

  doAssert saveDepGraph(g, cfg)

  let g2 = loadDepGraph(cfg, "2.2.10")
  assert g2.header.nimVersion == "2.2.10",
    "loaded header nim version mismatch: " & g2.header.nimVersion
  assert g2.header.formatVersion == DepGraphFormatVersion,
    "loaded header format version mismatch"

  let key = ("tests/unit/test_foo.nim", fh1)
  assert key in g2.entries, "entry not found after round-trip"
  let loaded = g2.entries[key]
  assert loaded.closure == closure1,
    "closure mismatch after round-trip: " & $loaded.closure & " vs " & $closure1

# ---------------------------------------------------------------------------
# Test: atomic/valid — after save, on-disk file is valid JSON
# ---------------------------------------------------------------------------

block test_atomic_valid_json:
  let root = getTempDir() / "crisol_depgraph_atomic"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, toHashSet(["tests/t.nim"]))
  doAssert saveDepGraph(g, cfg)

  let depgraphPath = root / ".crisol" / "depgraph"
  assert fileExists(depgraphPath), "depgraph file not found after save"

  let raw = readFile(depgraphPath)
  let node = parseJson(raw)  # raises if malformed
  assert node.kind == JObject, "top-level JSON must be an object"

# ---------------------------------------------------------------------------
# Test: (path, flagHash) keying — same path, two flagHashes → two entries
# ---------------------------------------------------------------------------

block test_two_flaghashes_same_path:
  let root = getTempDir() / "crisol_depgraph_keying"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")

  let fh1 = flagHash(@["-d:foo"])
  let fh2 = flagHash(@["-d:bar"])
  assert fh1 != fh2

  let path = "tests/unit/test_x.nim"
  let cl1 = toHashSet(["tests/unit/test_x.nim", "src/a.nim"])
  let cl2 = toHashSet(["tests/unit/test_x.nim", "src/b.nim"])
  updateEntry(g, path, fh1, cl1)
  updateEntry(g, path, fh2, cl2)

  doAssert saveDepGraph(g, cfg)
  let g2 = loadDepGraph(cfg, "2.2.10")

  assert (path, fh1) in g2.entries, "entry fh1 not found"
  assert (path, fh2) in g2.entries, "entry fh2 not found"
  assert g2.entries[(path, fh1)].closure == cl1, "closure for fh1 wrong"
  assert g2.entries[(path, fh2)].closure == cl2, "closure for fh2 wrong"

# ---------------------------------------------------------------------------
# Test: nim-version mismatch → empty graph
# ---------------------------------------------------------------------------

block test_nim_version_mismatch_empty:
  let root = getTempDir() / "crisol_depgraph_version"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, toHashSet(["tests/t.nim"]))
  doAssert saveDepGraph(g, cfg)

  # Load with a DIFFERENT nim version → should get empty graph
  let g2 = loadDepGraph(cfg, "2.4.0")
  assert g2.entries.len == 0,
    "expected empty graph on nim-version mismatch, got " & $g2.entries.len & " entries"

block test_nim_version_match_entries_present:
  let root = getTempDir() / "crisol_depgraph_version2"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, toHashSet(["tests/t.nim"]))
  doAssert saveDepGraph(g, cfg)

  let g2 = loadDepGraph(cfg, "2.2.10")
  assert g2.entries.len == 1, "expected 1 entry on nim-version match"

# ---------------------------------------------------------------------------
# Test: missing-file trigger — isEntryStale
# ---------------------------------------------------------------------------

block test_isEntryStale_missing_file:
  let root = getTempDir() / "crisol_depgraph_stale"
  createDir(root)
  defer: removeDir(root)

  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_foo.nim"
  let fh = flagHash(@[])
  # Closure includes a path that definitely does not exist
  let nonExistent = root / "this_does_not_exist.nim"
  updateEntry(g, path, fh, toHashSet([nonExistent]))

  let key = (path, fh)
  assert isEntryStale(g, key, root),
    "isEntryStale must be true when closure contains a non-existent file"

block test_isEntryStale_all_files_exist:
  let root = getTempDir() / "crisol_depgraph_fresh"
  createDir(root)
  defer: removeDir(root)

  # Create a real file in the closure
  let realFile = root / "real.nim"
  writeFile(realFile, "# stub")

  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_real.nim"
  let fh = flagHash(@[])
  updateEntry(g, path, fh, toHashSet([realFile]))

  let key = (path, fh)
  assert not isEntryStale(g, key, root),
    "isEntryStale must be false when all closure files exist"

block test_isEntryStale_absent_entry:
  let root = getTempDir() / "crisol_depgraph_absent_entry"
  createDir(root)
  defer: removeDir(root)

  var g = initDepGraph("2.2.10")
  let key = ("tests/nonexistent.nim", flagHash(@[]))
  # Key is not in the graph at all — should be treated as stale
  assert isEntryStale(g, key, root),
    "isEntryStale must be true when entry is absent from graph"

# ---------------------------------------------------------------------------
# Test: deleted-entrypoint GC
# ---------------------------------------------------------------------------

block test_gcDeletedEntrypoints:
  var g = initDepGraph("2.2.10")

  let fhA = flagHash(@["-d:a"])
  let fhB = flagHash(@["-d:b"])
  let keyA = ("tests/unit/test_a.nim", fhA)
  let keyB = ("tests/unit/test_b.nim", fhB)

  updateEntry(g, keyA[0], keyA[1], toHashSet(["tests/unit/test_a.nim"]), "", 0)
  updateEntry(g, keyB[0], keyB[1], toHashSet(["tests/unit/test_b.nim"]), "", 0)

  assert g.entries.len == 2

  # GC keeping only A
  gcDeletedEntrypoints(g, toHashSet([keyA]))

  assert keyA in g.entries, "keyA should be retained after GC"
  assert keyB notin g.entries, "keyB should be dropped after GC"
  assert g.entries.len == 1, "only 1 entry should remain"

# ---------------------------------------------------------------------------
# Test: missing depgraph file → empty graph (no raise)
# ---------------------------------------------------------------------------

block test_missing_depgraph_empty:
  let root = getTempDir() / "crisol_depgraph_missing"
  createDir(root)
  defer: removeDir(root)
  # Do NOT create .crisol/ or the depgraph file

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")
  assert g.entries.len == 0, "expected empty graph for missing depgraph file"
  # Must not raise

# ---------------------------------------------------------------------------
# Test: updateEntry upserts correctly
# ---------------------------------------------------------------------------

block test_updateEntry_upsert:
  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_u.nim"
  let fh = flagHash(@[])

  let cl1 = toHashSet(["tests/unit/test_u.nim", "src/a.nim"])
  updateEntry(g, path, fh, cl1)
  assert g.entries[(path, fh)].closure == cl1

  let cl2 = toHashSet(["tests/unit/test_u.nim", "src/b.nim"])
  updateEntry(g, path, fh, cl2)
  assert g.entries[(path, fh)].closure == cl2, "upsert should overwrite old closure"

# ---------------------------------------------------------------------------
# P5 — symlink write-through protection for depgraph temp file
# ---------------------------------------------------------------------------

block test_saveDepGraph_symlink_write_through_protection:
  ## A pre-existing <depgraph>.tmp symlink pointing to a sentinel file must NOT
  ## cause saveDepGraph to overwrite the sentinel.
  ## Mirror of the jsonout P3 test.
  let root = getTempDir() / "crisol_depgraph_p5sym"
  createDir(root)
  defer: removeDir(root)
  let stateDir = root / ".crisol"
  createDir(stateDir)

  let cfg        = makeTmpConfig(root)
  let finalPath  = stateDir / "depgraph"
  let tmpPath    = finalPath & ".tmp"

  # Plant a sentinel and a symlink at the .tmp location.
  let sentinel = root / "sentinel_must_not_be_overwritten.txt"
  writeFile(sentinel, "ORIGINAL")
  discard posix_mod.symlink(sentinel.cstring, tmpPath.cstring)

  var g = initDepGraph("2.2.10")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, toHashSet(["tests/t.nim"]))

  # Must not crash; sentinel must remain untouched.
  doAssert saveDepGraph(g, cfg)

  let sentinelContent = readFile(sentinel)
  assert sentinelContent == "ORIGINAL",
    "P5: sentinel was overwritten through symlink (got: " & sentinelContent & ")"

block test_saveDepGraph_normal_roundtrip_after_p5:
  ## Verify the happy path (no stale .tmp) still works after the P5 fix.
  let root = getTempDir() / "crisol_depgraph_p5happy"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10")
  let fh = flagHash(@["-d:test"])
  var cl = initHashSet[string]()
  cl.incl "tests/unit/test_p5.nim"
  updateEntry(g, "tests/unit/test_p5.nim", fh, cl)

  doAssert saveDepGraph(g, cfg)

  let g2 = loadDepGraph(cfg, "2.2.10")
  let key = ("tests/unit/test_p5.nim", fh)
  assert key in g2.entries, "P5 happy-path: entry not found after round-trip"
  assert g2.entries[key].closure == cl, "P5 happy-path: closure mismatch"

echo "PASS test_depgraph"

# ---------------------------------------------------------------------------
# Test: format version pin (issue #11)
# ---------------------------------------------------------------------------

block test_format_version_pin:
  ## DepGraphFormatVersion is 4 as of issue #11: closures now cover
  ## non-module compile inputs (include'd files, staticRead/slurp targets,
  ## nim.cfg/config.nims, {.compile.}d sources, {.link.}ed objects). A v3
  ## closure missing one of those inputs hash-matches itself forever and
  ## its nimcache manifest (compiled without -d:nimBetterRun) carries no
  ## `depfiles` to re-derive from, so the graph must be discarded once.
  ## Bump this pin only together with a History entry in depgraph.nim and a
  ## CHANGELOG "BREAKING CHANGE — dependency graph format N" section.
  assert DepGraphFormatVersion == 4,
    "DepGraphFormatVersion pin: expected 4 (issue #11), got " & $DepGraphFormatVersion

  # A v3 graph on disk is treated as absent (discarded, not migrated).
  let root = getTempDir() / ("crisol_depgraph_v3pin_" & $getpid())
  removeDir(root)
  ensureStateDirExists(root)
  defer: removeDir(root)
  let v3 = %*{
    "header": {"nimVersion": "", "formatVersion": 3},
    "entries": [{"path": "tests/unit/test_x.nim", "flagHash": "cbf29ce484222325",
                 "closure": ["tests/unit/test_x.nim"], "closureHash": "00",
                 "protocolMajor": 1}]}
  writeFile(root / ".crisol" / "depgraph", $v3)
  let loaded = loadDepGraph(makeTmpConfig(root), "")
  assert loaded.entries.len == 0,
    "a format-3 depgraph must be discarded on load (got " & $loaded.entries.len & " entries)"
