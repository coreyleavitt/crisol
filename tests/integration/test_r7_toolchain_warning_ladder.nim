## test_r7_toolchain_warning_ladder.nim — R7-L1 (round-7 review): the
## `api.runTestsWith` toolchain warning ladder, observed.
##
## THE FINDING. `api.nim` cases over `ccidentity.toolchainUnsoundReason(ccFp)`
## and prints one `crisol: warning:` line per reason (R6 made the `case`
## exhaustive). No test read what it printed: swapping two messages, or
## silencing one, left every suite green. The reason enum is pinned in
## `tests/unit/test_cc_banner_selection.nim`; the TEXT a user sees was not.
##
## WHAT THIS FILE PINS. A fingerprint per reason is injected through
## `api.CcFingerprintProbe` (R5-10's seam) into an otherwise real run, and the
## run's stderr is captured. Each reason's message carries one marker phrase
## no other message contains; each case asserts its own marker is present and
## every other marker absent, and the sound case asserts none is present. So:
##   * swapping two messages            -> both cases red;
##   * silencing one message            -> that case red;
##   * a new message that reuses another's wording -> the "others absent" check.
## The refused case is built by production code (`ccIdentity` over the
## measured R7-S1 capture: `CL=/W4`, cl and vccexe exit 2, gcc bystander), not
## by hand, so the warning is checked for the exact value a real host yields,
## including the driver names it must report (R7-D6).
##
## R8 (round-8 review) re-pinned the TEXT after it was found false:
##   * R8-D1: every message said results "will NOT be published to the
##     shared cache ... reads are unaffected". The refusal gates EVERY store,
##     the local tier included, and the degraded key is one no host stores
##     under, so nothing is cached at all. Every unsound message now carries
##     `MarkNotCached`, and the sound run does not; the last test observes the
##     claim itself (two runs against one backend: refused never hits, the
##     sound control stores and then hits).
##   * R8-D6: "driver(s) ... did not identify themselves" became singular or
##     plural by count, "refused" (cl under `CL=/W4` does print its banner),
##     and lost the misdirecting "_CL_" hint.
##   * R8-L8: the driver-name check was overfit -- a hard-coded
##     "`cl`, `vccexe`" passed it. The single-`gcc` case asserts gcc is named
##     and every other candidate is ABSENT.
##
## Integration, not unit: each case drives a real config, plan, compile and
## spawn. One temp project is reused across cases so the compile is paid once.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r7_toolchain_warning_ladder.nim

import std/[os, strutils, unittest]
import crisol/api            # runTestsWith/CacheDeps/CcFingerprintProbe
import crisol/types          # CacheConfig
import crisol/ccidentity     # CcFingerprint/CcHalf/ccIdentity/WindowsCcProfile
import crisol/toolrun        # RunProc
import crisol/cacheport      # nonePolicy
import crisol/cachetier      # Tier/TieredCache
import crisol/cachememory    # memory()
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/cachetelemetry # NilSink/TelemetryEvent
import crisol/paths          # TrackedRoots

import "../support/helpers"  # withTempProject
import "../support/capture"  # captureStderr

proc sharedDeps(backend: CacheBackend): CacheDeps =
  ## One LOCAL tier over `backend`. Passing the same backend to two runs is
  ## two runs on one host against one local cache.
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string;
                               maxEntries: int; resolvedSecrets: CacheSecrets;
                               trackedRoots: TrackedRoots): CacheRuntime =
    discard cfg; discard stateDir; discard maxEntries
    discard resolvedSecrets; discard trackedRoots
    CacheRuntime(
      cache: TieredCache(
        tiers: @[Tier(name: "l1", backend: backend, backfillOnHit: false,
                      verifyTrust: false)],
        trust: nonePolicy()),
      sink: NilSink[TelemetryEvent]()))

proc memoryDeps(): CacheDeps = sharedDeps(memory())

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(configPath: projectRoot / "crisol.kdl", installSignals: false,
             showProgress: false, persist: false)

# ---------------------------------------------------------------------------
# One marker per message. Each is a phrase ONLY that message contains.
# ---------------------------------------------------------------------------

const
  MarkRefused  = "refused as this host's compiler identity"
  MarkBlind    = "could not be identified at all"
  MarkUnnamed  = "this platform's profile records no content digest"
  MarkHalf     = "half of the C toolchain identity could not be established"
  AllMarks     = [MarkRefused, MarkBlind, MarkUnnamed, MarkHalf]
  MarkNotCached = "NOT cached for this run, locally or remotely"
    ## R8-D1: the consequence every unsound message states, and the sound run
    ## never prints. Shared, so it is not one of the per-reason markers.
  StaleClaim   = "reads are unaffected"
    ## R8-D1: the false claim every message used to make.

proc known(text: string; digested: bool): CcHalf =
  CcHalf(state: cfsKnown, text: text,
         digest: if digested: CcDigest(kind: cdkKnown, hex: "deadbeefcafef00d")
                 else: CcDigest(kind: cdkNone))

let runtimeKnown = known("libcmt+libucrt+libvcruntime", true)

