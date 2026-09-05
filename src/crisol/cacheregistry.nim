## cacheregistry.nim — RFC-0005 A2b: `CacheRuntime` + `localOnlyCache`;
## RFC-0005 A3a: `BackendRegistry` + scheme-resolved `buildBackend`;
## RFC-0005 A3c-ii: `configuredCache`.
##
## The cache-side bundle `realSeams`/`api.nim` receive (RFC-0005 "Wiring").
## A2b shipped ONLY the local-only factory; A3a added the scheme-resolved
## registry with no consumer wiring it to a real KDL block yet. A3c-ii
## closes that loop: `configuredCache` builds a real multi-tier
## `TieredCache` from `CacheConfig.remotes` (A3c-i's parser) via `reg`,
## rejecting an `"l1"`-named remote and a `file://` root inside `stateDir`,
## resolving `verify-trust`'s default honestly (no `cache-trust` block
## parser exists before C4, so the policy is unconditionally "none" and the
## default is `false`). `CacheSecrets`/per-tier credentials remain a later
## slice (C-dep/C4) — the `file` scheme has no credential axis
## (`fileBackendFactory` already discards `token`), so nothing here is dead
## substrate: `configuredCache` passes `token = ""` to `buildBackend` today
## and grows a `secrets` parameter only when `http`/`s3` need one.
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
## `productionRegistry()` registered ONLY `"file"` through A3c-ii. RFC-0005
## C3b adds `"http"`/`"https"`/`"s3"` — both PARAMETERIZED by the SAME
## injected `HttpFetcher` (production default: `httpraw.rawHttpFetcher()`;
## E2E-3 injects a fake one instead, so a test can drive the real KDL ->
## `configuredCache` path with no socket). `testRegistry(fetcher)` is
## `productionRegistry(fetcher)` PLUS `"memory"`/`"memorybytes"` — registered
## ONLY here: a typo'd `memory://` URL in production KDL must be a config
## error, never a silently-empty per-process tier (`cachememory.nim`'s own
## module doc already states this constraint; C3a's `types.knownCacheSchemes`
## enforces the same thing one layer up, at config-PARSE time). A
## `file://<dir>` remote tier is never auto-created and carries no soft cap
## (`autoCreate = false, maxEntries = 0`) — RFC-0005 "Local-fs root": a
## shared tier's cap is an O(n) `walkDir` per store, wrong for a shared
## root; the `l1`-name rejection and root-inside-stateDir check are
## `configuredCache`'s job (A3c-ii), not this scheme-resolution layer's.
##
## ## `http`/`s3` factories (RFC-0005 C3b)
##
## `httpBackendFactory(fetcher)` captures ONLY the fetcher and calls
## `cachehttp.httpBackend(fetcher, base = tier.url, token)` per tier —
## `tier.url` IS the http(s) base url verbatim (RFC "`<base>/
## <storageFormatVersion>/<key>`"). `s3BackendFactory(fetcher)` splits
## `tier.url` (`s3://<bucket>[/<prefix>]`) and threads `tier.endpoint`/
## `tier.pathStyle` straight through to `caches3.s3Backend`, resolving
## `pathStyle`'s config-time default HERE ("`#true` iff `endpoint` is set")
## since `RemoteTier.pathStyle` stays `none` through C3a when the KDL never
## sets it; `token` is discarded (unsigned s3 has no credential axis at
## all). Per-tier bearer tokens ($CRISOL_CACHE_TOKEN[_<TIER>]) are resolved
## by `httpTokenFor` below and threaded into EVERY factory uniformly
## (matching `fileBackendFactory`'s existing `discard token` precedent) —
## only the http factory actually reads it.

import std/[options, os, strutils, tables]
import crisol/cacheport
import crisol/cachetier
import crisol/cachelocalfs
import crisol/cachememory
import crisol/cachewire
import crisol/cachehttp
import crisol/caches3
import crisol/httpraw
import crisol/cachetelemetry
import crisol/cachetrust

export cachetelemetry
# RFC-0005 C5a: re-exports `cachetrust`'s public surface -- notably its
# `PublicKey` re-export (itself re-exported from `sello`, needed to name
# `seq[PublicKey]` below) and `ed25519Policy`/`decodeSignSeedB64`/
# `decodePinnedKeyB64` -- so a caller of THIS module (e.g. a test building
# `CacheConfig`/`CacheSecrets` fixtures) never needs its own `import
# crisol/cachetrust` line. `cachetrust.nim` stays the only module with a
# bare `import sello`/`import nimcrypto`.
export cachetrust

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

