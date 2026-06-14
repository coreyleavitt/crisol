## admission.nim — AdmissionController: group-cap + memory-aware admission.
##
## S3 builds the GROUP-CAP-ONLY subset; S5 extends with the memory predicate
## (pure decision + mutable controller state). S6b wires the real
## availableMemBytes probe and the adaptive estJobPeak update from live RSS.
##
## Public API:
##
##   SlotToken* = object
##     Opaque reservation handle returned by admit.  Carries the group name
##     and reserved bytes (bytes added to `committed` for this slot).
##
##   AdmissionController* = object
##     Owns mutable admission state (group in-flight counts, memory accounting).
##
##   initAdmission*(cfg, plan, probe, estJobPeakMb, safetyMb, memPerRunMb)
##     → AdmissionController
##     Build groupCap from cfg.groups (only groups WITH a cap), zero groupInflight.
##     Seed estJobPeak (512 MiB built-in when memPerJobMb absent; S6a wires config).
##     Applies M5b mem-aware truth table using cfg.memAware + probe candidate:
##       some(false) → kill switch: probe nil, budget 0 (gate fully inert).
##       some(true)  → force on: probe used AS-IS; budget active.
##       none + probe avail → auto ON; none + probe unavail → auto OFF (budget-only).
##
##   admit*(ac, passId, group, decision) → Option[SlotToken]
##     Returns some(token) iff:
##       (a) group-not-at-cap, AND
##       (b) memory-admits OR progress-override.
##     Memory-admits: availSnapshot.isSome AND
##       availSnapshot - committed - safety >= reserved.
##     Progress-override: liveCount == 0 globally (bypasses memory only, never cap).
##     When availSnapshot.isNone → B is inert → memory gate always passes.
##     Also enforces jobsCap (hard CPU upper limit).
##     On some: committed += reserved, groupInflight++, liveCount++.
##
##     passId: monotone epoch counter.  On the FIRST admit call of each fill pass
##     (when passId != ac.lastPassId), admit refreshes the availability snapshot
##     (same logic as the old public refreshAvail) before proceeding.  Subsequent
##     admit calls with the same passId reuse the cached snapshot.  The caller
##     increments passId once per outer fill pass and threads it into every
##     admit call within that pass; the snapshot is therefore taken at most once
##     per pass, on the first admit, and is impossible to forget or call twice.
##
##   release*(ac, token)
##     Spawn-failure rollback: committed -= token.reserved, groupInflight--, liveCount--.
##
##   onSlotFinish*(ac, token, rss)
##     Normal completion: committed -= token.reserved, groupInflight--, liveCount--.
##     If rss.isSome: estJobPeak = max(rss.get, estJobPeak) (monotonic, floored at seed).
##     If rss.isNone: estJobPeak unchanged.
##
## Judgment call — S5 seed injection:
##   initAdmission takes optional params estJobPeakMb, safetyMb, memPerRunMb for
##   test injection. S6a will parse the corresponding Config fields and pass them
##   through; Config itself remains pristine until S6a (no partial fields added now).
##   Default seeds: estJobPeak = 512 MiB, safety = 0, memPerRunMb = 64 MiB.
##
## liveCount derivation:
##   A dedicated `liveCount: int` counter is maintained alongside groupInflight.
##   It equals sum(groupInflight.values) for capped groups, plus uncapped-group
##   in-flight counts. A dedicated counter is O(1) vs O(groups) for the sum and
##   avoids special-casing uncapped groups (which have no groupInflight entry).
##
## The double-count is intentional (RFC B2 lines 278–286):
##   Live slot RSS is already reflected in the probe value (MemAvailable /
##   cgroup current have fallen), AND token.reserved still sits in committed.
##   The predicate is therefore pessimistic by up to one reservation per
##   in-flight slot during ramp-up — deliberate conservatism. Do NOT subtract
##   live-slot RSS from committed to "correct" it; that reintroduces burst overshoot.

