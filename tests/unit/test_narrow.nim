## test_narrow.nim — TDD tests for D3: narrowByDiff (diff ∩ closure selection).
##
## Tests use synthetic DepGraphs (via initDepGraph/updateEntry) and hand-built
## Entrypoints.  Closure paths that must be "fresh" (not stale) use real
## existing source files from the project (isEntryStale checks fileExists, an
## accepted D2 side effect; see D4).  Closure paths that are intentionally
## absent (stale/unknown-key) are synthetic paths that do not exist on disk.
##
## Coverage:
##   Hit              — ep with known closure that CONTAINS a changed file → selected.
##   Miss             — ep with known closure that does NOT intersect changed → excluded.
##   Multi-ep         — several eps; only intersection-matching ones returned, in order.
##   Shared dep       — two eps depending on same file; both selected when that file changes.
##   Own file changed — ep's own path is in changed and in its closure → selected.
##   Unknown key      — ep with no graph entry → conservatively included even if changed is empty.
##   flagHash keying  — same path, two flag-sets; one has matching closure, other has no entry;
##                      matching one selected by intersection, other by unknown-key rule.
##   Empty changed    — all-known non-intersecting closures → none selected;
##                      unknown-key ep still included.

import std/[os, sets]
import crisol/types
import crisol/depgraph
import crisol/narrow

# Real project-root-relative paths that exist in the workspace.
# isEntryStale checks fileExists on these; using real files keeps entries fresh.
const kNarrow   = "src/crisol/narrow.nim"
const kTypes    = "src/crisol/types.nim"
const kDepgraph = "src/crisol/depgraph.nim"
const kDiscover = "src/crisol/discover.nim"
const kRender   = "src/crisol/render.nim"
const kRunner   = "src/crisol/runner.nim"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ep(path: string; flags: seq[string] = @[]): Entrypoint =
  Entrypoint(path: path, group: "default", flags: flags)

proc mkGraph(nimVer = "2.2.10"): DepGraph =
  initDepGraph(nimVer)

proc toSet(paths: varargs[string]): HashSet[string] =
  result = initHashSet[string]()
  for p in paths:
    result.incl p

# ---------------------------------------------------------------------------
# Hit: ep closure intersects changed → selected
# ---------------------------------------------------------------------------

block test_hit:
  var g = mkGraph()
  let e = ep("tests/unit/test_foo.nim")
  # Use a real existing file as the dep so isEntryStale does not fire.
  let closure = toSet(kNarrow, kTypes)
  g.updateEntry(e.path, flagHash(e.flags), closure)
  let changed = toSet(kTypes)
  let result = narrowByDiff(@[e], changed, g, getCurrentDir())
  assert result.len == 1, "expected 1 selected, got " & $result.len
  assert result[0].path == e.path

# ---------------------------------------------------------------------------
# Miss: ep closure does NOT intersect changed → excluded
# ---------------------------------------------------------------------------

block test_miss:
  var g = mkGraph()
  let e = ep("tests/unit/test_bar.nim")
  # Use real existing files; closure does NOT include the changed file.
  let closure = toSet(kNarrow, kTypes)
  g.updateEntry(e.path, flagHash(e.flags), closure)
  # changed is kDepgraph, which is NOT in the closure → miss.
  let changed = toSet(kDepgraph)
  let result = narrowByDiff(@[e], changed, g, getCurrentDir())
  assert result.len == 0, "expected 0 selected, got " & $result.len

# ---------------------------------------------------------------------------
# Multi-entrypoint: only intersecting ones returned, in input order
# ---------------------------------------------------------------------------

block test_multi_ep:
  var g = mkGraph()
  let e1 = ep("tests/unit/test_a.nim")
  let e2 = ep("tests/unit/test_b.nim")
  let e3 = ep("tests/unit/test_c.nim")
  # Each closure uses real existing files; changed only hits e1 and e3.
  g.updateEntry(e1.path, flagHash(e1.flags), toSet(kNarrow))
  g.updateEntry(e2.path, flagHash(e2.flags), toSet(kTypes))
  g.updateEntry(e3.path, flagHash(e3.flags), toSet(kDepgraph))
  let changed = toSet(kNarrow, kDepgraph)
  let result = narrowByDiff(@[e1, e2, e3], changed, g, getCurrentDir())
  assert result.len == 2, "expected 2 selected, got " & $result.len
  assert result[0].path == e1.path, "first must be e1 (input order)"
  assert result[1].path == e3.path, "second must be e3 (input order)"

# ---------------------------------------------------------------------------
# Shared dependency: two eps depending on same file → both selected
# ---------------------------------------------------------------------------

