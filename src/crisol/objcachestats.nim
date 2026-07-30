## objcachestats.nim — RFC-0006 Stage R, R5a: REALIZED objcache hit/miss
## telemetry.
##
## Stage R's `newCacheDriver` (compiledriver.nim) already decides, per
## compile unit, whether the object cache was a HIT, a MISS that compiled
## and stored, a MISS that compiled but could not store (soft cap), or the
## unit was non-cacheable (`ocdDisabled`) — see `objcache.ObjCacheDecision`.
## This module is the PERSISTENCE layer: one `ObjCacheStatsRow` per
## successful cache-mode compile, carrying REALIZED (i.e.,
## actually-happened-this-run) hit/miss/store COUNTS plus the total bytes
## served from cache — the input a report aggregates into a
## cache-effectiveness summary.
##
## ## Counting convention (DOCUMENTED — the one genuine judgment call here)
##
## Per compile, `ObjCacheStatsRow` tallies `spans.decisions`
## (`compiledriver.CompileSpans.decisions`) into four buckets:
##
##   hits*     = count(ocdHit)            — object reused verbatim from cache.
##   stored*   = count(ocdStored)         — compiled locally AND persisted to
##                                           the cache for future reuse.
##   misses*   = count(ocdMissCompiled) + count(ocdStored)
##                                         — EVERY unit that was NOT found in
##                                           the cache and had to be compiled
##                                           locally, whether or not the
##                                           result could be stored afterward.
##                                           `stored` is thus a SUBSET of
##                                           `misses`, not a disjoint bucket —
##                                           "did this compile miss the
##                                           cache" and "did this compile's
##                                           result get persisted" are two
##                                           different questions, and a
##                                           report wanting "raw miss rate"
##                                           needs the former while a report
##                                           wanting "cache growth this run"
##                                           needs the latter. Storing both
##                                           raw counts (not just the
##                                           difference) keeps that
##                                           distinction available at report
##                                           time without recomputation.
##   disabled* = count(ocdDisabled)       — never cacheable at all (e.g. the
##                                           entry unit) — excluded from both
##                                           the hit and the miss rate, since
##                                           it was never a caching decision.
##
## `ocdSoftCapSkipped`/`ocdCollisionReject` are objcache-internal outcomes
## that `newCacheDriver` never emits as a *unit* decision today (see
## objcache.nim/compiledriver.nim) — they fold into `ocdMissCompiled` at the
## `newCacheDriver` layer already (a skipped/rejected store still leaves the
## unit's decision as `ocdMissCompiled`, not a distinct value here), so this
## row schema does not need separate counters for them; if that ever changes
## upstream, this module's tally loop is the only place to extend.
##
## `reusedBytes*` sums the on-disk size of the `.o` file at each HIT unit's
## object-output path (`compiledriver.parseCcOutputObj(ccCmd)`) — the
## object that was actually copied into place from the cache for this
## compile. Best-effort: an unstattable path contributes 0, never raises
## (mirrors `recordArtifactRows`'s own best-effort `getFileSize` idiom).
##
## ## R3 extraction (code-review finding, subsuming R12)
##
## The sharded-NDJSON writer/reader/compactor below is now a THIN typed
## instantiation of the generic substrate in `shardedledger.nim` — same
## public proc names/signatures, same on-disk format, same
## corruption-tolerance semantics as before the extraction. See
## `shardedledger.nim`'s module doc for the full mechanism.
##
## ## On-disk layout
##
##   <stateDir>/ledger/objcachestats/<pid>-<bootId>-<seq>.ndjson
##
## ## Wire format
##
## Header line (first line of each shard):
##   {"objCacheStatsLedgerFormatVersion":<int>}
##
## Row line (one JSON object per line):
##   {"rowVersion":1,"entrypointIdentity":"<str>","groupId":"<str>",
##    "configHash":"<str>","hits":<int>,"misses":<int>,"stored":<int>,
##    "disabled":<int>,"reusedBytes":<int64>,"timestamp":<int64>}
##
## This stream is LEAN, same as `compilecost.nim`: at most ONE row is
## appended per successful cache-mode compile (one ObjCacheStatsRow per
## entrypoint per run), so it needs no per-unit-scale machinery — just the
## same shard/read/compact shape, matched for consistency.

import std/json
import crisol/types
import crisol/shardedledger

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const objCacheStatsLedgerFormatVersion* = 1
  ## Increment when the NDJSON row schema changes incompatibly. A shard
  ## whose header version differs from this is discarded on read.

