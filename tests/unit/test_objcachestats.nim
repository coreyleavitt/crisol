## test_objcachestats.nim — RFC-0006 Stage R, R5a: realized objcache
## hit/miss/store telemetry stream.
##
## TDD: tests written first (RED), then objcachestats.nim written to make
## them pass. Mirrors test_compilecost.nim's coverage shape over
## ObjCacheStatsRow: round-trip, writer isolation, torn-row tolerance, and
## (new here) a header-version-mismatch discards-the-whole-shard case,
## mirroring test_artifactledger.nim's own precedent for that behavior.
##
## Compaction/GC coverage lives in test_objcachestats_gc.nim (mirrors the
## compilecost.nim / test_compilecost_gc.nim split).

import std/[os, strutils]
import crisol/types
import crisol/objcachestats

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_objcachestats_" & name)
  removeDir(result)
  createDir(result)

proc sampleRow(ident: IdentityKey; ts: int64;
              groupId = "unit"; configHash = "cfg0000000000000";
              hits = 3; misses = 2; stored = 1; disabled = 1;
              reusedBytes = 4096i64): ObjCacheStatsRow =
  ObjCacheStatsRow(
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:         configHash,
    hits:               hits,
    misses:             misses,
    stored:             stored,
    disabled:           disabled,
    reusedBytes:        reusedBytes,
    timestamp:          ts,
    rowVersion:         currentObjCacheStatsRowVersion,
  )

# ---------------------------------------------------------------------------
# 1. Round-trip: append -> scanObjCacheStatsLedger returns fields intact
# ---------------------------------------------------------------------------

block test_roundtrip:
  let sd = freshStateDir("roundtrip")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_foo.nim::")
  var led = openObjCacheStatsLedger(sd)
  let row = sampleRow(ident, 1000)
  append(led, row)
  closeObjCacheStatsLedger(led)

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 1, "roundtrip: expected 1 row, got " & $rows.len
  assert rows[0].entrypointIdentity == ident
  assert rows[0].groupId == "unit"
  assert rows[0].configHash == "cfg0000000000000"
  assert rows[0].hits == 3
  assert rows[0].misses == 2
  assert rows[0].stored == 1
  assert rows[0].disabled == 1
  assert rows[0].reusedBytes == 4096
  assert rows[0].timestamp == 1000
  assert rows[0].rowVersion == currentObjCacheStatsRowVersion

# ---------------------------------------------------------------------------
# 2. writer isolation: shard lives under ledger/objcachestats/, a SIBLING of
#    ledger/ (exec), ledger/artifacts/, and ledger/compilecost/ — never
#    inside any of them.
# ---------------------------------------------------------------------------

block test_writer_isolation:
  let sd = freshStateDir("isolation")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_iso.nim::")
  var led = openObjCacheStatsLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeObjCacheStatsLedger(led)

  var directLedgerShards: seq[string]
  for kind, p in walkDir(sd / "ledger"):
    if kind == pcFile and p.endsWith(".ndjson"):
      directLedgerShards.add p
  assert directLedgerShards.len == 0,
    "writer isolation: expected 0 shards directly under ledger/, got " &
    $directLedgerShards.len

  var statsShards: seq[string]
  for kind, p in walkDir(sd / "ledger" / "objcachestats"):
    if kind == pcFile and p.endsWith(".ndjson"):
      statsShards.add p
  assert statsShards.len == 1,
    "writer isolation: expected exactly 1 objcachestats shard, got " & $statsShards.len

# ---------------------------------------------------------------------------
# 3. torn-row-skip: malformed line tolerated, good rows survive
# ---------------------------------------------------------------------------

block test_torn_row_skip:
  let sd = freshStateDir("tornrow")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_y.nim::")

  var led = openObjCacheStatsLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeObjCacheStatsLedger(led)

  var shardFiles: seq[string]
  for kind, p in walkDir(sd / "ledger" / "objcachestats"):
    if kind == pcFile and p.endsWith(".ndjson"):
      shardFiles.add p
  assert shardFiles.len == 1, "torn-row-skip: expected exactly 1 shard"
  let shardPath = shardFiles[0]

  let f = open(shardPath, fmAppend)
  f.write("{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_y.nim::\",\"torn\n")
  f.close()

  var led2 = openObjCacheStatsLedger(sd)
  append(led2, sampleRow(ident, 3000))
  closeObjCacheStatsLedger(led2)

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 2, "torn-row-skip: expected 2 good rows, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 3000

# ---------------------------------------------------------------------------
# 4. header-version mismatch -> whole shard discarded
# ---------------------------------------------------------------------------

block test_header_version_mismatch:
  let sd = freshStateDir("hdrver")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_hdr.nim::")
  var led = openObjCacheStatsLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeObjCacheStatsLedger(led)

  createDir(sd / "ledger" / "objcachestats")
  let badShardPath = sd / "ledger" / "objcachestats" / "99999-badbad-1.ndjson"
  let f = open(badShardPath, fmWrite)
  f.write("{\"objCacheStatsLedgerFormatVersion\":9999}\n")
  f.write("{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_hdr.nim::\"," &
          "\"groupId\":\"unit\",\"configHash\":\"c\",\"hits\":1,\"misses\":1,\"stored\":1," &
          "\"disabled\":0,\"reusedBytes\":1,\"timestamp\":2000}\n")
  f.close()

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 1, "header-version mismatch: expected 1 row (bad shard discarded), got " & $rows.len
  assert rows[0].timestamp == 1000

echo "test_objcachestats: all blocks passed"
