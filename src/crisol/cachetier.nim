## cachetier.nim — RFC-0005 A3a: the multi-tier `TieredCache` engine.
##
## `lookup` must NOT discard which tier hit, whether trust passed, or what
## each tier said — telemetry, `run/v2` provenance, the 100%-error
## diagnostic, and the backfill rule all need it. Hence `CacheLookup.verdicts`:
## one per tier CONSULTED, in search order.
##
## **A3a lifts A1's single-tier restriction** (the `doAssert tiers.len <= 1`
## that made `lookup`/`put` refuse a second tier) and builds the general
## N-tier waterfall: backfill-on-hit gated by the **verified-bit backfill
## rule**, the **put rule** (separate gate, `put`'s own fan-out), a per-tier
## **circuit breaker**, and a budget-bounded drain for **deferred puts**
## (RFC-0005 "TieredCache — the composition, with provenance" + "B0").
##
## **A3c-ii wires the deferred-put split live:** `putLocal` is the
## SYNCHRONOUS half a live finalize calls (tier 0 / "l1" only — the caller
## queues the same entry for tiers 1..N and flushes that queue once, at the
## end-of-run join point, via the unchanged `drainPending` — see
## `cachedispatch.realSeams.store`/`api.runTestsWith`).
##
## `TieredCache` stays a PURE lookup engine — no `TelemetrySink` field (that
## lives on `CacheRuntime`, Stage A2b): telemetry emission is a translation
## concern belonging to the `realSeams` adapter, exactly where an
## observation of the call belongs, not to the engine itself. Likewise no
## stderr I/O here: the circuit breaker's "one stderr line" (RFC "Per-tier
## circuit breaker") is a rendering decision for whichever layer has I/O
## access (mirrors `cachetelemetry.tierErrorWarning`: a pure formatter, the
## caller writes it) — a tripped tier is fully legible from `CacheLookup`'s
## `cvOffline`/`cvTimeout` verdicts without this module ever touching stderr.

import std/[options, sets, tables]
import crisol/cacheport
# KeyDiff (RFC-0005 B1b's explain-miss attachment) lives in `crisol/types`
# (B1c re-home) and reaches here via `cacheport`'s `export types` -- no
# direct `crisol/keys` import needed.

