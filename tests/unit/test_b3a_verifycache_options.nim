## test_b3a_verifycache_options.nim — RFC-0005 B3a: VerifyCache options object.
##
## `RunOptions.verifyCache: VerifyCache` is the --verify-cache facade
## (RFC-0005 §Stage B "Facade (round 3)"): `{enabled, pct = 5, seed, strict}`
## built via `noVerify()` / `verifySample(pct, seed, strict)` — the same
## RunNarrowing constructor idiom (noNarrowing/failedOnly/…) so
## "strict without enabled" is unconstructable through the public API.
##
## B3a scope: the object + constructors only. Nothing yet CONSUMES
## RunOptions.verifyCache (the post-run pass lands in B3b; the CLI in B3c).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_b3a_verifycache_options.nim

import std/options
import crisol/api

# ---------------------------------------------------------------------------
# 1. noVerify() — the disabled default
# ---------------------------------------------------------------------------

block test_no_verify:
  let vc = noVerify()
  assert vc.enabled == false
  assert vc.strict == false

# ---------------------------------------------------------------------------
# 2. verifySample() — defaults (pct=5, seed=none, strict=false, enabled=true)
# ---------------------------------------------------------------------------

block test_verify_sample_defaults:
  let vc = verifySample()
  assert vc.enabled == true
  assert vc.pct == 5
  assert vc.seed.isNone
  assert vc.strict == false

# ---------------------------------------------------------------------------
# 3. verifySample(pct, seed, strict) — explicit fields carried through exactly
# ---------------------------------------------------------------------------

block test_verify_sample_explicit:
  let vc = verifySample(pct = 20, seed = some(1234'i64), strict = true)
  assert vc.enabled == true
  assert vc.pct == 20
  assert vc.seed == some(1234'i64)
  assert vc.strict == true

# ---------------------------------------------------------------------------
# 4. RunOptions.verifyCache default-constructs to the disabled state
# ---------------------------------------------------------------------------

block test_run_options_default:
  let opts = RunOptions()
  assert opts.verifyCache.enabled == false
  assert opts.verifyCache.strict == false

echo "test_b3a_verifycache_options: OK"
