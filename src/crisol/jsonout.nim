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
import crisol/types
import crisol/render  # for filterRecordsByTag

# ---------------------------------------------------------------------------
# Stable string mappings
# ---------------------------------------------------------------------------

proc outcomeString*(o: Outcome): string =
  ## Returns the stable JSON string for an Outcome enum value.
  case o
  of oPassed:        "passed"
  of oFailed:        "exitNonZero"
  of oCompileFailed: "compileFailed"
  of oTimeout:       "timedOut"
  of oSignal:        "signaled"
  of oSpawnError:    "spawnError"

proc recordStatusString*(s: RecordStatus): string =
  ## Returns the stable JSON string for a RecordStatus enum value.
  case s
  of rsPass: "pass"
  of rsFail: "fail"
  of rsSkip: "skip"

# ---------------------------------------------------------------------------
# toJson -- pure serializer
# ---------------------------------------------------------------------------

proc toJson*(results: seq[EntrypointResult]; summary: Summary;
             filterTag: string = ""): JsonNode =
  ## Pure: serialize to the crisol/run/v1 JsonNode.
  ## No I/O.
  ## C3: when filterTag is non-empty, each entrypoint's records array contains
  ## only records whose tags include filterTag.  The summary block always
  ## reflects the full unfiltered run (no re-counting from filtered records).

  # Build summary object (always full-run counts)
  let summaryNode = newJObject()
  summaryNode["total"]         = newJInt(summary.total)
  summaryNode["passed"]        = newJInt(summary.passed)
  summaryNode["failed"]        = newJInt(summary.failed)
  summaryNode["compileFailed"] = newJInt(summary.compileFailed)
  summaryNode["timedOut"]      = newJInt(summary.timedOut)
  summaryNode["signaled"]      = newJInt(summary.signaled)
  summaryNode["spawnErrors"]   = newJInt(summary.spawnErrors)
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
    epNode["path"]       = newJString(r.ep.path)
    epNode["group"]      = newJString(r.ep.group)
    epNode["outcome"]    = newJString(outcomeString(r.outcome))
    epNode["exitCode"]   = newJInt(r.exitCode)
    if r.outcome == oSignal:
      epNode["signal"] = newJInt(r.signal)
    else:
      epNode["signal"] = newJNull()
    epNode["durationMs"] = newJFloat(r.durationMs.float)
    epNode["records"]    = recordsNode
    entrypointsNode.add epNode

  # Assemble top-level object
  result = newJObject()
  result["schema"]      = newJString("crisol/run/v1")
  result["summary"]     = summaryNode
  result["entrypoints"] = entrypointsNode

proc toJsonString*(results: seq[EntrypointResult]; summary: Summary;
                   filterTag: string = ""): string =
  ## Pure: compact JSON string of the crisol/run/v1 document.
  ## C3: filterTag threads through to toJson.
  $toJson(results, summary, filterTag)

# ---------------------------------------------------------------------------
# persistLastRun -- effectful
# ---------------------------------------------------------------------------

proc persistLastRun*(results: seq[EntrypointResult]; summary: Summary;
                     config: Config) =
  ## Write lastrun.json atomically to <projectRoot>/<stateDir>/lastrun.json.
  ## Creates the state directory if it does not exist.
  ## On any failure: prints a warning to stderr and returns -- never raises.
  let stateDir = config.projectRoot / config.stateDir
  let finalPath = stateDir / "lastrun.json"

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return

  # Write to a temp file in the same directory, then rename (atomic on POSIX).
  let tmpPath = finalPath & ".tmp"
  try:
    let jsonStr = toJsonString(results, summary)
    writeFile(tmpPath, jsonStr)
    moveFile(tmpPath, finalPath)
  except OSError as e:
    stderr.write("crisol: warning: could not write lastrun.json: " & e.msg & "\n")
    # Try to clean up tmp file; ignore errors.
    try: removeFile(tmpPath) except: discard
  except Exception as e:
    stderr.write("crisol: warning: unexpected error writing lastrun.json: " &
                 e.msg & "\n")
    try: removeFile(tmpPath) except: discard

# ---------------------------------------------------------------------------
# loadLastRun -- B7: read back the failed (path,group) set
# ---------------------------------------------------------------------------

const FailureOutcomeStrings* = ["exitNonZero", "compileFailed", "timedOut",
                                 "signaled", "spawnError"]
  ## The set of outcome JSON strings that count as "failed" for --failed.
  ## "passed" and "noTestsRan" are NOT in this set (noTestsRan is a summary
  ## flag, not an outcome string; outcome "passed" is success).

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
  let path = config.projectRoot / config.stateDir / "lastrun.json"

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
  if schemaVal != "crisol/run/v1":
    raise newCrisolError(cekEnvironment,
      "stale lastrun.json (schema '" & schemaVal &
      "') — run `crisol run` first")

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
