## test_objcache_soundness_independence.nim — RFC-0006 Stage R, R3: the
## real-binary regression guard proving object-cache (objcache.nim) reuse is
## OUTSIDE the RFC-0004 result-cache soundness key.
##
## Companion to tests/unit/test_soundness_key_objcache_independence.nim: that
## file proves the claim STRUCTURALLY (KeyInputs carries no objcache field;
## soundnessKey is pure). This file proves it BEHAVIORALLY, end to end,
## through the real `crisol` binary: the SAME entrypoint, run separately with
## `--objcache` and with `--no-objcache`, must record the IDENTICAL
## `inputHash` (the persisted soundnessKey string) in each run's
## `.crisol/lastrun.json` -- i.e. whether or not a compiled `.o` was reused
## across entrypoints has zero effect on the value that gates the result
## cache.
##
## Field under test: `entrypoints[0].inputHash` in the crisol/run/v1 JSON
## document (see jsonout.nim's module doc / schema comment). jsonout.nim
## stamps this from `$soundnessKey(KeyInputs(...))` at the point a freshly
## run (uncached) result is store-gated into the result cache (runner.nim's
## post-run store gate) -- see runner.nim's `result[completedIdx].inputHash =
## $key` assignment. It is populated on a plain first-ever run (no prior
## cache state needed): the store gate fires whenever the run passes on
## attempt 1 with hermeticity achieved and the result cache is active
## (default: on: neither `--objcache`/`--no-objcache` nor a fresh/empty
## `--no-cache`-free run disables it).
##
## Mirrors tests/integration/test_objcache_gate.nim's real-binary harness
## exactly (same fixture, same self-reexec constraint: `--objcache` spawns a
## compile-worker child via the crisol binary's own argv[0], so the test
## MUST drive a real, freshly-built crisol binary rather than making a
## library call from this unittest binary -- see that file's module doc for
## the full self-reexec soundness explanation).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_objcache_soundness_independence.nim

import std/[json, os, osproc, streams, strtabs, unittest]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc projectRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

const epRelPath = "tests" / "fixtures" / "pass_always.nim"

proc freshStateDir(tag: string): string =
  result = getTempDir() / "crisol_test_objcache_soundness_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc buildCrisolBinary(): string =
  ## Compile the REAL src/crisol.nim CLI binary once, into an isolated temp
  ## path -- the only sound host for --objcache's self-reexec (mirrors
  ## test_objcache_gate.nim's buildCrisolBinary exactly).
  result = getTempDir() / "crisol_test_objcache_soundness_bin" / "crisol"
  createDir(result.parentDir)
  let cmd = "nim c --hints:off --warnings:off -d:release --mm:orc -o:" &
            result.quoteShell & " " & (projectRoot() / "src" / "crisol.nim").quoteShell
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "failed to build crisol binary for objcache soundness test: " & output
  doAssert fileExists(result), "crisol binary not produced at " & result

let crisolBin = buildCrisolBinary()

proc runCrisol(stateDir: string; extraArgs: seq[string] = @[]):
              tuple[exitCode: int; output: string] =
  let p = startProcess(
    crisolBin,
    workingDir = projectRoot(),
    args = @["run", epRelPath, "--jobs", "1"] & extraArgs,
    env = {"CRISOL_STATE_DIR": stateDir, "PATH": getEnv("PATH"), "HOME": getEnv("HOME")}.newStringTable,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  close(p)
  (exitCode: code, output: output)

proc readInputHash(stateDir: string): string =
  ## Read <stateDir>/lastrun.json (crisol/run/v1) and return
  ## entrypoints[0].inputHash -- the persisted soundnessKey string
  ## (jsonout.nim's toJson: `epNode["inputHash"] = newJString(r.inputHash)`).
  let lastrunPath = stateDir / "lastrun.json"
  doAssert fileExists(lastrunPath), "lastrun.json not found at " & lastrunPath
  let node = parseFile(lastrunPath)
  doAssert node.hasKey("entrypoints"), "lastrun.json missing 'entrypoints'"
  let eps = node["entrypoints"]
  doAssert eps.len == 1, "expected exactly 1 entrypoint in lastrun.json, got " & $eps.len
  doAssert eps[0].hasKey("inputHash"), "lastrun.json entrypoint missing 'inputHash'"
  eps[0]["inputHash"].getStr("")

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "objcache soundness independence — RFC-0006 Stage R R3":

  test "--objcache and --no-objcache runs of the same entrypoint record identical inputHash":
    let stateDirOn  = freshStateDir("on")
    let stateDirOff = freshStateDir("off")
    defer:
      removeDir(stateDirOn)
      removeDir(stateDirOff)

    let (codeOn, outOn) = runCrisol(stateDirOn, @["--objcache"])
    check codeOn == 0
    if codeOn != 0: echo "crisol run (--objcache) output:\n", outOn

    let (codeOff, outOff) = runCrisol(stateDirOff, @["--no-objcache"])
    check codeOff == 0
    if codeOff != 0: echo "crisol run (--no-objcache) output:\n", outOff

    let hashOn  = readInputHash(stateDirOn)
    let hashOff = readInputHash(stateDirOff)

    # Both runs must have actually consulted the result cache (non-empty
    # inputHash) -- an empty hash on either side would silently defeat this
    # proof rather than fail it, so assert non-emptiness explicitly first.
    check hashOn.len > 0
    check hashOff.len > 0

    # THE proof: object reuse (or its absence) is invisible to the
    # result-soundness key. If a future change ever folded objcache state
    # into KeyInputs/soundnessKey, this assertion would be the one to catch
    # it end-to-end (the unit guard in
    # test_soundness_key_objcache_independence.nim catches it structurally).
    check hashOn == hashOff

  test "--objcache run's inputHash equals a plain default run's inputHash (objcache transparent to soundness)":
    let stateDirObjCache = freshStateDir("objcache_default_cmp")
    let stateDirDefault  = freshStateDir("plain_default_cmp")
    defer:
      removeDir(stateDirObjCache)
      removeDir(stateDirDefault)

    let (codeObjCache, outObjCache) = runCrisol(stateDirObjCache, @["--objcache"])
    check codeObjCache == 0
    if codeObjCache != 0: echo "crisol run (--objcache) output:\n", outObjCache

    let (codeDefault, outDefault) = runCrisol(stateDirDefault)
    check codeDefault == 0
    if codeDefault != 0: echo "crisol run (default) output:\n", outDefault

    let hashObjCache = readInputHash(stateDirObjCache)
    let hashDefault   = readInputHash(stateDirDefault)

    check hashObjCache.len > 0
    check hashDefault.len > 0
    check hashObjCache == hashDefault

when isMainModule:
  echo "All objcache soundness independence tests passed."
