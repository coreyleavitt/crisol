## jsonout.nim — B5 JSON serialization + lastrun.json persistence
##              B7 loadLastRun: read back failed (path,group) keys
##
## Public API:
##
##   toJson*(results: seq[EntrypointResult]; summary: Summary;
##           filterTag: string = ""): JsonNode
##     Pure: produce the crisol/run/v1 JSON object.
##     C3: when filterTag is non-empty, each entrypoint's records array
##     contains ONLY records whose tags include the tag.  This keeps
##     --filter-tag consistent between human and machine output.
##     The summary object is always the FULL-RUN summary (never re-counted
##     from filtered records) so the JSON verdict is not distorted.
##
##   toJsonString*(results: seq[EntrypointResult]; summary: Summary;
##                 filterTag: string = ""): string
##     Pure: compact JSON string (calls `$` on the JsonNode).
##
##   persistLastRun*(results: seq[EntrypointResult]; summary: Summary; config: Config)
##     Effectful: write <config.projectRoot>/<config.stateDir>/lastrun.json
##     atomically (temp file + rename).  Creates the state dir if absent.
##     On any write failure: warns to stderr and continues -- never crashes.
##
##   loadLastRun*(config: Config): tuple[found: bool; failed: HashSet[tuple[path,group: string]]]
##     Effectful: read <projectRoot>/<stateDir>/lastrun.json and return the set
##     of (path, group) pairs whose outcome is a failure (not "passed" and not
##     "noTestsRan" — specifically: "exitNonZero", "compileFailed", "timedOut",
##     "signaled", "spawnError").
##     found=false means the file is ABSENT (caller should exit 3).
##     If the file is present but malformed or has an unrecognized schema version,
##     raises CrisolError(cekEnvironment) — caller also exits 3.
##
## Schema (crisol/run/v1):
##   {
##     "schema":      "crisol/run/v1",
##     "summary": { total, passed, failed, compileFailed, timedOut,
##                  signaled, spawnErrors, noTestsRan },
##     "entrypoints": [
##       { path, group, outcome (string), exitCode (int),
##         signal (int|null), durationMs (float),
##         records: [{ name, status (string), durationUs (int),
##                     msg (string|null), tags ([string]) }] }
##     ],
##     "compile": {   // OPTIONAL (rev 7): present only when telemetry exists
##       "segments": [
##         { groupId, configHash, rTime, rSize, ccPct, codegenPct, linkPct,
##           reproducible (bool), artifactsTotal, artifactsShared,
##           bytesTotal, bytesShared }
##       ],
##       "ambientCcacheDetected": bool,  // rev 8
##       "topUnits": [ { basename, sizeBytes, ccTimeUs }, ... ],  // rev 8, top-10
##       "compileRegressions": [   // rev 9: ALWAYS PRESENT (once compile exists); empty by default
##         { entrypointIdentity, groupId, configHash, currentUs, baselineUs, thresholdUs }
##       ]
##     },
##     "reuseAlerts": [   // rev 8: ALWAYS PRESENT; empty when reuse-check disabled
##       { groupId, configHash, rTime, alertBelow }
##     ]
##   }
##
## Outcome string values (stable):
##   oPassed        -> "passed"
##   oFailed        -> "exitNonZero"
##   oCompileFailed -> "compileFailed"
##   oTimeout       -> "timedOut"
##   oSignal        -> "signaled"
##   oSpawnError    -> "spawnError"
##
## RecordStatus string values (stable):
##   rsPass -> "pass"
##   rsFail -> "fail"
##   rsSkip -> "skip"

import std/[json, options, os, sets]
import std/posix as posix_mod
import crisol/types
import crisol/config  # for stateDirOf
import crisol/render  # for filterRecordsByTag
import crisol/planview  # for warningsToJsonArray
import crisol/outcomestrings  # re-exports FailureOutcomeStrings (the only symbol
                              # used from this module); imported separately from
                              # types so the dependency on the wire-string set is
                              # explicit rather than hidden inside a bulk import.
import crisol/ioutils  # R2-a: writeAllFd replaces bare write() (EINTR/short-write safe)

# ---------------------------------------------------------------------------
# Schema-version constant (single source of truth)
# ---------------------------------------------------------------------------

const RunV1Schema* = "crisol/run/v1"
  ## Stable schema identifier embedded in every crisol/run/v1 JSON document.
  ## Import crisol/api (or crisol/jsonout directly) to reference this constant
  ## rather than duplicating the string literal.

