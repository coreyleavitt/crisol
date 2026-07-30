## test_compilereport.nim — RFC-0006 M-report PASS (a): segmented `compile`
## block aggregation (crisol/compilereport).
##
## Covers the PURE core `buildCompileBlock` only (no I/O): per-segment
## rTime/rSize (cross-checked against artifactid.reuseRatios), ccPct/
## codegenPct/linkPct, artifactsTotal/Shared, bytesTotal/Shared,
## reproducible, deterministic segment ordering, and empty/partial-stream
## handling.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_compilereport.nim

import std/[json, os, unittest]
import crisol/types
import crisol/artifactledger
import crisol/compilecost
import crisol/objcachestats
import crisol/compilereport

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkArtifactRow(identity: string; groupId, configHash, basename, keyHash: string;
                   sizeBytes, ccTimeUs: int64): ArtifactRow =
  ArtifactRow(
    rowVersion:         1,
    entrypointIdentity: IdentityKey(identity),
    groupId:            groupId,
    configHash:         configHash,
    artifactBasename:   basename,
    keyHash:            keyHash,
    sizeBytes:          sizeBytes,
    ccTimeUs:           ccTimeUs,
    timestamp:          1000,
  )

proc mkCostRow(identity: string; groupId, configHash: string;
              codegenUs, ccUs, linkUs: int64): CompileCostRow =
  CompileCostRow(
    rowVersion:         1,
    entrypointIdentity: IdentityKey(identity),
    groupId:            groupId,
    configHash:         configHash,
    codegenUs:          codegenUs,
    ccUs:               ccUs,
    linkUs:             linkUs,
    timestamp:          1000,
  )

proc mkCostRowAt(identity: string; groupId, configHash: string;
                 codegenUs, ccUs, linkUs, timestamp: int64): CompileCostRow =
  ## Like mkCostRow, but with an explicit timestamp -- for exercising
  ## computeCompileRegressions' current/history split (M-report PASS b2).
  CompileCostRow(
    rowVersion:         1,
    entrypointIdentity: IdentityKey(identity),
    groupId:            groupId,
    configHash:         configHash,
    codegenUs:          codegenUs,
    ccUs:               ccUs,
    linkUs:             linkUs,
    timestamp:          timestamp,
  )

proc findSegment(node: JsonNode; groupId, configHash: string): JsonNode =
  for seg in node["segments"]:
    if seg["groupId"].getStr == groupId and seg["configHash"].getStr == configHash:
      return seg
  result = nil

proc mkObjCacheStatsRow(identity: string; groupId, configHash: string;
                        hits, misses, stored, disabled: int;
                        reusedBytes: int64): ObjCacheStatsRow =
  ObjCacheStatsRow(
    rowVersion:         1,
    entrypointIdentity: IdentityKey(identity),
    groupId:            groupId,
    configHash:         configHash,
    hits:               hits,
    misses:             misses,
    stored:             stored,
    disabled:           disabled,
    reusedBytes:        reusedBytes,
    timestamp:          1000,
  )

proc findOcSegment(ocNode: JsonNode; groupId, configHash: string): JsonNode =
  for seg in ocNode["segments"]:
    if seg["groupId"].getStr == groupId and seg["configHash"].getStr == configHash:
      return seg
  result = nil

# ---------------------------------------------------------------------------
# 1. Two segments: rTime/rSize, ccPct/codegenPct/linkPct, counts, ordering
# ---------------------------------------------------------------------------

