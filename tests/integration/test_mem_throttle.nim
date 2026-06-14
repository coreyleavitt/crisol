## test_mem_throttle.nim — S6b integration: mem-aware probe + serialization.
##
## Tests:
##   1. (mem-budget-mb 256, safety 0, no group cap): observed concurrency
##      collapses to 1 (interval non-overlap), run still completes.
##
##   2. (mem-aware false, same tiny budget): concurrency returns to jobs=2
##      (intervals overlap), proving the kill switch works.
##
##   3. (Gap 3 / M1): tiny mem-budget-mb forces throttling; execute's
##      memThrottledSlots counter is non-zero, and the JSON output field
##      memThrottledSlots reflects that non-zero value.
##
## Arithmetic (RFC lines 528-532):
##   mem-budget-mb = 256 < 512 MiB built-in estJobPeak seed.
##   safety = 0 (no safetyMb).
##   First slot: liveCount==0 → progress-override → admits.
##   Second slot: avail(256 MiB) - committed(512 MiB) - 0 < 512 MiB → blocked.
##   → exactly serial execution.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_mem_throttle.nim

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import crisol/types
import crisol/runner
import crisol/config
import crisol/jsonout

# ---------------------------------------------------------------------------
# Helpers (shared with test_max_jobs_overlap)
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

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

proc intervalsOverlap(a, b: Interval): bool =
  a.start < b.fin and b.start < a.fin

proc anyOverlap(intervals: seq[Interval]): bool =
  for i in 0 ..< intervals.len:
    for j in i+1 ..< intervals.len:
      if intervalsOverlap(intervals[i], intervals[j]):
        return true
  false

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "default", flags: @[])

proc runWithMemConfig(eps: seq[Entrypoint];
                      memBudgetMb: Option[int];
                      memAware: Option[bool];
                      jobs: int): seq[Interval] =
  ## Run eps under execute() with the given memory config,
  ## writing overlap results to a temp file; parse and return intervals.
  let (tmp, tmpPath) = createTempFile("crisol_memoverlap_", ".txt")
  close(tmp)
  defer: removeFile(tmpPath)

  # No group cap — testing memory gate only.
  let cfg = Config(
    groups:             @[],
    jobs:               jobs,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    memBudgetMb:        memBudgetMb,
    memAware:           memAware,
  )

  putEnv("CRISOL_TEST_OVERLAP_FILE", tmpPath)
  defer: delEnv("CRISOL_TEST_OVERLAP_FILE")

  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  discard execute(p, config = cfg, graph = g, showProgress = false)

  parseOverlapFile(tmpPath)

