## artifactledger.nim — RFC-0006 M0: artifact telemetry substrate.
##
## Append-only time-series store for cross-entrypoint compile-artifact
## identity — the substrate Stage M's reuse-ratio measurement (`r_time`) and
## a future Stage R object cache read.  **Separate from `RunLedger`**
## (ledger.nim): `RunLedger` has no row-kind discriminator, and its
## `parseRow`/`rowToJsonLine`/`compactLedger`/`computeFlakeRate` all assume
## the single exec-row shape — writing artifact rows into the exec shards
## would pollute flake-rate/perf baselines or be silently truncated on
## compaction.  `ledger.nim` is untouched by this module.
##
## RFC-0006 review finding R3 (subsuming R12): this module is now a THIN
## typed instantiation of the generic sharded-NDJSON substrate in
## `shardedledger.nim` — same public proc names/signatures, same on-disk
## format, same corruption-tolerance semantics as before the extraction.
## See `shardedledger.nim`'s module doc for the full mechanism (shard
## naming, header/row framing, corruption-resilient reads, compaction
## crash-safety). This file supplies only the `ArtifactRow` shape and its
## own extra-field codec (`groupId`/`configHash`/`entrypointIdentity`/
## `timestamp`/`rowVersion` are handled generically — see
## `shardedledger.nim`'s "Common row shape").
##
## ## On-disk layout
##
##   <stateDir>/ledger/artifacts/<pid>-<bootId>-<seq>.ndjson
##
## ## Wire format
##
## Header line (first line of each shard):
##   {"artifactLedgerFormatVersion":<int>}
##
## Row line (one JSON object per line):
##   {"rowVersion":1,"entrypointIdentity":"<str>","groupId":"<str>",
##    "configHash":"<str>","artifactBasename":"<str>","keyHash":"<str>",
##    "sizeBytes":<int64>,"ccTimeUs":<int64>,"toolchainFp":"<str>",
##    "timestamp":<int64>}
##
## `toolchainFp` (W9l): the toolchain identity `ccTimeUs` was measured under
## -- `planner.toolchainFingerprint(nimVersion, ccVersion)`, computed ONCE by
## the host process and passed down through `MeasurePlan.toolchainFp` (the
## measure-worker never re-probes; see `workerplan.MeasurePlan.toolchainFp`'s
## doc for why). OPTIONAL on read, same convention as `depgraph.DepGraphHeader.
## ccVersion` (W3): a pre-W9l row with no `toolchainFp` field decodes as `""`
## -- a real, queryable "unknown toolchain" bucket, not a crash and not
## silently folded into whatever toolchain wrote the NEXT row. No
## `artifactLedgerFormatVersion`/`rowVersion` bump: this is a strictly
## additive field an old reader ignores and a new reader defaults cleanly,
## the same shape of change W3 already established for this exact file
## format family.
##
## `entrypointIdentity` is the same `IdentityKey` ((path, flagHash)) RunLedger
## rows carry — but that hash is opaque and does not decode back to a group
## name or raw flag set, so `groupId` and `configHash` are carried alongside
## it as their own fields so a future M-report can segment by group/config
## without reversing a digest.
##
## ## Row fields (per RFC-0006 §M-artifact-identity)
##
## `(entrypointIdentity, artifactBasename, keyHash, sizeBytes, ccTimeUs)` is
## the RFC's named tuple; `groupId`/`configHash` add segmentability;
## `timestamp`/`rowVersion` mirror `LedgerRow`'s bookkeeping fields (ordering
## + compaction age-filter + forward-compatible row-shape versioning).
## `keyHash` is an opaque string here — this module does not compute it, does
## not hash `.c` content or `#include` closures, and does not import
## `closure.nim`/`ccprobe.nim`. Only the M-artifact-identity writer
## (`measureworker.nim`) computes and passes it.

import std/json
import crisol/types
import crisol/shardedledger

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const artifactLedgerFormatVersion* = 1
  ## Increment when the NDJSON row schema changes incompatibly.  A shard
  ## whose header version differs from this is discarded on read.

