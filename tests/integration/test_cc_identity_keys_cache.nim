## test_cc_identity_keys_cache.nim — R9-L3 (round-9 review): the host's C
## toolchain identity is part of the result-cache key, observed through a
## real run.
##
## THE FINDING. `api.runTestsWith` builds the run's `KeyContext` with
## `ccVersion = ccVer`, the one production site that feeds the C toolchain
## identity into the SoundnessKey. Replacing it with `ccVersion = ""` left
## every suite green: nothing ran the same project under two different
## toolchains against one cache and asked whether the second run was served
## the first run's result.
##
## WHAT THIS FILE PINS. Two runs of one project share one local cache; only
## the injected fingerprint varies, and both fingerprints are sound (so the
## cache is live on both runs). The same fingerprint twice must hit; two
## different fingerprints must not. Under the `ccVersion = ""` mutant the
## second run of the differing pair is served from the cache and this file
## goes red.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cc_identity_keys_cache.nim

import std/[os, tables, unittest]
import crisol/api
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/types          # CacheConfig, CacheDecision
import crisol/ccidentity     # CcFingerprint/CcProbeContext
import crisol/cacheport      # CacheBackend/nonePolicy
import crisol/cachetier      # Tier/TieredCache
import crisol/cachememory    # memory()
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/cachetelemetry # NilSink/TelemetryEvent
import crisol/paths          # TrackedRoots

import "../support/helpers"  # withTempProject
import "../support/ccfake"   # knownHalf/msvcHost/probe
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

proc sharedDeps(backend: CacheBackend; fp: CcFingerprint): RunDeps =
  ## One local tier over `backend`, and `fp` as this run's C toolchain
  ## identity. The same backend across two runs is one host's local cache.
  RunDeps(
    buildRuntime: proc(cfg: CacheConfig; stateDir: string;
                       maxEntries: int; resolvedSecrets: CacheSecrets;
                       trackedRoots: TrackedRoots): CacheRuntime =
      discard cfg; discard stateDir; discard maxEntries
      discard resolvedSecrets; discard trackedRoots
      CacheRuntime(
        cache: TieredCache(
          tiers: @[Tier(name: "l1", backend: backend, backfillOnHit: false,
                        verifyTrust: false)],
          trust: nonePolicy()),
        sink: NilSink[TelemetryEvent]()),
    ccProbe: proc(ctx: CcProbeContext): ToolchainProbe =
      ToolchainProbe(fp: fp, site: unprobedSite()))

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(configPath: projectRoot / "crisol.kdl", installSignals: false,
             showProgress: false, persist: false)

let gcc13 = CcFingerprint(compiler: knownHalf("gcc 13.2.0", "1313131313131313"),
                          runtime:  knownHalf("glibc 2.38", "3838383838383838"))
let gcc14 = CcFingerprint(compiler: knownHalf("gcc 14.1.0", "1414141414141414"),
                          runtime:  knownHalf("glibc 2.38", "3838383838383838"))

proc clValue(value: string): CcFingerprint =
  ## The measured MSVC host, with `CL` set to `value` ("" = unset).
  let f = msvcHost()
  if value.len > 0: f.env["CL"] = value
  probe(f)

proc secondRun(first, second: CcFingerprint): tuple[a, b: EntrypointResult] =
  ## Runs one project twice against one cache, under `first` then `second`.
  withTempProject:
    writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    let backend = memory()
    let rr1 = runTestsWith(baseOpts(projectRoot), sharedDeps(backend, first))
    doAssert rr1.status == rsOk, "first run failed: " & rr1.error
    doAssert rr1.results.len == 1
    let rr2 = runTestsWith(baseOpts(projectRoot), sharedDeps(backend, second))
    doAssert rr2.status == rsOk, "second run failed: " & rr2.error
    doAssert rr2.results.len == 1
    result = (rr1.results[0], rr2.results[0])

suite "R9-L3 — the C toolchain identity keys the result cache":

  test "sanity: both fingerprints are sound, and they differ":
    check toolchainVerdict(gcc13).kind == tvIdentified
    check toolchainVerdict(gcc14).kind == tvIdentified
    check $gcc13 != $gcc14

  test "control — the same toolchain twice: the second run is served (cdmHit)":
    let (a, b) = secondRun(gcc13, gcc13)
    check a.cacheDecision == cdmStored
    check b.cacheDecision == cdmHit
    check b.cached

  test "a different toolchain: the second run is NOT served another toolchain's result":
    let (a, b) = secondRun(gcc13, gcc14)
    check a.cacheDecision == cdmStored
    check b.cacheDecision != cdmHit
    check not b.cached
    check b.outcome == oPassed   # it ran live, and stored under its own key
    check b.cacheDecision == cdmStored

  test "a CL value change on an MSVC host: the second run is NOT served (R9-D1c)":
    let (a, b) = secondRun(clValue(""), clValue("/DFOO"))
    check a.cacheDecision == cdmStored
    check b.cacheDecision == cdmStored
    check not b.cached

  test "control -- the same CL value twice is served":
    let (a, b) = secondRun(clValue("/MP"), clValue("/MP"))
    check a.cacheDecision == cdmStored
    check b.cacheDecision == cdmHit
