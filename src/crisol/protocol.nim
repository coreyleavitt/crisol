## protocol.nim — crisol result protocol codec + host-side sink reader
##
## Implements the B1 slice: NDJSON wire format (header + test records),
## the host-side sink reader with full reader-contract compliance, and
## the OR-rule reconciliation helper.
##
## Wire format (NDJSON — one JSON object per line, newline-terminated):
##   Line 1: header  {"crisol":"sink","v":1,"ep":"<path>","pid":<n>}
##   Line N: record  {"name":"...","status":"pass"|"fail"|"skip",
##                    "duration_us":<int>, ["msg":"..."], ["tags":[...]]}
##
## Reader contract (from RFC §Result Protocol §Reader contract):
##   1. Truncated final line: an incomplete JSON fragment at EOF (no trailing
##      newline) is discarded silently; prior complete records are kept.
##   2. Records + non-zero exit (OR rule): caller applies
##      `reconcile(records) or exitCode != 0`.
##   3. Opaque fallback: no sink file, empty file, or zero valid records →
##      SinkData.hasProtocol = false; executor falls back to exit-code-only.
##
## rfc-0007 §2: reconcile() shrank to a records-only predicate (bool, not
## Outcome) — the executor-precedence rule (a killed/signaled process's
## records never override the executor's verdict) is now subsumed by the
## `outcome(r)` derivation (`cause.by == cbRunner` dominates before records
## are ever consulted), so it is no longer reconcile()'s job to encode. Call
## reconcile() only when the process exited normally (no signal/timeout).
##
## All functions here are pure except readSink (reads one file).

import std/[json, options, os, strutils]
import crisol/types

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  ProtocolVersion* = 1
  SentinelKey      = "crisol"
  SentinelVal      = "sink"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

type
  SinkHeader* = object
    ## Decoded header record from the first line of a sink file.
    v*:   int     ## protocol schema version
    ep*:  string  ## entrypoint path (advisory, debugging only)
    pid*: int     ## PID of the writer process

proc encodeHeader*(ep: string; pid: int): string =
  ## Encode the sink header as a single NDJSON line (no trailing newline).
  ## Callers must append '\n' before writing to file.
  let n = newJObject()
  n[SentinelKey] = newJString(SentinelVal)
  n["v"]         = newJInt(ProtocolVersion)
  n["ep"]        = newJString(ep)
  n["pid"]       = newJInt(pid)
  $n

proc decodeHeader*(line: string): Option[SinkHeader] =
  ## Parse a header line. Returns none if the line is not a valid crisol
  ## sink header (wrong sentinel, missing fields, or bad JSON).
  try:
    let j = parseJson(line)
    if j.kind != JObject: return none(SinkHeader)
    if not j.hasKey(SentinelKey): return none(SinkHeader)
    if j[SentinelKey].getStr != SentinelVal: return none(SinkHeader)
    if not (j.hasKey("v") and j.hasKey("ep") and j.hasKey("pid")):
      return none(SinkHeader)
    some(SinkHeader(
      v:   j["v"].getInt,
      ep:  j["ep"].getStr,
      pid: j["pid"].getInt,
    ))
  except:
    none(SinkHeader)

# ---------------------------------------------------------------------------
# Record codec
# ---------------------------------------------------------------------------

proc statusStr(s: RecordStatus): string =
  case s
  of rsPass: "pass"
  of rsFail: "fail"
  of rsSkip: "skip"

proc parseStatus(s: string): Option[RecordStatus] =
  case s
  of "pass": some(rsPass)
  of "fail": some(rsFail)
  of "skip": some(rsSkip)
  else:      none(RecordStatus)

proc encodeRecord*(rec: TestRecord): string =
  ## Encode a TestRecord as a single NDJSON line (no trailing newline).
  let n = newJObject()
  n["name"]        = newJString(rec.name)
  n["status"]      = newJString(statusStr(rec.status))
  n["duration_us"] = newJInt(rec.durationUs)
  if rec.msg.isSome:
    n["msg"] = newJString(rec.msg.get)
  if rec.tags.len > 0:
    let arr = newJArray()
    for t in rec.tags: arr.add newJString(t)
    n["tags"] = arr
  $n

proc decodeRecord*(line: string): Option[TestRecord] =
  ## Parse a record line. Returns none if the line is not a valid test record
  ## (missing required fields, bad JSON, or unrecognised status string).
  try:
    let j = parseJson(line)
    if j.kind != JObject: return none(TestRecord)
    # A record must NOT be a header sentinel
    if j.hasKey(SentinelKey): return none(TestRecord)
    if not (j.hasKey("name") and j.hasKey("status") and j.hasKey("duration_us")):
      return none(TestRecord)
    let statusOpt = parseStatus(j["status"].getStr)
    if statusOpt.isNone: return none(TestRecord)
    var rec = TestRecord(
      name:       j["name"].getStr,
      status:     statusOpt.get,
      durationUs: j["duration_us"].getBiggestInt,
    )
    if j.hasKey("msg"):
      rec.msg = some(j["msg"].getStr)
    if j.hasKey("tags"):
      let arr = j["tags"]
      if arr.kind == JArray:
        for el in arr:
          rec.tags.add el.getStr
    some(rec)
  except:
    none(TestRecord)

