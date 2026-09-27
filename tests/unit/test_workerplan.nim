## test_workerplan.nim — unit tests for crisol/workerplan.nim (RFC-0006
## M-artifact-identity, PASS (b1)): the MeasurePlan schema used by the
## measurement compile worker.
##
## No real `nim`/`cc` invocation anywhere in this file. This file covers:
##
##   1. MeasurePlan round-trips through toJson/parseMeasurePlan.
##   2. A malformed/missing plan.json raises a clear CrisolError.
##   3. forceMeasurementCcEnv() actually sets CCACHE_DISABLE=1 in this
##      process's env (the focused unit on the env-injection helper).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_workerplan.nim

import std/[json, os, strutils, unittest]
import crisol/types
import crisol/workerplan

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpPlanPath(): string =
  getTempDir() / "crisol_test_workerplan_" & $getCurrentProcessId() & ".json"

proc samplePlan(): MeasurePlan =
  MeasurePlan(
    entrypointPath:    "tests/fixtures/pass_always.nim",
    entrypointAbsPath: "/workspace/tests/fixtures/pass_always.nim",
    flags:             @["--define:foo"],
    nimcacheDir:       "/workspace/.crisol/cache/pass_always_0",
    outputBinPath:     "/workspace/.crisol/bin/pass_always_0/pass_always",
    groupId:           "unit",
    configHash:        "deadbeefcafef00d",
    stateDir:          "/workspace/.crisol",
    projectRoot:       "/workspace",
    # W9l / L1: a distinctive non-empty value, so the round-trip below fails
    # if toJson or parseMeasurePlan drops the field (both would yield "").
    toolchainFp:       "0123456789abcdef",
    driverSite:        DriverSite(known: true, nimExe: "/opt/nim/bin/nim",
                                  nimCwd: "/workspace", search: dsPosix,
                                  pathVar: "/opt/tc/bin:/usr/bin",
                                  systemRoot: ""),
  )

# ===========================================================================
# Behavior 1 — MeasurePlan round-trip
# ===========================================================================

suite "MeasurePlan — toJson / parseMeasurePlan round-trip":

  test "every field survives a toJson -> write -> parseMeasurePlan round-trip":
    let plan = samplePlan()
    let path = tmpPlanPath()
    writeFile(path, $toJson(plan))
    defer: removeFile(path)

    let parsed = parseMeasurePlan(path)
    check parsed.entrypointPath    == plan.entrypointPath
    check parsed.entrypointAbsPath == plan.entrypointAbsPath
    check parsed.flags             == plan.flags
    check parsed.nimcacheDir       == plan.nimcacheDir
    check parsed.outputBinPath     == plan.outputBinPath
    check parsed.groupId           == plan.groupId
    check parsed.configHash        == plan.configHash
    check parsed.stateDir          == plan.stateDir
    check parsed.projectRoot       == plan.projectRoot
    # L1: the plan file is the ONLY channel the toolchain fingerprint takes
    # from the host process into the measure-worker (which deliberately never
    # re-probes it) -- a dropped key here orphans every row the worker writes
    # from the toolchain it was measured under.
    check parsed.toolchainFp       == plan.toolchainFp
    check parsed.toolchainFp.len   > 0
    # R10-S6: likewise the only channel the run's driver site takes.
    check parsed.driverSite.known
    check parsed.driverSite.nimExe     == "/opt/nim/bin/nim"
    check parsed.driverSite.nimCwd     == "/workspace"
    check parsed.driverSite.search     == dsPosix
    check parsed.driverSite.pathVar    == "/opt/tc/bin:/usr/bin"
    check parsed.driverSite.systemRoot == ""

  test "a Windows site round-trips with its search rule and SystemRoot (R10-S6)":
    var plan = samplePlan()
    plan.driverSite = DriverSite(known: true, nimExe: r"C:\nim\bin\nim.exe",
                                 nimCwd: r"C:\proj", search: dsWindows,
                                 pathVar: r"C:\msvc\bin;C:\git\cmd",
                                 systemRoot: r"C:\Windows")
    let path = tmpPlanPath()
    writeFile(path, $toJson(plan))
    defer: removeFile(path)
    let parsed = parseMeasurePlan(path)
    check parsed.driverSite.known
    check parsed.driverSite.search     == dsWindows
    check parsed.driverSite.nimExe     == r"C:\nim\bin\nim.exe"
    check parsed.driverSite.systemRoot == r"C:\Windows"

  test "an unknown site round-trips as unknown, with its reason (R10-S6)":
    var plan = samplePlan()
    plan.driverSite = DriverSite(known: false, why: "the discovery compile failed")
    let path = tmpPlanPath()
    writeFile(path, $toJson(plan))
    defer: removeFile(path)
    let parsed = parseMeasurePlan(path)
    check not parsed.driverSite.known
    check parsed.driverSite.why == "the discovery compile failed"

  test "a malformed site parses as unknown (R10-S6)":
    for bad in [%*{"known": true, "nimExe": "", "nimCwd": "/w", "search": "dsBogus",
                   "pathVar": "", "systemRoot": ""},
                %*{"known": true, "nimExe": "", "nimCwd": "/w", "search": "dsPosix",
                   "pathVar": 3, "systemRoot": ""},
                %*{"known": true, "nimCwd": "/w", "search": "dsPosix",
                   "pathVar": "", "systemRoot": ""},
                %*{"known": "yes"},
                %*[1, 2]]:
      let path = tmpPlanPath()
      var n = toJson(samplePlan())
      n["driverSite"] = bad
      writeFile(path, $n)
      check not parseMeasurePlan(path).driverSite.known
      removeFile(path)

  test "an empty flags array round-trips as an empty seq (not a parse failure)":
    var plan = samplePlan()
    plan.flags = @[]
    let path = tmpPlanPath()
    writeFile(path, $toJson(plan))
    defer: removeFile(path)

    let parsed = parseMeasurePlan(path)
    check parsed.flags.len == 0

  test "groupId/configHash/toolchainFp default to empty string when absent from the JSON":
    let path = tmpPlanPath()
    var n = newJObject()
    n["entrypointPath"]    = newJString("tests/fixtures/pass_always.nim")
    n["entrypointAbsPath"] = newJString("/workspace/tests/fixtures/pass_always.nim")
    n["nimcacheDir"]       = newJString("/workspace/.crisol/cache/x")
    n["outputBinPath"]     = newJString("/workspace/.crisol/bin/x/pass_always")
    n["stateDir"]          = newJString("/workspace/.crisol")
    n["projectRoot"]       = newJString("/workspace")
    writeFile(path, $n)
    defer: removeFile(path)

    let parsed = parseMeasurePlan(path)
    check parsed.groupId == ""
    check parsed.configHash == ""
    check parsed.toolchainFp == ""   # W9l: a pre-W9l plan parses, never raises
    check not parsed.driverSite.known  # R10-S6: absent is unknown (fail closed)
    check parsed.driverSite.why.len > 0
    check parsed.flags.len == 0

