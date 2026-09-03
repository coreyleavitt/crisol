## test_rfc0007_a5_rusage_limits_wire.nim — rfc-0007 A5 E2E: rusage and
## per-limit evidence, proven through the real entry point (`crisol run
## --json`).
##
## This is the slice's load-bearing tracer: §7 says "Rusage is a new
## quantity, not a replacement" — the wait4-reaped rusage (populated at
## every reap site since A1b) must actually reach the crisol/run/v2 wire,
## not just live in ProcessResult unobserved. Two properties, both asserted
## through the CLI's `--json` output:
##
##   1. A trivial passing binary's run/v2 entry carries a real, non-null
##      `run.rusage` with a plausible nonzero `maxRssBytes` — proof the
##      wait4 producer (A1b) reaches the wire (process/resultjson.toJson
##      already renders it; this is the first CLI-level pin).
##
##   2. A limits-configured group (crisol.kdl `rlimit-nofile N`, which
##      resolveSandbox folds into the default hlIsolated sandbox spec
##      alongside RLIMIT_FSIZE/RLIMIT_CORE) shows REAL per-limit
##      `run.evidence.limits` statuses on the wire ("applied" for the three
##      requested-by-default kinds, "notRequested" for the two that stay
##      unrequested). Before this slice, runner.nim's `toProcessResult`
##      built `evidence` from `default(ptypes.Evidence)` unconditionally —
##      the achieved per-limit readback (`ReapReport.limits`) was computed
##      by the Supervisor but discarded before it ever reached the wire, so
##      `evidence.limits` always read all-"notRequested" regardless of what
##      actually happened. This test is RED against that behavior.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a5_rusage_limits_wire.nim

import std/[json, os, times, unittest]
import std/posix as posix_mod
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  ## Same idiom as test_rfc0007_a1b_kill_path.nim's captureStdout — not
  ## imported, so this file has no test-to-test dependency.
  let outPath = getTempDir() / ("crisol_rfc0007_a5_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc firstEntrypoint(jsonText: string): JsonNode =
  let doc = parseJson(jsonText)
  check doc["entrypoints"].len == 1
  doc["entrypoints"][0]

proc writeFD(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc uniqueTmpDir(tag: string): string =
  getTempDir() / ("crisol_a5_" & tag & "_" & $getpid() & "_" & $epochTime().int64)

# ---------------------------------------------------------------------------
# Suite 1 — rusage reaches the wire
# ---------------------------------------------------------------------------

suite "rfc-0007 A5 — rusage reaches the crisol/run/v2 wire":

  test "pass_always: run.rusage is non-null with a plausible nonzero maxRssBytes":
    let fd = fixtureDir()
    let (code, output) = captureStdout(@["run", fd / "pass_always.nim",
                                         "--jobs", "1", "--json", "--no-cache"])
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["run"]["kind"].getStr == "ran"
    require ep["run"].hasKey("rusage")
    check ep["run"]["rusage"].kind == JObject   # never null for a real live run
    check ep["run"]["rusage"]["maxRssBytes"].getBiggestInt > 0
    # §7 "Rusage is a new quantity, not a replacement": userCpuUs/sysCpuUs are
    # rendered too, no zero-filled fabrication — just present, whatever wait4
    # actually observed (a trivial quit(0) binary may report 0 CPU time).
    check ep["run"]["rusage"].hasKey("userCpuUs")
    check ep["run"]["rusage"].hasKey("sysCpuUs")

# ---------------------------------------------------------------------------
# Suite 2 — per-limit evidence reaches the wire
# ---------------------------------------------------------------------------

const LimitedGroupKdl = """
rlimit-nofile 64
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

suite "rfc-0007 A5 — per-limit evidence.limits reaches the crisol/run/v2 wire":

  test "limits-configured group: run.evidence.limits shows REAL achieved statuses":
    let root = uniqueTmpDir("limits")
    defer: removeDir(root)
    writeFD(root, "tests/unit/test_pass_always.nim", readFile(fixtureDir() / "pass_always.nim"))
    writeFile(root / "crisol.kdl", LimitedGroupKdl)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let (code, output) = captureStdout(@["run", "--jobs", "1", "--json", "--no-cache"])
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["run"]["kind"].getStr == "ran"
    require ep["run"].hasKey("evidence")
    let limits = ep["run"]["evidence"]["limits"]

    # The default hlIsolated sandbox requests fileSize/openFiles/core (with
    # openFiles overridden to 64 by the config above) — all three must read
    # back "applied", the REAL per-limit readback from the Supervisor's
    # ReapReport, not the always-"notRequested" placeholder this slice fixes.
    check limits["fileSize"].getStr  == "applied"
    check limits["openFiles"].getStr == "applied"
    check limits["core"].getStr      == "applied"
    # cpu/addressSpace stay unrequested by default — the honest negative.
    check limits["cpu"].getStr         == "notRequested"
    check limits["addressSpace"].getStr == "notRequested"

when isMainModule:
  echo "test_rfc0007_a5_rusage_limits_wire done"
