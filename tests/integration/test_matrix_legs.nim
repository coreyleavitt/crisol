## test_matrix_legs.nim — issue #10: groups own (globs x flags).
##
## End-to-end proof, through the real CLI entry point (runMain), that the same
## test file configured under two groups with different `flags` is TWO
## first-class entrypoints ("legs"): separately compiled (each under its own
## define), separately run, separately reported.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_matrix_legs.nim

import std/[json, os, osproc, sets, strutils, times, unittest]
import std/posix as posix_mod
import crisol

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_matrix_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_matrix_" & tag & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / ".crisol")

const MatrixKdl = """
group "unit-a" {
    globs "tests/unit/test_*.nim"
    flags "-d:legA"
}
group "unit-b" {
    globs "tests/unit/test_*.nim"
    flags "-d:legB"
}
"""

## The entrypoint passes ONLY when compiled under exactly one leg define and
## leaves a marker named after that define next to its source — so two
## markers after one `crisol run` prove two distinct compiles actually ran.
const LegProbe = """
import std/os
when defined(legA) and defined(legB):
  {.error: "both leg defines set".}
elif defined(legA):
  const leg = "A"
elif defined(legB):
  const leg = "B"
else:
  {.error: "no leg define".}
writeFile(currentSourcePath().parentDir / ("leg_" & leg & ".marker"), leg)
quit(0)
"""

# ---------------------------------------------------------------------------
# Load-bearing property: one file, two groups, two flag-sets → two legs
# ---------------------------------------------------------------------------

suite "issue #10 — matrix legs end-to-end":

  test "crisol run: same file under two groups with different flags runs as two legs":
    let root = newProject("run")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", MatrixKdl)
    writeFile(root / "tests" / "unit" / "test_probe.nim", LegProbe)

    let r = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check r.code == 0
    let j = parseJson(r.output.strip())

    # Two separately-reported legs, one per group, both passed.
    check j["entrypoints"].len == 2
    var groups: HashSet[string]
    for ep in j["entrypoints"]:
      groups.incl ep["group"].getStr
      check ep["path"].getStr.endsWith("tests/unit/test_probe.nim")
      check ep["outcome"].getStr == "passed"
    check groups == ["unit-a", "unit-b"].toHashSet

    # Two separately-compiled binaries: each leg observed ITS define.
    check fileExists(root / "tests" / "unit" / "leg_A.marker")
    check fileExists(root / "tests" / "unit" / "leg_B.marker")

# ---------------------------------------------------------------------------
# Plan visibility: `crisol list` exposes each leg's effective flags
# ---------------------------------------------------------------------------

const MatrixKdlWithGlobal = "flags \"-d:common\"\n" & MatrixKdl

suite "issue #10 — crisol list shows each leg's effective flags":

  test "list --json: every leg carries its effective flags, global then group":
    let root = newProject("listjson")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", MatrixKdlWithGlobal)
    writeFile(root / "tests" / "unit" / "test_probe.nim", LegProbe)

    let r = captureStdout(@["list", "--config", root / "crisol.kdl", "--json"])
    check r.code == 0
    let j = parseJson(r.output.strip())
    check j["schema"].getStr == "crisol/plan/v1"
    check j["schemaRevision"].getInt >= 3
    check j["entrypoints"].len == 2
    var seen: seq[(string, seq[string])]
    for ep in j["entrypoints"]:
      var fl: seq[string]
      for f in ep["flags"]: fl.add f.getStr
      seen.add (ep["group"].getStr, fl)
    check ("unit-a", @["-d:common", "-d:legA"]) in seen
    check ("unit-b", @["-d:common", "-d:legB"]) in seen

# ---------------------------------------------------------------------------
# Explicit-path resolution: a path matching several groups is several legs
# ---------------------------------------------------------------------------

suite "issue #10 — explicit path runs every matching leg; --group narrows":

  test "list <path>: a path owned by two groups plans both legs":
    let root = newProject("explicit")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", MatrixKdlWithGlobal)
    let probe = root / "tests" / "unit" / "test_probe.nim"
    writeFile(probe, LegProbe)

    let r = captureStdout(@["list", "--config", root / "crisol.kdl", "--json", probe])
    check r.code == 0
    let j = parseJson(r.output.strip())
    check j["entrypoints"].len == 2
    var seen: seq[(string, seq[string])]
    for ep in j["entrypoints"]:
      var fl: seq[string]
      for f in ep["flags"]: fl.add f.getStr
      seen.add (ep["group"].getStr, fl)
    check ("unit-a", @["-d:common", "-d:legA"]) in seen
    check ("unit-b", @["-d:common", "-d:legB"]) in seen

  test "list <path> --group unit-b: narrows to the one named leg":
    let root = newProject("explicitnarrow")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", MatrixKdlWithGlobal)
    let probe = root / "tests" / "unit" / "test_probe.nim"
    writeFile(probe, LegProbe)

    let r = captureStdout(@["list", "--config", root / "crisol.kdl", "--json",
                            "--group", "unit-b", probe])
    check r.code == 0
    let j = parseJson(r.output.strip())
    check j["entrypoints"].len == 1
    check j["entrypoints"][0]["group"].getStr == "unit-b"

# ---------------------------------------------------------------------------
# Impact selection is per leg: a define-gated import is in ONE leg's closure
# ---------------------------------------------------------------------------

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

suite "issue #10 — --changed selects per leg":

  test "a change to a file imported only under -d:legA selects only the legA leg":
    let root = newProject("changed")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", MatrixKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.marker\n")
    # Only the legA compile imports `extra`; legB's import graph omits it.
    writeFile(root / "tests" / "unit" / "extra.nim", "proc extraValue*(): int = 1\n")
    writeFile(root / "tests" / "unit" / "test_probe.nim", """
when defined(legA):
  import extra
  doAssert extraValue() == 1
quit(0)
""")
    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # A full run records each leg's closure from ITS OWN compile.
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json"])
    check full.code == 0
    check parseJson(full.output.strip())["entrypoints"].len == 2

    # Touch the define-gated dependency; only legA's closure contains it.
    writeFile(root / "tests" / "unit" / "extra.nim", "proc extraValue*(): int = 1 # touched\n")
    let plan = captureStdout(@["run", "--config", root / "crisol.kdl",
                               "--changed", "--dry-run", "--json"])
    check plan.code == 0
    let j = parseJson(plan.output.strip())
    check j["entrypoints"].len == 1
    check j["entrypoints"][0]["group"].getStr == "unit-a"
    check j["entrypoints"][0]["flags"] == %*["-d:legA"]
