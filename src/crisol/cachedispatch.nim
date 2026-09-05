## cachedispatch.nim — A6: plan-time result-cache lookup + store gating (RFC-0004 F3).
##
## This is the wiring that turns crisol's content-addressed ExecutionCache
## (resultcache.nim) + soundness key (keys.nim) into an INCREMENTAL engine: a
## provably-unchanged `edRunFresh` entrypoint is promoted to `edCached`, its
## result synthesized from cache and its `ResultCallback` fired at PLAN TIME —
## it spawns nothing and bypasses the admission controller entirely.
##
## ## Seams (why this module exists)
##
## The two effectful dependencies — soundness-key derivation and the on-disk
## cache load/store — are injected as proc values bundled in `CacheSeams`.  This
## lets the boundary tests (A6) drive the dispatch logic with a pre-seeded /
## mocked cache and a synthetic key proc, without touching the real key chain or
## the filesystem.  Production wiring builds the real seams via `realSeams`.
##
## ## What lives here
##   - `CachePolicy`    — resolved global caching policy (on / off via --no-cache).
##   - `CacheSeams`     — the injectable (keyOf, load, store) bundle.
##   - `lookupAtPlan`   — promote edRunFresh → edCached on a hit; synthesize the
##                        EntrypointResult; ALWAYS populate CacheDecision.
##   - `shouldStore`    — the store gate: evidenceSatisfies AND attempt-1 pass.
##   - `KeyContext`/`keyContext`/`keyOfProc` — key-derivation state + closure
##                        builder (RFC-0005 A2b), independent of any backend.
##   - `realSeams`      — production seam bundle: `keyOf` from `keyOfProc`;
##                        `load`/`store` close over a `CacheRuntime`'s
##                        `TieredCache` (cachetier.nim over cacheport.nim/
##                        cacheregistry.nim) instead of `loadCached`/
##                        `storeCached` directly.
##
## The execute loop (runner.nim) calls `lookupAtPlan` once per runnable
## entrypoint before dispatch, and `shouldStore` after each live result.

import std/[options, os, tables]
import crisol/[types, keys, resultcache, sandbox, depgraph, planner]
# RFC-0005 A2b: the seam now derives INPUTS and looks them up through a
# TieredCache (cachetier) over a CacheBackend (cacheport/cachewire) — see
# KeyContext/KeyDerivation/realSeams below.
import crisol/cacheport
import crisol/cachetier
import crisol/cachewire
import crisol/cachelocalfs  # RFC-0005 B1b: readSidecar/writeSidecar (sidecar I/O)
import crisol/cacheregistry
import crisol/cachetelemetry  # RFC-0005 B2a: TelemetryEvent/TelemetrySink/NilSink
# rfc-0007 §2: synthesize() replays the REAL stored `run` ProcessResult as
# a `Phase(kind: pkCached, ...)` node -- `outcome(r)` (there is no stored
# field) is recomputed over it at THIS boundary (lookupAtPlan) -- see
# synthesize's and lookupAtPlan's comments below.
from crisol/process/types as ptypes import nil

# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------

type
  CachePolicy* = object
    ## Resolved global caching policy.  Per-group `cacheable` tri-state is A9;
    ## v1 here is the global on/off (--no-cache → enabled=false).
    enabled*: bool   ## false = --no-cache: do NOT read and do NOT write.

proc defaultCachePolicy*(): CachePolicy =
  ## Caching is ON by default (RFC-0004 Resolved defaults).
  CachePolicy(enabled: true)

# ---------------------------------------------------------------------------
# Per-entrypoint cacheable resolution (RFC-0004 §144, A9)
# ---------------------------------------------------------------------------

type
  CacheableResolution* = object
    ## Resolved read+write permissions for one entrypoint.
    ## Single source of truth: call `resolveCacheable` once; pass the result.
    readOk*:   bool          ## consult the cache on a plan-time lookup
    writeOk*:  bool          ## store a fresh result into the cache
    decision*: CacheDecision ## structural reason when either is false
                             ## (meaningful only when readOk or writeOk is false)

proc resolveCacheable*(policy: CachePolicy;
                       groupState: CacheableState): CacheableResolution =
  ## RFC-0004 §144 precedence: csFalse → hermeticity-gate → global default.
  ##
  ## Concretely:
  ##   csFalse:   NEVER cache (absolute; blocks read+write regardless of global
  ##              policy or hermeticity gate).  Reports cdmGroupOptOut (M8: distinct
  ##              from --no-cache; this is a permanent config-declared opt-out).
  ##   csTrue:    cache IFF global policy enabled AND hermeticity gate passes.
  ##              Hermeticity is checked at store time by `shouldStore` — this
  ##              proc only gates on global policy.
  ##   csDefault: inherit global policy (same as csTrue for our purposes:
  ##              cache iff global policy enabled + hermeticity gate at store time).
  ##
  ## M8: csFalse reports cdmGroupOptOut; global --no-cache reports cdmPolicyDisabled.
  ## These were previously conflated as cdmPolicyDisabled, making them indistinguishable.
  if groupState == csFalse:
    return CacheableResolution(readOk: false, writeOk: false,
                               decision: cdmGroupOptOut)
  # csTrue or csDefault: gate on global policy.
  if not policy.enabled:
    return CacheableResolution(readOk: false, writeOk: false,
                               decision: cdmPolicyDisabled)
  # Global on + not csFalse: caching permitted (hermeticity checked at store time).
  # M8: `decision` is only meaningful when readOk/writeOk is false; use cdmNotEligible
  # as a neutral sentinel here (this branch means "proceed to lookup").
  CacheableResolution(readOk: true, writeOk: true, decision: cdmNotEligible)

