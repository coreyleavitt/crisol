## test_fallback.nim — TDD tests for D4: conservative fallback taxonomy.
##
## Tests the `selectByDiff` detailed selector and the `fallbackNotes` helper.
## All reason-taxonomy rules are exercised; D3's `narrowByDiff` green tests
## are kept in test_narrow.nim (which still passes unchanged).
##
## Coverage:
##   graph_absent_all     — empty graph → ALL eps included with srGraphAbsent.
##   own_file_beats_miss  — ep.path in changed → srOwnFileChanged even when
##                          its known closure does NOT intersect changed.
##   own_file_beats_stale — ep.path in changed AND entry is stale → srOwnFileChanged
##                          (own-file rule has higher priority than stale rule).
##   unknown_closure      — graph non-empty, no entry for this key → srUnknownClosure.
##   stale_entry          — closure references a now-missing file → srStaleEntry
##                          even when changed is disjoint.
##   known_hit            — known fresh closure ∩ changed ≠ ∅ → srClosureHit.
##   known_miss_excluded  — known fresh closure ∩ changed = ∅ → excluded (sole exclusion).
##   priority_own_vs_stale — ep is both own-file-changed AND stale → srOwnFileChanged.
##   summary_graph_absent — fallbackNotes yields "dep graph absent — full run".
##   summary_mixed        — fallbackNotes reports conservative-inclusion count.
##   order_preserved      — input order preserved in output.

import std/[os, sets, strutils, tempfiles]
import crisol/types
import crisol/depgraph
import crisol/narrow
import "../support/rfc9_narrow_support"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ep(path: string; flags: seq[string] = @[]): Entrypoint =
  Entrypoint(path: path, group: "default", flags: flags)

proc emptyGraph(nimVer = "2.2.10"): DepGraph =
  initDepGraph(nimVer)

proc toSet(paths: varargs[string]): HashSet[string] =
  result = initHashSet[string]()
  for p in paths:
    result.incl p

proc reasonsOf(results: seq[SelectionResult]): seq[SelectionReason] =
  for r in results: result.add r.reason

proc pathsOf(results: seq[SelectionResult]): seq[string] =
  for r in results: result.add r.ep.path

# roots for the TrackedPath-typed `changed` parameter (RFC-0009 A3b-ii).
# Most blocks below pass projectRoot == "" to selectByDiff (as before this
# migration) and only ever put project-root-RELATIVE strings in `changed` —
# `fromCanonical` never touches the filesystem or `roots.project.abs`, so a
# bogus/empty root is safe here (see rfc9_narrow_support.nim's doc comment).
let roots = mkRoots("")

# ---------------------------------------------------------------------------
# Graph absent → ALL eps included with srGraphAbsent
# ---------------------------------------------------------------------------

block test_graph_absent_all:
  let g = emptyGraph()
  let e1 = ep("tests/unit/test_a.nim")
  let e2 = ep("tests/unit/test_b.nim")
  let changed = changedTp(roots)  # even empty changed
  let result = selectByDiff(@[e1, e2], changed, g, roots, "")
  assert result.len == 2, "graph absent: expected both eps selected, got " & $result.len
  for item in result:
    assert item.reason == srGraphAbsent,
      "graph absent: expected srGraphAbsent, got " & $item.reason

