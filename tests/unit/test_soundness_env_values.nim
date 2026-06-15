## test_soundness_env_values.nim — cache-soundness bug: env values must enter the key.
##
## RFC-0004 §Keys: the hermetic env component of the soundness key MUST hash
## names AND values of every allowlisted var (excluding TMPDIR value and
## CRISOL_* per-run injections).
##
## The bug (before fix): realSeams called hermeticEnvHashForSpec(spec) which
## hashes only env var NAMES.  Two runs where an allowlisted var's VALUE changed
## (e.g. PATH=/usr/bin vs PATH=/usr/local/bin) produced the SAME key and shared
## a cache entry, so a stale/wrong cached pass was served.
##
## After fix: realSeams uses hermeticEnvHash(filterEnv(envPairs(), spec, @[]))
## so names AND values both enter the key.
##
## This test file proves the invariant at the component level (pure, no live env):
##   1. Two filtered envs with the same allowlist but different values → DIFFERENT key.
##   2. Two filtered envs with the same allowlist and same values → SAME key.
##   3. TMPDIR value change alone → SAME key (value is per-run noise).
##   4. CRISOL_SINK / CRISOL_ATTEMPT value changes → SAME key (per-run injections).
##   5. namesOnlyHash (replicating old hermeticEnvHashForSpec logic) is unsound:
##      it produces the SAME hash for two environments that differ in an
##      allowlisted value — proving the bug was real.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/test_soundness_env_values.nim

import std/[algorithm, strutils]
import crisol/[types, sandbox, depgraph]

# ---------------------------------------------------------------------------
# Helper: build a minimal scrubbed SandboxSpec with a fixed allowlist.
# ---------------------------------------------------------------------------

proc scrubSpec(): SandboxSpec =
  SandboxSpec(
    level:                hlIsolated,
    envScrub:             true,
    envAllowlist:         @["HOME", "NIMBLE_DIR", "PATH"],
    envAllowlistPrefixes: @[],
  )

# ---------------------------------------------------------------------------
# Replicate the OLD (buggy) hermeticEnvHashForSpec logic in-test so this
# test remains self-contained and correct even after the proc is deleted from
# sandbox.nim.
# ---------------------------------------------------------------------------

proc namesOnlyHash(spec: SandboxSpec): string =
  ## Reproduces the OLD (now-deleted) hermeticEnvHashForSpec logic:
  ## hashes only env var NAMES, not values.
  if not spec.envScrub:
    return toHex16(fnv1a64("crisol:hermetic-env:unscrubbed:v1"))
  var names = spec.envAllowlist
  sort(names)
  var prefixes = spec.envAllowlistPrefixes
  sort(prefixes)
  var blob = "names:"
  for n in names:
    blob.add(n & "\x00")
  blob.add("prefixes:")
  for p in prefixes:
    blob.add(p & "\x00")
  result = toHex16(fnv1a64(blob))

# ---------------------------------------------------------------------------
# 1. Different allowlisted VALUES → DIFFERENT hermeticEnvHash.
##    (This is the soundness requirement.)
# ---------------------------------------------------------------------------

block test_different_value_different_hash:
  let spec = scrubSpec()
  # Two environments identical in shape (same names allowlisted) but differing
  # in PATH value — the exact scenario that triggered the cache-soundness bug.
  let env1 = filterEnv(
    @[("HOME", "/root"), ("NIMBLE_DIR", "/root/.nimble"), ("PATH", "/usr/bin"), ("SECRET", "drop")],
    spec, @[])
  let env2 = filterEnv(
    @[("HOME", "/root"), ("NIMBLE_DIR", "/root/.nimble"), ("PATH", "/usr/local/bin"), ("SECRET", "drop")],
    spec, @[])
  let h1 = hermeticEnvHash(env1)
  let h2 = hermeticEnvHash(env2)
  assert h1 != h2,
    "hermeticEnvHash: different PATH value must produce a different hash " &
    "(soundness: equal key ⇒ equal result; different values ⇒ different key). " &
    "Got h1=" & h1 & " h2=" & h2

