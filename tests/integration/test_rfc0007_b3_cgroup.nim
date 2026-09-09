## test_rfc0007_b3_cgroup.nim — rfc-0007 B3 E2E: the delegated cgroup-v2
## backend, driven directly against `process/posixcore.nim` (PosixCore),
## bypassing the `Supervisor` wrapper (`process/posix.nim`) on purpose —
## the fault-injection case needs `cgroupSiblingParent`/`cgroupSlotLeafName`
## (posixcore's exported, deterministic leaf-placement/-naming procs) to
## predict and pre-collide ONE specific spawn's leaf path, which the
## Supervisor's private `core` field does not expose. `spawnChild`/
## `nextEvent`/`reapCore` called directly are EXACTLY what `Supervisor.spawn`/
## `next`/`reap` delegate onto (process/posix.nim) — same production code
## path, same `initPosixCore` subreaper setup, no behavior difference.
##
## Delegation exists ONLY in the CI `cgroup` job (`docker run --privileged`,
## see ci.yml's `cgroup` job comment for the topology) — rootless dev/podman
## and every other CI leg have `cgroupDelegation:false`. Every suite below
## gates on `cachedCapabilities().cgroupDelegation` and calls `skip()`
## otherwise: inert (not silently vacuous — a `[SKIPPED]` line is visible)
## everywhere delegation is absent, actually exercised where it is real.
##
## Covered here (RFC checklist item 545 / B3-brief.md "Tests"):
##   1. cgroup tier conformance: killDomain=kdsCgroup, tree=toComplete, no
##      escapees for a clean pass_always run.
##   2. Fault injection (load-bearing): a green probe + a leaf that fails
##      to materialize for ONE spawn ⇒ that spawn's killDomain honestly
##      degrades to the pre-B3 achieved domain (kdsProcessGroupSubreaper on
##      this tier), run still correct.
##   3. lkMemory E2E: a fixture that OOMs under a small `memory.max` ⇒
##      Cause(cbLimit, lkMemory), exit SIGKILL, `memory.events` oom_kill>0
##      (proven indirectly: classifyCause only returns cbLimit(lkMemory)
##      when `ReapReport.memoryOomKill` — the leaf's real oom_kill readback
##      — was true; asserted directly too).
##
## The setsid-escapee-caught-by-cgroup.kill case (contrast the subreaper
## tier's pidfd path) is NOT duplicated here — it rides
## tests/integration/test_rfc0007_a6a_cli.nim's existing spawn_grandchild_
## setsid E2E (through the real `crisol run` CLI, full event loop, already
## asserts escapees.len==1 / tree=="complete"), which gained one additional
## cgroup-tier-only assertion (killDomain=="cgroup") rather than a
## duplicate raw-Supervisor rebuild of the same scenario.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_b3_cgroup.nim
## (delegation absent outside the CI `cgroup` job ⇒ every case above skips)

import std/[unittest, os, posix, options, osproc, monotimes, times]
import crisol/process/types
import crisol/process/posixcore

# ---------------------------------------------------------------------------
# Local helpers — this file drives PosixCore directly (see header), so it
# cannot reuse tests/support/spawnhelpers.nim (Supervisor-typed) or
# tests/conformance/helpers.nim (conformance-suite-only by import-purity
# convention); a small self-contained mirror of both, matching
# test_sandbox_achieved.nim's inline-execCmdEx compile idiom.
# ---------------------------------------------------------------------------

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
let binDir = fixtureDir / "bin"

proc sabotageLeaf(leafPath: string) =
  ## Deterministically forces THIS leaf's `cgroup.procs` writes to fail —
  ## the "un-creatable leaf" the fault-injection test needs — WITHOUT
  ## relying on filesystem tricks cgroupfs (a kernfs) does not actually
  ## support (a plain `open(O_CREAT)` for an arbitrary regular file where
  ## a directory needs to go is REJECTED by cgroupfs itself, not merely by
  ## permission bits — confirmed empirically in CI), and without touching
  ## the "no internal process" enable-while-populated constraint (also
  ## tried and confirmed empirically NOT to reject a later cgroup.procs
  ## write into an already-subtree_control-enabled-while-empty cgroup —
  ## that constraint is checked at ENABLE time, not at migrate-in time).
  ## Instead: pre-create the SAME leaf directory (harmless — `createDir`
  ## on an already-existing directory is a silent no-op, so `spawnChild`'s
  ## own `createCgroupLeaf` still "succeeds"), then set the leaf's OWN
  ## `pids.max` to 0. The `pids` controller is enabled root-down for the
  ## whole delegated subtree (ci.yml's setup), so every leaf — including
  ## this one — has a real, per-leaf `pids.max`; zero means the kernel
  ## rejects ANY attempt to add a process to this cgroup (EAGAIN),
  ## deterministically and regardless of privilege level (root cannot
  ## write around a numeric admission-control ceiling) — exactly, and
  ## only, the self-join step spawnChild's child performs.
  createDir(leafPath)
  writeFile(leafPath / "pids.max", "0")

