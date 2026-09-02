## test_cli_run.nim — A5 integration tests for the crisol CLI.
##
## Tests the observable CLI behavior via runMain() — the same proc the binary
## calls.  This covers the real pipeline (discover→applyGates→plan→execute→
## summarize→exitCode) through the public CLI surface.
##
## All tests use existing fixture files (tests/fixtures/*.nim) so no file
## creation is required and discovery stays within the project root.
##
## Assertions:
##   1. run <passing fixture>  → exit 0.
##   2. run <failing fixture>  → exit 1.
##   3. --jobs 1 and --jobs 2 produce the same verdict.
##   4. --fail-fast with multiple failing entrypoints → non-zero exit.
##   5. --fail-fast with all-passing → exit 0.
##   6. Unknown subcommand → exit 3 (environment error).
##   7. Unknown flag → exit 3.
##   8. --jobs with invalid value → exit 3.
##   9. --jobs with zero → exit 3.
##  10. No args → exit 3.
##  11. No entrypoints matched → exit 3.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_run.nim

import std/[json, monotimes, options, os, strutils, unittest]
import std/posix as posix_mod2
import crisol         # imports runMain
import crisol/types
import crisol/jsonout
import crisol/process/types as ptypes

# rfc-0007 A1d-i: run/v2's `outcome` (and --failed's loadLastRun narrowing,
# which reads it) is sourced from deriveOutcome(r), which walks the real
# compile/run Phase pair -- a fixture must carry a coherent Phase, not just
# the legacy `outcome` field, or every entry silently derives oSpawnError
# (Phase defaults to pkSkipped) and gets treated as failed.
proc okPhase(code: int = 0): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: ptypes.Exit(kind: ptypes.ekExited, code: code),
    cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: ptypes.Evidence(killDomain: ptypes.kdsProcessGroup,
                              tree: ptypes.toUnobservable,
                              hermetic: ptypes.hlIsolated),
    rusage: none(ptypes.Rusage),
    durationUs: 1000,
  ))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  ## Return absolute path to tests/fixtures/ relative to this file's location.
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "crisol CLI — A5 wiring":

  # -------------------------------------------------------------------------
  # Test 1: passing fixture → exit 0
  # -------------------------------------------------------------------------

  test "run with passing entrypoint → exit 0":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1"])
    check code == 0

  # -------------------------------------------------------------------------
  # Test 2: failing fixture → exit 1
  # -------------------------------------------------------------------------

  test "run with failing entrypoint → exit 1":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "fail_always.nim", "--jobs", "1"])
    check code == 1

  # -------------------------------------------------------------------------
  # Test 3: compile-failing fixture → exit 1
  # -------------------------------------------------------------------------

  test "run with compile-failing entrypoint → exit 1":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "fail_compile.nim", "--jobs", "1"])
    check code == 1

  # -------------------------------------------------------------------------
  # Test 4: --jobs 1 vs --jobs 2 — same verdict for passing
  # -------------------------------------------------------------------------

  test "--jobs 1 and --jobs 2 produce same exit 0 for passing fixture":
    let fd = fixtureDir()
    let code1 = runMain(@["run", fd / "pass_always.nim", "--jobs", "1"])
    let code2 = runMain(@["run", fd / "pass_always.nim", "--jobs", "2"])
    check code1 == 0
    check code2 == 0

  test "--jobs 1 and --jobs 2 produce same exit 1 for failing fixture":
    let fd = fixtureDir()
    let code1 = runMain(@["run", fd / "fail_always.nim", "--jobs", "1"])
    let code2 = runMain(@["run", fd / "fail_always.nim", "--jobs", "2"])
    check code1 == 1
    check code2 == 1

  # -------------------------------------------------------------------------
  # Test 5: --fail-fast with multiple failing entrypoints → non-zero exit
  # -------------------------------------------------------------------------

  test "--fail-fast with multiple failing entrypoints → exit 1":
    ## With --jobs 1 (serial) and --fail-fast, only the first entrypoint runs;
    ## the rest are never dispatched.  Exit must be non-zero.
    let fd = fixtureDir()
    let code = runMain(@[
      "run",
      "--fail-fast",
      "--jobs", "1",
      fd / "fail_always.nim",
      fd / "pass_always.nim",  # would pass; should not run under fail-fast
      fd / "fail_compile.nim", # also skipped
    ])
    check code == 1

  # -------------------------------------------------------------------------
  # Test 6: --fail-fast does not affect an all-passing run
  # -------------------------------------------------------------------------

  test "--fail-fast with all passing → exit 0":
    let fd = fixtureDir()
    let code = runMain(@[
      "run",
      "--fail-fast",
      "--jobs", "1",
      fd / "pass_always.nim",
    ])
    check code == 0

  # -------------------------------------------------------------------------
  # Test 7: --fail-fast with mixed: first fails → stops early → exit 1
  # -------------------------------------------------------------------------

  test "--fail-fast mix: passing then failing → exit 1":
    let fd = fixtureDir()
    let code = runMain(@[
      "run",
      "--fail-fast",
      "--jobs", "1",
      fd / "fail_always.nim",
      fd / "pass_always.nim",
    ])
    check code == 1

  # -------------------------------------------------------------------------
  # Test 8: bad usage → exit 3 (environment exit code)
  # -------------------------------------------------------------------------

  test "unknown subcommand → exit 3":
    let code = runMain(@["frobnicate"])
    check code == 3

  test "unknown flag for run → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--no-such-flag"])
    check code == 3

  test "no args → exit 3":
    let code = runMain(@[])
    check code == 3

  test "--jobs with non-integer value → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--jobs", "banana"])
    check code == 3

  test "--jobs with zero → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--jobs", "0"])
    check code == 3

  # -------------------------------------------------------------------------
  # L14: --hermetic <none|isolated|network> level control
  # -------------------------------------------------------------------------

  test "--hermetic none is accepted (passing fixture → exit 0)":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1",
                         "--hermetic", "none"])
    check code == 0

  test "--hermetic isolated is accepted (passing fixture → exit 0)":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--jobs", "1",
                         "--hermetic", "isolated"])
    check code == 0

  test "--hermetic with invalid level → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--hermetic", "banana"])
    check code == 3

  test "--hermetic is not valid for list → exit 3":
    let fd = fixtureDir()
    let code = runMain(@["list", fd / "pass_always.nim", "--hermetic", "none"])
    check code == 3

  # -------------------------------------------------------------------------
  # Test 9: no entrypoints matched → exit 3
  # -------------------------------------------------------------------------

  test "no entrypoints matched → exit 3":
    ## Pass a glob that matches no files in the project tree.
    let code = runMain(@["run", "tests/fixtures/no_such_test_xyzzy_*.nim"])
    check code == 3

  # -------------------------------------------------------------------------
  # Test 10: --timeout flag is accepted and overrides default
  # -------------------------------------------------------------------------

  test "--timeout is accepted and run completes normally":
    let fd = fixtureDir()
    let code = runMain(@["run", fd / "pass_always.nim", "--timeout", "60", "--jobs", "1"])
    check code == 0

  # -------------------------------------------------------------------------
  # Test 11: --help is accepted → exit 0
  # -------------------------------------------------------------------------

  test "--help → exit 0":
    let code = runMain(@["--help"])
    check code == 0