const currentObjCacheStatsRowVersion* = 1
  ## Row-level version. An unknown rowVersion (> current) is skipped.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ObjCacheStatsRow* = object
    ## One PER-COMPILE realized objcache hit/miss/store observation,
    ## appended by `measureworker.recordObjCacheStatsRow` after a
    ## successful CACHE-MODE compile. See module doc's "Counting convention"
    ## for exactly what `hits`/`misses`/`stored`/`disabled` count.
    entrypointIdentity*: IdentityKey  ## same (path, flagHash) identity as ArtifactRow/CompileCostRow
    groupId*:            string       ## Group.name — segmentation
    configHash*:         string       ## flagHash(ep.flags) rendered — segmentation
    hits*:                int         ## count(ocdHit)
    misses*:              int         ## count(ocdMissCompiled) + count(ocdStored)
    stored*:               int        ## count(ocdStored) — subset of misses that persisted
    disabled*:             int        ## count(ocdDisabled) — never a caching decision
    reusedBytes*:          int64      ## sum of .o bytes served from cache (HIT units only)
    timestamp*:            int64      ## unix epoch microseconds
    rowVersion*:            int       ## must equal currentObjCacheStatsRowVersion to be accepted

  ObjCacheStatsLedger* = ShardedLedger[ObjCacheStatsRow]
    ## An open per-process objcache-stats shard. One per crisol
    ## compile-cache-worker invocation that records a stats row.

  CompactObjCacheStatsLedgerReport* = CompactReport
    ## Summary of a compactObjCacheStatsLedger run.

# ---------------------------------------------------------------------------
# Codec — the stream's own extra fields on top of the five common ones
# (entrypointIdentity/groupId/configHash/timestamp/rowVersion, handled
# generically by shardedledger.nim)
# ---------------------------------------------------------------------------

proc encodeObjCacheStatsExtra(n: var JsonNode; row: ObjCacheStatsRow) =
  n["hits"]        = newJInt(row.hits)
  n["misses"]      = newJInt(row.misses)
  n["stored"]      = newJInt(row.stored)
  n["disabled"]    = newJInt(row.disabled)
  n["reusedBytes"] = newJInt(row.reusedBytes)

proc decodeObjCacheStatsExtra(n: JsonNode; rv: int; ident: IdentityKey;
                               groupId, configHash: string; timestamp: int64): ObjCacheStatsRow =
  ObjCacheStatsRow(
    rowVersion:         rv,
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:         configHash,
    hits:               n{"hits"}.getInt(0),
    misses:             n{"misses"}.getInt(0),
    stored:             n{"stored"}.getInt(0),
    disabled:           n{"disabled"}.getInt(0),
    reusedBytes:        n{"reusedBytes"}.getBiggestInt(0),
    timestamp:          timestamp,
  )

let objCacheStatsLedgerSpec = ShardedLedgerSpec[ObjCacheStatsRow](
  dirName:           "objcachestats",
  formatVersion:     objCacheStatsLedgerFormatVersion,
  headerField:       "objCacheStatsLedgerFormatVersion",
  currentRowVersion: currentObjCacheStatsRowVersion,
  streamLabel:       "objcache-stats ledger",
  encodeExtra:       encodeObjCacheStatsExtra,
  decodeExtra:       decodeObjCacheStatsExtra,
)

# ---------------------------------------------------------------------------
# Public API — same names/signatures as before the R3 extraction
# ---------------------------------------------------------------------------

proc openObjCacheStatsLedger*(stateDir: string): ObjCacheStatsLedger =
  openShardedLedger(objCacheStatsLedgerSpec, stateDir)

proc append*(led: var ObjCacheStatsLedger; row: ObjCacheStatsRow) =
  appendRow(objCacheStatsLedgerSpec, led, row)

proc closeObjCacheStatsLedger*(led: var ObjCacheStatsLedger) =
  closeShardedLedger(led)

proc scanObjCacheStatsLedger*(stateDir: string): seq[ObjCacheStatsRow] =
  ## Scan ALL shard files under `<stateDir>/ledger/objcachestats/` and
  ## return ALL rows, sorted by timestamp ascending. Corruption-resilient:
  ## malformed rows are skipped with a warning; a header-version mismatch in
  ## a shard discards that shard. Never raises.
  scanShardedLedger(objCacheStatsLedgerSpec, stateDir)

proc compactObjCacheStatsLedger*(stateDir: string; maxAgeSecs: int64; nowSecs: int64):
    CompactObjCacheStatsLedgerReport =
  ## Merge ALL shard files under `<stateDir>/ledger/objcachestats/` into a
  ## single compacted segment, then remove the originals. Optionally drops
  ## rows older than `maxAgeSecs` seconds (0 = keep all rows). Callers
  ## (cleanOrphans) must hold the stateDir lock.
  compactShardedLedger(objCacheStatsLedgerSpec, stateDir, maxAgeSecs, nowSecs)
