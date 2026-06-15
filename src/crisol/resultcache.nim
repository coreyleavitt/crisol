## resultcache.nim — A1a: the ExecutionCache store (RFC-0004 F1).
##
## A content-addressed key-value store: `SoundnessKey → CachedResult`.  This is
## the substrate that turns crisol from a *selection* tool into an *incremental*
## engine: a provably-unchanged entrypoint (same `SoundnessKey`) skips both
## compile and run, its result served from here.
##
## ## On-disk layout
##
## One JSON file per key:
##
## ```
##   <stateDir>/cache/v<resultCacheFormatVersion>/<soundnessKey>.json
## ```
##
## A directory of per-key files is naturally concurrent-safe across a CI matrix:
## two invocations storing *different* keys never conflict; two storing the
## *same* key are idempotent (same inputs ⇒ same result), so last-writer-wins
## via `rename(2)` is correct.  The `SoundnessKey` is a 16-hex-char digest, so it
## is a safe filename (no path separators, no traversal).
##
## ## File format
##
## ```json
## {
##   "header":  { "formatVersion": <int> },
##   "payloadChecksum": "<16 hex chars>",   -- FNV-1a over the serialized payload
##   "payload": {
##     "outcome":    "<enum name>",
##     "exitCode":   <int>,
##     "signal":     <int>,
##     "durationMs": <int64>,
##     "cachedAt":   <int64>,
##     "records":    [ { "name", "status", "durationUs", "msg"?, "tags" }, ... ]
##   }
## }
## ```
##
## ## Invalidation (both ⇒ a MISS, never an error/raise)
##
## - **Format-version mismatch** (header): the on-disk schema differs from this
##   binary's `resultCacheFormatVersion`.  Discard-on-mismatch, exactly as
##   `DepGraphFormatVersion` already works.
## - **Checksum mismatch**: the `payloadChecksum` does not match an FNV-1a fold
##   over the (canonically re-serialized) payload — the file was torn or tampered.
##
## ## Atomic writes
##
## serialize → write `<key>.<pid>.tmp` (O_CREAT|O_EXCL — fails on a planted
## symlink, P5 hardening; PID suffix avoids concurrent-writer collisions per L10)
## → `rename(2)` to `<key>.json`.  Stale `.tmp` files from crashed writers are
## removed by `gcResultCache` at GC time (L8).  Readers always see the old or
## new file, never a torn write.
##
## ## Interim soft cap (GC deferred to A1c)
##
## On write, if the cache directory already holds ≥ `maxCacheEntries` (default
## 10 000) *distinct* keys AND this key is new, the write is **skipped** and
## `storeCached` returns `false` — it never raises and never evicts.  Re-storing
## an *existing* key is always allowed (it replaces in place, not grows).  This
## bounds inode/directory growth (`ext4` `readdir`/`unlink` degrade past ~100 K
## entries) until the real LRU GC lands in A1c.

import std/[algorithm, json, options, os, strutils]
import std/posix as posix_mod
import crisol/types
import crisol/depgraph   # re-uses fnv1a64, toHex16; never reimplement the hash
import crisol/ioutils    # writeAllFd: robust partial-write + EINTR-retry loop

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const resultCacheFormatVersion* = 1
  ## Increment when the cache JSON schema changes incompatibly.  A loaded file
  ## with a different formatVersion is treated as a MISS (discard-on-mismatch).
  ## Note: the version is part of the on-disk *path* (`cache/v<fmt>/`) AND the
  ## file header — the path partitions by version so old and new entries never
  ## share a directory, and the header is the authoritative deserialize check.

const DefaultMaxCacheEntries* = 10_000
  ## Interim soft cap on distinct cache entries (RFC-0004 F1, round 2).

# ---------------------------------------------------------------------------
# Type — kept local to the store (serialization-coupled; not a shared core type)
# ---------------------------------------------------------------------------

type
  CachedResult* = object
    ## A cached test-execution outcome, addressed by `SoundnessKey`.
    ## `payloadChecksum` is computed on store and verified on load — a caller
    ## constructs the record with it empty; `storeCached` fills it.
    outcome*:         Outcome
    exitCode*:        int
    signal*:          int
    durationMs*:      int64
    records*:         seq[TestRecord]
    cachedAt*:        int64    ## unix epoch seconds at store time
    payloadChecksum*: string   ## FNV-1a (16 hex) over the serialized payload

