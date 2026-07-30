## test_objcache_gc.nim — RFC-0006 Stage R, R4: object-cache GC
## (`gcObjCache`) + `cleanOrphans` wiring.
##
## Mirrors test_a1c_gc.nim's gcResultCache coverage, adapted for objcache's
## two-artifact (`<keyHash>.o` + `<keyHash>.meta`) entries. All clock inputs
## are injected so every test is deterministic (no real-time dependency).
##
## Coverage:
##   1. Age eviction: stale pairs (both files) removed; fresh pairs survive.
##   2. Size (LRU) eviction: oldest-by-mtime pairs removed until at cap.
##   3. `.tmp` sweep: planted `.o.<pid>.tmp` removed and counted; committed
##      pairs untouched.
##   4. Version preservation: a sibling `objcache/v<other>/` dir is left
##      entirely untouched.
##   5. Orphan hygiene: a lone `.meta` (no `.o`) and a lone `.o` (no `.meta`)
##      are removed; GC never raises and leaves no half-pair.
##   6. cleanOrphans integration: config with `objcacheMaxEntries` set +
##      seeded objcache over cap -> cleanOrphans(config).objCacheEvicted > 0.
##   7. RFC-0006 review R6 — aggregate-byte cap: seed pairs whose combined
##      `.o`+`.meta` bytes exceed `maxBytes` -> oldest entries evicted until
##      under the cap; under-cap seed -> no eviction.
##   8. R6 — whichever bound is tighter wins: a byte cap tighter than the
##      entry-count cap evicts MORE than the count cap alone would, and vice
##      versa (both bounds are satisfied simultaneously after GC).
##   9. R6 — cleanOrphans integration: config with `objcacheMaxBytes` set +
##      seeded objcache over the byte cap -> cleanOrphans(config).objCacheEvicted > 0.

import std/[os, strutils, times]
import std/posix as posix_mod
import crisol/[types, objcache, clean]

# ---------------------------------------------------------------------------
# Helpers — state-dir factories
# ---------------------------------------------------------------------------

proc freshSD(tag: string): string =
  result = getTempDir() / ("crisol_objcache_gc_" & tag & "_" & $posix_mod.getpid())
  removeDir(result)
  createDir(result)

proc verDirOf(sd: string): string =
  sd / "objcache" / ("v" & $objCacheFormatVersion)

# ---------------------------------------------------------------------------
# Helpers — seed a committed <key>.o + <key>.meta pair, backdating the .o
# mtime to `mtime` (unix epoch seconds).
# ---------------------------------------------------------------------------

proc seedPair(stateDir: string; key: string; mtime: int64) =
  let verDir = verDirOf(stateDir)
  createDir(verDir)
  let objPath  = verDir / (key & ".o")
  let metaPath = verDir / (key & ".meta")
  writeFile(objPath, "fake object bytes for " & key)
  writeFile(metaPath, "{\"header\":{\"formatVersion\":" & $objCacheFormatVersion &
                       "},\"payloadChecksum\":\"deadbeefdeadbeef\"," &
                       "\"keyPreimage\":\"preimage-" & key & "\"}")
  setLastModificationTime(objPath, fromUnix(mtime))

proc seedPairSized(stateDir: string; key: string; mtime: int64; objSize: int): int64 =
  ## Same commit shape as `seedPair`, but the `.o` payload is exactly
  ## `objSize` bytes (a repeated filler char) so R6's byte-cap tests can
  ## construct precise aggregate totals. Returns the pair's ACTUAL combined
  ## `.o` + `.meta` size in bytes, read back from disk (never hardcoded),
  ## so a test never assumes a JSON serialization width that could drift.
  let verDir = verDirOf(stateDir)
  createDir(verDir)
  let objPath  = verDir / (key & ".o")
  let metaPath = verDir / (key & ".meta")
  writeFile(objPath, repeat('x', objSize))
  writeFile(metaPath, "{\"header\":{\"formatVersion\":" & $objCacheFormatVersion &
                       "},\"payloadChecksum\":\"deadbeefdeadbeef\"," &
                       "\"keyPreimage\":\"preimage-" & key & "\"}")
  setLastModificationTime(objPath, fromUnix(mtime))
  result = getFileSize(objPath) + getFileSize(metaPath)