proc splitS3Url(url: string): tuple[bucket, prefix: string] =
  ## RFC-0005 C3b: "splitting `RemoteTier.url` into these is the future
  ## registry factory's job" (`caches3.nim`'s own module doc) — `s3://
  ## <bucket>[/<prefix>]`. No further validation here: an empty bucket
  ## (`s3:///prefix`) is not a shape this registry rejects; `parseRemoteCache`
  ## already guarantees SOME non-empty scheme-tail reached this point.
  let rest = url["s3://".len .. ^1]
  let slashIdx = rest.find('/')
  if slashIdx < 0:
    (bucket: rest, prefix: "")
  else:
    (bucket: rest[0 ..< slashIdx], prefix: rest[slashIdx + 1 .. ^1])

proc httpBackendFactory(fetcher: HttpFetcher): BackendFactory =
  ## Captures ONLY `fetcher` (RFC-0005 "BackendFactory ... captures nothing
  ## else") — `base`/`token` come from the `RemoteTier`/token this factory
  ## is invoked with, per call.
  result = proc(tier: RemoteTier; token: string): CacheBackend =
    httpBackend(fetcher, base = tier.url, token = token)

proc s3BackendFactory(fetcher: HttpFetcher): BackendFactory =
  ## RFC-0005 C3b: `endpoint`/`path-style` come from the `RemoteTier`
  ## (C3a's parser); unsigned s3 has no credential axis at all (`token` is
  ## discarded — RFC "Secure-by-default": "Unsigned S3/MinIO has no
  ## transport-level write authorization" — never even attempted).
  ## `path-style`'s default ("`#true` iff `endpoint` is set", RFC
  ## "Configuration") is resolved HERE, not at config-parse time: a config
  ## file that never sets `path-style` leaves `RemoteTier.pathStyle` as
  ## `none` (C3a), and THIS is where that absence becomes a concrete
  ## `bool` for `s3Backend`'s plain-`bool` parameter.
  result = proc(tier: RemoteTier; token: string): CacheBackend =
    discard token  # unsigned -- no credential axis
    let (bucket, prefix) = splitS3Url(tier.url)
    s3Backend(fetcher, bucket = bucket, prefix = prefix,
              endpoint = tier.endpoint.get(""),
              pathStyle = tier.pathStyle.get(tier.endpoint.isSome))

proc productionRegistry*(fetcher: HttpFetcher = rawHttpFetcher()): BackendRegistry =
  result = BackendRegistry()
  result.registerBackend("file", fileBackendFactory)
  result.registerBackend("http", httpBackendFactory(fetcher))
  result.registerBackend("https", httpBackendFactory(fetcher))
  result.registerBackend("s3", s3BackendFactory(fetcher))

proc testRegistry*(fetcher: HttpFetcher): BackendRegistry =
  result = productionRegistry(fetcher)
  result.registerBackend("memory", proc(tier: RemoteTier; token: string): CacheBackend =
    discard tier; discard token
    memory())
  result.registerBackend("memorybytes", proc(tier: RemoteTier; token: string): CacheBackend =
    discard tier; discard token
    memoryBytes(jsonCacheSerializer()))