block test_graph_absent_nonempty_changed:
  let g = emptyGraph()
  let e = ep("tests/unit/test_c.nim")
  let changed = changedTp(roots, "src/crisol/something.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1
  assert result[0].reason == srGraphAbsent

# ---------------------------------------------------------------------------
# Own-file-changed → srOwnFileChanged even when closure does NOT intersect changed
# ---------------------------------------------------------------------------

block test_own_file_beats_miss:
  # ep has a known closure that does NOT contain any changed file —
  # but ep.path itself is in changed.  Should still include with srOwnFileChanged.
  # The own-file rule fires at priority 2, before staleness is even checked.
  # We use a non-existent dep in the closure to also verify that even if the
  # closure is stale (missing file), own-file rule still fires first.
  var g = emptyGraph()
  let e = ep("tests/unit/test_self.nim")
  # Closure has a non-existent file; would be stale if we got that far.
  let tmpDir = getTempDir()
  let nonExistent = tmpDir / "crisol_d4_self_unrel_" & $getCurrentProcessId() & ".nim"
  g.updateEntry(e.path, flagHash(e.flags), toSet(nonExistent))
  # changed only contains ep.path — the own-file rule fires (priority 2).
  let changed = changedTp(roots, "tests/unit/test_self.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1, "own-file-changed must be included even on closure miss"
  assert result[0].reason == srOwnFileChanged,
    "expected srOwnFileChanged, got " & $result[0].reason

# ---------------------------------------------------------------------------
# Own-file-changed beats stale (priority rule)
# ---------------------------------------------------------------------------

block test_own_file_beats_stale:
  # ep.path is in changed AND the entry is stale (closure has a missing file).
  # Priority: srOwnFileChanged comes before srStaleEntry.
  let tmpDir = getTempDir()
  let missingFile = tmpDir / "crisol_d4_test_missing_" & $getCurrentProcessId() & ".nim"
  # Do NOT create missingFile — it must not exist.

  var g = emptyGraph()
  let e = ep("tests/unit/test_priority.nim")
  # Closure includes a file that does not exist → isEntryStale would return true.
  g.updateEntry(e.path, flagHash(e.flags), toSet(missingFile))
  # ep.path is also in changed → own-file rule fires first.
  let changed = changedTp(roots, "tests/unit/test_priority.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1
  assert result[0].reason == srOwnFileChanged,
    "own-file must beat stale; got " & $result[0].reason

# ---------------------------------------------------------------------------
# Unknown closure → srUnknownClosure (graph non-empty, key absent)
# ---------------------------------------------------------------------------

block test_unknown_closure:
  # Graph has entries for OTHER eps but NOT for this ep's key.
  var g = emptyGraph()
  let eOther = ep("tests/unit/test_other.nim")
  g.updateEntry(eOther.path, flagHash(eOther.flags), toSet("src/crisol/other.nim"))
  let e = ep("tests/unit/test_unknown.nim")
  let changed = changedTp(roots)
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1,
    "unknown-closure ep must be included even with empty changed"
  assert result[0].reason == srUnknownClosure,
    "expected srUnknownClosure, got " & $result[0].reason

block test_unknown_closure_nonempty_changed:
  var g = emptyGraph()
  let eOther2 = ep("tests/unit/test_other2.nim")
  g.updateEntry(eOther2.path, flagHash(eOther2.flags), toSet("src/crisol/x.nim"))
  let e = ep("tests/unit/test_unknown2.nim")
  let changed = changedTp(roots, "src/crisol/something_else.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1
  assert result[0].reason == srUnknownClosure

# ---------------------------------------------------------------------------
# Stale entry → srStaleEntry (closure references a now-missing file)
# ---------------------------------------------------------------------------

block test_stale_entry:
  # Create a real temp file, populate a closure with it, then delete it.
  # isEntryStale will detect the missing file and return true.
  let tmpDir = getTempDir()
  let tmpFile = tmpDir / "crisol_d4_stale_" & $getCurrentProcessId() & ".nim"
  writeFile(tmpFile, "# temp\n")

  var g = emptyGraph()
  let e = ep("tests/unit/test_stale.nim")
  # Closure references the temp file (which exists right now).
  g.updateEntry(e.path, flagHash(e.flags), toSet(tmpFile))

  # Now delete the file to simulate a missing closure dependency.
  removeFile(tmpFile)

  # changed is disjoint — would be a miss if fresh — but entry is stale.
  let changed = changedTp(roots, "src/crisol/unrelated.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1,
    "stale entry must be included even when changed is disjoint"
  assert result[0].reason == srStaleEntry,
    "expected srStaleEntry, got " & $result[0].reason

# ---------------------------------------------------------------------------
# Known hit → srClosureHit
# ---------------------------------------------------------------------------

block test_known_hit:
  # Closure files must exist on disk so isEntryStale does not fire.
  # RFC-0009 A3b-ii: closure/changed members must be reducible to
  # TrackedPath, so the temp dir itself is the "project root" here and the
  # closure carries names RELATIVE to it (fromCanonical rejects absolute
  # input) -- same isolation/uniqueness guarantee as before, just addressed
  # relative to tmpDir instead of as bare absolute strings.
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
  g.updateEntry(e.path, flagHash(e.flags), toSet(tmpAName, tmpBName))
  # changed contains one of the closure files → hit.
  let changed = changedTp(tmpRoots, tmpBName)
  let result = selectByDiff(@[e], changed, g, tmpRoots, tmpDir)
  assert result.len == 1, "expected 1 hit, got " & $result.len
  assert result[0].reason == srClosureHit,
    "expected srClosureHit, got " & $result[0].reason

# ---------------------------------------------------------------------------
# Known miss → EXCLUDED (the sole exclusion path)
# ---------------------------------------------------------------------------

block test_known_miss_excluded:
  # Closure files must exist on disk so isEntryStale does not fire.
  # See test_known_hit: tmpDir is the "project root" so the closure/changed
  # members reduce to TrackedPath (fromCanonical rejects absolute input).
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
  g.updateEntry(e.path, flagHash(e.flags), toSet(tmpCName, tmpDName))
  # changed does NOT contain any closure file → miss → excluded.
  let changed = changedTp(tmpRoots, "crisol_d4_unrelated.nim")
  let result = selectByDiff(@[e], changed, g, tmpRoots, tmpDir)
  assert result.len == 0,
    "known-fresh closure miss must be excluded; got " & $result.len

# ---------------------------------------------------------------------------
# Priority documented: own-file > stale (already tested above in own_file_beats_stale)
# Confirm via the reasons list when both conditions could apply.
# ---------------------------------------------------------------------------

block test_priority_own_file_vs_stale:
  let tmpDir = getTempDir()
  let missingFile2 = tmpDir / "crisol_d4_prio_" & $getCurrentProcessId() & ".nim"
  # missingFile2 does NOT exist — closure will be stale.

  var g = emptyGraph()
  let e = ep("tests/unit/test_prio.nim")
  g.updateEntry(e.path, flagHash(e.flags), toSet(missingFile2))
  # Both conditions: own-file in changed AND entry is stale.
  let changed = changedTp(roots, "tests/unit/test_prio.nim")
  let result = selectByDiff(@[e], changed, g, roots, "")
  assert result.len == 1
  # Own-file rule (priority 2) fires before stale rule (priority 4).
  assert result[0].reason == srOwnFileChanged,
    "priority: own-file must beat stale; got " & $result[0].reason

# ---------------------------------------------------------------------------
# Summary message: graph-absent run → "dep graph absent — full run"
# ---------------------------------------------------------------------------

block test_summary_graph_absent:
  let g = emptyGraph()
  let e1 = ep("tests/unit/test_sa.nim")
  let e2 = ep("tests/unit/test_sb.nim")
  let detailed = selectByDiff(@[e1, e2], changedTp(roots), g, roots, "")
  let msg = fallbackNotes(detailed, 2)
  assert "dep graph absent — full run" in msg,
    "expected 'dep graph absent — full run' in msg, got: " & msg

# ---------------------------------------------------------------------------
# Summary message: mixed run → reports conservative-inclusion count
# ---------------------------------------------------------------------------

block test_summary_mixed:
  # One ep with a known closure hit, one unknown closure, one stale.
  # See test_known_hit: tmpDir is the "project root" so the closure/changed
  # members reduce to TrackedPath (fromCanonical rejects absolute input).
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  # Real existing file for eHit's closure (so it's fresh, not stale).
  let hitDepName = "crisol_d4_mix_hit_" & pid & ".nim"
  writeFile(tmpDir / hitDepName, "# hit dep\n")
  # Non-existing file for eStale's closure.
  let missingFile3Name = "crisol_d4_mix_miss_" & pid & ".nim"
  defer:
    try: removeFile(tmpDir / hitDepName) except: discard

  var g = emptyGraph()
  let eHit     = ep("tests/unit/test_mhit.nim")
  let eUnknown = ep("tests/unit/test_munk.nim")
  let eStale   = ep("tests/unit/test_mstale.nim")

  # eHit: known fresh closure (existing file) that intersects changed.
  g.updateEntry(eHit.path, flagHash(eHit.flags), toSet(hitDepName))
  # eUnknown: no entry → unknown closure.
  # eStale: entry with a missing file → stale.
  g.updateEntry(eStale.path, flagHash(eStale.flags), toSet(missingFile3Name))

  let changed = changedTp(tmpRoots, hitDepName)
  let detailed = selectByDiff(@[eHit, eUnknown, eStale], changed, g, tmpRoots, tmpDir)

  # Verify reasons.
  let reasons = reasonsOf(detailed)
  assert srClosureHit    in reasons, "expected srClosureHit in mixed run"
  assert srUnknownClosure in reasons, "expected srUnknownClosure in mixed run"
  assert srStaleEntry    in reasons, "expected srStaleEntry in mixed run"

  let msg = fallbackNotes(detailed, 3)
  # 2 force-included (unknown + stale).
  assert "2 entrypoint(s) force-included" in msg,
    "expected '2 entrypoint(s) force-included' in msg, got: " & msg

# ---------------------------------------------------------------------------
# Input order preserved
# ---------------------------------------------------------------------------

block test_order_preserved:
  # All closure files must exist for fresh (non-stale) entries.
  # See test_known_hit: tmpDir is the "project root" so the closure/changed
  # members reduce to TrackedPath (fromCanonical rejects absolute input).
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
  g.updateEntry(e1.path, flagHash(e1.flags), toSet(dep1Name))
  g.updateEntry(e2.path, flagHash(e2.flags), toSet(dep2Name))
  g.updateEntry(e3.path, flagHash(e3.flags), toSet(dep3Name))
  let changed = changedTp(tmpRoots, dep1Name, dep3Name)
  let result = selectByDiff(@[e1, e2, e3], changed, g, tmpRoots, tmpDir)
  assert result.len == 2, "expected 2 hits (e1, e3), got " & $result.len
  assert result[0].ep.path == e1.path, "first must be e1"
  assert result[1].ep.path == e3.path, "second must be e3"

# ---------------------------------------------------------------------------
# narrowByDiff delegates to selectByDiff (RFC pipeline API still works)
# ---------------------------------------------------------------------------

block test_narrowByDiff_delegates:
  # Closure files must exist so fresh entries are not tagged stale.
  # See test_known_hit: tmpDir is the "project root" so the closure/changed
  # members reduce to TrackedPath (fromCanonical rejects absolute input).
  let tmpDir = getTempDir()
  let tmpRoots = mkRoots(tmpDir)
  let pid = $getCurrentProcessId()
  let ndDepName   = "crisol_d4_nd_dep_"   & pid & ".nim"
  let ndOtherName = "crisol_d4_nd_other_" & pid & ".nim"
  writeFile(tmpDir / ndDepName,   "# nd dep\n")
  writeFile(tmpDir / ndOtherName, "# nd other\n")
  defer:
    try: removeFile(tmpDir / ndDepName)   except: discard
    try: removeFile(tmpDir / ndOtherName) except: discard

  var g = emptyGraph()
  let eHit  = ep("tests/unit/test_nd_hit.nim")
  let eMiss = ep("tests/unit/test_nd_miss.nim")
  let eUnk  = ep("tests/unit/test_nd_unk.nim")
  g.updateEntry(eHit.path,  flagHash(eHit.flags),  toSet(ndDepName))
  g.updateEntry(eMiss.path, flagHash(eMiss.flags), toSet(ndOtherName))
  # eUnk has no entry.
  let changed = changedTp(tmpRoots, ndDepName)
  let result = narrowByDiff(@[eHit, eMiss, eUnk], changed, g, tmpRoots, tmpDir)
  assert result.len == 2,
    "narrowByDiff: expected hit + unknown, got " & $result.len
  assert result[0].path == eHit.path
  assert result[1].path == eUnk.path

echo "PASS test_fallback"