const RunV1Revision* = 13
  ## Integer minor revision of the crisol/run/v1 schema (A8).  Additive only:
  ## the `schema` STRING stays "crisol/run/v1"; this integer is bumped each time
  ## additive optional fields land, so a consumer can gate on feature presence
  ## (`schemaRevision >= 6`) without substring-parsing the string.
  ##   rev 1 (implicit) — B5/S2a fields (compileSkipped, memThrottledSlots, …).
  ##   rev 2           — per-entrypoint cached / inputHash / cacheDecision (A6).
  ##   rev 3 (B3)      — per-entrypoint quarantined (bool), flaky (bool), attempts (int);
  ##                     summary quarantined (int).
  ##   rev 4 (C5)      — per-entrypoint peakRssBytes (int64); 0 for cached/unmeasured.
  ##   rev 5 (C6)      — top-level regressions array (path, currentUs, baselineUs,
  ##                     thresholdUs); per-entrypoint regressed (bool). Empty when
  ##                     perf-check is disabled (additive default).
  ##   rev 6 (M8)      — cacheDecision vocabulary expanded: "stored" (miss+stored),
  ##                     "groupOptOut" (cacheable #false config), legacy "keyMiss"
  ##                     now means ran-but-not-stored; "policyDisabled" is --no-cache only.
  ##   rev 7 (M-report a) — top-level `compile` object: segmented per
  ##                     (groupId, configHash) reuse/cost-split summary
  ##                     (segments[].{groupId, configHash, rTime, rSize, ccPct,
  ##                     codegenPct, linkPct, reproducible, artifactsTotal,
  ##                     artifactsShared, bytesTotal, bytesShared}).  FIELD IS
  ##                     ABSENT (not merely empty) when measureCompileReuse is
  ##                     off — additive/back-compat with pre-rev-7 documents.
  ##   rev 8 (M-report b1) — top-level `reuseAlerts` array (groupId, configHash,
  ##                     rTime, alertBelow); ALWAYS PRESENT, empty when
  ##                     reuse-check is disabled (default) or no segment
  ##                     qualifies — mirrors the `regressions` array's
  ##                     present-but-possibly-empty convention (unlike
  ##                     `compile`, which is absent entirely when there is no
  ##                     telemetry). Also: `compile.ambientCcacheDetected`
  ##                     (bool) and `compile.topUnits` (top-10 per-basename
  ##                     {basename, sizeBytes, ccTimeUs}, both additive
  ##                     siblings of `compile.segments`.
  ##   rev 9 (M-report b2) — `compile.compileRegressions` array (entrypointIdentity,
  ##                     groupId, configHash, currentUs, baselineUs,
  ##                     thresholdUs): the compile-wall-time analog of the
  ##                     top-level `regressions` array, but nested inside
  ##                     `compile` (only meaningful when measureCompileReuse
  ##                     is on). ALWAYS PRESENT once `compile` exists, empty
  ##                     when no entrypoint regressed or history is
  ##                     insufficient — mirrors `regressions`' own
  ##                     present-but-possibly-empty convention.
  ##   rev 10 (Stage R R5b, REMOVED in rev 12) — formerly `compile.objcache`,
  ##                     realized object-cache hit/miss/store telemetry. The
  ##                     RFC-0006 Stage R object cache was removed after an
  ##                     end-to-end A/B showed it didn't pay off on the target
  ##                     consumer (codegen-bound, not cc-bound; cold runs were
  ##                     slower) — see rev 12.
  ##   rev 11 (code review R7) — each `compile.segments[]` entry gains
  ##                     `currentRunEntrypoints` (int: distinct entrypoints
  ##                     THIS run itself contributed artifact rows for to
  ##                     this segment), `sampleEntrypoints` (int: distinct
  ##                     entrypoints contributing ANY row, all history
  ##                     included), and `lowConfidence` (bool: true iff
  ##                     `currentRunEntrypoints` is below
  ##                     compilereport.LowConfidenceMinEntrypoints). A
  ##                     `--changed`-narrowed run touching only 1-2
  ##                     entrypoints now marks its segments low-confidence,
  ##                     and `reuseAlerts` SKIPS low-confidence segments
  ##                     regardless of rTime (matches the RFC's own "marked
  ##                     low-confidence (and reuse-check suppressed)"
  ##                     commitment). Purely additive per-segment fields —
  ##                     no existing field's meaning changes.
  ##   rev 12 — RFC-0006 Stage R (the object cache) removed entirely: the
  ##                     `compile.objcache` sub-block (rev 10) no longer
  ##                     appears in any document. Stage M (measurement:
  ##                     `compile.segments`, `topUnits`, `compileRegressions`,
  ##                     `ambientCcacheDetected`) and the RFC-0004 result
  ##                     cache are UNCHANGED. A reader that only reads
  ##                     `compile.objcache` optionally (as rev 10 always
  ##                     documented it) is unaffected by its permanent
  ##                     absence.
  ##   rev 13 (#5)     — cacheDecision vocabulary: "closureUnrecorded" (fresh run;
  ##                     store refused because the source closure could not be
  ##                     recorded — see depgraph.recordClosure).
  ## A reader seeing `schemaRevision > RunV1Revision` treats the file as no-data
  ## (safe cold-start) — it was written by a newer crisol.

