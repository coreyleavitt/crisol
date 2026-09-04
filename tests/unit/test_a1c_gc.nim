## test_a1c_gc.nim — A1c: result-cache GC + ledger compaction.
##
## TDD: tests written for the A1c slice.  All clock inputs are injected so
## every test is deterministic (no real-time dependency).
##
## Coverage:
##
##  gcResultCache:
##   1. Under cap + all fresh → nothing evicted.
##   2. Size bound: > maxEntries → oldest evicted, newest kept.
##   3. Age bound: too-old entries removed (even when under cap).
##   4. Age + size combined: age pass first, then size.
##   5. Malformed file (invalid JSON) → treated as cachedAt=0 (oldest) → evicted first.
##   6. Empty cache dir → 0 evictions, no error.
##
##  compactLedger:
##   7. Single shard → compacted to 1 file; scanLedger round-trip identical.
##   8. Multiple shards → merged into 1; scanLedger returns same rows sorted by ts.
##   9. Age filter: rows older than maxAgeSecs dropped.
##  10. Torn shard tolerated: good rows from other shards survive compaction.
##  11. Empty ledger dir → 0 shards removed, 0 rows kept, no error.
##
##  cleanOrphans integration:
##  12. cleanOrphans evicts over-cap result-cache entries + returns count.
##  13. cleanOrphans compacts ledger shards + returns counts.
##
##  RFC-0005 B1b — orphan sidecar pruning (inside gcResultCacheAt's walk):
##  14. entry evicted (age bound) -> its path's sidecar is pruned.
##  15. entry NOT evicted -> its path's sidecar survives.
##  16. a sidecar with multiple records survives if ANY record's key is
##      still live, even when others are not.
##  17. a sidecar all of whose records are dead (evicted or never-live) is
##      pruned entirely.
##  18. a corrupt/malformed sidecar file is pruned too (never crashes GC).
##  19. sidecars are outside countCacheEntries's cap glob / the LRU walk:
##      exactly-at-cap real entries + extra sidecars in the same verDir ->
##      0 evictions (sidecars never inflate the apparent entry count).

import std/[os, json, options, sequtils, strutils, tables, times]
import std/posix as posix_mod
import crisol/[types, resultcache, ledger, clean, depgraph]
import crisol/keys
import crisol/cachewire
import crisol/cachelocalfs
import crisol/process/types as ptypes  # default(Limits) for the sidecar fixtures below

# ---------------------------------------------------------------------------
# Helpers — state-dir factories
# ---------------------------------------------------------------------------

proc freshSD(tag: string): string =
  result = getTempDir() / ("crisol_a1c_" & tag & "_" & $posix_mod.getpid())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Helpers — seed a result-cache entry with a specific cachedAt
# ---------------------------------------------------------------------------

proc seedCacheEntry(stateDir: string; key: string; cachedAt: int64) =
  ## Write a minimal valid cache JSON file with the given cachedAt.
  ## We bypass storeCached here so we can set arbitrary cachedAt values
  ## without relying on real clock time.
  let verDir = stateDir / "cache" / ("v" & $resultCacheFormatVersion)
  createDir(verDir)
  # Build a minimal valid cache file manually.
  # We need a valid checksum over the payload — use a simple payload.
  let payloadNode = newJObject()
  payloadNode["outcome"]    = newJString("oPassed")
  payloadNode["exitCode"]   = newJInt(0)
  payloadNode["signal"]     = newJInt(0)
  payloadNode["durationMs"] = newJInt(100)
  payloadNode["cachedAt"]   = newJInt(cachedAt)
  payloadNode["records"]    = newJArray()

  let checksum = toHex16(fnv1a64($payloadNode))

  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)

  let fileNode = newJObject()
  fileNode["header"]          = headerNode
  fileNode["payloadChecksum"] = newJString(checksum)
  fileNode["payload"]         = payloadNode

  writeFile(verDir / (key & ".json"), $fileNode)

# ---------------------------------------------------------------------------
# Helpers — plant a ledger shard directly (bypassing openLedger)
# ---------------------------------------------------------------------------

