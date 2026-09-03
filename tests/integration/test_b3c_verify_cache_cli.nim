## test_b3c_verify_cache_cli.nim — RFC-0005 B3c E2E ("E2E-B verify half"):
## `--verify-cache` / `--verify-cache-pct` / `--verify-cache-seed` /
## `--verify-cache-strict` through the REAL entry point (`crisol run`), not
## the library facade directly (that is B3b's test_b3b_verify_cache.nim,
## which this file deliberately reuses the nondeterministic counter-file
## fixture recipe from).
##
## Properties pinned:
##   1. Nondeterministic fixture + `--verify-cache --verify-cache-pct 100
##      --verify-cache-seed 1 --json` -> a stderr divergence warning naming
##      the entrypoint AND a nonzero top-level `verifyFails` in the run/v2
##      JSON document, with the process exit code staying 0 (unstrict).
##   2. The identical scenario with `--verify-cache-strict` added flips the
##      exit code to 1 -- the CI gate -- while leaving the JSON/stderr shape
##      the same.
##   3. A deterministic fixture never diverges: `verifyFails == 0`, exit 0.
##   4. Each of `--verify-cache-pct`, `--verify-cache-seed`, and
##      `--verify-cache-strict` REQUIRES `--verify-cache`; given alone, each
##      exits `ExitEnvironment` (3) with a message naming the missing flag,
##      the same shape as `--base` requiring `--changed`.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_b3c_verify_cache_cli.nim

import std/[json, os, strutils, times, unittest]
import std/posix as posix_mod
import crisol   # runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshProjectRoot(name: string): string =
  ## A dedicated temp project (own crisol.kdl + .crisol state dir) so this
  ## file's cache entries / counter files never collide across cases.
  result = getTempDir() / ("crisol_b3c_" & name & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

## Flips its exit code on every REAL execution, tracked via a counter file
## written to the project root (spawnRunDirect's CWD).  Odd invocation count
## -> exit 0 (so the first live run passes and stores); even -> exit 1.
## Identical recipe to test_b3b_verify_cache.nim's NondeterministicFixture.
const NondeterministicFixture = """
import std/[os, strutils]
const counterFile = "verify_counter.txt"
var n = 0
if fileExists(counterFile):
  n = parseInt(readFile(counterFile).strip())
inc n
writeFile(counterFile, $n)
if n mod 2 == 1: quit(0) else: quit(1)
"""

const DeterministicFixture = "quit(0)\n"

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  ## Captures BOTH stdout and stderr of one runMain() invocation
  ## simultaneously (fd 1 -> outPath, fd 2 -> errPath) -- neither of the
  ## codebase's existing single-stream capture helpers
  ## (test_cli_s4.captureStdout/captureStderr,
  ## test_rfc0007_a6a_cli.captureStdout) covers both at once, and this
  ## file's tracer needs the JSON on stdout AND the divergence warning on
  ## stderr from the SAME call.
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_b3c_out_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_b3c_err_" & tag & ".txt")
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
# 1 + 2 — nondeterministic fixture: divergence surfaces on the wire and in
# stderr; --verify-cache-strict flips the exit code, plain --verify-cache
# does not.
# ---------------------------------------------------------------------------

suite "B3c CLI — nondeterministic fixture: verifyFails + stderr warning":

  test "unstrict: verifyFails nonzero, stderr warns, exit stays 0":
    let root = freshProjectRoot("flip_unstrict")
    defer: removeDir(root)
    let epPath = "tests/unit/test_flip.nim"
    writeFile(root / epPath, NondeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    # Run 1: live, populates the cache (n=1, odd -> exit 0 -> stored).
    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    # Run 2: served from cache; --verify-cache re-executes the sampled hit
    # for real (n=2, even -> exit 1) -> diverges from the stored exit 0.
    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache", "--verify-cache-pct", "100",
                          "--verify-cache-seed", "1", "--json"])
    check r.code == 0   # unstrict: divergence never touches the exit code

    let doc = parseJson(r.stdout)
    check doc["verifyFails"].getInt == 1
    check doc["schemaRevision"].getInt >= 19

    check epPath in r.stderr
    check "diverg" in r.stderr.toLowerAscii

  test "strict: the SAME divergence flips the exit code to 1":
    let root = freshProjectRoot("flip_strict")
    defer: removeDir(root)
    let epPath = "tests/unit/test_flip.nim"
    writeFile(root / epPath, NondeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache", "--verify-cache-pct", "100",
                          "--verify-cache-seed", "1", "--verify-cache-strict",
                          "--json"])
    check r.code == 1   # strict: a divergence set is a CI-gate failure

    let doc = parseJson(r.stdout)
    check doc["verifyFails"].getInt == 1
    check epPath in r.stderr

