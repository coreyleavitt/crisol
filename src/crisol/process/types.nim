## process/types.nim — rfc-0007 §2: the platform-neutral result model.
##
## Types + pure derivation only.  NO backend, NO consumer: A1a births this
## module in isolation (`process.nim`'s backend-selection ladder and the
## Supervisor contract itself are A2a-i).  Everything here is either a value
## type or a pure function over value types — nothing here spawns, waits, or
## touches the filesystem.
##
## Window note: this module's `Outcome` is `crisol/types.Outcome`, extended
## (not redefined) by rfc-0007 with `oKilled`/`oCrashed` alongside the legacy
## `oTimeout`/`oSignal` pair for the A1a-A1e dual-write window (see
## crisol/types.nim). `deriveOutcome` below only ever produces the six values
## named in §2 — the two legacy values are never returned by it.
import std/[options, strutils, tables]
import crisol/types as ctypes

export ctypes.Outcome, ctypes.HermeticLevel

# ---------------------------------------------------------------------------
# Exit — LOSSLESS observation of how the child ended, and nothing else.
# ---------------------------------------------------------------------------

type
  ExitKind* = enum ekExited, ekSignaled, ekNtStatus
  Exit* = object                      ## LOSSLESS observation of how the child
    case kind*: ExitKind              ## ended — and nothing else (§2).
    of ekExited:
      code*: int                      ## WEXITSTATUS / Windows exit code < 0xC0000000
    of ekSignaled:
      sig*: int
      coreDumped*: bool
    of ekNtStatus:
      status*: uint32                 ## Windows crash (STATUS_ACCESS_VIOLATION …)

proc isSuccess*(e: Exit): bool =
  ## true iff the child exited normally with code 0.
  e.kind == ekExited and e.code == 0

proc `==`*(a, b: Exit): bool =
  ## Nim's auto-derived `==` cannot walk a `case` object's parallel fields
  ## (a known limitation) — provided explicitly so ProcessResult equality
  ## (used by the resultjson roundtrip tests) works structurally.
  if a.kind != b.kind: return false
  case a.kind
  of ekExited:   a.code == b.code
  of ekSignaled: a.sig == b.sig and a.coreDumped == b.coreDumped
  of ekNtStatus: a.status == b.status

const signalNames = {
  1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP",
  6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1",
  11: "SIGSEGV", 12: "SIGUSR2", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
  16: "SIGSTKFLT", 17: "SIGCHLD", 18: "SIGCONT", 19: "SIGSTOP", 20: "SIGTSTP",
  21: "SIGTTIN", 22: "SIGTTOU", 23: "SIGURG", 24: "SIGXCPU", 25: "SIGXFSZ",
  26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH", 29: "SIGIO", 30: "SIGPWR",
  31: "SIGSYS",
}.toTable

const ntStatusNames = {
  0xC0000005'u32: "STATUS_ACCESS_VIOLATION",
  0xC00000FD'u32: "STATUS_STACK_OVERFLOW",
}.toTable


# ---------------------------------------------------------------------------
# Limits (§1) — ONE vocabulary for requested/achieved resource limits.
# ---------------------------------------------------------------------------

type
  LimitKind* = enum          ## ONE vocabulary for limits: requested, achieved,
    lkAddressSpace, lkCpu,   ## and Cause.cbLimit all index by it.
    lkFileSize, lkOpenFiles,
    lkCore

  Limits* = object           ## the SINGLE home for resource limits.
    req*: array[LimitKind, Option[int64]]

  LimitStatus* = enum lsNotRequested, lsUnsupported, lsFailed, lsApplied
    ## ord 0 is the WEAKEST claim (the house rule for every evidence enum,
    ## §2): a default-initialized value must never encode a vouch.
  LimitsAchieved* = array[LimitKind, LimitStatus]

const DeterministicLimits* = {lkCpu, lkFileSize}
  ## The deterministic subset a Cause may cite (§2). B3 adds lkMemory WITH
  ## its producer (cgroup memory.events); citing any other kind in cbLimit
  ## is a bug by construction.

# ---------------------------------------------------------------------------
# Cause — AUTHORSHIP, from the runner's recorded acts only (§2).
# ---------------------------------------------------------------------------