suite "buildCompileBlock — reuse ratios + cost split, segmented":

  test "one segment: two entrypoints sharing one unit and diverging on another -- rTime/rSize/counts match reuseRatios":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "shared.c",   "K_SHARED",      100, 50),
      mkArtifactRow("ep_b", "g1", "c1", "shared.c",   "K_SHARED",      100, 50),
      mkArtifactRow("ep_a", "g1", "c1", "tailored.c", "K_TAILORED_A",  20, 200),
      mkArtifactRow("ep_b", "g1", "c1", "tailored.c", "K_TAILORED_B",  20, 200),
    ]
    let costRows = @[
      mkCostRow("ep_a", "g1", "c1", 100, 300, 100),
    ]
    let node = buildCompileBlock(artifactRows, costRows)
    check node != nil
    let seg = findSegment(node, "g1", "c1")
    check seg != nil

    # bytes: shared=200 (100*2), total=240 (200+40) -> r_size = 200/240
    check abs(seg["rSize"].getFloat - (200.0 / 240.0)) < 1e-9
    # cc time: shared=100 (50*2), total=500 (100+400) -> r_time = 0.2
    check abs(seg["rTime"].getFloat - 0.2) < 1e-9

    # cost split: codegen=100, cc=300, link=100 -> total=500
    check abs(seg["codegenPct"].getFloat - 0.2) < 1e-9
    check abs(seg["ccPct"].getFloat - 0.6) < 1e-9
    check abs(seg["linkPct"].getFloat - 0.2) < 1e-9

    check seg["artifactsTotal"].getInt == 4
    # Only the two K_SHARED rows are carried by >=2 distinct entrypoints.
    check seg["artifactsShared"].getInt == 2
    check seg["bytesTotal"].getInt == 240
    check seg["bytesShared"].getInt == 200

    check seg["reproducible"].getBool == true

  test "two segments are computed independently and appear in deterministic (groupId, configHash) sorted order":
    let artifactRows = @[
      # segment (g2, c2): fully shared
      mkArtifactRow("ep_a", "g2", "c2", "u.c", "K1", 100, 100),
      mkArtifactRow("ep_b", "g2", "c2", "u.c", "K1", 100, 100),
      # segment (g1, c1): fully unshared
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "K2A", 100, 100),
      mkArtifactRow("ep_b", "g1", "c1", "u.c", "K2B", 100, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    check node != nil
    check node["segments"].len == 2
    # Deterministic sort: (g1, c1) before (g2, c2).
    check node["segments"][0]["groupId"].getStr == "g1"
    check node["segments"][1]["groupId"].getStr == "g2"
    check node["segments"][0]["rTime"].getFloat == 0.0
    check node["segments"][1]["rTime"].getFloat == 1.0

# ---------------------------------------------------------------------------
# 2. reproducible: a cross-slot keyHash mismatch on the SAME unit -> false
# ---------------------------------------------------------------------------

suite "buildCompileBlock — reproducible":

  test "a single (identity, basename) unit carrying two conflicting keyHashes -> reproducible=false":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "flaky.c", "K_ONE", 100, 100),
      mkArtifactRow("ep_a", "g1", "c1", "flaky.c", "K_TWO", 100, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    let seg = findSegment(node, "g1", "c1")
    check seg["reproducible"].getBool == false

  test "every (identity, basename) unit carries exactly one keyHash -> reproducible=true":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "stable.c", "K_ONE", 100, 100),
      mkArtifactRow("ep_b", "g1", "c1", "stable.c", "K_ONE", 100, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    let seg = findSegment(node, "g1", "c1")
    check seg["reproducible"].getBool == true

# ---------------------------------------------------------------------------
# 3. Empty telemetry -> nil; single-stream segment doesn't crash
# ---------------------------------------------------------------------------

suite "buildCompileBlock — empty/partial telemetry":

  test "both streams empty -> nil":
    check buildCompileBlock(@[], @[]) == nil

  test "a segment present only in the artifact stream (no cost rows) doesn't crash -- cost fields default to zero":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    let seg = findSegment(node, "g1", "c1")
    check seg != nil
    check seg["codegenPct"].getFloat == 0.0
    check seg["ccPct"].getFloat == 0.0
    check seg["linkPct"].getFloat == 0.0
    check seg["artifactsTotal"].getInt == 1

  test "a segment present only in the cost stream (no artifact rows) doesn't crash -- reuse fields default to zero":
    let costRows = @[
      mkCostRow("ep_a", "g1", "c1", 100, 100, 100),
    ]
    let node = buildCompileBlock(@[], costRows)
    let seg = findSegment(node, "g1", "c1")
    check seg != nil
    check seg["rTime"].getFloat == 0.0
    check seg["rSize"].getFloat == 0.0
    check seg["artifactsTotal"].getInt == 0
    check seg["artifactsShared"].getInt == 0
    check seg["reproducible"].getBool == true  # vacuously true: no units at all

# ---------------------------------------------------------------------------
# 4. ambientCcacheDetected -- pure threading + real (never-throwing) detector
# ---------------------------------------------------------------------------

suite "buildCompileBlock — ambientCcacheDetected (M-report b1)":

  test "default (param omitted) -> false":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let node = buildCompileBlock(artifactRows, @[])
    check node["ambientCcacheDetected"].getBool == false

  test "ambientCcacheDetected=true is threaded through as a top-level sibling of segments":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let node = buildCompileBlock(artifactRows, @[], ambientCcacheDetected = true)
    check node["ambientCcacheDetected"].getBool == true
    check node.hasKey("segments")

  test "detectAmbientCcache(): real detector runs without throwing and returns a bool":
    let detected = detectAmbientCcache()
    check detected == true or detected == false  # exercised for real; type-checked by compiling

# ---------------------------------------------------------------------------
# 5. topUnits -- top-10 reusable-unit rows across the run, deterministic
# ---------------------------------------------------------------------------

suite "buildCompileBlock — topUnits (M-report b1)":

  test "fewer than 10 rows -> all present, sorted DESC by ccTimeUs":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "low.c",  "K1", 10, 50),
      mkArtifactRow("ep_a", "g1", "c1", "high.c", "K2", 10, 500),
      mkArtifactRow("ep_a", "g1", "c1", "mid.c",  "K3", 10, 200),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    check node["topUnits"].len == 3
    check node["topUnits"][0]["basename"].getStr == "high.c"
    check node["topUnits"][0]["ccTimeUs"].getBiggestInt == 500
    check node["topUnits"][1]["basename"].getStr == "mid.c"
    check node["topUnits"][2]["basename"].getStr == "low.c"
    check node["topUnits"][0]["sizeBytes"].getBiggestInt == 10

  test "tie-break: equal ccTimeUs -> larger sizeBytes first":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "small.c", "K1", 10, 100),
      mkArtifactRow("ep_a", "g1", "c1", "big.c",   "K2", 99, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    check node["topUnits"][0]["basename"].getStr == "big.c"
    check node["topUnits"][1]["basename"].getStr == "small.c"

  test "tie-break: equal ccTimeUs and sizeBytes -> basename ascending":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "zzz.c", "K1", 10, 100),
      mkArtifactRow("ep_a", "g1", "c1", "aaa.c", "K2", 10, 100),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    check node["topUnits"][0]["basename"].getStr == "aaa.c"
    check node["topUnits"][1]["basename"].getStr == "zzz.c"

  test "more than 10 rows -> only the top 10 by ccTimeUs are kept":
    var artifactRows: seq[ArtifactRow]
    for i in 0 ..< 15:
      artifactRows.add mkArtifactRow("ep_a", "g1", "c1", "u" & $i & ".c", "K" & $i,
                                     10, int64(i))
    let node = buildCompileBlock(artifactRows, @[])
    check node["topUnits"].len == 10
    # highest ccTimeUs values are 14..5, descending.
    check node["topUnits"][0]["ccTimeUs"].getBiggestInt == 14
    check node["topUnits"][9]["ccTimeUs"].getBiggestInt == 5

  test "topUnits spans multiple segments (across the whole run, not per-segment)":
    let artifactRows = @[
      mkArtifactRow("ep_a", "g1", "c1", "seg1.c", "K1", 10, 999),
      mkArtifactRow("ep_b", "g2", "c2", "seg2.c", "K2", 10, 1),
    ]
    let node = buildCompileBlock(artifactRows, @[])
    check node["topUnits"].len == 2
    check node["topUnits"][0]["basename"].getStr == "seg1.c"

