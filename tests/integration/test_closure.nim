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
  # issue #11: extractClosure now requires the manifest's `depfiles` array
  # (only written under -d:nimBetterRun) — matches what crisol's own
  # compile paths inject (compiledriver.nimCompileArgs).
  cmd.add " -d:nimBetterRun"
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
# Test 1b — issue #5 acceptance: cold closure == warm-recompile closure
# ---------------------------------------------------------------------------

suite "extractClosure — warm recompile yields the same closure as cold (issue #5)":

  test "cold == warm, and the warm manifest really had an empty compile array":
    let src    = fixtureDir / "deptest_main.nim"
    let config = Config(projectRoot: projectRoot, depRoots: @[])
    let parent = getTempDir() / "crisol_closure_coldwarm_" & $getCurrentProcessId()
    removeDir(parent)
    createDir(parent)
    defer: removeDir(parent)

    # Cold: fresh nimcache → every module is in `compile`.
    let (nc, bn) = compileFixture(src, nimcacheParent = parent)
    let cold = extractClosure(nc, bn, src, config)
    check cold.len >= 3                              # main + dep + dep2
    check parseCompileManifest(nc / bn & ".json").compile.len > 0

    # Delete the `-o:` binary before the warm recompile, mirroring crisol's
    # own runner (which always removes the per-slot scratch bin dir after
    # copying the produced binary out). With -d:nimBetterRun now on every
    # compile (issue #11), leaving a stale-but-still-present `-o:` binary in
    # place would let the compiler's own "nothing changed at all, skip the
    # whole compile" short-circuit fire (changeDetectedViaJsonBuildInstructions
    # requires the output binary to exist) — which would leave the manifest
    # UNTOUCHED from the cold compile (still full) rather than exercising
    # the warm-recompile path this test is about. See
    # compiledriver.nimCompileArgs's doc comment for the same reasoning.
    removeFile(parent / bn)

    # Warm: SAME nimcache, source unchanged → Nim marks every module Cached
    # and emits an EMPTY `compile` array (the issue #5 trigger); `link` is
    # still complete. The closure must not shrink.
    discard compileFixture(src, nimcacheParent = parent)
    let warmManifest = parseCompileManifest(nc / bn & ".json")
    check warmManifest.compile.len == 0
    check warmManifest.link.len > 0
    let warm = extractClosure(nc, bn, src, config)
    check warm == cold

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
# Test 5 — R1 regression: a real {.compile.}d C external must not become a
# phantom closure entry.
# ---------------------------------------------------------------------------

suite "extractClosure — real {.compile.}d external (R1 regression, issue #5 fix)":

  test "ep_a's closure has no phantom entry for fixture.c; every path exists on disk":
    ## Real evidence: tests/fixtures/golden_reuse/generated/ep_a/ep_a.json's
    ## `link` array contains `.../@mfixture.c.o` (from `fixture_ffi.nim`'s
    ## `{.compile: "fixture.c".}`).  A `.c.o`-only filter accepts it and
    ## resolveMangledAll decodes it into the phantom path
    ## `<epDir>/fixture` (no `.nim` extension) — under projectRoot, so it
    ## survives the tracked-root filter and lands in the closure even though
    ## no such file exists on disk.
    let src        = fixtureDir / "golden_reuse" / "ep_a.nim"
    let includeDir = fixtureDir / "golden_reuse" / "include"
    let (nc, bn)   = compileFixture(src, @["--passC:-I" & includeDir])
    let config     = Config(projectRoot: projectRoot, depRoots: @[])
    let cl         = extractClosure(nc, bn, src, config)

    check "tests/fixtures/golden_reuse/ep_a.nim" in cl
    check "tests/fixtures/golden_reuse/fixture_substrate.nim" in cl

    for p in cl:
      check fileExists(projectRoot / p)

# ---------------------------------------------------------------------------
# Test 6 — missing JSON raises CrisolError(cekEnvironment)
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
