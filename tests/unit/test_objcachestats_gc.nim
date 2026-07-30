## test_objcachestats_gc.nim — RFC-0006 Stage R, R5a: objcache-stats stream
## compaction + GC.
##
## Mirrors test_compilecost_gc.nim's compactCompileCostLedger coverage, over
## the objcache-stats stream's compactObjCacheStatsLedger.
##
## Coverage:
##   1. Single shard -> compacted to 1 file; scanObjCacheStatsLedger
##      round-trip identical.
##   2. Multiple shards -> merged into 1; scanObjCacheStatsLedger returns
##      same rows sorted by timestamp.
##   3. Age filter: rows older than maxAgeSecs dropped.
##   4. Empty objcachestats-ledger dir -> 0 shards removed, 0 rows kept, no
##      error.
##   5. cleanOrphans reaches compactObjCacheStatsLedger and reports counts.
##   6. cleanOrphans compacting the objcachestats stream leaves the exec
##      ledger's, the artifact stream's, AND the compile-cost stream's own
##      compaction results untouched (all four streams compact independently
##      in the same cleanOrphans call).

import std/[os, strutils]
import std/posix as posix_mod
import crisol/[types, ledger, artifactledger, compilecost, objcachestats, clean]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshSD(tag: string): string =
  result = getTempDir() / ("crisol_ocsgc_" & tag & "_" & $posix_mod.getpid())
  removeDir(result)
  createDir(result)

proc seedObjCacheStatsShard(stateDir: string; name: string; rows: seq[ObjCacheStatsRow]) =
  ## Plant a shard directly (bypassing openObjCacheStatsLedger), mirroring
  ## test_compilecost_gc.nim's seedCompileCostShard helper.
  let dir = stateDir / "ledger" / "objcachestats"
  createDir(dir)
  var content = "{\"objCacheStatsLedgerFormatVersion\":" & $objCacheStatsLedgerFormatVersion & "}\n"
  for row in rows:
    content.add "{\"rowVersion\":" & $row.rowVersion &
      ",\"entrypointIdentity\":\"" & $row.entrypointIdentity & "\"" &
      ",\"groupId\":\"" & row.groupId & "\"" &
      ",\"configHash\":\"" & row.configHash & "\"" &
      ",\"hits\":" & $row.hits &
      ",\"misses\":" & $row.misses &
      ",\"stored\":" & $row.stored &
      ",\"disabled\":" & $row.disabled &
      ",\"reusedBytes\":" & $row.reusedBytes &
      ",\"timestamp\":" & $row.timestamp & "}\n"
  writeFile(dir / name, content)

proc makeRow(identity: IdentityKey; ts: int64): ObjCacheStatsRow =
  ObjCacheStatsRow(
    rowVersion:         1,
    entrypointIdentity: identity,
    groupId:            "unit",
    configHash:         "cfg0000000000000",
    hits:               3,
    misses:             2,
    stored:             1,
    disabled:           1,
    reusedBytes:        4096,
    timestamp:          ts,
  )

# ---------------------------------------------------------------------------
# 1. Single shard -> compacted to 1 file, scanObjCacheStatsLedger round-trips
# ---------------------------------------------------------------------------