# ---------------------------------------------------------------------------
# Public: result-cache directory-name predicates
# ---------------------------------------------------------------------------

proc resultCacheDirName*(): string {.inline.} =
  ## Returns the base directory name for the current result-cache version,
  ## i.e. `"v" & $resultCacheFormatVersion`.  This is the single authoritative
  ## source for the name so that `clean.nim` never hardcodes `"v1"`.
  "v" & $resultCacheFormatVersion

proc isResultCacheRootName*(name: string): bool =
  ## Returns true iff `name` matches the pattern `v<digits>` (one or more
  ## decimal digits following a leading `v`).  This recognises ANY result-cache
  ## version subtree — including old versions whose directory survives after a
  ## format bump — so `cleanOrphans` never misidentifies them as orphan compile
  ## dirs.  Content-GC of superseded versions is A1c; C0 only preserves.
  if name.len < 2: return false
  if name[0] != 'v': return false
  for i in 1 ..< name.len:
    if name[i] notin {'0' .. '9'}: return false
  true

# ---------------------------------------------------------------------------
# Path helpers (internal)
# ---------------------------------------------------------------------------

proc cacheVersionDir(stateDir: string): string {.inline.} =
  stateDir / "cache" / resultCacheDirName()

proc keyFilePath(stateDir: string; key: SoundnessKey): string {.inline.} =
  cacheVersionDir(stateDir) / ($key & ".json")

# ---------------------------------------------------------------------------
# Payload (de)serialization — the canonical form the checksum is taken over
# ---------------------------------------------------------------------------

proc payloadToJson(res: CachedResult): JsonNode =
  ## Serialize ONLY the payload (no header, no checksum).  The checksum is an
  ## FNV-1a fold over `$payloadToJson(res)`, so this must be deterministic.
  let recsArr = newJArray()
  for r in res.records:
    let recNode = newJObject()
    recNode["name"]       = newJString(r.name)
    recNode["status"]     = newJString($r.status)
    recNode["durationUs"] = newJInt(r.durationUs)
    if r.msg.isSome:
      recNode["msg"] = newJString(r.msg.get)
    # msg absent in JSON ⇔ none — no null sentinel, keeps the canonical form tight.
    let tagsArr = newJArray()
    for t in r.tags:
      tagsArr.add newJString(t)
    recNode["tags"] = tagsArr
    recsArr.add recNode

  result = newJObject()
  result["outcome"]    = newJString($res.outcome)
  result["exitCode"]   = newJInt(res.exitCode)
  result["signal"]     = newJInt(res.signal)
  result["durationMs"] = newJInt(res.durationMs)
  result["cachedAt"]   = newJInt(res.cachedAt)
  result["records"]    = recsArr

proc parseStatus(s: string): Option[RecordStatus] =
  case s
  of "rsPass": some(rsPass)
  of "rsFail": some(rsFail)
  of "rsSkip": some(rsSkip)
  else:        none(RecordStatus)

proc parseOutcome(s: string): Option[Outcome] =
  case s
  of "oPassed":        some(oPassed)
  of "oFailed":        some(oFailed)
  of "oCompileFailed": some(oCompileFailed)
  of "oTimeout":       some(oTimeout)
  of "oSignal":        some(oSignal)
  of "oSpawnError":    some(oSpawnError)
  else:                none(Outcome)

