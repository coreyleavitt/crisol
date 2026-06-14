## test_api_boundary.nim — H1 drift guard: verify the public api boundary.
##
## Positive: all contracted symbols must be importable from crisol/api.
## Negative: internal types (Config, RunPlan) must NOT be reachable.

import std/unittest
import crisol/api

suite "api boundary — positive: contracted symbols reachable":
  test "request/selection types":
    let _: RunOptions = RunOptions()
    let _: GroupSelection = defaultGroups()
    let _: GroupSelectionKind = gskDefault
    let _: RunNarrowing = noNarrowing()
    let _: NarrowingKind = nkNone

  test "result/plan/report tree":
    let _: PlanReport = PlanReport()
    let _: RunReport = RunReport()
    let _: EntrypointResult = EntrypointResult()
    let _: PlannedEntrypoint = PlannedEntrypoint()
    let _: Entrypoint = Entrypoint()
    let _: Outcome = oPassed
    let _: TestRecord = TestRecord()
    let _: RecordStatus = rsPass
    let _: Summary = Summary()
    let _: GatedEntry = ("", "", "")
    let _: ConfigWarning = ConfigWarning()
    let _: CompileDecision = cdNeverBuilt

  test "error types":
    let _: CrisolErrorKind = cekConfig
    # CrisolError is an exception type

  test "schema constants":
    check RunV1Schema.len > 0
    check PlanV1Schema.len > 0

  test "render helpers":
    let _: RenderOpts = RenderOpts()
    # gateSkipMessages, filterRecordsByTag, hasZeroTagMatches, render accessible
    let msgs = gateSkipMessages(@[])
    check msgs.len == 0

  test "ZeroRunnableReason":
    let _: ZeroRunnableReason = zrkNone

  test "planToJsonString facade accepts PlanReport":
    let pr = PlanReport()
    let s = planToJsonString(pr)
    check s.len > 0

  test "renderPlan facade accepts PlanReport":
    let pr = PlanReport()
    let opts = RenderOpts()
    let s = renderPlan(pr, opts)
    check s.len >= 0  # may be empty for empty plan

suite "api boundary — negative: internal types not in public surface":
  test "Config not reachable via crisol/api":
    # Config is an internal type; it must NOT be importable through crisol/api.
    # If someone adds `export types.Config` to api.nim, this test will FAIL
    # because `compiles()` will return true, making `not compiles(...)` false.
    check not compiles((block:
      var c: Config
      discard c))

  test "RunPlan not reachable via crisol/api":
    # RunPlan is internal; facade overloads (H2) accept PlanReport instead.
    # If someone adds `export types.RunPlan` to api.nim, this test will FAIL.
    check not compiles((block:
      var p: RunPlan
      discard p))
