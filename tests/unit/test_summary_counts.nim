## test_summary_counts.nim — rfc-0007 §2: Summary.counts, the derived array.
##
## `summarize()` folds `counts: array[Outcome, int]` via outcome(r) over the
## result seq. A killed/crashed result has no scalar counterpart any more
## (rfc-0007 A1e-i deleted the legacy timedOut/signaled counters outright) —
## `counts` is the ONLY accounting for those two buckets, same quarantine
## exclusion as the remaining scalar counters (passed/failed/compileFailed/
## spawnErrors).
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
  result = EntrypointResult(ep: makeEp(path))
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 0))

proc failedResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path))
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 1))

proc killedResult(path: string; quarantined = false): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path),
                            quarantined: quarantined)
  result.compile = skippedPhase
  result.run = ranPhase(
    ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 9, coreDumped: false))

proc crashedResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path))
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekSignaled, sig: 11, coreDumped: false))

suite "summarize — counts array (rfc-0007 §2)":
  test "counts folds outcome(r); killed/crashed have no scalar counterpart":
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
    # the remaining scalars stay independently accurate
    check s.passed == 2
    check s.failed == 1

  test "a quarantined failure is excluded from counts, same as the scalar buckets":
    let results = @[killedResult("d.nim", quarantined = true)]
    let s = summarize(results)
    check s.quarantined == 1
    check s.counts[oKilled] == 0

  test "empty results → all-zero counts array":
    let s = summarize(@[])
    for o in Outcome:
      check s.counts[o] == 0
