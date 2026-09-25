## test_r5_10_toolchain_unsound_wire.nim — R5-10 (round-5 review): the W4 wire.
##
## THE FINDING. crisol's L2 cache tier is shared across hosts, so cache-key
## soundness is a security property and UNDER-invalidation is the defect class.
## W4 is the mechanism for the case where crisol cannot identify the host's C
## toolchain at all: the fingerprint then folds to a sentinel constant shared by
## every host in the same degraded state, so the run must refuse to PUBLISH.
## The chain is three links:
##
##   1. `ccidentity.toolchainUnsound(fp)`      — the predicate (unit-covered:
##                                               tests/unit/test_cachedispatch.nim)
##   2. `api.runTestsWith`'s
##      `let toolchainUnidentified = toolchainUnsound(ccFp)`
##      → `cachedispatch.cacheEnabled(..., toolchainUnidentified = ...)`  — THE WIRE
##   3. `cachedispatch.shouldStore` → `cdmToolchainUnidentified`  — the gate
##      (unit-covered, from a hand-passed `toolchainUnidentified = true`)
##
## Link 1 and link 3 were proved; link 2 was proved by nothing. Every host the
## suite runs on has an identifiable `cc`, so the degraded branch was
## unreachable from a real run: hardcoding `toolchainUnidentified = false` at
## the `cacheEnabled` call, or replacing the whole `toolchainUnsound(ccFp)` call
## with `false`, left the entire tree green. Round 4's R4-4 (`{.deprecated.}`
## companion, no default) only catches OMITTING the argument — passing the
## unsound value explicitly was invisible.
##
## WHAT THIS FILE PINS. `api.CcFingerprintProbe` (R5-10) is the seam:
## `runTestsWith` takes the C-toolchain probe as a parameter, defaulting to the
## real memoised `ccidentity.cachedCcFingerprint`, so a test can hand it a DEGRADED
## fingerprint and drive an otherwise completely real run (real config, real
## plan, real compile, real spawn, real store path) into the branch. The
## assertion is the run's own observable store decision --
## `EntrypointResult.cacheDecision == cdmToolchainUnidentified`, on the
## in-process result AND on the run/v2 wire -- not the flag the test itself set.
## A counting `CacheBackend` corroborates it at the port: the backend's `put` is
## never reached on a degraded run, and IS reached on the control.
##
## These tests go RED under both mutations that round 5 proved invisible:
##   * `toolchainUnidentified = false` hardcoded at the `cacheEnabled` call
##     → the degraded runs publish (`cdmStored`, `puts == 1`).
##   * `toolchainUnsound(ccFp)` replaced by `false`
##     → identical: the local is false regardless of the injected fingerprint.
## It also goes red if the predicate is narrowed back to `isFullyDegraded`
## (the half-degraded case below), which is the more likely real-world vector.
##
## Integration, not unit: each case loads a real config, compiles a real
## entrypoint and spawns it. Runs on every platform -- the degradation is
## injected, never staged on the host, so no `CRISOL-SKIP` marker is needed.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r5_10_toolchain_unsound_wire.nim

import std/[json, os, unittest]
import crisol/api            # runTestsWith/CacheDeps/CcFingerprintProbe (uncontracted)
import crisol/types          # CacheConfig, CacheDecision (cdmStored/cdmToolchainUnidentified)
import crisol/ccidentity     # CcFingerprint/CcHalf/CcDigest — the injected probe's value
import crisol/cacheport      # CacheBackend/StoredEntry/CacheVerdict/SoundnessKey/nonePolicy
import crisol/cachetier      # Tier/TieredCache
import crisol/cachememory    # memory() — the zero-I/O backend this wraps
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/cachetelemetry # NilSink/TelemetryEvent
import crisol/paths          # TrackedRoots (buildRuntime's 5th parameter)

import "../support/helpers"  # withTempProject

# ---------------------------------------------------------------------------
# A CacheDeps whose single tier counts every `put` that reaches the port
# ---------------------------------------------------------------------------

proc countingDeps(puts: ref int): CacheDeps =
  ## One in-memory tier (`memory()`, RFC-0005 A1's zero-I/O double) wrapped so
  ## that every `put` the store path performs increments `puts[]`. `nonePolicy`
  ## + `verifyTrust: false` is `cacheregistry.localOnlyCache`'s own shape, so
  ## nothing here can refuse a store for a TRUST reason and be mistaken for the
  ## W4 refusal under test.
  let inner = memory()
  let innerPut = inner.put
  var spy = inner
  spy.put = proc(entry: StoredEntry): CacheVerdict =
    inc puts[]
    innerPut(entry)
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string;
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
    ))

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

