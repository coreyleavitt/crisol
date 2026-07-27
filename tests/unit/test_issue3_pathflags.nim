## test_issue3_pathflags.nim — issue #3: `crisol run <path>` must inherit the
## owning group's (or global) flags instead of compiling with EMPTY flags, and
## must not silently drop `--group` when a positional path is also given.
##
## RFC-0001:409 — "a path matching no configured group becomes an ad-hoc
## entrypoint with global flags only, plus a warning."
##
## Follows strict RED→GREEN→REFACTOR per behavior, one test at a time.
## Fixture trees are built in a unique temp subdirectory per test and cleaned
## up on exit — same conventions as test_discover.nim.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_issue3_pathflags.nim

import std/[os, options, sequtils, strutils, unittest]
import crisol/types
import crisol/discover
import crisol/render

# ---------------------------------------------------------------------------
# Fixture helpers (mirrors test_discover.nim)
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_test_issue3_" & tag)
  createDir(result)

proc writeFixture(root, rel: string) =
  let full = root / rel
  createDir(full.parentDir)
  writeFile(full, "# fixture\n")

proc cleanupDir(path: string) =
  try: os.removeDir(path) except: discard

proc makeConfig(root: string; groups: seq[Group]): Config =
  Config(projectRoot: root, groups: groups)

# ---------------------------------------------------------------------------
# Behavior 1 [TRACER]: explicit path matching a configured group resolves to
# that group — ep.flags == group.flags AND ep.group == "<groupname>".
# ---------------------------------------------------------------------------

suite "gskFiles – explicit path resolves to owning group":
  test "path matching a configured group's globs gets that group's name and flags":
    let root = makeTempRoot("match")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/unit/test_a.nim"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run

    check eps.len == 1
    check eps[0].group == "unit"
    check eps[0].flags == @["-d:someDefine"]

# ---------------------------------------------------------------------------
# Behavior 2: explicit path matching NO configured group becomes an ad-hoc
# entrypoint with GLOBAL flags (RFC-0001:409), group "paths".
# ---------------------------------------------------------------------------

suite "gskFiles – explicit path matching no group is ad-hoc":
  test "path matching no configured group's globs gets global flags and group 'paths'":
    let root = makeTempRoot("nomatch")
    defer: cleanupDir(root)

    writeFixture(root, "tests/adhoc/test_a.nim")

    var cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])
    cfg.flags = @["-d:globalDefine"]

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/adhoc/test_a.nim"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run

    check eps.len == 1
    check eps[0].group == "paths"
    check eps[0].flags == cfg.flags

# ---------------------------------------------------------------------------
# Behavior 3: the ad-hoc path is surfaced as DATA on the DiscoveredSet so the
# CLI layer can print the RFC-0001:409 warning — discover() stays pure (no
# stderr writes from within it).
# ---------------------------------------------------------------------------

suite "gskFiles – ad-hoc paths recorded as data":
  test "unmatched path is recorded in DiscoveredSet.adHocPaths":
    let root = makeTempRoot("adhoc_data")
    defer: cleanupDir(root)

    writeFixture(root, "tests/adhoc/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/adhoc/test_a.nim"])
    let ds  = discover(cfg, sel)

    check ds.adHocPaths == @["tests/adhoc/test_a.nim"]

# ---------------------------------------------------------------------------
# Behavior 4: `--group unit <path in unit>` must not drop the group — the CLI
# builds gskFiles(paths, withinGroups: @["unit"]) and the path still resolves
# to unit's flags.
# ---------------------------------------------------------------------------

