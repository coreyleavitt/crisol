## test_c4_order.nim — TDD tests for C4: history-based prioritization (--order).
##
## Coverage:
##
##   OrderMode enum + parseOrderMode:
##     valid strings → correct enum values
##     unknown string → raises ValueError
##
##   orderBy (pure):
##     omNone    — identity: output equals input in same sequence
##     omRecentFail — recent fails first (desc timestamp), never-failed after,
##                    lexicographic tie-break within each tier
##     omDuration   — longest first (desc), no-history last, lex tie-break
##     cold-start   — empty tables → lexicographic for omRecentFail/omDuration
##     permutation invariant — output is a permutation of input (all modes)
##
##   orderByHistory (I/O wrapper):
##     cold-start (no ledger rows) → lexicographic order
##     recent-fail: ep with newest fail row comes first
##     duration: ep with largest median duration comes first
##     failure outcomes identified correctly (exitNonZero/compileFailed/timedOut/signaled/spawnError)
##     non-failure outcomes excluded from lastFail table (passed)
##     compileFailed rows excluded from duration median (mirrors C3 shard logic)
##
##   buildRunPlan wiring:
##     omNone (default) → byte-for-byte parity with no order param (existing tests pass)
##     order applied after shard: shard membership unchanged, sequence changed
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c4_order.nim

