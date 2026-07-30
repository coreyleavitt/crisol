## test_objcache.nim — RFC-0006 Stage R, R1: the content-keyed object cache CORE.
##
## Tests written FIRST (TDD), then implementation written to make them pass.
## keyHash + keyPreimage are GIVEN inputs here (R1 does not compute the real
## cache key — that lives in artifactid.nim and gets wired in R2).
##
## Coverage:
##   1. store -> lookup happy path: bytes round-trip through the confirmed hit.
##   2. preimage collision defense: same keyHash, different keyPreimage -> MISS.
##   3a. missing .meta (simulated crash between the two renames) -> MISS.
##   3b. corrupted .o bytes after store (torn write) -> MISS.
##   4. soft cap: an (N+1)th NEW key is skipped; re-storing an existing key
##      still succeeds.
##   5a. RFC-0006 review R14-T3: a .meta present but with a MISMATCHED
##       formatVersion -> MISS (via lookupObject, not a unit test of the
##       branch in isolation).
##   5b. RFC-0006 review R14-T3: a .meta corrupted to unparseable JSON (not
##       merely absent) -> MISS.

import std/[os, options, json]
import crisol/objcache

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_objcache_" & name)
  removeDir(result)
  createDir(result)

proc writeSourceObj(dir: string; name: string; content: string): string =
  ## Simulates a compiled `.o` sitting somewhere OUTSIDE the objcache (e.g. a
  ## per-slot nimcache dir) that storeObject copies bytes FROM.
  createDir(dir)
  result = dir / name
  writeFile(result, content)

# The objcache dir layout: <stateDir>/objcache/v<fmt>/<keyHash>.{o,meta}
proc objFile(stateDir, keyHash: string): string =
  stateDir / "objcache" / ("v" & $objCacheFormatVersion) / (keyHash & ".o")

proc metaFile(stateDir, keyHash: string): string =
  stateDir / "objcache" / ("v" & $objCacheFormatVersion) / (keyHash & ".meta")

# ---------------------------------------------------------------------------
# 1. store -> lookup happy path
# ---------------------------------------------------------------------------

block test_store_lookup_happy_path:
  let sd = freshStateDir("happy")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "\x7fELF fake object bytes for mod.nim")

  let keyHash     = "aabbccdd11223344"
  let keyPreimage = "cc -c mod.nim.c -o mod.nim.c.o|<content of mod.nim.c>|<include closure>|nim-2.0|gcc-13"

  let stored = storeObject(sd, keyHash, keyPreimage, srcObj)
  assert stored, "storeObject should succeed on a fresh key"
  assert fileExists(objFile(sd, keyHash)), "the .o artifact must exist after store"
  assert fileExists(metaFile(sd, keyHash)), "the .meta artifact must exist after store"

  let hit = lookupObject(sd, keyHash, keyPreimage)
  assert hit.isSome, "lookup with the SAME (keyHash, keyPreimage) must be a confirmed hit"
  assert readFile(hit.get) == readFile(srcObj),
    "the returned .o path's bytes must equal the original source .o bytes"

# ---------------------------------------------------------------------------
# 2. preimage collision defense
# ---------------------------------------------------------------------------

block test_preimage_collision_reject:
  let sd = freshStateDir("collision")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "object bytes for preimage A")

  let keyHash = "deadbeefcafef00d"
  let preimageA = "preimage A — the real inputs for this compile unit"
  let preimageB = "preimage B — DIFFERENT inputs that happen to digest-collide"

  assert storeObject(sd, keyHash, preimageA, srcObj)

  let hit = lookupObject(sd, keyHash, preimageB)
  assert hit.isNone,
    "a digest hit with a MISMATCHED preimage must be rejected as a MISS (collision defense)"

# ---------------------------------------------------------------------------
# 3a. missing .meta (simulated crash between .o rename and .meta rename)
# ---------------------------------------------------------------------------

block test_missing_meta_is_miss:
  let sd = freshStateDir("nometa")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "object bytes, meta about to vanish")

  let keyHash     = "0011223344556677"
  let keyPreimage = "preimage for the no-meta case"

  assert storeObject(sd, keyHash, keyPreimage, srcObj)
  assert fileExists(metaFile(sd, keyHash))

  # Simulate a crash between the .o rename and the .meta rename: the .o
  # artifact survives on disk, but its .meta sibling never got written.
  removeFile(metaFile(sd, keyHash))
  assert fileExists(objFile(sd, keyHash)), ".o must still be present (simulates a torn commit)"

  let hit = lookupObject(sd, keyHash, keyPreimage)
  assert hit.isNone, "a .o with no .meta must be a MISS, never a false hit"

# ---------------------------------------------------------------------------
# 3b. corrupted .o bytes after store (torn write / bit rot)
# ---------------------------------------------------------------------------