proc runWithMemConfigThrottled(eps: seq[Entrypoint];
                               memBudgetMb: Option[int];
                               memAware: Option[bool];
                               jobs: int;
                               throttledOut: var int): seq[EntrypointResult] =
  ## Run eps under execute() with the given memory config.
  ## Writes ac.memThrottledSlots into throttledOut via the memThrottledOut seam.
  let cfg = Config(
    groups:             @[],
    jobs:               jobs,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    memBudgetMb:        memBudgetMb,
    memAware:           memAware,
  )
  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  result = execute(p, config = cfg, graph = g, showProgress = false,
                   memThrottledOut = addr throttledOut)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "S6b — mem-aware probe: serialization via tiny mem-budget-mb":

  test "mem-budget-mb 256 (< 512 MiB seed): two probes serialize (non-overlap)":
    ## With mem-budget-mb=256 (below the 512 MiB estJobPeak seed) and safety=0:
    ## - First slot: liveCount==0 → progress-override → admits.
    ## - Second slot: avail(256 MiB) - committed(512 MiB) < 512 MiB → blocked.
    ## → Only one probe runs at a time → intervals must NOT overlap.
    let fdir = fixtureDir()
    let probe = fdir / "overlap_probe.nim"
    let eps = @[mkEp(probe), mkEp(probe)]

    let intervals = runWithMemConfig(eps, memBudgetMb = some(256),
                                     memAware = none(bool), jobs = 2)

    check intervals.len == 2
    check not anyOverlap(intervals)

  test "mem-aware false: same tiny budget, probes overlap (kill switch works)":
    ## With mem-aware=false, the memory gate is inert regardless of mem-budget-mb.
    ## Two probes with jobs=2 run concurrently → intervals MUST overlap.
    let fdir = fixtureDir()
    let probe = fdir / "overlap_probe.nim"
    let eps = @[mkEp(probe), mkEp(probe)]

    let intervals = runWithMemConfig(eps, memBudgetMb = some(256),
                                     memAware = some(false), jobs = 2)

    check intervals.len == 2
    check anyOverlap(intervals)  # probe inert → concurrent → overlap

  # -------------------------------------------------------------------------
  # Gap 3 / M1: memThrottledSlots end-to-end
  # -------------------------------------------------------------------------
  #
  # Verify that a run throttled by mem-budget-mb produces a non-zero
  # memThrottledSlots counter (via the memThrottledOut seam) AND that the JSON
  # output produced by toJsonString reflects that non-zero value.
  #
  # Arithmetic: mem-budget-mb=256 < 512 MiB estJobPeak seed.
  #   - Slot 1: liveCount==0 → progress-override → admitted (memThrottledSlots unchanged).
  #   - Slot 2: liveCount==1, avail(256 MiB) - committed(512 MiB) < 512 MiB → blocked
  #     → memThrottledSlots incremented.
  # So with two entrypoints and jobs=2, memThrottledSlots >= 1 after the run.
  #
  # Non-vacuity proof: with mem-aware=false (kill switch), the gate is inert,
  # memThrottledSlots stays 0, and the JSON field reflects 0 — verifying the
  # "would be 0 if throttling didn't fire" baseline.

  test "Gap 3: memThrottledSlots > 0 in counter and JSON when gate throttles":
    ## mem-budget-mb=256 with jobs=2 and 2 entrypoints forces the second slot
    ## to be memory-blocked (mem-throttled) at least once → counter > 0.
    ## The JSON memThrottledSlots field must carry that non-zero value.
    ##
    ## Uses pass_always.nim (instant exit) so no CRISOL_TEST_OVERLAP_FILE env
    ## setup is needed.  The budget constraint still fires: with mem-budget-mb=256
    ## and estJobPeak=512 MiB, the second entrypoint is memory-blocked on every
    ## fill pass until the first finishes (liveCount > 0 → no override).
    let fdir  = fixtureDir()
    let probe = fdir / "pass_always.nim"
    let eps   = @[mkEp(probe), mkEp(probe)]

    var throttled = 0
    let results = runWithMemConfigThrottled(eps,
                                            memBudgetMb  = some(256),
                                            memAware     = none(bool),
                                            jobs         = 2,
                                            throttledOut = throttled)
    # Both entrypoints must complete successfully.
    check results.len == 2
    for r in results:
      check r.outcome == oPassed

    # The memory gate must have blocked the second slot at least once.
    check throttled > 0

    # The JSON output must carry the non-zero count.
    let summary = summarize(results)
    let jsonStr = toJsonString(results, summary, memThrottledSlots = throttled)
    let parsed  = parseJson(jsonStr)
    check parsed.hasKey("memThrottledSlots")
    check parsed["memThrottledSlots"].getInt > 0
    ## Non-vacuity: with mem-aware=false (kill switch) the counter stays 0
    ## and the JSON field reflects 0 — confirmed by the baseline test below.

  test "Gap 3 baseline: memThrottledSlots == 0 when kill switch disables gate":
    ## With mem-aware=false, the memory gate is inert → no throttling → counter=0.
    ## Proves the Gap 3 test would fail if throttling didn't fire.
    let fdir  = fixtureDir()
    let probe = fdir / "pass_always.nim"
    let eps   = @[mkEp(probe), mkEp(probe)]

    var throttled = 0
    let results = runWithMemConfigThrottled(eps,
                                            memBudgetMb  = some(256),
                                            memAware     = some(false),
                                            jobs         = 2,
                                            throttledOut = throttled)
    check results.len == 2
    for r in results:
      check r.outcome == oPassed
    check throttled == 0  # kill switch → gate inert → no throttle events

    let summary = summarize(results)
    let jsonStr = toJsonString(results, summary, memThrottledSlots = throttled)
    let parsed  = parseJson(jsonStr)
    check parsed["memThrottledSlots"].getInt == 0

when isMainModule:
  echo "S6b mem-throttle tests done."
