## test_a0_env_pin_cli.nim — RFC-0005 A0 E2E tracer: `--env-pin NAME=VALUE`
## makes the pinned value visible in the child process env, through the REAL
## entry point (`crisol run`), not the library facade directly.
##
## Properties pinned:
##   1. `--env-pin NAME=VALUE` (repeatable) injects NAME=VALUE into the run
##      child's environment, regardless of NAME's value (or absence) on the
##      host running crisol.
##   2. Malformed `--env-pin` (no '=', or an empty NAME) -> ExitEnvironment
##      (3) with a message naming the bad flag, same shape as `--base`
##      requiring `--changed`.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_a0_env_pin_cli.nim

import std/[os, strutils, times, unittest]
import std/posix as posix_mod
import crisol   # runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## file's probe files never collide across cases.
  result = getTempDir() / ("crisol_a0_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

## Writes the observed value of CRISOL_ENV_PIN_TEST to a probe file in the
## run child's cwd (== the project root; runner.nim buildRunChildSpec's cwd
## default) so the test can read it back after the process exits.
const EnvPinProbeFixture = """
import std/os
writeFile("env_pin_probe.txt", "PINNED=" & getEnv("CRISOL_ENV_PIN_TEST", "<UNSET>"))
quit(0)
"""

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  ## Captures BOTH stdout and stderr of one runMain() invocation
  ## simultaneously. Identical recipe to test_b3c_verify_cache_cli.nim's
  ## captureBoth — reused rather than re-derived.
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_a0_out_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_a0_err_" & tag & ".txt")
  let outF = open(outPath, fmWrite)
  let errF = open(errPath, fmWrite)
  let outFd: cint = outF.getFileHandle.cint
  let errFd: cint = errF.getFileHandle.cint
  let savedOutFd: cint = posix_mod.dup(1.cint)
  let savedErrFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(outFd, 1.cint)
  discard posix_mod.dup2(errFd, 2.cint)
  outF.close()
  errF.close()
  var code = 0
  try:
    code = runMain(args)
  finally:
    flushFile(stdout)
    flushFile(stderr)
    discard posix_mod.dup2(savedOutFd, 1.cint)
    discard posix_mod.dup2(savedErrFd, 2.cint)
    discard posix_mod.close(savedOutFd)
    discard posix_mod.close(savedErrFd)
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  try: removeFile(outPath) except CatchableError: discard
  try: removeFile(errPath) except CatchableError: discard
  (code: code, stdout: outText, stderr: errText)

# ---------------------------------------------------------------------------
# 1 — the pinned value reaches the run child, regardless of the host's value.
# ---------------------------------------------------------------------------

suite "A0 CLI — --env-pin injects NAME=VALUE into the run child env":

  test "pinned value visible to the child even though the host never set it":
    let root = freshProjectRoot("basic")
    defer: removeDir(root)
    delEnv("CRISOL_ENV_PIN_TEST")   # host does NOT have this var set at all
    let epPath = "tests/unit/test_probe.nim"
    writeFile(root / epPath, EnvPinProbeFixture)
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--env-pin", "CRISOL_ENV_PIN_TEST=pinned-value"])
    check r.code == 0

    let probePath = root / "env_pin_probe.txt"
    check fileExists(probePath)
    check readFile(probePath) == "PINNED=pinned-value"

  test "pinned value OVERRIDES the host's own value for the run child":
    let root = freshProjectRoot("override")
    defer: removeDir(root)
    putEnv("CRISOL_ENV_PIN_TEST", "host-value")
    defer: delEnv("CRISOL_ENV_PIN_TEST")
    let epPath = "tests/unit/test_probe.nim"
    writeFile(root / epPath, EnvPinProbeFixture)
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--env-pin", "CRISOL_ENV_PIN_TEST=pinned-value"])
    check r.code == 0

    let probePath = root / "env_pin_probe.txt"
    check fileExists(probePath)
    check readFile(probePath) == "PINNED=pinned-value"

# ---------------------------------------------------------------------------
# 2 — malformed --env-pin -> ExitEnvironment(3), clear message.
# ---------------------------------------------------------------------------

suite "A0 CLI — malformed --env-pin is rejected":

  test "--env-pin without '=' -> ExitEnvironment(3)":
    let root = freshProjectRoot("no_eq")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_probe.nim", "quit(0)\n")
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--env-pin", "NOEQUALSIGN"])
    check r.code == 3
    check "--env-pin" in r.stderr

  test "--env-pin with empty NAME -> ExitEnvironment(3)":
    let root = freshProjectRoot("empty_name")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_probe.nim", "quit(0)\n")
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--env-pin", "=somevalue"])
    check r.code == 3
    check "--env-pin" in r.stderr

when isMainModule:
  echo "test_a0_env_pin_cli: done"
