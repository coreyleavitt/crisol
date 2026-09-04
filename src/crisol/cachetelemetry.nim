## cachetelemetry.nim — RFC-0005 B2a: telemetry events + stats aggregation.
##
## The event vocabulary the `realSeams` load/store adapters and `lookupAtPlan`
## emit through a `cacheport.TelemetrySink[TelemetryEvent]`, plus the pure
## fold that turns a run's collected events (and per-result `CacheDecision`s)
## into a `CacheStats` summary (RFC-0005 "Hit-rate telemetry").
##
## **No dormant enum arms.** Every `TelemetryEventKind` arm defined here has
## a live producer THIS slice:
##   - `tekHit`        — `cachedispatch.lookupAtPlan`, a genuine (non-
##                        diagnostic) cache-level hit.
##   - `tekMiss`        — `cachedispatch.lookupAtPlan`, a genuine consulted
##                        lookup that missed.
##   - `tekRemoteErr`   — `cachedispatch.realSeams`'s `store` closure, a put
##                        returning a transport-class verdict (today: the
##                        local "l1" tier's put failures — `cvOffline`/
##                        `cvTimeout`/`cvUnauthorized`; see `transportVerdicts`
##                        in `cacheport.nim`).
##   - `tekPublish`     — `cachedispatch.realSeams`'s `store` closure, a
##                        successful put.
##   - `tekVerifyFail`  — `api.verifyCachePass`, the landed `--verify-cache`
##                        (B3c) divergence path.
##   - `tekBackfillErr` — RFC-0005 A3a: `backfillErrEvents`, a pure
##                        translation of `cachetier.CacheLookup.backfillVerdicts`
##                        (the multi-tier `lookup`'s backfill-on-hit writes)
##                        into events, mirroring `realSeams.store`'s own
##                        `v in transportVerdicts` filter for `tekRemoteErr`.
##                        `TieredCache` itself stays a pure engine with no
##                        sink (see `cachetier.nim`'s module doc) — the
##                        actual `sink.emit` call site for a LIVE run is
##                        `realSeams.load` (Stage A3b, the very next slice),
##                        exactly the split B1a's `explainMiss` already used
##                        (a pure, exhaustively-tested function ships with
##                        its data producer; the live call site follows).
##
## **`lookupAtPlan` emits, not `realSeams.load`.** The RFC's inline sketch
## shows hit/miss emission inside `realSeams`'s `load` closure. That closure
## is ALSO invoked by `lookupAtPlan`'s flag-gated *diagnostic* consult for a
## non-`edRunFresh` entrypoint (RFC-0005 B1c, `--explain-miss`'s "your flags
## changed" scenario) — a read-only probe for `.explain`, not a real lookup.
## Emitting inside `load` would count every diagnostic consult as a real
## hit/miss and dilute `cacheStats`. `lookupAtPlan` is the one call site that
## knows which path it is on, so it owns the emission (see that proc's body
## in `cachedispatch.nim`); `realSeams.load` itself stays a pure adapter with
## no sink access on the read side. The store side has no such split — every
## `cache.seams.store` call is a genuine put — so `tekPublish`/`tekRemoteErr`
## stay in `realSeams.store`, exactly where the RFC sketch places them.

import std/sequtils
import std/tables
import crisol/cacheport
import crisol/cachetier

export cacheport
export cachetier

# ---------------------------------------------------------------------------
# TelemetryEvent — the variant object (the codebase's kind-dependent-fields
# idiom, cf. GroupSelection, types.nim).
# ---------------------------------------------------------------------------

type
  TelemetryEventKind* = enum
    tekHit
    tekMiss
    tekRemoteErr
    tekPublish
    tekVerifyFail
    tekBackfillErr

  TelemetryEvent* = object
    case kind*: TelemetryEventKind
    of tekHit:
      tier*:        string
      durationMs*:  int64
    of tekMiss:
      verdicts*:    seq[TierVerdict]
    of tekRemoteErr, tekBackfillErr:
      putTier*:     string
      putVerdict*:  CacheVerdict
    of tekPublish:
      publishedTo*: string
    of tekVerifyFail:
      path*:        string

