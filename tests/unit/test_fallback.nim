## test_fallback.nim — TDD tests for D4: the conservative fallback rules.
##
## Every rule of `narrowByDiff` that includes an entrypoint without a
## closure hit is exercised, each set up so that no other rule could
## include it; D3's closure-hit tests are in test_narrow.nim.
##
## Coverage:
##   graph_absent_all     — empty graph → ALL eps included.
##   own_file_beats_miss  — ep.path in changed → included even when its known,
##                          fresh closure does NOT intersect changed.
##   own_file_and_stale   — ep.path in changed AND entry is stale → included.
##   unknown_closure      — graph non-empty, no entry for this key → included.
##   stale_entry          — closure references a now-missing file → included
##                          even when changed is disjoint.
##   known_hit            — known fresh closure ∩ changed ≠ ∅ → included.
##   known_miss_excluded  — known fresh closure ∩ changed = ∅ → excluded (sole exclusion).
##   mixed                — hit, unknown and stale included; a miss is not.
##   order_preserved      — input order preserved in output.

import std/[options, os, sets, tables]
import crisol/types
import crisol/depgraph
import crisol/narrow
import "../support/rfc9_narrow_support"
import "../support/testep"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ep(path: string; flags: seq[string] = @[]): Entrypoint =
  testEp(path, group = "default", flags = flags)

proc emptyGraph(nimVer = "2.2.10"): DepGraph =
  initDepGraph(nimVer)

proc toSet(roots: TrackedRoots; paths: varargs[string]): HashSet[TrackedPath] =
  ## RFC-0009 A3c-ii: `DepGraphEntry.closure` is now `HashSet[TrackedPath]`.
  ## Uses `classify` (not `fromCanonical`/`closureTp`) because this file's
  ## closures mix relative bare filenames (real `tmpRoots`/`tmpDir` blocks)
  ## and absolute synthetic paths (vacuous-`roots` blocks) -- `classify`
  ## handles both uniformly; `fromCanonical` would reject the absolute ones.
  result = initHashSet[TrackedPath]()
  for p in paths:
    let pc = classify(p, roots)
    doAssert pc.kind == pcTracked, "test path failed to classify: " & p
    result.incl pc.tp

proc pathsOf(eps: seq[Entrypoint]): seq[string] =
  for e in eps: result.add string(e.tp.display())

# roots for the TrackedPath-typed `changed` parameter (RFC-0009 A3b-ii).
# Most blocks below use a bogus project root and only ever put
# project-root-RELATIVE strings in `changed` —
# `fromCanonical` never touches the filesystem or `roots.project.abs`, so a
# bogus/empty root is safe here (see rfc9_narrow_support.nim's doc comment).
let roots = mkRoots("")

# ---------------------------------------------------------------------------
# Graph absent → ALL eps included
# ---------------------------------------------------------------------------

block test_graph_absent_all:
  let g = emptyGraph()
  let e1 = ep("tests/unit/test_a.nim")
  let e2 = ep("tests/unit/test_b.nim")
  let changed = changedTp(roots)  # even empty changed
  let result = narrowByDiff(@[e1, e2], changed, g, roots)
  assert pathsOf(result) == @["tests/unit/test_a.nim", "tests/unit/test_b.nim"],
    "graph absent: expected both eps selected, got " & $pathsOf(result)

block test_graph_absent_nonempty_changed:
  let g = emptyGraph()
  let e = ep("tests/unit/test_c.nim")
  let changed = changedTp(roots, "src/crisol/something.nim")
  let result = narrowByDiff(@[e], changed, g, roots)
  assert result.len == 1

# ---------------------------------------------------------------------------
# Own file changed → included even when the fresh closure does NOT intersect
# ---------------------------------------------------------------------------

block test_own_file_beats_miss:
  # ep has a known, FRESH closure (its member exists) that does not contain
  # any changed file, so rules 3-5 would all exclude it: only ep.path being
  # in changed (rule 2) can include it.
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let depName = "crisol_d4_self_dep_" & $getCurrentProcessId() & ".nim"
  writeFile(tmpDir / depName, "# dep\n")
  defer:
    try: removeFile(tmpDir / depName) except: discard
  var g = emptyGraph()
  let e = ep("tests/unit/test_self.nim")
  g.updateEntry(string(e.tp.display()), flagHash(e.flags), toSet(tmpRoots, depName), @[])
  let control = narrowByDiff(@[e], changedTp(tmpRoots, "crisol_d4_other.nim"),
                             g, tmpRoots)
  assert control.len == 0, "CONTROL: a fresh closure miss must be excluded"
  let changed = changedTp(tmpRoots, "tests/unit/test_self.nim")
  let result = narrowByDiff(@[e], changed, g, tmpRoots)
  assert result.len == 1, "own-file-changed must be included even on closure miss"

# ---------------------------------------------------------------------------
# Own file changed and stale → included
# ---------------------------------------------------------------------------

