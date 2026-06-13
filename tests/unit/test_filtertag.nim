## test_filtertag.nim — unit tests for C3: --filter-tag reporting-level filter
##
## All tests are PURE: no I/O, no subprocess, no TTY.
## The filter is injected via RenderOpts.filterTag (Option[string]).
## The zero-match predicate hasZeroTagMatches is tested as a pure function.
##
## Covers:
##   1. filterRecordsByTag — basic tag match / non-match
##   2. filterRecordsByTag — empty tag returns all records
##   3. render with filterTag=some("fast") — only tagged records shown
##   4. render with filterTag=some("fast") — non-tagged records NOT shown
##   5. render without filter — all records shown
##   6. Verdict / summary footer unchanged by filter (PASSED stays PASSED even
##      when filtered-out records include failing ones)
##   7. Per-entrypoint counts reflect filtered view
##   8. hasZeroTagMatches — tag present in some records → false
##   9. hasZeroTagMatches — tag absent from all records → true
##  10. hasZeroTagMatches — empty results → true
##  11. hasZeroTagMatches — empty tag → false (safety guard)
##  12. JSON: toJson with filterTag → records array contains only matching records
##  13. JSON: toJson with filterTag → summary reflects full run (not filtered counts)
##  14. Exit code from summary is independent of filter (verdict invariant)

import std/[json, options, strutils, unittest]
import crisol/types
import crisol/render
import crisol/jsonout
import crisol/runner  # for summarize

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeEp(path: string; group = "unit"): Entrypoint =
  Entrypoint(path: path, group: group)

proc taggedRecord(name: string; tags: seq[string];
                  status: RecordStatus = rsPass;
                  us: int64 = 100): TestRecord =
  TestRecord(name: name, status: status, durationUs: us,
             msg: none(string), tags: tags)

proc passedEp(path: string; records: seq[TestRecord]): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oPassed, exitCode: 0,
                   durationMs: 50, records: records)

proc failedEp(path: string; records: seq[TestRecord]): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oFailed, exitCode: 1,
                   durationMs: 50, records: records)

proc noFilterOpts(): RenderOpts =
  RenderOpts(color: false, slowestN: 5, filterTag: none(string))

proc filterOpts(tag: string): RenderOpts =
  RenderOpts(color: false, slowestN: 5, filterTag: some(tag))

# ---------------------------------------------------------------------------
# Suite 1 — filterRecordsByTag (pure predicate)
# ---------------------------------------------------------------------------

suite "filterRecordsByTag":
  test "returns only records whose tags contain the tag":
    let records = @[
      taggedRecord("fast_test",   @["fast", "unit"]),
      taggedRecord("slow_test",   @["slow", "integration"]),
      taggedRecord("medium_test", @["unit"]),
    ]
    let filtered = filterRecordsByTag(records, "fast")
    check filtered.len == 1
    check filtered[0].name == "fast_test"

  test "returns all records when tag matches all":
    let records = @[
      taggedRecord("a", @["shared"]),
      taggedRecord("b", @["shared"]),
    ]
    let filtered = filterRecordsByTag(records, "shared")
    check filtered.len == 2

  test "returns empty seq when tag matches nothing":
    let records = @[
      taggedRecord("x", @["alpha"]),
      taggedRecord("y", @["beta"]),
    ]
    let filtered = filterRecordsByTag(records, "gamma")
    check filtered.len == 0

  test "empty tag returns all records unchanged (safety guard)":
    let records = @[
      taggedRecord("a", @["foo"]),
      taggedRecord("b", @[]),
    ]
    let filtered = filterRecordsByTag(records, "")
    check filtered.len == 2

  test "record with no tags is excluded when filter is set":
    let records = @[
      taggedRecord("with_tag", @["fast"]),
      taggedRecord("no_tags",  @[]),
    ]
    let filtered = filterRecordsByTag(records, "fast")
    check filtered.len == 1
    check filtered[0].name == "with_tag"

# ---------------------------------------------------------------------------
# Suite 2 — render with filterTag: what appears and what does not
# ---------------------------------------------------------------------------