# ---------------------------------------------------------------------------
# Sink data + reader
# ---------------------------------------------------------------------------

type
  SinkData* = object
    ## Result of reading a sink file.
    hasProtocol*:  bool           ## false → opaque fallback (no valid records)
    header*:       Option[SinkHeader]
    records*:      seq[TestRecord]
    truncated*:    bool           ## true → final line was a partial/invalid fragment

const DefaultSinkMaxBytes* = 10 * 1024 * 1024  ## 10 MiB cap for sink file reads.

proc readSink*(path: string; maxBytes: int = DefaultSinkMaxBytes): SinkData =
  ## Read and parse a sink file.  Implements the full reader contract:
  ##
  ##   • Truncated final line: if the last line has no trailing newline (or
  ##     is invalid JSON), it is discarded; prior complete records are kept
  ##     and truncated is set to true.
  ##
  ##   • Opaque fallback: file absent, empty, or has zero valid records →
  ##     hasProtocol = false; caller must use exit-code-only interpretation.
  ##
  ##   • Corruption (invalid line NOT at EOF, followed by more valid lines):
  ##     not silently dropped — treated the same as a valid record that
  ##     failed to parse (skipped with truncated=true, which is a safe
  ##     conservative signal for the caller).
  ##     RFC: "reported as a sink-corruption warning … never silently dropped"
  ##     — the caller may log this if truncated=true and more records follow.
  ##
  ##   • Size cap (M7): if the file exceeds maxBytes, only the first maxBytes
  ##     are read.  SinkData.truncated is set to true in that case.
  ##     Callers should pass config.maxOutputBytes or a dedicated constant.
  ##     Defaults to DefaultSinkMaxBytes (10 MiB).

  # Absent file → opaque fallback
  if not fileExists(path):
    return SinkData(hasProtocol: false)

  let fileSize = getFileSize(path)
  if fileSize == 0:
    return SinkData(hasProtocol: false)

  # M7: size-cap — read only up to maxBytes to prevent OOM on runaway sinks.
  var raw: string
  var sizeCapTruncated = false
  if fileSize > int64(maxBytes):
    sizeCapTruncated = true
    let f = open(path, fmRead)
    defer: f.close()
    raw = newString(maxBytes)
    discard f.readBuffer(addr raw[0], maxBytes)
  else:
    raw = readFile(path)

  if raw.len == 0:
    return SinkData(hasProtocol: false)

  # Split on newlines.  A well-formed sink always ends with '\n'; if the
  # final byte is NOT '\n', the last element is a partial/truncated line.
  # When size-cap truncation occurred, the final fragment is always dropped.
  let endsWithNewline = raw[^1] == '\n'
  var lines = raw.splitLines   # splitLines drops a trailing empty element

  # splitLines on "a\nb\n" → @["a","b"]; on "a\nb" → @["a","b"]
  # The distinction is captured by endsWithNewline.
  var truncatedLine = sizeCapTruncated  # start true if already size-capped

  if (not endsWithNewline or sizeCapTruncated) and lines.len > 0:
    # Drop the final (unterminated or possibly-partial) line as per reader contract.
    lines.setLen(lines.len - 1)
    truncatedLine = true

  var data = SinkData(truncated: truncatedLine)

  for line in lines:
    if line.len == 0: continue   # blank line between records (shouldn't happen but tolerate)

    # First non-blank line must be the header
    if data.header.isNone:
      let hOpt = decodeHeader(line)
      if hOpt.isNone:
        # First line is not a valid header → no protocol
        return SinkData(hasProtocol: false, truncated: truncatedLine)
      data.header = hOpt
      continue

    # Subsequent lines are records
    let recOpt = decodeRecord(line)
    if recOpt.isSome:
      data.records.add recOpt.get
    else:
      # Invalid line that is NOT the final line → corruption, not truncation.
      # Mark truncated as a conservative signal; don't fail the whole parse.
      data.truncated = true

  # hasProtocol iff we found a valid header (even with zero records)
  data.hasProtocol = data.header.isSome
  data

# ---------------------------------------------------------------------------
# Reconciliation
# ---------------------------------------------------------------------------

proc reconcile*(records: seq[TestRecord]): bool =
  ## rfc-0007 A1c: shrunk to a records-only predicate — true iff any PARSED
  ## record is rsFail. Feeds crisol/types.hasFailRecords' definition (the
  ## same rule, over an EntrypointResult's stored records).
  ##
  ## The exit-code OR-rule and the former executor-precedence rule (a
  ## killed/crashed process's records never override the executor's verdict)
  ## are now subsumed by the `outcome(r)` derivation (§2): `cause.by ==
  ## cbRunner` dominates before records are ever consulted, so callers apply
  ## the OR-rule themselves — `reconcile(records) or exitCode != 0` — only
  ## when the process exited normally.
  ##
  ## Truncated-stream conservatism is preserved unchanged: this reads
  ## whatever records were successfully parsed (readSink already dropped an
  ## unparseable tail per the reader contract) and never fabricates a failure
  ## from truncation itself — a truncated stream with zero parsed records
  ## returns false, same as an empty stream.
  for rec in records:
    if rec.status == rsFail:
      return true
  false
