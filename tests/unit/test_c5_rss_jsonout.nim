## test_c5_rss_jsonout.nim — C5: peak RSS serialization + RunSchemaRevision bump
##
## Tests:
##   1. RunSchemaRevision is now 4 (bumped from 3 for the peakRssBytes field).
##   2. Each entrypoint node carries "peakRssBytes" as a JInt.
##   3. peakRssBytes defaults to 0 for default-constructed EntrypointResult.
##   4. peakRssBytes is serialized from EntrypointResult.peakRssBytes.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c5_rss_jsonout.nim

import std/[json, unittest]
import crisol/types
import crisol/jsonout

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

suite "C5 — run/v1 peakRssBytes serialization":

  test "RunSchemaRevision is at least 5 (bumped by M8 to 6 for expanded cacheDecision)":
    ## Rev 5 added top-level regressions array; rev 6 (M8) expanded cacheDecision vocab.
    check RunSchemaRevision >= 5

  test "each entrypoint carries peakRssBytes as integer field":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_foo.nim"),
                       outcome: oPassed, exitCode: 0, durationMs: 10,
                       peakRssBytes: 8_388_608'i64, records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    let ep = node["entrypoints"][0]
    check ep.hasKey("peakRssBytes")
    check ep["peakRssBytes"].kind == JInt
    check ep["peakRssBytes"].getBiggestInt == 8_388_608

  test "peakRssBytes defaults to 0 for default-constructed result":
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_bar.nim"),
                       outcome: oPassed, exitCode: 0, durationMs: 5,
                       records: @[]),
    ]
    let node = toJson(results, Summary(total: 1, passed: 1))
    let ep = node["entrypoints"][0]
    check ep.hasKey("peakRssBytes")
    check ep["peakRssBytes"].getBiggestInt == 0

  test "peakRssBytes is threaded through toJson from EntrypointResult field":
    ## Two results with distinct peakRssBytes — both serialize correctly.
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_a.nim"),
                       outcome: oPassed, exitCode: 0, durationMs: 10,
                       peakRssBytes: 4_000_000'i64, records: @[]),
      EntrypointResult(ep: makeEp("tests/unit/test_b.nim"),
                       outcome: oPassed, exitCode: 0, durationMs: 20,
                       peakRssBytes: 12_000_000'i64, records: @[]),
    ]
    let node = toJson(results, Summary(total: 2, passed: 2))
    check node["entrypoints"][0]["peakRssBytes"].getBiggestInt == 4_000_000
    check node["entrypoints"][1]["peakRssBytes"].getBiggestInt == 12_000_000

  test "schemaRevision in output equals RunSchemaRevision (currently 6)":
    let node = toJson(@[], Summary())
    check node["schemaRevision"].getInt == RunSchemaRevision

when isMainModule:
  echo "test_c5_rss_jsonout done"
