## test_rfc0007_r66_spawn_failure_quarantine.nim — code-review r66 (Medium):
## the fill-pass spawn-failure blocks (runner.nim, the two `if not ok:` arms
## right after `spawnRunDirect`/`spawnCompileStable` inside `execute`'s main
## dispatch loop) used to hand-roll their own finalization — unconditional
## `anyFailed = true`, no `decideExit`, no `isQuarantined` overlay — while
## the IDENTICAL failure reaching `fkDone` (the live-completion path) got
## the quarantine downgrade. Same event class (a genuine oSpawnError), two
## policies.
##
## Concretely: `results[i].quarantined` was simply never set for a fill-pass
## spawn failure — it stayed the zero-value `false` — so a path-quarantined
## entrypoint whose spawn genuinely fails (fork/file-open failure BEFORE any
## process ever existed) was still counted as a real failure by
## `summarize()`'s exit-1 buckets, breaking quarantine's whole-binary path
## rule (B3) for exactly the process class B3 exists to cover (an opaque,
## record-less failure with no rsFail records to even consult B4 against).
##
## Strategy: force a REAL, deterministic spawn failure without touching
## process/* — point $TMPDIR at a path that exists but is a plain FILE, not
## a directory. `spawnCompileStable`'s own `makeTmpDir("crisol_slot_")` call
## (its per-slot scratch dir for compOut/runOut/sinkFile) resolves against
## `getTempDir()` and fails with ENOTDIR before `nim` is ever spawned —
## exactly the "fork or file-open failed before compile" arm this finding
## names. Single entrypoint, `config.quarantineTp` set to its own `tp` (the
## B3 whole-binary path rule, matching exactly what `config.nim`'s
## `classify`-driven resolution would produce for a `quarantine "<path>"`
## entry), `jobs=1` — no concurrency, no parallel-scheduling nondeterminism.
##
## Assert (RED before the fix): `results[0].quarantined == true` and
## `summarize(results).exitCode == 0` — the failure is downgraded, not
## flipped into a run failure, matching the fkDone arm's behavior for the
## exact same B3 rule.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r66_spawn_failure_quarantine.nim

import std/[os, sets, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner
import "../support/testep"

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  thisFile.parentDir.parentDir / "fixtures"

suite "rfc-0007 code-review r66 — fill-pass spawn failure respects the quarantine overlay":

  test "a path-quarantined entrypoint whose spawn genuinely fails is NOT flipped into a run failure":
    let fdir = fixtureDir()
    let ep   = testEp((fdir / "pass_fast.nim").relativePath(getCurrentDir()),
                      group = "test", flags = @[])

    # Break $TMPDIR: point it at a plain FILE (not a directory), so any
    # `createTempDir(..., dir = getTempDir())` call fails deterministically
    # with ENOTDIR — a real, injected spawn failure, no process/* changes.
    let bogusTmpFile = getTempDir() / ("crisol_r66_bogus_tmp_" & $getCurrentProcessId())
    writeFile(bogusTmpFile, "not a directory")
    defer: (try: removeFile(bogusTmpFile) except: discard)
    let savedTmpDir = getEnv("TMPDIR")
    putEnv("TMPDIR", bogusTmpFile)
    defer: putEnv("TMPDIR", savedTmpDir)

    var cfg = Config(
      jobs:               1,
      compileTimeoutSecs: 30,
      timeoutSecs:        30,
      projectRoot:        getCurrentDir(),
      trackedRoots:       initTrackedRoots(getCurrentDir(), newSeq[tuple[name, native: string]](), ""),
      quarantineTp:       toHashSet([ep.tp]),  # B3: whole-binary path rule
    )

    let p = plan(cfg, @[ep], emptyDepGraph())
    var g = emptyDepGraph()
    let execReport = execute(p, config = cfg, graph = g, onResult = noopResult,
                             showProgress = false, progressIntervalMs = 30_000)
    let results = execReport.results

    check results.len == 1
    if results.len == 1:
      # Sanity: this really is the injected spawn failure, not some other
      # outcome the TMPDIR trick failed to trigger.
      check outcome(results[0]) == oSpawnError
      # r66: the quarantine overlay must be applied on THIS path exactly
      # like the fkDone path applies it.
      check results[0].quarantined == true

    let s = summarize(results)
    check s.spawnErrors == 0     # downgraded out of the exit-contributing bucket
    check s.quarantined == 1
    check exitCode(s) == 0       # parity with the fkDone arm: quarantined failure, exit 0

  test "a NON-quarantined entrypoint whose spawn fails still counts as a real failure":
    ## Regression guard on r66's fix: routing the fill-pass spawn-failure
    ## finalize through `decideExit`/`isQuarantined` must not accidentally
    ## soften the ordinary (non-quarantined) case — the whole point is
    ## PARITY with fkDone, not a blanket downgrade.
    let fdir = fixtureDir()
    let ep   = testEp((fdir / "pass_fast.nim").relativePath(getCurrentDir()),
                      group = "test", flags = @[])

    let bogusTmpFile = getTempDir() / ("crisol_r66_bogus_tmp2_" & $getCurrentProcessId())
    writeFile(bogusTmpFile, "not a directory")
    defer: (try: removeFile(bogusTmpFile) except: discard)
    let savedTmpDir = getEnv("TMPDIR")
    putEnv("TMPDIR", bogusTmpFile)
    defer: putEnv("TMPDIR", savedTmpDir)

    let cfg = Config(
      jobs:               1,
      compileTimeoutSecs: 30,
      timeoutSecs:        30,
      projectRoot:        getCurrentDir(),
      trackedRoots:       initTrackedRoots(getCurrentDir(), newSeq[tuple[name, native: string]](), ""),
      # quarantineTp deliberately empty — this entrypoint is NOT quarantined.
    )

    let p = plan(cfg, @[ep], emptyDepGraph())
    var g = emptyDepGraph()
    let execReport = execute(p, config = cfg, graph = g, onResult = noopResult,
                             showProgress = false, progressIntervalMs = 30_000)
    let results = execReport.results

    check results.len == 1
    if results.len == 1:
      check outcome(results[0]) == oSpawnError
      check results[0].quarantined == false

    let s = summarize(results)
    check s.spawnErrors == 1
    check s.quarantined == 0
    check exitCode(s) == 1
