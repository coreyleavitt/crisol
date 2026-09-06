## test_so2_drain_interrupt.nim — RFC-0005 code-review SO2: the end-of-run
## deferred-put drain (`api.runTestsWith`'s `drainPending` call site) must
## never fire on an INTERRUPTED run.
##
## Real signal delivery happens inside a FORKED child process (mirrors
## test_signal.nim's own convention/rationale, and test_run_tests.nim's own
## documented discipline of confining real signal delivery to a forked
## child) — the parent test process is never touched by SIGINT.
##
## Strategy (mirrors tests/timing/test_interrupt_e2e.nim's proven jobs=2
## race-free pattern, in-process via `runTestsWith` rather than a compiled
## CLI subprocess — the injected two-tier `CacheDeps` this proves against
## is a test-only seam with no CLI surface):
##   1. Fork a child. Inside it: build a two-`memory`-tier `CacheDeps` (l1 +
##      a counting-wrapped l2 "remote" tier) and run `runTestsWith` over
##      `pass_fast.nim` (fast — writes a marker file, then exits 0) and
##      `hang_forever.nim` (never exits on its own), `jobs: 2` so both are
##      dispatched together — `hang_forever`'s compile is at least as fast
##      as `pass_fast`'s compile+run (test_interrupt_e2e.nim's own
##      established rationale), so by the time the marker file appears
##      `hang_forever` is guaranteed already in flight.
##   2. `pass_fast` finishing publishes to l1 AND queues an entry on
##      `rt.pending` (a remote tier is configured — `realSeams.store`'s own
##      rule). The child's own `installSignals: true` Supervisor is still
##      blocked on `hang_forever`.
##   3. The PARENT polls for the marker file, then sends a REAL SIGINT to
##      the child process.
##   4. The child's `execute()` returns with `interrupted: true`. Before
##      this fix, `api.runTestsWith`'s drain gate ignored `interrupted` and
##      would flush the queued entry to l2 anyway; after the fix, the drain
##      is skipped entirely.
##   5. The child writes `interrupted,l2PutCalls` to a result file and
##      exits; the parent asserts `interrupted == true` AND `l2PutCalls ==
##      0` — the queued entry was never flushed to the remote tier.

import std/[os, posix, strutils, times, unittest]
import crisol/api
import crisol/sandbox
import crisol/types      # CacheConfig
import crisol/cachetier   # Tier, TieredCache
import crisol/cachememory # memory()
import crisol/cacheregistry # CacheRuntime
import crisol/cacheport  # CacheBackend, nonePolicy, NilSink
import crisol/cachetelemetry # TelemetryEvent

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  thisFile.parentDir.parentDir / "fixtures"

proc pollForFile(path: string; timeoutMs: int): bool =
  let step = 50
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc countingPutBackend(inner: CacheBackend): tuple[backend: CacheBackend; putCalls: ref int] =
  ## Wraps `inner` so a test can prove its `put` was NEVER called, without
  ## needing to know the exact `SoundnessKey` a live run derives (mirrors
  ## test_cachetier.nim's `countingBackend`, scoped to `put` only since
  ## `get` is never exercised by this scenario).
  let putCalls = new(int)
  let captured = inner
  let backend = CacheBackend(
    scheme: captured.scheme,
    get:    captured.get,
    put:    proc(entry: StoredEntry): CacheVerdict =
              inc putCalls[]
              captured.put(entry),
    probe:  captured.probe,
  )
  (backend, putCalls)

suite "RFC-0005 code-review SO2 — end-of-run drain skipped on an interrupted run":

  test "SIGINT mid-run: a fast entrypoint's already-queued remote entry is never flushed":
    let tag        = "crisol_so2_drain_" & $getpid()
    let markerFile = getTempDir() / (tag & "_marker")
    let resultFile = getTempDir() / (tag & "_result")
    let stateDir   = getTempDir() / (tag & "_state")

    if fileExists(markerFile): removeFile(markerFile)
    if fileExists(resultFile): removeFile(resultFile)
    removeDir(stateDir)
    createDir(stateDir)
    defer:
      try: removeFile(markerFile) except: discard
      try: removeFile(resultFile) except: discard
      try: removeDir(stateDir) except: discard

    let childPid = fork()
    check childPid >= 0

    if childPid == 0:
      # =====================================================================
      # CHILD: install signal handlers (installSignals:true), run over
      # pass_fast.nim + hang_forever.nim with a two-tier CacheDeps.
      # =====================================================================
      putEnv("CRISOL_PASS_FAST_MARKER", markerFile)
      putEnv("CRISOL_STATE_DIR", stateDir)

      let l1 = memory()
      let (l2, l2PutCalls) = countingPutBackend(memory())

      let deps = CacheDeps(buildRuntime: proc(cfg: CacheConfig; sd: string; maxEntries: int): CacheRuntime =
        discard cfg; discard sd; discard maxEntries
        CacheRuntime(
          cache: TieredCache(
            tiers: @[
              Tier(name: "l1", backend: l1, backfillOnHit: false, verifyTrust: false),
              Tier(name: "l2", backend: l2, backfillOnHit: false, verifyTrust: false),
            ],
            trust: nonePolicy(),
          ),
          sink: NilSink[TelemetryEvent](),
        ))

      let fdir = fixtureDir()
      let opts = RunOptions(
        selection:      filesSelection(fdir / "pass_fast.nim", fdir / "hang_forever.nim"),
        jobs:           2,
        timeoutSecs:    300,
        hermeticLevel:  hlNone,   # CRISOL_PASS_FAST_MARKER must reach pass_fast.nim
        installSignals: true,
        persist:        false,
        manageLock:     true,
      )

      try:
        let rr = runTestsWith(opts, deps)
        writeFile(resultFile, (if rr.interrupted: "1" else: "0") & "," & $l2PutCalls[])
      except:
        writeFile(resultFile, "EXC," & getCurrentExceptionMsg())
      quit(0)
      # =====================================================================

    # -------------------------------------------------------------------
    # PARENT: wait for pass_fast's marker, then send a real SIGINT.
    # -------------------------------------------------------------------
    let appeared = pollForFile(markerFile, 60_000)
    check appeared
    if not appeared:
      discard kill(childPid, SIGKILL)
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      fail()
    else:
      check kill(childPid, SIGINT) == 0

      var wstatus: cint = 0
      let deadline = epochTime() + 30.0
      var reaped = false
      while epochTime() < deadline:
        let r = waitpid(childPid, wstatus, WNOHANG)
        if r == childPid:
          reaped = true
          break
        os.sleep(100)
      check reaped

      check fileExists(resultFile)
      if fileExists(resultFile):
        let parts = readFile(resultFile).strip().split(',')
        check parts.len == 2
        if parts.len == 2:
          check parts[0] == "1"    # rr.interrupted == true
          check parts[1] == "0"    # l2's put was never called
