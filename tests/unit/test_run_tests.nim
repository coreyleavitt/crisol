## test_run_tests.nim — boundary tests for runTests() (S2a–S2d, F1).
##
## Tests observable behavior through the public crisol/api surface only.
## No internal call sequences; end-to-end SIGINT/SIGTERM-through-execute()
## behavior is covered by the existing test_signal.nim integration suite.
## The one S2d test that forks and signals itself does so ONLY to exercise
## `crisol/signals.shutdownRequested()`'s process-global isolation from a
## fresh runTests() call (rfc-0007 A4) — real signal delivery stays
## confined to that forked child so this file's other tests never observe
## process-global signal state.
##
## Covers (S2a):
##   - runTests happy path: all-pass fixture → rsOk, exitCode 0, populated results + settings
##   - summary.passed == number of entrypoints, summary.failed == 0
##   - plan.settings is correctly populated on RunReport
##
## Covers (S2b):
##   - failing fixture → exitCode 1, status still rsOk (failure is a result, not structural)
##   - onResult callback fires once per entrypoint
##   - failFast:true → first failure stops dispatch; remaining skipped (results.len < plan.entrypoints.len)
##
## Covers (S2c):
##   - bad configPath → rsStructural, exitCode 3, error non-empty, does NOT raise
##   - no entrypoints matched (empty discovery, bad globs) → rsStructural, exitCode 3
##   - changed-clean-tree (zero runnable, useChanged) → rsOk, exitCode 0
##   - failed-none-matched (zero runnable, useFailed, prior run has no failures) → rsOk, exitCode 0
##   - all-gated-out (zero runnable due to gates) → rsOk, exitCode 0
##
## Covers (S2d):
##   - manageLock:false skips lock entirely (runs without a state dir)
##   - memThrottledSlots surfaced on RunReport (0 when mem-aware off)
##   - rfc-0007 A4: a STALE `shutdownRequested()` (some OTHER
##     installSignals=true Supervisor in this process saw a signal earlier)
##     does NOT interrupt a later runTests(installSignals:false) call —
##     each execute() call owns its OWN fresh Supervisor/pendingShutdown
##     queue (A2b), so the process-global sticky flag `signals.nim` exposes
##     is never consulted by interrupted-detection.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_run_tests.nim

import std/[options, os, osproc, posix, strutils, unittest]
import crisol/api
import crisol/types
import crisol/signals
import crisol/process

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

# Helper: import the test support module
import "../support/helpers"

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc writePassFixture(dir: string; name: string) =
  ## Write a trivially-passing Nim entrypoint.
  createDir(dir)
  writeFile(dir / name, "quit(0)\n")

proc writeFailFixture(dir: string; name: string) =
  ## Write a trivially-failing Nim entrypoint.
  createDir(dir)
  writeFile(dir / name, "quit(1)\n")

# ---------------------------------------------------------------------------
# S2a — happy path
# ---------------------------------------------------------------------------

suite "runTests — S2a happy path":

  test "all-pass suite → rsOk, exitCode 0":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath:   projectRoot / "crisol.kdl",
        manageLock:   true,
        installSignals: false,
        persist:      false,   # avoid writing to temp dir
      )
      let rr = runTests(opts)
      check rr.status   == rsOk
      check rr.exitCode == 0

  test "all-pass suite → summary.passed == 1, summary.failed == 0":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath:   projectRoot / "crisol.kdl",
        persist:      false,
      )
      let rr = runTests(opts)
      check rr.summary.total  == 1
      check rr.summary.passed == 1
      check rr.summary.failed == 0

  test "all-pass suite → results seq has one oPassed entry":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check rr.results.len == 1
      check rr.results[0].outcome == oPassed

  test "plan.settings.projectRoot is populated on RunReport":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check rr.plan.settings.projectRoot == projectRoot

  test "plan.settings.stateDir is absolute on RunReport":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check isAbsolute(rr.plan.settings.stateDir)

  test "plan.entrypoints reflects what was planned":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check rr.plan.entrypoints.len == 1

# ---------------------------------------------------------------------------
# S2b — failure + callback + failFast
# ---------------------------------------------------------------------------

