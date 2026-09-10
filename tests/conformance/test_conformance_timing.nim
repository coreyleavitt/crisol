## test_conformance_timing.nim — rfc-0007 A2a-ii: the conformance suite's
## THREE wall-clock-sensitive pins, driven through `process.nim` ONLY (same
## rule as test_conformance.nim; enforced by test_conformance_import_purity.nim
## across this whole directory):
##
##   - timeout-kill grace timing: requestStop -> the child is confirmed dead
##     well inside one grace window, not "eventually" (test_conformance.nim's
##     item 2/3 case proves the FUNCTIONAL honest-Exit shape with generous
##     deadlines; this proves the WALL-CLOCK bound).
##   - item 4: shared grace window — N children stopped together tear down in
##     ONE grace window, not N sequential ones.
##   - item 9: shutdown wakeup — a signal delivered while blocked in next()
##     returns weShutdown well before the deadline.
##
## GATING: quits 0 immediately when CRISOL_TIMING_TESTS is unset/empty — same
## convention as tests/timing/*.nim (see test_rlimits_timing.nim), so
## `./dev test` / the main CI leg never eats this file's flake risk under
## concurrent host load. `./dev timing` and the serial CI timing job set
## CRISOL_TIMING_TESTS=1 and include tests/conformance in CRISOL_TEST_DIRS.
##
## HONEST NOTE: as in test_conformance.nim, this proves the §1 CONTRACT —
## the product runner has executed the Supervisor since A2b (this file's
## item-4 shared-grace-window case is the primitive-level proof; the
## runner-level acceptance lives in tests/timing/test_rfc0007_a2b_shared_grace.nim).
##
## Run with:
##   ./dev timing
## or, for this file alone:
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
##     --path:src tests/conformance/test_conformance_timing.nim

import std/[os, osproc, posix, unittest, monotimes, times, sequtils, options]

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

import ./helpers

# ---------------------------------------------------------------------------
# Fixtures compiled once at module load (after the gate — never compiled on
# the main leg).
# ---------------------------------------------------------------------------

let hangBin        = compileFixture("hang_forever")
let termIgnoresBin = compileFixture("term_ignores")
let sleepBin       = compileFixture("sleep_then_exit")

# ---------------------------------------------------------------------------
# Timeout-kill grace timing.
# ---------------------------------------------------------------------------

suite "conformance timing — timeout-kill grace timing":

  test "hang_forever dies within one grace window of requestStop, not merely 'eventually'":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("timing_grace_single")
    let spec = ChildSpec(argv: @[hangBin], cwd: getCurrentDir(), env: @[],
                          sinks: combinedSink(outPath))
    let sr = sv.spawn(spec)
    check sr.ok
    let t0 = getMonoTime()
    sv.requestStop(sr.id, krTimeout)
    let ev = sv.next(t0 + initDuration(seconds = 5))
    let elapsed = getMonoTime() - t0
    check ev.kind == weChildExited
    discard sv.reap(ev.id)
    echo "  observed: hang_forever died ", elapsed.inMilliseconds, " ms after requestStop"
    # A generous bound (SIGTERM default disposition is near-instant on any
    # host; 1s covers scheduler noise) — pins "in grace", not "on a timer".
    check elapsed < initDuration(seconds = 1)
    removeFile(outPath)

# ---------------------------------------------------------------------------
# Item 4 — shared grace window: N children stopped together tear down in ONE
# grace window, not N sequential ones. requestStop is non-blocking (§1) —
# the executor pattern below is exactly what A2b's teardown machinery does:
# fire all the stop acts, THEN wait once with a single shared deadline.
# ---------------------------------------------------------------------------

