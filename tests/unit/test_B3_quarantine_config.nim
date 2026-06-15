## test_B3_quarantine_config.nim — B3 unit tests: quarantine config parsing
##
## Covers:
##   1. quarantine { "a.nim" "b.nim" } → config.quarantine == {"a.nim","b.nim"}
##   2. Missing quarantine block → empty HashSet (default)
##   3. Empty quarantine block → empty HashSet
##   4. Quarantine paths are root-relative strings (raw equality vs ep.path)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_B3_quarantine_config.nim

import std/[os, sets, unittest, tempfiles]
import crisol/[types, config]

proc writeTmpFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc makeTmpDir(): string =
  result = createTempDir("crisol_b3_cfg_", "")

# ---------------------------------------------------------------------------
# Suite 1: quarantine block present
# ---------------------------------------------------------------------------

suite "B3 config — quarantine block parsing":

  test "quarantine block with two paths yields HashSet of those paths":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
quarantine "tests/integration/test_x.nim" "tests/integration/test_y.nim"

group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeTmpFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check cfg.quarantine.len == 2
    check "tests/integration/test_x.nim" in cfg.quarantine
    check "tests/integration/test_y.nim" in cfg.quarantine

  test "missing quarantine block yields empty set":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeTmpFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check cfg.quarantine.len == 0

  test "quarantine block with no paths yields empty set":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    # A quarantine node with no arguments — empty block
    let kdl = """
quarantine

group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeTmpFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check cfg.quarantine.len == 0

  test "quarantine paths are raw strings (no normalization)":
    ## Matching contract: config path is matched against ep.path by raw string
    ## equality. ep.path is project-root-relative with '/' separators.
    ## This test locks in that the stored form is exactly as-written.
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let kdl = """
quarantine "tests/unit/test_foo.nim"

group "unit" {
    globs "tests/unit/test_*.nim"
}
"""
    let cfgPath = writeTmpFile(tmp, "crisol.kdl", kdl)
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check "tests/unit/test_foo.nim" in cfg.quarantine
    # Normalization variants must NOT match — this locks the raw-equality rule.
    check "tests/unit/test_foo.nim/" notin cfg.quarantine
    check "./tests/unit/test_foo.nim" notin cfg.quarantine

when isMainModule:
  echo "B3 config quarantine tests passed."