proc seedLedgerShard(stateDir: string; name: string; rows: seq[LedgerRow]) =
  let ledgerDir = stateDir / "ledger"
  createDir(ledgerDir)
  var content = "{\"historyFormatVersion\":" & $historyFormatVersion & "}\n"
  for row in rows:
    # Re-use ledger's internal rowToJsonLine by going through the public API indirectly.
    # We hand-serialize here to avoid exposing private procs.
    var n = newJObject()
    n["rowVersion"]  = newJInt(row.rowVersion)
    n["identity"]    = newJString($row.identity)
    n["timestamp"]   = newJInt(row.timestamp)
    n["inputHash"]   = newJString(row.inputHash)
    n["outcome"]     = newJString(row.outcome)
    n["attempt"]     = newJInt(row.attempt)
    n["durationUs"]  = newJInt(row.durationUs)
    n["rssBytes"]    = newJInt(row.rssBytes)
    content.add $n & "\n"
  writeFile(stateDir / "ledger" / name, content)

proc makeRow(identity: IdentityKey; ts: int64): LedgerRow =
  LedgerRow(
    rowVersion: 1,
    identity:   identity,
    timestamp:  ts,
    inputHash:  "abc",
    outcome:    "passed",
    attempt:    1,
    durationUs: 1000,
    rssBytes:   4096,
  )

# ---------------------------------------------------------------------------
# 1. Under cap + all fresh → nothing evicted
# ---------------------------------------------------------------------------

block test_gc_nothing_to_evict:
  let sd = freshSD("gc_nothing")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  seedCacheEntry(sd, "aaaa0000aaaa0000", now - 100)
  seedCacheEntry(sd, "bbbb0000bbbb0000", now - 50)

  let r = gcResultCache(sd, maxEntries = 10, maxAgeSecs = 0, nowSecs = now)
  assert r.evicted == 0, "nothing to evict: got " & $r.evicted

  # Both files still present.
  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  assert fileExists(verDir / "aaaa0000aaaa0000.json")
  assert fileExists(verDir / "bbbb0000bbbb0000.json")

# ---------------------------------------------------------------------------
# 2. Size bound: > maxEntries → oldest evicted, newest kept
# ---------------------------------------------------------------------------

block test_gc_size_bound:
  let sd = freshSD("gc_size")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  # Seed 5 entries with increasing cachedAt (older = smaller value = lower key).
  let keys = ["k0000000000000000", "k1111111111111111", "k2222222222222222",
              "k3333333333333333", "k4444444444444444"]
  for i, k in keys:
    seedCacheEntry(sd, k, now - int64(500 - i * 100))
    # timestamps: now-500, now-400, now-300, now-200, now-100

  # Keep only 3 → evict the 2 oldest (keys[0] and keys[1]).
  let r = gcResultCache(sd, maxEntries = 3, maxAgeSecs = 0, nowSecs = now)
  assert r.evicted == 2, "size bound: expected 2 evicted, got " & $r.evicted

  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  # Oldest 2 must be gone.
  assert not fileExists(verDir / (keys[0] & ".json")), "oldest must be evicted"
  assert not fileExists(verDir / (keys[1] & ".json")), "2nd oldest must be evicted"
  # Newest 3 must survive.
  assert fileExists(verDir / (keys[2] & ".json")), "3rd oldest must survive"
  assert fileExists(verDir / (keys[3] & ".json")), "4th oldest must survive"
  assert fileExists(verDir / (keys[4] & ".json")), "newest must survive"

# ---------------------------------------------------------------------------
# 3. Age bound: too-old entries removed (under cap)
# ---------------------------------------------------------------------------

block test_gc_age_bound:
  let sd = freshSD("gc_age")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let maxAge: int64 = 7 * 86_400  # 7 days in seconds

  # Fresh entry (within age bound).
  seedCacheEntry(sd, "fresh000fresh0000", now - int64(3 * 86_400))
  # Stale entry (beyond age bound).
  seedCacheEntry(sd, "stale000stale0000", now - int64(10 * 86_400))

  let r = gcResultCache(sd, maxEntries = 100, maxAgeSecs = maxAge, nowSecs = now)
  assert r.evicted == 1, "age bound: expected 1 evicted, got " & $r.evicted

  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  assert fileExists(verDir / "fresh000fresh0000.json"), "fresh entry must survive"
  assert not fileExists(verDir / "stale000stale0000.json"), "stale entry must be evicted"