# ---------------------------------------------------------------------------
# Seams
# ---------------------------------------------------------------------------

type
  KeyOfProc* = proc(pep: PlannedEntrypoint): KeyInputs {.closure.}
    ## Derive the soundness-key INPUTS for an entrypoint (RFC-0005 A2b: was
    ## `pep -> SoundnessKey` directly).  All effectful inputs (closureHash,
    ## ccVersion, hermeticEnvHash, …) are captured in the closure when the
    ## seam is built, so the dispatch logic stays pure w.r.t. them.  Dispatch
    ## (`derive`, below) hashes the returned `KeyInputs` — the seam itself
    ## never hashes, so a caller that needs the inputs (the explain-miss
    ## sidecar, the wire's `keyInputs` field) can always get them back; a
    ## `SoundnessKey` is a one-way FNV fold and cannot be reversed.

  LoadProc* = proc(pep: PlannedEntrypoint; d: KeyDerivation): CacheLookup {.closure.}
    ## Look up a cached result.  `d` is `derive(seams, pep)` — the caller
    ## derives once and passes both the entrypoint (for adapters that key
    ## provenance/sidecars by path) and the derivation (inputs + hashed key).
    ## RFC-0005 A2b: was `key -> Option[CachedResult]`.

  StoreProc* = proc(pep: PlannedEntrypoint; d: KeyDerivation; res: CachedResult): bool {.closure.}
    ## Persist a result.  Returns false when skipped (soft cap, offline tier,
    ## or any I/O error).  RFC-0005 A2b: was `(key, res) -> bool`.

  CacheSeams* = object
    ## Injectable bundle: production builds it via `realSeams`; tests mock it.
    ## Still exactly three closures (RFC-0005: "re-typed, not re-shaped").
    keyOf*: KeyOfProc
    load*:  LoadProc
    store*: StoreProc

  KeyDerivation* = object
    ## RFC-0005 A2b: the seam derives INPUTS; dispatch hashes them (pure,
    ## keys.nim) — the clean split that lets `load`/`store` recover the
    ## inputs a `SoundnessKey` alone cannot yield back up.
    inputs*: KeyInputs
    key*:    SoundnessKey  ## = soundnessKey(inputs)

proc derive*(seams: CacheSeams; pep: PlannedEntrypoint): KeyDerivation =
  ## Derive an entrypoint's `KeyDerivation` exactly once: `inputs =
  ## seams.keyOf(pep)`, `key = soundnessKey(inputs)`.  `lookupAtPlan` and
  ## the runner's store-gate call site each call this once per entrypoint.
  let inputs = seams.keyOf(pep)
  KeyDerivation(inputs: inputs, key: soundnessKey(inputs))

# ---------------------------------------------------------------------------
# CacheContext — cohesive bundle enforcing the cache invariant (M4)
# ---------------------------------------------------------------------------
#
# The three cache parameters (spec, policy, seams) were previously passed
# separately to execute().  Their coupling is implicit but absolute: caching
# is "active" iff seams.keyOf != nil AND policy.enabled.  A caller that set
# policy.enabled=true but left seams.keyOf=nil (or vice-versa) silently
# disabled caching with no diagnostic.
#
# CacheContext makes the invariant structural: use `cacheDisabled(spec)` when
# caching should be fully bypassed, or `cacheEnabled(spec, policy, seams)` for
# an active cache.  `isActive` is the single authority on the enabled/disabled
# query — the execute loop MUST NOT re-derive it from seams.keyOf/policy.enabled.
#
# spec is always present (hermeticity still governs the STORE gate and
# sandbox setup even when caching is off) so it is not hidden inside the
# cache-only path.

type
  CacheContext* = object
    ## Cohesive bundle: hermeticity spec + cache policy + cache seams.
    ## Constructed ONLY via `cacheDisabled` / `cacheEnabled`.
    ## Internal layout is NOT part of the public API; use `isActive` / field
    ## accessors.
    spec*:   SandboxSpec   ## always present: governs hermetic sandbox for runs
    policy*: CachePolicy   ## always present: governs store-gate decisions
    seams*:  CacheSeams    ## keyOf==nil iff !active (invariant maintained by constructors)
    active*: bool          ## true iff caching is fully enabled (keyOf!=nil AND policy.enabled)
    sink*:   TelemetrySink[TelemetryEvent]
      ## RFC-0005 B2a: threaded to `lookupAtPlan`'s hit/miss emission (the
      ## store side gets its sink from the `CacheRuntime` `realSeams`
      ## closed over — see that proc). Defaults to `NilSink` so a caller
      ## that never installs telemetry (e.g. every existing `cacheEnabled`
      ## call site predating B2a) pays nothing for it.

proc cacheDisabled*(spec: SandboxSpec): CacheContext =
  ## Construct a CacheContext with caching fully disabled.
  ## The spec still governs sandbox hermeticity for live runs.
  ## seams.keyOf is nil; active is false.
  CacheContext(
    spec:   spec,
    policy: CachePolicy(enabled: false),
    seams:  CacheSeams(),   # keyOf==nil sentinel
    active: false,
    sink:   NilSink[TelemetryEvent](),
  )

