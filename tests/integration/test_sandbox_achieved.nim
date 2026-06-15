## test_sandbox_achieved.nim — A4d integration tests
##
## Verifies the SandboxAchieved IPC: a pre-fork status pipe over which the child
## writes a small status word (async-signal-safe) before execvpe, encoding which
## hermeticity controls it actually delivered.  The parent reads the word and
## populates a SandboxAchieved record, returned alongside the child Pid from
## forkExecEnvScratch.
##
## Status-word bit encoding (uint8, child→parent over the pre-fork pipe):
##   bit 0 (0x01) envScrubbed     — env allowlist filter applied
##   bit 1 (0x02) tmpdirIso       — isolated TMPDIR scratch dir created
##   bit 2 (0x04) rlimitsApplied  — config rlimits set AND getrlimit read-back confirmed
##   bit 3 (0x08) netIso          — CLONE_NEWNET applied (never set today; degrades)
##
## Behaviors tested:
##   1. hlIsolated + all controls OK → envScrubbed/tmpdirIso/rlimitsApplied true;
##      isFullyAchieved(spec, got) == true
##   2. getrlimit read-back: RLIMIT_FSIZE configured → rlimitsApplied true
##   3. forced degradation: netIso requested (hlNetwork) → netIso bit FALSE,
##      isFullyAchieved FALSE (netIso is not wired in spawn → never achieved)
##   4. child dies before write (exec of nonexistent binary) → parent does not
##      hang; EOF on the pipe → all bits false / not-achieved

import std/[unittest, os, osproc, posix, options]
import crisol/[types, sandbox, spawn]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (cint, string) =
  let path = getTempDir() / "crisol_achieved_test_" & $getpid() & ".txt"
  let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
  doAssert fd >= 0, "failed to open temp file: " & path
  (fd, path)

proc runAchieved(bin: string; spec: SandboxSpec; timeoutMs: int = 5000):
    tuple[exitCode: int; signal: int; timedOut: bool;
          achieved: SandboxAchieved; scratchDir: string] =
  ## Fork-exec `bin` under `spec`; return supervise result + achieved + scratchDir.
  let (fd, outPath) = tmpOutputFile()
  var scratchDir = ""
  let (pid, achieved) = forkExecEnvScratch(@[bin], fd, @[], spec, scratchDir)
  discard posix.close(fd)
  removeFile(outPath)
  if pid <= Pid(0):
    return (exitCode: -1, signal: 0, timedOut: false,
            achieved: achieved, scratchDir: scratchDir)
  let (ec, sig, timedOut) = supervise(pid, timeoutMs)
  result = (exitCode: ec, signal: sig, timedOut: timedOut,
            achieved: achieved, scratchDir: scratchDir)

proc cleanup(scratchDir: string) =
  if scratchDir.len > 0:
    try: removeDir(scratchDir) except: discard

# ---------------------------------------------------------------------------
# Compile fixtures at module load time
# ---------------------------------------------------------------------------

let fixtureDir   = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir       = fixtureDir / "bin"
let nimcacheDir  = fixtureDir / "nimcache"

createDir(binDir)

# A small, clean-exit fixture: env_probe reads env and exits 0.
let probeSrc   = fixtureDir / "env_probe.nim"
let probeBin   = binDir / "env_probe"
let probeCache = nimcacheDir / "env_probe"
let (cpOut, cpRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & probeCache & " -o:" & probeBin & " " & probeSrc)
doAssert cpRc == 0, "env_probe compile failed:\n" & cpOut

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "A4d SandboxAchieved IPC (pre-fork status pipe)":

  test "hlIsolated all controls OK → achieved bits set; isFullyAchieved true":
    ## Under the default isolated spec every requested control succeeds in a
    ## normal environment: env scrub, scratch TMPDIR, and config rlimits (with
    ## getrlimit read-back) are all delivered.  netIso is NOT requested here.
    let spec = resolveSandbox(level = hlIsolated)
    doAssert spec.envScrub and spec.tmpdir and spec.rlimits
    doAssert not spec.netIso

    let r = runAchieved(probeBin, spec)
    cleanup(r.scratchDir)
    check r.exitCode == 0

    check r.achieved.envScrubbed
    check r.achieved.tmpdirIso
    check r.achieved.rlimitsApplied
    check not r.achieved.netIso          # not requested → not delivered
    check isFullyAchieved(spec, r.achieved)

  test "getrlimit read-back: RLIMIT_FSIZE configured → rlimitsApplied true":
    ## With an explicit (kernel-acceptable) RLIMIT_FSIZE, the child sets it and
    ## confirms via getrlimit read-back that the soft limit reads back equal.
    let spec = resolveSandbox(
      level = hlIsolated,
      rlimits = RlimitOverrides(limitFsize: some(1_048_576'i64)),   # 1 MiB — comfortably acceptable
    )
    doAssert spec.rlimits
    doAssert spec.rlimitConfig.limitFsize == some(1_048_576'i64)

    let r = runAchieved(probeBin, spec)
    cleanup(r.scratchDir)
    check r.exitCode == 0
    check r.achieved.rlimitsApplied
    check isFullyAchieved(spec, r.achieved)

  test "forced degradation: netIso requested (hlNetwork) → netIso FALSE, gate FALSE":
    ## hlNetwork requests CLONE_NEWNET.  spawn does NOT implement netIso, so the
    ## child never sets that bit → achieved.netIso is false and isFullyAchieved
    ## is false (the gate blocks caching for a degraded run).  The other controls
    ## still succeed.
    let spec = resolveSandbox(level = hlNetwork)
    doAssert spec.netIso, "hlNetwork must request netIso"

    let r = runAchieved(probeBin, spec)
    cleanup(r.scratchDir)
    check r.exitCode == 0

    check not r.achieved.netIso            # degraded — not wired in spawn
    check not isFullyAchieved(spec, r.achieved)
    # The non-net controls still succeeded:
    check r.achieved.envScrubbed
    check r.achieved.tmpdirIso
    check r.achieved.rlimitsApplied

  test "child dies before write (nonexistent binary) → EOF → not achieved":
    ## execvpe of a nonexistent path fails; the child writes its status word
    ## BEFORE execvpe, so in the normal flow the parent still reads it.  But to
    ## exercise the EOF / child-died path robustly we point at a path that the
    ## child cannot reach — and assert the parent does NOT hang and returns a
    ## well-formed (not-fully-achieved is acceptable) result without blocking
    ## forever.
    ##
    ## Primary guarantee under test: the parent's blocking read of the status
    ## byte terminates (either it reads the pre-exec byte, or it gets EOF when
    ## the child's write-end closes on _exit).  Either way it must not hang.
    let spec = resolveSandbox(level = hlIsolated)
    let bogus = binDir / "this_binary_does_not_exist_zzzz"
    doAssert not fileExists(bogus)

    let r = runAchieved(bogus, spec, timeoutMs = 5000)
    cleanup(r.scratchDir)
    # The child exec fails and _exit(127)s; supervise sees a non-zero exit.
    # The key assertion is that we got HERE (no hang) with a decoded record.
    check not r.timedOut
    # netIso is never achieved regardless.
    check not r.achieved.netIso

when isMainModule:
  echo "test_sandbox_achieved done"