# ---------------------------------------------------------------------------
# Stable string mappings
# ---------------------------------------------------------------------------

proc outcomeString*(o: Outcome): string {.inline.} =
  ## Returns the stable JSON wire string for an Outcome enum value.
  ## Delegates to types.outcomeString — single source of truth lives there.
  types.outcomeString(o)

proc recordStatusString*(s: RecordStatus): string =
  ## Returns the stable JSON string for a RecordStatus enum value.
  case s
  of rsPass: "pass"
  of rsFail: "fail"
  of rsSkip: "skip"

proc cacheDecisionString*(d: CacheDecision): string =
  ## Returns the stable JSON string for a CacheDecision enum value (A8).
  ## These answer "why did this entrypoint cache or not?" in run/v1 output.
  ## M8 additions (rev 6):
  ##   "stored"      — cdmStored: fresh run on a miss; result written to cache.
  ##   "groupOptOut" — cdmGroupOptOut: per-group cacheable #false config opt-out.
  ## M8 refined meanings:
  ##   "keyMiss"           — ran live on a miss but was NOT stored, for a reason
  ##                        not covered by one of the other, more specific
  ##                        variants (see cdmHermeticityDeg, cdmFlaky,
  ##                        cdmClosureUnrecorded).
  ##   "policyDisabled"    — invocation --no-cache flag only (not config cacheable #false).
  ##   "closureUnrecorded" — fresh run; store refused because the entrypoint's
  ##                        source closure could not be recorded.
  case d
  of cdmNotEligible:       "notEligible"
  of cdmHit:               "hit"
  of cdmStored:            "stored"
  of cdmKeyMiss:           "keyMiss"
  of cdmHermeticityDeg:    "hermeticityDegraded"
  of cdmGroupOptOut:       "groupOptOut"
  of cdmPolicyDisabled:    "policyDisabled"
  of cdmFlaky:             "flaky"
  of cdmClosureUnrecorded: "closureUnrecorded"

# ---------------------------------------------------------------------------
# toJson -- pure serializer
# ---------------------------------------------------------------------------

