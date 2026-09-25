## test_issue16_headers.nim — issue #16 slice 1a: headers a `{.compile.}`d C
## source `#include`s are tracked compile inputs.
##
## Today, `closure.extractClosure` tracks a `{.compile.}`d external's own
## `.c`/`.cpp` source (issue #11, D3c) but nothing it `#include`s: Nim's own
## external-object cache (`extccomp.nim`'s `footprint`/`addExternalFileToCompile`)
## never inspects headers either, so a header-only edit is invisible both to
## crisol's `--changed` selection and to Nim's own cache-freshness check.
##
## This slice (1a) makes crisol's closure — and therefore `--changed`
## selection and `crisol closure --json` — SEE the header: `extractCompileInputs`
## runs `cc -M` on the manifest's own compile command for the external,
## folds the resulting `#include` closure into the entrypoint's tracked
## files, and persists a per-external header set in the depgraph
## (`DepGraphEntry.externals`). Busting Nim's OWN external-object cache so a
## header-only edit actually triggers a real recompile is slice 1b — NOT
## covered here; this slice only proves the header is now TRACKED (visible
## in the closure and drives `--changed` SELECTION).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue16_headers.nim

import std/[json, os, osproc, strutils, times, unittest]
import crisol
import crisol/[types, planner, nimprobe, ccidentity, closure]
import "../support/testep"
import ../support/capture

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue11_externals.nim —
# not imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_issue16_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests")
  createDir(result / "native")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

const ProjectKdl = """
group "unit" {
    globs "tests/test_*.nim"
}
"""

const AddH = """
#ifndef ADD_H
#define ADD_H
#include <stdint.h>
#define ADD_BIAS 42
int32_t cadd(int32_t a, int32_t b);
#endif
"""

const AddHV2 = """
#ifndef ADD_H
#define ADD_H
#include <stdint.h>
#define ADD_BIAS 43
int32_t cadd(int32_t a, int32_t b);
#endif
"""

const MixedH = """
#ifndef ADDMIXED_H
#define ADDMIXED_H
#define ADD_EXTRA 0
#endif
"""
  ## Deliberately MIXED CASE on disk (`native/AddMixed.h`). `cl
  ## /sourceDependencies` lowercases every path it reports, so this header is
  ## the only one in the fixture whose reported spelling differs from its
  ## real one -- `add.h` is already all-lowercase, which is why the original
  ## six tests could not see the tail half of the case defect. Contributes
  ## `ADD_EXTRA 0` so the arithmetic (and T3's 45 -> 46 flip) is unchanged.

const AddC = """
#include "add.h"
#include "AddMixed.h"
int32_t cadd(int32_t a, int32_t b) { return a + b + ADD_BIAS + ADD_EXTRA; }
"""

const CaddProbe = """
{.compile: "../native/add.c".}
proc cadd(a, b: int32): int32 {.importc, cdecl.}
quit(if cadd(1, 2) == 45: 0 else: 1)
"""

proc setupProject(tag: string): tuple[root, epPath: string] =
  let root = newProject(tag)
  writeFile(root / "crisol.kdl", ProjectKdl)
  writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
  writeFile(root / "native" / "add.h", AddH)
  writeFile(root / "native" / "AddMixed.h", MixedH)
  writeFile(root / "native" / "add.c", AddC)
  let epPath = root / "tests" / "test_cadd.nim"
  writeFile(epPath, CaddProbe)

  git(root, "init -q")
  git(root, "config user.email crisol@test.local")
  git(root, "config user.name crisol-test")
  git(root, "config commit.gpgsign false")
  git(root, "add -A")
  git(root, "commit -q -m baseline")
  (root: root, epPath: epPath)

# ---------------------------------------------------------------------------
# CR2 fixture — gcc/clang arm producer for the W1 case-resolution fix.
#
# `MixedH`/`AddMixed.h` above spells its `#include` directive with the SAME
# case as the on-disk file (`#include "AddMixed.h"` against real
# `native/AddMixed.h`), so it only ever exercises cl's *systemic*
# `/sourceDependencies` lowercasing -- under gcc/clang, whose `-M`/`-MM`
# instead echo the `#include` directive's LITERAL spelling verbatim
# (measured, docs/handoff/msvc-selection-layer.md's #23 section), that
# fixture produces no reported-vs-real-case mismatch at all. The only way to
# reproduce one under gcc/clang is a directive that ITSELF differs in case
# from the on-disk file, resolved only because the volume is
# case-insensitive.
# ---------------------------------------------------------------------------

