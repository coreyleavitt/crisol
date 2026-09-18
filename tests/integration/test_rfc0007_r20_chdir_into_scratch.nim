## test_rfc0007_r20_chdir_into_scratch.nim -- rfc-0007 code-review r20:
## `SandboxSpec.chdirIntoScratch` is a live, load-bearing consumer
## (runner.buildRunChildSpec picks the run child's cwd from it -- see
## runner.nim's `let cwd = if spec.chdirIntoScratch and outScratchDir.len >
## 0: outScratchDir else: projectRoot`) with ZERO producers before this
## slice: `resolveSandbox`'s `chdirIntoScratch` param was reachable from no
## RunOptions field, no KDL key, and no CLI flag, despite being documented
## "opt-in, default off" -- there was no opt-in surface at all.
##
## FIX: RunOptions.chdirIntoScratch + Config.chdirIntoScratch (KDL
## `chdir-into-scratch #true`) + CLI `--chdir-into-scratch`, merged with
## the same CLI/library-wins precedence as the rlimit-* family in
## api.planImpl, threaded to `resolveSandbox` at the api.nim:~1514 call
## site.
##
## Driven through the REAL entry point (`crisol run`), against an ISOLATED
## tmp project dir (own crisol.kdl, own cwd, own .crisol state dir -- same
## idiom as test_rfc0007_w2_limit_wiring.nim, avoiding any advisory-lock
## contention with a concurrent `crisol run` elsewhere in the checkout).
##
## The `cwd_marker` fixture (tests/fixtures/cwd_marker.nim) writes its own
## `getCurrentDir()` to a marker file named by an --env-pin'd
## CRISOL_R20_MARKER (pins bypass the allowlist entirely, reaching the
## child at every hermeticity level -- sandbox.filterEnv's tail contract),
## so the test can assert exactly what cwd the run child observed without
## needing to parse captured stdout through the CLI's --json output (which
## does not carry a captured-output field).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r20_chdir_into_scratch.nim

import std/[os, strutils, times, unittest]
import crisol         # imports runMain
import ../support/capture

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc writeFD(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_r20_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

const UnitGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const ChdirIntoScratchKdl = """
chdir-into-scratch #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

proc setupProject(tag: string; kdl: string): tuple[root, markerPath: string] =
  let root = uniqueTmpDir(tag)
  writeFD(root, "tests/unit/test_cwd_marker.nim", readFile(fixtureDir() / "cwd_marker.nim"))
  writeFile(root / "crisol.kdl", kdl)
  let markerPath = root / "cwd_marker_output.txt"
  (root, markerPath)

suite "rfc-0007 r20 -- --chdir-into-scratch is reachable end to end":

  test "without the flag: run child's cwd is projectRoot (A2c contract, unchanged default)":
    let (root, markerPath) = setupProject("default", UnitGroupKdl)
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--env-pin", "CRISOL_R20_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    let observedCwd = readFile(markerPath).strip()
    check observedCwd == root.absolutePath.normalizedPath

  test "CLI --chdir-into-scratch: run child's cwd is the per-slot scratch dir, not projectRoot":
    let (root, markerPath) = setupProject("cli-flag", UnitGroupKdl)
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1", "--chdir-into-scratch",
                        "--env-pin", "CRISOL_R20_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    let observedCwd = readFile(markerPath).strip()
    check observedCwd != root.absolutePath.normalizedPath
    check "crisol_scratch_" in observedCwd.extractFilename

  test "KDL chdir-into-scratch #true: same effect as the CLI flag":
    let (root, markerPath) = setupProject("kdl-key", ChdirIntoScratchKdl)
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--env-pin", "CRISOL_R20_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    let observedCwd = readFile(markerPath).strip()
    check observedCwd != root.absolutePath.normalizedPath
    check "crisol_scratch_" in observedCwd.extractFilename

when isMainModule:
  echo "test_rfc0007_r20_chdir_into_scratch done"
