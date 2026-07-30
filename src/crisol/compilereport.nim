## compilereport.nim — RFC-0006 M-report PASS (a)+(b1)+(b2): segmented
## `compile` block for the crisol/run/v1 JSON document, plus PASS (b1)'s
## three additive durable-report surfaces (reuse-check alerting,
## ambient-ccache detection, per-basename top-N).
##
## Aggregates TWO measurement telemetry streams already written per-compile
## by the measurement worker — the artifact stream (`artifactledger.
## scanArtifactLedger`: one `ArtifactRow` per reusable compile unit) and the
## compile-cost stream (`compilecost.scanCompileCostLedger`: one
## `CompileCostRow` per compile) — into a single `compile` JSON block, per
## `(groupId, configHash)` segment:
##
##   { "segments": [
##       { "groupId", "configHash", "rTime", "rSize", "ccPct", "codegenPct",
##         "linkPct", "reproducible", "artifactsTotal", "artifactsShared",
##         "bytesTotal", "bytesShared" }, ...
##     ],
##     "ambientCcacheDetected": bool,   // PASS (b1): run-wide hygiene field
##     "topUnits": [ { "basename", "sizeBytes", "ccTimeUs" }, ... ],  // top-10
##     "compileRegressions": [   // PASS (b2): ALWAYS PRESENT; empty by default
##       { "entrypointIdentity", "groupId", "configHash", "currentUs",
##         "baselineUs", "thresholdUs" }, ...
##     ]
##   }
##
## `rTime`/`rSize` are NEVER reinvented here — `artifactid.reuseRatios` is the
## single source of truth for that computation; this module only maps
## `artifactledger.ArtifactRow` to `artifactid.ArtifactRecord` (the two shapes
## are mirrored deliberately, per both modules' docstrings) and calls it.
##
## The two streams are segmented INDEPENDENTLY on disk — a segment may
## exist in one stream but not another (e.g. a group's compiles all failed
## before producing artifact rows, but a cost row was still recorded).
##
## Entry points:
##   buildCompileBlock*(artifactRows, costRows, ambientCcacheDetected = false,
##                      compileRegressions = nil): JsonNode
##     PURE core — no I/O. Returns `nil` when BOTH artifactRows/costRows are
##     empty (no telemetry at all), so the caller can omit the `compile`
##     field entirely (additive/back-compat: measurement-off runs get
##     byte-identical output to before PASS (a)).
##   readCompileBlock*(stateDir, currentRunStartUs): JsonNode
##     Effectful wrapper: scans both ledgers, resolves
##     ambientCcacheDetected via detectAmbientCcache(), computes
##     compileRegressions via computeCompileRegressions(), and calls
##     buildCompileBlock.
##   detectAmbientCcache*(): bool
##     Effectful, never-throwing: best-effort detection of an ambient ccache
##     wrapper around THIS (parent) process — env `CCACHE_*` vars or a `cc`/
##     `gcc` PATH resolution that is itself a ccache shim.
##   buildReuseAlerts*(compileBlock, reuseCheck: ReuseCheckConfig): JsonNode
##     PURE: evaluates the (default-OFF) reuse-check alerting policy against
##     an already-built compile block's segments. ALWAYS returns a JArray
##     (present-but-possibly-empty, mirroring jsonout's `regressions` array)
##     — never nil, unlike buildCompileBlock/readCompileBlock.
##   computeCompileRegressions*(costRows, currentRunStartUs, k, sampleFloor,
##                              absFloorMs): JsonNode
##     M-report PASS (b2): PURE compile-wall-time regression guard — the
##     compile-side analog of perf-check's run-duration guard
##     (crisol/stats.isRegression), applied to the compile-cost stream.
##     ALWAYS returns a JArray (present-but-possibly-empty). See its own
##     doc comment for the current/history split and k/sampleFloor sourcing.

import std/[algorithm, json, os, sets, strutils, tables]
import crisol/types      # for IdentityKey's `$` (borrowed proc), ReuseCheckConfig
import crisol/artifactledger
import crisol/compilecost
import crisol/artifactid
import crisol/stats       # for median/mad/isRegression — M-report PASS (b2)

type
  SegmentKey = tuple[groupId, configHash: string]
  UnitKey = tuple[identity, basename: string]

const TopUnitsLimit = 10
  ## M-report PASS (b1): top-N per-basename breakdown feeding Stage S1's
  ## per-module list.

