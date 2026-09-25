## test_depgraph.nim — TDD tests for D2: depgraph persistence and invalidation.
##
## Tests written FIRST (TDD), then implementation written to make them pass.
##
## Coverage:
##   - Round-trip: build graph, save, load → identical entries + header.
##   - Atomic/valid: after save, on-disk file is valid JSON.
##   - (path,flagHash) keying: same path, two flagHashes → two distinct entries.
##   - Nim-version mismatch → empty: different nim version → empty graph.
##   - Toolchain-staleness gate (R3-8): nim/cc mismatch → the right discard
##     reason and a replacement header stamped with the REQUESTED versions;
##     nim-before-cc priority; success-path header re-stamp.
##   - Missing-file trigger: isEntryStale with absent closure file → true.
##   - Deleted-entrypoint GC: gcDeletedEntrypoints drops unlisted keys.
##   - Missing file → empty graph: loadDepGraph on missing depgraph → empty, no raise.

import std/[options, os, sets, json, tables, strutils]
import crisol/types
import crisol/depgraph
import ../support/symlinkprobe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTmpConfig(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol")

proc ensureStateDirExists(root: string) =
  createDir(root / ".crisol")

proc fixedProbe(policy: FoldPolicy): FoldProbe =
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy)

let tpSetRoots = initTrackedRoots(getTempDir(), @[], "", fixedProbe(fpNone))
  ## RFC-0009 B4a: a REAL `TrackedRoots` anchored at the OS temp directory,
  ## with a FIXED fpNone fold probe. Two reasons for both choices:
  ##   * REAL root (not the vacuous/zero-value `default(TrackedRoots)`): a
  ##     zero root (project.abs == "") only classified a path `pcTracked` by
  ##     accident of `underRoot`'s "/"-prefix fallback — a POSIX-only
  ##     coincidence that matched every ABSOLUTE spelling on Linux/macOS but
  ##     never on Windows (`C:\...` doesn't start with "/"). `getTempDir()` is
  ##     an ancestor of every real absolute path this file builds.
  ##   * FIXED fpNone (not the host-probed default): the tps built here are
  ##     compared with `==` against tps `loadDepGraph` reconstructs under a
  ##     `makeTmpConfig` whose `trackedRoots` is the default (fpNone). A
  ##     host-probed policy makes this root fpAsciiLower on macOS/Windows,
  ##     tripping TrackedPath's `a.fold == b.fold` same-policy invariant on
  ##     those legs (it was invisible on Linux, where the probe returns
  ##     fpNone anyway). fpNone keeps every tp in this file on one policy.

proc tpSet(paths: varargs[string]): HashSet[TrackedPath] =
  ## Build a `HashSet[TrackedPath]` via `classify` under `tpSetRoots` (see
  ## above). Every absolute OR project-relative spelling classifies
  ## `pcTracked` under this root by construction.
  result = initHashSet[TrackedPath]()
  for p in paths:
    let pc = classify(p, tpSetRoots)
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
# Test: cc-version mismatch → empty graph (W3, nimVersion's sibling check)
# ---------------------------------------------------------------------------

block test_cc_version_mismatch_empty:
  let root = getTempDir() / "crisol_depgraph_ccversion"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10", "cc-OLD")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))
  doAssert saveDepGraph(g, cfg)

  # Same nim version, DIFFERENT cc version → should get empty graph.
  let g2 = loadDepGraph(cfg, "2.2.10", "cc-NEW")
  assert g2.entries.len == 0,
    "expected empty graph on cc-version mismatch, got " & $g2.entries.len & " entries"

block test_cc_version_match_entries_present:
  let root = getTempDir() / "crisol_depgraph_ccversion2"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10", "cc-OLD")
  let fh = flagHash(@[])
  updateEntry(g, "tests/t.nim", fh, tpSet("tests/t.nim"))
  doAssert saveDepGraph(g, cfg)

  let g2 = loadDepGraph(cfg, "2.2.10", "cc-OLD")
  assert g2.entries.len == 1, "expected 1 entry on cc-version match"
  assert g2.header.ccVersion == "cc-OLD", "loaded header cc version mismatch: " & g2.header.ccVersion