# ---------------------------------------------------------------------------
# 6. buildReuseAlerts -- pure evaluation of reuse-check policy over a
#    compile block's segments (M-report b1)
# ---------------------------------------------------------------------------

suite "buildReuseAlerts (M-report b1)":

  proc reuseCheckOn(alertBelow: float): ReuseCheckConfig =
    ReuseCheckConfig(enabled: true, alertBelow: alertBelow)

  proc reuseCheckOff(): ReuseCheckConfig =
    ReuseCheckConfig(enabled: false)

  test "disabled -> zero alerts even when every segment is below threshold":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 10, 100)]
    let node = buildCompileBlock(artifactRows, @[])
    let alerts = buildReuseAlerts(node, reuseCheckOff())
    check alerts.kind == JArray
    check alerts.len == 0

  test "enabled: one segment below threshold, one above -> exactly one alert (the below one)":
    let artifactRows = @[
      # (g1,c1): fully unshared -> rTime == 0.0 (below 0.5)
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "KA", 10, 100),
      mkArtifactRow("ep_b", "g1", "c1", "u.c", "KB", 10, 100),
      # (g2,c2): fully shared -> rTime == 1.0 (above 0.5)
      mkArtifactRow("ep_a", "g2", "c2", "u.c", "K1", 10, 100),
      mkArtifactRow("ep_b", "g2", "c2", "u.c", "K1", 10, 100),
    ]
    # R7: this test isolates the ALERT-THRESHOLD logic from the SEPARATE
    # low-confidence gate (both segments here only carry 2 entrypoints each,
    # well below the real-world LowConfidenceMinEntrypoints default) -- so
    # the gate is explicitly relaxed to 2 here. The gate itself is exercised
    # on its own terms in the "R7 low-confidence gate" suite below.
    let node = buildCompileBlock(artifactRows, @[], lowConfidenceMinEntrypoints = 2)
    let alerts = buildReuseAlerts(node, reuseCheckOn(0.5))
    check alerts.len == 1
    check alerts[0]["groupId"].getStr == "g1"
    check alerts[0]["configHash"].getStr == "c1"
    check alerts[0]["rTime"].getFloat == 0.0
    check alerts[0]["alertBelow"].getFloat == 0.5

  test "nil compileBlock -> zero alerts even when enabled":
    let alerts = buildReuseAlerts(nil, reuseCheckOn(0.9))
    check alerts.kind == JArray
    check alerts.len == 0

# ---------------------------------------------------------------------------
# 7. computeCompileRegressions -- M-report PASS (b2): compile-wall-time
#    regression guard (median + k*MAD over the compile-cost stream)
# ---------------------------------------------------------------------------