block test_own_file_and_stale:
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let missingFile = tmpDir / "crisol_d4_test_missing_" & $getCurrentProcessId() & ".nim"
  # Do NOT create missingFile — it must not exist.
  var g = emptyGraph()
  let e = ep("tests/unit/test_priority.nim")
  # RFC-0009 B4a: missingFile is a real absolute OS path; anchor at tmpDir.
  g.updateEntry(string(e.tp.display()), flagHash(e.flags), toSet(tmpRoots, missingFile), @[])
  let changed = changedTp(tmpRoots, "tests/unit/test_priority.nim")
  let result = narrowByDiff(@[e], changed, g, tmpRoots)
  assert result.len == 1

# ---------------------------------------------------------------------------
# Unknown closure → included (graph non-empty, key absent)
# ---------------------------------------------------------------------------

block test_unknown_closure:
  # Graph has entries for OTHER eps but NOT for this ep's key.
  var g = emptyGraph()
  let eOther = ep("tests/unit/test_other.nim")
  g.updateEntry(string(eOther.tp.display()), flagHash(eOther.flags), toSet(roots, "src/crisol/other.nim"), @[])
  let e = ep("tests/unit/test_unknown.nim")
  let changed = changedTp(roots)
  let result = narrowByDiff(@[e], changed, g, roots)
  assert result.len == 1,
    "unknown-closure ep must be included even with empty changed"

block test_unknown_closure_nonempty_changed:
  var g = emptyGraph()
  let eOther2 = ep("tests/unit/test_other2.nim")
  g.updateEntry(string(eOther2.tp.display()), flagHash(eOther2.flags), toSet(roots, "src/crisol/x.nim"), @[])
  let e = ep("tests/unit/test_unknown2.nim")
  let changed = changedTp(roots, "src/crisol/something_else.nim")
  let result = narrowByDiff(@[e], changed, g, roots)
  assert result.len == 1

# ---------------------------------------------------------------------------
# Stale entry → included (closure references a now-missing file)
# ---------------------------------------------------------------------------

block test_stale_entry:
  # Create a real temp file, populate a closure with it, then delete it.
  # isEntryStale will detect the missing file and return true.
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let tmpFile = tmpDir / "crisol_d4_stale_" & $getCurrentProcessId() & ".nim"
  writeFile(tmpFile, "# temp\n")

  var g = emptyGraph()
  let e = ep("tests/unit/test_stale.nim")
  # RFC-0009 B4a: tmpFile is a real absolute OS path; anchor at tmpDir so
  # isEntryStale's toNative(roots) round-trips it to the real path.
  g.updateEntry(string(e.tp.display()), flagHash(e.flags), toSet(tmpRoots, tmpFile), @[])
  # changed is disjoint — a miss while the entry is fresh.
  let changed = changedTp(tmpRoots, "src/crisol/unrelated.nim")
  assert narrowByDiff(@[e], changed, g, tmpRoots).len == 0,
    "CONTROL: a fresh closure miss must be excluded"

  # Now delete the file to simulate a missing closure dependency.
  removeFile(tmpFile)
  let result = narrowByDiff(@[e], changed, g, tmpRoots)
  assert result.len == 1,
    "stale entry must be included even when changed is disjoint"

# ---------------------------------------------------------------------------
# Known hit → included
# ---------------------------------------------------------------------------

block test_known_hit:
  # Closure files must exist on disk so isEntryStale does not fire.
  # RFC-0009 A3b-ii: closure/changed members must be reducible to
  # TrackedPath, so the temp dir itself is the "project root" here and the
  # closure carries names RELATIVE to it (fromCanonical rejects absolute
  # input).
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  let tmpAName = "crisol_d4_hit_a_" & pid & ".nim"
  let tmpBName = "crisol_d4_hit_b_" & pid & ".nim"
  writeFile(tmpDir / tmpAName, "# a\n")
  writeFile(tmpDir / tmpBName, "# b\n")
  defer:
    try: removeFile(tmpDir / tmpAName) except: discard
    try: removeFile(tmpDir / tmpBName) except: discard

  var g = emptyGraph()
  let e = ep("tests/unit/test_hit.nim")
  g.updateEntry(string(e.tp.display()), flagHash(e.flags), toSet(tmpRoots, tmpAName, tmpBName), @[])
  # changed contains one of the closure files → hit.
  let changed = changedTp(tmpRoots, tmpBName)
  let result = narrowByDiff(@[e], changed, g, tmpRoots)
  assert result.len == 1, "expected 1 hit, got " & $result.len
  # Rule 5, not a fallback: the entry is known and fresh, and diffReach
  # finds the member.
  let key = entryKey(e.tp, e.flags)
  assert not isEntryStale(g, key, tmpRoots)
  let hit = diffReach(g.entries[key], changed, tmpRoots)
  assert hit.isSome and hit.get.kind == hkMember

# ---------------------------------------------------------------------------
# Known miss → EXCLUDED (the sole exclusion path)
# ---------------------------------------------------------------------------

