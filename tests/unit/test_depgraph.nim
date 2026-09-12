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

proc tpSet(paths: varargs[string]): HashSet[TrackedPath] =
  ## RFC-0009 A3c-ii: build a `HashSet[TrackedPath]` via `classify` under a
  ## vacuous (zero-value) `TrackedRoots` -- matches `makeTmpConfig`'s
  ## `Config`, which leaves `trackedRoots` at ITS zero value too, so a
  ## closure built here round-trips identically through save/load in the
  ## SAME test (both sides classify under the same vacuous root). Every
  ## absolute OR project-relative spelling classifies `pcTracked` under
  ## this root by construction (see `classify`/`underRoot` with an empty
  ## `roots.project.abs`).
  result = initHashSet[TrackedPath]()
  for p in paths:
    let pc = classify(p, default(TrackedRoots))
    doAssert pc.kind == pcTracked, "test path failed to classify: " & p
    result.incl pc.tp

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
  let closure1 = tpSet("tests/unit/test_foo.nim", "src/crisol/foo.nim")

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
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))
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
  let cl1 = tpSet("tests/unit/test_x.nim", "src/a.nim")
  let cl2 = tpSet("tests/unit/test_x.nim", "src/b.nim")
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
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))
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
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))
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
  updateEntry(g, path, fh, tpSet(nonExistent))

  let key = (path, fh)
  assert isEntryStale(g, key, root, default(TrackedRoots)),
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
  updateEntry(g, path, fh, tpSet(realFile))

  let key = (path, fh)
  assert not isEntryStale(g, key, root, default(TrackedRoots)),
    "isEntryStale must be false when all closure files exist"

block test_isEntryStale_absent_entry:
  let root = getTempDir() / "crisol_depgraph_absent_entry"
  createDir(root)
  defer: removeDir(root)

  var g = initDepGraph("2.2.10")
  let key = ("tests/nonexistent.nim", flagHash(@[]))
  # Key is not in the graph at all — should be treated as stale
  assert isEntryStale(g, key, root, default(TrackedRoots)),
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

  updateEntry(g, keyA[0], keyA[1], tpSet("tests/unit/test_a.nim"), "", 0)
  updateEntry(g, keyB[0], keyB[1], tpSet("tests/unit/test_b.nim"), "", 0)

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

  let cl1 = tpSet("tests/unit/test_u.nim", "src/a.nim")
  updateEntry(g, path, fh, cl1)
  assert g.entries[(path, fh)].closure == cl1

  let cl2 = tpSet("tests/unit/test_u.nim", "src/b.nim")
  updateEntry(g, path, fh, cl2)
  assert g.entries[(path, fh)].closure == cl2, "upsert should overwrite old closure"

# ---------------------------------------------------------------------------
# P5 — symlink write-through protection for depgraph temp file
# ---------------------------------------------------------------------------

block test_saveDepGraph_symlink_write_through_protection:
  ## A pre-existing <depgraph>.<pid>.tmp symlink pointing to a sentinel file
  ## must NOT cause saveDepGraph to overwrite the sentinel.
  ## Mirror of the jsonout P3 test.
  let root = getTempDir() / "crisol_depgraph_p5sym"
  createDir(root)
  defer: removeDir(root)
  let stateDir = root / ".crisol"
  createDir(stateDir)

  let cfg        = makeTmpConfig(root)
  let finalPath  = stateDir / "depgraph"
  # RFC-0007 A3: saveDepGraph now writes via ioutils.atomicPublish, whose
  # temp path is PID-suffixed (`<finalPath>.<pid>.tmp`), not a bare
  # `<finalPath>.tmp` — plant the symlink at the REAL path atomicPublish
  # will actually open.
  let tmpPath    = finalPath & "." & $posix_mod.getpid() & ".tmp"

  # Plant a sentinel and a symlink at the .tmp location.
  let sentinel = root / "sentinel_must_not_be_overwritten.txt"
  writeFile(sentinel, "ORIGINAL")
  discard posix_mod.symlink(sentinel.cstring, tmpPath.cstring)

  var g = initDepGraph("2.2.10")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))

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
  let cl = tpSet("tests/unit/test_p5.nim")
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
  ## DepGraphFormatVersion is 6 as of RFC-0009 A3c-i: the header gains a
  ## `roots` descriptor (this file's own local tag->name table plus each
  ## named root's probed `foldPolicy`), so a graph persisted under one root
  ## layout / fold policy is never silently reused under another — an
  ## unknown root name or a fold-policy disagreement discards it as absent.
  ## A v5 (or older) graph predates that descriptor and is discarded once.
  ## (v5, issue #16: a {.compile.}d external's #include'd headers became
  ## tracked compile inputs recorded per-external in `externals`.)
  ## Bump this pin only together with a History entry in depgraph.nim and a
  ## CHANGELOG "BREAKING CHANGE — dependency graph format N" section.
  assert DepGraphFormatVersion == 6,
    "DepGraphFormatVersion pin: expected 6 (RFC-0009 A3c-i), got " & $DepGraphFormatVersion

  # A v4 graph on disk is treated as absent (discarded, not migrated).
  let root = getTempDir() / ("crisol_depgraph_v4pin_" & $getpid())
  removeDir(root)
  ensureStateDirExists(root)
  defer: removeDir(root)
  let v4 = %*{
    "header": {"nimVersion": "", "formatVersion": 4},
    "entries": [{"path": "tests/unit/test_x.nim", "flagHash": "cbf29ce484222325",
                 "closure": ["tests/unit/test_x.nim"], "closureHash": "00",
                 "protocolMajor": 1}]}
  writeFile(root / ".crisol" / "depgraph", $v4)
  let loaded = loadDepGraph(makeTmpConfig(root), "")
  assert loaded.entries.len == 0,
    "a format-4 depgraph must be discarded on load (got " & $loaded.entries.len & " entries)"

  # A v5 graph — the format immediately prior to the RFC-0009 A3c-i root
  # descriptor — predates the header `roots` table and is likewise discarded
  # once on load (the CHANGELOG format-6 migration promise). It carries the
  # v5 `externals` shape (issue #16) to prove the discard is driven purely by
  # the formatVersion mismatch, not by a shape parse failure.
  let root5 = getTempDir() / ("crisol_depgraph_v5pin_" & $getpid())
  removeDir(root5)
  ensureStateDirExists(root5)
  defer: removeDir(root5)
  let v5 = %*{
    "header": {"nimVersion": "", "formatVersion": 5},
    "entries": [{"path": "tests/unit/test_x.nim", "flagHash": "cbf29ce484222325",
                 "closure": ["tests/unit/test_x.nim"], "closureHash": "00",
                 "externals": [], "protocolMajor": 1}]}
  writeFile(root5 / ".crisol" / "depgraph", $v5)
  let loaded5 = loadDepGraph(makeTmpConfig(root5), "")
  assert loaded5.entries.len == 0,
    "a format-5 depgraph must be discarded on load (got " & $loaded5.entries.len & " entries)"