const GccCaseH = """
#ifndef GCCCASE_H
#define GCCCASE_H
#include <stdint.h>
#define GCC_CASE_BIAS 100
#endif
"""

const GccCaseC = """
#include "gcccase.h"
int32_t gccCaseProbe(int32_t a) { return a + GCC_CASE_BIAS; }
"""
  ## The `#include` directive is deliberately ALL-LOWERCASE
  ## (`"gcccase.h"`); the on-disk header is `native/GccCase.h` (mixed
  ## case). On a case-insensitive volume the include still resolves, and
  ## gcc/clang's `-M` reports back the directive's own lowercase spelling
  ## -- the mismatch the `ReportedPath`-typed rescue in `closure.nim`'s
  ## header loop (CR10) exists to catch.

const GccCaseEp = """
{.compile: "../native/gcccase.c".}
proc gccCaseProbe(a: int32): int32 {.importc, cdecl.}
quit(if gccCaseProbe(1) == 101: 0 else: 1)
"""

proc setupGccCaseProject(tag: string): tuple[root, epPath: string] =
  let root = newProject(tag)
  writeFile(root / "crisol.kdl", ProjectKdl)
  writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
  writeFile(root / "native" / "GccCase.h", GccCaseH)   # real on-disk spelling: mixed case
  writeFile(root / "native" / "gcccase.c", GccCaseC)   # #include "gcccase.h" — mismatched case
  let epPath = root / "tests" / "test_gcccase.nim"
  writeFile(epPath, GccCaseEp)

  git(root, "init -q")
  git(root, "config user.email crisol@test.local")
  git(root, "config user.name crisol-test")
  git(root, "config commit.gpgsign false")
  git(root, "add -A")
  git(root, "commit -q -m baseline")
  (root: root, epPath: epPath)