proc cacheEnabled*(spec: SandboxSpec; policy: CachePolicy;
                   seams: CacheSeams;
                   sink: TelemetrySink[TelemetryEvent] = NilSink[TelemetryEvent]()
                   ): CacheContext =
  ## Construct a CacheContext with caching enabled.
  ## `seams.keyOf` MUST be non-nil; asserted at construction time so an
  ## inconsistent (enabled-but-no-keyOf) state is caught at the boundary.
  ## `sink` defaults to `NilSink` — pass a real sink (e.g. an
  ## `InMemorySink`'s, or, production, the `CacheRuntime`'s) to observe
  ## `lookupAtPlan`'s hit/miss events.
  doAssert seams.keyOf != nil,
    "cacheEnabled: seams.keyOf must be non-nil (use cacheDisabled if not caching)"
  doAssert policy.enabled,
    "cacheEnabled: policy.enabled must be true (use cacheDisabled if not caching)"
  CacheContext(
    spec:   spec,
    policy: policy,
    seams:  seams,
    active: true,
    sink:   sink,
  )

proc isActive*(ctx: CacheContext): bool {.inline.} =
  ## True iff caching is fully operational for this context.
  ## Single source of truth — do NOT re-derive from seams.keyOf or policy.enabled.
  ctx.active

# ---------------------------------------------------------------------------
# Plan-time lookup — promote edRunFresh → edCached on a hit
# ---------------------------------------------------------------------------

type
  PlanLookup* = object
    ## Outcome of a single plan-time cache lookup.
    decision*:    EntrypointDecision  ## edCached on hit; otherwise unchanged
    cacheDecision*: CacheDecision     ## ALWAYS populated
    inputHash*:   string  ## A8: soundnessKey string for an eligible entry; ""
                          ## when the cache was not consulted (not edRunFresh or
                          ## --no-cache).  The runner stamps this onto the live
                          ## EntrypointResult so run/v1 reports inputHash on
                          ## misses too, not only on hits.
    synthesized*: Option[EntrypointResult]  ## some() iff a hit was served
    explain*:     seq[KeyDiff]  ## RFC-0005 B1c: threaded verbatim from the seam's
                          ## `CacheLookup.explain` (B1b) on a genuine miss (`l.hit.
                          ## isNone`) or a recompute-invalidated hit (empty in that
                          ## case -- the entry WAS found, so there is nothing to
                          ## diff against). Empty for every other early return (not
                          ## eligible / policy disabled / group opt-out) -- the seam
                          ## is never consulted on those paths. The runner threads
                          ## this onto the live EntrypointResult's `keyDiff` field.
    tier*:        string  ## RFC-0005 A3b: the serving tier's name on a genuine
                          ## cache-level hit (`l.hit.get.tier`); "" otherwise --
                          ## whether the eventual EntrypointResult is served from
                          ## this lookup (a promoted edCached) or not (a recompute-
                          ## invalidated hit, or a miss) is the runner's business,
                          ## not this proc's; see `synthesize`'s caller and the
                          ## hit/live stamp sites in runner.nim. Threaded onto the
                          ## live/synthesized EntrypointResult's `cacheTier` field.
    lookup*:      CacheVerdict  ## RFC-0005 A3b: the TieredCache-level lookup
                          ## verdict -- `cvOk` on a genuine hit (`l.hit.isSome`,
                          ## regardless of a later recompute-invalidation: the
                          ## CACHE lookup itself succeeded); `worst(l)` over every
                          ## tier CONSULTED on a miss (`l.hit.isNone` -- surfaces
                          ## the specific trust/transport code even when an
                          ## earlier tier's rejection isn't why the OVERALL lookup
                          ## missed, exactly `worst`'s own documented purpose). The
                          ## zero value `cvOk` (ord 0) on every early return (not
                          ## eligible / policy disabled / group opt-out) -- the
                          ## seam is never consulted on those paths, so there is no
                          ## verdict to report; `EntrypointResult.cacheLookup`'s own
                          ## doc comment covers why the wire presence-gates this
                          ## rather than trusting the bare value. Threaded onto the
                          ## live/synthesized EntrypointResult's `cacheLookup` field.

proc synthesize(pep: PlannedEntrypoint; cr: CachedResult;
                inputHash: string): EntrypointResult =
  ## Build an EntrypointResult from a CachedResult.  Carries the HISTORICAL
  ## duration (derived from cr.run.durationUs) and records; marks it cached
  ## with cacheDecision cdmHit.  `compileSkipped` is true (edCached skips both
  ## compile and run).  `inputHash` is the soundnessKey string the hit was
  ## keyed on (A8).
  ##
  ## rfc-0007 §2: `run` replays the REAL stored observation verbatim --
  ## `Phase(kind: pkCached, res: cr.run)` -- so `outcome(this)`/`cached(this)`
  ## derive genuinely from it, not from a re-stated value here. The CALLER
  ## (`lookupAtPlan`) has ALREADY checked `outcome(this) == oPassed` before
  ## returning this synthesis as a hit; a recompute-invalidated synthesis is
  ## discarded (cdmRecomputeMiss) before any caller sees it. `compile` stays
  ## pkSkipped: edCached genuinely never compiles.
  result = EntrypointResult(
    ep:             pep.ep,
    records:        cr.records,
    output:         "",            # cached results carry no captured output
    compileSkipped: true,
    durationMs:     cr.run.durationUs div 1000, # historical duration
    inputHash:      inputHash,     # A8: key the hit was served on
    cacheDecision:  cdmHit,
  )
  result.compile = ptypes.Phase(kind: ptypes.pkSkipped)
  result.run = ptypes.Phase(kind: ptypes.pkCached, res: cr.run)

