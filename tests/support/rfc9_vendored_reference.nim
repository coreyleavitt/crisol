## rfc9_vendored_reference.nim — RFC-0009 A0 golden-pin: a FROZEN, vendored
## copy of `main`'s CURRENT `chainedContentHash`/`slug`/`identityKey`/
## `flagHash` algorithms, std-only (no `crisol/*` imports), for the depRoot
## golden vectors that cannot be literal byte-pinned.
##
## WHY THIS FILE EXISTS (RFC-0009 A0 bullet, round-3 R3-29):
##
## `fnv.nim:68`'s `chainedContentHash` chains a depRoot closure member's
## ABSOLUTE native path directly into the hash. That path embeds the
## checkout location (a container's `/workspace` differs from a CI runner's
## checkout dir), so it can never be a literal, host-invariant byte-pin the
## way a path-RELATIVE (single-root project) vector can. Instead, this
## module is a snapshot of TODAY's algorithm, decoupled from `src/crisol/*`,
## so `test_rfc9_golden_pin.nim` can assert "production's live output equals
## this frozen reference's output on the SAME raw inputs" — a preservation
## oracle that is checkable on ANY host, rather than a literal string that
## is not.
##
## PRESERVATION-ORACLE SCOPE (round-3 R3-29): this vendored copy backs the
## depRoot vectors for A1 through A4b ONLY. At A5a, once a depRoot member's
## `keyBytes` genuinely becomes the host-invariant `dep:name/rel` form, the
## depRoot vectors FLIP to literal byte-pins and THIS FILE IS DELETED in
## that same slice — do not carry it further than that.
##
## DO NOT "fix" or "improve" this file to track a `src/crisol/*` change.
## It exists specifically to NOT track such a change — a divergence between
## this file's output and production's is exactly the regression this
## harness exists to catch. Any legitimate algorithm change belongs in
## `src/crisol/*`; this file changes only when A0's own preservation-oracle
## scope moves (i.e. at A5a, per above).
##
## Frozen from (as of RFC-0009 A0, 2026-09):
##   - src/crisol/fnv.nim       — fnv1a64, toHex16, chainedContentHash
##   - src/crisol/planner.nim   — slugify, slug
##   - src/crisol/keys.nim      — identityKey (returns plain `string`, not
##                                 the distinct `IdentityKey` type — callers
##                                 here never need that type, and dragging it
##                                 in would require importing `crisol/types`,
##                                 defeating the point of vendoring)
##   - src/crisol/depgraph.nim  — flagHash

import std/[algorithm, os, strutils]

# ---------------------------------------------------------------------------
# fnv.nim — FNV-1a 64-bit primitives
# ---------------------------------------------------------------------------

const fnvOffset64 = 0xcbf29ce484222325'u64
const fnvPrime64  = 0x00000100000001b3'u64

proc fnv1a64(data: string): uint64 =
  result = fnvOffset64
  for c in data:
    result = result xor uint64(ord(c))
    result = result * fnvPrime64

proc toHex16(v: uint64): string =
  const hexChars = "0123456789abcdef"
  result = newString(16)
  var x = v
  for i in countdown(15, 0):
    result[i] = hexChars[x and 0xf]
    x = x shr 4

proc chainedContentHash*(files: seq[string]; projectRoot: string): string =
  ## Frozen copy of `crisol/fnv.chainedContentHash`.
  var sorted = files
  sorted.sort()
  var running: uint64 = fnvOffset64
  for relPath in sorted:
    let absPath =
      if relPath.isAbsolute: relPath
      else: projectRoot / relPath
    let content = readFile(absPath)
    running = fnv1a64(toHex16(running) & "\x00" & relPath & "\x00" & content)
  result = toHex16(running)

# ---------------------------------------------------------------------------
# planner.nim — slug
# ---------------------------------------------------------------------------

proc slugify(path: string): string =
  result = newStringOfCap(path.len)
  for c in path:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      result.add c
    else:
      result.add "__"

proc slug*(path: string; flags: seq[string]): string =
  ## Frozen copy of `crisol/planner.slug`.
  let readablePrefix = slugify(path)
  var sortedFlags = flags
  sortedFlags.sort()
  let hashInput = path & "\x00" & sortedFlags.join("\x1f")
  let hash16 = toHex16(fnv1a64(hashInput))
  result = readablePrefix & "-" & hash16

# ---------------------------------------------------------------------------
# keys.nim — identityKey (plain string return, not the distinct IdentityKey)
# ---------------------------------------------------------------------------

proc identityKey*(path: string; flagHash: string): string =
  ## Frozen copy of `crisol/keys.identityKey`.
  let h = fnv1a64("\x00" & path & "\x00" & flagHash)
  result = toHex16(h)

# ---------------------------------------------------------------------------
# depgraph.nim — flagHash
# ---------------------------------------------------------------------------

proc flagHash*(flags: seq[string]): string =
  ## Frozen copy of `crisol/depgraph.flagHash`.
  var sorted = flags
  sorted.sort()
  let joined = sorted.join("\x00")
  result = toHex16(fnv1a64(joined))
