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
##   - `shouldStore`    — the store gate: isFullyAchieved AND attempt-1 pass.
##   - `realSeams`      — production seam bundle (keys.nim + resultcache.nim).
##
## The execute loop (runner.nim) calls `lookupAtPlan` once per runnable
## entrypoint before dispatch, and `shouldStore` after each live result.

import std/[options, os, tables]
import crisol/[types, keys, resultcache, sandbox, depgraph, planner]
# rfc-0007 A1c: synthesize() dual-writes a minimal §2 Phase pair from the
# CachedResult fields it already has, so deriveOutcome (which every consumer
# now calls instead of trusting the stored `outcome` field) reads correctly
# for a cache hit too — see synthesize's comment below.
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
  KeyOfProc* = proc(pep: PlannedEntrypoint): SoundnessKey {.closure.}
    ## Derive the soundness key for an entrypoint.  All effectful inputs
    ## (closureHash, ccVersion, hermeticEnvHash, …) are captured in the closure
    ## when the seam is built, so the dispatch logic stays pure w.r.t. them.

  LoadProc* = proc(key: SoundnessKey): Option[CachedResult] {.closure.}
    ## Look up a cached result.  none = miss.

  StoreProc* = proc(key: SoundnessKey; res: CachedResult): bool {.closure.}
    ## Persist a result.  Returns false when skipped (soft cap) or on I/O error.

  CacheSeams* = object
    ## Injectable bundle: production builds it via `realSeams`; tests mock it.
    keyOf*: KeyOfProc
    load*:  LoadProc
    store*: StoreProc

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

proc cacheDisabled*(spec: SandboxSpec): CacheContext =
  ## Construct a CacheContext with caching fully disabled.
  ## The spec still governs sandbox hermeticity for live runs.
  ## seams.keyOf is nil; active is false.
  CacheContext(
    spec:   spec,
    policy: CachePolicy(enabled: false),
    seams:  CacheSeams(),   # keyOf==nil sentinel
    active: false,
  )

