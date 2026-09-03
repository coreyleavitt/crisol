## test_rfc0007_a7_substrate_cli.nim — rfc-0007 A7 E2E: `capabilities()` reaches
## the wire, through the real entry point (`crisol run --json` / `crisol run
## --dry-run --json`), not a hand-built JsonNode.
##
## Tier detection (§4's two known tiers):
##   - "Linux CI leg" (ci.yml's `test` job, a plain `docker run` on a GitHub-
##     hosted ubuntu-latest runner) — CRISOL_TIER=ci-linux is set explicitly
##     by that job's docker invocation (ci.yml), because GITHUB_ACTIONS itself
##     is a runner-host fact that is NOT forwarded into the container by
##     `docker run -e ...` unless named explicitly — same convention already
##     used for CRISOL_TIMING_TESTS/CRISOL_TEST_DIRS.
##   - "rootless-podman dev tier" (`./dev test`) — CRISOL_TIER unset.
## Both tiers run this same file (tests/integration is a default discovery
## dir); the assertions below are real, tier-appropriate pins, not dead
## branches — each arm actually executes on the tier it names.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a7_substrate_cli.nim

import std/[json, os, posix, strutils, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  let outPath = getTempDir() / ("crisol_rfc0007_a7_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_a7_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

const LinuxSubstrateKeys = ["pidfd", "subreaper", "cgroupDelegation",
                            "cgroupKill", "memoryPeak", "flock", "wait4Rusage"]
const InapplicableKeys = ["kqueue", "jobObjectNesting", "ctrlBreakDeliverable"]

proc checkLinuxShape(sub: JsonNode) =
  ## §4: "a platform's substrate node is its own, never a placeholder" —
  ## exactly the Linux-applicable keys, each a real bool, nothing else.
  check sub.kind == JObject
  for key in LinuxSubstrateKeys:
    require sub.hasKey(key)
    check sub[key].kind == JBool
  for key in InapplicableKeys:
    check not sub.hasKey(key)

proc checkTierPins(sub: JsonNode) =
  ## The acceptance pins from RFC-0007 line 539 — real assertions, gated to
  ## the tier they actually hold on, so an inert always-false (or always-
  ## true) probe fails HERE rather than silently passing on the wrong tier.
  if getEnv("CRISOL_TIER") == "ci-linux":
    check sub["pidfd"].getBool == true
    check sub["wait4Rusage"].getBool == true
    check sub["flock"].getBool == true
  else:
    # rootless-podman dev tier (./dev test): no cgroup delegation, no
    # user-ns, but PR_SET_CHILD_SUBREAPER is unprivileged and unaffected.
    check sub["subreaper"].getBool == true
    check sub["cgroupDelegation"].getBool == false

proc checkInternalConsistency(sub: JsonNode) =
  ## §4: "a delegated 5.15 LTS host must probe green for delegation and red
  ## for the files it lacks" — the converse always holds regardless of tier:
  ## cgroup.kill/memory.peak can only be true INSIDE a delegated leaf.
  if not sub["cgroupDelegation"].getBool:
    check sub["cgroupKill"].getBool == false
    check sub["memoryPeak"].getBool == false

# ---------------------------------------------------------------------------
# Suite 1 — run/v2: top-level `substrate` node
# ---------------------------------------------------------------------------

suite "rfc-0007 A7 — run/v2 substrate node reaches the wire via crisol run --json":

  let root = freshProjectRoot("run")
  writeFile(root / "tests" / "unit" / "test_pass_always.nim",
           readFile(fixtureDir() / "pass_always.nim"))
  let cfgPath = root / "crisol.kdl"
  let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                       "--jobs", "1", "--json"])
  let doc = parseJson(output)

  test "exit 0 and top-level substrate key present":
    check code == 0
    require doc.hasKey("substrate")

  test "substrate has exactly the Linux-applicable keys, all real bools":
    checkLinuxShape(doc["substrate"])

  test "tier-pinned values hold on the tier this test is actually running on":
    checkTierPins(doc["substrate"])

  test "cgroup.kill/memory.peak never true without delegation":
    checkInternalConsistency(doc["substrate"])

  test "evidence.killDomain is the real per-spawn achieved domain (processGroup, this backend)":
    ## Locks the flow verified by source audit: runner.toProcessResult copies
    ## `report.killDomain` (posixcore.reapCore's ReapReport) verbatim into
    ## Evidence — never a literal re-stamped downstream at JSON-render time.
    let ep = doc["entrypoints"][0]
    check ep["run"]["evidence"]["killDomain"].getStr == "processGroup"

  removeDir(root)

# ---------------------------------------------------------------------------
# Suite 2 — plan/v1: top-level `substrate` node
# ---------------------------------------------------------------------------

suite "rfc-0007 A7 — plan/v1 substrate node reaches the wire via crisol run --dry-run --json":

  let root = freshProjectRoot("plan")
  writeFile(root / "tests" / "unit" / "test_pass_always.nim",
           readFile(fixtureDir() / "pass_always.nim"))
  let cfgPath = root / "crisol.kdl"
  let (code, output) = captureStdout(@["run", "--config", cfgPath,
                                       "--dry-run", "--json"])
  let doc = parseJson(output)

  test "exit 0 and top-level substrate key present":
    check code == 0
    require doc.hasKey("substrate")

  test "substrate has exactly the Linux-applicable keys, all real bools":
    checkLinuxShape(doc["substrate"])

  test "tier-pinned values hold on the tier this test is actually running on":
    checkTierPins(doc["substrate"])

  test "cgroup.kill/memory.peak never true without delegation":
    checkInternalConsistency(doc["substrate"])

  removeDir(root)

when isMainModule:
  echo "test_rfc0007_a7_substrate_cli: done"