type
  CacheRuntime* = ref object
    ## The cache-side bundle `realSeams`/`api.nim` receive (one place for
    ## growth; no dispose — RFC-0005 "Wiring").
    ##
    ## **`ref` since A3c-ii (was `object`).** `realSeams` receives `rt` by
    ## value and keeps its OWN captured copy alive for the closures it
    ## returns (`cachedispatch.nim`'s `var rt = rt`) — that copy is where the
    ## per-run circuit breaker actually accumulates state across a run's
    ## `load`/`store` calls, entirely inside `realSeams`'s own closure
    ## environment. `api.runTestsWith`'s end-of-run deferred-put FLUSH
    ## (RFC-0005 "Deferred remote puts") needs to observe THAT SAME
    ## accumulated state (the breaker, and the queue of remote-destined
    ## entries below) from ITS OWN copy of `rt`, built before `realSeams` is
    ## ever called — a value type cannot do this (copying a `TieredCache`
    ## struct only shares backend closures' own captured environments, never
    ## the `breaker`/`pending` fields living directly on the struct). Making
    ## the WHOLE bundle a `ref` costs nothing at every existing call site
    ## (`CacheRuntime(...)` object-construction syntax already allocates on
    ## the heap for a `ref object`; field access/mutation through a `let`- or
    ## `var`-bound handle is unchanged) and requires editing no test.
    cache*: TieredCache
    sink*:  TelemetrySink[TelemetryEvent]
    localRoot*: string
      ## RFC-0005 B1b: the LOCAL-FS root the explain-miss sidecar lives
      ## under (tier 0 / "l1" only — never a shared remote tier, which
      ## must not host per-host history). "" means no local root to write
      ## a sidecar against (e.g. a bare test runtime with no local-fs tier
      ## at all). NOT a general per-tier concept — the RFC pins the
      ## sidecar mechanism to tier 0 specifically.
    pending*: seq[StoredEntry]
      ## RFC-0005 B0/A3c-ii "Deferred remote puts": entries a live finalize
      ## wrote to tier 0 ("l1") synchronously via `TieredCache.putLocal` AND
      ## destined for at least one remote tier (`cache.tiers.len > 1`) —
      ## queued here instead of fanning out inline. `api.runTestsWith`
      ## drains this ONCE, at the end-of-run join point (after the poll loop
      ## drains, before `persistLastRun`), via `cache.drainPending`, under
      ## the SAME circuit breaker the run's own lookups/puts already
      ## accumulated and a total attempt budget (`DefaultDeferredPutBudget`).
      ## Empty for the common single-tier (no remote configured) run — never
      ## populated, so `drainPending` is never even called (RFC "A purely-
      ## local run... behaviorally identical to RFC-0004").

type
  CacheSecrets* = object
    ## RFC-0005 C4 "Secrets come from the environment, are resolved once in
    ## `api.nim`, are then removed from the process environment, and are
    ## injected -- the cache modules never read env." `api.nim` builds
    ## this ONCE per `runTests`/`runTestsWith` call (via
    ## `resolveCacheSecrets`) and moves it into the `productionCacheDeps`
    ## closure; `configuredCache` (below) is the ONLY consumer.
    ##
    ## `hmacKey` (`$CRISOL_CACHE_HMAC_KEY`) is C4's field. `signSeedB64` (RFC-
    ## 0005 C5a: raw `$CRISOL_CACHE_SIGN_KEY`, base64 of the 32-byte ed25519
    ## seed, "" if absent) is decoded into a `sello.Seed` ON DEMAND, inside
    ## `buildTrustPolicy`'s "ed25519" branch below, via `cachetrust.
    ## decodeSignSeedB64` -- NOT eagerly here.
    ##
    ## **Judgment call (recorded):** the RFC's own inline sketch has
    ## `api.nim` decode straight to `Option[sello.Seed]` and move THAT into
    ## `CacheSecrets`/`ed25519Policy`. That does not typecheck through this
    ## codebase's ACTUAL plumbing: `productionCacheDeps` (below) resolves
    ## `CacheSecrets` ONCE and captures it in a `{.closure.}` `buildRuntime`
    ## whose type permits more than one call; Nim's move analysis (correctly)
    ## refuses to move a field out of a value shared by a closure's captured
    ## environment, since a second call would then observe an
    ## already-moved-from `Seed`. `sello.Seed`'s `=copy {.error.}` (by
    ## design -- see `sello/signing.nim`) forecloses the alternative of just
    ## copying it instead. Keeping the RAW STRING here (trivially copyable,
    ## exactly like `hmacKey` already is) and decoding it FRESH on every
    ## `buildTrustPolicy` call sidesteps the conflict entirely: each decode
    ## produces its own independent, freshly-owned `Option[Seed]` temporary,
    ## which is unconditionally safe to move into `ed25519Policy`'s `sink`
    ## parameter no matter how many times `buildTrustPolicy` runs. The ONE
    ## place the RFC's own "Keypair captured in the sign closure is
    ## destroyed when CacheRuntime drops" guarantee actually matters --
    ## the constructed `Keypair` inside `ed25519Policy`'s closure -- is
    ## unaffected: it is still built exactly once, there, per `TieredCache`.
    ## `defaultHttpToken`/`httpTokens` (RFC-0005 C3b): `$CRISOL_CACHE_TOKEN`
    ## / `$CRISOL_CACHE_TOKEN_<TIER>` bearer tokens for the `http`/`https`
    ## adapter (`s3` is unsigned -- no credential axis at all, so these are
    ## never even read for an `s3://` tier). `api.resolveCacheSecrets`
    ## captures BOTH before it scrubs the `CRISOL_CACHE_*` namespace, since
    ## the scrub runs BEFORE the KDL config (and therefore the configured
    ## tier NAMES) is even parsed -- there is no "look up by tier name" to
    ## do yet at that point. So `httpTokens` is keyed by the raw env-var
    ## SUFFIX as it appeared in the environment (e.g. `CRISOL_CACHE_TOKEN_
    ## MIRROR` -> key `"MIRROR"`), and `httpTokenFor` below re-derives that
    ## same suffix from a configured tier's NAME on demand, once `configuredCache`
    ## actually has one. `defaultHttpToken` is the bare (un-suffixed)
    ## `$CRISOL_CACHE_TOKEN`, the fallback for a tier whose own suffix was
    ## never set.
    hmacKey*:          Option[string]
    signSeedB64*:      string
    defaultHttpToken*: Option[string]
    httpTokens*:       Table[string, string]