type
  Tier* = object
    name*: string
      ## Deployer label: `"l1"` (pinned, Stage A2a) | the KDL remote-cache
      ## name (Stage A3c). NOT `CacheBackend.scheme` (the adapter kind).
    backend*: CacheBackend
    backfillOnHit*: bool
      ## Write to THIS tier when a DOWNSTREAM tier serves the hit.
    verifyTrust*: bool
      ## Reject entries READ from this tier that fail `TrustPolicy`; also:
      ## PUT here only attested entries (the A3a put rule).

  TieredCache* = object
    tiers*: seq[Tier]
      ## L1 → L2 → L3 …, searched in order.
    trust*: TrustPolicy
      ## ONE policy per cache — shared by every `verifyTrust` tier (a
      ## backfilled entry is re-stored WITH the attestation it arrived
      ## with, valid at the destination only under the SAME policy).
    breaker: HashSet[string]
      ## Per-tier circuit breaker state (RFC-0005 "Per-tier circuit
      ## breaker"), keyed by `Tier.name`. Once a tier's `get`/`put` returns
      ## `cvOffline`/`cvTimeout`, it is added here and every subsequent
      ## `get`/`put` against that tier for the rest of THIS `TieredCache`'s
      ## life (== the run, since one `TieredCache` is built per run) short-
      ## circuits to `cvOffline` without touching the backend — "total dead
      ## wall-clock per run per tier ≤ one deadline" holds by construction.
      ## A private, non-exported field: callers observe the effect (through
      ## verdicts), never the state directly. No injected clock: the RFC's
      ## own design text (unlike the stage-list's terse parenthetical)
      ## describes a permanent-for-the-run latch, not a timed half-open —
      ## building an unrequested recovery window would be speculative code
      ## the standing rules forbid. See the module test suite's breaker
      ## block for the "still dead after N further calls" proof.
    probed: Table[string, HashSet[SoundnessKey]]
      ## RFC-0005 C3c (prefetch): per-tier bulk-existence result, keyed by
      ## `Tier.name`, populated ONLY by `resolveProbes` (below) for a tier
      ## whose backend `canProbe` — absent for every other tier (nil-probe,
      ## not-yet-resolved, or breaker-tripped) for the life of this
      ## `TieredCache`, exactly like `breaker`. A private, non-exported
      ## field: `lookup` is the sole reader.
    probedKeys: HashSet[SoundnessKey]
      ## RFC-0005 C3c: the union of every key `resolveProbes` was ever
      ## asked about THIS run — shared across tiers (one candidate set,
      ## probed once per tier). `lookup` only trusts a tier's `probed` set
      ## to mean "absent" for a key that is IN `probedKeys`; a key outside
      ## it (e.g. a post-compile key derived after the plan-time prefetch,
      ## RFC-0005 A2c) was never asked about, so its absence from a probe
      ## response is not evidence of absence — `lookup` falls back to a
      ## real `get` for it (see `lookup`'s own comment).

  TierHit* = object
    result*: CachedResult
    tier*: string
      ## Which tier served it — `run/v2` provenance + telemetry.
    verified*: bool
      ## True iff the entry PASSED trust verification (NOT merely "the
      ## tier didn't require it"). Meaningful only when `trust.name !=
      ## "none"`; under `nonePolicy` it is trivially true.

  TierVerdict* = tuple[tier: string, verdict: CacheVerdict]

  CacheLookup* = object
    hit*: Option[TierHit]
    verdicts*: seq[TierVerdict]
      ## One per tier CONSULTED, in search order (`cvOk` for the serving
      ## tier).
    backfillVerdicts*: seq[TierVerdict]
      ## RFC-0005 A3a: one per UPSTREAM `backfillOnHit` tier this lookup
      ## actually attempted to backfill (empty on a miss, or when no
      ## upstream tier qualifies). A backfill write is attempted only for
      ## tiers passing the verified-bit backfill rule (below) — a skipped
      ## tier (rule failed) contributes NO entry here, same as an
      ## unconsulted tier contributes none to `verdicts`. `cachetelemetry`
      ## folds the transport-class entries here into `tekBackfillErr`
      ## (`backfillErrEvents`) — kept as data on the pure engine's result,
      ## never emitted from here (see the module doc comment above).
    explain*: seq[KeyDiff]
      ## RFC-0005 B1b: populated ONLY by the `cachedispatch.realSeams`
      ## `load` adapter, on a MISS, when the path-keyed local-fs sidecar
      ## (tier 0 / local root only) has a prior record to diff against via
      ## `keys.explainMiss` — empty otherwise (a hit, no sidecar, or a
      ## runtime with no local root). NOT set by `TieredCache.lookup`
      ## itself: this is a pure lookup engine with no path/sidecar
      ## knowledge — see `cachelocalfs.nim`'s module doc ("sidecar I/O is a
      ## local-fs implementation detail, not a CacheBackend contract").

proc worst*(l: CacheLookup): CacheVerdict =
  ## The strongest verdict across `l.verdicts`, by `CacheVerdict`'s own
  ## declared weakest → strongest order (`cvOk` is deliberately the WEAKEST
  ## of all — ord 0 — so a tier that rejects 100% of reads stays
  ## attributable even when a LATER tier serves the hit; RFC-0005 "a tier
  ## that rejects 100% of reads is attributable even when a later tier
  ## serves the hit"). `cvMiss` when `l.verdicts` is empty (vacuously — no
  ## tier was even consulted); that empty-list sentinel must NOT double as
  ## a fold seed for a non-empty list, since `cvMiss`'s ord (1) sits ABOVE
  ## `cvOk`'s (0) and would wrongly swallow a genuine `cvOk`.
  if l.verdicts.len == 0: return cvMiss
  result = l.verdicts[0].verdict
  for tv in l.verdicts:
    if ord(tv.verdict) > ord(result):
      result = tv.verdict

