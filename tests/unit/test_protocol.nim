## test_protocol.nim — unit suite for crisol/protocol (B1 slice)
##
## Covers:
##   • Header encode/decode round-trip
##   • Record encode/decode round-trips for each status + edge cases
##   • readSink: well-formed multi-record sink
##   • readSink: truncated final line (reader contract)
##   • readSink: opaque fallback (missing file, empty file, zero valid records)
##   • reconcile: OR-rule for all combinations
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_protocol.nim

import std/[os, options, strutils, unittest]
import crisol/types
import crisol/protocol

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc writeSinkFile(path: string; lines: seq[string]) =
  ## Write lines to path, each followed by '\n'.
  createDir(path.parentDir)
  var content = ""
  for ln in lines: content &= ln & "\n"
  writeFile(path, content)

proc writeSinkFileNoFinalNewline(path: string; lines: seq[string]; partial: string) =
  ## Write complete lines (each '\n'-terminated) then append an
  ## unterminated fragment to simulate a mid-write crash.
  createDir(path.parentDir)
  var content = ""
  for ln in lines: content &= ln & "\n"
  content &= partial
  writeFile(path, content)

proc makeTempSink(tag: string): string =
  getTempDir() / ("crisol_proto_" & tag) / "sink.ndjson"

proc cleanup(path: string) =
  try: removeDir(path.parentDir) except: discard

# ---------------------------------------------------------------------------
# Suite 1 — Header round-trip
# ---------------------------------------------------------------------------

suite "protocol – header round-trip":
  test "encodeHeader/decodeHeader preserves all fields":
    let encoded = encodeHeader("tests/unit/test_foo.nim", 12345)
    let hOpt = decodeHeader(encoded)
    check hOpt.isSome
    let h = hOpt.get
    check h.v   == ProtocolVersion
    check h.ep  == "tests/unit/test_foo.nim"
    check h.pid == 12345

  test "decodeHeader returns none for a random JSON object":
    check decodeHeader("""{"name":"x","status":"pass","duration_us":0}""").isNone

  test "decodeHeader returns none for a non-JSON string":
    check decodeHeader("not json at all <<<").isNone

  test "decodeHeader returns none for JSON with wrong sentinel value":
    check decodeHeader("""{"crisol":"notSink","v":1,"ep":"x","pid":1}""").isNone

  test "decodeHeader returns none when required fields are missing":
    check decodeHeader("""{"crisol":"sink","v":1}""").isNone

# ---------------------------------------------------------------------------
# Suite 2 — Record round-trips
# ---------------------------------------------------------------------------

suite "protocol – record round-trips":
  test "pass record round-trips (no msg, no tags)":
    let rec = TestRecord(name: "parses valid input",
                         status: rsPass,
                         durationUs: 12400)
    let decoded = decodeRecord(encodeRecord(rec))
    check decoded.isSome
    let d = decoded.get
    check d.name       == "parses valid input"
    check d.status     == rsPass
    check d.durationUs == 12400
    check d.msg.isNone
    check d.tags.len == 0

  test "fail record round-trips with failure message":
    let rec = TestRecord(name: "rejects empty string",
                         status: rsFail,
                         durationUs: 3100,
                         msg: some("expected Error got nil"))
    let decoded = decodeRecord(encodeRecord(rec))
    check decoded.isSome
    let d = decoded.get
    check d.status == rsFail
    check d.msg == some("expected Error got nil")

  test "skip record round-trips with skip reason":
    let rec = TestRecord(name: "skips on windows",
                         status: rsSkip,
                         durationUs: 0,
                         msg: some("windows-only API"))
    let decoded = decodeRecord(encodeRecord(rec))
    check decoded.isSome
    check decoded.get.status == rsSkip
    check decoded.get.msg    == some("windows-only API")

  test "record with tags round-trips":
    let rec = TestRecord(name: "tagged test",
                         status: rsPass,
                         durationUs: 500,
                         tags: @["unit", "fast"])
    let decoded = decodeRecord(encodeRecord(rec))
    check decoded.isSome
    check decoded.get.tags == @["unit", "fast"]

  test "record with awkward characters in msg round-trips losslessly":
    # Embedded quotes, backslash, and a literal newline in the message.
    let msg = "he said \"hello\"\nand\\slashed"
    let rec = TestRecord(name: "awkward",
                         status: rsFail,
                         durationUs: 1,
                         msg: some(msg))
    let encoded = encodeRecord(rec)
    # Must be a single line (no embedded raw newline in the JSON line).
    check encoded.count('\n') == 0
    let decoded = decodeRecord(encoded)
    check decoded.isSome
    check decoded.get.msg == some(msg)

  test "decodeRecord returns none for a header line":
    let header = encodeHeader("tests/unit/test_foo.nim", 1)
    check decodeRecord(header).isNone

  test "decodeRecord returns none for garbage":
    check decodeRecord("not json").isNone

  test "decodeRecord returns none for JSON missing required fields":
    check decodeRecord("""{"name":"x"}""").isNone

# ---------------------------------------------------------------------------
# Suite 3 — readSink: well-formed sink
# ---------------------------------------------------------------------------