block test_known_miss_excluded:
  # Closure files must exist on disk so isEntryStale does not fire.
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  let tmpCName = "crisol_d4_miss_c_" & pid & ".nim"
  let tmpDName = "crisol_d4_miss_d_" & pid & ".nim"
  writeFile(tmpDir / tmpCName, "# c\n")
  writeFile(tmpDir / tmpDName, "# d\n")
  defer:
    try: removeFile(tmpDir / tmpCName) except: discard
    try: removeFile(tmpDir / tmpDName) except: discard

  var g = emptyGraph()
  let e = ep("tests/unit/test_miss.nim")
  g.updateEntry(string(e.tp.display()), flagHash(e.flags), toSet(tmpRoots, tmpCName, tmpDName), @[])
  # changed does NOT contain any closure file → miss → excluded.
  let changed = changedTp(tmpRoots, "crisol_d4_unrelated.nim")
  let result = narrowByDiff(@[e], changed, g, tmpRoots)
  assert result.len == 0,
    "known-fresh closure miss must be excluded; got " & $result.len

# ---------------------------------------------------------------------------
# Mixed: a hit, an unknown and a stale entry are included; a miss is not
# ---------------------------------------------------------------------------

block test_mixed:
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  # Real existing files for eHit's and eMiss's closures (so they are fresh).
  let hitDepName = "crisol_d4_mix_hit_" & pid & ".nim"
  let missDepName = "crisol_d4_mix_other_" & pid & ".nim"
  writeFile(tmpDir / hitDepName, "# hit dep\n")
  writeFile(tmpDir / missDepName, "# other dep\n")
  # Non-existing file for eStale's closure.
  let missingFile3Name = "crisol_d4_mix_miss_" & pid & ".nim"
  defer:
    try: removeFile(tmpDir / hitDepName) except: discard
    try: removeFile(tmpDir / missDepName) except: discard

  var g = emptyGraph()
  let eHit     = ep("tests/unit/test_mhit.nim")
  let eUnknown = ep("tests/unit/test_munk.nim")
  let eStale   = ep("tests/unit/test_mstale.nim")
  let eMiss    = ep("tests/unit/test_mmiss.nim")
  g.updateEntry(string(eHit.tp.display()), flagHash(eHit.flags), toSet(tmpRoots, hitDepName), @[])
  # eUnknown: no entry → unknown closure.
  g.updateEntry(string(eStale.tp.display()), flagHash(eStale.flags), toSet(tmpRoots, missingFile3Name), @[])
  g.updateEntry(string(eMiss.tp.display()), flagHash(eMiss.flags), toSet(tmpRoots, missDepName), @[])

  let changed = changedTp(tmpRoots, hitDepName)
  let result = narrowByDiff(@[eHit, eUnknown, eStale, eMiss], changed, g, tmpRoots)
  assert pathsOf(result) == @["tests/unit/test_mhit.nim",
                              "tests/unit/test_munk.nim",
                              "tests/unit/test_mstale.nim"],
    "mixed: got " & $pathsOf(result)

# ---------------------------------------------------------------------------
# Input order preserved
# ---------------------------------------------------------------------------

block test_order_preserved:
  # All closure files must exist for fresh (non-stale) entries.
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  let dep1Name = "crisol_d4_ord_dep1_" & pid & ".nim"
  let dep2Name = "crisol_d4_ord_dep2_" & pid & ".nim"
  let dep3Name = "crisol_d4_ord_dep3_" & pid & ".nim"
  writeFile(tmpDir / dep1Name, "# dep1\n")
  writeFile(tmpDir / dep2Name, "# dep2\n")
  writeFile(tmpDir / dep3Name, "# dep3\n")
  defer:
    try: removeFile(tmpDir / dep1Name) except: discard
    try: removeFile(tmpDir / dep2Name) except: discard
    try: removeFile(tmpDir / dep3Name) except: discard

  var g = emptyGraph()
  let e1 = ep("tests/unit/test_ord1.nim")
  let e2 = ep("tests/unit/test_ord2.nim")
  let e3 = ep("tests/unit/test_ord3.nim")
  # e1: hit, e2: miss (excluded), e3: hit
  g.updateEntry(string(e1.tp.display()), flagHash(e1.flags), toSet(tmpRoots, dep1Name), @[])
  g.updateEntry(string(e2.tp.display()), flagHash(e2.flags), toSet(tmpRoots, dep2Name), @[])
  g.updateEntry(string(e3.tp.display()), flagHash(e3.flags), toSet(tmpRoots, dep3Name), @[])
  let changed = changedTp(tmpRoots, dep1Name, dep3Name)
  let result = narrowByDiff(@[e1, e2, e3], changed, g, tmpRoots)
  assert pathsOf(result) == @["tests/unit/test_ord1.nim", "tests/unit/test_ord3.nim"],
    "expected e1, e3 in order, got " & $pathsOf(result)

echo "PASS test_fallback"
