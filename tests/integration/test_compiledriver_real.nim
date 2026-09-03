## test_compiledriver_real.nim — RFC-0006 M-driver: ONE real live-compile
## integration test.
##
## Everything else in test_compiledriver.nim (unit) exercises the driver with
## synthetic seams / cheap shell commands. This is the single deliberately-
## budgeted exception (mirrors ccprobe/closure precedent): drive the REAL
## `newMeasureDriver()` — real `nim c --compileOnly`, real `cc`, real linker —
## against `tests/fixtures/pass_always.nim` (`quit(0)`, the smallest/fastest
## fixture in the suite) and prove the three phases actually ran, in order,
## producing real on-disk artifacts, with positive overlap-aware spans.
##
## (The COMMITTED golden real-.c fixture for normalization/r_time testing is
## a SEPARATE, later slice — M-golden-fixture. This test does not build that;
## it only proves the driver mechanism works end-to-end.)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_compiledriver_real.nim

import std/[os, osproc, tables, unittest]
import crisol/compiledriver

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root
let fixture = projectRoot / "tests" / "fixtures" / "pass_always.nim"

suite "runMeasured — real live compile (pass_always fixture)":

  test "compileOnly -> cc -> link all run for real, in order, with positive spans":
    let workDir       = getTempDir() / "crisol_test_compiledriver_real_" & $getCurrentProcessId()
    let nimcacheDir    = workDir / "nimcache"
    let outputBinPath  = workDir / "pass_always"
    createDir(nimcacheDir)

    let driver = newMeasureDriver()
    let spans = runMeasured(driver, fixture, @[], nimcacheDir, outputBinPath)

    check spans.ok
    check spans.errorMsg == ""

    # Spans are positive: all three phases genuinely ran and took real time.
    check spans.codegenSpanUs > 0
    check spans.ccSpanUs > 0
    check spans.linkSpanUs > 0
    check spans.ccUnitTimesUs.len > 0

    # Ordering, proved by artifacts rather than raw timestamps: the manifest
    # only exists because compileOnly ran; the .o files only exist because
    # the cc phase read that manifest and ran; the binary only exists AND
    # runs because link ran last, against those .o files.
    let manifestPath = nimcacheDir / "pass_always.json"
    check fileExists(manifestPath)

    var sawObjectFile = false
    for f in walkFiles(nimcacheDir / "*.o"):
      sawObjectFile = true
      break
    check sawObjectFile

    check fileExists(outputBinPath)
    let (_, exitCode) = execCmdEx(outputBinPath)
    check exitCode == 0   # pass_always.nim is literally `quit(0)`

    removeDir(workDir)

# ---------------------------------------------------------------------------
# rfc-0007 A2c (issue #17): newMeasureDriver's `workingDir` — the SECOND
# compile substrate (raw osproc.startProcess, not a Supervisor ChildSpec)
# that must independently resolve a root-relative compile flag against
# projectRoot, regardless of the calling process's own cwd.
# ---------------------------------------------------------------------------

proc freshA2cRoot(tag: string): string =
  result = getTempDir() / "crisol_test_compiledriver_real_a2c_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc writeA2cFixture(root: string) =
  ## src/helper.nim, importable ONLY via a root-relative `--path:src`.
  createDir(root / "src")
  createDir(root / "tests")
  writeFile(root / "src" / "helper.nim", "proc helperValue*(): int = 42\n")
  writeFile(root / "tests" / "t.nim", """
import helper
doAssert helperValue() == 42
""")

suite "newMeasureDriver — workingDir resolves a root-relative --path:src flag (rfc-0007 A2c, issue #17)":

  test "[RED-pin] workingDir=\"\" (pre-A2c default) fails to compile from an unrelated cwd":
    ## Sanity-pins the bug this slice fixes: absent an explicit workingDir,
    ## `nim --compileOnly` inherits the CALLING process's cwd, so a
    ## root-relative `--path:src` cannot find `src/helper.nim`.
    let root = freshA2cRoot("red")
    defer: removeDir(root)
    let elsewhere = freshA2cRoot("red_elsewhere")
    defer: removeDir(elsewhere)
    writeA2cFixture(root)

    let workDir      = getTempDir() / "crisol_test_compiledriver_real_a2c_red_out_" & $getCurrentProcessId()
    let nimcacheDir   = workDir / "nimcache"
    let outputBinPath = workDir / "t"
    createDir(nimcacheDir)
    defer: removeDir(workDir)

    let savedCwd = getCurrentDir()
    setCurrentDir(elsewhere)
    defer: setCurrentDir(savedCwd)

    let driver = newMeasureDriver()   # workingDir defaults to "" — inherits elsewhere
    let spans = runMeasured(driver, root / "tests" / "t.nim", @["--path:src"],
                            nimcacheDir, outputBinPath)
    check not spans.ok

  test "workingDir=projectRoot compiles successfully from an unrelated cwd":
    let root = freshA2cRoot("green")
    defer: removeDir(root)
    let elsewhere = freshA2cRoot("green_elsewhere")
    defer: removeDir(elsewhere)
    writeA2cFixture(root)

    let workDir      = getTempDir() / "crisol_test_compiledriver_real_a2c_green_out_" & $getCurrentProcessId()
    let nimcacheDir   = workDir / "nimcache"
    let outputBinPath = workDir / "t"
    createDir(nimcacheDir)
    defer: removeDir(workDir)

    let savedCwd = getCurrentDir()
    setCurrentDir(elsewhere)
    defer: setCurrentDir(savedCwd)

    let driver = newMeasureDriver(workingDir = root)
    let spans = runMeasured(driver, root / "tests" / "t.nim", @["--path:src"],
                            nimcacheDir, outputBinPath)
    check spans.ok
    check spans.errorMsg == ""
    check fileExists(outputBinPath)

when isMainModule:
  echo "All compiledriver real-compile tests passed."
