## clean.nim — C4: `crisol clean` orphan pruning + `--all`.
##
## ## Contract (from RFC §State directory & cache management)
##
## `crisol clean`:
##   1. Load config.
##   2. Discover ALL entrypoints across ALL groups (gskAll, opt-in included).
##      Gates are IGNORED — a closed gate must NOT delete caches.
##   3. For each discovered entrypoint compute `slug(ep.path, ep.flags)`.
##      This is the FORWARD-COMPUTED expected slug set.  No slug decoding.
##   4. Delete every directory under `<stateDir>/cache/` and `<stateDir>/bin/`
##      whose base name is NOT in the expected slug set.
##      (The execute scheduler also creates per-slot transient dirs suffixed
##      with `_<pepIdx>`.  Those are temp artifacts — clean removes them too,
##      unless their prefix without the suffix is in the expected set.  We
##      check: a dir name is retained iff slug ∈ expectedSlugs OR the name
##      has a `_<N>` suffix whose prefix is in expectedSlugs.  This mirrors
##      how spawnCompileStable names its per-slot dirs.)
##   5. Load dep graph, run `gcDeletedEntrypoints(graph, currentKeys)`, save.
##
## `crisol clean --all`:
##   - Remove the entire `<stateDir>/` directory recursively.
##   - No lock needed (no other state to read/write after deletion).
##
## Lock:
##   `clean` (without --all) takes the advisory lock — it reads and mutates
##   shared state (cache, bin, depgraph).  A clean racing a run would corrupt
##   that state.  `--all` does not need the lock (it just nukes the dir).

import std/[os, sets, strutils, tables, times]
import crisol/[types, discover, planner, runner, depgraph, resultcache, ledger]
  # `planner` imported explicitly for `slug` (forward-computed expected-slug set
  # below) rather than leaning on runner's re-export — keeps the dependency
  # visible in the import list.
  # `resultcache` imported for `isResultCacheRootName` and `gcResultCache`.
  # `ledger` imported for `compactLedger`.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc splitSlotSuffix(name: string): (string, bool) =
  ## If `name` ends with `_<digits>`, return (prefix, true).
  ## Otherwise return (name, false).
  ## Used to recognise per-slot temp dirs created by spawnCompileStable.
  let uIdx = name.rfind('_')
  if uIdx < 0:
    return (name, false)
  let suffix = name[uIdx + 1 .. ^1]
  if suffix.len == 0:
    return (name, false)
  for c in suffix:
    if c notin {'0' .. '9'}:
      return (name, false)
  (name[0 ..< uIdx], true)

proc pruneDir(parentDir: string; expectedSlugs: HashSet[string]): int =
  ## Delete every direct child of `parentDir` whose slug is NOT retained.
  ##
  ## A child is retained if:
  ##   a) its name is in expectedSlugs, OR
  ##   b) it looks like `<slug>_<N>` where <slug> is in expectedSlugs
  ##      (per-slot transient dir), OR
  ##   c) its name matches the result-cache root pattern `v<digits>` —
  ##      recognised via `isResultCacheRootName` from resultcache.nim.
  ##      This preserves `cache/v1/`, `cache/v2/`, etc. so orphan pruning
  ##      never deletes the live result-cache store (C0 bug fix).
  ##      Content-GC of superseded version dirs is deferred to A1c.
  ##
  ## Returns the count of deleted directories.
  var deleted = 0
  if not dirExists(parentDir):
    return 0
  for kind, child in walkDir(parentDir):
    let name = child.extractFilename()
    let (prefix, hasSuffix) = splitSlotSuffix(name)
    let retain =
      name in expectedSlugs or
      (hasSuffix and prefix in expectedSlugs) or
      isResultCacheRootName(name)
    if not retain:
      try:
        if kind == pcDir:
          removeDir(child)
        else:
          removeFile(child)
        inc deleted
      except:
        discard  # best-effort; next run will retry
  deleted

# ---------------------------------------------------------------------------
# Public: cleanAll
# ---------------------------------------------------------------------------

proc cleanAll*(config: Config) =
  ## Remove the entire stateDir (`<projectRoot>/<stateDir>/`) recursively.
  let stateDir = config.projectRoot / config.stateDir
  if dirExists(stateDir):
    removeDir(stateDir)
  stdout.write("crisol clean --all: removed " & stateDir & "\n")

