## test_process_cause.nim — rfc-0007 A1a: Cause (authorship) + classifyCause,
## the second pure function (§2). Table-tested with the documented
## misattribution windows pinned as explicit cases.
import std/[options, unittest]
import crisol/process/types as ptypes

suite "process/types — Cause construction":

  test "cbProcess carries no payload (ended on its own)":
    let c = Cause(by: cbProcess)
    check c.by == cbProcess

  test "cbRunner carries reason and escalated":
    let c = Cause(by: cbRunner, reason: krTimeout, escalated: true)
    check c.by == cbRunner
    check c.reason == krTimeout
    check c.escalated == true

  test "cbLimit carries the LimitKind it was asserted for":
    let c = Cause(by: cbLimit, limit: lkCpu)
    check c.by == cbLimit
    check c.limit == lkCpu

  test "cbExternal carries no payload (a kill we did not send and cannot attribute)":
    let c = Cause(by: cbExternal)
    check c.by == cbExternal

  test "cbLimit(lkMemory) is a real, constructible payload (rfc-0007 B3)":
    let c = Cause(by: cbLimit, limit: lkMemory)
    check c.by == cbLimit
    check c.limit == lkMemory

  test "DeterministicLimits names exactly {lkCpu, lkFileSize, lkMemory}":
    check DeterministicLimits == {lkCpu, lkFileSize, lkMemory}