# ---------------------------------------------------------------------------
# Test: the toolchain-staleness gate is HERE, and nowhere else
#
# R3-8, round 5, 2026-09-24. `planner.decideCompile` used to carry two arms of
# its own -- `graph.header.nimVersion != nimVersion` and its ccVersion twin,
# each returning cdStale -- with two cases in tests/unit/test_freshness.nim
# hand-building a mismatched-header graph to reach them. Those arms could never
# fire on a graph that came through `loadDepGraph` (it discards a mismatched
# graph, and re-stamps the header on the success path), so they were removed
# along with the parameters they read, and their coverage moved HERE, to the
# mechanism that is genuinely live.
#
# The two blocks above already prove the entries-are-dropped half. These add
# what the moved cases were really asserting and what the two above leave
# implicit: the discard REASON that the caller surfaces as a ConfigWarning, the
# REQUESTED-not-stored header stamp on the discarded-graph replacement, the
# nim-before-cc priority when both moved, and the success-path re-stamp that is
# the whole reason `decideCompile` can trust `graph.header`.
# ---------------------------------------------------------------------------

block test_nim_version_mismatch_reason_and_stamp:
  let root = getTempDir() / "crisol_depgraph_nimver_reason"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10", "cc-OLD")
  updateEntry(g, "tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"))
  doAssert saveDepGraph(g, cfg)

  var discarded = DepGraphDiscard(kind: dgdNone)
  let g2 = loadDepGraph(cfg, "2.4.0", discarded, "cc-OLD")

  doAssert discarded.kind == dgdNimVersion,
    "nim-version mismatch must be reported as dgdNimVersion, got " & $discarded.kind
  doAssert discarded.stored == "2.2.10",
    "discard provenance lost the STORED nim version: " & discarded.stored
  doAssert discarded.current == "2.4.0",
    "discard provenance lost the CURRENT nim version: " & discarded.current
  doAssert g2.entries.len == 0,
    "expected empty graph on nim-version mismatch, got " & $g2.entries.len & " entries"

  # The replacement graph is stamped with the REQUESTED versions, never the
  # stored ones -- this is what makes `header.X == X` an invariant for every
  # downstream reader of the returned graph (planner.decideCompile among them).
  doAssert g2.header.nimVersion == "2.4.0",
    "replacement header kept the STORED nim version: " & g2.header.nimVersion
  doAssert g2.header.ccVersion == "cc-OLD",
    "replacement header lost the requested cc version: " & g2.header.ccVersion

block test_cc_version_mismatch_reason_and_stamp:
  let root = getTempDir() / "crisol_depgraph_ccver_reason"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10", "cc-OLD")
  updateEntry(g, "tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"))
  doAssert saveDepGraph(g, cfg)

  # Same nim version, DIFFERENT cc version: the cc-only change that W3 exists
  # for, and the one an unchanged `nimVersion` used to hide entirely.
  var discarded = DepGraphDiscard(kind: dgdNone)
  let g2 = loadDepGraph(cfg, "2.2.10", discarded, "cc-NEW")

  doAssert discarded.kind == dgdCcVersion,
    "cc-version mismatch must be reported as dgdCcVersion, got " & $discarded.kind
  doAssert discarded.stored == "cc-OLD",
    "discard provenance lost the STORED cc version: " & discarded.stored
  doAssert discarded.current == "cc-NEW",
    "discard provenance lost the CURRENT cc version: " & discarded.current
  doAssert g2.entries.len == 0,
    "expected empty graph on cc-version mismatch, got " & $g2.entries.len & " entries"
  doAssert g2.header.ccVersion == "cc-NEW",
    "replacement header kept the STORED cc version: " & g2.header.ccVersion
  doAssert g2.header.nimVersion == "2.2.10",
    "replacement header lost the requested nim version: " & g2.header.nimVersion