suite "runTests — S2b failure + callback + failFast":

  test "failing fixture → exitCode 1, status rsOk":
    withTempProject:
      writeFailFixture(projectRoot / "tests" / "unit", "test_fail.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check rr.status   == rsOk
      check rr.exitCode == 1

  test "onResult callback fires once per entrypoint":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass1.nim")
      writePassFixture(projectRoot / "tests" / "unit", "test_pass2.nim")
      var callCount = 0
      proc countCb(r: EntrypointResult) = inc callCount
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
        onResult:   countCb,
      )
      let rr = runTests(opts)
      check rr.status == rsOk
      check callCount == 2

  test "onResult fires even for failing entrypoints":
    withTempProject:
      writeFailFixture(projectRoot / "tests" / "unit", "test_fail.nim")
      var sawFail = false
      proc failCb(r: EntrypointResult) =
        if r.outcome == oFailed: sawFail = true
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
        onResult:   failCb,
      )
      let rr = runTests(opts)
      check sawFail

  test "failFast:true → results.len < plan.entrypoints.len after first failure":
    ## With failFast, after the first failure no new entrypoints are dispatched.
    ## We use 3 failing entrypoints: failFast should stop before all 3 finish.
    ## (In-flight entrypoints drain, so the count may be 1 or 2, but < 3.)
    withTempProject:
      writeFailFixture(projectRoot / "tests" / "unit", "test_fail1.nim")
      writeFailFixture(projectRoot / "tests" / "unit", "test_fail2.nim")
      writeFailFixture(projectRoot / "tests" / "unit", "test_fail3.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
        failFast:   true,
        jobs:       1,   # serial so failFast halts after exactly 1
      )
      let rr = runTests(opts)
      check rr.status   == rsOk
      check rr.exitCode == 1
      # With jobs:1 and failFast:true, exactly 1 entrypoint runs.
      check rr.results.len < rr.plan.entrypoints.len
      check rr.results.len == 1

# ---------------------------------------------------------------------------
# S2c — catch-and-encode + zero-runnable mapping
# ---------------------------------------------------------------------------

