## test_statedirof.nim — unit tests for stateDirOf (CRISOL_STATE_DIR override)
##
## Covers:
##   1. CRISOL_STATE_DIR set to an absolute path → stateDirOf returns exactly that
##      (overriding cfg.stateDir).
##   2. env unset → stateDirOf == absolutePath(cfg.projectRoot / cfg.stateDir)
##   3. env unset + cfg.stateDir == "" → returns ""
##
## Run with:
##   ./dev test tests/unit/test_statedirof.nim

import std/[os, unittest, tempfiles]
import crisol/[types, config]

proc makeTmpDir(): string =
  createTempDir("crisol_statedirof_", "")

proc writeFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc loadKdl(tmp: string; kdl: string): Config =
  let path = writeFile(tmp, "crisol.kdl",
    "group \"unit\" { globs \"tests/unit/*.nim\" }\n" & kdl)
  let (cfg, _) = loadConfig(configPath = path)
  cfg

suite "stateDirOf — CRISOL_STATE_DIR env override":

  test "CRISOL_STATE_DIR set → overrides cfg.stateDir":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfg = loadKdl(tmp, "state-dir \".crisol\"\n")
    let override = "/tmp/crisol_test_override_dir"
    putEnv("CRISOL_STATE_DIR", override)
    try:
      check stateDirOf(cfg) == absolutePath(override)
    finally:
      delEnv("CRISOL_STATE_DIR")

  test "env unset → absolutePath(cfg.projectRoot / cfg.stateDir)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfg = loadKdl(tmp, "state-dir \".crisol\"\n")
    delEnv("CRISOL_STATE_DIR")
    check stateDirOf(cfg) == absolutePath(cfg.projectRoot / cfg.stateDir)

  test "env unset + stateDir empty → returns empty string":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # Build a Config directly with stateDir="" to exercise that branch.
    var cfg = Config(
      projectRoot: tmp,
      stateDir:    "",
      groups:      @[],
      timeoutSecs: 300,
      compileTimeoutSecs: 600,
      maxOutputBytes: 10 * 1024 * 1024,
    )
    delEnv("CRISOL_STATE_DIR")
    check stateDirOf(cfg) == ""
