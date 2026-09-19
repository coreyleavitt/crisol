## process/caps.nim — rfc-0007 A7 (§4) capability probes, split out of
## posixcore.nim (code-review finding r27): EVERY field below is a REAL,
## live probe (attempt the mechanism, verify it worked; never an
## assumed/hardcoded literal) — pidfd/subreaper/cgroup are Linux-only
## kernel features (prctl(2) and pidfd_open(2) do not exist on Darwin), so
## they are `when defined(linux)` gated; this module is also today's macOS
## backend's capability producer (§1 module-layout comment: darwin.nim
## re-exports posix.nim's Supervisor, which embeds PosixCore, which imports
## this module), and an unconditional importc of a Linux-only syscall
## constant would fail `nim check --os:macosx` outright, not just report
## false at runtime. flock/wait4 are genuinely POSIX-portable (both probed
## for real on any posix target this file backs). kqueue (rfc-0007 C1b) is
## a REAL probe here too, `when defined(macosx)` gated the same way — this
## module is darwin.nim's mechanism, not a separate claim it makes itself.
## jobObjectNesting/ctrlBreakDeliverable stay windows.nim's own fields
## (Stage D) — always false here, never this module's claim to make.
##
## Probed exactly once per process (`cachedCapabilities`, ccprobe/nimprobe's
## `cachedX` idiom) — every real probe below does actual I/O (fork+wait4,
## flock a tempfile, mkdir+write under /sys/fs/cgroup) so re-running it on
## every `capabilities()` call would be wasteful, not merely un-idiomatic.
##
## The Linux `pidfd_open`/`pidfd_send_signal` syscall FFI and the
## `PR_SET_CHILD_SUBREAPER`/`PR_GET_CHILD_SUBREAPER` prctl FFI live HERE,
## not in `posixcore.nim`, even though posixcore's own spawn/escapee-kill/
## subreaper-setup machinery (§1/§3 core) is their heavier user by call
## count: both are genuinely DUAL-USE (this module's `probePidfd`/
## `probeSubreaper` probe them; posixcore's spawn/kill/init/destroy paths
## USE them for real), and posixcore already unconditionally imports this
## module for `cachedCapabilities` — Nim has no partial module override (a
## third "ffi-only" module would just move the seam, not remove it), so
## this is the one direction that avoids a cycle: posixcore -> caps, never
## the reverse.

import std/[options, os, posix, strutils]
import crisol/process/types
import crisol/process/cgroup
import crisol/ioutils

when defined(linux):
  # rfc-0007 B1/B2 (§1/§3): pidfd_open/pidfd_send_signal — no Nim wrapper
  # exists (even std/posix's own `syscall` helper is `when defined(android)`-
  # only) — importc syscall(2) directly, the same duplicate-importc idiom
  # this file's header sanctions. Exported (`*`): posixcore.nim's spawn
  # (pidfd registration) and escapee-kill (discoverAndReapEscapees) paths
  # call these directly too — see this module's header note on why they
  # live here rather than in posixcore.nim itself.
  proc c_syscall*(number: clong): clong {.importc: "syscall", varargs,
                                          header: "<unistd.h>".}
  var SYS_pidfd_open* {.importc: "SYS_pidfd_open", header: "<sys/syscall.h>".}: clong
  var SYS_pidfd_send_signal* {.importc: "SYS_pidfd_send_signal",
                               header: "<sys/syscall.h>".}: clong

  proc probePidfd*(): bool =
    let r = c_syscall(SYS_pidfd_open, clong(getpid()), 0.clong)
    if r < 0: return false
    discard posix.close(cint(r))
    true

  # PR_SET_CHILD_SUBREAPER / PR_GET_CHILD_SUBREAPER: unprivileged since
  # Linux 3.4. Exported (`*`): posixcore.nim's `initPosixCore`/
  # `destroyPosixCore` set/clear the bit for real — see this module's
  # header note.
  proc c_prctl*(option: cint): cint {.importc: "prctl", varargs,
                                      header: "<sys/prctl.h>".}
  var PR_SET_CHILD_SUBREAPER* {.importc, header: "<sys/prctl.h>".}: cint
  var PR_GET_CHILD_SUBREAPER* {.importc, header: "<sys/prctl.h>".}: cint

  proc probeSubreaper*(): bool =
    ## Set-then-read-back is the real verification (not "the set call
    ## returned 0, therefore assume it worked").
    if c_prctl(PR_SET_CHILD_SUBREAPER, 1.cint) != 0: return false
    var val: cint = -1
    if c_prctl(PR_GET_CHILD_SUBREAPER, addr val) != 0: return false
    val == 1
else:
  proc probePidfd*(): bool = false
  proc probeSubreaper*(): bool = false

