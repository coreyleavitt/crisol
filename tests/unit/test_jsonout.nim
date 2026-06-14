## test_jsonout.nim -- unit tests for crisol/jsonout (B5 slice)
##
## Covers:
##   1. Schema stability / completeness: toJson over mixed-outcome results
##      -> version field, summary counts, entrypoints array, outcome/status
##         are STRINGS (not integers), failing entrypoint record carries msg.
##   2. lastrun.json persistence: persistLastRun writes valid JSON to
##      <stateDir>/lastrun.json; file is valid JSON matching toJson output.
##   3. --json CLI behavior: runMain(["run", <fixture>, "--json"]) ->
##      stdout is valid JSON, no human-render lines, exit code matches.
##      runMain without --json still writes lastrun.json.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_jsonout.nim

import std/[json, monotimes, options, os, sequtils, sets, strutils, unittest]
import std/posix as posix_mod
import crisol/types
import crisol/jsonout
import crisol

# ---------------------------------------------------------------------------
# Helpers -- build synthetic EntrypointResults
# ---------------------------------------------------------------------------

proc makeEp(path: string; group: string = "unit"): Entrypoint =
  Entrypoint(path: path, group: group, flags: @[])

proc makeRecord(name: string; status: RecordStatus;
                msg: string = ""; tags: seq[string] = @[]): TestRecord =
  TestRecord(
    name:       name,
    status:     status,
    durationUs: 12_345,
    msg:        if msg.len > 0: some(msg) else: none(string),
    tags:       tags,
  )

proc syntheticResults(): seq[EntrypointResult] =
  ## One result per distinct Outcome; each with representative records.
  result = @[
    # Passed -- rsPass + rsSkip records
    EntrypointResult(
      ep:         makeEp("tests/unit/test_alpha.nim"),
      outcome:    oPassed,
      exitCode:   0,
      signal:     0,
      durationMs: 123,
      records:    @[
        makeRecord("alpha passes",  rsPass),
        makeRecord("alpha skipped", rsSkip, "not applicable"),
      ],
    ),
    # Failed -- rsFail record with msg
    EntrypointResult(
      ep:         makeEp("tests/unit/test_beta.nim"),
      outcome:    oFailed,
      exitCode:   1,
      signal:     0,
      durationMs: 456,
      records:    @[
        makeRecord("beta passes",  rsPass),
        makeRecord("beta fails",   rsFail, "expected 1 got 2"),
      ],
    ),
    # CompileFailed -- no records
    EntrypointResult(
      ep:         makeEp("tests/unit/test_gamma.nim"),
      outcome:    oCompileFailed,
      exitCode:   1,
      signal:     0,
      durationMs: 789,
      records:    @[],
    ),
    # Timeout -- no records
    EntrypointResult(
      ep:         makeEp("tests/integration/test_delta.nim", "integration"),
      outcome:    oTimeout,
      exitCode:   0,
      signal:     0,
      durationMs: 300_000,
      records:    @[],
    ),
    # Signal -- no records
    EntrypointResult(
      ep:         makeEp("tests/unit/test_epsilon.nim"),
      outcome:    oSignal,
      exitCode:   0,
      signal:     11,   # SIGSEGV
      durationMs: 50,
      records:    @[],
    ),
    # SpawnError -- no records
    EntrypointResult(
      ep:         makeEp("tests/unit/test_zeta.nim"),
      outcome:    oSpawnError,
      exitCode:   0,
      signal:     0,
      durationMs: 0,
      records:    @[],
    ),
  ]

proc syntheticSummary(): Summary =
  Summary(
    total:         6,
    passed:        1,
    failed:        1,
    compileFailed: 1,
    timedOut:      1,
    signaled:      1,
    spawnErrors:   1,
    noTestsRan:    false,
  )

# ---------------------------------------------------------------------------
# Suite 1 -- Schema stability / completeness
# ---------------------------------------------------------------------------

