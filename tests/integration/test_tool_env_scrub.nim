## test_tool_env_scrub.nim — CR18: a tool crisol spawns never inherits the
## remote-cache credentials.
##
## `CRISOL_CACHE_TOKEN[_<TIER>]`, `CRISOL_CACHE_HMAC_KEY` and
## `CRISOL_CACHE_SIGN_KEY` are env-borne (`cacheregistry`). A cache-enabled
## `runTestsWith` resolves them and `delEnv`s the namespace before its first
## child, but every other path that spawns a tool does not: a `--no-cache`
## run (the scrub is skipped by design, RFC-0005 D5), `planTests`,
## `closureReport`, `crisol clean`, and any library caller. The compiler
## probes, the header probe and git then handed the credential to whatever
## PATH resolved `cc`/`gcc.exe`/`vccexe.exe`/`git` to. `toolexec.runTool` now
## removes the whole `CRISOL_CACHE_*` namespace from every tool's
## environment, without touching crisol's own.
##
## Pinned through both entry points: `runTool` directly (bounded and
## `NoDeadline`) and `toolrun.realRun`, the seam the probes use. The
## CONTROL variable must still arrive, so a pass cannot come from a child
## that inherited nothing. On Windows, where variable names are
## case-insensitive, a lower-case spelling is stripped too (crisol's own
## `getEnv` would read it).
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_tool_env_scrub.nim

import std/[os, osproc, strutils, unittest]
import crisol/[toolexec, toolrun]

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin" / "envscrub"
  cacheDir   = fixtureDir / "nimcache" / "envscrub"

let probeBin = block:
  createDir(binDir)
  let b = binDir / "cache_env_probe".addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --nimcache:" &
                          (cacheDir / "cache_env_probe") & " -o:" & b & " " &
                          (fixtureDir / "cache_env_probe.nim"))
  doAssert rc == 0, "cache_env_probe compile failed:\n" & o
  b

const Secrets = ["CRISOL_CACHE_TOKEN", "CRISOL_CACHE_TOKEN_MIRROR",
                 "CRISOL_CACHE_HMAC_KEY", "CRISOL_CACHE_SIGN_KEY"]

template withSecrets(body: untyped) =
  for s in Secrets: putEnv(s, "secret-" & s)
  putEnv("CRISOL_TOOL_CONTROL", "visible")
  when defined(windows):
    putEnv("crisol_cache_token_lc", "secret-lower")
  try:
    body
  finally:
    for s in Secrets: delEnv(s)
    delEnv("CRISOL_TOOL_CONTROL")
    when defined(windows):
      delEnv("crisol_cache_token_lc")

template checkScrubbed(run: RunResult) =
  ## A template, not a proc: `check` marks the enclosing test failed only
  ## when it expands inside the test body.
  let r = run
  checkpoint("run: " & describe(r))
  check r.ending == reExited
  if r.ending == reExited:
    checkpoint("child saw:\n" & r.output)
    for s in Secrets:
      check (s & "=<UNSET>") in r.output
    check "CRISOL_TOOL_CONTROL=visible" in r.output
    when defined(windows):
      check "CRISOL_CACHE_TOKEN_LC=<UNSET>" in r.output

suite "CR18 — tools never inherit the CRISOL_CACHE_* credentials":

  test "runTool, bounded":
    withSecrets:
      checkScrubbed(runTool(probeBin, [], "", {poUsePath}, "", 10_000,
                            MaxToolOutputBytes))

  test "runTool, NoDeadline":
    withSecrets:
      checkScrubbed(runTool(probeBin, [], "", {poUsePath}, "", NoDeadline,
                            MaxToolOutputBytes))

  test "toolrun.realRun, the probe seam":
    withSecrets:
      checkScrubbed(realRun(probeBin, []))

  test "crisol's own environment is left as it was":
    withSecrets:
      discard runTool(probeBin, [], "", {poUsePath}, "", 10_000,
                      MaxToolOutputBytes)
      for s in Secrets:
        check getEnv(s) == "secret-" & s

when isMainModule:
  echo "test_tool_env_scrub done"
