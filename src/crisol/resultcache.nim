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
## rfc-0007 A1d-ii: the payload carries the REAL stored observation — the
## run-phase `ProcessResult` exactly as `process/resultjson` (the ONE wire
## owner) would serialize it — not a derived outcome/exitCode/signal
## projection.  `outcome` is deliberately ABSENT: the cache stores the
## observation and never the verdict (§2); a hit's outcome is recomputed via
## `outcome(r)` at the trust boundary (`cachedispatch.lookupAtPlan`),
## never read from disk.
##
## ```json
## {
##   "header":  { "formatVersion": <int> },
##   "payloadChecksum": "<16 hex chars>",   -- FNV-1a over the serialized payload
##   "payload": {
##     "run":        { "exit": {...}, "cause": {...}, "evidence": {...},
##                     "rusage": {...} | null, "durationUs": <int64> },
##                   -- process/resultjson.toJson's shape, verbatim
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
## - **Structural failure in the stored observation** (rfc-0007 A1d-ii): `run`
##   fails `resultjson.fromJson` — a missing key, a wrong JSON kind, or an
##   enum string that does not inhabit the Nim enum.  Same strict own-reader
##   posture as `process/resultjson` itself (§2): never a default-valued lie.
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
import crisol/types
import crisol/depgraph   # re-uses fnv1a64, toHex16; never reimplement the hash
import crisol/ioutils    # atomicPublish: shared O_EXCL-tmp + writeAllFd + rename(2)
import crisol/process/types as ptypes
import crisol/process/resultjson  # the ONE ProcessResult<->JSON owner (§2)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const resultCacheFormatVersion* = 3
  ## Increment when the cache JSON schema changes incompatibly.  A loaded file
  ## with a different formatVersion is treated as a MISS (discard-on-mismatch).
  ## Note: the version is part of the on-disk *path* (`cache/v<fmt>/`) AND the
  ## file header — the path partitions by version so old and new entries never
  ## share a directory, and the header is the authoritative deserialize check.
  ##
  ## rfc-0007 A1d-ii: bumped 1 -> 2.  The payload shape changed from a derived
  ## {outcome,exitCode,signal,durationMs} projection to the REAL stored `run`
  ## ProcessResult (process/resultjson's wire shape).  A pre-bump (v1) entry
  ## lives under a different directory (`cache/v1/`) and its header
  ## formatVersion (1) mismatches this binary's constant regardless — a v1
  ## entry is a MISS here, never a fabricated read of the old shape.
  ##
  ## rfc-0007 A2a-iii: bumped 2 -> 3.  The SoundnessKey's fold-input shape
  ## changed (`keys.KeyInputs.rlimitConfig: RlimitConfig` -> `.limits:
  ## Limits`, the §1 enum-indexed home) — deliberate and free (§5): a v2 key
  ## folded the old five-field RlimitConfig serialization, so a stored v2
  ## entry's key can never match a freshly-derived v3 key even for an
  ## unchanged config, and must MISS rather than alias a differently-shaped
  ## fold input to a coincidentally-equal-looking string.

const DefaultMaxCacheEntries* = 10_000
  ## Interim soft cap on distinct cache entries (RFC-0004 F1, round 2).

# ---------------------------------------------------------------------------
# Type — kept local to the store (serialization-coupled; not a shared core type)
# ---------------------------------------------------------------------------

type
  CachedResult* = object
    ## A cached test-execution observation, addressed by `SoundnessKey`.
    ## `payloadChecksum` is computed on store and verified on load — a caller
    ## constructs the record with it empty; `storeCached` fills it.
    ##
    ## rfc-0007 A1d-ii: `run` is the REAL run-phase `ProcessResult` — the
    ## observation, not the verdict.  There is deliberately NO `outcome`
    ## field here: the cache always stores the observation and NEVER the
    ## derived verdict (§2) — `outcome(r)` is recomputed over it at every
    ## replay, at the trust boundary (`cachedispatch.lookupAtPlan`), never
    ## trusted from storage.  The exit code/signal/durationMs are subsumed by
    ## `run.exit`/`run.durationUs` — asking this type to carry both would be
    ## two sources of truth for the same fact.
    run*:             ptypes.ProcessResult
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

