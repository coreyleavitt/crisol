## test_rfc9_nonascii_lever.nim — RFC-0009 "Risks accepted" NFC/NFD
## mitigation: the previously-unimplemented lever, now implemented in
## `narrow.foldUntrusted` (pure predicate) and wired into
## `pipeline.buildRunPlan` (the narrowing gate).
##
## docs/rfc/0009-path-identity.md, "Risks accepted" (NFC/NFD bullet): the
## fold is deliberately ASCII-only (`paths.fold`, `fpAsciiLower ==
## toLowerAscii`). On a folding root, HFS+/APFS-style Unicode normalization
## can make a `--changed` diff name and the on-disk spelling of the SAME
## file fold to two DISTINCT `TrackedPath`s, silently under-selecting. The
## accepted mitigation: a non-ASCII byte anywhere in the changed-set's
## spelling, on a config where some tracked root actually folds, distrusts
## fold-based narrowing entirely for this run — full run instead, mirroring
## the existing degraded-probe lever (`TrackedRoots.degraded`).
##
## ## Coverage
##
## Part 1 (pure predicate, no I/O): `narrow.changedSetHasNonAscii`,
## `narrow.anyRootFolds`, `narrow.foldUntrusted` directly, across the full
## 2x2 matrix (fold active/inactive x non-ASCII present/absent) plus the
## always-false-on-empty-changed-set case.
##
## Part 2 (wiring, through the real `pipeline.buildRunPlan`): a real
## two-entrypoint fixture with a REAL persisted DepGraph (so Rule 1's
## "graph absent -> force include everything" cannot mask the effect) where
## one entrypoint's known-fresh closure does NOT intersect the changed set
## (a genuine closure-miss exclusion under normal narrowing). Proves:
##   - fold-active root + non-ASCII name anywhere in the changed set -> the
##     would-be-excluded entrypoint IS included (narrowing skipped, full run).
##   - fold-active root + an all-ASCII changed set -> narrowing proceeds
##     normally; the closure-miss entrypoint is excluded.
##   - fpNone (no folding root) + the SAME non-ASCII name -> narrowing still
##     proceeds normally (the lever never fires when nothing folds); the
##     closure-miss entrypoint is excluded.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc9_nonascii_lever.nim

import std/[options, os, sets, unittest]
import crisol/types
import crisol/paths
import crisol/pipeline
import crisol/discover
import crisol/depgraph
import crisol/narrow

# ---------------------------------------------------------------------------
# Shared helper: an injectable fold-policy probe (mirrors the seam other
# RFC-0009 tests use, e.g. tests/unit/test_paths.nim's `fixedProbe`) so a
# genuinely case-sensitive Linux CI volume can still exercise an
# `fpAsciiLower` (folding) root deterministically.
# ---------------------------------------------------------------------------

proc fixedProbe(policy: FoldPolicy): proc (rootAbs, stateDir: string): Option[FoldPolicy] =
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy)

proc mkRootsWith(projectRoot: string; policy: FoldPolicy): TrackedRoots =
  initTrackedRoots(projectRoot, @[], "", fixedProbe(policy))

# ===========================================================================
# Part 1 — pure predicate coverage (no filesystem, no buildRunPlan)
# ===========================================================================

