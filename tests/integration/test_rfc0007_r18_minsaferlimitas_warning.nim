## test_rfc0007_r18_minsaferlimitas_warning.nim -- rfc-0007 code-review r18:
## sandbox.nim's MinSafeRlimitAs doc comment has long promised "crisol logs
## a warning when limitAs < MinSafeRlimitAs at spec-resolution time" -- no
## such warning existed anywhere. A small --rlimit-as silently makes every
## child SIGSEGV before main() even returns, reported as a bare crash with
## zero guidance.
##
## Driven through the REAL entry point (`crisol run`), against an ISOLATED
## tmp project dir (own crisol.kdl, own cwd, own .crisol state dir) -- same
## idiom as test_rfc0007_w2_limit_wiring.nim -- so this test never contends
## the ambient project's advisory run-lock with a concurrent `crisol run`
## elsewhere in the checkout.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r18_minsaferlimitas_warning.nim

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
  getTempDir() / ("crisol_r18_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

const UnitGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

proc setupProject(tag: string): string =
  result = uniqueTmpDir(tag)
  writeFD(result, "tests/unit/test_pass_always.nim", readFile(fixtureDir() / "pass_always.nim"))
  writeFile(result / "crisol.kdl", UnitGroupKdl)

suite "rfc-0007 r18 -- MinSafeRlimitAs warning fires at spec-resolution time":

  test "--rlimit-as below MinSafeRlimitAs (3 GiB) prints a stderr warning":
    let root = setupProject("warn")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let errText = captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--rlimit-as", "1048576",  # 1 MiB, far below 3 GiB
                        "--json", "--no-cache"]))
    # The warning must fire regardless of what the run itself did (the child
    # may well SIGSEGV under such a tiny ceiling) -- it is written at
    # spec-resolution time, before any child is spawned.
    check errText.contains("warning")
    check errText.contains("rlimit-as")
    check errText.contains("1048576")
    check errText.contains("SIGSEGV")

  test "--rlimit-as at/above MinSafeRlimitAs prints no warning":
    let root = setupProject("nowarn-at")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let errText = captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--rlimit-as", "3221225472",  # exactly 3 GiB
                        "--json", "--no-cache"]))
    check code == 0
    check not errText.contains("rlimit-as")

  test "no --rlimit-as at all prints no warning":
    let root = setupProject("nowarn-unset")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let errText = captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1", "--json", "--no-cache"]))
    check code == 0
    check not errText.contains("rlimit-as")

when isMainModule:
  echo "test_rfc0007_r18_minsaferlimitas_warning done"
