## process/types.nim — rfc-0007 §2: the platform-neutral result model.
##
## Types + pure derivation only.  NO backend, NO consumer: A1a births this
## module in isolation (`process.nim`'s backend-selection ladder and the
## Supervisor contract itself are A2a-i).  Everything here is either a value
## type or a pure function over value types — nothing here spawns, waits, or
## touches the filesystem.
##
## Window note: `Outcome` and `HermeticLevel` are defined HERE (rfc-0007 A1c
## dependency inversion) and re-exported by crisol/types.nim, not the other
## way around — crisol/types.EntrypointResult carries `compile`/`run: Phase`
## fields (this module's shape) directly, so process/types cannot import
## crisol/types without cycling back through it. `deriveOutcome`/
## `hasFailRecords` therefore live in crisol/types.nim (the module that owns
## the real production EntrypointResult), not here — see that module for
## both. `deriveOutcome` only ever produces six of Outcome's eight values —
## the two legacy values (`oTimeout`/`oSignal`) are never returned by it.
import std/[options, strutils, tables]

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

proc causeLabel*(c: Cause): string =
  ## Render a Cause as a short human-readable label — "runner timeout",
  ## "runner interrupt (escalated)", "limit cpu", "external". Same rule as
  ## `symbol`: a PROC over the case, serialized at render time (§2, A1c) —
  ## consumed by render.nim and api.failureLine so the two never diverge.
  case c.by
  of cbProcess:
    "process"
  of cbRunner:
    let base = case c.reason
               of krTimeout:   "runner timeout"
               of krInterrupt: "runner interrupt"
    if c.escalated: base & " (escalated)" else: base
  of cbLimit:
    "limit " & $c.limit
  of cbExternal:
    "external"

# ---------------------------------------------------------------------------
# Rusage — a FOURTH axis, not part of Exit (§2).
# ---------------------------------------------------------------------------

type
  Rusage* = object
    maxRssBytes*, userCpuUs*, sysCpuUs*: int64

# ---------------------------------------------------------------------------
# HermeticLevel / Outcome — moved from crisol/types.nim (rfc-0007 A1c: the
# dependency inversion). crisol/types.nim re-exports both so every existing
# `import crisol/types` consumer keeps compiling unchanged.
# ---------------------------------------------------------------------------

type
  HermeticLevel* = enum
    ## Hermeticity levels, monotone — each is a strict superset of the one below.
    ## hlNone  < hlIsolated (the default) < hlNetwork.
    hlNone       ## today's behavior: full env inherited, parent cwd, no limits
    hlIsolated   ## env allowlist, isolated tmpdir, config-declared rlimits; no net isolation
    hlNetwork    ## superset of hlIsolated + unshare(CLONE_NEWNET) + loopback

  Outcome* = enum
    oPassed         ## exit 0, no protocol failure records
    oFailed         ## exit non-zero, or ≥ 1 fail record from protocol
    oCompileFailed  ## nim c exited non-zero or timed out during compile
    oTimeout        ## LEGACY (rfc-0007 window): run phase exceeded timeout.
                    ## Superseded by oKilled; removed at A1e-i.
    oSignal         ## LEGACY (rfc-0007 window): run phase killed by a signal.
                    ## Superseded by oCrashed; removed at A1e-i.
    oSpawnError     ## fork/exec failed at the OS level
    oKilled         ## rfc-0007: a runner-authored kill (timeout or interrupt) —
                    ## cause.by == cbRunner.
    oCrashed        ## rfc-0007: the process ended on a signal/ntstatus it did not
                    ## request and the runner did not send.

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

  OutcomePolicy* = object    ## policy is a VALUE, not a positional bool (§2).
    strictHygiene*: bool

const DefaultPolicy* = OutcomePolicy()