import std/[algorithm, os, sequtils, sets, tables, unittest]
import crisol/types
import crisol/order
import crisol/ledger
import crisol/keys
import crisol/depgraph  # for flagHash

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ep(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

proc epPaths(eps: seq[Entrypoint]): seq[string] =
  eps.mapIt(it.path)

proc pathSet(eps: seq[Entrypoint]): HashSet[string] =
  result = initHashSet[string]()
  for e in eps:
    result.incl e.path

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_c4_" & name)
  removeDir(result)
  createDir(result)

proc seedLedger(sd: string; rows: openArray[(string, int64, int64, string)]) =
  ## Seed ledger with (path, timestamp, durationUs, outcome) quads.
  ## flags = @[] so flagHash = flagHash(@[]).
  var led = openLedger(sd)
  let fh = flagHash(@[])
  for (path, ts, dur, outcome) in rows:
    let ik = identityKey(path, fh)
    let row = LedgerRow(
      identity:   ik,
      timestamp:  ts,
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
# Suite: parseOrderMode
# ---------------------------------------------------------------------------

suite "parseOrderMode":

  test "recent-fail → omRecentFail":
    check parseOrderMode("recent-fail") == omRecentFail

  test "duration → omDuration":
    check parseOrderMode("duration") == omDuration

  test "none → omNone":
    check parseOrderMode("none") == omNone

  test "unknown value → ValueError":
    var raised = false
    try:
      discard parseOrderMode("bogus")
    except ValueError:
      raised = true
    check raised

  test "empty string → ValueError":
    var raised = false
    try:
      discard parseOrderMode("")
    except ValueError:
      raised = true
    check raised

  test "case-sensitive: 'None' → ValueError (not same as 'none')":
    var raised = false
    try:
      discard parseOrderMode("None")
    except ValueError:
      raised = true
    check raised

# ---------------------------------------------------------------------------
# Suite: orderBy — omNone (identity)
# ---------------------------------------------------------------------------

suite "orderBy — omNone identity":

  test "omNone: empty input → empty output":
    let eps: seq[Entrypoint] = @[]
    let got = orderBy(eps, omNone,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check got.len == 0

  test "omNone: single ep → same single ep":
    let eps = @[ep("tests/unit/test_a.nim")]
    let got = orderBy(eps, omNone,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check epPaths(got) == epPaths(eps)

  test "omNone: multiple eps → same order as input":
    let eps = @[ep("z.nim"), ep("a.nim"), ep("m.nim")]
    let got = orderBy(eps, omNone,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check epPaths(got) == @["z.nim", "a.nim", "m.nim"]

  test "omNone: permutation invariant — same set as input":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim"), ep("d.nim")]
    let got = orderBy(eps, omNone,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check pathSet(got) == pathSet(eps)
    check got.len == eps.len

# ---------------------------------------------------------------------------
# Suite: orderBy — omRecentFail
# ---------------------------------------------------------------------------

suite "orderBy — omRecentFail":

  proc failTable(pairs: openArray[(string, int64)]): Table[string, int64] =
    result = initTable[string, int64]()
    for (k, v) in pairs: result[k] = v

  proc durTable(pairs: openArray[(string, int64)]): Table[string, int64] =
    result = initTable[string, int64]()
    for (k, v) in pairs: result[k] = v

  test "cold-start (empty tables) → lexicographic path order":
    let eps = @[ep("c.nim"), ep("a.nim"), ep("b.nim")]
    let got = orderBy(eps, omRecentFail,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check epPaths(got) == @["a.nim", "b.nim", "c.nim"]

  test "more recent fail timestamp comes first":
    # ep_b failed at t=2000, ep_a failed at t=1000 → b before a
    let eps = @[ep("ep_a.nim"), ep("ep_b.nim")]
    let lastFail = failTable([("ep_a.nim", 1000i64), ("ep_b.nim", 2000i64)])
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    check epPaths(got) == @["ep_b.nim", "ep_a.nim"]

  test "never-failed eps come after all eps with failures":
    let eps = @[ep("no_fail.nim"), ep("has_fail.nim"), ep("also_no.nim")]
    let lastFail = failTable([("has_fail.nim", 5000i64)])
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    # has_fail first; then no_fail and also_no in lex order
    check got[0].path == "has_fail.nim"
    check got[1].path == "also_no.nim"
    check got[2].path == "no_fail.nim"

  test "tie-break by lexicographic path within same failure tier":
    # Two eps with same fail timestamp → sorted lexicographically
    let eps = @[ep("z_test.nim"), ep("a_test.nim")]
    let lastFail = failTable([("z_test.nim", 1000i64), ("a_test.nim", 1000i64)])
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    check epPaths(got) == @["a_test.nim", "z_test.nim"]

  test "never-failed eps tie-broken lexicographically":
    let eps = @[ep("z.nim"), ep("a.nim"), ep("m.nim")]
    let lastFail = initTable[string, int64]()  # none have failed
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    check epPaths(got) == @["a.nim", "m.nim", "z.nim"]

  test "permutation invariant":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim")]
    let lastFail = failTable([("b.nim", 2000i64)])
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    check pathSet(got) == pathSet(eps)
    check got.len == eps.len

  test "multiple eps with failures then multiple without":
    # Three with failures (different timestamps), two without
    let eps = @[ep("no1.nim"), ep("old_fail.nim"), ep("no2.nim"),
                ep("new_fail.nim"), ep("mid_fail.nim")]
    let lastFail = failTable([
      ("old_fail.nim", 1000i64),
      ("new_fail.nim", 3000i64),
      ("mid_fail.nim", 2000i64),
    ])
    let got = orderBy(eps, omRecentFail, lastFail, initTable[string, int64]())
    # Fails descending by time: new_fail(3000) > mid_fail(2000) > old_fail(1000)
    check got[0].path == "new_fail.nim"
    check got[1].path == "mid_fail.nim"
    check got[2].path == "old_fail.nim"
    # Never-failed in lex order: no1 < no2
    check got[3].path == "no1.nim"
    check got[4].path == "no2.nim"

# ---------------------------------------------------------------------------
# Suite: orderBy — omDuration
# ---------------------------------------------------------------------------

suite "orderBy — omDuration":

  proc failTable(pairs: openArray[(string, int64)]): Table[string, int64] =
    result = initTable[string, int64]()
    for (k, v) in pairs: result[k] = v

  proc durTable(pairs: openArray[(string, int64)]): Table[string, int64] =
    result = initTable[string, int64]()
    for (k, v) in pairs: result[k] = v

  test "cold-start (empty tables) → lexicographic path order":
    let eps = @[ep("c.nim"), ep("a.nim"), ep("b.nim")]
    let got = orderBy(eps, omDuration,
                      initTable[string, int64](),
                      initTable[string, int64]())
    check epPaths(got) == @["a.nim", "b.nim", "c.nim"]

  test "longer duration comes first (descending)":
    let eps = @[ep("fast.nim"), ep("slow.nim")]
    let medDur = durTable([("fast.nim", 100i64), ("slow.nim", 5000i64)])
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    check epPaths(got) == @["slow.nim", "fast.nim"]

  test "no-history eps sort last (treated as 0)":
    let eps = @[ep("no_hist.nim"), ep("has_hist.nim")]
    let medDur = durTable([("has_hist.nim", 100i64)])
    # no_hist has no entry → treated as 0 → comes after has_hist
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    check got[0].path == "has_hist.nim"
    check got[1].path == "no_hist.nim"

  test "no-history eps tie-broken lexicographically":
    let eps = @[ep("z_no.nim"), ep("a_no.nim"), ep("m_no.nim")]
    let medDur = initTable[string, int64]()
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    check epPaths(got) == @["a_no.nim", "m_no.nim", "z_no.nim"]

  test "tie-break by lex path when durations equal":
    let eps = @[ep("z.nim"), ep("a.nim")]
    let medDur = durTable([("z.nim", 1000i64), ("a.nim", 1000i64)])
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    check epPaths(got) == @["a.nim", "z.nim"]

  test "permutation invariant":
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim")]
    let medDur = durTable([("a.nim", 300i64), ("c.nim", 500i64)])
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    check pathSet(got) == pathSet(eps)
    check got.len == eps.len

  test "mixed: some with history (descending) then no-history (lex)":
    let eps = @[ep("no_a.nim"), ep("slow.nim"), ep("no_b.nim"), ep("fast.nim")]
    let medDur = durTable([("slow.nim", 5000i64), ("fast.nim", 100i64)])
    let got = orderBy(eps, omDuration, initTable[string, int64](), medDur)
    # slow first, fast second (desc duration), then no_a < no_b (lex, no history → 0)
    check got[0].path == "slow.nim"
    check got[1].path == "fast.nim"
    check got[2].path == "no_a.nim"
    check got[3].path == "no_b.nim"

# ---------------------------------------------------------------------------
# Suite: orderByHistory (I/O wrapper)
# ---------------------------------------------------------------------------

suite "orderByHistory — I/O wrapper":

  test "cold-start (empty stateDir, omRecentFail) → lexicographic order":
    let sd = freshStateDir("io_cold_rf")
    defer: removeDir(sd)
    let eps = @[ep("z.nim"), ep("a.nim"), ep("m.nim")]
    let got = orderByHistory(eps, omRecentFail, sd)
    check epPaths(got) == @["a.nim", "m.nim", "z.nim"]

  test "cold-start (empty stateDir, omDuration) → lexicographic order":
    let sd = freshStateDir("io_cold_dur")
    defer: removeDir(sd)
    let eps = @[ep("z.nim"), ep("a.nim"), ep("m.nim")]
    let got = orderByHistory(eps, omDuration, sd)
    check epPaths(got) == @["a.nim", "m.nim", "z.nim"]

  test "omNone ignores ledger entirely → identity":
    let sd = freshStateDir("io_none")
    defer: removeDir(sd)
    let eps = @[ep("z.nim"), ep("a.nim"), ep("m.nim")]
    seedLedger(sd, [
      ("a.nim", 1000i64, 100i64, "exitNonZero"),
    ])
    let got = orderByHistory(eps, omNone, sd)
    check epPaths(got) == @["z.nim", "a.nim", "m.nim"]

  test "omRecentFail: ep with newest fail row comes first":
    let sd = freshStateDir("io_rf_newest")
    defer: removeDir(sd)
    let eps = @[ep("ep_a.nim"), ep("ep_b.nim"), ep("ep_c.nim")]
    # ep_b failed most recently
    seedLedger(sd, [
      ("ep_a.nim", 1000i64, 500i64, "exitNonZero"),
      ("ep_b.nim", 3000i64, 500i64, "exitNonZero"),
      ("ep_c.nim", 2000i64, 500i64, "exitNonZero"),
    ])
    let got = orderByHistory(eps, omRecentFail, sd)
    check got[0].path == "ep_b.nim"
    check got[1].path == "ep_c.nim"
    check got[2].path == "ep_a.nim"

  test "omRecentFail: 'passed' outcome NOT counted as failure":
    let sd = freshStateDir("io_rf_pass_excluded")
    defer: removeDir(sd)
    let eps = @[ep("ep_a.nim"), ep("ep_b.nim")]
    # ep_a has only passed rows → should NOT appear in lastFail
    # ep_b has a fail row → should come first
    seedLedger(sd, [
      ("ep_a.nim", 5000i64, 500i64, "passed"),    # recent but passed → not counted
      ("ep_b.nim", 1000i64, 500i64, "exitNonZero"),  # older fail → still a fail
    ])
    let got = orderByHistory(eps, omRecentFail, sd)
    # ep_b has a failure, ep_a does not → ep_b first
    check got[0].path == "ep_b.nim"
    check got[1].path == "ep_a.nim"

  test "omRecentFail: all failure outcomes recognized":
    ## exitNonZero, compileFailed, timedOut, signaled, spawnError all count as failures
    let sd = freshStateDir("io_rf_all_outcomes")
    defer: removeDir(sd)
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim"), ep("d.nim"), ep("e.nim")]
    # Each has a different failure outcome; timestamps differ so order is deterministic
    seedLedger(sd, [
      ("a.nim", 1000i64, 100i64, "exitNonZero"),
      ("b.nim", 2000i64, 100i64, "compileFailed"),
      ("c.nim", 3000i64, 100i64, "timedOut"),
      ("d.nim", 4000i64, 100i64, "signaled"),
      ("e.nim", 5000i64, 100i64, "spawnError"),
    ])
    let got = orderByHistory(eps, omRecentFail, sd)
    # All have failures; ordered by timestamp desc: e > d > c > b > a
    check got[0].path == "e.nim"
    check got[1].path == "d.nim"
    check got[2].path == "c.nim"
    check got[3].path == "b.nim"
    check got[4].path == "a.nim"

  test "omDuration: ep with largest median duration comes first":
    let sd = freshStateDir("io_dur_largest")
    defer: removeDir(sd)
    let eps = @[ep("fast.nim"), ep("slow.nim"), ep("mid.nim")]
    seedLedger(sd, [
      ("fast.nim", 1000i64, 100i64, "passed"),
      ("slow.nim", 1000i64, 9000i64, "passed"),
      ("mid.nim",  1000i64, 500i64,  "passed"),
    ])
    let got = orderByHistory(eps, omDuration, sd)
    check got[0].path == "slow.nim"
    check got[1].path == "mid.nim"
    check got[2].path == "fast.nim"

  test "omDuration: compileFailed rows excluded from duration median":
    ## An ep has 1 compileFailed row (dur=50) and 2 passed rows (dur=1000, 2000).
    ## Median should be 1000 from passed rows only (mirrors C3 shard logic).
    let sd = freshStateDir("io_dur_compile_excluded")
    defer: removeDir(sd)
    let eps = @[ep("filtered.nim"), ep("baseline.nim")]
    var led = openLedger(sd)
    let fh = flagHash(@[])
    let filtIk = identityKey("filtered.nim", fh)
    let baseIk  = identityKey("baseline.nim", fh)
    # compileFailed row (should be excluded from median)
    append(led, LedgerRow(identity: filtIk, timestamp: 1000i64, inputHash: "x",
                          outcome: "compileFailed", attempt: 1,
                          durationUs: 50i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    # Two pass rows
    append(led, LedgerRow(identity: filtIk, timestamp: 2000i64, inputHash: "x",
                          outcome: "passed", attempt: 1,
                          durationUs: 1000i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    append(led, LedgerRow(identity: filtIk, timestamp: 3000i64, inputHash: "x",
                          outcome: "passed", attempt: 1,
                          durationUs: 2000i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    # baseline has median 500 (below filtered's true median of 1000 after exclusion)
    append(led, LedgerRow(identity: baseIk, timestamp: 1000i64, inputHash: "y",
                          outcome: "passed", attempt: 1,
                          durationUs: 500i64, rssBytes: 0i64, rowVersion: currentRowVersion))
    closeLedger(led)
    # After excluding compileFailed: filtered median = median([1000, 2000]) = 2000
    # baseline median = 500 → filtered > baseline → filtered first
    let got = orderByHistory(eps, omDuration, sd)
    check got[0].path == "filtered.nim"
    check got[1].path == "baseline.nim"

  test "permutation invariant for all modes":
    let sd = freshStateDir("io_perm")
    defer: removeDir(sd)
    let eps = @[ep("a.nim"), ep("b.nim"), ep("c.nim")]
    seedLedger(sd, [
      ("a.nim", 1000i64, 200i64, "exitNonZero"),
      ("b.nim", 2000i64, 500i64, "passed"),
    ])
    for mode in [omNone, omRecentFail, omDuration]:
      let got = orderByHistory(eps, mode, sd)
      check pathSet(got) == pathSet(eps)
      check got.len == eps.len

when isMainModule:
  echo "test_c4_order done"