suite "render – filter-tag visibility":
  # Records with distinct durations so the slowest-N section is deterministic.
  # fast_test: durationUs=300 (slowest → appears in slowest-N under any filter)
  # slow_test: durationUs=200
  # unit_test: durationUs=100 (fastest)
  # We use a slowestN=1 so that only fast_test (the slowest record) appears in
  # the Slowest-N section, keeping slow_test and unit_test out of the whole
  # output when they are filtered away.
  let fastRec   = taggedRecord("fast_test",   @["fast", "unit"], us = 300)
  let slowRec   = taggedRecord("slow_test",   @["slow"],         us = 200)
  let unitRec   = taggedRecord("unit_test",   @["unit"],         us = 100)
  let results = @[
    passedEp("tests/unit/ep1.nim", @[fastRec, slowRec, unitRec]),
  ]
  let opts1 = RenderOpts(color: false, slowestN: 1, filterTag: some("fast"))

  test "filter=fast: fast_test appears in output":
    let rendered = render(results, summarize(results), opts1)
    check "fast_test" in rendered

  test "filter=fast, slowestN=1: slow_test does NOT appear in output":
    # slow_test is neither the slowest record (fast_test is) nor tagged 'fast',
    # so with slowestN=1 it should not appear anywhere in the output.
    let rendered = render(results, summarize(results), opts1)
    check "slow_test" notin rendered

  test "filter=fast, slowestN=1: unit_test does NOT appear in output":
    # unit_test is tagged 'unit' not 'fast', and is not in the slowest-1.
    let rendered = render(results, summarize(results), opts1)
    check "unit_test" notin rendered

  test "no filter: all records appear":
    let rendered = render(results, summarize(results), noFilterOpts())
    check "fast_test" in rendered
    check "slow_test" in rendered
    check "unit_test" in rendered

# ---------------------------------------------------------------------------
# Suite 3 — verdict/exit code invariant under filter
# ---------------------------------------------------------------------------

suite "render – verdict invariant":
  test "PASSED verdict unchanged even when failing records are filtered away":
    # A failing record tagged 'slow' exists.  Filter for 'fast' hides it.
    # The RUN itself still passes (no oFailed outcome in the results).
    # Verdict must remain PASSED.
    let fastRec  = taggedRecord("fast_ok",    @["fast"])
    let slowFail = taggedRecord("slow_fail",  @["slow"], status = rsFail)
    # Make an entrypoint that PASSED overall (outcome=oPassed) but has a fail record
    # tagged "slow".  After filtering for "fast" only fast_ok is shown, but the
    # PASSED verdict comes from the summary (which reflects full run).
    let ep = EntrypointResult(
      ep: makeEp("tests/unit/ep.nim"), outcome: oPassed, exitCode: 0,
      durationMs: 10, records: @[fastRec, slowFail])
    let results  = @[ep]
    let s        = summarize(results)  # summarize uses outcome=oPassed → passed
    let rendered = render(results, s, filterOpts("fast"))
    check "PASSED" in rendered
    check "FAILED" notin rendered

  test "exit code from summary is independent of filter tag":
    # Even when all records are filtered out the exit code follows the summary.
    let rec1 = taggedRecord("test_a", @["slow"])
    let ep   = passedEp("tests/unit/ep.nim", @[rec1])
    let results = @[ep]
    let s    = summarize(results)
    check exitCode(s) == 0   # independent of any filter

  test "FAILED verdict unchanged when filter hides some (but not all) failures":
    # An entrypoint FAILED overall.  Filtering for 'fast' hides a slow failure
    # but the entrypoint is still oFailed → summary.failed = 1 → FAILED verdict.
    let fastFail = taggedRecord("fast_fail", @["fast"], status = rsFail)
    let slowFail = taggedRecord("slow_fail", @["slow"], status = rsFail)
    let ep = failedEp("tests/unit/ep.nim", @[fastFail, slowFail])
    let results = @[ep]
    let s = summarize(results)
    let rendered = render(results, s, filterOpts("slow"))
    # Verdict must be FAILED regardless of filter
    check "FAILED" in rendered

# ---------------------------------------------------------------------------
# Suite 4 — per-entrypoint counts reflect filtered view
# ---------------------------------------------------------------------------

