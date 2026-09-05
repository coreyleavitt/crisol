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

import std/[os, options, strutils, unittest, tempfiles]
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
    let (cfg, _) = loadConfig(configPath = cfgPath)

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
    let (cfg, _) = loadConfig(configPath = cfgPath)
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
    let (cfg, _) = loadConfig(configPath = cfgPath)
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
    let (cfg, _) = loadConfig(configPath = cfgPath)
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
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].flags == @["-d:only"]

  test "issue #3: Config.flags retains the RAW global set (not pre-merged with any group)":
    ## Group.flags is globalFlags & groupFlags (pre-merged, per group). Config.flags
    ## is the separate raw global set — the fallback for an ad-hoc gskFiles path
    ## that matches no configured group (RFC-0001:409).
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
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.flags == @["-d:global1", "-d:global2"]

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
    let (cfg, _) = loadConfig(startDir = nested)
    check cfg.projectRoot == tmp
    check cfg.groups.len == 1
    check cfg.groups[0].name == "unit"

  test "startDir with no ancestor config → convention fallback (no error)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # No crisol.kdl anywhere; no .git either
    let (cfg, _) = loadConfig(startDir = tmp)
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
    let (cfg, _) = loadConfig(configPath = cfgPath, startDir = tmp)
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
    let (cfg, _) = loadConfig(startDir = tmp)
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
    let (cfg, _) = loadConfig(startDir = sub)
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

# ---------------------------------------------------------------------------
# S1 — unknown-config-key warnings (Feature D)
# ---------------------------------------------------------------------------

suite "config — unknown-key warnings (S1)":

  test "top-level typo'd key yields one warning with correct fields":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
timeout-secs 60
timeout-sec 30
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.timeoutSecs == 60          # valid key parsed correctly
    check warns.len == 1
    check warns[0].key     == "timeout-sec"
    check warns[0].context == "top-level"
    check warns[0].source  == cfgPath
    check "timeout-sec" in warns[0].message
    check "top-level"   in warns[0].message

  test "clean config yields zero warnings":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
jobs 2
timeout-secs 120
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (_, warns) = loadConfig(configPath = cfgPath)
    check warns.len == 0

  test "group-level unknown key warns with group name as context":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "integration" {
    globs "tests/integration/test_*.nim"
    max-retries 3
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (_, warns) = loadConfig(configPath = cfgPath)
    check warns.len == 1
    check warns[0].key     == "max-retries"
    check warns[0].context == "integration"
    check warns[0].source  == cfgPath
    check "max-retries"   in warns[0].message
    check "integration"   in warns[0].message

# ---------------------------------------------------------------------------
# S3 — max-jobs parsing (Feature C)
# ---------------------------------------------------------------------------

suite "config — max-jobs parsing (S3)":

  test "max-jobs 1 in group → Group.maxJobs == some(1)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    max-jobs 1
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].maxJobs == some(1)

  test "max-jobs 4 in group → Group.maxJobs == some(4)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    max-jobs 4
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].maxJobs == some(4)

  test "max-jobs 0 → cekConfig (0 is not a valid cap)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    max-jobs 0
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

  test "max-jobs -1 → cekConfig (negative is not valid)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    max-jobs -1
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

  test "absent max-jobs → Group.maxJobs == none":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].maxJobs == none(int)

# ---------------------------------------------------------------------------
# B1 — retries config-key parsing
# ---------------------------------------------------------------------------

suite "config — retries (B1)":

  test "global retries N → Config.retries == N":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
retries 2
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.retries == 2

  test "group retries N → Group.retries == N":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    retries 1
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.groups[0].retries == 1

  test "absent retries → Config.retries == 0 and Group.retries == 0":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.retries == 0
    check cfg.groups[0].retries == 0

  test "retries -1 → cekConfig (negative not allowed)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    retries -1
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

# ---------------------------------------------------------------------------
# S6a (Feature B) — memory config-key parsing
# ---------------------------------------------------------------------------