proc consultReal(pep: PlannedEntrypoint; seams: CacheSeams;
                 sink: TelemetrySink[TelemetryEvent]): PlanLookup =
  ## The genuine (non-diagnostic) derive+load+recompute-check+synthesize
  ## sequence, shared by the two REAL cache-consult call sites this RFC now
  ## has: `lookupAtPlan`'s plan-time lookup for an `edRunFresh` entrypoint
  ## (a binary already exists — the RFC-0004 case), and `consultPostCompile`
  ## (RFC-0005 A2c-ii), the runner's post-compile consult for an
  ## `edNeverBuilt`/`edStale` entrypoint immediately after a fresh compile —
  ## the case `lookupAtPlan` could never reach (no binary existed BEFORE
  ## that compile). Both callers have already confirmed eligibility (their
  ## own `edecision` gate) and permission (`resolveCacheable().readOk`) —
  ## this proc only does the consult itself, so the two sites can never
  ## drift on the recompute rule, the telemetry emission, or the
  ## PlanLookup shape.
  ##
  ## `pep.edecision` is threaded through verbatim as the returned
  ## `PlanLookup.decision` on a miss/recompute-invalidated result ("edCached
  ## on hit; otherwise unchanged" — see that field's own doc comment) —
  ## `edRunFresh` for `lookupAtPlan`'s caller, `edNeverBuilt`/`edStale` for
  ## `consultPostCompile`'s.
  let d    = derive(seams, pep)
  let kStr = $d.key
  let l    = seams.load(pep, d)
  # RFC-0005 B2a: the real (non-diagnostic) consult -- exactly one event.
  # A later recompute-invalidated hit (cdmRecomputeMiss, below) still emits
  # tekHit here: the cache-level lookup genuinely hit; see
  # cachetelemetry.aggregateCacheStats's doc for why l1Hits is nonetheless
  # decision-sourced rather than a raw tekHit count.
  if l.hit.isSome:
    sink.emit(TelemetryEvent(kind: tekHit, tier: l.hit.get.tier,
                             durationMs: l.hit.get.result.run.durationUs div 1000))
  else:
    sink.emit(TelemetryEvent(kind: tekMiss, verdicts: l.verdicts))
  if l.hit.isNone:
    # RFC-0005 A3b: `lookup` = worst(l) -- the strongest verdict across every
    # tier CONSULTED (cvMiss on an empty/cold cache; a trust code, e.g.
    # cvTrustBadSignature, when a verifyTrust tier rejected an entry and the
    # waterfall found nothing servable -- E2E-A-trust). `tier` stays "" (no
    # tier served this lookup).
    return PlanLookup(decision: pep.edecision, cacheDecision: cdmKeyMiss, inputHash: kStr,
                      synthesized: none(EntrypointResult), explain: l.explain,
                      tier: "", lookup: worst(l))

  # rfc-0007 A1d-ii / §2: recompute the outcome at THIS trust boundary, never
  # read it from storage.  A hit whose recomputed outcome is not oPassed is
  # treated as a MISS and rerun — a derivation or policy change must never
  # serve a stale/invalidated pass from cache forever with no rerun path.
  let synth = synthesize(pep, l.hit.get.result, kStr)
  if outcome(synth) != oPassed:
    # RFC-0005 A3b (judgment call): the CACHE lookup itself genuinely hit
    # (l.hit.isSome) -- `lookup` stays cvOk, honestly describing that fact;
    # `tier` names which tier had the now-invalidated entry. Neither reaches
    # the wire as "served" (EntrypointResult.cacheTier stays "" here) --
    # only the runner's HIT stamp site copies `tier` onto a result, and this
    # branch returns `synthesized: none`, so it never takes that path; the
    # live rerun's own stamp threads `lookup` (cvOk) alongside cacheDecision
    # "recomputeMiss" -- an honest, if unusual, combination: the lookup
    # succeeded, a later check invalidated it.
    return PlanLookup(decision: pep.edecision, cacheDecision: cdmRecomputeMiss,
                      inputHash: kStr, synthesized: none(EntrypointResult),
                      explain: l.explain, tier: l.hit.get.tier, lookup: cvOk)
  PlanLookup(decision: edCached, cacheDecision: cdmHit, inputHash: kStr,
             synthesized: some(synth), tier: l.hit.get.tier, lookup: cvOk)