block test_corrupted_obj_is_miss:
  let sd = freshStateDir("corrupt")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "pristine object bytes, not yet corrupted")

  let keyHash     = "9988776655443322"
  let keyPreimage = "preimage for the corruption case"

  assert storeObject(sd, keyHash, keyPreimage, srcObj)

  # Corrupt the on-disk .o bytes directly (torn write / bit rot simulation) —
  # the .meta's payloadChecksum now no longer matches.
  writeFile(objFile(sd, keyHash), "CORRUPTED bytes that do not match the stored checksum")

  let hit = lookupObject(sd, keyHash, keyPreimage)
  assert hit.isNone, "a checksum mismatch on the .o bytes must be a MISS"

# ---------------------------------------------------------------------------
# 4. soft cap: (N+1)th NEW key skipped; re-storing an existing key succeeds
# ---------------------------------------------------------------------------

block test_soft_cap_skip:
  let sd = freshStateDir("softcap")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObjA = writeSourceObj(srcDir, "a.o", "object bytes A")
  let srcObjB = writeSourceObj(srcDir, "b.o", "object bytes B")
  let srcObjC = writeSourceObj(srcDir, "c.o", "object bytes C")

  let kA = "aaaa1111aaaa1111"
  let kB = "bbbb2222bbbb2222"
  let kC = "cccc3333cccc3333"

  assert storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 2)
  assert storeObject(sd, kB, "preimage B", srcObjB, maxEntries = 2)

  # Third NEW key with cap = 2: dir already has 2 entries -> skip, return false.
  let ok = storeObject(sd, kC, "preimage C", srcObjC, maxEntries = 2)
  assert not ok, "store must be SKIPPED (false) when the dir is already at cap"
  assert not fileExists(objFile(sd, kC)), "a skipped store must not create a .o file"
  assert not fileExists(metaFile(sd, kC)), "a skipped store must not create a .meta file"

  # Existing entries intact.
  assert lookupObject(sd, kA, "preimage A").isSome
  assert lookupObject(sd, kB, "preimage B").isSome

  # Re-storing an EXISTING key at cap must still succeed (it replaces, not grows).
  let okReplace = storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 2)
  assert okReplace, "re-storing an existing key at cap must not be soft-capped"

# ---------------------------------------------------------------------------
# 5a. RFC-0006 review R14-T3: .meta present with a MISMATCHED formatVersion
#     -> MISS (never crashes, never serves the .o).
# ---------------------------------------------------------------------------

block test_meta_format_version_mismatch_is_miss:
  let sd = freshStateDir("formatmismatch")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "object bytes, about to get a stale-version meta")

  let keyHash     = "ffee00112233ffee"
  let keyPreimage = "preimage for the format-version-mismatch case"

  assert storeObject(sd, keyHash, keyPreimage, srcObj)
  assert fileExists(objFile(sd, keyHash))
  assert fileExists(metaFile(sd, keyHash))

  # Rewrite .meta with a formatVersion that does NOT match
  # objCacheFormatVersion, otherwise a well-formed, checksum-correct entry
  # (simulates a stale entry left over from an older on-disk schema).
  let staleNode = newJObject()
  let staleHeader = newJObject()
  staleHeader["formatVersion"] = newJInt(objCacheFormatVersion + 1)
  staleNode["header"]          = staleHeader
  staleNode["payloadChecksum"] = newJString("deadbeefdeadbeef")
  staleNode["keyPreimage"]     = newJString(keyPreimage)
  writeFile(metaFile(sd, keyHash), $staleNode)

  let hit = lookupObject(sd, keyHash, keyPreimage)
  assert hit.isNone,
    "a .meta with a MISMATCHED formatVersion must be a MISS, never served"
  assert fileExists(objFile(sd, keyHash)), ".o must still be on disk (only the .meta was rewritten)"

# ---------------------------------------------------------------------------
# 5b. RFC-0006 review R14-T3: .meta corrupted to unparseable JSON (not
#     merely absent) -> MISS, no crash.
# ---------------------------------------------------------------------------

block test_meta_malformed_json_is_miss:
  let sd = freshStateDir("malformedmeta")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObj = writeSourceObj(srcDir, "mod.nim.c.o", "object bytes, about to get garbage meta")

  let keyHash     = "0badc0de0badc0de"
  let keyPreimage = "preimage for the malformed-meta case"

  assert storeObject(sd, keyHash, keyPreimage, srcObj)
  assert fileExists(metaFile(sd, keyHash))

  # Corrupt .meta to unparseable JSON (garbage bytes, not merely absent).
  writeFile(metaFile(sd, keyHash), "{ this is not valid JSON at all !!")

  let hit = lookupObject(sd, keyHash, keyPreimage)
  assert hit.isNone,
    "an unparseable (garbage-JSON) .meta must be a MISS, not a crash"
  assert fileExists(objFile(sd, keyHash)), ".o must still be on disk (only the .meta was corrupted)"

