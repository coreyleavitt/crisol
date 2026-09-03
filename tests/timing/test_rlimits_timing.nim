## test_rlimits_timing.nim — A4c integration tests
##
## Verifies timing/privilege-sensitive rlimits:
##   - RLIMIT_CPU: a tight CPU-spin fixture is killed by SIGXCPU deterministically
##     when a small CPU limit is set.
##   - RLIMIT_AS: a large-allocation fixture fails deterministically when AS is
##     capped at/above MinSafeRlimitAs (safe for ORC) but below the requested alloc.
##
## rfc-0007 A2a-i: migrated off `spawn.forkExecEnvScratch` + the deleted
## `spawn.supervise` onto process.nim's Supervisor — see `../support/spawnhelpers`.
##
## GATING: This file quits 0 immediately when CRISOL_TIMING_TESTS is unset or
## empty.  The env var is NOT forwarded by ./dev run (podman only sets HOME), so
## the normal ./dev test run always skips these tests (tests/timing/ is also
## outside the default CRISOL_TEST_DIRS list, so they aren't even discovered).
## Use `./dev timing` (sets both CRISOL_TIMING_TESTS=1 and
## CRISOL_TEST_DIRS=tests/timing for the whole serial timing leg), or to run
## this file alone:
##
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --path:src \
##     tests/timing/test_rlimits_timing.nim
##
## Note: CRISOL_TIMING_TESTS must be explicitly passed via --env if using podman:
##   podman run --env CRISOL_TIMING_TESTS=1 ...
##
## Behaviors tested (vertical slices):
##   1. RLIMIT_CPU=1s → cpu fixture killed by SIGXCPU (signal 24 on Linux)
##   2. RLIMIT_CPU unset (rlimits=false) → cpu fixture would spin; we use a
##      short wall timeout instead to verify it does NOT exit on its own
##   3. RLIMIT_AS at MinSafeRlimitAs → as fixture's 2 GiB alloc fails/aborts
##   4. RLIMIT_AS unset (rlimits=false) → as fixture's alloc succeeds (exits 0)
##   5. Gating: with CRISOL_TIMING_TESTS empty the file quits 0 immediately

import std/[os, osproc, options, unittest, monotimes, times]
import crisol/[types, sandbox]
import crisol/process
import "../support/spawnhelpers"

# ---------------------------------------------------------------------------
# GATE: quit 0 immediately when env var is unset or empty.
# This is the FIRST executable statement so the file is skippable with zero
# overhead even if test infrastructure runs it without the env var.
# ---------------------------------------------------------------------------

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const SIGXCPU = 24  ## Linux signal number for CPU time limit exceeded

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc runFixture(bin: string; spec: SandboxSpec; timeoutMs: int = 10_000):
    tuple[ok: bool; report: ReapReport; scratchDir: string] =
  var sv = initSupervisor(installSignals = false)
  let outPath = getTempDir() / "crisol_timing_test_" & $getCurrentProcessId() & ".txt"
  var scratchDir = ""
  let cs = buildChildSpec(bin, [], spec, outPath, scratchDir)
  let (ok, report) = spawnAndWait(sv, cs, timeoutMs)
  removeFile(outPath)
  (ok, report, scratchDir)

# ---------------------------------------------------------------------------
# Compile fixtures at module load time
# ---------------------------------------------------------------------------

let fixtureDir  = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir      = fixtureDir / "bin"
let nimcacheDir = fixtureDir / "nimcache"

createDir(binDir)

# --- rlimit_cpu fixture ---
let cpuSrc   = fixtureDir / "rlimit_cpu.nim"
let cpuBin   = binDir / "rlimit_cpu"
let cpuCache = nimcacheDir / "rlimit_cpu"
let (cpuOut, cpuRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & cpuCache & " -o:" & cpuBin & " " & cpuSrc)
doAssert cpuRc == 0, "rlimit_cpu compile failed:\n" & cpuOut

