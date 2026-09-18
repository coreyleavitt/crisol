## test_rfc0007_w1_cgroup_kill_gate.nim — rfc-0007 wiring-audit W1, unit
## level: the pure tier-selection predicate + the probe-level env override.
##
## THE GAP this closes: `Capabilities.cgroupKill` was probed
## (posixcore.probeCgroupV2, `fileExists(leaf / "cgroup.kill")`) and
## reported (substrate JSON) but never CONSULTED — the spawn-time tier
## gate selected the cgroup tier on `cgroupDelegation` alone. On a
## delegated cgroup-v2 host whose kernel lacks the `cgroup.kill` file
## (< 5.14 — RHEL8 4.18, 5.4/5.10 LTS containers), a SIGTERM-ignoring
## child would survive escalation with NO SIGKILL ever sent
## (`killCgroupLeaf` is deliberately best-effort and swallows that write
## failure, and `killpg` is skipped ENTIRELY on the cgroup arm — not
## merely redundant with it), while reap still stamped
## `killDomain = kdsCgroup` — a vouch the mechanism could not honor.
##
## Covered here:
##   1. `cgroupTierUsable(caps)` — the pure predicate's full truth table
##      over both bits (no I/O; a plain object literal per case).
##   2. `CRISOL_FORCE_NO_CGROUP_KILL` — the probe-level env escape hatch
##      (same shape as the existing `CRISOL_FORCE_POLL` knob): forces the
##      RAW probe (`probeCapabilities`, unmemoised) to report
##      `cgroupKill == false` even when the real `cgroup.kill` file would
##      otherwise be found. Self-gates on real delegation (only true on
##      the CI `cgroup` job, per tests/integration/test_rfc0007_b3_cgroup.
##      nim's header) — everywhere else `cgroupDelegation` is already
##      false, so `cgroupKill` is trivially false with or without the
##      override, and the override's OWN effect cannot be distinguished
##      locally (only proven for real on the cgroup CI leg).
##
## The end-to-end tracer for the gate this predicate feeds (spawn a real
## SIGTERM-ignoring child, forced onto this condition, and watch it
## actually die via the subreaper/pgid tier instead of hanging) is
## tests/integration/test_rfc0007_w1_cgroup_kill_gate.nim, not here — this
## file is unit-level and touches no real child process.
##
## `CRISOL_FORCE_NO_CGROUP_KILL` is set at the very top of this file,
## before ANY `capabilities()`/`cachedCapabilities()` call in this
## process — required because `cachedCapabilities()` memoises its result
## after the first probe (same rule `CRISOL_FORCE_POLL` documents at its
## own definition, posixcore.nim's `forcePollRequested`); this test file
## never calls the memoised entry points at all (it uses the unmemoised
## `probeCapabilities()` directly), but sets it early anyway so the
## contract is demonstrated honestly rather than sidestepped.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_w1_cgroup_kill_gate.nim

import std/os
putEnv("CRISOL_FORCE_NO_CGROUP_KILL", "1")

when defined(posix):
  import std/unittest
  import crisol/process/types
  import crisol/process/posixcore

  suite "rfc-0007 W1 — cgroupTierUsable: pure predicate, full truth table":

    test "delegation=true, kill=true -> usable":
      let caps = Capabilities(cgroupDelegation: true, cgroupKill: true)
      check cgroupTierUsable(caps) == true

    test "delegation=true, kill=false -> NOT usable (the W1 gap this closes)":
      let caps = Capabilities(cgroupDelegation: true, cgroupKill: false)
      check cgroupTierUsable(caps) == false

    test "delegation=false, kill=true -> NOT usable (defensive; the real probe never produces this combination)":
      let caps = Capabilities(cgroupDelegation: false, cgroupKill: true)
      check cgroupTierUsable(caps) == false

    test "delegation=false, kill=false -> NOT usable":
      let caps = Capabilities(cgroupDelegation: false, cgroupKill: false)
      check cgroupTierUsable(caps) == false

  suite "rfc-0007 W1 — CRISOL_FORCE_NO_CGROUP_KILL: probe-level override":

    test "forces cgroupKill=false even where a real cgroup.kill file would be found (self-gated: only real on a delegation-capable host)":
      let caps = probeCapabilities()
      if not caps.cgroupDelegation:
        skip()
      else:
        check caps.cgroupKill == false


  when isMainModule:
    echo "test_rfc0007_w1_cgroup_kill_gate: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_w1_cgroup_kill_gate.nim"
    echo "test_rfc0007_w1_cgroup_kill_gate: skipped (POSIX-only backend test)"