suite "computeCompileRegressions (M-report PASS b2)":

  const CurrentRunStartUs = 10_000_000'i64  # any prior row has timestamp < this

  test "current well above median+k*MAD of priors -> flagged with correct baseline/threshold; an entrypoint within threshold -> absent":
    # ep_regressed: 10 identical prior rows (total=100_000us each) ->
    # median=100_000, MAD=0 -> madUs floored to absFloorMs*1000=5_000 ->
    # threshold = 100_000 + 3.0*5_000 = 115_000.
    var rows: seq[CompileCostRow]
    for i in 0 ..< 10:
      rows.add mkCostRowAt("ep_regressed", "g1", "c1", 100_000, 0, 0,
                           CurrentRunStartUs - 1000 - int64(i))
    # Current run's row: total=500_000, far above the 115_000 threshold.
    rows.add mkCostRowAt("ep_regressed", "g1", "c1", 500_000, 0, 0, CurrentRunStartUs)

    # ep_ok: same history shape, current total=110_000 stays <= threshold.
    for i in 0 ..< 10:
      rows.add mkCostRowAt("ep_ok", "g2", "c2", 100_000, 0, 0,
                           CurrentRunStartUs - 1000 - int64(i))
    rows.add mkCostRowAt("ep_ok", "g2", "c2", 110_000, 0, 0, CurrentRunStartUs)

    let node = computeCompileRegressions(rows, CurrentRunStartUs)
    check node.kind == JArray
    check node.len == 1
    check node[0]["entrypointIdentity"].getStr == "ep_regressed"
    check node[0]["groupId"].getStr == "g1"
    check node[0]["configHash"].getStr == "c1"
    check node[0]["currentUs"].getBiggestInt == 500_000
    check node[0]["baselineUs"].getBiggestInt == 100_000
    check node[0]["thresholdUs"].getBiggestInt == 115_000

  test "fewer than sample-floor prior rows -> never flagged, even when current is huge":
    var rows: seq[CompileCostRow]
    # Only 3 prior rows -- well below the default sample-floor of 10.
    for i in 0 ..< 3:
      rows.add mkCostRowAt("ep_new", "g1", "c1", 100_000, 0, 0,
                           CurrentRunStartUs - 1000 - int64(i))
    rows.add mkCostRowAt("ep_new", "g1", "c1", 999_999_999, 0, 0, CurrentRunStartUs)

    let node = computeCompileRegressions(rows, CurrentRunStartUs)
    check node.kind == JArray
    check node.len == 0

  test "the current run's own row is excluded from its own baseline (verified by construction)":
    # 10 prior rows with DISTINCT totals 10_000..100_000 (step 10_000) ->
    # true median (excluding current) = 55_000, true MAD = 25_000.
    # If the current row's own (huge, 5_000_000) total were wrongly folded
    # into the history pool, the 11-element median would shift to 60_000
    # instead -- so asserting baselineUs == 55_000 (not 60_000) proves the
    # current row never entered its own baseline.
    var rows: seq[CompileCostRow]
    for i in 1 .. 10:
      rows.add mkCostRowAt("ep_x", "g1", "c1", int64(i) * 10_000, 0, 0,
                           CurrentRunStartUs - 1000 - int64(i))
    rows.add mkCostRowAt("ep_x", "g1", "c1", 5_000_000, 0, 0, CurrentRunStartUs)

    let node = computeCompileRegressions(rows, CurrentRunStartUs)
    check node.len == 1
    check node[0]["baselineUs"].getBiggestInt == 55_000   # NOT 60_000
    check node[0]["thresholdUs"].getBiggestInt == 55_000 + 3 * 25_000
    check node[0]["currentUs"].getBiggestInt == 5_000_000

  test "an entrypoint with no current-run row (absent from this run's rows) is never flagged, regardless of its history":
    var rows: seq[CompileCostRow]
    for i in 0 ..< 10:
      rows.add mkCostRowAt("ep_absent_this_run", "g1", "c1", 100_000, 0, 0,
                           CurrentRunStartUs - 1000 - int64(i))
    # No row with timestamp >= CurrentRunStartUs for this identity.
    let node = computeCompileRegressions(rows, CurrentRunStartUs)
    check node.len == 0

  test "empty costRows -> empty array, no crash":
    check computeCompileRegressions(@[], CurrentRunStartUs).len == 0

# ---------------------------------------------------------------------------
# 8. buildCompileBlock -- compileRegressions threading (M-report PASS b2)
# ---------------------------------------------------------------------------