proc tierEnvSuffix(tierName: string): string =
  ## RFC-0005 C3b: "`<TIER>` = the KDL tier name upper-cased with `-`->`_`".
  tierName.toUpperAscii.replace("-", "_")

proc httpTokenFor(secrets: CacheSecrets; tierName: string): string =
  ## The bearer token for one configured `http`/`https` tier: its own
  ## `$CRISOL_CACHE_TOKEN_<TIER>` if set, else the bare `$CRISOL_CACHE_TOKEN`
  ## fallback, else "" (no token configured at all -- `authHeaders` then
  ## sends no `Authorization` header, a legitimate public-read mirror).
  let suffix = tierEnvSuffix(tierName)
  if secrets.httpTokens.hasKey(suffix):
    secrets.httpTokens[suffix]
  else:
    secrets.defaultHttpToken.get("")

proc buildTrustPolicy(trust: TrustConfig; secrets: CacheSecrets): TrustPolicy =
  ## RFC-0005 C4 "Misconfiguration is a config error, not a silent dead
  ## tier": resolves `CacheConfig.trust` (the parsed `cache-trust { }`
  ## block) + the env-resolved `CacheSecrets` into a real `TrustPolicy`,
  ## raising `CrisolError(cekConfig)` for a policy that cannot actually
  ## verify/sign -- never a silently-inert trust layer. Called
  ## UNCONDITIONALLY by `configuredCache` below, even when `cfg.remotes`
  ## is empty: a `cache-trust` block describes what a fleet's shared
  ## cache WILL use, exactly like a `remote-cache` block, so an
  ## unsatisfiable policy (hmac with no resolvable secret) is a
  ## misconfiguration regardless of whether a remote tier has been added
  ## yet.
  case trust.policy
  of "none":
    nonePolicy()
  of "hmac":
    if secrets.hmacKey.isNone:
      raise newCrisolError(cekConfig,
        "config: cache-trust policy 'hmac' requires $CRISOL_CACHE_HMAC_KEY to be set")
    hmacPolicy(secrets.hmacKey.get, trust.keyId)
  of "ed25519":
    # RFC-0005 C5a: zero `pinned-key`s is a config error (an unverifiable,
    # trust-nobody policy is exactly the "silent dead tier" the RFC forbids)
    # -- checked BEFORE decoding, so the error names the real problem
    # (nothing pinned) rather than an incidental empty-loop no-op. A
    # missing `secrets.signSeedB64` is NOT rejected here: a read-only
    # (verify-only) participant is a legitimate deployment (RFC "no-seed
    # verify-only mode").
    if trust.pinnedKeys.len == 0:
      raise newCrisolError(cekConfig,
        "config: cache-trust policy 'ed25519' requires at least one 'pinned-key'")
    var pinned: seq[PublicKey] = @[]
    for raw in trust.pinnedKeys:
      let pk = decodePinnedKeyB64(raw)
      if pk.isNone:
        raise newCrisolError(cekConfig,
          "config: cache-trust 'pinned-key' is not a valid base64 32-byte " &
          "ed25519 public key: '" & raw & "'")
      pinned.add pk.get
    ed25519Policy(decodeSignSeedB64(secrets.signSeedB64), pinned)
  else:
    # Unreachable in practice: config.nim's parser already restricts
    # `policy` to {none, hmac, ed25519}. Kept as a defensive fail-closed
    # branch rather than an unchecked `case` -- never silently downgrade
    # an unrecognized policy string to `none`.
    raise newCrisolError(cekConfig,
      "config: cache-trust: unknown policy '" & trust.policy & "'")

