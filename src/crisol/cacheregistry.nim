## cacheregistry.nim — RFC-0005 A2b: `CacheRuntime` + `localOnlyCache`.
##
## The cache-side bundle `realSeams`/`api.nim` receive (RFC-0005 "Wiring").
## A2b ships ONLY the local-only factory — `BackendRegistry`, `CacheSecrets`,
## `configuredCache`, `productionRegistry`/`testRegistry` belong to their
## OWN later slices (A3a/A3c/C-dep) per the RFC's stage list; building them
## now, with nothing yet able to configure a remote tier, would be exactly
## the dormant substrate the standing rules forbid.
##
## `localOnlyCache(stateDir, maxEntries)` builds the single-tier "l1"
## local-fs cache that makes a purely-local run behaviorally identical to
## RFC-0004: `TieredCache{@[l1Tier], nonePolicy()}` + a silent sink.

import std/os
import crisol/cacheport
import crisol/cachetier
import crisol/cachelocalfs

type
  CacheEvent* = object
    ## A2b placeholder event type. `cacheport.TelemetrySink[E]` is generic
    ## (see that module's doc comment on why); the real event type
    ## (`TelemetryEvent`, a variant covering tekHit/tekMiss/tekPublish/…)
    ## is owned by `cachetelemetry.nim`, which does not exist until Stage
    ## B2a. Rather than leak `TelemetrySink`'s generic parameter into
    ## `CacheRuntime` (and therefore into every caller of `realSeams`/
    ## `localOnlyCache`, none of which has any business naming an event
    ## type it will never construct in A2b), `CacheRuntime.sink` is pinned
    ## to `TelemetrySink[CacheEvent]` — a zero-field, uninstantiable-except-
    ## as-a-unit placeholder. Nothing in A2b constructs a `CacheEvent`
    ## value or calls `sink.emit`: `NilSink[CacheEvent]()` (its `emit` is
    ## `discard`) is the only value ever assigned, matching the RFC's "a
    ## purely-local run pays nothing for observability it never asked for."
    ## Stage B2a swaps this alias for the real `TelemetryEvent` and wires
    ## the `tekHit`/`tekMiss`/`tekPublish`/`tekRemoteErr` emit calls into
    ## `realSeams`' load/store adapters.

  CacheRuntime* = object
    ## The cache-side bundle `realSeams`/`api.nim` receive (one place for
    ## growth; no dispose — RFC-0005 "Wiring").
    cache*: TieredCache
    sink*:  TelemetrySink[CacheEvent]
    localRoot*: string
      ## RFC-0005 B1b: the LOCAL-FS root the explain-miss sidecar lives
      ## under (tier 0 / "l1" only — never a shared remote tier, which
      ## must not host per-host history). "" means no local root to write
      ## a sidecar against (e.g. a bare test runtime with no local-fs tier
      ## at all). NOT a general per-tier concept — the RFC pins the
      ## sidecar mechanism to tier 0 specifically.

proc localOnlyCache*(stateDir: string; maxEntries: int): CacheRuntime =
  ## Single-tier local-fs ("l1"), `nonePolicy`, `NilSink` — the default for
  ## every run with no remote tier configured (RFC-0005 "Local-fs root":
  ## L1 is never a URL; the tier name is pinned "l1").
  let root = stateDir / "cache"
  let l1 = Tier(
    name:          "l1",
    backend:       localFsBackend(root = root, autoCreate = true,
                                   maxEntries = maxEntries),
    backfillOnHit: false,  # A1 single-tier scope: no downstream tier to backfill from
    verifyTrust:   false,  # nonePolicy already verifies unconditionally cvOk
  )
  CacheRuntime(
    cache:     TieredCache(tiers: @[l1], trust: nonePolicy()),
    sink:      NilSink[CacheEvent](),
    localRoot: root,
  )