# ---------------------------------------------------------------------------
# 2. Identical allowlisted VALUES → SAME hermeticEnvHash.
##    (Stability: same real inputs ⇒ same key.)
# ---------------------------------------------------------------------------

block test_same_value_same_hash:
  let spec = scrubSpec()
  let env1 = filterEnv(
    @[("HOME", "/root"), ("PATH", "/usr/bin"), ("NIMBLE_DIR", "/root/.nimble")],
    spec, @[])
  let env2 = filterEnv(
    @[("PATH", "/usr/bin"), ("HOME", "/root"), ("NIMBLE_DIR", "/root/.nimble")],
    spec, @[])
  let h1 = hermeticEnvHash(env1)
  let h2 = hermeticEnvHash(env2)
  assert h1 == h2,
    "hermeticEnvHash: same values in different order must produce the same hash " &
    "(filterEnv sorts; hermeticEnvHash also sorts). Got h1=" & h1 & " h2=" & h2

# ---------------------------------------------------------------------------
# 3. TMPDIR value change → SAME hash (value is a per-run random suffix).
##    (hermeticEnvHash hashes TMPDIR name only, not value.)
# ---------------------------------------------------------------------------

block test_tmpdir_value_change_same_hash:
  let spec = SandboxSpec(
    level:                hlIsolated,
    envScrub:             true,
    envAllowlist:         @["PATH", "TMPDIR"],
    envAllowlistPrefixes: @[],
  )
  let env1 = filterEnv(
    @[("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-abc123")],
    spec, @[])
  let env2 = filterEnv(
    @[("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-xyz999")],
    spec, @[])
  let h1 = hermeticEnvHash(env1)
  let h2 = hermeticEnvHash(env2)
  assert h1 == h2,
    "hermeticEnvHash: TMPDIR value must NOT enter the hash (per-run noise). " &
    "Got h1=" & h1 & " h2=" & h2

# ---------------------------------------------------------------------------
# 4. CRISOL_SINK / CRISOL_ATTEMPT value changes → SAME hash.
##    (These are per-run injections; excluded entirely from the hash.)
# ---------------------------------------------------------------------------

block test_crisol_injections_excluded_from_hash:
  let spec = SandboxSpec(
    level:                hlIsolated,
    envScrub:             true,
    envAllowlist:         @["PATH"],
    envAllowlistPrefixes: @[],
  )
  let base = filterEnv(@[("PATH", "/usr/bin")], spec, @[])
  # Simulate what spawn does: inject CRISOL_SINK and CRISOL_ATTEMPT.
  # hermeticEnvHash must exclude them regardless of value.
  let withInj1 = base & @[("CRISOL_SINK", "/tmp/sink-run1"), ("CRISOL_ATTEMPT", "1")]
  let withInj2 = base & @[("CRISOL_SINK", "/tmp/sink-run2"), ("CRISOL_ATTEMPT", "3")]
  let h1 = hermeticEnvHash(withInj1)
  let h2 = hermeticEnvHash(withInj2)
  assert h1 == h2,
    "hermeticEnvHash: CRISOL_SINK and CRISOL_ATTEMPT must NOT enter the hash. " &
    "Got h1=" & h1 & " h2=" & h2

# ---------------------------------------------------------------------------
# 5. SOUNDNESS BUG PROOF: the old names-only approach (namesOnlyHash, which
##   replicates the deleted hermeticEnvHashForSpec) is unsound — it produces
##   the SAME hash regardless of allowlisted values.
##   Meanwhile, hermeticEnvHash(filterEnv(...)) CORRECTLY differs when values differ.
# ---------------------------------------------------------------------------