const CompileRegressionK* = 3.0
const CompileRegressionSampleFloor* = 10
const CompileRegressionAbsFloorMs* = 5
  ## M-report PASS (b2): compile-wall-time regression guard's k / sample-floor
  ## / abs-floor-ms.  These NUMERICALLY match perf-check's "moderate" preset
  ## (api.nim's effectivePerfCheck fallback: k=3.0, sampleFloor=10,
  ## absFloorMs=5) for consistency, but are DELIBERATELY independent
  ## constants rather than a read of `cfg.perfCheck`/`effectivePerfCheck`:
  ## this guard's gating condition is `cfg.measureCompileReuse` (the
  ## compile-cost stream's own on/off switch), which is completely
  ## independent of whether the separate perf-check feature happens to be
  ## enabled. Sourcing k/sampleFloor/absFloorMs from `effectivePerfCheck`
  ## would silently break in the common case of "measureCompileReuse on,
  ## perf-check off" — PerfCheckConfig's zero-value (perf-check disabled)
  ## has k=0.0/sampleFloor=0/absFloorMs=0, which would turn this guard
  ## degenerate (threshold == median, sampleFloor never suppresses) rather
  ## than simply matching perf-check's own (correct, deliberate) disabled
  ## behavior. A well-named const avoids that soundness trap without
  ## introducing a new user-facing config block (no CLI/KDL knob exists,
  ## or is asked for, to tune this guard independently of perf-check today).

const LowConfidenceMinEntrypoints* = 5
  ## Code-review R7: the RFC commits that "`--changed`-narrowed runs:
  ## r_time/M-report are statistically meaningless on a 1-2-entrypoint
  ## subset ... marked low-confidence (and reuse-check suppressed) unless
  ## the run covers a representative entrypoint count." This is the
  ## representativeness floor: a `(groupId, configHash)` segment is
  ## `lowConfidence` when the CURRENT run itself contributed artifact rows
  ## for FEWER than this many DISTINCT entrypoints to that segment (see
  ## `segCurrentRunEntrypoints` below) -- independent of how much
  ## HISTORICAL data the segment's rTime is otherwise aggregated over
  ## (that total is separately surfaced as `sampleEntrypoints`, so a reader
  ## can always see both numbers, never just a bare misleading ratio).
  ##
  ## rTime is inherently a CROSS-entrypoint measurement -- with 1 current-run
  ## entrypoint there is no possibility of THIS run demonstrating sharing
  ## with itself, only against whatever the ledger already accumulated
  ## historically, which is exactly the "computed almost entirely from stale
  ## prior data" failure mode the finding names. The RFC's own motivating
  ## example of a non-representative narrow run is explicitly "a 1-2-
  ## entrypoint subset"; 5 is the smallest round number strictly above that
  ## stated band -- a defensible floor (mirroring how CompileRegressionK/
  ## SampleFloor/AbsFloorMs above are named consts with a documented
  ## rationale rather than empirically tuned) pending real-world calibration
  ## once Stage M's measurement is re-run against a representative
  ## multi-entrypoint suite (see the RFC-0006 handoff's decision-gate note).
  ## No CLI/KDL knob exists to tune this independently today -- same stance
  ## as CompileRegressionK's own doc.

proc toArtifactRecord(row: ArtifactRow): ArtifactRecord =
  ## Bridge ArtifactRow -> ArtifactRecord: the two shapes are mirrored
  ## deliberately (see artifactid.nim's ArtifactRecord doc) so this is a
  ## straight field-for-field map; `entrypointIdentity` is the only field
  ## whose TYPE differs (IdentityKey vs plain string), stringified via `$`.
  ArtifactRecord(
    entrypointIdentity: $row.entrypointIdentity,
    groupId:            row.groupId,
    configHash:         row.configHash,
    basename:           row.artifactBasename,
    keyHash:            row.keyHash,
    sizeBytes:          row.sizeBytes,
    ccTimeUs:           row.ccTimeUs,
  )

proc segKeyOf(groupId, configHash: string): SegmentKey {.inline.} =
  (groupId: groupId, configHash: configHash)

proc sortedSegmentKeys(keys: HashSet[SegmentKey]): seq[SegmentKey] =
  for k in keys: result.add k
  result.sort(proc(a, b: SegmentKey): int =
    if a.groupId != b.groupId: cmp(a.groupId, b.groupId)
    else: cmp(a.configHash, b.configHash))