proc toJson*(results: seq[EntrypointResult]; summary: Summary;
             filterTag: string = "";
             warnings: seq[ConfigWarning] = @[];
             memThrottledSlots: int = 0;
             compileBlock: JsonNode = nil;
             reuseAlerts: JsonNode = nil): JsonNode =
  ## Pure: serialize to the crisol/run/v1 JsonNode.
  ## No I/O.
  ## C3: when filterTag is non-empty, each entrypoint's records array contains
  ## only records whose tags include filterTag.  The summary block always
  ## reflects the full unfiltered run (no re-counting from filtered records).
  ## warnings: config warnings (unknown keys) threaded from loadConfig.
  ## memThrottledSlots: count of slots that were memory-blocked (S2a schema
  ## field; populated by AdmissionController in S6b).  Defaults to 0. # S6b
  ## compileBlock: M-report pass (a) segmented compile-reuse/cost-split block
  ## (crisol/compilereport.readCompileBlock), or nil when no telemetry exists
  ## (measureCompileReuse off). nil -> the "compile" field is OMITTED entirely
  ## (additive/back-compat) rather than emitted as an empty object.
  ## reuseAlerts: M-report pass (b1) alert array
  ## (crisol/compilereport.buildReuseAlerts). Unlike compileBlock, this field
  ## is ALWAYS PRESENT (mirrors `regressions`) -- nil/omitted is treated as an
  ## empty JArray, never omitted from the document.

  # Build summary object (always full-run counts)
  let summaryNode = newJObject()
  summaryNode["total"]         = newJInt(summary.total)
  summaryNode["passed"]        = newJInt(summary.passed)
  summaryNode["failed"]        = newJInt(summary.failed)
  summaryNode["compileFailed"] = newJInt(summary.compileFailed)
  summaryNode["timedOut"]      = newJInt(summary.timedOut)
  summaryNode["signaled"]      = newJInt(summary.signaled)
  summaryNode["spawnErrors"]   = newJInt(summary.spawnErrors)
  # B3: quarantined failure count — failures excluded from exit-1 decision.
  summaryNode["quarantined"]   = newJInt(summary.quarantined)
  summaryNode["noTestsRan"]    = newJBool(summary.noTestsRan)

  # Build entrypoints array
  let entrypointsNode = newJArray()
  for r in results:
    # C3: filter records if a tag was supplied
    let displayRecords =
      if filterTag.len > 0: filterRecordsByTag(r.records, filterTag)
      else: r.records

    # Build records array for this entrypoint
    let recordsNode = newJArray()
    for rec in displayRecords:
      let recNode = newJObject()
      recNode["name"]       = newJString(rec.name)
      recNode["status"]     = newJString(recordStatusString(rec.status))
      recNode["durationUs"] = newJInt(rec.durationUs)
      if rec.msg.isSome:
        recNode["msg"] = newJString(rec.msg.get)
      else:
        recNode["msg"] = newJNull()
      let tagsNode = newJArray()
      for t in rec.tags:
        tagsNode.add newJString(t)
      recNode["tags"] = tagsNode
      recordsNode.add recNode

    # Build entrypoint object
    let epNode = newJObject()
    epNode["path"]          = newJString(r.ep.path)
    epNode["group"]         = newJString(r.ep.group)
    epNode["outcome"]       = newJString(outcomeString(r.outcome))
    epNode["exitCode"]      = newJInt(r.exitCode)
    if r.outcome == oSignal:
      epNode["signal"] = newJInt(r.signal)
    else:
      epNode["signal"] = newJNull()
    epNode["durationMs"]    = newJFloat(r.durationMs.float)
    epNode["compileSkipped"] = newJBool(r.compileSkipped)  # S2a: complete the schema
    # A8 (run/v1 rev 2): cache observability.  `cached` absence-default false;
    # `inputHash` is the soundnessKey string ("" when caching not consulted);
    # `cacheDecision` is the stable string form of the always-populated enum.
    epNode["cached"]        = newJBool(r.cached)
    epNode["inputHash"]     = newJString(r.inputHash)
    epNode["cacheDecision"] = newJString(cacheDecisionString(r.cacheDecision))
    # B1 (rev 3): per-entrypoint retry observability.  `flaky` absence-default false;
    # `attempts` is 0 for cached results (no live run), 1 for a clean first-pass, >1 if retried.
    epNode["flaky"]         = newJBool(r.flaky)
    epNode["attempts"]      = newJInt(r.attempts)
    # B3 (rev 3): quarantine overlay — true iff ep.path ∈ Config.quarantine.
    # Absence-default false; only quarantined entrypoints carry true.
    epNode["quarantined"]   = newJBool(r.quarantined)
    # C5 (rev 4): per-entrypoint peak RSS in bytes.  0 for cached results or
    # when RSS sampling was unavailable.  Absence-default 0.
    epNode["peakRssBytes"]  = newJInt(r.peakRssBytes)
    # C6 (rev 5): per-entrypoint regression flag.  Absence-default false.
    # Only true when perf-check is enabled AND this run exceeded median+k·MAD.
    epNode["regressed"]     = newJBool(r.regressed)
    epNode["records"]       = recordsNode
    entrypointsNode.add epNode

  # C6 (rev 5): build the regressions array from regressed results.
  # Each entry: { path, currentUs (durationMs*1000), baselineUs, thresholdUs }.
  # Array is always present; empty when perf-check is disabled or no regressions.
  let regressionsNode = newJArray()
  for r in results:
    if r.regressed:
      let rn = newJObject()
      rn["path"]        = newJString(r.ep.path)
      rn["currentUs"]   = newJInt(r.durationMs * 1000)
      rn["baselineUs"]  = newJInt(r.perfBaselineUs)
      rn["thresholdUs"] = newJInt(r.perfThresholdUs)
      regressionsNode.add rn

  # Assemble top-level object
  result = newJObject()
  result["schema"]           = newJString(RunV1Schema)
  result["schemaRevision"]   = newJInt(RunV1Revision)  # A8: additive minor revision
  result["summary"]          = summaryNode
  result["entrypoints"]      = entrypointsNode
  result["memThrottledSlots"] = newJInt(memThrottledSlots)  # S2a schema field; S6b populates
  result["warnings"]         = warningsToJsonArray(warnings)
  result["regressions"]      = regressionsNode  # C6: empty when perf-check disabled
  if compileBlock != nil:
    result["compile"] = compileBlock  # M-report pass (a): additive; absent when nil
  # M-report pass (b1): always present, empty by default (mirrors `regressions`).
  result["reuseAlerts"] = if reuseAlerts != nil: reuseAlerts else: newJArray()

