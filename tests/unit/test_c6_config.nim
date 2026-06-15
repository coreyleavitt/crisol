## test_c6_config.nim — C6: unit tests for perf-check config parsing
##
## Coverage:
##   1. No perf-check block → disabled (enabled=false, zero values)
##   2. sensitivity "none" → disabled
##   3. sensitivity "moderate" → preset (k=3.0, sampleFloor=10, absFloorMs=5)
##   4. sensitivity "conservative" → preset (k=4.0, sampleFloor=20, absFloorMs=10)
##   5. sensitivity "aggressive" → preset (k=2.0, sampleFloor=5, absFloorMs=2)
##   6. Override k only → preset sampleFloor+absFloorMs preserved
##   7. Override sample-floor only → preset k+absFloorMs preserved
##   8. Override abs-floor-ms only → preset k+sampleFloor preserved
##   9. All three overrides → all apply
##   10. Unknown sensitivity → config error (cekConfig)
##   11. Malformed k (non-numeric) → config error
##   12. k <= 0 → config error
##   13. sample-floor < 1 → config error
##   14. abs-floor-ms < 0 → config error
##   15. Unknown child key in perf-check block → config warning (not error)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_c6_config.nim

import std/[os, strutils, unittest, tempfiles]
import crisol/[types, config]

proc makeTmpDir(): string =
  result = createTempDir("crisol_c6cfg_", "")

proc writeFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc loadKdl(tmp: string; kdl: string): (Config, seq[ConfigWarning]) =
  let path = writeFile(tmp, "crisol.kdl",
    "group \"unit\" { globs \"tests/unit/*.nim\" }\n" & kdl)
  loadConfig(configPath = path)

suite "C6 — perf-check config":

  test "absent perf-check block → disabled":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, "")
    check not cfg.perfCheck.enabled
    check cfg.perfCheck.k == 0.0
    check cfg.perfCheck.sampleFloor == 0
    check cfg.perfCheck.absFloorMs == 0

  test "sensitivity none → disabled":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "none"
}
""")
    check not cfg.perfCheck.enabled

  test "sensitivity moderate → preset":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 3.0
    check cfg.perfCheck.sampleFloor == 10
    check cfg.perfCheck.absFloorMs == 5

  test "sensitivity conservative → stricter preset":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "conservative"
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 4.0
    check cfg.perfCheck.sampleFloor == 20
    check cfg.perfCheck.absFloorMs == 10

  test "sensitivity aggressive → more sensitive preset":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "aggressive"
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 2.0
    check cfg.perfCheck.sampleFloor == 5
    check cfg.perfCheck.absFloorMs == 2

  test "override k only — preset sampleFloor+absFloorMs preserved":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
    k 5.0
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 5.0
    check cfg.perfCheck.sampleFloor == 10  # moderate preset
    check cfg.perfCheck.absFloorMs == 5    # moderate preset

  test "override sample-floor only":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
    sample-floor 15
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 3.0
    check cfg.perfCheck.sampleFloor == 15
    check cfg.perfCheck.absFloorMs == 5

  test "override abs-floor-ms only":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
    abs-floor-ms 20
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 3.0
    check cfg.perfCheck.sampleFloor == 10
    check cfg.perfCheck.absFloorMs == 20

  test "all three overrides apply":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, _) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
    k 2.5
    sample-floor 8
    abs-floor-ms 3
}
""")
    check cfg.perfCheck.enabled
    check cfg.perfCheck.k == 2.5
    check cfg.perfCheck.sampleFloor == 8
    check cfg.perfCheck.absFloorMs == 3

  test "unknown sensitivity → config error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let path = writeFile(tmp, "crisol.kdl", """
group "unit" { globs "tests/unit/*.nim" }
perf-check {
    sensitivity "banana"
}
""")
    try:
      discard loadConfig(configPath = path)
      check false  # should have raised CrisolError
    except CrisolError as e:
      check e.kind == cekConfig
      check "banana" in e.msg

  test "malformed k (string) → config error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let path = writeFile(tmp, "crisol.kdl", """
group "unit" { globs "tests/unit/*.nim" }
perf-check {
    sensitivity "moderate"
    k "not-a-number"
}
""")
    try:
      discard loadConfig(configPath = path)
      check false  # should have raised CrisolError
    except CrisolError as e:
      check e.kind == cekConfig

  test "k <= 0 → config error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let path = writeFile(tmp, "crisol.kdl", """
group "unit" { globs "tests/unit/*.nim" }
perf-check {
    sensitivity "moderate"
    k 0.0
}
""")
    try:
      discard loadConfig(configPath = path)
      check false  # should have raised CrisolError
    except CrisolError as e:
      check e.kind == cekConfig
      check "k" in e.msg

  test "sample-floor < 1 → config error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let path = writeFile(tmp, "crisol.kdl", """
group "unit" { globs "tests/unit/*.nim" }
perf-check {
    sensitivity "moderate"
    sample-floor 0
}
""")
    try:
      discard loadConfig(configPath = path)
      check false  # should have raised CrisolError
    except CrisolError as e:
      check e.kind == cekConfig

  test "abs-floor-ms < 0 → config error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let path = writeFile(tmp, "crisol.kdl", """
group "unit" { globs "tests/unit/*.nim" }
perf-check {
    sensitivity "moderate"
    abs-floor-ms -1
}
""")
    try:
      discard loadConfig(configPath = path)
      check false  # should have raised CrisolError
    except CrisolError as e:
      check e.kind == cekConfig

  test "unknown child key in perf-check → warning, not error":
    let tmp = makeTmpDir(); defer: removeDir(tmp)
    let (cfg, warns) = loadKdl(tmp, """
perf-check {
    sensitivity "moderate"
    unknown-future-key "value"
}
""")
    check cfg.perfCheck.enabled
    check warns.len == 1
    check "unknown-future-key" in warns[0].message

when isMainModule:
  echo "test_c6_config: done"
