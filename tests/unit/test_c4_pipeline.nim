## test_c4_pipeline.nim — TDD tests for C4 wiring in buildRunPlan.
##
## Coverage:
##   omNone (default) → parity: no reorder vs baseline without order param
##   order applied after shard: shard membership unchanged, sequence may differ
##   omRecentFail: ep with most recent fail timestamp appears first in plan
##   omDuration: ep with largest median duration appears first in plan
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c4_pipeline.nim

import std/[os, sequtils, sets, tables, unittest]
import crisol/types
import crisol/pipeline
import crisol/order
import crisol/ledger
import crisol/keys
import crisol/depgraph  # for flagHash

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_c4_pipe_" & tag)
  createDir(result)

proc writeFixture(root, rel: string) =
  let full = root / rel
  createDir(full.parentDir)
  writeFile(full, "# fixture\n")

proc cleanupDir(path: string) =
  try: removeDir(path) except: discard

proc makeConfig(root: string; globs: seq[string]): Config =
  Config(
    projectRoot: root,
    stateDir:    ".crisol",
    groups: @[Group(name: "unit", globs: globs)],
    jobs:    1,
    timeoutSecs: 60,
    compileTimeoutSecs: 120,
  )

proc pathsOf(pv: RunPlanView): seq[string] =
  pv.plan.entrypoints.mapIt(it.ep.path)

proc pathSetOf(pv: RunPlanView): HashSet[string] =
  result = initHashSet[string]()
  for p in pathsOf(pv):
    result.incl p

proc seedLedger(sd: string; rows: openArray[(string, int64, int64, string)]) =
  ## Seed ledger with (path, timestamp, durationUs, outcome).
  var led = openLedger(sd)
  let fh = flagHash(@[])
  for (path, ts, dur, outcome) in rows:
    let ik = identityKey(path, fh)
    append(led, LedgerRow(
      identity:   ik,
      timestamp:  ts,
      inputHash:  "abc",
      outcome:    outcome,
      attempt:    1,
      durationUs: dur,
      rssBytes:   0i64,
      rowVersion: currentRowVersion,
    ))
  closeLedger(led)

# ---------------------------------------------------------------------------
# Suite: omNone parity
# ---------------------------------------------------------------------------

suite "buildRunPlan — C4 omNone parity":

  test "omNone (default): same runnable count as without order param":
    let root = makeTempRoot("c4_none")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_b.nim")
    writeFixture(root, "tests/unit/test_c.nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    let pvBase  = buildRunPlan(cfg = cfg, selection = sel)
    let pvNone  = buildRunPlan(cfg = cfg, selection = sel, order = omNone)

    check pvBase.runnable  == pvNone.runnable
    check pathSetOf(pvBase) == pathSetOf(pvNone)
    # omNone preserves input sequence — both should produce identical path sequences
    check pathsOf(pvBase) == pathsOf(pvNone)

# ---------------------------------------------------------------------------
# Suite: shard × order composition
# ---------------------------------------------------------------------------

suite "buildRunPlan — C4 shard × order composition":

  test "shard membership unchanged when order is applied after shard":
    ## shardK=1/2 with omRecentFail must produce same membership as shardK=1/2 alone.
    ## The order step only reorders; it must not add or remove eps.
    let root = makeTempRoot("c4_shard_order")
    defer: cleanupDir(root)

    let names = ["test_alpha", "test_beta", "test_gamma",
                 "test_delta", "test_epsilon", "test_zeta"]
    for n in names:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    # Shard 1/2 without ordering
    let pvShard = buildRunPlan(cfg = cfg, selection = sel,
                               shardK = 1, shardN = 2)
    # Shard 1/2 with omRecentFail ordering
    let pvShardOrder = buildRunPlan(cfg = cfg, selection = sel,
                                    shardK = 1, shardN = 2,
                                    order = omRecentFail)

    # Same membership — ordering is a permutation, not a filter
    check pathSetOf(pvShard) == pathSetOf(pvShardOrder)
    check pvShard.runnable == pvShardOrder.runnable

  test "shard×order: both shards together still cover all eps (disjoint, complete)":
    let root = makeTempRoot("c4_shard_order_complete")
    defer: cleanupDir(root)

    let names = ["test_a", "test_b", "test_c", "test_d"]
    for n in names:
      writeFixture(root, "tests/unit/" & n & ".nim")

    # Seed a ledger so ordering has real data to work with
    let stateDir = root / ".crisol"
    createDir(stateDir)
    seedLedger(stateDir, [
      ("tests/unit/test_a.nim", 2000i64, 100i64, "exitNonZero"),
      ("tests/unit/test_b.nim", 1000i64, 200i64, "passed"),
    ])

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    let pv1 = buildRunPlan(cfg = cfg, selection = sel,
                           shardK = 1, shardN = 2, order = omRecentFail)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel,
                           shardK = 2, shardN = 2, order = omRecentFail)

    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    # Disjoint
    check disjoint(s1, s2)
    # Complete: union covers all 4 eps
    check s1.len + s2.len == names.len
    for n in names:
      check ("tests/unit/" & n & ".nim") in (s1 + s2)

# ---------------------------------------------------------------------------
# Suite: omRecentFail ordering in plan
# ---------------------------------------------------------------------------

suite "buildRunPlan — C4 omRecentFail ordering":

  test "ep with most recent fail row appears first in plan":
    let root = makeTempRoot("c4_rf_plan")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_b.nim")
    writeFixture(root, "tests/unit/test_c.nim")

    let stateDir = root / ".crisol"
    createDir(stateDir)
    # test_c failed most recently
    seedLedger(stateDir, [
      ("tests/unit/test_a.nim", 1000i64, 100i64, "exitNonZero"),
      ("tests/unit/test_b.nim", 3000i64, 100i64, "exitNonZero"),
      ("tests/unit/test_c.nim", 2000i64, 100i64, "passed"),
    ])

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    let pv = buildRunPlan(cfg = cfg, selection = sel, order = omRecentFail)
    let paths = pathsOf(pv)

    # test_b failed at t=3000 (most recent), test_a at t=1000, test_c never failed
    check paths[0] == "tests/unit/test_b.nim"
    check paths[1] == "tests/unit/test_a.nim"
    check paths[2] == "tests/unit/test_c.nim"

# ---------------------------------------------------------------------------
# Suite: omDuration ordering in plan
# ---------------------------------------------------------------------------

suite "buildRunPlan — C4 omDuration ordering":

  test "ep with largest median duration appears first in plan":
    let root = makeTempRoot("c4_dur_plan")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_b.nim")
    writeFixture(root, "tests/unit/test_c.nim")

    let stateDir = root / ".crisol"
    createDir(stateDir)
    # test_b is slowest
    seedLedger(stateDir, [
      ("tests/unit/test_a.nim", 1000i64, 100i64, "passed"),
      ("tests/unit/test_b.nim", 1000i64, 9000i64, "passed"),
      ("tests/unit/test_c.nim", 1000i64, 500i64,  "passed"),
    ])

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    let pv = buildRunPlan(cfg = cfg, selection = sel, order = omDuration)
    let paths = pathsOf(pv)

    # descending: test_b(9000) > test_c(500) > test_a(100)
    check paths[0] == "tests/unit/test_b.nim"
    check paths[1] == "tests/unit/test_c.nim"
    check paths[2] == "tests/unit/test_a.nim"

when isMainModule:
  echo "test_c4_pipeline done"
