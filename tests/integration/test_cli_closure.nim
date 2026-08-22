## test_cli_closure.nim — issue #9 slice A integration tests for `crisol closure`.
##
## Proves the new read-only CLI subcommand surfaces the SAME depgraph data
## crisol itself uses for --changed selection, so a downstream consumer
## (amoxtli) never has to re-implement the depgraph loader or group/flag
## resolution.
##
##   crisol closure <entrypoint> [--json]    — entries for one entrypoint path.
##   crisol closure --all [--json]           — every discovered entrypoint.
##
## Coverage:
##   1. Before any run: `closure <path> --json` → recorded == false, closure == [].
##   2. After `run <path>`: `closure <path> --json` → recorded == true, closure
##      contains the entrypoint AND its dependency, closureHash is 16 hex chars,
##      group/flagHash are populated.
##   3. `closure --all --json` → one entry per discovered entrypoint, in one doc.
##   4. Usage errors: no args, or positional + --all together → exit 3.
##   5. Non-JSON `closure --all` → exit 0, human listing mentions both paths.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_closure.nim

import std/[json, monotimes, os, strutils, unittest]
import std/posix as posix_mod
import crisol  # runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  result = getTempDir() / ("crisol_closure_" & tag & "_" & $mono.ticks)
  createDir(result)

proc captureStdoutToFile(path: string; body: proc()): void =
  ## Redirect fd 1 (stdout) to `path`, call body(), then restore.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(1) failed")
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stdout)
    discard posix_mod.dup2(savedFd, 1.cint)
    discard posix_mod.close(savedFd)

proc writeF(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc setUpProject(): string =
  ## Build a temp project root with a dep.nim + two test entrypoints, laid
  ## out under the default "unit" group convention glob
  ## (tests/unit/test_*.nim — see config.nim's DefaultGroups) so no
  ## crisol.kdl is needed.
  let root = uniqueTmpDir("proj")
  writeF(root, "tests/unit/dep.nim", "proc v*(): int = 1\n")
  writeF(root, "tests/unit/test_a.nim", "import dep\ndoAssert v() == 1\n")
  writeF(root, "tests/unit/test_b.nim", "doAssert true\n")
  root

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "crisol closure — issue #9 slice A":

  test "closure <path> --json BEFORE any run: recorded == false, closure == []":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_before.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["schema"].getStr == "crisol/closure/v1"
    check j["entries"].len == 1
    let e = j["entries"][0]
    check e["path"].getStr == "tests/unit/test_a.nim"
    check e["recorded"].getBool == false
    check e["closure"].len == 0
    check e["closureHash"].getStr == ""

  test "run then closure <path> --json: recorded == true, closure has both files":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the captureStdoutToFile block below
    check runCode == 0

    let outPath = getTempDir() / "crisol_closure_after.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len == 1
    let e = j["entries"][0]
    check e["recorded"].getBool == true
    check e["group"].getStr.len > 0
    check e["flagHash"].getStr.len == 16
    check e["closureHash"].getStr.len == 16
    var closureSet: seq[string]
    for c in e["closure"]:
      closureSet.add c.getStr
    check "tests/unit/test_a.nim" in closureSet
    check "tests/unit/dep.nim" in closureSet

  test "closure --all --json: entries for BOTH test_a (recorded) and test_b (not)":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the captureStdoutToFile block below
    check runCode == 0

    let outPath = getTempDir() / "crisol_closure_all.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    var byPath: seq[(string, bool)]
    for e in j["entries"]:
      byPath.add (e["path"].getStr, e["recorded"].getBool)
    check ("tests/unit/test_a.nim", true) in byPath
    check ("tests/unit/test_b.nim", false) in byPath

  test "closure with no args → exit 3":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)
    let code = runMain(@["closure"])
    check code == 3

  test "closure --all <path> together → exit 3":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)
    let code = runMain(@["closure", "--all", "tests/unit/test_a.nim"])
    check code == 3

  test "non-json closure --all → exit 0, stdout mentions both paths":
    let root = setUpProject()
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_all_human.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all"]))
    check code == 0
    let txt = readFile(outPath)
    check "tests/unit/test_a.nim" in txt
    check "tests/unit/test_b.nim" in txt
