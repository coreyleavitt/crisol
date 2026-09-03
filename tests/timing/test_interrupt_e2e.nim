## test_interrupt_e2e.nim — rfc-0007 A1e-ii SIGINT/SIGTERM E2E.
##
## GATING: This file quits 0 immediately when CRISOL_TIMING_TESTS is unset or
## empty — see tests/timing/test_rlimits_timing.nim for the full rationale.
## Use `./dev timing`, or to run this file alone:
##
##   ./dev run env CRISOL_TIMING_TESTS=1 nim r --hints:off --warnings:off \
##     --path:src tests/timing/test_interrupt_e2e.nim
##
## Why this lives in tests/timing/ (serial leg) rather than tests/integration/:
## it compiles the REAL `crisol` CLI binary and runs it as a genuine CHILD
## process (not an in-process runMain call — a real SIGINT/SIGTERM must land
## on a process the OS actually schedules and reap), with a real compile +
## run cycle over two real fixtures. That is slow and, like the other timing
## tests, sensitive to host scheduling noise under parallel load.
##
## Proves §2's interrupt partial-results contract on the wire, end to end:
##   - jobs>=2: pass_fast.nim (fast, writes a marker file) and hang_forever.nim
##     (never exits on its own) are dispatched concurrently.
##   - The marker file is the NON-VACUOUS sync point: by the time it appears,
##     pass_fast has genuinely finished and hang_forever is still live (jobs=2
##     admits both immediately; hang_forever's compile is at least as fast as
##     pass_fast's compile+run, so it is always already dispatched).
##   - The child is then signaled for real (SIGINT case / SIGTERM case).
##   - Assertions (SIGINT case, all five from the RFC bullet):
##       1. exit code == 130 (128 + SIGINT)
##       2. stdout parses as crisol/run/v2 JSON with "interrupted": true
##       3. the pass_fast entry has outcome "passed"
##       4. the hang_forever entry carries cause {by: "runner", reason: "interrupt"}
##          on whichever phase actually ran (§2's last-started-phase rule)
##       5. summary.counts.killed >= 1 AND summary.counts.passed >= 1
##   - PLUS: no ledger row for the killed (hang_forever) entry, and no
##     lastrun.json persisted at all.
##   - SIGTERM case: same shape, pins exit 143 (128 + SIGTERM).
##
## Run with:
##   ./dev timing

import std/[json, os, osproc, streams, strtabs, strutils, times, unittest]
import std/posix
import crisol/depgraph  # flagHash
import crisol/keys      # identityKey
import crisol/ledger    # scanLedger

# ---------------------------------------------------------------------------
# GATE: quit 0 immediately when env var is unset or empty.
# ---------------------------------------------------------------------------

