## test_degraded_roots_cache_decision.nim -- R10-D5 (round-10 review): a run
## whose tracked roots are degraded reports why its cache was off, through
## the real run path.
##
## THE FINDING. RFC-0009 §3's degraded mode (a tracked root whose case-fold
## policy could not be probed) turns the result cache off for the run. Every
## result of such a run was stamped `cdmPolicyDisabled` -- "policyDisabled"
## on the wire -- which is documented to mean the `--no-cache` flag and
## nothing else, so a `--json` reader was told the invocation asked for no
## cache when it had not.
##
## WHAT THIS FILE PINS. A degraded run (forced by an injected fold probe that
## always fails) with the cache requested and an identified toolchain: every
## result, never-built and fresh alike, reads `cdmRootsDegraded` and
## serializes as "rootsDegraded"; no cache runtime is built. The control, the
## same fixture with `--no-cache` and a healthy probe, still reads
## "policyDisabled" on its fresh result.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_degraded_roots_cache_decision.nim

import std/[json, options, os, unittest]
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/api            # RunOptions/RunReport/toJsonString
import crisol/types          # CacheConfig/CacheDecision
import crisol/ccidentity     # CcFingerprint/CcProbeContext
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/paths          # TrackedRoots/FoldPolicy

import "../support/helpers"  # withTempProject
import "../support/ccfake"   # fpOf/SoundFp
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

proc alwaysFails(rootAbs, stateDir: string): Option[FoldPolicy] =
  none(FoldPolicy)

proc deps(): RunDeps =
  RunDeps(
    buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int;
                       resolvedSecrets: CacheSecrets;
                       trackedRoots: TrackedRoots): CacheRuntime =
      doAssert false, "buildRuntime reached on a cache-off run"
      nil,
    ccProbe: proc(ctx: CcProbeContext): ToolchainProbe =
      ToolchainProbe(fp: fpOf(SoundFp), site: unprobedSite()))

proc wireDecision(rr: RunReport): string =
  parseJson(toJsonString(rr.doc))["entrypoints"][0]["cacheDecision"].getStr

suite "R10-D5: degraded tracked roots are not the --no-cache flag":

  test "a degraded run stamps rootsDegraded on a never-built binary":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            installSignals: false, showProgress: false,
                            persist: false, foldProbe: alwaysFails)
      let rr1 = runTestsWith(opts, deps())
      require rr1.status == rsOk
      require rr1.trackedRoots.degraded
      check not rr1.results[0].compileSkipped   # never built
      check rr1.results[0].cacheDecision == cdmRootsDegraded
      check rr1.wireDecision == "rootsDegraded"

  test "a degraded run stamps rootsDegraded on a fresh binary too":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      # A healthy run builds the binary and persists the depgraph (a degraded
      # run persists none), so the degraded run below finds it fresh.
      var opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            installSignals: false, showProgress: false,
                            persist: false, noCache: true)
      require runTestsWith(opts, deps()).status == rsOk
      opts.noCache = false
      opts.foldProbe = alwaysFails
      let rr = runTestsWith(opts, deps())
      require rr.status == rsOk
      require rr.trackedRoots.degraded
      checkpoint("compileSkipped = " & $rr.results[0].compileSkipped)
      check rr.results[0].cacheDecision == cdmRootsDegraded
      check rr.wireDecision == "rootsDegraded"

  test "control: --no-cache on a healthy run still reads policyDisabled":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            installSignals: false, showProgress: false,
                            persist: false, noCache: true)
      discard runTestsWith(opts, deps())
      let rr = runTestsWith(opts, deps())
      require rr.status == rsOk
      require not rr.trackedRoots.degraded
      check rr.results[0].compileSkipped
      check rr.results[0].cacheDecision == cdmPolicyDisabled
      check rr.wireDecision == "policyDisabled"
