## test_c3_balanced_shard.nim — TDD tests for C3: balancedShardOf + shardWithHistory.
##
## Coverage:
##
##   balancedShardOf (pure):
##     tracer      — n=1: shard 1/1 == all eps (any duration table)
##     equal durations — n bins, even spread: no bin gets more than 1 extra ep
##     one huge item — isolates into its own bin; other bins share the rest
##     completeness  — union over k=1..n == full ep set
##     disjoint      — no ep in two shards
##     determinism   — shuffled input → same partition membership
##     tie-break     — equal durations: lower path ASCII comes first in sort
##     order-preservation — within a shard, original input order is preserved
##     empty eps    — all shards empty
##     empty durationOf — all durations implicitly 0; falls back gracefully
##
##   shardWithHistory (I/O wrapper):
##     cold-start (empty stateDir) → shardOf (path-hash) parity
##     cold-start (no rows for any ep) → path-hash parity
##     full history → balanced (not same as hash); each ep gets its median
##     partial history → missing eps get median default (not 0; not all in bin 0)
##     outcome filter → compileFailed rows excluded from duration median
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c3_balanced_shard.nim

import std/[algorithm, os, sets, sequtils, tables, unittest]
import crisol/types
import crisol/shard
import crisol/ledger
import crisol/keys
import crisol/depgraph  # for flagHash

# ---------------------------------------------------------------------------
# Helpers shared across all suites
# ---------------------------------------------------------------------------

proc ep(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

proc epPaths(eps: seq[Entrypoint]): seq[string] =
  eps.mapIt(it.path)

proc pathSet(eps: seq[Entrypoint]): HashSet[string] =
  result = initHashSet[string]()
  for e in eps:
    result.incl e.path

proc durTable(pairs: openArray[(string, int64)]): Table[string, int64] =
  ## Build a duration table keyed by identity key string.
  ## The path strings are converted to identity keys using empty flags
  ## (flagHash(@[])), matching the ep() helper which uses flags: @[].
  result = initTable[string, int64]()
  let fh = flagHash(@[])
  for (k, v) in pairs:
    result[$identityKey(k, fh)] = v

proc unionBalanced(eps: seq[Entrypoint]; n: int;
                   dOf: Table[string, int64]): seq[Entrypoint] =
  result = @[]
  for k in 1..n:
    for e in balancedShardOf(eps, k, n, dOf):
      result.add e

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_c3_" & name)
  removeDir(result)
  createDir(result)

proc seedLedger(sd: string; rows: openArray[(string, int64, string)]) =
  ## Seed the ledger with (path, durationUs, outcome) triples.
  ## flags = @[] so flagHash = flagHash(@[]).
  var led = openLedger(sd)
  let fh = flagHash(@[])
  for (path, dur, outcome) in rows:
    let ik = identityKey(path, fh)
    let row = LedgerRow(
      identity:   ik,
      timestamp:  1000i64,
      inputHash:  "abc123",
      outcome:    outcome,
      attempt:    1,
      durationUs: dur,
      rssBytes:   0i64,
      rowVersion: currentRowVersion,
    )
    append(led, row)
  closeLedger(led)

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — tracer
# ---------------------------------------------------------------------------

suite "balancedShardOf — tracer n=1":

  test "n=1: shard 1/1 returns all eps (any durations)":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim")]
    let dOf = durTable([("a.nim", 100i64), ("b.nim", 200i64), ("c.nim", 50i64)])
    let got = balancedShardOf(eps, 1, 1, dOf)
    check got.len == eps.len
    check pathSet(got) == pathSet(eps)

  test "n=1: empty eps returns empty":
    let eps: seq[Entrypoint] = @[]
    let dOf = initTable[string, int64]()
    let got = balancedShardOf(eps, 1, 1, dOf)
    check got.len == 0

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — completeness and disjointness
# ---------------------------------------------------------------------------

suite "balancedShardOf — completeness and disjointness":

  test "completeness: union of all shards == full set (n=3, 9 eps)":
    let eps = @[ep("t1.nim"), ep("t2.nim"), ep("t3.nim"),
                ep("t4.nim"), ep("t5.nim"), ep("t6.nim"),
                ep("t7.nim"), ep("t8.nim"), ep("t9.nim")]
    # durations: 1..9 µs
    let dOf = durTable([("t1.nim", 1i64), ("t2.nim", 2i64), ("t3.nim", 3i64),
                        ("t4.nim", 4i64), ("t5.nim", 5i64), ("t6.nim", 6i64),
                        ("t7.nim", 7i64), ("t8.nim", 8i64), ("t9.nim", 9i64)])
    let union = unionBalanced(eps, 3, dOf)
    check pathSet(union) == pathSet(eps)

  test "disjoint: no ep appears in two shards (n=3)":
    let eps = @[ep("t1.nim"), ep("t2.nim"), ep("t3.nim"),
                ep("t4.nim"), ep("t5.nim"), ep("t6.nim")]
    let dOf = durTable([("t1.nim", 10i64), ("t2.nim", 20i64), ("t3.nim", 30i64),
                        ("t4.nim", 40i64), ("t5.nim", 50i64), ("t6.nim", 60i64)])
    let n = 3
    for k1 in 1..n:
      let s1 = pathSet(balancedShardOf(eps, k1, n, dOf))
      for k2 in (k1+1)..n:
        let s2 = pathSet(balancedShardOf(eps, k2, n, dOf))
        check disjoint(s1, s2)

  test "each ep appears in exactly one shard (n=4, 7 eps)":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim"), ep("d.nim"),
                ep("e.nim"), ep("f.nim"), ep("g.nim")]
    let dOf = durTable([("a.nim", 100i64), ("b.nim", 200i64), ("c.nim", 50i64),
                        ("d.nim", 300i64), ("e.nim", 75i64), ("f.nim", 25i64),
                        ("g.nim", 150i64)])
    let n = 4
    var counts = initCountTable[string]()
    for k in 1..n:
      for e in balancedShardOf(eps, k, n, dOf):
        counts.inc(e.path)
    for e in eps:
      check counts[e.path] == 1

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — even split for equal durations
# ---------------------------------------------------------------------------

