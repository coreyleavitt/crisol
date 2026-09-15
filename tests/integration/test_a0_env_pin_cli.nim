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

import std/[os, strutils, unittest]
import crisol   # runMain
import ../support/capture

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## file's probe files never collide across cases.
  result = getTempDir() / ("crisol_a0_" & name & "_" & $getCurrentProcessId())
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

    var code = 0
    discard captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                       "--env-pin", "CRISOL_ENV_PIN_TEST=pinned-value"]))
    check code == 0

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

    var code = 0
    discard captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                       "--env-pin", "CRISOL_ENV_PIN_TEST=pinned-value"]))
    check code == 0

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

    var code = 0
    let (_, errText) = captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                       "--env-pin", "NOEQUALSIGN"]))
    check code == 3
    check "--env-pin" in errText

  test "--env-pin with empty NAME -> ExitEnvironment(3)":
    let root = freshProjectRoot("empty_name")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_probe.nim", "quit(0)\n")
    let cfgPath = root / "crisol.kdl"

    var code = 0
    let (_, errText) = captureBoth(proc() =
      code = runMain(@["run", "--config", cfgPath, "--jobs", "1",
                       "--env-pin", "=somevalue"]))
    check code == 3
    check "--env-pin" in errText

when isMainModule:
  echo "test_a0_env_pin_cli: done"