block test_names_only_is_unsound_and_fix_is_correct:
  let spec = scrubSpec()

  ## Old (buggy) behavior: spec with same allowlist → same hash, even though
  ## the actual env values differ.  This is the soundness hole we are plugging.
  let oldHash1 = namesOnlyHash(spec)
  let oldHash2 = namesOnlyHash(spec)   # same spec → same hash regardless of env
  assert oldHash1 == oldHash2,
    "names-only hash is always the same for a given spec shape — " &
    "this proves it cannot distinguish runs that differ only in env values."

  ## New (fixed) behavior: hermeticEnvHash(filterEnv(...)) correctly differs
  ## when allowlisted values differ.
  let env1 = filterEnv(
    @[("HOME", "/root"), ("NIMBLE_DIR", "/root/.nimble"), ("PATH", "/usr/bin")],
    spec, @[])
  let env2 = filterEnv(
    @[("HOME", "/root"), ("NIMBLE_DIR", "/root/.nimble"), ("PATH", "/usr/local/bin")],
    spec, @[])
  assert hermeticEnvHash(env1) != hermeticEnvHash(env2),
    "values-included hash MUST differ when PATH differs — proving the fix is correct."

# ---------------------------------------------------------------------------
# 6. FAILING TEST (TDD RED): hermeticEnvHashForSpec must NOT be used as the
##   soundness key input.  Prove it by testing that realSeams-style wiring
##   with different env values produces DIFFERENT hashes.
##
##   The correct production wiring is:
##     hermeticEnvHash(filterEnv(envPairs(), spec, @[]))
##   NOT:
##     hermeticEnvHashForSpec(spec)      ← names-only, ignores values (BUG)
##
##   This block asserts that the CORRECT proc (hermeticEnvHash on filtered env)
##   distinguishes two env snapshots that differ in PATH — which is what the
##   production soundness key must do.  It ALSO asserts that the old names-only
##   proc FAILS to distinguish them, proving the wiring bug.
##
##   After the fix lands, this entire block remains green (it documents correct
##   post-fix behavior and the old-path unsoundness simultaneously).
# ---------------------------------------------------------------------------

block test_production_wiring_must_hash_values:
  ## Simulate two "host environments" that differ only in PATH.
  ## The correct soundness-key env hash must differ between them.
  ## The old names-only hash (as used by realSeams before the fix) does NOT differ.
  let spec = resolveSandbox()   # default hlIsolated spec, as used by api.nim

  let hostEnv1 = @[
    ("HOME", "/root"), ("PATH", "/usr/bin"), ("NIMBLE_DIR", "/root/.nimble"),
    ("TMPDIR", "/tmp/run-aaa"), ("CRISOL_SINK", "/tmp/s1"), ("CRISOL_ATTEMPT", "1"),
    ("SECRET_TOKEN", "drop-me"),
  ]
  let hostEnv2 = @[
    ("HOME", "/root"), ("PATH", "/usr/local/bin"), ("NIMBLE_DIR", "/root/.nimble"),
    ("TMPDIR", "/tmp/run-bbb"), ("CRISOL_SINK", "/tmp/s2"), ("CRISOL_ATTEMPT", "1"),
    ("SECRET_TOKEN", "drop-me"),
  ]

  # Correct wiring: filter then hash names+values.
  let filteredEnv1 = filterEnv(hostEnv1, spec, @[])
  let filteredEnv2 = filterEnv(hostEnv2, spec, @[])
  let correctH1 = hermeticEnvHash(filteredEnv1)
  let correctH2 = hermeticEnvHash(filteredEnv2)

  # The two envs differ only in PATH value and TMPDIR value (TMPDIR is excluded
  # from the hash value; PATH value must distinguish them).
  assert correctH1 != correctH2,
    "PRODUCTION WIRING: hermeticEnvHash(filterEnv(hostEnv, spec, [])) must " &
    "differ when PATH differs. This is the RFC-0004 soundness requirement. " &
    "Got same hash=" & correctH1 & " — fix: wire realSeams to filterEnv+hermeticEnvHash."

  # Old wiring (names-only) does NOT distinguish them — proving the bug.
  let buggyH1 = namesOnlyHash(spec)
  let buggyH2 = namesOnlyHash(spec)
  assert buggyH1 == buggyH2,
    "OLD WIRING (names-only): should produce same hash for same spec, " &
    "regardless of env values. Got different hashes unexpectedly."

echo "PASS test_soundness_env_values"
