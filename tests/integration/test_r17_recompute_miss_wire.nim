## test_r17_recompute_miss_wire.nim — code-review r17 (Medium): a
## recompute-invalidated hit whose rerun FAILS must keep reporting
## `cacheDecision: cdmRecomputeMiss` on the wire, never the generic
## `cdmKeyMiss`.
##
## Plan-time sets `cacheDecisions[i] = cdmRecomputeMiss` when a cache entry
## genuinely exists (the lookup itself hit) but recomputing its outcome/
## evidence under the run's OWN policy invalidates it (`cachedispatch.
## consultReal`'s `cdmRecomputeMiss` return site — its own doc there
## already says the live rerun's stamp is SUPPOSED to thread `lookup: cvOk`
## alongside `cacheDecision: "recomputeMiss"`). Before this fix, the
## live-finalize store gate in `runner.execute` unconditionally overwrote
## that: a PASSING rerun stamps `cdmStored` (fine, documented self-heal),
## but a FAILING rerun fell into `shouldStore`'s generic "not a pass"
## return (`cdmKeyMiss` — "no entry was found at all"), producing an
## internally contradictory wire pair: `cacheLookup: "ok"` (an entry WAS
## found) alongside `cacheDecision: "keyMiss"` (no entry was found).
##
## Drives this to the FINAL wire through the real API (`crisol/api.
## runTests`, real on-disk cache — no mocks): a fixture keeps its OWN
## source BYTE-IDENTICAL across two runs (so its soundnessKey never
## changes) but toggles its own exit code via a runtime counter file (the
## same idiom `test_verifycache_records_diverge.nim` uses to force a
## genuine second-invocation divergence without touching the entrypoint's
## closure) — PASSES on invocation 1 (gets stored), FAILS on invocation 2.
## Between the two `runTests` calls, the stored entry's `Evidence` is
## corrupted with one fabricated escapee: `evidenceSatisfies` (types.nim)
## fails UNCONDITIONALLY whenever `escapees.len > 0`, so the SAME
## (unchanged-key) entry's plan-time consult on run 2 is recompute-
## invalidated -- exactly the same mechanism `test_cachedispatch.nim`'s
## "escapee-evidence hit -> cdmRecomputeMiss" unit tests exercise, but
## driven here through a REAL store/lookup/live-rerun cycle to reach the
## site rev 17 actually broke (the runner's live-finalize stamp, not
## `lookupAtPlan`/`consultReal` themselves, which were already correct).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r17_recompute_miss_wire.nim

import std/[os, strutils, unittest]
import crisol/api
import crisol/cacheport    # StoredEntry
import crisol/cachewire    # jsonCacheSerializer
import crisol/process/types as ptypes  # ProcSnapshot

import "../support/helpers"

const R17Fixture = """
import std/[os, strutils]
const counterFile = "r17_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
if n == 1:
  quit(0)   # first invocation (the plan-time store): pass
else:
  quit(1)   # every later invocation (the recompute-invalidated rerun): fail
"""

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,
    showProgress:   false,
    noCache:        false,
  )

proc findStoredEntryPath(projectRoot: string): string =
  ## The one on-disk result-cache entry this test's single entrypoint
  ## stores, under `.crisol/cache/v<N>/<soundnessKey>.json` (cachelocalfs.
  ## entryPath's own layout -- NOT the `.crisol/cache/<epSlug>*` nimcache
  ## dirs that share the same "cache" parent).
  result = ""
  let cacheRoot = projectRoot / ".crisol" / "cache"
  for verKind, verPath in walkDir(cacheRoot):
    if verKind == pcDir and verPath.extractFilename.startsWith("v"):
      for kind, path in walkDir(verPath):
        if kind == pcFile and path.endsWith(".json"):
          result = path

proc injectFakeEscapee(entryPath: string) =
  ## Corrupts the stored entry's Evidence with one fabricated escapee --
  ## `evidenceSatisfies` refuses unconditionally on `escapees.len > 0`
  ## (types.nim), so the next plan-time consult of this SAME entry
  ## recomputes it as invalidated, regardless of sandbox spec.
  let ser = jsonCacheSerializer()
  let decoded = ser.decode(readFile(entryPath))
  check decoded.verdict == cvOk
  var entry = decoded.value
  entry.result.run.evidence.escapees = @[
    ptypes.ProcSnapshot(pid: 999999, ppid: 1, command: "r17-fake-escapee", rssBytes: 0)
  ]
  writeFile(entryPath, ser.encode(entry))

suite "r17 — recompute-invalidated hit whose rerun fails keeps cdmRecomputeMiss on the wire":

  test "cacheDecision stays recomputeMiss (not keyMiss) alongside cacheLookup ok":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_r17.nim", R17Fixture)

      # Run 1: live, invocation n=1, PASSES -- stores (cdmStored) under the
      # SAME closure/key this test keeps unchanged for the rest of the run.
      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.exitCode == 0
      check rr1.results.len == 1
      check rr1.results[0].outcome == oPassed
      check rr1.results[0].cacheDecision == cdmStored

      let entryPath = findStoredEntryPath(projectRoot)
      check entryPath.len > 0
      injectFakeEscapee(entryPath)

      # Run 2: plan-time consult finds the SAME entry (cvOk) but recompute-
      # invalidates it (fabricated escapee) -> cdmRecomputeMiss, a genuine
      # live rerun. The fixture's own counter (n=2 now) makes THIS
      # invocation fail -- rev 17's exact scenario.
      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.results.len == 1
      check rr2.results[0].outcome != oPassed  # sanity: the rerun genuinely failed

      # THE FIX: cacheDecision must stay recomputeMiss (not collapse to the
      # generic not-a-pass keyMiss), alongside a lookup that honestly
      # reports the entry WAS found (cvOk) -- before the fix these two
      # fields were an internally contradictory pair on the wire.
      check rr2.results[0].cacheDecision == cdmRecomputeMiss
      check rr2.results[0].cacheLookup == cvOk
