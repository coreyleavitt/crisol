## tests/integration/test_tool_terminate_escalation.nim — R3-3 (code review
## round 3, 2026-09-24): the tool deadline must survive a child that ignores
## SIGTERM.
##
## CR4 put a deadline on the tool-invocation capture layer, and round 3 proved
## the drain loops themselves are live (mutating their four `if left <= 0`
## guards turns `test_tool_capture_deadline.nim` red 3/3). The GIVE-UP path was not
## live. `toolexec.terminateAndReap` did `p.terminate()` and then an UNBOUNDED
## `p.waitForExit()`; on POSIX `terminate()` is SIGTERM alone, so a tool that
## ignores TERM — or one wedged in D-state — was waited on for its entire
## remaining lifetime, AFTER the caller had already printed "giving up".
## Measured on a `cc` shim doing `trap "" TERM; echo banner; sleep 45`:
## `realRunMerged` returned after 45006 ms instead of ~10000. For the case CR4
## was written for (a `git` blocked on a credential prompt, in the host process
## before the Supervisor exists) that wait is unbounded in principle.
##
## `terminateAndReap` now escalates — bounded wait, SIGKILL (unignorable),
## bounded wait. Since R3-12 a bounded run owns its process tree, so on this
## path TERM and KILL go to the tool's process group (`killpg`), with the
## single-process `terminate()`/`kill()` pair kept as the fallback when the
## group could not be set up; `test_tool_tree_termination.nim` pins the
## tree half.
##
## WHAT THIS ASSERTS. The fix has TWO independent halves, and this file pins
## both, because round 4 (R4-2) showed it pinned only one:
##
##   1. ELAPSED TIME. The defect was never a wrong return VALUE:
##      `realRunMerged` reported `ok=false` correctly the whole time. It was
##      the TIME taken to get there. So the first assertion is elapsed
##      duration against the fixture's own lifetime: the call must come back
##      near the probe's composite bound, not near the child's 45 s sleep. A
##      regression therefore makes this test slow and then failing, never
##      hung — the fixture does exit on its own.
##
##   2. THE CHILD IS GONE. Bounding the waits alone caps elapsed time at ~14 s
##      on this path (10 s drain deadline + 2×2 s grace), so the `kill()` was
##      DARK to (1): two reviewers replaced `p.kill()` (now the group
##      `killpg(..., SIGKILL)`) with a no-op and the
##      time assertion stayed green while `ps` showed the TERM-ignoring child
##      still alive, reparented to PID 1, with ~31 s of its sleep left. That
##      is exactly the guarantee `terminateAndReap`'s doc sells ("so a
##      timed-out caller cannot leak a process") and that `gitdiff.runGit`'s
##      call site relies on ("the child has already been terminated and
##      reaped … the caller never needs to clean up itself"), and no other
##      test in the tree asserted it. So after `realRunMerged` returns we go
##      looking for the fixture process and require it to be absent.
##
## WHAT "GONE" MEANS HERE, precisely. `terminateAndReap` ends with the reap
## (`peekExitCode()`, i.e. `waitpid(WNOHANG)`) once its bounded waits have
## seen the child exit, so on the fixed path the child's `/proc` entry is
## already gone when the call returns. No sleep, no retry loop, no polling:
## the ordering is a consequence of `waitpid` having returned, not of luck. A
## ZOMBIE is deliberately NOT what this file hunts: the regression guarded
## here produces a fully ALIVE child, which is what `/proc/<pid>/cmdline`
## sees (a zombie's `cmdline` is empty). The reap itself is pinned separately
## (R5-19, `test_tool_tree_termination.nim`), by the `/proc/<pid>/stat` state
## letter of the tool's own pid.
##
## WHAT THIS DEPENDS ON: Linux `/proc`, enumerated directly — no `ps`, no
## `pgrep`, nothing outside the process's own PID namespace. That dependency is
## asserted, not assumed: if `/proc` is missing the test FAILS with an
## explanation rather than passing vacuously, and `procsRunning` is
## self-checked against this very process first, so a green "no survivors"
## cannot be an artifact of a scanner that finds nothing at all.
##
## POSIX only, and honestly so: on Windows `terminate()` is `TerminateProcess`,
## which a child cannot ignore, so the escalation is unreachable and there is
## nothing to prove. This file lives in `tests/integration/`, which the windows
## and macOS legs sweep only via explicitly pinned per-file steps, and it is
## deliberately NOT pinned there — so it adds no skip to either leg's honesty
## set. The whole-file marker below exists anyway, so that if someone does pin
## it later the skip is visible to `ci/assert-subset-honesty.sh` rather than
## silent (the W5/CR6 class). If you ever pin it on macOS — POSIX, but with no
## `/proc` — you will get a loud red from the dependency check above, not a
## silent hole: replace the OBSERVATION with a Darwin one, never the assertion.

