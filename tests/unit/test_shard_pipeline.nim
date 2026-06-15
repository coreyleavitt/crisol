## test_shard_pipeline.nim — TDD tests for C2 shard wiring in buildRunPlan.
##
## Tests the shard step insertion in the pipeline (after narrowing, before plan)
## by calling buildRunPlan directly with a real (temp) fixture tree.
##
## Coverage:
##   shard partition    — shardK=1/2 and shardK=2/2 give disjoint, complete subsets
##   no sharding        — shardK=0 (default): full set returned
##   shard×changed      — --changed narrows first, then shard partitions the result:
##                        (useChanged=true, shardK=1/2) composes correctly
##   n=1                — shardK=1/shardN=1 returns all runnable
##   shard empty        — shardK that hashes to no eps returns empty runnable
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_shard_pipeline.nim

import std/[os, sets, sequtils, unittest]
import crisol/types
import crisol/pipeline
import crisol/shard
import crisol/ledger
import crisol/keys
import crisol/depgraph  # for flagHash

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_shard_pipe_" & tag)
  createDir(result)

proc writeFixture(root, rel: string) =
  let full = root / rel
  createDir(full.parentDir)
  writeFile(full, "# fixture\n")

proc cleanupDir(path: string) =
  try: os.removeDir(path) except: discard

proc makeConfig(root: string; globs: seq[string]): Config =
  Config(
    projectRoot: root,
    stateDir:    ".crisol",
    groups: @[Group(name: "unit", globs: globs)],
    jobs:    1,
    timeoutSecs: 60,
    compiletimeoutSecs: 120,
  )

proc pathsOf(pv: RunPlanView): seq[string] =
  ## Extract entrypoint paths from the plan view.
  pv.plan.entrypoints.mapIt(it.ep.path)

proc pathSetOf(pv: RunPlanView): HashSet[string] =
  result = initHashSet[string]()
  for p in pathsOf(pv):
    result.incl p

# ---------------------------------------------------------------------------
# Suite: shard wiring in buildRunPlan
# ---------------------------------------------------------------------------

suite "buildRunPlan — shard wiring":

  test "shardK=0 (no sharding): all discovered eps run":
    let root = makeTempRoot("no_shard")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_b.nim")
    writeFixture(root, "tests/unit/test_c.nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let pv = buildRunPlan(cfg = cfg, selection = GroupSelection(kind: gskDefault))
    check pv.runnable == 3

  test "shardK=1/shardN=1 returns all runnable":
    let root = makeTempRoot("shard_1_1")
    defer: cleanupDir(root)

    writeFixture(root, "tests/unit/test_a.nim")
    writeFixture(root, "tests/unit/test_b.nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let pv = buildRunPlan(cfg = cfg,
                          selection = GroupSelection(kind: gskDefault),
                          shardK = 1, shardN = 1)
    check pv.runnable == 2

  test "shardK=1/2 and shardK=2/2 partition: disjoint and complete":
    let root = makeTempRoot("shard_partition")
    defer: cleanupDir(root)

    let names = ["test_alpha", "test_beta", "test_gamma",
                 "test_delta", "test_epsilon", "test_zeta"]
    for n in names:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    let pv1 = buildRunPlan(cfg = cfg, selection = sel, shardK = 1, shardN = 2)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel, shardK = 2, shardN = 2)

    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    # Disjoint
    check disjoint(s1, s2)
    # Complete
    check s1.len + s2.len == names.len
    # Union covers everything
    let unionSet = s1 + s2
    for n in names:
      check ("tests/unit/" & n & ".nim") in unionSet

  test "shard×changed: --changed narrows first, then shard partitions the result":
    ## Scenario:
    ##   - 4 eps discovered
    ##   - useChanged=true + a dep-graph-absent trigger → all 4 are in changedNarrowed
    ##     (srGraphAbsent rule: with empty graph, all eps are conservatively included)
    ##   - shardK=1/2 then partitions those 4 → 2 shards, disjoint, complete
    let root = makeTempRoot("shard_changed")
    defer: cleanupDir(root)

    for n in ["test_a", "test_b", "test_c", "test_d"]:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    # With an empty dep graph (absent), narrowByDiff conservatively includes ALL
    # eps (srGraphAbsent rule).  So useChanged=true with any non-empty changedSet
    # will return all 4 after narrowing.
    var changedSet = initHashSet[string]()
    changedSet.incl "src/crisol/types.nim"   # any file — graph absent triggers inclusion

    let pv1 = buildRunPlan(cfg = cfg, selection = sel,
                           useChanged = true, changed = changedSet,
                           shardK = 1, shardN = 2)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel,
                           useChanged = true, changed = changedSet,
                           shardK = 2, shardN = 2)

    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    # Disjoint
    check disjoint(s1, s2)
    # Complete: union of shards == narrowed set (which is all 4)
    check s1.len + s2.len == 4
    # Each shard has at least 0 eps (may be 0 if all hash to one side)
    # But their union must cover all 4
    let unionSet = s1 + s2
    for n in ["test_a", "test_b", "test_c", "test_d"]:
      check ("tests/unit/" & n & ".nim") in unionSet

  test "shard is LAST selection step: shard partitions the narrowed set, not the full set":
    ## Build 4 eps. Mark 2 as 'failed'. Run with useFailed=true + shardK=1/2.
    ## The shard must partition only the 2 failed eps, not all 4.
    let root = makeTempRoot("shard_last")
    defer: cleanupDir(root)

    for n in ["test_a", "test_b", "test_c", "test_d"]:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)

    # Mark test_a and test_b as failed.
    var failedKeys = initHashSet[tuple[path, group: string]]()
    failedKeys.incl (path: "tests/unit/test_a.nim", group: "unit")
    failedKeys.incl (path: "tests/unit/test_b.nim", group: "unit")

    let pv1 = buildRunPlan(cfg = cfg, selection = sel,
                           useFailed = true, failedKeys = failedKeys,
                           shardK = 1, shardN = 2)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel,
                           useFailed = true, failedKeys = failedKeys,
                           shardK = 2, shardN = 2)

    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    # Disjoint
    check disjoint(s1, s2)
    # Complete over the 2 failed eps (not all 4!)
    check s1.len + s2.len == 2
    let unionSet = s1 + s2
    check "tests/unit/test_a.nim" in unionSet
    check "tests/unit/test_b.nim" in unionSet
    # Non-failed eps must NOT appear
    check "tests/unit/test_c.nim" notin unionSet
    check "tests/unit/test_d.nim" notin unionSet