suite "render – filtered counts":
  test "count suffix shows filtered test count (1 of 3 records matches)":
    let r1 = taggedRecord("tagged",   @["fast"])
    let r2 = taggedRecord("untagged", @["slow"])
    let r3 = taggedRecord("other",    @["unit"])
    let ep = passedEp("tests/unit/ep.nim", @[r1, r2, r3])
    let results = @[ep]
    let rendered = render(results, summarize(results), filterOpts("fast"))
    # The counts suffix for ep should show "1 tests" (one matching record)
    check "1 tests" in rendered

  test "no-filter shows all 3 tests in count":
    let r1 = taggedRecord("a", @["fast"])
    let r2 = taggedRecord("b", @["slow"])
    let r3 = taggedRecord("c", @["unit"])
    let ep = passedEp("tests/unit/ep.nim", @[r1, r2, r3])
    let results = @[ep]
    let rendered = render(results, summarize(results), noFilterOpts())
    check "3 tests" in rendered

# ---------------------------------------------------------------------------
# Suite 5 — hasZeroTagMatches (pure zero-match predicate)
# ---------------------------------------------------------------------------

suite "hasZeroTagMatches":
  test "tag present in records → false":
    let records = @[taggedRecord("t1", @["fast"]), taggedRecord("t2", @["slow"])]
    let ep = passedEp("tests/unit/ep.nim", records)
    check hasZeroTagMatches(@[ep], "fast") == false

  test "tag absent from all records → true":
    let records = @[taggedRecord("t1", @["fast"]), taggedRecord("t2", @["slow"])]
    let ep = passedEp("tests/unit/ep.nim", records)
    check hasZeroTagMatches(@[ep], "integration") == true

  test "empty results → true":
    check hasZeroTagMatches(@[], "fast") == true

  test "no records in any entrypoint → true":
    let ep = passedEp("tests/unit/ep.nim", @[])
    check hasZeroTagMatches(@[ep], "fast") == true

  test "empty tag → false (safety guard)":
    # An empty tag means 'no filter set'; hasZeroTagMatches should return false
    # so the caller does not emit a spurious warning.
    let ep = passedEp("tests/unit/ep.nim", @[taggedRecord("t", @[])])
    check hasZeroTagMatches(@[ep], "") == false

  test "tag present in one of multiple entrypoints → false":
    let ep1 = passedEp("tests/unit/ep1.nim", @[taggedRecord("t1", @["alpha"])])
    let ep2 = passedEp("tests/unit/ep2.nim", @[taggedRecord("t2", @["fast"])])
    check hasZeroTagMatches(@[ep1, ep2], "fast") == false

# ---------------------------------------------------------------------------
# Suite 6 — JSON output: toJson with filterTag
# ---------------------------------------------------------------------------

suite "toJson – filter-tag":
  test "filterTag filters records in JSON output":
    let fastRec = taggedRecord("fast_test", @["fast"])
    let slowRec = taggedRecord("slow_test", @["slow"])
    let ep      = passedEp("tests/unit/ep.nim", @[fastRec, slowRec])
    let results = @[ep]
    let s       = summarize(results)
    let node    = toJson(results, s, "fast")
    let eps     = node["entrypoints"]
    check eps.len == 1
    let recs = eps[0]["records"]
    check recs.len == 1
    check recs[0]["name"].getStr == "fast_test"

  test "filterTag='' (empty) returns all records":
    let r1 = taggedRecord("a", @["fast"])
    let r2 = taggedRecord("b", @["slow"])
    let ep = passedEp("tests/unit/ep.nim", @[r1, r2])
    let results = @[ep]
    let s = summarize(results)
    let node = toJson(results, s, "")
    let recs = node["entrypoints"][0]["records"]
    check recs.len == 2

  test "JSON summary reflects full run, not filtered record counts":
    # summary.passed is entrypoint-level (1 passed), not record-level.
    # Filter should NOT change the summary block.
    let r1 = taggedRecord("tagged",   @["fast"])
    let r2 = taggedRecord("untagged", @["slow"])
    let ep = passedEp("tests/unit/ep.nim", @[r1, r2])
    let results = @[ep]
    let s = summarize(results)
    let node = toJson(results, s, "fast")
    # Summary should reflect the full run: 1 entrypoint total, 1 passed
    check node["summary"]["total"].getInt  == 1
    check node["summary"]["passed"].getInt == 1
    check node["summary"]["failed"].getInt == 0
