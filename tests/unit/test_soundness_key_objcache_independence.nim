## test_soundness_key_objcache_independence.nim — RFC-0006 Stage R, R3: the
## regression guard proving object-cache (objcache.nim) reuse is OUTSIDE the
## RFC-0004 result-cache soundness key.
##
## WHY this guard exists: `keys.soundnessKey` is the single source of truth
## for "same key ⇒ same result may be served from cache" (RFC-0004). The
## RFC-0006 object cache (objcache.nim) caches individual *compiled .o
## objects* across entrypoints — a hit there changes HOW a binary got built,
## never WHAT its source/flags/toolchain/fixtures/argv/env/protocol are. It
## is therefore sound for objcache hits/misses to be completely invisible to
## `soundnessKey`: folding any objcache/compile-cache signal into the key
## would be both unnecessary (nothing observable changes) AND actively
## harmful (it would make an implementation-detail cache-internal state leak
## into a key that is supposed to describe only externally-observable
## inputs).
##
## This file asserts that invariant two ways:
##
##   1. `soundnessKey` is a pure function of `KeyInputs` — two structurally
##      identical `KeyInputs` values always produce the same key (baseline
##      purity/determinism check; also covered by test_keys.nim's
##      `test_soundness_key_deterministic`, repeated here so this file is a
##      self-contained guard).
##   2. `KeyInputs` itself carries NO objcache/compile-cache field to fold in,
##      even if a future change wanted to. Enumerated at runtime via
##      `fieldPairs` over the 9 known RFC-0004 fields, so a future PR that
##      adds a 10th field (e.g. an `objCacheHit`/`compileCacheKey` field) trips
##      this test red — either the field-count assertion or the
##      name-denylist assertion below will fail, forcing the change to be
##      reviewed rather than silently landing.
##
## Honesty note (per RFC-0006 R3 instructions): the strongest assertion this
## file can make is exactly what it says — "same KeyInputs -> same key" plus
## "KeyInputs has no compile-cache-shaped field today". It does NOT (and
## cannot, from a unit test alone) prove that no *future* field could be
## misused; the integration test in
## tests/integration/test_objcache_soundness_independence.nim supplies the
## complementary real-world proof: a real `--objcache` run and a real
## `--no-objcache` run of the same entrypoint produce byte-identical
## `inputHash` (the soundnessKey string) in their respective lastrun.json.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_soundness_key_objcache_independence.nim

import std/[options, strutils]
import crisol/keys
import crisol/types

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc baseInputs(): KeyInputs =
  KeyInputs(
    closureContentHash: "aabbccdd11223344",
    flagHash:           "0011223344556677",
    nimVersion:         "2.2.10",
    ccVersion:          "gcc 13.2.0|ldd 2.39",
    fixtureHash:        "fedcba9876543210",
    argv:               @["./test_foo", "--seed=42"],
    rlimitConfig:       RlimitConfig(),
    hermeticEnvHash:    "1122334455667788",
    protocolMajor:      1,
  )

# ---------------------------------------------------------------------------
# 1. Purity/determinism: identical KeyInputs -> identical SoundnessKey.
#
# Two INDEPENDENTLY-constructed (but field-for-field identical) KeyInputs
# values must hash to the same key. If objcache state (or any other hidden
# global/mutable state) were somehow leaking into the computation, this
# would be the first thing to break -- soundnessKey is documented as a pure
# function of its single explicit parameter.
# ---------------------------------------------------------------------------

block test_identical_key_inputs_produce_identical_soundness_key:
  let a = baseInputs()
  let b = baseInputs()   # separately constructed, field-for-field equal
  assert soundnessKey(a) == soundnessKey(b),
    "soundnessKey must be a pure function of KeyInputs: two structurally " &
    "identical KeyInputs values must produce identical keys"

  # Calling it again on the SAME value must also be stable (no hidden
  # incrementing/mutating state inside soundnessKey itself).
  assert soundnessKey(a) == soundnessKey(a),
    "soundnessKey must be repeatable: calling it twice on the same value " &
    "must yield the same key"

# ---------------------------------------------------------------------------
# 2. KeyInputs carries no objcache/compile-cache field.
#
# Enumerate the object's fields via `fieldPairs` (runtime reflection over the
# object's declared fields -- this is NOT a hardcoded string list copy/pasted
# from keys.nim; it reads the actual type). Assert:
#   (a) the exact set of 9 RFC-0004 field names is present, and
#   (b) no field name is shaped like an objcache/compile-cache signal.
#
# If a future change adds a field such as `objCacheHit`, `compileCacheKey`,
# `objHash`, etc. to KeyInputs to fold objcache state into the soundness key,
# assertion (a) trips (field count / name-set changed) forcing this test --
# and the reviewer -- to consciously confront the soundness question before
# such a change can land quietly.
# ---------------------------------------------------------------------------

const ExpectedRfc0004Fields = [
  "closureContentHash",
  "flagHash",
  "nimVersion",
  "ccVersion",
  "fixtureHash",
  "argv",
  "rlimitConfig",
  "hermeticEnvHash",
  "protocolMajor",
]
  ## The 9 components documented in keys.nim's module doc, in KeyInputs
  ## declaration order. NOT itself a claim about what SHOULD be in the key
  ## (that's keys.nim's job to document) -- just the enumerated baseline this
  ## guard diffs against.

const ObjCacheShapedSubstrings = ["obj", "compilecache", "objcache"]
  ## Case-insensitive substrings that would flag a field name as
  ## objcache/compile-cache-shaped. "obj" alone catches "objCacheHit",
  ## "objHash", "objectCache", etc.

block test_key_inputs_has_no_objcache_field:
  var fieldNames: seq[string] = @[]
  let inp = baseInputs()
  for name, _ in inp.fieldPairs:
    fieldNames.add name

  assert fieldNames == @ExpectedRfc0004Fields,
    "KeyInputs field set changed from the documented RFC-0004 9-component " &
    "baseline -- if this is an intentional new soundness input, update " &
    "ExpectedRfc0004Fields; if it is an objcache/compile-cache field being " &
    "folded into the result-soundness key, STOP: object reuse is supposed " &
    "to be provably outside this key (see objcache.nim's module doc and " &
    "this file's header comment)"

  for name in fieldNames:
    let lower = name.toLowerAscii
    for bad in ObjCacheShapedSubstrings:
      assert bad notin lower,
        "KeyInputs field '" & name & "' looks objcache/compile-cache-shaped " &
        "(matched substring '" & bad & "') -- object reuse must stay OUTSIDE " &
        "the result-soundness key; see objcache.nim's module doc"

echo "test_soundness_key_objcache_independence: all assertions passed"
