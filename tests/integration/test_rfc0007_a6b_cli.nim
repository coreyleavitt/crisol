## test_rfc0007_a6b_cli.nim — rfc-0007 A6b E2E, two properties through the
## real entry point (`crisol run`):
##
##   1. `--strict-hygiene` promotes a would-be pass with an OBSERVED escapee
##      (spawn_grandchild, same-pgroup, visible — the A6a fixture) to a
##      failure: `outcome` flips passed -> exitNonZero and the process exit
##      code flips 0 -> 1. Without the flag, the same fixture still exits 0
##      (unstrict is the default — both directions pinned in one file so a
##      future regression in either can't hide behind the other passing).
##      The cache-store gate is UNAFFECTED either way — an observed escapee
##      is already uncacheable via `evidenceSatisfies` (A6a); `--strict-
##      hygiene` never reaches the cache's own `outcome()` call (RFC-0007
##      §2: "the cache always stores the observation and derives unstrict").
##
##   2. `Evidence.hermetic` (runner-authored, folded into this slice per
##      A6a's flag) reaches the `run/v2` wire `evidence.hermetic` node: the
##      default level (`isolated`, no `--hermetic` flag) and an explicitly
##      requested non-default level (`--hermetic none`) are both pinned
##      against a plain passing fixture (`pass_always`) — no escapee
##      involvement, an orthogonal axis.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a6b_cli.nim

import std/[json, os, posix, strutils, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers (per-file idiom — no cross-test-file import, mirrors
# test_rfc0007_a6a_cli.nim's identical captureStdout/freshProjectRoot)
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  let outPath = getTempDir() / ("crisol_rfc0007_a6b_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_a6b_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

proc reapMarker(root, markerName: string) =
  ## The spawn_grandchild fixture's grandchild is orphaned by construction
  ## (its immediate parent — the entrypoint — already exited), so this test
  ## process is never its real parent and cannot wait() it; SIGKILL by pid
  ## (read from the marker the fixture itself writes, at the run child's
  ## cwd — projectRoot, rfc-0007 A2c) is the correct teardown.
  let markerPath = root / markerName
  if fileExists(markerPath):
    try:
      let pid = parseInt(readFile(markerPath).strip())
      if pid > 0: discard posix.kill(Pid(pid), SIGKILL)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Suite 1 — --strict-hygiene: escapee-bearing pass becomes a failure
# ---------------------------------------------------------------------------

suite "rfc-0007 A6b — --strict-hygiene promotes an observed escapee to a failure":

  test "spawn_grandchild WITHOUT --strict-hygiene: exit 0, outcome passed (unstrict default)":
    let root = freshProjectRoot("gc_unstrict")
    defer:
      reapMarker(root, "spawn_grandchild.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild.nim",
             readFile(fixtureDir() / "spawn_grandchild.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                         "--jobs", "1", "--json"])
    let ep = firstEntrypoint(output)
    require ep["run"]["evidence"]["escapees"].len == 1  # the fixture DID leak
    check ep["outcome"].getStr == "passed"
    check code == 0

  test "spawn_grandchild WITH --strict-hygiene: exit 1, outcome exitNonZero (hygiene failure)":
    let root = freshProjectRoot("gc_strict")
    defer:
      reapMarker(root, "spawn_grandchild.pid")
      removeDir(root)
    writeFile(root / "tests" / "unit" / "test_spawn_grandchild.nim",
             readFile(fixtureDir() / "spawn_grandchild.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                         "--jobs", "1", "--strict-hygiene", "--json"])
    let ep = firstEntrypoint(output)
    require ep["run"]["evidence"]["escapees"].len == 1  # same observation as unstrict
    check ep["outcome"].getStr == "exitNonZero"          # but the VERDICT flips
    # The cache-store gate is untouched by the policy: an observed escapee
    # was already uncacheable via evidenceSatisfies before this slice.
    check ep["cacheDecision"].getStr == "hermeticityDegraded"
    check code == 1

# ---------------------------------------------------------------------------
# Suite 2 — Evidence.hermetic reaches the run/v2 wire evidence node
# ---------------------------------------------------------------------------

suite "rfc-0007 A6b — Evidence.hermetic reaches the run/v2 wire":

  test "no --hermetic flag: evidence.hermetic == isolated (the default level)":
    let root = freshProjectRoot("herm_default")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass_always.nim",
             readFile(fixtureDir() / "pass_always.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                         "--jobs", "1", "--json"])
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["run"]["evidence"]["hermetic"].getStr == "isolated"

  test "--hermetic none: evidence.hermetic == none (the configured, non-default level)":
    let root = freshProjectRoot("herm_none")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass_always.nim",
             readFile(fixtureDir() / "pass_always.nim"))
    let cfgPath = root / "crisol.kdl"

    let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                         "--jobs", "1", "--hermetic", "none", "--json"])
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["run"]["evidence"]["hermetic"].getStr == "none"

when isMainModule:
  echo "test_rfc0007_a6b_cli done"
