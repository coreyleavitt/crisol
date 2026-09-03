## test_interim_limits.nim — rfc-0007 A1f: `interimLimits`, the pure mapping
## from a resolved SandboxSpec + the aggregate SandboxAchieved bit to the §1
## per-limit `Limits`/`LimitsAchieved` shape classifyCause consumes.
##
## This is the "interim evidence population" the RFC's table (§2,
## docs/rfc/0007-execution-substrate.md, "Interim evidence population")
## documents: until A2a-iii's real per-limit getrlimit readback, the ONE
## aggregate `rlimitsApplied` bit is fanned uniformly over every kind the
## spec actually REQUESTED — never over a kind that was never requested
## (ord-0 house rule: a default value must never encode a vouch).
import std/[options, unittest]
import crisol/types
import crisol/process/types as ptypes

suite "interimLimits — the A1f aggregate-approximation mapping":

  test "hlNone (no rlimits requested): every kind is lsNotRequested regardless of the achieved bit":
    let spec = SandboxSpec(level: hlNone)  # rlimitConfig left at its zero value: all none
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: true))
    for kind in ptypes.LimitKind:
      check limits.req[kind].isNone
      check achieved[kind] == ptypes.lsNotRequested

  test "a requested kind with the aggregate bit TRUE reads lsApplied":
    var spec = SandboxSpec(level: hlIsolated)
    spec.rlimitConfig.limitCpu = some(1'i64)
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: true))
    check limits.req[ptypes.lkCpu] == some(1'i64)
    check achieved[ptypes.lkCpu] == ptypes.lsApplied

  test "a requested kind with the aggregate bit FALSE reads lsFailed, never lsApplied or lsNotRequested":
    ## A real request that did not confirm must never be silently promoted
    ## to lsApplied (a false vouch) nor demoted to lsNotRequested (which
    ## would misreport that no request was ever made).
    var spec = SandboxSpec(level: hlIsolated)
    spec.rlimitConfig.limitCpu = some(1'i64)
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: false))
    check limits.req[ptypes.lkCpu] == some(1'i64)
    check achieved[ptypes.lkCpu] == ptypes.lsFailed

  test "an UNrequested kind stays lsNotRequested even when the aggregate bit is true":
    var spec = SandboxSpec(level: hlIsolated)
    spec.rlimitConfig.limitCpu = some(1'i64)  # only cpu requested
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: true))
    check limits.req[ptypes.lkFileSize].isNone
    check achieved[ptypes.lkFileSize] == ptypes.lsNotRequested

  test "multiple requested kinds all fan the same aggregate bit":
    var spec = SandboxSpec(level: hlIsolated)
    spec.rlimitConfig.limitCpu   = some(1'i64)
    spec.rlimitConfig.limitFsize = some(4096'i64)
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: true))
    check limits.req[ptypes.lkCpu]      == some(1'i64)
    check limits.req[ptypes.lkFileSize] == some(4096'i64)
    check achieved[ptypes.lkCpu]      == ptypes.lsApplied
    check achieved[ptypes.lkFileSize] == ptypes.lsApplied

  test "the mapping feeds classifyCause end to end: requested+applied lkCpu ⇒ cbLimit(lkCpu)":
    var spec = SandboxSpec(level: hlIsolated)
    spec.rlimitConfig.limitCpu = some(1'i64)
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: true))
    let e = ptypes.Exit(kind: ptypes.ekSignaled, sig: 24, coreDumped: false)  # SIGXCPU
    let c = ptypes.classifyCause(e, none(tuple[reason: ptypes.KillReason, escalated: bool]),
                                  limits, achieved)
    check c.by == ptypes.cbLimit
    check c.limit == ptypes.lkCpu

  test "the mapping feeds classifyCause end to end: NOT requested ⇒ cbExternal":
    let spec = SandboxSpec(level: hlNone)
    let (limits, achieved) = interimLimits(spec, SandboxAchieved(rlimitsApplied: false))
    let e = ptypes.Exit(kind: ptypes.ekSignaled, sig: 24, coreDumped: false)  # SIGXCPU
    let c = ptypes.classifyCause(e, none(tuple[reason: ptypes.KillReason, escalated: bool]),
                                  limits, achieved)
    check c.by == ptypes.cbExternal