suite "gskFiles – withinGroups narrows candidates without dropping the group":
  test "path in the --group-restricted group resolves to that group's flags":
    let root = makeTempRoot("within")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/unit/test_a.nim"],
                              withinGroups: @["unit"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run

    check eps.len == 1
    check eps[0].group == "unit"
    check eps[0].flags == @["-d:someDefine"]

# ---------------------------------------------------------------------------
# Behavior 5: `--group unit <path NOT in unit's globs>` ⇒ ad-hoc (global
# flags, group "paths") AND recorded so the CLI can warn about the mismatch
# (reuses adHocPaths — the CLI already knows --group was given).
# ---------------------------------------------------------------------------

suite "gskFiles – withinGroups path outside the named group is ad-hoc":
  test "path not in the --group-restricted group's globs → ad-hoc, recorded":
    let root = makeTempRoot("within_mismatch")
    defer: cleanupDir(root)

    writeFixture(root, "tests/other/test_z.nim")

    var cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])
    cfg.flags = @["-d:globalDefine"]

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/other/test_z.nim"],
                              withinGroups: @["unit"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run

    check eps.len == 1
    check eps[0].group == "paths"
    check eps[0].flags == cfg.flags
    check ds.adHocPaths == @["tests/other/test_z.nim"]

# ---------------------------------------------------------------------------
# Behavior 6: a path matching TWO candidate groups (declared "unit" then
# "all-tests", with differing flags) resolves to the FIRST declared ("unit")
# AND is recorded as ambiguous so the CLI can warn about it.
# ---------------------------------------------------------------------------

suite "gskFiles – ambiguous multi-match":
  test "path matching two candidate groups picks the first declared, records ambiguity":
    let root = makeTempRoot("ambiguous")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[
      Group(name: "unit",      globs: @["tests/unit/test_*.nim"], flags: @["-d:unitDefine"]),
      Group(name: "all-tests", globs: @["tests/**/test_*.nim"],   flags: @["-d:allDefine"]),
    ])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/unit/test_a.nim"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run

    check eps.len == 1
    check eps[0].group == "unit"
    check eps[0].flags == @["-d:unitDefine"]
    check ds.ambiguousPaths.len == 1
    check ds.ambiguousPaths[0].path == "tests/unit/test_a.nim"
    check ds.ambiguousPaths[0].groups == @["unit", "all-tests"]

# ---------------------------------------------------------------------------
# Behavior 7 (CLI warnings, pure helper): pathFlagsWarnings() turns discovery
# data (adHocPaths/ambiguousPaths) into human-readable RFC-0001:409 warning
# lines — same pattern as render.gateSkipMessages.  crisol.nim prints these
# to stderr; the formatting itself is unit-tested here, pure, no I/O.
# ---------------------------------------------------------------------------

suite "pathFlagsWarnings – pure helper":
  test "ad-hoc path with no --group in effect: 'matched no configured group'":
    let msgs = pathFlagsWarnings(adHocPaths = @["tests/adhoc/test_a.nim"],
                                  ambiguousPaths = @[])
    check msgs.len == 1
    check "tests/adhoc/test_a.nim" in msgs[0]
    check "matched no configured group" in msgs[0]

  test "ad-hoc path WITH --group in effect: names the group mismatch":
    let msgs = pathFlagsWarnings(adHocPaths = @["tests/other/test_z.nim"],
                                  ambiguousPaths = @[],
                                  withinGroups = @["unit"])
    check msgs.len == 1
    check "tests/other/test_z.nim" in msgs[0]
    check "unit" in msgs[0]

  test "ambiguous path: names all matching groups and the one used":
    let msgs = pathFlagsWarnings(adHocPaths = @[],
                                  ambiguousPaths = @[(path: "tests/unit/test_a.nim",
                                                       groups: @["unit", "all-tests"])])
    check msgs.len == 1
    check "tests/unit/test_a.nim" in msgs[0]
    check "unit" in msgs[0]
    check "all-tests" in msgs[0]

  test "no ad-hoc, no ambiguous → empty result":
    check pathFlagsWarnings(adHocPaths = @[], ambiguousPaths = @[]).len == 0

# ---------------------------------------------------------------------------
# Behavior 10 (follow-up): an UNKNOWN --group name alongside a positional path
# must raise cekConfig (same as a bare `--group typo`), not silently degrade to
# an ad-hoc entrypoint with global flags. Closes the withinGroups validation
# gap left by the initial issue #3 fix.
# ---------------------------------------------------------------------------

suite "gskFiles – unknown --group name is validated":
  test "unknown --group name with a path raises cekConfig, not silent ad-hoc":
    let root = makeTempRoot("unknown_group")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/unit/test_a.nim"],
                              withinGroups: @["typodypo"])

    var raised = false
    try:
      discard discover(cfg, sel)
    except CrisolError as e:
      raised = true
      check e.kind == cekConfig
      check "typodypo" in e.msg
    check raised

  test "a KNOWN --group name with a path still resolves (no false positive)":
    let root = makeTempRoot("known_group_ok")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:someDefine"],
    )])

    let sel = GroupSelection(kind: gskFiles, paths: @["tests/unit/test_a.nim"],
                              withinGroups: @["unit"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 1
    check eps[0].group == "unit"