suite "config — memory config keys (S6a)":

  test "mem-budget-mb 2048 round-trips to cfg.memBudgetMb == some(2048)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-budget-mb 2048
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memBudgetMb == some(2048)

  test "absent mem-budget-mb → cfg.memBudgetMb == none (initAdmission uses no cap)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memBudgetMb == none(int)

  test "mem-per-job-mb 700 round-trips to cfg.memPerJobMb == some(700)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-job-mb 700
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memPerJobMb == some(700)

  test "absent mem-per-job-mb → cfg.memPerJobMb == none (initAdmission resolves none → 512 MiB seed)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memPerJobMb == none(int)

  test "mem-per-run-mb 128 round-trips to cfg.memPerRunMb == some(128)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-run-mb 128
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memPerRunMb == some(128)

  test "absent mem-per-run-mb → cfg.memPerRunMb == none (initAdmission resolves none → 64 MiB seed)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memPerRunMb == none(int)

  # L2: negative mem-*-mb values must be rejected as config errors.
  test "negative mem-budget-mb → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-budget-mb -1
group "unit" {
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

  test "negative mem-per-job-mb → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-job-mb -100
group "unit" {
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

  test "negative mem-per-run-mb → cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-run-mb -64
group "unit" {
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

  # L2b (Fix 1): zero is not meaningful for mem-per-job-mb / mem-per-run-mb;
  # only mem-budget-mb 0 is valid (sentinel meaning "no cap").
  test "mem-per-job-mb 0 → cekConfig (zero reservation is not meaningful)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-job-mb 0
group "unit" {
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

  test "mem-per-run-mb 0 → cekConfig (zero reservation is not meaningful)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-per-run-mb 0
group "unit" {
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

  test "mem-budget-mb 0 → accepted as some(0) (sentinel: no cap)":
    ## mem-budget-mb 0 is the user's way of saying "no budget cap".
    ## Unlike mem-per-job-mb and mem-per-run-mb, 0 IS a valid sentinel here.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-budget-mb 0
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memBudgetMb == some(0)

  test "mem-aware #false round-trips to cfg.memAware == some(false)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-aware #false
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memAware == some(false)

  test "mem-aware #true round-trips to cfg.memAware == some(true)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-aware #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memAware == some(true)

  test "absent mem-aware → cfg.memAware == none (unset = auto-detect at wiring time)":
    ## mem-aware models a tristate: none = auto (probe-availability decides),
    ## some(true) = forced on, some(false) = forced off (kill switch).
    ## S6b resolves the auto case; the config layer just records the user's intent.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.memAware == none(bool)

  test "all four mem keys together produce zero unknown-key warnings":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
mem-budget-mb 1024
mem-per-job-mb 512
mem-per-run-mb 64
mem-aware #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (_, warns) = loadConfig(configPath = cfgPath)
    check warns.len == 0

# ---------------------------------------------------------------------------
# RFC-0006 M-artifact-identity PASS (b2) — measure-compile-reuse gate
# ---------------------------------------------------------------------------

suite "config — measure-compile-reuse gate (RFC-0006 M-artifact-identity b2)":

  test "absent measure-compile-reuse -> cfg.measureCompileReuse == false (default off)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.measureCompileReuse == false

  test "measure-compile-reuse #true round-trips to cfg.measureCompileReuse == true":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
measure-compile-reuse #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.measureCompileReuse == true

  test "measure-compile-reuse #false round-trips to cfg.measureCompileReuse == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
measure-compile-reuse #false
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.measureCompileReuse == false

  test "no config file (convention fallback) -> cfg.measureCompileReuse == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.measureCompileReuse == false

# ---------------------------------------------------------------------------
# rfc-0007 A6b — strict-hygiene gate (config parity with the CLI flag)
# ---------------------------------------------------------------------------

suite "config — strict-hygiene gate (rfc-0007 A6b)":

  test "absent strict-hygiene -> cfg.strictHygiene == false (default off)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.strictHygiene == false

  test "strict-hygiene #true round-trips to cfg.strictHygiene == true":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
strict-hygiene #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.strictHygiene == true

  test "strict-hygiene #false round-trips to cfg.strictHygiene == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
strict-hygiene #false
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.strictHygiene == false

  test "no config file (convention fallback) -> cfg.strictHygiene == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.strictHygiene == false

# ---------------------------------------------------------------------------
# RFC-0005 B1c — explain-miss gate (config parity with --explain-miss)
# ---------------------------------------------------------------------------

suite "config — explain-miss gate (RFC-0005 B1c)":

  test "absent explain-miss -> cfg.explainMiss == false (default off)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.explainMiss == false

  test "explain-miss #true round-trips to cfg.explainMiss == true":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
explain-miss #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.explainMiss == true

  test "explain-miss #false round-trips to cfg.explainMiss == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
explain-miss #false
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.explainMiss == false

  test "explain-miss with a non-boolean argument raises cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "explain-miss \"yes\"\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    expect CrisolError:
      discard loadConfig(configPath = cfgPath)

  test "no config file (convention fallback) -> cfg.explainMiss == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.explainMiss == false

# ---------------------------------------------------------------------------
# RFC-0005 B2b — cache-stats gate (config parity with --cache-stats)
# ---------------------------------------------------------------------------

suite "config — cache-stats gate (RFC-0005 B2b)":

  test "absent cache-stats -> cfg.cacheStats == false (default off)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cacheStats == false

  test "cache-stats #true round-trips to cfg.cacheStats == true":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-stats #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cacheStats == true

  test "cache-stats #false round-trips to cfg.cacheStats == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-stats #false
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cacheStats == false

  test "cache-stats with a non-boolean argument raises cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "cache-stats \"yes\"\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    expect CrisolError:
      discard loadConfig(configPath = cfgPath)

  test "no config file (convention fallback) -> cfg.cacheStats == false":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.cacheStats == false

# ---------------------------------------------------------------------------
# M-report PASS (b1) — reuse-check alerting policy block
# ---------------------------------------------------------------------------

suite "config — reuse-check alerting policy (M-report b1)":

  test "absent reuse-check block -> disabled":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check not cfg.reuseCheck.enabled

  test "reuse-check block present with alert-below -> enabled, alertBelow round-trips":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below 0.4
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.reuseCheck.enabled
    check cfg.reuseCheck.alertBelow == 0.4

  test "reuse-check block present without alert-below -> enabled, default 0.5":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.reuseCheck.enabled
    check cfg.reuseCheck.alertBelow == 0.5

  test "no config file (convention fallback) -> cfg.reuseCheck disabled":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check not cfg.reuseCheck.enabled

  test "unknown child key in reuse-check -> warning, not error":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below 0.5
    bogus-key 1
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.reuseCheck.enabled
    check warns.len == 1
    check warns[0].key == "bogus-key"

  # -------------------------------------------------------------------------
  # RFC-0006 review R14-T4 — alert-below range validation ([0.0, 1.0])
  # -------------------------------------------------------------------------

  test "alert-below 1.5 -> cekConfig (above the [0.0, 1.0] range)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below 1.5
}
group "unit" {
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

  test "alert-below -0.1 -> cekConfig (below the [0.0, 1.0] range)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below -0.1
}
group "unit" {
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

  test "alert-below 0.0 (lower boundary) -> accepted":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below 0.0
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.reuseCheck.enabled
    check cfg.reuseCheck.alertBelow == 0.0

  test "alert-below 1.0 (upper boundary) -> accepted":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
reuse-check {
    alert-below 1.0
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.reuseCheck.enabled
    check cfg.reuseCheck.alertBelow == 1.0

# ---------------------------------------------------------------------------
# P1 — state-dir path traversal validation
# ---------------------------------------------------------------------------

suite "config — state-dir path validation (P1)":

  test "absolute state-dir is rejected with cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
state-dir "/tmp/evil"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
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
    check "state-dir" in msg
    check "relative" in msg

  test "state-dir with .. component is rejected with cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
state-dir "../../outside"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
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
    check "state-dir" in msg
    check ".." in msg

  test "state-dir with nested .. component is rejected with cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
state-dir "a/../../../escape"
group "unit" {
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

  test "normal relative state-dir loads successfully":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
state-dir ".crisol"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.stateDir == ".crisol"

  test "nested relative state-dir without .. loads successfully":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
state-dir "build/state/crisol"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.stateDir == "build/state/crisol"

# ---------------------------------------------------------------------------
# P4 — kvBigInt produces a "too large" config error, not misleading "integer" message
# ---------------------------------------------------------------------------

suite "config — kvBigInt oversized integer (P4)":

  test "integer value too large for int64 yields cekConfig with 'too large' message":
    ## nkdl represents integers that exceed int64 bounds as kvBigInt.
    ## The old requireIntArg check only tested kind != kvInt, so a kvBigInt
    ## triggered the generic "requires an integer argument" message. After
    ## the fix, kvBigInt must produce a "too large" message.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # 99999999999999999999999 is far beyond int64 max; nkdl will parse it as kvBigInt.
    let kdl = """
jobs 99999999999999999999999
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
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
    # Must say "too large" — not just "requires an integer argument".
    check "too large" in msg

# ---------------------------------------------------------------------------
# P6 — kvBigInt in group-level integer fields gives "too large" message
# ---------------------------------------------------------------------------

suite "config — kvBigInt in group integer fields (P6)":

  test "oversized timeout-secs in group yields cekConfig with 'too large' message":
    ## timeout-secs in a group block used to check `v.get.kind != kvInt` inline,
    ## so a kvBigInt value produced the generic "requires an integer argument" message.
    ## After routing through requireIntArg, it must produce a "too large" message.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    timeout-secs 99999999999999999999999
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
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
    check "too large" in msg

  test "oversized max-jobs in group yields cekConfig with 'too large' message":
    ## max-jobs in a group block had the same inline kind-check issue.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    max-jobs 99999999999999999999999
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
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
    check "too large" in msg

# ---------------------------------------------------------------------------
# Fix 1 — rlimit-nofile config plumbing
# ---------------------------------------------------------------------------

suite "config — rlimit-nofile (Fix 1: RLIMIT_NOFILE override plumbing)":

  test "absent rlimit-nofile -> cfg.rlimitNofile == none (sandbox applies its own default)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.rlimitNofile == none(int64)

  test "rlimit-nofile N round-trips to cfg.rlimitNofile == some(N)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
rlimit-nofile 4096
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.rlimitNofile == some(4096'i64)

  test "no config file (convention fallback) -> cfg.rlimitNofile == none":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.rlimitNofile == none(int64)

  test "rlimit-nofile 0 is rejected (must be >= 1)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
rlimit-nofile 0
group "unit" {
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

# ---------------------------------------------------------------------------
# RFC-0005 B3c — verify-cache-pct config plumbing
# ---------------------------------------------------------------------------

suite "config — verify-cache-pct (RFC-0005 B3c: --verify-cache sample-% default)":

  test "absent verify-cache-pct -> cfg.verifyCachePct == DefaultVerifyCachePct (5)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.verifyCachePct == DefaultVerifyCachePct
    check cfg.verifyCachePct == 5

  test "verify-cache-pct N round-trips to cfg.verifyCachePct == N":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
verify-cache-pct 25
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.verifyCachePct == 25

  test "no config file (convention fallback) -> cfg.verifyCachePct == DefaultVerifyCachePct":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.verifyCachePct == DefaultVerifyCachePct

  test "verify-cache-pct 0 is accepted (a legitimate 'sample nothing' config)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
verify-cache-pct 0
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.verifyCachePct == 0

  test "verify-cache-pct -1 is rejected (must be >= 0)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
verify-cache-pct -1
group "unit" {
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

suite "config — env-pin (RFC-0005 A0: repeatable NAME=VALUE pin)":

  test "absent env-pin -> cfg.envPins is empty":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.envPins.len == 0

  test "one env-pin node round-trips to cfg.envPins":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "USER" "ci-runner"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.envPins == @[("USER", "ci-runner")]

  test "repeated env-pin nodes each contribute one pair, in order":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "USER" "ci-runner"
env-pin "HOME" "/home/ci"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.envPins == @[("USER", "ci-runner"), ("HOME", "/home/ci")]

  test "env-pin with only 1 argument is rejected":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "USER"
group "unit" {
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

  test "env-pin with 3 arguments is rejected":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "USER" "ci-runner" "extra"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
    check caught

  test "env-pin with an empty NAME is rejected":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "" "value"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    var caught = false
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
    check caught

  test "env-pin with an empty VALUE is accepted (pins to the empty string)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
env-pin "LC_ALL" ""
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.envPins == @[("LC_ALL", "")]

# ---------------------------------------------------------------------------
# RFC-0005 A3c-i — remote-cache tier parse
# ---------------------------------------------------------------------------

suite "config — remote-cache tier parse (RFC-0005 A3c-i)":

  test "absent remote-cache blocks -> cfg.cache.remotes is empty":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.remotes.len == 0

  test "full block -> all fields parsed":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "team-s3" {
    url "file:///mnt/shared/crisol"
    verify-trust #true
    backfill-on-hit #false
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.remotes.len == 1
    let t = cfg.cache.remotes[0]
    check t.name == "team-s3"
    check t.url == "file:///mnt/shared/crisol"
    check t.verifyTrust == some(true)
    check t.backfillOnHit == false

  test "defaults when optional children absent: backfill-on-hit true, verify-trust none":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "mirror" {
    url "https://cache.example.com/crisol"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.remotes.len == 1
    let t = cfg.cache.remotes[0]
    check t.name == "mirror"
    check t.url == "https://cache.example.com/crisol"
    check t.verifyTrust.isNone
    check t.backfillOnHit == true

  test "multiple remote-cache blocks preserve document order":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "first" {
    url "file:///mnt/a"
}
remote-cache "second" {
    url "file:///mnt/b"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.remotes.len == 2
    check cfg.cache.remotes[0].name == "first"
    check cfg.cache.remotes[1].name == "second"

  test "duplicate remote-cache names -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "dup" {
    url "file:///mnt/a"
}
remote-cache "dup" {
    url "file:///mnt/b"
}
group "unit" {
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

  test "missing url -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "no-url" {
    backfill-on-hit #true
}
group "unit" {
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

  test "malformed url (no scheme) -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "bad-url" {
    url "not-a-url"
}
group "unit" {
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

  test "empty remote-cache name -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "" {
    url "file:///mnt/a"
}
group "unit" {
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

  test "unknown child key in remote-cache -> warning, not error":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
remote-cache "mirror" {
    url "file:///mnt/a"
    bogus-key 1
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.cache.remotes.len == 1
    check warns.len == 1
    check warns[0].key == "bogus-key"
    check warns[0].context == "remote-cache mirror"

# ---------------------------------------------------------------------------
# RFC-0005 C4 — cache-trust block parse
# ---------------------------------------------------------------------------

suite "config — cache-trust block parse (RFC-0005 C4)":

  test "absent cache-trust block -> policy \"none\", empty key-id":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n"
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.trust.policy == "none"
    check cfg.cache.trust.keyId == ""

  test "policy + key-id parsed":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-trust {
    policy "hmac"
    key-id "ci-2026"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.trust.policy == "hmac"
    check cfg.cache.trust.keyId == "ci-2026"

  test "policy \"ed25519\" parses (wiring arrives in C5a)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-trust {
    policy "ed25519"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.trust.policy == "ed25519"
    check cfg.cache.trust.pinnedKeys.len == 0

  test "pinned-key parsed, repeatable, order-preserving (RFC-0005 C5a)":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-trust {
    policy "ed25519"
    pinned-key "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="
    pinned-key "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb="
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)
    check cfg.cache.trust.policy == "ed25519"
    check cfg.cache.trust.pinnedKeys == @[
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=",
    ]

  test "unknown policy string -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-trust {
    policy "rot13"
}
group "unit" {
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

  test "unknown child key in cache-trust -> warning, not error":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
cache-trust {
    policy "hmac"
    bogus-key 1
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeFile(tmp, "crisol.kdl", kdl)
    let (cfg, warns) = loadConfig(configPath = cfgPath)
    check cfg.cache.trust.policy == "hmac"
    check warns.len == 1
    check warns[0].key == "bogus-key"
    check warns[0].context == "cache-trust"

when isMainModule:
  echo "All config tests passed."
