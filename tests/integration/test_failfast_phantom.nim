## test_failfast_phantom.nim — H1 regression: phantom entry in fail-fast early-exit.
##
## With skip-ahead dispatch (H1 fix), dispatched indices may be non-contiguous.
## Example: plan = [capped0(serial), capped1(serial), uncapped(free)], jobs=2.
##
## Pass 1 dispatch:
##   Slot 0 admits capped0 (serial group inflight=1).
##   Slot 1 scans: capped1 is blocked (serial at cap), skips to uncapped → admitted.
##   dispatched = [true, false, true], highWaterMark = 3.
##
## capped0 is fail_always → exits 1 → anyFailed = true.
## uncapped completes; no slots live; fail-fast early-exit fires.
##
## BUG: result[0..<highWaterMark] = result[0..<3] includes result[1] which was
##   NEVER dispatched. result[1] is a default-zero EntrypointResult with an empty
##   ep.path — a phantom entry that leaks into summarize/output.
##
## FIX: iterate dispatched[] and collect only ran entries.
##
## This test asserts: every returned EntrypointResult has a non-empty ep.path,
## and the result length equals the number of actually-dispatched entries (2).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_failfast_phantom.nim

import std/[options, os, sequtils, unittest]
import crisol/types
import crisol/runner
import crisol/config

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEpInGroup(path, groupName: string): Entrypoint =
  Entrypoint(path: path, group: groupName, flags: @[])

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "H1/fail-fast — no phantom entry under non-contiguous dispatch":

  test "fail-fast early-exit omits never-dispatched entries (non-contiguous dispatch)":
    ## Plan: [fail_always(serial), pass_always(serial), pass_always(free)]
    ##   - serial group: max-jobs=1.
    ##   - jobs=2 so two slots fill simultaneously.
    ##
    ## Expected dispatch with skip-ahead:
    ##   Slot 0: admits fail_always (serial, idx 0); serial inflight=1.
    ##   Slot 1: capped at serial cap → skips idx 1 → admits pass_always(free) at idx 2.
    ##   dispatched = [true, false, true], highWaterMark = 3.
    ##
    ## fail_always (idx 0) exits 1 → anyFailed = true.
    ## pass_always (idx 2) exits 0.
    ## No slots live → fail-fast early-exit.
    ##
    ## BUG: result[0..<3] contains a phantom at idx 1 (empty ep.path).
    ## FIX: result contains exactly the 2 dispatched entries; all have non-empty paths.

    let fdir = fixtureDir()
    let failFix = fdir / "fail_always.nim"
    let passFix = fdir / "pass_always.nim"

    let serialGroup = Group(
      name:        "serial",
      globs:       @[],
      flags:       @[],
      optIn:       false,
      gate:        none(Gate),
      timeoutSecs: 0,
      maxJobs:     some(1),   # serial cap: only 1 inflight at a time
    )
    let freeGroup = Group(
      name:        "free",
      globs:       @[],
      flags:       @[],
      optIn:       false,
      gate:        none(Gate),
      timeoutSecs: 0,
      maxJobs:     none(int),  # uncapped
    )

    let cfg = Config(
      groups:             @[serialGroup, freeGroup],
      jobs:               2,                    # 2 slots → skip-ahead can fire
      timeoutSecs:        30,
      compileTimeoutSecs: 120,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        getCurrentDir(),
      memAware:           some(false),          # disable mem gate for determinism
    )

    # Plan order:
    #   idx 0: fail_always in "serial" → will fail, triggering fail-fast
    #   idx 1: pass_always in "serial" → cap-blocked; should NEVER be dispatched
    #   idx 2: pass_always in "free"   → uncapped; skip-ahead dispatches this
    let eps = @[
      mkEpInGroup(failFix, "serial"),   # idx 0: fails → anyFailed
      mkEpInGroup(passFix, "serial"),   # idx 1: blocked by cap; never dispatched
      mkEpInGroup(passFix, "free"),     # idx 2: skip-ahead admits this
    ]

    let p = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g,
                          failFast = true, showProgress = false)

    # --- Core assertion: no phantom entries ---
    # Every returned result must correspond to an entry that actually ran.
    # A phantom entry has an empty ep.path (default-zero EntrypointResult).
    for r in results:
      check r.ep.path.len > 0

    # Exactly 2 entries were dispatched (idx 0 and idx 2); idx 1 was never dispatched.
    # BUG: this was 3 (included the phantom at idx 1).
    check results.len == 2

    # The failure must be present.
    let failCount = results.filterIt(it.outcome.isFailure).len
    check failCount >= 1

when isMainModule:
  echo "Fail-fast phantom entry regression test done."