suite "jsonout - toJson schema":

  test "top-level schema field is crisol/run/v1":
    let node = toJson(syntheticResults(), syntheticSummary())
    check node.kind == JObject
    check node.hasKey("schema")
    check node["schema"].getStr == "crisol/run/v1"

  test "top-level has summary, entrypoints, and warnings keys":
    let node = toJson(syntheticResults(), syntheticSummary())
    check node.hasKey("summary")
    check node.hasKey("entrypoints")
    check node.hasKey("warnings")

  test "run/v1 warnings array is empty when no warnings passed":
    let node = toJson(syntheticResults(), syntheticSummary())
    check node["warnings"].kind == JArray
    check node["warnings"].len == 0

  test "run/v1 warnings array carries ConfigWarning fields when provided":
    let warn = ConfigWarning(
      source:  "/proj/crisol.kdl",
      context: "integration",
      key:     "max-retries",
      message: "unknown config key 'max-retries' in integration (ignored)",
    )
    let node = toJson(syntheticResults(), syntheticSummary(), warnings = @[warn])
    check node["warnings"].len == 1
    let w = node["warnings"][0]
    check w["source"].getStr  == "/proj/crisol.kdl"
    check w["context"].getStr == "integration"
    check w["key"].getStr     == "max-retries"
    check "max-retries" in w["message"].getStr

  test "summary counts match input Summary":
    let s    = syntheticSummary()
    let node = toJson(syntheticResults(), s)
    let sum  = node["summary"]
    check sum["total"].getInt         == s.total
    check sum["passed"].getInt        == s.passed
    check sum["failed"].getInt        == s.failed
    check sum["compileFailed"].getInt == s.compileFailed
    check sum["timedOut"].getInt      == s.timedOut
    check sum["signaled"].getInt      == s.signaled
    check sum["spawnErrors"].getInt   == s.spawnErrors
    check sum["noTestsRan"].getBool   == s.noTestsRan

  test "entrypoints array has correct length":
    let results = syntheticResults()
    let node    = toJson(results, syntheticSummary())
    check node["entrypoints"].len == results.len

  test "outcome field is a STRING not an integer":
    let node = toJson(syntheticResults(), syntheticSummary())
    for ep in node["entrypoints"]:
      check ep["outcome"].kind == JString

  test "outcome string values are stable expected strings":
    let results = syntheticResults()
    let node    = toJson(results, syntheticSummary())
    let eps     = node["entrypoints"]
    # Order matches syntheticResults()
    check eps[0]["outcome"].getStr == "passed"
    check eps[1]["outcome"].getStr == "exitNonZero"
    check eps[2]["outcome"].getStr == "compileFailed"
    check eps[3]["outcome"].getStr == "timedOut"
    check eps[4]["outcome"].getStr == "signaled"
    check eps[5]["outcome"].getStr == "spawnError"

  test "record status field is a STRING not an integer":
    let node = toJson(syntheticResults(), syntheticSummary())
    for ep in node["entrypoints"]:
      for rec in ep["records"]:
        check rec["status"].kind == JString

  test "record status string values are stable expected strings":
    ## The first result (passed) has a rsPass and a rsSkip record.
    ## The second result (failed) has a rsPass and a rsFail record.
    let node = toJson(syntheticResults(), syntheticSummary())
    let eps  = node["entrypoints"]
    check eps[0]["records"][0]["status"].getStr == "pass"
    check eps[0]["records"][1]["status"].getStr == "skip"
    check eps[1]["records"][0]["status"].getStr == "pass"
    check eps[1]["records"][1]["status"].getStr == "fail"

  test "failing entrypoint record carries msg":
    let node    = toJson(syntheticResults(), syntheticSummary())
    let failEp  = node["entrypoints"][1]
    let failRec = failEp["records"][1]   # the rsFail record
    check failRec["msg"].kind == JString
    check failRec["msg"].getStr == "expected 1 got 2"

  test "skip record carries msg":
    let node    = toJson(syntheticResults(), syntheticSummary())
    let passEp  = node["entrypoints"][0]
    let skipRec = passEp["records"][1]   # the rsSkip record
    check skipRec["msg"].kind == JString
    check skipRec["msg"].getStr == "not applicable"

  test "record with no msg has null msg field":
    let node = toJson(syntheticResults(), syntheticSummary())
    # First record of first ep has no msg
    let rec = node["entrypoints"][0]["records"][0]
    check rec["msg"].kind == JNull

  test "signal entrypoint carries signal integer":
    let node  = toJson(syntheticResults(), syntheticSummary())
    let sigEp = node["entrypoints"][4]   # oSignal result
    check sigEp["signal"].kind == JInt
    check sigEp["signal"].getInt == 11

  test "non-signal entrypoint has null signal field":
    let node   = toJson(syntheticResults(), syntheticSummary())
    let passEp = node["entrypoints"][0]   # oPassed result
    check passEp["signal"].kind == JNull

  test "entrypoint carries path and group strings":
    let node = toJson(syntheticResults(), syntheticSummary())
    let ep   = node["entrypoints"][3]   # integration ep
    check ep["path"].getStr  == "tests/integration/test_delta.nim"
    check ep["group"].getStr == "integration"

  test "durationMs is a number field":
    let node = toJson(syntheticResults(), syntheticSummary())
    let ep   = node["entrypoints"][0]
    check ep["durationMs"].kind in {JFloat, JInt}

  test "toJsonString produces valid parseable JSON":
    let s      = toJsonString(syntheticResults(), syntheticSummary())
    check s.len > 0
    let parsed = parseJson(s)   # throws if invalid
    check parsed["schema"].getStr == "crisol/run/v1"

  # S2a: compileSkipped and memThrottledSlots schema fields

  test "run/v1 each entrypoint carries compileSkipped boolean field":
    ## S2a: EntrypointResult.compileSkipped already exists but toJson never
    ## emitted it.  This completes the schema.
    let results = @[
      EntrypointResult(ep: makeEp("tests/unit/test_a.nim"), outcome: oPassed,
                       exitCode: 0, durationMs: 10, compileSkipped: true, records: @[]),
      EntrypointResult(ep: makeEp("tests/unit/test_b.nim"), outcome: oPassed,
                       exitCode: 0, durationMs: 10, compileSkipped: false, records: @[]),
    ]
    let node = toJson(results, Summary(total: 2, passed: 2))
    check node["entrypoints"][0].hasKey("compileSkipped")
    check node["entrypoints"][0]["compileSkipped"].getBool == true
    check node["entrypoints"][1]["compileSkipped"].getBool == false

  test "run/v1 has top-level memThrottledSlots integer field":
    ## S2a: schema field for memory-throttled slot count.  The AdmissionController
    ## (S6b) will populate this; for now it is always 0.  # S6b
    let node = toJson(syntheticResults(), syntheticSummary())
    check node.hasKey("memThrottledSlots")
    check node["memThrottledSlots"].kind == JInt
    check node["memThrottledSlots"].getInt == 0

  test "run/v1 memThrottledSlots accepts a non-zero value when passed":
    ## Verify the field is wired through the parameter, not hard-coded.
    let node = toJson(syntheticResults(), syntheticSummary(),
                      memThrottledSlots = 3)
    check node["memThrottledSlots"].getInt == 3

  test "empty results sequence serializes cleanly":
    let s    = Summary(total: 0, passed: 0, noTestsRan: true)
    let node = toJson(@[], s)
    check node["schema"].getStr == "crisol/run/v1"
    check node["entrypoints"].len == 0
    check node["summary"]["noTestsRan"].getBool == true

