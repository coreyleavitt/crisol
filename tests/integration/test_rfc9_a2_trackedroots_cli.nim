## test_rfc9_a2_trackedroots_cli.nim — RFC-0009 A2 liveness E2E: the
## per-root FoldPolicy evidence (jsonout.trackedRootsToJson, rev 25) wired
## end-to-end through the REAL entry point (`crisol run --json`), not
## jsonout directly (mirrors test_b2b_cache_stats_cli.nim / test_b1c_explain_
## miss_cli.nim's own "through the real CLI" pattern).
##
## Why a dep-root is required to prove liveness (not just a project-only
## run): `jsonout.toJsonString`'s `trackedRoots` param defaults to
## `default(TrackedRoots)` -- the zero value -- which ALSO renders as a
## single project entry (`name` "", `foldPolicy` "none") on any ordinary
## case-sensitive filesystem. A project-root-only fixture would pass
## whether or not the CLI ever threads the real `Config.trackedRoots`
## through -- it would be evidence of nothing. Configuring one named dep
## root makes the two cases diverge: the zero-value default renders
## `trackedRoots.len == 1` (project only, the dep root silently dropped),
## while the REAL `cfg.trackedRoots` renders `trackedRoots.len == 2` with
## the dep root's configured name present. That divergence is the RED/
## GREEN signal this test pins.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc9_a2_trackedroots_cli.nim

import std/[json, os, strutils, times, unittest]
import std/posix as posix_mod
import crisol   # runMain

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_rfc9_a2_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")

const PassFixture = "quit(0)\n"

proc captureStdout(args: seq[string]): tuple[code: int; stdout: string] =
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_rfc9_a2_out_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_rfc9_a2_err_" & tag & ".txt")
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
  try: removeFile(outPath) except CatchableError: discard
  try: removeFile(errPath) except CatchableError: discard
  (code: code, stdout: outText)

suite "RFC-0009 A2 — trackedRoots evidence, wired end-to-end into real CLI --json":

  test "crisol run --json (real CLI) with one configured dep root reports BOTH roots":
    let root = freshProjectRoot("live")
    defer: removeDir(root)
    let depParent = getTempDir() / ("crisol_rfc9_a2_dep_" & $getpid())
    removeDir(depParent)
    let depDir = depParent / "mydep"
    createDir(depDir)
    defer: removeDir(depParent)

    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, """
dep-roots "$1" name="mydep"
group "unit" {
    globs "tests/unit/*.nim"
}
""" % [depDir])

    let r = captureStdout(@["run", "--config", cfgPath, "--jobs", "1", "--json"])
    check r.code == 0
    let doc = parseJson(r.stdout)
    check doc["schemaRevision"].getInt == 25

    # RED before wiring: `doc["trackedRoots"]` renders the jsonout
    # zero-value default (project only, dep root silently dropped) because
    # the real CLI never threads `RunReport.trackedRoots`/`cfg.trackedRoots`
    # into `toJsonString`. GREEN after wiring: the dep root configured
    # above is present, proving the evidence flows from the REAL Config,
    # not a stub.
    check doc.hasKey("trackedRoots")
    let roots = doc["trackedRoots"]
    check roots.len == 2
    check roots[0]["name"].getStr == ""            # project root, tag 0
    check roots[0]["foldPolicy"].getStr == "none"  # case-sensitive tmp fs
    check roots[1]["name"].getStr == "mydep"       # the configured dep root
    check roots[1]["foldPolicy"].getStr == "none"

when isMainModule:
  echo "All rfc9_a2_trackedroots_cli tests passed."
