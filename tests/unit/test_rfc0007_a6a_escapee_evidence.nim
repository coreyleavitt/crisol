## test_rfc0007_a6a_escapee_evidence.nim — rfc-0007 A6a: escapee observation
## reaches `Evidence`, proven through the real entry point (`execute()`).
##
## Before this slice, `runner.toProcessResult` built `Evidence` from
## `Evidence(limits: report.limits)` alone — `killDomain`/`tree`/`escapees`/
## `killSnapshot`/`cooperativeUnavailable` were silently discarded even
## though `posixcore.reapCore` already carried real backend observations in
## the `ReapReport` (killSnapshot was already captured at the first stop
## act; only the escapee scan and the honest `tree` derivation were
## missing). This is the load-bearing producer proof: three real fixtures,
## three real Evidence facets, all reached through `execute()` (the exact
## poll loop `crisol run` drives) rather than a hand-built ProcessResult.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_a6a_escapee_evidence.nim

import std/[os, posix, strutils, unittest]
import crisol/[types, runner, planner, depgraph, sandbox, cachedispatch]
import crisol/process
import crisol/process/types as ptypes

proc escapeeMechanismsAvailable(): bool =
  ## rfc-0007 C1a: escapee discovery (`discoverAndReapEscapees`) and the
  ## reparented-orphan/setsid-escapee scan it drives are gated in production
  ## (posixcore.nim) on `caps.subreaper and caps.pidfd` — both Linux-only
  ## (PR_SET_CHILD_SUBREAPER, pidfd_open(2)). On the macOS poll-fallback tier
  ## (process/posix.nim until C1b's process/darwin.nim exists) both are
  ## false, so escapees/tree/killSnapshot are honestly empty/unobservable —
  ## not a bug, the mechanism never engaged. Every case below whose premise
  ## depends on that mechanism gates on this and calls `skip()` rather than
  ## asserting the Linux-only outcome unconditionally.
  let caps = capabilities()
  caps.subreaper and caps.pidfd

let isoSpec = resolveSandbox(hlIsolated)

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc reapMarkerGrandchild(dir, markerName: string) =
  ## Teardown: the fixture's grandchild is orphaned by construction (its
  ## immediate parent — the entrypoint — already exited), so this test
  ## process is never its real parent and cannot wait() it; a direct
  ## SIGKILL by pid (read from the marker the fixture itself writes) is
  ## the correct cleanup so the suite never accumulates stray sleepers.
  let markerPath = dir / markerName
  if fileExists(markerPath):
    try:
      let pid = parseInt(readFile(markerPath).strip())
      if pid > 0: discard posix.kill(Pid(pid), SIGKILL)
    except CatchableError:
      discard

proc runSingle(fixtureName, markerName: string; scratchTag: string;
              runTimeoutMs: int64 = 60_000): EntrypointResult =
  ## Copies the named fixture source into a fresh scratch dir and drives it
  ## live through `execute()` (edNeverBuilt: real compile + real run), with
  ## caching fully disabled so this file tests Evidence PRODUCTION only —
  ## the cache-gate consequences are a separate slice (test_cachedispatch.nim).
  let dir = getTempDir() / ("crisol_a6a_" & scratchTag & "_" & $getCurrentProcessId())
  removeDir(dir); createDir(dir)
  defer:
    reapMarkerGrandchild(dir, markerName)
    removeDir(dir)
  let fixt = dir / ("test_" & scratchTag & ".nim")
  writeFile(fixt, readFile(fixtureDir() / fixtureName))

  let pep = PlannedEntrypoint(
    ep: Entrypoint(path: fixt, group: "unit", flags: @[]),
    edecision: edNeverBuilt, runTimeoutMs: runTimeoutMs)
  let p = RunPlan(entrypoints: @[pep], jobs: 1)
  var g = emptyDepGraph()
  let results = execute(
    p, config = Config(projectRoot: dir, stateDir: ".crisol",
                       compileTimeoutSecs: 120, timeoutSecs: 60),
    graph = g, showProgress = false,
    cache = cacheDisabled(isoSpec))
  check results.len == 1
  results[0]

proc runEvidence(r: EntrypointResult): ptypes.Evidence =
  check r.run.kind == ptypes.pkRan
  r.run.res.evidence

# ---------------------------------------------------------------------------
# Suite 1 — the observable escapee (spawn_grandchild)
# ---------------------------------------------------------------------------

