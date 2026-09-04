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
##
## RFC-0005 B1a — explainMiss + envDigest (§Miss-explanation, pure half):
##   - One vector per KeyComponent (9): changed alone ⇒ exactly that KeyDiff.
##   - Flag-change vector (the common deliberate miss).
##   - Env-name vector: changed value, added name, removed name — named in
##     envNames, values never appear in the output.
##   - Multi-component vector ⇒ all changed components, in enum order.
##   - No-diff vector ⇒ empty seq.
##   - envDigest: stable, hides the value, renders 16 hex chars.

import std/[options, strutils]
import crisol/keys
import crisol/types
import crisol/process/types  ## unqualified Limits/LimitKind (rfc-0007 A2a-iii)

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
    limits:             Limits(),
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

  # 7. limits — change limitAs (pins: the key changes when a limit changes)
  inp = base
  inp.limits = Limits()
  inp.limits.req[lkAddressSpace] = some(512 * 1024 * 1024'i64)
  assert soundnessKey(inp) != kBase, "limits must be load-bearing"

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

# ---------------------------------------------------------------------------
# Structural tripwire: KeyInputs has exactly the 9 documented RFC-0004
# components, none shaped like a compile-cache/object-cache signal.
#
# Preserved from the now-deleted RFC-0006 objcache-independence guard
# (test_soundness_key_objcache_independence.nim, removed with Stage R):
# object/compile-cache reuse must stay OUTSIDE the result-soundness key.
# Enumerated at runtime via `fieldPairs` (not a hardcoded copy of keys.nim's
# field list) so a future PR that adds a 10th field trips this test red,
# forcing the change to be reviewed rather than silently landing.
# ---------------------------------------------------------------------------

const ExpectedRfc0004Fields = [
  "closureContentHash",
  "flagHash",
  "nimVersion",
  "ccVersion",
  "fixtureHash",
  "argv",
  "limits",
  "hermeticEnvHash",
  "protocolMajor",
]
  ## The 9 components documented in keys.nim's module doc, in KeyInputs
  ## declaration order.

const CacheShapedSubstrings = ["obj", "compilecache", "objcache"]
  ## Case-insensitive substrings that would flag a field name as a
  ## compile-cache/object-cache signal (e.g. "objCacheHit", "objHash").

block test_key_inputs_has_no_cache_shaped_field:
  var fieldNames: seq[string] = @[]
  let inp = baseInputs()
  for name, _ in inp.fieldPairs:
    fieldNames.add name

  assert fieldNames == @ExpectedRfc0004Fields,
    "KeyInputs field set changed from the documented RFC-0004 9-component " &
    "baseline -- if this is an intentional new soundness input, update " &
    "ExpectedRfc0004Fields; if it is a compile-cache field being folded " &
    "into the result-soundness key, STOP: object/compile reuse is supposed " &
    "to stay provably outside this key"

  for name in fieldNames:
    let lower = name.toLowerAscii
    for bad in CacheShapedSubstrings:
      assert bad notin lower,
        "KeyInputs field '" & name & "' looks compile-cache-shaped " &
        "(matched substring '" & bad & "') -- object/compile reuse must " &
        "stay OUTSIDE the result-soundness key"

# ---------------------------------------------------------------------------
# RFC-0005 B1a — explainMiss + envDigest
# ---------------------------------------------------------------------------

const NoEnv: seq[(string, string)] = @[]
  ## Used for every vector that does not exercise kcHermeticEnv: prevEnv/
  ## currEnv are irrelevant when hermeticEnvHash itself is unchanged.

proc limitsStr(limits: Limits): string =
  ## Test-local mirror of keys.nim's private `limitsFoldString`, built from
  ## the documented format ("<kindName>=<v>|..." in LimitKind enum order)
  ## rather than importing the private proc — keeps the test honest about
  ## the format as observable behavior, not implementation reach-in.
  proc optStr(o: Option[int64]): string =
    if o.isSome: $o.get else: "-"
  result = ""
  for kind in LimitKind:
    if result.len > 0: result.add("|")
    result.add($kind & "=" & optStr(limits.req[kind]))

block test_explain_miss_no_diff:
  let base = baseInputs()
  assert explainMiss(base, base, NoEnv, NoEnv) == @[],
    "identical KeyInputs must explain to an empty seq"

block test_explain_miss_component_closure:
  let base = baseInputs()
  var curr = base
  curr.closureContentHash = "0000000000000000"
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcClosure
  assert diffs[0].prev == base.closureContentHash
  assert diffs[0].curr == curr.closureContentHash
  assert diffs[0].envNames == @[]

block test_explain_miss_component_flags:
  let base = baseInputs()
  var curr = base
  curr.flagHash = "ffffffffffffffff"
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcFlags
  assert diffs[0].prev == base.flagHash
  assert diffs[0].curr == curr.flagHash
  assert diffs[0].envNames == @[]

block test_explain_miss_component_nim_version:
  let base = baseInputs()
  var curr = base
  curr.nimVersion = "2.3.0"
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcNimVersion
  assert diffs[0].prev == base.nimVersion
  assert diffs[0].curr == curr.nimVersion

block test_explain_miss_component_cc_version:
  let base = baseInputs()
  var curr = base
  curr.ccVersion = "clang 18.0.0|ldd 2.40"
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcCcVersion
  assert diffs[0].prev == base.ccVersion
  assert diffs[0].curr == curr.ccVersion

block test_explain_miss_component_fixtures:
  let base = baseInputs()
  var curr = base
  curr.fixtureHash = "0000000000000000"
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcFixtures
  assert diffs[0].prev == base.fixtureHash
  assert diffs[0].curr == curr.fixtureHash

block test_explain_miss_component_argv:
  let base = baseInputs()
  var curr = base
  curr.argv = @["./test_foo", "--seed=99"]
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcArgv
  assert diffs[0].prev == "./test_foo --seed=42"
  assert diffs[0].curr == "./test_foo --seed=99"

block test_explain_miss_component_limits:
  let base = baseInputs()
  var curr = base
  curr.limits = Limits()
  curr.limits.req[lkAddressSpace] = some(512 * 1024 * 1024'i64)
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcLimits
  assert diffs[0].prev == limitsStr(base.limits)
  assert diffs[0].curr == limitsStr(curr.limits)
  assert diffs[0].curr != diffs[0].prev

block test_explain_miss_component_hermetic_env:
  let base = baseInputs()
  var curr = base
  curr.hermeticEnvHash = "ffffffffffffffff"
  let prevEnv = @[("PATH", "aaaa1111bbbb2222")]
  let currEnv = @[("PATH", "aaaa1111bbbb2222")]  # unchanged names/digests
  let diffs = explainMiss(base, curr, prevEnv, currEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcHermeticEnv
  assert diffs[0].prev == base.hermeticEnvHash
  assert diffs[0].curr == curr.hermeticEnvHash

block test_explain_miss_component_protocol:
  let base = baseInputs()
  var curr = base
  curr.protocolMajor = 2
  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcProtocol
  assert diffs[0].prev == "1"
  assert diffs[0].curr == "2"

# ---------------------------------------------------------------------------
# Flag-change vector — the common deliberate miss (RFC-0005 B1a bullet,
# stated separately from the generic per-component sweep above because it
# is the dominant real-world explainMiss case: a developer edits compile
# flags and expects the miss to say so, not "no prior inputs").
# ---------------------------------------------------------------------------

block test_explain_miss_flag_change_is_the_common_case:
  let prev = baseInputs()
  var curr = baseInputs()
  curr.flagHash = "9988776655443322"   # a different --define set, e.g.
  let diffs = explainMiss(prev, curr, NoEnv, NoEnv)
  assert diffs.len == 1, "a flag-only change must explain to exactly one KeyDiff"
  assert diffs[0].component == kcFlags
  assert diffs[0].prev == prev.flagHash
  assert diffs[0].curr == curr.flagHash

# ---------------------------------------------------------------------------
# Env-name vector: changed value, added name, removed name.
#
# prevEnv/currEnv are DIGESTS (per envDigest's contract) — this test builds
# them directly as opaque hex strings to prove explainMiss never needs (or
# leaks) the underlying values.
# ---------------------------------------------------------------------------

block test_explain_miss_env_names_changed_added_removed:
  let base = baseInputs()
  var curr = base
  curr.hermeticEnvHash = "abcdefabcdefabcd"   # must differ to report the component

  let prevEnv = @[
    ("CHANGED_VAR", "1111111111111111"),
    ("REMOVED_VAR", "2222222222222222"),
    ("STABLE_VAR",  "3333333333333333"),
  ]
  let currEnv = @[
    ("CHANGED_VAR", "9999999999999999"),  # value (digest) changed
    ("STABLE_VAR",  "3333333333333333"),  # unchanged
    ("ADDED_VAR",   "4444444444444444"),  # present only in curr
  ]

  let diffs = explainMiss(base, curr, prevEnv, currEnv)
  assert diffs.len == 1
  assert diffs[0].component == kcHermeticEnv
  assert diffs[0].envNames == @["ADDED_VAR", "CHANGED_VAR", "REMOVED_VAR"],
    "envNames must list changed/added/removed names, sorted, excluding STABLE_VAR"
  # No digest or value ever appears in prev/curr/envNames for this component.
  for n in diffs[0].envNames:
    assert "1111111111111111" notin n
    assert "9999999999999999" notin n

# ---------------------------------------------------------------------------
# Multi-component vector ⇒ all changed components, in enum (== field) order.
# ---------------------------------------------------------------------------

block test_explain_miss_multi_component_enum_order:
  let base = baseInputs()
  var curr = base
  # Change kcProtocol, kcClosure, kcFixtures out of enum order to prove the
  # OUTPUT order is enum order, not mutation order.
  curr.protocolMajor = 2
  curr.closureContentHash = "0000000000000000"
  curr.fixtureHash = "0000000000000000"

  let diffs = explainMiss(base, curr, NoEnv, NoEnv)
  assert diffs.len == 3
  assert diffs[0].component == kcClosure
  assert diffs[1].component == kcFixtures
  assert diffs[2].component == kcProtocol

# ---------------------------------------------------------------------------
# envDigest: stable, hides the value, 16 hex chars.
# ---------------------------------------------------------------------------

block test_env_digest_stable:
  let env = @[("PATH", "/usr/bin:/bin")]
  assert envDigest(env) == envDigest(env),
    "envDigest must be deterministic for identical input"

block test_env_digest_hides_value:
  let value = "super-secret-value-1234"
  let digested = envDigest(@[("SECRET", value)])
  assert digested.len == 1
  assert digested[0][0] == "SECRET"
  assert digested[0][1] != value
  assert value notin digested[0][1]

block test_env_digest_is_16_hex_chars:
  let digested = envDigest(@[("A", "x"), ("B", "")])
  const hexChars = "0123456789abcdef"
  for (_, digest) in digested:
    assert digest.len == 16, "envDigest must render 16 hex chars"
    for c in digest:
      assert c in hexChars, "envDigest must be lower-case hex"

echo "test_keys: all assertions passed"
