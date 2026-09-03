## process/resultjson.nim — rfc-0007 §2: the ONE owner of ProcessResult<->JSON,
## both directions.
##
## Enums serialize as strings.  Reader posture: this module IS "crisol's own
## reader" (feeds the cache and the 0005 StoredEntry) — every enum must
## inhabit its real Nim value to run the total derivation, so an unparseable
## enum is a STRUCTURAL parse failure (-> `none`, a future cache miss), never
## a default-valued lie.  External readers (jq, a human, another tool) are
## unknown-tolerant by construction: they read raw JSON strings, not typed
## Nim enums, so a future enum value costs them nothing.  This module never
## raises on bad input — malformed/unknown data always comes back `none`.
##
## Used later by run/v2 (A1d-i), resultcache (A1d-ii), and the 0005
## StoredEntry, so the format exists here once, not three times.
import std/[json, options]
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Enum <-> string (crisol's OWN mapping — never the `$` auto-stringify,
# so a Nim identifier rename can never silently change the wire).
# ---------------------------------------------------------------------------

proc exitKindStr(k: ExitKind): string =
  case k
  of ekExited:   "exited"
  of ekSignaled: "signaled"
  of ekNtStatus: "ntstatus"

proc parseExitKind(s: string): Option[ExitKind] =
  case s
  of "exited":   some(ekExited)
  of "signaled": some(ekSignaled)
  of "ntstatus": some(ekNtStatus)
  else:            none(ExitKind)

proc causeByStr(b: CauseBy): string =
  case b
  of cbProcess:  "process"
  of cbRunner:   "runner"
  of cbLimit:    "limit"
  of cbExternal: "external"

proc parseCauseBy(s: string): Option[CauseBy] =
  case s
  of "process":  some(cbProcess)
  of "runner":   some(cbRunner)
  of "limit":    some(cbLimit)
  of "external": some(cbExternal)
  else:            none(CauseBy)

proc killReasonStr(r: KillReason): string =
  case r
  of krTimeout:   "timeout"
  of krInterrupt: "interrupt"

proc parseKillReason(s: string): Option[KillReason] =
  case s
  of "timeout":   some(krTimeout)
  of "interrupt": some(krInterrupt)
  else:             none(KillReason)

proc limitKindStr(k: LimitKind): string =
  case k
  of lkAddressSpace: "addressSpace"
  of lkCpu:           "cpu"
  of lkFileSize:       "fileSize"
  of lkOpenFiles:      "openFiles"
  of lkCore:           "core"

proc parseLimitKind(s: string): Option[LimitKind] =
  case s
  of "addressSpace": some(lkAddressSpace)
  of "cpu":           some(lkCpu)
  of "fileSize":       some(lkFileSize)
  of "openFiles":      some(lkOpenFiles)
  of "core":            some(lkCore)
  else:                   none(LimitKind)

proc limitStatusStr(s: LimitStatus): string =
  case s
  of lsNotRequested: "notRequested"
  of lsUnsupported:  "unsupported"
  of lsFailed:       "failed"
  of lsApplied:      "applied"

proc parseLimitStatus(s: string): Option[LimitStatus] =
  case s
  of "notRequested": some(lsNotRequested)
  of "unsupported":  some(lsUnsupported)
  of "failed":       some(lsFailed)
  of "applied":      some(lsApplied)
  else:                none(LimitStatus)

proc killDomainStr(d: KillDomainStrength): string =
  case d
  of kdsProcessGroup:          "processGroup"
  of kdsProcessGroupSubreaper: "processGroupSubreaper"
  of kdsCgroup:                "cgroup"
  of kdsJobObject:             "jobObject"

proc parseKillDomain(s: string): Option[KillDomainStrength] =
  case s
  of "processGroup":          some(kdsProcessGroup)
  of "processGroupSubreaper": some(kdsProcessGroupSubreaper)
  of "cgroup":                some(kdsCgroup)
  of "jobObject":             some(kdsJobObject)
  else:                          none(KillDomainStrength)

proc treeObservationStr(t: TreeObservation): string =
  case t
  of toUnobservable: "unobservable"
  of toComplete:      "complete"

proc parseTreeObservation(s: string): Option[TreeObservation] =
  case s
  of "unobservable": some(toUnobservable)
  of "complete":      some(toComplete)
  else:                 none(TreeObservation)

proc hermeticLevelStr(h: HermeticLevel): string =
  case h
  of hlNone:     "none"
  of hlIsolated: "isolated"
  of hlNetwork:  "network"

proc parseHermeticLevel(s: string): Option[HermeticLevel] =
  case s
  of "none":     some(hlNone)
  of "isolated": some(hlIsolated)
  of "network":  some(hlNetwork)
  else:            none(HermeticLevel)

# ---------------------------------------------------------------------------
# ProcSnapshot
# ---------------------------------------------------------------------------

proc snapshotToJson(s: ProcSnapshot): JsonNode =
  result = newJObject()
  result["pid"]       = newJInt(s.pid)
  result["ppid"]      = newJInt(s.ppid)
  result["command"]   = newJString(s.command)
  result["rssBytes"]  = newJInt(s.rssBytes)

proc snapshotFromJson(node: JsonNode): Option[ProcSnapshot] =
  if node == nil or node.kind != JObject: return
  let pidN = node{"pid"}
  let ppidN = node{"ppid"}
  let cmdN = node{"command"}
  let rssN = node{"rssBytes"}
  if pidN == nil or pidN.kind != JInt: return
  if ppidN == nil or ppidN.kind != JInt: return
  if cmdN == nil or cmdN.kind != JString: return
  if rssN == nil or rssN.kind != JInt: return
  some(ProcSnapshot(pid: pidN.getInt, ppid: ppidN.getInt,
                     command: cmdN.getStr, rssBytes: rssN.getBiggestInt))

proc snapshotSeqToJson(xs: seq[ProcSnapshot]): JsonNode =
  result = newJArray()
  for x in xs: result.add snapshotToJson(x)

proc snapshotSeqFromJson(node: JsonNode): Option[seq[ProcSnapshot]] =
  if node == nil or node.kind != JArray: return
  var xs: seq[ProcSnapshot]
  for elt in node:
    let parsed = snapshotFromJson(elt)
    if parsed.isNone: return
    xs.add parsed.get
  some(xs)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

proc exitToJson*(e: Exit): JsonNode =
  result = newJObject()
  result["kind"] = newJString(exitKindStr(e.kind))
  case e.kind
  of ekExited:   result["code"] = newJInt(e.code)
  of ekSignaled:
    result["sig"] = newJInt(e.sig)
    result["coreDumped"] = newJBool(e.coreDumped)
  of ekNtStatus: result["status"] = newJInt(e.status.int64)

proc exitFromJson(node: JsonNode): Option[Exit] =
  if node == nil or node.kind != JObject: return
  let kindN = node{"kind"}
  if kindN == nil or kindN.kind != JString: return
  let kind = parseExitKind(kindN.getStr)
  if kind.isNone: return
  case kind.get
  of ekExited:
    let codeN = node{"code"}
    if codeN == nil or codeN.kind != JInt: return
    some(Exit(kind: ekExited, code: codeN.getInt))
  of ekSignaled:
    let sigN = node{"sig"}
    let coreN = node{"coreDumped"}
    if sigN == nil or sigN.kind != JInt: return
    if coreN == nil or coreN.kind != JBool: return
    some(Exit(kind: ekSignaled, sig: sigN.getInt, coreDumped: coreN.getBool))
  of ekNtStatus:
    let statusN = node{"status"}
    if statusN == nil or statusN.kind != JInt: return
    some(Exit(kind: ekNtStatus, status: statusN.getBiggestInt.uint32))

# ---------------------------------------------------------------------------
# Cause
# ---------------------------------------------------------------------------

proc causeToJson*(c: Cause): JsonNode =
  result = newJObject()
  result["by"] = newJString(causeByStr(c.by))
  case c.by
  of cbProcess, cbExternal: discard
  of cbRunner:
    result["reason"] = newJString(killReasonStr(c.reason))
    result["escalated"] = newJBool(c.escalated)
  of cbLimit:
    result["limit"] = newJString(limitKindStr(c.limit))

proc causeFromJson(node: JsonNode): Option[Cause] =
  if node == nil or node.kind != JObject: return
  let byN = node{"by"}
  if byN == nil or byN.kind != JString: return
  let by = parseCauseBy(byN.getStr)
  if by.isNone: return
  case by.get
  of cbProcess:  some(Cause(by: cbProcess))
  of cbExternal: some(Cause(by: cbExternal))
  of cbRunner:
    let reasonN = node{"reason"}
    let escN = node{"escalated"}
    if reasonN == nil or reasonN.kind != JString: return
    let reason = parseKillReason(reasonN.getStr)
    if reason.isNone: return
    if escN == nil or escN.kind != JBool: return
    some(Cause(by: cbRunner, reason: reason.get, escalated: escN.getBool))
  of cbLimit:
    let limitN = node{"limit"}
    if limitN == nil or limitN.kind != JString: return
    let limit = parseLimitKind(limitN.getStr)
    if limit.isNone: return
    some(Cause(by: cbLimit, limit: limit.get))

# ---------------------------------------------------------------------------
# LimitsAchieved — an object keyed by every LimitKind name.
# ---------------------------------------------------------------------------

proc limitsAchievedToJson(la: LimitsAchieved): JsonNode =
  result = newJObject()
  for k in LimitKind:
    result[limitKindStr(k)] = newJString(limitStatusStr(la[k]))

proc limitsAchievedFromJson(node: JsonNode): Option[LimitsAchieved] =
  if node == nil or node.kind != JObject: return
  var la: LimitsAchieved
  for k in LimitKind:
    let n = node{limitKindStr(k)}
    if n == nil or n.kind != JString: return
    let status = parseLimitStatus(n.getStr)
    if status.isNone: return
    la[k] = status.get
  some(la)

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------

proc evidenceToJson(ev: Evidence): JsonNode =
  result = newJObject()
  result["killDomain"] = newJString(killDomainStr(ev.killDomain))
  result["tree"] = newJString(treeObservationStr(ev.tree))
  result["escapees"] = snapshotSeqToJson(ev.escapees)
  result["limits"] = limitsAchievedToJson(ev.limits)
  result["hermetic"] = newJString(hermeticLevelStr(ev.hermetic))
  result["killSnapshot"] = snapshotSeqToJson(ev.killSnapshot)
  result["cooperativeUnavailable"] = newJBool(ev.cooperativeUnavailable)

proc evidenceFromJson(node: JsonNode): Option[Evidence] =
  if node == nil or node.kind != JObject: return
  let killDomainN = node{"killDomain"}
  let treeN = node{"tree"}
  let escapeesN = node{"escapees"}
  let limitsN = node{"limits"}
  let hermeticN = node{"hermetic"}
  let killSnapshotN = node{"killSnapshot"}
  let coopN = node{"cooperativeUnavailable"}
  if killDomainN == nil or killDomainN.kind != JString: return
  let killDomain = parseKillDomain(killDomainN.getStr)
  if killDomain.isNone: return
  if treeN == nil or treeN.kind != JString: return
  let tree = parseTreeObservation(treeN.getStr)
  if tree.isNone: return
  let escapees = snapshotSeqFromJson(escapeesN)
  if escapees.isNone: return
  let limits = limitsAchievedFromJson(limitsN)
  if limits.isNone: return
  if hermeticN == nil or hermeticN.kind != JString: return
  let hermetic = parseHermeticLevel(hermeticN.getStr)
  if hermetic.isNone: return
  let killSnapshot = snapshotSeqFromJson(killSnapshotN)
  if killSnapshot.isNone: return
  if coopN == nil or coopN.kind != JBool: return
  some(Evidence(
    killDomain: killDomain.get,
    tree: tree.get,
    escapees: escapees.get,
    limits: limits.get,
    hermetic: hermetic.get,
    killSnapshot: killSnapshot.get,
    cooperativeUnavailable: coopN.getBool,
  ))

# ---------------------------------------------------------------------------
# Rusage
# ---------------------------------------------------------------------------

proc rusageToJson(r: Rusage): JsonNode =
  result = newJObject()
  result["maxRssBytes"] = newJInt(r.maxRssBytes)
  result["userCpuUs"] = newJInt(r.userCpuUs)
  result["sysCpuUs"] = newJInt(r.sysCpuUs)

proc rusageFromJson(node: JsonNode): Option[Rusage] =
  if node == nil or node.kind != JObject: return
  let maxN = node{"maxRssBytes"}
  let userN = node{"userCpuUs"}
  let sysN = node{"sysCpuUs"}
  if maxN == nil or maxN.kind != JInt: return
  if userN == nil or userN.kind != JInt: return
  if sysN == nil or sysN.kind != JInt: return
  some(Rusage(maxRssBytes: maxN.getBiggestInt, userCpuUs: userN.getBiggestInt,
              sysCpuUs: sysN.getBiggestInt))

# ---------------------------------------------------------------------------
# Capabilities — the `substrate` node (rfc-0007 A7, §4), rendered in
# run/v2 and plan/v1. Platform-inapplicable fields are simply ABSENT from
# the serialized node (never a greyed-out `false`) — a macOS node carries
# `kqueue` and never the Linux-only cgroup/pidfd/subreaper fields; a
# Windows node carries `jobObjectNesting`/`ctrlBreakDeliverable` and never
# the POSIX-named `flock`/`wait4Rusage`. The included-field set is a
# compile-time platform fact, not a property of any particular probe
# result.
# ---------------------------------------------------------------------------

proc capabilitiesToJson*(c: Capabilities): JsonNode =
  result = newJObject()
  when defined(windows):
    result["jobObjectNesting"]     = newJBool(c.jobObjectNesting)
    result["ctrlBreakDeliverable"] = newJBool(c.ctrlBreakDeliverable)
  elif defined(macosx):
    result["kqueue"]       = newJBool(c.kqueue)
    result["flock"]        = newJBool(c.flock)
    result["wait4Rusage"]  = newJBool(c.wait4Rusage)
  else:   # linux (and, until a dedicated backend exists, any other posix)
    result["pidfd"]            = newJBool(c.pidfd)
    result["subreaper"]        = newJBool(c.subreaper)
    result["cgroupDelegation"] = newJBool(c.cgroupDelegation)
    result["cgroupKill"]       = newJBool(c.cgroupKill)
    result["memoryPeak"]       = newJBool(c.memoryPeak)
    result["flock"]            = newJBool(c.flock)
    result["wait4Rusage"]      = newJBool(c.wait4Rusage)

# ---------------------------------------------------------------------------
# ProcessResult — public surface
# ---------------------------------------------------------------------------

proc toJson*(r: ProcessResult): JsonNode =
  ## Serialize a ProcessResult. Enums as strings; `rusage` is `null` (never
  ## zero-filled) when the platform genuinely cannot say (§2).
  result = newJObject()
  result["exit"] = exitToJson(r.exit)
  result["cause"] = causeToJson(r.cause)
  result["evidence"] = evidenceToJson(r.evidence)
  result["rusage"] = if r.rusage.isSome: rusageToJson(r.rusage.get) else: newJNull()
  result["durationUs"] = newJInt(r.durationUs)

proc toJsonString*(r: ProcessResult): string =
  $toJson(r)

proc fromJson*(node: JsonNode): Option[ProcessResult] =
  ## crisol's OWN reader. Any structural problem — a missing key, a wrong
  ## JSON kind, or an enum string that does not inhabit the Nim enum — is a
  ## STRUCTURAL parse failure: `none`, never a default-valued lie (§2).
  if node == nil or node.kind != JObject: return
  let exitN = node{"exit"}
  let causeN = node{"cause"}
  let evidenceN = node{"evidence"}
  let durationN = node{"durationUs"}
  if durationN == nil or durationN.kind != JInt: return
  let exit = exitFromJson(exitN)
  if exit.isNone: return
  let cause = causeFromJson(causeN)
  if cause.isNone: return
  let evidence = evidenceFromJson(evidenceN)
  if evidence.isNone: return
  var rusage = none(Rusage)
  let rusageN = node{"rusage"}
  if rusageN != nil and rusageN.kind != JNull:
    let parsed = rusageFromJson(rusageN)
    if parsed.isNone: return
    rusage = parsed
  some(ProcessResult(
    exit: exit.get,
    cause: cause.get,
    evidence: evidence.get,
    rusage: rusage,
    durationUs: durationN.getBiggestInt,
  ))

proc fromJsonString*(s: string): Option[ProcessResult] =
  ## As `fromJson`, but over raw text — malformed JSON (not just malformed
  ## structure) also comes back `none`, never raises.
  try:
    fromJson(parseJson(s))
  except CatchableError:
    none(ProcessResult)
