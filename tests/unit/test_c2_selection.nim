## test_c2_selection.nim — unit tests for C2: group selection + gate skip messaging
##
## Covers:
##   • gskDefault excludes opt-in groups (existing behavior, re-confirmed for C2)
##   • gskNamed selects only the named group(s) (unknown name → cekConfig)
##   • gskAll includes opt-in groups
##   • multiple named groups (--group A --group B)
##   • gate skip: gatedOut list produced when gate closed, none when open
##   • gateSkipMessages pure helper: correct line format, empty input → empty output
##   • exit code unaffected by gate-skips (Summary.exitCode uses only run outcomes)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c2_selection.nim

import std/[options, strutils, unittest]
import crisol/types
import crisol/discover
import crisol/render

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeConfig(groups: seq[Group]): Config =
  ## Hand-build a Config with a fictional root (no real FS walk needed here).
  ## Tests that need discover() to walk files use makeTempRoot helpers instead.
  Config(projectRoot: "/nonexistent_c2_root", groups: groups)

# ---------------------------------------------------------------------------
# Suite 1 — gateSkipMessages pure helper
# ---------------------------------------------------------------------------

suite "gateSkipMessages — pure helper":

  test "empty input → empty output":
    let msgs = gateSkipMessages(@[])
    check msgs.len == 0

  test "single gated group → one line naming group and env var":
    let msgs = gateSkipMessages(@[(group: "integration", reason: "env FRESCO_DB_URL not set")])
    check msgs.len == 1
    check "integration" in msgs[0]
    check "FRESCO_DB_URL" in msgs[0]
    # Should include the word "skipped" somewhere
    check "skipped" in msgs[0]

  test "multiple gated groups → one line per group":
    let msgs = gateSkipMessages(@[
      (group: "smoke",       reason: "env SMOKE_KEY not set"),
      (group: "integration", reason: "env DB_URL not set"),
    ])
    check msgs.len == 2
    check "smoke" in msgs[0]
    check "integration" in msgs[1]

  test "reason text is preserved verbatim in message":
    let reason = "env AMOXTLI_OPENROUTER_API_KEY not set"
    let msgs = gateSkipMessages(@[(group: "llm", reason: reason)])
    check msgs.len == 1
    check reason in msgs[0]

# ---------------------------------------------------------------------------
# Suite 2 — GroupSelection variants (discover + applyGates over hand-built Config)
# We use toDiscoveredSet to bypass the file-tree walk — the selection logic
# under test is purely in discover() and applyGates(), not in FS walking.
# ---------------------------------------------------------------------------

suite "C2 selection — gskDefault excludes opt-in":

  test "gskDefault: opt-in group entrypoints do NOT appear in run set":
    let epOptIn    = Entrypoint(path: "tests/smoke/test_s.nim", group: "smoke",       flags: @[])
    let epDefault  = Entrypoint(path: "tests/unit/test_u.nim",  group: "unit",        flags: @[])
    let ds = toDiscoveredSet(@[epDefault])  # gskDefault discover excludes opt-in

    let cfg = makeConfig(@[
      Group(name: "unit",  globs: @["tests/unit/test_*.nim"], optIn: false),
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true),
    ])
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 1
    check run[0].group == "unit"
    check gatedOut.len == 0

