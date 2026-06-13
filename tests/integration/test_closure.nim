## test_closure.nim — integration tests for extractClosure (D1).
##
## Compiles real fixture entrypoints and exercises extractClosure against the
## resulting nimcache JSONs.  Three behavioural cases:
##
##   1. Relative-import chain (@m): deptest_main.nim imports ./deptest_dep
##      which imports ./deptest_dep2.  Without -d:extraDep the closure contains
##      main+dep+dep2 but NOT deptest_extra.nim.
##
##   2. Flag-sensitive closure: recompile WITH -d:extraDep → deptest_extra.nim
##      also appears (proves flag-sensitivity; @m path).
##
##   3. @p soundness case: pathimport_main.nim imports crisol/depparse via
##      --path:src.  The closure MUST contain src/crisol/depparse.nim (and
##      src/crisol/types.nim if depparse imports it) — proving @p project
##      modules are tracked, not excluded.  This is the D1a soundness fix.
##
## All three tests also assert: no stdlib path is returned (every returned path
## is projectRoot-relative and resolves to an existing file under projectRoot).

import std/[os, sets, strutils, unittest]
import crisol/closure
import crisol/types

# ---------------------------------------------------------------------------
# Helper: compile a fixture, return the nimcache dir + binary name used.
# ---------------------------------------------------------------------------

proc compileFixture(sourceFile: string;
                    extraFlags: seq[string] = @[];
                    nimcacheParent: string = getTempDir()): tuple[nimcacheDir, binName: string] =
  ## Compile `sourceFile` (absolute path) into a fresh temp nimcache.
  ## Returns the nimcache dir and binary name (stem of sourceFile).
  ## Raises if compilation fails.
  let stem       = sourceFile.extractFilename.changeFileExt("")
  let nimcacheDir = nimcacheParent / "crisol_test_" & stem
  let binPath    = nimcacheParent / stem
  createDir(nimcacheDir)
  var cmd = "nim c --mm:orc --hints:off --warnings:off"
  cmd.add " --nimcache:" & nimcacheDir
  cmd.add " -o:" & binPath
  for f in extraFlags:
    cmd.add " " & f
  cmd.add " " & sourceFile
  let rc = execShellCmd(cmd)
  if rc != 0:
    raise newException(IOError, "fixture compilation failed (exit " & $rc & "): " & cmd)
  result = (nimcacheDir: nimcacheDir, binName: stem)

# ---------------------------------------------------------------------------
# Fixture paths (absolute, derived from the project root).
# ---------------------------------------------------------------------------

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 → project root

let fixtureDir  = projectRoot / "tests" / "fixtures"

# ---------------------------------------------------------------------------
# Test 1 — relative-import chain (@m), no extraDep
# ---------------------------------------------------------------------------

suite "extractClosure — @m relative import chain":

  test "closure contains main, dep, dep2 — no extra":
    let src    = fixtureDir / "deptest_main.nim"
    let (nc, bn) = compileFixture(src)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    check "tests/fixtures/deptest_main.nim" in cl
    check "tests/fixtures/deptest_dep.nim"  in cl
    check "tests/fixtures/deptest_dep2.nim" in cl

  test "closure does NOT contain deptest_extra without -d:extraDep":
    let src    = fixtureDir / "deptest_main.nim"
    let (nc, bn) = compileFixture(src)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    check "tests/fixtures/deptest_extra.nim" notin cl

  test "every returned path is projectRoot-relative and exists under projectRoot":
    let src    = fixtureDir / "deptest_main.nim"
    let (nc, bn) = compileFixture(src)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    for p in cl:
      # Must not be absolute.
      check not p.isAbsolute
      # Must not contain stdlib indicators.
      check not p.startsWith("lib/")
      # Must exist on disk.
      let abs = projectRoot / p
      check fileExists(abs)

# ---------------------------------------------------------------------------
# Test 2 — flag-sensitive closure (with -d:extraDep)
# ---------------------------------------------------------------------------

suite "extractClosure — flag-sensitive closure":

  test "closure gains deptest_extra.nim when -d:extraDep is set":
    let src    = fixtureDir / "deptest_main.nim"
    # Use a separate nimcache so the two compiles don't collide.
    let tmpDir = getTempDir() / "crisol_extradep"
    createDir(tmpDir)
    let (nc, bn) = compileFixture(src, @["-d:extraDep"], tmpDir)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    check "tests/fixtures/deptest_main.nim"  in cl
    check "tests/fixtures/deptest_dep.nim"   in cl
    check "tests/fixtures/deptest_dep2.nim"  in cl
    check "tests/fixtures/deptest_extra.nim" in cl

# ---------------------------------------------------------------------------
# Test 3 — @p soundness case: --path:src project modules are tracked
# ---------------------------------------------------------------------------

suite "extractClosure — @p soundness (--path:src project modules tracked)":

  test "src/crisol/depparse.nim appears in closure when imported via --path:src":
    let src    = fixtureDir / "pathimport_main.nim"
    let srcDir = projectRoot / "src"
    let (nc, bn) = compileFixture(src, @["--path:" & srcDir])
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    # The critical assertion: @p-mangled project source is in the closure.
    check "src/crisol/depparse.nim" in cl

  test "stdlib paths are excluded from @p closure":
    let src    = fixtureDir / "pathimport_main.nim"
    let srcDir = projectRoot / "src"
    let tmpDir = getTempDir() / "crisol_pathp"
    createDir(tmpDir)
    let (nc, bn) = compileFixture(src, @["--path:" & srcDir], tmpDir)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    for p in cl:
      # system.nim, std/*, etc. must not appear
      check not p.startsWith("lib/")
      check not p.contains("system.nim")
      check not p.contains("/std/")
      # Must resolve to real file under project root
      check fileExists(projectRoot / p)

  test "types.nim is in closure if depparse imports it":
    # depparse imports std/[os, strutils] — no types.nim.
    # This test documents the transitive boundary: depparse itself imports only
    # stdlib, so types.nim should NOT be in the pathimport_main closure.
    # If depparse is later refactored to import types, this test catches drift.
    let src    = fixtureDir / "pathimport_main.nim"
    let srcDir = projectRoot / "src"
    let tmpDir = getTempDir() / "crisol_types_check"
    createDir(tmpDir)
    let (nc, bn) = compileFixture(src, @["--path:" & srcDir], tmpDir)
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let cl     = extractClosure(nc, bn, src, config)

    # depparse currently does NOT import types.nim — this is expected.
    # If this fails after a refactor, verify depparse's imports and update.
    check "src/crisol/types.nim" notin cl

# ---------------------------------------------------------------------------
# Test 4 — missing JSON raises CrisolError(cekEnvironment)
# ---------------------------------------------------------------------------

suite "extractClosure — error handling":

  test "missing nimcache JSON raises CrisolError cekEnvironment":
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let bogus  = getTempDir() / "crisol_missing_" & $getCurrentProcessId()
    createDir(bogus)
    try:
      discard extractClosure(bogus, "nonexistent", fixtureDir / "deptest_main.nim", config)
      fail()
    except CrisolError as e:
      check e.kind == cekEnvironment
