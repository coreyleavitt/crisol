## test_cli_list.nim — B6 integration tests for `crisol list` and `run --dry-run`.
##
## Proves the PLAN phase is rendered WITHOUT executing anything:
##   • `list <dir>` → exit 0, lists discovered fixtures with decision labels.
##   • `list <dir> --json` → single parseable crisol/plan/v1 doc, no human lines.
##   • `run <fail fixtures> --dry-run` → exit 0 even though a real run is exit 1
##     (robust non-execution proof), and stdout shows the plan, not results.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_list.nim

import std/[json, monotimes, os, strutils, unittest]
import std/posix as posix_mod
import crisol  # runMain

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

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

# Result-phase markers that must NEVER appear in a plan render.
const RunMarkers = ["[OK]", "[FAIL]", "[COMPILE]", "PASSED:", "FAILED:"]

suite "crisol list / run --dry-run — B6 (no execution)":

  # -------------------------------------------------------------------------
  # list: human output
  # -------------------------------------------------------------------------

  test "list <dir> → exit 0 and lists discovered fixtures with decisions":
    let outPath = getTempDir() / "crisol_list_human.txt"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["list", fd / "pass_always.nim"]))
    check code == 0
    let txt = readFile(outPath)
    check "pass_always.nim" in txt
    # The entrypoint may be "never built" (first run / cache absent), "binary
    # fresh" (D6: depgraph recorded from a prior run), or stale — binary present
    # but no/invalid depgraph record, rendered as plain "would compile" (e.g.
    # after a depgraph format bump or an invalidated record).  All are valid
    # plan decisions for a dry listing; accept any.
    check ("never built (would compile)" in txt or "binary fresh" in txt or
           "would compile" in txt)
    check "Planned entrypoints:" in txt
    check "entrypoint(s) across" in txt

  # -------------------------------------------------------------------------
  # list: --json output
  # -------------------------------------------------------------------------

  test "list <dir> --json → single parseable crisol/plan/v1 doc, no human lines":
    let outPath = getTempDir() / "crisol_list_json.json"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["list", fd / "pass_always.nim", "--json"]))
    check code == 0
    let raw = readFile(outPath).strip()
    # Single JSON document: parses cleanly.
    let j = parseJson(raw)
    check j["schema"].getStr == "crisol/plan/v1"
    check j["entrypoints"].len >= 1
    check j.hasKey("gatedOut")
    # No human render lines.
    for m in ["Planned entrypoints:", "never built", "entrypoint(s) across"]:
      check m notin raw

  # -------------------------------------------------------------------------
  # run --dry-run: robust non-execution proof
  # -------------------------------------------------------------------------

  test "run --dry-run with FAILING fixtures → exit 0 (a real run is exit 1)":
    ## A real `run` of fail_always + fail_compile is exit 1.  --dry-run must
    ## be exit 0 because NOTHING is compiled or run.
    let fd = fixtureDir()
    let realCode = runMain(@["run", fd / "fail_always.nim", "--jobs", "1"])
    check realCode == 1   # sanity: a real run of this fixture fails

    let dryCode = runMain(@[
      "run", "--dry-run",
      fd / "fail_always.nim",
      fd / "fail_compile.nim",
    ])
    check dryCode == 0

  test "run --dry-run stdout shows the PLAN, not results":
    let outPath = getTempDir() / "crisol_dryrun.txt"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", "--dry-run", fd / "fail_compile.nim"]))
    check code == 0
    let txt = readFile(outPath)
    check "fail_compile.nim" in txt
    check "would compile" in txt
    # No result-phase markers.
    for m in RunMarkers:
      check m notin txt

  test "run --dry-run --json → crisol/plan/v1 (not run/v1)":
    let outPath = getTempDir() / "crisol_dryrun.json"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", "--dry-run", "--json", fd / "fail_always.nim"]))
    check code == 0
    let j = parseJson(readFile(outPath).strip())
    check j["schema"].getStr == "crisol/plan/v1"

  # -------------------------------------------------------------------------
  # flag-scope guards
  # -------------------------------------------------------------------------

  test "list rejects run-only flags (--jobs) → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["list", fd / "pass_always.nim", "--jobs", "2"])
    check code == 3

  test "list rejects --dry-run → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["list", fd / "pass_always.nim", "--dry-run"])
    check code == 3

# ---------------------------------------------------------------------------
# L2: a malformed on-disk depgraph must be a visible, structured diagnostic
# for `list`, not silently swallowed. Temp-project harness (mirrors
# test_cli_closure.nim's setUpProject / test_cli_run.nim's writeFD +
# uniqueTmpDirD + setCurrentDir pattern) so we can point loadConfig() —
# which roots at getCurrentDir() — at an isolated <stateDir>/depgraph.
# ---------------------------------------------------------------------------

proc uniqueTmpDirL(tag: string): string =
  let mono = getMonoTime()
  getTempDir() / ("crisol_list_l2_" & tag & "_" & $mono.ticks)

proc writeFL(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

suite "crisol list — L2: malformed depgraph is a visible diagnostic":

  test "list --json after depgraph corruption → exit 0, warnings has key==malformed and 'depgraph discarded' message":
    let root = uniqueTmpDirL("malformed")
    defer: removeDir(root)
    writeFL(root, "tests/unit/test_a.nim", "doAssert true\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # Record a real depgraph first.
    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the captureStdoutToFile block below
    check runCode == 0
    let depgraphPath = root / ".crisol" / "depgraph"
    check fileExists(depgraphPath)

    # Corrupt it: valid JSON, but the header is not an object.
    writeFile(depgraphPath, """{"header": [1, 2, 3]}""")

    let outPath = getTempDir() / "crisol_list_l2_malformed.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["list", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j.hasKey("warnings")
    var found = false
    for w in j["warnings"].items:
      if w["key"].getStr == "malformed":
        found = true
        check "depgraph discarded" in w["message"].getStr
    check found
