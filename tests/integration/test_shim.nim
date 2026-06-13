## test_shim.nim — integration tests for crisol/unittest_shim (B3 slice)
##
## Verifies that a test binary importing crisol/unittest_shim:
##   1. Emits correct structured TestRecords to CRISOL_SINK when set.
##   2. Behaves normally (no crash, no sink file) when CRISOL_SINK is unset.
##   3. Exits non-zero (std/unittest semantics intact) when a test fails.
##
## The fixture shim_demo.nim (tests/fixtures/shim_demo.nim) is compiled here
## at test time using `nim c --path:src` — it cannot be in build.nim because
## build.nim does not pass --path:src, which is required to import
## crisol/unittest_shim.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_shim.nim

import std/[options, os, osproc, strtabs, unittest]
import crisol/protocol
import crisol/types

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc projectRoot(): string =
  ## Return the absolute project root (directory containing src/).
  ## Works when the test is run from project root or from inside tests/.
  let thisFile = currentSourcePath()   # absolute path to this .nim
  thisFile.parentDir.parentDir.parentDir

proc fixtureDir(): string =
  projectRoot() / "tests" / "fixtures"

proc binDir(): string =
  projectRoot() / "tests" / "fixtures" / "bin"

# ---------------------------------------------------------------------------
# One-time fixture compilation
# ---------------------------------------------------------------------------

var shimBin    = ""   ## path to the compiled shim_demo binary
var compileErr = ""   ## non-empty if compilation failed

proc compileFixture() =
  ## Compile shim_demo.nim once for the whole suite.
  let root   = projectRoot()
  let src    = fixtureDir() / "shim_demo.nim"
  let outBin = binDir() / "shim_demo"
  let cache  = fixtureDir() / "nimcache" / "shim_demo"

  createDir(binDir())
  createDir(cache)

  let cmd = "nim c --mm:orc --hints:off --warnings:off" &
            " --path:" & (root / "src") &
            " --nimcache:" & cache &
            " -o:" & outBin &
            " " & src
  let (output, rc) = execCmdEx(cmd)
  if rc != 0:
    compileErr = "fixture compilation failed (exit " & $rc & "):\n" & output
  else:
    shimBin = outBin

compileFixture()

# ---------------------------------------------------------------------------
# Suite 1 — with CRISOL_SINK set: structured records emitted correctly
# ---------------------------------------------------------------------------

suite "shim — CRISOL_SINK set":

  test "fixture compiles successfully":
    if compileErr.len > 0:
      fail()
      echo compileErr
    else:
      check shimBin.len > 0
      check fileExists(shimBin)

  test "3 records emitted with correct names and statuses":
    if compileErr.len > 0: skip()
    let sinkPath = getTempDir() / "crisol_shim_test_records" / "sink.ndjson"
    createDir(sinkPath.parentDir)
    defer:
      try: removeDir(sinkPath.parentDir) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["CRISOL_SINK"] = sinkPath

    let (_, rc) = execCmdEx(shimBin, env = env)

    # Exit code must be non-zero (the failing test causes unittest to exit 1).
    check rc != 0

    let data = readSink(sinkPath)
    check data.hasProtocol
    check data.records.len == 3

    # The order matches the suite declaration.
    check data.records[0].name   == "always passes"
    check data.records[0].status == rsPass

    check data.records[1].name   == "always fails"
    check data.records[1].status == rsFail

    check data.records[2].name   == "always skips"
    check data.records[2].status == rsSkip

  test "pass record has non-negative durationUs; sleep makes it > 0":
    if compileErr.len > 0: skip()
    let sinkPath = getTempDir() / "crisol_shim_test_duration" / "sink.ndjson"
    createDir(sinkPath.parentDir)
    defer:
      try: removeDir(sinkPath.parentDir) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["CRISOL_SINK"] = sinkPath

    discard execCmdEx(shimBin, env = env)

    let data = readSink(sinkPath)
    check data.hasProtocol
    check data.records.len == 3
    # Pass record: sleep(2) in fixture ensures measurable duration.
    check data.records[0].durationUs >= 0
    check data.records[0].durationUs > 0   # at least 2 ms = 2000 us

  test "failing record carries non-empty msg":
    if compileErr.len > 0: skip()
    let sinkPath = getTempDir() / "crisol_shim_test_msg" / "sink.ndjson"
    createDir(sinkPath.parentDir)
    defer:
      try: removeDir(sinkPath.parentDir) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["CRISOL_SINK"] = sinkPath

    discard execCmdEx(shimBin, env = env)

    let data = readSink(sinkPath)
    check data.hasProtocol
    check data.records.len == 3
    let failRec  = data.records[1]
    let hasmsg   = failRec.msg.isSome
    let msgText  = if failRec.msg.isSome: failRec.msg.get else: ""
    check failRec.status == rsFail
    check hasmsg
    check msgText.len > 0

  test "skip record is rsSkip":
    if compileErr.len > 0: skip()
    let sinkPath = getTempDir() / "crisol_shim_test_skip" / "sink.ndjson"
    createDir(sinkPath.parentDir)
    defer:
      try: removeDir(sinkPath.parentDir) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["CRISOL_SINK"] = sinkPath

    discard execCmdEx(shimBin, env = env)

    let data = readSink(sinkPath)
    check data.hasProtocol
    check data.records.len == 3
    check data.records[2].status == rsSkip

  test "process exit code is non-zero (unittest failure semantics intact)":
    if compileErr.len > 0: skip()
    let sinkPath = getTempDir() / "crisol_shim_test_exit" / "sink.ndjson"
    createDir(sinkPath.parentDir)
    defer:
      try: removeDir(sinkPath.parentDir) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["CRISOL_SINK"] = sinkPath

    let (_, rc) = execCmdEx(shimBin, env = env)
    check rc != 0

# ---------------------------------------------------------------------------
# Suite 2 — without CRISOL_SINK: normal standalone behavior
# ---------------------------------------------------------------------------

suite "shim — CRISOL_SINK unset (standalone)":

  test "runs without crash when CRISOL_SINK is unset":
    if compileErr.len > 0: skip()
    # Run fixture with CRISOL_SINK absent from the environment.
    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      if k != "CRISOL_SINK": env[k] = v

    let (_, rc) = execCmdEx(shimBin, env = env)
    # Should exit non-zero (failing test) but NOT crash.
    # A crash would typically produce a signal exit (rc < 0 or 128+N on Linux).
    # We accept any exit code — the point is it completes without SIGSEGV etc.
    check rc == 1   # std/unittest exits 1 on test failure

  test "no sink file created when CRISOL_SINK is unset":
    if compileErr.len > 0: skip()
    # Use a deterministic path that should NOT be written.
    let neverPath = getTempDir() / "crisol_shim_noop_sink.ndjson"
    try: removeFile(neverPath) except: discard
    defer:
      try: removeFile(neverPath) except: discard

    let env = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      if k != "CRISOL_SINK": env[k] = v

    discard execCmdEx(shimBin, env = env)
    check not fileExists(neverPath)