# ---------------------------------------------------------------------------
# 1. Age eviction: stale pairs removed, fresh pairs survive
# ---------------------------------------------------------------------------

block test_gc_age_bound:
  let sd = freshSD("age")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let maxAge: int64 = 7 * 86_400  # 7 days

  seedPair(sd, "fresh000fresh0000", now - int64(3 * 86_400))  # within bound
  seedPair(sd, "stale000stale0000", now - int64(10 * 86_400)) # beyond bound

  let r = gcObjCache(sd, maxEntries = 100, maxAgeSecs = maxAge, nowSecs = now)
  assert r.evicted == 1, "age bound: expected 1 evicted, got " & $r.evicted

  let verDir = verDirOf(sd)
  assert fileExists(verDir / "fresh000fresh0000.o"), "fresh .o must survive"
  assert fileExists(verDir / "fresh000fresh0000.meta"), "fresh .meta must survive"
  assert not fileExists(verDir / "stale000stale0000.o"), "stale .o must be evicted"
  assert not fileExists(verDir / "stale000stale0000.meta"), "stale .meta must be evicted"

# ---------------------------------------------------------------------------
# 2. Size (LRU) eviction: N+M pairs, maxEntries=N -> M oldest evicted
# ---------------------------------------------------------------------------

block test_gc_size_bound:
  let sd = freshSD("size")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let keys = ["k0000000000000000", "k1111111111111111", "k2222222222222222",
              "k3333333333333333", "k4444444444444444"]
  for i, k in keys:
    seedPair(sd, k, now - int64(500 - i * 100))
    # mtimes: now-500, now-400, now-300, now-200, now-100 (ascending age)

  # Keep only 3 -> evict the 2 oldest (keys[0], keys[1]).
  let r = gcObjCache(sd, maxEntries = 3, maxAgeSecs = 0, nowSecs = now)
  assert r.evicted == 2, "size bound: expected 2 evicted, got " & $r.evicted

  let verDir = verDirOf(sd)
  assert not fileExists(verDir / (keys[0] & ".o")), "oldest .o must be evicted"
  assert not fileExists(verDir / (keys[0] & ".meta")), "oldest .meta must be evicted"
  assert not fileExists(verDir / (keys[1] & ".o")), "2nd oldest .o must be evicted"
  assert not fileExists(verDir / (keys[1] & ".meta")), "2nd oldest .meta must be evicted"
  for i in 2 .. 4:
    assert fileExists(verDir / (keys[i] & ".o")), $i & " .o must survive"
    assert fileExists(verDir / (keys[i] & ".meta")), $i & " .meta must survive"

# ---------------------------------------------------------------------------
# 3. .tmp sweep: planted .o.<pid>.tmp removed and counted; committed pairs
#    untouched.
# ---------------------------------------------------------------------------

block test_gc_tmp_sweep:
  let sd = freshSD("tmp")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  seedPair(sd, "good0000good0000", now - 10)

  let verDir = verDirOf(sd)
  let staleTmp = verDir / "deadbeefdeadbeef.o.12345.tmp"
  writeFile(staleTmp, "orphaned partial write")
  let staleMetaTmp = verDir / "cafebabecafebabe.meta.6789.tmp"
  writeFile(staleMetaTmp, "orphaned partial write")

  let r = gcObjCache(sd, maxEntries = 100, maxAgeSecs = 0, nowSecs = now)
  assert r.tmpSwept == 2, "tmp sweep: expected 2 swept, got " & $r.tmpSwept
  assert r.evicted == 0, "tmp sweep: no committed entries evicted, got " & $r.evicted

  assert not fileExists(staleTmp), "stale .o.tmp must be removed"
  assert not fileExists(staleMetaTmp), "stale .meta.tmp must be removed"
  assert fileExists(verDir / "good0000good0000.o"), "committed .o must survive"
  assert fileExists(verDir / "good0000good0000.meta"), "committed .meta must survive"