proc lookupAtPlan*(
  pep:    PlannedEntrypoint;
  policy: CachePolicy;
  seams:  CacheSeams;
  explainDiag: bool = false;
  sink:   TelemetrySink[TelemetryEvent] = NilSink[TelemetryEvent]();
): PlanLookup =
  ## Decide whether `pep` can be served from cache.
  ##
  ## RFC-0005 B2a: on the REAL (non-diagnostic) consult (`consultReal`
  ## below), emits exactly one `tekHit`/`tekMiss` through `sink` — see
  ## `cachetelemetry.nim`'s module doc for why this proc, not
  ## `realSeams.load`, owns the emission (the diagnostic consult a few
  ## lines down calls that SAME `load` closure and must emit nothing).
  ##
  ## Only `edRunFresh` entrypoints are eligible (a fresh binary is required for
  ## edCached).  edNeverBuilt / edStale are `cdmNotEligible` HERE (cache not
  ## consulted AT PLAN TIME) -- RFC-0005 A2c-ii adds a SECOND real consult
  ## for exactly those two decisions, later, once a fresh compile makes a
  ## binary exist: see `consultPostCompile`, the runner's own caller.
  ##
  ## On an eligible entrypoint:
  ##   - policy disabled (--no-cache) OR group cacheable #false
  ##                                      → cdmPolicyDisabled, run live.
  ##   - cache hit, recomputed outcome oPassed → edCached, synthesize, cdmHit.
  ##   - cache hit, recomputed outcome NOT oPassed → cdmRecomputeMiss, run live.
  ##   - cache miss                       → cdmKeyMiss, run live.
  ##
  ## `--changed` is unaffected: a changed closure ⇒ different closureHash ⇒
  ## different soundness key ⇒ guaranteed miss (cache + impact read the same
  ## content, so they cannot disagree).
  ##
  ## `explainDiag` (RFC-0005 B1c, coordinator ruling): a recompiling
  ## entrypoint (flag change, source change, first-ever build) is the
  ## LOAD-BEARING explain-miss scenario (RFC line 375's "your flags
  ## changed") -- but it is NEVER edRunFresh (`planner.slug` hashes ALL
  ## flags into the bin directory, so any flag change points at a bin dir
  ## that does not exist yet), so the normal cache lookup below never runs
  ## for it. When `explainDiag` is true, the `pep.edecision != edRunFresh`
  ## branch does a READ-ONLY diagnostic consult (derive this run's
  ## KeyInputs, call the seam's `load` PURELY to recover `.explain`) --
  ## discarding `.hit`/`.verdicts` entirely: no promotion, no cacheDecision
  ## change (stays `cdmNotEligible`; actually promoting/serving a
  ## recompiled entry from a matching cache elsewhere is A2c's job, not
  ## this diagnostic). GATED on the flag (unlike the sidecar WRITE, which
  ## stays unconditional as B1b built it): with no `--explain-miss` the
  ## extra load has zero observable output (`keyDiff` is only rendered/
  ## serialized under the flag), so an unconditional consult here would be
  ## pure I/O waste -- one backend `get` per recompiling entrypoint per
  ## run, and on a future remote tier a pointless network GET at plan time.
  ## A stale/absent depgraph entry for the (path, NEW flagHash) pair (the
  ## graph is keyed by (path, flagHash); a flag change means no entry
  ## exists yet even though the source is unchanged) can make `keyOf`
  ## derive a degenerate `closureContentHash` ("" — DepGraphEntry()'s
  ## zero value) for this consult, which may surface as an HONEST but
  ## incidental `kcClosure` diff alongside the genuine `kcFlags` one --
  ## not suppressed; degrading gracefully means reporting what the diff
  ## actually is, not hiding a component `keys.explainMiss` legitimately
  ## found different.
  if pep.edecision != edRunFresh:
    var diagExplain: seq[KeyDiff] = @[]
    if explainDiag:
      let d = derive(seams, pep)
      diagExplain = seams.load(pep, d).explain
    return PlanLookup(decision: pep.edecision, cacheDecision: cdmNotEligible,
                      inputHash: "", synthesized: none(EntrypointResult),
                      explain: diagExplain)

  let res = resolveCacheable(policy, pep.cacheable)
  if not res.readOk:
    return PlanLookup(decision: edRunFresh, cacheDecision: res.decision,
                      inputHash: "", synthesized: none(EntrypointResult))

  # Eligible + caching on: consultReal derives the soundness key once
  # (RFC-0005 A2b) and surfaces it on the lookup so the runner can stamp it
  # onto BOTH a hit (synthesized) and a live miss — run/v1 reports
  # inputHash whenever the cache was actually consulted.
  consultReal(pep, seams, sink)

proc consultPostCompile*(
  pep:    PlannedEntrypoint;
  policy: CachePolicy;
  seams:  CacheSeams;
  sink:   TelemetrySink[TelemetryEvent] = NilSink[TelemetryEvent]();
): PlanLookup =
  ## RFC-0005 A2c-ii: the post-compile cache consult. `pep.edecision` is
  ## `edNeverBuilt`/`edStale` here -- `lookupAtPlan`'s edRunFresh-only gate
  ## never gave this entrypoint a real consult AT PLAN TIME, because no
  ## binary existed yet to serve from cache. The runner (`finalizeSlot`)
  ## calls this exactly once, immediately after a THIS-run compile
  ## succeeds and `recordClosure` records its outcome (RFC-0005 A2c-i) --
  ## `seams.keyOf`'s `closureContentHash` therefore reads the JUST-updated
  ## depgraph entry, deriving the SAME key a later run's plan-time lookup
  ## would derive for this exact content (the whole point: a hit here means
  ## some other host/run already published this exact closure).
  ##
  ## Callers MUST call this only when the closure was recorded successfully
  ## — see `finalizeSlot`'s own `rec.ok` guard; an unrecorded/invalidated
  ## closure cannot be trusted to derive a correct key (the same reasoning
  ## R9's store-gate already applies on the write side, applied here on the
  ## read side).
  ##
  ## Shares `resolveCacheable` + `consultReal` with `lookupAtPlan` so the
  ## --no-cache / group-opt-out precedence and the recompute/telemetry
  ## rules can never drift between the two real consult sites.
  let res = resolveCacheable(policy, pep.cacheable)
  if not res.readOk:
    return PlanLookup(decision: pep.edecision, cacheDecision: res.decision,
                      inputHash: "", synthesized: none(EntrypointResult))
  consultReal(pep, seams, sink)