const DefaultDeferredPutBudget* = 1000
  ## RFC-0005 "Deferred remote puts" requires the end-of-run flush be bounded
  ## by "a total budget" but pins no concrete number (no CLI/config knob is
  ## specified for tuning it either — a follow-on once real deployments need
  ## one). 1000 is a deliberately generous, arbitrary bound: it makes the
  ## "never blocks unboundedly" property concrete (worst case, 1000 ×
  ## the per-call deadline of a slow-but-alive remote) without constraining
  ## any real run — a single invocation storing 1000 fresh (non-cached)
  ## entries is already an extreme outlier for one `crisol run`.

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

proc rootInsideStateDir(root, stateDir: string): bool =
  ## `root` (a configured `file://` remote's directory) resolves equal to,
  ## or nested under, `stateDir` — RFC-0005 "Local-fs root": such a tier
  ## would recurse the L1 cache (`clean.nim`'s `pruneDir` walks the whole
  ## `stateDir`, not just `stateDir/cache`, so ANY location inside it is
  ## fair game for pruning). Absolute + normalized on both sides so a
  ## relative config value and trailing separators cannot dodge the check.
  let a = normalizedPath(absolutePath(root))
  let b = normalizedPath(absolutePath(stateDir))
  a == b or a.startsWith(b & DirSep)