proc countArtifactsShared(segArtifacts: seq[ArtifactRow]): int =
  ## Count of reusable-unit ROWS (mirroring `artifactsTotal`'s own row-count
  ## unit) whose keyHash is carried by >=2 DISTINCT entrypointIdentity values
  ## within the segment — the SAME "shared" predicate `artifactid.reuseRatios`
  ## applies per-row internally (`if entrypointsByKey[r.keyHash].len >= 2:
  ## sharedCc += r.ccTimeUs`), mirrored here rather than reinvented, and kept
  ## in the same per-row unit as `bytesShared`/`sharedCcTimeUs` so all four
  ## "shared" figures describe the same population.
  var entrypointsByKeyHash: Table[string, HashSet[string]]
  for r in segArtifacts:
    entrypointsByKeyHash.mgetOrPut(r.keyHash, initHashSet[string]())
      .incl($r.entrypointIdentity)
  for r in segArtifacts:
    if entrypointsByKeyHash[r.keyHash].len >= 2:
      inc result

proc isReproducible(segArtifacts: seq[ArtifactRow]): bool =
  ## TRUE iff no (entrypointIdentity, artifactBasename) unit in the segment
  ## carries >=2 DISTINCT keyHash values (a cross-slot mismatch of what should
  ## be the same reusable unit).
  var keyHashesByUnit: Table[UnitKey, HashSet[string]]
  for r in segArtifacts:
    let unit: UnitKey = (identity: $r.entrypointIdentity, basename: r.artifactBasename)
    keyHashesByUnit.mgetOrPut(unit, initHashSet[string]()).incl(r.keyHash)
  for unit, hashes in keyHashesByUnit:
    if hashes.len >= 2:
      return false
  result = true

proc segEntrypointCounts(segArtifacts: seq[ArtifactRow];
                         currentRunStartUs: int64): tuple[current, total: int] =
  ## R7: the provenance pair backing the low-confidence gate. `total` =
  ## number of DISTINCT entrypointIdentity values contributing ANY artifact
  ## row to this segment (the full aggregate the segment's rTime is computed
  ## over, however far back it goes). `current` = the SUBSET of those that
  ## contributed a row with `timestamp >= currentRunStartUs` -- i.e. THIS
  ## run's own contribution. A caller omitting currentRunStartUs (default 0)
  ## gets `current == total` (every row is >= 0), matching pre-R7
  ## buildCompileBlock behavior for callers that never pass it.
  var allIds, currentIds: HashSet[string]
  for r in segArtifacts:
    let ident = $r.entrypointIdentity
    allIds.incl ident
    if r.timestamp >= currentRunStartUs:
      currentIds.incl ident
  (current: currentIds.len, total: allIds.len)

proc buildTopUnits(artifactRows: seq[ArtifactRow]): JsonNode =
  ## M-report PASS (b1): the top `TopUnitsLimit` reusable-unit rows ACROSS
  ## THE WHOLE RUN (not per-segment), sorted DESC by ccTimeUs. Tie-break:
  ## sizeBytes DESC, then basename ASC (fully deterministic ordering even
  ## with identical measurements). Each entry: {basename, sizeBytes, ccTimeUs}.
  var rows = artifactRows
  rows.sort(proc(a, b: ArtifactRow): int =
    if a.ccTimeUs != b.ccTimeUs: cmp(b.ccTimeUs, a.ccTimeUs)
    elif a.sizeBytes != b.sizeBytes: cmp(b.sizeBytes, a.sizeBytes)
    else: cmp(a.artifactBasename, b.artifactBasename)
  )
  result = newJArray()
  for i in 0 ..< min(TopUnitsLimit, rows.len):
    let r = rows[i]
    let node = newJObject()
    node["basename"]  = newJString(r.artifactBasename)
    node["sizeBytes"] = newJInt(r.sizeBytes)
    node["ccTimeUs"]  = newJInt(r.ccTimeUs)
    result.add node

proc compileTotalUs(row: CompileCostRow): int64 {.inline.} =
  ## Total compile wall time of one CompileCostRow: the three phases
  ## (codegen, cc, link) are SEQUENTIAL (see compilecost.nim's module doc),
  ## so their sum is the compile wall time.
  row.codegenUs + row.ccUs + row.linkUs

