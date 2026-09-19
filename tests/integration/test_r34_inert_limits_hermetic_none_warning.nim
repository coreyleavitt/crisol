## test_r34_inert_limits_hermetic_none_warning.nim -- code-review r34:
## `sandbox.resolveSandbox`'s `hlNone` early-return
## (`if level == hlNone: return SandboxSpec(level: hlNone, envPins: envPins)`)
## sits BEFORE the block that consumes `rlimits`/`memoryLimit` at all, so a
## `--rlimit-*`/`--limit-memory` override set alongside `--hermetic none`
## was silently dropped on the floor -- no error, no warning, nothing. Fix:
## a loud stderr warning (`warnStderr`, r18/r62 precedent) at the ONE
## production `resolveSandbox` call site (api.nim) when any such override
## is set but the resolved hermeticity level is `hlNone`. hlNone's own
## semantics are UNCHANGED (it still applies no limits) -- only the silence
## is fixed.
##
## Same idiom as test_rfc0007_r18_minsaferlimitas_warning.nim: driven
## through the REAL entry point (`crisol run`), against an ISOLATED tmp
## project dir (own crisol.kdl, own cwd, own .crisol state dir) so this
## test never contends the ambient project's advisory run-lock with a
## concurrent `crisol run` elsewhere in the checkout.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r34_inert_limits_hermetic_none_warning.nim

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
  getTempDir() / ("crisol_r34_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

const UnitGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

proc setupProject(tag: string): string =
  result = uniqueTmpDir(tag)
  writeFD(result, "tests/unit/test_pass_always.nim", readFile(fixtureDir() / "pass_always.nim"))
  writeFile(result / "crisol.kdl", UnitGroupKdl)

template withProject(tag: string, body: untyped) =
  let root {.inject.} = setupProject(tag)
  defer: removeDir(root)
  let oldCwd = getCurrentDir()
  setCurrentDir(root)
  defer: setCurrentDir(oldCwd)
  body

suite "r34 -- --rlimit-*/--limit-memory overrides are declared inert under --hermetic none":

  test "--rlimit-fsize + --hermetic none prints a stderr warning naming both flags":
    withProject("rlimit-fsize"):
      var code = 0
      let errText = captureStderr(proc() =
        code = runMain(@["run", "--jobs", "1",
                          "--hermetic", "none",
                          "--rlimit-fsize", "1048576",
                          "--json", "--no-cache"]))
      check errText.contains("warning")
      check errText.contains("rlimit")
      check errText.contains("limit-memory")
      check errText.contains("hermetic none")
      check errText.contains("inert")

  test "--limit-memory + --hermetic none prints a stderr warning":
    withProject("limit-memory"):
      var code = 0
      let errText = captureStderr(proc() =
        code = runMain(@["run", "--jobs", "1",
                          "--hermetic", "none",
                          "--limit-memory", "67108864",
                          "--json", "--no-cache"]))
      check errText.contains("warning")
      check errText.contains("inert")

  test "--rlimit-fsize + --hermetic none but NO limit override prints no r34 warning":
    withProject("nowarn-no-override"):
      var code = 0
      let errText = captureStderr(proc() =
        code = runMain(@["run", "--jobs", "1",
                          "--hermetic", "none",
                          "--json", "--no-cache"]))
      check code == 0
      check not errText.contains("inert")

  test "--rlimit-fsize set but hermeticity NOT none prints no r34 warning":
    withProject("nowarn-hermetic-isolated"):
      var code = 0
      let errText = captureStderr(proc() =
        code = runMain(@["run", "--jobs", "1",
                          "--hermetic", "isolated",
                          "--rlimit-fsize", "1048576",
                          "--json", "--no-cache"]))
      check code == 0
      check not errText.contains("inert")

when isMainModule:
  echo "test_r34_inert_limits_hermetic_none_warning done"
