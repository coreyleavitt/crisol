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

import std/[os, strutils, unittest]
import crisol   # runMain
import ../support/capture

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_a3c2_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")

const PassFixture = "quit(0)\n"

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
    var badCode = 0
    let (_, badErr) = captureBoth(proc() =
      badCode = runMain(@["run", "--config", cfgPath, "--jobs", "1"]))
    check badCode == 3
    check "l1" in badErr

    # With --no-remote-cache: the remote is dropped before configuredCache
    # ever runs its rejections -- the run succeeds on l1 alone.
    var okCode = 0
    discard captureBoth(proc() =
      okCode = runMain(@["run", "--config", cfgPath, "--jobs", "1", "--no-remote-cache"]))
    check okCode == 0

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
    var code = 0
    let (_, errText) = captureBoth(proc() =
      code = runMain(@["list", "--config", root / "crisol.kdl", "--no-remote-cache"]))
    check code != 0
    check "not valid for 'list'" in errText

when isMainModule:
  echo "test_a3c2_no_remote_cache_cli: done"