# ---------------------------------------------------------------------------
# Circuit breaker — ~10 lines, private to this module (RFC-0005 "Per-tier
# circuit breaker").
# ---------------------------------------------------------------------------

proc breakerTripped(tc: TieredCache; name: string): bool {.inline.} =
  name in tc.breaker

proc tripBreaker(tc: var TieredCache; name: string; verdict: CacheVerdict) {.inline.} =
  if verdict in {cvOffline, cvTimeout}:
    tc.breaker.incl name

# ---------------------------------------------------------------------------
# resolveProbes — RFC-0005 C3c (prefetch): resolve every canProbe tier's
# key-existence set ONCE, over the caller's full plan-time candidate key
# set, so `lookup` (below) can consult it before any per-key `get`.
# ---------------------------------------------------------------------------

proc resolveProbes*(tc: var TieredCache; keys: openArray[SoundnessKey];
                     abandoned: proc(): bool {.closure.} = proc(): bool = false) =
  ## Called ONCE per run by the caller (the runner's plan-time consult loop,
  ## `runner.nim`) with the full set of candidate keys it is about to look
  ## up. For every tier whose backend `canProbe` (and is not already
  ## resolved or breaker-tripped), calls `backend.probe(keys)` exactly once
  ## and remembers the result; `lookup` then skips the `get` entirely for a
  ## key this tier's probe did not report present.
  ##
  ## `abandoned` is an injected predicate (default: never abandon) rather
  ## than a direct `crisol/signals` import — the SAME "no real clock/signal
  ## dependency, call-counting/injected-predicate only" discipline the
  ## circuit breaker already follows (module doc, above), keeping this a
  ## pure, memory-testable engine. The production caller wires
  ## `proc(): bool = signals.shutdownRequested().isSome`.
  ##
  ## RFC-0005 B0(c): "the prefetch loop checks `shutdownRequested()` per
  ## iteration and abandons the prefetch on a pending shutdown ... an
  ## abandoned prefetch degrades to per-key misses" — checked once PER TIER
  ## here (a probe is one network round trip; N tiers is N round trips), so
  ## a pending interrupt stops embarking on any further tier's probe. The
  ## remaining, un-probed tier(s) are marked probed-EMPTY (not left
  ## unresolved): every key ends up a `cvMiss` for that tier with no `get`
  ## at all, rather than falling through to the (potentially much slower,
  ## N-round-trip) per-key `get` path an unresolved tier would otherwise
  ## take — the whole point of abandoning is to stop doing more I/O, not to
  ## trade one kind of I/O for another.
  if keys.len == 0: return
  for k in keys: tc.probedKeys.incl k
  for tier in tc.tiers:
    if not canProbe(tier.backend): continue
    if tier.name in tc.probed: continue          # already resolved this run
    if tc.breakerTripped(tier.name): continue    # already known dead
    if abandoned():
      tc.probed[tier.name] = initHashSet[SoundnessKey]()
      continue
    let fetched = tier.backend.probe(keys)
    if fetched.verdict == cvOk:
      tc.probed[tier.name] = fetched.value
    else:
      # A probe failure is a transport failure by BackendProbeProc's own
      # contract (cacheport.nim) — trip the breaker exactly as a failed
      # `get`/`put` would; `lookup`'s breaker check (below) already short-
      # circuits every subsequent call against this tier, so leaving
      # `tc.probed` unset for it here is fine (unreachable via the breaker).
      tc.tripBreaker(tier.name, fetched.verdict)

# ---------------------------------------------------------------------------
# lookup — the waterfall + backfill-on-hit + the verified-bit rule.
# ---------------------------------------------------------------------------