# ---------------------------------------------------------------------------
# Store gate — decide whether a freshly-run result should be cached
# ---------------------------------------------------------------------------

type
  StoreVerdict* = object
    ## Result of the store gate.  When `store` is false, `decision` explains why
    ## so the caller can stamp the live EntrypointResult's CacheDecision.
    store*:    bool
    decision*: CacheDecision

proc shouldStore*(
  res:       EntrypointResult;
  spec:      SandboxSpec;
  attempt:   int;
  policy:    CachePolicy;
  cacheable: CacheableState = csDefault;
): StoreVerdict =
  ## Gate a freshly-run result for caching (RFC-0004 F3).  Store ONLY when:
  ##   (a) per-group cacheable is not csFalse AND global policy permits, and
  ##   (b) hermeticity was *achieved* (evidenceSatisfies over `res`'s own
  ##       `Evidence` — rfc-0007 A6a: named guarantees, incl. escapees and
  ##       the per-limit rules, §6), and
  ##   (c) it PASSED on attempt 1 (never cache a flaky-pass from attempt > 1, or
  ##       it freezes as PASS forever).
  ##
  ## No separate `achieved`/`evidence` parameter (A6a): the run phase's own
  ## `ProcessResult.evidence` — copied VERBATIM from the ReapReport at reap
  ## time (§1's "one report" promise) — is the SOLE source of truth
  ## (`runEvidence(res)`); threading a second, independently-settable value
  ## alongside `res` would let the gate's input disagree with the very
  ## observation it is gating.
  ##
  ## v1 caches passes only; a failing outcome is simply not eligible.  The
  ## returned CacheDecision is the MISS reason for the live result so the
  ## reporting layer (A8) can explain it.
  let res2 = resolveCacheable(policy, cacheable)
  if not res2.writeOk:
    # M8: propagate the resolved decision (cdmGroupOptOut or cdmPolicyDisabled)
    # so callers can distinguish config-declared opt-out from invocation --no-cache.
    return StoreVerdict(store: false, decision: res2.decision)
  if outcome(res) != oPassed:
    # Not a pass: not eligible to cache (v1 caches passes only).  A miss for a
    # fresh run is cdmKeyMiss; a fresh FAIL is simply not stored — we keep the
    # key-miss label (it was a fresh run that found no entry and produced none).
    return StoreVerdict(store: false, decision: cdmKeyMiss)
  if not evidenceSatisfies(spec, runEvidence(res)):
    return StoreVerdict(store: false, decision: cdmHermeticityDeg)
  if attempt != 1:
    return StoreVerdict(store: false, decision: cdmFlaky)
  # store=true: the live result was a fresh key-miss now being cached; the live
  # result's own CacheDecision stays cdmKeyMiss (it ran live).
  StoreVerdict(store: true, decision: cdmKeyMiss)

proc toCachedResult*(res: EntrypointResult; cachedAt: int64): CachedResult =
  ## Project a live EntrypointResult into the on-disk CachedResult shape
  ## (rfc-0007 A1d-ii): the REAL run-phase ProcessResult, not a derived
  ## outcome/exitCode/signal projection.  Callers (the runner's store gate)
  ## only ever reach this for a freshly-RUN result — never a cache hit — so
  ## `res.run.kind` is `pkRan` here; asserted rather than silently defaulted.
  doAssert res.run.kind == ptypes.pkRan,
    "toCachedResult: expected a live run phase (pkRan), got " & $res.run.kind
  CachedResult(
    run:             res.run.res,
    records:         res.records,
    cachedAt:        cachedAt,
    payloadChecksum: "",   # filled by storeCached
  )

# ---------------------------------------------------------------------------
# L15: inactiveDecision — canonical (isActive=false, edecision) → CacheDecision
# ---------------------------------------------------------------------------

proc inactiveDecision*(d: EntrypointDecision): CacheDecision =
  ## Map an EntrypointDecision to the correct CacheDecision when the cache is
  ## NOT active (CacheContext.isActive == false).
  ##
  ## This is the authoritative (isActive=false, edecision) → CacheDecision
  ## mapping.  The symmetric active-path mapping lives in `lookupAtPlan`.
  ##
  ## Decision table (inactive path):
  ##   edRunFresh   → cdmPolicyDisabled  — binary was cache-eligible but the cache
  ##                                       was explicitly disabled (--no-cache).
  ##                                       Distinct from cdmNotEligible: the
  ##                                       entrypoint WOULD have been consulted.
  ##   edNeverBuilt → cdmNotEligible     — had to be compiled; cache never applied.
  ##   edStale      → cdmNotEligible     — stale; had to recompile; cache never applied.
  ##   edCached     → cdmNotEligible     — unreachable on the !isActive path (a plan-
  ##                                       time hit requires isActive); documented as
  ##                                       a defensive fallthrough (cdmNotEligible is
  ##                                       the safest sentinel for an impossible state).
  case d
  of edRunFresh:   cdmPolicyDisabled
  of edNeverBuilt: cdmNotEligible
  of edStale:      cdmNotEligible
  of edCached:     cdmNotEligible   # unreachable: plan-time hit requires isActive

