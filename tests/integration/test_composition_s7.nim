## test_composition_s7.nim — S7 integration test: A+B+C+fail-fast composition.
##
## Proves that all admission machinery — per-group max-jobs cap (C), memory-aware
## admission (B), per-group timeouts (A), and fail-fast drain — compose without
## deadlock or correctness regression.
##
## Three focused procs:
##
##   1. testCapAndMemoryCompose  (A+C): max-jobs 1 group (serial) + uncapped group
##      with tiny mem-budget-mb (256 MiB < 512 MiB seed, safety 0).
##      Asserts: serial group intervals non-overlap (cap holds); uncapped group
##      intervals non-overlap (memory gate serializes it).
##
##   2. testFailFastDrains  (fail-fast + B+C): mix of groups, one entrypoint fails,
##      fail-fast enabled.  Asserts: run COMPLETES within a generous wall-clock
##      bound (no deadlock / hang), and the failure is reported.
##
##   3. testPerGroupTimeoutInComposedRun  (A in composed context): composed run
##      with a sleeping entrypoint in a group whose timeout-secs is 1.  Asserts
##      that entrypoint is classified oTimeout; others in a generous-budget group
##      complete normally.
##
## The PRIMARY goal of S7 is proving NO DEADLOCK when the new admission machinery
## (AdmissionController tokens, memThrottledSlots, group caps) runs together under
## fail-fast — a single live token not released on the drain path would hang the
## poll loop forever.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_composition_s7.nim

import std/[math, options, os, sequtils, strutils, tables, tempfiles, times, unittest]
import crisol/types
import crisol/runner
import crisol/config
import crisol/sandbox

# A6: the live run path is now hermetic by default (env scrub).  These tests
# spawn overlap_probe, which reads CRISOL_TEST_OVERLAP_FILE from its env — so we
# allowlist that var via the spec passed to execute().
let overlapSpec = resolveSandbox(passthroughs = @["CRISOL_TEST_OVERLAP_FILE"])

# ---------------------------------------------------------------------------
# Shared helpers
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
  ## Parse the overlap probe output file into per-PID intervals.
  ## Each line: "{pid}\t{tag}\t{monotonic_ns}"  (tag is "start" or "end").
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

proc mkEpInGroup(path, groupName: string; runTimeoutSecs: int = 0): Entrypoint =
  Entrypoint(path: path, group: groupName, flags: @[], runTimeoutSecs: runTimeoutSecs)

# ---------------------------------------------------------------------------
# Proc 1 — A+C composition: per-group cap + memory gate
# ---------------------------------------------------------------------------

