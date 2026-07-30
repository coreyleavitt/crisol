## test_compilecost_gc.nim — RFC-0006 M-cost-split: compile-cost stream
## compaction + GC.
##
## Mirrors test_artifactledger_gc.nim's compactArtifactLedger coverage, over
## the compile-cost stream's compactCompileCostLedger.
##
## Coverage:
##   1. Single shard -> compacted to 1 file; scanCompileCostLedger round-trip
##      identical.
##   2. Multiple shards -> merged into 1; scanCompileCostLedger returns same
##      rows sorted by timestamp.
##   3. Age filter: rows older than maxAgeSecs dropped.
##   4. Torn shard tolerated: good rows from other shards survive compaction.
##   5. Empty compile-cost-ledger dir -> 0 shards removed, 0 rows kept, no error.
##   6. cleanOrphans reaches compactCompileCostLedger and reports counts.
##   7. cleanOrphans compacting the compile-cost stream leaves the exec
##      ledger's AND the artifact stream's own compaction results untouched
##      (all three streams compact independently in the same cleanOrphans
##      call).

import std/[os, strutils]
import std/posix as posix_mod
import crisol/[types, ledger, artifactledger, compilecost, clean]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshSD(tag: string): string =
  result = getTempDir() / ("crisol_ccgc_" & tag & "_" & $posix_mod.getpid())
  removeDir(result)
  createDir(result)

proc seedCompileCostShard(stateDir: string; name: string; rows: seq[CompileCostRow]) =
  ## Plant a shard directly (bypassing openCompileCostLedger), mirroring
  ## test_artifactledger_gc.nim's seedArtifactShard helper.
  let dir = stateDir / "ledger" / "compilecost"
  createDir(dir)
  var content = "{\"compileCostLedgerFormatVersion\":" & $compileCostLedgerFormatVersion & "}\n"
  for row in rows:
    content.add "{\"rowVersion\":" & $row.rowVersion &
      ",\"entrypointIdentity\":\"" & $row.entrypointIdentity & "\"" &
      ",\"groupId\":\"" & row.groupId & "\"" &
      ",\"configHash\":\"" & row.configHash & "\"" &
      ",\"codegenUs\":" & $row.codegenUs &
      ",\"ccUs\":" & $row.ccUs &
      ",\"linkUs\":" & $row.linkUs &
      ",\"timestamp\":" & $row.timestamp & "}\n"
  writeFile(dir / name, content)

proc makeCompileCostRow(identity: IdentityKey; ts: int64): CompileCostRow =
  CompileCostRow(
    rowVersion:         1,
    entrypointIdentity: identity,
    groupId:            "unit",
    configHash:         "cfg0000000000000",
    codegenUs:          100_000,
    ccUs:               400_000,
    linkUs:             50_000,
    timestamp:          ts,
  )

# ---------------------------------------------------------------------------
# 1. Single shard -> compacted to 1 file, scanCompileCostLedger round-trips
# ---------------------------------------------------------------------------

