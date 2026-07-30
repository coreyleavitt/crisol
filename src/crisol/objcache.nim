## objcache.nim — RFC-0006 Stage R, R1: the content-keyed cross-entrypoint
## object cache CORE (types + store).
##
## A content-addressed store: `(keyHash, keyPreimage) → cached .o bytes`.
## Where resultcache.nim addresses whole test-execution outcomes by a
## `SoundnessKey`, objcache addresses individual C-compile *objects* by a key
## over the full cc input set — normalized cc command + `.c` content + the
## full `cc -M` `#include`-closure manifest + `nimVersion` + `ccVersion`.
##
## R1 takes `keyHash` + `keyPreimage` as GIVEN inputs (plain strings): the key
## itself is computed elsewhere (artifactid.nim, wired in R2). This module
## owns only the on-disk store and its two soundness defenses:
##
##   - **preimage confirmation** — a digest (`keyHash`) is not by itself
##     trustworthy: a fast non-cryptographic hash (crisol's folded FNV-1a
##     idiom) over a persisted keyspace of hundreds of thousands of
##     near-identical substrate `.c` files CAN collide. Every stored entry
##     also carries its full `keyPreimage`; a lookup is a confirmed hit only
##     when the requester's freshly-computed preimage matches the one on
##     disk. A digest match with a preimage mismatch is a `ocdCollisionReject`
##     — treated as a MISS, logged forensically (never silently served).
##   - **payload checksum** — an FNV-1a fold over the `.o` bytes, verified on
##     read, guards against torn writes / bit rot (same idiom as
##     resultcache's `payloadChecksum`, just over raw bytes instead of JSON).
##
## ## On-disk layout — a two-artifact commit
##
## ```
##   <stateDir>/objcache/v<objCacheFormatVersion>/<keyHash>.o
##   <stateDir>/objcache/v<objCacheFormatVersion>/<keyHash>.meta
## ```
##
## Unlike resultcache's single JSON file, an object's payload is raw bytes —
## the checksum cannot live *inside* the object the way it lives inside a JSON
## envelope. So the commit is two artifacts:
##
##   - `<keyHash>.o`    — the raw object bytes (copied from a caller-supplied
##                        source `.o` path).
##   - `<keyHash>.meta` — JSON: `{ "header": {"formatVersion": N},
##                        "payloadChecksum": "<16 hex FNV-1a over the .o
##                        bytes>", "keyPreimage": "<the full key preimage>" }`.
##
## **Write order is load-bearing**: `.o` FIRST (via `ioutils.atomicPutFile`),
## THEN `.meta`. A crash between the two renames leaves a `.o` with no
## `.meta` — and a missing/unreadable `.meta` is defined as a MISS (never a
## false hit), so a torn commit is always safe, never silently wrong.
##
## Both artifacts are written via the shared `ioutils.atomicPutFile` helper
## (O_EXCL-tmp + `writeAllFd` + `rename(2)`) — the exact mechanic
## resultcache.nim uses for its own entries, factored out in this same slice
## so there is exactly one correct atomic-file-write implementation.
##
## ## Miss conditions (lookup never raises; every failure is a MISS)
##
##   - `<keyHash>.o` missing/unreadable.
##   - `<keyHash>.meta` missing/unreadable (including the torn-commit case
##     above).
##   - `.meta`'s header `formatVersion` differs from `objCacheFormatVersion`.
##   - stored `keyPreimage` != the requester's `keyPreimage` (collision
##     reject — logged to stderr, naming the keyHash).
##   - recomputed FNV-1a checksum over the on-disk `.o` bytes != the stored
##     `payloadChecksum` (torn write).
##
## Only when BOTH the preimage confirms AND the checksum verifies does
## `lookupObject` return `some(pathToTheVerifiedObj)`.
##
## ## Interim soft cap (GC deferred to R4)
##
## Mirrors resultcache's soft cap, extended (review Finding 3) to ALSO honor
## an aggregate-BYTE cap: on store, if the version dir already holds
## >= `maxEntries` distinct keys, OR already holds >= `maxBytes` of on-disk
## `.o`+`.meta` bytes (`maxBytes <= 0` = unbounded on that axis), AND this
## key is new, the write is skipped (`storeObject` returns `false`) — it
## never raises and never evicts. Re-storing an EXISTING key always proceeds
## (it replaces in place, not grows). `realObjCacheSeams`/`storeObject`'s
## `maxEntries`/`maxBytes` parameters are THREADED FROM the caller's
## configured `objcacheMaxEntries`/`objcacheMaxBytes` (see
## `cacheworker.runCompileCacheWorker`, which resolves `MeasurePlan`'s
## `objcacheMaxEntries`/`objcacheMaxBytes` fields — themselves populated from
## `Config` in `runner.buildCompileWorkerPlan` — the SAME resolution
## `clean.cleanOrphans` already applies for `gcObjCache`'s bounds), not left
## hardcoded — this is what gives the DEFAULT `crisol run` path (not just
## the manual `crisol clean` GC pass) an automatic, configured bound on
## objcache disk growth. Real LRU GC (`gcObjCache`) is R4 and remains the
## only pass that EVICTS existing entries; this soft cap only ever refuses a
## NEW write, matching resultcache's own write-time/GC-time split.
##
## ## Scope of this module (R1 only)
##
## This module does NOT wire into the runner, the compile worker, or the
## M-driver (R2). It does NOT implement GC (R4) or hit-rate/reuse reporting
## (R5). It does NOT compute the cache key (artifactid.nim, wired in R2) — it
## takes `keyHash` + `keyPreimage` as given.
##
## ## Host-local v1 scope (R3)
##
## The objcache key (computed in artifactid.nim, R2) covers the normalized cc
## command, the `.c` file content, the full `cc -M` `#include`-closure
## manifest, `nimVersion`, and `ccVersion` — but it does NOT cover *ambient cc
## environment*: `CPATH`, `C_INCLUDE_PATH`, `LIBRARY_PATH`, `CCACHE_*`, and
## similar variables that can silently steer where a compiler looks for
## headers/libraries. This is a direct consequence of how the compile is
## spawned: the compile phase forks via raw `forkExec`, NOT the hermetic
## `forkExecEnvScratch` used for the test RUN — so unlike the run path,
## nothing scrubs or captures the ambient cc env before compiling.
##
## Within a single `crisol run` invocation every compile inherits the exact
## same process environment, so two objects compiled in the same run that hit
## the same key really were compiled under the same effective cc environment
## — a non-issue in-process. But ACROSS invocations/hosts sharing a cache
## directory (e.g. two CI runners, or a developer laptop vs. CI, with
## different `CPATH`/`CCACHE_*` setups) this is a real soundness gap: two
## hosts could compute the identical objcache key from identical `.c`
## content + identical include closure, yet have produced that closure (or
## would compile it) under different ambient cc environments. **Therefore the
## object cache is host-local in v1** — a `stateDir` (and its `objcache/`
## subtree) must not be shared/synced across hosts or CI runners with
## divergent toolchain environments. A cross-host/shared cache is deferred to
## the RFC-0005 (distributed cache and trust) door, and would require
## explicit compile-env capture folded into the objcache key before it could
## be trusted across machines.
##
## ## Ambient ccache
##
## The compile-worker forces `CCACHE_DISABLE=1` for its own cc invocations
## (measureworker.nim's `forceMeasurementCcEnv`, shared by the objcache
## worker path). This prevents an ambient system/user ccache from stacking
## underneath crisol's own object cache — without this, a ccache hit could
## make a "miss, compiled" objcache entry deceptively fast to reproduce (or,
## worse, ccache's own environment-sensitivity could smuggle exactly the kind
## of ambient-env non-determinism described above into what crisol believes
## is a clean compile).
##
## ## Soundness relationship to RFC-0004 (the "provably outside" invariant)
##
## Object reuse — whether a given `.o` was compiled fresh or served from this
## cache — is provably OUTSIDE the RFC-0004 result-cache soundness key.
## `keys.soundnessKey` folds exactly 9 components (`closureContentHash`,
## `flagHash`, `nimVersion`, `ccVersion`, `fixtureHash`, `argv`,
## `rlimitConfig`, `hermeticEnvHash`, `protocolMajor`) — source, flags,
## toolchain, fixtures, invocation, and hermetic env. NONE of them is the
## compiled `.o`'s identity or any objcache/compile-cache state; `KeyInputs`
## (keys.nim) has no field through which an objcache hit/miss could enter the
## key. An objcache hit changes only HOW a binary was assembled (link-in a
## reused `.o` vs. recompile one), never WHAT its source/flags/toolchain are
## — so it cannot perturb a result-cache key, and a hit vs. a miss must
## produce functionally identical output.
##
## This is a regression-guarded invariant, not just documentation:
##   - `tests/unit/test_soundness_key_objcache_independence.nim` — asserts
##     `soundnessKey` is a pure function of `KeyInputs`, and enumerates
##     `KeyInputs`'s actual fields (via `fieldPairs`) to assert none is
##     objcache/compile-cache-shaped.
##   - `tests/integration/test_objcache_soundness_independence.nim` — drives
##     the real crisol binary against the same entrypoint with `--objcache`
##     and with `--no-objcache` (and again against a plain default run) and
##     asserts the persisted `inputHash` (the soundnessKey string in
##     `.crisol/lastrun.json`) is byte-identical across all of them.