suite "narrow.foldUntrusted — pure predicate matrix":

  test "changedSetHasNonAscii: true when some member's spelling has a non-ASCII byte":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_a", fpAsciiLower)
    let changed = [fromCanonical("tests/unit/tst_a.nim", roots).get,
                   fromCanonical("tests/unit/tëst_ghost.nim", roots).get].toHashSet
    check changedSetHasNonAscii(changed)

  test "changedSetHasNonAscii: false when every member is pure ASCII":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_b", fpAsciiLower)
    let changed = [fromCanonical("tests/unit/tst_a.nim", roots).get,
                   fromCanonical("tests/unit/tst_b.nim", roots).get].toHashSet
    check not changedSetHasNonAscii(changed)

  test "changedSetHasNonAscii: false on an empty changed set":
    check not changedSetHasNonAscii(initHashSet[TrackedPath]())

  test "anyRootFolds: true when the project root's policy is fpAsciiLower":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_c", fpAsciiLower)
    check anyRootFolds(roots)

  test "anyRootFolds: false when the project root's policy is fpNone":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_d", fpNone)
    check not anyRootFolds(roots)

  test "foldUntrusted: fold-active + non-ASCII name -> true":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_e", fpAsciiLower)
    let changed = [fromCanonical("tests/unit/tëst_ghost.nim", roots).get].toHashSet
    check foldUntrusted(changed, roots)

  test "foldUntrusted: fold-active + all-ASCII names -> false":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_f", fpAsciiLower)
    let changed = [fromCanonical("tests/unit/tst_a.nim", roots).get].toHashSet
    check not foldUntrusted(changed, roots)

  test "foldUntrusted: fpNone + non-ASCII name -> false (nothing folds, nothing to distrust)":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_g", fpNone)
    let changed = [fromCanonical("tests/unit/tëst_ghost.nim", roots).get].toHashSet
    check not foldUntrusted(changed, roots)

  test "foldUntrusted: fpNone + all-ASCII -> false":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_h", fpNone)
    let changed = [fromCanonical("tests/unit/tst_a.nim", roots).get].toHashSet
    check not foldUntrusted(changed, roots)

  test "foldUntrusted: fold-active + empty changed set -> false (no --changed in play)":
    let roots = mkRootsWith(getTempDir() / "crisol_lever_pure_i", fpAsciiLower)
    check not foldUntrusted(initHashSet[TrackedPath](), roots)

# ===========================================================================
# Part 2 — wiring: pipeline.buildRunPlan actually consults the lever
# ===========================================================================

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_nonascii_lever_" & tag)
  try: removeDir(result) except: discard
  createDir(result)

proc writeFixture(root, rel: string) =
  let full = root / rel
  createDir(full.parentDir)
  writeFile(full, "# fixture\n")

proc cleanupDir(path: string) =
  try: removeDir(path) except: discard

proc makeConfig(root: string; roots: TrackedRoots): Config =
  Config(
    projectRoot: root,
    stateDir:    ".crisol",
    groups: @[Group(name: "unit", globs: @["tests/unit/test_*.nim"])],
    jobs:    1,
    timeoutSecs: 60,
    compileTimeoutSecs: 120,
    trackedRoots: roots,
  )

proc pathSetOf(pv: RunPlanView): HashSet[string] =
  result = initHashSet[string]()
  for e in pv.plan.entrypoints:
    result.incl string(e.ep.tp.display())

proc buildFixtureAndGraph(root: string; roots: TrackedRoots):
    tuple[cfg: Config; included, excluded: TrackedPath] =
  ## Builds a two-entrypoint fixture with a REAL persisted DepGraph: the
  ## "included" entrypoint's closure is {helperIncluded}; the "excluded"
  ## entrypoint's closure is {helperExcluded} — a DISJOINT dependency, so
  ## under normal (non-bypassed) narrowing against a changed set containing
  ## only helperIncluded, "excluded" is a genuine Rule-5 closure-miss.
  writeFixture(root, "tests/unit/test_included.nim")
  writeFixture(root, "tests/unit/test_excluded.nim")
  writeFixture(root, "tests/unit/helper_included.nim")
  writeFixture(root, "tests/unit/helper_excluded.nim")

  let cfg = makeConfig(root, roots)
  let sel = GroupSelection(kind: gskDefault)

  # Discover once here (mirrors what buildRunPlan will do internally,
  # deterministically, given the same cfg/sel) so the DepGraph entries we
  # persist are keyed EXACTLY as buildRunPlan's own internal discover() call
  # will key them (path display() + flagHash(flags)).
  let eps = unsafeToSeq(discover(cfg, sel))
  var includedEp, excludedEp: Entrypoint
  var foundIncluded, foundExcluded = false
  for e in eps:
    if e.tp.display() == "tests/unit/test_included.nim":
      includedEp = e; foundIncluded = true
    elif e.tp.display() == "tests/unit/test_excluded.nim":
      excludedEp = e; foundExcluded = true
  doAssert foundIncluded and foundExcluded, "fixture discovery did not find both entrypoints"

  let helperIncluded = fromCanonical("tests/unit/helper_included.nim", roots).get
  let helperExcluded = fromCanonical("tests/unit/helper_excluded.nim", roots).get

  var graph = initDepGraph("")
  graph.updateEntry(string(includedEp.tp.display()), flagHash(includedEp.flags), [helperIncluded].toHashSet)
  graph.updateEntry(string(excludedEp.tp.display()), flagHash(excludedEp.flags), [helperExcluded].toHashSet)
  check saveDepGraph(graph, cfg)

  (cfg: cfg, included: includedEp.tp, excluded: excludedEp.tp)

