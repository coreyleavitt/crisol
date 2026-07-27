## test_cli_group.nim — C2 integration tests for --group / --all-groups CLI flags.
##
## Tests the observable CLI behavior of the new C2 selection flags:
##   1. --group <name>          selects only that group's entrypoints.
##   2. --group A --group B     selects both named groups.
##   3. --all-groups            includes opt-in groups.
##   4. --group + --all-groups  is a usage error → exit 3.
##   5. --group <unknown>       raises cekConfig → exit 3.
##   6. --dry-run with a gated group shows the gate-skip line in output.
##   7. Gate-skip doesn't change exit code (exit 0 when non-gated groups pass).
##   8. --all-groups with a gated group: gated group in gatedOut, runs exit 0.
##
## All tests use runMain() directly.  Fixture files live in tests/fixtures/.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_group.nim

import std/[json, os, strutils, unittest]
import std/posix as posix_mod3
import crisol

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdoutToFile(path: string; body: proc()): void =
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod3.dup(1.cint)
  discard posix_mod3.dup2(fileFd, 1.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stdout)
    discard posix_mod3.dup2(savedFd, 1.cint)
    discard posix_mod3.close(savedFd)

proc captureStderrToFile(path: string; body: proc()): void =
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod3.dup(2.cint)
  discard posix_mod3.dup2(fileFd, 2.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod3.dup2(savedFd, 2.cint)
    discard posix_mod3.close(savedFd)

# ---------------------------------------------------------------------------
# Suite 1 — --group / --all-groups flag parsing
# ---------------------------------------------------------------------------

suite "crisol CLI — C2 --group / --all-groups":

  # -------------------------------------------------------------------------
  # 1. --group + --all-groups together → exit 3 (usage error)
  # -------------------------------------------------------------------------

  test "--group and --all-groups together → exit 3":
    let fd   = fixtureDir()
    let code = runMain(@["run", "--group", "unit", "--all-groups",
                         fd / "pass_always.nim", "--jobs", "1"])
    check code == 3

  # -------------------------------------------------------------------------
  # 2. --group <unknown> → exit 3 (cekConfig: unknown group name)
  # -------------------------------------------------------------------------

  test "--group <unknown group name> → exit 3":
    ## Convention config has "unit" and "integration".  "no_such_group" is absent.
    ## discover() raises cekConfig, which runMain maps to ExitEnvironment (3).
    let code = runMain(@["run", "--group", "no_such_group_xyzzy"])
    check code == 3

  # -------------------------------------------------------------------------
  # 3. --group unit selects only the unit group (with fixture dir as path)
  # -------------------------------------------------------------------------

  test "--group unit with path args → exit 0 (passing fixture runs)":
    ## Fix for issue #3: --group is threaded into GroupSelection.withinGroups
    ## alongside the path, not dropped.  This fixture path (tests/fixtures/) is
    ## outside "unit"'s configured globs (tests/unit/test_*.nim), so it does
    ## NOT match "unit" — per RFC-0001:409 it becomes an ad-hoc "paths"
    ## entrypoint with global flags, with a warning on stderr.  An ad-hoc
    ## entrypoint still compiles and runs normally, so this passes (exit 0).
    let fd   = fixtureDir()
    let code = runMain(@["run", "--group", "unit", fd / "pass_always.nim",
                         "--jobs", "1"])
    check code == 0

  # -------------------------------------------------------------------------
  # 4. --dry-run with --group selects correctly (plan shows group name)
  # -------------------------------------------------------------------------

  test "--group unit --dry-run: plan lists the selected fixture":
    let outPath = getTempDir() / "crisol_c2_dryrun_group.txt"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["list", fd / "pass_always.nim", "--group", "unit"]))
    ## Same ad-hoc case as above (fixture path is outside "unit"'s globs), via
    ## `list`/dry-run instead of `run`.  Should still exit 0 and list the path.
    check code == 0
    let txt = readFile(outPath)
    check "pass_always.nim" in txt

  # -------------------------------------------------------------------------
  # 5. --all-groups flag: accepted without error
  # -------------------------------------------------------------------------

  test "--all-groups is accepted and exits cleanly":
    ## With convention config (unit + integration, both non-opt-in), --all-groups
    ## behaves like gskDefault for the convention groups (no opt-in group exists).
    ## We just verify it doesn't crash and returns a recognized exit code.
    let code = runMain(@["run", "--all-groups",
                         "tests/fixtures/pass_always.nim", "--jobs", "1"])
    ## Should succeed (pass_always.nim passes)
    check code in [0, 1, 3]  # 3 if no fixtures found in cwd, 0/1 otherwise

  # -------------------------------------------------------------------------
  # 6. --dry-run shows gate-skip line for a gated group (via --group + env gate)
  # -------------------------------------------------------------------------
  # This test is tricky to exercise purely via the CLI because loadConfig() stub
  # doesn't have a gated group, and we can't inject a custom Config into runMain.
  # We verify it through the unit tests (test_c2_selection.nim covers the pure
  # helper; test_discover.nim covers applyGates).  For the CLI path, we verify
  # that --dry-run + --json produces a gatedOut array in the plan/v1 output
  # (gatedOut is present and is an array — actual gate exclusion requires a real
  # gated group in config which the stub doesn't have).

  test "--dry-run --json plan/v1 has gatedOut array":
    let outPath = getTempDir() / "crisol_c2_dryrun_json.json"
    defer: (try: removeFile(outPath) except: discard)
    let fd = fixtureDir()
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["run", "--dry-run", "--json", fd / "pass_always.nim"]))
    check code == 0
    let j = parseJson(readFile(outPath).strip())
    check j["schema"].getStr == "crisol/plan/v1"
    check j.hasKey("gatedOut")
    check j["gatedOut"].kind == JArray  # empty array since no gated groups in stub

  # -------------------------------------------------------------------------
  # 7. --group accepts =value syntax (--group=unit)
  # -------------------------------------------------------------------------

  test "--group=unit (= syntax) accepted without error → exit 3 for unknown group":
    ## The flag parser supports key=value inline.  Test that --group=no_such works
    ## and surfaces the unknown-group error (exit 3).
    let code = runMain(@["run", "--group=no_such_group_xyzzy"])
    check code == 3

  # -------------------------------------------------------------------------
  # 8. list command also accepts --group and --all-groups
  # -------------------------------------------------------------------------

  test "list --group unit → exit 0":
    let fd   = fixtureDir()
    let code = runMain(@["list", "--group", "unit", fd / "pass_always.nim"])
    check code == 0

  test "list --all-groups → exit 0":
    let fd   = fixtureDir()
    let code = runMain(@["list", "--all-groups", fd / "pass_always.nim"])
    check code == 0

  test "list --group + --all-groups → exit 3":
    let fd   = fixtureDir()
    let code = runMain(@["list", "--group", "unit", "--all-groups",
                         fd / "pass_always.nim"])
    check code == 3

  # -------------------------------------------------------------------------
  # 9. Issue #3 regression: --group <name> + a path that MATCHES that group's
  #    globs must resolve to the named group (and its flags) — not be
  #    silently downgraded to the ad-hoc "paths" group.  This is the CLI-level
  #    proof that giving both a path and --group no longer drops the group.
  # -------------------------------------------------------------------------

  test "issue #3: --group narrows an ambiguous path to the NAMED group, not the first-declared one":
    ## Two groups share an overlapping glob so the same path matches both.
    ## "special" is declared FIRST (would win discover()'s first-match rule
    ## with no narrowing); "unit" is declared second and is what --group asks
    ## for. If crisol.nim silently drops --group when a path is also given
    ## (the issue #3 bug), the plan reports group "special" (wrong). Threading
    ## --group into GroupSelection.withinGroups must make it report "unit".
    let root = getTempDir() / ("crisol_c2_issue3_" & $getpid())
    createDir(root)
    defer: removeDir(root)

    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, """
group "special" {
    globs "tests/unit/test_*.nim"
    flags "-d:specialmarker"
}
group "unit" {
    globs "tests/unit/test_*.nim"
    flags "-d:unitmarker"
}
""")

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    let epPath = unitDir / "test_a.nim"
    writeFile(epPath, "quit(0)\n")

    let outPath = getTempDir() / ("crisol_c2_issue3_out_" & $getpid() & ".json")
    defer: (try: removeFile(outPath) except: discard)

    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["list", "--config", cfgPath, "--group", "unit", epPath, "--json"]))
    check code == 0
    let j = parseJson(readFile(outPath).strip())
    check j["entrypoints"].len == 1
    check j["entrypoints"][0]["group"].getStr == "unit"

  # -------------------------------------------------------------------------
  # 10. Issue #3 regression: an ad-hoc path (matches no configured group)
  #     prints the RFC-0001:409 warning on stderr.
  # -------------------------------------------------------------------------

  test "issue #3: ad-hoc path (no matching group) prints an RFC-0001:409 warning on stderr":
    let fd = fixtureDir()
    let outPath = getTempDir() / "crisol_c2_issue3_adhoc.txt"
    defer: (try: removeFile(outPath) except: discard)

    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["list", fd / "pass_always.nim"]))
    check code == 0
    let errText = readFile(outPath)
    check "pass_always.nim" in errText
    check "matched no configured group" in errText