# ---------------------------------------------------------------------------
# 4. Version preservation: a sibling objcache/v<other>/ dir is left entirely
#    untouched (gcObjCache operates only on the current version dir).
# ---------------------------------------------------------------------------

block test_gc_version_preservation:
  let sd = freshSD("version")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000

  # Seed the current version dir with a stale entry that WOULD be evicted.
  seedPair(sd, "stale000stale0000", now - int64(10 * 86_400))

  # Seed a sibling "old format" version dir with its own entries.
  let otherVerDir = sd / "objcache" / "v999"
  createDir(otherVerDir)
  writeFile(otherVerDir / "old00000old00000.o", "old-format object bytes")
  writeFile(otherVerDir / "old00000old00000.meta", "{\"header\":{\"formatVersion\":999}}")
  writeFile(otherVerDir / "stray.tmp", "old writer's stale tmp")

  let r = gcObjCache(sd, maxEntries = 0, maxAgeSecs = 7 * 86_400, nowSecs = now)
  assert r.evicted == 1, "current version stale entry must be evicted"

  # Sibling version dir: untouched, byte for byte.
  assert fileExists(otherVerDir / "old00000old00000.o"), "sibling .o must survive"
  assert fileExists(otherVerDir / "old00000old00000.meta"), "sibling .meta must survive"
  assert fileExists(otherVerDir / "stray.tmp"), "sibling .tmp must NOT be swept"

# ---------------------------------------------------------------------------
# 5. Orphan hygiene: a lone .meta (no .o) and a lone .o (no .meta) are
#    removed; GC never raises and leaves no half-pair.
# ---------------------------------------------------------------------------

block test_gc_orphan_hygiene:
  let sd = freshSD("orphan")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let verDir = verDirOf(sd)
  createDir(verDir)

  # A valid, fresh, committed pair — must survive untouched.
  seedPair(sd, "good0000good0000", now - 10)

  # A lone .o with no .meta (crash between the two renames — R1 doc).
  writeFile(verDir / "loneobj0loneobj00.o", "orphaned object, no meta")

  # A lone .meta with no .o (should not normally happen, but must not crash
  # or be silently retained forever).
  writeFile(verDir / "lonemeta0lonemeta0.meta",
    "{\"header\":{\"formatVersion\":" & $objCacheFormatVersion &
    "},\"payloadChecksum\":\"aaaa\",\"keyPreimage\":\"orphan\"}")

  # Generous bounds — nothing should be evicted by age/size; only orphans go.
  let r = gcObjCache(sd, maxEntries = 100, maxAgeSecs = 0, nowSecs = now)
  assert r.evicted == 2, "orphan hygiene: expected 2 orphans removed, got " & $r.evicted

  assert not fileExists(verDir / "loneobj0loneobj00.o"), "lone .o must be removed"
  assert not fileExists(verDir / "lonemeta0lonemeta0.meta"), "lone .meta must be removed"
  assert fileExists(verDir / "good0000good0000.o"), "good .o must survive"
  assert fileExists(verDir / "good0000good0000.meta"), "good .meta must survive"

  # Leaves no half-pair: every remaining .o has a .meta and vice versa.
  var objNames, metaNames: seq[string]
  for kind, path in walkDir(verDir):
    let name = path.extractFilename()
    if name.endsWith(".o"): objNames.add name[0 ..< name.len - 2]
    elif name.endsWith(".meta"): metaNames.add name[0 ..< name.len - 5]
  assert objNames == metaNames, "no half-pairs may remain after GC"

# ---------------------------------------------------------------------------
# 6. cleanOrphans integration: config with objcacheMaxEntries set + seeded
#    objcache over cap -> cleanOrphans(config).objCacheEvicted > 0.
# ---------------------------------------------------------------------------