proc configuredCache*(cfg: CacheConfig; stateDir: string; maxEntries: int;
                      reg: BackendRegistry; secrets: CacheSecrets;
                      sink: TelemetrySink[TelemetryEvent]): CacheRuntime =
  ## RFC-0005 A3c-ii/C4: build the run's `TieredCache` from parsed KDL
  ## (`CacheConfig.remotes` — `types.RemoteTier` — and, since C4,
  ## `CacheConfig.trust` — `types.TrustConfig`), via `reg` (scheme ->
  ## adapter) and `secrets` (env-resolved, `api.nim`'s job — see
  ## `CacheSecrets`'s doc comment). Returns `localOnlyCache(stateDir,
  ## maxEntries)` unchanged when `cfg.remotes` is empty — a purely-local
  ## run stays behaviorally identical to RFC-0004 (RFC "What does not
  ## change") EVEN when a `cache-trust` policy is configured: signing
  ## local-only entries that no tier will ever verify (`l1.verifyTrust` is
  ## always `false`) would cost real CPU/storage for zero security
  ## benefit, so `localOnlyCache` keeps its own `nonePolicy()` regardless.
  ##
  ## **Invoked inside the plan `try`, BEFORE `acquireLock`** (`api.nim`'s
  ## `runTestsWith`): every rejection below raises `CrisolError(cekConfig)`,
  ## caught by the SAME structural-failure path a bad group/glob already
  ## uses, so a misconfigured remote-cache/cache-trust block is a plan-time
  ## exit 3, never a lock-then-fail.
  ##
  ## Rejects (RFC "Misconfiguration is a config error, not a silent dead
  ## tier"):
  ##   - a remote named `"l1"` — reserved for the pinned local tier.
  ##   - a `file://` root that resolves inside `stateDir` (`clean` would
  ##     prune it out from under a live remote — see `rootInsideStateDir`).
  ##   - a url whose scheme `reg` cannot resolve (`buildBackend` -> `none`):
  ##     an unregistered/typo'd/not-yet-shipped scheme (http/s3 arrive in
  ##     Stage C; `memory://` is registered ONLY by `testRegistry`) is a
  ##     config error here, per `cacheregistry`'s own module doc ("the
  ##     config layer... decides whether it's fatal") — never a silently
  ##     inert tier.
  ##   - **C4:** `cache-trust policy "hmac"` with no resolvable
  ##     `$CRISOL_CACHE_HMAC_KEY` (`buildTrustPolicy`, above) — checked
  ##     UNCONDITIONALLY, even when `cfg.remotes` is empty (a `cache-trust`
  ##     block describes a fleet's shared-cache intent, same as
  ##     `remote-cache`).
  ##   - **C4:** an *explicit* `verify-trust #true` on a remote tier under
  ##     `cache-trust policy "none"` (an unsatisfiable request: `nonePolicy`
  ##     cannot verify anything, so honoring it silently would make every
  ##     read on that tier a silent miss, indistinguishable from a cold
  ##     cache).
  ##   - **C5a:** `cache-trust policy "ed25519"` with zero `pinned-key`s, or
  ##     any `pinned-key` that does not decode to a valid base64 32-byte
  ##     ed25519 public key (`buildTrustPolicy`, above) — a MISSING
  ##     `$CRISOL_CACHE_SIGN_KEY` is NOT one of these: a read-only
  ##     (verify-only) participant is a legitimate deployment.
  ##
  ## **`verify-trust` default (RFC, round 3, C4-live): `cache-trust.policy
  ## != "none"`.** An explicit `verify-trust #true`/`#false` on a remote
  ## tier always wins (`RemoteTier.verifyTrust.get(...)` below) except the
  ## `#true`-under-`none` combination above, which is rejected outright.
  let trust = buildTrustPolicy(cfg.trust, secrets)
  let defaultVerifyTrust = cfg.trust.policy != "none"

  if cfg.remotes.len == 0:
    return localOnlyCache(stateDir, maxEntries)

  let root = stateDir / "cache"
  var tiers = @[Tier(
    name:          "l1",
    backend:       localFsBackend(root = root, autoCreate = true,
                                   maxEntries = maxEntries),
    # `backfillOnHit: true` here (unlike `localOnlyCache`'s single-tier
    # `false`) -- with at least one remote tier below, a remote HIT must
    # backfill l1 (RFC-0005 "TieredCache — the composition, with
    # provenance": backfill targets are UPSTREAM tiers of the one that
    # served; l1, at index 0, is upstream of every remote here). In the
    # single-tier case there is no downstream tier that could ever serve a
    # hit for l1 to backfill FROM, so `localOnlyCache` leaves it `false`
    # (a dead flag there either way) -- this proc reaches this branch only
    # once `cfg.remotes` is non-empty, so the flag is live here.
    backfillOnHit: true,
    verifyTrust:   false,
  )]

  for remote in cfg.remotes:
    if remote.name == "l1":
      raise newCrisolError(cekConfig,
        "config: remote-cache '" & remote.name & "': the name 'l1' is " &
        "reserved for the local cache tier")

    if remote.verifyTrust == some(true) and cfg.trust.policy == "none":
      raise newCrisolError(cekConfig,
        "config: remote-cache '" & remote.name & "': 'verify-trust #true' " &
        "requires a 'cache-trust' policy other than 'none'")

    if remote.url.startsWith("file://"):
      let fsRoot = remote.url["file://".len .. ^1]
      if rootInsideStateDir(fsRoot, stateDir):
        raise newCrisolError(cekConfig,
          "config: remote-cache '" & remote.name & "': url '" & remote.url &
          "' resolves inside the state dir '" & stateDir & "' -- this would " &
          "recurse the local (l1) cache; point it somewhere else")

    # RFC-0005 C3b: threaded uniformly for every scheme (matching the
    # existing `file` factory's own `discard token` precedent) -- the s3
    # factory discards it too (unsigned; no credential axis at all), so
    # only the http/https factory actually reads it.
    let backendOpt = reg.buildBackend(remote, token = httpTokenFor(secrets, remote.name))
    if backendOpt.isNone:
      raise newCrisolError(cekConfig,
        "config: remote-cache '" & remote.name & "': unsupported or " &
        "unrecognized scheme in url '" & remote.url & "'")

    tiers.add Tier(
      name:          remote.name,
      backend:       backendOpt.get,
      backfillOnHit: remote.backfillOnHit,
      verifyTrust:   remote.verifyTrust.get(defaultVerifyTrust),
    )

  CacheRuntime(
    cache:     TieredCache(tiers: tiers, trust: trust),
    sink:      sink,
    localRoot: root,
  )
