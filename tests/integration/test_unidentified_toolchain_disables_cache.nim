## test_unidentified_toolchain_disables_cache.nim — R5-10 (round-5 review), reshaped
## by R9-D3: an unidentified C toolchain turns the run's cache off.
##
## THE FINDING. crisol's L2 cache tier is shared across hosts, so cache-key
## soundness is a security property and UNDER-invalidation is the defect class.
## When crisol cannot identify the host's C toolchain, the fingerprint folds to
## a sentinel constant shared by every host in the same degraded state, so a
## result must never be published under it. R5-10 found the wire from the
## predicate (`ccidentity.toolchainVerdict`) to the refusal unobservable from a
## real run: every host the suite runs on identifies its `cc`.
##
## R9-D3. The refusal used to be a store-gate check while the run still
## consulted every tier for the degraded key -- a lookup that can never hit,
## since no host stores under it, and a network round trip per entrypoint on a
## shared remote. The run now takes the cache-disabled path outright: no tier
## is consulted and nothing is stored.
##
## WHAT THIS FILE PINS. `RunDeps.ccProbe` injects the fingerprint into an
## otherwise real run (real config, plan, compile, spawn). The assertions are
## the run's own observable decision -- `cacheDecision ==
## cdmToolchainUnidentified`, in process and on the run/v2 wire -- and a
## counting `CacheBackend` at the port: on a degraded run neither `get` nor
## `put` is reached; on the sound control both are.
##
## Red under: dropping the toolchain term from api.nim's `cacheOn` gate (the
## degraded runs consult and publish); narrowing the predicate to "both halves
## unidentified" (the half-degraded case publishes).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_unidentified_toolchain_disables_cache.nim

import std/[json, os, unittest]
import crisol/api
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/types          # CacheConfig, CacheDecision (cdmStored/cdmToolchainUnidentified)
import crisol/ccidentity     # CcFingerprint/CcProbeContext — the injected probe's value
import crisol/cacheport      # CacheBackend/StoredEntry/CacheVerdict/SoundnessKey/nonePolicy
import crisol/cachetier      # Tier/TieredCache
import crisol/cachememory    # memory() — the zero-I/O backend this wraps
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/cachetelemetry # NilSink/TelemetryEvent
import crisol/paths          # TrackedRoots (buildRuntime's 5th parameter)

import "../support/helpers"  # withTempProject
import "../support/ccfake"   # fpOf/SoundFp
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

# ---------------------------------------------------------------------------
# A RunDeps whose single tier counts every `put` that reaches the port
# ---------------------------------------------------------------------------

proc countingDeps(puts, gets: ref int; fp: CcFingerprint): RunDeps =
  ## One in-memory tier (`memory()`, RFC-0005 A1's zero-I/O double) wrapped so
  ## that every `put` the store path performs increments `puts[]`. `nonePolicy`
  ## + `verifyTrust: false` is `cacheregistry.localOnlyCache`'s own shape, so
  ## nothing here can refuse a store for a TRUST reason and be mistaken for the
  ## W4 refusal under test.
  let inner = memory()
  let innerPut = inner.put
  let innerGet = inner.get
  var spy = inner
  spy.put = proc(entry: StoredEntry): CacheVerdict =
    inc puts[]
    innerPut(entry)
  spy.get = proc(key: SoundnessKey): Fetched[StoredEntry] =
    inc gets[]
    innerGet(key)
  RunDeps(
    buildRuntime: proc(cfg: CacheConfig; stateDir: string;
                       maxEntries: int; resolvedSecrets: CacheSecrets;
                       trackedRoots: TrackedRoots): CacheRuntime =
      discard cfg; discard stateDir; discard maxEntries
      discard resolvedSecrets; discard trackedRoots
      CacheRuntime(
        cache: TieredCache(
          tiers: @[Tier(name: "l1", backend: spy, backfillOnHit: false,
                        verifyTrust: false)],
          trust: nonePolicy(),
        ),
        sink: NilSink[TelemetryEvent](),
      ),
    ccProbe: proc(ctx: CcProbeContext): ToolchainProbe =
      ToolchainProbe(fp: fp, site: unprobedSite()))

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    installSignals: false,
    showProgress:   false,
    persist:        false,
  )

# ---------------------------------------------------------------------------
# The injected fingerprints
# ---------------------------------------------------------------------------

