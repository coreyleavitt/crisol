## test_artifactledger_gc.nim — RFC-0006 M0: artifact stream compaction + GC.
##
## Mirrors test_a1c_gc.nim's compactLedger coverage, over the artifact
## stream's compactArtifactLedger — its own compaction/GC pass (round-2 gap:
## the artifact stream must not accumulate one shard per invocation forever).
##
## Coverage:
##   1. Single shard → compacted to 1 file; scanArtifactLedger round-trip
##      identical.
##   2. Multiple shards → merged into 1; scanArtifactLedger returns same rows
##      sorted by timestamp.
##   3. Age filter: rows older than maxAgeSecs dropped.
##   4. Torn shard tolerated: good rows from other shards survive compaction.
##   5. Empty artifact-ledger dir → 0 shards removed, 0 rows kept, no error.
##   6. cleanOrphans reaches compactArtifactLedger and reports counts —
##      GC is reachable from the same entry point as the exec ledger's.
##   7. cleanOrphans compacting the artifact stream leaves the exec ledger's
##      own compaction result untouched (both streams compact independently
##      in the same cleanOrphans call — proves exec path is not disturbed).

import std/[os, strutils]
import std/posix as posix_mod
import crisol/[types, ledger, artifactledger, clean]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshSD(tag: string): string =
  result = getTempDir() / ("crisol_artgc_" & tag & "_" & $posix_mod.getpid())
  removeDir(result)
  createDir(result)

proc seedArtifactShard(stateDir: string; name: string; rows: seq[ArtifactRow]) =
  ## Plant a shard directly (bypassing openArtifactLedger), mirroring
  ## test_a1c_gc.nim's seedLedgerShard helper.
  let dir = stateDir / "ledger" / "artifacts"
  createDir(dir)
  var content = "{\"artifactLedgerFormatVersion\":" & $artifactLedgerFormatVersion & "}\n"
  for row in rows:
    content.add "{\"rowVersion\":" & $row.rowVersion &
      ",\"entrypointIdentity\":\"" & $row.entrypointIdentity & "\"" &
      ",\"groupId\":\"" & row.groupId & "\"" &
      ",\"configHash\":\"" & row.configHash & "\"" &
      ",\"artifactBasename\":\"" & row.artifactBasename & "\"" &
      ",\"keyHash\":\"" & row.keyHash & "\"" &
      ",\"sizeBytes\":" & $row.sizeBytes &
      ",\"ccTimeUs\":" & $row.ccTimeUs &
      ",\"timestamp\":" & $row.timestamp & "}\n"
  writeFile(dir / name, content)

proc makeArtifactRow(identity: IdentityKey; ts: int64): ArtifactRow =
  ArtifactRow(
    rowVersion:         1,
    entrypointIdentity: identity,
    groupId:            "unit",
    configHash:         "cfg0000000000000",
    artifactBasename:   "@pchronos.nim.c",
    keyHash:            "keyhash000000000",
    sizeBytes:          4096,
    ccTimeUs:           1000,
    timestamp:          ts,
  )

# ---------------------------------------------------------------------------
# 1. Single shard → compacted to 1 file, scanArtifactLedger round-trips
# ---------------------------------------------------------------------------