proc computeCompileRegressions*(costRows: seq[CompileCostRow];
                                currentRunStartUs: int64;
                                k: float = CompileRegressionK;
                                sampleFloor: int = CompileRegressionSampleFloor;
                                absFloorMs: int = CompileRegressionAbsFloorMs): JsonNode =
  ## M-report PASS (b2): PURE compile-wall-time regression guard — the
  ## compile-side analog of perf-check's run-duration guard. No I/O.
  ##
  ## Current/history split mirrors api.nim's perf-check split EXACTLY: rows
  ## with `timestamp >= currentRunStartUs` belong to THIS run; earlier rows
  ## are PRIOR history (api.nim's own `runStartUs` is captured BEFORE
  ## execute() appends the current run's rows, so the same threshold used
  ## for the exec ledger there is reused here for the compile-cost stream).
  ##
  ## Per entrypointIdentity:
  ##   - current = the row with the HIGHEST timestamp at/above the
  ##     threshold (normally exactly one row per entrypoint per run).
  ##     Entrypoints with NO current-run row (e.g. compile skipped/cached/
  ##     failed before a cost row was recorded) are never flagged.
  ##   - history = codegenUs+ccUs+linkUs totals of that SAME entrypoint's
  ##     rows strictly BEFORE the threshold (the current run's own row is
  ##     excluded from its own baseline by construction).
  ##   - verdict = crisol/stats.isRegression(currentUs, historyUs, k,
  ##     sampleFloor, absFloorMs) — the SAME shared statistical primitive
  ##     perf-check uses, never reinvented here.
  ##
  ## Emission: one entry per REGRESSED entrypoint —
  ##   {entrypointIdentity, groupId, configHash, currentUs, baselineUs,
  ##    thresholdUs}
  ## (groupId/configHash taken from the current row). Entrypoints within
  ## threshold, or with insufficient history (< sampleFloor prior rows),
  ## are absent. Deterministic order: entrypointIdentity string ascending.
  ##
  ## ALWAYS returns a JArray (present-but-possibly-empty) — mirrors the
  ## top-level `regressions` array's convention — never nil.
  result = newJArray()

  var currentByIdentity: Table[string, CompileCostRow]
  var historyByIdentity: Table[string, seq[int64]]

  for row in costRows:
    let ik = $row.entrypointIdentity
    if row.timestamp >= currentRunStartUs:
      if ik notin currentByIdentity or row.timestamp > currentByIdentity[ik].timestamp:
        currentByIdentity[ik] = row
    else:
      historyByIdentity.mgetOrPut(ik, newSeq[int64]()).add compileTotalUs(row)

  var identities: seq[string]
  for ik in currentByIdentity.keys: identities.add ik
  identities.sort(cmp)

  for ik in identities:
    let cur = currentByIdentity[ik]
    let historyUs = historyByIdentity.getOrDefault(ik, newSeq[int64]())
    let verdict = isRegression(
      currentUs   = compileTotalUs(cur),
      historyUs   = historyUs,
      k           = k,
      sampleFloor = sampleFloor,
      absFloorMs  = absFloorMs,
    )
    if verdict.regressed:
      let n = newJObject()
      n["entrypointIdentity"] = newJString(ik)
      n["groupId"]            = newJString(cur.groupId)
      n["configHash"]         = newJString(cur.configHash)
      n["currentUs"]          = newJInt(compileTotalUs(cur))
      n["baselineUs"]         = newJInt(verdict.baselineUs)
      n["thresholdUs"]        = newJInt(verdict.thresholdUs)
      result.add n

proc detectAmbientCcache*(): bool =
  ## M-report PASS (b1): best-effort, NEVER-THROWING detection of an ambient
  ## ccache wrapper around this crisol invocation.
  ##
  ## Stage M forces `CCACHE_DISABLE=1` for the measurement WORKER's own
  ## process only; this parent-process check records whether ccache was
  ## ambiently present around the run at all (a hygiene/observability field —
  ## it never changes measurement behavior).
  ##
  ## Detection = ANY of:
  ##   - any `CCACHE_*` environment variable is set in THIS (parent) process.
  ##   - the `cc` or `gcc` resolved on PATH is a ccache shim -- its raw PATH
  ##     resolution or its fully-resolved (symlink-following) real path
  ##     contains "ccache".
  try:
    for k, _ in envPairs():
      if k.startsWith("CCACHE_"):
        return true
    for exe in ["cc", "gcc"]:
      let path = findExe(exe)
      if path.len == 0: continue
      if "ccache" in path.toLowerAscii:
        return true
      try:
        if "ccache" in expandFilename(path).toLowerAscii:
          return true
      except CatchableError:
        discard
  except CatchableError:
    discard
  false

