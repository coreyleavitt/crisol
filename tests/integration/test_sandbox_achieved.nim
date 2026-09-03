## test_sandbox_achieved.nim — A4d integration tests, rfc-0007 A2a-i migrated
##
## The original A4d status-pipe IPC (envScrubbed/tmpdirIso/rlimitsApplied/
## netIso bits, `isFullyAchieved`) belonged to `spawn.forkExecEnvScratch` —
## `runner.nim`'s still-live path (untouched this slice; A2b retires it).
## Under the §1 process contract that mechanism is SUPERSEDED, not merely
## relocated: `ChildSpec.env`/`cwd` are explicit, so env/tmpdir are achieved
## BY CONSTRUCTION (no probe, no partial-failure state — §1 doc comment);
## only rlimits still need readback, and that readback is now PER-LIMIT
## (`ReapReport.limits: LimitsAchieved`) rather than one aggregate bit.
##
## What this file verifies through the Supervisor:
##   1. every rlimit kind requested SIMULTANEOUSLY reads back lsApplied —
##      the old "all controls OK -> isFullyAchieved true" case, broader than
##      test_rlimits_safe.nim's one-kind-at-a-time coverage.
##   2. the hlNone control: nothing requested -> every kind lsNotRequested.
##   3. env/cwd are achieved BY CONSTRUCTION: the child sees EXACTLY the
##      resolved env/cwd, deterministically — no probe, nothing to degrade.
##
## The old case 4 ("child dies before write -> EOF -> not achieved") never
## actually reached a live child even before migration: a bogus absolute
## path fails `findExe` in the PARENT on both the old and new spawn entries,
## so it never forks at all. That "spawn error, never hangs" behavior is
## covered by test_rfc0007_a2a_supervisor.nim's dedicated case instead of
## being duplicated here.

import std/[unittest, os, osproc, options, strutils]
import crisol/[types, sandbox]
import crisol/process
import "../support/spawnhelpers"

# ---------------------------------------------------------------------------
# Compile fixtures at module load time
# ---------------------------------------------------------------------------

let fixtureDir   = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir       = fixtureDir / "bin"
let nimcacheDir  = fixtureDir / "nimcache"

createDir(binDir)

let probeSrc   = fixtureDir / "env_probe.nim"
let probeBin   = binDir / "env_probe"
let probeCache = nimcacheDir / "env_probe"
let (cpOut, cpRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & probeCache & " -o:" & probeBin & " " & probeSrc)
doAssert cpRc == 0, "env_probe compile failed:\n" & cpOut

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "A4d rlimit + env/cwd achievement through the Supervisor":

  test "every rlimit kind requested simultaneously reads back lsApplied":
    ## Generous values that no fixture behavior can trip — this is purely
    ## about readback confirmation, not enforcement.
    let spec = resolveSandbox(
      level = hlIsolated,
      rlimits = RlimitOverrides(
        limitAs:     some(MinSafeRlimitAs),
        limitCpu:    some(30'i64),
        limitFsize:  some(DefaultRlimitFsize),
        limitNofile: some(DefaultRlimitNofile),
        limitCore:   some(0'i64),
      ),
    )
    doAssert spec.rlimitConfig.limitAs.isSome
    doAssert spec.rlimitConfig.limitCpu.isSome

    var sv = initSupervisor(installSignals = false)
    let outPath = getTempDir() / "crisol_achieved_test_" & $getCurrentProcessId() & ".txt"
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    removeFile(outPath)
    cleanupScratch(scratchDir)

    check ok
    check report.exit.kind == ekExited
    check report.exit.code == 0
    for lk in LimitKind:
      check report.limits[lk] == lsApplied

  test "hlNone: nothing requested -> every kind reads lsNotRequested":
    let spec = resolveSandbox(level = hlNone)
    doAssert not spec.rlimits

    var sv = initSupervisor(installSignals = false)
    let outPath = getTempDir() / "crisol_achieved_test_" & $getCurrentProcessId() & ".txt"
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    removeFile(outPath)
    cleanupScratch(scratchDir)

    check ok
    check report.exit.code == 0
    for lk in LimitKind:
      check report.limits[lk] == lsNotRequested

  test "env/cwd achieved BY CONSTRUCTION: child sees exactly the resolved values":
    let spec = resolveSandbox(level = hlIsolated, chdirIntoScratch = true)
    var sv = initSupervisor(installSignals = false)
    let outPath = getTempDir() / "crisol_achieved_test_" & $getCurrentProcessId() & ".txt"
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code == 0

    let output = readFile(outPath)
    removeFile(outPath)
    let capturedScratch = scratchDir
    cleanupScratch(scratchDir)

    # No probe, no bit to read — the resolved ChildSpec.env/cwd ARE what the
    # child saw, deterministically. cwd == the scratch dir (chdirIntoScratch);
    # TMPDIR == the same scratch dir (the pair the old tmpdirIso bit vouched
    # for, now true by construction rather than confirmed post-hoc).
    var tmpdirLine, cwdLine: string
    for line in output.splitLines():
      if line.startsWith("TMPDIR="): tmpdirLine = line["TMPDIR=".len .. ^1]
      elif line.startsWith("CWD="):  cwdLine = line["CWD=".len .. ^1]
    check tmpdirLine == capturedScratch
    check cwdLine == capturedScratch

when isMainModule:
  echo "test_sandbox_achieved done"