block test_both_versions_changed_reported_as_nim:
  ## A simultaneous nim+cc move is ONE discard, reported as dgdNimVersion:
  ## nimVersion is the higher-priority signal, and the cc arm is only reached
  ## once the nim arm has passed. Asserted so the priority is a test, not just
  ## a sentence in `loadDepGraph`'s doc.
  let root = getTempDir() / "crisol_depgraph_bothver"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  var g = initDepGraph("2.2.10", "cc-OLD")
  updateEntry(g, "tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"))
  doAssert saveDepGraph(g, cfg)

  var discarded = DepGraphDiscard(kind: dgdNone)
  let g2 = loadDepGraph(cfg, "2.4.0", discarded, "cc-NEW")

  doAssert discarded.kind == dgdNimVersion,
    "a simultaneous nim+cc move must report dgdNimVersion, got " & $discarded.kind
  doAssert g2.entries.len == 0, "expected empty graph when both versions moved"
  doAssert g2.header.nimVersion == "2.4.0" and g2.header.ccVersion == "cc-NEW",
    "replacement header not stamped with BOTH requested versions: " &
    g2.header.nimVersion & " / " & g2.header.ccVersion

block test_success_path_restamps_header_to_live_versions:
  ## The invariant `planner.decideCompile` relies on (R3-8): on the NON-discard
  ## path the loader still overwrites the header with the requested versions, so
  ## no caller downstream of `loadDepGraph` can ever observe a header that
  ## disagrees with the live toolchain.
  ##
  ## An inert `""`/`""` header with zero entries is the one shape that reaches
  ## the success path while differing from the requested values: it is
  ## indistinguishable from "no file", so the observability guards leave it
  ## dgdNone (see `loadDepGraph`'s doc) -- which makes it the only way to watch
  ## the re-stamp actually happen rather than coincide with the stored values.
  let root = getTempDir() / "crisol_depgraph_restamp"
  createDir(root)
  defer: removeDir(root)
  ensureStateDirExists(root)

  let cfg = makeTmpConfig(root)
  doAssert saveDepGraph(initDepGraph("", ""), cfg)

  var discarded = DepGraphDiscard(kind: dgdNone)
  let g2 = loadDepGraph(cfg, "2.2.10", discarded, "cc-NEW")

  doAssert discarded.kind == dgdNone,
    "an inert empty header must not be reported as a discard, got " & $discarded.kind
  doAssert g2.header.nimVersion == "2.2.10",
    "success path did not re-stamp header.nimVersion: " & g2.header.nimVersion
  doAssert g2.header.ccVersion == "cc-NEW",
    "success path did not re-stamp header.ccVersion: " & g2.header.ccVersion