# ---------------------------------------------------------------------------
# 1b — omitting --verify-cache-pct falls back to the KDL verify-cache-pct
# config default, not the flat built-in 5 (proves the CLI's config-peek
# merge is genuinely live, not dead substrate: a config-set 0 %% silences
# sampling entirely even though the hit set would otherwise diverge).
# ---------------------------------------------------------------------------

suite "B3c CLI — omitted --verify-cache-pct honors the KDL verify-cache-pct default":

  test "verify-cache-pct 0 in crisol.kdl + bare --verify-cache -> zero samples taken":
    let root = freshProjectRoot("cfg_pct_zero")
    defer: removeDir(root)
    let epPath = "tests/unit/test_flip.nim"
    writeFile(root / epPath, NondeterministicFixture)
    let cfgPath = root / "crisol.kdl"
    # Overwrite freshProjectRoot's minimal config with one that sets
    # verify-cache-pct 0 -- if the CLI's config-peek merge were dead code
    # (always falling back to the flat built-in default of 5), the single
    # cdmHit entry would still be sampled (sampleHitIndices floors sample
    # size to max(1, ...) whenever pct > 0) and diverge; verifyFails would
    # then be 1, not 0.
    writeFile(cfgPath, """
verify-cache-pct 0
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")

    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache", "--json"])
    check r.code == 0
    let doc = parseJson(r.stdout)
    check doc["verifyFails"].getInt == 0
    check "diverg" notin r.stderr.toLowerAscii

# ---------------------------------------------------------------------------
# 3 — deterministic fixture: no divergence, ever.
# ---------------------------------------------------------------------------

suite "B3c CLI — deterministic fixture: verifyFails == 0":

  test "quit(0) fixture: verifyFails 0, no stderr warning, exit 0 even under strict":
    let root = freshProjectRoot("pass")
    defer: removeDir(root)
    let epPath = "tests/unit/test_pass.nim"
    writeFile(root / epPath, DeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    let pop = captureBoth(@["run", "--config", cfgPath, "--jobs", "1"])
    check pop.code == 0

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache", "--verify-cache-pct", "100",
                          "--verify-cache-strict", "--json"])
    check r.code == 0
    let doc = parseJson(r.stdout)
    check doc["verifyFails"].getInt == 0
    check "diverg" notin r.stderr.toLowerAscii

# ---------------------------------------------------------------------------
# 4 — the three parameter flags each REQUIRE --verify-cache.
# ---------------------------------------------------------------------------

suite "B3c CLI — --verify-cache-{pct,seed,strict} each require --verify-cache":

  test "--verify-cache-strict without --verify-cache -> ExitEnvironment (3)":
    let root = freshProjectRoot("strict_alone")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass.nim", DeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache-strict"])
    check r.code == 3
    check "--verify-cache" in r.stderr

  test "--verify-cache-pct without --verify-cache -> ExitEnvironment (3)":
    let root = freshProjectRoot("pct_alone")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass.nim", DeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache-pct", "50"])
    check r.code == 3
    check "--verify-cache" in r.stderr

  test "--verify-cache-seed without --verify-cache -> ExitEnvironment (3)":
    let root = freshProjectRoot("seed_alone")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_pass.nim", DeterministicFixture)
    let cfgPath = root / "crisol.kdl"

    let r = captureBoth(@["run", "--config", cfgPath, "--jobs", "1",
                          "--verify-cache-seed", "7"])
    check r.code == 3
    check "--verify-cache" in r.stderr

when isMainModule:
  echo "test_b3c_verify_cache_cli: done"
