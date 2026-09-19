## test_windows_jobnesting_healing.nim — code-review finding r68: a
## machinery-indeterminate `jobObjectNesting` probe must never get frozen
## into a permanent false claim, while a GENUINE determination still must.
##
## THE BUG this closes: `probeJobObjectNesting` (process/windows.nim)
## returned a plain `bool`, collapsing "the probe MACHINERY failed"
## (`CreateProcessW`/`CreateJobObjectW`/the FIRST `AssignProcessToJobObject`
## — transient, e.g. commit pressure or a broken COMSPEC, says NOTHING
## about nesting) into the SAME `false` as "the SECOND
## `AssignProcessToJobObject` was genuinely rejected" (a real,
## OS-version-gated host fact). r26's `cachedCapabilities` memo then froze
## whichever `false` it saw FIRST for the rest of the process — in an
## embedded host, one transient failure meant every later `initSupervisor`
## raised `OSError("host cannot create nested Job Objects")` permanently,
## even after the transient condition cleared (pre-r26, every call
## re-probed and healed).
##
## THE FIX: `probeJobObjectNesting` now returns `Option[bool]` — `none` for
## a machinery failure (never memoised), `some(bool)` for a genuine
## determination (memoised forever in the new, SEPARATE `jobNestingMemo`,
## independent of `capabilitiesMemo`'s whole-record freeze). This file
## drives that state machine through the PUBLIC surface only
## (`cachedCapabilities`/`probeCapabilities`/`initSupervisor`), using the
## `CRISOL_FORCE_JOBNESTING_INDETERMINATE` test seam (same shape as
## caps.nim's `CRISOL_FORCE_NO_CGROUP_KILL`) to simulate a machinery
## failure on demand — a REAL transient `CreateProcessW` failure is not
## reproducible to order, but "never memoise an indeterminate result" is a
## pure function of what the probe RETURNS, not of how it failed, so
## forcing the return value exercises the exact same memo-healing code
## path a real transient failure would.
##
## One test, single narrative, strict order (unittest runs `test:` blocks
## in declaration order, but this also documents WHY order matters here —
## `capabilitiesMemo`/`jobNestingMemo` are process-globals seeded on first
## use, so this is deliberately the ONLY test in this file and the FIRST
## thing in it to touch `cachedCapabilities`/`initSupervisor`):
##   1. cold start, forced indeterminate: `initSupervisor` raises honestly
##      (r22's "we don't know yet, don't proceed" gate) — but `capabilities
##      ()` itself never raises, just reports the honest weakest claim
##      (false), for two consecutive calls.
##   2. unforced: the NEXT `cachedCapabilities()` call re-probes (does not
##      serve a frozen false) and lands on the real, genuine ground truth.
##   3. re-forced indeterminate: a THIRD `cachedCapabilities()` call, now
##      that a genuine determination is memoised, must NOT revert to false
##      — the memo is frozen, immune to a later machinery failure.
##   4. `initSupervisor` is driven once more under the same re-forced
##      indeterminate condition and must follow the FROZEN ground truth
##      (succeed if it was `true`), never the currently-forced probe.
##
## Compile-time gated to `defined(windows)` (mirrors every other
## `test_windows_*.nim` file): the `else` branch must still compile and
## exit cleanly on Linux/macOS, since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file under tests/ regardless of host
## platform.

when defined(windows):
  import std/[os, unittest]
  import ./helpers

  suite "rfc-0007 code-review r68 — jobObjectNesting: indeterminate never freezes, genuine always does":

    test "machinery-indeterminate probes heal; a genuine determination then freezes through a later forced failure":
      # Forced BEFORE this process's first capabilities()/cachedCapabilities()/
      # initSupervisor() call, same requirement CRISOL_FORCE_NO_CGROUP_KILL's
      # own doc names (process/caps.nim's forceNoCgroupKillRequested).
      putEnv("CRISOL_FORCE_JOBNESTING_INDETERMINATE", "1")

      # 1. Cold start, indeterminate: initSupervisor's r22 gate raises
      #    honestly on "we don't know" -- but this is a NARROWER claim than
      #    "nesting refused": it must not be the LAST word.
      expect OSError:
        discard initSupervisor(installSignals = false)

      # capabilities() itself never raises (r68) -- an indeterminate probe
      # degrades to the honest weakest claim, not a propagated failure.
      # Two consecutive calls stay honest-false: nothing here memoises a
      # false permanently while the probe keeps coming back indeterminate.
      let caps1 = cachedCapabilities()
      check caps1.jobObjectNesting == false
      let caps2 = cachedCapabilities()
      check caps2.jobObjectNesting == false

      # 2. Unforce: the memo must have stayed OPEN (none), not frozen at
      #    false -- the next call re-probes for real and lands on ground
      #    truth. `probeCapabilities()` (raw, unmemoised, independent of
      #    everything above) supplies that ground truth.
      putEnv("CRISOL_FORCE_JOBNESTING_INDETERMINATE", "0")
      let ground = probeCapabilities().jobObjectNesting
      let caps3 = cachedCapabilities()
      check caps3.jobObjectNesting == ground

      # 3. Re-force indeterminate: a GENUINE determination, once reached,
      #    must survive a LATER machinery failure -- this is the crux of
      #    r68's fix (pre-fix, this would still have been healing-eligible
      #    every call; the point of memoising a genuine result at all is
      #    that it stops re-probing and stops being disturbable).
      putEnv("CRISOL_FORCE_JOBNESTING_INDETERMINATE", "1")
      let caps4 = cachedCapabilities()
      check caps4.jobObjectNesting == ground

      # 4. initSupervisor, driven again under the same forced-indeterminate
      #    condition, must follow the FROZEN ground truth, never the
      #    currently-forced probe -- this is the finding's own reproduction
      #    scenario (an embedded host's initSupervisor calls, post-healing,
      #    must not regress to permanently raising).
      if ground:
        var sv = initSupervisor(installSignals = false)
        check sv.capabilities().jobObjectNesting == true
      else:
        expect OSError:
          discard initSupervisor(installSignals = false)

      putEnv("CRISOL_FORCE_JOBNESTING_INDETERMINATE", "0")

  when isMainModule:
    echo "test_windows_jobnesting_healing done"

else:
  when isMainModule:
    echo "test_windows_jobnesting_healing: skipped (not windows)"