const currentArtifactRowVersion* = 1
  ## Row-level version.  An unknown rowVersion (> current) is skipped.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ArtifactRow* = object
    ## One compile-artifact identity observation, appended by the
    ## M-artifact-identity writer (`measureworker.recordArtifactRows`) at
    ## the measure-worker's compile-manifest pass.
    entrypointIdentity*: IdentityKey  ## same (path, flagHash) identity as LedgerRow
    groupId*:            string       ## Group.name — segmentation (identity is opaque)
    configHash*:         string       ## flagHash(ep.flags) rendered — segmentation
    artifactBasename*:   string       ## generated .c basename (closure.nim convention)
    keyHash*:            string       ## opaque Stage-R key-material hash; not computed here
    sizeBytes*:          int64        ## artifact size in bytes
    ccTimeUs*:           int64        ## measured cc wall-time for this artifact, microseconds
    toolchainFp*:        string       ## W9l: toolchainFingerprint(nimVersion, ccVersion) this
                                       ## ccTimeUs was measured under. "" = unknown/pre-W9l row.
    timestamp*:          int64        ## unix epoch microseconds
    rowVersion*:         int          ## must equal currentArtifactRowVersion to be accepted

  ArtifactLedger* = ShardedLedger[ArtifactRow]
    ## An open per-process artifact shard.  One per crisol invocation that
    ## writes artifact rows (measurement-mode-gated at the call site — this
    ## module itself is unconditional plumbing).

  CompactArtifactLedgerReport* = CompactReport
    ## Summary of a compactArtifactLedger run.

# ---------------------------------------------------------------------------
# Codec — the stream's own extra fields on top of the five common ones
# (entrypointIdentity/groupId/configHash/timestamp/rowVersion, handled
# generically by shardedledger.nim)
# ---------------------------------------------------------------------------

proc encodeArtifactExtra(n: var JsonNode; row: ArtifactRow) =
  n["artifactBasename"] = newJString(row.artifactBasename)
  n["keyHash"]          = newJString(row.keyHash)
  n["sizeBytes"]        = newJInt(row.sizeBytes)
  n["ccTimeUs"]         = newJInt(row.ccTimeUs)
  n["toolchainFp"]      = newJString(row.toolchainFp)

proc decodeArtifactExtra(n: JsonNode; rv: int; ident: IdentityKey;
                          groupId, configHash: string; timestamp: int64): ArtifactRow =
  ArtifactRow(
    rowVersion:         rv,
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:         configHash,
    artifactBasename:   n{"artifactBasename"}.getStr(""),
    keyHash:            n{"keyHash"}.getStr(""),
    sizeBytes:          n{"sizeBytes"}.getBiggestInt(0),
    ccTimeUs:           n{"ccTimeUs"}.getBiggestInt(0),
    # W9l: OPTIONAL on read -- a pre-W9l row has no "toolchainFp" field and
    # decodes to "" (same treatment as depgraph's W3 ccVersion field).
    toolchainFp:        n{"toolchainFp"}.getStr(""),
    timestamp:          timestamp,
  )

let artifactLedgerSpec = ShardedLedgerSpec[ArtifactRow](
  dirName:           "artifacts",
  formatVersion:     artifactLedgerFormatVersion,
  headerField:       "artifactLedgerFormatVersion",
  currentRowVersion: currentArtifactRowVersion,
  streamLabel:       "artifact ledger",
  encodeExtra:       encodeArtifactExtra,
  decodeExtra:       decodeArtifactExtra,
)

# ---------------------------------------------------------------------------
# Public API — same names/signatures as before the R3 extraction
# ---------------------------------------------------------------------------

proc openArtifactLedger*(stateDir: string): ArtifactLedger =
  openShardedLedger(artifactLedgerSpec, stateDir)

proc append*(led: var ArtifactLedger; row: ArtifactRow) =
  appendRow(artifactLedgerSpec, led, row)

proc closeArtifactLedger*(led: var ArtifactLedger) =
  closeShardedLedger(led)

proc scanArtifactLedger*(stateDir: string): seq[ArtifactRow] =
  ## Scan ALL shard files under `<stateDir>/ledger/artifacts/` and return
  ## ALL rows, sorted by timestamp ascending.
  ##
  ## Unlike `ledger.scanLedger` (which filters by a single `IdentityKey` for
  ## per-entrypoint history queries), artifact rows are consumed in
  ## aggregate — a report segments them by group/config across ALL
  ## entrypoints, not one at a time — so this returns everything.
  scanShardedLedger(artifactLedgerSpec, stateDir)

proc compactArtifactLedger*(stateDir: string; maxAgeSecs: int64; nowSecs: int64):
    CompactArtifactLedgerReport =
  ## Merge ALL shard files under `<stateDir>/ledger/artifacts/` into a single
  ## compacted segment, then remove the originals. Optionally drops rows
  ## older than `maxAgeSecs` seconds (0 = keep all rows). Callers
  ## (cleanOrphans) must hold the stateDir lock.
  compactShardedLedger(artifactLedgerSpec, stateDir, maxAgeSecs, nowSecs)
