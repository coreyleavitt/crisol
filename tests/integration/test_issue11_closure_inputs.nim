## test_issue11_closure_inputs.nim — issue #11: include'd files are tracked
## compile inputs.
##
## `closure.extractClosure` used to derive the source closure from the
## nimcache manifest's `link` array alone, which names only compiled MODULE
## objects. A file pulled in via `include` (no module object of its own — it
## is textually merged into its includer) was therefore invisible: editing it
## neither triggered a recompile (planner.decideCompile's closure content
## hash only covers closure files) nor got selected under `--changed`
## (narrow.selectByDiff intersects the git diff with the closure).
##
## Fix: compile with `-d:nimBetterRun` (compiledriver.nimCompileArgs), which
## makes Nim write a `depfiles` array into the manifest naming EVERY file it
## opened — including `include`d files — and union that into the closure.
##
## This test proves the fix end to end through the real CLI entry point
## (runMain): an `include`d file changes → `--changed` selects the
## includer → `run --changed` actually recompiles it (proved by the
## includer's own marker output value changing, not just staying stale).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue11_closure_inputs.nim

import std/[json, os, osproc, strutils, times, unittest]
import std/posix as posix_mod
import crisol

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_matrix_legs.nim — not
# imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_issue11_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_issue11_" & tag & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit" / "parts")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

const ProjectKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const BodyV1 = "const Answer = 1\n"
const BodyV2 = "const Answer = 2\n"

const IncludeProbe = """
import std/os
include parts/body
writeFile(currentSourcePath().parentDir / "answer.marker", $Answer)
quit(0)
"""

# ---------------------------------------------------------------------------
# End-to-end proof
# ---------------------------------------------------------------------------

