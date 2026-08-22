## test_zero_runnable.nim — CLI integration tests for zero-runnable exit-0 branches.
##
## Verifies the three branches that yield exit 0 with zero runnable entrypoints:
##   1. --changed on a clean git tree (nothing affected) — requires seeding the dep graph
##      so narrowByDiff can find a precise closure, not the conservative graph-absent fallback
##   2. --failed with no failed entrypoints from prior run
##   3. All selected entrypoints gated out
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_zero_runnable.nim

import std/[monotimes, os, osproc, sets, strutils, unittest]
import std/posix as posix_mod
import crisol
import crisol/types
import crisol/jsonout
import crisol/depgraph
import crisol/nimprobe  # for cachedNimFingerprint (the fingerprint runMain seeds/reads with)
import crisol/planner  # for CrisolProtocolMajor

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  result = getTempDir() / ("crisol_zr_" & tag & "_" & $mono.ticks)
  createDir(result)

proc git(repo: string; args: string): tuple[output: string; exitCode: int] =
  ## Run `git <args>` in `repo`.
  execCmdEx("git " & args, workingDir = repo)

proc initRepo(repo: string) =
  ## git init + minimal identity so commits succeed in a clean container.
  discard git(repo, "init -q")
  discard git(repo, "config user.email crisol@test.local")
  discard git(repo, "config user.name crisol-test")
  discard git(repo, "config commit.gpgsign false")

proc writeF(repo, rel, content: string) =
  let p = repo / rel
  createDir(p.parentDir)
  writeFile(p, content)

# A trivially-passing test body.
const PassBody = """
import std/unittest
suite "x":
  test "ok": check true
"""

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_zr_cap_" & $getMonoTime().ticks & ".txt")
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

# ---------------------------------------------------------------------------
# Suite 1 — --changed on a clean tree with seeded dep graph → exit 0
# ---------------------------------------------------------------------------

suite "crisol zero-runnable — branch 1: --changed clean tree":

  test "--changed with dep-graph-seeded clean tree → exit 0":
    ## To exercise the zero-runnable --changed branch, we need the dep graph
    ## to have entries (so narrowByDiff does NOT fall back to "graph absent =
    ## conservative full-run") AND the changed set must be empty (clean tree).
    ##
    ## We seed the dep graph manually before calling runMain.  The seed graph
    ## MUST use cachedNimFingerprint() — the same runtime fingerprint runMain
    ## now threads into loadDepGraph (via api.nim's cachedNimFingerprint(),
    ## not the compile-time crisolNimVersion string) — or the graph is
    ## treated as version-mismatched (cold-start empty), the precise closure
    ## is lost, and the ep is force-run instead of narrowed away.
    ##
    ## With a precise graph + empty changedSet, narrowByDiff excludes the ep
    ## (closure ∩ {} = ∅) → runnable == 0 → useChanged branch → exit 0.
    let repo = uniqueTmpDir("clean")
    defer: removeDir(repo)
    initRepo(repo)
    writeF(repo, "tests/unit/test_a.nim", PassBody)
    createDir(repo / ".crisol")

    # Write a minimal crisol.kdl so loadConfig roots at `repo`.
    writeFile(repo / "crisol.kdl",
      "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

    # Seed the dep graph: one entry for test_a.nim, closure = {test_a.nim}.
    # nimVersion=cachedNimFingerprint() matches what runMain passes to
    # loadDepGraph, so the seeded graph is read back as a precise (non-stale) match.
    let epPath = "tests/unit/test_a.nim"
    let fHash  = flagHash(@[])
    let closureSet = [epPath].toHashSet
    let cHash  = closureContentHash(@[epPath], repo)
    var graph  = initDepGraph(cachedNimFingerprint())
    graph.updateEntry(
      epPath, fHash, closureSet,
      closureHash   = cHash,
      protocolMajor = CrisolProtocolMajor,
    )
    let cfg = Config(
      projectRoot:        repo,
      stateDir:           ".crisol",
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    doAssert saveDepGraph(graph, cfg)

    # Git commit so there IS a HEAD, then clean tree.
    discard git(repo, "add -A")
    discard git(repo, "commit -q -m initial")

    let oldCwd = getCurrentDir()
    setCurrentDir(repo)
    defer: setCurrentDir(oldCwd)

    # Run with --changed. Tree is clean → changedSet empty → closure ∩ {} = ∅
    # → runnable == 0 → exit 0 with "nothing affected" message.
    let r = captureStdout(@["run", "--changed"])
    check r.code == 0
    check "nothing" in r.output

# ---------------------------------------------------------------------------
# Suite 2 — --failed with no prior failures → exit 0
# ---------------------------------------------------------------------------

suite "crisol zero-runnable — branch 2: --failed no prior failures":

  test "--failed when prior run had no failures → exit 0":
    ## Seed a lastrun.json where all entrypoints passed.
    ## --failed yields an empty failed-key set → runnable == 0 → exit 0.
    let repo = uniqueTmpDir("nofail")
    defer: removeDir(repo)
    initRepo(repo)
    writeF(repo, "tests/unit/test_a.nim", PassBody)
    discard git(repo, "add -A")
    discard git(repo, "commit -q -m initial")

    # Write a minimal crisol.kdl so loadConfig roots at `repo`.
    writeFile(repo / "crisol.kdl",
      "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

    # Build a cfg that points at this temp project root.
    let cfg = Config(
      projectRoot:        repo,
      stateDir:           ".crisol",
      groups:             @[],
      jobs:               1,
      timeoutSecs:        30,
      compileTimeoutSecs: 60,
      maxOutputBytes:     65536,
    )
    createDir(repo / ".crisol")

    # Seed lastrun.json: test_a passed (no failures).
    let results = @[
      EntrypointResult(
        ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit", flags: @[]),
        outcome: oPassed, exitCode: 0, signal: 0, durationMs: 10, records: @[]),
    ]
    persistLastRun(results, Summary(total: 1, passed: 1), cfg)

    let oldCwd = getCurrentDir()
    setCurrentDir(repo)
    defer: setCurrentDir(oldCwd)

    # --failed with no prior failures → exit 0.
    let code = runMain(@["run", "--failed"])
    check code == 0

# ---------------------------------------------------------------------------
# Suite 3 — all groups gated out → exit 0
# ---------------------------------------------------------------------------

suite "crisol zero-runnable — branch 3: all groups gated out":

  test "all entrypoints gated out by an unset env var → exit 0":
    ## Write a crisol.kdl with a gate on an env var that is NOT set.
    ## Discovery finds the test file, but applyGates removes it → gatedOut
    ## non-empty, runnable == 0 → exit 0 with a clear message.
    let repo = uniqueTmpDir("gated")
    defer: removeDir(repo)
    initRepo(repo)
    writeF(repo, "tests/unit/test_a.nim", PassBody)
    discard git(repo, "add -A")
    discard git(repo, "commit -q -m initial")

    # Write a crisol.kdl with a gate on a definitely-unset env var.
    let kdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
    gate "CRISOL_ZERO_RUNNABLE_TEST_GATE_NOTSET_XYZ_12345"
}
"""
    writeFile(repo / "crisol.kdl", kdl)

    let oldCwd = getCurrentDir()
    setCurrentDir(repo)
    defer: setCurrentDir(oldCwd)

    let r = captureStdout(@["run"])
    check r.code == 0
    check "gated out" in r.output or "gated" in r.output or
          r.output.contains("nothing to run")
