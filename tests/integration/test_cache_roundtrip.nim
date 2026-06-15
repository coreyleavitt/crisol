## test_cache_roundtrip.nim — A7: real run-twice → cached, through crisol/api.
##
## End-to-end, against the REAL on-disk ExecutionCache (no mocks), driven only
## through the public crisol/api surface:
##
##   1. run-twice → cached: first runTests runs live (stores); second runTests
##      with identical inputs HITS the cache → result.cached, cdmHit, no spawn.
##   2. changed closure → miss: editing the entrypoint source between runs
##      changes its closureHash ⇒ different soundness key ⇒ a live re-run.
##   3. FAILING entrypoint is NOT cached: a quit(1) fixture run twice runs live
##      both times (v1 caches passes only).
##   4. --no-cache: the second run does NOT consult the cache even after a store.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/integration/test_cache_roundtrip.nim

import std/[os, strutils, unittest]
import crisol/api

import "../support/helpers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc baseOpts(projectRoot: string; noCache = false): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,   # writes lastrun.json + depgraph; cache lives under stateDir
    showProgress:   false,
    noCache:        noCache,
  )

proc anyCached(rr: RunReport): bool =
  for r in rr.results:
    if r.cached: return true
  false

# ---------------------------------------------------------------------------
# 1. run-twice → cached
# ---------------------------------------------------------------------------

suite "A7 — run twice, second is cached":

  test "first runs live, second is served from cache":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_pass.nim", "quit(0)\n")

      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.status == rsOk
      check rr1.exitCode == 0
      check rr1.results.len == 1
      check not rr1.results[0].cached            # first run is live
      # M8: a live first-pass that successfully stores is cdmStored (not cdmKeyMiss).
      # cdmKeyMiss is reserved for live runs that did NOT produce a stored entry.
      check rr1.results[0].cacheDecision == cdmStored
      # A8: the live store path stamps the soundnessKey as inputHash.
      check rr1.results[0].inputHash.len > 0

      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.status == rsOk
      check rr2.exitCode == 0
      check rr2.results.len == 1
      check rr2.results[0].cached                # second run is CACHED
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.results[0].outcome == oPassed
      # A8: the hit was served on the SAME key the live run stored under —
      # inputHash must round-trip identically across the two runs.
      check rr2.results[0].inputHash == rr1.results[0].inputHash

# ---------------------------------------------------------------------------
# 2. changed closure → cache miss → live re-run
# ---------------------------------------------------------------------------

suite "A7 — changed closure misses the cache":

  test "editing the entrypoint source forces a live re-run":
    withTempProject:
      let f = projectRoot / "tests" / "unit" / "test_pass.nim"
      writeFile(f, "quit(0)\n")

      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.exitCode == 0
      check not rr1.results[0].cached

      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.results[0].cached                # confirm caching is working

      # Change the SOURCE: same outcome (still passes), but different closureHash
      # ⇒ different soundness key ⇒ guaranteed miss.
      writeFile(f, "discard 1 + 1\nquit(0)\n")
      let rr3 = runTests(baseOpts(projectRoot))
      check rr3.exitCode == 0
      check not rr3.results[0].cached            # changed closure ⇒ MISS, ran live
      # M8: the re-run passes and gets stored → cdmStored (not cdmKeyMiss).
      check rr3.results[0].cacheDecision == cdmStored

# ---------------------------------------------------------------------------
# 3. failing entrypoint is NOT cached
# ---------------------------------------------------------------------------

suite "A7 — failing entrypoint is never cached":

  test "a quit(1) fixture runs live on both runs (passes-only policy)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_fail.nim", "quit(1)\n")

      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.exitCode == 1
      check rr1.results[0].outcome == oFailed
      check not rr1.results[0].cached

      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.exitCode == 1
      check not rr2.results[0].cached            # still not cached on the 2nd run
      check rr2.results[0].cacheDecision == cdmKeyMiss

# ---------------------------------------------------------------------------
# 4. --no-cache full bypass
# ---------------------------------------------------------------------------

suite "A7 — --no-cache does not read the cache":

  test "after a normal store, a --no-cache run still runs live":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_pass.nim", "quit(0)\n")

      # Prime the cache with a normal run.
      let rr1 = runTests(baseOpts(projectRoot))
      check not rr1.results[0].cached
      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.results[0].cached                # cache is primed + working

      # --no-cache: must NOT consult the cache even though an entry exists.
      # R2-1: the binary is already built (edRunFresh), so --no-cache suppresses
      # an eligible lookup → cdmPolicyDisabled (not cdmNotEligible which means
      # "had to be compiled; cache was never applicable").
      let rr3 = runTests(baseOpts(projectRoot, noCache = true))
      check rr3.exitCode == 0
      check not rr3.results[0].cached
      check rr3.results[0].cacheDecision == cdmPolicyDisabled

echo "test_cache_roundtrip: done"