# ---------------------------------------------------------------------------
# KeyContext — everything keyOf closes over except the live graph
# (RFC-0005 A2b "Wiring": realSeams' key-derivation params, minus stateDir
# and graph, which load/store and keyOfProc need directly instead).
# ---------------------------------------------------------------------------

type
  KeyContext* = object
    ## Everything `keyOf` closes over except the live graph.
    nimVersion*, ccVersion*: string
    spec*:            SandboxSpec
    hermeticEnvHash*: string
      ## = hermeticEnvHash(filterEnv(parentEnv, spec, @[])) — computed ONCE
      ## by `keyContext` (env-pins are already applied via `spec.envPins`,
      ## which `filterEnv` reads; see `sandbox.filterEnv`).
    envDigest*: seq[(string, string)]
      ## RFC-0005 B1b: `keys.envDigest` over `sandbox.hermeticEnvDigestInput`'s
      ## normalized pairs — the SAME two exclusion rules `hermeticEnvHash`
      ## folds into the key (CRISOL_SINK/ATTEMPT dropped; TMPDIR value
      ## blanked), so this never disagrees with `hermeticEnvHash` about what
      ## is actually IN the key. Computed ONCE alongside `hermeticEnvHash`.
      ## Feeds the explain-miss sidecar's stored record and `explainMiss`'s
      ## `currEnv` — NEVER a raw value (`keys.envDigest` never retains one).
    protocolMajor*:   int

proc keyContext*(nimVersion, ccVersion: string; spec: SandboxSpec;
                 parentEnv: openArray[(string, string)];
                 protocolMajor: int): KeyContext =
  ## Build the key-derivation context once per run.
  ##
  ## `parentEnv` is the host environment snapshot to filter against `spec`.
  ## Pass `toSeq(envPairs())` at the production call site so the hash reflects
  ## the actual env values the child process will see.  Tests inject a
  ## synthetic snapshot to exercise the key-derivation logic without live env
  ## reads.  Filtering (allowlist + `spec.envPins`' tail) happens exactly once
  ## here — every `keyOfProc`-built closure reuses the resulting hash.
  let filtered = filterEnv(parentEnv, spec, @[])
  KeyContext(
    nimVersion:      nimVersion,
    ccVersion:       ccVersion,
    spec:            spec,
    hermeticEnvHash: hermeticEnvHash(filtered),
    envDigest:       envDigest(hermeticEnvDigestInput(filtered)),
    protocolMajor:   protocolMajor,
  )

proc keyOfProc*(ctx: KeyContext; graph: ptr DepGraph): KeyOfProc =
  ## Build the `KeyOfProc` closure — what the key-derivation tests call
  ## directly (no cache backend/CacheRuntime needed to exercise key logic).
  ##
  ## The soundness-key INPUTS are derived from:
  ##   closureContentHash ← DepGraphEntry.closureHash for (path, flagHash)
  ##   flagHash           ← flagHash(ep.flags)
  ##   nimVersion, ccVersion, protocolMajor ← ctx
  ##   fixtureHash        ← "" (EmptyFixtureSentinel; per-group fixtures are A9)
  ##   argv               ← [<slug>/<binName>] — stable machine-independent
  ##                        surrogate for the actual binary path used at run time
  ##                        (`<stateDir>/bin/<slug>/<binName>`).  Two entrypoints
  ##                        with the same basename but different paths get different
  ##                        slugs and therefore different argv components.
  ##   limits             ← ctx.spec.limits (rfc-0007 §1 enum-indexed Limits home)
  ##   hermeticEnvHash    ← ctx.hermeticEnvHash: names+values of every env var
  ##                        that actually reaches the hermetic child
  ##                        (post-allowlist-filter), EXCLUDING TMPDIR value
  ##                        (per-run random suffix) and CRISOL_SINK /
  ##                        CRISOL_ATTEMPT (per-run injections).  WHY values:
  ##                        an allowlisted var is one tests are *allowed to
  ##                        depend on*, so its value is a real input;
  ##                        soundness (equal key ⇒ equal result) requires it
  ##                        in the key.  Cross-host cache reuse is achieved by
  ##                        pinning the env, not by omitting values (cf.
  ##                        Bazel --action_env, Nix derivations).
  ##
  ## When an entrypoint has no graph entry (closureHash empty) the inputs
  ## still derive deterministically — but such entrypoints are never
  ## `edRunFresh` (decideCompile returns cdStale without a record), so they
  ## never reach the cache lookup; this is belt-and-suspenders.
  ##
  ## `graph` is a `ptr DepGraph` so the returned closure reads the LIVE
  ## graph: the runner updates the graph (fresh closureHash) right after a
  ## compile, and the store-key derived afterwards must reflect that updated
  ## hash so a later run's lookup-key (built from the persisted graph)
  ## matches.
  proc(pep: PlannedEntrypoint): KeyInputs =
    let ep    = pep.ep
    let fHash = flagHash(ep.flags)
    let entry =
      if (ep.path, fHash) in graph[].entries: graph[].entries[(ep.path, fHash)]
      else: DepGraphEntry()
    # L4: argv component reflects the actual binary path used at run time.
    # spawnRunDirect/spawnRun invoke `<stateDir>/bin/<slug>/<binName>` — a full
    # absolute path that varies per machine/stateDir and cannot be in a stable
    # key.  The stable, machine-independent surrogate is `<slug>/<binName>`:
    # it is uniquely determined by (ep.path, ep.flags) and matches what the
    # execute loop would build, making two entrypoints with the same basename but
    # different paths produce distinct argv components.
    let epSlug = slug(ep.path, ep.flags)
    let epArgv = epSlug / binName(ep)
    KeyInputs(
      closureContentHash: entry.closureHash,
      flagHash:           fHash,
      nimVersion:         ctx.nimVersion,
      ccVersion:          ctx.ccVersion,
      fixtureHash:        "",
      argv:               @[epArgv],
      limits:             ctx.spec.limits,
      hermeticEnvHash:    ctx.hermeticEnvHash,
      protocolMajor:      ctx.protocolMajor,
    )

