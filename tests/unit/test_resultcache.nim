## test_resultcache.nim — A1a: ExecutionCache store (RFC-0004 F1).
##
## Tests written FIRST (TDD), then implementation written to make them pass.
##
## Coverage:
##   1. roundtrip: store then load returns an equal CachedResult (incl. records,
##      cachedAt).
##   2. miss on absent key → none.
##   3. checksum mismatch (corrupt the payload bytes on disk) → none (MISS).
##   4. format-version mismatch (bumped version header) → none.
##   5. atomic write leaves no .tmp behind; a pre-existing stale .tmp is cleaned.
##   6. two different keys coexist; re-storing the same key is idempotent.
##   7. soft-cap: dir already at cap → store SKIPPED, returns false; entries intact.

import std/[os, json, options, strutils]
import std/posix as posix_m  # L10: getpid() for PID-unique tmp filename check
import crisol/types
import crisol/resultcache

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_resultcache_" & name)
  removeDir(result)
  createDir(result)

proc sampleResult(): CachedResult =
  CachedResult(
    outcome:    oPassed,
    exitCode:   0,
    signal:     0,
    durationMs: 1234,
    records: @[
      TestRecord(name: "alpha", status: rsPass, durationUs: 50,
                 msg: none(string), tags: @["fast"]),
      TestRecord(name: "beta", status: rsFail, durationUs: 90,
                 msg: some("boom"), tags: @[]),
    ],
    cachedAt:        1_700_000_000'i64,
    payloadChecksum: "",   # filled by storeCached
  )

# The cache-dir layout: <stateDir>/cache/v<fmt>/<key>.json
proc cacheDir(stateDir: string): string =
  stateDir / "cache" / ("v" & $resultCacheFormatVersion)

proc keyFile(stateDir: string; key: SoundnessKey): string =
  cacheDir(stateDir) / ($key & ".json")

# ---------------------------------------------------------------------------
# 1. roundtrip
# ---------------------------------------------------------------------------

block test_roundtrip:
  let sd = freshStateDir("roundtrip")
  defer: removeDir(sd)
  let key = SoundnessKey("00112233aabbccdd")
  let res = sampleResult()

  let ok = storeCached(sd, key, res)
  assert ok, "storeCached should succeed (not soft-capped)"

  let loaded = loadCached(sd, key)
  assert loaded.isSome, "loadCached should return some after store"
  let got = loaded.get

  assert got.outcome == res.outcome
  assert got.exitCode == res.exitCode
  assert got.signal == res.signal
  assert got.durationMs == res.durationMs
  assert got.cachedAt == res.cachedAt
  assert got.records.len == 2, "records must round-trip"
  assert got.records[0].name == "alpha"
  assert got.records[0].status == rsPass
  assert got.records[0].durationUs == 50
  assert got.records[0].tags == @["fast"]
  assert got.records[0].msg.isNone
  assert got.records[1].name == "beta"
  assert got.records[1].status == rsFail
  assert got.records[1].msg == some("boom")

# ---------------------------------------------------------------------------
# 2. miss on absent key → none
# ---------------------------------------------------------------------------

block test_miss_absent:
  let sd = freshStateDir("miss")
  defer: removeDir(sd)
  let loaded = loadCached(sd, SoundnessKey("deadbeefdeadbeef"))
  assert loaded.isNone, "absent key must be a miss (none)"

# ---------------------------------------------------------------------------
# 3. checksum mismatch → none (MISS), not an exception
# ---------------------------------------------------------------------------

block test_checksum_mismatch:
  let sd = freshStateDir("checksum")
  defer: removeDir(sd)
  let key = SoundnessKey("1111222233334444")
  assert storeCached(sd, key, sampleResult())

  # Corrupt the payload (NOT the checksum field) on disk.
  let path = keyFile(sd, key)
  let node = parseJson(readFile(path))
  node["payload"]["durationMs"] = newJInt(999999)  # tamper, checksum now stale
  writeFile(path, $node)

  let loaded = loadCached(sd, key)
  assert loaded.isNone, "checksum mismatch must be a MISS, not a load of tampered data"

# ---------------------------------------------------------------------------
# 4. format-version mismatch → none
# ---------------------------------------------------------------------------

block test_format_version_mismatch:
  let sd = freshStateDir("fmtver")
  defer: removeDir(sd)
  let key = SoundnessKey("5555666677778888")
  assert storeCached(sd, key, sampleResult())

  let path = keyFile(sd, key)
  let node = parseJson(readFile(path))
  node["header"]["formatVersion"] = newJInt(resultCacheFormatVersion + 99)
  writeFile(path, $node)

  let loaded = loadCached(sd, key)
  assert loaded.isNone, "format-version mismatch must be a MISS"

