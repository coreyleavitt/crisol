## test_rfc0007_w2_limit_wiring.nim — rfc-0007 wiring-audit W2 E2E: the
## cbLimit attribution chain (posix SIGXCPU -> cbLimit(lkCpu), B3
## memoryOomKill -> cbLimit(lkMemory)) is CI-proven at the backend layer
## (see tests/timing/test_rfc0007_a1f_limit_timing.nim, tests/unit/
## test_rfc0007_b3_*) but was UNREACHABLE from every entry point: crisol.kdl
## exposed only `rlimit-nofile`; nothing production ever set
## RlimitOverrides.limitCpu/limitAs/limitFsize/limitCore, and `req[lkMemory]`
## had NO config/CLI surface at all. This slice wires the remaining four
## rlimit-* config keys + CLI flags, and a brand-new `limit-memory` key/flag
## for the cgroup-tier memory ceiling (`req[lkMemory]`), all the way through
## to `resolveSandbox`.
##
## Driven through the REAL entry point (`crisol run --json`), same idiom as
## test_rfc0007_a5_rusage_limits_wire.nim (temp project dir + crisol.kdl) and
## test_rfc0007_a1b_kill_path.nim (in-process `runMain`, parse stdout JSON).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_w2_limit_wiring.nim

import std/[json, options, os, times, unittest]
import crisol         # imports runMain
import crisol/process  # capabilities() — tier-aware assertion in suite 2
import ../support/capture

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc firstEntrypoint(jsonText: string): JsonNode =
  let doc = parseJson(jsonText)
  check doc["entrypoints"].len == 1
  doc["entrypoints"][0]

proc writeFD(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_w2_" & tag & "_" & $getCurrentProcessId() & "_" & $epochTime().int64)

# ---------------------------------------------------------------------------
# Suite 1 (TRACER) — `rlimit-cpu` reaches resolveSandbox -> req[lkCpu] ->
# a real SIGXCPU, attributed cbLimit(lkCpu) on the wire.
# ---------------------------------------------------------------------------

const RlimitCpuKdl = """
rlimit-cpu 1
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

suite "rfc-0007 W2 — rlimit-cpu config key reaches resolveSandbox (cbLimit/lkCpu tracer)":

  test "rlimit-cpu 1: a CPU-spinning entrypoint is SIGXCPU-killed, cause.by=limit/cpu":
    let root = uniqueTmpDir("cpu")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_rlimit_cpu.nim", readFile(fixtureDir() / "rlimit_cpu.nim"))
    writeFile(root / "crisol.kdl", RlimitCpuKdl)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    # Generous wall-clock --timeout (10s) so the runner's OWN deadline never
    # wins the race against RLIMIT_CPU (which fires within ~1-2 CPU-seconds
    # of a 1-second cpu limit on any host) -- this test asserts the runner-
    # side ATTRIBUTION, never a latency threshold.
    let output = captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1", "--timeout", "10", "--json", "--no-cache"]))
    let ep = firstEntrypoint(output)

    check ep["run"]["kind"].getStr == "ran"
    # cbLimit + ekSignaled derives oCrashed, NOT oKilled (outcome() only
    # returns oKilled for cbRunner -- see types.outcome/test_process_
    # deriveoutcome.nim's "run pkRan, cbLimit, ekSignaled -> oCrashed" case).
    # A limit-authored kill is a real crash from the runner's authorship
    # point of view: the runner never sent this signal, the KERNEL did.
    check ep["outcome"].getStr == "crashed"
    check ep["run"]["cause"]["by"].getStr == "limit"
    check ep["run"]["cause"]["limit"].getStr == "cpu"
    check ep["run"]["exit"]["kind"].getStr == "signaled"
    check ep["run"]["exit"]["sig"].getInt == 24  # SIGXCPU (POSIX-standard number)

# ---------------------------------------------------------------------------
# Suite 1b — precedence: CLI --rlimit-cpu overrides a same-named config
# value (mirrors --rlimit-nofile's CLI-wins-over-config idiom, api.nim
# planImpl's `if opts.rlimitCpu.isSome: cfg.rlimitCpu = opts.rlimitCpu`).
# ---------------------------------------------------------------------------

const RlimitCpuGenerousKdl = """
rlimit-cpu 100
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

suite "rfc-0007 W2 — CLI --rlimit-cpu overrides Config.rlimitCpu (precedence)":

  test "config rlimit-cpu 100 + CLI --rlimit-cpu 1: the CLI value wins, SIGXCPU fires quickly":
    let root = uniqueTmpDir("cpuprec")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_rlimit_cpu.nim", readFile(fixtureDir() / "rlimit_cpu.nim"))
    # A config value (100s) that would never fire inside this test's own
    # --timeout budget if left unoverridden -- proving the CLI flag, not
    # the config default, is what actually reached resolveSandbox.
    writeFile(root / "crisol.kdl", RlimitCpuGenerousKdl)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let output = captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1", "--timeout", "10", "--rlimit-cpu", "1",
                        "--json", "--no-cache"]))
    let ep = firstEntrypoint(output)

    check ep["run"]["cause"]["by"].getStr == "limit"
    check ep["run"]["cause"]["limit"].getStr == "cpu"
    check ep["run"]["exit"]["sig"].getInt == 24  # SIGXCPU

# ---------------------------------------------------------------------------
# Suite 2 — `limit-memory` honest degradation: req[lkMemory] reaches
# resolveSandbox even where the cgroup tier cannot deliver it (container /
# no delegation), and the run still passes (cacheable-with-label).
# ---------------------------------------------------------------------------

const LimitMemoryKdl = """
limit-memory 67108864
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

suite "rfc-0007 W2 — limit-memory config key reaches resolveSandbox (honest degradation)":

  test "limit-memory 67108864: run.evidence.limits.memory is the honest achieved status, run still passes":
    let root = uniqueTmpDir("mem")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_pass_always.nim", readFile(fixtureDir() / "pass_always.nim"))
    writeFile(root / "crisol.kdl", LimitMemoryKdl)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    var code = 0
    let output = captureStdout(proc() =
      code = runMain(@["run", "--jobs", "1", "--json", "--no-cache"]))
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["run"]["kind"].getStr == "ran"
    require ep["run"].hasKey("evidence")
    let memStatus = ep["run"]["evidence"]["limits"]["memory"].getStr

    # Tier-aware: on a delegated cgroup-v2 host with a usable memory
    # controller, req[lkMemory] is actually appliable ("applied"); every
    # other tier (rootless podman dev, most CI legs) honestly reports
    # "unsupported" -- BOTH are the cacheable-with-label class
    # (evidenceSatisfies never rejects lsUnsupported), so the run passing
    # either way is the real assertion, not a tier-specific status string.
    if capabilities().cgroupDelegation:
      check memStatus in ["applied", "unsupported"]
    else:
      check memStatus == "unsupported"
    check ep["outcome"].getStr == "passed"
