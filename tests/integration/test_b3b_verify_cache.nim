## test_b3b_verify_cache.nim — RFC-0005 B3b: the --verify-cache post-run pass.
##
## Drives the pass entirely through the public crisol/api surface (runTests),
## against the REAL on-disk ExecutionCache — no mocks. Two fixtures:
##
##   1. NONDETERMINISTIC (test_flip.nim): flips its exit code based on a
##      counter file it writes to projectRoot on every real execution. Run 1
##      (live) exits 0 and gets stored; run 2 is served from the cache
##      (cdmHit, exit 0 still) but the verify pass genuinely RE-EXECUTES the
##      fixture a third time — flipping the counter again — so the fresh
##      Exit (1) diverges from the stored Exit (0). Proves: divergence
##      detection, the stderr warning (never silent), RunReport.results
##      untouched (guard 3), and — via the counter file itself, an
##      OBSERVABLE side effect of the real subprocess, not an internals
##      peek — that the sampled entry genuinely dispatched through
##      spawnRunDirect rather than being replayed from the cache.
##   2. DETERMINISTIC (test_pass.nim, quit(0)): no divergence.
##
## A third assertion (both suites) reads lastrun.json directly and confirms
## it reflects ONLY the main run's cache-served result — proving the pass's
## placement is strictly after persistLastRun (RFC-0005 "Binary
## precondition... the pass runs before releaseLock, after persistLastRun").
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_b3b_verify_cache.nim

import std/[json, os, strutils, unittest]
import std/posix as posix_mod
import crisol/api

import "../support/helpers"

# ---------------------------------------------------------------------------
# stderr capture helper (mirrors tests/unit/test_jsonout.nim's
# captureStdoutToFile — POSIX dup/dup2/close, fd 2 instead of fd 1).
# ---------------------------------------------------------------------------

proc captureStderrToFile(path: string; body: proc()): void =
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(2.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(2) failed")
  discard posix_mod.dup2(fileFd, 2.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod.dup2(savedFd, 2.cint)
    discard posix_mod.close(savedFd)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc baseOpts(projectRoot: string; vc: VerifyCache): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,   # writes lastrun.json; the pass must land after it
    showProgress:   false,
    verifyCache:    vc,
  )

## Flips its exit code on every REAL execution, tracked via a counter file
## written to the project root (spawnRunDirect's CWD — rfc-0007 issue #17).
## Odd invocation count -> exit 0 (so the FIRST live run passes and stores);
## even -> exit 1.
const NondeterministicFixture = """
import std/[os, strutils]
const counterFile = "verify_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
if n mod 2 == 1: quit(0) else: quit(1)
"""

proc lastRunEntry(projectRoot, epPath: string): JsonNode =
  let raw = parseJson(readFile(projectRoot / ".crisol" / "lastrun.json"))
  for ep in raw["entrypoints"]:
    if ep["path"].getStr == epPath:
      return ep
  raise newException(ValueError, "no lastrun.json entry for " & epPath)

# ---------------------------------------------------------------------------
# 1. Nondeterministic fixture -> divergence
# ---------------------------------------------------------------------------

suite "B3b — verify-cache divergence (nondeterministic fixture)":

  test "fresh re-execution diverges from the cache-served result; reported, never silent":
    withTempProject:
      let epPath = "tests/unit/test_flip.nim"
      writeFile(projectRoot / epPath, NondeterministicFixture)

      # Run 1: live. Odd invocation (n=1) -> exit 0 -> stored.
      let rr1 = runTests(baseOpts(projectRoot, noVerify()))
      check rr1.exitCode == 0
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      check readFile(projectRoot / "verify_counter.txt").strip() == "1"

      # Run 2: served from cache (cdmHit; no fresh execution for the main
      # run itself) + --verify-cache samples the single hit (pct=100, and a
      # 1-entry hit set always samples — see types.sampleHitIndices'
      # max(1, ...) floor).
      let stderrPath = projectRoot / "stderr_capture.txt"
      var rr2: RunReport
      captureStderrToFile(stderrPath, proc () =
        rr2 = runTests(baseOpts(projectRoot, verifySample(pct = 100))))

      # The main run's reported outcome is UNCHANGED by the verify pass —
      # it reports on the cache-served result immediately; verification is
      # a trailing pass (guard 3: never merged into RunReport.results).
      check rr2.exitCode == 0
      check rr2.results.len == 1
      check rr2.results[0].cacheDecision == cdmHit

      # Observable proof of a genuinely FRESH execution (spawnRunDirect),
      # not a cache replay: the counter file — written only by a real
      # subprocess invocation — advanced to 2 (even -> the fresh run
      # actually exited 1).
      check readFile(projectRoot / "verify_counter.txt").strip() == "2"

      # The divergence surfaces ONLY in verifyDivergences, never in .results.
      check rr2.verifyDivergences.len == 1
      let dv = rr2.verifyDivergences[0]
      check dv.ep.path == epPath
      check dv.exitDiverged
      check not dv.recordsDiverged   # neither run emits protocol records

      # Never silent: a stderr warning names the entrypoint.
      let captured = readFile(stderrPath)
      check epPath in captured
      check "diverg" in captured.toLowerAscii

      # Placement proof: lastrun.json reflects ONLY the main run's
      # cache-served (passing) result — never the verify pass's diverged,
      # failing fresh exit. This is only possible if the pass ran strictly
      # after persistLastRun.
      let entry = lastRunEntry(projectRoot, epPath)
      check entry["outcome"].getStr == "passed"
      check entry["cacheDecision"].getStr == "hit"

# ---------------------------------------------------------------------------
# 2. Deterministic fixture -> no divergence
# ---------------------------------------------------------------------------

suite "B3b — verify-cache, deterministic fixture":

  test "a deterministic quit(0) fixture never diverges":
    withTempProject:
      let epPath = "tests/unit/test_pass.nim"
      writeFile(projectRoot / epPath, "quit(0)\n")

      let rr1 = runTests(baseOpts(projectRoot, noVerify()))
      check rr1.results[0].cacheDecision == cdmStored

      let rr2 = runTests(baseOpts(projectRoot, verifySample(pct = 100)))
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.verifyDivergences.len == 0

      let entry = lastRunEntry(projectRoot, epPath)
      check entry["outcome"].getStr == "passed"
      check entry["cacheDecision"].getStr == "hit"

echo "test_b3b_verify_cache: done"