proc lookup*(tc: var TieredCache; key: SoundnessKey): CacheLookup =
  var verdicts: seq[TierVerdict] = @[]
  for idx, tier in tc.tiers:
    var fetched: Fetched[StoredEntry]
    if tc.breakerTripped(tier.name):
      fetched = Fetched[StoredEntry](verdict: cvOffline)
    elif tier.name in tc.probed and key in tc.probedKeys and key notin tc.probed[tier.name]:
      # RFC-0005 C3c: this tier's probe was resolved over a candidate set
      # that INCLUDED this key and did not report it present — skip the
      # `get` entirely, exactly the prefetch optimization's point. A key
      # outside `probedKeys` (e.g. a post-compile key derived AFTER this
      # run's plan-time prefetch, RFC-0005 A2c) is deliberately NOT covered
      # by this branch: it was never asked about, so its absence here is
      # not evidence of absence — it falls to the `else` branch's real
      # `get`, below, same as an unprobed tier.
      fetched = Fetched[StoredEntry](verdict: cvMiss)
    else:
      fetched = tier.backend.get(key)
      tc.tripBreaker(tier.name, fetched.verdict)

    if fetched.verdict != cvOk:
      verdicts.add (tier.name, fetched.verdict)
      continue

    # Trust verify runs for the `verified` bit even on a non-`verifyTrust`
    # tier (one pure local computation over bytes already in hand, no I/O) —
    # it is meaningful only under a real policy (nonePolicy is trivially ok).
    let verifyVerdict = tc.trust.verify(fetched.value)
    let verified = verifyVerdict == cvOk

    if tier.verifyTrust and verifyVerdict in trustVerdicts:
      # Never serve a failed entry: this tier's specific trust code is the
      # recorded verdict, not a generic miss (RFC-0005 "lookup (waterfall)").
      # Continue the waterfall — a rejected entry here does not abort the
      # search.
      verdicts.add (tier.name, verifyVerdict)
      continue

    verdicts.add (tier.name, cvOk)
    let hit = TierHit(result: fetched.value.result, tier: tier.name, verified: verified)

    # Backfill: earlier (upstream) `backfillOnHit` tiers, subject ONLY to
    # the verified-bit backfill rule -- "backfill tier t only if
    # hit.verified OR not t.verifyTrust". The entry is re-stored EXACTLY as
    # fetched (its own attestation, if any) -- backfill never re-signs
    # (RFC: "a backfilled entry is re-stored with the attestation it
    # arrived with").
    var backfillVerdicts: seq[TierVerdict] = @[]
    for j in 0 ..< idx:
      let btier = tc.tiers[j]
      if not btier.backfillOnHit: continue
      if not (verified or not btier.verifyTrust): continue
      var v: CacheVerdict
      if tc.breakerTripped(btier.name):
        v = cvOffline
      else:
        v = btier.backend.put(fetched.value)
        tc.tripBreaker(btier.name, v)
      backfillVerdicts.add (btier.name, v)

    return CacheLookup(hit: some(hit), verdicts: verdicts, backfillVerdicts: backfillVerdicts)

  CacheLookup(hit: none(TierHit), verdicts: verdicts, backfillVerdicts: @[])

# ---------------------------------------------------------------------------
# put — the fan-out + the put rule.
# ---------------------------------------------------------------------------

proc put*(tc: var TieredCache; entry: StoredEntry): seq[TierVerdict] =
  ## The entry has ALREADY cleared `shouldStore`'s gate (unchanged, upstream
  ## of this call). Signs once via `tc.trust.sign` (no-op under `nonePolicy`
  ## or a no-secret policy), then fans out to every tier subject to the
  ## **put rule**: "write to tier t only if entry.attestation.isSome OR NOT
  ## t.verifyTrust" -- a pinned-keys-only consumer (no signing secret) must
  ## never overwrite a validly-attested entry with an unverifiable one. A
  ## skipped tier returns `cvUnauthorized` ("no write credential") so
  ## `cacheStats.published` stays honest.
  var e = entry
  tc.trust.sign(e)
  result = @[]
  for tier in tc.tiers:
    if not (e.attestation.isSome or not tier.verifyTrust):
      result.add (tier.name, cvUnauthorized)
      continue
    if tc.breakerTripped(tier.name):
      result.add (tier.name, cvOffline)
      continue
    let v = tier.backend.put(e)
    tc.tripBreaker(tier.name, v)
    result.add (tier.name, v)

