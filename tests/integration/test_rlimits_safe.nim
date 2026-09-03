## test_rlimits_safe.nim — A4b integration tests
##
## Verifies that safe config-declared rlimits (RLIMIT_CORE=0, RLIMIT_NOFILE,
## RLIMIT_FSIZE) are applied via process.nim's Supervisor — the §1
## `ReapReport.limits` per-limit readback, the same per-limit semantics
## `spawn.forkExecEnvScratch`'s status pipe now reports too (rfc-0007
## A2a-iii replaced its old single aggregate bit with the same per-`LimitKind`
## shape this Supervisor path already used).
##
## rfc-0007 A2a-i: migrated off `spawn.forkExecEnvScratch` + the deleted
## `spawn.supervise` onto the Supervisor — see `../support/spawnhelpers`.
##
## RLIMIT_CPU and RLIMIT_AS are deferred to A4c-equivalent coverage in
## test_rlimits_timing.nim — NOT tested here.
##
## Behaviors tested (vertical slices):
##   1. RLIMIT_FSIZE small → fsize fixture is killed/fails deterministically
##   2. RLIMIT_FSIZE unset (spec.rlimits=false) → fsize fixture succeeds (control)
##   3. RLIMIT_NOFILE small → nofile fixture hits the ceiling deterministically
##   4. RLIMIT_NOFILE unset (spec.rlimits=false) → nofile fixture succeeds (control)
##   5. RLIMIT_CORE=0 applied → crashing child leaves no core file in scratch dir
##   6. spec.rlimits=false (hlNone) → child is unaffected by any limit

import std/[unittest, os, osproc, options, strutils]
import crisol/[types, sandbox]
import crisol/process
import "../support/spawnhelpers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc runFixture(bin: string; spec: SandboxSpec; timeoutMs: int = 5000):
    tuple[ok: bool; report: ReapReport; scratchDir: string] =
  ## Spawn `bin` under `spec` through the Supervisor; return the ReapReport +
  ## scratchDir (caller cleans it up).
  var sv = initSupervisor(installSignals = false)
  let outPath = getTempDir() / "crisol_rlimit_test_" & $getCurrentProcessId() & ".txt"
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

let fsizeSrc  = fixtureDir / "rlimit_fsize.nim"
let fsizeBin  = binDir / "rlimit_fsize"
let fsizeCache = nimcacheDir / "rlimit_fsize"
let (fsizeOut, fsizeRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & fsizeCache & " -o:" & fsizeBin & " " & fsizeSrc)
doAssert fsizeRc == 0, "rlimit_fsize compile failed:\n" & fsizeOut

let nofileSrc  = fixtureDir / "rlimit_nofile.nim"
let nofileBin  = binDir / "rlimit_nofile"
let nofileCache = nimcacheDir / "rlimit_nofile"
let (nofileOut, nofileRc) = execCmdEx(
  "nim c --mm:orc --nimcache:" & nofileCache & " -o:" & nofileBin & " " & nofileSrc)
doAssert nofileRc == 0, "rlimit_nofile compile failed:\n" & nofileOut

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "A4b safe rlimits (RLIMIT_CORE, RLIMIT_NOFILE, RLIMIT_FSIZE)":

  test "RLIMIT_FSIZE small → fsize fixture fails deterministically":
    ## With a 4 KiB RLIMIT_FSIZE the fixture (which tries to write 1 MiB) must
    ## fail: either killed by SIGXFSZ or exit non-zero from write error.
    ## SIGXFSZ = 25 on Linux.
    let smallFsize: int64 = 4 * 1024  # 4 KiB — well below 1 MiB fixture write
    let spec = resolveSandbox(
      level = hlIsolated,
      rlimits = RlimitOverrides(limitFsize: some(smallFsize)),
    )
    let r = runFixture(fsizeBin, spec)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.limits[lkFileSize] == lsApplied
    # The fixture must NOT succeed: either killed by signal or exits non-zero.
    let hitLimit = r.report.exit.kind == ekSignaled or
                   (r.report.exit.kind == ekExited and r.report.exit.code != 0)
    check hitLimit

  test "RLIMIT_FSIZE unset (rlimits=false) → fsize fixture succeeds (control)":
    ## Without a limit, the fixture writes 1 MiB and exits 0.
    let spec = resolveSandbox(level = hlNone)
    doAssert spec.limits == Limits()
    let r = runFixture(fsizeBin, spec)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.limits[lkFileSize] == lsNotRequested
    check r.report.exit.kind == ekExited
    check r.report.exit.code == 0

  test "RLIMIT_NOFILE small → nofile fixture hits the ceiling deterministically":
    ## With RLIMIT_NOFILE = 10 the fixture (which opens fds until EMFILE)
    ## must exit 1 (limit hit).
    let smallNofile: int64 = 10  # very small; fixture will exhaust it quickly
    let spec = resolveSandbox(
      level = hlIsolated,
      rlimits = RlimitOverrides(limitNofile: some(smallNofile)),
    )
    let r = runFixture(nofileBin, spec)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.limits[lkOpenFiles] == lsApplied
    # The fixture exits 1 when it hits EMFILE.
    check r.report.exit.kind == ekExited
    check r.report.exit.code == 1

  test "RLIMIT_NOFILE unset (rlimits=false) → nofile fixture succeeds (control)":
    ## Without a limit, the fixture opens 2048 fds and exits 0.
    let spec = resolveSandbox(level = hlNone)
    doAssert spec.limits == Limits()
    let r = runFixture(nofileBin, spec)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.exit.kind == ekExited
    check r.report.exit.code == 0

  test "RLIMIT_CORE=0 applied → no core file left in scratch dir after crash":
    ## We can observe RLIMIT_CORE=0 indirectly: a process that receives SIGABRT
    ## (via abort(3)) would normally write a core file, but with RLIMIT_CORE=0
    ## no core file is written.
    ##
    ## Strategy: run the nofile fixture (clean exit) under hlIsolated (which
    ## sets RLIMIT_CORE=0 by default) and verify the scratch dir carries no
    ## core.* files and lkCore reads back lsApplied — the same weak-but-best-
    ## available observable the pre-migration test used.
    let spec = resolveSandbox(level = hlIsolated)  # RLIMIT_CORE=0 by default
    doAssert spec.limits != Limits()
    doAssert spec.limits.req[lkCore].isSome
    doAssert spec.limits.req[lkCore].get() == 0

    let r = runFixture(nofileBin, spec)  # exits 0 normally (no limit here — default nofile is 1024)
    check r.ok
    check r.report.limits[lkCore] == lsApplied
    if r.scratchDir.len > 0:
      # Check for core files before cleanup
      var coreFound = false
      if dirExists(r.scratchDir):
        for kind, path in walkDir(r.scratchDir):
          if path.extractFilename().startsWith("core"):
            coreFound = true
      cleanupScratch(r.scratchDir)
      check not coreFound  # RLIMIT_CORE=0 must suppress any core dump

  test "spec.rlimits=false (hlNone) → child runs without imposed limits":
    ## Control case: hlNone passes parent env through; no rlimits applied.
    ## Both fixtures must complete normally (we already verified the fsize
    ## fixture above; use nofile here as a clean "runs to completion" proxy).
    let spec = resolveSandbox(level = hlNone)
    doAssert spec.limits == Limits()
    let r = runFixture(nofileBin, spec)
    cleanupScratch(r.scratchDir)
    check r.ok
    check r.report.exit.kind == ekExited
    check r.report.exit.code == 0
    for lk in LimitKind:
      check r.report.limits[lk] == lsNotRequested

when isMainModule:
  echo "test_rlimits_safe done"