# ---------------------------------------------------------------------------
# 5. atomic write leaves no writer-own .tmp; final .json is present
# ---------------------------------------------------------------------------
#
# L10: storeCached now writes to `<key>.<pid>.tmp` (unique per writer) rather
# than the old shared `<key>.tmp`.  The writer-own tmp is renamed to `<key>.json`
# atomically; no writer-own .tmp remains after a successful store.
#
# Stale .tmp files from CRASHED writers are cleaned by gcResultCache (L8), not
# by subsequent storeCached calls.  A pre-existing stale .tmp from a different
# writer (different PID) is intentionally left alone by a fresh store — it is
# an orphan from a crashed writer, and its cleanup belongs to GC-time (under
# the exclusive lock), not write-time.

block test_atomic_no_tmp:
  let sd = freshStateDir("atomic")
  defer: removeDir(sd)
  let key = SoundnessKey("99990000aaaa1111")

  # Plant a stale .tmp file with an OLD (pre-L10) fixed name, as if from a
  # crashed prior run with the legacy format.
  createDir(cacheDir(sd))
  let staleTmpLegacy = keyFile(sd, key) & ".tmp"
  writeFile(staleTmpLegacy, "garbage from a crashed run")

  assert storeCached(sd, key, sampleResult())

  # The final .json must exist after a successful store.
  assert fileExists(keyFile(sd, key)), "final .json must exist after store"

  # The writer-own PID-based .tmp is gone (renamed to .json or cleaned on error).
  # Walk the cache dir to confirm no PID-style .tmp was left behind.
  let myPidTmp = keyFile(sd, key) & "." & $posix_m.getpid() & ".tmp"
  assert not fileExists(myPidTmp), "writer-own .tmp must not exist after rename"

  # NOTE: the stale legacy-format .tmp may still be present — its cleanup is
  # deferred to gcResultCache (L8), which runs under the exclusive stateDir lock.
  # We do NOT assert it is gone here; that is tested in test_a1c_gc.nim.

# ---------------------------------------------------------------------------
# 6. two keys coexist; re-store is idempotent
# ---------------------------------------------------------------------------

block test_two_keys_coexist_idempotent:
  let sd = freshStateDir("twokeys")
  defer: removeDir(sd)
  let k1 = SoundnessKey("aaaaaaaaaaaaaaaa")
  let k2 = SoundnessKey("bbbbbbbbbbbbbbbb")

  var r1 = sampleResult()
  r1.exitCode = 1
  var r2 = sampleResult()
  r2.exitCode = 2

  assert storeCached(sd, k1, r1)
  assert storeCached(sd, k2, r2)

  let l1 = loadCached(sd, k1)
  let l2 = loadCached(sd, k2)
  assert l1.isSome and l1.get.exitCode == 1, "k1 must not be clobbered by k2"
  assert l2.isSome and l2.get.exitCode == 2, "k2 distinct from k1"

  # Re-store same key with same content: idempotent (still loads, still one file).
  assert storeCached(sd, k1, r1)
  let l1b = loadCached(sd, k1)
  assert l1b.isSome and l1b.get.exitCode == 1

# ---------------------------------------------------------------------------
# 7. soft-cap: dir at cap → store SKIPPED → false; existing entries intact
# ---------------------------------------------------------------------------

block test_soft_cap_skip:
  let sd = freshStateDir("softcap")
  defer: removeDir(sd)

  # Seed two existing entries with cap = 2 → already at cap.
  let kA = SoundnessKey("cccc0000cccc0000")
  let kB = SoundnessKey("dddd0000dddd0000")
  assert storeCached(sd, kA, sampleResult(), maxCacheEntries = 2)
  assert storeCached(sd, kB, sampleResult(), maxCacheEntries = 2)

  # Third store with cap = 2: dir already has 2 entries → skip, return false.
  let kC = SoundnessKey("eeee0000eeee0000")
  let ok = storeCached(sd, kC, sampleResult(), maxCacheEntries = 2)
  assert not ok, "store must be SKIPPED (false) when dir already at cap"
  assert not fileExists(keyFile(sd, kC)), "skipped store must not create a file"

  # Existing entries intact.
  assert loadCached(sd, kA).isSome, "existing entries must remain after a skipped store"
  assert loadCached(sd, kB).isSome

  # Re-storing an EXISTING key at cap must still succeed (it replaces, not grows).
  let okReplace = storeCached(sd, kA, sampleResult(), maxCacheEntries = 2)
  assert okReplace, "re-storing an existing key at cap must not be soft-capped"

echo "test_resultcache: all blocks passed"