block test_cleanorphans_objcache_eviction:
  let root = getTempDir() / ("crisol_objcache_gc_cleanorphans_" & $posix_mod.getpid())
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
    objcacheMaxEntries: 2,   # keep only 2
    objcacheMaxAgeDays: 0,   # age-bound disabled
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

  let stateDir = root / ".crisol"

  let now: int64 = 1_700_000_000
  seedPair(stateDir, "old00000old00000", now - 400)
  seedPair(stateDir, "old10000old10000", now - 300)
  seedPair(stateDir, "new00000new00000", now - 200)
  seedPair(stateDir, "new10000new10000", now - 100)

  let r = cleanOrphans(cfg)
  assert r.objCacheEvicted == 2,
    "cleanOrphans objcache eviction: expected 2 evicted, got " & $r.objCacheEvicted

  let verDir = verDirOf(stateDir)
  assert not fileExists(verDir / "old00000old00000.o"), "oldest .o must be evicted"
  assert not fileExists(verDir / "old00000old00000.meta"), "oldest .meta must be evicted"
  assert not fileExists(verDir / "old10000old10000.o"), "2nd oldest .o must be evicted"
  assert not fileExists(verDir / "old10000old10000.meta"), "2nd oldest .meta must be evicted"
  assert fileExists(verDir / "new00000new00000.o"), "newer .o must survive"
  assert fileExists(verDir / "new10000new10000.o"), "newest .o must survive"

# ---------------------------------------------------------------------------
# 7. RFC-0006 review R6 — aggregate-byte cap: over-cap seed evicts oldest
#    until under the cap; under-cap seed evicts nothing.
# ---------------------------------------------------------------------------

block test_gc_byte_cap_eviction:
  let sd = freshSD("bytecap")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let s0 = seedPairSized(sd, "byte0000byte00000", now - 300, 1000)
  let s1 = seedPairSized(sd, "byte1111byte11111", now - 200, 1000)
  let s2 = seedPairSized(sd, "byte2222byte22222", now - 100, 1000)

  # Cap large enough for the two NEWEST pairs, not the oldest.
  let maxBytes = s1 + s2 + 10

  let r = gcObjCache(sd, maxEntries = 0, maxAgeSecs = 0, nowSecs = now,
                      maxBytes = maxBytes)
  assert r.evicted == 1, "byte cap: expected 1 evicted (oldest), got " & $r.evicted

  let verDir = verDirOf(sd)
  assert not fileExists(verDir / "byte0000byte00000.o"), "oldest .o must be evicted (over byte cap)"
  assert not fileExists(verDir / "byte0000byte00000.meta"), "oldest .meta must be evicted (over byte cap)"
  assert fileExists(verDir / "byte1111byte11111.o"), "middle .o must survive"
  assert fileExists(verDir / "byte2222byte22222.o"), "newest .o must survive"

block test_gc_byte_cap_under_cap_no_eviction:
  let sd = freshSD("bytecap_under")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let s0 = seedPairSized(sd, "under000under00000", now - 200, 500)
  let s1 = seedPairSized(sd, "under111under11111", now - 100, 500)

  let r = gcObjCache(sd, maxEntries = 0, maxAgeSecs = 0, nowSecs = now,
                      maxBytes = s0 + s1 + 1000)
  assert r.evicted == 0, "under the byte cap: nothing should be evicted, got " & $r.evicted

  let verDir = verDirOf(sd)
  assert fileExists(verDir / "under000under00000.o"), "under cap: all pairs survive"
  assert fileExists(verDir / "under111under11111.o"), "under cap: all pairs survive"

# ---------------------------------------------------------------------------
# 8. R6 — whichever bound is tighter wins: the byte cap and the entry-count
#    cap are applied TOGETHER; eviction continues until BOTH are satisfied,
#    so the tighter of the two determines the surviving set.
# ---------------------------------------------------------------------------

