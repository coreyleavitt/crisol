## test_rfc0007_r21_env_passthrough.nim -- rfc-0007 code-review r21:
## `resolveSandbox`'s `passthroughs` param (env-allowlist extension) was
## reachable from no RunOptions field, no KDL key, and no CLI flag, despite
## `sandbox.DefaultEnvAllowlist`'s doc comment promising extensibility.
## Operators were abusing `--env-pin` (which PINS a fixed value into the
## soundness key, a different mechanism) as a stand-in.
##
## FIX: RunOptions.envPassthroughs + Config.envPassthroughs (KDL repeatable
## `env-passthrough "NAME"`) + CLI `--env-passthrough NAME` (repeatable),
## merged as a deduplicated UNION (api.envPassthroughsFrom) and threaded to
## `resolveSandbox`'s `passthroughs` param at the api.nim:~1514 call site.
##
## SOUNDNESS: a passed-through variable's live host VALUE already enters
## the soundness key via the EXISTING mechanism -- `resolveSandbox` folds
## `passthroughs` into `spec.envAllowlist`, and `cachedispatch.keyContext`
## already computes `hermeticEnvHash(filterEnv(parentEnv, spec, @[]))` over
## every ALLOWLISTED var's name+value (see sandbox.hermeticEnvHash's doc:
## "an allowlisted var is one tests are allowed to depend on, so its value
## is a real input"). No separate fold was needed in keys.nim/
## cachedispatch.nim -- suite 2 below proves this directly against
## `sandbox.hermeticEnvHash`/`filterEnv`, and proves the empty-passthrough
## case is BYTE-IDENTICAL to before this slice (no cache format bump).
##
## Driven through the REAL entry point (`crisol run`) for the E2E leg,
## against an ISOLATED tmp project dir (own crisol.kdl, own cwd, own
## .crisol state dir -- same idiom as test_rfc0007_w2_limit_wiring.nim).
## The `passthrough_marker` fixture (tests/fixtures/passthrough_marker.nim)
## writes what IT observed for an arbitrary, test-chosen env var NAME to a
## marker file (both the NAME and the marker path arrive via --env-pin,
## which bypasses the allowlist entirely -- sandbox.filterEnv's tail
## contract -- so this plumbing is independent of the very allowlist
## mechanism under test).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r21_env_passthrough.nim

import std/[os, strutils, times, unittest]
import crisol            # imports runMain
import crisol/[api, types, sandbox]
import ../support/capture

const ProbeVar = "CRISOL_R21_SENTINEL"
  ## Deliberately NOT on sandbox.DefaultEnvAllowlist and not LC_*-prefixed --
  ## scrubbed under hlIsolated unless passed through.

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc writeFD(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_r21_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

const UnitGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const PassthroughKdl = """
env-passthrough "CRISOL_R21_SENTINEL"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

proc setupProject(tag: string; kdl: string): tuple[root, markerPath: string] =
  let root = uniqueTmpDir(tag)
  writeFD(root, "tests/unit/test_passthrough_marker.nim",
          readFile(fixtureDir() / "passthrough_marker.nim"))
  writeFile(root / "crisol.kdl", kdl)
  let markerPath = root / "passthrough_marker_output.txt"
  (root, markerPath)

# ---------------------------------------------------------------------------
# Suite 1 -- E2E: --env-passthrough / env-passthrough KDL reach the child
# ---------------------------------------------------------------------------

suite "rfc-0007 r21 -- --env-passthrough is reachable end to end":

  test "without passthrough: sentinel var is scrubbed under hlIsolated (default)":
    let (root, markerPath) = setupProject("noflag", UnitGroupKdl)
    defer: removeDir(root)
    putEnv(ProbeVar, "forbidden_value")
    defer: delEnv(ProbeVar)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--env-pin", "CRISOL_R21_PROBE_NAME=" & ProbeVar,
                        "--env-pin", "CRISOL_R21_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    check readFile(markerPath).strip() == "<UNSET>"

  test "CLI --env-passthrough NAME: the child observes the host's live value":
    let (root, markerPath) = setupProject("cli-flag", UnitGroupKdl)
    defer: removeDir(root)
    putEnv(ProbeVar, "visible_value")
    defer: delEnv(ProbeVar)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1", "--env-passthrough", ProbeVar,
                        "--env-pin", "CRISOL_R21_PROBE_NAME=" & ProbeVar,
                        "--env-pin", "CRISOL_R21_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    check readFile(markerPath).strip() == "visible_value"

  test "KDL env-passthrough \"NAME\": same effect as the CLI flag":
    let (root, markerPath) = setupProject("kdl-key", PassthroughKdl)
    defer: removeDir(root)
    putEnv(ProbeVar, "kdl_visible_value")
    defer: delEnv(ProbeVar)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    discard captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1",
                        "--env-pin", "CRISOL_R21_PROBE_NAME=" & ProbeVar,
                        "--env-pin", "CRISOL_R21_MARKER=" & markerPath,
                        "--json", "--no-cache"]))
    check code == 0
    require fileExists(markerPath)
    check readFile(markerPath).strip() == "kdl_visible_value"

# ---------------------------------------------------------------------------
# Suite 2 -- unit-level soundness: hermeticEnvHash already covers a
# passthrough's value (no separate fold needed); the empty-passthrough case
# is byte-identical to before this slice.
# ---------------------------------------------------------------------------

suite "rfc-0007 r21 -- passthrough values already participate in the soundness key":

  test "no passthroughs configured: hermeticEnvHash is BYTE-IDENTICAL to the pre-r21 shape":
    let parentEnv = @[("PATH", "/usr/bin"), (ProbeVar, "irrelevant")]
    let specOld = resolveSandbox(level = hlIsolated)  # pre-r21 call shape (no passthroughs arg)
    let specNew = resolveSandbox(level = hlIsolated, passthroughs = @[])
    check hermeticEnvHash(filterEnv(parentEnv, specOld, @[])) ==
          hermeticEnvHash(filterEnv(parentEnv, specNew, @[]))

  test "a passthrough's value changing changes hermeticEnvHash (soundness: equal key <=> equal result)":
    let specWithPassthrough = resolveSandbox(level = hlIsolated, passthroughs = @[ProbeVar])
    let envA = @[("PATH", "/usr/bin"), (ProbeVar, "valueA")]
    let envB = @[("PATH", "/usr/bin"), (ProbeVar, "valueB")]
    check hermeticEnvHash(filterEnv(envA, specWithPassthrough, @[])) !=
          hermeticEnvHash(filterEnv(envB, specWithPassthrough, @[]))

  test "envPassthroughsFrom: empty config + empty options -> empty (byte-identical default)":
    let cfg = Config(envPassthroughs: @[])
    let opts = RunOptions(envPassthroughs: @[])
    check envPassthroughsFrom(cfg, opts).len == 0

  test "envPassthroughsFrom: union of config + options, deduplicated":
    let cfg = Config(envPassthroughs: @["FOO", "BAR"])
    let opts = RunOptions(envPassthroughs: @["BAR", "BAZ"])
    let merged = envPassthroughsFrom(cfg, opts)
    check merged.len == 3
    check "FOO" in merged
    check "BAR" in merged
    check "BAZ" in merged

when isMainModule:
  echo "test_rfc0007_r21_env_passthrough done"
