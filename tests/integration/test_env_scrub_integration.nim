## test_env_scrub_integration.nim — A5 end-to-end env filtering test
##
## Tests that the runner-resolved env (env scrub + injection, §1
## ChildSpec.env) actually filters the child environment at the OS level
## when spawned through process.nim's Supervisor. The env_probe fixture
## binary prints specific env vars so we can assert which are present/absent
## in the child.
##
## rfc-0007 A2a-i: migrated off `spawn.forkExecEnvScratch` + the deleted
## `spawn.supervise` onto the Supervisor — see `../support/spawnhelpers`.

import std/[unittest, os, osproc, posix, options, strutils]
import crisol/[types, sandbox]
import crisol/process
import "../support/spawnhelpers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (string) =
  ## Path for capturing child stdout+stderr.
  getTempDir() / "crisol_envscrub_" & $getpid() & ".txt"

proc readOutputFile(path: string): string =
  readFile(path)

# ---------------------------------------------------------------------------
# Compile the env_probe fixture once at module load time
# ---------------------------------------------------------------------------

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
let probeSrc   = fixtureDir / "env_probe.nim"
let probeBin   = fixtureDir / "bin" / "env_probe"
let nimcacheDir = fixtureDir / "nimcache" / "env_probe"

# Compile fixture (nim c).  Runs synchronously; only happens once per test run.
let compileCmd = "nim c --mm:orc --nimcache:" & nimcacheDir &
                 " -o:" & probeBin & " " & probeSrc
let (compileOut, compileRc) = execCmdEx(compileCmd)
doAssert compileRc == 0,
  "env_probe compile failed (rc=" & $compileRc & "):\n" & compileOut

# ---------------------------------------------------------------------------
# Integration tests
# ---------------------------------------------------------------------------

suite "spawn with SandboxSpec env resolution (end-to-end)":

  test "hlIsolated spec: CRISOL_SECRET_XYZ absent in child, PATH present":
    # Plant a forbidden var in the parent environment.
    putEnv("CRISOL_SECRET_XYZ", "forbidden_value")

    # Build an isolated spec using resolveSandbox defaults.
    # DefaultEnvAllowlist includes PATH but not CRISOL_SECRET_XYZ.
    let spec = resolveSandbox(level = hlIsolated)

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratch = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratch)
    defer: cleanupScratch(scratch)

    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.kind == ekExited
    check report.exit.code == 0
    check report.stop.isNone

    let output = readOutputFile(outPath)
    removeFile(outPath)

    # PATH must be present (it is on the default allowlist)
    check output.contains("PATH=/")
    # CRISOL_SECRET_XYZ must be absent (not on allowlist → scrubbed)
    check output.contains("CRISOL_SECRET_XYZ=<UNSET>")

  test "hlNone spec: CRISOL_SECRET_XYZ passes through to child":
    putEnv("CRISOL_SECRET_XYZ", "forbidden_value")

    let spec = resolveSandbox(level = hlNone)

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratch = ""
    let cs = buildChildSpec(probeBin, [], spec, outPath, scratch)
    defer: cleanupScratch(scratch)

    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.kind == ekExited
    check report.exit.code == 0
    check report.stop.isNone

    let output = readOutputFile(outPath)
    removeFile(outPath)

    # With hlNone (no scrub), the secret var must be visible in the child.
    check output.contains("CRISOL_SECRET_XYZ=forbidden_value")

when isMainModule:
  echo "test_env_scrub_integration done"
