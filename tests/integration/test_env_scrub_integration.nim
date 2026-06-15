## test_env_scrub_integration.nim — A5 end-to-end env filtering test
##
## Tests that the spec-driven spawn entry (forkExecEnvScratch — the single
## run-path spawn after the A6 consolidation) actually filters the child
## environment at the OS level.  The env_probe fixture binary prints specific
## env vars so we can assert which are present/absent in the child.

import std/[unittest, os, osproc, posix, strutils]
import crisol/[types, sandbox, spawn]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (cint, string) =
  ## Open a temp file for capturing child stdout+stderr.
  ## Returns (fd, path).
  let path = getTempDir() / "crisol_envscrub_" & $getpid() & ".txt"
  let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
  doAssert fd >= 0, "failed to open temp file: " & path
  (fd, path)

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

suite "forkExecEnv with SandboxSpec (end-to-end)":

  test "hlIsolated spec: CRISOL_SECRET_XYZ absent in child, PATH present":
    # Plant a forbidden var in the parent environment.
    putEnv("CRISOL_SECRET_XYZ", "forbidden_value")

    # Build an isolated spec using resolveSandbox defaults.
    # DefaultEnvAllowlist includes PATH but not CRISOL_SECRET_XYZ.
    let spec = resolveSandbox(level = hlIsolated)

    let (fd, outPath) = tmpOutputFile()
    var scratch: string
    let (pid, _) = forkExecEnvScratch(@[probeBin], fd,
                                      @[("CRISOL_SINK", "/dev/null")], spec, scratch)
    check pid > Pid(0)
    discard posix.close(fd)
    defer:
      if scratch.len > 0: removeDir(scratch)

    let (exitCode, sig, timedOut) = supervise(pid, 5000)
    check exitCode == 0
    check sig == 0
    check not timedOut

    let output = readOutputFile(outPath)
    removeFile(outPath)

    # PATH must be present (it is on the default allowlist)
    check output.contains("PATH=/")
    # CRISOL_SECRET_XYZ must be absent (not on allowlist → scrubbed)
    check output.contains("CRISOL_SECRET_XYZ=<UNSET>")

  test "hlNone spec: CRISOL_SECRET_XYZ passes through to child":
    putEnv("CRISOL_SECRET_XYZ", "forbidden_value")

    let spec = resolveSandbox(level = hlNone)

    let (fd, outPath) = tmpOutputFile()
    var scratch: string
    let (pid, _) = forkExecEnvScratch(@[probeBin], fd, @[], spec, scratch)
    check pid > Pid(0)
    discard posix.close(fd)
    defer:
      if scratch.len > 0: removeDir(scratch)

    let (exitCode, sig, timedOut) = supervise(pid, 5000)
    check exitCode == 0
    check sig == 0
    check not timedOut

    let output = readOutputFile(outPath)
    removeFile(outPath)

    # With hlNone (no scrub), the secret var must be visible in the child.
    check output.contains("CRISOL_SECRET_XYZ=forbidden_value")

when isMainModule:
  echo "test_env_scrub_integration done"