# ---------------------------------------------------------------------------
# Suite 2 — B7: --failed flag
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  getTempDir() / ("crisol_b7_" & tag & "_" & $mono.ticks)

proc makeCfg(projectRoot, stateDir: string): Config =
  Config(
    projectRoot:        projectRoot,
    stateDir:           stateDir,
    groups:             @[],
    jobs:               1,
    timeoutSecs:        30,
    compileTimeoutSecs: 60,
    maxOutputBytes:     65536,
  )

suite "crisol CLI — B7 --failed":

  # -------------------------------------------------------------------------
  # Absent lastrun.json → exit 3
  # -------------------------------------------------------------------------

  test "--failed with absent lastrun.json → exit 3":
    ## loadConfig() roots at getCurrentDir(), so we must ensure that
    ## .crisol/lastrun.json does NOT exist in the cwd during this test.
    ## We move it aside temporarily if it exists, then restore it.
    let realRoot   = getCurrentDir()
    let stateDir   = realRoot / ".crisol"
    let lrPath     = stateDir / "lastrun.json"
    let backupPath = stateDir / "lastrun.json.b7bak"

    let hadFile = fileExists(lrPath)
    if hadFile:
      moveFile(lrPath, backupPath)
    defer:
      if hadFile: moveFile(backupPath, lrPath)
      else: (try: removeFile(lrPath) except: discard)

    let fd   = fixtureDir()
    let code = runMain(@["run", "--failed", fd / "pass_always.nim", "--jobs", "1"])
    check code == 3

  # -------------------------------------------------------------------------
  # --failed + --dry-run: shows narrowed plan (only failed entrypoints)
  # -------------------------------------------------------------------------

  test "--failed + --dry-run: shows only previously-failed entrypoints":
    ## Seed a lastrun.json marking fail_always as failed and pass_always as
    ## passed.  With --dry-run + --failed, only fail_always should appear
    ## in the plan (without actually running anything).
    ##
    ## We use a temp project root and copy the fixture files there so we can
    ## control the state directory independently.  However, loadConfig() roots
    ## at getCurrentDir(); to avoid that ambiguity we test through the
    ## loadLastRun+buildPlanView path directly — but since we want to test
    ## the runMain surface, we seed via persistLastRun and use the dry-run
    ## stdout output to verify narrowing.
    ##
    ## Strategy: write a lastrun.json directly (v1 JSON string) into a temp
    ## stateDir, then call runMain with --dry-run --failed pointing at
    ## the fixture dir.  The loadConfig() will still root at cwd, so we must
    ## use the current project root's .crisol/ dir.
    ##
    ## To keep this non-fragile we write the lastrun.json into the REAL
    ## .crisol/ dir (current project root), then restore it afterward.

    let fd       = fixtureDir()
    let realRoot = fd.parentDir.parentDir  # tests/.. → project root
    let stateDir = realRoot / ".crisol"
    let lrPath   = stateDir / "lastrun.json"

    # Compute root-relative paths for the two fixtures.
    let failRelPath = relativePath(fd / "fail_always.nim", realRoot)
    let passRelPath = relativePath(fd / "pass_always.nim", realRoot)

    # Seed: fail_always failed, pass_always passed.
    let results = @[
      EntrypointResult(
        ep:       Entrypoint(path: failRelPath, group: "paths", flags: @[]), durationMs: 100, records: @[],
        compile: okPhase(), run: okPhase(1)),
      EntrypointResult(
        ep:       Entrypoint(path: passRelPath, group: "paths", flags: @[]), durationMs: 50, records: @[],
        compile: okPhase(), run: okPhase()),
    ]
    let summary = Summary(total: 2, passed: 1, failed: 1)
    let cfg = makeCfg(realRoot, ".crisol")

    # Save old lastrun.json if present, restore on exit.
    var oldContent: string = ""
    let hadOld = fileExists(lrPath)
    if hadOld:
      oldContent = readFile(lrPath)

    persistLastRun(results, summary, cfg)
    defer:
      if hadOld: writeFile(lrPath, oldContent)
      else: (try: removeFile(lrPath) except: discard)

    # --dry-run + --failed: capture stdout, check only fail_always in plan.
    let outPath = getTempDir() / "crisol_b7_dryrun.txt"
    defer: (try: removeFile(outPath) except: discard)

    # We need to capture stdout to inspect the plan output.
    let f = open(outPath, fmWrite)
    let fileFd: cint  = f.getFileHandle.cint
    let savedFd: cint = posix_mod2.dup(1.cint)
    discard posix_mod2.dup2(fileFd, 1.cint)
    f.close()

    let code = runMain(@["run", fd / "fail_always.nim", fd / "pass_always.nim",
                         "--dry-run", "--failed", "--jobs", "1"])

    flushFile(stdout)
    discard posix_mod2.dup2(savedFd, 1.cint)
    discard posix_mod2.close(savedFd)

    check code == 0
    let planText = readFile(outPath)
    # fail_always must appear in the plan; pass_always must NOT.
    check strutils.contains(planText, "fail_always")
    check not strutils.contains(planText, "pass_always")

  # -------------------------------------------------------------------------
  # All previously-failed now gone → exit 0, clear message
  # -------------------------------------------------------------------------

  test "--failed with all previously-failed gone → exit 0":
    ## Seed a lastrun.json marking a non-existent file as failed.
    ## Discovery finds nothing matching that path → narrowed set is empty.
    ## Per RFC exit-code table analogy (--changed zero affected → exit 0),
    ## crisol should exit 0 with a "nothing to re-run" message.

    let fd       = fixtureDir()
    let realRoot = fd.parentDir.parentDir
    let lrPath   = realRoot / ".crisol" / "lastrun.json"

    # Seed: a non-existent entrypoint as failed.
    let results = @[
      EntrypointResult(
        ep:      Entrypoint(path: "tests/fixtures/nonexistent_xyzzy.nim",
                            group: "paths", flags: @[]), durationMs: 10, records: @[],
        compile: okPhase(), run: okPhase(1)),
    ]
    let summary = Summary(total: 1, passed: 0, failed: 1)
    let cfg = makeCfg(realRoot, ".crisol")

    var oldContent = ""
    let hadOld = fileExists(lrPath)
    if hadOld: oldContent = readFile(lrPath)
    persistLastRun(results, summary, cfg)
    defer:
      if hadOld: writeFile(lrPath, oldContent)
      else: (try: removeFile(lrPath) except: discard)

    # We must pass at least one path arg so discovery only scans that area.
    # Pass a path that exists but doesn't contain the seeded (nonexistent) path.
    let code = runMain(@["run", fd / "pass_always.nim", "--failed", "--jobs", "1"])
    check code == 0