block test_compact_single_shard:
  let sd = freshSD("compact_single")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_a.nim::")
  let identB = IdentityKey("tests/unit/test_b.nim::")

  seedArtifactShard(sd, "10000-abc-1.ndjson", @[
    makeArtifactRow(identA, 1000),
    makeArtifactRow(identB, 2000),
    makeArtifactRow(identA, 3000),
  ])

  let r = compactArtifactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 1, "compact_single: expected 1 shard removed, got " & $r.shardsRemoved
  assert r.rowsKept == 3, "compact_single: expected 3 rows kept, got " & $r.rowsKept

  let rows = scanArtifactLedger(sd)
  assert rows.len == 3, "compact_single: expected 3 rows via scan, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 2000
  assert rows[2].timestamp == 3000

  var ndjsonFiles = 0
  for kind, p in walkDir(sd / "ledger" / "artifacts"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ndjsonFiles
  assert ndjsonFiles == 1, "compact_single: expected 1 ndjson file after compact, got " & $ndjsonFiles

# ---------------------------------------------------------------------------
# 2. Multiple shards → merged, scanArtifactLedger returns all rows
# ---------------------------------------------------------------------------

block test_compact_multi_shard:
  let sd = freshSD("compact_multi")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_multi.nim::")

  seedArtifactShard(sd, "s1-abc-1.ndjson", @[makeArtifactRow(ident, 100), makeArtifactRow(ident, 200)])
  seedArtifactShard(sd, "s2-abc-1.ndjson", @[makeArtifactRow(ident, 300)])
  seedArtifactShard(sd, "s3-abc-1.ndjson", @[makeArtifactRow(ident, 400), makeArtifactRow(ident, 500)])

  let r = compactArtifactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 3, "compact_multi: expected 3 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 5, "compact_multi: expected 5 rows kept, got " & $r.rowsKept

  let rows = scanArtifactLedger(sd)
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

  seedArtifactShard(sd, "age-shard-1.ndjson",
    @[makeArtifactRow(ident, staleTs), makeArtifactRow(ident, freshTs)])

  let r = compactArtifactLedger(sd, maxAgeSecs = maxAgeSecs, nowSecs = nowSecs)
  assert r.shardsRemoved == 1, "compact_age: expected 1 shard removed"
  assert r.rowsKept == 1, "compact_age: expected 1 row kept (stale dropped), got " & $r.rowsKept

  let rows = scanArtifactLedger(sd)
  assert rows.len == 1, "compact_age: expected 1 row, got " & $rows.len
  assert rows[0].timestamp == freshTs, "compact_age: surviving row must be the fresh one"

# ---------------------------------------------------------------------------
# 4. Torn shard tolerated: good rows from other shards survive
# ---------------------------------------------------------------------------

block test_compact_torn_shard:
  let sd = freshSD("compact_torn")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_torn.nim::")

  seedArtifactShard(sd, "good-shard-1.ndjson", @[makeArtifactRow(ident, 1000)])

  let artDir = sd / "ledger" / "artifacts"
  createDir(artDir)
  writeFile(artDir / "torn-shard-2.ndjson",
    "NOT A VALID HEADER\n" &
    "{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_torn.nim::\"," &
    "\"groupId\":\"unit\",\"configHash\":\"c\",\"artifactBasename\":\"@pfoo.nim.c\"," &
    "\"keyHash\":\"k\",\"sizeBytes\":1,\"ccTimeUs\":1,\"timestamp\":2000}\n")

  let r = compactArtifactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 2, "compact_torn: expected 2 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 1, "compact_torn: expected 1 row kept (torn shard discarded), got " & $r.rowsKept

  let rows = scanArtifactLedger(sd)
  assert rows.len == 1, "compact_torn: expected 1 row, got " & $rows.len
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 5. Empty artifact-ledger dir → no error, 0 shards, 0 rows
# ---------------------------------------------------------------------------

block test_compact_empty:
  let sd = freshSD("compact_empty")
  defer: removeDir(sd)
  let r = compactArtifactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 0
  assert r.rowsKept == 0

# ---------------------------------------------------------------------------
# 6 & 7. cleanOrphans reaches compactArtifactLedger; exec ledger compaction
# in the same call is unaffected by the artifact stream's presence.
# ---------------------------------------------------------------------------

block test_cleanorphans_compacts_artifact_stream:
  let root = getTempDir() / ("crisol_artgc_cleanorphans_" & $posix_mod.getpid())
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

  # Seed BOTH streams with multiple shards each.
  seedArtifactShard(stateDir, "as1-x-1.ndjson", @[makeArtifactRow(artIdent, 1000)])
  seedArtifactShard(stateDir, "as2-x-1.ndjson", @[makeArtifactRow(artIdent, 2000)])

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

  # Artifact stream compacted: 2 shards merged into 1, 2 rows kept.
  assert r.artifactShardsRemoved == 2,
    "cleanOrphans: expected 2 artifact shards removed, got " & $r.artifactShardsRemoved
  assert r.artifactRowsKept == 2,
    "cleanOrphans: expected 2 artifact rows kept, got " & $r.artifactRowsKept

  let artRows = scanArtifactLedger(stateDir)
  assert artRows.len == 2, "cleanOrphans: artifact scan expected 2 rows, got " & $artRows.len

  # Exec ledger compaction in the SAME call is unaffected: still 2 shards
  # merged, 2 rows kept, via the untouched exec path.
  assert r.shardsRemoved == 2,
    "cleanOrphans: expected 2 exec shards removed, got " & $r.shardsRemoved
  assert r.ledgerRowsKept == 2,
    "cleanOrphans: expected 2 exec rows kept, got " & $r.ledgerRowsKept

  let execRows = ledger.scanLedger(stateDir, execIdent)
  assert execRows.len == 2, "cleanOrphans: exec scan expected 2 rows, got " & $execRows.len

  # Exactly 1 compacted file per stream, in the correct directories.
  var artFiles = 0
  for kind, p in walkDir(stateDir / "ledger" / "artifacts"):
    if kind == pcFile and p.endsWith(".ndjson"): inc artFiles
  assert artFiles == 1, "cleanOrphans: expected 1 compacted artifact shard, got " & $artFiles

  var execFiles = 0
  for kind, p in walkDir(stateDir / "ledger"):
    if kind == pcFile and p.endsWith(".ndjson"): inc execFiles
  assert execFiles == 1, "cleanOrphans: expected 1 compacted exec shard (direct child), got " & $execFiles

echo "test_artifactledger_gc: all blocks passed"