proc payloadFromJson(node: JsonNode): Option[CachedResult] =
  ## Parse a payload node into a CachedResult.  Returns none on any structural
  ## problem (treated as a MISS by the caller) — never raises on bad data.
  if node == nil or node.kind != JObject: return
  let outcomeNode = node{"outcome"}
  if outcomeNode == nil or outcomeNode.kind != JString: return
  let outcome = parseOutcome(outcomeNode.getStr(""))
  if outcome.isNone: return

  var res = CachedResult(
    outcome:    outcome.get,
    exitCode:   node{"exitCode"}.getInt(0),
    signal:     node{"signal"}.getInt(0),
    durationMs: node{"durationMs"}.getBiggestInt(0),
    cachedAt:   node{"cachedAt"}.getBiggestInt(0),
  )

  let recsNode = node{"records"}
  if recsNode != nil and recsNode.kind == JArray:
    for recNode in recsNode:
      if recNode.kind != JObject: return
      let statusNode = recNode{"status"}
      if statusNode == nil or statusNode.kind != JString: return
      let status = parseStatus(statusNode.getStr(""))
      if status.isNone: return
      var rec = TestRecord(
        name:       recNode{"name"}.getStr(""),
        status:     status.get,
        durationUs: recNode{"durationUs"}.getBiggestInt(0),
        msg:        none(string),
        tags:       @[],
      )
      let msgNode = recNode{"msg"}
      if msgNode != nil and msgNode.kind == JString:
        rec.msg = some(msgNode.getStr(""))
      let tagsNode = recNode{"tags"}
      if tagsNode != nil and tagsNode.kind == JArray:
        for t in tagsNode:
          if t.kind == JString: rec.tags.add t.getStr("")
      res.records.add rec

  result = some(res)

# ---------------------------------------------------------------------------
# Public: load
# ---------------------------------------------------------------------------

proc loadCached*(stateDir: string; key: SoundnessKey): Option[CachedResult] =
  ## Look up `key` in the cache.
  ##
  ## Returns `none` (a MISS — never an exception) when:
  ##   - the file is absent;
  ##   - the file is unreadable or malformed JSON;
  ##   - the header `formatVersion` differs from `resultCacheFormatVersion`;
  ##   - the `payloadChecksum` does not match the re-serialized payload
  ##     (torn or tampered file).
  ##
  ## On a hit, returns `some(CachedResult)` with `payloadChecksum` populated.
  let path = keyFilePath(stateDir, key)
  if not fileExists(path): return

  var raw: string
  try:
    raw = readFile(path)
  except CatchableError:
    return  # unreadable ⇒ miss

  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError:
    return  # malformed ⇒ miss

  if node.kind != JObject: return

  # Header / format-version check.
  let header = node{"header"}
  if header == nil or header.kind != JObject: return
  if header{"formatVersion"}.getInt(-1) != resultCacheFormatVersion: return

  let payloadNode = node{"payload"}
  if payloadNode == nil: return

  # Integrity: recompute the checksum over the canonical re-serialization of the
  # parsed payload and compare to the stored one.  Any divergence ⇒ miss.
  let storedChecksum = node{"payloadChecksum"}.getStr("")
  if storedChecksum.len == 0: return

  let parsed = payloadFromJson(payloadNode)
  if parsed.isNone: return

  let recomputed = toHex16(fnv1a64($payloadToJson(parsed.get)))
  if recomputed != storedChecksum: return  # checksum mismatch ⇒ MISS

  var res = parsed.get
  res.payloadChecksum = storedChecksum
  result = some(res)

# ---------------------------------------------------------------------------
# Soft-cap helper
# ---------------------------------------------------------------------------

proc countCacheEntries(dir: string): int =
  ## Count `*.json` entries currently in the version dir.  Missing dir ⇒ 0.
  ## `.tmp` files are NOT counted (they are not committed entries).
  ##
  ## L6: This is O(n) in the number of cache files — a full `walkDir` on every
  ## `storeCached` call.  That cost is intentional and acceptable for v1: the soft
  ## cap is an interim write-time backstop against unbounded inode growth between
  ## `crisol clean` runs.  The real size bound is enforced by `gcResultCache`
  ## (A1c), which runs under the exclusive stateDir lock at clean time.  A cached
  ## entry-count mechanism would be over-engineering here.
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      inc result

# ---------------------------------------------------------------------------
# Public: store
# ---------------------------------------------------------------------------