# ---------------------------------------------------------------------------
# Helpers -- unique temp dir for each persist test
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  ## Generate a unique temp directory path using current monotonic time.
  let mono = getMonoTime()
  getTempDir() / ("crisol_jo_" & tag & "_" & $mono.ticks)

# ---------------------------------------------------------------------------
# Suite 2 -- persistLastRun
# ---------------------------------------------------------------------------

suite "jsonout - persistLastRun":

  test "persistLastRun creates lastrun.json in stateDir":
    let tmpDir   = uniqueTmpDir("persist")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    createDir(tmpDir)
    defer: removeDir(tmpDir)

    persistLastRun(syntheticResults(), syntheticSummary(), cfg)

    let finalPath = tmpDir / stateDir / "lastrun.json"
    check fileExists(finalPath)

  test "persisted file is valid JSON":
    let tmpDir   = uniqueTmpDir("json")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    createDir(tmpDir)
    defer: removeDir(tmpDir)

    persistLastRun(syntheticResults(), syntheticSummary(), cfg)

    let finalPath = tmpDir / stateDir / "lastrun.json"
    let raw       = readFile(finalPath)
    let parsed    = parseJson(raw)   # throws if invalid
    check parsed["schema"].getStr == "crisol/run/v1"

  test "persisted JSON matches toJson output":
    let tmpDir   = uniqueTmpDir("match")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let results = syntheticResults()
    let summary = syntheticSummary()
    persistLastRun(results, summary, cfg)

    let finalPath  = tmpDir / stateDir / "lastrun.json"
    let fromFile   = parseJson(readFile(finalPath))
    let fromToJson = toJson(results, summary)

    # Compare summary counts
    check fromFile["summary"]["total"].getInt  == fromToJson["summary"]["total"].getInt
    check fromFile["summary"]["passed"].getInt == fromToJson["summary"]["passed"].getInt
    check fromFile["summary"]["failed"].getInt == fromToJson["summary"]["failed"].getInt
    check fromFile["entrypoints"].len          == fromToJson["entrypoints"].len

  test "persistLastRun creates stateDir if absent":
    let tmpDir   = uniqueTmpDir("mkdir")
    let stateDir = ".crisol_nonexistent"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    createDir(tmpDir)
    defer: removeDir(tmpDir)
    # Do NOT create stateDir -- persistLastRun must create it.

    persistLastRun(syntheticResults(), syntheticSummary(), cfg)
    check fileExists(tmpDir / stateDir / "lastrun.json")

  test "persistLastRun does not crash when projectRoot is unwritable":
    ## Use a path under /proc that cannot be created to trigger the error path.
    ## We just verify it does not raise any exception.
    let cfg = Config(
      projectRoot:        "/proc/nonexistent_crisol_test_xyzzy",
      stateDir:           ".crisol",
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    # Should not raise; just warns to stderr.
    try:
      persistLastRun(syntheticResults(), syntheticSummary(), cfg)
    except:
      check false   # must not propagate any exception

# ---------------------------------------------------------------------------
# stdout capture helper using POSIX dup2
# ---------------------------------------------------------------------------

proc captureStdoutToFile(path: string; body: proc()): void =
  ## Redirect fd 1 (stdout) to `path`, call body(), then restore.
  ## Uses raw POSIX dup/dup2/close; safe for in-process capture.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(1) failed")
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()  # fd 1 now points at the file; we can close the extra fd
  try:
    body()
  finally:
    # Flush whatever Nim's stdout buffer has
    flushFile(stdout)
    discard posix_mod.dup2(savedFd, 1.cint)
    discard posix_mod.close(savedFd)

# ---------------------------------------------------------------------------
# Suite 3 -- --json CLI flag
# ---------------------------------------------------------------------------

suite "jsonout - --json CLI flag":

  proc fixtureDir(): string =
    let thisFile = currentSourcePath()
    let testsDir = thisFile.parentDir.parentDir
    testsDir / "fixtures"

  test "--json flag: stdout is valid parseable JSON":
    let outPath = getTempDir() / "crisol_json_stdout.json"
    defer: (try: removeFile(outPath) except: discard)

    let fd   = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1", "--json"]))

    check code == 0
    let raw    = readFile(outPath)
    check raw.strip().len > 0
    let parsed = parseJson(raw.strip())
    check parsed["schema"].getStr == "crisol/run/v1"

  test "--json flag: output has no human-render lines (no [OK], PASSED:)":
    let outPath = getTempDir() / "crisol_json_nohuman.json"
    defer: (try: removeFile(outPath) except: discard)

    let fd   = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1", "--json"]))

    check code == 0
    let raw = readFile(outPath).strip()
    check not raw.contains("[OK]")
    check not raw.contains("PASSED:")
    check not raw.contains("FAILED:")
    # Compact JSON: should be a single non-empty line
    let lines = raw.splitLines().filterIt(it.len > 0)
    check lines.len == 1

  test "--json flag with failing fixture: exit 1, output still valid JSON":
    let outPath = getTempDir() / "crisol_json_fail.json"
    defer: (try: removeFile(outPath) except: discard)

    let fd   = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", fd / "fail_always.nim", "--jobs", "1", "--json"]))

    check code == 1
    let parsed = parseJson(readFile(outPath).strip())
    check parsed["schema"].getStr == "crisol/run/v1"

  test "without --json: lastrun.json is written to .crisol/":
    ## runMain uses loadConfig() which roots at getCurrentDir().
    ## Verify lastrun.json is created after a normal (non-json) run.
    let fd        = fixtureDir()
    let statePath = getCurrentDir() / ".crisol" / "lastrun.json"
    try: removeFile(statePath) except: discard

    # Suppress human-render stdout so test output stays clean.
    let outPath = getTempDir() / "crisol_nojson_stdout.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1"]))

    check code == 0
    check fileExists(statePath)
    let parsed = parseJson(readFile(statePath))
    check parsed["schema"].getStr == "crisol/run/v1"

