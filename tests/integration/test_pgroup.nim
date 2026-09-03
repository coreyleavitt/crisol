## test_pgroup.nim — rfc-0007 A2a-i: process-group kill, as a Supervisor
## conformance case.
##
## Was: a raw `std/posix` mechanism spike (fork/setpgid/killpg by hand) that
## proved `killpg` reaps a grandchild in the child's process group before
## the Supervisor existed to prove it through. Rewritten to drive the SAME
## proof through `process.nim`'s Supervisor: `requestStop` (SIGTERM to the
## domain — the grandchild is unaffected by an ignored/absent-handler
## default, so escalation is needed) then `forceKill` (SIGKILL to the
## domain) must kill the whole process group, grandchild included, exactly
## as `killpg` did by hand — this is the mechanism A2a-ii's conformance
## suite will absorb, driven here through the real contract surface instead
## of a hand-rolled fork/setpgid/killpg spike.
##
## Fixture: spawn_pgroup_child (tests/fixtures) forks its own grandchild
## (same pgroup — never calls setpgid again) which writes its pid to a file,
## sleeps 30s, then would write a SURVIVED marker — must never be reached if
## the Supervisor's kill domain (pgid) is right.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_pgroup.nim

import std/[os, osproc, strutils, unittest, options, monotimes, times]
import crisol/process

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pollForFile(path: string; timeoutMs: int): bool =
  let step = 10
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc pidDeadOrZombie(pid: int; timeoutMs: int): bool =
  ## Poll until the pid is either gone from /proc (ESRCH — fully reaped) or
  ## a zombie (state 'Z' — killed but not yet reaped by init). Both confirm
  ## the process was killed; a zombie executes no more code.
  let step = 20
  var elapsed = 0
  let statPath = "/proc/" & $pid & "/stat"
  while elapsed < timeoutMs:
    if not fileExists(statPath):
      return true
    let content = readFile(statPath)
    let closeIdx = content.rfind(')')
    if closeIdx >= 0 and closeIdx + 2 < content.len:
      if content[closeIdx + 2] == 'Z':
        return true
    os.sleep(step)
    elapsed += step
  false

# ---------------------------------------------------------------------------
# Compile the fixture at module load time
# ---------------------------------------------------------------------------

let fixtureDir  = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir      = fixtureDir / "bin"
let nimcacheDir = fixtureDir / "nimcache"
createDir(binDir)

let src   = fixtureDir / "spawn_pgroup_child.nim"
let bin   = binDir / "spawn_pgroup_child"
let cache = nimcacheDir / "spawn_pgroup_child"
let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & bin & " " & src)
doAssert rc == 0, "spawn_pgroup_child compile failed:\n" & o

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "process-group kill — grandchild reap, through the Supervisor":

  test "requestStop+forceKill kills the whole domain; grandchild never survives":
    let tmpDir       = getTempDir()
    let gcPidFile    = tmpDir / "crisol_pgroup_gc_pid.txt"
    let survivedFile = tmpDir / "crisol_pgroup_survived.txt"
    if fileExists(gcPidFile):    removeFile(gcPidFile)
    if fileExists(survivedFile): removeFile(survivedFile)
    let outPath = tmpDir / "crisol_pgroup_out_" & $getCurrentProcessId() & ".txt"

    var sv = initSupervisor(installSignals = false)
    let spec = ChildSpec(argv: @[bin, gcPidFile, survivedFile], cwd: getCurrentDir(),
                          env: @[], sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok

    # Wait for the grandchild to announce its pid (up to 3 s).
    check pollForFile(gcPidFile, 3000)
    let grandchildPid = parseInt(readFile(gcPidFile).strip())
    check grandchildPid > 0

    # Cooperative stop first (the real requestStop/forceKill sequence a
    # timeout uses) — the child ignores SIGTERM in this fixture (mirrors a
    # blocked/hung compile grandchild that would otherwise survive), so a
    # short grace window elapses and forceKill escalates.
    sv.requestStop(sr.id, krTimeout)
    var ev = sv.next(getMonoTime() + initDuration(milliseconds = 300))
    if ev.kind != weChildExited:
      sv.forceKill(sr.id)
      ev = sv.next(getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    let report = sv.reap(ev.id)
    check report.stop.isSome

    # The grandchild (same pgroup, never re-parented via setpgid) must be
    # dead or a zombie — SIGKILL to the whole domain reached it too.
    check pidDeadOrZombie(grandchildPid, 2000)
    check not fileExists(survivedFile)

    removeFile(outPath)
    if fileExists(gcPidFile):    removeFile(gcPidFile)
    if fileExists(survivedFile): removeFile(survivedFile)

when isMainModule:
  echo "test_pgroup done"