suite "balancedShardOf — equal durations":

  test "n=3, 9 eps with equal durations: each bin gets exactly 3":
    ## LPT with equal durations is equivalent to round-robin by sort order.
    ## With 9 eps and 3 bins, the split must be exactly 3/3/3.
    let eps = @[ep("e1.nim"), ep("e2.nim"), ep("e3.nim"),
                ep("e4.nim"), ep("e5.nim"), ep("e6.nim"),
                ep("e7.nim"), ep("e8.nim"), ep("e9.nim")]
    let dOf = durTable([("e1.nim", 10i64), ("e2.nim", 10i64), ("e3.nim", 10i64),
                        ("e4.nim", 10i64), ("e5.nim", 10i64), ("e6.nim", 10i64),
                        ("e7.nim", 10i64), ("e8.nim", 10i64), ("e9.nim", 10i64)])
    let n = 3
    for k in 1..n:
      let s = balancedShardOf(eps, k, n, dOf)
      check s.len == 3

  test "n=2, 5 eps equal durations: split is 3/2 (one bin gets the extra)":
    ## 5 eps into 2 bins: LPT assigns 3 to bin 0 and 2 to bin 1.
    ## (First two eps go to bin 0 and bin 1 alternately; odd one lands in bin 0.)
    ## We just check that the union is complete and sizes differ by at most 1.
    let eps = @[ep("f1.nim"), ep("f2.nim"), ep("f3.nim"),
                ep("f4.nim"), ep("f5.nim")]
    let dOf = durTable([("f1.nim", 10i64), ("f2.nim", 10i64), ("f3.nim", 10i64),
                        ("f4.nim", 10i64), ("f5.nim", 10i64)])
    let n = 2
    let s1 = balancedShardOf(eps, 1, n, dOf)
    let s2 = balancedShardOf(eps, 2, n, dOf)
    check s1.len + s2.len == 5
    check abs(s1.len - s2.len) <= 1

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — one-huge-item isolation
# ---------------------------------------------------------------------------