# ---------------------------------------------------------------------------
# InMemorySink — the test double (RFC-0005 "InMemorySink is the test double").
# ---------------------------------------------------------------------------

type
  InMemorySink* = ref object
    ## Collects every event emitted through the `TelemetrySink[TelemetryEvent]`
    ## it hands out via `sink()`. A `ref object` so the closure captured by
    ## that sink and the test's own handle observe the SAME growing seq.
    events*: seq[TelemetryEvent]

proc newInMemorySink*(): InMemorySink =
  InMemorySink(events: @[])

proc sink*(m: InMemorySink): TelemetrySink[TelemetryEvent] =
  ## Adapts the collector to the `cacheport.TelemetrySink[TelemetryEvent]`
  ## contract expected by `CacheRuntime.sink` / `CacheContext.sink`.
  TelemetrySink[TelemetryEvent](emit: proc(ev: TelemetryEvent) = m.events.add ev)

# ---------------------------------------------------------------------------
# backfillErrEvents — the tekBackfillErr producer (RFC-0005 A3a).
# ---------------------------------------------------------------------------

proc backfillErrEvents*(l: CacheLookup): seq[TelemetryEvent] =
  ## Pure translation of a lookup's backfill writes into events: one
  ## `tekBackfillErr` per `backfillVerdicts` entry whose verdict is
  ## transport-class (`cvOffline`/`cvTimeout`/`cvUnauthorized`) — mirroring
  ## `realSeams.store`'s existing `v in transportVerdicts` filter for the
  ## primary-put `tekRemoteErr` (RFC "the backfill-failure path in the
  ## multi-tier lookup" — `cachetier.lookup`'s backfill loop is the DATA
  ## producer via `CacheLookup.backfillVerdicts`; this is the EVENT
  ## producer). A successful backfill (`cvOk`) or one skipped by the
  ## verified-bit rule (never recorded in `backfillVerdicts` at all) is
  ## never an event — only a genuine write failure is.
  for tv in l.backfillVerdicts:
    if tv.verdict in transportVerdicts:
      result.add TelemetryEvent(kind: tekBackfillErr, putTier: tv.tier, putVerdict: tv.verdict)

# ---------------------------------------------------------------------------
# CacheStats — the aggregate (RFC-0005 "Hit-rate telemetry").
# ---------------------------------------------------------------------------

type
  CacheStats* = object
    l1Hits*:       int
    remoteHits*:   int
      ## Always 0 until a remote tier exists (Stage A3a) — no producer today.
    misses*:       int
    remoteErrors*: int
    total*:        int
      ## Lookups actually consulted: every per-result `CacheDecision` NOT in
      ## `notConsultedDecisions` (RFC: "hit + keyMiss + recomputeMiss +
      ## stored + hermeticityDegraded + flaky + closureUnrecorded +
      ## trust-rejected").
    notConsulted*: int
      ## `cdmNotEligible` / `cdmGroupOptOut` / `cdmPolicyDisabled` — kept OUT
      ## of `total` so `hitPct` is not diluted by e.g. `cacheable #false`
      ## groups (RFC-0005 "Hit-rate telemetry").
    hitPct*:       float
      ## `(l1Hits + remoteHits) / total * 100`; `0.0` (never NaN) when
      ## `total == 0`.
    wallSavedMs*:  int64
      ## Sum of served hits' historical `run.durationUs`, rendered as ms.
    published*:    int
    verifyFails*:  int