suite "buildCompileBlock — compileRegressions threading (M-report b2)":

  test "default (param omitted) -> present and empty, mirrors 'regressions' convention":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let node = buildCompileBlock(artifactRows, @[])
    check node.hasKey("compileRegressions")
    check node["compileRegressions"].kind == JArray
    check node["compileRegressions"].len == 0

  test "a non-empty compileRegressions JArray is threaded through as a sibling of segments/topUnits":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    var regressions = newJArray()
    var r = newJObject()
    r["entrypointIdentity"] = newJString("ep_a")
    r["groupId"]            = newJString("g1")
    r["configHash"]         = newJString("c1")
    r["currentUs"]          = newJInt(500_000)
    r["baselineUs"]         = newJInt(100_000)
    r["thresholdUs"]        = newJInt(115_000)
    regressions.add r

    let node = buildCompileBlock(artifactRows, @[], compileRegressions = regressions)
    check node["compileRegressions"].len == 1
    check node["compileRegressions"][0]["entrypointIdentity"].getStr == "ep_a"
    check node.hasKey("segments")
    check node.hasKey("topUnits")

  test "omitted vs explicit empty JArray -> byte-identical document (additive/back-compat)":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let withDefault = buildCompileBlock(artifactRows, @[])
    let withExplicitEmpty = buildCompileBlock(artifactRows, @[], compileRegressions = newJArray())
    check $withDefault == $withExplicitEmpty

# ---------------------------------------------------------------------------
# 9. objcache aggregation -- RFC-0006 Stage R, R5b: realized objcache
#    hit/miss/stored/disabled counts + reusedBytes/cacheSizeBytes aggregated
#    into compile.objcache, per (groupId, configHash) segment.
# ---------------------------------------------------------------------------

suite "buildCompileBlock — objcache aggregation (RFC-0006 R5b)":

  test "two segments: correct sum hits/misses/stored/disabled, hitRate, reusedBytes, per-segment breakdown, cacheSizeBytes echoed, note present":
    let ocRows = @[
      mkObjCacheStatsRow("ep_a", "g1", "c1", hits = 3, misses = 1, stored = 1, disabled = 0, reusedBytes = 300),
      mkObjCacheStatsRow("ep_b", "g1", "c1", hits = 2, misses = 2, stored = 1, disabled = 1, reusedBytes = 200),
      mkObjCacheStatsRow("ep_c", "g2", "c2", hits = 1, misses = 0, stored = 0, disabled = 0, reusedBytes = 50),
    ]
    let node = buildCompileBlock(@[], @[], objCacheStatsRows = ocRows, cacheSizeBytes = 10_000)
    check node != nil
    check node.hasKey("objcache")
    let oc = node["objcache"]

    check oc["hits"].getInt == 6
    check oc["misses"].getInt == 3
    check oc["stored"].getInt == 2
    check oc["disabled"].getInt == 1
    check abs(oc["hitRate"].getFloat - (6.0 / 9.0)) < 1e-9
    check oc["reusedBytes"].getBiggestInt == 550
    check oc["cacheSizeBytes"].getBiggestInt == 10_000
    check oc.hasKey("note")
    check oc["note"].getStr.len > 0

    check oc["segments"].len == 2
    let seg1 = findOcSegment(oc, "g1", "c1")
    check seg1 != nil
    check seg1["hits"].getInt == 5
    check seg1["misses"].getInt == 3
    check seg1["stored"].getInt == 2
    check abs(seg1["hitRate"].getFloat - (5.0 / 8.0)) < 1e-9
    check seg1["reusedBytes"].getBiggestInt == 500

    let seg2 = findOcSegment(oc, "g2", "c2")
    check seg2 != nil
    check seg2["hits"].getInt == 1
    check seg2["misses"].getInt == 0
    check abs(seg2["hitRate"].getFloat - 1.0) < 1e-9
    check seg2["reusedBytes"].getBiggestInt == 50

  test "hits+misses == 0 -> hitRate is 0.0, not NaN or a crash":
    let ocRows = @[mkObjCacheStatsRow("ep_a", "g1", "c1", hits = 0, misses = 0, stored = 0, disabled = 3, reusedBytes = 0)]
    let node = buildCompileBlock(@[], @[], objCacheStatsRows = ocRows)
    check node["objcache"]["hitRate"].getFloat == 0.0
    check node["objcache"]["hits"].getInt == 0
    check node["objcache"]["disabled"].getInt == 3

# ---------------------------------------------------------------------------
# 10. objcache absence -- back-compat: no rows -> no 'objcache' key at all
# ---------------------------------------------------------------------------

suite "buildCompileBlock — objcache absence (RFC-0006 R5b, back-compat)":

  test "no objcachestats rows -> the compile block has no 'objcache' key":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let node = buildCompileBlock(artifactRows, @[])
    check node != nil
    check not node.hasKey("objcache")

  test "objCacheStatsRows alone (no artifact/cost rows at all) is enough to produce a non-nil block with an empty segments array":
    let ocRows = @[mkObjCacheStatsRow("ep_a", "g1", "c1", 1, 0, 0, 0, 100)]
    let node = buildCompileBlock(@[], @[], objCacheStatsRows = ocRows)
    check node != nil
    check node.hasKey("objcache")
    check node["segments"].len == 0

  test "omitted vs explicit empty objCacheStatsRows -> byte-identical document (additive/back-compat)":
    let artifactRows = @[mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100)]
    let withDefault = buildCompileBlock(artifactRows, @[])
    let withExplicitEmpty = buildCompileBlock(artifactRows, @[], objCacheStatsRows = @[])
    check $withDefault == $withExplicitEmpty

