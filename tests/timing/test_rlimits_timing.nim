## test_rlimits_timing.nim — A4c integration tests
##
## Verifies timing/privilege-sensitive rlimits:
##   - RLIMIT_CPU: a tight CPU-spin fixture is killed by SIGXCPU deterministically
##     when a small CPU limit is set.
##   - RLIMIT_AS: a large-allocation fixture fails deterministically when AS is
##     capped at/above MinSafeRlimitAs (safe for ORC) but below the requested alloc.
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

import std/[os, osproc, posix, options, unittest]
import crisol/[types, sandbox, spawn]

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

const SIGXCPU = cint(24)  ## Linux signal number for CPU time limit exceeded
  ## POSIX value; present in std/posix on Linux but we spell it out for clarity.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (cint, string) =
  let path = getTempDir() / "crisol_timing_test_" & $getpid() & ".txt"
  let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
  doAssert fd >= 0, "failed to open temp file: " & path
  (fd, path)

proc runFixture(bin: string; spec: SandboxSpec; timeoutMs: int = 10_000):
    tuple[exitCode: int; signal: int; timedOut: bool; scratchDir: string] =
  ## Fork-exec `bin` under `spec`; return the supervise result + scratchDir.
  let (fd, outPath) = tmpOutputFile()
  var scratchDir = ""
  let (pid, _) = forkExecEnvScratch(@[bin], fd, @[], spec, scratchDir)
  discard posix.close(fd)
  removeFile(outPath)
  if pid <= Pid(0):
    return (exitCode: -1, signal: 0, timedOut: false, scratchDir: scratchDir)
  let (ec, sig, timedOut) = supervise(pid, timeoutMs)
  result = (exitCode: ec, signal: sig, timedOut: timedOut, scratchDir: scratchDir)

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
    if r.scratchDir.len > 0:
      try: removeDir(r.scratchDir) except: discard
    # Must be killed by SIGXCPU; may not exit normally.
    check r.signal == int(SIGXCPU)
    check not r.timedOut

  test "RLIMIT_CPU unset (rlimits=false) → cpu fixture runs until wall timeout":
    ## Without RLIMIT_CPU the fixture spins forever.  We give it a short wall
    ## timeout (2s) — it must time out, NOT exit with SIGXCPU, demonstrating
    ## no CPU limit was imposed.
    let spec = resolveSandbox(level = hlNone)  # no rlimits
    doAssert not spec.rlimits
    let r = runFixture(cpuBin, spec, timeoutMs = 2_000)
    if r.scratchDir.len > 0:
      try: removeDir(r.scratchDir) except: discard
    # The fixture must NOT exit via SIGXCPU — it should time out instead.
    check r.timedOut
    check r.signal != int(SIGXCPU)

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
    if r.scratchDir.len > 0:
      try: removeDir(r.scratchDir) except: discard
    # The fixture must NOT succeed: either killed by signal or exits non-zero.
    let hitLimit = r.signal != 0 or r.exitCode != 0
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
    doAssert not spec.rlimits
    let r = runFixture(asBin, spec, timeoutMs = 15_000)
    if r.scratchDir.len > 0:
      try: removeDir(r.scratchDir) except: discard
    check r.exitCode == 0
    check r.signal == 0
    check not r.timedOut

when isMainModule:
  echo "test_rlimits_timing done"
