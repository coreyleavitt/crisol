## test_b2b_cache_stats_cli.nim — RFC-0005 B2b E2E ("E2E-B stats half"):
## `--cache-stats` through the REAL entry point (`crisol run`), not the
## library facade directly (mirrors test_b1c_explain_miss_cli.nim /
## test_b3c_verify_cache_cli.nim's own pattern).
##
## Properties pinned (RFC-0005 line 561, B2b; line 542, E2E-B):
##   1. A cold run (--cache-stats --json) shows misses > 0, hitPct == 0.0,
##      a nonzero `cacheStats.total`, and `schemaRevision == 26` (rev 21
##      B2b's original cacheStats object + rev 22's additive `localErrors`
##      (RFC-0005 code-review D1) + rev 23's additive `trustRejects`/
##      `corruptReads` (RFC-0005 code-review R2-T8b) + rev 24's additive
##      top-level `lateOrphansReaped` (rfc-0007 B1) + rev 25's additive
##      top-level `trackedRoots` array (RFC-0009 A2)).
##   2. A warm rerun of the SAME entrypoint (--cache-stats --json) shows
##      hits > 0 and hitPct > 0 -- sane values proving the aggregation is
##      wired to a REAL run, not a stub.
##   3. In --json mode the human summary line goes to stderr ("cache: ...")
##      while stdout stays parseable JSON.
##   4. In human mode (no --json) the same summary line appears on stdout.
##   5. Without --cache-stats: no `cacheStats` key in the JSON document, and
##      no "cache:" summary line anywhere (additive/off-by-default).
##
## The per-tier 100%-error warning (erroredTiers/tierErrorWarning,
## cachetelemetry.nim) is covered by pure unit tests in
## tests/unit/test_cachetelemetry.nim instead of here: forcing a REAL "l1
## offline" condition through a full `crisol run` requires blocking either
## the local-fs backend's outer cache root (which rfc-0006's nimcache-
## persistence ALSO nests inside, breaking compilation, not just the result
## cache) or its version subdirectory (which surfaces a pre-existing,
## unrelated bug -- see this slice's final report: `createDir` raises
## `IOError` on this toolchain, not `OSError`, so the `except OSError`
## guards around a blocked version dir in cachelocalfs.put/resultcache.
## storeCachedAt do not catch it). Neither makes a good CLI-level fixture.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_b2b_cache_stats_cli.nim

import std/[json, os, strutils, unittest]
import crisol   # runMain
import ../support/capture

# ---------------------------------------------------------------------------
# Helpers (mirrors test_b1c_explain_miss_cli.nim's freshProjectRoot/captureBoth)
# ---------------------------------------------------------------------------

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_b2b_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

const PassFixture = "quit(0)\n"

# ---------------------------------------------------------------------------
# 1 + 2 — cold run then warm rerun: sane, real values
# ---------------------------------------------------------------------------

suite "B2b CLI — --cache-stats --json: cold run then warm rerun":

  test "cold run: misses > 0, hitPct 0.0; warm rerun: hits > 0, hitPct > 0":
    let root = freshProjectRoot("cold_warm")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    # Run 1: cold -- nothing cached yet, this consult is a genuine miss.
    var code1 = 0
    let (out1, _) = captureBoth(proc() =
      code1 = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                        "--cache-stats", "--json"]))
    check code1 == 0
    let doc1 = parseJson(out1)
    check doc1["schemaRevision"].getInt == 26  # rev 25: RFC-0009 A2's top-level trackedRoots array
    check doc1.hasKey("cacheStats")
    let cs1 = doc1["cacheStats"]
    check cs1["misses"].getInt > 0
    check cs1["l1Hits"].getInt == 0
    check cs1["hitPct"].getFloat == 0.0
    check cs1["total"].getInt > 0
    # RFC-0005 code-review R2-T8b: a genuine cold miss (no cache-trust
    # configured in this fixture) must read both distinguishing counters
    # zero -- the CLI-level negative control for distinguishability.
    check cs1["trustRejects"].getInt == 0
    check cs1["corruptReads"].getInt == 0
    check cs1["localErrors"].getInt == 0
    check cs1["remoteErrors"].getInt == 0

    # Run 2: warm -- served from cache; a genuine hit this time.
    var code2 = 0
    let (out2, _) = captureBoth(proc() =
      code2 = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                        "--cache-stats", "--json"]))
    check code2 == 0
    let doc2 = parseJson(out2)
    let cs2 = doc2["cacheStats"]
    check cs2["l1Hits"].getInt > 0
    check cs2["hitPct"].getFloat > 0.0
    check cs2["misses"].getInt == 0

# ---------------------------------------------------------------------------
# 3 — --json mode: human line on stderr, stdout stays parseable
# ---------------------------------------------------------------------------

suite "B2b CLI — --cache-stats --json: human line on stderr only":

  test "the 'cache: ...' summary line appears in stderr, never in stdout":
    let root = freshProjectRoot("json_routing")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    var code = 0
    let (outText, errText) = captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                       "--cache-stats", "--json"]))
    check code == 0
    check "cache:" in errText
    check "hit rate" in errText
    # stdout carries ONLY the JSON document -- parseable, no stray text.
    discard parseJson(outText)
    check "cache:" notin outText

# ---------------------------------------------------------------------------
# 4 — human mode: the summary line appears on stdout
# ---------------------------------------------------------------------------

suite "B2b CLI — --cache-stats, human mode: summary line on stdout":

  test "the 'cache: ...' summary line appears on stdout (no --json)":
    let root = freshProjectRoot("human")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    var code = 0
    let (outText, _) = captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1", "--cache-stats"]))
    check code == 0
    check "cache:" in outText
    check "hit rate" in outText

# ---------------------------------------------------------------------------
# 5 — without --cache-stats: nothing surfaces (default off, additive)
# ---------------------------------------------------------------------------

suite "B2b CLI — without --cache-stats: no cacheStats field, no summary line":

  test "no 'cacheStats' key in JSON, no 'cache:' line anywhere":
    let root = freshProjectRoot("off")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    var jsonCode = 0
    let (jsonOut, jsonErr) = captureBoth(proc() =
      jsonCode = runMain(@["run", "--config", cfgPath, "--jobs", "1", "--json"]))
    check jsonCode == 0
    let doc = parseJson(jsonOut)
    check not doc.hasKey("cacheStats")
    check "cache:" notin jsonErr
    check "cache:" notin jsonOut

    var humanCode = 0
    let (humanOut, _) = captureBoth(proc() =
      humanCode = runMain(@["run", "--config", cfgPath, "--jobs", "1"]))
    check humanCode == 0
    check "cache:" notin humanOut

when isMainModule:
  echo "test_b2b_cache_stats_cli: done"
