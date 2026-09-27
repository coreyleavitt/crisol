## test_toolchain_warning_ladder.nim -- the `api.runTestsWith` toolchain
## warning ladder, observed.
##
## `api.nim` prints one `crisol: warning:` line per
## `ccidentity.toolchainVerdict`. A fingerprint per reason is injected
## through `RunDeps.ccProbe` into an otherwise real run, and the run's
## stderr is captured. Each reason's message carries one marker phrase no
## other message contains; each case asserts its own marker is present and
## every other marker absent, and the sound case asserts none is present. So:
##   * swapping two messages            -> both cases red;
##   * silencing one message            -> that case red;
##   * a new message that reuses another's wording -> the "others absent" check.
## The unidentified halves are built by the production derivation
## (`ccFingerprintWith` over recorded probe output, `tests/support/ccfake`),
## so each warning is checked for the value a real host yields, including the
## cause it must report.
##
## Every unsound message carries `MarkNotCached`, and the sound run does not;
## the last test observes that claim (two runs against one backend: the
## unidentified host never hits, the sound control stores and then hits).
##
## Integration, not unit: each case drives a real config, plan, compile and
## spawn. One temp project is reused across cases so the compile is paid once.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_toolchain_warning_ladder.nim

import std/[os, strutils, tables, unittest]
import crisol/api
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/types          # CacheConfig
import crisol/ccidentity     # CcFingerprint/CcProbeContext
import crisol/toolrun        # ran/notRun
import "../support/ccfake"   # the recorded probe output
import crisol/cacheport      # nonePolicy
import crisol/cachetier      # Tier/TieredCache
import crisol/cachememory    # memory()
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/cachetelemetry # NilSink/TelemetryEvent
import crisol/paths          # TrackedRoots

import "../support/helpers"  # withTempProject
import "../support/capture"  # captureStderr
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

proc sharedDeps(backend: CacheBackend; fp: CcFingerprint): RunDeps =
  ## One LOCAL tier over `backend`, and `fp` as the host's C toolchain
  ## identity. Passing the same backend to two runs is two runs on one host
  ## against one local cache.
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

# ---------------------------------------------------------------------------
# One marker per message. Each is a phrase ONLY that message contains.
# ---------------------------------------------------------------------------

const
  MarkCompiler  = "C compiler Nim is configured to use could not be identified"
  MarkRuntime   = "C runtime library the configured compiler links"
  MarkBlind     = "could not be identified at all"
  AllMarks      = [MarkCompiler, MarkRuntime, MarkBlind]
  MarkNotCached = "nothing is cached for this run: no result is stored or looked up"
    ## The consequence every unsound message states, and the sound run never
    ## prints. Shared, so it is not one of the per-reason markers.
  InternalName = "ccidentity."
    ## The text a user reads names no internal identifier.

proc clRefusesProbe(): CcFingerprint =
  ## The configured cl exits 2 on the identity probe; the runtime half is
  ## still identified.
  let f = msvcHost()
  f.macroReply = ran(2, "", "cl : Command line error D8021 : invalid numeric argument '/Wfoo'")
  probe(f)

proc runtimeUnreadable(): CcFingerprint =
  let f = msvcHost()
  f.fileHex.del "C:\\msvc\\sdk\\lib\\ucrt\\libucrt.lib"
  probe(f)

proc discoveryFailed(): CcFingerprint =
  let f = msvcHost()
  f.discovery = Discovery(kind: dkNotFound, why: "`nim c --compileOnly` of a probe module failed (exited 1)")
  probe(f)

proc stderrOf(projectRoot: string; fp: CcFingerprint): string =
  captureStderr(proc() =
    let rr = runTestsWith(baseOpts(projectRoot), sharedDeps(memory(), fp))
    doAssert rr.status == rsOk, "run failed: " & rr.error)

template checkOnly(err: string; mark: string) =
  checkpoint("stderr = " & err)
  for m in AllMarks:
    if m == mark: check m in err
    else:         check m notin err
  check MarkNotCached in err
  check InternalName notin err

suite "the toolchain warning ladder prints the right message per reason":

  test "every reason, one real run each":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")

      block sound:
        let err = stderrOf(projectRoot, probe(msvcHost()))
        checkpoint("sound stderr = " & err)
        for m in AllMarks: check m notin err
        check MarkNotCached notin err

      block compilerUnidentified:
        let fp = clRefusesProbe()
        require toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upCompiler)
        let err = stderrOf(projectRoot, fp)
        checkOnly(err, MarkCompiler)
        # The configured driver, named by the file the probe ran: the one the
        # build's nim resolves (R10-S6), not the manifest's bare token.
        check ("`" & FakeNimDir & "\\vccexe.exe`") in err
        check "exited 2" in err

      block runtimeUnidentified:
        let fp = runtimeUnreadable()
        require toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upRuntime)
        let err = stderrOf(projectRoot, fp)
        checkOnly(err, MarkRuntime)
        check "libucrt.lib" in err

      block blind:
        let err = stderrOf(projectRoot, discoveryFailed())
        checkOnly(err, MarkBlind)
        check "--compileOnly" in err

      block notProbed:
        ## The zero value fails closed, and says so.
        let err = stderrOf(projectRoot, CcFingerprint())
        checkOnly(err, MarkBlind)

  test "an unidentified host caches nothing -- two runs, one local cache":
    ## The message's claim, observed. Two runs share ONE local backend. The
    ## sound control stores on the first run and HITS on the second; the
    ## unidentified host is refused on both and never served, because nothing
    ## was ever stored under its key -- locally included.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")

      proc twoRuns(fp: CcFingerprint): seq[EntrypointResult] =
        let backend = memory()
        for i in 0 .. 1:
          let rr = runTestsWith(baseOpts(projectRoot), sharedDeps(backend, fp))
          doAssert rr.status == rsOk, "run failed: " & rr.error
          doAssert rr.results.len == 1
          result.add rr.results[0]

      block control:
        let r = twoRuns(probe(msvcHost()))
        check r[0].cacheDecision == cdmStored
        check r[1].cacheDecision == cdmHit
        check r[1].cached

      block unidentified:
        let r = twoRuns(clRefusesProbe())
        for x in r:
          check x.cacheDecision == cdmToolchainUnidentified
          check not x.cached
