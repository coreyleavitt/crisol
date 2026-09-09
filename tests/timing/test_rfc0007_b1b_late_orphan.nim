## test_rfc0007_b1b_late_orphan.nim — rfc-0007 B1b E2E: the async
## `waitid(P_ALL, WNOWAIT)` orphan sweep in `next()`, proven through the
## real entry point (`crisol run --json`).
##
## Drives tests/fixtures/spawn_late_orphan.nim (paired with
## pass_after_delay.nim purely to keep the executor's event loop alive
## long enough to observe the late chain — see that fixture's doc comment)
## and asserts BOTH `weOrphanReaped` destinations fire for real:
##   1. Chain 1 (G1): dies while its owning slot is still live — folded
##      into that slot's OWN `run.evidence.escapees` (never a separate
##      wire field; same list rfc-0007 A6a/B1a already populate).
##   2. Chain 2 (G2): a setsid orphan that dies well after its owner has
##      already been reaped and emitted — counted at RUN level via the
##      top-level `lateOrphansReaped` field (rev 24), never retro-fitted
##      into the already-emitted result.
## Both escapees actually being GONE afterward (not merely un-waited) is
## also asserted — the "reaped, not leaked" half of item 543, same as B1a's
## tracer.
##
## GATING: quits 0 immediately when CRISOL_TIMING_TESTS is unset/empty —
## see tests/timing/test_rlimits_timing.nim for the full rationale. This
## fixture's cross-chain timing (a slot dying while its owner is still
## live vs. well after) is inherently wall-clock-dependent; parallel host
## load flakes it, hence the timing suite + serial `./dev timing` home.
##
## Run with:
##   ./dev timing
## or, for this file alone:
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
##     --path:src tests/timing/test_rfc0007_b1b_late_orphan.nim

import std/[json, os, posix, strutils, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

# ---------------------------------------------------------------------------
# Helpers (per-file idiom — no cross-test-file import, see
# test_rfc0007_a1b_kill_path.nim's identical captureStdout)
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  let outPath = getTempDir() / ("crisol_rfc0007_b1b_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## test's cache entries never collide with any other test's.
  result = getTempDir() / ("crisol_b1b_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

proc reapMarker(root, markerName: string) =
  ## Safety-net teardown only — crisol's own B1 mechanism is expected to
  ## have already killed+reaped everything; this exists purely so a test
  ## FAILURE (an assertion tripping before cleanup) never leaves a stray
  ## sleeper behind.
  let markerPath = root / markerName
  if fileExists(markerPath):
    try:
      let pid = parseInt(readFile(markerPath).strip())
      if pid > 0: discard posix.kill(Pid(pid), SIGKILL)
    except CatchableError:
      discard

proc isGone(pid: int): bool =
  ## true iff no process exists at `pid` any more (posix.kill(pid, 0) as a
  ## pure existence probe — ESRCH means truly gone, not merely un-waited).
  let rc = posix.kill(Pid(pid), 0.cint)
  rc == -1 and errno == ESRCH

suite "rfc-0007 B1b — spawn_late_orphan: both weOrphanReaped destinations fire":

  test "fold-in (still-live owner) AND run-level (already-emitted owner) both observed":
    let root = freshProjectRoot("lateorphan")
    defer:
      reapMarker(root, "spawn_late_orphan_g1.pid")
      reapMarker(root, "spawn_late_orphan_g2.pid")
      reapMarker(root, "spawn_late_orphan.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_rfc0007_b1b_late_orphan_a_spawn.nim",
             readFile(fixtureDir() / "spawn_late_orphan.nim"))
    writeFile(root / "tests" / "unit" / "test_rfc0007_b1b_late_orphan_b_keepalive.nim",
             readFile(fixtureDir() / "pass_after_delay.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                         "--jobs", "1", "--json"])
    check code == 0
    let doc = parseJson(output)
    require doc["entrypoints"].len == 2

    # Discovery order is sorted by (path, group) — "..._a_spawn" precedes
    # "..._b_keepalive" lexicographically, so index 0 is deterministically
    # spawn_late_orphan.
    let epSpawn = doc["entrypoints"][0]
    check epSpawn["path"].getStr.contains("late_orphan_a_spawn")
    check epSpawn["outcome"].getStr == "passed"

    # rfc-0007 B1: the subreaper tier sees the whole descendant tree.
    check epSpawn["run"]["evidence"]["tree"].getStr == "complete"

    # Chain 1 (G1, folded into this slot's OWN escapees while still live)
    # PLUS chain 2's H2 (killed as P's own escapee at P's reap — which is
    # what orphans G2 onto crisol in the first place) PLUS H1 (a zombie
    # child of P, reparented and reaped at P's own reap alongside H2) — see
    # the fixture's doc comment for the full accounting: exactly 3.
    let escapees = epSpawn["run"]["evidence"]["escapees"]
    require escapees.len == 3
    var g1Found = false
    for e in escapees:
      let epid = e["pid"].getInt
      check epid > 0
      check isGone(epid)   # reaped, not leaked (item 543's other half)
      if fileExists(root / "spawn_late_orphan_g1.pid") and
         epid == parseInt(readFile(root / "spawn_late_orphan_g1.pid").strip()):
        g1Found = true
    check g1Found   # the fold-in path actually landed the RIGHT pid

    # Chain 2 (G2): unattributable (setsid) AND its owner (P) had already
    # been reaped/emitted by the time it died — counted at RUN level, not
    # retro-fitted into epSpawn's escapees above.
    require doc.hasKey("lateOrphansReaped")
    check doc["lateOrphansReaped"].getInt == 1
    let g2MarkerPath = root / "spawn_late_orphan_g2.pid"
    require fileExists(g2MarkerPath)
    let g2Pid = parseInt(readFile(g2MarkerPath).strip())
    check isGone(g2Pid)   # reaped, not leaked

    # The keepalive entrypoint itself is an unrelated clean pass — sanity
    # only (it is not part of the property under test).
    let epKeepalive = doc["entrypoints"][1]
    check epKeepalive["outcome"].getStr == "passed"

when isMainModule:
  echo "test_rfc0007_b1b_late_orphan done"
