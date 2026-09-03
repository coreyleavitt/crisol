## test_scratch_tmpdir.nim — A4a integration tests
##
## Verifies isolated tmpdir creation, TMPDIR injection, opt-in chdir,
## cleanup on all exit paths, and the hlNone (no scratch) path.
##
## rfc-0007 A2a-i: migrated off `spawn.forkExecEnvScratch` + the deleted
## `spawn.supervise` onto `process.nim`'s Supervisor — spawn via a ChildSpec
## built by `../support/spawnhelpers.buildChildSpec` (env scrub + TMPDIR
## injection resolved the way a real runner would, §1 ChildSpec.env doc),
## wait via `spawnAndWait`. Same six behaviors, same fixtures.
##
## Behaviors tested (vertical slices):
##   1. hlIsolated: child sees TMPDIR pointing at a fresh crisol-created dir
##   2. hlIsolated: scratch dir is REMOVED after run (no leak — the caller
##      inspects the path spawnhelpers.buildChildSpec returns)
##   3. hlIsolated, chdirIntoScratch=false (default): child cwd is UNCHANGED
##   4. hlIsolated, chdirIntoScratch=true: child cwd IS the scratch dir
##   5. hlNone: no crisol scratch TMPDIR injected (no new crisol_scratch_* dir)
##   6. cleanup-on-failure: a failing child still gets scratch dir removed

import std/[unittest, os, osproc, posix, strutils]
import crisol/[types, sandbox]
import crisol/process
import "../support/spawnhelpers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (string) =
  getTempDir() / "crisol_scratch_test_" & $getpid() & ".txt"

proc readOutput(path: string): string =
  if fileExists(path): readFile(path) else: ""

proc extractLine(output, prefix: string): string =
  for line in output.splitLines():
    if line.startsWith(prefix):
      return line[prefix.len..^1]
  return ""

# ---------------------------------------------------------------------------
# Compile fixtures once at module load time
# ---------------------------------------------------------------------------

let fixtureDir   = currentSourcePath().parentDir().parentDir() / "fixtures"
let probeSrc     = fixtureDir / "env_probe.nim"
let probeBin     = fixtureDir / "bin" / "env_probe"
let nimcacheDir  = fixtureDir / "nimcache" / "env_probe"

let failSrc      = fixtureDir / "fail_always.nim"
let failBin      = fixtureDir / "bin" / "fail_always"
let failNimcache = fixtureDir / "nimcache" / "fail_always"

let compileEnvProbe = "nim c --mm:orc --nimcache:" & nimcacheDir &
                      " -o:" & probeBin & " " & probeSrc
let (cpOut, cpRc) = execCmdEx(compileEnvProbe)
doAssert cpRc == 0, "env_probe compile failed (rc=" & $cpRc & "):\n" & cpOut

let compileFailBin = "nim c --mm:orc --nimcache:" & failNimcache &
                     " -o:" & failBin & " " & failSrc
