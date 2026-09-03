## test_conformance.nim — rfc-0007 A2a-ii: the backend-agnostic conformance
## suite's non-timing-sensitive cases, driven through `process.nim` (the §1
## selection ladder) ONLY — never a backend module directly (enforced by
## test_conformance_import_purity.nim in this directory). Whichever backend
## `process.nim`'s `when defined(...)` selects on the host running this file
## is what gets proven; on Linux today that is `process/posix.nim`.
##
## HONEST NOTE (rfc-0007 A2a-ii bullet, superseded by A2b): before A2b, the
## PRODUCT runner did not execute the Supervisor at all — `runner.nim` drove
## `crisol/spawn.nim`'s `forkExec`/`forkExecEnvScratch` directly, and this
## suite proved only the §1 CONTRACT, saying nothing about whether the
## runner used it. A2b migrated `runner.nim` onto the Supervisor and deleted
## `spawn.nim`; this suite now proves the substrate the product runner
## actually runs on.
##
## Items covered here (see docs/rfc/0007-execution-substrate.md, the A2a-ii
## bullet, for the canonical list of nine): 1 (spawn/exit), 2 (timeout kill —
## functional half; the wall-clock grace-timing pin lives in
## test_conformance_timing.nim), 3 (cooperative vs escalated), 5 (output
## caps), 6 (achieved readback), 7 (spawn error), 8 (level-triggered
## re-report). Items 4 (shared grace window) and 9 (shutdown wakeup) are
## entirely wall-clock pins and live in test_conformance_timing.nim, gated on
## CRISOL_TIMING_TESTS.
##
## Reorganization note: items 1, 3, 7, 8 absorb the corresponding seed cases
## from tests/integration/test_rfc0007_a2a_supervisor.nim (A2a-i) verbatim in
## substance — that file now keeps only the one case that ISN'T conformance
## material (the double-reap misuse Defect, a Supervisor lifecycle-misuse
## regression test, not one of the nine contract items).

import std/[options, os, posix, unittest, monotimes, times]
import ./helpers

# ---------------------------------------------------------------------------
# Fixtures compiled once at module load.
# ---------------------------------------------------------------------------

let passBin        = compileFixture("pass_always")
let failBin        = compileFixture("fail_always")
let hangBin        = compileFixture("hang_forever")
let termIgnoresBin = compileFixture("term_ignores")
let noisyBin       = compileFixture("noisy_output")

# ---------------------------------------------------------------------------
# Item 1 — spawn/exit: normal exit, code propagation.
# ---------------------------------------------------------------------------

