## test_artifactledger.nim — RFC-0006 M0: artifact telemetry substrate.
##
## TDD: tests written first (RED), then artifactledger.nim written to make
## them pass.
##
## `RunLedger` (ledger.nim) has no row-kind discriminator — writing
## artifact-identity rows into its exec shards would pollute flake-rate/perf
## baselines or be silently truncated on compaction (`parseRow`/`compactLedger`
## both assume the single exec-row shape).  This module is a SEPARATE shard
## stream at `<stateDir>/ledger/artifacts/`, mirroring ledger.nim's per-process
## shard machinery exactly, but kept entirely distinct on disk and in code.
##
## Coverage (this file):
##   1. roundtrip: append a row → scanArtifactLedger returns it, fields equal.
##   2. writer isolation: opening an ArtifactLedger creates a shard under
##      `<stateDir>/ledger/artifacts/`, NEVER under `<stateDir>/ledger/`
##      directly (where the exec RunLedger writes) — and appending to one
##      never appears in the other's scan.
##   3. torn-row-skip: a hand-injected malformed line is skipped, good rows
##      survive.
##   4. header-version mismatch shard → whole shard discarded.
##
## Compaction/GC coverage lives in test_artifactledger_gc.nim (mirrors the
## ledger.nim / test_a1c_gc.nim split).

import std/[os, sequtils, strutils]
import crisol/types
import crisol/ledger      # exec RunLedger — used ONLY to prove writer isolation
import crisol/artifactledger

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_artifactledger_" & name)
  removeDir(result)
  createDir(result)

proc sampleArtifactRow(ident: IdentityKey; ts: int64;
                       groupId = "unit"; configHash = "cfg0000000000000";
                       basename = "@pchronos.nim.c"; keyHash = "keyhash000000000";
                       sizeBytes = 4096i64; ccTimeUs = 123_456i64): ArtifactRow =
  ArtifactRow(
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:          configHash,
    artifactBasename:    basename,
    keyHash:             keyHash,
    sizeBytes:           sizeBytes,
    ccTimeUs:            ccTimeUs,
    timestamp:           ts,
    rowVersion:          1,
  )

# ---------------------------------------------------------------------------
# 1. roundtrip
# ---------------------------------------------------------------------------

block test_roundtrip:
  let sd = freshStateDir("roundtrip")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_foo.nim::")
  var led = openArtifactLedger(sd)
  let row = sampleArtifactRow(ident, 1000)
  append(led, row)
  closeArtifactLedger(led)

  let rows = scanArtifactLedger(sd)
  assert rows.len == 1, "roundtrip: expected 1 row, got " & $rows.len
  assert rows[0].entrypointIdentity == ident
  assert rows[0].groupId == "unit"
  assert rows[0].configHash == "cfg0000000000000"
  assert rows[0].artifactBasename == "@pchronos.nim.c"
  assert rows[0].keyHash == "keyhash000000000"
  assert rows[0].sizeBytes == 4096
  assert rows[0].ccTimeUs == 123_456
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 2. writer isolation: artifact shard lives under ledger/artifacts/, never
#    under ledger/ directly; exec RunLedger and ArtifactLedger never
#    cross-contaminate each other's scans.
# ---------------------------------------------------------------------------