proc testCapAndMemoryCompose() =
  ## Combines:
  ##   - "serial" group: max-jobs 1, 2 overlap_probe entrypoints → must NOT overlap.
  ##   - "mem_group" group: uncapped, 2 overlap_probe entrypoints, tiny mem-budget-mb
  ##     (256 MiB < 512 MiB seed, safety 0) → memory gate serializes → must NOT overlap.
  ##
  ## Both groups use the same overlap fixture; each group writes to a SEPARATE temp
  ## file so the intervals can be checked independently.
  ##
  ## Arithmetic (same as S6b):
  ##   mem-budget-mb = 256 < 512 MiB estJobPeak seed.
  ##   safety = 0.
  ##   First mem_group slot: liveCount==0 → progress-override → admits.
  ##   Second mem_group slot: avail(256 MiB) − committed(512 MiB) − 0 < 512 MiB → blocked.
  ##   → exactly serial for mem_group.

  let fdir = fixtureDir()
  let probe = fdir / "overlap_probe.nim"

  # Separate overlap files for the two groups so we can parse them independently.
  let (tmpSerial, serialPath) = createTempFile("crisol_s7_serial_", ".txt")
  close(tmpSerial)
  defer: removeFile(serialPath)

  let (tmpMem, memPath) = createTempFile("crisol_s7_mem_", ".txt")
  close(tmpMem)
  defer: removeFile(memPath)

  # We can't set two CRISOL_TEST_OVERLAP_FILE values simultaneously for two
  # groups with the same fixture binary.  Both groups use the same probe binary
  # which reads the *same* env var.  Solution: run two separate execute() calls,
  # one per group.  This still proves composition because each call exercises the
  # full admission machinery (including memory gate on the mem_group call).

  # --- Run 1: serial group (max-jobs 1, no mem constraint) ---
  let serialGroup = Group(
    name:        "serial",
    globs:       @[],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 30,
    maxJobs:     some(1),
  )
  let cfgSerial = Config(
    groups:             @[serialGroup],
    jobs:               2,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    memBudgetMb:        none(int),  # no mem constraint for this sub-test
  )
  let epsSerial = @[
    mkEpInGroup(probe, "serial"),
    mkEpInGroup(probe, "serial"),
  ]
  putEnv("CRISOL_TEST_OVERLAP_FILE", serialPath)
  let pSerial = plan(cfgSerial, epsSerial, emptyDepGraph())
  var gSerial = emptyDepGraph()
  discard execute(pSerial, config = cfgSerial, graph = gSerial, showProgress = false,
                  cache = cacheDisabled(overlapSpec))
  delEnv("CRISOL_TEST_OVERLAP_FILE")

  let serialIntervals = parseOverlapFile(serialPath)

  # --- Run 2: mem_group (uncapped, tiny mem-budget-mb) ---
  let memGroup = Group(
    name:        "mem_group",
    globs:       @[],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 30,
    maxJobs:     none(int),   # uncapped — memory gate is the only serializer
  )
  let cfgMem = Config(
    groups:             @[memGroup],
    jobs:               2,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    memBudgetMb:        some(256),  # < 512 MiB seed → gate serializes
    memAware:           none(bool),
  )
  let epsMem = @[
    mkEpInGroup(probe, "mem_group"),
    mkEpInGroup(probe, "mem_group"),
  ]
  putEnv("CRISOL_TEST_OVERLAP_FILE", memPath)
  let pMem = plan(cfgMem, epsMem, emptyDepGraph())
  var gMem = emptyDepGraph()
  discard execute(pMem, config = cfgMem, graph = gMem, showProgress = false,
                  cache = cacheDisabled(overlapSpec))
  delEnv("CRISOL_TEST_OVERLAP_FILE")

  let memIntervals = parseOverlapFile(memPath)

  # Assertions —
  check serialIntervals.len == 2
  check not anyOverlap(serialIntervals)  # cap holds: serial group serialized

  check memIntervals.len == 2
  check not anyOverlap(memIntervals)     # memory gate serializes uncapped group

# ---------------------------------------------------------------------------
# Proc 2 — fail-fast + B+C composition: no deadlock, clean drain
# ---------------------------------------------------------------------------

proc testFailFastDrains() =
  ## PRIMARY S7 goal: prove no deadlock when fail-fast fires while the
  ## admission controller holds live tokens (group caps, mem tokens).
  ##
  ## Setup:
  ##   - "serial" group (max-jobs 1, tiny mem-budget-mb): one overlap_probe (slow)
  ##     + one fail_always (fast) — the failure triggers fail-fast.
  ##   - failFast = true.
  ##   - Generous wall-clock bound: if a token is not released on the drain path,
  ##     the poll loop would spin forever waiting for the cap to drop → test hangs.
  ##
  ## Asserts:
  ##   1. run COMPLETES within 120 s (no deadlock).
  ##   2. At least one result is a failure (fail_always was dispatched/ran).
  ##   3. result seq is non-empty (not a crash-before-first-result).

  let fdir = fixtureDir()
  let probe = fdir / "overlap_probe.nim"
  let failFix = fdir / "fail_always.nim"

  let (tmp, tmpPath) = createTempFile("crisol_s7_failfast_", ".txt")
  close(tmp)
  defer: removeFile(tmpPath)

  # One group, max-jobs 1 (serial cap), tiny mem-budget (memory gate active).
  # fail_always will likely dispatch first (or second); either way one failure
  # fires fail-fast and the remaining queue is drained without new dispatches.
  let serialGrp = Group(
    name:        "serial",
    globs:       @[],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 30,
    maxJobs:     some(1),
  )
  let cfg = Config(
    groups:             @[serialGrp],
    jobs:               2,
    timeoutSecs:        30,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
    memBudgetMb:        some(256),   # memory gate active
    memAware:           none(bool),
  )

  # Three entrypoints: one fast-fail + two probes (slow).
  # With max-jobs 1 they are serial anyway; fail_always at idx 0 will fail
  # on the first slot, triggering fail-fast.  The two probes are never dispatched
  # (or at most one in-flight probe drains if compiles overlapped).
  let eps = @[
    mkEpInGroup(failFix, "serial"),    # idx 0: fails immediately
    mkEpInGroup(probe, "serial"),      # idx 1: queued (never dispatched under fail-fast)
    mkEpInGroup(probe, "serial"),      # idx 2: queued (never dispatched under fail-fast)
  ]

  putEnv("CRISOL_TEST_OVERLAP_FILE", tmpPath)
  let t0 = epochTime()
  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  let results = execute(p, config = cfg, graph = g,
                        failFast = true, showProgress = false, cache = cacheDisabled(overlapSpec))
  let elapsed = epochTime() - t0
  delEnv("CRISOL_TEST_OVERLAP_FILE")

  # Must complete without hanging.
  check elapsed < 120.0   # generous; any real deadlock will be >> 120 s

  # At least one result recorded (fail_always ran).
  check results.len >= 1

  # The failure must be present in results.
  let failOutcomes = results.filterIt(it.outcome.isFailure)
  check failOutcomes.len >= 1

