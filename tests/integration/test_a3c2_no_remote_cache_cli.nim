## test_a3c2_no_remote_cache_cli.nim — RFC-0005 A3c-ii: `--no-remote-cache`
## through the REAL entry point (`crisol run`/`crisol list`), mirroring
## test_b2b_cache_stats_cli.nim / test_b1c_explain_miss_cli.nim's own pattern.
##
## Properties pinned (RFC-0005 line 432, 467; A3c-ii bullet):
##   1. `--no-remote-cache` drops every configured `remote-cache` tier for
##      the run -- even one that would otherwise be REJECTED by
##      `configuredCache` (an "l1"-named remote) never reaches that
##      validation, since the remote is dropped before `configuredCache`
##      ever sees it. The run still succeeds; l1 caching stays active.
##   2. `--no-remote-cache` is rejected for `list` (a run-only flag, same
##      shape as `--cache-stats`/`--explain-miss`).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_a3c2_no_remote_cache_cli.nim

import std/[os, strutils, times, unittest]
import std/posix as posix_mod
import crisol   # runMain

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_a3c2_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")

const PassFixture = "quit(0)\n"

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_a3c2_out_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_a3c2_err_" & tag & ".txt")
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
  var code = 0
  try:
    code = runMain(args)
  finally:
    flushFile(stdout)
    flushFile(stderr)
    discard posix_mod.dup2(savedOutFd, 1.cint)
    discard posix_mod.dup2(savedErrFd, 2.cint)
    discard posix_mod.close(savedOutFd)
    discard posix_mod.close(savedErrFd)
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  try: removeFile(outPath) except CatchableError: discard
  try: removeFile(errPath) except CatchableError: discard
  (code: code, stdout: outText, stderr: errText)

suite "A3c-ii CLI — --no-remote-cache drops an otherwise-rejected remote before configuredCache sees it":

  test "an 'l1'-named remote-cache block would normally be a config error (exit 3); --no-remote-cache makes the run succeed":
    let root = freshProjectRoot("dropsbad")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_a.nim", PassFixture)
    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "l1" {
    url "file:///nonexistent/wherever"
}
""")
    let cfgPath = root / "crisol.kdl"

    # Without --no-remote-cache: configuredCache rejects the reserved "l1"
    # name -- a structural config error, exit 3.
    let rBad = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check rBad.code == 3
    check "l1" in rBad.stderr

    # With --no-remote-cache: the remote is dropped before configuredCache
    # ever runs its rejections -- the run succeeds on l1 alone.
    let rOk = captureBoth(@["run", "--config", cfgPath, "--jobs", "1", "--no-remote-cache"])
    check rOk.code == 0

suite "A3c-ii CLI — --no-remote-cache is run-only":

  test "--no-remote-cache is rejected for 'list'":
    let root = freshProjectRoot("listrejects")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_a.nim", PassFixture)
    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
    let r = captureBoth(@["list", "--config", root / "crisol.kdl", "--no-remote-cache"])
    check r.code != 0
    check "not valid for 'list'" in r.stderr

when isMainModule:
  echo "test_a3c2_no_remote_cache_cli: done"