when defined(macosx):
  # rfc-0007 C1b (§1): `posix/kqueue` (stdlib, lives under lib/posix/, not
  # std/) wraps kqueue()/kevent()/EV_SET()/the `KEvent` struct and the
  # EVFILT_*/EV_*/NOTE_* consts already — no hand-importc needed.
  # posixcore.nim's own event loop (initPosixCore/kqueueBlock/spawnChild's
  # per-child EVFILT_PROC registration) imports this same stdlib module
  # independently for its OWN kqueue use — this probe is self-contained and
  # shares no state with that machinery, only the underlying mechanism.
  import posix/kqueue

  proc probeKqueue*(): bool =
    let kq = kqueue()
    if kq < 0: return false
    discard posix.close(kq)
    true

proc forceNoCgroupKillRequested(): bool =
  ## rfc-0007 wiring-audit W1's env knob — `CRISOL_FORCE_NO_CGROUP_KILL`,
  ## the same shape/doc style as posixcore.nim's `CRISOL_FORCE_POLL`
  ## (`forcePollRequested`). Consulted INSIDE `probeCgroupV2` (below), never
  ## as a separate branch at the spawn gate: this makes `capabilities()`/
  ## the substrate JSON honestly report `cgroupKill: false` too, not just
  ## the gate's internal decision — the same "attempt the mechanism, verify
  ## it worked" probe discipline this module's header documents, just with
  ## the verification forced negative. Two purposes, not one: (1) the test
  ## seam this slice's conformance/unit tests need to exercise the
  ## cgroup-tier degrade without a real broken kernel; (2) a genuine
  ## operator escape hatch for a delegated host whose `cgroup.kill` file
  ## exists but is known-buggy. Read fresh, same as `forcePollRequested` —
  ## but because the caller (`cachedCapabilities`) memoises its RESULT
  ## after the first probe, this only has effect if set before this
  ## process's first `capabilities()`/`cachedCapabilities()` call; a
  ## process that probed already will not re-probe on a later env change.
  let v = getEnv("CRISOL_FORCE_NO_CGROUP_KILL")
  v.len > 0 and v != "0"

when defined(linux):
  # cgroup v2 delegation (§4): "mkdir a leaf + write cgroup.procs" is the
  # RFC's own recipe, tried on THIS process (moved back to its original
  # cgroup and the leaf removed afterward, on every path). A delegated
  # 5.15 LTS host must probe green for delegation and red for the files it
  # lacks — cgroup.kill/memory.peak are only even CHECKED inside a leaf
  # that delegation itself proved writable; never probed independently
  # (never "fail per-file at spawn time" — §4).
  #
  # `cgroupSiblingParent()`/`ownCgroupV2Path()` (process/cgroup.nim) are the
  # SAME topology decision B3's real per-spawn leaf placement uses — see
  # `cgroupSiblingParent`'s doc comment for the full "why a sibling, never a
  # child of `base`" reasoning, empirically verified against a real
  # cgroup-v2 host.
  proc probeCgroupV2*(): tuple[delegation, kill, memoryPeak: bool] =
    result = (delegation: false, kill: false, memoryPeak: false)
    # Captured BEFORE the move below (moving into `leaf` changes what
    # `ownCgroupV2Path()` would return) — this is where "move back" must
    # restore this process to.
    let base = "/sys/fs/cgroup" & ownCgroupV2Path()
    let parent = cgroupSiblingParent()
    if parent.len == 0:
      return   # at the cgroupfs root, or /proc/self/cgroup unreadable
    let leaf = parent / ("crisol-probe-" & $getpid())
    try:
      createDir(leaf)
    except CatchableError:
      return   # not writable here (e.g. rootless podman: read-only cgroupfs)
    try:
      writeFile(leaf / "cgroup.procs", $getpid() & "\n")
      result.delegation = true
      # rfc-0007 wiring-audit W1: the real file-existence probe, THEN the
      # env override forced negative — never the reverse order (a real
      # probe that never ran would make `forceNoCgroupKillRequested`
      # meaningless as an escape hatch for a host where the file exists
      # but is known-buggy; this order is what makes it a real override,
      # not merely a fallback default).
      result.kill = fileExists(leaf / "cgroup.kill") and not forceNoCgroupKillRequested()
      result.memoryPeak = fileExists(leaf / "memory.peak")
    except CatchableError:
      discard   # mkdir succeeded but the move failed — honestly not delegated
    try: writeFile(base / "cgroup.procs", $getpid() & "\n")   # move back FIRST —
    except CatchableError: discard                             # a non-empty
    try: removeDir(leaf)                                       # cgroup can't rmdir
    except CatchableError: discard
else:
  proc probeCgroupV2*(): tuple[delegation, kill, memoryPeak: bool] =
    (delegation: false, kill: false, memoryPeak: false)

# flock(2) is BSD/Linux, not POSIX, and absent from std/posix — same
# duplicate-importc idiom lock.nim already uses (safe: no C definition is
# emitted, only a reference through the header).
proc c_flock(fd: cint; operation: cint): cint {.importc: "flock",
                                                header: "<sys/file.h>".}
