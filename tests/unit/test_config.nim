## test_config.nim — C1 unit tests for crisol.kdl config loading
##
## Covers:
##   - Full parse: globals + two groups (opt-in, gated, custom timeout, flags)
##   - Flag merge precedence: global flags appear BEFORE group flags
##   - Walk-up discovery: finds crisol.kdl in an ancestor dir
##   - --config override wins over walk-up
##   - --config to missing path → cekEnvironment
##   - No config → convention groups (no error), projectRoot = .git or cwd
##   - Malformed KDL → CrisolError(cekConfig)
##   - Validation: duplicate group names → cekConfig
##   - Validation: group with no globs → cekConfig

import std/[os, options, unittest, tempfiles]
import crisol/[types, config]

# ---------------------------------------------------------------------------
# Helper: write a file into a temp directory
# ---------------------------------------------------------------------------

proc writeFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc makeTmpDir(): string =
  result = createTempDir("crisol_test_", "")

# ---------------------------------------------------------------------------
# Full parse test
# ---------------------------------------------------------------------------

suite "config — full KDL parse":

  test "globals + two groups (one opt-in, gated, custom timeout, flags)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)

    let kdl = """
jobs 4
timeout-secs 120
compile-timeout-secs 300
flags "--hints:off" "--mm:orc"
dep-roots "../sibling/src"

group "unit" {
    globs "tests/unit/test_*.nim"
}
group "integration" {
    opt-in #true
    gate "FRESCO_DB_URL"
    timeout-secs 60
    flags "-d:integration"
    globs "tests/integration/test_*.nim" "tests/integration/**/it_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let cfg = loadConfig(configPath = cfgPath)

    check cfg.jobs == 4
    check cfg.timeoutSecs == 120
    check cfg.compileTimeoutSecs == 300
    check cfg.depRoots == @["../sibling/src"]
    check cfg.groups.len == 2

    let unit = cfg.groups[0]
    check unit.name == "unit"
    check unit.optIn == false
    check unit.gate.isNone
    check unit.timeoutSecs == 0
    check unit.globs == @["tests/unit/test_*.nim"]
    # Flag merge: global flags only (no group-specific)
    check unit.flags == @["--hints:off", "--mm:orc"]

    let integ = cfg.groups[1]
    check integ.name == "integration"
    check integ.optIn == true
    check integ.gate.isSome
    check integ.gate.get.env == "FRESCO_DB_URL"
    check integ.timeoutSecs == 60
    check integ.globs == @["tests/integration/test_*.nim",
                            "tests/integration/**/it_*.nim"]
    # Flag merge: global flags FIRST, then group flags
    check integ.flags == @["--hints:off", "--mm:orc", "-d:integration"]

  test "projectRoot is the config file's directory":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let cfg = loadConfig(configPath = cfgPath)
    check cfg.projectRoot == tmp

# ---------------------------------------------------------------------------
# Flag merge precedence
# ---------------------------------------------------------------------------

suite "config — flag merge":

  test "global flags appear before group flags":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
flags "-d:global1" "-d:global2"

group "a" {
    flags "-d:group1"
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let cfg = loadConfig(configPath = cfgPath)
    check cfg.groups[0].flags == @["-d:global1", "-d:global2", "-d:group1"]

  test "group with no specific flags only has globals":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
flags "--mm:orc"

group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let cfg = loadConfig(configPath = cfgPath)
    check cfg.groups[0].flags == @["--mm:orc"]

  test "no globals + group flags → only group flags":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    flags "-d:only"
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let cfg = loadConfig(configPath = cfgPath)
    check cfg.groups[0].flags == @["-d:only"]

# ---------------------------------------------------------------------------
# Walk-up discovery
# ---------------------------------------------------------------------------

suite "config — walk-up discovery":

  test "finds crisol.kdl in ancestor, projectRoot = that dir":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # Put crisol.kdl at tmp root
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    discard writeFile(tmp, "crisol.kdl", kdl)
    # startDir is a deeply nested subdirectory
    let nested = tmp / "a" / "b" / "c"
    createDir(nested)
    let cfg = loadConfig(startDir = nested)
    check cfg.projectRoot == tmp
    check cfg.groups.len == 1
    check cfg.groups[0].name == "unit"

  test "startDir with no ancestor config → convention fallback (no error)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # No crisol.kdl anywhere; no .git either
    let cfg = loadConfig(startDir = tmp)
    check cfg.groups.len == 2
    check cfg.groups[0].name == "unit"
    check cfg.groups[1].name == "integration"

# ---------------------------------------------------------------------------
# --config override
# ---------------------------------------------------------------------------

suite "config — --config override":

  test "--config path wins over walk-up":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # Create an override config in a subdirectory
    let sub = tmp / "sub"
    createDir(sub)
    let kdl = "group \"smoke\" {\n    globs \"tests/smoke/test_*.nim\"\n}\n"
    let cfgPath = writeFile(sub, "crisol.kdl", kdl)
    # Also put a different config at the walk-up location (should be ignored)
    discard writeFile(tmp, "crisol.kdl",
      "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
    let cfg = loadConfig(configPath = cfgPath, startDir = tmp)
    check cfg.groups.len == 1
    check cfg.groups[0].name == "smoke"

  test "--config to missing path raises cekEnvironment":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = tmp / "does_not_exist.kdl")
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekEnvironment

# ---------------------------------------------------------------------------
# No config → conventions
# ---------------------------------------------------------------------------

suite "config — convention fallback":

  test "no crisol.kdl → convention groups returned, no error":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfg = loadConfig(startDir = tmp)
    check cfg.groups.len == 2
    check cfg.groups[0].name == "unit"
    check cfg.groups[0].globs == @["tests/unit/test_*.nim"]
    check cfg.groups[1].name == "integration"
    check cfg.groups[1].globs == @["tests/integration/test_*.nim"]

  test "convention fallback with .git dir sets projectRoot to .git parent":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    createDir(tmp / ".git")
    let sub = tmp / "nested"
    createDir(sub)
    let cfg = loadConfig(startDir = sub)
    check cfg.projectRoot == tmp

# ---------------------------------------------------------------------------
# Malformed KDL → cekConfig
# ---------------------------------------------------------------------------

suite "config — malformed KDL":

  test "syntactically broken file raises cekConfig with non-empty message":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfgPath = writeFile(tmp, "crisol.kdl", "this is not ; valid {{{{")
    var caught = false
    var kind: CrisolErrorKind
    var msg = ""
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
      msg = e.msg
    check caught
    check kind == cekConfig
    check msg.len > 0

# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

suite "config — validation":

  test "duplicate group names → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
group "unit" {
    globs "tests/other/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "group with no globs → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"empty\" {\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "gate with empty env-var name → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    gate "   "
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "negative timeout-secs in group → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    timeout-secs -5
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

when isMainModule:
  echo "All config tests passed."