import std/[options, tables]
import crisol/types

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  DefaultEstJobPeakMb* = 512i64  ## Built-in seed for estJobPeak (MiB). RFC lines 311-314.
  DefaultMemPerRunMb*  = 64i64   ## Built-in seed for memPerRunMb (MiB). RFC B2 lines 288-292.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  SlotToken* = object
    ## Opaque reservation handle returned by admit.
    ## group: which group this slot belongs to.
    ## reserved: bytes reserved in committed for this slot.
    ##   Set from estJobPeak (cdNeverBuilt/cdStale) or memPerRunMb (cdSkipFresh).
    group*:    string
    reserved*: int64

  AdmissionController* = object
    ## Owns mutable admission state.
    ##
    ## Group-cap fields (S3, active):
    ##   groupCap      — from Config.groups; only groups WITH a cap (maxJobs.isSome)
    ##   groupInflight — current in-flight count per group name
    ##
    ## Memory predicate fields (S5+S6b, active):
    ##   jobsCap           — plan.jobs (CPU-bound hard upper limit)
    ##   liveCount         — global count of admitted, not-yet-finished slots
    ##   estJobPeak        — adaptive global memory-per-job estimate (MiB → bytes);
    ##                       monotonic non-decreasing, floored at seed
    ##   estJobPeakSeed    — floor for monotonic ratchet (= initial estJobPeak)
    ##   safety            — reserve margin (bytes)
    ##   committed         — sum of in-flight reservations (bytes)
    ##   memPerRun         — bytes reserved for a cdSkipFresh slot (no compile phase)
    ##   probe             — injected; returns available memory bytes each call
    ##   availSnapshot     — cached once per fill pass; refreshed lazily on first admit of a new pass
    ##   memBudgetBytes    — CI cap (bytes); 0 = no cap (use probe raw). S6b.
    ##   memThrottledSlots — count of slots ever memory-blocked (S6b).
    jobsCap*:            int
    liveCount:           int
    estJobPeak:          int64
    estJobPeakSeed:      int64
    safety:              int64
    committed:           int64
    memPerRun:           int64
    groupCap:            Table[string, int]
    groupInflight:       Table[string, int]
    probe:               proc(): Option[int64]
    availSnapshot:       Option[int64]
    memBudgetBytes:      int64   ## 0 = no cap; > 0 = clamp availSnapshot here
    memThrottledSlots*:  int     ## count of candidates ever blocked by memory gate
    lastPassId:          uint    ## epoch of the last snapshot refresh

# ---------------------------------------------------------------------------
# initAdmission
# ---------------------------------------------------------------------------