import std/[algorithm, json, options, os, sets, strutils, times]
import crisol/depgraph   # re-uses fnv1a64, toHex16; never reimplement the hash
import crisol/ioutils    # atomicPutFile: shared O_EXCL-tmp + writeAllFd + rename(2)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const objCacheFormatVersion* = 1
  ## Increment when the .meta JSON schema changes incompatibly. A loaded
  ## entry with a different formatVersion is treated as a MISS
  ## (discard-on-mismatch), exactly like resultCacheFormatVersion. The version
  ## is part of the on-disk *path* (`objcache/v<fmt>/`) AND the .meta header —
  ## the path partitions by version so old and new entries never share a
  ## directory, and the header is the authoritative deserialize check.

const DefaultMaxObjCacheEntries* = 10_000
  ## Interim soft cap on distinct object-cache entries, mirroring
  ## resultcache's DefaultMaxCacheEntries. Real LRU GC is R4.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ObjCacheDecision* = enum
    ## Mutually-exclusive TERMINAL per-object outcomes (RFC-0004 M8 enum
    ## discipline: each value stands alone, callers never need to combine
    ## two values to describe one object's fate).
    ##
    ##   ocdHit            — a confirmed cache hit: preimage matched AND the
    ##                       on-disk checksum verified. The compile for this
    ##                       object was skipped.
    ##   ocdMissCompiled   — a miss; the object was compiled locally but NOT
    ##                       stored (e.g. store was gated off, or the store
    ##                       itself failed/was skipped). Distinguishes
    ##                       "compiled, not cached" from "compiled AND cached"
    ##                       (M8's cdmKeyMiss/cdmStored split, mirrored here).
    ##   ocdStored         — a miss; the object was compiled locally AND
    ##                       successfully stored for future hits.
    ##   ocdDisabled       — the object cache is off (`--no-objcache`);
    ##                       neither lookup nor store was consulted.
    ##   ocdSoftCapSkipped — a store was attempted for a NEW key but the
    ##                       interim soft cap (`maxEntries`) was already
    ##                       reached; the object was compiled but the store
    ##                       write was skipped.
    ##   ocdCollisionReject — a digest hit (`<keyHash>.o`/`.meta` exist) whose
    ##                       stored `keyPreimage` does NOT match the
    ##                       requester's preimage — treated as a miss (the
    ##                       object is recompiled), logged forensically since
    ##                       this signals a hash collision, not routine churn.
    ##
    ## R1 defines this enum and threads it through the natural branches of
    ## `storeObject`/`lookupObject` (soft-cap-skip, collision-reject) for
    ## diagnostic use; the FULL decision threading (choosing between
    ## ocdMissCompiled/ocdStored/ocdDisabled at the call site) is R2's job,
    ## once the compile-worker actually drives lookup-or-compile-and-store.
    ocdHit
    ocdMissCompiled
    ocdStored
    ocdDisabled
    ocdSoftCapSkipped
    ocdCollisionReject

  ObjCacheLookupProc* = proc(keyHash, keyPreimage: string): Option[string] {.closure.}
    ## Look up a cached object. Returns the path to a VERIFIED cached `.o` on
    ## a confirmed hit (preimage matched AND checksum verified); `none`
    ## otherwise (any miss condition — see module docs).

  ObjCacheStoreProc* = proc(keyHash, keyPreimage, objPath: string): bool {.closure.}
    ## Store the object at `objPath` under `(keyHash, keyPreimage)`. Returns
    ## `false` when skipped (soft cap) or on I/O error; never raises.

  ObjCacheSeams* = object
    ## Injectable bundle mirroring `cachedispatch.CacheSeams`: production
    ## builds it via `realObjCacheSeams`; R2's tests mock it to drive the
    ## compile-worker's cache-mode logic against synthetic lookup/store
    ## behavior without touching the filesystem.
    lookup*: ObjCacheLookupProc
    store*:  ObjCacheStoreProc

