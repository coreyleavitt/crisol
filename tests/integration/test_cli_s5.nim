## test_cli_s5.nim — S5 (F3) integration tests: crisol --version / -V.
##
## Tests:
##   1. --version prints "crisol 0.1.0" (exact match) to stdout, exits 0.
##   2. -V is equivalent.
##   3. version subcommand is equivalent.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_s5.nim

import std/[os, strutils, unittest]
import std/posix as posix_mod
import crisol   # runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc captureStdout(body: proc()): string =
  let outPath = getTempDir() / ("crisol_s5_" & $getpid() & ".txt")
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

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "crisol S5 — --version / -V":

  test "--version prints exact version string to stdout and exits 0":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["--version"]))
    check code == 0
    # Exact string: "crisol 0.1.0\n" (matches crisol.nimble version = "0.1.0")
    check txt.strip() == "crisol 0.1.0"

  test "-V is equivalent to --version":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["-V"]))
    check code == 0
    check txt.strip() == "crisol 0.1.0"

  test "'version' subcommand is equivalent to --version":
    var code = 0
    let txt = captureStdout(proc() = code = runMain(@["version"]))
    check code == 0
    check txt.strip() == "crisol 0.1.0"
