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
import std/posix as posix_mod
import crisol
import crisol/[types, planner, nimprobe, ccprobe, closure]

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue11_externals.nim —
# not imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_issue16_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_issue16_" & tag & "_" & $getpid())
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

const AddC = """
#include "add.h"
int32_t cadd(int32_t a, int32_t b) { return a + b + ADD_BIAS; }
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
# Test 1 — a {.compile.}d external's #include'd header is a tracked closure
# member, and every closure path stays root-relative (no absolute path, no
# path escaping the project root via "..").
# ---------------------------------------------------------------------------

suite "issue #16 slice 1a — a {.compile.}d source's #include'd header is tracked":

  test "native/add.h appears in the closure after a full run; every closure path is root-relative":
    let (root, epPath) = setupProject("cadd")
    defer: removeDir(root)

    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0

    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr

    check "native/add.h" in closureSet
    for p in closureSet:
      check not p.isAbsolute
      check not p.startsWith("..")
    check "stdint.h" notin closureSet   # system header excluded

  test "editing only the header selects the includer under --changed --dry-run":
    let (root, epPath) = setupProject("cadd_sel")
    defer: removeDir(root)

    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0

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

    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
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

    let full1 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full1.code == 0
    let full1Json = parseJson(full1.output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # Header-only edit: bias 42 -> 43, so cadd(1, 2) == 1 + 2 + 43 == 46, but
    # the probe still checks == 45 and now exits 1. Neither add.c nor the
    # entrypoint itself is touched — only native/add.h.
    writeFile(root / "native" / "add.h", AddHV2)

    let full2 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    let full2Json = parseJson(full2.output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full2.code != 0

  test "T4: a header-only edit is busted even with a warm nimcache and no depgraph record":
    let (root, epPath) = setupProject("t4")
    defer: removeDir(root)

    let full1 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full1.code == 0
    let full1Json = parseJson(full1.output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # Lose the depgraph record entirely (simulates a format-version discard,
    # a `crisol clean` GC, or an entry invalidated by a prior failed
    # recordClosure) while leaving the WARM persistent nimcache directory
    # untouched on disk — the "no entry, but cacheDir already had content"
    # case bustStaleExternalObjects rule 2 exists for.
    removeFile(root / ".crisol" / "depgraph")

    writeFile(root / "native" / "add.h", AddHV2)

    let full2 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    let full2Json = parseJson(full2.output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full2.code != 0

    # The depgraph record is rebuilt by this run; closure --json must still
    # list the header (rule 2's cold-every-foreign-object recovery lets
    # extractCompileInputs's cc -M rediscovery run fresh instead of failing
    # closed for want of a carried-forward header record).
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "native/add.h" in closureSet

  test "T5: an unchanged second run neither recompiles nor busts the external's object":
    let (root, epPath) = setupProject("t5")
    defer: removeDir(root)

    let full1 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full1.code == 0
    let full1Json = parseJson(full1.output.strip())
    check full1Json["entrypoints"].len == 1
    check full1Json["entrypoints"][0]["outcome"].getStr == "passed"

    # No edits at all. The plan for a second run must show the entrypoint's
    # binary as fresh (no compile needed) — the compile-decision is the
    # load-bearing signal here, not merely a repeated "passed" outcome (a
    # wastefully-busted-then-recompiled binary would also pass, since the
    # source hasn't changed).
    let plan2 = captureStdout(@["run", "--config", root / "crisol.kdl",
                                "--dry-run", "--json"])
    check plan2.code == 0
    let plan2Json = parseJson(plan2.output.strip())
    check plan2Json["entrypoints"].len == 1
    let epNode = plan2Json["entrypoints"][0]
    check epNode["path"].getStr == "tests/test_cadd.nim"
    check epNode["decision"].getStr in ["skipFresh", "cached"]

    # The external's object must still be present in the persistent
    # nimcache — busting is SELECTIVE (staleExternalObjects found nothing
    # stale), never wholesale, when nothing actually changed.
    var flags: seq[string]
    for f in epNode["flags"]: flags.add f.getStr
    let ep = Entrypoint(path: epNode["path"].getStr, group: epNode["group"].getStr,
                        flags: flags)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    let toolchainFp = toolchainFingerprint(cachedNimFingerprint(), cachedCcVersion())
    let cacheDir = cachePath(ep, cfg, toolchainFp)
    check dirExists(cacheDir)
    var foundExternalObj = false
    for kind, path in walkDir(cacheDir):
      if kind != pcFile: continue
      let base = path.extractFilename
      if base.endsWith(".o") and not isModuleObjectName(base):
        foundExternalObj = true
    check foundExternalObj

  test "T6: a carried-forward header record still busts correctly after a warm module-only recompile":
    let (root, epPath) = setupProject("t6")
    defer: removeDir(root)

    let full1 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full1.code == 0
    let full1Json = parseJson(full1.output.strip())
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

    let full2 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full2.code == 0
    let full2Json = parseJson(full2.output.strip())
    check full2Json["entrypoints"].len == 1
    check full2Json["entrypoints"][0]["outcome"].getStr == "passed"

    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "native/add.h" in closureSet

    # Now edit the header — the carried-forward record must still let
    # bustStaleExternalObjects detect the change correctly on this THIRD run.
    writeFile(root / "native" / "add.h", AddHV2)

    let full3 = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    let full3Json = parseJson(full3.output.strip())
    check full3Json["entrypoints"].len == 1
    check full3Json["entrypoints"][0]["outcome"].getStr != "passed"
    check full3.code != 0
