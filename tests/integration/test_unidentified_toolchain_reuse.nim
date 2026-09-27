## test_unidentified_toolchain_reuse.nim -- R10-S4/R10-L8 (round-10
## review): a C toolchain that cannot be identified never compares equal to
## anything, itself included.
##
## THE FINDING. An unidentified toolchain serializes to a constant
## (`<cc-unavailable>|<runtime-unidentified>`). Turning the result cache off
## for such a run was not enough: the same constant also stamped the depgraph
## header (the `dgdCcVersion` staleness check) and keyed the persistent
## nimcache path. Two different toolchains that both failed identification
## therefore compared equal, so the second run reused binaries and object
## files the first toolchain built, and `--changed` trusted closures recorded
## under it.
##
## WHAT THIS FILE PINS, through the real run path (`runTestsWith` with an
## injected probe), for two runs whose toolchains both fail identification
## (different causes, identical serialized form):
##   - the second run recompiles instead of skipping a "fresh" binary;
##   - it compiles into a nimcache directory the first run never used;
##   - `--changed` on a clean tree reselects every entrypoint instead of
##     reporting nothing to run.
## Each assertion has a control: the same pair of runs under one identified
## toolchain skips the compile, reuses the nimcache directory and selects
## nothing, so the file cannot pass by never reusing anything at all.
##
## Every run passes `noCache: true` so what is observed is compile reuse and
## selection, never a result-cache hit.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_unidentified_toolchain_reuse.nim

import std/[algorithm, os, osproc, unittest]
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/api            # RunOptions/RunReport/changedOnly
import crisol/types          # CacheConfig
import crisol/ccidentity     # CcFingerprint/CcProbeContext/Discovery
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/paths          # TrackedRoots

import "../support/helpers"  # withTempProject/withTempGitProject
import "../support/ccfake"   # newFakeCc/probe/fpOf/SoundFp
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

proc undiscovered(why: string): CcFingerprint =
  ## A toolchain whose compiler could not be discovered, for `why`. Two
  ## different causes stand for two different hosts' toolchains; both
  ## serialize to the same sentinel pair.
  let f = newFakeCc("")
  f.discovery = Discovery(kind: dkNotFound, why: why)
  result = probe(f)
  doAssert (toolchainVerdict(result).kind == tvUnidentified)

proc depsFor(fp: CcFingerprint): RunDeps =
  ## `fp` as the run's toolchain identity. `buildRuntime` is never reached:
  ## every run here passes `noCache: true`.
  RunDeps(
    buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int;
                       resolvedSecrets: CacheSecrets;
                       trackedRoots: TrackedRoots): CacheRuntime =
      doAssert false, "buildRuntime reached on a noCache run"
      nil,
    ccProbe: proc(ctx: CcProbeContext): ToolchainProbe =
      ToolchainProbe(fp: fp, site: unprobedSite()))

proc opts(projectRoot: string; narrowing: RunNarrowing): RunOptions =
  RunOptions(configPath: projectRoot / "crisol.kdl", installSignals: false,
             showProgress: false, persist: false, noCache: true,
             narrowing: narrowing)

proc nimcacheDirs(projectRoot: string): seq[string] =
  for kind, path in walkDir(projectRoot / ".crisol" / "cache"):
    if kind == pcDir: result.add path.extractFilename
  result.sort()

let unidentifiedA = undiscovered("no C compiler on PATH (host A)")
let unidentifiedB = undiscovered("the configured compiler crashed (host B)")
let identified = fpOf(SoundFp)

doAssert $unidentifiedA == $unidentifiedB,
  "the premise: both unidentified toolchains serialize identically"

type TwoRuns = tuple[secondSkipped: bool; firstDirs, secondDirs: seq[string]]

proc compileTwice(first, second: CcFingerprint): TwoRuns =
  withTempProject:
    writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    let rr1 = runTestsWith(opts(projectRoot, noNarrowing()), depsFor(first))
    doAssert rr1.status == rsOk, "first run failed: " & rr1.error
    doAssert rr1.results.len == 1
    doAssert not rr1.results[0].compileSkipped
    result.firstDirs = nimcacheDirs(projectRoot)
    let rr2 = runTestsWith(opts(projectRoot, noNarrowing()), depsFor(second))
    doAssert rr2.status == rsOk, "second run failed: " & rr2.error
    doAssert rr2.results.len == 1
    result.secondSkipped = rr2.results[0].compileSkipped
    result.secondDirs = nimcacheDirs(projectRoot)

proc git(root: string; args: string) =
  let (output, code) = execCmdEx("git " & args, workingDir = root)
  doAssert code == 0, "git " & args & ": " & output

proc changedAfter(first, second: CcFingerprint): RunReport =
  ## Run 1 selects everything and records closures; run 2 asks `--changed`
  ## on a tree with no change to any tracked source.
  withTempGitProject:
    writeFile(gitRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    writeFile(gitRoot / "tests" / "unit" / "test_b.nim", "quit(0)\n")
    writeFile(gitRoot / ".gitignore", ".crisol/\n")
    git(gitRoot, "add -A")
    git(gitRoot, "commit -q -m fixture")
    let rr1 = runTestsWith(opts(gitRoot, noNarrowing()), depsFor(first))
    doAssert rr1.status == rsOk, "first run failed: " & rr1.error
    doAssert rr1.results.len == 2
    result = runTestsWith(opts(gitRoot, changedOnly()), depsFor(second))
    doAssert result.status == rsOk, "second run failed: " & result.error

suite "R10-S4: an unidentified toolchain is never reused":

  test "control: one identified toolchain twice reuses the binary and the nimcache":
    let r = compileTwice(identified, identified)
    check r.secondSkipped
    check r.secondDirs == r.firstDirs

  test "two unidentified toolchains: the second run recompiles":
    let r = compileTwice(unidentifiedA, unidentifiedB)
    check not r.secondSkipped

  test "two unidentified toolchains: the second run compiles into a fresh nimcache":
    let r = compileTwice(unidentifiedA, unidentifiedB)
    checkpoint("first: " & $r.firstDirs & " second: " & $r.secondDirs)
    check r.firstDirs.len == 1
    check r.secondDirs.len == 2

  test "the same unidentified toolchain twice is not reused either":
    let r = compileTwice(unidentifiedA, unidentifiedA)
    check not r.secondSkipped
    check r.secondDirs.len == 2

  test "control: --changed on a clean tree under one identified toolchain selects nothing":
    let rr = changedAfter(identified, identified)
    check rr.zeroRunnableReason == zrkChangedClean
    check rr.results.len == 0

  test "two unidentified toolchains: --changed reselects every entrypoint":
    let rr = changedAfter(unidentifiedA, unidentifiedB)
    check rr.zeroRunnableReason == zrkNone
    check rr.results.len == 2
