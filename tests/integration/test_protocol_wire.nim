## test_protocol_wire.nim — R1 integration test: structured result protocol wired.
##
## Verifies that crisol's executor:
##   1. Injects CRISOL_SINK into the child environment (the child can write to it).
##   2. After the run, reads the sink and populates EntrypointResult.records.
##   3. Applies the OR-rule: a fixture that emits rsFail but quits(0) is
##      classified oFailed (NOT oPassed).
##   4. A fixture with only rsPass records and exit 0 is classified oPassed.
##
## The fixture `protocol_fail_exit0.nim` emits 1 rsFail + 1 rsPass, then exits 0.
## Without the OR-rule the executor would see exit 0 and classify oPassed.
## With the OR-rule wired, it must classify oFailed.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_protocol_wire.nim

import std/[os, unittest]
import crisol/types
import crisol/runner
import crisol/depgraph

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

proc makeCfg(): Config =
  Config(
    compileTimeoutSecs: 60,
    timeoutSecs:        30,
    maxOutputBytes:     65_536,
    projectRoot:        getCurrentDir(),
  )

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------

suite "R1 — protocol wired: OR-rule and records populated":

  test "rsFail record + exit 0 → oFailed (OR-rule)":
    ## The fixture emits an rsFail record and calls quit(0).
    ## Without the OR-rule the executor would see exit 0 and return oPassed.
    ## With R1 wired, the executor must read the sink and classify oFailed.
    let src = fixtureDir() / "protocol_fail_exit0.nim"
    check fileExists(src)
    let ep  = mkEp(src)
    let cfg = makeCfg()
    let p   = plan(cfg, @[ep], emptyDepGraph())
    var g   = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 1
    let r = results[0]
    # OR-rule: rsFail record takes precedence over exit 0.
    check r.outcome == oFailed
    # Records must be populated (protocol was used).
    check r.records.len == 2
    check r.records[0].status == rsFail
    check r.records[1].status == rsPass

  test "records.len > 0 after protocol run (sink populated)":
    ## Separately verify the records field is non-empty after a run that uses
    ## the structured protocol.  This fails if CRISOL_SINK was never injected.
    let src = fixtureDir() / "protocol_fail_exit0.nim"
    check fileExists(src)
    let ep  = mkEp(src)
    let cfg = makeCfg()
    let p   = plan(cfg, @[ep], emptyDepGraph())
    var g   = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 1
    check results[0].records.len > 0

  test "fixture with no rsFail and exit 0 still passes → oPassed":
    ## Sanity: pass_always.nim does not use the protocol at all → opaque
    ## fallback → exit 0 → oPassed.  Ensures we didn't break the non-protocol
    ## path.
    let src = fixtureDir() / "pass_always.nim"
    check fileExists(src)
    let ep  = mkEp(src)
    let cfg = makeCfg()
    let p   = plan(cfg, @[ep], emptyDepGraph())
    var g   = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 1
    check results[0].outcome == oPassed

  test "fail_always.nim (exit non-zero, no protocol) → oFailed":
    ## Opaque fallback: no sink written, exit non-zero → oFailed (unchanged).
    let src = fixtureDir() / "fail_always.nim"
    check fileExists(src)
    let ep  = mkEp(src)
    let cfg = makeCfg()
    let p   = plan(cfg, @[ep], emptyDepGraph())
    var g   = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)
    check results.len == 1
    check results[0].outcome == oFailed
    # No records for opaque fallback.
    check results[0].records.len == 0
