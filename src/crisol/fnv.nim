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

import std/[algorithm, os]

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

proc chainedContentHash*(files: seq[string]; projectRoot: string): string =
  ## Compute a stable 64-bit FNV-1a hash over the CONTENTS of all `files`.
  ##
  ## Algorithm: iterate over sorted(files); for each file, chain the running hash
  ## through both the relative path AND the file content using FNV-1a:
  ##   running = fnv1a64(toHex16(running) & "\x00" & relPath & "\x00" & content)
  ##
  ## Properties:
  ##   - Order-independent for the same set (files are sorted before hashing).
  ##   - Position-sensitive AND path-sensitive: swapping file contents between two
  ##     paths changes the hash (R6 fix vs the old XOR scheme which is commutative
  ##     and self-cancelling).
  ##   - Non-self-cancelling: two files with identical content are distinguished by
  ##     their paths.
  ##
  ## Parameters:
  ##   `files`       — seq of project-root-relative file paths (sorted internally)
  ##   `projectRoot` — absolute path to project root for resolving relative paths
  ##
  ## Returns 16 lower-case hex chars (or all-zeros string if files is empty).
  ##
  ## Raises OSError/IOError if any file cannot be read.
  var sorted = files
  sorted.sort()
  var running: uint64 = fnvOffset64  # start from FNV offset (not 0) for non-trivial empty case
  for relPath in sorted:
    let absPath =
      if relPath.isAbsolute: relPath
      else: projectRoot / relPath
    let content = readFile(absPath)
    # Chain: mix running hash value, path, and content together.
    # This makes the result sensitive to both WHICH file changed AND WHAT its content is.
    running = fnv1a64(toHex16(running) & "\x00" & relPath & "\x00" & content)
  result = toHex16(running)
