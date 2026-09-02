## test_B4_quarantine_per_test.nim — B4 unit tests: isQuarantined pure helper
##
## Tests the `isQuarantined` pure function that encodes BOTH B3 and B4 rules:
##
##   B3 (path rule):  ep.path ∈ q  → quarantined (regardless of records)
##   B4 (per-test):   outcome is failure AND records.len > 0 AND
##                    every rsFail record's name ∈ q  → quarantined
##
## B4 per-test rule does NOT fire when:
##   - The entrypoint passed (nothing to downgrade)
##   - The entrypoint failed with NO failing records (opaque; only B3 path-match applies)
##   - ANY failing record's name is NOT in q
##
## The same flat quarantine set is matched against BOTH entrypoint paths (B3)
## and test-record names (B4). An entry is whichever it happens to match —
## one flat set, raw string equality.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_B4_quarantine_per_test.nim

import std/[options, sets, unittest]
import crisol/types
import crisol/runner  # for isQuarantined
from crisol/process/types as ptypes import nil

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

proc failRec(name: string): TestRecord =
  TestRecord(name: name, status: rsFail, durationUs: 1)

proc passRec(name: string): TestRecord =
  TestRecord(name: name, status: rsPass, durationUs: 1)

proc skipRec(name: string): TestRecord =
  TestRecord(name: name, status: rsSkip, durationUs: 1)

## rfc-0007 A1e-i: outcome is derived from compile/run Phase — isQuarantined's
## B4 rule branches on outcome(res).isFailure, so these fixtures must carry a
## real Phase pair that derives the outcome each helper's name promises.
proc ranPhase(exit: ptypes.Exit): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: default(ptypes.Evidence), rusage: none(ptypes.Rusage),
    durationUs: 0))

const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)

proc failResult(ep: Entrypoint; recs: seq[TestRecord]): EntrypointResult =
  result = EntrypointResult(ep: ep, records: recs)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 1))

proc passResult(ep: Entrypoint; recs: seq[TestRecord]): EntrypointResult =
  result = EntrypointResult(ep: ep, records: recs)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Exit(kind: ptypes.ekExited, code: 0))

# ---------------------------------------------------------------------------
# Suite 1: B3 path-match rule (both rules share one helper)
# ---------------------------------------------------------------------------

suite "B4 isQuarantined — B3 path-match rule":

  test "ep.path in quarantine set → quarantined (B3 path rule)":
    let ep  = makeEp("tests/integration/test_x.nim")
    let res = failResult(ep, @[])
    let q   = toHashSet(["tests/integration/test_x.nim"])
    check isQuarantined(ep, res, q) == true

  test "ep.path NOT in quarantine set, no failing records → not quarantined":
    let ep  = makeEp("tests/integration/test_x.nim")
    let res = failResult(ep, @[])
    let q   = toHashSet(["tests/integration/test_y.nim"])
    check isQuarantined(ep, res, q) == false

  test "empty quarantine set → not quarantined":
    let ep  = makeEp("tests/integration/test_x.nim")
    let res = failResult(ep, @[failRec("some test")])
    let q   = initHashSet[string]()
    check isQuarantined(ep, res, q) == false

  test "B3 path-match: passed result with path in set → still quarantined":
    ## A cached pass for a now-path-quarantined binary is marked quarantined
    ## (harmless — quarantined pass counts as a normal pass in summarize).
    let ep  = makeEp("tests/integration/test_x.nim")
    let res = passResult(ep, @[])
    let q   = toHashSet(["tests/integration/test_x.nim"])
    check isQuarantined(ep, res, q) == true

# ---------------------------------------------------------------------------
# Suite 2: B4 per-test rule
# ---------------------------------------------------------------------------

suite "B4 isQuarantined — per-test name-match rule":

  test "all failing records quarantined → entrypoint quarantined (B4)":
    let ep  = makeEp("tests/integration/test_z.nim")
    let res = failResult(ep, @[failRec("bad test A"), failRec("bad test B")])
    let q   = toHashSet(["bad test A", "bad test B"])
    check isQuarantined(ep, res, q) == true

  test "some failing record NOT quarantined → NOT quarantined":
    let ep  = makeEp("tests/integration/test_z.nim")
    let res = failResult(ep, @[failRec("bad test A"), failRec("real failure")])
    let q   = toHashSet(["bad test A"])
    check isQuarantined(ep, res, q) == false

  test "single failing record, quarantined → quarantined":
    let ep  = makeEp("tests/unit/test_w.nim")
    let res = failResult(ep, @[failRec("known flaky test")])
    let q   = toHashSet(["known flaky test"])
    check isQuarantined(ep, res, q) == true

  test "failed with NO failing records (opaque binary) → per-test rule N/A, not quarantined":
    ## When an entrypoint failed (exit nonzero) but emitted no failing records
    ## (opaque, or protocol records were all pass/skip), per-test rule does not
    ## apply. Only the B3 path-match can downgrade it.
    let ep  = makeEp("tests/integration/test_opaque.nim")
    # Records contain only pass/skip, but outcome is oFailed (e.g., exit nonzero)
    let res = failResult(ep, @[passRec("something"), skipRec("something else")])
    let q   = toHashSet(["something", "something else"])
    check isQuarantined(ep, res, q) == false

  test "failed with zero records (completely opaque) → not quarantined by per-test rule":
    let ep  = makeEp("tests/integration/test_opaque2.nim")
    let res = failResult(ep, @[])
    let q   = toHashSet(["any name"])
    check isQuarantined(ep, res, q) == false

  test "passed result with all-named records → per-test rule N/A (nothing to downgrade)":
    ## A passed entrypoint is never downgraded by per-test rule.
    let ep  = makeEp("tests/integration/test_pass.nim")
    let res = passResult(ep, @[passRec("test foo"), passRec("test bar")])
    let q   = toHashSet(["test foo", "test bar"])
    check isQuarantined(ep, res, q) == false

  test "mix of fail+pass records: all fail records quarantined → quarantined":
    ## Non-fail records are irrelevant. Only rsFail records must all be in q.
    let ep  = makeEp("tests/integration/test_mixed.nim")
    let res = failResult(ep, @[failRec("bad test"), passRec("good test")])
    let q   = toHashSet(["bad test"])
    check isQuarantined(ep, res, q) == true

  test "mix of fail+skip records: all fail records quarantined → quarantined":
    let ep  = makeEp("tests/integration/test_mixed2.nim")
    let res = failResult(ep, @[failRec("bad test"), skipRec("skipped test")])
    let q   = toHashSet(["bad test"])
    check isQuarantined(ep, res, q) == true

  test "B4 and B3 overlap: test name equals ep path → still quarantined":
    ## One flat set matched against both paths and names. An entry matching
    ## ep.path wins via B3 even if the per-test rule would also match.
    let ep  = makeEp("tests/integration/test_x.nim")
    let res = failResult(ep, @[failRec("tests/integration/test_x.nim")])
    let q   = toHashSet(["tests/integration/test_x.nim"])
    check isQuarantined(ep, res, q) == true

when isMainModule:
  echo "B4 isQuarantined unit tests done."
