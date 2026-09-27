## test_probe_context_wiring.nim -- R10-L2 (round-10 review): what the C
## toolchain probe is told about the configuration, pinned against
## expectations computed independently of the code under test.
##
## THE FINDING. `ccProbeContextOf(cfg)` is the production wiring from a
## loaded `Config` into `CcProbeContext`: the project root (the discovery
## compile's cwd), the state directory (its scratch space) and the global
## crisol.kdl flags (a `--passC`, a `cc =` override, a `-d:` define can each
## change which compiler Nim selects). Every existing test built its expected
## context with `ccProbeContextOf` too, so a mutant dropping the flags
## (`flags: @[]`) or passing the state dir as the project root survived all
## of them: both sides of each comparison changed together.
##
## WHAT THIS FILE PINS. (1) The projection itself, for a `Config` whose
## fields are known literals. (2) The context a real run hands the injected
## probe, for a project whose crisol.kdl declares a global flag and a
## group-only flag, against paths and flags written out in the test. Both go
## red under either mutant.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_probe_context_wiring.nim

import std/[os, unittest]
import crisol/runcore        # runTestsWith/RunDeps (uncontracted)
import crisol/api            # RunOptions/RunReport
import crisol/types          # Config/CacheConfig
import crisol/pipeline       # ccProbeContextOf
import crisol/ccidentity     # CcFingerprint/CcProbeContext
import crisol/cacheregistry  # CacheRuntime/CacheSecrets
import crisol/paths          # TrackedRoots

import "../support/helpers"  # withTempProject
import "../support/ccfake"   # fpOf/SoundFp
import "../support/driversite"  # R11-D1: RunDeps.ccProbe returns a ToolchainProbe

const GlobalFlag = "--passC:-DCRISOL_R10_GLOBAL"
const GroupFlag = "-d:crisolR10GroupOnly"

suite "R10-L2: the probe context a configuration yields":

  test "ccProbeContextOf projects root, absolute state dir and global flags":
    let root = getTempDir() / "crisol_r10_ctx_root"
    let cfg = Config(projectRoot: root, stateDir: "state-here",
                     flags: @[GlobalFlag, "-d:second"])
    let ctx = ccProbeContextOf(cfg)
    check ctx.projectRoot == root
    check ctx.stateDir == root / "state-here"
    check ctx.flags == @[GlobalFlag, "-d:second"]

  test "a real run hands the probe the project's root, state dir and global flags":
    withTempProject:
      writeFile(projectRoot / "crisol.kdl",
                "flags \"" & GlobalFlag & "\"\n" &
                "group \"unit\" {\n" &
                "    globs \"tests/unit/test_*.nim\"\n" &
                "    flags \"" & GroupFlag & "\"\n" &
                "}\n")
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      var seen: seq[CcProbeContext]
      let deps = RunDeps(
        buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int;
                           resolvedSecrets: CacheSecrets;
                           trackedRoots: TrackedRoots): CacheRuntime =
          doAssert false, "buildRuntime reached on a noCache run"
          nil,
        ccProbe: proc(ctx: CcProbeContext): ToolchainProbe =
          seen.add ctx
          ToolchainProbe(fp: fpOf(SoundFp), site: unprobedSite()))
      let rr = runTestsWith(
        RunOptions(configPath: projectRoot / "crisol.kdl", installSignals: false,
                   showProgress: false, persist: false, noCache: true), deps)
      require rr.status == rsOk
      require seen.len == 1
      let expectedRoot = projectRoot.normalizedPath
      checkpoint("probe saw " & $seen[0])
      check seen[0].projectRoot.normalizedPath == expectedRoot
      check seen[0].stateDir.normalizedPath == expectedRoot / ".crisol"
      check seen[0].flags == @[GlobalFlag]
