## test_summary_counts.nim — rfc-0007 A1c: Summary.counts, the derived array.
##
## `summarize()` gains `counts: array[Outcome, int]` ADDITIVELY alongside the
## hand-maintained scalar counters (passed/failed/compileFailed/timedOut/
## signaled/spawnErrors) — both are folded from the same result seq, on
## every call, until A1e-i deletes the scalars. `counts` is folded via
## deriveOutcome, so a killed/crashed result (oTimeout/oSignal legacy ->
## oKilled/oCrashed derived) counts under the NEW vocabulary, same quarantine
## exclusion as the scalar counters.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_summary_counts.nim

import std/[options, unittest]
import crisol/types
import crisol/runner  # for summarize
import crisol/process/types as ptypes

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

proc ranPhase(cause: ptypes.Cause; exit: ptypes.Exit): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: cause, evidence: default(ptypes.Evidence),
    rusage: none(ptypes.Rusage), durationUs: 0))

const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)
const cbProcess = ptypes.Cause(by: ptypes.cbProcess)

proc passedResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), outcome: oPassed, exitCode: 0)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 0))

proc failedResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), outcome: oFailed, exitCode: 1)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 1))

proc killedResult(path: string; quarantined = false): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), outcome: oTimeout, signal: 9,
                            quarantined: quarantined)
  result.compile = skippedPhase
  result.run = ranPhase(
    ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 9, coreDumped: false))

proc crashedResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), outcome: oSignal, signal: 11)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekSignaled, sig: 11, coreDumped: false))

suite "summarize — counts array (rfc-0007 A1c)":
  test "counts folds deriveOutcome, dual-counted alongside the scalar buckets":
    let results = @[
      passedResult("a.nim"),
      passedResult("b.nim"),
      failedResult("c.nim"),
      killedResult("d.nim"),
      crashedResult("e.nim"),
    ]
    let s = summarize(results)
    check s.counts[oPassed] == 2
    check s.counts[oFailed] == 1
    check s.counts[oKilled] == 1
    check s.counts[oCrashed] == 1
    # the legacy scalars stay dual-counted, unaffected
    check s.passed == 2
    check s.failed == 1
    check s.timedOut == 1
    check s.signaled == 1

  test "deriveOutcome never returns the legacy values — counts[oTimeout]/[oSignal] stay 0":
    let results = @[killedResult("d.nim"), crashedResult("e.nim")]
    let s = summarize(results)
    check s.counts[oTimeout] == 0
    check s.counts[oSignal] == 0

  test "a quarantined failure is excluded from counts, same as the scalar buckets":
    let results = @[killedResult("d.nim", quarantined = true)]
    let s = summarize(results)
    check s.quarantined == 1
    check s.counts[oKilled] == 0

  test "empty results → all-zero counts array":
    let s = summarize(@[])
    for o in Outcome:
      check s.counts[o] == 0