import std/[monotimes, os, times, unittest]

when defined(posix):
  import std/strutils
  import ../support/deadline
  import crisol/toolexec  # TerminateGraceMs — see CeilingMs below
  import crisol/toolrun   # realRunMerged, ToolProbeTimeoutMs

  const
    fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
    binDir     = fixtureDir / "bin" / "r3esc"
    cacheDir   = fixtureDir / "nimcache" / "r3esc"
    srcDir     = currentSourcePath().parentDir().parentDir().parentDir() / "src"
    ChildLifetimeMs = 45_000
      ## `hang_ignores_term.nim`'s own sleep. The ceiling below must sit well
      ## under this, or the test would pass simply by outlasting the fixture.
      ## Duplicated from the fixture because Nim fixtures are separate
      ## programs; the `static: doAssert` below is what keeps the relationship
      ## between the two numbers honest.
    WorstCaseMs = ToolProbeTimeoutMs + 2 * TerminateGraceMs
      ## The worst case of one `toolrun` run, computed from the two production
      ## constants rather than restated as a literal (R4-L2): the drain and
      ## the exit wait share ONE `ToolProbeTimeoutMs` budget, and every
      ## ending but a clean exit then runs `terminateAndReap` -- grace,
      ## `kill()`, grace. A capture that fails part-way ends the run at once
      ## (`reIoError`) instead of falling through to a second full wait.
    SlackMs = 6_000
      ## Headroom for a loaded CI runner on top of the derived bound. The
      ## signal this test carries is "~bound, not ~45 s", so the slack is
      ## deliberately generous; `static: doAssert` below guarantees it cannot
      ## grow into the fixture's lifetime and make the test vacuous.
    CeilingMs = WorstCaseMs + SlackMs

  static:
    doAssert CeilingMs + 10_000 <= ChildLifetimeMs,
      "R3-3: CeilingMs (" & $CeilingMs & "ms) must stay well under " &
      "hang_ignores_term's own " & $ChildLifetimeMs & "ms sleep, or a pass " &
      "could mean 'outlasted the fixture' instead of 'the escalation fired'. " &
      "Raise the fixture's sleep, do not raise the ceiling."

  let ignoresTermBin = block:
    createDir(binDir)
    let b = binDir / "hang_ignores_term".addFileExt(ExeExt)
    compileFixtureWithSrc(fixtureDir, cacheDir, "hang_ignores_term", b, srcDir)
    b

  proc procsRunning(needle: string): seq[int] =
    ## Every PID in this PID namespace whose `/proc/<pid>/cmdline` contains
    ## `needle`. Linux-only by construction (see the file doc). An entry that
    ## disappears between `walkDir` and the read is NOT a survivor — that is a
    ## process exiting, i.e. the outcome we want — so the read failure is
    ## skipped rather than reported.
    ##
    ## A zombie has an EMPTY `cmdline` and is therefore invisible here, on
    ## purpose: see WHAT "GONE" MEANS HERE in the file doc.
    for kind, path in walkDir("/proc"):
      if kind != pcDir: continue
      let base = path.lastPathPart
      if base.len == 0 or not base.allCharsInSet({'0' .. '9'}): continue
      var cmdline: string
      try:
        cmdline = readFile("/proc" / base / "cmdline")
      except CatchableError:
        continue
      if cmdline.len > 0 and needle in cmdline:
        result.add parseInt(base)

  proc procState(pid: int): string =
    ## The state letter from `/proc/<pid>/stat` (`R` running, `S` sleeping,
    ## `Z` zombie, `D` uninterruptible), for the failure message only — a
    ## surviving child's state is the first thing a diagnostician wants.
    try:
      let st = readFile("/proc" / $pid / "stat")
      let afterComm = st.rfind(')')   # comm is parenthesised and may contain spaces
      if afterComm < 0: return "?"
      let fields = st[afterComm + 1 .. ^1].splitWhitespace()
      if fields.len > 0: fields[0] else: "?"
    except CatchableError:
      "?"

  suite "R3-3 — the tool deadline is not defeated by a child that ignores SIGTERM":

    test "the /proc observation used below actually observes this process":
      ## Guards the assertion in the next test from the worst kind of green: a
      ## scanner that matches nothing at all would "prove" no child survives.
      ## The needle is this process's own argv[0] as the kernel reports it, so
      ## the check is self-consistent and cannot fail on a path-spelling
      ## difference.
      check dirExists("/proc")   # see WHAT THIS DEPENDS ON in the file doc
      var selfArgv0 = ""
      try:
        selfArgv0 = readFile("/proc/self/cmdline").split('\0')[0]
      except CatchableError:
        checkpoint("could not read /proc/self/cmdline")
      check selfArgv0.len > 0
      let seen = procsRunning(selfArgv0)
      if getCurrentProcessId() notin seen:
        checkpoint("procsRunning(" & selfArgv0 & ") = " & $seen &
                   " but this process is pid " & $getCurrentProcessId())
      check getCurrentProcessId() in seen

    test "realRunMerged returns near its deadline, not at the child's lifetime":
      ## RED pre-fix: ~45006 ms (the child's full sleep), because
      ## `terminateAndReap` waited unboundedly on a TERM it could never have
      ## delivered. GREEN post-fix: ~12 s — the 10 s drain deadline, then TERM
      ## ignored, then SIGKILL after the grace period.
      let before = procsRunning(ignoresTermBin)
      let t0 = getMonoTime()
      let r = realRunMerged(ignoresTermBin, [])
      let elapsedMs = (getMonoTime() - t0).inMilliseconds
      let survivors = procsRunning(ignoresTermBin)

      if elapsedMs >= CeilingMs:
        echo "R3-3 DIAGNOSTIC: elapsed=", elapsedMs, "ms ceiling=", CeilingMs,
             "ms (", WorstCaseMs, "ms derived bound + ", SlackMs,
             "ms slack) childLifetime=", ChildLifetimeMs,
             "ms — the wait is not bounded"

      check r.ending == reTimedOut    # the probe still fails honestly
      check elapsedMs < CeilingMs

      # R4-2: the OTHER half of the fix. `terminateAndReap` escalates to
      # `kill()` precisely so this cannot be non-empty: deleting that `kill()`
      # leaves the TERM-ignoring fixture alive here (state `S`, ~31 s of sleep
      # to go, reparented to PID 1 once we exit) while every timing assertion
      # above stays green.
      if survivors.len > 0:
        var desc: seq[string]
        for pid in survivors: desc.add $pid & " (state " & procState(pid) & ")"
        checkpoint("R3-3/R4-2: `" & ignoresTermBin & "` SURVIVED " &
                   "realRunMerged (elapsed=" & $elapsedMs & "ms): pid(s) " &
                   desc.join(", ") & ". terminateAndReap must escalate " &
                   "terminate() -> kill() and REAP; a live child here means " &
                   "the kill() or the reap is gone. Pre-call scan saw " &
                   $before & " (non-empty => a leak from an earlier run, not " &
                   "from this call).")
      check survivors.len == 0

      # No output reaches the caller on the give-up path, even though the
      # fixture printed a plausible banner before ignoring TERM: a
      # `reTimedOut` result has no `output` field at all. A partial banner
      # from a tool that never finished answering must never reach
      # `versionLine`, or a truncated line becomes a "compiler identity" --
      # the class R3-1 closed on the fold path.
      check not r.ok

else:
  echo "CRISOL-SKIP: tests/integration/test_tool_terminate_escalation.nim"
  echo "  (R3-3 escalation is POSIX-only: TerminateProcess cannot be ignored)"