proc toJsonString*(results: seq[EntrypointResult]; summary: Summary;
                   filterTag: string = "";
                   warnings: seq[ConfigWarning] = @[];
                   memThrottledSlots: int = 0;
                   compileBlock: JsonNode = nil;
                   reuseAlerts: JsonNode = nil): string =
  ## Pure: compact JSON string of the crisol/run/v1 document.
  ## C3: filterTag threads through to toJson.
  $toJson(results, summary, filterTag, warnings, memThrottledSlots, compileBlock, reuseAlerts)

# ---------------------------------------------------------------------------
# persistLastRun -- effectful
# ---------------------------------------------------------------------------

proc persistLastRun*(results: seq[EntrypointResult]; summary: Summary;
                     config: Config;
                     warnings: seq[ConfigWarning] = @[];
                     memThrottledSlots: int = 0;
                     compileBlock: JsonNode = nil;
                     reuseAlerts: JsonNode = nil) =
  ## Write lastrun.json atomically to <projectRoot>/<stateDir>/lastrun.json.
  ## Creates the state directory if it does not exist.
  ## On any failure: prints a warning to stderr and returns -- never raises.
  ##
  ## warnings and memThrottledSlots are threaded through to toJsonString so
  ## the persisted file matches the stdout JSON path exactly (M3 fix).
  ## compileBlock: M-report pass (a) segmented compile block, or nil (default)
  ## when there is no telemetry to report -- threads through unchanged.
  ## reuseAlerts: M-report pass (b1) alert array, or nil (default; persisted
  ## as an empty array) -- threads through unchanged.
  let stateDir = stateDirOf(config)
  let finalPath = stateDir / "lastrun.json"

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return

  # Write to a temp file in the same directory, then rename (atomic on POSIX).
  # Use O_CREAT|O_EXCL|O_WRONLY so the open fails if a file (or symlink) already
  # exists at the temp path — prevents a pre-planted symlink from redirecting our
  # write to an attacker-chosen path (symlink write-through attack on shared fs).
  # If a stale .tmp from a previous crashed run exists, we remove it first.
  let tmpPath = finalPath & ".tmp"
  try: removeFile(tmpPath) except: discard
  let jsonStr = toJsonString(results, summary, warnings = warnings,
                             memThrottledSlots = memThrottledSlots,
                             compileBlock = compileBlock,
                             reuseAlerts = reuseAlerts)
  var tmpFd: cint = -1
  try:
    let flags = O_CREAT or O_EXCL or O_WRONLY or O_CLOEXEC
    tmpFd = posix_mod.open(tmpPath.cstring, flags, Mode(0o600))
    if tmpFd < 0:
      let err = $strerror(errno)
      stderr.write("crisol: warning: could not create temp file for lastrun.json: " &
                   err & "\n")
      return
    # R2-a: use writeAllFd (EINTR-safe, short-write-retry loop) instead of a
    # bare write() call — matches the same pattern used in resultcache/ledger.
    let ok = writeAllFd(tmpFd, jsonStr)
    discard posix_mod.close(tmpFd)
    tmpFd = -1
    if not ok:
      stderr.write("crisol: warning: short write to lastrun.json temp file\n")
      try: removeFile(tmpPath) except: discard
      return
    moveFile(tmpPath, finalPath)
  except OSError as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: could not write lastrun.json: " & e.msg & "\n")
    try: removeFile(tmpPath) except: discard
  except Exception as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: unexpected error writing lastrun.json: " &
                 e.msg & "\n")
    try: removeFile(tmpPath) except: discard

# ---------------------------------------------------------------------------
# loadLastRun -- B7: read back the failed (path,group) set
# ---------------------------------------------------------------------------

const FailureOutcomeStrings* = failureOutcomeStrings
  ## The set of outcome JSON strings that count as "failed" for --failed.
  ## "passed" and "noTestsRan" are NOT in this set (noTestsRan is a summary
  ## flag, not an outcome string; outcome "passed" is success).
  ## Re-exported from crisol/outcomestrings for backward compatibility.

