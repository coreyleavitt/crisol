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
import crisol/process/types as ptypes

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

suite "rfc-0007 A6a — spawn_grandchild: a same-pgroup grandchild IS observed":

  test "evidence.escapees carries the leaked grandchild (pid > 0)":
    let r = runSingle("spawn_grandchild.nim", "spawn_grandchild.pid", "gc")
    check r.outcome == oPassed   # the entrypoint itself is a clean pass
    let ev = runEvidence(r)
    require ev.escapees.len == 1
    check ev.escapees[0].pid > 0

  test "tree stays toUnobservable even WITH an observed escapee (pgid-only tier)":
    ## §2/§3: a pgid-only tier may NEVER claim toComplete — "every pid I saw
    ## is gone" is vacuous when the scan cannot see a setsid escape. That
    ## honesty holds regardless of what THIS scan happened to find.
    let r = runSingle("spawn_grandchild.nim", "spawn_grandchild.pid", "gc2")
    let ev = runEvidence(r)
    check ev.tree == ptypes.toUnobservable

# ---------------------------------------------------------------------------
# Suite 2 — the invisible escapee (spawn_grandchild_setsid)
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — spawn_grandchild_setsid: invisible to a pgid scan by construction":

  test "evidence.escapees stays empty (the daemonized grandchild left the group)":
    let r = runSingle("spawn_grandchild_setsid.nim", "spawn_grandchild_setsid.pid", "setsid")
    check r.outcome == oPassed
    let ev = runEvidence(r)
    check ev.escapees.len == 0

  test "tree is the honest toUnobservable label, never a false toComplete":
    let r = runSingle("spawn_grandchild_setsid.nim", "spawn_grandchild_setsid.pid", "setsid2")
    let ev = runEvidence(r)
    check ev.tree == ptypes.toUnobservable

# ---------------------------------------------------------------------------
# Suite 3 — killSnapshot reaches Evidence, rssBytes populated (hang_forever)
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — killSnapshot reaches Evidence with a real rssBytes":

  test "hang_forever times out: evidence.killSnapshot is non-empty with rssBytes > 0":
    ## The first stop act (requestStop, on timeout) already snapshots the
    ## process group in posixcore — this pins that the snapshot actually
    ## reaches the wire-facing Evidence, not just ReapReport.
    let r = runSingle("hang_forever.nim", "no_marker", "hang", runTimeoutMs = 300)
    let ev = runEvidence(r)
    require ev.killSnapshot.len >= 1
    check ev.killSnapshot[0].pid > 0
    check ev.killSnapshot[0].rssBytes > 0

echo "test_rfc0007_a6a_escapee_evidence: done"
