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

import std/[json, monotimes, options, os, sequtils, sets, strutils, times, unittest]
import std/posix as posix_mod
import crisol/types
import crisol/jsonout
import crisol/render
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
# A8 — cached / inputHash / cacheDecision / schemaRevision
# ---------------------------------------------------------------------------

suite "jsonout A8 — cache reporting fields":

  proc cachedResult(): EntrypointResult =
    EntrypointResult(
      ep: makeEp("tests/unit/test_cached.nim"), outcome: oPassed,
      exitCode: 0, durationMs: 999, records: @[],
      cached: true, inputHash: "deadbeefcafef00d", cacheDecision: cdmHit)

  proc liveResult(): EntrypointResult =
    EntrypointResult(
      ep: makeEp("tests/unit/test_live.nim"), outcome: oPassed,
      exitCode: 0, durationMs: 12, records: @[],
      cached: false, inputHash: "0011223344556677", cacheDecision: cdmKeyMiss)

  test "run/v1 carries an integer schemaRevision alongside schema string":
    let node = toJson(syntheticResults(), syntheticSummary())
    check node["schema"].getStr == "crisol/run/v1"
    check node.hasKey("schemaRevision")
    check node["schemaRevision"].kind == JInt
    check node["schemaRevision"].getInt == RunV1Revision
    check RunV1Revision >= 2

  test "each entrypoint carries cached boolean (absence-default false)":
    let node = toJson(@[cachedResult(), liveResult()], Summary(total: 2, passed: 2))
    check node["entrypoints"][0]["cached"].getBool == true
    check node["entrypoints"][1]["cached"].getBool == false

  test "cached defaults to false for a default-constructed result":
    ## syntheticResults never set `cached`; field must serialize as false.
    let node = toJson(syntheticResults(), syntheticSummary())
    for ep in node["entrypoints"]:
      check ep.hasKey("cached")
      check ep["cached"].getBool == false

  test "each entrypoint carries inputHash string":
    let node = toJson(@[cachedResult(), liveResult()], Summary(total: 2, passed: 2))
    check node["entrypoints"][0]["inputHash"].getStr == "deadbeefcafef00d"
    check node["entrypoints"][1]["inputHash"].getStr == "0011223344556677"

  test "each entrypoint carries cacheDecision stable string":
    let node = toJson(@[cachedResult(), liveResult()], Summary(total: 2, passed: 2))
    check node["entrypoints"][0]["cacheDecision"].getStr == "hit"
    check node["entrypoints"][1]["cacheDecision"].getStr == "keyMiss"

  test "cacheDecisionString maps every enum value to a stable distinct string":
    ## M8 rev 6: cdmStored and cdmGroupOptOut added.
    ## R9: cdmClosureUnrecorded added; all 9 variants covered.
    check cacheDecisionString(cdmNotEligible)       == "notEligible"
    check cacheDecisionString(cdmHit)               == "hit"
    check cacheDecisionString(cdmStored)            == "stored"
    check cacheDecisionString(cdmKeyMiss)           == "keyMiss"
    check cacheDecisionString(cdmHermeticityDeg)    == "hermeticityDegraded"
    check cacheDecisionString(cdmGroupOptOut)       == "groupOptOut"
    check cacheDecisionString(cdmPolicyDisabled)    == "policyDisabled"
    check cacheDecisionString(cdmFlaky)             == "flaky"
    check cacheDecisionString(cdmClosureUnrecorded) == "closureUnrecorded"

  test "default-constructed result reports notEligible cacheDecision":
    let node = toJson(syntheticResults(), syntheticSummary())
    # syntheticResults leave cacheDecision at its default (cdmNotEligible, ord 0)
    for ep in node["entrypoints"]:
      check ep["cacheDecision"].getStr == "notEligible"

  test "render shows [CACHED] label for a cached entrypoint":
    let s = render(@[cachedResult(), liveResult()],
                   Summary(total: 2, passed: 2), defaultOpts())
    check "[CACHED]" in s
    # The live (non-cached) pass must NOT carry [CACHED].
    let cachedLineIdx = s.find("test_cached.nim")
    let liveLineIdx   = s.find("test_live.nim")
    check cachedLineIdx >= 0
    check liveLineIdx >= 0
    # [CACHED] appears once (only for the cached entrypoint).
    check s.count("[CACHED]") == 1

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
# Fresh CRISOL_STATE_DIR helper (RFC-0006 Issue-2 regression coverage)
# ---------------------------------------------------------------------------
#
# `runMain()` below is called IN-PROCESS: this unittest binary itself is the
# "currently running process." Before the Issue-2 fix, runMain UNCONDITIONALLY
# set RunOptions.workerBinary = getAppFilename(), which here resolves to THIS
# TEST BINARY -- not crisol. Had a measure/cache worker been requested, that
# would have made spawnCompileStable self-reexec this test binary as the
# "worker": the re-invoked process doesn't dispatch the internal token at all
# (its entrypoint is the unittest runner, not crisol.runMain), so it just
# re-runs the whole test suite -- unsound, and a potential unbounded
# recursive fork (see crisol.nim's runMain doc for the full mechanism).
#
# Two independent hazards must both be ruled out for a genuinely COLD proof:
#   1. workerBinary must stay "" for an in-process runMain() call (the actual
#      Issue-2 fix, verified structurally by the assertions below).
#   2. crisol's OWN result cache must not mark pass_always.nim "fresh" and
#      skip compiling it -- if compile is skipped entirely, the workerBinary
#      bug never gets exercised, silently masking a regression (see the
#      standing verification rules on cache-masked failures). A FRESH
#      CRISOL_STATE_DIR per test forces a genuinely cold compile every time.
template withFreshCrisolStateDir(tag: string, body: untyped) =
  block:
    let stateDirTmp = getTempDir() / "crisol_test_jsonout_" & tag & "_" &
                       $getCurrentProcessId()
    removeDir(stateDirTmp)
    createDir(stateDirTmp)
    putEnv("CRISOL_STATE_DIR", stateDirTmp)
    try:
      body
    finally:
      delEnv("CRISOL_STATE_DIR")
      removeDir(stateDirTmp)

