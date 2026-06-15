## test_keys.nim — TDD tests for A2: IdentityKey + SoundnessKey derivation.
##
## All effectful inputs (ccVersion, hermeticEnvHash, closureContentHash) are
## injected as params so every proc under test is pure and deterministic.
##
## Coverage:
##   - IdentityKey stability: same (path, flagHash) → same key.
##   - IdentityKey discrimination: different path or flagHash → different key.
##   - SoundnessKey determinism: identical KeyInputs → identical key.
##   - Each of the 9 components is load-bearing: mutating any one changes the key.
##   - XOR-cancellation negative: swapping two components must change the key
##     (XOR is commutative; chained-FNV must not be).
##   - NUL-in-fixture aliasing negative: embedded NUL bytes in a component cannot
##     alias the NUL separator between components.
##   - Empty-fixture sentinel produces a stable key distinct from a non-empty hash.

import std/options
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
# IdentityKey: stability
# ---------------------------------------------------------------------------

block test_identity_key_stable:
  let k1 = identityKey("tests/unit/test_foo.nim", "aabbccdd11223344")
  let k2 = identityKey("tests/unit/test_foo.nim", "aabbccdd11223344")
  assert k1 == k2, "IdentityKey must be deterministic"

block test_identity_key_differs_by_path:
  let k1 = identityKey("tests/unit/test_foo.nim", "aabbccdd11223344")
  let k2 = identityKey("tests/unit/test_bar.nim", "aabbccdd11223344")
  assert k1 != k2, "IdentityKey must differ when path differs"

block test_identity_key_differs_by_flaghash:
  let k1 = identityKey("tests/unit/test_foo.nim", "aabbccdd11223344")
  let k2 = identityKey("tests/unit/test_foo.nim", "ffffffffffffffff")
  assert k1 != k2, "IdentityKey must differ when flagHash differs"

# ---------------------------------------------------------------------------
# SoundnessKey: determinism
# ---------------------------------------------------------------------------

block test_soundness_key_deterministic:
  let inp = baseInputs()
  let k1 = soundnessKey(inp)
  let k2 = soundnessKey(inp)
  assert k1 == k2, "SoundnessKey must be deterministic for identical inputs"

# ---------------------------------------------------------------------------
# SoundnessKey: each component is load-bearing
# ---------------------------------------------------------------------------

block test_soundness_key_each_component_matters:
  let base = baseInputs()
  let kBase = soundnessKey(base)

  # 1. closureContentHash
  var inp = base
  inp.closureContentHash = "0000000000000000"
  assert soundnessKey(inp) != kBase, "closureContentHash must be load-bearing"

  # 2. flagHash
  inp = base
  inp.flagHash = "ffffffffffffffff"
  assert soundnessKey(inp) != kBase, "flagHash must be load-bearing"

  # 3. nimVersion
  inp = base
  inp.nimVersion = "2.3.0"
  assert soundnessKey(inp) != kBase, "nimVersion must be load-bearing"

  # 4. ccVersion
  inp = base
  inp.ccVersion = "clang 18.0.0|ldd 2.40"
  assert soundnessKey(inp) != kBase, "ccVersion must be load-bearing"

  # 5. fixtureHash
  inp = base
  inp.fixtureHash = "0000000000000000"
  assert soundnessKey(inp) != kBase, "fixtureHash must be load-bearing"

  # 6. argv
  inp = base
  inp.argv = @["./test_foo", "--seed=99"]
  assert soundnessKey(inp) != kBase, "argv must be load-bearing"

  # 7. rlimitConfig — change limitAs
  inp = base
  inp.rlimitConfig = RlimitConfig(limitAs: some(512 * 1024 * 1024'i64))
  assert soundnessKey(inp) != kBase, "rlimitConfig must be load-bearing"

  # 8. hermeticEnvHash
  inp = base
  inp.hermeticEnvHash = "ffffffffffffffff"
  assert soundnessKey(inp) != kBase, "hermeticEnvHash must be load-bearing"

  # 9. protocolMajor
  inp = base
  inp.protocolMajor = 2
  assert soundnessKey(inp) != kBase, "protocolMajor must be load-bearing"

# ---------------------------------------------------------------------------
# XOR-cancellation NEGATIVE: order-sensitivity (chained-FNV is not commutative)
#
# Under an XOR fold: H(A ⊕ B) = H(B ⊕ A). Swapping any two components that
# carry the same value would still cancel under XOR. Here we swap the VALUES of
# closureContentHash and flagHash; a commutative fold would give the same result.
# Chained-FNV must give a DIFFERENT result because order is part of the chain.
# ---------------------------------------------------------------------------

block test_soundness_key_order_sensitive_xor_negative:
  var a = baseInputs()
  a.closureContentHash = "aaaaaaaaaaaaaaaa"
  a.flagHash           = "bbbbbbbbbbbbbbbb"

  var b = baseInputs()
  b.closureContentHash = "bbbbbbbbbbbbbbbb"  # swapped
  b.flagHash           = "aaaaaaaaaaaaaaaa"  # swapped

  let kA = soundnessKey(a)
  let kB = soundnessKey(b)
  assert kA != kB,
    "SoundnessKey must be order-sensitive (chained-FNV); XOR would make these equal"

# ---------------------------------------------------------------------------
# NUL-in-fixture aliasing NEGATIVE:
#
# If the separator NUL between components could be aliased by a NUL embedded
# inside a component value, two DIFFERENT component splits might hash identically.
#
# The RFC's protection rule: each variable-length component is placed LAST within
# its own per-component fnv1a64 call, so a NUL embedded in e.g. fixtureHash
# cannot alias the separator that precedes the NEXT component.
#
# Construct: two inputs where only fixtureHash differs but in a way that would
# be indistinguishable if we naively concatenated components with NUL separators
# without the per-component wrapping. Specifically:
#   A: fixtureHash = "ab\x00" , argv suffix starts with "cd"
#   B: fixtureHash = "ab"     , argv suffix starts with "\x00cd"
# Under naive "join with NUL" these produce the same byte stream for those two
# components. The per-component fnv1a64 wrapping must distinguish them.
# ---------------------------------------------------------------------------

block test_soundness_key_nul_in_fixture_no_alias:
  var a = baseInputs()
  # fixtureHash with embedded NUL, argv without
  a.fixtureHash = "ab\x00"
  a.argv        = @["cd"]

  var b = baseInputs()
  # fixtureHash without NUL, argv with leading NUL
  b.fixtureHash = "ab"
  b.argv        = @["\x00cd"]

  let kA = soundnessKey(a)
  let kB = soundnessKey(b)
  assert kA != kB,
    "SoundnessKey must not alias NUL-in-component with component separator"

# ---------------------------------------------------------------------------
# Empty-fixture sentinel: stable and distinct from a real hash
# ---------------------------------------------------------------------------

block test_soundness_key_empty_fixture_sentinel_stable:
  var a = baseInputs()
  a.fixtureHash = ""          # empty → sentinel applied internally

  var b = baseInputs()
  b.fixtureHash = ""

  assert soundnessKey(a) == soundnessKey(b),
    "empty-fixture sentinel must produce a stable SoundnessKey"

block test_soundness_key_empty_fixture_differs_from_real:
  var a = baseInputs()
  a.fixtureHash = ""          # empty → sentinel

  var b = baseInputs()
  b.fixtureHash = "fedcba9876543210"   # non-empty

  assert soundnessKey(a) != soundnessKey(b),
    "empty-fixture sentinel must differ from a real fixtureHash"

echo "test_keys: all assertions passed"