proc initAdmission*(cfg: Config; plan: RunPlan;
                    probe: proc(): Option[int64] = nil;
                    estJobPeakMb: int64 = 0;
                    safetyMb: int64 = 0;
                    memPerRunMb: int64 = 0): AdmissionController =
  ## Construct an AdmissionController from config and plan.
  ##
  ## groupCap is built from cfg.groups: only groups where maxJobs.isSome get an
  ## entry (groups without maxJobs are uncapped and have no entry).
  ## groupInflight starts at zero for every capped group.
  ##
  ## probe: candidate probe proc (e.g. availableMemBytes from the production path,
  ##   or a fixed-return proc injected by tests).  initAdmission resolves the
  ##   mem-aware truth table (M5b) using cfg.memAware and this candidate probe:
  ##
  ##   cfg.memAware == some(false) → kill switch: gate fully OFF (probe set to nil,
  ##                                 budget suppressed to 0).
  ##   cfg.memAware == some(true)  → force on: probe used AS-IS unconditionally;
  ##                                 budget active if configured.
  ##   cfg.memAware == none(bool)  → auto: probe is called once to test availability;
  ##                                 if it returns some → use it; else → probe=nil
  ##                                 (budget still active if configured).
  ##   probe == nil (no candidate) → gate inert unless budget configured.
  ##
  ## Seed resolution order (highest priority first):
  ##   1. Explicit injected param (> 0) — used by S5/S6a tests for direct injection.
  ##   2. Config field (cfg.memPerJobMb / cfg.memPerRunMb, some(v)) — S6a production path.
  ##   3. Built-in default (512 MiB / 64 MiB).
  ##
  ## safetyMb: injected param only (no Config field in RFC-0002; 0 = no margin).
  var groupCap: Table[string, int]
  var groupInflight: Table[string, int]
  for g in cfg.groups:
    if g.maxJobs.isSome:
      groupCap[g.name]      = g.maxJobs.get
      groupInflight[g.name] = 0

  # Resolve estJobPeak seed: injected param > cfg.memPerJobMb > built-in 512 MiB.
  let resolvedPeakMb =
    if estJobPeakMb > 0:              estJobPeakMb                  # explicit test injection wins
    elif cfg.memPerJobMb.isSome:      int64(cfg.memPerJobMb.get)    # Config field (S6a production path)
    else:                             DefaultEstJobPeakMb            # built-in 512 MiB

  # Resolve memPerRun seed: injected param > cfg.memPerRunMb > built-in 64 MiB.
  let resolvedRunMb =
    if memPerRunMb > 0:               memPerRunMb                   # explicit test injection wins
    elif cfg.memPerRunMb.isSome:      int64(cfg.memPerRunMb.get)    # Config field (S6a production path)
    else:                             DefaultMemPerRunMb             # built-in 64 MiB

  let peak = resolvedPeakMb * 1024 * 1024
  let run  = resolvedRunMb  * 1024 * 1024

  # memBudgetBytes: convert MiB to bytes; 0 = no cap.
  let budgetBytes: int64 =
    if cfg.memBudgetMb.isSome and cfg.memBudgetMb.get > 0:
      int64(cfg.memBudgetMb.get) * 1024 * 1024
    else:
      0i64

  # M5b: resolve mem-aware truth table — decide the actual probe and budget.
  # This logic previously lived in execute(); it now lives here so execute() is clean.
  #
  #   some(false) → kill switch OFF: probe=nil, budget=0 (gate fully inert).
  #   some(true)  → force ON: use candidate probe AS-IS; budget active.
  #   none (auto):
  #     candidate probe non-nil → call once to test availability:
  #       returns some → use it (gate ON); else → nil (budget still active).
  #     candidate probe nil → gate inert (budget still active if configured).
  var resolvedProbe: proc(): Option[int64] = nil
  var resolvedBudget: int64 = budgetBytes

  if cfg.memAware == some(false):
    # Kill switch: gate fully off — suppress probe AND budget.
    resolvedProbe  = nil
    resolvedBudget = 0i64
  elif cfg.memAware == some(true):
    # Force on: use the candidate probe unconditionally.
    resolvedProbe  = probe
    resolvedBudget = budgetBytes
  else:
    # Auto (none): use probe only if it returns some on a test call.
    resolvedBudget = budgetBytes
    if probe != nil:
      let testSnap = probe()
      if testSnap.isSome:
        resolvedProbe = probe
      # else: probe unavailable → gate inert (budget still active)
    # else: no candidate probe → gate inert (budget still active)

  result = AdmissionController(
    jobsCap:           max(1, plan.jobs),
    liveCount:         0,
    estJobPeak:        peak,
    estJobPeakSeed:    peak,
    safety:            safetyMb * 1024 * 1024,
    committed:         0,
    memPerRun:         run,
    groupCap:          groupCap,
    groupInflight:     groupInflight,
    probe:             resolvedProbe,
    availSnapshot:     none(int64),
    memBudgetBytes:    resolvedBudget,
    memThrottledSlots: 0,
    lastPassId:        0,
  )

# ---------------------------------------------------------------------------
# refreshAvailImpl — private: snapshot probe; called lazily from admit
# ---------------------------------------------------------------------------

proc refreshAvailImpl(ac: var AdmissionController) =
  ## Private helper: cache the memory probe result into availSnapshot.
  ## If probe is nil → availSnapshot stays none → B is inert.
  ##
  ## S6b: apply mem-budget-mb clamping:
  ##   If probe returns some(v) and memBudgetBytes > 0 → clamp to min(v, budget).
  ##   If probe is nil but memBudgetBytes > 0 → availSnapshot = some(budget).
  ##   If probe is nil and memBudgetBytes == 0 → availSnapshot = none → B inert.
  var raw: Option[int64] =
    if ac.probe != nil: ac.probe()
    else:               none(int64)

  if ac.memBudgetBytes > 0:
    if raw.isSome:
      ac.availSnapshot = some(min(raw.get, ac.memBudgetBytes))
    else:
      ac.availSnapshot = some(ac.memBudgetBytes)
  else:
    ac.availSnapshot = raw

# ---------------------------------------------------------------------------
# admit
# ---------------------------------------------------------------------------

