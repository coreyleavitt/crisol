## test_r29_verify_cache_pct_library.nim — code-review r29: --verify-cache-pct's
## config-file fallback is now resolved in api.planImpl's merge chain (the
## RunOptions -> Config -> default chain every sibling setting uses), not a
## CLI-only second `loadConfig` peek. This pins the LIBRARY path specifically
## (RunOptions/runTests, no crisol.nim/runMain involved at all) — the CLI's
## own coverage of the same crisol.kdl fallback already lives in
## test_b3c_verify_cache_cli.nim ("omitted --verify-cache-pct honors the KDL
## verify-cache-pct default").
##
## Properties pinned:
##   1. A library caller enabling verify-cache via `verifySample()` (bare —
##      pct's default is -1, "no override") on a project whose crisol.kdl
##      sets `verify-cache-pct 0` gets ZERO samples taken: the sole cache hit
##      is never re-executed, even though it WOULD diverge if it were
##      sampled. Proves the config-file value is honored purely through
##      runTests(), independent of the CLI.
##   2. The SAME project + an explicit `verifySample(pct = 100)` still wins
##      over the config-file `verify-cache-pct 0` — the hit IS sampled and
##      diverges. Proves a RunOptions-level override still beats the config
##      file through the library path too, mirroring --verify-cache-pct's
##      CLI-wins-over-config precedence.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r29_verify_cache_pct_library.nim

import std/[os, strutils, unittest]
import crisol/api
import crisol/types

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## file's cache entries / counter files never collide across cases —
  ## same recipe as test_b3c_verify_cache_cli.nim's freshProjectRoot.
  result = getTempDir() / ("crisol_r29_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")

## Flips its exit code on every REAL execution, tracked via a counter file
## written to the project root (spawnRunDirect's CWD). Odd invocation count
## -> exit 0 (so the first live run passes and stores); even -> exit 1.
## Identical recipe to test_b3b_verify_cache.nim / test_b3c_verify_cache_cli.nim.
const NondeterministicFixture = """
import std/[os, strutils]
const counterFile = "verify_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
if n mod 2 == 1: quit(0) else: quit(1)
"""

proc baseOpts(projectRoot: string; vc: VerifyCache): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,
    showProgress:   false,
    verifyCache:    vc,
  )

suite "r29 — library path (RunOptions/runTests) honors crisol.kdl's verify-cache-pct":

  test "verify-cache-pct 0 in crisol.kdl + bare verifySample() -> zero samples taken":
    let root = freshProjectRoot("pct_zero")
    defer: removeDir(root)
    let epPath = "tests/unit/test_flip.nim"
    writeFile(root / epPath, NondeterministicFixture)
    writeFile(root / "crisol.kdl", """
verify-cache-pct 0
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

    let rr1 = runTests(baseOpts(root, noVerify()))
    check rr1.exitCode == 0
    check rr1.results.len == 1
    check rr1.results[0].cacheDecision == cdmStored
    check readFile(root / "verify_counter.txt").strip() == "1"

    let rr2 = runTests(baseOpts(root, verifySample()))
    check rr2.exitCode == 0
    check rr2.results[0].cacheDecision == cdmHit
    check rr2.verifyDivergences.len == 0
    # Never re-executed by the verify pass: the counter stayed at 1 (if the
    # config-file fallback were dead and pct silently defaulted to 5, this
    # single-entry hit set would still be sampled -- max(1, 5*1/100) floors
    # to 1 -- and the counter would advance to 2).
    check readFile(root / "verify_counter.txt").strip() == "1"

  test "an explicit verifySample(pct = 100) still overrides the config-file 0":
    let root = freshProjectRoot("pct_override")
    defer: removeDir(root)
    let epPath = "tests/unit/test_flip.nim"
    writeFile(root / epPath, NondeterministicFixture)
    writeFile(root / "crisol.kdl", """
verify-cache-pct 0
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

    let rr1 = runTests(baseOpts(root, noVerify()))
    check rr1.exitCode == 0
    check readFile(root / "verify_counter.txt").strip() == "1"

    let rr2 = runTests(baseOpts(root, verifySample(pct = 100)))
    check rr2.exitCode == 0
    check rr2.results[0].cacheDecision == cdmHit
    check rr2.verifyDivergences.len == 1
    check readFile(root / "verify_counter.txt").strip() == "2"

echo "test_r29_verify_cache_pct_library: done"
