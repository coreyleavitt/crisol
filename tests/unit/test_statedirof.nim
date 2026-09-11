## test_statedirof.nim — unit tests for stateDirOf (CRISOL_STATE_DIR override)
##
## Covers:
##   1. CRISOL_STATE_DIR set to an absolute path → stateDirOf returns exactly that
##      (overriding cfg.stateDir).
##   2. env unset → stateDirOf == absolutePath(cfg.projectRoot / cfg.stateDir)
##   3. env unset + cfg.stateDir == "" → returns ""
##   4. RFC-0009 A2 (R3-25): CRISOL_STATE_DIR set to a RELATIVE/odd value is
##      routed through paths.nativeCanonicalize against cfg.projectRoot as the
##      explicit base -- NEVER against the process cwd (config.nim:108's old
##      bare `absolutePath(getEnv(...))` joined against cwd).
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

  test "RFC-0009 A2: relative CRISOL_STATE_DIR resolves against cfg.projectRoot, never cwd":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfg = loadKdl(tmp, "state-dir \".crisol\"\n")
    # A cwd that is DELIBERATELY not cfg.projectRoot -- proves the base is
    # projectRoot, not whatever the process happens to be running from.
    let otherCwd = makeTmpDir()
    defer: removeDir(otherCwd)
    let origCwd = getCurrentDir()
    setCurrentDir(otherCwd)
    putEnv("CRISOL_STATE_DIR", "relative_state/../relative_state/sub")
    try:
      check stateDirOf(cfg) == cfg.projectRoot / "relative_state" / "sub"
      check stateDirOf(cfg) != otherCwd / "relative_state" / "sub"
    finally:
      delEnv("CRISOL_STATE_DIR")
      setCurrentDir(origCwd)

  test "RFC-0009 A2: CRISOL_STATE_DIR with redundant separators normalizes":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfg = loadKdl(tmp, "state-dir \".crisol\"\n")
    putEnv("CRISOL_STATE_DIR", tmp & "//nested///dir")
    try:
      check stateDirOf(cfg) == tmp / "nested" / "dir"
    finally:
      delEnv("CRISOL_STATE_DIR")