suite "conformance timing — item 4: shared grace window":

  test "3 term_ignores children, stopped together, tear down in ~one grace window":
    const graceMs = 300
    var sv = initSupervisor(installSignals = false)
    var outPaths: seq[string]
    var ids: seq[ChildId]
    for i in 0 ..< 3:
      let outPath = tmpOutputFile("shared_grace_" & $i)
      outPaths.add outPath
      let spec = ChildSpec(argv: @[termIgnoresBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      check sr.ok
      ids.add sr.id
    # term_ignores installs SIG_IGN in the first line of main — same startup
    # race note as test_conformance.nim's item 3 case.
    os.sleep(150)

    let t0 = getMonoTime()
    for id in ids:
      sv.requestStop(id, krTimeout)   # non-blocking (§1) — fired for all 3 up front

    # Reap each child the MOMENT it's observed exited, not after the whole
    # batch: next() is level-triggered (§1) — an unreaped exited child is
    # re-reported on every call, so leaving one unreaped would starve the
    # scan of ever noticing its siblings exit. Reporting is deferred into
    # `reports`, keyed by id, so the escalated/exit assertions below still
    # run once, after the whole batch is down.
    var reports: seq[tuple[id: ChildId; report: ReapReport]]
    let graceDeadline = t0 + initDuration(milliseconds = graceMs)
    while getMonoTime() < graceDeadline and reports.len < ids.len:
      let ev = sv.next(graceDeadline)
      if ev.kind == weChildExited:
        reports.add (ev.id, sv.reap(ev.id))

    # term_ignores never dies cooperatively (SIG_IGN) — escalate whoever's left.
    let reapedSoFar = reports.len
    for id in ids:
      if not reports.anyIt(it.id == id):
        sv.forceKill(id)

    let killDeadline = getMonoTime() + initDuration(seconds = 5)
    while reports.len < ids.len:
      let ev = sv.next(killDeadline)
      check ev.kind == weChildExited   # never weDeadline — all 3 must die
      reports.add (ev.id, sv.reap(ev.id))

    let totalElapsed = getMonoTime() - t0
    check reapedSoFar == 0   # SIG_IGN: none died cooperatively during grace
    for (_, report) in reports:
      check report.stop.isSome
      check report.stop.get.escalated == true
      check report.exit.kind == ekSignaled
      check report.exit.sig == int(SIGKILL)

    echo "  observed: 3 children stopped together, all reaped in ",
         totalElapsed.inMilliseconds, " ms (grace window: ", graceMs, " ms)"
    # ONE shared grace window, not three sequential ones: 3 serial
    # (grace + kill-response) cycles would be >= 3 * graceMs (900ms) before
    # even counting kill-response time. A generous bound catches a
    # regression to N sequential windows while tolerating scheduler noise.
    check totalElapsed < initDuration(milliseconds = graceMs * 2)

    for p in outPaths: removeFile(p)

# ---------------------------------------------------------------------------
# Item 9 — shutdown wakeup: a signal delivered while blocked in next()
# returns weShutdown well before the deadline (moved from
# tests/integration/test_rfc0007_a2a_supervisor.nim's A2a-i seed case, now
# gated per this file's header).
# ---------------------------------------------------------------------------

suite "conformance timing — item 9: shutdown wakeup":

  test "a signal delivered while blocked in next() returns weShutdown promptly":
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
    let elapsed = getMonoTime() - t0
    check ev.kind == weShutdown
    check ev.signal.signum == int(SIGINT)
    echo "  observed: weShutdown ", elapsed.inMilliseconds,
         " ms after signal delivery (deadline was 10000 ms out)"
    check elapsed < initDuration(seconds = 2)   # well before the 10s deadline
    discard waitForExit(helper)
    close(helper)


# ---------------------------------------------------------------------------
# rfc-0007 B2 — event-driven exit detection: a registered child's pidfd
# becoming readable wakes `next()` directly, instead of waiting out the
# poll(2)-tier's up-to-25ms tick. `CRISOL_FORCE_POLL=1` (this file's own
# knob-under-test) picks the OTHER bound deliberately, so running this suite
# under both env states (see this repo's `./dev test` / `./dev timing` CI
# wiring) proves both tiers live, not just the default one.
#
# Run BOTH tiers directly:
#   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
#     --path:src tests/conformance/test_conformance_timing.nim
#   ./dev run env CRISOL_TIMING_TESTS=1 CRISOL_FORCE_POLL=1 nim r \
#     --hints:off --warnings:off --path:src tests/conformance/test_conformance_timing.nim
# ---------------------------------------------------------------------------

suite "conformance timing — B2: event-driven exit detection":

  test "a child's exit is observed promptly, not merely within the old 25ms poll tick":
    var sv = initSupervisor(installSignals = false)
    let outPath = tmpOutputFile("b2_latency")
    const sleepMs = 200
    let spec = ChildSpec(argv: @[sleepBin], cwd: getCurrentDir(),
                          env: @[("CRISOL_SLEEP_MS", $sleepMs)],
                          sinks: combinedSink(outPath))
    let t0 = getMonoTime()
    let sr = sv.spawn(spec)
    check sr.ok
    let ev = sv.next(t0 + initDuration(seconds = 5))
    let elapsed = getMonoTime() - t0
    check ev.kind == weChildExited
    discard sv.reap(ev.id)
    echo "  observed: exit detected ", elapsed.inMilliseconds,
         " ms after spawn (fixture slept ", sleepMs, " ms)"
    let forcedPoll = getEnv("CRISOL_FORCE_POLL", "") notin ["", "0"]
    if forcedPoll:
      # Poll(2) fallback tier: bounded by the retained ~25ms tick, same
      # latency shape as pre-B2 — generous margin for scheduler noise.
      check elapsed < initDuration(milliseconds = sleepMs + 60)
    else:
      # Event-driven tier: the child's pidfd becomes readable and wakes
      # epoll_wait directly — detection latency is scheduling noise, not a
      # poll quantum. A regression back to a poll-shaped wait (forgetting to
      # register/consult the pidfd) would blow this bound.
      check elapsed < initDuration(milliseconds = sleepMs + 20)
    removeFile(outPath)

# ---------------------------------------------------------------------------
# rfc-0007 C1b — kqueue EVFILT_PROC event-driven exit detection (macOS).
# Mirrors the B2 latency case above exactly, pinned to Darwin's kqueue
# backend rather than Linux's epoll/pidfd one. Only compiled on macOS: B2
# above already proves the Linux side, and this suite exists specifically to
# prove the OTHER platform's mechanism actually engages, not to duplicate the
# same fact twice.
#
# Run BOTH tiers directly on a macOS host:
#   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
#     --path:src tests/conformance/test_conformance_timing.nim
#   ./dev run env CRISOL_TIMING_TESTS=1 CRISOL_FORCE_POLL=1 nim r \
#     --hints:off --warnings:off --path:src tests/conformance/test_conformance_timing.nim
# ---------------------------------------------------------------------------

when defined(macosx):
  suite "conformance timing — C1b: kqueue event-driven exit detection (macOS)":

    test "a child's exit is observed promptly on the real kqueue backend, not the poll(2) tick":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("c1b_kqueue_latency")
      const sleepMs = 200
      let spec = ChildSpec(argv: @[sleepBin], cwd: getCurrentDir(),
                            env: @[("CRISOL_SLEEP_MS", $sleepMs)],
                            sinks: combinedSink(outPath))
      let t0 = getMonoTime()
      let sr = sv.spawn(spec)
      check sr.ok
      let ev = sv.next(t0 + initDuration(seconds = 5))
      let elapsed = getMonoTime() - t0
      check ev.kind == weChildExited
      discard sv.reap(ev.id)
      echo "  observed: exit detected ", elapsed.inMilliseconds,
           " ms after spawn (fixture slept ", sleepMs, " ms)"
      let forcedPoll = getEnv("CRISOL_FORCE_POLL", "") notin ["", "0"]
      if forcedPoll:
        # Poll(2) fallback tier: bounded by the retained ~25ms tick, widened
        # relative to B2's Linux bound — GitHub's macos-latest runners are
        # measurably slower/noisier under CI load (the same reason C1a
        # widened `ccSpanUs`).
        check elapsed < initDuration(milliseconds = sleepMs + 100)
      else:
        # Event-driven tier: the child's kqueue registration
        # (EVFILT_PROC/NOTE_EXIT) fires and wakes `kevent` directly —
        # detection latency is scheduling noise, not a poll quantum. Wider
        # than B2's Linux `sleepMs + 20` for the same runner-noise reason,
        # but still well under the poll(2) fallback's own worst case above —
        # a regression back to a poll-shaped wait (forgetting to
        # register/consult the kqueue fd) still fails this.
        check elapsed < initDuration(milliseconds = sleepMs + 50)
      removeFile(outPath)

when isMainModule:
  echo "test_conformance_timing done"
