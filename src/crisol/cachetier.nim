## cachetier.nim — RFC-0005 A1: `TieredCache`, the pure lookup engine.
##
## `lookup` must NOT discard which tier hit, whether trust passed, or what
## each tier said — telemetry, `run/v2` provenance, the 100%-error
## diagnostic, and the backfill rule (Stage A3a) all need it. Hence
## `CacheLookup.verdicts`: one per tier CONSULTED, in search order.
##
## **A1 scope is deliberately SINGLE-TIER** (`tc.tiers[0]` only) —
## RFC-0005's Stage list assigns the general N-tier waterfall +
## backfill-on-hit + the verified-bit backfill rule + the put rule + the
## per-tier circuit breaker to **A3a**, which re-touches this exact file
## with its own tests (the exhaustive 2×2×2 backfill matrix + 2×2 put
## matrix, via a controllable mock `TrustPolicy` — `nonePolicy.verify`
## always returns `cvOk`, so the security-meaningful multi-tier cases
## cannot be exercised until A3a's mock exists). Writing the general loop
## now, un-exercised by any multi-tier test, would be exactly the dormant
## substrate the standing rules forbid — so `lookup`/`put` fail loudly
## (`doAssert`) rather than silently mis-serving a second tier if one is
## ever configured before A3a lands (nothing in A1 can configure one: KDL
## remote-tier parsing is A3c).
##
## `TieredCache` is a PURE lookup engine — no `TelemetrySink` field (that
## lives on `CacheRuntime`, Stage A2b): telemetry emission is a translation
## concern belonging to the `realSeams` adapter, exactly where an
## observation of the call belongs, not to the engine itself.

import std/options
import crisol/cacheport

type
  Tier* = object
    name*: string
      ## Deployer label: `"l1"` (pinned, Stage A2a) | the KDL remote-cache
      ## name (Stage A3c). NOT `CacheBackend.scheme` (the adapter kind).
    backend*: CacheBackend
    backfillOnHit*: bool
      ## Write to THIS tier when a DOWNSTREAM tier serves the hit. Consumed
      ## starting A3a; A1's single-tier `lookup`/`put` never backfills
      ## (there is no downstream tier to backfill FROM).
    verifyTrust*: bool
      ## Reject entries READ from this tier that fail `TrustPolicy`; also:
      ## PUT here only attested entries (the A3a put rule).

  TieredCache* = object
    tiers*: seq[Tier]
      ## L1 → L2 → L3, searched in order. A1: `len <= 1`.
    trust*: TrustPolicy
      ## ONE policy per cache — shared by every `verifyTrust` tier (a
      ## backfilled entry is re-stored WITH the attestation it arrived
      ## with, valid at the destination only under the SAME policy).

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

proc lookup*(tc: var TieredCache; key: SoundnessKey): CacheLookup =
  ## See the module doc comment for the A1 single-tier scope note.
  doAssert tc.tiers.len <= 1,
    "cachetier.lookup: multi-tier waterfall is RFC-0005 Stage A3a, not yet built"
  if tc.tiers.len == 0:
    return CacheLookup(hit: none(TierHit), verdicts: @[])

  let tier = tc.tiers[0]
  let fetched = tier.backend.get(key)
  if fetched.verdict != cvOk:
    return CacheLookup(hit: none(TierHit), verdicts: @[(tier.name, fetched.verdict)])

  # Trust verify runs for the `verified` bit even on a non-`verifyTrust`
  # tier (one pure local computation over bytes already in hand, no I/O) —
  # it is meaningful only under a real policy (nonePolicy is trivially ok).
  let verifyVerdict = tc.trust.verify(fetched.value)
  let verified = verifyVerdict == cvOk

  if tier.verifyTrust and verifyVerdict in trustVerdicts:
    # Never serve a failed entry: this tier's specific trust code is the
    # recorded verdict, not a generic miss (RFC-0005 "lookup (waterfall)").
    return CacheLookup(hit: none(TierHit), verdicts: @[(tier.name, verifyVerdict)])

  let hit = TierHit(result: fetched.value.result, tier: tier.name, verified: verified)
  CacheLookup(hit: some(hit), verdicts: @[(tier.name, cvOk)])

proc put*(tc: var TieredCache; entry: StoredEntry): seq[TierVerdict] =
  ## See the module doc comment for the A1 single-tier scope note — the put
  ## rule (`entry.attestation.isSome or not t.verifyTrust`) is A3a's.
  doAssert tc.tiers.len <= 1,
    "cachetier.put: the multi-tier put rule is RFC-0005 Stage A3a, not yet built"
  if tc.tiers.len == 0:
    return @[]

  var e = entry
  tc.trust.sign(e)  # no-op under nonePolicy; sets e.attestation under a real policy
  let tier = tc.tiers[0]
  @[(tier.name, tier.backend.put(e))]