# ---------------------------------------------------------------------------
# Public: cleanOrphans
# ---------------------------------------------------------------------------

proc cleanOrphans*(config: Config): tuple[
    cacheDeleted, binDeleted, graphEntriesDropped,
    cacheEvicted, shardsRemoved, ledgerRowsKept: int] =
  ## Prune orphan cache/bin dirs, stale depgraph entries, and GC the
  ## result-cache + ledger stores.
  ##
  ## Steps:
  ##   1. Discover ALL entrypoints (gskAll, gates ignored — no applyGates call).
  ##   2. Build the expected slug set via slug(ep.path, ep.flags).
  ##   3. Prune <stateDir>/cache/ and <stateDir>/bin/.
  ##   4. GC the depgraph (drop entries not in discovered set).
  ##   5. GC the result-cache (size + age LRU via gcResultCache).
  ##   6. Compact the ledger (merge shards via compactLedger).
  ##
  ## Lock:
  ##   The caller (crisol clean in crisol.nim) acquires the stateDir lock
  ##   BEFORE calling cleanOrphans, and holds it for the entire call.  This
  ##   guarantees that no concurrent `crisol run` can write to the result-cache
  ##   or ledger while GC or compaction is in progress.  The lock prevents
  ##   a run from writing a new entry that the GC then immediately deletes
  ##   (size-bound eviction) or a shard that compaction then absorbs
  ##   mid-write (which would produce a partial shard).
  ##
  ## Returns counts of what was pruned/evicted/compacted.

  let stateDir = config.projectRoot / config.stateDir

  # Step 1: Discover ALL entrypoints, ALL groups, gates IGNORED.
  # applyGates is deliberately NOT called here — a closed gate must not
  # cause crisol to delete caches for gated groups.
  let allSel     = GroupSelection(kind: gskAll)
  let discovered = discover(config, allSel)
  # unsafeToSeq: gates are intentionally ignored here — a closed gate must not
  # cause crisol to delete caches for gated groups.
  let eps        = unsafeToSeq(discovered)

  # Step 2: Compute expected slug set (forward-computation, no slug decoding).
  var expectedSlugs = initHashSet[string]()
  for ep in eps:
    expectedSlugs.incl slug(ep.path, ep.flags)

  # Step 3: Prune cache/ and bin/.
  let cacheParent = stateDir / "cache"
  let binParent   = stateDir / "bin"
  let cacheDeleted = pruneDir(cacheParent, expectedSlugs)
  let binDeleted   = pruneDir(binParent,   expectedSlugs)

  # Step 4: GC depgraph entries.
  # Build the currentKeys set as (ep.path, flagHash(ep.flags)) — the same
  # key shape used by the depgraph (Table[(string, string), DepGraphEntry]).
  var currentKeys = initHashSet[(string, string)]()
  for ep in eps:
    currentKeys.incl (ep.path, flagHash(ep.flags))

  var graph = loadDepGraph(config, "")   # nimVersion="" — we only GC, no freshness
  let beforeCount = graph.entries.len
  gcDeletedEntrypoints(graph, currentKeys)
  let afterCount = graph.entries.len
  let dropped = beforeCount - afterCount
  if dropped > 0 or graph.entries.len > 0:
    saveDepGraph(graph, config)

  # Step 5: GC result-cache (size + age LRU).
  let maxEntries = if config.maxCacheEntries > 0: config.maxCacheEntries
                   else: DefaultMaxCacheEntries
  let maxAgeSecs: int64 =
    if config.cacheMaxAgeDays > 0: int64(config.cacheMaxAgeDays) * 86_400
    else: 0
  let nowSecs = int64(epochTime())
  let gcReport = gcResultCache(stateDir, maxEntries, maxAgeSecs, nowSecs)

  # Step 6: Compact the ledger.
  let ledgerMaxAgeSecs: int64 =
    if config.ledgerMaxAgeDays > 0: int64(config.ledgerMaxAgeDays) * 86_400
    else: 0
  let compactReport = compactLedger(stateDir, ledgerMaxAgeSecs, nowSecs)

  result = (
    cacheDeleted:      cacheDeleted,
    binDeleted:        binDeleted,
    graphEntriesDropped: dropped,
    cacheEvicted:      gcReport.evicted,
    shardsRemoved:     compactReport.shardsRemoved,
    ledgerRowsKept:    compactReport.rowsKept,
  )