proc cleanupSabotagedLeaf(leafPath: string) =
  ## Safety-net teardown only — the production per-spawn honest-degrade
  ## path (posixcore.spawnChild) is expected to have already rmdir'd this
  ## leaf itself once it saw the child's join fail; this exists purely so
  ## a test FAILURE (an assertion tripping before that path runs) never
  ## leaves a stray sabotaged cgroup behind for the next test to collide
  ## with. `pids.max` never blocks `rmdir` of an otherwise-empty leaf (it
  ## only ever gates NEW admissions), so a bare rmdir is enough here.
  discard posix.rmdir(leafPath.cstring)   # bare rmdir — os.removeDir would try
                                            # (and fail) to unlink cgroupfs's
                                            # own control-file entries first

proc compileFixture(name: string): string =
  createDir(binDir)
  let src = fixtureDir / (name & ".nim")
  let bin = binDir / name
  let cache = fixtureDir / "nimcache" / name
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & bin & " " & src)
  doAssert rc == 0, name & " compile failed:\n" & o
  bin

proc tmpOutputFile(tag: string): string =
  getTempDir() / "crisol_b3_" & tag & "_" & $getpid() & "_" & $epochTime().int64 & ".txt"

proc spawnAndWait(core: var PosixCore; spec: ChildSpec; deadline: MonoTime):
    tuple[ev: WaitEvent; report: ReapReport] =
  let sr = spawnChild(core, spec)
  doAssert sr.ok, "spawnAndWait: spawn failed unexpectedly: " &
    (if sr.ok: "" else: sr.error)
  let ev = nextEvent(core, deadline)
  if ev.kind != weChildExited:
    return (ev, ReapReport())
  (ev, reapCore(core, ev.id, false))

# ---------------------------------------------------------------------------
# Suite 1 — cgroup tier conformance
# ---------------------------------------------------------------------------

suite "rfc-0007 B3 — cgroup tier conformance":

  test "pass_always under real cgroup-v2 delegation: killDomain=kdsCgroup, tree=toComplete, no escapees":
    if not cachedCapabilities().cgroupDelegation:
      skip()
    else:
      let bin = compileFixture("pass_always")
      var core = initPosixCore(installSignals = false)
      let outPath = tmpOutputFile("conformance")
      let spec = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(core, spec, getMonoTime() + initDuration(seconds = 5))
      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0
      check report.killDomain == kdsCgroup
      check report.tree == toComplete
      check report.escapees.len == 0
      removeFile(outPath)

# ---------------------------------------------------------------------------
# Suite 2 — fault injection (load-bearing): per-spawn honest degrade
# ---------------------------------------------------------------------------

