## test_rfc0007_r16_persist_tail_lock_leak.nim -- rfc-0007 code-review r16:
## `runTestsWith`'s post-execute() tail (drainPending, perf-check ledger
## scans, persistLastRun, aggregateCacheStats) had no try/finally around
## the advisory lock -- an exception escaping ANY of those steps skipped
## `releaseLock`, leaking the lock for the lifetime of a library-embedding
## host process (the CLI is saved only by process exit).
##
## The one concretely reachable escape: `persistLastRun`'s own documented
## contract (jsonout.nim) is "on any failure: prints a warning to stderr
## and returns -- never raises" -- but that contract has exactly one gap:
## its OWN warning-write can itself raise (e.g. a closed/broken stderr) at
## the moment it tries to report an unwritable persist target.
##
## Portable injection (no std/posix): `close(stderr)` so any write to it
## raises -- Nim's `system.close`/`open` on a `File` work identically on
## POSIX and Windows, unlike a raw fd dup/close pair -- THEN make the
## persist target unwritable (pre-create `<stateDir>/lastrun.json` as a
## DIRECTORY, so `atomicPublish`'s `rename(2)` fails and `persistLastRun`
## falls into its "could not write lastrun.json" warning branch). `stderr`
## is reopened (redirected to a scratch file, not the original stream)
## immediately after call 1 so the second call -- and this test's own
## diagnostics -- are unaffected by the deliberately-broken stream.
##
## Drives `runTests()` directly, in-process, TWICE, against an isolated
## `CRISOL_STATE_DIR` (own state dir, never the ambient project's --
## mirrors tests/integration/test_rfc0007_w2_limit_wiring.nim's isolation
## rationale, and test_so2_drain_interrupt.nim's own direct-`runTests`-
## style, `CRISOL_STATE_DIR`-only isolation, since ad-hoc `filesSelection`
## paths need no separate tmp PROJECT dir).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r16_persist_tail_lock_leak.nim

import std/[os, times, unittest]
import crisol/api

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  thisFile.parentDir.parentDir / "fixtures"

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_r16_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

suite "rfc-0007 r16 -- runTestsWith tail: no raw exception, no lock leak":

  test "persistLastRun's own warning-write failing does not raise or leak the advisory lock":
    let stateDir = uniqueTmpDir("state")
    createDir(stateDir)
    defer: removeDir(stateDir)
    putEnv("CRISOL_STATE_DIR", stateDir)
    defer: delEnv("CRISOL_STATE_DIR")

    let lastrunPath = stateDir / "lastrun.json"
    # Injection half 1: pre-create the persist target AS A DIRECTORY so
    # atomicPublish's rename(2) reliably fails (EISDIR) cross-container.
    # persistLastRun's own `createDir(stateDir)` no-ops (stateDir already
    # exists, from the line above), so this fails ONLY the leaf write --
    # exactly the "could not write lastrun.json" branch, not the
    # "could not create state dir" one.
    createDir(lastrunPath)

    let opts = RunOptions(
      selection:  filesSelection(fixtureDir() / "pass_always.nim"),
      jobs:       1,
      persist:    true,
      manageLock: true,
      noCache:    true,   # I/O-minimal; the cache pipeline is irrelevant to r16
    )

    let scratchStderr = stateDir / "scratch_stderr.txt"

    # Injection half 2: close stderr so persistLastRun's own warning-write
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

    # RED-today failure mode (i): persistLastRun's own warning-write raises
    # a raw, unhandled exception straight out of runTests() -- violating
    # the facade's documented "never raises for expected conditions"
    # contract (api.nim's own `runTests*` doc comment).
    check not raised1
    if raised1:
      echo "runTests() call 1 raised: ", excMsg1
    else:
      # The chosen convention (rfc-0007 r16 fix): an environmental persist
      # failure surfaces as a best-effort warning, never destroying an
      # otherwise-complete run report -- the run itself still succeeded.
      check rr1.status == rsOk
      check rr1.exitCode == 0

    # Clean the injection so the second run's persist path is a normal,
    # unobstructed success -- proves "the normal path still releases (a
    # plain second run works)", not merely "the lock isn't held forever".
    removeDir(lastrunPath)

    # RED-today failure mode (ii): if call 1's exception escaped BEFORE
    # reaching `releaseLock` (the actual r16 defect), the advisory lock on
    # `<stateDir>/lock` is still held. This second call's `acquireLock` is
    # non-blocking (LOCK_NB) and fails FAST with CrisolError(cekEnvironment)
    # ("another crisol run is in progress"), surfaced here as
    # `rr2.status == rsStructural` -- never a hang, so this assertion alone
    # is a reliable, bounded-time leak detector.
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
      check rr2.exitCode == 0
      if rr2.status != rsOk:
        echo "call 2 status=", rr2.status, " error=", rr2.error