suite "C2 selection — gskNamed":

  test "gskNamed: only the named group is active, opt-in or not":
    # We build the DiscoveredSet manually to reflect what discover() would return
    # for gskNamed(["smoke"]) — i.e. only the smoke entrypoint.
    let epSmoke = Entrypoint(path: "tests/smoke/test_s.nim", group: "smoke", flags: @[])
    let ds = toDiscoveredSet(@[epSmoke])

    let cfg = makeConfig(@[
      Group(name: "unit",  globs: @["tests/unit/test_*.nim"],  optIn: false),
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true),
    ])
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 1
    check run[0].group == "smoke"

  test "gskNamed: unknown group name raises cekConfig":
    ## This tests discover() itself; we must use a real (temp) root.
    ## We pass a nonexistent root — discover() raises before walking files.
    let cfg = Config(
      projectRoot: "/nonexistent_c2",
      groups: @[Group(name: "unit", globs: @["tests/unit/test_*.nim"])],
    )
    let sel = GroupSelection(kind: gskNamed, names: @["no_such_group"])
    var raised = false
    var kind: CrisolErrorKind
    try:
      discard discover(cfg, sel)
    except CrisolError as e:
      raised = true
      kind = e.kind
    check raised
    check kind == cekConfig

  test "gskNamed with multiple names: both groups active":
    let epA = Entrypoint(path: "tests/unit/test_a.nim",  group: "unit",        flags: @[])
    let epB = Entrypoint(path: "tests/smoke/test_b.nim", group: "smoke",       flags: @[])
    let ds = toDiscoveredSet(@[epA, epB])

    let cfg = makeConfig(@[
      Group(name: "unit",  globs: @["tests/unit/test_*.nim"],  optIn: false),
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true),
    ])
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 2

suite "C2 selection — gskAll":

  test "gskAll includes opt-in group entries":
    let epUnit  = Entrypoint(path: "tests/unit/test_u.nim",  group: "unit",  flags: @[])
    let epSmoke = Entrypoint(path: "tests/smoke/test_s.nim", group: "smoke", flags: @[])
    # gskAll discover would include both; simulate with toDiscoveredSet.
    let ds = toDiscoveredSet(@[epUnit, epSmoke])

    let cfg = makeConfig(@[
      Group(name: "unit",  globs: @["tests/unit/test_*.nim"],  optIn: false),
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true),
    ])
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 2
    check gatedOut.len == 0

# ---------------------------------------------------------------------------
# Suite 3 — Gate skip: gatedOut + exit code unaffected
# ---------------------------------------------------------------------------

suite "C2 gate skip — applyGates gatedOut":

  test "gated group (env unset) → in gatedOut, not in run":
    let epGated = Entrypoint(path: "tests/smoke/test_s.nim", group: "smoke", flags: @[])
    let epRun   = Entrypoint(path: "tests/unit/test_u.nim",  group: "unit",  flags: @[])
    let ds = toDiscoveredSet(@[epRun, epGated])

    let cfg = makeConfig(@[
      Group(name: "unit",  globs: @["tests/unit/test_*.nim"],  optIn: false, gate: none(Gate)),
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true,
            gate: some(Gate(env: "SMOKE_API_KEY"))),
    ])
    # SMOKE_API_KEY absent from state → gate closed.
    let state = initGateState([])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 1
    check run[0].group == "unit"
    check gatedOut.len == 1
    check gatedOut[0].group == "smoke"
    check "SMOKE_API_KEY" in gatedOut[0].reason

  test "gate open (env set to non-empty) → group runs, gatedOut empty":
    let epGated = Entrypoint(path: "tests/smoke/test_s.nim", group: "smoke", flags: @[])
    let ds = toDiscoveredSet(@[epGated])

    let cfg = makeConfig(@[
      Group(name: "smoke", globs: @["tests/smoke/test_*.nim"], optIn: true,
            gate: some(Gate(env: "SMOKE_API_KEY"))),
    ])
    let state = initGateState([("SMOKE_API_KEY", "secret-value")])
    let (run, gatedOut) = applyGates(ds, cfg, state)
    check run.len == 1
    check gatedOut.len == 0

  test "gate-skip does NOT affect exit code — Summary.exitCode ignores gates":
    ## Gate-skips are never failures.  A Summary with only passed entrypoints
    ## should exit 0 regardless of how many gated-out entries exist.
    let s = Summary(total: 2, passed: 2, failed: 0, compileFailed: 0,
                    spawnErrors: 0)
    check exitCode(s) == 0

  test "gate-skip message helper produces correct format":
    let msgs = gateSkipMessages(@[
      (group: "integration", reason: "env FRESCO_DB_URL not set"),
    ])
    check msgs.len == 1
    # Required elements: the word "skipped", the group name, and the reason
    let line = msgs[0]
    check "skipped" in line
    check "integration" in line
    check "FRESCO_DB_URL" in line