suite "classifyCause — authorship table (§2)":
  ## classifyCause(exit, stop, limits, achieved): Cause
  ##   - stop.isSome ALWAYS wins: cbRunner iff a stop act was recorded before
  ##     the backend observed the exit (§2 "Authorship has ONE owner").
  ##   - otherwise the exit signal is classified by a documented heuristic.

  let noLimits = Limits()
  let noneAchieved: LimitsAchieved = default(LimitsAchieved)  # all lsNotRequested

  proc withCpuAchieved(): tuple[limits: Limits; achieved: LimitsAchieved] =
    var lim = Limits()
    lim.req[lkCpu] = some(10'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkCpu] = lsApplied
    (lim, ach)

  proc withFsizeAchieved(): tuple[limits: Limits; achieved: LimitsAchieved] =
    var lim = Limits()
    lim.req[lkFileSize] = some(10'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkFileSize] = lsApplied
    (lim, ach)

  test "a recorded stop act is cbRunner regardless of the signal observed — the ONE owner rule":
    let e = Exit(kind: ekSignaled, sig: 15, coreDumped: false)  # SIGTERM
    let stop = some((reason: krTimeout, escalated: false))
    let c = classifyCause(e, stop, noLimits, noneAchieved)
    check c.by == cbRunner
    check c.reason == krTimeout
    check c.escalated == false

  test "escalated stop act (SIGKILL after SIGTERM ignored) is cbRunner escalated:true":
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)  # SIGKILL
    let stop = some((reason: krTimeout, escalated: true))
    let c = classifyCause(e, stop, noLimits, noneAchieved)
    check c.by == cbRunner
    check c.escalated == true

  test "MISATTRIBUTION (documented, accepted): cooperative death on SIGTERM inside grace still reads cbRunner — the exit signal is not consulted when stop.isSome":
    ## §2: "an external SIGTERM inside our grace window reads as cbRunner" —
    ## the runner's own recorded stop act wins even though the SIGTERM in
    ## this specific instant could theoretically have come from elsewhere.
    let e = Exit(kind: ekExited, code: 0)  # died cooperatively, exit 0
    let stop = some((reason: krTimeout, escalated: false))
    let c = classifyCause(e, stop, noLimits, noneAchieved)
    check c.by == cbRunner

  test "interrupt is a distinct KillReason from timeout":
    let e = Exit(kind: ekSignaled, sig: 15, coreDumped: false)
    let stop = some((reason: krInterrupt, escalated: false))
    let c = classifyCause(e, stop, noLimits, noneAchieved)
    check c.by == cbRunner
    check c.reason == krInterrupt

  test "default-disposition crash signals (no stop recorded) classify as cbProcess":
    for sig in [11, 6, 8, 4, 7, 5]:  # SIGSEGV SIGABRT SIGFPE SIGILL SIGBUS SIGTRAP
      let e = Exit(kind: ekSignaled, sig: sig, coreDumped: false)
      let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                             noLimits, noneAchieved)
      check c.by == cbProcess

  test "MISATTRIBUTION (documented, accepted): an operator's kill -SEGV reads as cbProcess — indistinguishable from a genuine crash":
    let e = Exit(kind: ekSignaled, sig: 11, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbProcess

  test "a SIGKILL we did not send is cbExternal (OOM killer, operator, unknown)":
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbExternal

  test "rfc-0007 B3: SIGKILL classifies cbLimit(lkMemory) ONLY when a memory ceiling was requested (lkMemory's own slot), the cgroup leaf applied it, AND memory.events showed oom_kill>0":
    var lim = Limits()
    lim.req[lkMemory] = some(64 * 1024 * 1024'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkMemory] = lsApplied
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           lim, ach, memoryOomKill = true)
    check c.by == cbLimit
    check c.limit == lkMemory

  test "rfc-0007 B3: SIGKILL with achieved lkMemory=lsApplied but NO oom_kill fact is cbExternal, not cbLimit":
    ## The ambiguity SIGXCPU/SIGXFSZ never have: a raw SIGKILL could be an
    ## operator, an external OOM killer, or our own ceiling — requested+
    ## achieved alone is not enough here.
    var lim = Limits()
    lim.req[lkMemory] = some(64 * 1024 * 1024'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkMemory] = lsApplied
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           lim, ach, memoryOomKill = false)
    check c.by == cbExternal

  test "rfc-0007 B3: SIGKILL with oom_kill fact but achieved lkMemory=lsFailed (leaf never materialized) is cbExternal":
    ## The per-spawn honest-degrade case: the probe was green, the ceiling
    ## was requested, but THIS spawn's leaf failed — never attributed to a
    ## limit we could not actually vouch was applied.
    var lim = Limits()
    lim.req[lkMemory] = some(64 * 1024 * 1024'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkMemory] = lsFailed
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           lim, ach, memoryOomKill = true)
    check c.by == cbExternal

  test "rfc-0007 B3: SIGKILL + oom_kill fact + achieved lsApplied but NO memory ceiling ever requested is cbExternal (unreachable in practice, same belt-and-suspenders shape as SIGXCPU/SIGXFSZ)":
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkMemory] = lsApplied
    let e = Exit(kind: ekSignaled, sig: 9, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, ach, memoryOomKill = true)
    check c.by == cbExternal

  test "SIGXCPU classifies cbLimit(lkCpu) ONLY when lkCpu was requested and achieved":
    let (lim, ach) = withCpuAchieved()
    let e = Exit(kind: ekSignaled, sig: 24, coreDumped: false)  # SIGXCPU
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]), lim, ach)
    check c.by == cbLimit
    check c.limit == lkCpu

  test "SIGXCPU without a requested+achieved lkCpu is cbExternal, never cbLimit":
    let e = Exit(kind: ekSignaled, sig: 24, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbExternal

  test "SIGXFSZ classifies cbLimit(lkFileSize) ONLY when lkFileSize was requested and achieved":
    let (lim, ach) = withFsizeAchieved()
    let e = Exit(kind: ekSignaled, sig: 25, coreDumped: false)  # SIGXFSZ
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]), lim, ach)
    check c.by == cbLimit
    check c.limit == lkFileSize

  test "SIGXFSZ without a requested+achieved lkFileSize is cbExternal":
    let e = Exit(kind: ekSignaled, sig: 25, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbExternal

  test "SIGXCPU requested but NOT achieved (lsFailed) is cbExternal, not cbLimit":
    var lim = Limits()
    lim.req[lkCpu] = some(10'i64)
    var ach: LimitsAchieved = default(LimitsAchieved)
    ach[lkCpu] = lsFailed
    let e = Exit(kind: ekSignaled, sig: 24, coreDumped: false)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]), lim, ach)
    check c.by == cbExternal

  test "a clean exit with no stop recorded is cbProcess (ended on its own)":
    let e = Exit(kind: ekExited, code: 0)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbProcess

  test "a non-zero exit with no stop recorded is still cbProcess — exit code is not authorship":
    let e = Exit(kind: ekExited, code: 1)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbProcess

  test "an ekNtStatus crash with no stop recorded is cbProcess (ended on its own)":
    let e = Exit(kind: ekNtStatus, status: 0xC0000005'u32)
    let c = classifyCause(e, none(tuple[reason: KillReason, escalated: bool]),
                           noLimits, noneAchieved)
    check c.by == cbProcess
