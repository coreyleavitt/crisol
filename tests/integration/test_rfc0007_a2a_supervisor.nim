## test_rfc0007_a2a_supervisor.nim — rfc-0007 A2a-i: the Supervisor, driven
## directly (process.nim, never a backend module directly).
##
## A2a-ii absorbed six of this file's seven original seed cases into
## tests/conformance/ (spawn/exit, level-triggered re-report, cooperative
## kill, escalated kill, spawn error moved into test_conformance.nim;
## shutdown wakeup moved into test_conformance_timing.nim, gated on
## CRISOL_TIMING_TESTS) — those are contract material, and duplicating them
## here would mean pinning the same fact twice. What's left is the ONE case
## that is not one of the nine A2a-ii conformance items: a Supervisor
## lifecycle-misuse regression (double-reap raises a Defect, per §1's
## "requestStop/forceKill/snapshotTree on a consumed id: Defect, never a
## silent no-op" rule — reap follows the same rule though §1 states it only
## for the other three procs).
##
## The runner does NOT drive the Supervisor yet (A2b).

import std/[unittest, os, osproc, posix, monotimes, times]
import crisol/process

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tmpOutputFile(): (string) =
  getTempDir() / "crisol_sv_test_" & $getpid() & "_" & $epochTime().int64 & ".txt"

let fixtureDir  = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir      = fixtureDir / "bin"
let nimcacheDir = fixtureDir / "nimcache"
createDir(binDir)

proc compileFixture(name: string): string =
  let src   = fixtureDir / (name & ".nim")
  let bin   = binDir / name
  let cache = nimcacheDir / name
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & bin & " " & src)
  doAssert rc == 0, name & " compile failed:\n" & o
  bin

let passBin = compileFixture("pass_always")

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 A2a-i — the Supervisor, driven directly":

  test "misuse: reap() twice on the same ChildId is a Defect":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
    discard sv.reap(ev.id)
    expect AssertionDefect:
      discard sv.reap(ev.id)
    removeFile(outPath)

when isMainModule:
  echo "test_rfc0007_a2a_supervisor done"
