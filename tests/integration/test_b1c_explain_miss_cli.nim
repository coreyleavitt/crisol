## test_b1c_explain_miss_cli.nim — RFC-0005 B1c E2E ("E2E-B explain half"):
## `--explain-miss` / `--explain-miss-verbose` through the REAL entry point
## (`crisol run`), not the library facade directly.
##
## Properties pinned (RFC-0005 line 542, E2E-B, explain half):
##   1. Run 1 populates the cache (live pass, stored + sidecar written).
##   2. Changing a compile flag (crisol.kdl group `flags`) and re-running
##      with `--explain-miss --json` produces a per-entrypoint `keyDiff`
##      array naming `kcFlags` with non-empty prev/curr, schemaRevision 21,
##      and stdout stays parseable JSON (the human explain line goes to
##      stderr instead).
##   3. Changing an allowlisted env var (via `--env-pin TERM=...`, which
##      routes through the SAME hermetic-env soundness component
##      regardless of the host's own TERM) and re-running with
##      `--explain-miss --json` names `kcHermeticEnv` AND the variable name
##      "TERM" in `envNames` — never the value.
##   4. The same flag-change scenario WITHOUT `--json` (human mode) prints
##      the `kcFlags` explanation to STDOUT (no stderr routing needed
##      outside --json mode).
##   5. Without `--explain-miss`, none of the above surfaces: no `keyDiff`
##      key in the JSON document, no "explain:" line in human output.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_b1c_explain_miss_cli.nim

import std/[json, os, sequtils, strutils, times, unittest]
import std/posix as posix_mod
import crisol   # runMain

# ---------------------------------------------------------------------------
# Helpers (mirrors test_b3c_verify_cache_cli.nim's captureBoth/freshProjectRoot)
# ---------------------------------------------------------------------------

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_b1c_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")

