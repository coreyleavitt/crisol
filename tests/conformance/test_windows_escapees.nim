## test_windows_escapees.nim — rfc-0007 review fix r4: `reap()`'s escapees
## must report genuine survivors OBSERVED at reap time, never a hardcoded
## `@[]`.
##
## Before this fix, process/windows.nim's `reap()` always reported
## `escapees: @[]`, justified as "breakaway denied => nothing can leave the
## Job". That justification conflates two separate claims (contract,
## process/types.nim's `escapees` doc / rfc-0007 docs §1/§6): "nothing can
## LEAVE the Job" (true — breakaway is denied, see
## test_windows_containment.nim) is NOT the same claim as "nothing survives
## past this reap" — the contract defines escapees as survivors OBSERVED at
## kill/reap time, counted "even where the escapees were then reaped" (the
## POSIX subreaper tier's own kill-then-report shape, see
## test_rfc0007_a6a_escapee_evidence.nim's Suite 1). A leaky-but-passing
## entrypoint (this file's fixture, leaky_child.nim) spawns a plain,
## contained, non-breakaway child and exits 0 WHILE that child is still
## alive — the old code reported clean (cacheable) evidence even though a
## real process was still running inside the Job at the moment of the
## report, only killed AFTERWARD, silently, at `closeHandle(entry.hJob)`
## (KILL_ON_JOB_CLOSE) — after the report had already been sealed.
##
## This file proves the fix: `reap`'s report now carries a non-empty
## `escapees` for this exact shape, the windows-backend mirror of
## test_rfc0007_a6a_escapee_evidence.nim's POSIX proof (same fixture shape
## as spawn_grandchild.nim: a clean pass that leaves a live descendant
## behind).
##
## CANNOT be verified RED-then-GREEN locally — windows code only runs on
## the windows CI leg (see this repo's cross-platform convention: every
## other `test_windows_*.nim` file). This file's assertions are therefore
## UNVERIFIED against real Windows as of this commit; they are written
## sharp (an exact `> 0` length check plus a real-pid sanity check, no
## loose bound) specifically so a regression back to the `@[]` hardcode —
## or any future change that silently drops this observation — fails
## loudly on the windows CI leg rather than passing vacuously.
##
## Compile-time gated to `defined(windows)` (mirrors every other
## `test_windows_*.nim` file): the `else` branch must still compile and
## exit cleanly on Linux/macOS, since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file under tests/ regardless of host
## platform.

when defined(windows):
  import std/[os, unittest, monotimes, times]
  import ./helpers

  let leakyBin = compileFixture("leaky_child")

  suite "rfc-0007 review r4 — windows reap() reports genuine Job survivors":

    test "leaky_child: parent exits 0 while its contained child is still alive -- escapees.len > 0":
      var sv = initSupervisor(installSignals = false)
      let markerPath = tmpOutputFile("win_escapee_marker")
      let outPath = tmpOutputFile("win_escapee_out")
      let spec = ChildSpec(argv: @[leakyBin, markerPath], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))
      removeFile(markerPath)
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0   # the entrypoint itself is a clean pass

      # r4's load-bearing assertion: the still-alive grandchild is a
      # genuine survivor at reap time -- never the fabricated `@[]`.
      require report.escapees.len > 0
      check report.escapees[0].pid > 0

      # KILL_ON_JOB_CLOSE has ALREADY fired by the time `reap` returns
      # (inside reap(), via closeHandle(entry.hJob), AFTER the report
      # above was built) -- nothing further to clean up here; the Job
      # teardown already killed the grandchild.

  when isMainModule:
    echo "test_windows_escapees done"

else:
  when isMainModule:
    echo "test_windows_escapees: skipped (not windows)"
