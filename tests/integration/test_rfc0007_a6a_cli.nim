## test_rfc0007_a6a_cli.nim — rfc-0007 A6a E2E: escapee observation gates
## the cache AND renders a warning, proven through the real entry point
## (`crisol run`).
##
## Before this slice, the cache-store gate (`shouldStore` → `isFullyAchieved`)
## never consulted `evidence.escapees` at all — a leaked same-pgroup
## grandchild (spawn_grandchild) would have been cached exactly like any
## other clean pass, silently vouching for an environment that had already
## leaked a side effect. This file is RED against that behavior before the
## `evidenceSatisfies` cache-gate wiring lands.
##
## Two properties, both through the CLI:
##   1. spawn_grandchild: observed escapee ⇒ NOT stored — a second run
##      re-executes (still shows the same escapee, still not cached), and
##      the plain-text render carries a first-class warning tag.
##   2. spawn_grandchild_setsid: escapee invisible to the pgid tier ⇒ the
##      honest `toUnobservable` label, but EMPTY escapees ⇒ still
##      cacheable — a second run IS served from cache, with the
##      `toUnobservable` tree label replayed on the wire. No warning tag.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a6a_cli.nim

import std/[json, os, posix, strutils, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers (per-file idiom — no cross-test-file import, see
# test_rfc0007_a1b_kill_path.nim's identical captureStdout)
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  let outPath = getTempDir() / ("crisol_rfc0007_a6a_cap_" & $getpid() & "_" &
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

proc firstEntrypoint(jsonText: string): JsonNode =
  let doc = parseJson(jsonText)
  check doc["entrypoints"].len == 1
  doc["entrypoints"][0]

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## test's cache entries never collide with any other test's.
  result = getTempDir() / ("crisol_a6a_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

proc reapMarker(root, markerName: string) =
  ## The fixture's grandchild is orphaned by construction (its immediate
  ## parent — the entrypoint — already exited), so this test process is
  ## never its real parent and cannot wait() it; SIGKILL by pid (read from
  ## the marker the fixture itself writes, at the run child's cwd —
  ## `projectRoot`, rfc-0007 A2c) is the correct teardown.
  let markerPath = root / markerName
  if fileExists(markerPath):
    try:
      let pid = parseInt(readFile(markerPath).strip())
      if pid > 0: discard posix.kill(Pid(pid), SIGKILL)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Suite 1 — observed escapee (spawn_grandchild): not cached, re-executes
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — spawn_grandchild: observed escapee is NOT cached":

  test "cold run then warm re-run: both live, escapee observed both times":
    let root = freshProjectRoot("gc")
    defer:
      reapMarker(root, "spawn_grandchild.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild.nim",
             readFile(fixtureDir() / "spawn_grandchild.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code1, out1) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code1 == 0
    let ep1 = firstEntrypoint(out1)
    check ep1["outcome"].getStr == "passed"
    check ep1["cached"].getBool == false
    require ep1["run"]["evidence"]["escapees"].len == 1
    # Observed escapee ⇒ NOT stored — cdmHermeticityDeg, not cdmStored.
    check ep1["cacheDecision"].getStr == "hermeticityDegraded"

    reapMarker(root, "spawn_grandchild.pid")   # the cold run's grandchild

    let (code2, out2) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code2 == 0
    let ep2 = firstEntrypoint(out2)
    # NOT served from cache — the store never happened, so this is a fresh
    # miss again (still ran live, still shows the escapee).
    check ep2["cached"].getBool == false
    check ep2["run"]["kind"].getStr == "ran"
    require ep2["run"]["evidence"]["escapees"].len == 1

# ---------------------------------------------------------------------------
# Suite 2 — invisible escapee (spawn_grandchild_setsid): cacheable-with-label
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — spawn_grandchild_setsid: cacheable, honest toUnobservable label":

  test "cold run then warm hit: served from cache, tree label replayed byte-equal":
    let root = freshProjectRoot("setsid")
    defer:
      reapMarker(root, "spawn_grandchild_setsid.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild_setsid.nim",
             readFile(fixtureDir() / "spawn_grandchild_setsid.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code1, out1) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code1 == 0
    let ep1 = firstEntrypoint(out1)
    check ep1["outcome"].getStr == "passed"
    check ep1["cached"].getBool == false
    check ep1["run"]["evidence"]["escapees"].len == 0
    check ep1["run"]["evidence"]["tree"].getStr == "unobservable"
    # Cacheable: no escapee observed, even though the tier can't fully vouch.
    check ep1["cacheDecision"].getStr == "stored"

    let (code2, out2) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code2 == 0
    let ep2 = firstEntrypoint(out2)
    check ep2["cached"].getBool == true
    check ep2["cacheDecision"].getStr == "hit"
    check ep2["run"]["kind"].getStr == "cached"
    # The honest label survives the roundtrip byte-equal, not a fabricated
    # re-derivation.
    check ep2["run"]["evidence"]["tree"].getStr == "unobservable"
    check ep2["run"]["evidence"]["escapees"].len == 0

# ---------------------------------------------------------------------------
# Suite 3 — render warning (plain-text, non-JSON `crisol run` output)
# ---------------------------------------------------------------------------

suite "rfc-0007 A6a — render: a first-class warning tag on an observed escapee":

  test "spawn_grandchild: plain render shows an [ESCAPEE] warning tag":
    let root = freshProjectRoot("gc_render")
    defer:
      reapMarker(root, "spawn_grandchild.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild.nim",
             readFile(fixtureDir() / "spawn_grandchild.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath, "--jobs", "1"])
    check code == 0
    check "[ESCAPEE]" in output

  test "spawn_grandchild_setsid: plain render carries NO escapee warning":
    let root = freshProjectRoot("setsid_render")
    defer:
      reapMarker(root, "spawn_grandchild_setsid.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild_setsid.nim",
             readFile(fixtureDir() / "spawn_grandchild_setsid.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath, "--jobs", "1"])
    check code == 0
    check "[ESCAPEE]" notin output

when isMainModule:
  echo "test_rfc0007_a6a_cli done"