suite "conformance 1 — spawn/exit":

  test "pass_always: ekExited code 0, no stop act recorded":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("spawn_exit_pass")
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    check report.exit.kind == ekExited
    check report.exit.code == 0
    check report.stop.isNone
    check report.killDomain == kdsProcessGroup
    removeFile(outPath)

  test "fail_always: exit code propagates losslessly (not just pass/fail)":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("spawn_exit_fail")
    let spec = ChildSpec(argv: @[failBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    check report.exit.kind == ekExited
    check report.exit.code == 1
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 2 (functional half) / Item 3 — cooperative vs escalated.
#
# hang_forever dies on SIGTERM inside the grace window: the ONE test proves
# both item 2 (requestStop at deadline -> child dies in grace -> the honest
# Exit reported, never a fabricated one) and item 3's escalated:false half
# (nothing to escalate FROM). term_ignores needs SIGKILL: item 3's
# escalated:true half — the act-ledger definition of "escalated" (§1
# forceKill doc: `escalated := forceKill was recorded before the backend
# observed the exit`), not "was it actually needed".
# ---------------------------------------------------------------------------

suite "conformance 2+3 — timeout kill, cooperative vs escalated":

  test "hang_forever: requestStop(krTimeout) -> dies on SIGTERM in grace, honest Exit, escalated:false":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("coop_hang")
    let spec = ChildSpec(argv: @[hangBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    sv.requestStop(sr.id, krTimeout)
    let ev = sv.next(getMonoTime() + initDuration(seconds = 3))
    check ev.kind == weChildExited
    let report = sv.reap(ev.id)
    check report.stop.isSome
    check report.stop.get.reason == krTimeout
    check report.stop.get.escalated == false
    check report.exit.kind == ekSignaled          # honest — never a fabricated ekExited
    check report.exit.sig == int(SIGTERM)
    removeFile(outPath)

  test "term_ignores: requestStop then forceKill -> escalated:true, SIGKILL observed":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("coop_termignores")
    let spec = ChildSpec(argv: @[termIgnoresBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    # term_ignores installs SIG_IGN in its first line of main — give it a
    # moment before requestStop, or a SIGTERM racing ahead of the handler
    # install would kill it under the default disposition (a startup race,
    # not Supervisor behavior; the runner's real usage never races this
    # tightly — a compile/run timeout is always at least hundreds of ms).
    os.sleep(150)
    sv.requestStop(sr.id, krTimeout)
    var ev = sv.next(getMonoTime() + initDuration(milliseconds = 300))
    check ev.kind == weDeadline   # grace exhausted; still alive, ignoring SIGTERM
    sv.forceKill(sr.id)
    ev = sv.next(getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    let report = sv.reap(ev.id)
    check report.stop.isSome
    check report.stop.get.reason == krTimeout
    check report.stop.get.escalated == true
    check report.exit.kind == ekSignaled
    check report.exit.sig == int(SIGKILL)
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 5 — output caps: StdioSink is by-path (§1); capping/truncation is a
# READ-time property of that file, never silent. The helper below is a
# TEST-ONLY mirror of the shape runner.nim's `readCapped` already implements
# in production — deliberately re-derived here rather than imported, so this
# suite stays decoupled from crisol/runner (see the file header's honest
# note: proving the contract, not the runner's use of it). noisy_output
# writes a deterministic a-z pattern, so both the truncated and untruncated
# reads are checked byte-for-byte, not just by length.
# ---------------------------------------------------------------------------

proc expectedPattern(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(ord('a') + (i mod 26))

proc readWithCap(path: string; maxBytes: int): tuple[content: string; truncated: bool] =
  let size = getFileSize(path)
  if size <= int64(maxBytes):
    return (readFile(path), false)
  let f = open(path, fmRead)
  defer: f.close()
  var buf = newString(maxBytes)
  discard f.readBuffer(addr buf[0], maxBytes)
  (buf, true)

suite "conformance 5 — output caps":

  test "output beyond the cap is truncated AND reported truncated, never silently":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("cap_over")
    let spec = ChildSpec(argv: @[noisyBin], cwd: getCurrentDir(),
                          env: @[("CRISOL_NOISY_BYTES", "200000")],
                          sinks: combinedSink(outPath))
    let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    check report.exit.kind == ekExited
    check report.exit.code == 0
    let (content, truncated) = readWithCap(outPath, 65_536)
    check truncated == true
    check content.len == 65_536
    check content == expectedPattern(65_536)   # exactly the first N bytes — no corruption
    removeFile(outPath)

  test "output under the cap is reported NOT truncated, and reaches the sink whole":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("cap_under")
    let spec = ChildSpec(argv: @[noisyBin], cwd: getCurrentDir(),
                          env: @[("CRISOL_NOISY_BYTES", "100")],
                          sinks: combinedSink(outPath))
    let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    check report.exit.kind == ekExited
    let (content, truncated) = readWithCap(outPath, 65_536)
    check truncated == false
    check content == expectedPattern(100)
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 6 — achieved readback: requested limits -> LimitsAchieved lsApplied;
# unrequested limits -> lsNotRequested. Generous values (pass_always does no
# I/O, no CPU burn, no large allocation) so setrlimit + readback succeeds
# deterministically without racing a signal.
# ---------------------------------------------------------------------------

suite "conformance 6 — achieved readback":

  test "requested limits read back lsApplied; unrequested read back lsNotRequested":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("achieved")
    var limits = Limits()
    limits.req[lkFileSize] = some(10_000_000'i64)
    limits.req[lkCore]     = some(0'i64)
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath), limits: limits)
    let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 5))
    check ev.kind == weChildExited
    check report.exit.kind == ekExited
    check report.exit.code == 0
    check report.limits[lkFileSize] == lsApplied
    check report.limits[lkCore] == lsApplied
    check report.limits[lkCpu] == lsNotRequested
    check report.limits[lkAddressSpace] == lsNotRequested
    check report.limits[lkOpenFiles] == lsNotRequested
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 7 — spawn error: nonexistent binary, no zombie, no fabricated Exit.
# ---------------------------------------------------------------------------

suite "conformance 7 — spawn error":

  test "nonexistent binary: SpawnResult ok:false, never a crash, never a fabricated Exit":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("spawn_error")
    let spec = ChildSpec(argv: @["crisol_conformance_nonexistent_binary_zzz"],
                          cwd: getCurrentDir(), env: @[], sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check not sr.ok
    check sr.error.len > 0
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 8 — level-triggered re-report: an unreaped exited child is re-reported
# by next() every call, not dropped after the first observation.
# ---------------------------------------------------------------------------

suite "conformance 8 — level-triggered re-report":

  test "an exited-but-unreaped child is reported again on the next next() call":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("level_triggered")
    let spec = ChildSpec(argv: @[passBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    let deadline = getMonoTime() + initDuration(seconds = 5)
    let ev1 = sv.next(deadline)
    check ev1.kind == weChildExited
    let ev2 = sv.next(deadline)   # still unreaped: must report the SAME id again
    check ev2.kind == weChildExited
    check ev2.id == ev1.id
    discard sv.reap(ev1.id)
    removeFile(outPath)

when isMainModule:
  echo "test_conformance done"