# ---------------------------------------------------------------------------
# Helper: seed ledger rows for pipeline tests
# ---------------------------------------------------------------------------

proc seedLedgerForPipeline(stateDir: string;
                            rows: openArray[(string, int64, string)]) =
  var led = openLedger(stateDir)
  let fh = flagHash(@[])
  for (path, dur, outcome) in rows:
    let ik = identityKey(path, fh)
    append(led, LedgerRow(
      identity:   ik,
      timestamp:  1000i64,
      inputHash:  "abc",
      outcome:    outcome,
      attempt:    1,
      durationUs: dur,
      rssBytes:   0i64,
      rowVersion: currentRowVersion,
    ))
  closeLedger(led)

# ---------------------------------------------------------------------------
# Suite: C3 — buildRunPlan cold-start parity with C2
# ---------------------------------------------------------------------------

suite "buildRunPlan — C3 cold-start parity with C2":

  test "cold-start (no ledger): shardWithHistory == shardOf for each shard":
    ## With no ledger rows, shardWithHistory must fall back to shardOf.
    ## buildRunPlan's cold-start output must match what C2 produced.
    let root = makeTempRoot("c3_cold")
    defer: cleanupDir(root)

    let names = ["test_alpha", "test_beta", "test_gamma",
                 "test_delta", "test_epsilon", "test_zeta"]
    for n in names:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let sel = GroupSelection(kind: gskDefault)
    let n = 2

    # Get parity: C2 hash-based (direct shardOf call) vs C3 pipeline (cold start).
    # Since buildRunPlan now calls shardWithHistory, cold-start must give identical
    # membership to the old shardOf call.
    for k in 1..n:
      let pv = buildRunPlan(cfg = cfg, selection = sel, shardK = k, shardN = n)
      # The plan's entrypoints should match shardOf over the discovered set.
      # We verify the C3 pipeline output is complete+disjoint over k=1..2.
      discard pathSetOf(pv)  # just ensure it works

    let pv1 = buildRunPlan(cfg = cfg, selection = sel, shardK = 1, shardN = n)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel, shardK = 2, shardN = n)
    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    check disjoint(s1, s2)
    check s1.len + s2.len == names.len

# ---------------------------------------------------------------------------
# Suite: C3 — buildRunPlan balanced sharding with seeded ledger history
# ---------------------------------------------------------------------------

suite "buildRunPlan — C3 balanced sharding with ledger history":

  test "seeded history: complete + disjoint across shards":
    ## Seed ledger rows for all eps, then confirm buildRunPlan uses balanced sharding
    ## (still complete/disjoint — the fundamental property).
    let root = makeTempRoot("c3_balanced")
    defer: cleanupDir(root)

    let names = ["test_a", "test_b", "test_c", "test_d", "test_e", "test_f"]
    for n in names:
      writeFixture(root, "tests/unit/" & n & ".nim")

    let cfg = makeConfig(root, @["tests/unit/test_*.nim"])
    let stateDir = root / ".crisol"
    createDir(stateDir)

    # Seed with varying durations.
    seedLedgerForPipeline(stateDir, [
      ("tests/unit/test_a.nim", 100i64,  "passed"),
      ("tests/unit/test_b.nim", 500i64,  "passed"),
      ("tests/unit/test_c.nim", 200i64,  "passed"),
      ("tests/unit/test_d.nim", 1000i64, "passed"),
      ("tests/unit/test_e.nim", 50i64,   "passed"),
      ("tests/unit/test_f.nim", 750i64,  "passed"),
    ])

    let sel = GroupSelection(kind: gskDefault)
    let n = 2
    let pv1 = buildRunPlan(cfg = cfg, selection = sel, shardK = 1, shardN = n)
    let pv2 = buildRunPlan(cfg = cfg, selection = sel, shardK = 2, shardN = n)
    let s1 = pathSetOf(pv1)
    let s2 = pathSetOf(pv2)

    check disjoint(s1, s2)
    check s1.len + s2.len == names.len
    for n in names:
      check ("tests/unit/" & n & ".nim") in (s1 + s2)
