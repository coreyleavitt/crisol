## test_rfc0007_w1_cgroup_kill_gate.nim — rfc-0007 wiring-audit W1 E2E: the
## cgroup tier is gated on `cgroupTierUsable` (delegation AND cgroup.kill),
## not delegation alone — the load-bearing tracer.
##
## THE GAP (see tests/unit/test_rfc0007_w1_cgroup_kill_gate.nim's header
## for the full writeup): before this slice, a delegated cgroup-v2 host
## whose kernel lacks `cgroup.kill` (< 5.14) would select the cgroup tier
## anyway. `forceKillCore`'s cgroup arm skips `killpg` ENTIRELY when a
## leaf exists, and `killCgroupLeaf` best-effort-swallows a write to a
## nonexistent `cgroup.kill` — so a SIGTERM-ignoring child would survive
## escalation with NO SIGKILL ever sent, while reap still stamped
## `killDomain = kdsCgroup`.
##
## `CRISOL_FORCE_NO_CGROUP_KILL` (rfc-0007 wiring-audit W1's env knob,
## same shape as the existing `CRISOL_FORCE_POLL`) is both the seam this
## test needs AND a real operator escape hatch for a host with a
## present-but-buggy `cgroup.kill`. Set at the very top of this file,
## BEFORE this process's first `capabilities()` call — required because
## `cachedCapabilities()` memoises its result after the first probe.
##
## Driven through the REAL Supervisor (crisol/process's §1 ladder), never
## a backend module directly — unlike test_rfc0007_b3_cgroup.nim (which
## needs posixcore's leaf-placement internals to pre-collide a specific
## spawn's path and so bypasses Supervisor on purpose, per its own
## header), this slice is about TIER SELECTION, not leaf mechanics, so
## the ordinary Supervisor surface is the right level.
##
## Delegation is only real in the CI `cgroup` job (`docker run
## --privileged`, see ci.yml's `cgroup` job comment / test_rfc0007_b3_
## cgroup.nim's header for the topology) — rootless dev/podman and every
## other CI leg have `cgroupDelegation:false`, so both cases below
## self-skip there: inert (a visible `[SKIPPED]`), not silently vacuous.
##
## RED evidence note: locally (no delegation) both cases self-skip
## honestly regardless of whether the gate exists — the real RED for this
## behavior only fires on the CI `cgroup` job. This file's local run
## proves it still compiles and self-skips correctly; the unit-level
## sibling file is where genuine local RED (a missing `cgroupTierUsable`
## symbol) was actually observed for this slice.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_w1_cgroup_kill_gate.nim

import std/os
putEnv("CRISOL_FORCE_NO_CGROUP_KILL", "1")

import std/[options, unittest, osproc, monotimes, times]
import crisol/process

# ---------------------------------------------------------------------------
# Local helpers — a small self-contained mirror (same idiom
# test_rfc0007_a2a_supervisor.nim and test_rfc0007_b3_cgroup.nim's own
# headers use) rather than reaching into tests/conformance/helpers.nim,
# which that directory's import-purity convention reserves for files in
# tests/conformance/.
# ---------------------------------------------------------------------------

let fixtureDir  = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir      = fixtureDir / "bin"
let nimcacheDir = fixtureDir / "nimcache"
createDir(binDir)

proc compileFixture(name: string): string =
  let src   = fixtureDir / (name & ".nim")
  let bin   = binDir / name
  let cache = nimcacheDir / name
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & bin & " " & src)
  doAssert rc == 0, name & " compile failed:\n" & o
  bin

proc tmpOutputFile(tag: string): string =
  getTempDir() / "crisol_w1_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64 & ".txt"

let termIgnoresBin = compileFixture("term_ignores")

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 W1 — cgroup tier gated on cgroupKill, not delegation alone":

  test "CRISOL_FORCE_NO_CGROUP_KILL: capabilities() honestly reports cgroupKill=false while cgroupDelegation=true":
    if not capabilities().cgroupDelegation:
      skip()
    else:
      check capabilities().cgroupKill == false

  test "term_ignores under a forced-absent cgroup.kill: escalation still kills the child via the subreaper/pgid tier, killDomain != kdsCgroup":
    if not capabilities().cgroupDelegation:
      skip()
    else:
      require capabilities().cgroupKill == false   # the forced condition this test exercises

      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("termignores")
      let spec = ChildSpec(argv: @[termIgnoresBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let sr = sv.spawn(spec)
      check sr.ok
      # term_ignores installs SIG_IGN in its first line of main — give it a
      # moment before requestStop, same startup-race guard
      # tests/conformance/test_conformance.nim's own term_ignores case uses.
      os.sleep(150)
      sv.requestStop(sr.id, krTimeout)
      var ev = sv.next(getMonoTime() + initDuration(milliseconds = 300))
      check ev.kind == weDeadline   # grace exhausted; still alive, ignoring SIGTERM
      sv.forceKill(sr.id)
      # THE assertion: this must observe weChildExited within the deadline —
      # i.e. killpg (the subreaper/pgid tier's mechanism) actually fired.
      # With the W1 gate absent, this spawn would have taken a cgroup leaf
      # anyway, forceKillCore's cgroup arm would have skipped killpg
      # ENTIRELY, and killCgroupLeaf's write to the (forced-)absent
      # cgroup.kill would have silently no-op'd — the child would still be
      # alive when this deadline expires.
      ev = sv.next(getMonoTime() + initDuration(seconds = 5))
      check ev.kind == weChildExited
      let report = sv.reap(ev.id)
      check report.stop.isSome
      check report.stop.get.escalated == true
      check report.exit.kind == ekSignaled
      check report.exit.sig == 9  # SIGKILL (POSIX-standard number; the runner reports these)
      check report.killDomain == kdsProcessGroupSubreaper   # NOT kdsCgroup — the
                                                             # tier fell back, per W1.
      removeFile(outPath)

when isMainModule:
  echo "test_rfc0007_w1_cgroup_kill_gate: done"