suite "protocol – readSink well-formed":
  test "reads header and multiple records":
    let path = makeTempSink("wellformed")
    defer: cleanup(path)

    let hdr = encodeHeader("tests/unit/test_foo.nim", 99)
    let r1  = encodeRecord(TestRecord(name: "t1", status: rsPass, durationUs: 100))
    let r2  = encodeRecord(TestRecord(name: "t2", status: rsFail, durationUs: 200,
                                      msg: some("boom")))
    let r3  = encodeRecord(TestRecord(name: "t3", status: rsSkip, durationUs: 0,
                                      msg: some("skipped")))
    writeSinkFile(path, @[hdr, r1, r2, r3])

    let data = readSink(path)
    check data.hasProtocol
    check data.header.isSome
    check data.header.get.ep  == "tests/unit/test_foo.nim"
    check data.header.get.pid == 99
    check data.records.len == 3
    check data.records[0].name   == "t1"
    check data.records[0].status == rsPass
    check data.records[1].name   == "t2"
    check data.records[1].status == rsFail
    check data.records[2].status == rsSkip
    check not data.truncated

  test "sink with only header and zero records → hasProtocol true, empty records":
    let path = makeTempSink("headeronly")
    defer: cleanup(path)
    writeSinkFile(path, @[encodeHeader("ep.nim", 1)])
    let data = readSink(path)
    check data.hasProtocol
    check data.records.len == 0

# ---------------------------------------------------------------------------
# Suite 4 — readSink: truncated final line (reader contract rule 1)
# ---------------------------------------------------------------------------

suite "protocol – readSink truncated final line":
  test "partial JSON fragment at EOF is discarded; prior records kept":
    let path = makeTempSink("truncated")
    defer: cleanup(path)

    let hdr = encodeHeader("tests/unit/test_foo.nim", 1)
    let r1  = encodeRecord(TestRecord(name: "good", status: rsPass, durationUs: 50))
    writeSinkFileNoFinalNewline(path, @[hdr, r1], "{\"name\":\"partial")

    let data = readSink(path)
    check data.hasProtocol
    check data.records.len == 1
    check data.records[0].name == "good"
    check data.truncated

  test "only header + partial record → hasProtocol true, zero records, truncated":
    let path = makeTempSink("truncated2")
    defer: cleanup(path)
    writeSinkFileNoFinalNewline(path, @[encodeHeader("ep.nim", 1)], "{\"name\":")
    let data = readSink(path)
    check data.hasProtocol
    check data.records.len == 0
    check data.truncated

  test "completely unterminated header (only fragment, no newline) → opaque fallback":
    let path = makeTempSink("truncated3")
    defer: cleanup(path)
    # File contains only an unterminated header fragment.
    createDir(path.parentDir)
    writeFile(path, "{\"crisol\":\"sink\",\"v\":1")
    let data = readSink(path)
    # The only line is partial → dropped → no header parsed → no protocol
    check not data.hasProtocol

# ---------------------------------------------------------------------------
# Suite 5 — readSink: opaque fallback (reader contract rule 3)
# ---------------------------------------------------------------------------

suite "protocol – readSink opaque fallback":
  test "missing file → hasProtocol false":
    let data = readSink("/tmp/crisol_nonexistent_9999.ndjson")
    check not data.hasProtocol
    check data.records.len == 0

  test "empty file → hasProtocol false":
    let path = makeTempSink("empty")
    defer: cleanup(path)
    createDir(path.parentDir)
    writeFile(path, "")
    let data = readSink(path)
    check not data.hasProtocol

  test "file with no valid header line → hasProtocol false":
    let path = makeTempSink("noheader")
    defer: cleanup(path)
    # Write records without a header
    let r1 = encodeRecord(TestRecord(name: "t1", status: rsPass, durationUs: 0))
    writeSinkFile(path, @[r1])
    let data = readSink(path)
    check not data.hasProtocol
    check data.records.len == 0

  test "file with only garbage lines → hasProtocol false":
    let path = makeTempSink("garbage")
    defer: cleanup(path)
    writeSinkFile(path, @["not json", "still not json"])
    let data = readSink(path)
    check not data.hasProtocol

# ---------------------------------------------------------------------------
# Suite 6 — reconcile: OR rule (reader contract rule 2)
# ---------------------------------------------------------------------------

suite "protocol – reconcile OR rule":
  test "all-pass records + exit 0 → oPassed":
    let recs = @[
      TestRecord(name: "t1", status: rsPass, durationUs: 0),
      TestRecord(name: "t2", status: rsPass, durationUs: 0),
    ]
    check reconcile(recs, 0) == oPassed

  test "all-skip records + exit 0 → oPassed":
    let recs = @[
      TestRecord(name: "t1", status: rsSkip, durationUs: 0, msg: some("skip")),
    ]
    check reconcile(recs, 0) == oPassed

  test "mix pass+skip records + exit 0 → oPassed":
    let recs = @[
      TestRecord(name: "t1", status: rsPass, durationUs: 0),
      TestRecord(name: "t2", status: rsSkip, durationUs: 0),
    ]
    check reconcile(recs, 0) == oPassed

  test "any fail record + exit 0 → oFailed (OR rule)":
    let recs = @[
      TestRecord(name: "t1", status: rsPass, durationUs: 0),
      TestRecord(name: "t2", status: rsFail, durationUs: 0, msg: some("boom")),
    ]
    check reconcile(recs, 0) == oFailed

  test "all-pass records + non-zero exit → oFailed (OR rule)":
    let recs = @[
      TestRecord(name: "t1", status: rsPass, durationUs: 0),
    ]
    check reconcile(recs, 1) == oFailed

  test "fail record + non-zero exit → oFailed":
    let recs = @[
      TestRecord(name: "t1", status: rsFail, durationUs: 0),
    ]
    check reconcile(recs, 1) == oFailed

  test "opaque fallback path: no records + exit 0 → oPassed":
    ## When the executor detects opaque fallback (hasProtocol=false), it
    ## interprets exit code directly without calling reconcile.  But to verify
    ## the rule is internally consistent: reconcile on empty records + exit 0
    ## must also yield oPassed.
    check reconcile(@[], 0) == oPassed

  test "opaque fallback path: no records + non-zero exit → oFailed":
    check reconcile(@[], 1) == oFailed
