## test_windows_cli_smoke.nim — rfc-0007 D2a-6: the LOAD-BEARING liveness
## proof for Stage D.
##
## D2a-5 (httpraw de-POSIXed) closed the last windows compile gap in
## crisol's dependency closure, so `src/crisol.nim` — the real product CLI
## entrypoint — now compiles clean under `--os:windows`. That was necessary
## but not sufficient: a clean compile proves the compiler accepts the
## code, not that the resulting binary actually RUNS a test and reports a
## real pass. This file closes that gap: it builds the genuine `crisol`
## binary from source, points it at a throwaway one-entrypoint project, runs
## `crisol run --jobs 1 --json` as a real subprocess, and asserts the
## resulting crisol/run/v2 JSON document reports exactly one passing
## entrypoint. That is the end-to-end liveness proof for all of Stage D —
## crisol's actual product runs on Windows, not just compiles.
##
## Compile-time gated to `defined(windows)`, mirroring test_windows_smoke.nim
## in this directory: crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform, so the `else`
## branch below must compile and exit cleanly on Linux/macOS too; only a
## `windows-latest` CI leg (or a real Windows host) ever executes the body.
##
## Imports ONLY std/[json, os, osproc, streams, unittest] (streams for
## osproc's Stream.readAll — osproc does not re-export it) — no std/posix,
## no crisol modules, no `./helpers` — so this file runs standalone
## pre-RFC-0009 (the process-backend conformance harness this directory
## otherwise depends on is itself not yet proven on windows; this smoke
## test cannot depend on it). It shells out to a REAL compiled `crisol`
## binary via osproc rather than calling library code in-process, exactly
## mirroring how a real user invokes crisol from a shell.

when defined(windows):
  import std/[json, os, osproc, streams, unittest]

  const projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    ## tests/conformance/test_windows_cli_smoke.nim -> tests/conformance ->
    ## tests -> repo root.

  suite "rfc-0007 D2a-6 — windows CLI liveness: crisol run --json end-to-end":

    test "real crisol binary, real subprocess run, one entrypoint passes":
      # 1. Build the real CLI binary once, in an isolated nimcache so this
      #    build never races the suite's own compile cache.
      let workDir = getTempDir() / "crisol_cli_smoke"
      removeDir(workDir)
      createDir(workDir)
      let crisolBin = workDir / "crisol"
      let nimcache = getTempDir() / "crisol_cli_smoke_nimcache"
      removeDir(nimcache)
      let buildCmd = "nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                     nimcache.quoteShell &
                     " --path:" & (projectRoot / "src").quoteShell &
                     " -o:" & crisolBin.quoteShell & " " &
                     (projectRoot / "src" / "crisol.nim").quoteShell
      let (buildOut, buildCode) = execCmdEx(buildCmd)
      if buildCode != 0:
        echo "BUILD OUTPUT:\n" & buildOut
      check buildCode == 0   # if this fails, the CLI didn't compile on windows

      # 2. Stand up a throwaway project: one group, one trivially-passing
      #    entrypoint (mirrors tests/support/helpers.nim's withTempProject /
      #    MinimalCrisolKdl, inlined here since this file cannot import
      #    ./helpers).
      let proj = getTempDir() / "crisol_cli_smoke_proj_" & $getCurrentProcessId()
      removeDir(proj)
      createDir(proj)
      createDir(proj / ".crisol")
      createDir(proj / "tests" / "unit")
      writeFile(proj / "crisol.kdl", "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
      writeFile(proj / "tests" / "unit" / "test_smoke.nim", "quit(0)\n")

      # 3. Run `crisol run --jobs 1 --json` as a real subprocess, cwd = the
      #    project root (config walk-up finds crisol.kdl there). Keep
      #    stdout (the single JSON doc) separate from stderr (human-
      #    readable lines go to stderr in --json mode).
      let p = startProcess(crisolBin, workingDir = proj,
                            args = @["run", "--jobs", "1", "--json"],
                            options = {})
      let outText = p.outputStream.readAll()
      let errText = p.errorStream.readAll()
      let code = p.waitForExit()
      close(p)

      # 4. Assert a real run happened and passed.
      if code != 0:
        echo "STDERR:\n" & errText
        echo "STDOUT:\n" & outText
      check code == 0
      let doc =
        try:
          parseJson(outText)
        except CatchableError:
          echo "STDERR:\n" & errText
          echo "STDOUT:\n" & outText
          raise
      check doc["schema"].getStr == "crisol/run/v2"
      check doc["summary"]["total"].getInt == 1
      check doc["summary"]["counts"]["passed"].getInt == 1
      check doc["entrypoints"].len == 1
      check doc["entrypoints"][0]["outcome"].getStr == "passed"

      # Clean up.
      removeDir(proj)
      removeDir(workDir)
      removeDir(nimcache)

  when isMainModule:
    echo "test_windows_cli_smoke done"

else:
  when isMainModule:
    echo "test_windows_cli_smoke: skipped (not windows)"