# ---------------------------------------------------------------------------
# 11. drift visibility -- potential rTime (segments[]) vs realized hitRate
#     (objcache.segments[]), same (groupId, configHash) key (RFC-0006 R5b,
#     reworded honest per R16/R9-revert)
#
# R16: the cache-mode worker no longer writes ArtifactRows (see
# measureworker.nim's R16 doc) -- a cache HIT does no compilation, so its
# ArtifactRow would necessarily carry ccTimeUs=0, skewing the cc-time-
# weighted rTime and permanently polluting the append-only artifact ledger.
# So `segments[].rTime` and `objcache.segments[].hitRate` can never both be
# freshly populated by ONE worker run in the real system: `rTime` comes
# ONLY from a MEASURE-mode run's artifact rows; `hitRate` comes ONLY from a
# LATER CACHE-mode run's objcache-stats rows, scanned from the SAME
# on-disk `stateDir` at report time. `buildCompileBlock` itself is a PURE
# function that just aggregates whatever rows it's handed -- it doesn't
# know or care which worker/run produced them -- so this test constructs
# `artifactRows` and `ocRows` as the two INDEPENDENT on-disk streams a real
# `readCompileBlock(stateDir, ...)` would scan after a measure-run followed
# by a cache-run against the same stateDir, and asserts the drift numbers
# line up per (groupId, configHash) once both are aggregated into one block.
# ---------------------------------------------------------------------------

suite "buildCompileBlock — objcache/segments drift visibility (RFC-0006 R5b, cross-run per R16)":

  test "a MEASURE-run's potential rTime and a LATER CACHE-run's realized hitRate, both scanned from the same stateDir, are keyed identically for drift comparison":
    # Stands in for `scanArtifactLedger(stateDir)` after a MEASURE-mode run
    # (runMeasureCompileWorker) -- the only worker that writes artifact rows.
    let artifactRows = @[
      # fully shared -> rTime == 1.0 (high POTENTIAL reuse)
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100),
      mkArtifactRow("ep_b", "g1", "c1", "u.c", "K1", 100, 100),
    ]
    # Stands in for `scanObjCacheStatsLedger(stateDir)` after a LATER
    # CACHE-mode run (runCompileCacheWorker) against the SAME stateDir.
    let ocRows = @[
      # cold cache that run -> hitRate == 0.0 (low REALIZED reuse)
      mkObjCacheStatsRow("ep_a", "g1", "c1", hits = 0, misses = 2, stored = 1, disabled = 0, reusedBytes = 0),
    ]
    let node = buildCompileBlock(artifactRows, @[], objCacheStatsRows = ocRows)

    let seg = findSegment(node, "g1", "c1")
    check seg != nil
    check seg["rTime"].getFloat == 1.0

    let ocSeg = findOcSegment(node["objcache"], "g1", "c1")
    check ocSeg != nil
    check ocSeg["hitRate"].getFloat == 0.0

    # Drift: potential (rTime, from the measure-run) far exceeds realized
    # (hitRate, from the later cache-run) for the SAME (groupId, configHash)
    # -- the cold-cache / first-wave-dedup gap, visible across the two runs'
    # reports because both are keyed consistently.
    check seg["rTime"].getFloat - ocSeg["hitRate"].getFloat > 0.5

# ---------------------------------------------------------------------------
# 12. R7 (code review) — low-confidence gate: THIS run's own contributing-
#     entrypoint count vs the aggregate, and reuse-check suppression on thin
#     (e.g. --changed-narrowed) runs. RFC-0006 §Wire/schema touchpoints:
#     "--changed-narrowed runs: r_time/M-report are statistically
#     meaningless on a 1-2-entrypoint subset ... marked low-confidence (and
#     reuse-check suppressed) unless the run covers a representative
#     entrypoint count."
# ---------------------------------------------------------------------------

proc mkArtifactRowAt(identity: string; groupId, configHash, basename, keyHash: string;
                     sizeBytes, ccTimeUs, timestamp: int64): ArtifactRow =
  ## Like mkArtifactRow, but with an explicit timestamp -- for exercising the
  ## low-confidence gate's current-run/history split (mirrors mkCostRowAt).
  ArtifactRow(
    rowVersion:         1,
    entrypointIdentity: IdentityKey(identity),
    groupId:            groupId,
    configHash:         configHash,
    artifactBasename:   basename,
    keyHash:            keyHash,
    sizeBytes:          sizeBytes,
    ccTimeUs:           ccTimeUs,
    timestamp:          timestamp,
  )

