## test_plan.nim — unit tests for plan() (pure; no I/O, no subprocess).
##
## Verifies:
##   • plan() annotates every entrypoint cdNeverBuilt with an empty graph.
##   • plan() resolves jobs=0 to 1.
##   • plan() is truly pure: synthetic (non-existent) entrypoints are accepted.
##   • plan() preserves entrypoint identity in the output.
##   • plan() with multiple entrypoints produces one PlannedEntrypoint each.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_plan.nim

import std/unittest
import crisol/types
import crisol/runner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkEp(path: string; group = "unit"; flags: seq[string] = @[]): Entrypoint =
  Entrypoint(path: path, group: group, flags: flags)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "plan() — pure compile-decision annotation":

  test "empty entrypoint list produces empty plan":
    let p = plan(Config(), @[], emptyDepGraph())
    check p.entrypoints.len == 0

  test "single entrypoint → cdNeverBuilt with empty graph":
    let eps = @[mkEp("tests/unit/test_foo.nim")]
    let p = plan(Config(), eps, emptyDepGraph())
    check p.entrypoints.len == 1
    check p.entrypoints[0].decision == cdNeverBuilt
    check p.entrypoints[0].ep.path == "tests/unit/test_foo.nim"

  test "multiple entrypoints → all cdNeverBuilt":
    let eps = @[
      mkEp("tests/unit/test_a.nim"),
      mkEp("tests/unit/test_b.nim"),
      mkEp("tests/integration/test_c.nim", group = "integration"),
    ]
    let p = plan(Config(), eps, emptyDepGraph())
    check p.entrypoints.len == 3
    for pep in p.entrypoints:
      check pep.decision == cdNeverBuilt

  test "entrypoint identity is preserved (path, group, flags)":
    let ep = mkEp("tests/unit/test_x.nim", group = "mygroup", flags = @["-d:foo"])
    let p = plan(Config(), @[ep], emptyDepGraph())
    let pep = p.entrypoints[0]
    check pep.ep.path  == "tests/unit/test_x.nim"
    check pep.ep.group == "mygroup"
    check pep.ep.flags == @["-d:foo"]

  test "jobs=0 resolved to at least 1 (A4: max(1, cpu-2))":
    let p = plan(Config(jobs: 0), @[], emptyDepGraph())
    check p.jobs >= 1

  test "jobs>0 preserved":
    let p = plan(Config(jobs: 8), @[], emptyDepGraph())
    check p.jobs == 8

  test "plan is pure: synthetic (non-existent) paths do not raise":
    ## If plan tried to stat or open these files it would fail; the fact that
    ## plan() returns without raising proves no I/O is performed.
    let eps = @[
      mkEp("no/such/file_a.nim"),
      mkEp("no/such/file_b.nim"),
      mkEp("also/does/not/exist.nim", group = "ghost"),
    ]
    var raised = false
    try:
      let p = plan(Config(), eps, emptyDepGraph())
      check p.entrypoints.len == 3
    except:
      raised = true
    check not raised

  test "reason field is non-empty for cdNeverBuilt":
    let p = plan(Config(), @[mkEp("x.nim")], emptyDepGraph())
    check p.entrypoints[0].reason.len > 0
