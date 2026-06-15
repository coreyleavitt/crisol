## test_shard.nim — TDD tests for C2: shardOf + parseShardSpec.
##
## Coverage:
##   shardOf:
##     tracer      — n=1: shard 1/1 == all eps
##     completeness — union of all shards == full ep set
##     disjoint    — no ep in two shards
##     stability   — shuffled input → same shard membership; recompute → identical
##     order-preservation — within a shard, input order is preserved
##     empty shards — n > eps.len: some shards empty, union still complete
##     single ep   — always lands in some shard; that shard contains exactly it
##     empty eps   — all shards empty, union empty
##
##   parseShardSpec:
##     valid parse  — "1/3", "2/3", "3/3" parse correctly
##     n==1         — "1/1" is valid
##     bad format   — no slash / extra slash → ValueError
##     non-integer  — "a/3", "1/b" → ValueError
##     n<1          — "1/0", "2/-1" → ValueError
##     k<1          — "0/3" → ValueError
##     k>n          — "4/3" → ValueError
##     k==n         — "3/3" valid
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_shard.nim

import std/[algorithm, sets, sequtils, tables, unittest]
import crisol/types
import crisol/shard
import crisol/keys
import crisol/depgraph

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

proc unionAllShards(eps: seq[Entrypoint]; n: int): seq[Entrypoint] =
  ## Collect all eps across all shards k=1..n (without deduplication).
  result = newSeq[Entrypoint]()
  for k in 1..n:
    for e in shardOf(eps, k, n):
      result.add e

proc shuffled(eps: seq[Entrypoint]): seq[Entrypoint] =
  ## Return eps in reverse order (deterministic "shuffle" for stability tests).
  result = eps
  result.reverse()

# ---------------------------------------------------------------------------
# Suite: shardOf — tracer
# ---------------------------------------------------------------------------

suite "shardOf — tracer n=1":

  test "n=1: shard 1/1 returns all entrypoints":
    let eps = @[ep("tests/a.nim"), ep("tests/b.nim"), ep("tests/c.nim")]
    let got = shardOf(eps, 1, 1)
    check got.len == eps.len
    check pathSet(got) == pathSet(eps)

  test "n=1: empty input returns empty":
    let eps: seq[Entrypoint] = @[]
    let got = shardOf(eps, 1, 1)
    check got.len == 0

# ---------------------------------------------------------------------------
# Suite: shardOf — completeness and disjointness
# ---------------------------------------------------------------------------

suite "shardOf — completeness and disjointness":

  test "completeness: union of all shards equals full set (n=3, 10 eps)":
    let eps = @[
      ep("tests/unit/test_a.nim"),
      ep("tests/unit/test_b.nim"),
      ep("tests/unit/test_c.nim"),
      ep("tests/unit/test_d.nim"),
      ep("tests/unit/test_e.nim"),
      ep("tests/integration/test_f.nim"),
      ep("tests/integration/test_g.nim"),
      ep("tests/integration/test_h.nim"),
      ep("tests/integration/test_i.nim"),
      ep("tests/integration/test_j.nim"),
    ]
    let unionEps = unionAllShards(eps, 3)
    # every ep appears at least once
    let unionSet = pathSet(unionEps)
    check unionSet == pathSet(eps)

  test "disjoint: no ep appears in two shards (n=3, 10 eps)":
    let eps = @[
      ep("tests/unit/test_a.nim"),
      ep("tests/unit/test_b.nim"),
      ep("tests/unit/test_c.nim"),
      ep("tests/unit/test_d.nim"),
      ep("tests/unit/test_e.nim"),
      ep("tests/integration/test_f.nim"),
      ep("tests/integration/test_g.nim"),
      ep("tests/integration/test_h.nim"),
      ep("tests/integration/test_i.nim"),
      ep("tests/integration/test_j.nim"),
    ]
    let n = 3
    for k1 in 1..n:
      let s1 = pathSet(shardOf(eps, k1, n))
      for k2 in (k1+1)..n:
        let s2 = pathSet(shardOf(eps, k2, n))
        check disjoint(s1, s2)

  test "completeness: each ep appears in exactly one shard (n=4, 7 eps)":
    let eps = @[
      ep("a.nim"), ep("b.nim"), ep("c.nim"), ep("d.nim"),
      ep("e.nim"), ep("f.nim"), ep("g.nim"),
    ]
    let n = 4
    var counts = initCountTable[string]()
    for k in 1..n:
      for e in shardOf(eps, k, n):
        counts.inc(e.path)
    for e in eps:
      check counts[e.path] == 1

