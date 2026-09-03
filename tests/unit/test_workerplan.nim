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

  test "an empty flags array round-trips as an empty seq (not a parse failure)":
    var plan = samplePlan()
    plan.flags = @[]
    let path = tmpPlanPath()
    writeFile(path, $toJson(plan))
    defer: removeFile(path)

    let parsed = parseMeasurePlan(path)
    check parsed.flags.len == 0

  test "groupId/configHash default to empty string when absent from the JSON":
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

when isMainModule:
  echo "All workerplan unit tests passed."