# ---------------------------------------------------------------------------
# 4. Age + size combined: age pass first, then size
# ---------------------------------------------------------------------------

block test_gc_age_and_size:
  let sd = freshSD("gc_agesize")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let maxAge: int64 = 7 * 86_400  # 7 days

  # 4 entries: 1 very stale, 3 fresh but we only want to keep 2.
  seedCacheEntry(sd, "very0000stale0000", now - int64(30 * 86_400))  # age-evicted
  seedCacheEntry(sd, "fresh00000000old0", now - int64(5 * 86_400))   # oldest fresh
  seedCacheEntry(sd, "fresh0000000mid00", now - int64(3 * 86_400))   # middle fresh
  seedCacheEntry(sd, "fresh0000000new00", now - int64(1 * 86_400))   # newest fresh

  # maxAge removes the stale one → 3 remain → maxEntries=2 → evict oldest of 3.
  let r = gcResultCache(sd, maxEntries = 2, maxAgeSecs = maxAge, nowSecs = now)
  assert r.evicted == 2, "age+size: expected 2 evicted, got " & $r.evicted

  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  assert not fileExists(verDir / "very0000stale0000.json"), "very stale must be evicted"
  assert not fileExists(verDir / "fresh00000000old0.json"), "oldest fresh must be evicted"
  assert fileExists(verDir / "fresh0000000mid00.json"),   "middle fresh must survive"
  assert fileExists(verDir / "fresh0000000new00.json"),   "newest fresh must survive"

# ---------------------------------------------------------------------------
# 5. Malformed file → treated as cachedAt=0 → evicted first
# ---------------------------------------------------------------------------

block test_gc_malformed_file:
  let sd = freshSD("gc_malformed")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  createDir(verDir)

  # Write a malformed (non-JSON) file that the GC must handle without crashing.
  writeFile(verDir / "badfile000bad0000.json", "this is not json !!!")
  # Write one valid entry (newer).
  seedCacheEntry(sd, "good0000good0000", now - 10)

  # With maxEntries=1, the malformed file (cachedAt=0 = oldest) must be evicted.
  let r = gcResultCache(sd, maxEntries = 1, maxAgeSecs = 0, nowSecs = now)
  assert r.evicted == 1, "malformed: expected 1 evicted, got " & $r.evicted
  assert not fileExists(verDir / "badfile000bad0000.json"), "malformed must be evicted"
  assert fileExists(verDir / "good0000good0000.json"), "valid entry must survive"

# ---------------------------------------------------------------------------
# 6. Empty cache dir → 0 evictions, no error
# ---------------------------------------------------------------------------

block test_gc_empty_dir:
  let sd = freshSD("gc_empty")
  defer: removeDir(sd)

  # Don't create the cache dir at all.
  let r = gcResultCache(sd, maxEntries = 100, maxAgeSecs = 86_400, nowSecs = 1_700_000_000)
  assert r.evicted == 0, "empty dir: expected 0 evicted"

# ---------------------------------------------------------------------------
# 7. compactLedger: single shard → 1 compacted file, scanLedger round-trips
# ---------------------------------------------------------------------------

block test_compact_single_shard:
  let sd = freshSD("compact_single")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_a.nim::")
  let identB = IdentityKey("tests/unit/test_b.nim::")

  seedLedgerShard(sd, "10000-abc-1.ndjson", @[
    makeRow(identA, 1000),
    makeRow(identB, 2000),
    makeRow(identA, 3000),
  ])

  let r = compactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 1, "compact_single: expected 1 shard removed, got " & $r.shardsRemoved
  assert r.rowsKept == 3, "compact_single: expected 3 rows kept, got " & $r.rowsKept

  # scanLedger must see all rows for each identity.
  let rowsA = scanLedger(sd, identA)
  assert rowsA.len == 2, "compact_single: identA expected 2 rows, got " & $rowsA.len
  assert rowsA[0].timestamp == 1000
  assert rowsA[1].timestamp == 3000

  let rowsB = scanLedger(sd, identB)
  assert rowsB.len == 1, "compact_single: identB expected 1 row, got " & $rowsB.len
  assert rowsB[0].timestamp == 2000

  # There must be exactly 1 .ndjson file (the compacted one).
  var ndjsonFiles = 0
  for kind, p in walkDir(sd / "ledger"):
    if kind == pcFile and p.endsWith(".ndjson"): inc ndjsonFiles
  assert ndjsonFiles == 1, "compact_single: expected 1 ndjson file after compact, got " & $ndjsonFiles

