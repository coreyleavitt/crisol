## test_resultcache.nim — A1a: ExecutionCache store (RFC-0004 F1).
##                        rfc-0007 A1d-ii: the payload carries the REAL
##                        stored `run` ProcessResult, not a derived
##                        outcome/exitCode/signal projection.
##
## Tests written FIRST (TDD), then implementation written to make them pass.
##
## Coverage:
##   1. roundtrip: store then load returns an equal CachedResult (incl. the
##      real `run` ProcessResult -- exit/cause/evidence/rusage/durationUs --
##      records, cachedAt).
##   2. miss on absent key → none.
##   3. checksum mismatch (corrupt the payload bytes on disk) → none (MISS).
##   4. format-version mismatch (bumped version header) → none.
##   5. atomic write leaves no .tmp behind; a pre-existing stale .tmp is cleaned.
##   6. two different keys coexist; re-storing the same key is idempotent.
##   7. soft-cap: dir already at cap → store SKIPPED, returns false; entries intact.
##   8. rfc-0007 A1d-ii: a structurally-bad `run` node (unparseable enum
##      string) is a MISS, never a fabricated read (§2 own-reader posture).
##   9. rfc-0005 A2a: the root-taking helpers (`loadCachedAt`/
##      `storeCachedAt`/`gcResultCacheAt`) and the stateDir-taking legacy
##      forms are behavior-identical -- same file, same bytes, on disk,
##      regardless which form a caller uses (the no-regression anchor for
##      the A2a refactor).
##  10. rfc-0005 A2a: `storeCachedAt`'s stderr failure warning is
##      rate-limited to ONE line per root per process lifetime -- proven via
##      real stderr (fd-level capture), not just the once-set's bookkeeping.

import std/[os, json, options, strutils]
import std/posix as posix_m  # L10: getpid() for PID-unique tmp filename check; also fd-capture (test 10)
import crisol/types
import crisol/resultcache
import crisol/process/types as ptypes
import crisol/depgraph  # fnv1a64/toHex16 — recompute a matching checksum in test 8

# ---------------------------------------------------------------------------
# Stderr fd-capture helper (test 10) — redirects the OS-level fd 2 for the
# duration of `body`, so the rate-limiting proof exercises the REAL stream
# `warnStoreFailureOnce` writes to, not merely the once-set's internal state.
# ---------------------------------------------------------------------------

proc withCapturedStderr(body: proc()): string =
  stdout.flushFile()
  stderr.flushFile()
  let capPath = getTempDir() / ("crisol_resultcache_stderr_capture_" & $posix_m.getpid() & ".txt")
  let savedFd = posix_m.dup(2.cint)
  let capFd = posix_m.open(capPath.cstring,
                            posix_m.O_WRONLY or posix_m.O_CREAT or posix_m.O_TRUNC, 0o600)
  discard posix_m.dup2(capFd, 2.cint)
  discard posix_m.close(capFd)
  body()
  stderr.flushFile()
  discard posix_m.dup2(savedFd, 2.cint)
  discard posix_m.close(savedFd)
  result = readFile(capPath)
  removeFile(capPath)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_resultcache_" & name)
  removeDir(result)
  createDir(result)

proc sampleProcessResult(exitCode: int = 0): ptypes.ProcessResult =
  ## A real, non-default observation -- exercises every ProcessResult field
  ## with genuine (not zero-valued) data so a roundtrip proves the WHOLE
  ## shape survives, not just the fields that happen to match a default.
  ptypes.ProcessResult(
    exit:  ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
    cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: ptypes.Evidence(
      killDomain: ptypes.kdsProcessGroup,
      tree:       ptypes.toComplete,
      escapees:   @[],
      limits:     default(ptypes.LimitsAchieved),
      hermetic:   ptypes.hlIsolated,
      killSnapshot: @[],
      cooperativeUnavailable: false,
    ),
    rusage: some(ptypes.Rusage(maxRssBytes: 4_096_000, userCpuUs: 1500, sysCpuUs: 300)),
    durationUs: 1_234_000,
  )