suite "pipeline.buildRunPlan — NFC/NFD lever wiring":

  test "fold-active root + non-ASCII name in changed set -> narrowing skipped, closure-miss entrypoint still runs":
    let root = makeTempRoot("fold_nonascii")
    defer: cleanupDir(root)
    let roots = mkRootsWith(root, fpAsciiLower)
    let (cfg, _, excluded) = buildFixtureAndGraph(root, roots)
    let sel = GroupSelection(kind: gskDefault)

    # The changed set carries the REAL signal (helper_included, matching
    # "included"'s closure) PLUS one unrelated non-ASCII-named diff entry —
    # exactly the RFC's "a non-ASCII byte anywhere in a changed-set name"
    # trigger. Its mere presence must distrust narrowing for the WHOLE run,
    # not just for the entrypoint whose closure it happens to touch.
    let ghost = fromCanonical("tests/unit/tëst_ghost.nim", roots).get
    let helperIncluded = fromCanonical("tests/unit/helper_included.nim", roots).get
    let changed = [helperIncluded, ghost].toHashSet

    let pv = buildRunPlan(cfg = cfg, selection = sel, useChanged = true, changed = changed)
    let selected = pathSetOf(pv)
    check "tests/unit/test_included.nim" in selected
    check string(excluded.display()) in selected   # would be a closure-miss under real narrowing
    check pv.runnable == 2

  test "fold-active root + all-ASCII changed set -> narrowing proceeds; closure-miss entrypoint excluded":
    let root = makeTempRoot("fold_ascii")
    defer: cleanupDir(root)
    let roots = mkRootsWith(root, fpAsciiLower)
    let (cfg, _, excluded) = buildFixtureAndGraph(root, roots)
    let sel = GroupSelection(kind: gskDefault)

    let helperIncluded = fromCanonical("tests/unit/helper_included.nim", roots).get
    let changed = [helperIncluded].toHashSet

    let pv = buildRunPlan(cfg = cfg, selection = sel, useChanged = true, changed = changed)
    let selected = pathSetOf(pv)
    check "tests/unit/test_included.nim" in selected
    check string(excluded.display()) notin selected
    check pv.runnable == 1

  test "fpNone root + non-ASCII changed-set name -> narrowing proceeds (nothing folds, lever never fires)":
    let root = makeTempRoot("nofold_nonascii")
    defer: cleanupDir(root)
    let roots = mkRootsWith(root, fpNone)
    let (cfg, _, excluded) = buildFixtureAndGraph(root, roots)
    let sel = GroupSelection(kind: gskDefault)

    let ghost = fromCanonical("tests/unit/tëst_ghost.nim", roots).get
    let helperIncluded = fromCanonical("tests/unit/helper_included.nim", roots).get
    let changed = [helperIncluded, ghost].toHashSet

    let pv = buildRunPlan(cfg = cfg, selection = sel, useChanged = true, changed = changed)
    let selected = pathSetOf(pv)
    check "tests/unit/test_included.nim" in selected
    check string(excluded.display()) notin selected
    check pv.runnable == 1

  test "fold-active root + non-ASCII changed set -> a warning is surfaced via the existing ConfigWarning channel":
    let root = makeTempRoot("fold_nonascii_warn")
    defer: cleanupDir(root)
    let roots = mkRootsWith(root, fpAsciiLower)
    let (cfg, _, _) = buildFixtureAndGraph(root, roots)
    let sel = GroupSelection(kind: gskDefault)

    let ghost = fromCanonical("tests/unit/tëst_ghost.nim", roots).get
    let changed = [ghost].toHashSet

    let pv = buildRunPlan(cfg = cfg, selection = sel, useChanged = true, changed = changed)
    var found = false
    for w in pv.warnings:
      if w.context == "changed-set-fold" and w.key == "nonAsciiChangedName":
        found = true
    check found