proc cacheEnabled*(spec: SandboxSpec; policy: CachePolicy;
                   seams: CacheSeams): CacheContext =
  ## Construct a CacheContext with caching enabled.
  ## `seams.keyOf` MUST be non-nil; asserted at construction time so an
  ## inconsistent (enabled-but-no-keyOf) state is caught at the boundary.
  doAssert seams.keyOf != nil,
    "cacheEnabled: seams.keyOf must be non-nil (use cacheDisabled if not caching)"
  doAssert policy.enabled,
    "cacheEnabled: policy.enabled must be true (use cacheDisabled if not caching)"
  CacheContext(
    spec:   spec,
    policy: policy,
    seams:  seams,
    active: true,
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

proc synthesize(pep: PlannedEntrypoint; cr: CachedResult;
                inputHash: string): EntrypointResult =
  ## Build an EntrypointResult from a CachedResult.  Carries the HISTORICAL
  ## duration (cr.durationMs) and records; marks it cached with cacheDecision
  ## cdmHit.  `compileSkipped` is true (edCached skips both compile and run).
  ## `inputHash` is the soundnessKey string the hit was keyed on (A8).
  ##
  ## rfc-0007 A1c: also dual-writes a minimal `run: Phase(kind: pkCached, …)`
  ## so deriveOutcome — which every consumer now calls instead of trusting
  ## the stored `outcome` field — reads this result correctly. This is NOT
  ## A1d-ii's real cache-replay (the cache does not store Exit/Cause/Evidence
  ## yet); it is an honest replay of the two fields we DO have:
  ##   - Exit(ekExited, cr.exitCode): a real historical observation, not
  ##     fabricated (CachedResult stores it).
  ##   - Cause(cbProcess): true by construction — shouldStore only ever
  ##     caches an `oPassed` result, which can only arise from a cause-less,
  ##     self-terminated process (§2's derivation never reaches oPassed
  ##     through cbRunner/cbLimit/cbExternal).
  ## Evidence/rusage are NOT observed here (the cache doesn't carry them) and
  ## stay at their honest weakest-claim defaults — same house rule as every
  ## other interim-population corner in this RFC (§2). `compile` stays
  ## pkSkipped: edCached genuinely never compiles.
  result = EntrypointResult(
    ep:             pep.ep,
    outcome:        cr.outcome,
    exitCode:       cr.exitCode,
    signal:         cr.signal,
    records:        cr.records,
    output:         "",            # cached results carry no captured output
    compileSkipped: true,
    durationMs:     cr.durationMs, # historical duration (round 1)
    cached:         true,
    inputHash:      inputHash,     # A8: key the hit was served on
    cacheDecision:  cdmHit,
  )
  result.compile = ptypes.Phase(kind: ptypes.pkSkipped)
  result.run = ptypes.Phase(kind: ptypes.pkCached, res: ptypes.ProcessResult(
    exit:       ptypes.Exit(kind: ptypes.ekExited, code: cr.exitCode),
    cause:      ptypes.Cause(by: ptypes.cbProcess),
    evidence:   default(ptypes.Evidence),
    rusage:     none(ptypes.Rusage),
    durationUs: cr.durationMs * 1000,
  ))

proc lookupAtPlan*(
  pep:    PlannedEntrypoint;
  policy: CachePolicy;
  seams:  CacheSeams;
): PlanLookup =
  ## Decide whether `pep` can be served from cache.
  ##
  ## Only `edRunFresh` entrypoints are eligible (a fresh binary is required for
  ## edCached).  edNeverBuilt / edStale are `cdmNotEligible` (cache not consulted).
  ##
  ## On an eligible entrypoint:
  ##   - policy disabled (--no-cache) OR group cacheable #false
  ##                                      → cdmPolicyDisabled, run live.
  ##   - cache hit                        → edCached, synthesize, cdmHit.
  ##   - cache miss                       → cdmKeyMiss, run live.
  ##
  ## `--changed` is unaffected: a changed closure ⇒ different closureHash ⇒
  ## different soundness key ⇒ guaranteed miss (cache + impact read the same
  ## content, so they cannot disagree).
  if pep.edecision != edRunFresh:
    return PlanLookup(decision: pep.edecision, cacheDecision: cdmNotEligible,
                      inputHash: "", synthesized: none(EntrypointResult))

  let res = resolveCacheable(policy, pep.cacheable)
  if not res.readOk:
    return PlanLookup(decision: edRunFresh, cacheDecision: res.decision,
                      inputHash: "", synthesized: none(EntrypointResult))

  # Eligible + caching on: derive the soundness key once.  Surface it on the
  # lookup so the runner can stamp it onto BOTH a hit (synthesized) and a live
  # miss — run/v1 reports inputHash whenever the cache was actually consulted.
  let key  = seams.keyOf(pep)
  let kStr = $key
  let hit  = seams.load(key)
  if hit.isSome:
    PlanLookup(decision: edCached, cacheDecision: cdmHit, inputHash: kStr,
               synthesized: some(synthesize(pep, hit.get, kStr)))
  else:
    PlanLookup(decision: edRunFresh, cacheDecision: cdmKeyMiss, inputHash: kStr,
               synthesized: none(EntrypointResult))

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
  ##   (b) hermeticity was *achieved* (isFullyAchieved spec vs res.achieved), and
  ##   (c) it PASSED on attempt 1 (never cache a flaky-pass from attempt > 1, or
  ##       it freezes as PASS forever).
  ##
  ## v1 caches passes only; a failing outcome is simply not eligible.  The
  ## returned CacheDecision is the MISS reason for the live result so the
  ## reporting layer (A8) can explain it.
  let res2 = resolveCacheable(policy, cacheable)
  if not res2.writeOk:
    # M8: propagate the resolved decision (cdmGroupOptOut or cdmPolicyDisabled)
    # so callers can distinguish config-declared opt-out from invocation --no-cache.
    return StoreVerdict(store: false, decision: res2.decision)
  if res.outcome != oPassed:
    # Not a pass: not eligible to cache (v1 caches passes only).  A miss for a
    # fresh run is cdmKeyMiss; a fresh FAIL is simply not stored — we keep the
    # key-miss label (it was a fresh run that found no entry and produced none).
    return StoreVerdict(store: false, decision: cdmKeyMiss)
  if not isFullyAchieved(spec, res.achieved):
    return StoreVerdict(store: false, decision: cdmHermeticityDeg)
  if attempt != 1:
    return StoreVerdict(store: false, decision: cdmFlaky)
  # store=true: the live result was a fresh key-miss now being cached; the live
  # result's own CacheDecision stays cdmKeyMiss (it ran live).
  StoreVerdict(store: true, decision: cdmKeyMiss)

proc toCachedResult*(res: EntrypointResult; cachedAt: int64): CachedResult =
  ## Project a live EntrypointResult into the on-disk CachedResult shape.
  CachedResult(
    outcome:    res.outcome,
    exitCode:   res.exitCode,
    signal:     res.signal,
    durationMs: res.durationMs,
    records:    res.records,
    cachedAt:   cachedAt,
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
# Real production seams (keys.nim + resultcache.nim)
# ---------------------------------------------------------------------------

proc realSeams*(
  stateDir:   string;
  graph:      ptr DepGraph;
  nimVersion: string;
  ccVersion:  string;
  spec:       SandboxSpec;
  parentEnv:  seq[(string, string)];
  protocolMajor: int;
): CacheSeams =
  ## Build the production seam bundle.
  ##
  ## The soundness key is derived from:
  ##   closureContentHash ← DepGraphEntry.closureHash for (path, flagHash)
  ##   flagHash           ← flagHash(ep.flags)
  ##   nimVersion, ccVersion, protocolMajor ← passed in
  ##   fixtureHash        ← "" (EmptyFixtureSentinel; per-group fixtures are A9)
  ##   argv               ← [<slug>/<binName>] — stable machine-independent
  ##                        surrogate for the actual binary path used at run time
  ##                        (`<stateDir>/bin/<slug>/<binName>`).  Two entrypoints
  ##                        with the same basename but different paths get different
  ##                        slugs and therefore different argv components.
  ##   rlimitConfig       ← spec.rlimitConfig
  ##   hermeticEnvHash    ← hash of names+values of every env var that actually
  ##                        reaches the hermetic child (post-allowlist-filter),
  ##                        EXCLUDING TMPDIR value (per-run random suffix) and
  ##                        CRISOL_SINK / CRISOL_ATTEMPT (per-run injections).
  ##                        WHY values: an allowlisted var is one tests are
  ##                        *allowed to depend on*, so its value is a real input;
  ##                        soundness (equal key ⇒ equal result) requires it in
  ##                        the key.  Cross-host cache reuse is achieved by pinning
  ##                        the env, not by omitting values (cf. Bazel --action_env,
  ##                        Nix derivations).
  ##
  ## `parentEnv` is the host environment snapshot to filter against `spec`.
  ## Pass `toSeq(envPairs())` at the production call site so the hash reflects
  ## the actual env values the child process will see.  Tests inject a synthetic
  ## snapshot to exercise the key-derivation logic without live env reads.
  ##
  ## When an entrypoint has no graph entry (closureHash empty) the key still
  ## derives deterministically — but such entrypoints are never `edRunFresh`
  ## (decideCompile returns cdStale without a record), so they never reach the
  ## cache lookup; this is belt-and-suspenders.
  ##
  ## `graph` is a `ptr DepGraph` so the key proc reads the LIVE graph: the
  ## runner updates the graph (fresh closureHash) right after a compile, and the
  ## store-key derived afterwards must reflect that updated hash so a later run's
  ## lookup-key (built from the persisted graph) matches.

  # Filter the parent env through the allowlist (no per-run injections yet —
  # those are noise, already excluded inside hermeticEnvHash), then hash
  # names+values.  TMPDIR value and CRISOL_* vars are excluded by hermeticEnvHash.
  let hEnvHash = hermeticEnvHash(filterEnv(parentEnv, spec, @[]))

  let keyOf: KeyOfProc = proc(pep: PlannedEntrypoint): SoundnessKey =
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
    soundnessKey(KeyInputs(
      closureContentHash: entry.closureHash,
      flagHash:           fHash,
      nimVersion:         nimVersion,
      ccVersion:          ccVersion,
      fixtureHash:        "",
      argv:               @[epArgv],
      rlimitConfig:       spec.rlimitConfig,
      hermeticEnvHash:    hEnvHash,
      protocolMajor:      protocolMajor,
    ))

  let load: LoadProc = proc(key: SoundnessKey): Option[CachedResult] =
    loadCached(stateDir, key)

  let store: StoreProc = proc(key: SoundnessKey; res: CachedResult): bool =
    storeCached(stateDir, key, res)

  CacheSeams(keyOf: keyOf, load: load, store: store)
