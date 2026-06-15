## shard.nim — C2: stable path-hash partition for CI shard selection.
##             C3: duration-balanced partition via ledger history (LPT bin-pack).
##
## ## C2: shardOf
##
## Provides a PURE proc `shardOf` that partitions a seq[Entrypoint] into n
## stable, disjoint shards using 64-bit FNV-1a over ep.path.
##
## Assignment rule (1-indexed k):
##   ep is in shard k  iff  fnv1a64(ep.path) mod n  == (k - 1)
##
## Properties:
##   Complete  — every entrypoint lands in exactly one shard:
##               ⋃_{k=1..n} shardOf(eps, k, n) == eps (as a set)
##   Disjoint  — no entrypoint appears in two shards.
##   Stable    — result is deterministic from ep.path alone; independent of
##               input order and of the process/machine (FNV, not std/hashes).
##   Order-preserving — within a shard, entrypoints appear in the same order
##               as in the input seq (filter, not reorder).
##
## Edge cases:
##   n == 1  → shardOf(eps, 1, 1) == eps (all eps in the one shard)
##   n > eps.len → some shards are empty (still complete/disjoint)
##
## ## C3: balancedShardOf
##
## PURE proc: given a duration table, assign each ep to the least-loaded bin
## using Longest Processing Time (LPT) greedy bin-pack:
##   1. Sort eps by duration DESCENDING, tie-break by ep.path ASCENDING.
##   2. Walk the sorted list; assign each ep to the bin with the currently
##      smallest cumulative load (tie among bins → lowest bin index).
##   3. Return eps assigned to bin k-1, in ORIGINAL input order (filter).
##
## Properties: complete, disjoint, stable/deterministic (same eps + durations ⇒
## same partition), order-preserving.
##
## ## C3: ledger-aware wrapper (shardWithHistory)
##
## `shardWithHistory` does ledger I/O, builds the durationOf table, then calls
## the pure bin-pack (or shardOf on cold start).  Decision:
##   - representative duration = MEDIAN of an ep's durationUs rows, excluding
##     rows whose outcome starts with "compileFailed" (those rows have 0 or tiny
##     durationUs that reflects only the compiler, not the test run, and skew the
##     representative duration for sharding purposes).  If all rows are excluded
##     the ep is treated as having no history.
##   - Cold start (NO ep has any history): fallback to shardOf (C2 path-hash).
##   - Partial history (SOME eps have no history): assign them the median of all
##     known durations (not 0 — that would cluster all new tests into bin 0).
##
## IMPORTANT: this wrapper assumes all CI runners share the same `<stateDir>/`
## ledger directory.  If runners have divergent ledgers they may compute different
## partitions, silently breaking the cross-runner disjoint/complete guarantee.
## The deterministic cold-start fallback (path-hash) is always safe when no
## shared ledger is present.
##
## ## Validation
##
## `parseShardSpec(raw)` parses a "k/n" string and returns (k, n).
## Raises ValueError on malformed input; callers that need exit-3 semantics
## catch ValueError and write the error message themselves (see src/crisol.nim).
## Constraints: n >= 1, 1 <= k <= n.

import std/[algorithm, sequtils, strutils, tables]
import crisol/types
import crisol/depgraph       # for fnv1a64, flagHash
import crisol/ledger         # for scanLedger, LedgerRow
import crisol/keys           # for identityKey
import crisol/stats          # for median (C6: shared stats module)
import crisol/outcomestrings # for isCompileFailedOutcomeString

# ---------------------------------------------------------------------------
# Public: shardOf  (C2 — path-hash partition)
# ---------------------------------------------------------------------------