suite "rfc-0007 B1 — spawn_grandchild: a same-pgroup grandchild is observed, killed, and reaped":

  test "evidence.escapees carries the leaked grandchild (pid > 0)":
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild.nim", "spawn_grandchild.pid", "gc")
      check r.outcome == oPassed   # the entrypoint itself is a clean pass
      let ev = runEvidence(r)
      require ev.escapees.len == 1
      check ev.escapees[0].pid > 0

  test "tree flips to toComplete: the subreaper tier sees the WHOLE descendant tree":
    ## rfc-0007 B1 (§2/§3): killDomain is now capability-driven
    ## (kdsProcessGroupSubreaper, since this process is really a subreaper
    ## — B1a sets PR_SET_CHILD_SUBREAPER deliberately at Supervisor init),
    ## so `treeObservationFor` honestly reports toComplete — EVEN WITH a
    ## non-empty `escapees` (the two axes are separate, §6): "I can see
    ## every pid in this domain" is a true claim on this tier regardless of
    ## whether something happened to survive past the reap.
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild.nim", "spawn_grandchild.pid", "gc2")
      let ev = runEvidence(r)
      check ev.tree == ptypes.toComplete

  test "the escapee is actually reaped, not leaked: no live process at that pid afterward":
    ## rfc-0007 B1 (§3) item 543's "reaped + counted" half: the fixture's
    ## grandchild sleeps 30s on its own — a LEAKED escapee would still be
    ## alive well after this run returns. B1a kills it via
    ## pidfd_open + starttime-identity-check + pidfd_send_signal and reaps
    ## it (wait4) inside reapCore, so by the time execute() returns, the
    ## pid must be gone (posix.kill(pid, 0) -> ESRCH), not merely un-waited.
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild.nim", "spawn_grandchild.pid", "gc3")
      let ev = runEvidence(r)
      require ev.escapees.len == 1
      let escapeePid = ev.escapees[0].pid
      let rc = posix.kill(Pid(escapeePid), 0.cint)
      check rc == -1
      check errno == ESRCH

# ---------------------------------------------------------------------------
# Suite 2 — the setsid escapee, invisible to the pgid test alone but caught
# by the reparented-orphan (ppid == crisol) discovery path (rfc-0007 B1)
# ---------------------------------------------------------------------------

suite "rfc-0007 B1 — spawn_grandchild_setsid: reparented to crisol, observed, killed, reaped":

  test "evidence.escapees carries the daemonized grandchild (reparented, not pgid-matched)":
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild_setsid.nim", "spawn_grandchild_setsid.pid", "setsid")
      check r.outcome == oPassed
      let ev = runEvidence(r)
      require ev.escapees.len == 1
      check ev.escapees[0].pid > 0

  test "tree flips to toComplete: PR_SET_CHILD_SUBREAPER sees past the setsid escape":
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild_setsid.nim", "spawn_grandchild_setsid.pid", "setsid2")
      let ev = runEvidence(r)
      check ev.tree == ptypes.toComplete

  test "the reparented escapee is actually reaped, not leaked":
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("spawn_grandchild_setsid.nim", "spawn_grandchild_setsid.pid", "setsid3")
      let ev = runEvidence(r)
      require ev.escapees.len == 1
      let escapeePid = ev.escapees[0].pid
      let rc = posix.kill(Pid(escapeePid), 0.cint)
      check rc == -1
      check errno == ESRCH

# ---------------------------------------------------------------------------
# Suite 3 — killSnapshot reaches Evidence, rssBytes populated (hang_forever)
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — killSnapshot reaches Evidence with a real rssBytes":

  test "hang_forever times out: evidence.killSnapshot is non-empty with rssBytes > 0":
    ## The first stop act (requestStop, on timeout) already snapshots the
    ## process group in posixcore — this pins that the snapshot actually
    ## reaches the wire-facing Evidence, not just ReapReport.
    ##
    ## rfc-0007 C1a: `scanProcessGroup`/`readVmRssBytes` walk `/proc`, which
    ## does not exist on macOS (poll-fallback tier, no darwin backend until
    ## C1b) — `killSnapshot` is honestly empty there, not a bug. Reuses the
    ## same subreaper+pidfd gate as the escapee suites above: on every tier
    ## this codebase runs today, that pair is true iff /proc is real.
    if not escapeeMechanismsAvailable():
      skip()
    else:
      let r = runSingle("hang_forever.nim", "no_marker", "hang", runTimeoutMs = 300)
      let ev = runEvidence(r)
      require ev.killSnapshot.len >= 1
      check ev.killSnapshot[0].pid > 0
      check ev.killSnapshot[0].rssBytes > 0

echo "test_rfc0007_a6a_escapee_evidence: done"
