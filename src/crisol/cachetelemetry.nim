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
## `tekBackfillErr` from the RFC's inline sketch is deliberately NOT defined
## here: backfill does not exist until Stage A3a, which lands the arm
## alongside its producer (multi-tier `lookup`'s backfill-on-hit).  Shipping
## the arm now would be a consumer-less arm — exactly the dormant substrate
## the standing rules forbid.
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

  TelemetryEvent* = object
    case kind*: TelemetryEventKind
    of tekHit:
      tier*:        string
      durationMs*:  int64
    of tekMiss:
      verdicts*:    seq[TierVerdict]
    of tekRemoteErr:
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

const notConsultedDecisions = {cdmNotEligible, cdmGroupOptOut, cdmPolicyDisabled}
  ## RFC-0005 "Hit-rate telemetry" / `cachedispatch.inactiveDecision`'s own
  ## domain — the three `CacheDecision`s that mean "never consulted", not
  ## "consulted and did not hit".

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
    of tekRemoteErr:
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