proc loadLastRun*(config: Config):
    tuple[found: bool; failed: HashSet[tuple[path, group: string]]] =
  ## Read <projectRoot>/<stateDir>/lastrun.json.
  ##
  ## Returns:
  ##   (found: false, failed: {})  — file does not exist (caller → exit 3).
  ##   (found: true,  failed: S)   — file parsed; S is the set of (path,group)
  ##                                 pairs whose outcome is a failure string.
  ##
  ## Raises CrisolError(cekEnvironment) if the file exists but is malformed
  ## or carries an unrecognized schema version.
  let path = stateDirOf(config) / "lastrun.json"

  if not fileExists(path):
    return (found: false, failed: initHashSet[tuple[path, group: string]]())

  var raw: string
  try:
    raw = readFile(path)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "could not read lastrun.json: " & e.msg)

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    raise newCrisolError(cekEnvironment,
      "lastrun.json is malformed JSON: " & e.msg &
      " — run `crisol run` first")

  # Validate schema version.
  if node.kind != JObject or not node.hasKey("schema"):
    raise newCrisolError(cekEnvironment,
      "lastrun.json is missing 'schema' field — run `crisol run` first")
  let schemaVal = node["schema"].getStr("")
  if schemaVal != RunV1Schema:
    raise newCrisolError(cekEnvironment,
      "stale lastrun.json (schema '" & schemaVal &
      "') — run `crisol run` first")

  # A8 forward tolerance: an absent schemaRevision is an old (rev-1) document and
  # is fully readable.  A revision GREATER than what we know is from a future
  # crisol whose additive fields we cannot interpret — treat as no-data (safe
  # cold-start), symmetric with loadLastPlan.  Caller handles found=false (exit 3).
  let rev = node.getOrDefault("schemaRevision").getInt(0)
  if rev > RunV1Revision:
    stderr.write("crisol: warning: lastrun.json schemaRevision " & $rev &
                 " is newer than this crisol understands (max " &
                 $RunV1Revision & "); ignoring it as cold-start\n")
    return (found: false, failed: initHashSet[tuple[path, group: string]]())

  # Parse entrypoints array.
  if not node.hasKey("entrypoints") or node["entrypoints"].kind != JArray:
    raise newCrisolError(cekEnvironment,
      "lastrun.json is missing 'entrypoints' array — run `crisol run` first")

  var failedSet = initHashSet[tuple[path, group: string]]()
  for ep in node["entrypoints"]:
    if ep.kind != JObject: continue
    let epPath    = ep.getOrDefault("path").getStr("")
    let epGroup   = ep.getOrDefault("group").getStr("")
    let epOutcome = ep.getOrDefault("outcome").getStr("")
    if epOutcome in FailureOutcomeStrings:
      failedSet.incl((path: epPath, group: epGroup))

  result = (found: true, failed: failedSet)

# ---------------------------------------------------------------------------
# closureToJsonString — issue #9 slice A: crisol/closure/v1
# ---------------------------------------------------------------------------

const ClosureV1Schema* = "crisol/closure/v1"
  ## Stable schema identifier embedded in every crisol/closure/v1 JSON document.

const ClosureV1Revision* = 1
  ## Integer minor revision of the crisol/closure/v1 schema (A8 convention).

proc closureToJson*(r: ClosureReport): JsonNode =
  ## Pure: serialize a ClosureReport to the crisol/closure/v1 JsonNode.  No I/O.
  ## Deterministic ordering: entries in plan order (as received); each
  ## entry's `closure` array is already sorted by api.closureReport().
  let entriesNode = newJArray()
  for e in r.entries:
    let eNode = newJObject()
    eNode["path"]        = newJString(e.path)
    eNode["group"]       = newJString(e.group)
    eNode["flagHash"]    = newJString(e.flagHash)
    eNode["recorded"]    = newJBool(e.recorded)
    let closureNode = newJArray()
    for f in e.closure:
      closureNode.add newJString(f)
    eNode["closure"]     = closureNode
    eNode["closureHash"] = newJString(e.closureHash)
    entriesNode.add eNode

  result = newJObject()
  result["schema"]         = newJString(ClosureV1Schema)
  result["schemaRevision"] = newJInt(ClosureV1Revision)
  result["entries"]        = entriesNode
  result["warnings"]       = warningsToJsonArray(r.warnings)

proc closureToJsonString*(r: ClosureReport): string =
  ## Pure: compact JSON string of the crisol/closure/v1 document.
  $closureToJson(r)
