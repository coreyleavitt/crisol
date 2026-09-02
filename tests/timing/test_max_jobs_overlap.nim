## test_max_jobs_overlap.nim — S3 integration test: per-group max-jobs concurrency cap.
##
## Verifies:
##   1. With max-jobs 1 on a group, two entrypoints in that group do NOT overlap
##      (their wall-time intervals are disjoint — one finishes before the other starts).
##   2. Without max-jobs (uncapped), two entrypoints CAN overlap when run with jobs=2.
##
## The overlap_probe fixture writes {pid}\tstart/end\t{monotonic_ns} lines to a shared
## file (atomic O_APPEND writes).  The harness reads and parses them.
##
## Line format:  "{pid}\t{tag}\t{monotonic_ns}\n"  (tag is "start" or "end")
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/timing/test_max_jobs_overlap.nim

import std/[options, os, sequtils, strutils, tables, tempfiles, times, unittest]
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

proc mkEpInGroup(path: string; groupName: string): Entrypoint =
  Entrypoint(path: path, group: groupName, flags: @[])

type Interval = object
  pid:   int
  start: int64
  fin:   int64

proc parseOverlapFile(path: string): seq[Interval] =
  ## Parse the overlap probe output file into per-PID intervals.
  ## Each line: "{pid}\t{tag}\t{monotonic_ns}"  where tag is "start" or "end".
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

proc intervalsOverlap(a, b: Interval): bool =
  ## Returns true iff the two monotonic intervals [a.start, a.end] and
  ## [b.start, b.end] overlap (i.e. not strictly disjoint).
  a.start < b.fin and b.start < a.fin

proc anyOverlap(intervals: seq[Interval]): bool =
  ## Returns true iff any pair of intervals overlaps.
  for i in 0 ..< intervals.len:
    for j in i+1 ..< intervals.len:
      if intervalsOverlap(intervals[i], intervals[j]):
        return true
  false

proc runWithCap(eps: seq[Entrypoint]; groupName: string;
                maxJobsOpt: Option[int]; jobs: int): seq[Interval] =
  ## Run eps under execute() with the given group config, writing overlap
  ## results to a temp file; parse and return the intervals.
  let (tmp, tmpPath) = createTempFile("crisol_overlap_", ".txt")
  close(tmp)
  defer: removeFile(tmpPath)

  let group = Group(
    name:        groupName,
    globs:       @["tests/fixtures/overlap_probe.nim"],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 0,
    maxJobs:     maxJobsOpt,
  )

  let cfg = Config(
    groups:             @[group],
    jobs:               jobs,
    timeoutSecs:        30,
    compileTimeoutSecs: 60,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    # This suite verifies the per-group max-jobs CAP, not the memory-admission
    # gate.  Since C5 (NSpgid fix) the gate's RSS feedback is real and AUTO mode
    # could intermittently throttle a 2nd slot, suppressing the overlap the
    # "uncapped … DO overlap" test asserts.  Disable mem-aware so the cap
    # behaviour is isolated from the gate.  (test_mem_throttle keeps it on to
    # exercise the gate; test_composition_s7 relies on the gate serialising.)
    memAware:           some(false),
  )

  # Set the env var so the fixture knows where to write.
  putEnv("CRISOL_TEST_OVERLAP_FILE", tmpPath)
  defer: delEnv("CRISOL_TEST_OVERLAP_FILE")

  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  discard execute(p, config = cfg, graph = g, showProgress = false, cache = cacheDisabled(overlapSpec))

  parseOverlapFile(tmpPath)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "S3 — per-group max-jobs concurrency cap":

  test "max-jobs 1: two probes in the same serial group do NOT overlap":
    ## With max-jobs 1, the second probe is not admitted until the first finishes.
    ## Each probe sleeps 150ms, so if they ran concurrently their intervals would
    ## definitely overlap.  With the cap they must be disjoint.
    let fdir = fixtureDir()
    let probe = fdir / "overlap_probe.nim"
    let eps = @[
      mkEpInGroup(probe, "serial"),
      mkEpInGroup(probe, "serial"),
    ]

    let intervals = runWithCap(eps, "serial", some(1), jobs = 2)

    # Both probes must have produced intervals.
    check intervals.len == 2

    # With serial cap, intervals must NOT overlap.
    check not anyOverlap(intervals)

  test "uncapped: two probes in the same group DO overlap with jobs=2":
    ## Without max-jobs the two probes run concurrently (jobs=2).
    ## Each sleeps 150ms — concurrently dispatched, their intervals will overlap.
    let fdir = fixtureDir()
    let probe = fdir / "overlap_probe.nim"
    let eps = @[
      mkEpInGroup(probe, "free"),
      mkEpInGroup(probe, "free"),
    ]

    let intervals = runWithCap(eps, "free", none(int), jobs = 2)

    # Both probes must have produced intervals.
    check intervals.len == 2

    # Without cap, intervals MUST overlap (each sleeps 150ms; total < 300ms).
    check anyOverlap(intervals)

when isMainModule:
  echo "All max-jobs overlap tests passed."