type
  CauseBy* = enum cbProcess, cbRunner, cbLimit, cbExternal
  KillReason* = enum krTimeout, krInterrupt
    ## ONLY reasons with named producers exist (§2) — the wire is additive.
  Cause* = object                     ## AUTHORSHIP — from the runner's
    case by*: CauseBy                 ## recorded acts.
    of cbProcess:
      ## ended on its own
      discard
    of cbRunner:
      reason*: KillReason
      escalated*: bool
    of cbLimit:
      ## asserted ONLY when that limit was requested and achieved for this child
      limit*: LimitKind
    of cbExternal:
      ## a kill we did not send and cannot attribute
      discard

proc `==`*(a, b: Cause): bool =
  ## See the note on `==`(Exit, Exit) above — same limitation, same fix.
  if a.by != b.by: return false
  case a.by
  of cbProcess, cbExternal: true
  of cbRunner: a.reason == b.reason and a.escalated == b.escalated
  of cbLimit:  a.limit == b.limit

proc classifyCause*(exit: Exit;
                     stop: Option[tuple[reason: KillReason, escalated: bool]];
                     limits: Limits; achieved: LimitsAchieved): Cause =
  ## The SECOND pure function (§2). `cbRunner` iff a stop act was recorded
  ## before the backend observed the exit — the ONE owner of authorship
  ## (§2 "Authorship has ONE owner: the Supervisor's act ledger"); the exit
  ## signal is NOT consulted once a stop act is present, which is exactly
  ## the documented, accepted misattribution window (an external SIGTERM
  ## racing our own grace-window SIGTERM reads as cbRunner).
  if stop.isSome:
    return Cause(by: cbRunner, reason: stop.get.reason, escalated: stop.get.escalated)
  if exit.kind == ekSignaled:
    case exit.sig
    of 9:  # SIGKILL we did not send — OOM killer, operator, unknown.
      return Cause(by: cbExternal)
    of 24:  # SIGXCPU — requested-AND-achieved join, once, here.
      if limits.req[lkCpu].isSome and achieved[lkCpu] == lsApplied:
        return Cause(by: cbLimit, limit: lkCpu)
      return Cause(by: cbExternal)
    of 25:  # SIGXFSZ
      if limits.req[lkFileSize].isSome and achieved[lkFileSize] == lsApplied:
        return Cause(by: cbLimit, limit: lkFileSize)
      return Cause(by: cbExternal)
    else:
      # Default-disposition crash signals (SIGSEGV, SIGABRT, SIGFPE, …) — a
      # documented heuristic, not knowledge: an operator's `kill -SEGV` is
      # indistinguishable from a genuine crash and reads as cbProcess too.
      return Cause(by: cbProcess)
  # ekExited or ekNtStatus with no stop recorded: the process ended on its own.
  Cause(by: cbProcess)

proc symbol*(e: Exit): string =
  ## Render an Exit as a short human-readable label — "SIGSEGV",
  ## "STATUS_ACCESS_VIOLATION", "exit 0". A PROC over a table, serialized at
  ## render time; derived data is never stored (§2 — same rule as outcome).
  case e.kind
  of ekExited:
    "exit " & $e.code
  of ekSignaled:
    signalNames.getOrDefault(e.sig, "SIG" & $e.sig)
  of ekNtStatus:
    ntStatusNames.getOrDefault(e.status, "STATUS_0x" & e.status.toHex(8))

# ---------------------------------------------------------------------------
# Rusage — a FOURTH axis, not part of Exit (§2).
# ---------------------------------------------------------------------------

type
  Rusage* = object
    maxRssBytes*, userCpuUs*, sysCpuUs*: int64

# ---------------------------------------------------------------------------
# Evidence — what the runner can VOUCH for (§2). Backend-observed fields are
# copied verbatim from ReapReport (A2a-i); only `hermetic` is runner-authored.
# ---------------------------------------------------------------------------

type
  KillDomainStrength* = enum kdsProcessGroup, kdsProcessGroupSubreaper,
                              kdsCgroup, kdsJobObject
    ## a LABEL for the mechanism, never an ordered ladder — nothing may
    ## compare these by ord (§2).

  TreeObservation* = enum
    toUnobservable  ## ord 0 = the WEAKEST claim (house rule: a default-
                    ## initialized evidence value must never encode a vouch).
    toComplete      ## the domain is fully observable at this tier and every
                    ## pid in it was seen to end. Survivors are NOT a third
                    ## enum value — `escapees.len > 0` is the separate,
                    ## orthogonal fact (§2).

  ProcSnapshot* = object     ## WIRE TYPE (Evidence.killSnapshot/escapees).
    pid*, ppid*: int
    command*: string         ## comm / image name
    rssBytes*: int64

  Evidence* = object
    killDomain*: KillDomainStrength   ## per-spawn achieved (from ReapReport)
    tree*: TreeObservation
    escapees*: seq[ProcSnapshot]
    limits*: LimitsAchieved           ## per-limit (§1), replacing the aggregate bit
    hermetic*: HermeticLevel          ## the level this ran under (crisol/types)
    killSnapshot*: seq[ProcSnapshot]  ## tree at the first stop act (§1)
    cooperativeUnavailable*: bool     ## from ReapReport — without this bit
                                      ## `escalated` degrades into noise (§3)

