## test_cli_s4.nim — S4 (F3) integration tests: help/usage/--base/clean--config.
##
## Tests:
##   S4.1 — --help / -h → usage to STDOUT, exit 0.
##   S4.2 — clean and -j/-t short forms appear in usage() text.
##   S4.3 — --base without --changed → exit 3 (behavioral reversal).
##   S4.4 — crisol clean --config <path> honours a non-default state dir.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_s4.nim

import std/[os, strutils, unittest]
import std/posix as posix_mod
import crisol   # runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc captureStdout(body: proc()): string =
  let outPath = getTempDir() / ("crisol_s4_" & $getpid() & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stdout)
    discard posix_mod.dup2(savedFd, 1.cint)
    discard posix_mod.close(savedFd)
  result = readFile(outPath)
  try: removeFile(outPath) except: discard

proc captureStderr(body: proc()): string =
  let outPath = getTempDir() / ("crisol_s4_err_" & $getpid() & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(fileFd, 2.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod.dup2(savedFd, 2.cint)
    discard posix_mod.close(savedFd)
  result = readFile(outPath)
  try: removeFile(outPath) except: discard

# ---------------------------------------------------------------------------
# S4.1 — --help / -h → stdout, exit 0
# ---------------------------------------------------------------------------

suite "crisol S4.1 — --help / -h → stdout, exit 0":

  test "--help writes usage to stdout and returns 0":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["--help"]))
    check code == 0
    check "crisol" in txt
    check "run" in txt
    check "list" in txt

  test "-h writes usage to stdout and returns 0":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["-h"]))
    check code == 0
    check "crisol" in txt
    check "run" in txt

  test "no-arg invocation is still an error (exit 3) — not affected by --help change":
    var errText = ""
    var code = 0
    errText = captureStderr(proc() = code = runMain(@[]))
    check code == 3
    # Error path: usage may go to stderr; just verify exit code

# ---------------------------------------------------------------------------
# S4.2 — clean and -j/-t appear in usage text
# ---------------------------------------------------------------------------

suite "crisol S4.2 — clean and short flags in usage":

  test "usage text includes 'clean' subcommand":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["--help"]))
    check code == 0
    check "clean" in txt

  test "usage text documents -j short form for --jobs":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["--help"]))
    check code == 0
    check "-j" in txt

  test "usage text documents -t short form for --timeout":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["--help"]))
    check code == 0
    check "-t" in txt

# ---------------------------------------------------------------------------
# S4.3 — --base without --changed → exit 3 (behavioral reversal)
# ---------------------------------------------------------------------------

suite "crisol S4.3 — --base without --changed is an error":

  test "--base without --changed returns exit 3":
    ## This is a deliberate REVERSAL from the old behavior (warn + exit 0).
    ## --base is meaningless without --changed and must now be an error.
    var errText = ""
    var code = 0
    errText = captureStderr(proc() =
      code = runMain(@["run", "--base", "HEAD", "--dry-run"]))
    check code == 3
    check "base" in errText.toLower or "changed" in errText.toLower

# ---------------------------------------------------------------------------
# S4.4 — crisol clean --config <path> honours non-default state dir
# ---------------------------------------------------------------------------

suite "crisol S4.4 — clean --config <path>":

  test "clean --config <path> targets the state dir from that config":
    ## Build a project with a custom state-dir in its config.
    ## Verify that clean --config <cfg> prunes from that dir, not the default.
    let root = getTempDir() / ("crisol_s4_clean_" & $getpid())
    createDir(root)
    defer: removeDir(root)

    # Config uses a non-default state dir.
    let customStateDir = ".mystate"
    let cfgPath = root / "crisol_custom.kdl"
    writeFile(cfgPath, "state-dir \"" & customStateDir & "\"\ngroup \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

    # Create the custom state dir with an orphan cache entry.
    let stateDir = root / customStateDir
    createDir(stateDir / "cache")
    createDir(stateDir / "cache" / "orphan_aabbccdd")

    # No test files on disk so all cache entries are orphans.
    let unitDir = root / "tests" / "unit"
    createDir(unitDir)

    # Run from within the project root so relative paths work.
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # Without --config this would use default .crisol/ (which doesn't exist here).
    # With --config it targets customStateDir.
    let code = runMain(@["clean", "--config", cfgPath])
    check code == 0

    # The orphan should have been pruned from the custom state dir.
    check not dirExists(stateDir / "cache" / "orphan_aabbccdd")

  test "clean --config=<path> (inline form) targets the state dir from that config":
    let root = getTempDir() / ("crisol_s4_clean_eq_" & $getpid())
    createDir(root)
    defer: removeDir(root)

    let customStateDir = ".mystate"
    let cfgPath = root / "crisol_custom.kdl"
    writeFile(cfgPath, "state-dir \"" & customStateDir & "\"\ngroup \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

    let stateDir = root / customStateDir
    createDir(stateDir / "cache")
    createDir(stateDir / "cache" / "orphan_aabbccdd")

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let code = runMain(@["clean", "--config=" & cfgPath])
    check code == 0
    check not dirExists(stateDir / "cache" / "orphan_aabbccdd")

  test "clean --config= (inline form, empty value) → exit 3":
    var errText = ""
    var code = 0
    errText = captureStderr(proc() =
      code = runMain(@["clean", "--config="]))
    check code == 3
    check "crisol: --config requires a file path" in errText

  test "clean --config (space form, missing value) → exit 3":
    var errText = ""
    var code = 0
    errText = captureStderr(proc() =
      code = runMain(@["clean", "--config"]))
    check code == 3
    check "crisol: --config requires a file path" in errText