# ---------------------------------------------------------------------------
# 6. review Finding 3: storeObject honors a CONFIGURED aggregate-BYTE cap at
#    write time (not just the entry-count cap), and the caller's configured
#    value (not the hardcoded default) is what gets enforced.
# ---------------------------------------------------------------------------

block test_byte_cap_skip:
  let sd = freshStateDir("bytecap")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObjA = writeSourceObj(srcDir, "a.o", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
  let srcObjB = writeSourceObj(srcDir, "b.o", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")

  let kA = "1111aaaa1111aaaa"
  let kB = "2222bbbb2222bbbb"

  # Store A unbounded first, then measure its REAL on-disk footprint (.o +
  # .meta) rather than guessing at JSON-serialization overhead — set the
  # byte cap to EXACTLY that, so a second NEW key must be skipped (the dir
  # is already >= the cap before B's write is even attempted).
  assert storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 1000)
  let aFootprint = getFileSize(objFile(sd, kA)) + getFileSize(metaFile(sd, kA))
  assert aFootprint > 0

  let okB = storeObject(sd, kB, "preimage B", srcObjB, maxEntries = 1000,
                        maxBytes = aFootprint)
  assert not okB,
    "second NEW key must be SKIPPED once the aggregate byte cap is (already) reached"
  assert not fileExists(objFile(sd, kB)), "a byte-cap-skipped store must not create a .o file"
  assert not fileExists(metaFile(sd, kB)), "a byte-cap-skipped store must not create a .meta file"

  # The first entry is untouched.
  assert lookupObject(sd, kA, "preimage A").isSome

  # Under the cap: a SMALLER cap-respecting scenario stores normally when
  # the dir is empty and the new object fits comfortably under a generous cap.
  let sd2 = freshStateDir("bytecap_under")
  defer: removeDir(sd2)
  let srcDir2 = sd2 / "src_objs"
  let srcObjC = writeSourceObj(srcDir2, "c.o", "small object")
  let kC = "8888cccc8888cccc"
  let okC = storeObject(sd2, kC, "preimage C", srcObjC, maxEntries = 1000,
                        maxBytes = 1_000_000)
  assert okC, "a store well under a generous byte cap must succeed normally"
  assert lookupObject(sd2, kC, "preimage C").isSome

block test_byte_cap_zero_is_unbounded:
  let sd = freshStateDir("bytecap_zero")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObjA = writeSourceObj(srcDir, "a.o", "some object bytes, moderately sized here")
  let srcObjB = writeSourceObj(srcDir, "b.o", "some other object bytes, also moderately sized")

  let kA = "3333cccc3333cccc"
  let kB = "4444dddd4444dddd"

  # maxBytes defaults to 0 (unbounded) — both stores must succeed regardless
  # of aggregate size, exactly as before this parameter existed.
  assert storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 1000)
  assert storeObject(sd, kB, "preimage B", srcObjB, maxEntries = 1000)
  assert lookupObject(sd, kA, "preimage A").isSome
  assert lookupObject(sd, kB, "preimage B").isSome

block test_byte_cap_replace_existing_key_not_capped:
  let sd = freshStateDir("bytecap_replace")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObjA = writeSourceObj(srcDir, "a.o", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

  let kA = "5555eeee5555eeee"
  assert storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 1000, maxBytes = 45)

  # Re-storing the SAME key at (now, post-store) an already-at/near-cap size
  # must still succeed — the byte cap, like the entry cap, only blocks
  # growth via a NEW key, never a replacement.
  let okReplace = storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 1000, maxBytes = 45)
  assert okReplace, "re-storing an existing key at/over the byte cap must not be soft-capped"

block test_entry_cap_still_enforced_when_byte_cap_is_generous:
  ## The OR semantics the other direction: a tight entry cap must still
  ## trigger even when the byte cap is generous/unset — proves the two
  ## bounds are independent, not just the byte cap alone doing the work.
  let sd = freshStateDir("entrycap_with_generous_bytecap")
  defer: removeDir(sd)
  let srcDir = sd / "src_objs"
  let srcObjA = writeSourceObj(srcDir, "a.o", "bytes A")
  let srcObjB = writeSourceObj(srcDir, "b.o", "bytes B")

  let kA = "6666ffff6666ffff"
  let kB = "7777aaaa7777aaaa"

  assert storeObject(sd, kA, "preimage A", srcObjA, maxEntries = 1, maxBytes = 1_000_000)
  let okB = storeObject(sd, kB, "preimage B", srcObjB, maxEntries = 1, maxBytes = 1_000_000)
  assert not okB, "entry cap alone must still gate a new store even with a generous byte cap"

echo "test_objcache: all blocks passed"