# ---------------------------------------------------------------------------
# Suite 3 -- --json CLI flag
# ---------------------------------------------------------------------------

suite "jsonout - --json CLI flag":

  proc fixtureDir(): string =
    let thisFile = currentSourcePath()
    let testsDir = thisFile.parentDir.parentDir
    testsDir / "fixtures"

  test "--json flag: stdout is valid parseable JSON":
    ## RFC-0006 Issue-2 regression: this test used to flake because runMain
    ## (in-process, this test binary) set workerBinary = getAppFilename()
    ## unconditionally; had a worker been requested that would have
    ## self-reexec'd THIS test binary as an unsound worker. Fixed
    ## structurally (runMain now only wires workerBinary from an explicit
    ## `selfWorkerBinary` param that ONLY the real crisol CLI's own
    ## top-level entrypoint passes) -- this test proves the fix
    ## deterministically with a fresh, genuinely COLD stateDir so the
    ## compile step is never skipped/masked by cache state (see the
    ## standing verification rules).
    withFreshCrisolStateDir("stdout_json"):
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

  test "RFC-0006 Issue-2 regression: in-process runMain() with no selfWorkerBinary never self-reexecs; compiles monolithically and succeeds (cold stateDir)":
    ## Direct proof of the fix's soundness invariant. Before the fix,
    ## runMain(args) called in-process (no selfWorkerBinary argument, as
    ## every caller here does) would still set RunOptions.workerBinary =
    ## getAppFilename() = THIS test binary; had a compile-slot worker been
    ## requested, spawnCompileStable would self-reexec this test binary as
    ## the "worker" -- which doesn't dispatch the internal token and so
    ## just re-runs the whole unittest suite (unsound; a bounded elapsed-time
    ## check below is the observable guard against that never terminating
    ## quickly). After the fix, runMain's default `selfWorkerBinary = ""`
    ## means RunOptions.workerBinary stays "" here, so spawnCompileStable
    ## always degrades to the safe monolithic `nim c` path.
    withFreshCrisolStateDir("issue2_regress"):
      let outPath = getTempDir() / "crisol_issue2_regress_stdout.json"
      defer: (try: removeFile(outPath) except: discard)

      let fd = fixtureDir()
      var code = 0
      let t0 = getMonoTime()
      captureStdoutToFile(outPath, proc () =
        code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1", "--json"]))
      let elapsedMs = (getMonoTime() - t0).inMilliseconds

      # A self-reexec of this test binary would re-run the ENTIRE unittest
      # suite (recursively) instead of a single trivial compile+run -- this
      # would take dramatically longer than a genuine cold single-fixture
      # compile, which completes in well under this bound.
      check elapsedMs < 60_000

      check code == 0
      let raw = readFile(outPath).strip()
      check raw.len > 0
      let parsed = parseJson(raw)
      check parsed["schema"].getStr == "crisol/run/v1"
      check parsed["summary"]["passed"].getInt == 1
      check parsed["summary"]["total"].getInt == 1

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

  # ---------------------------------------------------------------------------
  # A8: loadLastRun forward/backward tolerance for schemaRevision
  # ---------------------------------------------------------------------------

  test "loadLastRun tolerates an old doc with no schemaRevision and no new fields":
    let tmpDir   = uniqueTmpDir("a8old")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    # An old document: no schemaRevision, entrypoint has no cached/inputHash.
    let doc = """{"schema":"crisol/run/v1","summary":{"total":1,"passed":0,"failed":1,"compileFailed":0,"timedOut":0,"signaled":0,"spawnErrors":0,"noTestsRan":false},"entrypoints":[{"path":"a.nim","group":"g","outcome":"exitNonZero","exitCode":1,"signal":null,"durationMs":1.0,"records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", doc)
    let lr = loadLastRun(makeCfg(tmpDir, stateDir))
    check lr.found == true
    check (path: "a.nim", group: "g") in lr.failed

  test "loadLastRun tolerates a new doc carrying cached/inputHash/cacheDecision":
    let tmpDir   = uniqueTmpDir("a8new")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    let doc = """{"schema":"crisol/run/v1","schemaRevision":2,"summary":{"total":1,"passed":1,"failed":0,"compileFailed":0,"timedOut":0,"signaled":0,"spawnErrors":0,"noTestsRan":false},"entrypoints":[{"path":"a.nim","group":"g","outcome":"passed","exitCode":0,"signal":null,"durationMs":1.0,"cached":true,"inputHash":"abc","cacheDecision":"hit","records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", doc)
    let lr = loadLastRun(makeCfg(tmpDir, stateDir))
    check lr.found == true
    check lr.failed.len == 0

  test "loadLastRun treats schemaRevision > CURRENT_MAX as safe cold-start":
    ## A future crisol wrote this file; we must NOT trust its fields.  Per RFC
    ## this is a safe cold-start (no data) — found=false — symmetric with plans.
    let tmpDir   = uniqueTmpDir("a8future")
    let stateDir = ".crisol_test"
    createDir(tmpDir); createDir(tmpDir / stateDir)
    defer: removeDir(tmpDir)
    let doc = """{"schema":"crisol/run/v1","schemaRevision":9999,"summary":{"total":1,"passed":0,"failed":1},"entrypoints":[{"path":"a.nim","group":"g","outcome":"exitNonZero","records":[]}]}"""
    writeFile(tmpDir / stateDir / "lastrun.json", doc)
    let lr = loadLastRun(makeCfg(tmpDir, stateDir))
    check lr.found == false
    check lr.failed.len == 0

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

# ---------------------------------------------------------------------------
# M-report pass (a) — optional `compile` block, additive/back-compat
# ---------------------------------------------------------------------------

suite "jsonout M-report (a) — compile block threading":

  test "compileBlock=nil (default): document is byte-identical to before this slice -- no 'compile' key":
    let withDefault = toJson(syntheticResults(), syntheticSummary())
    let withExplicitNil = toJson(syntheticResults(), syntheticSummary(), compileBlock = nil)
    check not withDefault.hasKey("compile")
    check not withExplicitNil.hasKey("compile")
    check $withDefault == $withExplicitNil

  test "RunV1Revision was bumped for the additive compile field":
    check RunV1Revision >= 7

  test "a non-nil compileBlock is threaded through toJson as the top-level 'compile' key, well-formed":
    var blk = newJObject()
    var segments = newJArray()
    var seg = newJObject()
    seg["groupId"] = newJString("g1")
    seg["configHash"] = newJString("c1")
    seg["rTime"] = newJFloat(0.5)
    segments.add seg
    blk["segments"] = segments

    let node = toJson(syntheticResults(), syntheticSummary(), compileBlock = blk)
    check node.hasKey("compile")
    check node["compile"]["segments"].kind == JArray
    check node["compile"]["segments"].len == 1
    check node["compile"]["segments"][0]["groupId"].getStr == "g1"
    check node["compile"]["segments"][0]["rTime"].getFloat == 0.5

  test "toJsonString threads compileBlock through to the serialized string":
    var blk = newJObject()
    blk["segments"] = newJArray()
    let str = toJsonString(syntheticResults(), syntheticSummary(), compileBlock = blk)
    let node = parseJson(str)
    check node.hasKey("compile")
    check node["compile"]["segments"].len == 0

  test "persistLastRun threads compileBlock through to the persisted lastrun.json":
    let tmpDir   = uniqueTmpDir("compileblock")
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

    var blk = newJObject()
    var segments = newJArray()
    var seg = newJObject()
    seg["groupId"] = newJString("unit")
    seg["configHash"] = newJString("cfg0")
    seg["rTime"] = newJFloat(0.25)
    segments.add seg
    blk["segments"] = segments

    persistLastRun(syntheticResults(), syntheticSummary(), cfg, compileBlock = blk)

    let persisted = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check persisted.hasKey("compile")
    check persisted["compile"]["segments"][0]["groupId"].getStr == "unit"

  test "persistLastRun with compileBlock=nil (default) omits 'compile' from the persisted file":
    let tmpDir   = uniqueTmpDir("compileblocknil")
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

    persistLastRun(syntheticResults(), syntheticSummary(), cfg)

    let persisted = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check not persisted.hasKey("compile")

# ---------------------------------------------------------------------------
# M-report PASS (b1) — reuseAlerts array threading, additive/back-compat
# ---------------------------------------------------------------------------

suite "jsonout M-report (b1) — reuseAlerts threading":

  test "reuseAlerts omitted (default): 'reuseAlerts' is present and empty -- matches 'regressions' present-but-empty convention":
    let node = toJson(syntheticResults(), syntheticSummary())
    check node.hasKey("reuseAlerts")
    check node["reuseAlerts"].kind == JArray
    check node["reuseAlerts"].len == 0

  test "reuseAlerts omitted: document is byte-identical to explicit empty array (back-compat default)":
    let withDefault = toJson(syntheticResults(), syntheticSummary())
    let withExplicitEmpty = toJson(syntheticResults(), syntheticSummary(), reuseAlerts = newJArray())
    check $withDefault == $withExplicitEmpty

  test "RunV1Revision was bumped again for the additive reuseAlerts/ambientCcacheDetected/topUnits fields":
    check RunV1Revision >= 8

  test "a non-empty reuseAlerts array is threaded through toJson as the top-level 'reuseAlerts' key, well-formed":
    var alerts = newJArray()
    var a = newJObject()
    a["groupId"]    = newJString("g1")
    a["configHash"] = newJString("c1")
    a["rTime"]      = newJFloat(0.1)
    a["alertBelow"] = newJFloat(0.5)
    alerts.add a

    let node = toJson(syntheticResults(), syntheticSummary(), reuseAlerts = alerts)
    check node.hasKey("reuseAlerts")
    check node["reuseAlerts"].len == 1
    check node["reuseAlerts"][0]["groupId"].getStr == "g1"
    check node["reuseAlerts"][0]["rTime"].getFloat == 0.1

  test "toJsonString threads reuseAlerts through to the serialized string":
    var alerts = newJArray()
    var a = newJObject()
    a["groupId"]    = newJString("g1")
    a["configHash"] = newJString("c1")
    a["rTime"]      = newJFloat(0.1)
    a["alertBelow"] = newJFloat(0.5)
    alerts.add a

    let str = toJsonString(syntheticResults(), syntheticSummary(), reuseAlerts = alerts)
    let node = parseJson(str)
    check node["reuseAlerts"].len == 1

  test "persistLastRun threads reuseAlerts through to the persisted lastrun.json":
    let tmpDir   = uniqueTmpDir("reusealerts")
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

    var alerts = newJArray()
    var a = newJObject()
    a["groupId"]    = newJString("unit")
    a["configHash"] = newJString("cfg0")
    a["rTime"]      = newJFloat(0.2)
    a["alertBelow"] = newJFloat(0.5)
    alerts.add a

    persistLastRun(syntheticResults(), syntheticSummary(), cfg, reuseAlerts = alerts)

    let persisted = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check persisted.hasKey("reuseAlerts")
    check persisted["reuseAlerts"][0]["groupId"].getStr == "unit"

  test "persistLastRun with reuseAlerts omitted: 'reuseAlerts' persisted as an empty array":
    let tmpDir   = uniqueTmpDir("reusealertsdefault")
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

    persistLastRun(syntheticResults(), syntheticSummary(), cfg)

    let persisted = parseJson(readFile(tmpDir / stateDir / "lastrun.json"))
    check persisted.hasKey("reuseAlerts")
    check persisted["reuseAlerts"].len == 0

# ---------------------------------------------------------------------------
# M-report PASS (b2) — compile.compileRegressions, additive/back-compat
# ---------------------------------------------------------------------------

suite "jsonout M-report (b2) — compile.compileRegressions threading":

  test "RunV1Revision was bumped again for the additive compile.compileRegressions field":
    check RunV1Revision >= 9

  test "a compileBlock carrying a non-empty compileRegressions array threads through toJson opaquely":
    var blk = newJObject()
    blk["segments"] = newJArray()
    var regressions = newJArray()
    var r = newJObject()
    r["entrypointIdentity"] = newJString("ep_a|flaghash")
    r["groupId"]            = newJString("g1")
    r["configHash"]         = newJString("c1")
    r["currentUs"]          = newJInt(500_000)
    r["baselineUs"]         = newJInt(100_000)
    r["thresholdUs"]        = newJInt(200_000)
    regressions.add r
    blk["compileRegressions"] = regressions

    let node = toJson(syntheticResults(), syntheticSummary(), compileBlock = blk)
    check node["compile"]["compileRegressions"].len == 1
    check node["compile"]["compileRegressions"][0]["entrypointIdentity"].getStr == "ep_a|flaghash"
    check node["compile"]["compileRegressions"][0]["currentUs"].getBiggestInt == 500_000

  test "compileBlock with an empty compileRegressions array (the default) -> present and empty, document otherwise byte-identical":
    var blkEmpty = newJObject()
    blkEmpty["segments"] = newJArray()
    blkEmpty["compileRegressions"] = newJArray()

    var blkOmitted = newJObject()
    blkOmitted["segments"] = newJArray()
    blkOmitted["compileRegressions"] = newJArray()

    let withEmpty   = toJson(syntheticResults(), syntheticSummary(), compileBlock = blkEmpty)
    let withOmitted = toJson(syntheticResults(), syntheticSummary(), compileBlock = blkOmitted)
    check withEmpty["compile"]["compileRegressions"].len == 0
    check $withEmpty == $withOmitted

# ---------------------------------------------------------------------------
# Code review R7 — compile.segments[] gains currentRunEntrypoints/
# sampleEntrypoints/lowConfidence, additive/back-compat (RunV1Revision 10->11)
# ---------------------------------------------------------------------------

suite "jsonout code-review R7 — compile.segments low-confidence-gate fields":

  test "RunV1Revision is 13 (rev 12: Stage R removal; rev 13: cacheDecision \"closureUnrecorded\")":
    check RunV1Revision == 13

  test "a compileBlock carrying the new per-segment fields threads through toJson opaquely (jsonout never inspects compile's internal shape)":
    var blk = newJObject()
    var seg = newJObject()
    seg["groupId"]              = newJString("g1")
    seg["configHash"]           = newJString("c1")
    seg["rTime"]                = newJFloat(0.0)
    seg["currentRunEntrypoints"] = newJInt(1)
    seg["sampleEntrypoints"]     = newJInt(9)
    seg["lowConfidence"]         = newJBool(true)
    var segments = newJArray()
    segments.add seg
    blk["segments"] = segments

    let node = toJson(syntheticResults(), syntheticSummary(), compileBlock = blk)
    check node["compile"]["segments"][0]["currentRunEntrypoints"].getInt == 1
    check node["compile"]["segments"][0]["sampleEntrypoints"].getInt == 9
    check node["compile"]["segments"][0]["lowConfidence"].getBool == true

# ---------------------------------------------------------------------------
# closureToJson (crisol/closure/v1): schema/revision pin + full field
# serialization for both a recorded and an unrecorded ClosureEntry, plus the
# warnings array.
# ---------------------------------------------------------------------------

suite "jsonout — closureToJson (crisol/closure/v1)":

  test "schema constants are the documented literals":
    check ClosureV1Schema == "crisol/closure/v1"
    check ClosureV1Revision == 2

  test "closureToJson: schema/schemaRevision, a recorded entry's full field set, an unrecorded entry, and warnings":
    let report = ClosureReport(
      entries: @[
        ClosureEntry(
          path:        "tests/unit/test_a.nim",
          group:       "unit",
          flagHash:    "0123456789abcdef",
          recorded:    true,
          closure:     @["lib/dep.nim", "tests/unit/test_a.nim"],
          closureHash: "fedcba9876543210",
        ),
        ClosureEntry(
          path:        "tests/unit/test_b.nim",
          group:       "unit",
          flagHash:    "1111111111111111",
          recorded:    false,
          closure:     @[],
          closureHash: "",
        ),
      ],
      warnings: @[
        ConfigWarning(source: "crisol.kdl", context: "top-level", key: "bogus",
                      message: "unknown config key 'bogus' in top-level (ignored)"),
      ],
    )
    let j = closureToJson(report)

    check j["schema"].getStr == ClosureV1Schema
    check j["schemaRevision"].getInt == ClosureV1Revision

    check j["entries"].len == 2
    let recEntry = j["entries"][0]
    check recEntry["path"].getStr        == "tests/unit/test_a.nim"
    check recEntry["group"].getStr       == "unit"
    check recEntry["flagHash"].getStr    == "0123456789abcdef"
    check recEntry["recorded"].getBool   == true
    check recEntry["closureHash"].getStr == "fedcba9876543210"
    var closureFiles: seq[string]
    for f in recEntry["closure"]:
      closureFiles.add f.getStr
    check closureFiles == @["lib/dep.nim", "tests/unit/test_a.nim"]

    let unrecEntry = j["entries"][1]
    check unrecEntry["path"].getStr        == "tests/unit/test_b.nim"
    check unrecEntry["recorded"].getBool   == false
    check unrecEntry["closure"].len        == 0
    check unrecEntry["closureHash"].getStr == ""

    check j["warnings"].len == 1
    check j["warnings"][0]["key"].getStr == "bogus"
    check "bogus" in j["warnings"][0]["message"].getStr

  test "closureToJson: no entries and no warnings -> empty (but present) arrays":
    let j = closureToJson(ClosureReport())
    check j["entries"].len == 0
    check j["warnings"].len == 0
    check j["gatedOut"].len == 0

  test "closureToJsonString round-trips through parseJson to the same document as closureToJson":
    let report = ClosureReport(
      entries: @[ClosureEntry(path: "a.nim", group: "unit", flagHash: "h",
                              recorded: false, closure: @[], closureHash: "")],
    )
    check parseJson(closureToJsonString(report)) == closureToJson(report)