const notConsultedDecisions* = {cdmNotEligible, cdmGroupOptOut, cdmPolicyDisabled}
  ## RFC-0005 "Hit-rate telemetry" / `cachedispatch.inactiveDecision`'s own
  ## domain — the three `CacheDecision`s that mean "never consulted", not
  ## "consulted and did not hit". Exported since RFC-0005 A3b: `jsonout`
  ## reuses this SAME set as the presence gate for the per-result
  ## `cacheLookup` wire field (`EntrypointResult.cacheLookup`'s zero value,
  ## `cvOk`, is ambiguous between "hit" and "never consulted" — presence on
  ## the wire is keyed off `cacheDecision` instead, one source of truth for
  ## "was this entrypoint's cache actually consulted").

proc aggregateCacheStats*(events: seq[TelemetryEvent];
                          decisions: seq[CacheDecision]): CacheStats =
  ## Pure fold. Two independent inputs, matching what a run naturally
  ## produces:
  ##   - `events`    — everything collected by an `InMemorySink` (or the
  ##                   production summary sink, Stage B2b) over one run:
  ##                   `tekHit`/`tekMiss` from `lookupAtPlan`'s real (non-
  ##                   diagnostic) consult, `tekPublish`/`tekRemoteErr` from
  ##                   `realSeams.store`, `tekVerifyFail` from the
  ##                   `--verify-cache` pass.
  ##   - `decisions` — every `EntrypointResult.cacheDecision` this run
  ##                   produced (one per entrypoint, `runner.execute`'s own
  ##                   bookkeeping — NOT re-derived from `events`).
  ##
  ## `l1Hits`/`total`/`notConsulted` are decision-sourced: a `CacheDecision`
  ## is the run's own authoritative record of what actually happened to an
  ## entrypoint (served vs. reran), immune to a subtlety `events` alone
  ## cannot resolve — a `tekHit` fires on every cache-level hit, including
  ## the rare rfc-0007 A1d-ii case where the recomputed outcome invalidates
  ## it (`cdmRecomputeMiss`): that entrypoint reran live and is correctly
  ## NOT one of the `l1Hits` a reader can trust the binary came straight
  ## from cache. `wallSavedMs` stays event-sourced (only a `tekHit` carries
  ## the historical duration) — in that same rare case it may over-count by
  ## one entry's duration; undetected by this slice's test vectors and
  ## follow-on if it ever matters in practice.
  ##
  ## `remoteHits` is hardcoded 0: no producer exists before a remote tier
  ## (Stage A3a).
  var l1Hits, remoteErrors, published, verifyFails: int
  var wallSavedMs: int64
  for ev in events:
    case ev.kind
    of tekHit:
      wallSavedMs += ev.durationMs
    of tekMiss:
      discard  # miss count is decision-sourced (see `misses` below)
    of tekRemoteErr, tekBackfillErr:
      inc remoteErrors
    of tekPublish:
      inc published
    of tekVerifyFail:
      inc verifyFails

  l1Hits = decisions.filterIt(it == cdmHit).len
  let remoteHits = 0
  let notConsulted = decisions.filterIt(it in notConsultedDecisions).len
  let total = decisions.len - notConsulted
  let misses = max(0, total - l1Hits - remoteHits)
  let hitPct = if total == 0: 0.0 else: (l1Hits + remoteHits).float / total.float * 100.0

  CacheStats(
    l1Hits:       l1Hits,
    remoteHits:   remoteHits,
    misses:       misses,
    remoteErrors: remoteErrors,
    total:        total,
    notConsulted: notConsulted,
    hitPct:       hitPct,
    wallSavedMs:  wallSavedMs,
    published:    published,
    verifyFails:  verifyFails,
  )

# ---------------------------------------------------------------------------
# Per-tier 100%-error diagnostic — RFC-0005 B2b ("Hit-rate telemetry":
# "crisol additionally writes a stderr warning when a configured remote tier
# errored on every call in a run ... attributed per tier via
# CacheLookup.verdicts even when a later tier served").
# ---------------------------------------------------------------------------