# ---------------------------------------------------------------------------
# 8. compactLedger: multiple shards → merged, scanLedger returns all rows
# ---------------------------------------------------------------------------

block test_compact_multi_shard:
  let sd = freshSD("compact_multi")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_multi.nim::")

  # Three shards with different rows.
  seedLedgerShard(sd, "s1-abc-1.ndjson", @[makeRow(ident, 100), makeRow(ident, 200)])
  seedLedgerShard(sd, "s2-abc-1.ndjson", @[makeRow(ident, 300)])
  seedLedgerShard(sd, "s3-abc-1.ndjson", @[makeRow(ident, 400), makeRow(ident, 500)])

  let r = compactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 3, "compact_multi: expected 3 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 5, "compact_multi: expected 5 rows kept, got " & $r.rowsKept

  let rows = scanLedger(sd, ident)
  assert rows.len == 5, "compact_multi: expected 5 rows after compact, got " & $rows.len
  # Must be in timestamp order.
  for i in 0 ..< rows.len:
    assert rows[i].timestamp == int64((i + 1) * 100),
      "compact_multi: row " & $i & " timestamp wrong"

# ---------------------------------------------------------------------------
# 9. compactLedger: age filter drops old rows
# ---------------------------------------------------------------------------

block test_compact_age_filter:
  let sd = freshSD("compact_age")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_age.nim::")
  # Timestamps are microseconds; nowSecs is seconds.
  let nowSecs: int64 = 1_700_000_000
  let maxAgeSecs: int64 = 7 * 86_400   # 7 days

  # Fresh rows (within age bound in µs).
  let freshTs: int64 = (nowSecs - 3 * 86_400) * 1_000_000
  # Stale rows (beyond age bound in µs).
  let staleTs: int64 = (nowSecs - 10 * 86_400) * 1_000_000

  var staleRow = makeRow(ident, staleTs)
  var freshRow = makeRow(ident, freshTs)

  seedLedgerShard(sd, "age-shard-1.ndjson", @[staleRow, freshRow])

  let r = compactLedger(sd, maxAgeSecs = maxAgeSecs, nowSecs = nowSecs)
  assert r.shardsRemoved == 1, "compact_age: expected 1 shard removed"
  assert r.rowsKept == 1, "compact_age: expected 1 row kept (stale dropped), got " & $r.rowsKept

  let rows = scanLedger(sd, ident)
  assert rows.len == 1, "compact_age: scanLedger expected 1 row, got " & $rows.len
  assert rows[0].timestamp == freshTs, "compact_age: surviving row must be the fresh one"

# ---------------------------------------------------------------------------
# 10. Torn shard tolerated: good rows from other shards survive
# ---------------------------------------------------------------------------

block test_compact_torn_shard:
  let sd = freshSD("compact_torn")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_torn.nim::")

  # Good shard.
  seedLedgerShard(sd, "good-shard-1.ndjson", @[makeRow(ident, 1000)])

  # Torn shard: bad header → whole shard discarded during compaction.
  let ledgerDir = sd / "ledger"
  createDir(ledgerDir)
  writeFile(ledgerDir / "torn-shard-2.ndjson",
    "NOT A VALID HEADER\n" &
    "{\"rowVersion\":1,\"identity\":\"tests/unit/test_torn.nim::\",\"timestamp\":2000," &
    "\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":1000,\"rssBytes\":4096}\n")

  let r = compactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  # Both shards are removed (even the torn one); 1 row from the good shard kept.
  assert r.shardsRemoved == 2, "compact_torn: expected 2 shards removed, got " & $r.shardsRemoved
  assert r.rowsKept == 1, "compact_torn: expected 1 row kept (torn shard discarded), got " & $r.rowsKept

  let rows = scanLedger(sd, ident)
  assert rows.len == 1, "compact_torn: expected 1 row via scanLedger, got " & $rows.len
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 11. Empty ledger dir → no error, 0 shards, 0 rows
# ---------------------------------------------------------------------------