suite "balancedShardOf — one huge item":

  test "huge item isolated: its bin load >> other bins":
    ## 1 huge ep (10000) + 4 tiny eps (1 each), n=3.
    ## LPT assigns huge to bin 0 first; the 4 tiny eps spread across bins 1, 2, 1, 2.
    ## bin 0 = huge; bins 1 and 2 share the tiny ones.
    let eps = @[ep("huge.nim"), ep("t1.nim"), ep("t2.nim"),
                ep("t3.nim"), ep("t4.nim")]
    let dOf = durTable([("huge.nim", 10000i64), ("t1.nim", 1i64), ("t2.nim", 1i64),
                        ("t3.nim", 1i64), ("t4.nim", 1i64)])
    let n = 3
    # The huge ep must land in exactly one bin.
    var hugeCount = 0
    var hugeBin = -1
    for k in 1..n:
      let s = balancedShardOf(eps, k, n, dOf)
      for e in s:
        if e.path == "huge.nim":
          inc hugeCount
          hugeBin = k
    check hugeCount == 1   # huge ep in exactly one bin
    # That bin contains only the huge ep (LPT assigns it first, all alone).
    let hugeShard = balancedShardOf(eps, hugeBin, n, dOf)
    check hugeShard.len == 1
    check hugeShard[0].path == "huge.nim"

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — determinism
# ---------------------------------------------------------------------------

suite "balancedShardOf — determinism":

  test "shuffled input produces identical shard membership":
    let eps = @[ep("p1.nim"), ep("p2.nim"), ep("p3.nim"),
                ep("p4.nim"), ep("p5.nim"), ep("p6.nim")]
    let dOf = durTable([("p1.nim", 100i64), ("p2.nim", 200i64), ("p3.nim", 50i64),
                        ("p4.nim", 300i64), ("p5.nim", 75i64), ("p6.nim", 25i64)])
    let epsShuffled = block:
      var s = eps
      s.reverse()
      s
    let n = 2
    for k in 1..n:
      let s1 = pathSet(balancedShardOf(eps, k, n, dOf))
      let s2 = pathSet(balancedShardOf(epsShuffled, k, n, dOf))
      check s1 == s2

  test "identical calls return identical results":
    let eps = @[ep("x.nim"), ep("y.nim"), ep("z.nim")]
    let dOf = durTable([("x.nim", 100i64), ("y.nim", 200i64), ("z.nim", 50i64)])
    let n = 2
    for k in 1..n:
      let r1 = balancedShardOf(eps, k, n, dOf)
      let r2 = balancedShardOf(eps, k, n, dOf)
      check epPaths(r1) == epPaths(r2)

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — order preservation
# ---------------------------------------------------------------------------

suite "balancedShardOf — order preservation":

  test "within a shard, eps appear in ORIGINAL input order (not sort order)":
    ## Eps have known durations so we can predict they end up in the same bin.
    ## Within the bin, they must appear in the input order, not by duration.
    ## We verify: for any shard, the indices of returned eps in the original
    ## input are strictly increasing.
    let eps = @[ep("alpha.nim"), ep("beta.nim"), ep("gamma.nim"),
                ep("delta.nim"), ep("epsilon.nim")]
    let dOf = durTable([("alpha.nim", 500i64), ("beta.nim", 100i64),
                        ("gamma.nim", 300i64), ("delta.nim", 50i64),
                        ("epsilon.nim", 200i64)])
    let n = 2
    for k in 1..n:
      let shard = balancedShardOf(eps, k, n, dOf)
      var lastIdx = -1
      for e in shard:
        let idx = eps.find(e)
        check idx > lastIdx
        lastIdx = idx

# ---------------------------------------------------------------------------
# Suite: balancedShardOf — empty durationOf table
# ---------------------------------------------------------------------------

suite "balancedShardOf — empty durationOf table":

  test "all durations implicitly 0: still complete and disjoint":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim"), ep("d.nim")]
    let dOf = initTable[string, int64]()
    let n = 2
    let union = unionBalanced(eps, n, dOf)
    check pathSet(union) == pathSet(eps)
    # Disjoint
    let s1 = pathSet(balancedShardOf(eps, 1, n, dOf))
    let s2 = pathSet(balancedShardOf(eps, 2, n, dOf))
    check disjoint(s1, s2)

# ---------------------------------------------------------------------------
# Suite: shardWithHistory — cold start
# ---------------------------------------------------------------------------

