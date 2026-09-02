## test_process_deriveoutcome.nim — rfc-0007 §2: deriveOutcome(r, policy),
## the pure total derivation over the real crisol/types.EntrypointResult.
## Exhaustive over every reachable PhaseKind × cause × exit cell of the case
## expression — table-driven, not sampled.
##
## A1c moved deriveOutcome/hasFailRecords onto crisol/types.EntrypointResult
## itself (the dependency-inversion refactor — see crisol/types.nim's header
## comment): they now operate on the SAME type the runner actually produces,
## not a parallel A1a scaffold type.
##
## Named `deriveOutcome` (not `outcome`) deliberately: while the legacy
## `outcome` FIELD exists on crisol/types.EntrypointResult, that name must
## stay free of collision during the A1a-A1e dual-write window.
import std/[options, unittest]
import crisol/types as ctypes
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

let anEp = Entrypoint(path: "tests/fixtures/dummy.nim", group: "default", flags: @[])

proc procResult(exit: Exit; cause: Cause; escapees: seq[ProcSnapshot] = @[]): ProcessResult =
  ProcessResult(
    exit: exit,
    cause: cause,
    evidence: Evidence(
      killDomain: kdsProcessGroup,
      tree: toUnobservable,
      escapees: escapees,
      limits: default(LimitsAchieved),
      hermetic: hlIsolated,
      killSnapshot: @[],
      cooperativeUnavailable: false,
    ),
    rusage: none(Rusage),
    durationUs: 1000,
  )

proc ran(pr: ProcessResult): Phase = Phase(kind: pkRan, res: pr)
proc cached(pr: ProcessResult): Phase = Phase(kind: pkCached, res: pr)

const skippedPhase = Phase(kind: pkSkipped)
const spawnFailedPhase = Phase(kind: pkSpawnFailed, spawnError: "fork failed")

proc entrypointResult(compile, run: Phase; records: seq[TestRecord] = @[]): EntrypointResult =
  EntrypointResult(
    ep: anEp,
    compile: compile,
    run: run,
    records: records,
    output: "",
    outputTruncated: false,
    attempts: 1,
    quarantined: false,
  )

let cProcess    = Cause(by: cbProcess)
let cRunnerTimeout = Cause(by: cbRunner, reason: krTimeout, escalated: false)
let cRunnerInterrupt = Cause(by: cbRunner, reason: krInterrupt, escalated: false)
let cLimit      = Cause(by: cbLimit, limit: lkCpu)
let cExternal   = Cause(by: cbExternal)