echo "test_depgraph: toolchain-staleness gate (R3-8 moved coverage)"

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
  assert isEntryStale(g, key, root, tpSetRoots),
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
  assert not isEntryStale(g, key, root, tpSetRoots),
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
  if not symlinksAvailable():
    # RFC-0009 S5 wiring audit: per-block `break` (the file keeps running
    # after it) -- must NOT emit the whole-file CRISOL-SKIP marker; emits
    # the distinct per-test CRISOL-SKIP-TEST marker instead (see
    # ci/assert-subset-honesty.sh's windows symlink-skip manifest).
    echo "CRISOL-SKIP-TEST: tests/unit/test_depgraph.nim#test_saveDepGraph_symlink_write_through_protection"
    echo "SKIP: symlinks unavailable"
    break
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
  let tmpPath    = finalPath & "." & $getCurrentProcessId() & ".tmp"

  # Plant a sentinel and a symlink at the .tmp location.
  let sentinel = root / "sentinel_must_not_be_overwritten.txt"
  writeFile(sentinel, "ORIGINAL")
  createSymlink(sentinel, tmpPath)

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
  ## DepGraphFormatVersion is 9 as of W3 (wiring-audit finding, re-verified
  ## 2026-09-21): the header gains `ccVersion` -- the depgraph-header sibling
  ## of `nimVersion` -- so `loadDepGraph` can finally see a C toolchain change
  ## and discard a cc-mismatched graph (`dgdCcVersion`). W3 also wired it into
  ## `decideCompile`, previously blind to cc; R3-8 (round 5) later deleted both
  ## of `decideCompile`'s staleness arms, so `loadDepGraph`'s discard is now
  ## the only toolchain gate. See DepGraphFormatVersion's own
  ## History doc (depgraph.nim) for why the bump is taken (discard, not
  ## silent misparse) even though `ccVersion` is parsed leniently (absent ->
  ## "", mirroring `roots`' v6 precedent).
  ##
  ## DepGraphFormatVersion was 8 as of RFC-0009 F13 (wiring-audit finding):
  ## `entry.externals[].source`/`.headers` are now serialized in the SAME
  ## portable `paths.keyBytes` spelling `entry.closure` members already use
  ## (`dep:<name>/<rel>` for a dep-root source/header) instead of a
  ## dep-root member spelling its absolute native path. A v7 (or older)
  ## graph's dep-root externals are exactly those absolute-native spellings
  ## and cannot be re-attributed to their portable form after the fact
  ## (an absolute path no longer round-trips through `fromKeyBytes`), so it
  ## is discarded once.
  ## (v7, RFC-0009 W1: each closure member is now serialized in its
  ## `paths.keyBytes` spelling (`dep:<name>/<rel>` for a dep-root member)
  ## instead of a bare `display(tp)` rel, so a dep-root member round-trips
  ## back to its OWN root tag on load instead of being re-tagged as a
  ## phantom tag-0 project path; the header's per-root `tag` column is
  ## dropped (nothing read it back). A v6 (or older) graph's dep-root
  ## closure members are exactly those phantom tag-0 spellings and cannot
  ## be re-attributed to their real root after the fact, so it was
  ## discarded once.
  ## v6, RFC-0009 A3c-i: the header gained a `roots` descriptor — this
  ## file's own local name->foldPolicy table — so a graph persisted under
  ## one root layout / fold policy is never silently reused under another.
  ## v5, issue #16: a {.compile.}d external's #include'd headers became
  ## tracked compile inputs recorded per-external in `externals`.)
  ## Bump this pin only together with a History entry in depgraph.nim and a
  ## CHANGELOG "BREAKING CHANGE — dependency graph format N" section.
  assert DepGraphFormatVersion == 9,
    "DepGraphFormatVersion pin: expected 9 (W3), got " & $DepGraphFormatVersion

  # A v4 graph on disk is treated as absent (discarded, not migrated).
  let root = getTempDir() / ("crisol_depgraph_v4pin_" & $getCurrentProcessId())
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
  let root5 = getTempDir() / ("crisol_depgraph_v5pin_" & $getCurrentProcessId())
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

# ---------------------------------------------------------------------------
# Test: RFC-0009 W1 — a dep-root closure member survives save/load round trip
# ---------------------------------------------------------------------------

block test_deproot_closure_member_round_trip:
  ## A dep-root closure member must round-trip back to its OWN root tag —
  ## never a phantom tag-0 project path (the pre-W1 defect: the read side
  ## used `classify(s, roots)`, whose project-first relative join re-tags
  ## every persisted member as project-relative) — and its persisted JSON
  ## spelling must be the documented `dep:<name>/rel` (paths.keyBytes),
  ## never a bare rel.
  let base      = getTempDir() / ("crisol_depgraph_deproot_rt_" & $getCurrentProcessId())
  let root      = base / "proj"
  let depNative = base / "dep_real"
  removeDir(base)
  createDir(root)
  createDir(depNative / "src")
  defer: removeDir(base)
  ensureStateDirExists(root)

  var cfg = makeTmpConfig(root)
  cfg.trackedRoots = initTrackedRoots(root, @[("mydep", depNative)], ".crisol",
                                      fixedProbe(fpNone))

  let depClass = classify(depNative / "src" / "foo.nim", cfg.trackedRoots)
  doAssert depClass.kind == pcTracked, "dep file failed to classify"
  doAssert not depClass.tp.isProject, "dep file must classify under the dep root"
  let epClass = classify(root / "tests" / "t.nim", cfg.trackedRoots)
  doAssert epClass.kind == pcTracked, "entrypoint file failed to classify"

  var closure = initHashSet[TrackedPath]()
  closure.incl depClass.tp
  closure.incl epClass.tp   # NONEMPTY-CLOSURE: a real closure always also
                            # contains the entrypoint itself.
  let fh = flagHash(@[])
  var g = initDepGraph("2.2.10")
  updateEntry(g, "tests/t.nim", fh, closure, "h", 1)

  doAssert saveDepGraph(g, cfg)

  # On-disk wire spelling: `dep:mydep/src/foo.nim`, never a bare rel.
  let doc = parseJson(readFile(depgraphPath(cfg)))
  var sawDepSpelling = false
  for entryNode in doc["entries"]:
    for c in entryNode["closure"]:
      let s = c.getStr()
      if s == "dep:mydep/src/foo.nim": sawDepSpelling = true
      doAssert s != "src/foo.nim",
        "dep-root member persisted as a bare rel (phantom tag-0 spelling): " & s
  doAssert sawDepSpelling,
    "dep-root member missing its dep:<name>/rel wire spelling on disk"

  let g2 = loadDepGraph(cfg, "2.2.10")
  let key = ("tests/t.nim", fh)
  doAssert key in g2.entries, "entry missing after round trip"
  let loadedClosure = g2.entries[key].closure
  doAssert depClass.tp in loadedClosure,
    "dep-root member did not round-trip back to its OWN tag"
  for tp in loadedClosure:
    if tp.display() == "src/foo.nim":
      doAssert not tp.isProject,
        "dep-root member came back as a phantom tag-0 project path"

