## test_statedirof.nim — unit tests for stateDirOf (CRISOL_STATE_DIR override)
##
## Covers:
##   1. CRISOL_STATE_DIR set to an absolute path → stateDirOf returns exactly that
##      (overriding cfg.stateDir).
##   2. env unset → stateDirOf == absolutePath(cfg.projectRoot / cfg.stateDir)
##   3. env unset + cfg.stateDir == "" → the CLI's default,
##      absolutePath(cfg.projectRoot / DefaultStateDir) -- never "" (R8-D3:
##      "" made every bin/cache/depgraph path cwd-relative)
##   3b. env unset + relative/empty cfg.projectRoot → CrisolError(cekConfig),
##      never a silent join against the process cwd (R8-D3)
##   4. RFC-0009 A2 (R3-25): CRISOL_STATE_DIR set to a RELATIVE/odd value is
##      routed through paths.nativeCanonicalize against cfg.projectRoot as the
##      explicit base -- NEVER against the process cwd (config.nim:108's old
##      bare `absolutePath(getEnv(...))` joined against cwd).
##
## Run with:
##   ./dev test tests/unit/test_statedirof.nim

import std/[os, unittest, tempfiles, strutils]
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

  test "R8-D3: env unset + stateDir empty → <projectRoot>/.crisol (the CLI default), never cwd":
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
    # A cwd that is DELIBERATELY not cfg.projectRoot: pre-R8-D3 this branch
    # returned "", and every consumer's `"" / "bin"` resolved against it.
    let otherCwd = makeTmpDir()
    defer: removeDir(otherCwd)
    let origCwd = getCurrentDir()
    setCurrentDir(otherCwd)
    defer: setCurrentDir(origCwd)
    delEnv("CRISOL_STATE_DIR")
    check stateDirOf(cfg) == absolutePath(tmp / DefaultStateDir)
    check stateDirOf(cfg).isAbsolute
    # Same answer the config loader gives a crisol.kdl with no state-dir node.
    let loaded = loadKdl(tmp, "")
    check stateDirOf(loaded) == stateDirOf(cfg)

  test "R8-D3: env unset + relative or empty projectRoot → CrisolError, never a cwd join":
    delEnv("CRISOL_STATE_DIR")
    for root in ["", "relative/root"]:
      for sd in ["", ".crisol"]:
        let cfg = Config(projectRoot: root, stateDir: sd)
        expect CrisolError:
          discard stateDirOf(cfg)
    # An ABSOLUTE stateDir needs no base, so it still resolves.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    check stateDirOf(Config(projectRoot: "", stateDir: tmp)) == tmp

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
      # RFC-0009 B4a: stateDirOf's env-set branch routes through
      # nativeCanonicalize, which always returns forward-slash canonical
      # text (see paths.nim) -- regardless of host OS. std/os's `/` would
      # yield a backslash-joined expectation on native Windows, so build
      # the expected value as an explicit forward-slash string instead.
      check stateDirOf(cfg) == cfg.projectRoot.replace('\\', '/') & "/relative_state/sub"
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
      # RFC-0009 B4a: see the note above -- forward-slash canonical expected.
      check stateDirOf(cfg) == tmp.replace('\\', '/') & "/nested/dir"
    finally:
      delEnv("CRISOL_STATE_DIR")