proc blindFingerprint(): CcFingerprint =
  ## The fully-degraded host: neither a compiler driver nor a runtime library
  ## answered, so both halves fold to their sentinel constants.
  CcFingerprint()

proc halfDegradedFingerprint(): CcFingerprint =
  ## A fleet sharing one correctly-identified compiler whose RUNTIME probe
  ## fails on some subset of hosts (a sandboxed link probe, say): every one
  ## of those hosts folds the runtime half to the same constant and would
  ## collide on one key.
  CcFingerprint(compiler: fpOf(SoundFp).compiler)

proc soundFingerprint(): CcFingerprint =
  fpOf(SoundFp)

proc wireDecision(rr: RunReport): string =
  ## The run/v2 rendering of the same decision — the fact an external consumer
  ## (CI, `crisol run --json`) actually sees.
  parseJson(toJsonString(rr.doc))["entrypoints"][0]["cacheDecision"].getStr

# ---------------------------------------------------------------------------

suite "R5-10/R9-D3 — an unidentified toolchain turns the run's cache off":

  test "sanity: the injected fingerprints are exactly what the predicate judges":
    ## Guards the fixtures themselves, so a red case below can only mean the
    ## WIRE moved, never that these three values stopped meaning what they say.
    check (toolchainVerdict(blindFingerprint()).kind == tvUnidentified)
    check toolchainVerdict(blindFingerprint()) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check (toolchainVerdict(halfDegradedFingerprint()).kind == tvUnidentified)
    check toolchainVerdict(halfDegradedFingerprint()) == ToolchainVerdict(kind: tvUnidentified, part: upRuntime)
    check toolchainVerdict(soundFingerprint()).kind == tvIdentified

  test "control — sound toolchain: the run publishes (cdmStored, backend put reached)":
    ## The differential partner of the two refusal cases: same project, same
    ## deps, same code path, the ONLY difference being the injected
    ## fingerprint's soundness. Without this, a refusal assertion could pass on
    ## a run that was never going to store anything anyway.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let gets = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts, gets, soundFingerprint()))
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmStored
      check rr.wireDecision == "stored"
      check puts[] == 1                      # the entry really reached the port
      check gets[] >= 1                      # and the tier was consulted first

  test "fully degraded toolchain: no lookup, no publish (cdmToolchainUnidentified)":
    ## THE WIRE. The only input is a degraded `CcFingerprint`; the decision
    ## must be derived from it by production code.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let gets = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts, gets, blindFingerprint()))
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed  # the run itself still succeeds...
      check rr.exitCode == 0
      check not rr.results[0].cached          # ...and was never served from cache
      # ...but nothing may be published under a sentinel-folded key.
      check rr.results[0].cacheDecision == cdmToolchainUnidentified
      check rr.wireDecision == "toolchainUnidentified"
      check puts[] == 0                       # the store never reached the port
      # R9-D3: nor did any LOOKUP. A degraded key is one no host stores under,
      # so consulting a tier for it (a network round trip per entrypoint on a
      # shared remote) can never hit; the run takes the cache-disabled path.
      check gets[] == 0

  test "half-degraded toolchain (runtime half only): same refusal":
    ## `toolchainVerdict` (either half unidentified), not a both-halves-blind test, is what the wire must consult.
    ## Narrowing the predicate at the call site to the fully-blind case would
    ## leave the case above green and only this one red.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let gets = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts, gets, halfDegradedFingerprint()))
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmToolchainUnidentified
      check rr.wireDecision == "toolchainUnidentified"
      check puts[] == 0
      check gets[] == 0                       # R9-D3: no lookup either

  test "productionRunDeps installs the real probe, and this host publishes":
    ## The production seam value is the memoised real probe; on every host the
    ## suite runs on it identifies the toolchain, so caching works.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let gets = new(int)
      var deps = countingDeps(puts, gets, CcFingerprint())
      deps.ccProbe = productionRunDeps().ccProbe
      let rr = runTestsWith(baseOpts(projectRoot), deps)
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmStored
      check puts[] == 1

  test "a RunDeps without a probe is refused, not silently given the host's":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      var deps = countingDeps(new(int), new(int), soundFingerprint())
      deps.ccProbe = nil
      expect AssertionDefect:
        discard runTestsWith(baseOpts(projectRoot), deps)