proc writeGroupConfig(root: string; flagsLine: string) =
  writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
    """ & flagsLine & """
}
""")

const PassFixture = "quit(0)\n"

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_b1c_out_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_b1c_err_" & tag & ".txt")
  let outF = open(outPath, fmWrite)
  let errF = open(errPath, fmWrite)
  let outFd: cint = outF.getFileHandle.cint
  let errFd: cint = errF.getFileHandle.cint
  let savedOutFd: cint = posix_mod.dup(1.cint)
  let savedErrFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(outFd, 1.cint)
  discard posix_mod.dup2(errFd, 2.cint)
  outF.close()
  errF.close()
  var code = 0
  try:
    code = runMain(args)
  finally:
    flushFile(stdout)
    flushFile(stderr)
    discard posix_mod.dup2(savedOutFd, 1.cint)
    discard posix_mod.dup2(savedErrFd, 2.cint)
    discard posix_mod.close(savedOutFd)
    discard posix_mod.close(savedErrFd)
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  try: removeFile(outPath) except CatchableError: discard
  try: removeFile(errPath) except CatchableError: discard
  (code: code, stdout: outText, stderr: errText)

# ---------------------------------------------------------------------------
# 1 + 2 — flag change surfaces kcFlags via --json (structured, stderr human)
# ---------------------------------------------------------------------------

suite "B1c CLI — --explain-miss over --json: kcFlags on a flag change":

  test "run1 populates; flag change + --explain-miss --json -> keyDiff names kcFlags, stdout parseable":
    let root = freshProjectRoot("flags_json")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    writeGroupConfig(root, "flags \"-d:e2ev1\"")
    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    writeGroupConfig(root, "flags \"-d:e2ev2\"")
    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--explain-miss", "--json"])
    check r.code == 0

    # stdout stays parseable JSON even with the flag on.
    let doc = parseJson(r.stdout)
    check doc["schemaRevision"].getInt == 21
    let eps = doc["entrypoints"]
    check eps.len == 1
    check eps[0].hasKey("keyDiff")
    var sawFlags = false
    var componentsSeen: seq[string] = @[]
    for kd in eps[0]["keyDiff"].elems:
      componentsSeen.add kd["component"].getStr
      if kd["component"].getStr == "kcFlags":
        sawFlags = true
        check kd["prev"].getStr.len > 0
        check kd["curr"].getStr.len > 0
        check kd["prev"].getStr != kd["curr"].getStr
    check sawFlags
    # A flag change makes this entrypoint recompile (edNeverBuilt --
    # planner.slug hashes ALL flags into the bin dir). Before RFC-0005
    # A2c-ii, the ONLY explain available for a recompiling entrypoint was
    # B1c's plan-time DIAGNOSTIC consult, taken before the depgraph had a
    # (path, NEW flagHash) entry -- keyOfProc derived a degenerate ("")
    # closureContentHash there, which spuriously diffed against the
    # sidecar's real recorded hash (an honest but incidental kcClosure
    # line). A2c-ii's post-compile consult (finalizeSlot, right after THIS
    # compile finishes) now runs a SECOND, REAL explain over the
    # JUST-updated depgraph entry -- its correct closureContentHash matches
    # the sidecar's (the source never changed, only the flags did), so the
    # incidental kcClosure noise is gone: the post-compile explain, being
    # strictly more accurate, is what the live result actually reports.
    # kcArgv still genuinely differs: argv's stable surrogate is
    # `<slug>/<binName>`, and slug is itself flag-dependent.
    check "kcClosure" notin componentsSeen
    check "kcArgv" in componentsSeen

    # The human explanation goes to STDERR in --json mode; stdout carries
    # ONLY the structured document -- "kcFlags" legitimately appears there
    # too (as the keyDiff[].component string value, asserted above), so the
    # correct negative check is that no HUMAN "explain:" line leaks into
    # stdout, not that the bare component name is absent from stdout.
    check "kcFlags" in r.stderr
    check "explain:" notin r.stdout

# ---------------------------------------------------------------------------
# 3 — env-pin change surfaces kcHermeticEnv + the variable NAME (never a value)
# ---------------------------------------------------------------------------

suite "B1c CLI — --explain-miss over --json: kcHermeticEnv names the variable on an env-pin change":

  test "run1 populates (TERM pinned); env-pin value change + --explain-miss --json -> keyDiff names TERM":
    let root = freshProjectRoot("env_json")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"
    writeGroupConfig(root, "")

    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                            "--env-pin", "TERM=e2e-term-v1"])
    check pop.code == 0

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--env-pin", "TERM=e2e-term-v2",
                          "--explain-miss", "--json"])
    check r.code == 0

    let doc = parseJson(r.stdout)
    let eps = doc["entrypoints"]
    check eps.len == 1
    var sawEnv = false
    for kd in eps[0]["keyDiff"].elems:
      if kd["component"].getStr == "kcHermeticEnv":
        sawEnv = true
        let names = kd["envNames"].elems.mapIt(it.getStr)
        check "TERM" in names
        # Never the value: neither pinned value string appears anywhere on
        # the wire for this component.
        check "e2e-term-v1" notin $kd
        check "e2e-term-v2" notin $kd
    check sawEnv

    check "kcHermeticEnv" in r.stderr
    check "TERM" in r.stderr

# ---------------------------------------------------------------------------
# 4 — the same flag-change scenario in HUMAN mode: explanation on stdout
# ---------------------------------------------------------------------------

suite "B1c CLI — --explain-miss, human mode: kcFlags line on stdout":

  test "flag change + --explain-miss (no --json) -> 'kcFlags' appears on stdout":
    let root = freshProjectRoot("flags_human")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    writeGroupConfig(root, "flags \"-d:e2ev1\"")
    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    writeGroupConfig(root, "flags \"-d:e2ev2\"")
    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1", "--explain-miss"])
    check r.code == 0
    check "kcFlags" in r.stdout
    check "explain:" in r.stdout

# ---------------------------------------------------------------------------
# 5 — without --explain-miss, nothing surfaces (default off, additive)
# ---------------------------------------------------------------------------

suite "B1c CLI — without --explain-miss: no keyDiff field, no explain line":

  test "flag change WITHOUT --explain-miss: no 'keyDiff' key, no 'explain:' anywhere":
    let root = freshProjectRoot("flags_off")
    defer: removeDir(root)
    let epPath = "tests/unit/test_a.nim"
    writeFile(root / epPath, PassFixture)
    let cfgPath = root / "crisol.kdl"

    writeGroupConfig(root, "flags \"-d:e2ev1\"")
    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    writeGroupConfig(root, "flags \"-d:e2ev2\"")
    let rJson = captureBoth(@["run", "--config", cfgPath, "--jobs", "1", "--json"])
    check rJson.code == 0
    let doc = parseJson(rJson.stdout)
    check not doc["entrypoints"][0].hasKey("keyDiff")
    check "explain:" notin rJson.stderr

    let rHuman = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check rHuman.code == 0
    check "explain:" notin rHuman.stdout

when isMainModule:
  echo "test_b1c_explain_miss_cli: done"