# ===========================================================================
# Behavior 2 — malformed plan -> clear CrisolError, never a bare exception
# ===========================================================================

suite "parseMeasurePlan — malformed plan -> clear CrisolError":

  test "missing file raises CrisolError(cekEnvironment)":
    let path = tmpPlanPath()  # never written
    expect(CrisolError):
      discard parseMeasurePlan(path)
    try:
      discard parseMeasurePlan(path)
    except CrisolError as e:
      check e.kind == cekEnvironment
      check "not found" in e.msg

  test "unparseable JSON raises CrisolError(cekEnvironment)":
    let path = tmpPlanPath()
    writeFile(path, "{ this is not valid json ")
    defer: removeFile(path)
    expect(CrisolError):
      discard parseMeasurePlan(path)

  test "a JSON array (not object) raises CrisolError(cekEnvironment)":
    let path = tmpPlanPath()
    writeFile(path, "[1, 2, 3]")
    defer: removeFile(path)
    expect(CrisolError):
      discard parseMeasurePlan(path)

  test "missing required field 'entrypointAbsPath' raises a clear CrisolError naming the field":
    let path = tmpPlanPath()
    var n = newJObject()
    n["entrypointPath"] = newJString("tests/fixtures/pass_always.nim")
    n["nimcacheDir"]     = newJString("/workspace/.crisol/cache/x")
    n["outputBinPath"]   = newJString("/workspace/.crisol/bin/x/pass_always")
    n["stateDir"]        = newJString("/workspace/.crisol")
    writeFile(path, $n)
    defer: removeFile(path)

    try:
      discard parseMeasurePlan(path)
      check false  # must not reach here
    except CrisolError as e:
      check e.kind == cekEnvironment
      check "entrypointAbsPath" in e.msg

  test "missing required field 'projectRoot' raises a clear CrisolError naming the field (rfc-0007 A2c, issue #17)":
    let path = tmpPlanPath()
    var n = newJObject()
    n["entrypointPath"]    = newJString("tests/fixtures/pass_always.nim")
    n["entrypointAbsPath"] = newJString("/workspace/tests/fixtures/pass_always.nim")
    n["nimcacheDir"]       = newJString("/workspace/.crisol/cache/x")
    n["outputBinPath"]     = newJString("/workspace/.crisol/bin/x/pass_always")
    n["stateDir"]          = newJString("/workspace/.crisol")
    writeFile(path, $n)
    defer: removeFile(path)

    try:
      discard parseMeasurePlan(path)
      check false  # must not reach here
    except CrisolError as e:
      check e.kind == cekEnvironment
      check "projectRoot" in e.msg

  test "empty-string required field is treated the same as missing":
    let path = tmpPlanPath()
    var n = newJObject()
    n["entrypointPath"]    = newJString("tests/fixtures/pass_always.nim")
    n["entrypointAbsPath"] = newJString("/workspace/tests/fixtures/pass_always.nim")
    n["nimcacheDir"]       = newJString("")   # empty!
    n["outputBinPath"]     = newJString("/workspace/.crisol/bin/x/pass_always")
    n["stateDir"]          = newJString("/workspace/.crisol")
    writeFile(path, $n)
    defer: removeFile(path)

    try:
      discard parseMeasurePlan(path)
      check false
    except CrisolError as e:
      check e.kind == cekEnvironment
      check "nimcacheDir" in e.msg

