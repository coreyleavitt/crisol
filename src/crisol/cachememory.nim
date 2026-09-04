## cachememory.nim — RFC-0005 A1: the two in-memory `CacheBackend` test
## doubles, both zero-I/O, zero-network (RFC-0005 "No network or hot-path
## disk in the test suite").
##
## - **`memory()`** — `Table[SoundnessKey, StoredEntry]`: stores the object
##   handed to `put`, after stamping `result.payloadChecksum` itself (the
##   same writer-fills-it-in contract `resultcache.storeCached` already
##   documents — a caller builds a `CachedResult` with the checksum empty).
##   Simplest possible double, but NOT a bypass of the port's integrity
##   contract: `get` runs `verifyEntryIntegrity`
##   (`cachewire.nim`) exactly as a byte-oriented backend's `decode` would,
##   so `cvCorrupt`/`cvVersionSkew` are reachable here too (by mutating a
##   `StoredEntry` field directly before `put`) — the contract is a property
##   of `CacheBackend.get`, not an artifact of serialization.
## - **`memoryBytes(serializer)`** — `Table[SoundnessKey, string]`, routing
##   every `get`/`put` THROUGH the given `CacheSerializer` — so the wire
##   shape itself (not just the logical contract) is exercised in Stage A,
##   before `StoredEntry` freezes, not first when `cachehttp`/`caches3` land.
##
## Registered by `cacheregistry.testRegistry()` (Stage A3a) under the
## `memory://`/`memorybytes://` schemes — `productionRegistry()` never
## registers either (a typo'd `memory://` URL in production KDL must be a
## config error, not a silently-empty per-process tier).

import std/tables
import crisol/cacheport
import crisol/cachewire
import crisol/fnv

proc memory*(): CacheBackend =
  var tbl = initTable[SoundnessKey, StoredEntry]()
  CacheBackend(
    scheme: "memory",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      if key notin tbl:
        return Fetched[StoredEntry](verdict: cvMiss)
      let e = tbl[key]
      let v = verifyEntryIntegrity(e)
      if v != cvOk:
        return Fetched[StoredEntry](verdict: v)
      Fetched[StoredEntry](verdict: cvOk, value: e)
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      # Mirrors `storeCached`/`jsonEncode`: the WRITE path computes and
      # stamps the checksum — a caller (e.g. the future `cachedispatch`
      # store closure) builds a `CachedResult` with `payloadChecksum`
      # empty, exactly as `resultcache.storeCached`'s contract already
      # documents; `memory` must fill it in itself since, unlike
      # `memoryBytes`, it never routes through `jsonEncode`.
      var e = entry
      e.result.payloadChecksum = toHex16(fnv1a64(canonicalPayload(e.result)))
      tbl[e.key] = e
      cvOk
    ,
    probe: nil,
  )

proc memoryBytes*(serializer: CacheSerializer): CacheBackend =
  var tbl = initTable[SoundnessKey, string]()
  CacheBackend(
    scheme: "memorybytes",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      if key notin tbl:
        return Fetched[StoredEntry](verdict: cvMiss)
      let fetched = serializer.decode(tbl[key])
      if fetched.verdict != cvOk:
        return Fetched[StoredEntry](verdict: fetched.verdict)
      var e = fetched.value
      e.key = key
      Fetched[StoredEntry](verdict: cvOk, value: e)
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      tbl[entry.key] = serializer.encode(entry)
      cvOk
    ,
    probe: nil,
  )
