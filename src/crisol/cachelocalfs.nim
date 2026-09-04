## cachelocalfs.nim — RFC-0005 A2a: the `local-fs` `CacheBackend` adapter.
##
## Stores `StoredEntry` envelopes through the ONE on-disk/on-wire encoding
## (`cachewire.jsonCacheSerializer` — RFC-0005 "One format, everywhere"),
## one JSON file per key, at:
##
## ```
##   <root>/v<cachewire.storageFormatVersion>/<soundnessKey>.json
## ```
##
## `<root>` is whatever the caller hands in — the future `localOnlyCache`
## (Stage A2b) passes `stateDir / "cache"` for the pinned `"l1"` tier; a
## configured `file://<dir>` remote tier (Stage A3c) passes `<dir>` directly.
## This module has NO opinion on which; it is not the port-registry/config
## layer (Non-Goals, RFC-0005 A2a bullet).
##
## ## Offline semantics
##
## A missing or non-directory root on a non-`autoCreate` backend is `cvOffline`
## on BOTH `get` and `put` — the RFC's fixture for "non-directory" is a
## regular *file* sitting at the root path (`ENOTDIR`); `chmod`-based
## unreadable-dir fixtures are unusable here because `./dev` runs as root
## in-container (root bypasses permission bits). A root blocked by a file is
## `cvOffline` REGARDLESS of `autoCreate` — creating a directory where a file
## already sits is not something `autoCreate` can fix. A root that is simply
## ABSENT (nothing there yet) is `cvMiss` on `get` when `autoCreate` is true
## (there is nothing wrong, just nothing stored yet) and `cvOffline` when
## `autoCreate` is false (this backend is never allowed to conjure the root
## into existence, so an absent root is unreachable, not merely empty).
##
## ## Soft cap
##
## `maxEntries` mirrors `resultcache.storeCached`'s interim soft cap exactly
## (an O(n) `walkDir` count per `put`, `maxEntries = 0` ⇒ no cap — see there
## for why this is fine for a private per-process/per-host L1 and wrong for a
## shared tier). A `put` that would grow the entry count past `maxEntries`
## is SKIPPED, not an error in the exceptional sense, but still reported as
## a non-`cvOk` verdict (`cvUnauthorized` — the generic "write did not land"
## bucket a NAT'd/full/read-only backend also reports; see below).
##
## ## Verdict choice for write failures
##
## `CacheBackend.put` has no dedicated "capacity"/"write failed" verdict in
## `CacheVerdict` (RFC-0005's port). `cvUnauthorized` is the RFC's own
## precedent for this bucket (§"Local-fs root": "NFS... O_EXCL fails closed
## ⇒ put returns cvUnauthorized-class false, acceptable") — reused here for
## EVERY local write failure that is not itself a reachability problem
## (soft-cap skip, cache-dir create failure, atomic-write failure). A
## reachability problem (root missing/blocked) is `cvOffline` instead, since
## the caller could not even attempt the write.
##
## ## Rate-limited failure warnings
##
## Write failures route through `resultcache.warnStoreFailureOnce` — the
## SAME once-per-root-per-run stderr suppressor `storeCachedAt` uses (see
## there) — so a full disk hit across many `put`s to the same root emits one
## line, not N.

import std/[os, strutils]
import crisol/cacheport
import crisol/cachewire
import crisol/resultcache
import crisol/ioutils

proc versionDir(root: string): string {.inline.} =
  root / ("v" & $storageFormatVersion)

proc entryPath(root: string; key: SoundnessKey): string {.inline.} =
  versionDir(root) / ($key & ".json")

proc countEntries(dir: string): int =
  ## Mirrors `resultcache`'s `countCacheEntries` exactly — count `*.json`
  ## files only, `.tmp` files excluded, missing dir ⇒ 0.
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      inc result

type RootState = enum
  rsUsable      ## root exists as a directory — proceed.
  rsEmptyOk     ## root does not exist, but autoCreate means "nothing here
                ## yet" is not an error — a GET-only state (never returned
                ## for a write path, which must actually create the dir).
  rsOffline     ## root is unreachable: missing without autoCreate, or
                ## blocked by a non-directory entry regardless of autoCreate.

proc classifyRootForRead(root: string; autoCreate: bool): RootState =
  if dirExists(root): return rsUsable
  if fileExists(root): return rsOffline  # ENOTDIR — a file blocks the dir
  if autoCreate: return rsEmptyOk
  return rsOffline

proc localFsBackend*(root: string; autoCreate: bool; maxEntries: int): CacheBackend =
  let ser = jsonCacheSerializer()
  CacheBackend(
    scheme: "file",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      case classifyRootForRead(root, autoCreate)
      of rsOffline: return Fetched[StoredEntry](verdict: cvOffline)
      of rsEmptyOk: return Fetched[StoredEntry](verdict: cvMiss)
      of rsUsable: discard

      let path = entryPath(root, key)
      if not fileExists(path):
        return Fetched[StoredEntry](verdict: cvMiss)

      var raw: string
      try:
        raw = readFile(path)
      except CatchableError:
        return Fetched[StoredEntry](verdict: cvCorrupt)

      let decoded = ser.decode(raw)
      if decoded.verdict != cvOk:
        return Fetched[StoredEntry](verdict: decoded.verdict)
      var e = decoded.value
      e.key = key  # contextual — the serializer never carries it (cachewire doc)
      Fetched[StoredEntry](verdict: cvOk, value: e)
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      if not dirExists(root):
        if fileExists(root):
          return cvOffline  # ENOTDIR — a file blocks the dir, autoCreate can't fix it
        if not autoCreate:
          return cvOffline
        try:
          createDir(root)
        except OSError as e:
          warnStoreFailureOnce(root, "crisol: warning: could not create cache root '" &
                       root & "': " & e.msg & "\n")
          return cvUnauthorized

      let verDir = versionDir(root)
      let finalPath = entryPath(root, entry.key)

      if not fileExists(finalPath):
        if maxEntries > 0 and countEntries(verDir) >= maxEntries:
          warnStoreFailureOnce(root, "crisol: warning: local-fs cache at soft cap (" &
                       $maxEntries & " entries) at '" & root &
                       "'; skipping write for key " & $entry.key &
                       " (run `crisol clean` to prune)\n")
          return cvUnauthorized

      try:
        createDir(verDir)
      except OSError as e:
        warnStoreFailureOnce(root, "crisol: warning: could not create cache dir '" &
                     verDir & "': " & e.msg & "\n")
        return cvUnauthorized

      let bytes = ser.encode(entry)
      let (ok, err) = atomicPublish(finalPath, bytes)
      if not ok:
        warnStoreFailureOnce(root, "crisol: warning: could not write cache entry '" &
                     finalPath & "': " & err & "\n")
        return cvUnauthorized
      cvOk
    ,
    probe: nil,
  )