block test_shared_dep:
  var g = mkGraph()
  let e1 = ep("tests/unit/test_x.nim")
  let e2 = ep("tests/unit/test_y.nim")
  # sharedDep must be a real existing file so entries are not stale.
  let sharedDep = kDiscover
  g.updateEntry(e1.path, flagHash(e1.flags), toSet(kNarrow, sharedDep))
  g.updateEntry(e2.path, flagHash(e2.flags), toSet(kTypes,  sharedDep))
  let changed = toSet(sharedDep)
  let result = narrowByDiff(@[e1, e2], changed, g, getCurrentDir())
  assert result.len == 2, "expected both eps selected via shared dep, got " & $result.len

# ---------------------------------------------------------------------------
# Own file changed: ep's own path is in closure and in changed → selected
# ---------------------------------------------------------------------------

block test_own_file_changed:
  var g = mkGraph()
  let e = ep("tests/unit/test_self.nim")
  # D4: own-file rule (priority 2) fires before staleness check (priority 4).
  # The closure can be entirely synthetic (non-existent) — own-file wins first.
  g.updateEntry(e.path, flagHash(e.flags),
                toSet("tests/unit/test_self.nim", "src/crisol/self_nonexistent.nim"))
  let changed = toSet("tests/unit/test_self.nim")
  let result = narrowByDiff(@[e], changed, g, getCurrentDir())
  assert result.len == 1, "own-file-changed should be selected, got " & $result.len

# ---------------------------------------------------------------------------
# Unknown key → conservative include (D3 fallback; D4 will refine)
# ---------------------------------------------------------------------------

block test_unknown_key_conservative_include:
  var g = mkGraph()
  let e = ep("tests/unit/test_unknown.nim")
  # No entry added to graph for this ep
  let changed = initHashSet[string]()  # even empty changed set
  let result = narrowByDiff(@[e], changed, g, getCurrentDir())
  assert result.len == 1,
    "unknown-key ep must be conservatively included even when changed is empty, got " &
    $result.len

block test_unknown_key_with_nonempty_changed:
  var g = mkGraph()
  let e = ep("tests/unit/test_unknown2.nim")
  # No entry added to graph for this ep
  let changed = toSet("src/crisol/something.nim")
  let result = narrowByDiff(@[e], changed, g, getCurrentDir())
  assert result.len == 1,
    "unknown-key ep must be conservatively included regardless of changed set"

# ---------------------------------------------------------------------------
# flagHash keying: same path, two eps with different flags
# ---------------------------------------------------------------------------

block test_flaghash_keying:
  var g = mkGraph()
  let path = "tests/unit/test_flags.nim"
  let eA = ep(path, @["-d:release"])
  let eB = ep(path, @["-d:debug"])
  # eA has a graph entry with real existing files in its closure.
  # The closure must include kRender (the changed file) and kNarrow.
  g.updateEntry(eA.path, flagHash(eA.flags), toSet(kNarrow, kRender))
  # eB has NO graph entry → unknown-key → conservatively included.
  let changed = toSet(kRender)
  let result = narrowByDiff(@[eA, eB], changed, g, getCurrentDir())
  assert result.len == 2,
    "eA selected by intersection, eB selected by unknown-key rule; expected 2, got " &
    $result.len
  assert result[0].path == eA.path
  assert result[0].flags == eA.flags
  assert result[1].path == eB.path
  assert result[1].flags == eB.flags

# ---------------------------------------------------------------------------
# Empty changed set: all-known non-intersecting → none; unknown-key ep still in
# ---------------------------------------------------------------------------

block test_empty_changed_known_only:
  var g = mkGraph()
  let e1 = ep("tests/unit/test_p.nim")
  let e2 = ep("tests/unit/test_q.nim")
  # Real existing files so entries are fresh (not stale).
  g.updateEntry(e1.path, flagHash(e1.flags), toSet(kNarrow))
  g.updateEntry(e2.path, flagHash(e2.flags), toSet(kTypes))
  let changed = initHashSet[string]()
  let result = narrowByDiff(@[e1, e2], changed, g, getCurrentDir())
  assert result.len == 0,
    "empty changed + all-known closures → nothing selected, got " & $result.len

block test_empty_changed_with_unknown_key:
  var g = mkGraph()
  let eKnown   = ep("tests/unit/test_known.nim")
  let eUnknown = ep("tests/unit/test_nograph.nim")
  # eKnown uses a real existing file so it is fresh.
  g.updateEntry(eKnown.path, flagHash(eKnown.flags), toSet(kRunner))
  # eUnknown has no graph entry → conservatively included.
  let changed = initHashSet[string]()
  let result = narrowByDiff(@[eKnown, eUnknown], changed, g, getCurrentDir())
  assert result.len == 1,
    "only unknown-key ep selected when changed is empty, got " & $result.len
  assert result[0].path == eUnknown.path

echo "PASS test_narrow"
