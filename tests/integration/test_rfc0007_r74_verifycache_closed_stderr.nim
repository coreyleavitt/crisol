## test_rfc0007_r74_verifycache_closed_stderr.nim -- code-review r74:
## `verifyCachePass`'s four warning sites (api.nim, the `--verify-cache`
## determinism backstop) were bare `stderr.write` calls, reached with the
## advisory lock held (the same "closed/broken stderr raises IOError,
## escapes `runTestsWith`, and (pre-r62-fix-pattern) can leak the lock"
## hazard r62 already fixed for two OTHER sites in `runTestsWith` itself).
## r74 routes all four through the (r74-hoisted) `warnStderr` helper.
##
## Same closed-stderr injection idiom as
## tests/integration/test_rfc0007_r62_minsaferlimitas_lock_leak.nim:
## `close(stderr)` so any write to it raises, portably, via Nim's
## `system.close`/`open` on a `File` rather than a raw fd dup/close pair.
## Kept in its OWN process (own test binary), same reason r62's own file
## gives for not sharing one with r16's: two independent close/reopen
## cycles against `system.stderr` in one process is its own, unrelated
## hazard neither test needs to also prove safe.
##
## Drives the DIVERGENCE warning site specifically (api.verifyCachePass's
## last of the four -- "--verify-cache divergence for ... diverged from the
## cached result") via the same recipe
## tests/integration/test_verifycache_records_diverge.nim's T12 uses: a
## fixture whose emitted record content changes by invocation count, so the
## SECOND run (served cdmHit, --verify-cache forces a genuine re-execution)
## observes a real divergence and verifyCachePass's warning fires -- with
## stderr closed at exactly that point.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_r74_verifycache_closed_stderr.nim

import std/[options, os, unittest]
import crisol/api
import crisol/types

import "../support/helpers"

const DivergingFixture = """
import std/[os, strutils]
const counterFile = "r74_counter.txt"
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

proc baseOpts(projectRoot: string; vc: VerifyCache): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,
    showProgress:   false,
    verifyCache:    vc,
  )

suite "rfc-0007 r74 -- verifyCachePass warning sites survive a closed stderr":

  test "a genuine --verify-cache divergence warning does not raise or escape with stderr closed":
    withTempProject:
      let epPath = "tests/unit/test_r74_divfixture.nim"
      writeFile(projectRoot / epPath, DivergingFixture)

      # Run 1: live (n=1), real stderr still open. Stores. Exit 0.
      let rr1 = runTests(baseOpts(projectRoot, noVerify()))
      check rr1.exitCode == 0
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored

      let scratchStderr = projectRoot / "scratch_stderr.txt"

      # Injection: close stderr so verifyCachePass's own divergence warning
      # write raises instead of silently succeeding.
      close(stderr)

      var raised = false
      var excMsg = ""
      var rr2: RunReport
      try:
        # Run 2: served from cache (cdmHit); --verify-cache forces a
        # genuine re-execution (n=2) whose record diverges -> the
        # divergence warning site fires with stderr closed.
        rr2 = runTests(baseOpts(projectRoot, verifySample(pct = 100)))
      except CatchableError as e:
        raised = true
        excMsg = e.msg

      # Reopen stderr -- redirected to a scratch file, not the original
      # stream -- so this test's own diagnostics below are unaffected by
      # the deliberately-broken stream above.
      discard open(stderr, scratchStderr, fmWrite)

      # RED-before-r74 failure mode: the warning's own bare `stderr.write`
      # raises a raw, unhandled IOError straight out of runTests() --
      # violating the facade's documented "never raises for expected
      # conditions" contract.
      check not raised
      if raised:
        echo "runTests() call 2 raised: ", excMsg
      else:
        check rr2.exitCode == 0
        check rr2.results.len == 1
        check rr2.results[0].cacheDecision == cdmHit
        # The divergence itself is still detected and reported in the
        # RETURNED report -- only the stderr WRITE of that same fact was
        # ever at risk; the finding itself must not be lost.
        check rr2.verifyDivergences.len == 1

echo "test_rfc0007_r74_verifycache_closed_stderr: done"