suite "runTests — S2c structural + zero-runnable":

  test "bad configPath → rsStructural, exitCode 3, error non-empty, does NOT raise":
    var raised = false
    var rr: RunReport
    try:
      rr = runTests(RunOptions(configPath: "/nonexistent/path/crisol.kdl"))
    except:
      raised = true
    check not raised
    check rr.status   == rsStructural
    check rr.exitCode == 3
    check rr.error.len > 0

  test "no entrypoints matched (bad globs / empty discovery) → rsStructural, exitCode 3":
    withTempProject:
      # The minimal config globs tests/unit/test_*.nim — no files there → no match.
      # An EMPTY discovery (no files at all) maps to rsStructural per the RFC table.
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      # No fixture files written → empty discovery
      let rr = runTests(opts)
      check rr.status   == rsStructural
      check rr.exitCode == 3
      check rr.error.len > 0

  test "changed-clean-tree → rsOk, exitCode 0":
    ## When narrowing is changedOnly and the tree is clean (empty diff),
    ## runnable == 0 with useChanged → rsOk, exit 0.
    withTempGitProject:
      let testA = gitRoot / "tests" / "unit" / "test_a.nim"
      writeFile(testA, "quit(0)\n")
      discard execCmdEx("git add -A", workingDir = gitRoot)
      discard execCmdEx("git commit -m init", workingDir = gitRoot)
      # Tree is now clean — changedFiles returns empty → runnable == 0.
      let opts = RunOptions(
        configPath: gitRoot / "crisol.kdl",
        narrowing:  changedOnly(),
        persist:    false,
      )
      var raised = false
      var rr: RunReport
      try:
        rr = runTests(opts)
      except:
        raised = true
      check not raised
      check rr.status   == rsOk
      check rr.exitCode == 0

  test "failed-none-matched (prior run all-passed) → rsOk, exitCode 0":
    ## When narrowing is failedOnly and the prior run had no failures,
    ## failedKeys is empty → runnable == 0 → rsOk, exit 0.
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      # Seed: everything passed.
      let results = @[EntrypointResult(
        ep:      Entrypoint(path: "tests/unit/test_pass.nim", group: "unit"), compile: okPhase(), run: okPhase())]
      seedLastRun(projectRoot, results, Summary(total: 1, passed: 1))
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        narrowing:  failedOnly(),
        persist:    false,
      )
      var raised = false
      var rr: RunReport
      try:
        rr = runTests(opts)
      except:
        raised = true
      check not raised
      check rr.status   == rsOk
      check rr.exitCode == 0

  test "all-gated-out → rsOk, exitCode 0":
    ## Use a group with a gate that always fails → gatedOut non-empty, runnable == 0.
    withTempProject:
      # Write a config with a gate that references a non-existent file (gate = file must exist).
      let gatedKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
    gate "nonexistent-command-xyz-12345"
}
"""
      writeFile(projectRoot / "crisol.kdl", gatedKdl)
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      var raised = false
      var rr: RunReport
      try:
        rr = runTests(opts)
      except:
        raised = true
      check not raised
      # Gated-out with no runnable entrypoints → rsOk, exitCode 0
      check rr.status   == rsOk
      check rr.exitCode == 0

  test "structural error does NOT populate results":
    var rr: RunReport
    try:
      rr = runTests(RunOptions(configPath: "/nonexistent/path/crisol.kdl"))
    except:
      discard
    check rr.results.len == 0

# ---------------------------------------------------------------------------
# S2d — manageLock + memThrottledSlots + stale shutdownRequested()
# ---------------------------------------------------------------------------

suite "runTests — S2d lock lifecycle + shutdownRequested isolation + memThrottledSlots":

  test "manageLock:false skips lock — runs successfully without state dir lock":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath:  projectRoot / "crisol.kdl",
        manageLock:  false,
        persist:     false,
      )
      let rr = runTests(opts)
      check rr.status   == rsOk
      check rr.exitCode == 0

  test "memThrottledSlots is 0 on a normal run (mem-aware disabled by default)":
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        persist:    false,
      )
      let rr = runTests(opts)
      check rr.memThrottledSlots == 0

  test "rfc-0007 A4: a stale process-global shutdownRequested() does NOT interrupt a fresh runTests call":
    ## Real signal delivery happens in a FORKED child so the process-global
    ## flag `crisol/signals` reads is never mutated in the test runner's own
    ## process. Inside the child: install a Supervisor with
    ## installSignals=true and self-signal SIGTERM (so shutdownRequested()
    ## goes `some` — simulating "some earlier Supervisor elsewhere in this
    ## process saw a shutdown signal"), THEN run runTests(installSignals:
    ## false) in that SAME process. If the stale global leaked into the new
    ## call's interrupted-detection, this run would report rsInterrupted;
    ## it must not, because each execute() call owns its own fresh
    ## Supervisor/pendingShutdown queue (A2b) — shutdownRequested()'s
    ## global is a separate, sticky, read-only mirror, never consulted by
    ## the poll loop.
    withTempProject:
      writePassFixture(projectRoot / "tests" / "unit", "test_pass.nim")
      let resultFile = projectRoot / "a4_result.txt"

      let childPid = fork()
      if childPid == 0:
        var sv = initSupervisor(installSignals = true)
        discard sv   # keep the handler installed for the life of this child
        discard kill(getpid(), SIGTERM)
        var waited = 0
        while shutdownRequested().isNone and waited < 2000:
          os.sleep(10)
          waited += 10
        let sawStale = shutdownRequested().isSome

        let opts = RunOptions(
          configPath:     projectRoot / "crisol.kdl",
          installSignals: false,
          persist:        false,
        )
        let rr = runTests(opts)
        let outcome = (if sawStale: "1" else: "0") & "," &
                      (if rr.status == rsOk: "1" else: "0") & "," & $rr.exitCode
        writeFile(resultFile, outcome)
        quit(0)
      else:
        var ws: cint = 0
        discard waitpid(childPid, ws, 0)
        check fileExists(resultFile)
        let parts = readFile(resultFile).strip().split(',')
        check parts[0] == "1"   # the stale global really was observed
        check parts[1] == "1"   # rr.status == rsOk (not rsInterrupted)
        check parts[2] == "0"   # rr.exitCode == 0