# ---------------------------------------------------------------------------
# Suite 3 — the no-entrypoints-matched structural branch still carries the
# plan's config warnings (RunReport.plan must not be dropped on that branch).
# ---------------------------------------------------------------------------

proc uniqueTmpDirD(tag: string): string =
  let mono = getMonoTime()
  getTempDir() / ("crisol_norun_plan_" & tag & "_" & $mono.ticks)

proc writeFD(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc captureStderrToFileD(path: string; body: proc()): void =
  ## Redirect fd 2 (stderr) to `path`, call body(), then restore.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod2.dup(2.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(2) failed")
  discard posix_mod2.dup2(fileFd, 2.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod2.dup2(savedFd, 2.cint)
    discard posix_mod2.close(savedFd)

suite "crisol CLI — no-entrypoints-matched carries plan warnings":

  test "run <nonexistent path> with an unknown config key → exit 3 and stderr still carries the config warning":
    let root = uniqueTmpDirD("cfgwarn")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_a.nim", "doAssert true\n")
    writeFile(root / "crisol.kdl",
      "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n" &
      "bogus-top-level-key \"nope\"\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let errPath = getTempDir() / "crisol_norun_plan_err.txt"
    defer: (try: removeFile(errPath) except: discard)
    var code = 0
    captureStderrToFileD(errPath, proc () =
      code = runMain(@["run", "does/not/exist.nim"]))
    check code == 3
    let err = readFile(errPath)
    check "warning:" in err
    check "bogus-top-level-key" in err

# ---------------------------------------------------------------------------
# A stale-nimVersion depgraph must be a visible, structured diagnostic for
# `run` — reported exactly ONCE on stderr (no double-report between the
# depgraph loader and the caller's ConfigWarning surfacing), and present in
# the run/v1 JSON `warnings` array.
# ---------------------------------------------------------------------------

proc captureStdoutToFileD(path: string; body: proc()): void =
  ## Redirect fd 1 (stdout) to `path`, call body(), then restore.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod2.dup(1.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(1) failed")
  discard posix_mod2.dup2(fileFd, 1.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stdout)
    discard posix_mod2.dup2(savedFd, 1.cint)
    discard posix_mod2.close(savedFd)

suite "crisol CLI — stale depgraph nimVersion is a visible, once-only diagnostic":

  test "run --json after depgraph header nimVersion goes stale → stderr has exactly ONE 'depgraph discarded' line; JSON warnings has key==nimVersion":
    let root = uniqueTmpDirD("depgraph_nimver")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_a.nim", "doAssert true\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # Record a real depgraph first.
    let primeCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the capture blocks below
    check primeCode == 0
    let depgraphPath = root / ".crisol" / "depgraph"
    check fileExists(depgraphPath)

    # Make the recorded nimVersion stale by editing the header in place.
    var doc = parseJson(readFile(depgraphPath))
    doc["header"]["nimVersion"] = newJString("0.0.0-stale")
    writeFile(depgraphPath, $doc)

    let outPath = getTempDir() / "crisol_l2_run_stale.json"
    let errPath = getTempDir() / "crisol_l2_run_stale_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    defer: (try: removeFile(errPath) except: discard)
    var code = 0
    captureStderrToFileD(errPath, proc () =
      captureStdoutToFileD(outPath, proc () =
        code = runMain(@["run", "tests/unit/test_a.nim", "--json"])))
    check code == 0

    # Exactly one report of the discard on stderr (no double-reporting
    # between depgraph.nim's loader and pipeline.nim's ConfigWarning).
    let err = readFile(errPath)
    var occurrences = 0
    for line in err.splitLines:
      if "depgraph discarded" in line:
        inc occurrences
    check occurrences == 1

    let j = parseJson(readFile(outPath).strip())
    check j.hasKey("warnings")
    var found = false
    for w in j["warnings"].items:
      if w["key"].getStr == "nimVersion":
        found = true
    check found

# ---------------------------------------------------------------------------
# A gated group's own NAME can carry untrusted-origin control bytes (config
# file text) — the gate-skip line printed for `run` must sanitize it the same
# way `closure`'s analogous gate-skip line does (see
# test_cli_closure.nim's TAB-in-group-name test for the same fixture shape).
# ---------------------------------------------------------------------------

suite "crisol CLI — gate-skip line sanitizes a control byte in the group name":

  test "run <path> whose only match is gated out, group name containing a TAB byte, renders sanitized on stdout":
    let root = uniqueTmpDirD("gate_tab")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_a.nim", "doAssert true\n")
    writeFile(root / "crisol.kdl", "group \"un\\tit\" {\n" &
      "    globs \"tests/unit/test_*.nim\"\n" &
      "    gate \"CRISOL_CLI_RUN_GATED_TEST_UNSET_XYZ_12345\"\n" &
      "}\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_cli_run_gate_tab_out.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFileD(outPath, proc () =
      code = runMain(@["run", "tests/unit/test_a.nim"]))
    check code == 0

    let outText = readFile(outPath)
    check "skipped group \"un?it\"" in outText   # TAB sanitized to '?'
    check '\t' notin outText
