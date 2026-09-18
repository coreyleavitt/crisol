## test_rfc0007_r3_library_embedding.nim — rfc-0007 code-review finding r3:
## library-embedding hazards + subreaper permanence.
##
## A Supervisor is not always the whole process — crisol runs embedded
## inside a longer-lived HOST application (e.g. amoxtli), where `ownPid` IS
## the host's own pid and the host may already have its own, unrelated
## children running before the Supervisor is ever constructed. Two hazards:
##
##   (a) a run-phase reap's escapee-kill scan walks every live pid whose
##       ppid == ownPid that is not a registered slot — a host's own
##       pre-existing child qualifies by that test alone, so an unfixed
##       Supervisor SIGKILLs it mid-run and steals its exit status.
##   (b) the subreaper bit, once set, was never cleared at teardown — a
##       Supervisor destroyed inside a still-running host left every LATER
##       orphan of unrelated host code reparenting here with no loop left
##       to sweep them.
##
## This proves both through the real Supervisor lifecycle (`crisol/process`
## — the §1 backend-selection ladder — via this directory's own
## `./helpers` re-export, never a backend module directly; see
## test_conformance_import_purity.nim in this directory):
##   1. Fork a "host child" BEFORE `initSupervisor` — a marker-synced
##      sleeper standing in for the host application's own pre-existing
##      worker.
##   2. `initSupervisor`, spawn+run+reap ONE normal quick child with
##      `runPhase = true` — the exact condition that engages the
##      escapee-kill scan.
##   3. Destroy the Supervisor (block-scope end triggers its `=destroy`).
##   4. Assert: the host child is still alive; this test process can still
##      `waitpid` it normally (no ECHILD — its exit status was never
##      stolen); the subreaper readback is back to 0.
##
## The subreaper readback below is a SECOND, independent FFI import — same
## discipline tests/unit/test_process_capabilities.nim's own cross-check
## uses — never the same code path the backend itself calls internally, so
## the two can never share a bug.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_rfc0007_r3_library_embedding.nim

when defined(linux):
  import std/[os, posix, strutils, unittest, monotimes, times]
  import ./helpers

  proc c_prctl_r3(option: cint): cint {.importc: "prctl", varargs,
                                        header: "<sys/prctl.h>".}
  var PR_GET_CHILD_SUBREAPER_r3 {.importc: "PR_GET_CHILD_SUBREAPER",
                                  header: "<sys/prctl.h>".}: cint

  proc subreaperReadback(): int =
    var val: cint = -1
    let rc = c_prctl_r3(PR_GET_CHILD_SUBREAPER_r3, addr val)
    doAssert rc == 0, "PR_GET_CHILD_SUBREAPER readback failed"
    int(val)

  proc writeMarker(path, s: string) =
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    if fd >= 0:
      discard posix.write(fd, s.cstring, s.len)
      discard posix.close(fd)

  proc pollForFile(path: string; timeoutMs: int): bool =
    let step = 20
    var elapsed = 0
    while elapsed < timeoutMs:
      if fileExists(path): return true
      os.sleep(step)
      elapsed += step
    false

  suite "rfc-0007 r3 — library-embedding hazards":

    test "a Supervisor never kills/steals the host's own pre-existing child, and clears the subreaper bit at teardown":
      let caps = capabilities()
      if not (caps.subreaper and caps.pidfd):
        skip()
      else:
        let dir = getTempDir() / ("crisol_r3_" & $getCurrentProcessId())
        removeDir(dir); createDir(dir)
        defer: removeDir(dir)

        let markerPath = dir / "host_child.pid"
        let releasePath = dir / "host_child_release"

        # ---------------------------------------------------------------
        # Step 1 — fork the "host child" BEFORE any Supervisor exists.
        # ---------------------------------------------------------------
        let hostChildPid = fork()
        check hostChildPid >= 0
        if hostChildPid == 0:
          # CHILD — stands in for an unrelated worker the host application
          # already had running. Never falls through into the rest of this
          # unittest binary: exitnow only, past this point.
          writeMarker(markerPath, $getpid())
          var waited = 0
          while not fileExists(releasePath) and waited < 20_000:
            os.sleep(20)
            waited += 20
          exitnow(0)

        # ---------------------------------------------------------------
        # PARENT (this test process) from here on. Always release + reap
        # the host child, even on a failed assertion above.
        # ---------------------------------------------------------------
        defer:
          writeMarker(releasePath, "go")
          var hostStatus: cint = 0
          discard waitpid(hostChildPid, hostStatus, 0)

        check pollForFile(markerPath, 5_000)
        let hostChildRealPid = Pid(parseInt(readFile(markerPath).strip()))
        check int(hostChildRealPid) == int(hostChildPid)

        # ---------------------------------------------------------------
        # Step 2 — Supervisor lifecycle: init, spawn+run+reap ONE normal
        # quick child with runPhase = true (the exact condition that
        # engages the escapee-kill scan this finding is about), then let
        # the block end so `=destroy` runs deterministically here.
        # ---------------------------------------------------------------
        block:
          var sv = initSupervisor(installSignals = false)
          check subreaperReadback() == 1   # sanity: this core did set it

          let bin = compileFixture("pass_always")
          let outPath = tmpOutputFile("r3_quick_child")
          let spec = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                                sinks: combinedSink(outPath))
          let sr = sv.spawn(spec)
          check sr.ok
          let ev = sv.next(getMonoTime() + initDuration(seconds = 5))
          check ev.kind == weChildExited
          discard sv.reap(ev.id, runPhase = true)
          removeFile(outPath)

          # The host child must still be genuinely alive here — kill(pid,
          # 0) fails ESRCH only once the pid is gone (dead AND reaped, or
          # never existed); a live process (running or zombie) succeeds.
          # It is NOT yet a zombie (it is still polling for `releasePath`,
          # written only in the `defer` above, after this block ends).
          check kill(hostChildRealPid, 0.cint) == 0

        # ---------------------------------------------------------------
        # Step 3/4 — after destroy: subreaper bit cleared.
        # ---------------------------------------------------------------
        check subreaperReadback() == 0

        # The `defer` above releases the host child and waitpid()s it;
        # if its exit status had been stolen by the Supervisor's escapee
        # scan, that waitpid would return ECHILD instead of the real pid —
        # asserted here via a second, explicit waitpid before the defer's
        # own (which would then just see ECHILD silently). To observe it
        # honestly, release + wait explicitly, then let the defer's own
        # waitpid degrade to a harmless no-op (already-reaped).
        writeMarker(releasePath, "go")
        var hostStatus: cint = 0
        let waited = waitpid(hostChildRealPid, hostStatus, 0)
        check waited == hostChildRealPid   # never ECHILD — never stolen
        check WIFEXITED(hostStatus)
        check WEXITSTATUS(hostStatus) == 0

  echo "test_rfc0007_r3_library_embedding: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/conformance/test_rfc0007_r3_library_embedding.nim"
    echo "test_rfc0007_r3_library_embedding: skipped (Linux-only: PR_SET_CHILD_SUBREAPER " &
         "has no Darwin/Windows analog)"