block test_compact_empty:
  let sd = freshSD("compact_empty")
  defer: removeDir(sd)
  # No ledger dir at all.
  let r = compactLedger(sd, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.shardsRemoved == 0
  assert r.rowsKept == 0

# ---------------------------------------------------------------------------
# 12. cleanOrphans: evicts over-cap result-cache entries + returns count
# ---------------------------------------------------------------------------

block test_cleanorphans_cache_eviction:
  let root = getTempDir() / ("crisol_a1c_cleanorphans_rc_" & $posix_mod.getpid())
  removeDir(root)
  createDir(root)
  defer: removeDir(root)

  # No test entrypoints needed for GC (discover returns empty).
  let cfg = Config(
    projectRoot:        root,
    stateDir:           ".crisol",
    jobs:               1,
    timeoutSecs:        300,
    compileTimeoutSecs: 600,
    maxOutputBytes:     1024 * 1024,
    maxCacheEntries:    2,   # keep only 2
    cacheMaxAgeDays:    0,   # age-bound disabled
    ledgerMaxAgeDays:   0,
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

  let stateDir = root / ".crisol"

  # Seed 4 cache entries with different ages.
  let now: int64 = 1_700_000_000
  seedCacheEntry(stateDir, "old00000old00000", now - 400)
  seedCacheEntry(stateDir, "old10000old10000", now - 300)
  seedCacheEntry(stateDir, "new00000new00000", now - 200)
  seedCacheEntry(stateDir, "new10000new10000", now - 100)

  let r = cleanOrphans(cfg)
  # 4 entries, maxEntries=2 → 2 evicted.
  assert r.cacheEvicted == 2, "cleanOrphans cache eviction: expected 2 evicted, got " & $r.cacheEvicted

  let verDir = stateDir / "cache" / ("v" & $resultCacheFormatVersion)
  assert not fileExists(verDir / "old00000old00000.json"), "oldest must be evicted"
  assert not fileExists(verDir / "old10000old10000.json"), "2nd oldest must be evicted"
  assert fileExists(verDir / "new00000new00000.json"), "newer must survive"
  assert fileExists(verDir / "new10000new10000.json"), "newest must survive"

# ---------------------------------------------------------------------------
# 13. cleanOrphans: compacts ledger shards + returns counts
# ---------------------------------------------------------------------------

block test_cleanorphans_ledger_compact:
  let root = getTempDir() / ("crisol_a1c_cleanorphans_led_" & $posix_mod.getpid())
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
    maxCacheEntries:    0,   # no size bound
    cacheMaxAgeDays:    0,
    ledgerMaxAgeDays:   0,
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

  let stateDir = root / ".crisol"
  let ident = IdentityKey("tests/unit/test_co.nim::")

  # Seed 3 shards.
  seedLedgerShard(stateDir, "s1-x-1.ndjson", @[makeRow(ident, 1000)])
  seedLedgerShard(stateDir, "s2-x-1.ndjson", @[makeRow(ident, 2000)])
  seedLedgerShard(stateDir, "s3-x-1.ndjson", @[makeRow(ident, 3000)])

  let r = cleanOrphans(cfg)
  assert r.shardsRemoved == 3, "cleanOrphans ledger: expected 3 shards removed, got " & $r.shardsRemoved
  assert r.ledgerRowsKept == 3, "cleanOrphans ledger: expected 3 rows kept, got " & $r.ledgerRowsKept

  # scanLedger must still return all 3 rows.
  let rows = scanLedger(stateDir, ident)
  assert rows.len == 3, "cleanOrphans ledger: expected 3 rows via scanLedger, got " & $rows.len

# ---------------------------------------------------------------------------
# L8: gcResultCache removes stale .tmp files from cache/v<N>/
# ---------------------------------------------------------------------------

block test_gc_removes_stale_tmp:
  ## Any `.tmp` file in the version dir is orphaned (a crash mid-write) and must
  ## be removed by gcResultCache.  GC runs under the exclusive stateDir lock, so
  ## it cannot race a live writer.
  let sd = freshSD("gc_stale_tmp")
  defer: removeDir(sd)

  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  createDir(verDir)

  # Plant a stale tmp file (simulates a crashed storeCached call).
  let staleTmp = verDir / "deadbeefdeadbeef.json.tmp"
  writeFile(staleTmp, "{\"incomplete\": true}")

  # Also plant a PID-style tmp (L10 naming).
  let stalePidTmp = verDir / "cafebabecafebabe.json.12345.tmp"
  writeFile(stalePidTmp, "{\"incomplete\": true}")

  # One valid cache entry.
  seedCacheEntry(sd, "good0000good0000", 1_700_000_000)

  let r = gcResultCache(sd, maxEntries = 100, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  # GC evicts 0 .json entries (well under cap) but must clean the .tmp files.
  assert r.evicted == 0, "no json evicted: got " & $r.evicted

  assert not fileExists(staleTmp),    "stale .tmp must be removed"
  assert not fileExists(stalePidTmp), "stale PID-style .tmp must be removed"
  assert fileExists(verDir / "good0000good0000.json"), "valid json must survive"

block test_gc_removes_tmp_even_when_no_json:
  ## Stale .tmp cleanup must fire even when there are no .json files to evict.
  let sd = freshSD("gc_tmp_only")
  defer: removeDir(sd)

  let verDir = sd / "cache" / ("v" & $resultCacheFormatVersion)
  createDir(verDir)

  # Only tmp files; no json.
  writeFile(verDir / "aaaa0000aaaa0000.json.99.tmp", "orphaned")
  writeFile(verDir / "bbbb0000bbbb0000.json.tmp",     "orphaned")

  let r = gcResultCache(sd, maxEntries = 100, maxAgeSecs = 0, nowSecs = 1_700_000_000)
  assert r.evicted == 0
  assert not fileExists(verDir / "aaaa0000aaaa0000.json.99.tmp"), "pid-style tmp removed"
  assert not fileExists(verDir / "bbbb0000bbbb0000.json.tmp"),    "plain tmp removed"

# ---------------------------------------------------------------------------
# RFC-0005 B1b: orphan sidecar pruning inside gcResultCacheAt's walk
# ---------------------------------------------------------------------------

proc sampleKeyInputsFor(flagHash: string): KeyInputs =
  KeyInputs(
    closureContentHash: "closure-abc",
    flagHash:            flagHash,
    nimVersion:          "2.2.10",
    ccVersion:           "gcc-13",
    fixtureHash:         "",
    argv:                @["mybin"],
    limits:              default(ptypes.Limits),
    hermeticEnvHash:     "envhash-xyz",
    protocolMajor:       1,
  )

proc seedSidecarRecord(root: string; path: string; key: string; flagHash: string) =
  ## `root` is the cache ROOT (`stateDir / "cache"`), matching
  ## `cachelocalfs.writeSidecar`'s own parameter — the same value
  ## `gcResultCacheAt` is called with below.
  writeSidecar(root, path, SidecarEntry(
    key:       SoundnessKey(key),
    inputs:    sampleKeyInputsFor(flagHash),
    envDigest: @[("HOME", "aa11bb22cc33dd44")],
  ))

block test_sidecar_pruned_when_its_only_entry_is_evicted:
  let sd = freshSD("sidecar_prune_evicted")
  defer: removeDir(sd)
  let root = sd / "cache"
  let path = "tests/unit/test_gone.nim"

  seedCacheEntry(sd, "keyA0000keyA0000", cachedAt = 1_000)  # old
  seedSidecarRecord(root, path, "keyA0000keyA0000", "flagA")
  let sc = sidecarPath(root, path)
  assert fileExists(sc), "sidecar must exist before GC"

  # Age-evict everything older than (nowSecs - maxAgeSecs).
  let r = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 100, nowSecs = 1_000_000)
  assert r.evicted == 1
  assert not fileExists(sc), "the path's sidecar must be pruned once its only entry is gone"

block test_sidecar_survives_when_its_entry_stays_live:
  let sd = freshSD("sidecar_survive_live")
  defer: removeDir(sd)
  let root = sd / "cache"
  let path = "tests/unit/test_stays.nim"

  seedCacheEntry(sd, "keyB0000keyB0000", cachedAt = 999_999)  # recent
  seedSidecarRecord(root, path, "keyB0000keyB0000", "flagB")
  let sc = sidecarPath(root, path)

  let r = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 100, nowSecs = 1_000_000)
  assert r.evicted == 0
  assert fileExists(sc), "a sidecar whose entry is still live must survive GC"

block test_sidecar_survives_if_any_record_still_live:
  let sd = freshSD("sidecar_multi_any_live")
  defer: removeDir(sd)
  let root = sd / "cache"
  let path = "tests/unit/test_multi.nim"

  # keyLive has a real, recent entry; keyGoneForever never had one at all
  # (already evicted in some earlier GC pass, in the real-world story).
  seedCacheEntry(sd, "keyLive0keyLive0", cachedAt = 999_999)
  seedSidecarRecord(root, path, "keyGoneForevr000", "flagOld")
  seedSidecarRecord(root, path, "keyLive0keyLive0", "flagNew")
  let sc = sidecarPath(root, path)

  let r = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 100, nowSecs = 1_000_000)
  assert r.evicted == 0
  assert fileExists(sc), "a sidecar survives as long as ANY record's key is still live"

