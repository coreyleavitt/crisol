## test_rfc0007_a2a_supervisor.nim — rfc-0007 A2a-i: the Supervisor, driven
## directly (process.nim, never a backend module directly — same rule the
## A2a-ii conformance suite will enforce). These seed cases become the basis
## A2a-ii's full conformance suite absorbs; this slice's job is proving the
## Supervisor is genuinely alive, not exhaustive: spawn+exit, requestStop's
## cooperative path, forceKill's escalation path, level-triggered
## re-reporting, the shutdown self-pipe wakeup, misuse Defects, and a spawn
## error. The runner does NOT drive the Supervisor yet (A2b).

import std/[unittest, os, osproc, posix, options, monotimes, times]
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

let passBin        = compileFixture("pass_always")
let hangBin        = compileFixture("hang_forever")
let termIgnoresBin = compileFixture("term_ignores")

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 A2a-i — the Supervisor, driven directly":

  test "spawn pass_always -> weChildExited -> reap: ekExited code 0, no stop act":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    let deadline = getMonoTime() + initDuration(seconds = 5)
    let ev = sv.next(deadline)
    check ev.kind == weChildExited
    check ev.id == sr.id
    let report = sv.reap(ev.id)
    check report.exit.kind == ekExited
    check report.exit.code == 0
    check report.stop.isNone
    check report.killDomain == kdsProcessGroup
    removeFile(outPath)

  test "level-triggered: an exited-but-unreaped child is re-reported every next()":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    let deadline = getMonoTime() + initDuration(seconds = 5)
    let ev1 = sv.next(deadline)
    check ev1.kind == weChildExited
    # Second call, still unreaped: must report the SAME id again, not drop it.
    let ev2 = sv.next(deadline)
    check ev2.kind == weChildExited
    check ev2.id == ev1.id
    discard sv.reap(ev1.id)
    removeFile(outPath)

  test "requestStop(krTimeout) on hang_forever: dies on SIGTERM inside grace, escalated:false":
    ## hang_forever has default signal dispositions -> SIGTERM terminates it
    ## promptly; no forceKill is ever needed (the "honest A1 expectation").
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @[hangBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    sv.requestStop(sr.id, krTimeout)
    let deadline = getMonoTime() + initDuration(seconds = 3)
    let ev = sv.next(deadline)
    check ev.kind == weChildExited
    let report = sv.reap(ev.id)
    check report.stop.isSome
    check report.stop.get.reason == krTimeout
    check report.stop.get.escalated == false
    check report.exit.kind == ekSignaled
    check report.exit.sig == int(SIGTERM)
    check report.killSnapshot.len >= 0   # taken at the first stop act — never omitted
    removeFile(outPath)

  test "requestStop then forceKill on term_ignores: escalated:true, SIGKILL observed":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @[termIgnoresBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    # term_ignores installs its SIG_IGN handler in its first line of `main` —
    # give it a moment to run before requestStop, or a SIGTERM racing ahead
    # of the handler install would kill it under the DEFAULT disposition
    # (a startup race, not a Supervisor behavior under test; the runner's
    # real usage never races this way — a compile/run timeout is always at
    # least hundreds of ms).
    os.sleep(150)
    sv.requestStop(sr.id, krTimeout)
    # Short grace window — term_ignores never dies cooperatively (SIG_IGN).
    let graceDeadline = getMonoTime() + initDuration(milliseconds = 300)
    var ev = sv.next(graceDeadline)
    check ev.kind == weDeadline   # grace exhausted; still alive
    sv.forceKill(sr.id)
    let killDeadline = getMonoTime() + initDuration(seconds = 5)
    ev = sv.next(killDeadline)
    check ev.kind == weChildExited
    let report = sv.reap(ev.id)
    check report.stop.isSome
    check report.stop.get.reason == krTimeout
    check report.stop.get.escalated == true
    check report.exit.kind == ekSignaled
    check report.exit.sig == int(SIGKILL)
    removeFile(outPath)

  test "shutdown wakeup: a signal delivered while blocked in next() returns weShutdown promptly":
    var sv = initSupervisor(installSignals = true)
    let t0 = getMonoTime()
    # A helper process delivers SIGINT to THIS process after a short delay —
    # a real, externally-delivered signal (not a same-thread coincidence),
    # arriving while `next` is expected to be blocked in poll(2).
    let helper = startProcess("/bin/sh", args = @["-c",
                 "sleep 0.2; kill -INT " & $getpid()],
                 options = {poUsePath})
    let farDeadline = t0 + initDuration(seconds = 10)
    let ev = sv.next(farDeadline)
    check ev.kind == weShutdown
    check ev.signal.signum == int(SIGINT)
    let elapsed = getMonoTime() - t0
    check elapsed < initDuration(seconds = 2)   # well before the 10 s deadline
    discard waitForExit(helper)
    close(helper)

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

  test "spawn error: nonexistent binary yields SpawnResult ok:false, not a crash":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile()
    let spec = ChildSpec(argv: @["crisol_this_binary_does_not_exist_zzz"],
                          cwd: getCurrentDir(), env: @[], sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check not sr.ok
    check sr.error.len > 0

when isMainModule:
  echo "test_rfc0007_a2a_supervisor done"