# ---------------------------------------------------------------------------
# Real production seams (cacheport.nim + cachetier.nim + cacheregistry.nim)
# ---------------------------------------------------------------------------

proc realSeams*(ctx: KeyContext; graph: ptr DepGraph; rt: CacheRuntime): CacheSeams =
  ## Build the production seam bundle.  `load`/`store` close over `rt.cache`
  ## (a single-tier `TieredCache` over the local-fs backend by default, via
  ## `cacheregistry.localOnlyCache`) instead of `loadCached`/`storeCached`
  ## directly (RFC-0005 A2b — "the load-bearing refactor").
  ##
  ## `rt` is captured as a mutable local shadow so the closures below can
  ## call `TieredCache.lookup`/`put` (which take `var TieredCache`); `rt`'s
  ## `cache` field is otherwise identical to what the caller passed in.
  ## (`CacheRuntime` is a `ref` since A3c-ii, so this shadow and the caller's
  ## own handle already point at the SAME heap object — the caller observes
  ## everything these closures accumulate, including the breaker and the
  ## deferred-put queue below, without any extra plumbing.)
  ##
  ## RFC-0005 B0/A3c-ii "Deferred remote puts": `store` writes tier 0 ("l1")
  ## SYNCHRONOUSLY via `TieredCache.putLocal` and, only when a remote tier is
  ## actually configured (`rt.cache.tiers.len > 1`), queues the SAME entry on
  ## `rt.pending` for `api.runTestsWith`'s end-of-run flush
  ## (`TieredCache.drainPending`) instead of fanning out to remote tiers
  ## inline — remote I/O must never run inside the poll loop at every live
  ## finalize. The seam's boolean return (published-or-not, folded by the
  ## caller into `cdmStored`/live-stamp bookkeeping) reflects tier 0's
  ## verdict ONLY — the remote verdict is not yet known at this point in the
  ## run.
  ##
  ## RFC-0005 B1b: `load`/`store` ALSO drive the path-keyed explain-miss
  ## sidecar directly via `cachelocalfs.readSidecar`/`writeSidecar` — NOT
  ## through `CacheBackend`/`TieredCache` (sidecar I/O is a local-fs
  ## implementation detail, not a port concern) — gated on
  ## `rt.localRoot.len > 0` (tier 0 / local root only; a runtime with no
  ## local root, e.g. a bare test double, simply has nothing to diff
  ## against or write to).
  var rt = rt
  CacheSeams(
    keyOf: keyOfProc(ctx, graph),
    load:  proc(pep: PlannedEntrypoint; d: KeyDerivation): CacheLookup =
             result = rt.cache.lookup(d.key)
             # RFC-0005 A3b: the tekBackfillErr LIVE emission site -- A3a
             # landed the pure producer (cachetelemetry.backfillErrEvents,
             # over CacheLookup.backfillVerdicts) with no caller; this is
             # that caller. Mirrors realSeams.store's own tekPublish/
             # tekRemoteErr emission a few lines down -- the store side of
             # the SAME "translate a cache-layer outcome into telemetry"
             # concern this adapter already owns for puts.
             for ev in backfillErrEvents(result):
               rt.sink.emit(ev)
             if result.hit.isNone and rt.localRoot.len > 0:
               let prior = mostRecentRecord(readSidecar(rt.localRoot, pep.ep.path))
               if prior.isSome:
                 result.explain = explainMiss(prior.get.entry.inputs, d.inputs,
                                               prior.get.entry.envDigest, ctx.envDigest)
    ,
    store: proc(pep: PlannedEntrypoint; d: KeyDerivation; res: CachedResult): bool =
             let entry = StoredEntry(
               key:            d.key,
               keyInputs:      some(d.inputs),
               result:         res,
               storageVersion: storageFormatVersion,
             )
             let v = rt.cache.putLocal(entry)
             result = v.verdict == cvOk
             # RFC-0005 B2a: publish/remote-err on tier 0's put outcome. The
             # remote tiers' own publish/remote-err events fire later, at
             # drain time (api.runTestsWith), when their verdicts actually
             # exist.
             if result:
               rt.sink.emit(TelemetryEvent(kind: tekPublish, publishedTo: v.tier))
             elif v.verdict in transportVerdicts:
               rt.sink.emit(TelemetryEvent(kind: tekRemoteErr, putTier: v.tier,
                                           putVerdict: v.verdict))
             if rt.cache.tiers.len > 1:
               rt.pending.add entry
             if result and rt.localRoot.len > 0:
               writeSidecar(rt.localRoot, pep.ep.path,
                            SidecarEntry(key: d.key, inputs: d.inputs, envDigest: ctx.envDigest))
    ,
  )