proc gccCaseVolumeIsInsensitive(): bool =
  ## Same technique as test_rfc9_a3bii_fold_selection.nim's Mode-3 probe /
  ## test_rfc9_a4b_determinism.nim's `isCaseInsensitiveVolume`: write a
  ## lowercase temp file, then check whether its uppercase spelling also
  ## resolves.
  let dir = getTempDir() / ("crisol_issue16_gcccase_volprobe_" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let lowerPath = dir / "volprobe.tmp"
  let upperPath = dir / "VOLPROBE.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)

# ---------------------------------------------------------------------------
# Test 1 — a {.compile.}d external's #include'd header is a tracked closure
# member, and every closure path stays root-relative (no absolute path, no
# path escaping the project root via "..").
# ---------------------------------------------------------------------------

suite "issue #16 slice 1a — a {.compile.}d source's #include'd header is tracked":

  test "native/add.h appears in the closure after a full run; every closure path is root-relative":
    let (root, epPath) = setupProject("cadd")
    defer: removeDir(root)

    var fullCode = 0
    discard captureStdout(proc() = fullCode = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check fullCode == 0

    var clCode = 0
    let clOutput = captureStdout(proc() = clCode = runMain(@["closure", "--json", "--config", root / "crisol.kdl", epPath]))
    check clCode == 0
    let clJson = parseJson(clOutput.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr

    check "native/add.h" in closureSet
    for p in closureSet:
      check not p.isAbsolute
      check not p.startsWith("..")
    check "stdint.h" notin closureSet   # system header excluded

  test "W1: a mixed-case header keeps its REAL case when the root spelling already case-matches the probe":
    ## The wiring-audit W1 vector. `classify`'s F18 expansion only ever ran
    ## as a FALLBACK on a `matchRoots` MISS, and `matchRoots` misses only on
    ## a case difference inside the ROOT PREFIX (`underRoot` is a
    ## case-sensitive prefix test that slices the tail VERBATIM into
    ## `TrackedPath.rel`). So when the root spelling already case-matches
    ## what the probe reports, the direct match wins, the expansion never
    ## runs, and the tail is stored exactly as the C compiler spelled it.
    ##
    ## `windows-latest` runs in `D:\a\crisol\crisol` -- all lowercase -- and
    ## hits this on every run. The MSVC container MASKS it: its
    ## `getTempDir()` is `C:\Users\ContainerAdministrator\...`, mixed case,
    ## so the prefix mismatches, the fallback fires, and `winRealPath`
    ## happens to fix the tail as a side effect. Spelling the config path in
    ## lowercase reproduces the CI shape on any host -- the SAME directory,
    ## just a root `abs` that case-matches `/sourceDependencies` output.
    ##
    ## This matters because `rel` IS the cache-key material (paths.nim's
    ## `keyBytes` doc, `keyBytes == rel`, UNFOLDED). A lowercased `rel` gives a cl-populated
    ## closure a different `headersHash` from a gcc-populated one for
    ## byte-identical files -- and because `==`/`hash` fold (paths.nim's
    ## `TrackedPath` `==`/`hash`),
    ## that divergence NEVER surfaces as a failed comparison, only as a
    ## permanent cross-toolchain cache miss.
    let (root, _) = setupProject("w1case")
    defer: removeDir(root)

    let lowerCfg = (root / "crisol.kdl").toLowerAscii
    let lowerEp  = (root / "tests" / "test_cadd.nim").toLowerAscii

    var fullCode = 0
    discard captureStdout(proc() = fullCode = runMain(
      @["run", "--config", lowerCfg, "--json"]))
    check fullCode == 0

    var clCode = 0
    let clOutput = captureStdout(proc() = clCode = runMain(
      @["closure", "--json", "--config", lowerCfg, lowerEp]))
    check clCode == 0
    let clJson = parseJson(clOutput.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr

    check "native/AddMixed.h" in closureSet
    check "native/addmixed.h" notin closureSet

  test "editing only the header selects the includer under --changed --dry-run":
    let (root, epPath) = setupProject("cadd_sel")
    defer: removeDir(root)

    var fullCode = 0
    discard captureStdout(proc() = fullCode = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check fullCode == 0

    # Edit ONLY the header (not add.c, not the entrypoint itself). Left
    # UNCOMMITTED, deliberately — `--changed`'s default baseRef is
    # `git diff HEAD` (working tree vs the last commit, staged + unstaged;
    # see gitdiff.changedFiles's doc comment): committing here would make
    # the working tree equal HEAD again, producing an empty diff and
    # silently vacuous-passing (or, correctly, failing) this test regardless
    # of whether the header is tracked. Mirrors
    # tests/integration/test_issue11_externals.nim's proven pattern (edit,
    # then check --changed --dry-run against the uncommitted change).
    writeFile(root / "native" / "add.h", AddHV2)

    var planCode = 0
    let planOutput = captureStdout(proc() = planCode = runMain(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"]))
    check planCode == 0
    let planJson = parseJson(planOutput.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/test_cadd.nim")

# ---------------------------------------------------------------------------
# Slice 1b (issue #16 part 2) — busting Nim's own external-object cache so a
# header-only edit reaches the compiled test binary, not merely the tracked
# closure. Slice 1a (above) only proved the header is SEEN (tracked in the
# closure, drives --changed selection); it deliberately did not prove the
# edit is ACTED on by the compiler, because Nim's own external-object cache
# (extccomp.nim's footprint/addExternalFileToCompile) never inspects headers
# either, and can therefore serve a stale object from the persistent
# nimcache even after crisol correctly decides to recompile.
# ---------------------------------------------------------------------------

suite "issue #16 slice 1b — a header-only edit reaches the test binary":

  test "T3: a header-only edit flips the probe's outcome on the next full run":
    let (root, epPath) = setupProject("t3")
    defer: removeDir(root)

    var full1Code = 0
    let full1Output = captureStdout(proc() = full1Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check full1Code == 0
    let full1Json = parseJson(full1Output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # Header-only edit: bias 42 -> 43, so cadd(1, 2) == 1 + 2 + 43 == 46, but
    # the probe still checks == 45 and now exits 1. Neither add.c nor the
    # entrypoint itself is touched — only native/add.h.
    writeFile(root / "native" / "add.h", AddHV2)

    var full2Code = 0
    let full2Output = captureStdout(proc() = full2Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    let full2Json = parseJson(full2Output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full2Code != 0

  test "T4: a header-only edit is busted even with a warm nimcache and no depgraph record":
    let (root, epPath) = setupProject("t4")
    defer: removeDir(root)

    var full1Code = 0
    let full1Output = captureStdout(proc() = full1Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check full1Code == 0
    let full1Json = parseJson(full1Output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # Lose the depgraph record entirely (simulates a format-version discard,
    # a `crisol clean` GC, or an entry invalidated by a prior failed
    # recordClosure) while leaving the WARM persistent nimcache directory
    # untouched on disk — the "no entry, but cacheDir already had content"
    # case bustStaleExternalObjects rule 2 exists for.
    removeFile(root / ".crisol" / "depgraph")

    writeFile(root / "native" / "add.h", AddHV2)

    var full2Code = 0
    let full2Output = captureStdout(proc() = full2Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    let full2Json = parseJson(full2Output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full2Code != 0

    # The depgraph record is rebuilt by this run; closure --json must still
    # list the header (rule 2's cold-every-foreign-object recovery lets
    # extractCompileInputs's cc -M rediscovery run fresh instead of failing
    # closed for want of a carried-forward header record).
    var clCode = 0
    let clOutput = captureStdout(proc() = clCode = runMain(@["closure", "--json", "--config", root / "crisol.kdl", epPath]))
    check clCode == 0
    let clJson = parseJson(clOutput.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "native/add.h" in closureSet

  test "T5: an unchanged second run neither recompiles nor busts the external's object":
    let (root, epPath) = setupProject("t5")
    defer: removeDir(root)

    var full1Code = 0
    let full1Output = captureStdout(proc() = full1Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check full1Code == 0
    let full1Json = parseJson(full1Output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # No edits at all. The plan for a second run must show the entrypoint's
    # binary as fresh (no compile needed) — the compile-decision is the
    # load-bearing signal here, not merely a repeated "passed" outcome (a
    # wastefully-busted-then-recompiled binary would also pass, since the
    # source hasn't changed).
    var plan2Code = 0
    let plan2Output = captureStdout(proc() = plan2Code = runMain(@["run", "--config", root / "crisol.kdl",
                                "--dry-run", "--json"]))
    check plan2Code == 0
    let plan2Json = parseJson(plan2Output.strip())
    check plan2Json["entrypoints"].len == 1
    let epNode = plan2Json["entrypoints"][0]
    check epNode["path"].getStr == "tests/test_cadd.nim"
    check epNode["decision"].getStr in ["skipFresh", "cached"]

    # The external's object must still be present in the persistent
    # nimcache — busting is SELECTIVE (staleExternalObjects found nothing
    # stale), never wholesale, when nothing actually changed.
    var flags: seq[string]
    for f in epNode["flags"]: flags.add f.getStr
    let ep = testEp(epNode["path"].getStr, group = epNode["group"].getStr, flags = flags)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    let toolchainFp = toolchainFingerprint(cachedNimFingerprint(), cachedCcVersion())
    let cacheDir = cachePath(ep, cfg, toolchainFp)
    check dirExists(cacheDir)
    var foundExternalObj = false
    for kind, path in walkDir(cacheDir):
      if kind != pcFile: continue
      let base = path.extractFilename
      # `hasObjectExt`, not `endsWith(".o")`: cl/vccexe emit `.obj`, so a
      # hardcoded `.o` made this scan find nothing at all under MSVC and
      # fail for a reason that had nothing to do with what T5 asserts
      # (issue #21 slice 1a).
      if hasObjectExt(base) and not isModuleObjectName(base):
        foundExternalObj = true
    check foundExternalObj

  test "T6: a carried-forward header record still busts correctly after a warm module-only recompile":
    let (root, epPath) = setupProject("t6")
    defer: removeDir(root)

    var full1Code = 0
    let full1Output = captureStdout(proc() = full1Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check full1Code == 0
    let full1Json = parseJson(full1Output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # Edit ONLY the Nim entrypoint (append a comment) — NOT add.c, NOT
    # add.h. decideCompile's closure-content-hash rule recompiles on ANY
    # closure member's content changing (the entrypoint itself is always a
    # closure member), so a plain "run" (no --changed needed) triggers a
    # warm recompile here. That recompile regenerates test_cadd's own C
    # file, but add.c's OWN object is unchanged — Nim marks it Cached and
    # its entry is ABSENT from the warm manifest's `compile` array — so
    # extractCompileInputs must carry the external's header record FORWARD
    # from the previous recordClosure instead of re-deriving it.
    writeFile(epPath, CaddProbe & "# warm-recompile trigger\n")

    var full2Code = 0
    let full2Output = captureStdout(proc() = full2Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    check full2Code == 0
    let full2Json = parseJson(full2Output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr == "passed"

    var clCode = 0
    let clOutput = captureStdout(proc() = clCode = runMain(@["closure", "--json", "--config", root / "crisol.kdl", epPath]))
    check clCode == 0
    let clJson = parseJson(clOutput.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "native/add.h" in closureSet

    # Now edit the header — the carried-forward record must still let
    # bustStaleExternalObjects detect the change correctly on this THIRD run.
    writeFile(root / "native" / "add.h", AddHV2)

    var full3Code = 0
    let full3Output = captureStdout(proc() = full3Code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
    let full3Json = parseJson(full3Output.strip())
    check full3Json["entrypoints"].len == 1
    check full3Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full3Code != 0

# ---------------------------------------------------------------------------
# CR2 — end-to-end producer for the gcc/clang arm of the W1 case-resolution
# fix (code-review 2026-09-21). Pinned as a per-file step on the macOS leg
# in ci.yml, the same way #21/#22/#23's tests are pinned on windows: this
# file lives under tests/integration/, which the macOS leg's bulk sweep
# (CRISOL_TEST_DIRS: tests/unit:tests/conformance) does not cover.
#
# Self-probing, not env-gated (mirrors test_rfc9_a3bii_fold_selection.nim's
# belt-and-suspenders Mode 3): runs the real body on any volume that
# genuinely answers case-insensitive (macOS/APFS on the pinned CI step;
# windows/NTFS too, since this whole file already runs there), self-skips
# on a case-sensitive one (this dev container's ext4, and the Linux `test`
# job, which sweeps tests/integration/ unconditionally and would otherwise
# fail outright — the mismatched #include cannot even resolve there).
# ---------------------------------------------------------------------------

suite "issue #16 CR2 — gcc/clang arm producer for the W1 case-resolution fix":

  test "a gcc/clang-reported #include spelling that mis-cases the on-disk header still resolves to real case":
    if not gccCaseVolumeIsInsensitive():
      echo "CR2 gcc/clang case-mismatch producer SKIPPED: case-sensitive volume — nothing to prove here"
      # RFC-0009 S5 wiring-audit convention: per-test skip() (this file's
      # other suites keep running for real) must emit CRISOL-SKIP-TEST, not
      # vanish silently -- see ci/assert-subset-honesty.sh's
      # EXPECTED_SKIP_TEST manifest.
      echo "CRISOL-SKIP-TEST: tests/integration/test_issue16_headers.nim#gcc_clang_case_mismatch_producer"
      skip()
    else:
      let (root, epPath) = setupGccCaseProject("gcccase")
      defer: removeDir(root)

      var fullCode = 0
      discard captureStdout(proc() = fullCode = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
      check fullCode == 0

      var clCode = 0
      let clOutput = captureStdout(proc() = clCode = runMain(@["closure", "--json", "--config", root / "crisol.kdl", epPath]))
      check clCode == 0
      let clJson = parseJson(clOutput.strip())
      check clJson["entries"].len == 1
      var closureSet: seq[string]
      for c in clJson["entries"][0]["closure"]:
        closureSet.add c.getStr

      # The ReportedPath-typed rescue must resolve the mismatched-case
      # candidate to the real on-disk spelling -- never store the compiler's
      # literal (lowercase) report, and never silently drop the header
      # instead.
      check "native/GccCase.h" in closureSet
      check "native/gcccase.h" notin closureSet
