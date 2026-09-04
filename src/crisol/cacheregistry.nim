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
##
## RFC-0005 B2a: `CacheRuntime.sink` is `TelemetrySink[TelemetryEvent]` —
## the real event type (`cachetelemetry.nim`), replacing A2b's placeholder
## `CacheEvent`.  `localOnlyCache` still defaults to `NilSink` (a purely-
## local run with no `--cache-stats`/InMemorySink override pays nothing for
## observability it never asked for); a caller that wants telemetry
## overrides `.sink` on the returned `CacheRuntime`.

import std/os
import crisol/cacheport
import crisol/cachetier
import crisol/cachelocalfs
import crisol/cachetelemetry

export cachetelemetry

type
  CacheRuntime* = object
    ## The cache-side bundle `realSeams`/`api.nim` receive (one place for
    ## growth; no dispose — RFC-0005 "Wiring").
    cache*: TieredCache
    sink*:  TelemetrySink[TelemetryEvent]
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
    sink:      NilSink[TelemetryEvent](),
    localRoot: root,
  )