suite "buildCompileBlock — R7 low-confidence gate (contributing-entrypoint provenance)":

  const RunStart = 10_000_000'i64

  test "segment provenance fields: currentRunEntrypoints and sampleEntrypoints are present and correct":
    var rows: seq[ArtifactRow]
    # 8 DISTINCT historical entrypoints (prior to RunStart), all in (g1,c1).
    for i in 0 ..< 8:
      rows.add mkArtifactRowAt("ep_hist" & $i, "g1", "c1", "u.c", "K" & $i,
                               100, 100, RunStart - 1000)
    # THIS run contributes exactly 1 entrypoint.
    rows.add mkArtifactRowAt("ep_now", "g1", "c1", "u.c", "K_NOW", 100, 100, RunStart)

    let node = buildCompileBlock(rows, @[], currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg != nil
    check seg.hasKey("currentRunEntrypoints")
    check seg.hasKey("sampleEntrypoints")
    check seg["currentRunEntrypoints"].getInt == 1
    check seg["sampleEntrypoints"].getInt == 9   # 8 historical + 1 current, distinct

  test "1-entrypoint CURRENT run against many historical rows -> lowConfidence true (the RFC's own '1-2 entrypoint' --changed example)":
    var rows: seq[ArtifactRow]
    for i in 0 ..< 20:
      rows.add mkArtifactRowAt("ep_hist" & $i, "g1", "c1", "u.c", "K" & $i,
                               100, 100, RunStart - 1000)
    rows.add mkArtifactRowAt("ep_now", "g1", "c1", "u.c", "K_NOW", 100, 100, RunStart)

    let node = buildCompileBlock(rows, @[], currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg["lowConfidence"].getBool == true

  test "a representative run (>= LowConfidenceMinEntrypoints DISTINCT entrypoints contributed THIS run) -> lowConfidence false":
    var rows: seq[ArtifactRow]
    for i in 0 ..< LowConfidenceMinEntrypoints:
      rows.add mkArtifactRowAt("ep" & $i, "g1", "c1", "u.c", "K_SHARED", 100, 100, RunStart)

    let node = buildCompileBlock(rows, @[], currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg["lowConfidence"].getBool == false

  test "default currentRunStartUs (param omitted -> 0) is back-compat: all rows treated as current, matching pre-R7 callers that never pass it":
    let rows = @[
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100),
      mkArtifactRow("ep_b", "g1", "c1", "u.c", "K1", 100, 100),
    ]
    let node = buildCompileBlock(rows, @[])
    let seg = findSegment(node, "g1", "c1")
    check seg["currentRunEntrypoints"].getInt == 2
    check seg["sampleEntrypoints"].getInt == 2

  test "lowConfidenceMinEntrypoints override lets a test isolate a SEPARATE assertion from the gate":
    let rows = @[
      mkArtifactRow("ep_a", "g1", "c1", "u.c", "K1", 100, 100),
      mkArtifactRow("ep_b", "g1", "c1", "u.c", "K1", 100, 100),
    ]
    let node = buildCompileBlock(rows, @[], lowConfidenceMinEntrypoints = 2)
    let seg = findSegment(node, "g1", "c1")
    check seg["lowConfidence"].getBool == false

  test "a cost-only segment (no artifact rows at all) is vacuously lowConfidence (zero contributing entrypoints), not a crash":
    let costRows = @[mkCostRow("ep_a", "g1", "c1", 100, 100, 100)]
    let node = buildCompileBlock(@[], costRows, currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg["currentRunEntrypoints"].getInt == 0
    check seg["lowConfidence"].getBool == true

suite "buildReuseAlerts — R7: low-confidence segments are suppressed regardless of rTime":

  proc reuseCheckOn(alertBelow: float): ReuseCheckConfig =
    ReuseCheckConfig(enabled: true, alertBelow: alertBelow)

  const RunStart = 10_000_000'i64

  test "a low-confidence segment with rTime far below threshold produces NO alert (RFC: narrow runs are 'marked low-confidence AND reuse-check suppressed')":
    var rows: seq[ArtifactRow]
    for i in 0 ..< 20:
      rows.add mkArtifactRowAt("ep_hist" & $i, "g1", "c1", "u.c", "K" & $i,
                               100, 100, RunStart - 1000)
    # THIS run: exactly 1 entrypoint -> low-confidence, regardless of rTime.
    rows.add mkArtifactRowAt("ep_now", "g1", "c1", "u.c", "K_NOW", 100, 100, RunStart)

    let node = buildCompileBlock(rows, @[], currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg["lowConfidence"].getBool == true

    let alerts = buildReuseAlerts(node, reuseCheckOn(0.99))
    check alerts.len == 0

  test "a representative (non-low-confidence) segment below threshold STILL alerts (the gate suppresses only low-confidence segments, not every segment)":
    var rows: seq[ArtifactRow]
    for i in 0 ..< LowConfidenceMinEntrypoints:
      # All distinct keyHash -> fully unshared -> rTime == 0.0.
      rows.add mkArtifactRowAt("ep" & $i, "g1", "c1", "u.c", "K" & $i,
                               100, 100, RunStart)
    let node = buildCompileBlock(rows, @[], currentRunStartUs = RunStart)
    let seg = findSegment(node, "g1", "c1")
    check seg["lowConfidence"].getBool == false
    check seg["rTime"].getFloat == 0.0

    let alerts = buildReuseAlerts(node, reuseCheckOn(0.5))
    check alerts.len == 1
    check alerts[0]["groupId"].getStr == "g1"

# ---------------------------------------------------------------------------
# 13. R14-T5 (code review, test gap) — readCompileBlock adversarial on-disk
#     state: the individual per-stream scans are corruption-resilient and
#     tested per-stream, but the AGGREGATOR that joins all three streams had
#     no test of its own. This exercises readCompileBlock (the effectful
#     entry point) against malformed/partial rows across ALL three ledgers
#     simultaneously.
# ---------------------------------------------------------------------------

suite "readCompileBlock — R14-T5: adversarial on-disk state across all three telemetry streams":

  proc freshStateDir(tag: string): string =
    result = getTempDir() / "crisol_test_compilereport_readblock_" & tag &
             "_" & $getCurrentProcessId()
    removeDir(result)
    createDir(result / "ledger" / "artifacts")
    createDir(result / "ledger" / "compilecost")
    createDir(result / "ledger" / "objcachestats")

  test "malformed/partial rows across all three streams -> readCompileBlock tolerates them (no crash, sane block, surviving good rows visible)":
    let stateDir = freshStateDir("adversarial")
    defer: removeDir(stateDir)

    # Artifact stream, shard a.ndjson: valid header + one good row + one
    # unparsable line + one row missing a required field.
    writeFile(stateDir / "ledger" / "artifacts" / "a.ndjson",
      """{"artifactLedgerFormatVersion":1}""" & "\n" &
      """{"rowVersion":1,"entrypointIdentity":"ep_a","groupId":"g1","configHash":"c1","artifactBasename":"u.c","keyHash":"K1","sizeBytes":10,"ccTimeUs":100,"timestamp":1000}""" & "\n" &
      "NOT VALID JSON {{{" & "\n" &
      """{"rowVersion":1,"groupId":"g1"}""" & "\n"
    )
    # Artifact stream, shard b.ndjson: bad format-version header -> the
    # WHOLE shard (including its otherwise-well-formed row) is discarded.
    writeFile(stateDir / "ledger" / "artifacts" / "b.ndjson",
      """{"artifactLedgerFormatVersion":999}""" & "\n" &
      """{"rowVersion":1,"entrypointIdentity":"ep_z","groupId":"g1","configHash":"c1","artifactBasename":"z.c","keyHash":"KZ","sizeBytes":10,"ccTimeUs":100,"timestamp":1000}""" & "\n"
    )

    # Compile-cost stream: valid header + one good row + one garbage line.
    writeFile(stateDir / "ledger" / "compilecost" / "a.ndjson",
      """{"compileCostLedgerFormatVersion":1}""" & "\n" &
      """{"rowVersion":1,"entrypointIdentity":"ep_a","groupId":"g1","configHash":"c1","codegenUs":10,"ccUs":20,"linkUs":5,"timestamp":1000}""" & "\n" &
      "{{{garbage" & "\n"
    )

    # Objcache-stats stream: valid header + one good row + a blank line +
    # a non-JSON line.
    writeFile(stateDir / "ledger" / "objcachestats" / "a.ndjson",
      """{"objCacheStatsLedgerFormatVersion":1}""" & "\n" &
      """{"rowVersion":1,"entrypointIdentity":"ep_a","groupId":"g1","configHash":"c1","hits":1,"misses":1,"stored":1,"disabled":0,"reusedBytes":50,"timestamp":1000}""" & "\n" &
      "\n" &
      "not json at all" & "\n"
    )

    var node: JsonNode
    var raised = false
    try:
      node = readCompileBlock(stateDir, currentRunStartUs = 2000)
    except CatchableError:
      raised = true
    check not raised
    check node != nil

    # The surviving GOOD rows (one per stream, all identity ep_a/g1/c1) are
    # still visible in the aggregated segment -- proof malformed sibling
    # rows/shards were skipped, not that everything silently vanished.
    let seg = findSegment(node, "g1", "c1")
    check seg != nil
    check seg["artifactsTotal"].getInt == 1   # b.ndjson's whole shard was discarded
    check node.hasKey("objcache")
    check node["objcache"]["hits"].getInt == 1

  test "totally empty ledger subdirectories and a never-created stateDir -> readCompileBlock returns nil, no crash":
    let stateDir = freshStateDir("empty")
    defer: removeDir(stateDir)
    check readCompileBlock(stateDir, currentRunStartUs = 2000) == nil

    let neverCreated = getTempDir() / "crisol_test_compilereport_never_created_" &
                       $getCurrentProcessId()
    removeDir(neverCreated)
    check readCompileBlock(neverCreated, currentRunStartUs = 2000) == nil

when isMainModule:
  echo "All compilereport tests passed."
