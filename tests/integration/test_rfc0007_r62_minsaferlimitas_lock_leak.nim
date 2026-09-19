## test_rfc0007_r62_minsaferlimitas_lock_leak.nim -- code-review r62:
## the MinSafeRlimitAs warning (r18, api.nim) is a bare `stderr.write`
## reached BEFORE `runTestsWith`'s first `try` -- the advisory lock is
## already held by that point (`acquireLock` runs ahead of it, and no
## `finally` covers this span at all). A closed/broken stderr
## (`crisol run 2>&-`) makes that write raise IOError, which used to escape
## `runTestsWith` entirely AND leak the advisory lock for the rest of the
## host process's lifetime -- STRICTLY worse than r16's defect (persistLastRun's
## own warning is at least inside the outer try/finally, so releaseLock still
## ran even when ITS write raised).
##
## Same closed-stderr injection idiom as
## tests/integration/test_rfc0007_r16_persist_tail_lock_leak.nim: `close(stderr)`
## so any write to it raises, portably (POSIX + Windows), via Nim's
## `system.close`/`open` on a `File` rather than a raw fd dup/close pair.
## Kept in its OWN process (own test binary), unlike appending a second
## suite into r16's file, so this test's close/reopen cycle never runs in
## the same process as r16's -- two independent close/reopen cycles against
## `system.stderr` in one process is its own, unrelated hazard this test
## does not need to also prove safe.
##
## The trigger is `RunOptions.rlimits.limitAs` set far below
## `sandbox.MinSafeRlimitAs` (3 GiB) -- the same condition
## test_rfc0007_r18_minsaferlimitas_warning.nim drives through the CLI's
## `--rlimit-as` flag, driven here through the library surface directly so
## it can be paired with the closed-stderr injection in-process.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r62_minsaferlimitas_lock_leak.nim

import std/[options, os, times, unittest]
import crisol/api

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  thisFile.parentDir.parentDir / "fixtures"

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_r62_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

suite "rfc-0007 r62 -- MinSafeRlimitAs warning: no raw exception, no lock leak":

  test "MinSafeRlimitAs warning-write failing (closed stderr) does not raise or leak the advisory lock":
    let stateDir = uniqueTmpDir("state")
    createDir(stateDir)
    defer: removeDir(stateDir)
    putEnv("CRISOL_STATE_DIR", stateDir)
    defer: delEnv("CRISOL_STATE_DIR")

    let opts = RunOptions(
      selection:  filesSelection(fixtureDir() / "pass_always.nim"),
      jobs:       1,
      persist:    false,  # I/O-minimal; r62's warning fires well before any persist attempt
      manageLock: true,
      noCache:    true,
      rlimits:    RlimitOverrides(limitAs: some(1_048_576'i64)),  # 1 MiB, far below MinSafeRlimitAs (3 GiB)
    )

    let scratchStderr = stateDir / "scratch_stderr.txt"

    # Injection: close stderr so the MinSafeRlimitAs warning's own write
    # raises instead of silently succeeding.
    close(stderr)

    var raised1 = false
    var excMsg1 = ""
    var rr1: RunReport
    try:
      rr1 = runTests(opts)
    except CatchableError as e:
      raised1 = true
      excMsg1 = e.msg

    # Reopen stderr -- redirected to a scratch file, not the original
    # stream -- so the second call below, and this test's own diagnostics,
    # are never affected by the deliberately-broken stream above.
    discard open(stderr, scratchStderr, fmWrite)

    # RED-today failure mode (i): the warning's own write raises a raw,
    # unhandled exception straight out of runTests() -- violating the
    # facade's documented "never raises for expected conditions" contract.
    check not raised1
    if raised1:
      echo "runTests() call 1 raised: ", excMsg1
    else:
      # The child likely DOES crash/fail under a 1 MiB address-space
      # ceiling (that's the whole point of the warning) -- this test
      # asserts only that the RUN ITSELF completes normally (rsOk; a
      # crashed/failed entrypoint is an ENTRYPOINT outcome, not a
      # structural failure), never a specific exit code.
      check rr1.status == rsOk

    # RED-today failure mode (ii): if call 1's exception escaped before
    # ever reaching `releaseLock` (the r62 defect -- no enclosing try/
    # finally covers the MinSafeRlimitAs warning at all), the advisory lock
    # on `<stateDir>/lock` is still held. This second call's `acquireLock`
    # is non-blocking (LOCK_NB) and fails FAST with
    # CrisolError(cekEnvironment) ("another crisol run is in progress"),
    # surfaced here as `rr2.status == rsStructural` -- never a hang, so
    # this assertion alone is a reliable, bounded-time leak detector.
    var raised2 = false
    var excMsg2 = ""
    var rr2: RunReport
    try:
      rr2 = runTests(opts)
    except CatchableError as e:
      raised2 = true
      excMsg2 = e.msg

    check not raised2
    if raised2:
      echo "runTests() call 2 raised: ", excMsg2
    else:
      check rr2.status == rsOk
      if rr2.status != rsOk:
        echo "call 2 status=", rr2.status, " error=", rr2.error
