## test_rfc0007_r6_run_duration.nim — rfc-0007 code-review r6 (High):
## `run.durationUs` must exclude compile time.
##
## `slot.t0` is set once at compile spawn (spawnCompileStable) and, before
## this fix, was never reset at the compile→run transition
## (`transitionToRun`) — `finalizeSlot`'s `elapsed` (computed from `t0`) is
## stamped as the RUN phase's `durationUs` (jsonout.nim documents compile+run
## as independently summable, jsonout.nim:193-197), so a recompiled
## entrypoint's reported run duration silently included its ENTIRE compile
## time. `spawnRunDirect` (the cdSkipFresh path) already reset `t0` fresh, so
## only the "just compiled, transitioning straight to run" path was affected
## — exactly the ordinary, non-cached case this test exercises.
##
## Uses `slow_compile.nim` (tests/fixtures/), a `staticExec("sleep 3")`-gated
## compile with a near-instant run (`quit(0)`) — compile is GUARANTEED to
## dominate wall-clock time by construction, so the assertion
## `run.durationUs < compile.durationUs` is deterministic, not a race: before
## this fix, `run.durationUs` was >= `compile.durationUs` (it included the
## same 3+ compile seconds AND the run itself); after the fix it is a small
## fraction of it.
##
## Drives the real CLI surface (`runMain(... "--json")`) in-process, the same
## `crisol/jsonout` wire the RFC's summing claim (jsonout.nim:193-197)
## describes — mirrors test_interrupt_e2e.nim's own JSON-field-path
## conventions (`entry["compile"]["durationUs"]` / `entry["run"]["durationUs"]`,
## `phaseToJson`'s <PhaseNode> shape) and test_rfc0007_a1f_authorship.nim's
## `captureStdout`-based in-process CLI idiom (no subprocess needed — `nim`
## being on PATH inside ./dev is not a factor here since `slow_compile.nim`'s
## own compile is what's slow, not building a crisol binary).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r6_run_duration.nim

when defined(posix):
  import std/[json, os, strutils, unittest]
  import crisol         # imports runMain
  import ../support/capture

  proc fixtureDir(): string =
    let thisFile = currentSourcePath()
    thisFile.parentDir.parentDir / "fixtures"

  proc entrypointNamed(doc: JsonNode; suffix: string): JsonNode =
    result = nil
    for ep in doc["entrypoints"]:
      if ep["path"].getStr.endsWith(suffix):
        return ep

  suite "rfc-0007 code-review r6 — run.durationUs excludes compile time":

    test "compile-dominant entrypoint: run.durationUs < compile.durationUs":
      let fd = fixtureDir()
      # Isolated CRISOL_STATE_DIR: this repo checkout is shared with other
      # concurrent fix-loop agents' own test runs (each acquiring the
      # project's default .crisol/lock via manageLock) — redirecting state
      # keeps this CLI-level run from contending with (or being blocked by)
      # any of them.
      let stateDir = getTempDir() / ("crisol_r6_state_" & $getCurrentProcessId())
      removeDir(stateDir)
      createDir(stateDir)
      putEnv("CRISOL_STATE_DIR", stateDir)
      defer:
        delEnv("CRISOL_STATE_DIR")
        try: removeDir(stateDir) except: discard

      var code = 0
      let outp = captureStdout(proc() =
        code = runMain(@["run", fd / "slow_compile.nim", "--jobs", "1", "--json"]))

      check code == 0

      let doc = parseJson(outp)
      check doc["schema"].getStr == "crisol/run/v2"

      let entry = entrypointNamed(doc, "slow_compile.nim")
      check entry != nil
      if entry != nil:
        check entry["compile"]["kind"].getStr == "ran"
        check entry["run"]["kind"].getStr == "ran"

        let compileUs = entry["compile"]["durationUs"].getInt
        let runUs     = entry["run"]["durationUs"].getInt

        # compile is staticExec("sleep 3")-gated — at least 3,000,000us on
        # its own, a floor no near-instant `quit(0)` run could ever reach.
        check compileUs >= 2_500_000
        # The regression: before the fix, run.durationUs included the ENTIRE
        # compile time (same t0), so it was >= compileUs. After the fix it
        # is the run's own near-instant wall-clock only.
        check runUs < compileUs
        check runUs < 1_000_000  # comfortably under 1s — the real run has no
                                 # sleep of its own at all.
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/integration/test_rfc0007_r6_run_duration.nim"
    echo "test_rfc0007_r6_run_duration: skipped (POSIX-only backend test)"
