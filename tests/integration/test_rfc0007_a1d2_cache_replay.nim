## test_rfc0007_a1d2_cache_replay.nim — rfc-0007 A1d-ii E2E: cache replay
## carries the REAL stored observation, byte-equal, through the real CLI.
##
## This is the slice's load-bearing hit-path proof: run once cold (live,
## stores), once warm (cache hit), both through `crisol run --json`
## (crisol/run/v2). The replayed entry's `run.cause`, `run.evidence.tree`,
## and `run.rusage` nodes -- fields the pre-A1d-ii interim `synthesize()`
## could never carry (it fabricated a constant `Cause(cbProcess)` and left
## evidence/rusage at their zero-value defaults -- `rusage` serialized as
## JSON `null`) -- must be BYTE-EQUAL to what the cold run actually
## observed, not merely the outcome string.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a1d2_cache_replay.nim

import std/[json, os, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers (per-file idiom, no cross-test-file import -- see
# test_rfc0007_a1b_kill_path.nim's identical captureStdout)
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_rfc0007_a1d2_cap_" & $getpid() & "_" &
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
  result = getTempDir() / ("crisol_a1d2_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 A1d-ii — cache replay carries the real stored observation (crisol run --json)":

  test "cold run then warm hit: run.cause / run.evidence.tree / run.rusage are byte-equal":
    let root = freshProjectRoot("bytequal")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass.nim", "quit(0)\n")
    let cfgPath = root / "crisol.kdl"

    # Cold: live run. Only oPassed results are ever stored (pass-only store).
    let (code1, out1) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code1 == 0
    let ep1 = firstEntrypoint(out1)
    check ep1["outcome"].getStr == "passed"
    check ep1["cached"].getBool == false
    check ep1["run"]["kind"].getStr == "ran"
    check ep1["run"].hasKey("rusage")

    # Warm: identical config + entrypoint -> served from cache (edCached).
    let (code2, out2) = captureStdout(@["run", "--config", cfgPath,
                                        "--jobs", "1", "--json"])
    check code2 == 0
    let ep2 = firstEntrypoint(out2)
    check ep2["outcome"].getStr == "passed"
    check ep2["cached"].getBool == true
    check ep2["cacheDecision"].getStr == "hit"
    check ep2["run"]["kind"].getStr == "cached"

    # The pinned nodes: BYTE-EQUAL between the cold observation and the warm
    # replay. `rusage` is the decisive proof -- the interim synthesize()
    # could only ever produce `null` there (none(Rusage)); a real cache
    # replay reproduces the cold run's ACTUAL measured numbers exactly, which
    # a second, independent live measurement could never coincidentally
    # match (this IS a cache hit -- no live run happens on the warm call).
    check $ep1["run"]["cause"]            == $ep2["run"]["cause"]
    check $ep1["run"]["evidence"]["tree"] == $ep2["run"]["evidence"]["tree"]
    check $ep1["run"]["rusage"]           == $ep2["run"]["rusage"]
    check ep1["run"]["rusage"].kind != JNull   # the cold run's rusage is real...
    check ep2["run"]["rusage"].kind != JNull   # ...and so is the warm replay's.

echo "test_rfc0007_a1d2_cache_replay: done"
