## process/cgroup.nim — rfc-0007 B3/§4 delegated cgroup-v2 leaf plumbing,
## split out of posixcore.nim (code-review finding r27): topology
## (`ownCgroupV2Path`/`cgroupSiblingParent`), leaf lifecycle
## (create/join-is-the-child's-job/kill/remove), and the two per-leaf
## readers (`cgroup.procs` survivors, `memory.events` oom_kill).
##
## Linux-only (cgroup v2 does not exist on Darwin) — every proc below is
## `when defined(linux)`-gated, with an inert `else` stub only where a
## non-Linux caller needs one to keep compiling (posixcore's spawn/reap
## paths guard their own call sites with `when defined(linux):` already, so
## most of this module needs no `else` arm at all).
##
## `cgroupSiblingParent()`/`cgroupSlotLeafName()`/`createCgroupLeaf()`/
## `killCgroupLeaf()`/`cgroupLeafSurvivors()` are exported (`*`) beyond this
## module's own posixcore.nim/caps.nim consumers purely so the fault-
## injection and unit tests can drive them directly — see each proc's own
## doc comment for the specific test that needs it.

import std/[os, posix, strutils]
import crisol/process/types
import crisol/process/procscan

when defined(linux):
  proc ownCgroupV2Path*(): string =
    ## Reads /proc/self/cgroup's unified (v2) line: "0::<path>".
    try:
      for line in lines("/proc/self/cgroup"):
        if line.startsWith("0::"):
          return line[3 .. ^1]
    except CatchableError:
      discard
    ""

  proc cgroupSiblingParent*(): string =
    ## The REAL production topology, shared by the capabilities probe
    ## (`process/caps.nim`'s `probeCgroupV2`) and every per-spawn leaf below
    ## (and reused by the fault-injection test to predict/collide a
    ## specific spawn's leaf path — rfc-0007 B3): a SIBLING of this
    ## process's own cgroup residence (a child of its PARENT), never a
    ## child of the residence itself. cgroup v2's "no internal process"
    ## constraint forbids a cgroup from enabling controllers in its OWN
    ## `cgroup.subtree_control` while it holds a resident process — this
    ## process IS resident in its own cgroup right now, so only a SIBLING
    ## (never a child of it) can inherit delegated controllers (see
    ## `process/caps.nim`'s `probeCgroupV2` for the full "why a sibling"
    ## reasoning, empirically verified against a real cgroup-v2 host). ""
    ## when there is nowhere to place a sibling (e.g. already at the
    ## cgroupfs root, or /proc/self/cgroup unreadable).
    let relPath = ownCgroupV2Path()
    if relPath.len == 0: return ""
    let base = "/sys/fs/cgroup" & relPath
    let parent = base.parentDir
    if parent.len == 0 or not parent.startsWith("/sys/fs/cgroup"): return ""
    parent

  proc cgroupSlotLeafName*(pid: Pid; id: int32): string =
    ## Deterministic per-spawn leaf name — exported so the fault-injection
    ## test (tests/integration/test_rfc0007_b3_cgroup.nim) can predict and
    ## pre-collide ONE specific spawn's leaf path (a plain file where a
    ## directory needs to go — un-creatable regardless of privilege level,
    ## unlike a permission-based sabotage a `--privileged` CI container's
    ## root would simply bypass).
    "crisol-slot-" & $pid & "-" & $id

  proc createCgroupLeaf*(parent, name: string): string =
    ## mkdir the leaf; returns its full path, or "" on ANY failure (already
    ## exists as a non-directory, parent not writable, etc.) — the
    ## per-spawn honest-degrade trigger (rfc-0007 B3): a failure here NEVER
    ## aborts the spawn, it just leaves this one spawn off the cgroup tier.
    let leaf = parent / name
    try:
      createDir(leaf)
      leaf
    except CatchableError:
      ""

  proc writeCgroupMemoryMax*(leafPath: string; bytes: int64): bool =
    ## cgroup `memory.max` — the tagged successor to RLIMIT_AS on this tier
    ## (real RSS-backed enforcement + kernel OOM-kill accounting, vs.
    ## RLIMIT_AS's virtual-address-space-only ceiling). RLIMIT_AS itself is
    ## NOT removed (posixcore's `applyLimitsChildSide`, unchanged) — both
    ## are attempted when a memory ceiling is requested; this is the
    ## cgroup-specific one. Also disables swap for the leaf
    ## (`memory.swap.max` = 0): without this, a process that hits
    ## `memory.max` can be pushed to swap instead of OOM-killed, defeating
    ## the ceiling's whole purpose as a deterministic Cause(cbLimit,
    ## lkMemory) producer. Best-effort — an environment with no swap-
    ## accounting controller at all never fails the memory.max write itself
    ## over it.
    try:
      writeFile(leafPath / "memory.max", $bytes)
      try: writeFile(leafPath / "memory.swap.max", "0")
      except CatchableError: discard
      true
    except CatchableError:
      false

  proc killCgroupLeaf*(leafPath: string): bool =
    ## Atomic, airtight teardown (rfc-0007 B3): write "1" to `cgroup.kill`
    ## — kills every process resident in the subtree in one syscall,
    ## including a setsid escapee the pgid-only `killpg` can never reach.
    ## Safe to call on an EMPTY cgroup too (the normal-exit case) — a
    ## harmless no-op write that still reports `true`.
    ##
    ## rfc-0007 r10: returns the write's real success/failure — this proc
    ## itself no longer swallows it (a same-uid child migrating itself OUT
    ## of the leaf before this write, or a runtime EACCES/ENOENT on the
    ## write, used to be invisible: `forceKillCore` skipped `killpg`
    ## ENTIRELY on the cgroup arm, so a write failure meant NO kill signal
    ## of any kind was ever sent, while reap still stamped `killDomain =
    ## kdsCgroup` — a vouch the mechanism did not honor). The caller
    ## (`forceKillCore`/`reapCore`, both posixcore.nim) is responsible for
    ## (a) backstopping with `killpg` regardless, and (b) recording a
    ## `false` here so the spawn's `killDomain` vouch degrades honestly —
    ## see `killDomainFor` (posixcore.nim). Exported (like
    ## `cgroupSiblingParent`/`cgroupSlotLeafName`) purely so a unit test can
    ## drive a genuine write failure (a nonexistent leaf path) without
    ## needing real cgroup-v2 delegation.
    try:
      writeFile(leafPath / "cgroup.kill", "1")
      true
    except CatchableError:
      false

  proc cgroupLeafSurvivors*(leafPath: string): seq[ProcSnapshot] =
    ## rfc-0007 B3: the cgroup-tier's OWN escapee/tree accounting — every
    ## pid still listed in this leaf's `cgroup.procs` at reap time. No
    ## /proc pgid/ppid scan needed (unlike the subreaper tier's
    ## `posixcore.discoverAndReapEscapees`): a process's cgroup membership
    ## is LEAF-SCOPED by construction (each spawn gets its own leaf), so
    ## unlike the pgid/ppid heuristics this can NEVER cross-attribute a
    ## different slot's descendant — structurally sound regardless of
    ## compile vs. run phase, which is why (unlike
    ## `discoverAndReapEscapees`) this path never needs a `runPhase` guard.
    result = @[]
    var pids: seq[int]
    try:
      for line in lines(leafPath / "cgroup.procs"):
        let s = line.strip()
        if s.len == 0: continue
        try: pids.add parseInt(s)
        except ValueError: discard
    except CatchableError:
      discard
    for pid in pids:
      var ppid = 0
      var comm = ""
      try:
        let parsed = parseStatLine(readFile("/proc/" & $pid & "/stat"))
        ppid = parsed.ppid
        comm = parsed.comm
      except CatchableError:
        discard
      result.add ProcSnapshot(pid: pid, ppid: ppid, command: comm,
                              rssBytes: readVmRssBytes(pid))

  proc cgroupLeafOomKill*(leafPath: string): bool =
    ## `memory.events`' `oom_kill` counter > 0 — read BEFORE any teardown
    ## write (killCgroupLeaf/removeCgroupLeafBounded), so a real OOM fact
    ## is never raced by the leaf's own removal.
    try:
      for line in lines(leafPath / "memory.events"):
        if line.startsWith("oom_kill "):
          try: return parseInt(line.split(' ')[1].strip()) > 0
          except ValueError: return false
    except CatchableError:
      discard
    false

  proc removeCgroupLeafBounded*(leafPath: string): bool =
    ## Never leak leaves (rfc-0007 B3), but NEVER an unbounded blocking
    ## wait in the event-loop path either (the B1 lesson). A `cgroup.kill`
    ## target's cgroup membership drops at the kernel's `do_exit()` —
    ## BEFORE its parent ever wait()s it (not dependent on THIS event
    ## loop's own future orphan-sweep iteration reaping it first, so
    ## polling here cannot self-deadlock the loop that would otherwise
    ## have to do that reaping) — so a short bound is safe, mirroring
    ## posixcore's `reapBounded`'s identical accepted-bound convention for
    ## the exact same "SIGKILL is near-instant" reasoning. Gives up
    ## (leaving the leaf, a rare pathological case) only past the budget.
    const budgetMs = 300
    const stepMs = 5
    var waited = 0
    while waited < budgetMs:
      if posix.rmdir(leafPath.cstring) == 0: return true
      os.sleep(stepMs)
      waited += stepMs
    false
