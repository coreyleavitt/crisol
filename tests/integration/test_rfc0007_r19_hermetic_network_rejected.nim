## test_rfc0007_r19_hermetic_network_rejected.nim -- rfc-0007 code-review r19:
## `--hermetic network` was a live CLI/library arm for a mechanism that has
## never been implemented: no network isolation exists anywhere (types.nim
## documents `netIso` as unenforced). Accepting the level silently had two
## consequences: (a) `evidence.hermetic` serialized "network" on the run/v2
## wire -- an unenforced vouch an external reader cannot detect; (b)
## `evidenceSatisfies` silently disabled ALL cache store/serve for the run,
## with no warning anywhere.
##
## DECIDED FIX (see api.planImpl): reject the request loudly and
## structurally -- a CrisolError(cekConfig) -- at the ONE point every CLI
## invocation and every library caller of planTests()/runTests() flows
## through. Note: this codebase has NO separate KDL `hermetic` config key
## today (grep confirms `config.nim` has no such node) -- RunOptions.
## hermeticLevel is the ONLY producer, reachable from the CLI's `--hermetic`
## flag or directly from a library caller. So "the CLI arm" and "the
## library/RunOptions arm" (suite 2 below) are the two actual surfaces;
## there is no third KDL surface to separately test.
##
## Driven through the REAL entry points: `crisol run` via `runMain` against
## an ISOLATED tmp project dir (own crisol.kdl, own cwd, own .crisol state
## dir -- same idiom as test_rfc0007_w2_limit_wiring.nim, so this never
## contends the ambient project's advisory run-lock with a concurrent
## `crisol run` elsewhere in the checkout) for the CLI surface, and
## `planTests`/`runTests` called directly for the library surface.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r19_hermetic_network_rejected.nim

import std/[os, strutils, times, unittest]
import crisol            # imports runMain
import crisol/[api, types]
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
  getTempDir() / ("crisol_r19_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

const UnitGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

proc setupProject(tag: string): string =
  result = uniqueTmpDir(tag)
  writeFD(result, "tests/unit/test_pass_always.nim", readFile(fixtureDir() / "pass_always.nim"))
  writeFile(result / "crisol.kdl", UnitGroupKdl)

# ---------------------------------------------------------------------------
# Suite 1 -- CLI arm (`crisol run --hermetic network`)
# ---------------------------------------------------------------------------

suite "rfc-0007 r19 -- CLI --hermetic network is rejected":

  test "--hermetic network: exits nonzero with a clear 'not implemented' message":
    let root = setupProject("network")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let errText = captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1", "--hermetic", "network",
                        "--json", "--no-cache"]))
    check code == 3
    check errText.contains("hermetic level 'network' is not implemented")
    check errText.contains("RFC-0008")

  test "--hermetic network also rejected on `run --dry-run` (plan-only path)":
    # `list` itself already refuses `--hermetic` as "not valid for 'list'"
    # (a pre-existing, unrelated usage-error gate -- crisol.nim's per-
    # subcommand flag allowlist) before ever reaching planImpl, so it is not
    # a useful second surface for THIS check. `run --dry-run` also stops at
    # the plan phase (planTests, same as `list`) but --hermetic IS a valid
    # `run` flag, so it reaches planImpl and proves the check fires even
    # when nothing would ever be spawned.
    let root = setupProject("network-dryrun")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let errText = captureStderr(proc() =
      code = runMain(@["run", "--dry-run", "--hermetic", "network"]))
    check code == 3
    check errText.contains("hermetic level 'network' is not implemented")

  test "--hermetic none still works":
    let root = setupProject("none")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1", "--hermetic", "none",
                        "--json", "--no-cache"]))
    check code == 0

  test "--hermetic isolated still works":
    let root = setupProject("isolated")
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStderr(proc() =
      code = runMain(@["run", "--jobs", "1", "--hermetic", "isolated",
                        "--json", "--no-cache"]))
    check code == 0

# ---------------------------------------------------------------------------
# Suite 2 -- library arm (RunOptions.hermeticLevel = hlNetwork, no CLI)
# ---------------------------------------------------------------------------

suite "rfc-0007 r19 -- library RunOptions.hermeticLevel = hlNetwork is rejected":

  test "planTests raises CrisolError(cekConfig) for hlNetwork":
    # The check runs BEFORE config load / entrypoint selection, so a
    # zero-value RunOptions (no project context needed) is enough --
    # planTests never gets far enough to need one.
    let opts = RunOptions(hermeticLevel: hlNetwork)
    var caught = false
    try:
      discard planTests(opts)
    except CrisolError as e:
      caught = true
      check e.kind == cekConfig
      check e.msg.contains("hermetic level 'network' is not implemented")
    check caught

  test "runTests encodes the SAME rejection as a structural RunReport (exit 3)":
    let opts = RunOptions(hermeticLevel: hlNetwork, noCache: true)
    let rr = runTests(opts)
    check rr.status == rsStructural
    check rr.exitCode == 3
    check rr.error.contains("hermetic level 'network' is not implemented")

when isMainModule:
  echo "test_rfc0007_r19_hermetic_network_rejected done"
