## fnv.nim — FNV-1a 64-bit hash primitives (leaf module, std-only imports).
##
## The single, canonical implementation of the 64-bit FNV-1a hash crisol
## uses everywhere a stable, cross-Nim-version hash is needed (`std/hashes`
## is NOT used for this — its output is not guaranteed stable across Nim
## versions). Every other module that needs these primitives imports THIS
## module directly, or reaches them transitively through `crisol/depgraph`
## (which imports and re-exports them for backward compatibility with
## existing `import crisol/depgraph` call sites).
##
## This module is a true leaf — std-only imports, no crisol imports — so it
## can be imported from anywhere in the dependency graph without risk of a
## cycle. In particular, `crisol/closure` needs `chainedContentHash` (for
## `ExternalSource.headersHash`, issue #16) but cannot import
## `crisol/depgraph` (which itself imports `crisol/closure` — a cycle); it
## imports this module instead.

import std/algorithm

const fnvOffset64* = 0xcbf29ce484222325'u64
  ## FNV-1a 64-bit offset basis.
const fnvPrime64* = 0x00000100000001b3'u64
  ## FNV-1a 64-bit prime.

proc fnv1a64*(data: string): uint64 =
  ## 64-bit FNV-1a hash over `data`.
  result = fnvOffset64
  for c in data:
    result = result xor uint64(ord(c))
    result = result * fnvPrime64

proc toHex16*(v: uint64): string =
  ## Render a uint64 as 16 lower-case hex chars.
  const hexChars = "0123456789abcdef"
  result = newString(16)
  var x = v
  for i in countdown(15, 0):
    result[i] = hexChars[x and 0xf]
    x = x shr 4

proc chainedContentHash*(pairs: seq[tuple[key: string; nativePath: string]]): string =
  ## Compute a stable 64-bit FNV-1a hash over the CONTENTS of all `pairs`.
  ##
  ## RFC-0009 A5a: the CHAINED path component is now the PORTABLE `key`
  ## (a project member's project-root-relative spelling, or a dep-root
  ## member's `dep:name/rel` spelling — see `crisol/paths.keyBytes`), never
  ## the machine-local absolute path. Content is still read from
  ## `nativePath` — the absolute, already-resolved path — so a project-only
  ## closure hashes BYTE-IDENTICAL to before this change (its `key` is the
  ## same relative spelling the old `relPath` was), while a dep-root
  ## member's hash becomes host-portable (its `key` no longer embeds the
  ## checkout location).
  ##
  ## Algorithm: iterate over `pairs` sorted by `key`; for each pair, chain
  ## the running hash through both `key` AND the file content (read from
  ## `nativePath`) using FNV-1a:
  ##   running = fnv1a64(toHex16(running) & "\x00" & key & "\x00" & content)
  ##
  ## Properties:
  ##   - Order-independent for the same set (pairs are sorted by `key`
  ##     before hashing — never by `nativePath`, which is not portable).
  ##   - Position-sensitive AND key-sensitive: swapping file contents
  ##     between two keys changes the hash (R6 fix vs the old XOR scheme
  ##     which is commutative and self-cancelling).
  ##   - Non-self-cancelling: two files with identical content are
  ##     distinguished by their keys.
  ##
  ## Parameters:
  ##   `pairs` — seq of (key, nativePath): `key` is the portable spelling to
  ##             chain into the hash; `nativePath` is the ABSOLUTE native
  ##             path content is read from (no projectRoot resolution
  ##             happens here — the caller hands over an already-resolved
  ##             absolute path).
  ##
  ## Returns 16 lower-case hex chars (or all-zeros string if pairs is empty).
  ##
  ## Raises OSError/IOError if any file cannot be read.
  var sorted = pairs
  sorted.sort(proc(a, b: tuple[key: string; nativePath: string]): int =
    cmp(a.key, b.key))
  var running: uint64 = fnvOffset64  # start from FNV offset (not 0) for non-trivial empty case
  for pair in sorted:
    let content = readFile(pair.nativePath)
    # Chain: mix running hash value, portable key, and content together.
    # This makes the result sensitive to both WHICH file changed AND WHAT its content is.
    running = fnv1a64(toHex16(running) & "\x00" & pair.key & "\x00" & content)
  result = toHex16(running)