var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
var LOCK_UN {.importc, header: "<sys/file.h>".}: cint
var LOCK_NB {.importc, header: "<sys/file.h>".}: cint

proc probeFlock*(): bool =
  ## rfc-0007 code-review r9: the probe file lives at an UNPREDICTABLE name,
  ## opened via `ioutils.exclusiveCreate` (`O_CREAT|O_EXCL|O_NOFOLLOW`) —
  ## never the old `crisol-flock-probe-<pid>` FIXED name opened with Nim's
  ## plain `open(path, fmWrite)` (`O_CREAT|O_TRUNC`, no `O_EXCL`/
  ## `O_NOFOLLOW`). A name predictable from the pid alone let a local
  ## attacker in shared `/tmp` pre-plant a symlink at that exact path and
  ## have it silently FOLLOWED and TRUNCATED as the crisol user — blocked
  ## on default Linux by `fs.protected_symlinks`, but NOT on macOS
  ## (`TMPDIR=/tmp` with a stripped CI/container env) or a hardened-off
  ## Linux. This matches the repo's own posture everywhere else a
  ## predictable-name attack matters (`ioutils.exclusiveCreate`/
  ## `atomicPublish` already use `O_EXCL` exactly against a planted-symlink
  ## attacker; this probe was the one holdout still using a raw `open`).
  ##
  ## The random suffix (`ioutils.readRandomBytes`, `/dev/urandom`) makes
  ## the name unguessable in advance; `O_EXCL`/`O_NOFOLLOW` then make ANY
  ## pre-existing entry at that exact name — planted, or a
  ## vanishingly-unlikely genuine collision — fail CLOSED (probe returns
  ## `false`) rather than following/truncating it. No retry-with-a-
  ## different-name on collision: this is best-effort capability
  ## detection, not correctness-critical machinery, so a false negative on
  ## an astronomically unlikely 16-random-byte collision is an acceptable,
  ## simpler failure mode than a retry loop.
  try:
    let randBytes = readRandomBytes(16)
    if randBytes.len == 0:
      return false   # /dev/urandom unavailable — fail closed, never fall
                       # back to a predictable name
    var suffix = newStringOfCap(32)
    for b in randBytes: suffix.add toHex(b)
    let path = getTempDir() / ("crisol-flock-probe-" & $getpid() & "-" & suffix)
    let (fd, _, _) = exclusiveCreate(path, noFollow = true)
    if fd < 0: return false
    defer:
      closeFd(fd)
      try: removeFile(path)
      except CatchableError: discard
    if c_flock(fd, LOCK_EX or LOCK_NB) != 0: return false
    discard c_flock(fd, LOCK_UN)
    true
  except CatchableError:
    false

proc probeWait4Rusage*(): bool =
  ## A throwaway fork+wait4 (not "wait4 is called elsewhere in this module,
  ## therefore assume true") — some sandboxes filter wait4/rusage collection
  ## via seccomp; this actually exercises the syscall once and checks the
  ## real return value.
  let pid = fork()
  if pid == 0:
    exitnow(0)   # async-signal-safe: no Nim runtime after fork in the child
  elif pid > 0:
    var status: cint
    var ru: posix.Rusage
    let r = wait4(pid, addr status, 0.cint, addr ru)
    r == pid
  else:
    false

proc probeCapabilities*(): Capabilities =
  ## The raw, seam-free probe — real I/O, freely callable (mirrors
  ## `ccprobe.ccVersion` / `nimprobe.nimFingerprint`: the pure-ish real
  ## probe stays exported and un-memoised; `cachedCapabilities` below is
  ## the memoised wrapper every production call site actually uses).
  let cg = probeCgroupV2()
  Capabilities(
    pidfd: probePidfd(),
    subreaper: probeSubreaper(),
    cgroupDelegation: cg.delegation,
    cgroupKill: cg.kill,
    memoryPeak: cg.memoryPeak,
    kqueue: (when defined(macosx): probeKqueue() else: false),
                                # rfc-0007 C1b: THIS module's producer now —
                                # darwin.nim re-exports posix.nim's Supervisor
                                # unchanged (§1 module-layout comment); a real
                                # probe, not a stub, exactly like pidfd/
                                # subreaper/cgroup above (linux.nim doesn't
                                # probe its own caps either — posixcore does).
    jobObjectNesting: false,    # windows.nim's field (Stage D), never this module's
    ctrlBreakDeliverable: false,# windows.nim's field (Stage D), never this module's
    flock: probeFlock(),
    wait4Rusage: probeWait4Rusage(),
  )

var capabilitiesMemo: Option[Capabilities] = none(Capabilities)

proc cachedCapabilities*(): Capabilities =
  ## Probed exactly once per process; every later caller — Supervisor-
  ## backed (`capabilities(sv)`) or not (the plan/list CLI path, which
  ## never spawns anything) — reads the SAME memoised value (§4).
  if capabilitiesMemo.isNone:
    capabilitiesMemo = some(probeCapabilities())
  capabilitiesMemo.get
