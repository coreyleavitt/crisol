## test_process_capabilities.nim — rfc-0007 A7: `capabilities()` probes are
## REAL, not hardcoded literals — unit-level, independent of the CLI wire
## (tests/integration/test_rfc0007_a7_substrate_cli.nim covers the wire).
##
## "Real" is proven two ways here:
##   1. Cross-checking the probe's own claim against an INDEPENDENT syscall
##      made directly in this test file (subreaper: this test's own
##      PR_GET_CHILD_SUBREAPER readback must agree with what `capabilities()`
##      reported — a fake `true` hardcode would still happen to pass the
##      wire-shape test but would diverge here whenever this process was
##      never actually made a subreaper).
##   2. The same tier-scoped acceptance pins as the CLI tracer (RFC-0007
##      line 539), so an inert always-false/always-true probe fails at the
##      unit level too, not only when it happens to reach a CLI test.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_process_capabilities.nim

import std/[os, posix, unittest]
import crisol/process

when defined(linux):
  # Independent readback — NOT the same code path `capabilities()` uses
  # internally (posixcore.probeSubreaper duplicate-importc's its own; this
  # is a second, separate importc so the two can never accidentally share
  # a bug). rfc-0007 C1a: <sys/prctl.h>/PR_SET_CHILD_SUBREAPER are Linux-only
  # — no Darwin header to import against, so this whole cross-check is
  # `when defined(linux)`, not merely runtime-gated on `caps.subreaper`.
  proc c_prctl_check(option: cint): cint {.importc: "prctl", varargs,
                                          header: "<sys/prctl.h>".}
  var PR_GET_CHILD_SUBREAPER_check {.importc: "PR_GET_CHILD_SUBREAPER",
                                     header: "<sys/prctl.h>".}: cint

suite "rfc-0007 A7 — capabilities() is memoised":

  test "repeated calls return an identical snapshot (probed once, cached)":
    let a = capabilities()
    let b = capabilities()
    check a == b

suite "rfc-0007 A7 — capabilities() fields that are real on every Linux tier":

  let caps = capabilities()

  test "flock: true (a real flock(2) probe on a throwaway tempfile)":
    check caps.flock == true

  test "wait4Rusage: true (a real fork+wait4 probe, not inferred from other call sites)":
    check caps.wait4Rusage == true

  test "pidfd: platform-honest (true on Linux; pidfd_open(2) has no Darwin analog)":
    ## rfc-0007 C1a: this suite's title predates the macOS leg — pidfd is
    ## real (and pinned true) on every LINUX tier; on the macOS poll-fallback
    ## tier (process/posix.nim, pre-C1b) there is no pidfd_open(2) at all,
    ## so the honest value is false, not a degraded/skipped Linux feature.
    when defined(linux):
      check caps.pidfd == true
    else:
      check caps.pidfd == false

suite "rfc-0007 A7 — capabilities() acceptance pins (per known tier, RFC-0007 line 539)":

  let caps = capabilities()

  test "tier-pinned values hold on the tier this test is actually running on":
    case getEnv("CRISOL_TIER")
    of "ci-linux":
      check caps.pidfd == true
      check caps.wait4Rusage == true
      check caps.flock == true
      check caps.cgroupDelegation == false   # plain docker run: no delegation
    of "ci-cgroup":
      # rfc-0007 B3: ci.yml's `cgroup` job — same Linux CI container with a
      # real cgroup-v2 subtree delegated before the suite starts, so every
      # ci-linux pin holds PLUS delegation itself is real. An inert probe
      # (or a regression) fails HERE, before B3's backend consumes it.
      check caps.pidfd == true
      check caps.wait4Rusage == true
      check caps.flock == true
      check caps.cgroupDelegation == true
      check caps.cgroupKill == true
      check caps.memoryPeak == true
    of "macos":
      # rfc-0007 C1a: ci.yml's `macos` job — real macOS-latest runner, the
      # posix backend's poll(2) fallback (process/posix.nim maps here until
      # C1b births process/darwin.nim). subreaper/pidfd/cgroup delegation
      # are Linux-only kernel mechanisms and honestly false; flock and
      # wait4Rusage are real POSIX and hold on Darwin exactly as on Linux.
      check caps.subreaper == false
      check caps.pidfd == false
      check caps.cgroupDelegation == false
      check caps.flock == true
      check caps.wait4Rusage == true
      # rfc-0007 C1b: kqueue is real on this tier now — darwin.nim's
      # backend registers EVFILT_PROC for `next` and probes kqueue() for
      # real (posixcore.probeKqueue), the same "attempt the mechanism,
      # verify it worked" discipline every other field here already had.
      check caps.kqueue == true
    else:
      # rootless-podman dev tier (./dev test): no cgroup delegation, no
      # user-ns, but PR_SET_CHILD_SUBREAPER is unprivileged and unaffected.
      check caps.subreaper == true
      check caps.cgroupDelegation == false

  test "subreaper, independently cross-checked (not this test's own probe code)":
    when defined(linux):
      if caps.subreaper:
        var val: cint = -1
        let rc = c_prctl_check(PR_GET_CHILD_SUBREAPER_check, addr val)
        check rc == 0
        check val == 1
    else:
      # rfc-0007 C1a: no PR_SET_CHILD_SUBREAPER on Darwin — caps.subreaper
      # is honestly false (asserted above), so there is nothing to cross-
      # check here yet. Not a deferral: a real Darwin subreaper-equivalent
      # (if any) is C1b's call, not this slice's.
      skip()

suite "rfc-0007 A7 — capabilities() internal consistency (§4, both tiers)":

  let caps = capabilities()

  test "cgroup.kill can only be true inside a delegated leaf":
    if not caps.cgroupDelegation:
      check caps.cgroupKill == false

  test "memory.peak can only be true inside a delegated leaf":
    if not caps.cgroupDelegation:
      check caps.memoryPeak == false

when isMainModule:
  echo "test_process_capabilities: done"