proc storeCached*(stateDir: string; key: SoundnessKey; res: CachedResult;
                  maxCacheEntries = DefaultMaxCacheEntries): bool =
  ## Store `res` under `key`, atomically.  Returns:
  ##   - `true`  — the entry was written (or replaced in place);
  ##   - `false` — the write was SKIPPED by the interim soft cap.
  ##
  ## The soft cap skips only when adding a *new* key would exceed
  ## `maxCacheEntries`; re-storing an existing key always proceeds (it replaces,
  ## not grows).  A skipped store never raises and never evicts.
  ##
  ## Atomicity: payload+header+checksum are serialized, written to
  ## `<key>.json.tmp` with O_CREAT|O_EXCL (a planted symlink/file makes the open
  ## fail), then `rename(2)`d into place.  A stale `.tmp` is removed first.
  ## On any I/O failure this warns to stderr and returns `false` — a cache write
  ## is best-effort and never aborts a run.
  let verDir    = cacheVersionDir(stateDir)
  let finalPath = keyFilePath(stateDir, key)
  # L10: include the writer's PID in the tmp filename so concurrent writers for
  # the same key each operate on their own tmp file — no collision on the stale-tmp
  # removal or the O_EXCL open.  Each writer renames its own `<key>.<pid>.tmp` to
  # `<key>.json`; rename(2) is atomic, so last-writer-wins on identical content.
  let tmpPath   = finalPath & "." & $posix_mod.getpid() & ".tmp"

  # Soft cap: only blocks growth (a NEW key past the cap), never a replacement.
  if not fileExists(finalPath):
    if countCacheEntries(verDir) >= maxCacheEntries:
      stderr.write("crisol: warning: result cache at soft cap (" &
                   $maxCacheEntries & " entries); skipping write for key " &
                   $key & " (run `crisol clean` to prune)\n")
      return false

  try:
    createDir(verDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create cache dir '" & verDir &
                 "': " & e.msg & "\n")
    return false

  # Compute checksum over the canonical payload serialization, then assemble the
  # full file node (header + checksum + payload).
  let payloadNode = payloadToJson(res)
  let checksum    = toHex16(fnv1a64($payloadNode))

  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)

  let fileNode = newJObject()
  fileNode["header"]          = headerNode
  fileNode["payloadChecksum"] = newJString(checksum)
  fileNode["payload"]         = payloadNode

  let jsonStr = $fileNode

  # Best-effort removal of our own PID-specific .tmp if it exists (leftover from
  # a previous attempt in the same process, e.g. a retry loop).  Different PIDs
  # have different tmpPaths so this never races another live writer.  Stale .tmp
  # files from different crashed writers are cleaned by gcResultCache (L8).
  try: removeFile(tmpPath) except CatchableError: discard

  var tmpFd: cint = -1
  try:
    let flags = posix_mod.O_CREAT or posix_mod.O_EXCL or posix_mod.O_WRONLY or
                posix_mod.O_CLOEXEC
    tmpFd = posix_mod.open(tmpPath.cstring, flags, posix_mod.Mode(0o600))
    if tmpFd < 0:
      let err = $posix_mod.strerror(posix_mod.errno)
      stderr.write("crisol: warning: could not create temp file for cache entry '" &
                   tmpPath & "': " & err & "\n")
      return false
    let writeOk = writeAllFd(tmpFd, jsonStr)
    discard posix_mod.close(tmpFd)
    tmpFd = -1
    if not writeOk:
      stderr.write("crisol: warning: short/interrupted write to cache temp file '" &
                   tmpPath & "'\n")
      try: removeFile(tmpPath) except CatchableError: discard
      return false
    moveFile(tmpPath, finalPath)
    return true
  except OSError as e:
    if tmpFd >= 0: discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: could not write cache entry '" & finalPath &
                 "': " & e.msg & "\n")
    try: removeFile(tmpPath) except CatchableError: discard
    return false
  except Exception as e:
    if tmpFd >= 0: discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: unexpected error writing cache entry '" &
                 finalPath & "': " & e.msg & "\n")
    try: removeFile(tmpPath) except CatchableError: discard
    return false