# --- rlimit_as fixture ---
let asSrc   = fixtureDir / "rlimit_as.nim"
let asBin   = binDir / "rlimit_as"
let asCache = nimcacheDir / "rlimit_as"
let (asOut, asRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & asCache & " -o:" & asBin & " " & asSrc)
doAssert asRc == 0, "rlimit_as compile failed:\n" & asOut

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "A4c timing/privilege-sensitive rlimits (RLIMIT_CPU, RLIMIT_AS)":

  test "RLIMIT_CPU=1s → cpu fixture killed by SIGXCPU":
    ## With RLIMIT_CPU = 1 second the spinning fixture accumulates 1 CPU-second
    ## and the kernel sends SIGXCPU (24 on Linux), terminating it.
    ## Wall-clock timeout is generous (10s) so CI scheduler noise cannot cause
    ## a false timeout; SIGXCPU fires well within 1–2 wall seconds on any host.
    let spec = resolveSandbox(
      level    = hlIsolated,
      rlimits = RlimitOverrides(limitCpu: some(int64(1))),  # 1 CPU-second
    )
    let r = runFixture(cpuBin, spec, timeoutMs = 10_000)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.limits[lkCpu] == lsApplied
    # Must be killed by SIGXCPU.
    check r.report.exit.kind == ekSignaled
    check r.report.exit.sig == SIGXCPU

  test "RLIMIT_CPU unset (rlimits=false) → cpu fixture runs until wall timeout":
    ## Without RLIMIT_CPU the fixture spins forever.  We give it a short wall
    ## timeout (2s) — it must NOT exit on its own (weDeadline, not
    ## weChildExited), demonstrating no CPU limit was imposed. Unlike
    ## runFixture/spawnAndWait (which never sends a stop act), this case
    ## drives the Supervisor directly: it MUST clean up the still-alive
    ## child itself before `sv` goes out of scope, or the Supervisor's own
    ## misuse Defect fires ("destroyed with live children", §1 lifecycle
    ## rule) — a real guard, not test friction, and the same requestStop/
    ## forceKill drain the RLIMIT_CPU=1s case above never needed because
    ## SIGXCPU already ended that child.
    let spec = resolveSandbox(level = hlNone)  # no rlimits
    doAssert spec.limits == Limits()
    var sv = initSupervisor(installSignals = false)
    let outPath = getTempDir() / "crisol_timing_test_" & $getCurrentProcessId() & ".txt"
    var scratchDir = ""
    let cs = buildChildSpec(cpuBin, [], spec, outPath, scratchDir)
    let sr = sv.spawn(cs)
    check sr.ok
    let deadline = getMonoTime() + initDuration(milliseconds = 2_000)
    let ev = sv.next(deadline)
    check ev.kind == weDeadline   # must NOT have exited on its own

    sv.requestStop(sr.id, krTimeout)
    var ev2 = sv.next(getMonoTime() + initDuration(milliseconds = 500))
    if ev2.kind != weChildExited:
      sv.forceKill(sr.id)
      ev2 = sv.next(getMonoTime() + initDuration(seconds = 5))
    check ev2.kind == weChildExited
    discard sv.reap(ev2.id)
    removeFile(outPath)
    cleanupScratch(scratchDir)

  test "RLIMIT_AS at MinSafeRlimitAs → as fixture's 2 GiB alloc fails/aborts":
    ## MinSafeRlimitAs is generous enough for ORC's arena + normal test startup,
    ## but well below the fixture's 2 GiB alloc request.  The fixture's alloc
    ## fails, Nim raises OutOfMemDefect (or SIGSEGV from mmap failure), and the
    ## child exits non-zero.
    ##
    ## CRITICAL: MinSafeRlimitAs is set in the CHILD only (via setrlimit in the
    ## fork window).  The crisol runner process itself is unaffected.
    let spec = resolveSandbox(
      level    = hlIsolated,
      rlimits = RlimitOverrides(limitAs: some(MinSafeRlimitAs)),  # ceiling at the documented safe min
    )
    let r = runFixture(asBin, spec, timeoutMs = 15_000)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.limits[lkAddressSpace] == lsApplied
    # The fixture must NOT succeed: either killed by signal or exits non-zero.
    let hitLimit = r.report.exit.kind == ekSignaled or
                   (r.report.exit.kind == ekExited and r.report.exit.code != 0)
    check hitLimit

  test "RLIMIT_AS unset (rlimits=false) → as fixture's 2 GiB alloc succeeds":
    ## Without RLIMIT_AS the fixture successfully allocates 2 GiB virtual
    ## address space and exits 0.  This confirms the limit test above is
    ## actually enforcing the ceiling, not testing a spurious alloc failure.
    ##
    ## PREREQUISITE: the host/container must have ≥ 2 GiB virtual address
    ## space available.  On any modern 64-bit Linux this is trivially satisfied
    ## (process AS limit is typically 128 TiB).
    let spec = resolveSandbox(level = hlNone)  # no rlimits
    doAssert spec.limits == Limits()
    let r = runFixture(asBin, spec, timeoutMs = 15_000)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.exit.kind == ekExited
    check r.report.exit.code == 0

when isMainModule:
  echo "test_rlimits_timing done"