suite "rfc-0007 B3 — fault injection: per-spawn honest degrade":

  test "green probe + an un-creatable leaf path for spawn 0 -> that spawn's killDomain honestly degrades, run still correct":
    if not cachedCapabilities().cgroupDelegation:
      skip()
    else:
      let parent = cgroupSiblingParent()
      require parent.len > 0   # the probe is green — this must resolve
      var core = initPosixCore(installSignals = false)
      # Sabotage: pre-create a REGULAR FILE at the exact path spawnChild
      # will try to mkdir for THIS spawn — `initPosixCore`'s documented
      # contract (`nextIdVal: 0'i32`) makes id 0 the first spawn on a
      # fresh core, so this path is fully predictable. A plain file where
      # a directory needs to go is un-creatable regardless of privilege
      # level (even --privileged root cannot mkdir over an existing
      # regular file) — unlike a permission-based sabotage a privileged CI
      # container's root would simply bypass.
      let leafPath = parent / cgroupSlotLeafName(getpid(), 0'i32)
      sabotageLeaf(leafPath)
      defer: cleanupSabotagedLeaf(leafPath)

      let bin = compileFixture("pass_always")
      let outPath = tmpOutputFile("fault")
      let spec = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(core, spec, getMonoTime() + initDuration(seconds = 5))

      # The run itself is completely unaffected by the leaf failure — spawn/
      # exec/exit observation never depended on the cgroup leaf existing.
      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0

      # THE assertion: despite the green probe, THIS spawn's leaf failed to
      # materialize -> honest degrade to the pre-B3 achieved domain, NEVER
      # a false kdsCgroup claim. This tier really is a subreaper (B1),
      # independent of B3, so that is the exact degraded domain expected.
      check report.killDomain != kdsCgroup
      check report.killDomain == kdsProcessGroupSubreaper
      check report.tree == toComplete   # the degraded domain is STILL toComplete (B1)
      removeFile(outPath)

  test "a later spawn on the SAME core (a fresh id) is unaffected by the earlier spawn's sabotaged leaf":
    ## Proves the degrade is genuinely PER-SPAWN, not a core-wide latch: the
    ## sabotaged path only collides with id 0's name, so id 1 (this spawn)
    ## gets a real leaf normally.
    if not cachedCapabilities().cgroupDelegation:
      skip()
    else:
      let parent = cgroupSiblingParent()
      require parent.len > 0
      var core = initPosixCore(installSignals = false)
      let sabotagedPath = parent / cgroupSlotLeafName(getpid(), 0'i32)
      sabotageLeaf(sabotagedPath)
      defer: cleanupSabotagedLeaf(sabotagedPath)

      let bin = compileFixture("pass_always")

      let outPath0 = tmpOutputFile("fault_seq0")
      let spec0 = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath0))
      let (ev0, report0) = spawnAndWait(core, spec0, getMonoTime() + initDuration(seconds = 5))
      check ev0.kind == weChildExited
      check report0.killDomain == kdsProcessGroupSubreaper   # id 0: degraded
      removeFile(outPath0)

      let outPath1 = tmpOutputFile("fault_seq1")
      let spec1 = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath1))
      let (ev1, report1) = spawnAndWait(core, spec1, getMonoTime() + initDuration(seconds = 5))
      check ev1.kind == weChildExited
      check report1.killDomain == kdsCgroup   # id 1: real leaf, unaffected
      removeFile(outPath1)

# ---------------------------------------------------------------------------
# Suite 3 — lkMemory E2E: a real cgroup memory.max OOM kill
# ---------------------------------------------------------------------------

suite "rfc-0007 B3 — lkMemory: a small memory.max ceiling OOMs the child":

  test "rss_oom under a 48 MiB memory.max -> Cause(cbLimit, lkMemory), exit SIGKILL, oom_kill observed":
    if not cachedCapabilities().cgroupDelegation:
      skip()
    else:
      let bin = compileFixture("rss_oom")
      var core = initPosixCore(installSignals = false)
      let outPath = tmpOutputFile("oom")
      var limits = Limits()
      # 48 MiB: generous margin above a trivial dynamically-linked Nim
      # binary's baseline RSS (a few MiB), but tiny next to rss_oom.nim's
      # 512 MiB safety cap — the OOM kill lands within the first ~50
      # chunks (~100ms), long before that cap or the 15s deadline below.
      limits.req[lkMemory] = some(48 * 1024 * 1024'i64)
      let spec = ChildSpec(argv: @[bin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath), limits: limits)
      let (ev, report) = spawnAndWait(core, spec, getMonoTime() + initDuration(seconds = 15))

      check ev.kind == weChildExited
      check report.exit.kind == ekSignaled
      check report.exit.sig == int(SIGKILL)
      check report.limits[lkMemory] == lsApplied
      check report.memoryOomKill == true   # the leaf's memory.events oom_kill>0 readback

      let cause = classifyCause(report.exit, report.stop, limits, report.limits,
                                report.memoryOomKill)
      check cause.by == cbLimit
      check cause.limit == lkMemory
      removeFile(outPath)

when isMainModule:
  echo "test_rfc0007_b3_cgroup: done"