# ---------------------------------------------------------------------------
# A1c: Result-cache GC (size-bounded LRU + age eviction)
# ---------------------------------------------------------------------------
##
## Design notes (A1c):
##
## - The soft-cap in `storeCached` is KEPT as a write-time backstop.  Real LRU
##   eviction at clean-time is additive — they are complementary.  The soft-cap
##   prevents unbounded growth between cleans; the GC enforces the bound.
##
## - `nowSecs` is INJECTED (not called internally) so the age logic is fully
##   deterministic in unit tests.  The clean entry point passes `epochTime()`.
##
## - `cachedAt` is read from the JSON payload.  On any parse failure the file is
##   treated as having `cachedAt = 0` (epoch origin) — effectively oldest —
##   which ensures malformed files are evicted first.  The file is never skipped
##   silently; it is counted and evicted.
##
## - Eviction order: sort by `cachedAt` ascending, then delete from the front.
##   Age bound is applied before size bound so age violations are always removed
##   regardless of the count.

type
  GcResultCacheReport* = tuple[evicted: int]
    ## Summary of a gcResultCache run.

proc readCachedAt(path: string): int64 =
  ## Extract `cachedAt` from a cache JSON file.
  ## Returns 0 on any read/parse failure (treated as oldest for GC ordering).
  var raw: string
  try: raw = readFile(path)
  except CatchableError: return 0
  var node: JsonNode
  try: node = parseJson(raw)
  except CatchableError: return 0
  if node == nil or node.kind != JObject: return 0
  let payload = node{"payload"}
  if payload == nil or payload.kind != JObject: return 0
  payload{"cachedAt"}.getBiggestInt(0)

proc gcResultCache*(stateDir: string; maxEntries: int; maxAgeSecs: int64;
                    nowSecs: int64): GcResultCacheReport =
  ## Evict result-cache entries that violate the size or age bound.
  ##
  ## Parameters:
  ##   stateDir    — the `.crisol` state directory.
  ##   maxEntries  — keep at most this many entries (LRU by cachedAt); 0 = no size bound.
  ##   maxAgeSecs  — evict entries older than this many seconds; 0 = no age bound.
  ##   nowSecs     — current unix epoch seconds (injected for testability).
  ##
  ## Returns the number of entries evicted.
  ##
  ## Safety:
  ##   - Never raises on malformed files; parse failures → treated as `cachedAt = 0`.
  ##   - Only deletes `*.json` files (not `.tmp` or other artifacts).
  ##   - Callers (cleanOrphans) must hold the stateDir lock before calling.
  let verDir = cacheVersionDir(stateDir)
  if not dirExists(verDir):
    return (evicted: 0)

  # L8: Remove stale `.tmp` files left by crashed `storeCached` calls.
  # GC holds the exclusive stateDir lock (guaranteed by cleanOrphans' caller),
  # so no live writer can be mid-write here — any `.tmp` present is genuinely
  # orphaned.  L10's PID-suffixed names (`<key>.<pid>.tmp`) are matched by the
  # `.tmp` suffix check below, so they are cleaned regardless of the PID suffix.
  for kind, path in walkDir(verDir):
    if kind == pcFile and path.endsWith(".tmp"):
      try: removeFile(path) except CatchableError: discard

  # Collect all *.json files with their cachedAt.
  type Entry = tuple[path: string; cachedAt: int64]
  var entries: seq[Entry]
  for kind, path in walkDir(verDir):
    if kind == pcFile and path.endsWith(".json"):
      let ca = readCachedAt(path)
      entries.add (path: path, cachedAt: ca)

  if entries.len == 0:
    return (evicted: 0)

  # Sort by cachedAt ascending (oldest first).
  entries.sort(proc(a, b: Entry): int = cmp(a.cachedAt, b.cachedAt))

  var evicted = 0

  # Age bound: evict everything older than (nowSecs - maxAgeSecs).
  if maxAgeSecs > 0:
    let cutoff = nowSecs - maxAgeSecs
    var kept: seq[Entry]
    for e in entries:
      if e.cachedAt < cutoff:
        try: removeFile(e.path) except CatchableError: discard
        inc evicted
      else:
        kept.add e
    entries = kept

  # Size bound: if still over maxEntries, evict oldest until at or under.
  if maxEntries > 0 and entries.len > maxEntries:
    let toEvict = entries.len - maxEntries
    for i in 0 ..< toEvict:
      try: removeFile(entries[i].path) except CatchableError: discard
      inc evicted

  result = (evicted: evicted)