# ---------------------------------------------------------------------------
# Suite 4 -- B7: loadLastRun
# ---------------------------------------------------------------------------

suite "jsonout - loadLastRun (B7)":

  proc makeCfg(projectRoot, stateDir: string): Config =
    Config(
      projectRoot:        projectRoot,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

  test "absent lastrun.json → found=false":
    let tmpDir = uniqueTmpDir("absent")
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    # Do NOT create .crisol/ or lastrun.json
    let cfg = makeCfg(tmpDir, ".crisol")
    let lr  = loadLastRun(cfg)
    check lr.found == false
    check lr.failed.len == 0

  test "loadLastRun: failed keys use (path,group) not path-only":
    ## Craft a lastrun.json with the SAME path under TWO groups:
    ##   group "unit"        → outcome "exitNonZero"  (failure)
    ##   group "integration" → outcome "passed"        (not a failure)
    ## plus a third entrypoint (different path) that passed.
    ## loadLastRun must return ONLY (same_path, "unit") — not the passed group.
    let tmpDir   = uniqueTmpDir("pathgroup")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)

    let jsonDoc = """{"schema":"crisol/run/v1","summary":{"total":3,"passed":2,"failed":1,"compileFailed":0,"timedOut":0,"signaled":0,"spawnErrors":0,"noTestsRan":false},"entrypoints":[{"path":"tests/unit/test_shared.nim","group":"unit","outcome":"exitNonZero","exitCode":1,"signal":null,"durationMs":100.0,"records":[]},{"path":"tests/unit/test_shared.nim","group":"integration","outcome":"passed","exitCode":0,"signal":null,"durationMs":50.0,"records":[]},{"path":"tests/unit/test_other.nim","group":"unit","outcome":"passed","exitCode":0,"signal":null,"durationMs":20.0,"records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", jsonDoc)

    let cfg = makeCfg(tmpDir, stateDir)
    let lr  = loadLastRun(cfg)

    check lr.found == true
    # Only the (test_shared.nim, "unit") pair is a failure.
    check lr.failed.len == 1
    check (path: "tests/unit/test_shared.nim", group: "unit") in lr.failed
    # The passed-group variant must NOT be in the failed set.
    check (path: "tests/unit/test_shared.nim", group: "integration") notin lr.failed
    # The other passed entrypoint must NOT be in the failed set.
    check (path: "tests/unit/test_other.nim", group: "unit") notin lr.failed

  test "loadLastRun: all failure outcome strings are recognised":
    ## One entrypoint per failure outcome string; all must appear in failed set.
    let tmpDir   = uniqueTmpDir("outcomes")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)

    let jsonDoc = """{"schema":"crisol/run/v1","summary":{"total":5,"passed":0,"failed":5,"compileFailed":0,"timedOut":0,"signaled":0,"spawnErrors":0,"noTestsRan":false},"entrypoints":[{"path":"a.nim","group":"g","outcome":"exitNonZero","exitCode":1,"signal":null,"durationMs":1.0,"records":[]},{"path":"b.nim","group":"g","outcome":"compileFailed","exitCode":1,"signal":null,"durationMs":1.0,"records":[]},{"path":"c.nim","group":"g","outcome":"timedOut","exitCode":0,"signal":null,"durationMs":1.0,"records":[]},{"path":"d.nim","group":"g","outcome":"signaled","exitCode":0,"signal":11,"durationMs":1.0,"records":[]},{"path":"e.nim","group":"g","outcome":"spawnError","exitCode":0,"signal":null,"durationMs":1.0,"records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", jsonDoc)

    let cfg = makeCfg(tmpDir, stateDir)
    let lr  = loadLastRun(cfg)

    check lr.found == true
    check lr.failed.len == 5
    check (path: "a.nim", group: "g") in lr.failed
    check (path: "b.nim", group: "g") in lr.failed
    check (path: "c.nim", group: "g") in lr.failed
    check (path: "d.nim", group: "g") in lr.failed
    check (path: "e.nim", group: "g") in lr.failed

  test "loadLastRun: 'passed' outcome is NOT in failed set":
    let tmpDir   = uniqueTmpDir("passed")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)

    let jsonDoc = """{"schema":"crisol/run/v1","summary":{"total":1,"passed":1,"failed":0,"compileFailed":0,"timedOut":0,"signaled":0,"spawnErrors":0,"noTestsRan":false},"entrypoints":[{"path":"a.nim","group":"g","outcome":"passed","exitCode":0,"signal":null,"durationMs":1.0,"records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", jsonDoc)

    let cfg = makeCfg(tmpDir, stateDir)
    let lr  = loadLastRun(cfg)

    check lr.found == true
    check lr.failed.len == 0

  test "loadLastRun: wrong schema version raises CrisolError":
    let tmpDir   = uniqueTmpDir("badschema")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)

    let jsonDoc = """{"schema":"crisol/run/v99","summary":{},"entrypoints":[]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", jsonDoc)

    let cfg = makeCfg(tmpDir, stateDir)
    var raised = false
    try:
      discard loadLastRun(cfg)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
      check e.msg.contains("stale lastrun.json")
    check raised

  test "loadLastRun: malformed JSON raises CrisolError":
    let tmpDir   = uniqueTmpDir("badjson")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / stateDir / "lastrun.json", "not valid json {{{{")

    let cfg = makeCfg(tmpDir, stateDir)
    var raised = false
    try:
      discard loadLastRun(cfg)
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
    check raised

  # ---------------------------------------------------------------------------
  # M3: persistLastRun must persist warnings and memThrottledSlots
  # ---------------------------------------------------------------------------

  test "persistLastRun preserves warnings in lastrun.json":
    ## RED against old code: persistLastRun called toJsonString(results, summary)
    ## without warnings, so warnings were always [] in the persisted file.
    ## After the fix, warnings must appear in lastrun.json exactly as they do
    ## in the stdout JSON path.
    let tmpDir   = uniqueTmpDir("m3warn")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let warn = ConfigWarning(
      source:  "/proj/crisol.kdl",
      context: "integration",
      key:     "max-retries",
      message: "unknown config key 'max-retries' in integration (ignored)",
    )
    persistLastRun(syntheticResults(), syntheticSummary(), cfg,
                   warnings = @[warn], memThrottledSlots = 0)

    let parsed = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check parsed.hasKey("warnings")
    check parsed["warnings"].kind == JArray
    check parsed["warnings"].len == 1
    check parsed["warnings"][0]["key"].getStr == "max-retries"

  test "persistLastRun preserves memThrottledSlots in lastrun.json":
    ## RED against old code: persistLastRun called toJsonString(results, summary)
    ## without memThrottledSlots, so it was always 0 in the persisted file even
    ## when the actual run throttled slots.
    let tmpDir   = uniqueTmpDir("m3mem")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    persistLastRun(syntheticResults(), syntheticSummary(), cfg,
                   warnings = @[], memThrottledSlots = 7)

    let parsed = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check parsed.hasKey("memThrottledSlots")
    check parsed["memThrottledSlots"].getInt == 7

  test "persistLastRun with warnings and memThrottledSlots matches toJsonString output":
    ## The file written by persistLastRun must match what toJsonString would
    ## produce with the same arguments — i.e., stdout and lastrun.json are
    ## consistent for the new RFC-0002 fields.
    let tmpDir   = uniqueTmpDir("m3match")
    let stateDir = ".crisol_test"
    let cfg      = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let warn = ConfigWarning(
      source:  "/proj/crisol.kdl",
      context: "unit",
      key:     "bad-key",
      message: "unknown config key 'bad-key' in unit (ignored)",
    )
    let results = syntheticResults()
    let summary = syntheticSummary()
    persistLastRun(results, summary, cfg, warnings = @[warn], memThrottledSlots = 3)

    let fromFile   = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    let fromStdout = parseJson(toJsonString(results, summary,
                                            warnings = @[warn],
                                            memThrottledSlots = 3))

    check fromFile["warnings"].len          == fromStdout["warnings"].len
    check fromFile["memThrottledSlots"].getInt == fromStdout["memThrottledSlots"].getInt
    check fromFile["warnings"][0]["key"].getStr == fromStdout["warnings"][0]["key"].getStr

  test "loadLastRun via persistLastRun: round-trip extracts correct failed set":
    ## Use persistLastRun (B5) to write a real lastrun.json, then loadLastRun
    ## (B7) to read it back — verifying the same serialization path is used.
    let tmpDir   = uniqueTmpDir("roundtrip")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # One failed, one passed.
    let results = @[
      EntrypointResult(ep: Entrypoint(path: "tests/unit/test_alpha.nim", group: "unit", flags: @[]),
                       outcome: oFailed, exitCode: 1, signal: 0,
                       durationMs: 100, records: @[]),
      EntrypointResult(ep: Entrypoint(path: "tests/unit/test_beta.nim", group: "unit", flags: @[]),
                       outcome: oPassed, exitCode: 0, signal: 0,
                       durationMs: 50, records: @[]),
    ]
    let summary = Summary(total: 2, passed: 1, failed: 1)
    let cfg = makeCfg(tmpDir, stateDir)

    persistLastRun(results, summary, cfg)
    let lr = loadLastRun(cfg)

    check lr.found == true
    check lr.failed.len == 1
    check (path: "tests/unit/test_alpha.nim", group: "unit") in lr.failed
    check (path: "tests/unit/test_beta.nim",  group: "unit") notin lr.failed

# ---------------------------------------------------------------------------
# P3 — symlink write-through protection for temp file
# ---------------------------------------------------------------------------

suite "jsonout - P3 symlink-safe temp write":

  test "persistLastRun with pre-planted .tmp symlink does not write through to symlink target":
    ## A pre-existing lastrun.json.tmp symlink pointing to a sentinel file
    ## must NOT cause persistLastRun to overwrite the sentinel.
    ## After the fix, O_CREAT|O_EXCL|O_WRONLY rejects the open when a file
    ## already exists at the temp path (the symlink is a pre-existing entry).
    ## The stale .tmp is removed first, then opened exclusively — so the only
    ## pre-existing .tmp that could interfere is one planted BETWEEN our
    ## removeFile and open, which is a TOCTOU window but not the stated
    ## symlink-pre-planting attack.  This test covers the simpler pre-planted
    ## case: the stale file is cleaned up and the write succeeds into a fresh fd.
    ##
    ## More specifically: we verify that the FINAL write goes to lastrun.json
    ## (not to some other path), and that the normal round-trip still works.
    let tmpDir   = uniqueTmpDir("p3sym")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    createDir(tmpDir / stateDir)

    let finalPath = tmpDir / stateDir / "lastrun.json"
    let tmpPath   = finalPath & ".tmp"

    # Plant a sentinel file and a symlink pointing to it at the .tmp location.
    let sentinel = tmpDir / "sentinel_must_not_be_overwritten.txt"
    writeFile(sentinel, "ORIGINAL")
    # Create a symlink: lastrun.json.tmp -> sentinel
    discard posix_mod.symlink(sentinel.cstring, tmpPath.cstring)

    let cfg = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    # This must not crash. Whether it succeeds or warns, the sentinel must be intact.
    persistLastRun(syntheticResults(), syntheticSummary(), cfg)

    # The sentinel file must NOT have been overwritten with JSON.
    let sentinelContent = readFile(sentinel)
    check sentinelContent == "ORIGINAL"

  test "persistLastRun normal round-trip still works after P3 fix":
    ## Verify that the O_CREAT|O_EXCL write path produces a correct lastrun.json
    ## when no stale .tmp exists (the happy path is preserved).
    let tmpDir   = uniqueTmpDir("p3happy")
    let stateDir = ".crisol_test"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let cfg = Config(
      projectRoot:        tmpDir,
      stateDir:           stateDir,
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )

    let results = syntheticResults()
    let summary = syntheticSummary()
    persistLastRun(results, summary, cfg)
    let lr = loadLastRun(cfg)

    check lr.found == true
    # syntheticResults has 5 failure outcomes out of 6 total
    check lr.failed.len == 5