block test_sidecar_pruned_when_all_records_are_dead:
  let sd = freshSD("sidecar_all_dead")
  defer: removeDir(sd)
  let root = sd / "cache"
  let path = "tests/unit/test_all_dead.nim"

  # Both referenced keys are dead: keyOld1 gets age-evicted, keyOld2 never
  # had a real entry file at all.
  seedCacheEntry(sd, "keyOld1keyOld100", cachedAt = 1_000)
  seedSidecarRecord(root, path, "keyOld1keyOld100", "flagA")
  seedSidecarRecord(root, path, "keyOld2keyOld200", "flagB")
  let sc = sidecarPath(root, path)

  let r = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 100, nowSecs = 1_000_000)
  assert r.evicted == 1
  assert not fileExists(sc), "a sidecar with NO surviving live record must be pruned entirely"

block test_corrupt_sidecar_is_pruned_not_crashed:
  let sd = freshSD("sidecar_corrupt")
  defer: removeDir(sd)
  let root = sd / "cache"
  let path = "tests/unit/test_corrupt.nim"

  seedSidecarRecord(root, path, "keyC0000keyC0000", "flagC")
  let sc = sidecarPath(root, path)
  writeFile(sc, "{ not json at all ]]]")

  let r = gcResultCacheAt(root, maxEntries = 0, maxAgeSecs = 0, nowSecs = 1_000_000)
  assert r.evicted == 0, "a malformed sidecar is not a result-cache ENTRY -- must not count toward `evicted`"
  assert not fileExists(sc), "a structurally-broken sidecar is treated as orphaned and pruned"