proc payloadToJson*(res: CachedResult): JsonNode =
  ## Serialize ONLY the payload (no header, no checksum).  The checksum is an
  ## FNV-1a fold over `$payloadToJson(res)`, so this must be deterministic.
  ##
  ## rfc-0005 A1: exported so `cachewire`'s `CacheSerializer` and this
  ## module's own `loadCached`/`storeCached` share the identical proc --
  ## "one canonical payload" (see `canonicalPayload` below), not two
  ## codecs that merely happen to agree by construction.
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
  # rfc-0007 A1d-ii: the REAL observation, via resultjson (the one wire owner).
  result["run"]        = resultjson.toJson(res.run)
  result["cachedAt"]   = newJInt(res.cachedAt)
  result["records"]    = recsArr

proc parseStatus(s: string): Option[RecordStatus] =
  case s
  of "rsPass": some(rsPass)
  of "rsFail": some(rsFail)
  of "rsSkip": some(rsSkip)
  else:        none(RecordStatus)

proc payloadFromJson*(node: JsonNode): Option[CachedResult] =
  ## Parse a payload node into a CachedResult.  Returns none on any structural
  ## problem (treated as a MISS by the caller) — never raises on bad data.
  ##
  ## rfc-0005 A1: exported alongside `payloadToJson` (see there).
  ##
  ## rfc-0007 A1d-ii: `run` is parsed through `resultjson.fromJson` — crisol's
  ## OWN reader (§2).  A structural problem in the stored observation (a
  ## missing key, a wrong JSON kind, an enum string that does not inhabit the
  ## Nim enum — e.g. a future crisol version's new Outcome-adjacent wire
  ## value) is a MISS here too, never a default-valued lie.
  if node == nil or node.kind != JObject: return
  let run = resultjson.fromJson(node{"run"})
  if run.isNone: return

  var res = CachedResult(
    run:      run.get,
    cachedAt: node{"cachedAt"}.getBiggestInt(0),
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

proc canonicalPayload*(res: CachedResult): string =
  ## THE canonical byte form the payload checksum is computed over -- one
  ## proc, shared by writer (`storeCached`), reader (`loadCached`), and, from
  ## rfc-0005 A1, the `cachewire` serializer's integrity and trust layers
  ## (RFC-0005 "Integrity vs. trust — two layers, two hashes, one canonical
  ## payload"; ed25519/HMAC sign over `SHA256(canonicalPayload(res))` in
  ## Stage C, but that layer is crypto-free through A1).  Deliberately just
  ## `$payloadToJson(res)` -- no separate encoding, so "one proc, shared by
  ## every consumer" is literally true rather than two codecs that happen to
  ## agree by construction.
  $payloadToJson(res)

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
  ##     (torn or tampered file);
  ##   - the stored `run` observation fails `resultjson.fromJson` (rfc-0007
  ##     A1d-ii's own-reader posture, §2).
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

  let recomputed = toHex16(fnv1a64(canonicalPayload(parsed.get)))
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
  # L10: atomicPublish (ioutils) writes to `<finalPath>.<pid>.tmp` — the
  # writer's PID in the tmp filename means concurrent writers for the same
  # key each operate on their own tmp file, no collision on the stale-tmp
  # removal or the O_EXCL open.  Each writer's tmp is renamed to `<key>.json`;
  # rename(2) is atomic, so last-writer-wins on identical content.

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
  let checksum    = toHex16(fnv1a64(canonicalPayload(res)))

  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)

  let fileNode = newJObject()
  fileNode["header"]          = headerNode
  fileNode["payloadChecksum"] = newJString(checksum)
  fileNode["payload"]         = payloadNode

  let jsonStr = $fileNode

  # RFC-0006 R1: the O_EXCL-tmp + writeAllFd + rename(2) mechanic is factored
  # into ioutils.atomicPublish (renamed from atomicPutFile at RFC-0007 A3) —
  # this call is behaviorally identical to the block it replaces. RFC-0006
  # review R10: atomicPublish reports the specific OS failure reason instead
  # of a bare bool, restoring the diagnostic this module logged before the R1
  # factor-out.
  let (ok, err) = atomicPublish(finalPath, jsonStr)
  if not ok:
    stderr.write("crisol: warning: could not write cache entry '" & finalPath &
                 "': " & err & "\n")
    return false
  return true

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