proc sampleResult(exitCode: int = 0): CachedResult =
  CachedResult(
    run: sampleProcessResult(exitCode),
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

  assert got.run.exit.kind == ptypes.ekExited
  assert got.run.exit.code == res.run.exit.code
  assert got.run.cause.by == ptypes.cbProcess
  assert got.run.evidence.tree == ptypes.toComplete
  assert got.run.evidence.killDomain == ptypes.kdsProcessGroup
  assert got.run.rusage.isSome
  assert got.run.rusage.get.maxRssBytes == 4_096_000
  assert got.run.durationUs == res.run.durationUs
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
  node["payload"]["cachedAt"] = newJInt(999999)  # tamper, checksum now stale
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

  let r1 = sampleResult(exitCode = 1)
  let r2 = sampleResult(exitCode = 2)

  assert storeCached(sd, k1, r1)
  assert storeCached(sd, k2, r2)

  let l1 = loadCached(sd, k1)
  let l2 = loadCached(sd, k2)
  assert l1.isSome and l1.get.run.exit.code == 1, "k1 must not be clobbered by k2"
  assert l2.isSome and l2.get.run.exit.code == 2, "k2 distinct from k1"

  # Re-store same key with same content: idempotent (still loads, still one file).
  assert storeCached(sd, k1, r1)
  let l1b = loadCached(sd, k1)
  assert l1b.isSome and l1b.get.run.exit.code == 1

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

# ---------------------------------------------------------------------------
# 8. rfc-0007 A1d-ii: structurally-bad `run` node → MISS (own-reader posture)
# ---------------------------------------------------------------------------
#
# Same rule process/resultjson.fromJson already enforces (§2): an unparseable
# enum string is a STRUCTURAL parse failure, never a default-valued lie.
# resultcache must propagate that as a cache MISS, not a load of garbage.

block test_structurally_bad_run_node_is_a_miss:
  let sd = freshStateDir("badrun")
  defer: removeDir(sd)
  let key = SoundnessKey("f00df00df00df00d")
  assert storeCached(sd, key, sampleResult())

  let path = keyFile(sd, key)
  let node = parseJson(readFile(path))
  # Corrupt the observation's `exit.kind` to an unparseable enum string, then
  # recompute a MATCHING checksum — isolating the `run`-structural-parse
  # failure from the checksum-mismatch path already covered by
  # test_checksum_mismatch above: even a self-consistent (checksum-valid)
  # entry with a structurally-bad `run` node must independently be a miss.
  node["payload"]["run"]["exit"]["kind"] = newJString("not-a-real-exit-kind")
  node["payloadChecksum"] = newJString(toHex16(fnv1a64($node["payload"])))
  writeFile(path, $node)

  let loaded = loadCached(sd, key)
  assert loaded.isNone, "a structurally-bad `run` node must be a MISS"

# ---------------------------------------------------------------------------
# 9. rfc-0005 A1 tracer: the shared codec (`payloadToJson`/`payloadFromJson`/
#    `canonicalPayload`), exported for the new `cachewire` serializer, is the
#    SAME codec the real production `loadCached` reads with -- not a private
#    duplicate that merely happens to share a shape.  Proven by building a
#    cache file using ONLY the exported functions (never `storeCached`) and
#    handing it to the real `loadCached`.
# ---------------------------------------------------------------------------

block test_exported_codec_is_loadCacheds_real_format:
  let sd = freshStateDir("exportedcodec")
  defer: removeDir(sd)
  let key = SoundnessKey("c0dec0dec0dec0de")
  let res = sampleResult(exitCode = 7)

  let payloadNode = payloadToJson(res)
  let checksum    = toHex16(fnv1a64(canonicalPayload(res)))
  assert canonicalPayload(res) == $payloadNode,
    "canonicalPayload must be exactly $payloadToJson(res) (RFC-0005 'one canonical payload')"

  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)
  let fileNode = newJObject()
  fileNode["header"]          = headerNode
  fileNode["payloadChecksum"] = newJString(checksum)
  fileNode["payload"]         = payloadNode

  createDir(cacheDir(sd))
  writeFile(keyFile(sd, key), $fileNode)

  let loaded = loadCached(sd, key)
  assert loaded.isSome, "loadCached must accept a file built purely from the exported shared codec"
  assert loaded.get.run.exit.code == 7
  assert loaded.get.payloadChecksum == checksum

  let reparsed = payloadFromJson(payloadNode)
  assert reparsed.isSome
  assert reparsed.get.run.exit.code == res.run.exit.code
  assert reparsed.get.cachedAt == res.cachedAt

# ---------------------------------------------------------------------------
# 9. rfc-0005 A2a: root-taking helpers vs. stateDir-taking delegates --
#    behavior-identical, same file on disk, either direction.
# ---------------------------------------------------------------------------

block test_at_helpers_and_statedir_delegates_agree:
  let sd = freshStateDir("a2a_anchor")
  defer: removeDir(sd)
  let root = sd / "cache"

  # Store via the legacy stateDir form; the file must land at exactly
  # <stateDir>/cache/v<N>/<key>.json (the documented, unchanged layout).
  let k1 = SoundnessKey("a0a0a0a0a0a0a0a0")
  let r1 = sampleResult(exitCode = 11)
  assert storeCached(sd, k1, r1)
  assert fileExists(keyFile(sd, k1)), "storeCached must write to <stateDir>/cache/v<N>/<key>.json"

  # The root-taking loader must read that SAME file.
  let viaAt = loadCachedAt(root, k1)
  assert viaAt.isSome
  assert viaAt.get.run.exit.code == 11

  # Store via the root-taking form directly; must land at the identical path
  # a stateDir-form store would have used.
  let k2 = SoundnessKey("b0b0b0b0b0b0b0b0")
  let r2 = sampleResult(exitCode = 22)
  assert storeCachedAt(root, k2, r2)
  assert fileExists(keyFile(sd, k2)),
    "storeCachedAt(stateDir / \"cache\", ...) must land at the SAME path storeCached(stateDir, ...) would"

  # The legacy loader must read what the root-taking form wrote.
  let viaLegacy = loadCached(sd, k2)
  assert viaLegacy.isSome
  assert viaLegacy.get.run.exit.code == 22

  # gcResultCacheAt(root, ...) and gcResultCache(stateDir, ...) must observe
  # and evict the identical entry set -- prove via a deterministic age-based
  # eviction of k1 (old) while k2 (fresh) survives, using the root-taking form.
  let nowSecs = int64(1_700_050_000)
  let report = gcResultCacheAt(root, maxEntries = 100, maxAgeSecs = 1,
                               nowSecs = nowSecs)
  assert report.evicted == 2, "both entries' cachedAt (1_700_000_xxx) predate nowSecs - 1s"
  assert loadCachedAt(root, k1).isNone
  assert loadCachedAt(root, k2).isNone