block test_sidecars_do_not_count_against_the_entry_cap_or_lru:
  let sd = freshSD("sidecar_not_counted")
  defer: removeDir(sd)
  let root = sd / "cache"

  # Exactly AT the cap: 3 real entries.
  seedCacheEntry(sd, "capA0000capA0000", cachedAt = 999_997)
  seedCacheEntry(sd, "capB0000capB0000", cachedAt = 999_998)
  seedCacheEntry(sd, "capC0000capC0000", cachedAt = 999_999)
  # Extra sidecars in the SAME verDir referencing all three (live) keys --
  # if the entry-collection walk (or countCacheEntries) mistakenly counted
  # inputs/*.json as entries, this would push the apparent count over the
  # cap and trigger a spurious eviction.
  seedSidecarRecord(root, "tests/unit/test_p1.nim", "capA0000capA0000", "f1")
  seedSidecarRecord(root, "tests/unit/test_p2.nim", "capB0000capB0000", "f2")
  seedSidecarRecord(root, "tests/unit/test_p3.nim", "capC0000capC0000", "f3")

  let r = gcResultCacheAt(root, maxEntries = 3, maxAgeSecs = 0, nowSecs = 1_000_000)
  assert r.evicted == 0, "sidecars must never be mistaken for cache entries by the size bound"

echo "test_a1c_gc: all blocks passed"
