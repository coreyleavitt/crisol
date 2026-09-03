## test_b3a_ledger_knob.nim — RFC-0005 B3a: execute(recordLedger = false).
##
## The --verify-cache post-run pass re-runs sampled entries through a SECOND
## bounded execute() call; those re-runs must not pollute --order
## (failed-first/medianDur), perf-check history, or --shard LPT samples
## (RFC-0005 §Stage B "execute() re-entrancy" guard #2). execute() gains a
## `recordLedger: bool = true` knob — default true (existing behavior
## unchanged); false suppresses ledger attempt rows for that call.
##
## Uses the pass_always.nim fixture (real compile+run — this is an
## effectful/integration test, not a pure unit test).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_b3a_ledger_knob.nim

import std/[os, unittest]
import crisol/types
import crisol/config
import crisol/depgraph
import crisol/runner
import crisol/ledger
import crisol/keys

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc stageEp(tmpRoot: string): Entrypoint =
  createDir(tmpRoot / "tests")
  copyFile(fixtureDir() / "pass_always.nim", tmpRoot / "tests" / "pass_always.nim")
  Entrypoint(path: "tests/pass_always.nim", group: "test", flags: @[])

proc makeIsolatedConfig(root: string): Config =
  Config(
    projectRoot:        root,
    stateDir:           ".crisol_b3a_ledger_test",
    timeoutSecs:        60,
    compileTimeoutSecs: 120,
    maxOutputBytes:     65_536,
    jobs:               1,
  )

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "B3a — execute(recordLedger) ledger knob":

  test "recordLedger default (true): a live attempt appends a ledger row":
    let tmpRoot = getTempDir() / "crisol_b3a_ledger_default"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = stageEp(tmpRoot)
    let cfg = makeIsolatedConfig(tmpRoot)
    let sd  = stateDirOf(cfg)

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)

    discard execute(p, config = cfg, graph = graph, nimVersion = "",
                    showProgress = false)

    let ident = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanLedger(sd, ident)
    check rows.len == 1

  test "recordLedger = false: the ledger gains no rows":
    let tmpRoot = getTempDir() / "crisol_b3a_ledger_suppressed"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = stageEp(tmpRoot)
    let cfg = makeIsolatedConfig(tmpRoot)
    let sd  = stateDirOf(cfg)

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)

    let results = execute(p, config = cfg, graph = graph, nimVersion = "",
                          showProgress = false, recordLedger = false)
    check results.len == 1
    check results[0].outcome == oPassed  # the run itself is unaffected

    let ident = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanLedger(sd, ident)
    check rows.len == 0

  test "recordLedger = false does not suppress rows from a PRIOR recordLedger=true call":
    ## Guards against an implementation that (wrongly) skips opening the
    ## ledger shard entirely, which could otherwise mask a bug where a later
    ## true-knob call's rows silently vanish too.
    let tmpRoot = getTempDir() / "crisol_b3a_ledger_mixed"
    createDir(tmpRoot)
    defer: removeDir(tmpRoot)

    let ep  = stageEp(tmpRoot)
    let cfg = makeIsolatedConfig(tmpRoot)
    let sd  = stateDirOf(cfg)
    let ident = identityKey(ep.path, flagHash(ep.flags))

    var graph = initDepGraph("")
    let p1 = plan(cfg, @[ep], graph, "", false)
    discard execute(p1, config = cfg, graph = graph, nimVersion = "",
                    showProgress = false)  # recordLedger default true → 1 row
    check scanLedger(sd, ident).len == 1

    # Second call, same plan (now cdSkipFresh), recordLedger = false.
    let p2 = plan(cfg, @[ep], graph, "", false)
    discard execute(p2, config = cfg, graph = graph, nimVersion = "",
                    showProgress = false, recordLedger = false)
    check scanLedger(sd, ident).len == 1  # still just the first row

echo "test_b3a_ledger_knob: OK"
