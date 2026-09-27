## tests/integration/test_cc_depgraph_liveness.nim — W3 wiring-audit liveness proof.
##
## The bug this closes (docs/handoff/msvc-selection-layer.md, "Wiring audit
## — 2026-09-21", row W3): a prior slice made
## `depgraph.loadDepGraph`/`DepGraphHeader` C-toolchain-aware (a `ccVersion`
## sibling to the existing `nimVersion` freshness check), gave
## `planner.decideCompile` a matching `graph.header.ccVersion != ccVersion`
## arm, and unit-tested both — but `api.nim`'s `planImpl`, the ONE production
## caller of `pipeline.buildRunPlan`, never threaded a real
## `ccidentity.cachedCcVersion()` into that call. It silently took
## `buildRunPlan`'s old `ccVersion: string = ""` default instead, so every real
## `crisol run` wrote AND read the dep-graph header with `ccVersion == ""` and
## `loadDepGraph`'s `dgdCcVersion` discard arm could never observe a mismatch
## on a real run. Fully built, fully green at the unit layer, and completely
## dark in production — exactly the shape a unit test on the pure planner
## cannot catch (it was already green).
##
## WHICH MECHANISM THIS ACTUALLY PROVES (round-2 review correction, refreshed
## round 5 after R3-8). The paragraph above names two cc-awareness sites; this
## file only ever proved ONE of them, and saying otherwise was the same
## over-claim the review treats as a defect in its own right. Since round 5
## only one of the two still exists.
##
## Proved here: `depgraph.loadDepGraph`'s `dgdCcVersion` discard (its `if
## ccMismatch:` arm). Verified by mutation -- with that arm disabled, this file
## FAILS at the run-3 assertion below (`compileSkipped was true`). It is the
## real, and now sole, production enforcement point for "C toolchain moved ->
## recompile".
##
## NOT proved here, and NO LONGER PRESENT IN THE TREE: `planner.decideCompile`
## used to carry its own `graph.header.ccVersion != ccVersion` check (plus a
## `nimVersion` twin). Round 2 showed by mutation that disabling the planner
## check changed nothing here -- it was unreachable from any real run, because
## every production graph arrives via `loadDepGraph`, which discards on
## mismatch and re-stamps the header to the live value on its success path,
## making `graph.header.ccVersion == ccVersion` a structural invariant by the
## time `decideCompile` sees it. Round 5's R3-8 therefore DELETED both arms and
## both of `decideCompile`'s version parameters; `decideCompile`'s doc now
## carries a "TOOLCHAIN STALENESS IS NOT DECIDED HERE" paragraph right after
## its step list. Do not go looking in
## planner.nim for a cc-staleness check, and do not read a failure of this file
## as evidence about one.
##
## Where the unit-level coverage of the live mechanism lives: the four
## `block`s in tests/unit/test_depgraph.nim that assert the discard REASON,
## the REQUESTED-not-stored header stamp on the replacement graph, the
## nim-before-cc priority, and the success-path re-stamp --
## `test_nim_version_mismatch_reason_and_stamp`,
## `test_cc_version_mismatch_reason_and_stamp`,
## `test_both_versions_changed_reported_as_nim` and
## `test_success_path_restamps_header_to_live_versions` (grep
## `toolchain-staleness gate (R3-8 moved coverage)`). tests/unit/
## test_freshness.nim is NOT part of that coverage any more: the two hand-built
## "version changed -> cdStale" cases it used to hold went out with the arms
## they exercised (see its `MOVED OUT, round 5` note). This file remains the
## end-to-end leg named in R3-8's own rationale.
##
## This file proves the fix the way it must be proved: through the REAL
## product entry point, not the pure planner. It builds the genuine
## `crisol` binary from source (mirroring
## tests/conformance/test_windows_cli_smoke.nim, the load-bearing CLI-
## subprocess liveness pattern for this repo) and drives it with THREE real
## `crisol run --json` subprocess invocations against the SAME throwaway
## project:
##
##   1. cold start (no binary, no dep graph yet)            -> compiles
##   2. same environment, unchanged fixture                 -> skips (cached)
##   3. Nim UNCHANGED, the configured C compiler's identity
##      changed                                             -> recompiles
##
## Step 3 is the liveness assertion: `crisol run` probes the C toolchain once
## per process -- this is a FRESH subprocess, so it probes fresh, exactly like
## a real toolchain change between two invocations of the CLI -- observes the
## changed identity, threads it into `buildRunPlan` -> `loadDepGraph`, which
## discards the run-1/2 graph (`dgdCcVersion`) and returns an EMPTY one; the
## run-1/2 binary is still on disk, so `decideCompile` lands on its
## entry-absent-from-graph arm and returns `cdStale`, surfaced on the wire as
## `entrypoints[0].compileSkipped == false`. Before the fix, step 3 would
## report `compileSkipped == true` (cdSkipFresh) -- silently stale.
##
## The change must reach the compiler Nim is CONFIGURED to use (ccidentity
## probes that one, not whatever answers on PATH) and must still compile, so
## it depends on the configured family, which the test learns from the real
## probe:
##   - MSVC (`cl` through `vccexe`): run 3 sets `CL=/DW3_LIVENESS`. cl reads
##     it on every compile, and ccidentity folds its value into the compiler
##     digest.
##   - GNU family on POSIX: run 3 puts a directory first on PATH whose `gcc`,
##     `clang` and `cc` are shell wrappers that `exec` the real driver. The
##     compile is unchanged; the driver binary the probe hashes is not.
##   - GNU family on Windows (mingw): no wrapper can shadow a `.exe` without
##     building one; the test self-skips with a CRISOL-SKIP-TEST marker.
##
## No injection seam is used: the real probe runs in the real CLI.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]
import crisol/ccidentity  # the real probe, to learn the configured family
import "../support/ccprobes"

const projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  ## tests/integration/test_cc_depgraph_liveness.nim -> tests/integration ->
  ## tests -> repo root.

suite "W3 liveness — crisol run subprocess sees a real C toolchain change":

  test "Nim unchanged, cc identity changed -> recompile instead of cdSkipFresh":
    # 1. Build the real CLI binary once, isolated nimcache/workDir so this
    #    build never races any other suite's own compile cache.
    let workDir = getTempDir() / ("crisol_cc_depgraph_liveness_" & $getCurrentProcessId())
    removeDir(workDir)
    createDir(workDir)
    let crisolBin = workDir / "crisol"
    let nimcache = workDir / "nimcache_bin"
    let buildCmd = "nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                   nimcache.quoteShell &
                   " --path:" & (projectRoot / "src").quoteShell &
                   " -o:" & crisolBin.quoteShell & " " &
                   (projectRoot / "src" / "crisol.nim").quoteShell
    let (buildOut, buildCode) = execCmdEx(buildCmd)
    if buildCode != 0:
      echo "BUILD OUTPUT:\n" & buildOut
    check buildCode == 0   # if this fails, crisol.nim itself didn't compile

    # 2. A throwaway one-entrypoint project — mirrors
    #    test_windows_cli_smoke.nim's fixture shape.
    let proj = workDir / "proj"
    createDir(proj / ".crisol")
    createDir(proj / "tests" / "unit")
    writeFile(proj / "crisol.kdl",
              "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
    writeFile(proj / "tests" / "unit" / "test_smoke.nim", "quit(0)\n")

    # 3. The configured compiler's family, from the real probe over this
    #    project (its configuration is the global Nim configuration).
    let fp = ccFingerprint(CcProbeContext(projectRoot: proj,
                                          stateDir: proj / ".crisol",
                                          flags: @[]))
    checkpoint("configured toolchain = " & $fp & " / " & fp.compiler.why)
    require toolchainVerdict(fp).kind == tvIdentified
    let msvc = fp.compiler.text.startsWith("msvc ") or
               fp.compiler.text.startsWith("clang-cl ")

    # `env = nil` (osproc default) inherits the current process's real
    # environment/PATH for runs 1/2 -- the real `cc` on this host resolves
    # exactly the way an ordinary `crisol run` would.
    let realPath = getEnv("PATH")

    proc envWith(name, value: string): StringTableRef =
      result = newStringTable(modeCaseSensitive)
      for k, v in envPairs():
        result[k] = v
      result[name] = value

    proc runCrisol(env: StringTableRef): JsonNode =
      var p = startProcess(crisolBin, workingDir = proj,
                            args = @["run", "--jobs", "1", "--no-cache", "--json"],
                            env = env, options = {})
      let outText = p.outputStream.readAll()
      let errText = p.errorStream.readAll()
      let code = p.waitForExit()
      close(p)
      if code != 0:
        echo "STDERR:\n" & errText
        echo "STDOUT:\n" & outText
      check code == 0
      try:
        result = parseJson(outText)
      except CatchableError:
        echo "STDERR:\n" & errText
        echo "STDOUT:\n" & outText
        raise

    # --- Run 1: cold start, real cc on PATH -> must compile. ---
    let doc1 = runCrisol(envWith("PATH", realPath))
    check doc1["schema"].getStr == "crisol/run/v2"
    check doc1["entrypoints"].len == 1
    check doc1["entrypoints"][0]["outcome"].getStr == "passed"
    check doc1["entrypoints"][0]["compileSkipped"].getBool == false

    # --- Run 2: SAME environment, unchanged fixture -> must skip (baseline
    #     freshness works at all -- this is not yet the W3 assertion). ---
    let doc2 = runCrisol(envWith("PATH", realPath))
    check doc2["entrypoints"][0]["outcome"].getStr == "passed"
    check doc2["entrypoints"][0]["compileSkipped"].getBool == true

    # --- Run 3: Nim UNCHANGED, the configured compiler's identity changed
    #     -> THE W3 liveness assertion: must recompile, not skip. ---
    var run3: StringTableRef = nil
    if msvc:
      run3 = envWith("CL", "/DW3_LIVENESS")
    elif defined(posix):
      let shadowDir = workDir / "shadowcc"
      createDir(shadowDir)
      for driver in ["gcc", "clang", "cc"]:
        let real = findExe(driver)
        if real.len == 0: continue
        let wrapper = shadowDir / driver
        writeFile(wrapper, "#!/bin/sh\nexec " & real.quoteShell & " \"$@\"\n")
        setFilePermissions(wrapper,
          {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
           fpOthersRead, fpOthersExec})
      run3 = envWith("PATH", shadowDir & PathSep & realPath)
    if run3 == nil:
      echo "CRISOL-SKIP-TEST: tests/integration/test_cc_depgraph_liveness.nim#gnu_on_windows_no_shadow"
      skip()
    else:
      let doc3 = runCrisol(run3)
      check doc3["entrypoints"][0]["outcome"].getStr == "passed"
      check doc3["entrypoints"][0]["compileSkipped"].getBool == false

    # Clean up.
    removeDir(workDir)
