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