# ---------------------------------------------------------------------------
# ProcessResult — ONE shape for the compile and run phases (§2).
# ---------------------------------------------------------------------------

type
  ProcessResult* = object
    exit*: Exit
    cause*: Cause
    evidence*: Evidence
    rusage*: Option[Rusage]           ## never serialized zero-filled as observation
    durationUs*: int64

  PhaseKind* = enum pkSkipped, pkSpawnFailed, pkRan, pkCached
  Phase* = object     ## illegal states unrepresentable — no Option × Option ×
    case kind*: PhaseKind             ## sentinel-string; phase identity by
    of pkSkipped:
      ## phase identity by construction (§2)
      discard
    of pkSpawnFailed:
      spawnError*: string
    of pkRan, pkCached:
      res*: ProcessResult             ## pkCached = the STORED observation
                                      ## replayed on a cache hit. Compile-phase
                                      ## pkCached is representable but
                                      ## UNREACHABLE by construction — the
                                      ## derivation below deliberately treats
                                      ## it as pkRan (§2's one bend, visible).

  EntrypointResult* = object
    ## rfc-0007 §2 shape — NOT crisol/types.EntrypointResult (the legacy
    ## producer field set). A1b dual-writes into the legacy type; this type
    ## exists in A1a purely so deriveOutcome/hasFailRecords are the real,
    ## spec-shaped functions from day one, with no consumer wired yet.
    ep*: Entrypoint
    compile*, run*: Phase
    records*: seq[TestRecord]
    output*: string
    outputTruncated*: bool
    attempts*: int
    quarantined*: bool

  OutcomePolicy* = object    ## policy is a VALUE, not a positional bool (§2).
    strictHygiene*: bool

const DefaultPolicy* = OutcomePolicy()

proc hasFailRecords*(r: EntrypointResult): bool =
  ## true iff any PARSED protocol record is a failure. A truncated/corrupt
  ## stream never fabricates a failure — the reader stays conservative (§2).
  for rec in r.records:
    if rec.status == rsFail: return true
  false

proc deriveOutcome*(r: EntrypointResult; policy: OutcomePolicy = DefaultPolicy): Outcome =
  ## PURE over (result, policy) — §2's total case expression, verbatim.
  ## Named `deriveOutcome`, not `outcome`: while the legacy `outcome` FIELD
  ## exists on crisol/types.EntrypointResult during the A1a-A1e window,
  ## `r.outcome` on THAT type binds to the field — a "migrated" consumer
  ## written against a same-named proc would silently read stale data.
  case r.compile.kind
  of pkSpawnFailed:
    return oSpawnError
  of pkRan, pkCached:
    let c = r.compile.res
    if c.cause.by == cbRunner and c.cause.reason == krInterrupt:
      return oKilled              ## Ctrl-C mid-compile is not a compile failure
    if c.cause.by != cbProcess or not c.exit.isSuccess:
      return oCompileFailed       ## incl. compile timeout — the cause is
                                   ## consulted, so a cooperative exit-0 inside
                                   ## a compile-kill grace window cannot
                                   ## masquerade as a good compile
  of pkSkipped:
    discard                       ## fresh — nothing to prove
  case r.run.kind
  of pkSpawnFailed:
    oSpawnError
  of pkSkipped:
    oSpawnError                   ## unreachable in any EMITTED result: a good
                                   ## compile is always followed by a run phase
                                   ## (§2) — derives loudly rather than lying
  of pkRan, pkCached:
    let p = r.run.res
    if p.cause.by == cbRunner:
      oKilled
    elif p.exit.kind != ekExited:
      oCrashed                    ## signaled/ntstatus; cause may be limit
                                   ## or external
    elif p.exit.code == 0 and not r.hasFailRecords:
      if policy.strictHygiene and p.evidence.escapees.len > 0: oFailed
      else: oPassed
    else:
      oFailed