if getEnv("CRISOL_TIMING_TESTS") == "":
  quit(0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  # this file is at tests/timing/ -> up 2 -> repo root.
  currentSourcePath().parentDir.parentDir.parentDir

const
  PassFastRel    = "tests" / "fixtures" / "pass_fast.nim"
  HangForeverRel = "tests" / "fixtures" / "hang_forever.nim"

proc buildCrisolBinary(): string =
  ## Compile the REAL src/crisol.nim CLI binary once, into an isolated temp
  ## path — a real SIGINT/SIGTERM must land on the actual crisol process,
  ## not an in-process runMain call (mirrors
  ## test_measure_compile_gate.buildCrisolBinary's rationale). `nim` is on
  ## PATH inside the ./dev container this test itself already runs in.
  result = getTempDir() / "crisol_interrupt_e2e_bin" / "crisol"
  createDir(result.parentDir)
  let cmd = "nim c --hints:off --warnings:off --mm:orc -o:" &
            result.quoteShell & " " & (repoRoot() / "src" / "crisol.nim").quoteShell
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "failed to build crisol binary for interrupt E2E: " & output
  doAssert fileExists(result), "crisol binary not produced at " & result

let crisolBin = buildCrisolBinary()

proc pollForFile(path: string; timeoutMs: int): bool =
  let step = 50
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc entrypointNamed(doc: JsonNode; suffix: string): JsonNode =
  ## Find the `entrypoints[]` node whose path ends with `suffix` — the wire
  ## may carry an absolute or relative path, so this matches on suffix only.
  result = nil
  for ep in doc["entrypoints"]:
    if ep["path"].getStr.endsWith(suffix):
      return ep

proc causeOf(entry: JsonNode): JsonNode =
  ## §2's last-started-phase rule: whichever of compile/run actually reached
  ## "ran" carries the interrupt attribution. Under jobs>=2 concurrent
  ## dispatch hang_forever's trivial compile is expected to have already
  ## finished by the time pass_fast's marker appears (so `run` is the one
  ## that ran) — the compile fallback keeps this robust to that race either
  ## way rather than assuming it.
  if entry["run"]["kind"].getStr == "ran": entry["run"]["cause"]
  else: entry["compile"]["cause"]

type InterruptCase = tuple[sig: cint; expectedExit: int; label: string]

template runInterruptCase(c: InterruptCase) =
  ## A TEMPLATE, not a proc: std/unittest's `check` only marks the enclosing
  ## `test:` block failed when `testStatusIMPL` is lexically visible at the
  ## call site (`when compiles(testStatusIMPL)`) — a plain proc call breaks
  ## that visibility and `check` failures inside it print but never fail the
  ## suite. A template inlines this body INTO the `test:` block, keeping
  ## `check` load-bearing.
  let tag       = "crisol_interrupt_e2e_" & c.label & "_" & $getpid()
  let stateDir  = getTempDir() / (tag & "_state")
  let markerFile = getTempDir() / (tag & "_marker")

  removeDir(stateDir)
  createDir(stateDir)
  if fileExists(markerFile): removeFile(markerFile)
  defer:
    removeDir(stateDir)
    try: removeFile(markerFile) except: discard

  let lastrunPath = stateDir / "lastrun.json"
  check not fileExists(lastrunPath)  # isolated dir: nothing pre-existing

  let p = startProcess(
    crisolBin,
    workingDir = repoRoot(),
    # --hermetic none: the default (hlIsolated) env-scrubs run children, and
    # CRISOL_PASS_FAST_MARKER (the marker-file sync point) would never reach
    # pass_fast.nim otherwise -- this test's own marker-file mechanism, not
    # anything under test, so bypassing the sandbox for it is the honest
    # choice rather than plumbing an allowlist through crisol.kdl.
    args = @["run", PassFastRel, HangForeverRel, "--json", "-j", "2", "-t", "300",
             "--hermetic", "none"],
    env = {
      "CRISOL_STATE_DIR":        stateDir,
      "CRISOL_PASS_FAST_MARKER": markerFile,
      "PATH":                    getEnv("PATH"),
      "HOME":                    getEnv("HOME"),
    }.newStringTable,
    options = {poUsePath},
  )
  defer: close(p)

  # Sync point: wait for pass_fast to genuinely finish. Generous budget —
  # covers compiling BOTH fixtures plus running pass_fast to completion.
  let appeared = pollForFile(markerFile, 60_000)
  check appeared
  if not appeared:
    # `return` is not valid inside a template inlined into a `test:` block
    # (unittest wraps the body in a plain block, not a proc) -- an `if`
    # covering the rest of the case stands in for early-return instead.
    discard kill(Pid(p.processID), SIGKILL)
    discard p.waitForExit()
  else:
    # Real signal to the real child process.
    check kill(Pid(p.processID), c.sig) == 0

    let exitCode = p.waitForExit()
    let stdoutText = p.outputStream.readAll()

    # 1. exit code.
    check exitCode == c.expectedExit

    # 2. valid run/v2 JSON with interrupted:true.
    let doc = parseJson(stdoutText)
    check doc["schema"].getStr == "crisol/run/v2"
    check doc["interrupted"].getBool == true

    # 3. pass_fast passed.
    let passFastEntry = entrypointNamed(doc, "pass_fast.nim")
    check passFastEntry != nil
    if passFastEntry != nil:
      check passFastEntry["outcome"].getStr == "passed"

    # 4. hang_forever was killed by the runner, attributed to the interrupt.
    let hangEntry = entrypointNamed(doc, "hang_forever.nim")
    check hangEntry != nil
    if hangEntry != nil:
      let cause = causeOf(hangEntry)
      check cause["by"].getStr == "runner"
      check cause["reason"].getStr == "interrupt"

    # 5. summary counts.
    check doc["summary"]["counts"]["killed"].getInt >= 1
    check doc["summary"]["counts"]["passed"].getInt >= 1

    # PLUS: no ledger row for the killed entry.
    let hangIdentity = identityKey(HangForeverRel, flagHash(@[]))
    let hangRows = scanLedger(stateDir, hangIdentity)
    check hangRows.len == 0

    # PLUS: no lastrun.json persisted.
    check not fileExists(lastrunPath)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 A1e-ii — interrupt partial results, end to end":

  test "SIGINT: exit 130, honest partial run/v2, no ledger row, no persist":
    runInterruptCase((sig: SIGINT, expectedExit: 130, label: "sigint"))

  test "SIGTERM: exit 143, honest partial run/v2, no ledger row, no persist":
    runInterruptCase((sig: SIGTERM, expectedExit: 143, label: "sigterm"))