const tierErrorVerdicts* = transportVerdicts + trustVerdicts + {cvCorrupt}
  ## The RFC's own list for this diagnostic: "'errored' includes the trust
  ## codes and cvCorrupt" in addition to the transport-class verdicts
  ## (`cvOffline`/`cvTimeout`/`cvUnauthorized`) `remoteErrors` already
  ## counts. Deliberately EXCLUDES `cvMiss` (a normal cold-cache miss is not
  ## an error) and `cvVersionSkew` (a storage-format mismatch, not a
  ## backend/trust failure) — the RFC's own enumerated set, not "every
  ## non-cvOk verdict".

type
  TierErrorReport* = object
    ## One tier that errored on every read this run consulted it for.
    tier*:  string
    calls*: int  ## the (nonzero) number of consulted reads — always equals
                 ## the error count by construction (see `erroredTiers`).

proc erroredTiers*(events: seq[TelemetryEvent]): seq[TierErrorReport] =
  ## Pure fold, mirroring `aggregateCacheStats`'s shape: tallies, per tier
  ## name, how many reads it was consulted for and how many of those came
  ## back with a verdict in `tierErrorVerdicts`.
  ##
  ## **Scope note (this slice ships a single "l1" tier only — Stage A3a
  ## lands the multi-tier waterfall):** the RFC's prose frames this as "a
  ## configured REMOTE tier errored on every call", but no remote tier can
  ## exist before A3a lands `cacheregistry.configuredCache` (A3c) — there is
  ## nothing "remote" to attribute yet. Rather than gate this on a tier
  ## label that cannot occur, the fold is written generically against
  ## whatever tiers `events` actually names: today that is only ever "l1",
  ## so a broken/misconfigured local-fs root (e.g. a state dir the process
  ## cannot read) already gets the SAME honest diagnosis the RFC wants for a
  ## dead remote — and once A3a/A3c add real remote tiers, this proc needs
  ## no changes to start covering them (each tier already carries its own
  ## name on every `TierVerdict`/`tekHit.tier`).
  ##
  ## A read is attributed via:
  ##   - `tekHit.tier`         — the serving tier's verdict was `cvOk` (never
  ##                             an error) — contributes to that tier's call
  ##                             count only.
  ##   - `tekMiss.verdicts`    — one `TierVerdict` per tier CONSULTED on the
  ##                             miss (`cachetier.CacheLookup.verdicts`,
  ##                             threaded verbatim into the event) —
  ##                             contributes to both the call count and,
  ##                             when the verdict is in `tierErrorVerdicts`,
  ##                             the error count.
  ## Store-side events (`tekPublish`/`tekRemoteErr`/`tekBackfillErr`) are
  ## deliberately NOT folded in here: the RFC's "attributed per tier via
  ## CacheLookup.verdicts" names the READ path specifically; `remoteErrors`
  ## already reports the write-side (primary put + backfill) failure count
  ## in aggregate.
  var totals, errors: OrderedTable[string, int]
  for ev in events:
    case ev.kind
    of tekHit:
      totals.mgetOrPut(ev.tier, 0).inc
    of tekMiss:
      for tv in ev.verdicts:
        totals.mgetOrPut(tv.tier, 0).inc
        if tv.verdict in tierErrorVerdicts:
          errors.mgetOrPut(tv.tier, 0).inc
    of tekRemoteErr, tekBackfillErr, tekPublish, tekVerifyFail:
      discard
  for tier, calls in totals:
    if calls > 0 and errors.getOrDefault(tier, 0) == calls:
      result.add TierErrorReport(tier: tier, calls: calls)

proc tierErrorWarning*(t: TierErrorReport): string =
  ## Pure formatter for the stderr warning `erroredTiers` results drive
  ## ("a tier that rejects 100% of reads is as dead as one that times out" —
  ## RFC-0005 "Hit-rate telemetry"). Callers write this unconditionally to
  ## stderr (no `--quiet` exists in crisol; RFC "Output channels").
  "cache tier '" & t.tier & "' errored on every consulted read this run (" &
  $t.calls & "/" & $t.calls & ") — treat it as misconfigured or unreachable"