block test_compact_single_shard:
  let sd = freshSD("compact_single")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_a.nim::")
  let identB = IdentityKey("tests/unit/test_b.nim::")

  seedObjCacheStatsShard(sd, "10000-abc-1.ndjson", @[
    makeRow(identA, 1000),
    makeRow(identB, 2000),
    makeRow(identA, 3000),
  ])

  let r = compactObjCacheStatsLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 1, "compact_single: expected 1 shard removed, got " & $r.shardsRemoved
  assert r.rowsKept == 3, "compact_single: expected 3 rows kept, got " & $r.rowsKept

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 3, "compact_single: expected 3 rows via scan, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 2000
  assert rows[2].timestamp == 3000

  var ndjsonFiles = 0
  for kind, p in walkDir(sd / "ledger" / "objcachestats"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ndjsonFiles
  assert ndjsonFiles == 1, "compact_single: expected 1 ndjson file after compact, got " & $ndjsonFiles

# ---------------------------------------------------------------------------
# 2. Multiple shards -> merged, scanObjCacheStatsLedger returns all rows
# ---------------------------------------------------------------------------

block test_compact_multi_shard:
  let sd = freshSD("compact_multi")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_multi.nim::")

  seedObjCacheStatsShard(sd, "s1-abc-1.ndjson", @[makeRow(ident, 100), makeRow(ident, 200)])
  seedObjCacheStatsShard(sd, "s2-abc-1.ndjson", @[makeRow(ident, 300)])
  seedObjCacheStatsShard(sd, "s3-abc-1.ndjson", @[makeRow(ident, 400), makeRow(ident, 500)])

  let r = compactObjCacheStatsLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 3, "compact_multi: expected 3 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 5, "compact_multi: expected 5 rows kept, got " & $r.rowsKept

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 5, "compact_multi: expected 5 rows after compact, got " & $rows.len
  for i in 0 ..< rows.len:
    assert rows[i].timestamp == int64((i + 1) * 100),
      "compact_multi: row " & $i & " timestamp wrong"

# ---------------------------------------------------------------------------
# 3. Age filter drops old rows
# ---------------------------------------------------------------------------

block test_compact_age_filter:
  let sd = freshSD("compact_age")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_age.nim::")
  let nowSecs: int64 = 1_700_000_000
  let maxAgeSecs: int64 = 7 * 86_400

  let freshTs: int64 = (nowSecs - 3 * 86_400) * 1_000_000
  let staleTs: int64 = (nowSecs - 10 * 86_400) * 1_000_000

  seedObjCacheStatsShard(sd, "age-shard-1.ndjson",
    @[makeRow(ident, staleTs), makeRow(ident, freshTs)])

  let r = compactObjCacheStatsLedger(sd, maxAgeSecs = maxAgeSecs, nowSecs = nowSecs)
  assert r.shardsRemoved == 1, "compact_age: expected 1 shard removed"
  assert r.rowsKept == 1, "compact_age: expected 1 row kept (stale dropped), got " & $r.rowsKept

  let rows = scanObjCacheStatsLedger(sd)
  assert rows.len == 1, "compact_age: expected 1 row, got " & $rows.len
  assert rows[0].timestamp == freshTs, "compact_age: surviving row must be the fresh one"

# ---------------------------------------------------------------------------
# 4. Empty objcachestats-ledger dir -> no error, 0 shards, 0 rows
# ---------------------------------------------------------------------------

block test_compact_empty:
  let sd = freshSD("compact_empty")
  defer: removeDir(sd)
  let r = compactObjCacheStatsLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 0
  assert r.rowsKept == 0

# ---------------------------------------------------------------------------
# 5 & 6. cleanOrphans reaches compactObjCacheStatsLedger; exec ledger AND
# artifact stream AND compile-cost stream compaction in the same call are
# unaffected.
# ---------------------------------------------------------------------------

block test_cleanorphans_compacts_objcachestats_stream:
  let root = getTempDir() / ("crisol_ocsgc_cleanorphans_" & $posix_mod.getpid())
  removeDir(root)
  createDir(root)
  defer: removeDir(root)

  let cfg = Config(
    projectRoot:        root,
    stateDir:           ".crisol",
    jobs:               1,
    timeoutSecs:        300,
    compileTimeoutSecs: 600,
    maxOutputBytes:     1024 * 1024,
    maxCacheEntries:    0,
    cacheMaxAgeDays:    0,
    ledgerMaxAgeDays:   0,
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

  let stateDir = root / ".crisol"
  let execIdent = IdentityKey("tests/unit/test_exec.nim::")
  let artIdent  = IdentityKey("tests/unit/test_art.nim::")
  let ccIdent   = IdentityKey("tests/unit/test_cc.nim::")
  let ocsIdent  = IdentityKey("tests/unit/test_ocs.nim::")

  # Seed ALL FOUR streams with multiple shards each.
  seedObjCacheStatsShard(stateDir, "os1-x-1.ndjson", @[makeRow(ocsIdent, 1000)])
  seedObjCacheStatsShard(stateDir, "os2-x-1.ndjson", @[makeRow(ocsIdent, 2000)])

  let ccDir = stateDir / "ledger" / "compilecost"
  createDir(ccDir)
  writeFile(ccDir / "cs1-x-1.ndjson",
    "{\"compileCostLedgerFormatVersion\":1}\n" &
    "{\"rowVersion\":1,\"entrypointIdentity\":\"" & $ccIdent & "\",\"groupId\":\"unit\"," &
    "\"configHash\":\"c\",\"codegenUs\":1,\"ccUs\":1,\"linkUs\":1,\"timestamp\":1000}\n")

  let artDir = stateDir / "ledger" / "artifacts"
  createDir(artDir)
  writeFile(artDir / "as1-x-1.ndjson",
    "{\"artifactLedgerFormatVersion\":1}\n" &
    "{\"rowVersion\":1,\"entrypointIdentity\":\"" & $artIdent & "\",\"groupId\":\"unit\"," &
    "\"configHash\":\"c\",\"artifactBasename\":\"@pfoo.nim.c\",\"keyHash\":\"k\"," &
    "\"sizeBytes\":1,\"ccTimeUs\":1,\"timestamp\":1000}\n")

  let execLedgerDir = stateDir / "ledger"
  createDir(execLedgerDir)
  writeFile(execLedgerDir / "es1-x-1.ndjson",
    "{\"historyFormatVersion\":1}\n" &
    "{\"rowVersion\":1,\"identity\":\"" & $execIdent & "\",\"timestamp\":500," &
    "\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":1000,\"rssBytes\":4096}\n")
  writeFile(execLedgerDir / "es2-x-1.ndjson",
    "{\"historyFormatVersion\":1}\n" &
    "{\"rowVersion\":1,\"identity\":\"" & $execIdent & "\",\"timestamp\":1500," &
    "\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":1000,\"rssBytes\":4096}\n")

  let r = cleanOrphans(cfg)

  # ObjCache-stats stream compacted: 2 shards merged into 1, 2 rows kept.
  assert r.objCacheStatsShardsRemoved == 2,
    "cleanOrphans: expected 2 objcachestats shards removed, got " & $r.objCacheStatsShardsRemoved
  assert r.objCacheStatsRowsKept == 2,
    "cleanOrphans: expected 2 objcachestats rows kept, got " & $r.objCacheStatsRowsKept

  let ocsRows = scanObjCacheStatsLedger(stateDir)
  assert ocsRows.len == 2, "cleanOrphans: objcachestats scan expected 2 rows, got " & $ocsRows.len

  # Compile-cost stream compaction in the SAME call is unaffected.
  assert r.compileCostShardsRemoved == 1,
    "cleanOrphans: expected 1 compile-cost shard removed, got " & $r.compileCostShardsRemoved
  assert r.compileCostRowsKept == 1,
    "cleanOrphans: expected 1 compile-cost row kept, got " & $r.compileCostRowsKept

  # Artifact stream compaction in the SAME call is unaffected.
  assert r.artifactShardsRemoved == 1,
    "cleanOrphans: expected 1 artifact shard removed, got " & $r.artifactShardsRemoved
  assert r.artifactRowsKept == 1,
    "cleanOrphans: expected 1 artifact row kept, got " & $r.artifactRowsKept

  # Exec ledger compaction in the SAME call is unaffected.
  assert r.shardsRemoved == 2,
    "cleanOrphans: expected 2 exec shards removed, got " & $r.shardsRemoved
  assert r.ledgerRowsKept == 2,
    "cleanOrphans: expected 2 exec rows kept, got " & $r.ledgerRowsKept

  let execRows = ledger.scanLedger(stateDir, execIdent)
  assert execRows.len == 2, "cleanOrphans: exec scan expected 2 rows, got " & $execRows.len

  # Exactly 1 compacted file per stream, in the correct directory.
  var ocsFiles = 0
  for kind, p in walkDir(stateDir / "ledger" / "objcachestats"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ocsFiles
  assert ocsFiles == 1, "cleanOrphans: expected 1 compacted objcachestats shard, got " & $ocsFiles

echo "test_objcachestats_gc: all blocks passed"
