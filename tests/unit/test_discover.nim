## test_discover.nim — unit suite for crisol/discover
##
## Follows strict RED→GREEN→REFACTOR per behavior.  Fixture trees are built in
## a unique temp subdirectory per test and cleaned up on exit.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_discover.nim

import std/[os, options, sequtils, strutils, sugar, unittest]
import crisol/types
import crisol/discover

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  ## Return a fresh, empty directory under the system temp dir.
  result = getTempDir() / ("crisol_test_" & tag)
  createDir(result)

proc writeFixture(root, rel: string) =
  ## Create `root/rel` (and intermediate dirs) with trivial content.
  let full = root / rel
  createDir(full.parentDir)
  writeFile(full, "# fixture\n")

proc cleanupDir(path: string) =
  ## Best-effort cleanup — ignore errors so a test failure doesn't mask cleanup.
  try: os.removeDir(path) except: discard

proc makeConfig(root: string; groups: seq[Group]): Config =
  ## Convenience: build a Config with projectRoot set to root.
  Config(projectRoot: root, groups: groups)

# ---------------------------------------------------------------------------
# Suite 1 — tracer: single group, single matching file
# ---------------------------------------------------------------------------

suite "discover – tracer":
  test "one group, one matching file → exactly one Entrypoint":
    let root = makeTempRoot("tracer")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @["-d:testing"],
    )])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 1
    check eps[0].path  == "tests/unit/test_a.nim"
    check eps[0].group == "unit"
    check eps[0].flags == @["-d:testing"]

# ---------------------------------------------------------------------------
# Suite 2 — matchGlob unit tests
# ---------------------------------------------------------------------------

suite "matchGlob":
  test "literal match":
    check matchGlob("tests/unit/test_a.nim", "tests/unit/test_a.nim")

  test "literal mismatch":
    check not matchGlob("tests/unit/test_a.nim", "tests/unit/test_b.nim")

  test "* within segment matches any run of chars":
    check matchGlob("tests/unit/test_*.nim", "tests/unit/test_parser.nim")
    check matchGlob("tests/unit/test_*.nim", "tests/unit/test_a.nim")

  test "* does not cross slash boundary":
    check not matchGlob("tests/*/test_a.nim", "tests/a/b/test_a.nim")

  test "? matches exactly one char":
    check matchGlob("tests/unit/test_?.nim", "tests/unit/test_a.nim")
    check not matchGlob("tests/unit/test_?.nim", "tests/unit/test_ab.nim")

  test "** consumes zero segments":
    # tests/**/test_a.nim should match tests/test_a.nim  (**→ zero)
    check matchGlob("tests/**/test_a.nim", "tests/test_a.nim")

  test "** consumes multiple segments":
    check matchGlob("tests/**/test_*.nim", "tests/unit/deep/test_b.nim")

  test "* in inner segment does not span multiple real segments":
    check not matchGlob("tests/*/x.nim", "tests/a/b/x.nim")

  test "trailing ** matches any depth":
    check matchGlob("tests/**", "tests/unit/test_a.nim")

# ---------------------------------------------------------------------------
# Suite 3 — union+dedup within a group
# ---------------------------------------------------------------------------

suite "discover – dedup within group":
  test "file matching two globs in same group → one Entrypoint":
    let root = makeTempRoot("dedup")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      # Both globs match the same file.
      globs: @["tests/unit/test_*.nim", "tests/**/test_a.nim"],
      flags: @[],
    )])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 1
    check eps[0].path == "tests/unit/test_a.nim"

# ---------------------------------------------------------------------------
# Suite 4 — sorted output
# ---------------------------------------------------------------------------

suite "discover – sorted output":
  test "results sorted by path then group":
    let root = makeTempRoot("sorted")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_b.nim")
    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_c.nim")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @[],
    )])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 3
    let paths = eps.mapIt(it.path)
    check paths == @[
      "tests/unit/test_a.nim",
      "tests/unit/test_b.nim",
      "tests/unit/test_c.nim",
    ]

# ---------------------------------------------------------------------------
# Suite 5 — opt-in groups
# ---------------------------------------------------------------------------

suite "discover – opt-in groups":
  test "opt-in group excluded under gskDefault":
    let root = makeTempRoot("optin_default")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      optIn:  true,
    )])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 0

  test "opt-in group included under gskNamed":
    let root = makeTempRoot("optin_named")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      optIn:  true,
    )])

    let sel = GroupSelection(kind: gskNamed, names: @["smoke"])
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 1
    check eps[0].group == "smoke"

  test "opt-in group included under gskAll":
    let root = makeTempRoot("optin_all")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      optIn:  true,
    )])

    let sel = GroupSelection(kind: gskAll)
    let ds  = discover(cfg, sel)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 1

# ---------------------------------------------------------------------------
# Suite 6 — gate checks (initGateState, never reads real env)
# ---------------------------------------------------------------------------

