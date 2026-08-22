## test_issue11_externals.nim — issue #11: `{.compile.}`d C sources are
## tracked compile inputs.
##
## `closure.extractClosure` derives the source closure from two nimcache-
## manifest arrays: `link` (module objects, `@m`/`@p`/`@n`-decoded) and
## `depfiles` (every file the compiler opened — modules, `include`s,
## `staticRead`/`slurp` targets, config files). Neither one, until now,
## covered a `{.compile: "x.c".}`d external source: it has no module of its
## own (so `depfiles`, which only records files `fileInfos` names, never
## sees it), and `link`'s object-file entry for it was deliberately excluded
## by `moduleMangledNameOf`'s `.nim.{c,cpp,m}.o` module-object filter (the R1
## fix in tests/unit/test_closure_warm.nim, which predates this contract).
##
## Fix (D3c): a `link` entry that ISN'T a module object (`moduleMangledNameOf`
## returns "") but whose basename IS `@m`/`@p`/`@n`-mangled in single-path
## form decodes via the SAME `resolveMangledAll` used for modules — stripping
## only the trailing `.o` (not a `.nim` component, since an external has
## none) leaves `<@m|@p|@n><mangled-source-path>`, e.g. `@mnative@sadd.c` for
## `native/add.c`. `SourceIndex`/`walkForIndex` (D4) now index every regular
## file under a tracked root, not just `.nim` files, so an `@p`-mangled C
## source resolves the same way an `@p`-mangled Nim module already did
## (issue #8).
##
## This test proves the fix end to end through the real CLI entry point
## (runMain), for both the `@m` form (slice 3, C file next to the
## entrypoint) and the `@p` form (slice 4, C file under a `--path:src`
## root), plus warm-recompile retention (slice 5: `link` stays complete even
## when `compile` is empty, so the external stays in the closure across a
## warm recompile that doesn't touch it).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue11_externals.nim

import std/[json, os, osproc, strutils, times, unittest]
import std/posix as posix_mod
import crisol

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue11_closure_inputs.nim
# — not imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_issue11ext_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_issue11ext_" & tag & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit" / "native")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

# ---------------------------------------------------------------------------
# Slice 3 — @m form: C file next to the entrypoint, {.compile: "native/add.c".}
# ---------------------------------------------------------------------------

const ProjectKdlSimple = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const AddCV1 = "int cadd(int a, int b) { return a + b; }\n"
const AddCV2 = "int cadd(int a, int b) { return a + b + 10; }\n"

const CaddProbe = """
import std/os
{.compile: "native/add.c".}
proc cadd(a, b: cint): cint {.importc, cdecl.}
writeFile(currentSourcePath().parentDir / "cadd.marker", $cadd(1, 1))
quit(0)
"""

