## compilecost.nim — RFC-0006 M-cost-split: per-compile codegen/cc/link cost
## telemetry.
##
## `compiledriver.runMeasured` already returns a `CompileSpans` carrying
## OVERLAP-AWARE wall-clock spans for the three SEQUENTIAL compile phases
## (codegen fully precedes cc precedes link, so total compile wall time is
## their sum). This module adds:
##
##   1. `costSplit` — a PURE function deriving the codegen/cc/link percentage
##      SHARE of one compile from its `CompileSpans`. Percentages are NOT
##      persisted (see `CompileCostRow` below) — this is a report-time helper.
##   2. `CompileCostRow` — one PER-COMPILE observation of the RAW µs split,
##      keyed by the same `IdentityKey`/`groupId`/`configHash` triple
##      `artifactledger.ArtifactRow` carries, so a report can join the two
##      streams and segment by (groupId, configHash).
##   3. A lean per-invocation sharded writer/reader for `CompileCostRow`.
##
## ## Why raw µs, not percentages, are persisted
##
## RFC's "derived from raw counts" principle (mirrors how `ArtifactRow`
## stores raw `sizeBytes`/`ccTimeUs`, not a precomputed ratio): percentages
## are trivially recomputed from raw µs at report time via `costSplit`, but
## the reverse (recovering raw µs from a stored percentage) is impossible.
## Storing raw counts keeps exactly one source of truth and lets a future
## M-report change how it aggregates without a schema migration.
##
## ## R3 extraction (code-review finding, subsuming R12)
##
## The sharded-NDJSON writer/reader/compactor below is now a THIN typed
## instantiation of the generic substrate in `shardedledger.nim` — same
## public proc names/signatures, same on-disk format, same
## corruption-tolerance semantics as before the extraction. See
## `shardedledger.nim`'s module doc for the full mechanism (shard naming,
## header/row framing, corruption-resilient reads, compaction
## crash-safety, and the per-stream independent bootId/shard-sequence
## argument).
##
## ## On-disk layout
##
##   <stateDir>/ledger/compilecost/<pid>-<bootId>-<seq>.ndjson
##
## ## Wire format
##
## Header line (first line of each shard):
##   {"compileCostLedgerFormatVersion":<int>}
##
## Row line (one JSON object per line):
##   {"rowVersion":1,"entrypointIdentity":"<str>","groupId":"<str>",
##    "configHash":"<str>","codegenUs":<int64>,"ccUs":<int64>,
##    "linkUs":<int64>,"timestamp":<int64>}
##
## This stream is LEAN relative to `artifactledger.nim`: at most ONE row is
## appended per successful compile (one CompileCostRow per entrypoint per
## run, vs. artifactledger's one ArtifactRow per REUSABLE UNIT), so it does
## not need per-unit-scale machinery — just the same shard/read/compact
## shape, matched for consistency.

import std/json
import crisol/types
import crisol/shardedledger
import crisol/compiledriver

# ---------------------------------------------------------------------------
# costSplit — pure percentage split (report-time helper; not persisted)
# ---------------------------------------------------------------------------

type
  CostSplit* = object
    ## Percentage share of each phase in one compile's total wall time.
    ## `total = spans.codegenSpanUs + spans.ccSpanUs + spans.linkSpanUs`
    ## (the three phases are sequential, per module doc). When `total == 0`
    ## (e.g. a compile that failed before any phase completed), all three
    ## fields are `0.0` rather than dividing by zero.
    codegenPct*: float
    ccPct*:      float
    linkPct*:    float

proc costSplit*(spans: CompileSpans): CostSplit =
  ## Derive the codegen/cc/link percentage split from `spans`' raw µs spans.
  ## When the three spans sum to a positive total, the three percentages
  ## sum to ~1.0 (subject to float rounding).
  let total = spans.codegenSpanUs + spans.ccSpanUs + spans.linkSpanUs
  if total == 0:
    return CostSplit(codegenPct: 0.0, ccPct: 0.0, linkPct: 0.0)
  result = CostSplit(
    codegenPct: spans.codegenSpanUs.float / total.float,
    ccPct:      spans.ccSpanUs.float / total.float,
    linkPct:    spans.linkSpanUs.float / total.float,
  )

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const compileCostLedgerFormatVersion* = 1
  ## Increment when the NDJSON row schema changes incompatibly. A shard
  ## whose header version differs from this is discarded on read.

