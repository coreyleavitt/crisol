## cacheregistry.nim — RFC-0005 A2b: `CacheRuntime` + `localOnlyCache`;
## RFC-0005 A3a: `BackendRegistry` + scheme-resolved `buildBackend`.
##
## The cache-side bundle `realSeams`/`api.nim` receive (RFC-0005 "Wiring").
## A2b shipped ONLY the local-only factory; `CacheSecrets` and
## `configuredCache` belong to their OWN later slices (C-dep/A3c) per the
## RFC's stage list — building them now, with no `cache-trust`/`remote-cache`
## KDL parser yet (A3c-i/C4), would be dormant substrate.
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
##
## ## `BackendRegistry` (RFC-0005 A3a)
##
## Resolves a `types.RemoteTier`'s `url` SCHEME (the substring before
## `"://"`) to a `CacheBackend`, via factories registered per scheme —
## "adding a transport = one file + one `registerBackend(scheme, factory)`"
## (RFC-0005 "BackendRegistry, serializer, telemetry"). `RemoteTier` itself
## lives in `types.nim` (not here — `config.nim` must not import the cache
## modules); its KDL *parser* is A3c-i, but `buildBackend` is a fully live
## consumer of the type TODAY, exercised with hand-built values — the same
## bottom-up pattern `Tier`/`TieredCache` used in A1, ahead of A3c's KDL
## wiring.
##
## `productionRegistry()` registers ONLY `"file"` in A3a (`http`/`https`/`s3`
## arrive with Stage C's `HttpFetcher`/S3 adapters — registering a scheme
## with no adapter built yet would be dormant). `testRegistry()` is
## `productionRegistry()` PLUS `"memory"`/`"memorybytes"` — registered ONLY
## here: a typo'd `memory://` URL in production KDL must be a config error,
## never a silently-empty per-process tier (`cachememory.nim`'s own module
## doc already states this constraint). A `file://<dir>` remote tier is
## never auto-created and carries no soft cap (`autoCreate = false,
## maxEntries = 0`) — RFC-0005 "Local-fs root": a shared tier's cap is an
## O(n) `walkDir` per store, wrong for a shared root; the `l1`-name
## rejection and root-inside-stateDir check are `configuredCache`'s job
## (A3c-ii), not this scheme-resolution layer's.
##
## No `fetcher`/`HttpFetcher` parameter yet: that type does not exist until
## Stage C1's transport seam lands; `productionRegistry`/`testRegistry`
## grow that parameter when `http`/`https` registration arrives (a normal
## signature evolution across slices, same as `realSeams`'s own history).

import std/[options, os, strutils, tables]
import crisol/cacheport
import crisol/cachetier
import crisol/cachelocalfs
import crisol/cachememory
import crisol/cachewire
import crisol/cachetelemetry

export cachetelemetry

type
  BackendFactory* = proc(tier: RemoteTier; token: string): CacheBackend {.closure.}
    ## Typed config in, adapter out — captures nothing else (RFC-0005
    ## "Registry resolves by URL scheme").

  BackendRegistry* = object
    factories: Table[string, BackendFactory]

proc registerBackend*(reg: var BackendRegistry; scheme: string; factory: BackendFactory) =
  reg.factories[scheme] = factory

proc urlScheme(url: string): string =
  let idx = url.find("://")
  if idx < 0: "" else: url[0 ..< idx]

proc buildBackend*(reg: BackendRegistry; tier: RemoteTier; token: string): Option[CacheBackend] =
  ## Resolves the adapter by URL SCHEME. `none` when no factory is
  ## registered for the scheme (an unconfigured/typo'd scheme — the config
  ## layer, not this proc, decides whether that is fatal).
  let scheme = urlScheme(tier.url)
  if reg.factories.hasKey(scheme):
    some(reg.factories[scheme](tier, token))
  else:
    none(CacheBackend)

proc fileBackendFactory(tier: RemoteTier; token: string): CacheBackend =
  discard token  # file:// has no credential axis
  let root = tier.url["file://".len .. ^1]
  localFsBackend(root, autoCreate = false, maxEntries = 0)

proc productionRegistry*(): BackendRegistry =
  result = BackendRegistry()
  result.registerBackend("file", fileBackendFactory)

proc testRegistry*(): BackendRegistry =
  result = productionRegistry()
  result.registerBackend("memory", proc(tier: RemoteTier; token: string): CacheBackend =
    discard tier; discard token
    memory())
  result.registerBackend("memorybytes", proc(tier: RemoteTier; token: string): CacheBackend =
    discard tier; discard token
    memoryBytes(jsonCacheSerializer()))

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