let exitOk      = Exit(kind: ekExited, code: 0)
let exitNonZero = Exit(kind: ekExited, code: 1)
let exitSignal  = Exit(kind: ekSignaled, sig: 11, coreDumped: false)
let exitNt      = Exit(kind: ekNtStatus, status: 0xC0000005'u32)

let passRun = ran(procResult(exitOk, cProcess))
let failRec = TestRecord(name: "t1", status: rsFail, durationUs: 1, msg: none(string), tags: @[])
let passRec = TestRecord(name: "t1", status: rsPass, durationUs: 1, msg: none(string), tags: @[])

# ---------------------------------------------------------------------------
# hasFailRecords
# ---------------------------------------------------------------------------

suite "hasFailRecords":
  test "false for empty records":
    check hasFailRecords(entrypointResult(skippedPhase, passRun, @[])) == false

  test "false when all records pass":
    check hasFailRecords(entrypointResult(skippedPhase, passRun, @[passRec])) == false

  test "true when any record fails":
    check hasFailRecords(entrypointResult(skippedPhase, passRun, @[passRec, failRec])) == true

# ---------------------------------------------------------------------------
# deriveOutcome — compile-phase table (run phase held at a fixed passing run
# so only the compile branch under test can affect the verdict).
# ---------------------------------------------------------------------------

suite "deriveOutcome — compile phase (PhaseKind × cause × exit)":

  test "compile pkSpawnFailed -> oSpawnError, regardless of run":
    let r = entrypointResult(spawnFailedPhase, passRun)
    check deriveOutcome(r) == oSpawnError

  test "compile pkSkipped -> falls through to run (fresh, nothing to prove)":
    let r = entrypointResult(skippedPhase, passRun)
    check deriveOutcome(r) == oPassed

  test "compile pkRan, cbRunner(interrupt) -> oKilled (Ctrl-C mid-compile is not a compile failure)":
    let r = entrypointResult(ran(procResult(exitSignal, cRunnerInterrupt)), passRun)
    check deriveOutcome(r) == oKilled

  test "compile pkRan, cbRunner(timeout, not interrupt) -> oCompileFailed":
    let r = entrypointResult(ran(procResult(exitSignal, cRunnerTimeout)), passRun)
    check deriveOutcome(r) == oCompileFailed

  test "compile pkRan, cbProcess, exit success -> falls through to run":
    let r = entrypointResult(ran(procResult(exitOk, cProcess)), passRun)
    check deriveOutcome(r) == oPassed

  test "compile pkRan, cbProcess, exit failure -> oCompileFailed":
    let r = entrypointResult(ran(procResult(exitNonZero, cProcess)), passRun)
    check deriveOutcome(r) == oCompileFailed

  test "compile pkRan, cbLimit -> oCompileFailed (cause.by != cbProcess dominates even on a cooperative exit)":
    let r = entrypointResult(ran(procResult(exitOk, cLimit)), passRun)
    check deriveOutcome(r) == oCompileFailed

  test "compile pkRan, cbExternal -> oCompileFailed":
    let r = entrypointResult(ran(procResult(exitOk, cExternal)), passRun)
    check deriveOutcome(r) == oCompileFailed

  test "compile pkCached (unreachable in practice, representable by construction) treated identically to pkRan":
    let r = entrypointResult(cached(procResult(exitOk, cProcess)), passRun)
    check deriveOutcome(r) == oPassed

  test "compile pkCached with a compile failure still derives oCompileFailed":
    let r = entrypointResult(cached(procResult(exitNonZero, cProcess)), passRun)
    check deriveOutcome(r) == oCompileFailed

# ---------------------------------------------------------------------------
# deriveOutcome — run-phase table (compile phase held at pkSkipped: "fresh,
# nothing to prove" -- isolates the run branch under test).
# ---------------------------------------------------------------------------

suite "deriveOutcome — run phase (PhaseKind × cause × exit)":

  test "run pkSpawnFailed -> oSpawnError":
    let r = entrypointResult(skippedPhase, spawnFailedPhase)
    check deriveOutcome(r) == oSpawnError

  test "run pkSkipped -> oSpawnError (unreachable in any EMITTED result; derives loudly rather than lying)":
    let r = entrypointResult(skippedPhase, skippedPhase)
    check deriveOutcome(r) == oSpawnError

  test "run pkRan, cbRunner -> oKilled regardless of exit kind (signaled)":
    let r = entrypointResult(skippedPhase, ran(procResult(exitSignal, cRunnerTimeout)))
    check deriveOutcome(r) == oKilled

  test "run pkRan, cbRunner -> oKilled regardless of exit kind (cooperative exit 0 inside grace window — the soundness case)":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cRunnerTimeout)))
    check deriveOutcome(r) == oKilled

  test "run pkRan, cbProcess, ekSignaled -> oCrashed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitSignal, cProcess)))
    check deriveOutcome(r) == oCrashed

  test "run pkRan, cbLimit, ekSignaled -> oCrashed (non-runner cause; exit.kind dominates once cause.by != cbRunner)":
    let r = entrypointResult(skippedPhase, ran(procResult(exitSignal, cLimit)))
    check deriveOutcome(r) == oCrashed

  test "run pkRan, cbExternal, ekNtStatus -> oCrashed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitNt, cExternal)))
    check deriveOutcome(r) == oCrashed

  test "run pkRan, cbProcess, ekExited code=0, no fail records -> oPassed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess)))
    check deriveOutcome(r) == oPassed

  test "run pkRan, cbProcess, ekExited code=0, hasFailRecords -> oFailed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess)), @[failRec])
    check deriveOutcome(r) == oFailed

  test "run pkRan, cbProcess, ekExited code!=0 -> oFailed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitNonZero, cProcess)))
    check deriveOutcome(r) == oFailed

  test "run pkCached, cbProcess, ekExited code=0 -> oPassed (identical treatment to pkRan)":
    let r = entrypointResult(skippedPhase, cached(procResult(exitOk, cProcess)))
    check deriveOutcome(r) == oPassed

# ---------------------------------------------------------------------------
# deriveOutcome — OutcomePolicy.strictHygiene × escapees
# ---------------------------------------------------------------------------

suite "deriveOutcome — policy (strictHygiene × escapees)":

  let anEscapee = ProcSnapshot(pid: 999, ppid: 1, command: "leaked", rssBytes: 4096)

  test "default policy: a would-be pass with escapees still passes (cache stores unstrict)":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess, @[anEscapee])))
    check deriveOutcome(r, DefaultPolicy) == oPassed

  test "strictHygiene=true with escapees.len > 0 -> oFailed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess, @[anEscapee])))
    check deriveOutcome(r, OutcomePolicy(strictHygiene: true)) == oFailed

  test "strictHygiene=true with NO escapees -> oPassed":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess, @[])))
    check deriveOutcome(r, OutcomePolicy(strictHygiene: true)) == oPassed

  test "strictHygiene=false with escapees -> oPassed (policy off, unaffected)":
    let r = entrypointResult(skippedPhase, ran(procResult(exitOk, cProcess, @[anEscapee])))
    check deriveOutcome(r, OutcomePolicy(strictHygiene: false)) == oPassed