# ---------------------------------------------------------------------------
# Path helpers (internal)
# ---------------------------------------------------------------------------

proc objCacheDirName*(): string {.inline.} =
  ## Returns the base directory name for the current object-cache version,
  ## i.e. `"v" & $objCacheFormatVersion` — the single authoritative source so
  ## `clean.nim` (R4) never hardcodes `"v1"`, mirroring
  ## `resultCacheDirName`.
  "v" & $objCacheFormatVersion

proc objCacheVersionDir(stateDir: string): string {.inline.} =
  stateDir / "objcache" / objCacheDirName()

proc objFilePath(stateDir, keyHash: string): string {.inline.} =
  objCacheVersionDir(stateDir) / (keyHash & ".o")

proc metaFilePath(stateDir, keyHash: string): string {.inline.} =
  objCacheVersionDir(stateDir) / (keyHash & ".meta")

# ---------------------------------------------------------------------------
# Soft-cap helper
# ---------------------------------------------------------------------------

proc fileSizeOrZero(path: string): int64 =
  ## Read `path`'s size in bytes. Returns 0 (never raises) on any failure —
  ## a missing/unreadable file simply contributes nothing to the byte total.
  try:
    result = getFileSize(path)
  except CatchableError:
    result = 0

proc objCacheDirStats(dir: string): tuple[count: int; bytes: int64] =
  ## Review Finding 3: a single `walkDir` pass computing BOTH the entry
  ## count (`.o` files, mirrors resultcache's `countCacheEntries` counting
  ## `*.json`) AND the aggregate on-disk byte usage (`.o` PLUS `.meta` sizes
  ## — the `.meta` is not negligible, it stores the full key preimage, which
  ## embeds the entire normalized `.c` content) — the same scan
  ## `storeObject`'s write-time soft cap already performs for the entry
  ## count, so computing the byte total alongside it is free, not a second
  ## directory walk. `.tmp` files are not counted (not a committed entry, on
  ## either axis). Missing dir -> (0, 0); never raises.
  if not dirExists(dir): return (0, 0'i64)
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if path.endsWith(".o"):
      inc result.count
      result.bytes += fileSizeOrZero(path)
    elif path.endsWith(".meta"):
      result.bytes += fileSizeOrZero(path)

# ---------------------------------------------------------------------------
# Public: store
# ---------------------------------------------------------------------------

proc storeObject*(stateDir: string; keyHash, keyPreimage, objPath: string;
                  maxEntries = DefaultMaxObjCacheEntries;
                  maxBytes: int64 = 0): bool =
  ## Store the object at `objPath` under `(keyHash, keyPreimage)`.
  ##
  ## Returns:
  ##   - `true`  — the two-artifact commit completed (`ocdStored`, in
  ##               `ObjCacheDecision` terms);
  ##   - `false` — skipped by the interim soft cap (`ocdSoftCapSkipped`), or
  ##               an I/O error occurred (reading `objPath`, or writing either
  ##               artifact). Never raises.
  ##
  ## The soft cap skips only when adding a *new* key would exceed EITHER
  ## bound: `maxEntries` (entry count) OR `maxBytes` (aggregate on-disk
  ## bytes across the version dir — review Finding 3; `0` = unbounded,
  ## matching `objcacheMaxBytes`'s "0 = unbounded" config semantics, the SAME
  ## convention `gcObjCache`'s own `maxBytes` parameter already uses).
  ## Re-storing an EXISTING key always proceeds (it replaces, not grows) —
  ## neither bound applies to a replacement.
  ##
  ## Write order is load-bearing: `.o` is written FIRST, then `.meta`. A
  ## failure writing `.meta` after `.o` succeeded leaves a `.o` with no
  ## `.meta` on disk — `lookupObject` treats that as a MISS, so this is safe,
  ## never a false hit; the caller may retry the store.
  let verDir     = objCacheVersionDir(stateDir)
  let finalObj   = objFilePath(stateDir, keyHash)
  let finalMeta  = metaFilePath(stateDir, keyHash)

  # Soft cap: only blocks growth (a NEW key past either bound), never a
  # replacement. `maxBytes <= 0` is treated as unbounded on that axis.
  if not fileExists(finalObj):
    let stats = objCacheDirStats(verDir)
    let overEntries = stats.count >= maxEntries
    let overBytes   = maxBytes > 0 and stats.bytes >= maxBytes
    if overEntries or overBytes:
      let decision = ocdSoftCapSkipped
      let boundDesc =
        if overEntries and overBytes: $maxEntries & " entries AND " & $maxBytes & " bytes"
        elif overEntries: $maxEntries & " entries"
        else: $maxBytes & " bytes"
      stderr.write("crisol: warning: object cache at soft cap (" & boundDesc &
                   "); skipping " & $decision &
                   " for key " & keyHash & " (run `crisol clean` to prune)\n")
      return false

  try:
    createDir(verDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create objcache dir '" & verDir &
                 "': " & e.msg & "\n")
    return false

  var objBytes: string
  try:
    objBytes = readFile(objPath)
  except CatchableError as e:
    stderr.write("crisol: warning: could not read source object '" & objPath &
                 "' for objcache store: " & e.msg & "\n")
    return false

  let checksum = toHex16(fnv1a64(objBytes))

  # 1) .o FIRST. RFC-0006 review R10: atomicPutFile reports the specific OS
  # failure reason (permission denied, disk full, EXDEV, a planted
  # symlink, …) instead of a bare bool — log it so an operator can diagnose
  # a production store failure without guessing.
  let (objOk, objErr) = atomicPutFile(finalObj, objBytes)
  if not objOk:
    stderr.write("crisol: warning: could not write objcache object '" &
                 finalObj & "': " & objErr & "\n")
    return false

  # 2) .meta SECOND. A crash/failure here leaves a .o with no .meta — defined
  # as a MISS by lookupObject, so this is safe (never a false hit).
  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(objCacheFormatVersion)

  let metaNode = newJObject()
  metaNode["header"]          = headerNode
  metaNode["payloadChecksum"] = newJString(checksum)
  metaNode["keyPreimage"]     = newJString(keyPreimage)

  let (metaOk, metaErr) = atomicPutFile(finalMeta, $metaNode)
  if not metaOk:
    stderr.write("crisol: warning: could not write objcache meta '" &
                 finalMeta & "': " & metaErr & " (object stored without its " &
                 "meta; next lookup will treat this key as a MISS)\n")
    return false

  true

# ---------------------------------------------------------------------------
# Public: lookup
# ---------------------------------------------------------------------------

proc lookupObject*(stateDir: string; keyHash, keyPreimage: string): Option[string] =
  ## Look up `(keyHash, keyPreimage)` in the object cache.
  ##
  ## Returns `none` (a MISS — never an exception) when:
  ##   - `<keyHash>.o` is absent/unreadable;
  ##   - `<keyHash>.meta` is absent/unreadable/malformed (including the
  ##     torn-commit case: a `.o` with no `.meta`);
  ##   - the `.meta` header `formatVersion` differs from
  ##     `objCacheFormatVersion`;
  ##   - the stored `keyPreimage` does not match the requester's
  ##     `keyPreimage` (`ocdCollisionReject` — logged to stderr, naming the
  ##     keyHash: a digest collision is a forensically interesting event, not
  ##     routine churn);
  ##   - the FNV-1a checksum recomputed over the on-disk `.o` bytes does not
  ##     match the stored `payloadChecksum` (torn write / bit rot).
  ##
  ## On a confirmed hit (`ocdHit`), returns `some(pathToTheOnDiskObj)`.
  let objP  = objFilePath(stateDir, keyHash)
  let metaP = metaFilePath(stateDir, keyHash)

  if not fileExists(objP): return none(string)
  if not fileExists(metaP): return none(string)  # torn commit -> MISS

  var metaRaw: string
  try:
    metaRaw = readFile(metaP)
  except CatchableError:
    return none(string)  # unreadable -> miss

  var node: JsonNode
  try:
    node = parseJson(metaRaw)
  except CatchableError:
    return none(string)  # malformed -> miss

  if node.kind != JObject: return none(string)

  let header = node{"header"}
  if header == nil or header.kind != JObject: return none(string)
  if header{"formatVersion"}.getInt(-1) != objCacheFormatVersion: return none(string)

  # Preimage confirmation (collision defense) — checked BEFORE the checksum
  # so a collision is diagnosed distinctly from a torn write.
  let storedPreimage = node{"keyPreimage"}
  if storedPreimage == nil or storedPreimage.kind != JString: return none(string)
  if storedPreimage.getStr("") != keyPreimage:
    let decision = ocdCollisionReject
    stderr.write("crisol: warning: objcache " & $decision & ": key " & keyHash &
                 " matched by digest but its stored preimage differs from the " &
                 "requester's — serving a MISS, not the cached object\n")
    return none(string)

  let storedChecksum = node{"payloadChecksum"}.getStr("")
  if storedChecksum.len == 0: return none(string)

  var objBytes: string
  try:
    objBytes = readFile(objP)
  except CatchableError:
    return none(string)  # unreadable -> miss

  let recomputed = toHex16(fnv1a64(objBytes))
  if recomputed != storedChecksum: return none(string)  # torn write -> MISS

  some(objP)

# ---------------------------------------------------------------------------
# Public: seams
# ---------------------------------------------------------------------------

proc realObjCacheSeams*(stateDir: string;
                        maxEntries = DefaultMaxObjCacheEntries;
                        maxBytes: int64 = 0): ObjCacheSeams =
  ## Bundle the real (filesystem-backed) lookup/store implementations, closing
  ## over `stateDir` (and `maxEntries`/`maxBytes` for store — review Finding
  ## 3: BOTH default to the same unconfigured backstop `storeObject` itself
  ## defaults to, so a caller that does not thread the user's configured caps
  ## still gets the existing hardcoded-10000-entries/unbounded-bytes
  ## behavior, never a silent behavior change for an untouched call site), so
  ## R2's compile-worker cache-mode logic and its tests can depend on
  ## `ObjCacheSeams` alone — production wiring calls this; tests inject a
  ## synthetic `ObjCacheSeams`.
  ObjCacheSeams(
    lookup: proc(keyHash, keyPreimage: string): Option[string] {.closure.} =
      lookupObject(stateDir, keyHash, keyPreimage),
    store: proc(keyHash, keyPreimage, objPath: string): bool {.closure.} =
      storeObject(stateDir, keyHash, keyPreimage, objPath, maxEntries, maxBytes),
  )

# ---------------------------------------------------------------------------
# R4: Object-cache GC (size-bounded LRU + age eviction)
# ---------------------------------------------------------------------------
##
## Design notes (R4) — mirrors `resultcache.gcResultCache` (A1c), adapted for
## objcache's two-artifact commit:
##
## - The soft-cap in `storeObject` is KEPT as a write-time backstop. Real LRU
##   eviction at clean-time is additive — they are complementary, exactly as
##   in resultcache.
##
## - `nowSecs` is INJECTED (not called internally) so the age logic is fully
##   deterministic in unit tests. The clean entry point passes `epochTime()`.
##
## - No stored timestamp exists in `.meta` (R4 does not touch the R1 schema),
##   so the `.o` file's last-MODIFICATION time is used as the store-time
##   proxy for LRU ordering — `storeObject` writes `.o` via `atomicPutFile`
##   at store time, so its mtime faithfully stands in for `cachedAt`.
##
## - Eviction order: orphan half-pairs first (unconditional — see below),
##   then age bound, then the combined entry-count/byte bound, exactly
##   mirroring gcResultCache's age-then-size ordering for the LRU pass.
##
## - RFC-0006 review R6 — aggregate-byte bound. An entry-count cap alone
##   cannot bound on-disk growth: each pair's `.meta` stores the FULL key
##   preimage, which embeds the entire normalized `.c` content (tens to
##   hundreds of KB), so per-entry footprint varies widely and a fixed entry
##   count is not a real circuit breaker on a large suite. `gcObjCache` now
##   also accepts `maxBytes` (0 = unbounded) and evicts, oldest-first in the
##   SAME age-then-mtime-LRU order already used for the entry-count bound,
##   until BOTH the entry-count bound AND the byte bound are satisfied —
##   whichever bound is tighter drives more eviction. A pair's size is the
##   sum of its `.o` AND `.meta` file sizes (both artifacts of the commit,
##   evicted atomically together, exactly as the entry-count pass already
##   does).
##
## - Orphan hygiene: a `.o` with no matching `.meta`, or a `.meta` with no
##   matching `.o`, is a torn commit (R1 doc: "a crash between the two
##   renames leaves a `.o` with no `.meta`"). Such a half-pair can NEVER
##   become a valid entry on its own, so it is swept unconditionally — before
##   the age/size LRU pass, regardless of its age or the current entry count.
##   This is the two-artifact analogue of gcResultCache's stale-`.tmp` sweep.

type
  GcObjCacheReport* = tuple[evicted: int; tmpSwept: int]
    ## Summary of a gcObjCache run. `evicted` counts ENTRIES removed — a
    ## matched `.o`+`.meta` pair evicted by the age/size LRU pass, or a lone
    ## half-pair removed by orphan hygiene. `tmpSwept` counts stale `.tmp`
    ## files removed.

proc objMtimeSecs(path: string): int64 =
  ## Read `path`'s last-modification time as a unix epoch second count — the
  ## LRU store-time proxy (see module notes above). Returns 0 (oldest, so a
  ## stat failure sorts first for eviction) on any failure; never raises.
  try:
    result = getLastModificationTime(path).toUnix()
  except CatchableError:
    result = 0

proc pairSizeBytes(verDir, key: string): int64 =
  ## RFC-0006 review R6: a pair's aggregate on-disk footprint = its `.o` size
  ## PLUS its `.meta` size — the `.meta` is not negligible (it stores the
  ## full key preimage, which embeds the entire normalized `.c` content).
  fileSizeOrZero(verDir / (key & ".o")) + fileSizeOrZero(verDir / (key & ".meta"))

proc gcObjCache*(stateDir: string; maxEntries: int; maxAgeSecs: int64;
                 nowSecs: int64; maxBytes: int64 = 0): GcObjCacheReport =
  ## Evict object-cache entries that violate the age, entry-count, or
  ## aggregate-byte bound, and sweep stale `.tmp` writers and torn
  ## half-pairs.
  ##
  ## Parameters:
  ##   stateDir    — the `.crisol` state directory.
  ##   maxEntries  — keep at most this many entries (LRU by `.o` mtime);
  ##                 0 = no entry-count bound.
  ##   maxAgeSecs  — evict entries whose `.o` mtime is older than
  ##                 `nowSecs - maxAgeSecs`; 0 = no age bound.
  ##   nowSecs     — current unix epoch seconds (injected for testability).
  ##   maxBytes    — keep at most this many aggregate bytes across all
  ##                 surviving pairs, counting BOTH each pair's `.o` AND
  ##                 `.meta` size (RFC-0006 review R6); 0 = no byte bound.
  ##
  ## The entry-count bound and the byte bound are applied TOGETHER in the
  ## same oldest-first LRU pass (by `.o` mtime): eviction continues until
  ## BOTH are satisfied, so whichever bound is tighter drives the actual
  ## eviction count. Either bound alone (the other left at 0) behaves exactly
  ## as before this parameter was added.
  ##
  ## Operates ONLY on the CURRENT version dir (`objcache/v<fmt>/`) — sibling
  ## `v<N>` dirs from a prior format version are NEVER touched (multi-version
  ## preservation contract, mirrors `gcResultCache`/`isResultCacheRootName`
  ## preservation in `clean.pruneDir`). A missing version dir yields an empty
  ## report.
  ##
  ## Safety:
  ##   - Never raises; every remove is best-effort.
  ##   - Only touches `.o`, `.meta`, and `.tmp` files in the version dir.
  ##   - Callers (cleanOrphans) must hold the stateDir lock before calling.
  let verDir = objCacheVersionDir(stateDir)
  if not dirExists(verDir):
    return (evicted: 0, tmpSwept: 0)

  # Step 1: sweep stale `.tmp` files left by crashed storeObject calls. Safe
  # under the caller's exclusive stateDir lock — no live writer can be
  # mid-write here, so any `.tmp` present is genuinely orphaned.
  var tmpSwept = 0
  for kind, path in walkDir(verDir):
    if kind == pcFile and path.endsWith(".tmp"):
      try: removeFile(path) except CatchableError: discard
      inc tmpSwept

  # Gather the key sets of committed `.o` and `.meta` artifacts.
  var objKeys, metaKeys: HashSet[string]
  for kind, path in walkDir(verDir):
    if kind != pcFile: continue
    var name = path.extractFilename()
    if name.endsWith(".o"):
      name.removeSuffix(".o")
      objKeys.incl name
    elif name.endsWith(".meta"):
      name.removeSuffix(".meta")
      metaKeys.incl name

  var evicted = 0

  # Step 2: orphan hygiene — a half-pair is swept unconditionally, regardless
  # of age or the size bound (it can never become valid on its own).
  for key in objKeys:
    if key notin metaKeys:
      try: removeFile(verDir / (key & ".o")) except CatchableError: discard
      inc evicted
  for key in metaKeys:
    if key notin objKeys:
      try: removeFile(verDir / (key & ".meta")) except CatchableError: discard
      inc evicted

  # Step 3: LRU pass over the remaining MATCHED pairs only.
  type Entry = tuple[key: string; mtime: int64; bytes: int64]
  var entries: seq[Entry]
  for key in objKeys:
    if key in metaKeys:
      entries.add (key: key, mtime: objMtimeSecs(verDir / (key & ".o")),
                   bytes: pairSizeBytes(verDir, key))

  if entries.len == 0:
    return (evicted: evicted, tmpSwept: tmpSwept)

  entries.sort(proc(a, b: Entry): int = cmp(a.mtime, b.mtime))

  proc removePair(key: string) =
    try: removeFile(verDir / (key & ".o")) except CatchableError: discard
    try: removeFile(verDir / (key & ".meta")) except CatchableError: discard

  # Age bound: evict everything older than (nowSecs - maxAgeSecs).
  if maxAgeSecs > 0:
    let cutoff = nowSecs - maxAgeSecs
    var kept: seq[Entry]
    for e in entries:
      if e.mtime < cutoff:
        removePair(e.key)
        inc evicted
      else:
        kept.add e
    entries = kept

  # Combined entry-count + aggregate-byte bound (RFC-0006 review R6): evict
  # oldest-first (entries is still mtime-ascending) until BOTH bounds are
  # satisfied. Either bound left at 0 (disabled) simply never contributes to
  # the loop condition, so a single-bound caller behaves exactly as before.
  if maxEntries > 0 or maxBytes > 0:
    var totalBytes: int64 = 0
    for e in entries: totalBytes += e.bytes
    var idx = 0
    while idx < entries.len and (
        (maxEntries > 0 and entries.len - idx > maxEntries) or
        (maxBytes > 0 and totalBytes > maxBytes)):
      removePair(entries[idx].key)
      inc evicted
      totalBytes -= entries[idx].bytes
      inc idx

  result = (evicted: evicted, tmpSwept: tmpSwept)