block test_compact_single_shard:
  let sd = freshSD("compact_single")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_a.nim::")
  let identB = IdentityKey("tests/unit/test_b.nim::")

  seedCompileCostShard(sd, "10000-abc-1.ndjson", @[
    makeCompileCostRow(identA, 1000),
    makeCompileCostRow(identB, 2000),
    makeCompileCostRow(identA, 3000),
  ])

  let r = compactCompileCostLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 1, "compact_single: expected 1 shard removed, got " & $r.shardsRemoved
  assert r.rowsKept == 3, "compact_single: expected 3 rows kept, got " & $r.rowsKept

  let rows = scanCompileCostLedger(sd)
  assert rows.len == 3, "compact_single: expected 3 rows via scan, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 2000
  assert rows[2].timestamp == 3000

  var ndjsonFiles = 0
  for kind, p in walkDir(sd / "ledger" / "compilecost"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ndjsonFiles
  assert ndjsonFiles == 1, "compact_single: expected 1 ndjson file after compact, got " & $ndjsonFiles

# ---------------------------------------------------------------------------
# 2. Multiple shards -> merged, scanCompileCostLedger returns all rows
# ---------------------------------------------------------------------------

block test_compact_multi_shard:
  let sd = freshSD("compact_multi")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_multi.nim::")

  seedCompileCostShard(sd, "s1-abc-1.ndjson", @[makeCompileCostRow(ident, 100), makeCompileCostRow(ident, 200)])
  seedCompileCostShard(sd, "s2-abc-1.ndjson", @[makeCompileCostRow(ident, 300)])
  seedCompileCostShard(sd, "s3-abc-1.ndjson", @[makeCompileCostRow(ident, 400), makeCompileCostRow(ident, 500)])

  let r = compactCompileCostLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 3, "compact_multi: expected 3 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 5, "compact_multi: expected 5 rows kept, got " & $r.rowsKept

  let rows = scanCompileCostLedger(sd)
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

  seedCompileCostShard(sd, "age-shard-1.ndjson",
    @[makeCompileCostRow(ident, staleTs), makeCompileCostRow(ident, freshTs)])

  let r = compactCompileCostLedger(sd, maxAgeSecs = maxAgeSecs, nowSecs = nowSecs)
  assert r.shardsRemoved == 1, "compact_age: expected 1 shard removed"
  assert r.rowsKept == 1, "compact_age: expected 1 row kept (stale dropped), got " & $r.rowsKept

  let rows = scanCompileCostLedger(sd)
  assert rows.len == 1, "compact_age: expected 1 row, got " & $rows.len
  assert rows[0].timestamp == freshTs, "compact_age: surviving row must be the fresh one"

# ---------------------------------------------------------------------------
# 4. Torn shard tolerated: good rows from other shards survive
# ---------------------------------------------------------------------------

block test_compact_torn_shard:
  let sd = freshSD("compact_torn")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_torn.nim::")

  seedCompileCostShard(sd, "good-shard-1.ndjson", @[makeCompileCostRow(ident, 1000)])

  let ccDir = sd / "ledger" / "compilecost"
  createDir(ccDir)
  writeFile(ccDir / "torn-shard-2.ndjson",
    "NOT A VALID HEADER\n" &
    "{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_torn.nim::\"," &
    "\"groupId\":\"unit\",\"configHash\":\"c\",\"codegenUs\":1,\"ccUs\":1,\"linkUs\":1," &
    "\"timestamp\":2000}\n")

  let r = compactCompileCostLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 2, "compact_torn: expected 2 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 1, "compact_torn: expected 1 row kept (torn shard discarded), got " & $r.rowsKept

  let rows = scanCompileCostLedger(sd)
  assert rows.len == 1, "compact_torn: expected 1 row, got " & $rows.len
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 5. Empty compile-cost-ledger dir -> no error, 0 shards, 0 rows
# ---------------------------------------------------------------------------

block test_compact_empty:
  let sd = freshSD("compact_empty")
  defer: removeDir(sd)
  let r = compactCompileCostLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 0
  assert r.rowsKept == 0

# ---------------------------------------------------------------------------
# 6 & 7. cleanOrphans reaches compactCompileCostLedger; exec ledger AND
# artifact-stream compaction in the same call are unaffected.
# ---------------------------------------------------------------------------

block test_cleanorphans_compacts_compilecost_stream:
  let root = getTempDir() / ("crisol_ccgc_cleanorphans_" & $posix_mod.getpid())
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

  # Seed ALL THREE streams with multiple shards each.
  seedCompileCostShard(stateDir, "cs1-x-1.ndjson", @[makeCompileCostRow(ccIdent, 1000)])
  seedCompileCostShard(stateDir, "cs2-x-1.ndjson", @[makeCompileCostRow(ccIdent, 2000)])

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

  # Compile-cost stream compacted: 2 shards merged into 1, 2 rows kept.
  assert r.compileCostShardsRemoved == 2,
    "cleanOrphans: expected 2 compile-cost shards removed, got " & $r.compileCostShardsRemoved
  assert r.compileCostRowsKept == 2,
    "cleanOrphans: expected 2 compile-cost rows kept, got " & $r.compileCostRowsKept

  let ccRows = scanCompileCostLedger(stateDir)
  assert ccRows.len == 2, "cleanOrphans: compile-cost scan expected 2 rows, got " & $ccRows.len

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

  # Exactly 1 compacted file per stream, in the correct directories.
  var ccFiles = 0
  for kind, p in walkDir(stateDir / "ledger" / "compilecost"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ccFiles
  assert ccFiles == 1, "cleanOrphans: expected 1 compacted compile-cost shard, got " & $ccFiles

echo "test_compilecost_gc: all blocks passed"