proc shardOf*(eps: seq[Entrypoint]; k, n: int): seq[Entrypoint] =
  ## Return the subset of `eps` assigned to shard `k` of `n`.
  ##
  ## Assignment: ep is in shard k iff
  ##   fnv1a64($identityKey(ep.path, flagHash(ep.flags))) mod n == (k - 1).
  ## Keying by composite identity ensures that two entrypoints sharing the same
  ## path but differing in compile flags are treated as DISTINCT identities and
  ## can land in different shards.
  ## Input order is preserved among the surviving entrypoints.
  ##
  ## Preconditions (caller is responsible for validation):
  ##   n >= 1
  ##   1 <= k <= n
  result = newSeq[Entrypoint]()
  let target = uint64(k - 1)
  for ep in eps:
    let h = fnv1a64($identityKey(ep.path, flagHash(ep.flags)))
    if h mod uint64(n) == target:
      result.add ep

# ---------------------------------------------------------------------------
# Public: balancedShardOf  (C3 — LPT duration-balanced partition)
# ---------------------------------------------------------------------------

proc balancedShardOf*(
  eps:        seq[Entrypoint];
  k, n:       int;
  durationOf: Table[string, int64]
): seq[Entrypoint] =
  ## Pure LPT (Longest Processing Time) greedy bin-pack.
  ##
  ## `durationOf` maps $identityKey(ep.path, flagHash(ep.flags)) → representative
  ## historical duration (µs).  An ep absent from the table is treated as duration 0.
  ##
  ## Keying by composite identity (path + flagHash) ensures that two entrypoints
  ## sharing the same path but differing in compile flags are treated as DISTINCT
  ## identities; the partition is always disjoint and complete over the full set.
  ##
  ## Algorithm:
  ##   1. Sort eps by duration DESC, tie-break by identity key ASC (fully deterministic).
  ##   2. Walk the sorted list; assign each ep to the bin with the smallest
  ##      cumulative load so far.  Ties among bins → lowest bin index (k-1 = 0).
  ##   3. Return the eps assigned to bin (k-1), in ORIGINAL input order.
  ##
  ## Preconditions (caller is responsible for validation):
  ##   n >= 1
  ##   1 <= k <= n
  if eps.len == 0:
    return @[]

  # Step 1: sort eps by duration DESC, then identity key ASC as tie-break.
  var sorted = eps
  sorted.sort(proc(a, b: Entrypoint): int =
    let ika = $identityKey(a.path, flagHash(a.flags))
    let ikb = $identityKey(b.path, flagHash(b.flags))
    let da = durationOf.getOrDefault(ika, 0'i64)
    let db = durationOf.getOrDefault(ikb, 0'i64)
    if db != da:
      return cmp(db, da)   # DESC by duration
    cmp(ika, ikb)          # ASC by identity key as tie-break
  )

  # Step 2: greedy assignment — bin loads are tracked as cumulative durations.
  var binLoads = newSeq[int64](n)   # all start at 0
  var assignment = newSeq[int](sorted.len)
  for i, ep in sorted:
    # Find the least-loaded bin; ties resolved by lowest index.
    var minLoad = binLoads[0]
    var minBin  = 0
    for b in 1 ..< n:
      if binLoads[b] < minLoad:
        minLoad = binLoads[b]
        minBin  = b
    assignment[i] = minBin
    let ik = $identityKey(ep.path, flagHash(ep.flags))
    binLoads[minBin] += durationOf.getOrDefault(ik, 0'i64)

  # Build a set of identity keys assigned to bin (k-1) for fast membership tests.
  let target = k - 1
  var inBin: seq[string] = @[]
  for i, ep in sorted:
    if assignment[i] == target:
      inBin.add $identityKey(ep.path, flagHash(ep.flags))

  # Step 3: return eps in ORIGINAL input order (filter, not reorder).
  let inBinSet = block:
    var t = initTable[string, bool]()
    for p in inBin: t[p] = true
    t
  result = eps.filterIt(inBinSet.getOrDefault(
    $identityKey(it.path, flagHash(it.flags)), false))

# ---------------------------------------------------------------------------
# Public: shardWithHistory  (C3 — ledger-aware wrapper)
# ---------------------------------------------------------------------------

proc shardWithHistory*(
  eps:      seq[Entrypoint];
  k, n:     int;
  stateDir: string;
): seq[Entrypoint] =
  ## Ledger-aware shard selector.  Reads each ep's ledger history, derives a
  ## representative duration (median of non-compile-fail durationUs rows), then
  ## calls `balancedShardOf` for LPT bin-packing.
  ##
  ## Decision rules:
  ##   Cold start (no ep has any history): fallback to `shardOf` (C2 path-hash),
  ##     which is deterministic without shared state.
  ##   Partial history (some eps have no history): missing eps receive the median
  ##     of all known durations — not 0 — so new tests spread across bins rather
  ##     than clustering into the lowest-index bin.
  ##
  ## Shared ledger assumption: correctness of the cross-runner complete/disjoint
  ## guarantee depends on all CI runners reading from the SAME `stateDir` ledger.
  ## If runners have divergent ledger snapshots they may compute different partitions
  ## silently.  The cold-start hash fallback is safe when no shared ledger exists.
  ##
  ## Outcome filter: rows whose outcome starts with "compileFailed" are excluded
  ## from the duration median because their durationUs reflects only the compiler
  ## invocation and not the test binary's run time.
  # Gather history per ep.  Key by identity string (not path alone) so that two
  # eps sharing the same path but differing in compile flags are distinct.
  var knownDurations: Table[string, seq[int64]] = initTable[string, seq[int64]]()
  for ep in eps:
    let ik = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanLedger(stateDir, ik)
    var durs: seq[int64] = @[]
    for r in rows:
      # Exclude compile-fail rows — they do not represent test-binary run time.
      if not isCompileFailedOutcomeString(r.outcome):
        durs.add r.durationUs
    if durs.len > 0:
      knownDurations[$ik] = durs

  # Cold-start: no ep has any history → fall back to path-hash.
  if knownDurations.len == 0:
    return shardOf(eps, k, n)

  # Compute per-ep representative duration (median of their rows).
  # Compute a global default for eps with no history.
  var allKnown: seq[int64] = @[]
  for durs in knownDurations.values:
    for d in durs:
      allKnown.add d

  let defaultDuration = median(allKnown)

  var durationOf = initTable[string, int64]()
  for ep in eps:
    let ik = $identityKey(ep.path, flagHash(ep.flags))
    if ik in knownDurations:
      durationOf[ik] = median(knownDurations[ik])
    else:
      durationOf[ik] = defaultDuration

  balancedShardOf(eps, k, n, durationOf)

# ---------------------------------------------------------------------------
# Public: parseShardSpec
# ---------------------------------------------------------------------------

proc parseShardSpec*(raw: string): tuple[k, n: int] =
  ## Parse a "k/n" shard spec string and return (k, n).
  ##
  ## Raises ValueError with a descriptive message on any of:
  ##   - raw does not contain exactly one '/'
  ##   - k or n are not valid integers
  ##   - n < 1
  ##   - k < 1 or k > n
  ##
  ## Callers that map ValueError to exit-3 (the CLI) catch and re-raise as
  ## needed.  This proc itself is pure — no I/O, no quit().
  let parts = raw.split('/')
  if parts.len != 2:
    raise newException(ValueError,
      "--shard requires k/n format (e.g. --shard 1/3); got '" & raw & "'")

  var k, n: int
  try:
    k = parseInt(parts[0])
  except ValueError:
    raise newException(ValueError,
      "--shard: k is not a valid integer in '" & raw & "'")
  try:
    n = parseInt(parts[1])
  except ValueError:
    raise newException(ValueError,
      "--shard: n is not a valid integer in '" & raw & "'")

  if n < 1:
    raise newException(ValueError,
      "--shard: n must be >= 1; got " & $n)
  if k < 1 or k > n:
    raise newException(ValueError,
      "--shard: k must be between 1 and n (got k=" & $k & ", n=" & $n & ")")

  result = (k: k, n: n)