let (cfOut, cfRc) = execCmdEx(compileFailBin)
doAssert cfRc == 0, "fail_always compile failed (rc=" & $cfRc & "):\n" & cfOut

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "A4a isolated tmpdir + TMPDIR injection + opt-in chdir":

  test "hlIsolated: child TMPDIR points at a fresh crisol scratch dir":
    ## Behavior 1: child sees TMPDIR set to a crisol-created directory,
    ## distinct from the parent's TMPDIR / host system temp.
    let parentTmpdir = getTempDir()
    let spec = resolveSandbox(level = hlIsolated)
    doAssert spec.tmpdir, "resolveSandbox(hlIsolated) must have tmpdir=true"

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.kind == ekExited
    check report.exit.code == 0

    let output = readOutput(outPath)
    removeFile(outPath)
    # Caller cleans scratch dir (mirrors runner.nim slot cleanup on success path)
    cleanupScratch(scratchDir)

    let childTmpdir = extractLine(output, "TMPDIR=")
    check childTmpdir.len > 0
    check childTmpdir != "<UNSET>"
    # Must be a real directory that crisol created (has crisol_scratch_ prefix)
    check "crisol_scratch_" in childTmpdir
    # Must differ from bare parent TMPDIR (it's a unique subdir of /tmp)
    check childTmpdir != parentTmpdir

  test "hlIsolated: scratch dir is REMOVED after run — no leak":
    ## Behavior 2: the scratch dir path is captured from buildChildSpec;
    ## after the caller removes it (as runner.nim's slot cleanup does),
    ## it no longer exists.
    let spec = resolveSandbox(level = hlIsolated)

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code == 0

    removeFile(outPath)

    # Capture path to assert post-cleanup
    let capturedScratch = scratchDir

    # Simulate slot cleanup (what runner.nim does on all paths)
    cleanupScratch(scratchDir)

    # After cleanup: dir must not exist
    check capturedScratch.len > 0
    check not dirExists(capturedScratch)

  test "hlIsolated, chdirIntoScratch=false (default): child cwd is UNCHANGED":
    ## Behavior 3: default off — child's cwd must equal the parent's cwd.
    let spec = resolveSandbox(level = hlIsolated, chdirIntoScratch = false)
    let parentCwd = getCurrentDir()

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code == 0

    let output = readOutput(outPath)
    removeFile(outPath)
    cleanupScratch(scratchDir)

    let childCwd = extractLine(output, "CWD=")
    check childCwd.len > 0
    check childCwd == parentCwd

  test "hlIsolated, chdirIntoScratch=true: child cwd IS the scratch dir":
    ## Behavior 4: opt-in chdir — child cwd must equal its injected TMPDIR.
    let spec = resolveSandbox(level = hlIsolated, chdirIntoScratch = true)

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code == 0

    let output = readOutput(outPath)
    removeFile(outPath)
    cleanupScratch(scratchDir)

    let childTmpdir = extractLine(output, "TMPDIR=")
    let childCwd    = extractLine(output, "CWD=")
    check childTmpdir.len > 0
    check childTmpdir != "<UNSET>"
    check childCwd.len > 0
    # Child's cwd must equal its TMPDIR (the scratch dir)
    check childCwd == childTmpdir

  test "hlNone: no crisol scratch TMPDIR injected":
    ## Behavior 5: hlNone passes parent env through; no crisol_scratch_* created.
    let spec = resolveSandbox(level = hlNone)
    doAssert not spec.tmpdir, "resolveSandbox(hlNone) must have tmpdir=false"

    let tmpBase = getTempDir()
    var beforeDirs: seq[string] = @[]
    for kind, path in walkDir(tmpBase):
      if kind == pcDir and path.extractFilename().startsWith("crisol_scratch_"):
        beforeDirs.add path

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(probeBin, [], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code == 0

    discard readOutput(outPath)
    removeFile(outPath)
    check scratchDir == ""  # hlNone must not create a scratch dir

    var afterDirs: seq[string] = @[]
    for kind, path in walkDir(tmpBase):
      if kind == pcDir and path.extractFilename().startsWith("crisol_scratch_"):
        afterDirs.add path

    check afterDirs.len == beforeDirs.len

  test "cleanup-on-failure: failing child scratch dir path is valid and removable":
    ## Behavior 6: even when a child exits non-zero, the scratch dir is
    ## created and returned — runner.nim cleans it on the failure path too.
    let spec = resolveSandbox(level = hlIsolated)

    # Record dirs before
    let tmpBase = getTempDir()
    var beforeDirs: seq[string] = @[]
    for kind, path in walkDir(tmpBase):
      if kind == pcDir and path.extractFilename().startsWith("crisol_scratch_"):
        beforeDirs.add path

    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    var scratchDir = ""
    let cs = buildChildSpec(failBin, [("CRISOL_SINK", "/dev/null")], spec, outPath, scratchDir)
    let (ok, report) = spawnAndWait(sv, cs, 5000)
    check ok
    check report.exit.code != 0  # fail_always exits non-zero

    removeFile(outPath)

    # Scratch dir must have been created (non-empty path)
    check scratchDir.len > 0
    check "crisol_scratch_" in scratchDir

    # Simulate cleanup (what runner.nim does on failure path)
    cleanupScratch(scratchDir)

    # After cleanup: no new scratch dirs leak
    var afterDirs: seq[string] = @[]
    for kind, path in walkDir(tmpBase):
      if kind == pcDir and path.extractFilename().startsWith("crisol_scratch_"):
        afterDirs.add path

    check afterDirs.len == beforeDirs.len

when isMainModule:
  echo "test_scratch_tmpdir done"