proc measuredClW4Half(): CcHalf =
  ## `ccIdentity` over the R7-S1 capture: `CL=/W4` makes cl and vccexe print
  ## their banner plus D8003 and exit 2; a mingw gcc answers cleanly.
  let clOut = "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64\n" &
              "Copyright (C) Microsoft Corporation.  All rights reserved.\n\n" &
              "cl : Command line error D8003 : missing source filename\n"
  let run: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe": (output: clOut, ok: false)
    of "gcc": (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n", ok: true)
    else: (output: "", ok: false)
  ccIdentity(run, WindowsCcProfile,
             proc(path: string): string = "aaaaaaaaaaaaaaaa")

proc stderrOf(projectRoot: string; fp: CcFingerprint): string =
  let probe: CcFingerprintProbe = proc(): CcFingerprint = fp
  captureStderr(proc() =
    let rr = runTestsWith(baseOpts(projectRoot), memoryDeps(), ccProbe = probe)
    doAssert rr.status == rsOk, "run failed: " & rr.error)

template checkOnly(err: string; mark: string) =
  checkpoint("stderr = " & err)
  for m in AllMarks:
    if m == mark: check m in err
    else:         check m notin err
  check MarkNotCached in err
  check StaleClaim notin err

template checkNamesOnly(err: string; named: openArray[string]) =
  ## R8-L8: every candidate driver in `named` is in the message, and every
  ## other `WindowsCcProfile` candidate is not.
  for d in ["cl", "vccexe", "gcc", "clang", "cc"]:
    if d in named: check ("`" & d & "`") in err
    else:          check ("`" & d & "`") notin err

suite "R7-L1 — the toolchain warning ladder prints the right message per reason":

  test "every reason, one real run each":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")

      block sound:
        let err = stderrOf(projectRoot, CcFingerprint(
          compiler: known("gcc 13.2.0", true), runtime: runtimeKnown))
        checkpoint("sound stderr = " & err)
        for m in AllMarks: check m notin err
        check MarkNotCached notin err

      block refusedMeasured:
        let half = measuredClW4Half()
        require half.state == cfsUnavailable
        let err = stderrOf(projectRoot,
                           CcFingerprint(compiler: half, runtime: runtimeKnown))
        checkOnly(err, MarkRefused)
        checkNamesOnly(err, ["cl", "vccexe"])  # R7-D6: the refused drivers, named
        check "drivers `cl`, `vccexe` were refused" in err  # R8-D6: plural for two
        check "unset it" in err               # R8-D1: what restores caching
        check "CL environment variable" in err
        check "_CL_" notin err                # R8-D6: _CL_ cannot cause this

      block refusedDiagnosticOnly:
        ## The R6 shape (a driver that exited 0 printing only a diagnostic),
        ## with NO runtime half: still reported as refused, not as blind.
        let half = ccIdentity(
          proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
            if cmd == "cl": (output: "cl : Command line error D8003 : missing source filename\n",
                             ok: true)
            else: (output: "", ok: false),
          WindowsCcProfile, proc(path: string): string = "aaaaaaaaaaaaaaaa")
        let err = stderrOf(projectRoot, CcFingerprint(
          compiler: half, runtime: CcHalf(state: cfsUnavailable)))
        checkOnly(err, MarkRefused)
        checkNamesOnly(err, ["cl"])
        check "driver `cl` was refused" in err   # R8-D6: singular for one
        check "it ran" in err
        check "drivers " notin err

      block refusedSingleGcc:
        ## R8-L8: ONE refused driver that is neither `cl` nor `vccexe` -- a
        ## direct driver that ran and exited non-zero. A message that
        ## hard-coded the measured names would pass the two cases above and
        ## fail here.
        let half = ccIdentity(
          proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
            if cmd == "gcc": (output: "gcc: internal failure\n", ok: false)
            else: (output: "", ok: false),
          WindowsCcProfile, proc(path: string): string = "aaaaaaaaaaaaaaaa")
        require half.refusedDrivers == @["gcc"]
        let err = stderrOf(projectRoot,
                           CcFingerprint(compiler: half, runtime: runtimeKnown))
        checkOnly(err, MarkRefused)
        checkNamesOnly(err, ["gcc"])
        check "driver `gcc` was refused" in err
        check "drivers " notin err
        check "each ran" notin err

      block blind:
        let err = stderrOf(projectRoot, CcFingerprint(
          compiler: CcHalf(state: cfsUnavailable),
          runtime: CcHalf(state: cfsUnavailable)))
        checkOnly(err, MarkBlind)

      block unnamed:
        let err = stderrOf(projectRoot, CcFingerprint(
          compiler: known("unit.c", false), runtime: runtimeKnown))
        checkOnly(err, MarkUnnamed)

      block halfMissing:
        let err = stderrOf(projectRoot, CcFingerprint(
          compiler: CcHalf(state: cfsUnavailable), runtime: runtimeKnown))
        checkOnly(err, MarkHalf)

      block notProbed:
        ## R7-S3: the zero value fails closed, and says so.
        let err = stderrOf(projectRoot, CcFingerprint())
        checkOnly(err, MarkBlind)

  test "R8-D1: a refused host caches nothing -- two runs, one local cache":
    ## The message's claim, observed. Two runs share ONE local backend. The
    ## sound control stores on the first run and HITS on the second; the
    ## refused host is refused on both and never served, because nothing was
    ## ever stored under its key -- locally included.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")

      proc twoRuns(fp: CcFingerprint): seq[EntrypointResult] =
        let backend = memory()
        let probe: CcFingerprintProbe = proc(): CcFingerprint = fp
        for i in 0 .. 1:
          let rr = runTestsWith(baseOpts(projectRoot), sharedDeps(backend),
                                ccProbe = probe)
          doAssert rr.status == rsOk, "run failed: " & rr.error
          doAssert rr.results.len == 1
          result.add rr.results[0]

      block control:
        let r = twoRuns(CcFingerprint(compiler: known("gcc 13.2.0", true),
                                      runtime: runtimeKnown))
        check r[0].cacheDecision == cdmStored
        check r[1].cacheDecision == cdmHit
        check r[1].cached

      block refused:
        let r = twoRuns(CcFingerprint(compiler: measuredClW4Half(),
                                      runtime: runtimeKnown))
        for x in r:
          check x.cacheDecision == cdmToolchainUnidentified
          check not x.cached
