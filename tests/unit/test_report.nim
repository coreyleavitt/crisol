## test_report.nim — unit suite for crisol/report (B2 slice)
##
## Covers:
##   1. CRISOL_SINK set  — initReport opens file, writes header, emits records
##   2. Flush-per-record — after N emits the file contains N+1 complete lines
##      (header + N records) before process exit
##   3. CRISOL_SINK unset — no file created, no exception
##   4. Round-trip integrity — awkward chars survive encode→file→readSink
##
## Note on module-global state: report.nim uses module-global state, so each
## test calls resetReport() before initReport() to avoid state leakage.
## The unset-CRISOL_SINK test is run after the set tests so it doesn't race
## with them (but any ordering is safe given resetReport() calls).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_report.nim

import std/[os, options, sequtils, strutils, unittest]
import crisol/types
import crisol/protocol
import crisol/report

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTempSink(tag: string): string =
  getTempDir() / ("crisol_report_" & tag) / "sink.ndjson"

proc cleanup(path: string) =
  try: removeDir(path.parentDir) except: discard

# ---------------------------------------------------------------------------
# Suite 1 — CRISOL_SINK set: header + records round-trip via readSink
# ---------------------------------------------------------------------------

suite "report – CRISOL_SINK set":
  test "initReport writes valid header with correct pid and ep":
    let path = makeTempSink("header")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport("tests/unit/test_foo.nim")

    let data = readSink(path)
    check data.hasProtocol
    check data.header.isSome
    check data.header.get.ep  == "tests/unit/test_foo.nim"
    check data.header.get.pid == getCurrentProcessId()
    check data.records.len == 0
    resetReport()

  test "emit produces records readable by readSink in correct order":
    let path = makeTempSink("emit_order")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport("tests/unit/test_emit.nim")

    let r1 = TestRecord(name: "alpha", status: rsPass, durationUs: 100)
    let r2 = TestRecord(name: "beta",  status: rsFail, durationUs: 200,
                        msg: some("expected X got Y"))
    let r3 = TestRecord(name: "gamma", status: rsSkip, durationUs: 0,
                        msg: some("skipped reason"))
    emit(r1)
    emit(r2)
    emit(r3)

    let data = readSink(path)
    check data.hasProtocol
    check data.records.len == 3
    check data.records[0].name   == "alpha"
    check data.records[0].status == rsPass
    check data.records[1].name   == "beta"
    check data.records[1].status == rsFail
    check data.records[1].msg    == some("expected X got Y")
    check data.records[2].name   == "gamma"
    check data.records[2].status == rsSkip
    resetReport()

# ---------------------------------------------------------------------------
# Suite 2 — Flush-per-record durability
# ---------------------------------------------------------------------------

suite "report – flush-per-record durability":
  test "after N emits file contains N+1 complete newline-terminated lines":
    let path = makeTempSink("flush")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport("ep.nim")

    let recs = @[
      TestRecord(name: "t1", status: rsPass, durationUs: 10),
      TestRecord(name: "t2", status: rsPass, durationUs: 20),
      TestRecord(name: "t3", status: rsFail, durationUs: 30, msg: some("oops")),
    ]
    for r in recs: emit(r)

    # Read file directly — before process exit — to verify durability.
    let raw = readFile(path)
    # Each line (header + 3 records) must be newline-terminated.
    check raw.len > 0
    # The file must end with '\n' (last record flushed completely).
    check raw[^1] == '\n'
    # Count lines: split on newlines, filter empty (trailing newline yields empty).
    let lines = raw.split('\n').filterIt(it.len > 0)
    check lines.len == 4  # 1 header + 3 records
    resetReport()

  test "each individual emit is immediately visible (not buffered)":
    let path = makeTempSink("flush2")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport("ep.nim")

    emit(TestRecord(name: "first", status: rsPass, durationUs: 1))
    # After one emit, the file should already have 2 lines (header + 1 record).
    let raw1 = readFile(path)
    let lines1 = raw1.split('\n').filterIt(it.len > 0)
    check lines1.len == 2

    emit(TestRecord(name: "second", status: rsPass, durationUs: 2))
    # After second emit: 3 lines.
    let raw2 = readFile(path)
    let lines2 = raw2.split('\n').filterIt(it.len > 0)
    check lines2.len == 3
    resetReport()

# ---------------------------------------------------------------------------
# Suite 3 — CRISOL_SINK unset: complete no-op
# ---------------------------------------------------------------------------

suite "report – CRISOL_SINK unset":
  test "no file created when CRISOL_SINK is unset":
    resetReport()
    delEnv("CRISOL_SINK")

    # Pick a path that should NOT be created.
    let path = getTempDir() / "crisol_noop_test" / "sink.ndjson"
    cleanup(path)

    initReport("ep.nim")
    emit(TestRecord(name: "should not write", status: rsPass, durationUs: 0))
    emit(TestRecord(name: "also no-op",       status: rsFail, durationUs: 0))

    check not fileExists(path)
    resetReport()

  test "no exception raised from emit when disabled":
    resetReport()
    delEnv("CRISOL_SINK")
    initReport()
    # If this raises, the test framework will catch it and mark the test failed.
    emit(TestRecord(name: "safe", status: rsPass, durationUs: 0))
    emit(TestRecord(name: "safe2", status: rsFail, durationUs: 0,
                    msg: some("irrelevant")))
    check true  # reached here means no exception
    resetReport()

# ---------------------------------------------------------------------------
# Suite 4 — Round-trip integrity (awkward chars via emitter path)
# ---------------------------------------------------------------------------

suite "report – round-trip integrity":
  test "records with special chars survive emitter encode+flush+readSink":
    let path = makeTempSink("roundtrip")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport("tests/unit/test_awkward.nim")

    # Embedded quotes, backslash, and a literal newline in the message —
    # same pattern as test_protocol.nim's awkward-chars test.
    let awkwardMsg  = "he said \"hello\"\nand\\slashed"
    let awkwardName = "test with\ttab and \"quotes\""
    let r = TestRecord(name:       awkwardName,
                       status:     rsFail,
                       durationUs: 42,
                       msg:        some(awkwardMsg),
                       tags:       @["unit", "edge-case"])
    emit(r)

    let data = readSink(path)
    check data.hasProtocol
    check data.records.len == 1
    let d = data.records[0]
    check d.name       == awkwardName
    check d.status     == rsFail
    check d.durationUs == 42
    check d.msg        == some(awkwardMsg)
    check d.tags       == @["unit", "edge-case"]
    resetReport()

  test "empty ep string is preserved in header":
    let path = makeTempSink("empty_ep")
    defer: cleanup(path)
    resetReport()
    createDir(path.parentDir)
    putEnv("CRISOL_SINK", path)
    defer: delEnv("CRISOL_SINK")

    initReport()  # ep defaults to ""

    let data = readSink(path)
    check data.hasProtocol
    check data.header.isSome
    check data.header.get.ep == ""
    resetReport()