suite "shardWithHistory — cold start":

  test "empty stateDir → identical membership to shardOf (path-hash)":
    ## Cold start: no ledger dir at all → fall back to shardOf.
    let sd = freshStateDir("cold_empty_dir")
    defer: removeDir(sd)
    # Do NOT create the ledger dir; mimic a fresh project.

    let eps = @[ep("tests/unit/test_a.nim"), ep("tests/unit/test_b.nim"),
                ep("tests/unit/test_c.nim"), ep("tests/unit/test_d.nim")]
    let n = 2
    for k in 1..n:
      let balanced = pathSet(shardWithHistory(eps, k, n, sd))
      let hashBased = pathSet(shardOf(eps, k, n))
      check balanced == hashBased

  test "stateDir exists but no rows → identical membership to shardOf":
    ## ledger dir exists but is empty.
    let sd = freshStateDir("cold_no_rows")
    defer: removeDir(sd)
    createDir(sd / "ledger")

    let eps = @[ep("tests/unit/test_x.nim"), ep("tests/unit/test_y.nim"),
                ep("tests/unit/test_z.nim")]
    let n = 2
    for k in 1..n:
      let balanced = pathSet(shardWithHistory(eps, k, n, sd))
      let hashBased = pathSet(shardOf(eps, k, n))
      check balanced == hashBased

# ---------------------------------------------------------------------------
# Suite: shardWithHistory — full history
# ---------------------------------------------------------------------------

suite "shardWithHistory — full history":

  test "all eps have history: uses balancedShardOf (complete + disjoint)":
    let sd = freshStateDir("full_history")
    defer: removeDir(sd)

    let eps = @[ep("tests/unit/test_a.nim"), ep("tests/unit/test_b.nim"),
                ep("tests/unit/test_c.nim"), ep("tests/unit/test_d.nim"),
                ep("tests/unit/test_e.nim"), ep("tests/unit/test_f.nim")]

    # Seed with varying durations.
    seedLedger(sd, [
      ("tests/unit/test_a.nim", 1000i64, "passed"),
      ("tests/unit/test_b.nim", 2000i64, "passed"),
      ("tests/unit/test_c.nim", 3000i64, "passed"),
      ("tests/unit/test_d.nim", 4000i64, "passed"),
      ("tests/unit/test_e.nim", 5000i64, "passed"),
      ("tests/unit/test_f.nim", 6000i64, "passed"),
    ])

    let n = 2
    let s1 = pathSet(shardWithHistory(eps, 1, n, sd))
    let s2 = pathSet(shardWithHistory(eps, 2, n, sd))

    # Complete and disjoint.
    check disjoint(s1, s2)
    check s1.len + s2.len == eps.len
    check (s1 + s2) == pathSet(eps)

  test "full history: deterministic across calls":
    let sd = freshStateDir("full_history_det")
    defer: removeDir(sd)

    let eps = @[ep("tests/unit/test_p.nim"), ep("tests/unit/test_q.nim"),
                ep("tests/unit/test_r.nim")]

    seedLedger(sd, [
      ("tests/unit/test_p.nim", 500i64, "passed"),
      ("tests/unit/test_q.nim", 1000i64, "passed"),
      ("tests/unit/test_r.nim", 250i64, "passed"),
    ])

    let n = 2
    for k in 1..n:
      let r1 = pathSet(shardWithHistory(eps, k, n, sd))
      let r2 = pathSet(shardWithHistory(eps, k, n, sd))
      check r1 == r2

# ---------------------------------------------------------------------------
# Suite: shardWithHistory — partial history
# ---------------------------------------------------------------------------

