## test_c6_jsonout.nim — C6: regression serialization in run/v1 + render tag
##
## Coverage:
##   1. RunSchemaRevision is 13.
##   2. regressions array is present in output (empty when no regressions).
##   3. regressed=false results do NOT appear in regressions array.
##   4. regressed=true results appear in regressions array with correct fields.
##   5. Per-entrypoint "regressed" field is emitted (false by default).
##   6. Render: no [SLOW] tag when regressed=false.
##   7. Render: [SLOW] tag appears when regressed=true.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_c6_jsonout.nim

import std/[json, strutils, unittest]
import crisol/types
import crisol/jsonout
import crisol/render

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

suite "C6 — run/v1 regressions + render":

  test "RunSchemaRevision is 13":
    ## M8 bumped 5->6 for expanded CacheDecision wire vocabulary;
    ## M-report pass (a) bumped 6->7 for the additive top-level `compile` field;
    ## M-report pass (b1) bumped 7->8 for the additive top-level `reuseAlerts`
    ## array and the compile block's `ambientCcacheDetected`/`topUnits` fields;
    ## M-report pass (b2) bumped 8->9 for the compile block's
    ## `compileRegressions` array; Stage R pass R5b bumped 9->10 for the
    ## compile block's additive `objcache` sub-block; code-review R7 bumped
    ## 10->11 for each segment's additive `currentRunEntrypoints`/
    ## `sampleEntrypoints`/`lowConfidence` low-confidence-gate fields;
    ## RFC-0006 Stage R removal bumped 11->12 -- `compile.objcache` (rev 10)
    ## no longer appears in any document (Stage M + the RFC-0004 result
    ## cache are unchanged); issue #5 bumped 12->13 (cacheDecision
    ## "closureUnrecorded"); issue #10 bumped 13->14 (per-entrypoint `flags`);
    ## rfc-0007 A1b bumped 14->15 (advisory per-entrypoint `exit`/`cause`);
    ## rfc-0007 A1d-i bumped 15->16 (the run/v2 wire cutover);
    ## rfc-0007 A1d-ii bumped 16->17 (cacheDecision "recomputeMiss");
    ## rfc-0007 A7 bumped 17->18 (top-level `substrate` node);
    ## rfc-0005 B3c bumped 18->19 (top-level `verifyFails`);
    ## rfc-0005 B1c bumped 19->20 (per-result `keyDiff` under --explain-miss);
    ## rfc-0005 B2b bumped 20->21 (top-level `cacheStats` under --cache-stats).
    check RunSchemaRevision == 21

  test "regressions array present and empty when no regressions":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_a.nim"), durationMs: 100,
                       regressed: false, records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    check node.hasKey("regressions")
    check node["regressions"].kind == JArray
    check node["regressions"].len == 0

  test "regressed=false → not in regressions array":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_a.nim"), durationMs: 200,
                       regressed: false, perfBaselineUs: 0, perfThresholdUs: 0,
                       records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    check node["regressions"].len == 0

  test "regressed=true → entry in regressions array with correct fields":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_slow.nim"), durationMs: 500,
                       regressed: true,
                       perfBaselineUs: 100_000'i64,
                       perfThresholdUs: 115_000'i64,
                       records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    check node["regressions"].len == 1
    let r = node["regressions"][0]
    check r["path"].getStr == "tests/unit/test_slow.nim"
    check r["currentUs"].getBiggestInt == 500_000   # durationMs * 1000
    check r["baselineUs"].getBiggestInt == 100_000
    check r["thresholdUs"].getBiggestInt == 115_000

  test "per-entrypoint regressed field present (false by default)":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_b.nim"), durationMs: 50,
                       records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    let ep = node["entrypoints"][0]
    check ep.hasKey("regressed")
    check ep["regressed"].getBool == false

  test "per-entrypoint regressed field true when regressed":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_slow.nim"), durationMs: 500,
                       regressed: true,
                       perfBaselineUs: 100_000'i64,
                       perfThresholdUs: 115_000'i64,
                       records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    check node["entrypoints"][0]["regressed"].getBool == true

  test "multiple results: only regressed ones appear in regressions array":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_fast.nim"), durationMs: 100,
                       regressed: false, records: @[]),
      EntrypointResult(ep: makeEp("tests/unit/test_slow.nim"), durationMs: 900,
                       regressed: true,
                       perfBaselineUs: 200_000'i64,
                       perfThresholdUs: 250_000'i64,
                       records: @[]),
      EntrypointResult(ep: makeEp("tests/unit/test_medium.nim"), durationMs: 300,
                       regressed: false, records: @[]),
    ]
    let node = toJson(results, Summary(total: 3, passed: 3))
    check node["regressions"].len == 1
    check node["regressions"][0]["path"].getStr == "tests/unit/test_slow.nim"

  test "render: no [SLOW] tag when regressed=false":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_ok.nim"), durationMs: 100,
                       regressed: false, records: @[]),
    ]
    let s = render(results, Summary(total: 1, passed: 1), defaultOpts())
    check "[SLOW" notin s

  test "render: [SLOW] tag present when regressed=true":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_slow.nim"), durationMs: 500,
                       regressed: true,
                       perfBaselineUs: 100_000'i64,
                       perfThresholdUs: 115_000'i64,
                       records: @[]),
    ]
    let s = render(results, Summary(total: 1, passed: 1), defaultOpts())
    check "[SLOW:" in s
    check "500000µs" in s   # currentUs = durationMs*1000
    check "115000µs" in s   # thresholdUs

when isMainModule:
  echo "test_c6_jsonout: done"