proc knownHalf(text: string): CcHalf =
  CcHalf(state: cfsKnown, text: text,
         digest: CcDigest(kind: cdkKnown, hex: "deadbeefcafef00d"))

proc blindFingerprint(): CcFingerprint =
  ## The fully-degraded host: neither a compiler driver nor a runtime library
  ## answered, so both halves fold to their sentinel constants
  ## (`ccidentity.isFullyDegraded`).
  CcFingerprint(compiler: CcHalf(state: cfsUnavailable),
                runtime:  CcHalf(state: cfsUnavailable))

proc halfDegradedFingerprint(): CcFingerprint =
  ## The likelier vector `toolchainUnsound` is deliberately broader than
  ## `isFullyDegraded` to catch: a fleet sharing one correctly-identified
  ## compiler whose RUNTIME probe fails on some subset of hosts (no `ldd`, a
  ## sandboxed link probe) — every one of those hosts folds the runtime half to
  ## the same constant and collides on one key.
  CcFingerprint(compiler: knownHalf("gcc 13.2.0"),
                runtime:  CcHalf(state: cfsUnavailable))

proc soundFingerprint(): CcFingerprint =
  CcFingerprint(compiler: knownHalf("gcc 13.2.0"),
                runtime:  knownHalf("glibc 2.38"))

proc wireDecision(rr: RunReport): string =
  ## The run/v2 rendering of the same decision — the fact an external consumer
  ## (CI, `crisol run --json`) actually sees.
  parseJson(toJsonString(rr.doc))["entrypoints"][0]["cacheDecision"].getStr

# ---------------------------------------------------------------------------

suite "R5-10 — api.nim's toolchainUnsound wire reaches the store gate":

  test "sanity: the injected fingerprints are exactly what the predicate judges":
    ## Guards the fixtures themselves, so a red case below can only mean the
    ## WIRE moved, never that these three values stopped meaning what they say.
    check toolchainUnsound(blindFingerprint())
    check isFullyDegraded(blindFingerprint())
    check toolchainUnsound(halfDegradedFingerprint())
    check not isFullyDegraded(halfDegradedFingerprint())
    check not toolchainUnsound(soundFingerprint())

  test "control — sound toolchain: the run publishes (cdmStored, backend put reached)":
    ## The differential partner of the two refusal cases: same project, same
    ## deps, same code path, the ONLY difference being the injected
    ## fingerprint's soundness. Without this, a refusal assertion could pass on
    ## a run that was never going to store anything anyway.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts),
                            ccProbe = proc(): CcFingerprint = soundFingerprint())
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmStored
      check rr.wireDecision == "stored"
      check puts[] == 1                      # the entry really reached the port

  test "fully degraded toolchain: the run refuses to publish (cdmToolchainUnidentified)":
    ## THE WIRE. Nothing here hands `cacheEnabled` a boolean: the only input is
    ## a degraded `CcFingerprint`, and the refusal must be derived from it by
    ## production code (`toolchainUnsound` → `CacheContext` → `shouldStore`).
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts),
                            ccProbe = proc(): CcFingerprint = blindFingerprint())
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed  # the run itself still succeeds...
      check rr.exitCode == 0
      check not rr.results[0].cached          # ...and was never served from cache
      # ...but nothing may be published under a sentinel-folded key.
      check rr.results[0].cacheDecision == cdmToolchainUnidentified
      check rr.wireDecision == "toolchainUnidentified"
      check puts[] == 0                       # the store never reached the port

  test "half-degraded toolchain (runtime half only): same refusal":
    ## `toolchainUnsound`, not `isFullyDegraded`, is what the wire must consult.
    ## Narrowing the predicate at the call site to the fully-blind case would
    ## leave the case above green and only this one red.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts),
                            ccProbe = proc(): CcFingerprint = halfDegradedFingerprint())
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmToolchainUnidentified
      check rr.wireDecision == "toolchainUnidentified"
      check puts[] == 0

  test "the default probe is the real one: omitting ccProbe still publishes":
    ## Pins that the seam's DEFAULT is production behaviour — every existing
    ## caller (`runTests`, the CLI) reaches the same store decision as the
    ## explicitly-sound control above, with no argument passed. If the default
    ## were ever changed to something degraded, caching would silently stop
    ## working for every consumer and this case would say so.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let puts = new(int)
      let rr = runTestsWith(baseOpts(projectRoot), countingDeps(puts))
      check rr.status == rsOk
      require rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check rr.results[0].cacheDecision == cdmStored
      check puts[] == 1