# ---------------------------------------------------------------------------
# Suite: shardOf — stability
# ---------------------------------------------------------------------------

suite "shardOf — stability":

  test "shuffled input: same set of paths in each shard":
    let eps = @[
      ep("tests/unit/test_a.nim"),
      ep("tests/unit/test_b.nim"),
      ep("tests/unit/test_c.nim"),
      ep("tests/unit/test_d.nim"),
      ep("tests/unit/test_e.nim"),
    ]
    let epsShuffled = shuffled(eps)
    let n = 2
    for k in 1..n:
      let s1 = pathSet(shardOf(eps, k, n))
      let s2 = pathSet(shardOf(epsShuffled, k, n))
      check s1 == s2

  test "determinism: identical calls return identical results":
    let eps = @[
      ep("tests/unit/test_x.nim"),
      ep("tests/unit/test_y.nim"),
      ep("tests/integration/test_z.nim"),
    ]
    let n = 2
    for k in 1..n:
      let r1 = shardOf(eps, k, n)
      let r2 = shardOf(eps, k, n)
      check epPaths(r1) == epPaths(r2)

# ---------------------------------------------------------------------------
# Suite: shardOf — order preservation
# ---------------------------------------------------------------------------

suite "shardOf — order preservation":

  test "within a shard, ep order matches input order":
    # Use paths that we know end up in the same shard by pre-computing their hashes.
    # Rather than pre-computing, we verify the relative order property:
    # take any shard's output and confirm it appears in the same relative order
    # as in the input.
    let eps = @[
      ep("alpha.nim"), ep("beta.nim"), ep("gamma.nim"),
      ep("delta.nim"), ep("epsilon.nim"), ep("zeta.nim"),
    ]
    let n = 3
    for k in 1..n:
      let shard = shardOf(eps, k, n)
      # The indices in the input of the returned eps must be strictly increasing.
      var lastIdx = -1
      for e in shard:
        let idx = eps.find(e)
        check idx > lastIdx
        lastIdx = idx

# ---------------------------------------------------------------------------
# Suite: shardOf — edge cases
# ---------------------------------------------------------------------------

suite "shardOf — edge cases":

  test "n > eps.len: some shards empty, union still complete":
    let eps = @[ep("tests/only_one.nim")]
    let n = 5
    let unionEps = unionAllShards(eps, n)
    check pathSet(unionEps) == pathSet(eps)
    # Exactly one shard is non-empty
    var nonEmpty = 0
    for k in 1..n:
      if shardOf(eps, k, n).len > 0:
        inc nonEmpty
    check nonEmpty == 1

  test "single ep always lands in exactly one shard":
    let e = ep("tests/unit/test_single.nim")
    let n = 4
    var found = 0
    for k in 1..n:
      if shardOf(@[e], k, n).len == 1:
        inc found
    check found == 1

  test "empty eps: all shards empty":
    let eps: seq[Entrypoint] = @[]
    let n = 3
    for k in 1..n:
      check shardOf(eps, k, n).len == 0

  test "n=1 single ep: shard 1/1 contains it":
    let e = ep("tests/only.nim")
    check shardOf(@[e], 1, 1).len == 1

# ---------------------------------------------------------------------------
# Suite: parseShardSpec — valid inputs
# ---------------------------------------------------------------------------

suite "parseShardSpec — valid inputs":

  test "1/3 parses to (k=1, n=3)":
    let (k, n) = parseShardSpec("1/3")
    check k == 1
    check n == 3

  test "2/3 parses to (k=2, n=3)":
    let (k, n) = parseShardSpec("2/3")
    check k == 2
    check n == 3

  test "3/3 parses to (k=3, n=3)":
    let (k, n) = parseShardSpec("3/3")
    check k == 3
    check n == 3

  test "1/1 is valid (n=1)":
    let (k, n) = parseShardSpec("1/1")
    check k == 1
    check n == 1

  test "1/100 is valid":
    let (k, n) = parseShardSpec("1/100")
    check k == 1
    check n == 100

# ---------------------------------------------------------------------------
# Suite: parseShardSpec — error cases
# ---------------------------------------------------------------------------

suite "parseShardSpec — error cases":

  test "missing slash raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("13")
    except ValueError:
      raised = true
    check raised

  test "extra slash raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("1/3/5")
    except ValueError:
      raised = true
    check raised

  test "empty string raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("")
    except ValueError:
      raised = true
    check raised

  test "non-integer k raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("a/3")
    except ValueError:
      raised = true
    check raised

  test "non-integer n raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("1/b")
    except ValueError:
      raised = true
    check raised

  test "n=0 raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("1/0")
    except ValueError:
      raised = true
    check raised

  test "n negative raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("1/-1")
    except ValueError:
      raised = true
    check raised

  test "k=0 raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("0/3")
    except ValueError:
      raised = true
    check raised

  test "k > n raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("4/3")
    except ValueError:
      raised = true
    check raised

  test "k negative raises ValueError":
    var raised = false
    try:
      discard parseShardSpec("-1/3")
    except ValueError:
      raised = true
    check raised