proc buildCompileBlock*(artifactRows: seq[ArtifactRow];
                        costRows: seq[CompileCostRow];
                        ambientCcacheDetected: bool = false;
                        compileRegressions: JsonNode = nil;
                        currentRunStartUs: int64 = 0;
                        lowConfidenceMinEntrypoints: int = LowConfidenceMinEntrypoints): JsonNode =
  ## Pure. No I/O beyond the caller-supplied rows/flag/pre-built regressions
  ## array. Returns `nil` when BOTH streams (artifactRows, costRows) are
  ## empty — the caller then omits the `compile` field entirely.
  ## compileRegressions: M-report PASS (b2) — a pre-built JArray (normally
  ## from computeCompileRegressions), embedded verbatim as
  ## `compile.compileRegressions`. nil (the default) -> emitted as an EMPTY
  ## JArray (present-but-possibly-empty; mirrors `regressions`/`reuseAlerts`'
  ## own convention), never omitted once the `compile` block itself exists.
  ## currentRunStartUs / lowConfidenceMinEntrypoints: R7 (code review) — the
  ## low-confidence gate. Each segment gains `currentRunEntrypoints`
  ## (DISTINCT entrypoints THIS run itself contributed rows for, i.e. rows
  ## with `timestamp >= currentRunStartUs`), `sampleEntrypoints` (DISTINCT
  ## entrypoints contributing ANY row, all history included — the full
  ## population rTime is aggregated over, made visible rather than left
  ## implicit), and `lowConfidence` (true iff `currentRunEntrypoints <
  ## lowConfidenceMinEntrypoints`). `currentRunStartUs` defaults to 0, so a
  ## caller that never passes it gets `currentRunEntrypoints ==
  ## sampleEntrypoints` (every row's timestamp is >= 0) — back-compat for
  ## existing callers/tests that predate this gate.
  if artifactRows.len == 0 and costRows.len == 0:
    return nil

  # Reuse ratios — delegated entirely to artifactid.reuseRatios.
  var records = newSeq[ArtifactRecord](artifactRows.len)
  for i, row in artifactRows:
    records[i] = toArtifactRecord(row)
  let ratiosBySegment = reuseRatios(records)

  # Group each stream's raw rows by segment (independent segmentation —
  # a segment may appear in only one of the two tables below).
  var artifactsBySegment: Table[SegmentKey, seq[ArtifactRow]]
  for row in artifactRows:
    artifactsBySegment.mgetOrPut(segKeyOf(row.groupId, row.configHash),
                                  newSeq[ArtifactRow]()).add row

  var costsBySegment: Table[SegmentKey, seq[CompileCostRow]]
  for row in costRows:
    costsBySegment.mgetOrPut(segKeyOf(row.groupId, row.configHash),
                              newSeq[CompileCostRow]()).add row

  var allKeys: HashSet[SegmentKey]
  for k in artifactsBySegment.keys: allKeys.incl k
  for k in costsBySegment.keys: allKeys.incl k

  let segmentsNode = newJArray()
  for key in sortedSegmentKeys(allKeys):
    let segArtifacts = artifactsBySegment.getOrDefault(key, newSeq[ArtifactRow]())
    let segCosts = costsBySegment.getOrDefault(key, newSeq[CompileCostRow]())
    let ratios = ratiosBySegment.getOrDefault(key, ReuseRatios())

    var codegenSum, ccSum, linkSum: int64
    for c in segCosts:
      codegenSum += c.codegenUs
      ccSum += c.ccUs
      linkSum += c.linkUs
    let costTotal = codegenSum + ccSum + linkSum
    let codegenPct = if costTotal == 0: 0.0 else: codegenSum.float / costTotal.float
    let ccPct      = if costTotal == 0: 0.0 else: ccSum.float / costTotal.float
    let linkPct    = if costTotal == 0: 0.0 else: linkSum.float / costTotal.float

    let entrypointCounts = segEntrypointCounts(segArtifacts, currentRunStartUs)

    let segNode = newJObject()
    segNode["groupId"]         = newJString(key.groupId)
    segNode["configHash"]      = newJString(key.configHash)
    segNode["rTime"]           = newJFloat(ratios.rTime)
    segNode["rSize"]           = newJFloat(ratios.rSize)
    segNode["ccPct"]           = newJFloat(ccPct)
    segNode["codegenPct"]      = newJFloat(codegenPct)
    segNode["linkPct"]         = newJFloat(linkPct)
    segNode["reproducible"]    = newJBool(isReproducible(segArtifacts))
    segNode["artifactsTotal"]  = newJInt(segArtifacts.len)
    segNode["artifactsShared"] = newJInt(countArtifactsShared(segArtifacts))
    segNode["bytesTotal"]      = newJInt(ratios.totalBytes)
    segNode["bytesShared"]     = newJInt(ratios.sharedBytes)
    # R7: low-confidence gate provenance -- see buildCompileBlock's own doc.
    segNode["currentRunEntrypoints"] = newJInt(entrypointCounts.current)
    segNode["sampleEntrypoints"]     = newJInt(entrypointCounts.total)
    segNode["lowConfidence"]         = newJBool(entrypointCounts.current < lowConfidenceMinEntrypoints)
    segmentsNode.add segNode

  result = newJObject()
  result["segments"]              = segmentsNode
  result["ambientCcacheDetected"] = newJBool(ambientCcacheDetected)
  result["topUnits"]              = buildTopUnits(artifactRows)
  # M-report PASS (b2): always present, empty by default (mirrors `regressions`).
  result["compileRegressions"] =
    if compileRegressions != nil: compileRegressions else: newJArray()

