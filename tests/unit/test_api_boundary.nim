## test_api_boundary.nim — H1 drift guard: verify the public api boundary.
##
## Positive: all contracted symbols must be importable from crisol/api.
## Negative: internal types (Config, RunPlan) must NOT be reachable.

import std/[options, unittest]
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

  test "rfc-0007 A1c: result-model facade — the ENUMERATED re-export set":
    # If any of these types/values stop being importable through crisol/api,
    # this test fails to compile — the enumerated set from the RFC's A1c
    # bullet (Outcome, Phase/PhaseKind, ProcessResult, Exit/ExitKind,
    # Cause/CauseBy/KillReason, Evidence/TreeObservation, Rusage,
    # LimitsAchieved, OutcomePolicy).
    let _: Phase = Phase(kind: pkSkipped)
    let _: PhaseKind = pkRan
    let _: ProcessResult = ProcessResult()
    let _: Exit = Exit(kind: ekExited, code: 0)
    let _: ExitKind = ekSignaled
    let _: Cause = Cause(by: cbProcess)
    let _: CauseBy = cbRunner
    let _: KillReason = krTimeout
    let _: Evidence = Evidence()
    let _: TreeObservation = toUnobservable
    let _: Rusage = Rusage()
    let _: LimitsAchieved = default(LimitsAchieved)
    let _: OutcomePolicy = OutcomePolicy(strictHygiene: true)

  test "rfc-0007 A1c: runResult/failureLine digest helpers are reachable":
    let r = EntrypointResult()
    check runResult(r).isNone         # default-constructed: no run phase captured
    check failureLine(r) == "spawn error"  # pkSkipped run -> derives oSpawnError

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