# ---------------------------------------------------------------------------
# Suite: shardOf + balancedShardOf — composite identity (same path, diff flags)
# ---------------------------------------------------------------------------

suite "shard — composite identity: same path, different flags":
  ## Both shardOf and balancedShardOf must treat (path, flags) as the identity,
  ## not path alone.  When the same source path is an entrypoint in two groups
  ## with different compile flags, they are DISTINCT entrypoints; the partition
  ## must be disjoint and complete over the FULL entrypoint set.
  ##
  ## Identity representation: we use identityKey(ep.path, flagHash(ep.flags))
  ## rendered as a string — the same key the ledger uses — to uniquify eps.

  proc epWithFlags(path: string; flags: seq[string]): Entrypoint =
    Entrypoint(path: path, group: "unit", flags: flags)

  proc identKey(ep: Entrypoint): string =
    ## The composite key string used by the fixed shard implementation.
    $identityKey(ep.path, flagHash(ep.flags))

  proc identSet(eps: seq[Entrypoint]): HashSet[string] =
    result = initHashSet[string]()
    for e in eps:
      result.incl identKey(e)

  proc unionAllShardsIdent(eps: seq[Entrypoint]; n: int): seq[Entrypoint] =
    result = @[]
    for k in 1..n:
      for e in shardOf(eps, k, n):
        result.add e

  test "shardOf: same-path/different-flags eps can land in different shards":
    ## With n=2, the two distinct eps (same path, different flags) must each
    ## appear in EXACTLY ONE shard, and together they must cover both shards'
    ## union completely.
    let epA = epWithFlags("tests/unit/test_shared.nim", @["-d:foo"])
    let epB = epWithFlags("tests/unit/test_shared.nim", @["-d:bar"])
    let eps = @[epA, epB]
    let n = 2
    # Each ep must appear in exactly one shard (complete + disjoint by identity).
    var identCounts = initCountTable[string]()
    for k in 1..n:
      for e in shardOf(eps, k, n):
        identCounts.inc(identKey(e))
    check identCounts[identKey(epA)] == 1
    check identCounts[identKey(epB)] == 1

  test "balancedShardOf: same-path/different-flags eps are disjoint":
    ## The partition break: if keyed by path alone, BOTH eps appear in the
    ## same shard (the one whose bin their path-hash maps to). After the fix,
    ## each ep appears in exactly one shard.
    let epA = epWithFlags("tests/unit/test_shared.nim", @["-d:foo"])
    let epB = epWithFlags("tests/unit/test_shared.nim", @["-d:bar"])
    let eps = @[epA, epB]
    # Assign different durations so LPT assigns them to different bins.
    # Use identity-keyed duration table (as the fixed implementation expects).
    var dOf = initTable[string, int64]()
    dOf[$identityKey(epA.path, flagHash(epA.flags))] = 1000i64
    dOf[$identityKey(epB.path, flagHash(epB.flags))] = 500i64
    let n = 2
    # Disjoint: each identity appears in exactly one shard.
    var identCounts = initCountTable[string]()
    for k in 1..n:
      for e in balancedShardOf(eps, k, n, dOf):
        identCounts.inc(identKey(e))
    check identCounts[identKey(epA)] == 1
    check identCounts[identKey(epB)] == 1

  test "balancedShardOf: complete — union of all shards == all eps by identity":
    let epA = epWithFlags("tests/unit/test_shared.nim", @["-d:foo"])
    let epB = epWithFlags("tests/unit/test_shared.nim", @["-d:bar"])
    let epC = epWithFlags("tests/other.nim", @[])
    let eps = @[epA, epB, epC]
    var dOf = initTable[string, int64]()
    dOf[$identityKey(epA.path, flagHash(epA.flags))] = 300i64
    dOf[$identityKey(epB.path, flagHash(epB.flags))] = 200i64
    dOf[$identityKey(epC.path, flagHash(epC.flags))] = 100i64
    let n = 2
    var identCounts = initCountTable[string]()
    for k in 1..n:
      for e in balancedShardOf(eps, k, n, dOf):
        identCounts.inc(identKey(e))
    for e in eps:
      check identCounts[identKey(e)] == 1