# -----------------------------------------------------------------------------
# Code review 2026-09-21: the dgdCcVersion discard message must name BOTH halves
#
# W3 added the cc-toolchain discard arm and rendered it with
# `sanitizeHeaderField(pipeAware = true)`, whose doc asserted that rule was
# "a harmless no-op truncation" for a cc fingerprint. It is not. That rule
# splits on the FINAL '|' and keeps only the last 12 characters after it --
# correct for the Nim fingerprint, whose tail really is a bare binary hash,
# and destructive for ccVersion, whose tail is the RUNTIME IDENTITY.
#
# Observed before the fix, in test_zero_runnable.nim's own output:
#   current toolchain is cc (SUSE Linux) 16.2.0 #b0dd4cd034d13600|390a4be6deb6
# The entire `ldd (GNU libc) 2.43 #542b` half erased -- on the one message
# whose job is to say WHICH half of the toolchain moved. A glibc rebuild at an
# unchanged version string (exactly what issue #23 exists to catch) would have
# reported twelve anonymous hex digits and nothing else.
# -----------------------------------------------------------------------------
block ccVersionDiscardMessageNamesBothHalves:
  const
    ccText = "cc (SUSE Linux) 16.2.0"
    rtOld  = "ldd (GNU libc) 2.37"
    rtNew  = "ldd (GNU libc) 2.43"
    stored  = ccText & " #aaaaaaaaaaaaaaaa|" & rtOld & " #1111111111111111"
    current = ccText & " #aaaaaaaaaaaaaaaa|" & rtNew & " #542b390a4be6deb6"
  let m = DepGraphDiscard(kind: dgdCcVersion, stored: stored,
                          current: current).message()

  # Both halves of BOTH fingerprints keep their legible text. This is the
  # assertion the old rendering failed.
  doAssert rtOld in m, "stored runtime half erased from the message: " & m
  doAssert rtNew in m, "current runtime half erased from the message: " & m
  doAssert ccText in m, "compiler half erased from the message: " & m

  # The half that actually moved is distinguishable from the half that did not.
  doAssert m.count(rtOld) == 1 and m.count(rtNew) == 1,
    "the runtime change is not legible in the message: " & m

  # Digests are abbreviated, not dropped -- enough to separate two builds at an
  # identical version string, which is the case the digest was added for.
  doAssert "390a4be6deb6" in m, "current runtime digest missing: " & m
  doAssert "542b390a4be6deb6" notin m, "digest not abbreviated: " & m

  # Still one line: this text is written raw to stderr.
  doAssert m.find(char(10)) < 0, "discard message is multi-line: " & m

  # A Windows-shaped value (compiler half carries NO digest -- cdVersionOnly by
  # decision) must render both halves just the same.
  let win = DepGraphDiscard(
    kind: dgdCcVersion,
    stored:  "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64|" &
             "kernel32+libcmt+libucrt #0d8cab78a8b5d998",
    current: "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64|" &
             "kernel32+libcmt+libucrt #ffffffffffffffff").message()
  doAssert "kernel32+libcmt+libucrt" in win,
    "windows runtime half erased from the message: " & win

echo "test_depgraph: dgdCcVersion message names both halves"