const currentCompileCostRowVersion* = 1
  ## Row-level version. An unknown rowVersion (> current) is skipped.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  CompileCostRow* = object
    ## One PER-COMPILE codegen/cc/link raw µs observation, appended by
    ## `measureworker.recordCompileCostRow` after a successful compile.
    entrypointIdentity*: IdentityKey  ## same (path, flagHash) identity as ArtifactRow
    groupId*:            string       ## Group.name — segmentation
    configHash*:         string       ## flagHash(ep.flags) rendered — segmentation
    codegenUs*:          int64        ## raw codegen-phase wall time, microseconds
    ccUs*:                int64        ## raw whole-cc-phase wall time, microseconds
    linkUs*:              int64        ## raw link-phase wall time, microseconds
    timestamp*:          int64        ## unix epoch microseconds
    rowVersion*:         int          ## must equal currentCompileCostRowVersion to be accepted

  CompileCostLedger* = ShardedLedger[CompileCostRow]
    ## An open per-process compile-cost shard. One per crisol measure-worker
    ## invocation that records a compile-cost row.

  CompactCompileCostLedgerReport* = CompactReport
    ## Summary of a compactCompileCostLedger run.

# ---------------------------------------------------------------------------
# Codec — the stream's own extra fields on top of the five common ones
# (entrypointIdentity/groupId/configHash/timestamp/rowVersion, handled
# generically by shardedledger.nim)
# ---------------------------------------------------------------------------

proc encodeCompileCostExtra(n: var JsonNode; row: CompileCostRow) =
  n["codegenUs"] = newJInt(row.codegenUs)
  n["ccUs"]      = newJInt(row.ccUs)
  n["linkUs"]    = newJInt(row.linkUs)

proc decodeCompileCostExtra(n: JsonNode; rv: int; ident: IdentityKey;
                             groupId, configHash: string; timestamp: int64): CompileCostRow =
  CompileCostRow(
    rowVersion:         rv,
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:         configHash,
    codegenUs:          n{"codegenUs"}.getBiggestInt(0),
    ccUs:               n{"ccUs"}.getBiggestInt(0),
    linkUs:             n{"linkUs"}.getBiggestInt(0),
    timestamp:          timestamp,
  )

let compileCostLedgerSpec = ShardedLedgerSpec[CompileCostRow](
  dirName:           "compilecost",
  formatVersion:     compileCostLedgerFormatVersion,
  headerField:       "compileCostLedgerFormatVersion",
  currentRowVersion: currentCompileCostRowVersion,
  streamLabel:       "compile-cost ledger",
  encodeExtra:       encodeCompileCostExtra,
  decodeExtra:       decodeCompileCostExtra,
)

# ---------------------------------------------------------------------------
# Public API — same names/signatures as before the R3 extraction
# ---------------------------------------------------------------------------

proc openCompileCostLedger*(stateDir: string): CompileCostLedger =
  openShardedLedger(compileCostLedgerSpec, stateDir)

proc append*(led: var CompileCostLedger; row: CompileCostRow) =
  appendRow(compileCostLedgerSpec, led, row)

proc closeCompileCostLedger*(led: var CompileCostLedger) =
  closeShardedLedger(led)

proc scanCompileCostLedger*(stateDir: string): seq[CompileCostRow] =
  ## Scan ALL shard files under `<stateDir>/ledger/compilecost/` and return
  ## ALL rows, sorted by timestamp ascending. Corruption-resilient: malformed
  ## rows are skipped with a warning; a header-version mismatch in a shard
  ## discards that shard. Never raises.
  scanShardedLedger(compileCostLedgerSpec, stateDir)

proc compactCompileCostLedger*(stateDir: string; maxAgeSecs: int64; nowSecs: int64):
    CompactCompileCostLedgerReport =
  ## Merge ALL shard files under `<stateDir>/ledger/compilecost/` into a
  ## single compacted segment, then remove the originals. Optionally drops
  ## rows older than `maxAgeSecs` seconds (0 = keep all rows). Callers
  ## (cleanOrphans) must hold the stateDir lock.
  compactShardedLedger(compileCostLedgerSpec, stateDir, maxAgeSecs, nowSecs)
