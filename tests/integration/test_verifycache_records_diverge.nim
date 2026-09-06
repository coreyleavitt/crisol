## test_verifycache_records_diverge.nim — RFC-0005 code-review T12/T13:
## recordsDiverge/exitsDiverge coverage for --verify-cache.
##
## Before this fix, `recordsDiverged` (api.exitsDiverge/recordsDiverge, the
## comparison verifyCachePass draws between a stored cache-served
## observation and a fresh forced-live re-execution) had no TRUE-POSITIVE
## test: nothing proved a genuine records-only divergence (constant exit
## code, differing protocol records) is actually detected and flagged
## `recordsDiverged: true` / `exitDiverged: false`. T13 is the cheap
## adjacent case: durationUs is DELIBERATELY excluded from the comparison
## (api.recordsDiverge's own doc comment) -- two records identical in every
## OTHER field but a different durationUs must NOT diverge.
##
## Fixtures write the crisol sink NDJSON wire format DIRECTLY (see
## crisol/protocol.nim's module doc: header `{"crisol":"sink","v":1,
## "ep":"...","pid":n}` then one record per line) rather than importing
## crisol/report or crisol/unittest_shim -- these fixtures compile inside a
## `withTempProject` temp root OUTSIDE the crisol repo tree, where
## `import crisol/...` does not resolve (no nim.cfg `--path:src` reachable
## from that tree; contrast tests/fixtures/protocol_fail_exit0.nim, which
## dogfoods `import crisol/report` successfully only because it lives
## INSIDE the crisol repo and is compiled with the repo root as cwd).
##
## Both fixtures use a counter file (same recipe as test_b3b_verify_cache's
## NondeterministicFixture) to make the SECOND (verify sub-run) invocation's
## sink content differ from the first (main run) invocation's -- but ALWAYS
## `quit(0)`, so `exitDiverged` stays structurally false throughout; only
## the records differ.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_verifycache_records_diverge.nim

import std/[options, os, strutils, unittest]
import std/posix as posix_mod
import crisol/api

import "../support/helpers"

# ---------------------------------------------------------------------------
# stderr capture helper (mirrors test_b3b_verify_cache.nim's own copy).
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

proc baseOpts(projectRoot: string; vc: VerifyCache): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,
    showProgress:   false,
    verifyCache:    vc,
  )

# ---------------------------------------------------------------------------
# T12 fixture: constant exit 0, but the emitted record's `msg` differs by
# invocation count -- a genuine records-only divergence.
# ---------------------------------------------------------------------------

const RecordMsgDivergesFixture = """
import std/[os, strutils]
const counterFile = "t12_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
let sinkPath = getEnv("CRISOL_SINK")
if sinkPath.len > 0:
  let f = open(sinkPath, fmWrite)
  f.write("{\"crisol\":\"sink\",\"v\":1,\"ep\":\"\",\"pid\":0}\n")
  f.write("{\"name\":\"counter test\",\"status\":\"pass\",\"duration_us\":100,\"msg\":\"invocation " & $n & "\"}\n")
  f.close()
quit(0)
"""

# ---------------------------------------------------------------------------
# T13 fixture: constant exit 0, IDENTICAL name/status/msg/tags every
# invocation -- only duration_us (deliberately excluded from the
# comparison) differs.
# ---------------------------------------------------------------------------

const RecordDurationOnlyFixture = """
import std/[os, strutils]
const counterFile = "t13_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
let sinkPath = getEnv("CRISOL_SINK")
if sinkPath.len > 0:
  let f = open(sinkPath, fmWrite)
  f.write("{\"crisol\":\"sink\",\"v\":1,\"ep\":\"\",\"pid\":0}\n")
  f.write("{\"name\":\"counter test\",\"status\":\"pass\",\"duration_us\":" & $(n * 100) & "}\n")
  f.close()
quit(0)
"""

# ---------------------------------------------------------------------------
# T12 — recordsDiverged true positive
# ---------------------------------------------------------------------------

suite "T12 — recordsDiverge true positive: constant exit, diverging record content":

  test "a record's msg differs between the cached observation and the forced-live re-execution":
    withTempProject:
      let epPath = "tests/unit/test_t12_recdiv.nim"
      writeFile(projectRoot / epPath, RecordMsgDivergesFixture)

      # Run 1: live (n=1). Stores. Exit 0.
      let rr1 = runTests(baseOpts(projectRoot, noVerify()))
      check rr1.exitCode == 0
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      check rr1.results[0].records.len == 1
      check rr1.results[0].records[0].msg.get == "invocation 1"

      # Run 2: served from cache (cdmHit); --verify-cache forces a genuine
      # re-execution (n=2) whose record's msg diverges from the stored one.
      let stderrPath = projectRoot / "stderr_capture.txt"
      var rr2: RunReport
      captureStderrToFile(stderrPath, proc () =
        rr2 = runTests(baseOpts(projectRoot, verifySample(pct = 100))))

      check rr2.exitCode == 0
      check rr2.results.len == 1
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.results[0].records[0].msg.get == "invocation 1"  # main run's
                                                                  # reported result is UNCHANGED

      check rr2.verifyDivergences.len == 1
      let dv = rr2.verifyDivergences[0]
      check dv.ep.path == epPath
      check dv.recordsDiverged == true
      check dv.exitDiverged == false   # exit stayed 0 both times -- ONLY records diverged

      let captured = readFile(stderrPath)
      check epPath in captured
      # api.verifyCachePass's stderr line joins `what` (["exit"] and/or
      # ["records"]) with ", " -- only "records" diverged here, so the
      # parenthesized clause must read exactly "records diverged", never
      # "exit" alongside it.
      check "(records diverged from the cached result)" in captured

# ---------------------------------------------------------------------------
# T13 — adjacent case: durationUs-only difference never diverges
# ---------------------------------------------------------------------------

suite "T13 — recordsDiverge adjacent case: durationUs excluded from the comparison":

  test "identical name/status/msg/tags, different durationUs -> no divergence":
    withTempProject:
      let epPath = "tests/unit/test_t13_durationonly.nim"
      writeFile(projectRoot / epPath, RecordDurationOnlyFixture)

      let rr1 = runTests(baseOpts(projectRoot, noVerify()))
      check rr1.exitCode == 0
      check rr1.results[0].cacheDecision == cdmStored
      check rr1.results[0].records[0].durationUs == 100

      let rr2 = runTests(baseOpts(projectRoot, verifySample(pct = 100)))
      check rr2.exitCode == 0
      check rr2.results[0].cacheDecision == cdmHit

      # The verify sub-run's fresh record has durationUs == 200 (n=2) --
      # different from the stored 100 -- yet recordsDiverge deliberately
      # excludes durationUs, so no divergence is reported.
      check rr2.verifyDivergences.len == 0
      check rr2.verifyCouldNotReexec.len == 0

echo "test_verifycache_records_diverge: done"
