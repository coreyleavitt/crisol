## test_headofline.nim — H1 regression: head-of-line blocking.
##
## Verifies that a max-jobs-1 capped group entry sitting FIRST in plan order
## does NOT serialise entries from uncapped groups.
##
## Plan order: [capA1(serial), capA2(serial), free1(open), free2(open)]
## serial group max-jobs=1; open group uncapped; jobs=2.
##
## Under the BUG (monotone nextEp cursor), with jobs=2:
##   Pass 1: slot 0 admits capA1 (nextEp→1, serial inflight=1).
##           Slot 1 tries capA2 → serial at cap → BLOCKED; nextEp stays at 1.
##           free1 and free2 starve until capA1 drains the serial cap.
##   After capA1 finishes: capA2 admitted. After capA2 finishes: free1, then
##   in the next pass free2. Total runtime ≈ 3 × 150ms = 450ms.
##
## Under the FIX (scan-ahead):
##   Pass 1: slot 0 admits capA1.
##           Slot 1 scans past blocked capA2 → admits free1.
##   After ~150ms (capA1 and free1 finish): capA2 admitted (slot 0), free2 admitted (slot 1).
##   capA2 and free2 run concurrently. Total ≈ 2 × 150ms = 300ms.
##
## Threshold 380ms: safely above fix (≈300ms), below bug minimum (450ms).
##
## Two-phase structure:
##   Phase 1 — warm run: compiles the binary (same source for all 4 eps).
##   Phase 2 — measured run: all cdSkipFresh; pure 150ms sleeps, no compile overhead.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_headofline.nim

import std/[options, os, strutils, tables, tempfiles, times, unittest]
import crisol/types
import crisol/runner
import crisol/sandbox

# A6: live run path is hermetic by default; allowlist the probe var.
let overlapSpec = resolveSandbox(passthroughs = @["CRISOL_TEST_OVERLAP_FILE"])

import crisol/config

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string; groupName: string): Entrypoint =
  Entrypoint(path: path, group: groupName, flags: @[])

type Interval = object
  pid:   int
  start: int64
  fin:   int64

proc parseOverlapFile(path: string): seq[Interval] =
  var starts: Table[int, int64]
  var ends:   Table[int, int64]
  for rawLine in lines(path):
    let line = rawLine.strip()
    if line.len == 0: continue
    let parts = line.split('\t')
    if parts.len != 3: continue
    let pid = parseInt(parts[0])
    let tag = parts[1]
    let ns  = parseBiggestInt(parts[2])
    if tag == "start":
      starts[pid] = ns
    elif tag == "end":
      ends[pid] = ns
  for pid, s in starts:
    if pid in ends:
      result.add Interval(pid: pid, start: s, fin: ends[pid])

proc makeConfig(jobs: int): Config =
  let serialGroup = Group(
    name:        "serial",
    globs:       @["tests/fixtures/overlap_probe.nim"],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 0,
    maxJobs:     some(1),
  )
  let openGroup = Group(
    name:        "open",
    globs:       @["tests/fixtures/overlap_probe.nim"],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 0,
    maxJobs:     none(int),
  )
  Config(
    groups:             @[serialGroup, openGroup],
    jobs:               jobs,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
  )

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "H1 — head-of-line blocking regression":

  test "uncapped entries skip ahead past a capped-group head with jobs=2":
    ## Plan: [capA1(serial), capA2(serial), free1(open), free2(open)], jobs=2.
    ##
    ## Phase 1 warms the binary cache (one compilation for the shared source).
    ## Phase 2 is cdSkipFresh for all four — timing is pure 150ms sleeps.
    ##
    ## Bug path (cursor stuck at capA2):
    ##   capA1 runs alone (150ms), then capA2 runs alone (150ms),
    ##   then free1+free2 run concurrently (150ms). Total ≥ 450ms.
    ##
    ## Fix path (scan-ahead):
    ##   capA1||free1 run concurrently (150ms),
    ##   then capA2||free2 run concurrently (150ms). Total ≈ 300ms.
    ##
    ## Threshold 380ms is above the fix ceiling and below the bug floor.
    let fdir  = fixtureDir()
    let probe = fdir / "overlap_probe.nim"

    let eps = @[
      mkEp(probe, "serial"),  # 0 — capped; admitted first into slot 0
      mkEp(probe, "serial"),  # 1 — capped; blocked in pass 1 (cap=1 full)
      mkEp(probe, "open"),    # 2 — uncapped; should be skipped to in pass 1
      mkEp(probe, "open"),    # 3 — uncapped
    ]

    let cfg = makeConfig(jobs = 2)

    # --- Phase 1: warm ---
    let (tmp1, path1) = createTempFile("crisol_hol1_", ".txt")
    close(tmp1)
    defer: removeFile(path1)

    putEnv("CRISOL_TEST_OVERLAP_FILE", path1)
    let p1 = plan(cfg, eps, emptyDepGraph())
    var g1 = emptyDepGraph()
    discard execute(p1, config = cfg, graph = g1, showProgress = false, cache = cacheDisabled(overlapSpec))
    delEnv("CRISOL_TEST_OVERLAP_FILE")

    let warm = parseOverlapFile(path1)
    check warm.len == 4

    # --- Phase 2: measure ---
    let (tmp2, path2) = createTempFile("crisol_hol2_", ".txt")
    close(tmp2)
    defer: removeFile(path2)

    putEnv("CRISOL_TEST_OVERLAP_FILE", path2)
    let p2 = plan(cfg, eps, g1)   # all cdSkipFresh now
    var g2 = g1
    let t0 = epochTime()
    discard execute(p2, config = cfg, graph = g2, showProgress = false, cache = cacheDisabled(overlapSpec))
    let elapsedMs = int64((epochTime() - t0) * 1000)
    delEnv("CRISOL_TEST_OVERLAP_FILE")

    let cached = parseOverlapFile(path2)
    check cached.len == 4

    # Fix ≈ 300ms; bug ≥ 450ms; threshold 380ms.
    const thresholdMs = 380
    check elapsedMs < thresholdMs

when isMainModule:
  echo "Head-of-line blocking regression test passed."