suite "issue #11 — include'd file is a tracked compile input":

  test "editing an include'd file selects, recompiles, and closure-tracks the includer":
    let root = newProject("main")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    writeFile(root / "tests" / "unit" / "parts" / "body.nim", BodyV1)
    let epPath = root / "tests" / "unit" / "test_inc.nim"
    writeFile(epPath, IncludeProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_inc, which writes answer.marker == "1".
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "answer.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "1"

    # Edit the include'd file (not the includer itself).
    writeFile(root / "tests" / "unit" / "parts" / "body.nim", BodyV2)

    # --changed --dry-run must select test_inc.nim: its closure must contain
    # the include'd file for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_inc.nim")

    # --changed (real run) must actually RECOMPILE test_inc.nim: a stale
    # binary would rewrite marker with the OLD Answer (1), not the new one.
    let changed = captureStdout(@["run", "--config", root / "crisol.kdl",
                                  "--changed", "--json"])
    check changed.code == 0
    let changedJson = parseJson(changed.output.strip())
    check changedJson["entrypoints"].len == 1
    check changedJson["entrypoints"][0]["outcome"].getStr == "passed"
    check readFile(markerPath).strip == "2"

    # `closure --json <path>` must list the include'd file as a tracked
    # compile input of test_inc.nim.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet.add c.getStr
    check "tests/unit/parts/body.nim" in closureSet

# ---------------------------------------------------------------------------
# staticRead input
# ---------------------------------------------------------------------------

const SrAnswerV1 = "1\n"
const SrAnswerV2 = "2\n"

const StaticReadProbe = """
import std/[os, strutils]
const Answer = staticRead("data/answer.txt").strip
writeFile(currentSourcePath().parentDir / "sr.marker", Answer)
quit(0)
"""

suite "issue #11 — staticRead target is a tracked compile input":

  test "staticRead input":
    let root = newProject("sr")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    createDir(root / "tests" / "unit" / "data")
    let dataPath = root / "tests" / "unit" / "data" / "answer.txt"
    writeFile(dataPath, SrAnswerV1)
    let epPath = root / "tests" / "unit" / "test_sr.nim"
    writeFile(epPath, StaticReadProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_sr, which writes sr.marker == "1".
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "sr.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "1"

    # Edit the staticRead target (not the entrypoint itself).
    writeFile(dataPath, SrAnswerV2)

    # --changed --dry-run must select test_sr.nim: its closure must contain
    # the staticRead target for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_sr.nim")

    # --changed (real run) must actually RECOMPILE test_sr.nim: a stale
    # binary would rewrite marker with the OLD Answer (1), not the new one —
    # staticRead is evaluated at compile time, so this also proves the
    # recompile actually re-executed the staticRead, not just relinked.
    let changed = captureStdout(@["run", "--config", root / "crisol.kdl",
                                  "--changed", "--json"])
    check changed.code == 0
    let changedJson = parseJson(changed.output.strip())
    check changedJson["entrypoints"].len == 1
    check changedJson["entrypoints"][0]["outcome"].getStr == "passed"
    check readFile(markerPath).strip == "2"

    # `closure --json <path>` must list the staticRead target as a tracked
    # compile input of test_sr.nim.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet2: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet2.add c.getStr
    check "tests/unit/data/answer.txt" in closureSet2

# ---------------------------------------------------------------------------
# nim.cfg next to the entrypoint
# ---------------------------------------------------------------------------

const CfgV1 = "# crisol test nim.cfg: no flags yet\n"
const CfgV2 = "-d:flip\n"

const NimCfgProbe = """
import std/os
when defined(flip):
  const Marker = "flipped"
else:
  const Marker = "plain"
writeFile(currentSourcePath().parentDir / "cfg.marker", Marker)
quit(0)
"""

suite "issue #11 — nim.cfg next to the entrypoint is a tracked compile input":

  test "nim.cfg next to the entrypoint is a compile input":
    let root = newProject("cfg")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    let cfgPath = root / "tests" / "unit" / "nim.cfg"
    writeFile(cfgPath, CfgV1)
    let epPath = root / "tests" / "unit" / "test_cfg.nim"
    writeFile(epPath, NimCfgProbe)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Full run: compiles + runs test_cfg, which writes cfg.marker == "plain"
    # (nim.cfg carries no -d:flip yet).
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    let markerPath = root / "tests" / "unit" / "cfg.marker"
    check fileExists(markerPath)
    check readFile(markerPath).strip == "plain"

    # The config file is a tracked input from the FIRST compile onward —
    # Nim registers it in fileInfos as soon as it is read, even when it
    # contributes no flags — so the closure already lists it before any
    # edit. (Selection on the edit below depends on exactly this.)
    let clPre = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check clPre.code == 0
    var closurePre: seq[string]
    for c in parseJson(clPre.output.strip())["entries"][0]["closure"]:
      closurePre.add c.getStr
    check "tests/unit/nim.cfg" in closurePre

    # Edit nim.cfg (not the entrypoint itself) to add -d:flip.
    writeFile(cfgPath, CfgV2)

    # --changed --dry-run must select test_cfg.nim: its closure must contain
    # nim.cfg for the git-diff intersection to hit.
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let planJson = parseJson(plan.output.strip())
    check planJson["entrypoints"].len == 1
    check planJson["entrypoints"][0]["path"].getStr.endsWith("tests/unit/test_cfg.nim")

    # --changed (real run) must actually RECOMPILE test_cfg.nim under the new
    # -d:flip: a stale binary would rewrite marker with "plain", not
    # "flipped".
    let changed = captureStdout(@["run", "--config", root / "crisol.kdl",
                                  "--changed", "--json"])
    check changed.code == 0
    let changedJson = parseJson(changed.output.strip())
    check changedJson["entrypoints"].len == 1
    check changedJson["entrypoints"][0]["outcome"].getStr == "passed"
    check readFile(markerPath).strip == "flipped"

    # `closure --json <path>` must list nim.cfg as a tracked compile input
    # of test_cfg.nim.
    let cl = captureStdout(@["closure", "--json", "--config", root / "crisol.kdl", epPath])
    check cl.code == 0
    let clJson = parseJson(cl.output.strip())
    check clJson["entries"].len == 1
    var closureSet3: seq[string]
    for c in clJson["entries"][0]["closure"]:
      closureSet3.add c.getStr
    check "tests/unit/nim.cfg" in closureSet3