block test_gc_entrycap_tighter_than_bytecap:
  let sd = freshSD("tighter_entries")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let keys = ["tt00000000000000t", "tt11111111111111t", "tt22222222222222t",
              "tt33333333333333t", "tt44444444444444t"]
  var perPairBytes: int64 = 0
  for i, k in keys:
    perPairBytes = seedPairSized(sd, k, now - int64(500 - i * 100), 1000)
    # ascending mtime: keys[0] oldest ... keys[4] newest; equal per-pair size.

  # entry-count bound (keep 3) is TIGHTER than the byte bound (room for 4).
  let r = gcObjCache(sd, maxEntries = 3, maxAgeSecs = 0, nowSecs = now,
                      maxBytes = perPairBytes * 4 + 10)
  assert r.evicted == 2,
    "entry-count-tighter: expected 2 evicted (driven by maxEntries=3), got " & $r.evicted

  let verDir = verDirOf(sd)
  assert not fileExists(verDir / (keys[0] & ".o")), "oldest evicted"
  assert not fileExists(verDir / (keys[1] & ".o")), "2nd oldest evicted"
  for i in 2 .. 4:
    assert fileExists(verDir / (keys[i] & ".o")), $i & " must survive"

block test_gc_bytecap_tighter_than_entrycap:
  let sd = freshSD("tighter_bytes")
  defer: removeDir(sd)

  let now: int64 = 1_700_000_000
  let keys = ["bb00000000000000b", "bb11111111111111b", "bb22222222222222b",
              "bb33333333333333b", "bb44444444444444b"]
  var perPairBytes: int64 = 0
  for i, k in keys:
    perPairBytes = seedPairSized(sd, k, now - int64(500 - i * 100), 1000)

  # byte bound (room for 2) is TIGHTER than the entry-count bound (keep 4).
  let r = gcObjCache(sd, maxEntries = 4, maxAgeSecs = 0, nowSecs = now,
                      maxBytes = perPairBytes * 2 + 10)
  assert r.evicted == 3,
    "byte-cap-tighter: expected 3 evicted (driven by maxBytes), got " & $r.evicted

  let verDir = verDirOf(sd)
  for i in 0 .. 2:
    assert not fileExists(verDir / (keys[i] & ".o")), $i & " must be evicted"
  for i in 3 .. 4:
    assert fileExists(verDir / (keys[i] & ".o")), $i & " must survive"

# ---------------------------------------------------------------------------
# 9. R6 — cleanOrphans integration: config with objcacheMaxBytes set + seeded
#    objcache over the byte cap -> cleanOrphans(config).objCacheEvicted > 0.
# ---------------------------------------------------------------------------

block test_cleanorphans_objcache_byte_eviction:
  let root = getTempDir() / ("crisol_objcache_gc_cleanorphans_bytes_" & $posix_mod.getpid())
  removeDir(root)
  createDir(root)
  defer: removeDir(root)

  let stateDir = root / ".crisol"
  let now: int64 = 1_700_000_000
  let s0 = seedPairSized(stateDir, "cbyte000cbyte0000", now - 400, 1000)
  let s1 = seedPairSized(stateDir, "cbyte111cbyte1111", now - 300, 1000)
  let s2 = seedPairSized(stateDir, "cbyte222cbyte2222", now - 200, 1000)
  discard s0
  let s3 = seedPairSized(stateDir, "cbyte333cbyte3333", now - 100, 1000)

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
    objcacheMaxEntries: 0,             # unbounded — isolate the byte-cap path
    objcacheMaxAgeDays: 0,
    objcacheMaxBytes:   s1 + s2 + s3 + 10,  # room for only the 3 newest
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

  let r = cleanOrphans(cfg)
  assert r.objCacheEvicted == 1,
    "cleanOrphans byte-cap eviction: expected 1 evicted, got " & $r.objCacheEvicted

  let verDir = verDirOf(stateDir)
  assert not fileExists(verDir / "cbyte000cbyte0000.o"), "oldest .o must be evicted (byte cap)"
  assert not fileExists(verDir / "cbyte000cbyte0000.meta"), "oldest .meta must be evicted (byte cap)"
  assert fileExists(verDir / "cbyte111cbyte1111.o"), "2nd oldest .o must survive"
  assert fileExists(verDir / "cbyte222cbyte2222.o"), "3rd .o must survive"
  assert fileExists(verDir / "cbyte333cbyte3333.o"), "newest .o must survive"

echo "test_objcache_gc: all blocks passed"