proc admit*(ac: var AdmissionController; passId: uint; group: string;
            decision: CompileDecision): Option[SlotToken] =
  ## Returns some(token) iff:
  ##   (a) group-not-at-cap (groupInflight[group] < groupCap[group], or no cap), AND
  ##   (b) liveCount < jobsCap (CPU hard upper limit), AND
  ##   (c) memory-admits OR progress-override.
  ##
  ## Memory-admits (when availSnapshot.isSome):
  ##   availSnapshot - committed - safety >= reserved
  ##   where reserved = estJobPeak for cold/stale, memPerRun for cdSkipFresh.
  ##
  ## Progress-override: liveCount == 0 globally.
  ##   Bypasses ONLY the memory gate — never the group cap or jobsCap.
  ##
  ## When availSnapshot.isNone (probe nil AND no budget): B inert → always passes (c).
  ##
  ## Epoch/snapshot management: on the first admit call of a new pass (passId !=
  ## ac.lastPassId), the availability snapshot is refreshed before the predicate
  ## runs. Subsequent calls with the same passId reuse the cached snapshot.
  ## This is self-managing — callers never call refreshAvail directly.
  ## passId contract: the caller must increment passId once per fill pass BEFORE
  ## the pass's first admit call; forgetting to increment reuses the prior snapshot
  ## (conservative/fail-safe — never unsafe, but may throttle when memory has freed).
  ##
  ## On some:
  ##   token.reserved = reserved
  ##   committed += reserved
  ##   groupInflight[group]++
  ##   liveCount++

  # Lazy snapshot: refresh once per pass on the first admit of a new passId.
  if passId != ac.lastPassId:
    refreshAvailImpl(ac)
    ac.lastPassId = passId

  # (a) Group cap check
  if group in ac.groupCap:
    let cap      = ac.groupCap[group]
    let inFlight = ac.groupInflight.getOrDefault(group, 0)
    if inFlight >= cap:
      return none(SlotToken)

  # (b) Hard CPU upper limit
  if ac.liveCount >= ac.jobsCap:
    return none(SlotToken)

  # (c) Memory gate
  let reserved =
    if decision == cdSkipFresh: ac.memPerRun
    else:                       ac.estJobPeak

  let memAdmits =
    if ac.availSnapshot.isNone:
      # B is inert — no probe and no budget
      true
    else:
      let avail    = ac.availSnapshot.get
      let headroom = avail - ac.committed - ac.safety
      headroom >= reserved

  let progressOverride = ac.liveCount == 0  # global; bypasses memory only

  if not (memAdmits or progressOverride):
    # Memory gate refused (not group cap or jobsCap). Track it.
    inc ac.memThrottledSlots
    return none(SlotToken)

  # Admitted — update state
  ac.committed += reserved
  if group in ac.groupInflight:
    ac.groupInflight[group] = ac.groupInflight.getOrDefault(group, 0) + 1
  # Note: uncapped groups have no groupInflight entry; liveCount still increments.
  ac.liveCount += 1

  some(SlotToken(group: group, reserved: reserved))

# ---------------------------------------------------------------------------
# release — spawn-failure rollback
# ---------------------------------------------------------------------------

proc release*(ac: var AdmissionController; token: SlotToken) =
  ## Decrement groupInflight and liveCount, subtract token.reserved from committed.
  ## Called on spawn failure so all reservation state rolls back.
  ac.committed -= token.reserved
  if token.group in ac.groupInflight:
    let cur = ac.groupInflight[token.group]
    if cur > 0:
      ac.groupInflight[token.group] = cur - 1
  if ac.liveCount > 0:
    ac.liveCount -= 1

# ---------------------------------------------------------------------------
# onSlotFinish — slot completion notification
# ---------------------------------------------------------------------------

proc onSlotFinish*(ac: var AdmissionController; token: SlotToken;
                   rss: Option[int64]) =
  ## Called when a slot finishes (normally or via cleanup).
  ## Subtracts token.reserved from committed, decrements groupInflight and liveCount.
  ##
  ## rss: observed RSS bytes for this slot.
  ##   isSome → update estJobPeak = max(rss.get, estJobPeak) (monotonic non-decreasing,
  ##             floored at estJobPeakSeed so a cheap job never collapses the estimate).
  ##   isNone → do NOT update estJobPeak (no observation was made).
  ac.committed -= token.reserved
  if token.group in ac.groupInflight:
    let cur = ac.groupInflight[token.group]
    if cur > 0:
      ac.groupInflight[token.group] = cur - 1
  if ac.liveCount > 0:
    ac.liveCount -= 1

  if rss.isSome:
    # Monotonic non-decreasing; floor at seed so a mixed-batch cdSkipFresh
    # completion never collapses the estimate below the initial seed.
    let observed = rss.get
    ac.estJobPeak = max(observed, max(ac.estJobPeak, ac.estJobPeakSeed))