proc putLocal*(tc: var TieredCache; entry: StoredEntry): TierVerdict =
  ## RFC-0005 B0 "Deferred remote puts": the SYNCHRONOUS half of a store —
  ## writes ONLY to tier 0 ("l1", pinned first by construction — RFC-0005
  ## "Local-fs root") at live finalize, applying the SAME put rule + circuit
  ## breaker `put` would for that one tier (signs once via `tc.trust.sign`,
  ## exactly like `put` — deterministic for both ed25519 and HMAC, so signing
  ## the SAME entry again at drain time, via the full `put`, produces
  ## byte-identical attestation bytes; no double-sign hazard). Tiers 1..N
  ## (remote) are the CALLER's job to queue and flush later via
  ## `drainPending` — never touched here. `("", cvMiss)` when `tc.tiers` is
  ## empty (defensive; unreachable in practice — every `TieredCache` has at
  ## least an "l1" tier by construction).
  if tc.tiers.len == 0:
    return (tier: "", verdict: cvMiss)
  var e = entry
  tc.trust.sign(e)
  let tier = tc.tiers[0]
  if not (e.attestation.isSome or not tier.verifyTrust):
    return (tier: tier.name, verdict: cvUnauthorized)
  if tc.breakerTripped(tier.name):
    return (tier: tier.name, verdict: cvOffline)
  let v = tier.backend.put(e)
  tc.tripBreaker(tier.name, v)
  (tier: tier.name, verdict: v)

proc drainPending*(tc: var TieredCache; pending: openArray[StoredEntry];
                    budget: int = high(int);
                    abandoned: proc(): bool {.closure.} = proc(): bool = false): seq[TierVerdict] =
  ## RFC-0005 B0 "Deferred remote puts": a caller (the runner's end-of-run
  ## join point, after the poll loop drains and before `persistLastRun` --
  ## wiring that lands with the first slice that has a real non-"l1" tier
  ## worth deferring for) does not call `put` inline at every live finalize
  ## for remote-destined entries; it QUEUES them (a plain `seq[StoredEntry]`
  ## the caller owns -- no new container type needed here) and drains the
  ## queue through this proc once, under the breaker (already `put`'s own
  ## behavior, unchanged) and a TOTAL BUDGET on the number of entries
  ## attempted this drain (bounding worst-case wall-clock on a slow-but-
  ## alive remote even when the breaker never trips -- N entries would
  ## otherwise cost up to N deadlines). Entries beyond the budget are
  ## simply never attempted this run: consistent with "a crash mid-run
  ## loses queued remote puts -- acceptable" (the loss is warmth, never
  ## correctness, since a future run re-publishes from its own live
  ## results).
  ##
  ## `abandoned` (RFC-0005 code-review SO2) is an injected predicate
  ## (default: never abandon), mirroring `resolveProbes`'s own "no real
  ## clock/signal dependency, call-counting/injected-predicate only"
  ## discipline (see that proc's doc comment) -- checked BETWEEN puts, so a
  ## pending shutdown stops the drain immediately rather than finishing out
  ## whatever remains of `pending`/`budget`. Exactly like a plan-time
  ## abandoned prefetch, an abandoned drain degrades to "never attempted"
  ## for the untouched remainder, not a partial/best-effort attempt --
  ## remote warmth lost this way is the SAME acceptable loss `budget`
  ## already documents, just triggered by a shutdown instead of a budget
  ## exhaustion. The production caller wires `proc(): bool =
  ## signals.shutdownRequested().isSome` (api.nim) -- the SAME global,
  ## level-triggered query the plan-time prefetch/consult loops already
  ## use, so a shutdown observed by ANY installSignals=true Supervisor in
  ## the process (not just this run's own) stops the drain too.
  result = @[]
  var attempted = 0
  for entry in pending:
    if attempted >= budget: break
    if abandoned(): break
    result.add tc.put(entry)
    inc attempted