suite "issue #11 — {.compile.}d C source is a tracked compile input (@m form)":

  test "editing a {.compile.}d C file selects, recompiles, and closure-tracks the includer":
    let root = newProject("cadd")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdlSimple)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    writeFile(root / "tests" / "unit" / "native" / "add.c", AddCV1)
    let epPath = root / "tests" / "unit" / "test_cadd.nim"
    writeFile(epPath, CaddProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_cadd, which writes cadd.marker == "2"
    # (cadd(1, 1) == 1 + 1).
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "cadd.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "2"

    # Edit the {.compile.}d C file (not the Nim entrypoint itself).
    writeFile(root / "tests" / "unit" / "native" / "add.c", AddCV2)

    # --changed --dry-run must select test_cadd.nim: its closure must
    # contain native/add.c for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_cadd.nim")

    # --changed (real run) must actually RECOMPILE test_cadd.nim: a stale
    # binary would rewrite marker with the OLD sum (2), not the new one (12).
    let changed = captureStdout(@["run", "--config", root / "crisol.kdl",
                                  "--changed", "--json"])
    check changed.code == 0
    let changedJson = parseJson(changed.output.strip())
    check changedJson["entrypoints"].len == 1
    check changedJson["entrypoints"][0]["outcome"].getStr == "passed"
    check readFile(markerPath).strip == "12"

    # `closure --json <path>` must list the {.compile.}d C file as a tracked
    # compile input of test_cadd.nim.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "tests/unit/native/add.c" in closureSet

# ---------------------------------------------------------------------------
# Slice 4 — @p form: C file under a --path:src root,
# {.compile: "../../src/native/mul.c".}
# ---------------------------------------------------------------------------

const MulCV1 = "int cmul(int a, int b) { return a * b; }\n"
const MulCV2 = "int cmul(int a, int b) { return a * b + 100; }\n"

const CmulProbe = """
import std/os
{.compile: "../../src/native/mul.c".}
proc cmul(a, b: cint): cint {.importc, cdecl.}
writeFile(currentSourcePath().parentDir / "cmul.marker", $cmul(3, 4))
quit(0)
"""

suite "issue #11 — {.compile.}d C source is a tracked compile input (@p form)":

  test "editing a {.compile.}d C file reached via --path:src selects, recompiles, and closure-tracks the includer":
    let root = newProject("cmul")
    defer: removeDir(root)
    createDir(root / "src" / "native")
    # Pathimport pragma paths are relative to the including file, but the
    # search-path mangling wants the SHORTER of the entrypoint-relative
    # (@m) and search-path-relative (@p) bodies — an absolute --path:src
    # root (test_closure.nim uses the same form: a relative --path does not
    # resolve from the project root, since crisol spawns `nim` without
    # setting its working directory to projectRoot) makes @p win here.
    let projectKdl = "group \"unit\" {\n" &
                      "    globs \"tests/unit/test_*.nim\"\n" &
                      "    flags \"--path:" & (root / "src") & "\"\n" &
                      "}\n"
    writeFile(root / "crisol.kdl", projectKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    writeFile(root / "src" / "native" / "mul.c", MulCV1)
    let epPath = root / "tests" / "unit" / "test_cmul.nim"
    writeFile(epPath, CmulProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_cmul, which writes cmul.marker == "12"
    # (cmul(3, 4) == 3 * 4).
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "cmul.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "12"

    # Edit the {.compile.}d C file (not the Nim entrypoint itself).
    writeFile(root / "src" / "native" / "mul.c", MulCV2)

    # --changed --dry-run must select test_cmul.nim: its closure must
    # contain src/native/mul.c for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_cmul.nim")

    # `closure --json <path>` must list src/native/mul.c as a tracked
    # compile input of test_cmul.nim.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "src/native/mul.c" in closureSet

# ---------------------------------------------------------------------------
# Slice 5 — warm-recompile retention: the external stays in the closure even
# after a warm recompile whose `compile` array omits its now-cached object.
# ---------------------------------------------------------------------------

suite "issue #11 — {.compile.}d C source survives a warm recompile (@m form)":

  test "closure still tracks add.c after a warm recompile that doesn't touch it":
    let root = newProject("cadd_warm")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdlSimple)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    writeFile(root / "tests" / "unit" / "native" / "add.c", AddCV1)
    let epPath = root / "tests" / "unit" / "test_cadd.nim"
    writeFile(epPath, CaddProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run (cold nimcache): compiles + runs test_cadd, marker == "2".
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "cadd.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "2"

    # Edit the Nim entrypoint itself (append a comment line) — NOT add.c.
    # The warm recompile this triggers regenerates test_cadd's own C file,
    # but add.c's OWN object is unchanged, so Nim marks it Cached and its
    # entry is ABSENT from the warm manifest's `compile` array; `link` still
    # names its object (complete on every compile, issue #5).
    writeFile(epPath, CaddProbe & "# warm-recompile trigger\n")
    let warm = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--json"])
    check warm.code == 0
    let warmJson = parseJson(warm.output.strip())
    check warmJson["entrypoints"].len == 1
    check warmJson["entrypoints"][0]["outcome"].getStr == "passed"

    # NOW edit add.c. If the closure lost track of it during the warm
    # recompile above (because `compile` omitted its cached object and
    # something wrongly read `compile` instead of `link`), this selection
    # would silently miss it.
    writeFile(root / "tests" / "unit" / "native" / "add.c", AddCV2)
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_cadd.nim")

    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "tests/unit/native/add.c" in closureSet

# ---------------------------------------------------------------------------
# Slice 8 — D8: a tuple-form `{.compile: (pattern, format).}` object erases
# the source path from its own basename, so it cannot be attributed to a
# source file.  extractClosure must fail closed (raise cekEnvironment,
# invalidating the entry) rather than silently record an incomplete closure.
# ---------------------------------------------------------------------------

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  ## Like `captureStdout`, but also captures stderr (fd 2) separately —
  ## needed to assert on the runner's "could not record its source closure"
  ## warning without losing the ability to also assert on stdout's JSON.
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_issue11ext_capout_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_issue11ext_caperr_" & tag & ".txt")
  let outF = open(outPath, fmWrite)
  let errF = open(errPath, fmWrite)
  let outFd: cint = outF.getFileHandle.cint
  let errFd: cint = errF.getFileHandle.cint
  let savedOutFd: cint = posix_mod.dup(1.cint)
  let savedErrFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(outFd, 1.cint)
  discard posix_mod.dup2(errFd, 2.cint)
  outF.close()
  errF.close()
  let code = runMain(args)
  flushFile(stdout)
  flushFile(stderr)
  discard posix_mod.dup2(savedOutFd, 1.cint)
  discard posix_mod.dup2(savedErrFd, 2.cint)
  discard posix_mod.close(savedOutFd)
  discard posix_mod.close(savedErrFd)
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  removeFile(outPath)
  removeFile(errPath)
  (code: code, stdout: outText, stderr: errText)

const GlobAddC = "int gadd(int a, int b) { return a + b; }\n"

const GaddProbe = """
import std/os
{.compile: ("native/glob*.c", "$1.o").}
proc gadd(a, b: cint): cint {.importc, cdecl.}
writeFile(currentSourcePath().parentDir / "gadd.marker", $gadd(1, 1))
quit(0)
"""

suite "issue #11 — tuple-form {.compile.} object is unattributable (D8, fail-closed)":

  test "tuple-form compile pragma: compiles fine, closure recording fails closed":
    let root = newProject("gadd")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdlSimple)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    writeFile(root / "tests" / "unit" / "native" / "globadd.c", GlobAddC)
    let epPath = root / "tests" / "unit" / "test_gadd.nim"
    writeFile(epPath, GaddProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: the tuple-form C source still COMPILES and RUNS fine — the
    # failure D8 introduces is in closure RECORDING, not compilation.
    let full = captureBoth(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "gadd.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "2"

    # The runner must warn that the closure could not be recorded, naming
    # the (pattern, format) tuple form as the reason.
    check "could not record its source closure" in full.stderr
    check "(pattern, format)" in full.stderr

    # With NO edits at all, the entrypoint must still be force-selected on
    # the next --changed run: recordClosure invalidated the entry, so there
    # is no closure record for narrowByDiff to trust.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_gadd.nim")

    # `closure --json` must report the entry as not recorded.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    check clJson["entries"][0]["recorded"].getBool == false

# ---------------------------------------------------------------------------
# Slice 9 — D9: a `{.link.}`d prebuilt object (not produced by this compile,
# not in the nimcache dir) is a tracked source when its path is absolute and
# lives under a tracked root — the same soundness gate as any other source.
# ---------------------------------------------------------------------------

const PrebuiltCV1 = "int padd(int a, int b) { return a + b; }\n"
const PrebuiltCV2 = "int padd(int a, int b) { return a + b + 10; }\n"

const PaddProbe = """
import std/os
{.link: "native/prebuilt.o".}
proc padd(a, b: cint): cint {.importc, cdecl.}
writeFile(currentSourcePath().parentDir / "padd.marker", $padd(1, 1))
quit(0)
"""

proc compileObj(cPath, oPath: string) =
  let cmd = "gcc -c " & quoteShell(cPath) & " -o " & quoteShell(oPath)
  let (o, rc) = execCmdEx(cmd)
  doAssert rc == 0, "gcc -c failed: " & o

suite "issue #11 — {.link.}d prebuilt object is a tracked compile input (D9)":

  test "editing a prebuilt {.link.}d .o file selects, recompiles, and closure-tracks it":
    let root = newProject("padd")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdlSimple)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    let cPath = root / "tests" / "unit" / "native" / "prebuilt.c"
    let oPath = root / "tests" / "unit" / "native" / "prebuilt.o"
    writeFile(cPath, PrebuiltCV1)
    compileObj(cPath, oPath)
    let epPath = root / "tests" / "unit" / "test_padd.nim"
    writeFile(epPath, PaddProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_padd, which writes padd.marker == "2"
    # (padd(1, 1) == 1 + 1).
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "padd.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "2"

    # Rebuild the .o from a modified .c. The git-visible change that must
    # drive selection is the REBUILT .o — the .c is edited too (so git sees
    # a change to both), but the .c itself is not a compile input for this
    # entrypoint; only the .o is named by {.link.}.
    writeFile(cPath, PrebuiltCV2)
    compileObj(cPath, oPath)

    # --changed --dry-run must select test_padd.nim: its closure must
    # contain native/prebuilt.o for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_padd.nim")

    # --changed (real run) must actually relink test_padd.nim against the
    # rebuilt object: a stale binary would rewrite marker with the OLD sum
    # (2), not the new one (12).
    let changed = captureStdout(@["run", "--config", root / "crisol.kdl",
                                  "--changed", "--json"])
    check changed.code == 0
    let changedJson = parseJson(changed.output.strip())
    check changedJson["entrypoints"].len == 1
    check changedJson["entrypoints"][0]["outcome"].getStr == "passed"
    check readFile(markerPath).strip == "12"

    # `closure --json` must list the {.link.}d prebuilt object as a tracked
    # compile input — and must NOT list its .c source (not a compile input
    # for this entrypoint at all; only the .o is named by {.link.}).
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "tests/unit/native/prebuilt.o" in closureSet
    check "tests/unit/native/prebuilt.c" notin closureSet