suite "discover – gate (via applyGates)":
  test "gate closed (env not in state) → group excluded, in gatedOut":
    let root = makeTempRoot("gate_closed")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      gate:   some(Gate(env: "FAKE_KEY")),
    )])

    # FAKE_KEY absent from state → gate closed.
    let state = initGateState([])
    let ds    = discover(cfg)
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 0
    check gatedOut.len == 1
    check gatedOut[0].group == "smoke"
    check "FAKE_KEY" in gatedOut[0].reason

  test "gate closed (env set to empty) → group excluded, in gatedOut":
    let root = makeTempRoot("gate_empty")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      gate:   some(Gate(env: "FAKE_KEY")),
    )])

    # FAKE_KEY present but blank → gate still closed.
    let state = initGateState([("FAKE_KEY", "   ")])
    let ds    = discover(cfg)
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 0
    check gatedOut.len == 1

  test "gate open (env set to non-empty) → group included, gatedOut empty":
    let root = makeTempRoot("gate_open")
    defer: cleanupDir(root)

    writeFixture(root, "tests/smoke/test_smoke.nim")

    let cfg = makeConfig(root, @[Group(
      name:   "smoke",
      globs:  @["tests/smoke/test_*.nim"],
      flags:  @[],
      gate:   some(Gate(env: "FAKE_KEY")),
    )])

    let state = initGateState([("FAKE_KEY", "secret")])
    let ds    = discover(cfg)
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 1
    check gatedOut.len == 0

# ---------------------------------------------------------------------------
# Suite 7 — gskNamed with unknown group name raises CrisolError(cekConfig)
# ---------------------------------------------------------------------------

suite "discover – unknown group name":
  test "gskNamed with absent group name raises cekConfig":
    let root = makeTempRoot("unknown_group")
    defer: cleanupDir(root)

    let cfg = makeConfig(root,
      @[Group(name: "unit", globs: @["tests/unit/test_*.nim"], flags: @[])])

    let sel = GroupSelection(kind: gskNamed, names: @["nonexistent"])

    var raised = false
    var kind: CrisolErrorKind
    try:
      discard discover(cfg, sel)
    except CrisolError as e:
      raised = true
      kind   = e.kind

    check raised
    check kind == cekConfig

# ---------------------------------------------------------------------------
# Suite 8 — two different groups matching same file → two Entrypoints
# ---------------------------------------------------------------------------

suite "discover – cross-group overlap":
  test "same file in two groups → two Entrypoints, distinct flags":
    let root = makeTempRoot("crossgroup")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")

    let cfg = makeConfig(root, @[
      Group(name: "unit",    globs: @["tests/unit/test_*.nim"], flags: @["-d:foo"]),
      Group(name: "special", globs: @["tests/unit/test_*.nim"], flags: @["-d:bar"]),
    ])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    check eps.len == 2

    # Sorted by (path, group): special < unit lexicographically
    check eps[0].group == "special"
    check eps[0].flags == @["-d:bar"]
    check eps[1].group == "unit"
    check eps[1].flags == @["-d:foo"]

# ---------------------------------------------------------------------------
# Suite 9 — directory symlinks are not descended
# ---------------------------------------------------------------------------

suite "discover – symlink directories not followed":
  test "symlinked dir containing matching file yields no Entrypoint":
    let root    = makeTempRoot("symlink_root")
    let symTarget = makeTempRoot("symlink_target")
    defer:
      cleanupDir(root)
      cleanupDir(symTarget)

    # Put a matching file inside the symlink target, NOT under root directly.
    writeFile(symTarget / "test_hidden.nim", "# fixture\n")

    # Create tests/unit/ dir and a symlink inside it pointing at symTarget.
    createDir(root / "tests" / "unit")
    createSymlink(symTarget, root / "tests" / "unit" / "linked_dir")

    let cfg = makeConfig(root, @[Group(
      name:  "unit",
      globs: @["tests/unit/test_*.nim"],
      flags: @[],
    )])

    let ds  = discover(cfg)
    let eps = applyGates(ds, cfg, initGateState([])).run
    # linked_dir/test_hidden.nim should not appear — symlink must not be descended.
    check eps.len == 0

# ---------------------------------------------------------------------------
# Suite 10 — toDiscoveredSet test constructor
# ---------------------------------------------------------------------------

suite "toDiscoveredSet – test constructor":
  test "toDiscoveredSet builds a DiscoveredSet without file-tree walk":
    let eps = @[
      Entrypoint(path: "tests/unit/test_a.nim", group: "unit", flags: @[]),
      Entrypoint(path: "tests/unit/test_b.nim", group: "unit", flags: @[]),
    ]
    let ds = toDiscoveredSet(eps)

    # A config with no gated groups: all entries pass through applyGates unchanged.
    let cfg   = Config(projectRoot: "/irrelevant")
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 2
    check gatedOut.len == 0
    check run[0].path == "tests/unit/test_a.nim"
    check run[1].path == "tests/unit/test_b.nim"