block test_writer_isolation:
  let sd = freshStateDir("isolation")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_iso.nim::")

  # Write to the exec RunLedger (ledger.nim) first.
  var execLed = ledger.openLedger(sd)
  ledger.append(execLed, ledger.LedgerRow(
    identity:   ident,
    timestamp:  500,
    inputHash:  "deadbeef",
    outcome:    "passed",
    attempt:    1,
    durationUs: 1000,
    rssBytes:   2048,
    rowVersion: 1,
  ))
  ledger.closeLedger(execLed)

  # Write to the artifact ledger.
  var artLed = openArtifactLedger(sd)
  append(artLed, sampleArtifactRow(ident, 1000))
  closeArtifactLedger(artLed)

  # The artifact shard must be under ledger/artifacts/, NOT directly under
  # ledger/ (where the exec shard lives).
  var execShards: seq[string]
  for kind, p in walkDir(sd / "ledger"):
    if kind == pcFile and p.endsWith(".ndjson"):
      execShards.add p
  assert execShards.len == 1,
    "writer isolation: expected exactly 1 exec shard directly under ledger/, got " &
    $execShards.len

  var artShards: seq[string]
  for kind, p in walkDir(sd / "ledger" / "artifacts"):
    if kind == pcFile and p.endsWith(".ndjson"):
      artShards.add p
  assert artShards.len == 1,
    "writer isolation: expected exactly 1 artifact shard under ledger/artifacts/, got " &
    $artShards.len

  # Scanning one stream must never see the other's rows.
  let execRows = ledger.scanLedger(sd, ident)
  assert execRows.len == 1, "writer isolation: exec scan expected 1 row, got " & $execRows.len
  assert execRows[0].inputHash == "deadbeef"

  let artRows = scanArtifactLedger(sd)
  assert artRows.len == 1, "writer isolation: artifact scan expected 1 row, got " & $artRows.len
  assert artRows[0].keyHash == "keyhash000000000"

# ---------------------------------------------------------------------------
# 3. torn-row-skip
# ---------------------------------------------------------------------------

block test_torn_row_skip:
  let sd = freshStateDir("tornrow")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_y.nim::")

  var led = openArtifactLedger(sd)
  append(led, sampleArtifactRow(ident, 1000))
  closeArtifactLedger(led)

  let shardFiles = block:
    var sf: seq[string]
    for kind, p in walkDir(sd / "ledger" / "artifacts"):
      if kind == pcFile and p.endsWith(".ndjson"):
        sf.add p
    sf
  assert shardFiles.len == 1, "torn-row-skip: expected exactly 1 shard"
  let shardPath = shardFiles[0]

  # Append a truncated/malformed JSON line after the good row.
  let f = open(shardPath, fmAppend)
  f.write("{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_y.nim::\",\"torn\n")
  f.close()

  # Append another valid row AFTER the torn one (requires a new shard).
  var led2 = openArtifactLedger(sd)
  append(led2, sampleArtifactRow(ident, 3000))
  closeArtifactLedger(led2)

  let rows = scanArtifactLedger(sd)
  assert rows.len == 2, "torn-row-skip: expected 2 good rows, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 3000

# ---------------------------------------------------------------------------
# 4. header-version mismatch → whole shard discarded
# ---------------------------------------------------------------------------

block test_header_version_mismatch:
  let sd = freshStateDir("hdrver")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_hdr.nim::")
  var led = openArtifactLedger(sd)
  append(led, sampleArtifactRow(ident, 1000))
  closeArtifactLedger(led)

  # Manually create a second shard file with a mismatched header version.
  createDir(sd / "ledger" / "artifacts")
  let badShardPath = sd / "ledger" / "artifacts" / "99999-badbad-1.ndjson"
  let f = open(badShardPath, fmWrite)
  f.write("{\"artifactLedgerFormatVersion\":9999}\n")
  f.write("{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_hdr.nim::\"," &
          "\"groupId\":\"unit\",\"configHash\":\"c\",\"artifactBasename\":\"@pfoo.nim.c\"," &
          "\"keyHash\":\"k\",\"sizeBytes\":1,\"ccTimeUs\":1,\"timestamp\":2000}\n")
  f.close()

  # Only the good shard's row should appear; the mismatched shard is discarded.
  let rows = scanArtifactLedger(sd)
  assert rows.len == 1, "header-version mismatch: expected 1 row (bad shard discarded), got " & $rows.len
  assert rows[0].timestamp == 1000

echo "test_artifactledger: all blocks passed"