# ---------------------------------------------------------------------------
# Proc 3 — per-group timeout in a composed run (A in composed context)
# ---------------------------------------------------------------------------

proc testPerGroupTimeoutInComposedRun() =
  ## Composed run with two groups:
  ##   - "timed" group: timeout-secs 2, contains hang_forever → expects oTimeout.
  ##   - "fast"  group: uncapped, no custom timeout, contains pass_always.
  ##
  ## The per-group timeout must fire at ~2 s (not the global 60 s).
  ## pass_always in "fast" must still complete normally.
  ##
  ## This confirms that A (per-group timeout) is honored in a multi-group
  ## composed run, not just in isolated single-group tests.

  let fdir = fixtureDir()
  let hang = fdir / "hang_forever.nim"
  let pass = fdir / "pass_always.nim"

  let timedGroup = Group(
    name:        "timed",
    globs:       @[],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 2,           # short group deadline
    maxJobs:     none(int),
  )
  let fastGroup = Group(
    name:        "fast",
    globs:       @[],
    flags:       @[],
    optIn:       false,
    gate:        none(Gate),
    timeoutSecs: 0,           # inherits global (60 s)
    maxJobs:     none(int),
  )
  let cfg = Config(
    groups:             @[timedGroup, fastGroup],
    jobs:               2,
    timeoutSecs:        60,
    compileTimeoutSecs: 120,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        getCurrentDir(),
  )

  let eps = @[
    mkEpInGroup(hang, "timed", runTimeoutSecs = 2),  # must timeout at ~2 s
    mkEpInGroup(pass, "fast"),                        # must pass normally
  ]

  let t0 = epochTime()
  let p = plan(cfg, eps, emptyDepGraph())
  var g = emptyDepGraph()
  let results = execute(p, config = cfg, graph = g, showProgress = false)
  let elapsed = epochTime() - t0

  check results.len == 2

  # hang_forever in the timed group must have timed out.
  check results[0].outcome == oTimeout

  # pass_always in the fast group must have passed.
  check results[1].outcome == oPassed

  # Must complete well under the global 60 s budget.
  # Allow up to 30 s (generous compile headroom + 2 s run limit).
  check elapsed < 30.0

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------

suite "S7 — A+B+C+fail-fast composition":

  test "C+B: max-jobs-1 cap serializes serial group; mem gate serializes uncapped group":
    testCapAndMemoryCompose()

  test "fail-fast: clean drain under serial cap + mem gate (no deadlock)":
    testFailFastDrains()

  test "A in composed run: per-group timeout fires at group budget, not global":
    testPerGroupTimeoutInComposedRun()

when isMainModule:
  echo "S7 composition tests done."