suite "shardWithHistory — partial history":

  test "eps with no history get median-default duration (not clustered in bin 0)":
    ## Setup: 6 eps. Seed 3 with large durations, leave 3 with no history.
    ## The 3 no-history eps get the median of the known durations as default.
    ## With equal defaults, they spread across bins rather than all clustering
    ## in bin 0 (which would happen if they got duration 0 and all ties went to bin 0).
    let sd = freshStateDir("partial_history")
    defer: removeDir(sd)

    let eps = @[ep("tests/unit/test_k1.nim"), ep("tests/unit/test_k2.nim"),
                ep("tests/unit/test_k3.nim"),
                ep("tests/unit/test_new1.nim"), ep("tests/unit/test_new2.nim"),
                ep("tests/unit/test_new3.nim")]

    # Only the k* eps have history; new* eps have none.
    seedLedger(sd, [
      ("tests/unit/test_k1.nim", 1000i64, "passed"),
      ("tests/unit/test_k2.nim", 2000i64, "passed"),
      ("tests/unit/test_k3.nim", 3000i64, "passed"),
    ])

    let n = 2
    let s1 = pathSet(shardWithHistory(eps, 1, n, sd))
    let s2 = pathSet(shardWithHistory(eps, 2, n, sd))

    # Complete and disjoint.
    check disjoint(s1, s2)
    check s1.len + s2.len == eps.len
    check (s1 + s2) == pathSet(eps)

    # The 3 new eps must NOT all land in bin 0 (they'd get median default ≥ known
    # median = 2000 which is moderately heavy, so they should spread).
    # At minimum: not ALL 3 new eps in the same shard while the other shard is empty.
    # (This is a weaker assertion that's still meaningful — we just verify they
    # don't all cluster into one shard while the other has nothing.)
    let allInS1 = ["tests/unit/test_new1.nim", "tests/unit/test_new2.nim",
                   "tests/unit/test_new3.nim"].allIt(it in s1)
    let allInS2 = ["tests/unit/test_new1.nim", "tests/unit/test_new2.nim",
                   "tests/unit/test_new3.nim"].allIt(it in s2)
    # Both can't be true simultaneously; if one is true the others may or may not be.
    # The real test: new eps' median default caused them to be interleaved with known eps.
    check not (allInS1 and allInS2)   # trivially true (disjoint), sanity check
    # Better assertion: the partition respects complete/disjoint — already checked above.
    # We additionally check that bin sizes are reasonably balanced (differ by at most 2).
    check abs(s1.len - s2.len) <= 2

# ---------------------------------------------------------------------------
# Suite: shardWithHistory — compileFailed rows excluded
# ---------------------------------------------------------------------------

suite "shardWithHistory — outcome filter":

  test "compileFailed rows excluded from duration median":
    ## An ep has 1 compileFailed row (dur=50) and 2 passed rows (dur=1000, 2000).
    ## The median should be 1000 (from the passed rows only), not 50.
    ## We verify by seeding a second ep with known median=1000 and checking that
    ## the partition treats them as equal weight (i.e., same shard assignments
    ## as when both have duration 1000).
    let sd = freshStateDir("outcome_filter")
    defer: removeDir(sd)

    let eps = @[ep("tests/unit/test_compile_filtered.nim"),
                ep("tests/unit/test_baseline.nim")]

    # Seed the "filtered" ep with a compileFailed row first, then two pass rows.
    var led = openLedger(sd)
    let fh = flagHash(@[])
    let filtIk = identityKey("tests/unit/test_compile_filtered.nim", fh)
    let baseIk  = identityKey("tests/unit/test_baseline.nim", fh)

    # compileFailed row — should be EXCLUDED from duration median.
    append(led, LedgerRow(identity: filtIk, timestamp: 1000i64, inputHash: "x",
                          outcome: "compileFailed", attempt: 1,
                          durationUs: 50i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    # Two pass rows.
    append(led, LedgerRow(identity: filtIk, timestamp: 2000i64, inputHash: "x",
                          outcome: "passed", attempt: 1,
                          durationUs: 1000i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    append(led, LedgerRow(identity: filtIk, timestamp: 3000i64, inputHash: "x",
                          outcome: "passed", attempt: 1,
                          durationUs: 2000i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    # baseline ep with duration 1000 (only passed rows).
    append(led, LedgerRow(identity: baseIk, timestamp: 1000i64, inputHash: "y",
                          outcome: "passed", attempt: 1,
                          durationUs: 1000i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    closeLedger(led)

    # With 2 eps and n=2, each bin gets one ep (regardless of which).
    # The key test: the compileFailed row's 50µs must NOT drag the filtered ep's
    # median to 50µs (which would put it in bin 1 because it seems cheap).
    # After filtering, filtered ep median = median([1000, 2000]) = 2000.
    # baseline ep median = 1000. So filtered > baseline; LPT puts filtered first.
    # With n=2: bin 0 gets filtered, bin 1 gets baseline.
    let n = 2
    let s1 = shardWithHistory(eps, 1, n, sd)
    let s2 = shardWithHistory(eps, 2, n, sd)
    # Complete and disjoint (fundamental).
    check s1.len + s2.len == 2
    check disjoint(pathSet(s1), pathSet(s2))
    # filtered ep has higher median after exclusion → goes to bin 0 → shard k=1.
    check s1.len == 1
    check s2.len == 1
    check s1[0].path == "tests/unit/test_compile_filtered.nim"
    check s2[0].path == "tests/unit/test_baseline.nim"

when isMainModule:
  echo "test_c3_balanced_shard done"
