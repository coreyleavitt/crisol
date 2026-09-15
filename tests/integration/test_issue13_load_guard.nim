## test_issue13_load_guard.nim — issue #13.1: the M10 load-time guard must
## drop relative closure paths that escape projectRoot (e.g. "../../etc/passwd"),
## not just absolute ones.
##
## Proves the fix end to end through the real CLI: a REAL run writes a REAL
## depgraph; the on-disk file is then tampered with (two escaping relative
## paths appended to a real entry's closure array); `crisol closure --json`
## must report the entry's closure WITHOUT the tampered paths, and WITH the
## legitimate entrypoint path still present.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue13_load_guard.nim

import std/[json, os, osproc, strutils, times, unittest]
import crisol
import ../support/capture

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue12_clean_gc.nim —
# not imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_issue13_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

const EpBody = "doAssert true\n"

const ProjectKdl = """
group "unit" {
    globs "tests/unit/t_*.nim"
}
"""

# ---------------------------------------------------------------------------
# End-to-end proof
# ---------------------------------------------------------------------------

suite "issue #13.1 — M10 load guard drops escaping relative closure paths":

  test "closure --json neither lists a tampered relative path nor loses the real entry":
    let root = newProject("main")
    defer: removeDir(root)
    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n")
    let epPath = root / "tests" / "unit" / "t_a.nim"
    writeFile(epPath, EpBody)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Real run: compiles + runs the entrypoint, writing a REAL depgraph with
    # a REAL closure for tests/unit/t_a.nim.
    var fullCode = 0
    let fullOutput = captureStdout(proc() = fullCode = runMain(@["run", "--config", cfgPath, "--json"]))
    check fullCode == 0
    let fullJson = parseJson(fullOutput.strip())
    check fullJson["entrypoints"].len == 1
    check fullJson["entrypoints"][0]["outcome"].getStr == "passed"

    # Tamper with the on-disk depgraph: append two escaping relative paths
    # to the entry's closure array. Keep the header and everything else
    # intact.
    let depPath = root / ".crisol" / "depgraph"
    var doc = parseJson(readFile(depPath))
    var found = false
    for entryNode in doc["entries"]:
      if entryNode["path"].getStr == "tests/unit/t_a.nim":
        found = true
        entryNode["closure"].add newJString("../../outside.nim")
        entryNode["closure"].add newJString("tests/../../escape.nim")
    check found
    writeFile(depPath, $doc)

    # `crisol closure --json` must load the tampered graph through the M10
    # guard: the entrypoint's closure survives (minus the tampered paths).
    var clsCode = 0
    let clsOutput = captureStdout(proc() = clsCode = runMain(@["closure", "tests/unit/t_a.nim", "--json",
                              "--config", cfgPath]))
    check clsCode == 0
    let clsJson = parseJson(clsOutput.strip())
    check clsJson["entries"].len == 1
    let e = clsJson["entries"][0]
    check e["recorded"].getBool == true

    var closureSet: seq[string]
    for c in e["closure"]:
      closureSet.add c.getStr

    check "tests/unit/t_a.nim" in closureSet
    check "../../outside.nim" notin closureSet
    check "tests/../../escape.nim" notin closureSet