# ===========================================================================
# Behavior 3 — forceMeasurementCcEnv() — the env-injection helper
# ===========================================================================

suite "forceMeasurementCcEnv — CCACHE_DISABLE=1 injection":

  test "sets CCACHE_DISABLE=1 in this process's environment":
    delEnv("CCACHE_DISABLE")
    check getEnv("CCACHE_DISABLE") == ""
    forceMeasurementCcEnv()
    check getEnv("CCACHE_DISABLE") == "1"

  test "overrides a pre-existing ambient CCACHE_DISABLE value (e.g. a CI image setting it to 0)":
    putEnv("CCACHE_DISABLE", "0")
    forceMeasurementCcEnv()
    check getEnv("CCACHE_DISABLE") == "1"

# ===========================================================================
# Behavior 4 — measureWorkerWarnings: only genuine warnings, bytes neutralised
# (R15-D3/R15-S5)
# ===========================================================================

suite "measureWorkerWarnings — genuine-only match, control/escape bytes neutralised":

  test "a genuine MeasureWarningPrefix line is relayed verbatim":
    let output = "nim compile output line one\n" &
                 MeasureWarningPrefix & "artifact-identity recording failed\n" &
                 "nim compile output line two\n"
    check measureWorkerWarnings(output) ==
      @[MeasureWarningPrefix & "artifact-identity recording failed"]

  test "a line starting with only the shorter/generic WorkerWarningPrefix, not the full MeasureWarningPrefix, is NOT relayed (R15-S5)":
    ## R15-S5: the merged stream this scans is not exclusively crisol's own
    ## writes -- `compiledriver.defaultRunCc`'s cc phase inherits the
    ## worker's stdout/stderr straight through (`poParentStreams`), so a
    ## compiled program's own diagnostic text can put an arbitrary line in
    ## front of this scan. A line that only manages the SHORT generic root
    ## (`WorkerWarningPrefix`) -- not the longer, specific one every real
    ## `measureworker` warning actually uses -- must be rejected, not
    ## relayed as if it were genuine.
    let spoofed = WorkerWarningPrefix & "not a real worker warning at all"
    check measureWorkerWarnings(spoofed) == newSeq[string]()

    # Mixed with a genuine line: only the genuine one survives.
    let mixed = spoofed & "\n" & MeasureWarningPrefix & "genuine\n"
    check measureWorkerWarnings(mixed) == @[MeasureWarningPrefix & "genuine"]

  test "ESC and other C0 control bytes inside a genuine warning line are neutralised, never passed through (R15-S5)":
    let escSeq  = "\x1b[31mHACKED\x1b[0m"
    let injected = MeasureWarningPrefix & "artifact-identity " & escSeq & " recording failed"
    let relayed = measureWorkerWarnings(injected)
    check relayed.len == 1
    check '\x1b' notin relayed[0]
    check '\x07' notin relayed[0]
    # The message text itself survives -- only the dangerous bytes are
    # swapped out, not the whole line.
    check "HACKED" in relayed[0]
    check "artifact-identity" in relayed[0]
    check "recording failed" in relayed[0]

  test "a BEL (0x07) and DEL (0x7f) byte are each neutralised":
    let injected = MeasureWarningPrefix & "line\x07with\x7fbytes"
    let relayed = measureWorkerWarnings(injected)
    check relayed.len == 1
    check '\x07' notin relayed[0]
    check '\x7f' notin relayed[0]

when isMainModule:
  echo "All workerplan unit tests passed."