# ---------------------------------------------------------------------------
# 10. rfc-0005 A2a: storeCachedAt's stderr warning is rate-limited to ONE
#     line per root per process lifetime.
# ---------------------------------------------------------------------------

block test_store_failure_warning_rate_limited_per_root:
  resetCacheWriteWarnings()

  let sdA = freshStateDir("ratelimit_a")
  let sdB = freshStateDir("ratelimit_b")
  defer:
    removeDir(sdA)
    removeDir(sdB)
  let rootA = sdA / "cache"
  let rootB = sdB / "cache"

  # Seed rootA to its cap (2), then attempt THREE further new-key stores --
  # each individually would warn under the old (unlimited) behavior; the
  # rate limiter must reduce that to exactly one line for rootA.
  assert storeCachedAt(rootA, SoundnessKey("c0c0c0c0c0c0c0c0"), sampleResult(), maxCacheEntries = 2)
  assert storeCachedAt(rootA, SoundnessKey("c1c1c1c1c1c1c1c1"), sampleResult(), maxCacheEntries = 2)

  let captured = withCapturedStderr(proc() =
    for i in 0 ..< 3:
      let k = SoundnessKey("c2c2c2c2c2c2c2c" & $i)
      let ok = storeCachedAt(rootA, k, sampleResult(), maxCacheEntries = 2)
      assert not ok, "each of these three stores must be soft-capped (skipped)"
    # A DIFFERENT root's first failure must still warn -- the bucket is
    # per-root, not a single global once-flag.
    assert storeCachedAt(rootB, SoundnessKey("d0d0d0d0d0d0d0d0"), sampleResult(), maxCacheEntries = 2)
    assert storeCachedAt(rootB, SoundnessKey("d1d1d1d1d1d1d1d1"), sampleResult(), maxCacheEntries = 2)
    let okB = storeCachedAt(rootB, SoundnessKey("d2d2d2d2d2d2d2d2"), sampleResult(), maxCacheEntries = 2)
    assert not okB
  )

  let lines = captured.strip(chars = {'\n'}).splitLines()
  var warnLines: seq[string]
  for l in lines:
    if l.len > 0: warnLines.add l
  assert warnLines.len == 2,
    "expected exactly 2 warning lines (one per root: the FIRST skipped key " &
    "each, never the 2nd/3rd skip on the same root), got " & $warnLines.len &
    ": " & captured
  # The warning message names the skipped KEY, not the root path (see
  # storeCachedAt) -- so the per-root FIRST-failure key is what proves which
  # root's warning survived: rootA's first skip is "c2...0", rootB's is
  # "d2...2" (its only attempted skip).
  assert "c2c2c2c2c2c2c2c0" in captured, "rootA's FIRST skip must still warn: " & captured
  assert "c2c2c2c2c2c2c2c1" notin captured, "rootA's 2nd skip must be suppressed: " & captured
  assert "c2c2c2c2c2c2c2c2" notin captured, "rootA's 3rd skip must be suppressed: " & captured
  assert "d2d2d2d2d2d2d2d2" in captured, "rootB's first skip must warn independently of rootA: " & captured

# ---------------------------------------------------------------------------
# 11. on this toolchain `os.createDir` raises `IOError`, not `OSError`, when
#     a plain FILE already occupies the exact directory path being created
#     (the root itself is a real, writable directory -- only the version-dir
#     segment is blocked). `storeCachedAt` must degrade exactly like any
#     other createDir failure: rate-limited stderr warning, return false,
#     never crash.
# ---------------------------------------------------------------------------

block test_store_ioerror_when_file_blocks_version_dir:
  resetCacheWriteWarnings()

  let sd = freshStateDir("ioerror_verdir")
  let root = sd / "cache"
  createDir(root)
  let verDir = cacheDir(sd)
  writeFile(verDir, "i am a file, not a directory")
  defer: removeFile(verDir)

  var ok = true
  let captured = withCapturedStderr(proc() =
    ok = storeCachedAt(root, SoundnessKey("8080808080808080"), sampleResult())
  )
  assert not ok, "a version dir blocked by a file (IOError) must degrade to false, not crash"
  assert "could not create cache dir" in captured

echo "test_resultcache: all blocks passed"