proc readCompileBlock*(stateDir: string; currentRunStartUs: int64): JsonNode =
  ## Effectful: scan both telemetry streams under `stateDir` and build
  ## the `compile` block. Returns `nil` when neither has any rows.
  ## ambientCcacheDetected is resolved here (report time, in the parent
  ## process) via the never-throwing detectAmbientCcache() helper.
  ## currentRunStartUs: the SAME run-start timestamp api.nim's perf-check
  ## captures (before execute() appends this run's rows) — threaded through
  ## to computeCompileRegressions() so the compile-cost stream's
  ## current/history split matches perf-check's exec-ledger split exactly.
  ## R7: `currentRunStartUs` is ALSO threaded into buildCompileBlock itself
  ## (not just computeCompileRegressions) — it is the "this run's scope"
  ## signal the low-confidence gate needs to tell THIS run's own
  ## contributing-entrypoint count apart from the aggregate.
  let costRows = scanCompileCostLedger(stateDir)
  let compileRegressions = computeCompileRegressions(costRows, currentRunStartUs)
  buildCompileBlock(scanArtifactLedger(stateDir), costRows,
                    ambientCcacheDetected = detectAmbientCcache(),
                    compileRegressions = compileRegressions,
                    currentRunStartUs = currentRunStartUs)

# ---------------------------------------------------------------------------
# M-report PASS (b1): reuse-check alerting policy evaluation
# ---------------------------------------------------------------------------

proc buildReuseAlerts*(compileBlock: JsonNode; reuseCheck: ReuseCheckConfig): JsonNode =
  ## Pure. Evaluate `reuseCheck` against an already-built `compile` block's
  ## `segments` and emit an alert for each segment whose rTime falls below
  ## `reuseCheck.alertBelow`.
  ##
  ## R7: a segment marked `lowConfidence` (this run itself contributed too
  ## few distinct entrypoints — see LowConfidenceMinEntrypoints) is SKIPPED
  ## regardless of its rTime, per the RFC: "the report is marked
  ## low-confidence (and reuse-check suppressed) unless the run covers a
  ## representative entrypoint count." A segment built by a pre-R7 caller
  ## that omits `lowConfidence` entirely is treated as NOT low-confidence
  ## (hasKey guard) — back-compat with hand-built JSON fixtures.
  ##
  ## ALWAYS returns a JArray (never nil) -- mirrors jsonout's `regressions`
  ## array: present and empty by default, not omitted. Empty when disabled,
  ## when compileBlock is nil (no telemetry / measurement off), or when no
  ## segment qualifies.
  result = newJArray()
  if not reuseCheck.enabled or compileBlock == nil:
    return
  for seg in compileBlock["segments"]:
    if seg.hasKey("lowConfidence") and seg["lowConfidence"].getBool:
      continue
    if seg["rTime"].getFloat < reuseCheck.alertBelow:
      let a = newJObject()
      a["groupId"]    = seg["groupId"]
      a["configHash"] = seg["configHash"]
      a["rTime"]      = seg["rTime"]
      a["alertBelow"] = newJFloat(reuseCheck.alertBelow)
      result.add a
