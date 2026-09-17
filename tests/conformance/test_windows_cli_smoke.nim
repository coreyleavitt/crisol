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
## Imports ONLY std/[json, os, osproc, streams, strutils, unittest] (streams
## for osproc's Stream.readAll — osproc does not re-export it) — no
## std/posix, no crisol modules, no `./helpers` — so this file runs
## standalone pre-RFC-0009 (the process-backend conformance harness this
## directory otherwise depends on is itself not yet proven on windows; this
## smoke test cannot depend on it). It shells out to a REAL compiled
## `crisol` binary via osproc rather than calling library code in-process,
## exactly mirroring how a real user invokes crisol from a shell.
##
## Second test (RFC-0009 wiring-audit W2, slice S6): the load-bearing
## property's SELECTION half is proven in-process, through the shared plan
## phase, by test_rfc9_a3bii_fold_selection.nim (and A4b/A5c) — never through
## this binary's own argv parsing. This file's second test closes that gap:
## a real git repo (doubling as the project root), a committed case-only
## rename of a transitively-imported dependency, and a genuine `crisol run
## --changed --base <rev> --json` SUBPROCESS spawn — the actual argv path at
## src/crisol.nim's `of "changed": useChanged = true` / `of "base": ...`
## flag parsing — asserting via the --json output that the dependent
## entrypoint is selected and the independent one is not. Self-gates on the
## volume actually being case-insensitive (see that test for why: production
## has no CRISOL_FOLD_POLICY/CRISOL_EXPECT_FOLD injection seam — grep src/
## turns up nothing — so this scenario can only observe the real probe, not
## force one).

when defined(windows):
  import std/[json, os, osproc, streams, strutils, unittest]

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

    test "spawned binary run --changed selects only the entrypoint whose closure member changed (case-variant spelling)":
      # Case-insensitive-volume gate: production's `crisol` binary reads no
      # fold-policy injection env (CRISOL_FOLD_POLICY/CRISOL_EXPECT_FOLD are
      # test-only seams into `RunOptions.foldProbe` — see the module doc
      # above), so unlike test_rfc9_a3bii_fold_selection.nim this scenario
      # cannot force a policy; it can only run for real when THIS volume
      # genuinely answers case-insensitive. Same probe technique as that
      # test's mode-3 branch and test_spike_import_case.nim's
      # isCaseInsensitiveVolume. windows-latest NTFS always answers
      # case-insensitive, so the real branch always runs there; the skip
      # branch below exists only so a hypothetical case-sensitive Windows
      # volume fails honestly (CRISOL-SKIP-TEST) instead of silently
      # vanishing — this suite's OTHER test still runs for real either way,
      # so this is a per-test skip, not the whole-file CRISOL-SKIP marker.
      let caseProbeDir = getTempDir() / ("crisol_cli_smoke_caseprobe_" & $getCurrentProcessId())
      removeDir(caseProbeDir)
      createDir(caseProbeDir)
      let lowerProbe = caseProbeDir / "case_probe.tmp"
      let upperProbe = caseProbeDir / "CASE_PROBE.tmp"
      writeFile(lowerProbe, "x")
      let insensitive = fileExists(upperProbe)
      removeDir(caseProbeDir)

      if not insensitive:
        echo "CLI-SMOKE-CASECHANGED SKIPPED: case-sensitive volume -- the case-variant --changed premise does not hold here"
        echo "CRISOL-SKIP-TEST: tests/conformance/test_windows_cli_smoke.nim#case_variant_changed_selection"
        skip()
      else:
        echo "CLI-SMOKE-CASECHANGED REAL: case-insensitive volume confirmed -- running the case-variant --changed scenario"

        # 1. Build the real CLI binary, isolated from the first test's build
        #    (distinct workDir/nimcache so the two tests never race).
        let workDir = getTempDir() / "crisol_cli_smoke_changed"
        removeDir(workDir)
        createDir(workDir)
        let crisolBin = workDir / "crisol"
        let nimcache = getTempDir() / "crisol_cli_smoke_changed_nimcache"
        removeDir(nimcache)
        let buildCmd = "nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                       nimcache.quoteShell &
                       " --path:" & (projectRoot / "src").quoteShell &
                       " -o:" & crisolBin.quoteShell & " " &
                       (projectRoot / "src" / "crisol.nim").quoteShell
        let (buildOut, buildCode) = execCmdEx(buildCmd)
        if buildCode != 0:
          echo "BUILD OUTPUT:\n" & buildOut
        check buildCode == 0

        # 2. A real git repo, doubling as the project root (config walk-up
        #    and --changed's git diff both need it there): one group, two
        #    entrypoints -- `test_dependent.nim` (imports `helper.nim`,
        #    which imports `widget.nim`, a TRANSITIVE dependency) and
        #    `test_independent.nim` (shares nothing). Mirrors
        #    test_rfc9_a3bii_fold_selection.nim's fixture, at the CLI layer.
        let repo = getTempDir() / ("crisol_cli_smoke_changed_repo_" & $getCurrentProcessId())
        removeDir(repo)
        createDir(repo)

        proc gitCmd(args: string): tuple[output: string; exitCode: int] =
          execCmdEx("git " & args, workingDir = repo)

        proc writeRepoFile(rel, content: string) =
          let p = repo / rel
          createDir(p.parentDir)
          writeFile(p, content)

        discard gitCmd("init -q")
        discard gitCmd("config user.email crisol@test.local")
        discard gitCmd("config user.name crisol-test")
        discard gitCmd("config commit.gpgsign false")
        # The runner's global autocrlf would (a) rewrite the LF fixture
        # files on checkout and (b) print an "LF will be replaced by CRLF"
        # warning that execCmdEx's merged stderr splices into the raw
        # `git diff -z` output below, corrupting the NUL-split entries.
        discard gitCmd("config core.autocrlf false")

        writeRepoFile(".gitignore", ".crisol/\n")
        writeRepoFile("crisol.kdl", "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
        writeRepoFile("tests/unit/widget.nim", "proc widgetValue*(): int = 42\n")
        writeRepoFile("tests/unit/helper.nim",
                      "import widget\nproc helperValue*(): int = widgetValue() + 1\n")
        writeRepoFile("tests/unit/test_dependent.nim",
                      "import std/unittest\nimport helper\nsuite \"dependent\":\n" &
                      "  test \"ok\": check helperValue() > 0\n")
        # The dependent test's assertion is deliberately value-INDEPENDENT:
        # it must pass both before (helperValue 43) and after (4243) the
        # widget edit below -- the scenario's subject is which entrypoints
        # get SELECTED, never whether the fixture's arithmetic changed.
        writeRepoFile("tests/unit/test_independent.nim",
                      "import std/unittest\nsuite \"independent\":\n  test \"ok\": check true\n")
        discard gitCmd("add -A")
        discard gitCmd("commit -q -m initial")

        # 3. RUN 1: no --changed -- a real subprocess run that compiles both
        #    entrypoints for real and PERSISTS the dep graph to `.crisol/`
        #    via a genuine recordClosure/saveDepGraph.
        let p1 = startProcess(crisolBin, workingDir = repo,
                               args = @["run", "--jobs", "1", "--json"],
                               options = {})
        let out1 = p1.outputStream.readAll()
        let err1 = p1.errorStream.readAll()
        let code1 = p1.waitForExit()
        close(p1)
        if code1 != 0:
          echo "RUN1 STDERR:\n" & err1
          echo "RUN1 STDOUT:\n" & out1
        check code1 == 0
        let doc1 = parseJson(out1)
        check doc1["summary"]["total"].getInt == 2
        check doc1["summary"]["counts"]["passed"].getInt == 2

        # 4. Case-divergence: a COMMITTED rename (git mv X tmp && git mv tmp
        #    Y, one commit) -- never an uncommitted staged rename, which
        #    would show both the delete of the old spelling and the add of
        #    the new one in the same diff (vacuous). Then edit Widget.nim's
        #    CONTENT, uncommitted -- this is the change RUN 2's --changed
        #    must see.
        let mv1 = gitCmd("mv tests/unit/widget.nim tests/unit/tmp.nim")
        let mv2 = gitCmd("mv tests/unit/tmp.nim tests/unit/Widget.nim")
        let cmt = gitCmd("commit -q -m rename-widget-to-Widget")
        check mv1.exitCode == 0
        check mv2.exitCode == 0
        check cmt.exitCode == 0
        let renameRev = gitCmd("rev-parse HEAD").output.strip()

        writeRepoFile("tests/unit/Widget.nim", "proc widgetValue*(): int = 4242\n")

        # --- Lightweight negative control (the CLI-observable equivalent of
        # A3b-ii's mandatory raw-string check): the diff crisol's own
        # gitdiff.nim runs (`git diff -z --no-renames --relative --name-only
        # <base>`) reports the NEW spelling; the OLD spelling (still
        # resolvable on this case-insensitive volume, and still the spelling
        # RUN 1's persisted dep graph carries) does not appear in the diff at
        # all -- only the fold can make the two identities match.
        let rawDiff = gitCmd("diff -z --no-renames --relative --name-only " & renameRev).output
        let diffEntries = rawDiff.split('\0')
        echo "CLI-SMOKE-CASECHANGED: raw git diff entries = ", $diffEntries
        check "tests/unit/Widget.nim" in diffEntries
        check "tests/unit/widget.nim" notin diffEntries

        # 5. RUN 2: the REAL argv path -- `crisol run --changed --base
        #    <renameRev> --json`, a genuine subprocess spawn, exactly how a
        #    user invokes crisol from a shell (src/crisol.nim's
        #    `of "changed"` / `of "base"` flag parsing).
        let p2 = startProcess(crisolBin, workingDir = repo,
                               args = @["run", "--changed", "--base", renameRev,
                                        "--jobs", "1", "--json"],
                               options = {})
        let out2 = p2.outputStream.readAll()
        let err2 = p2.errorStream.readAll()
        let code2 = p2.waitForExit()
        close(p2)
        if code2 != 0:
          echo "RUN2 STDERR:\n" & err2
          echo "RUN2 STDOUT:\n" & out2
        check code2 == 0
        let doc2 =
          try:
            parseJson(out2)
          except CatchableError:
            echo "RUN2 STDERR:\n" & err2
            echo "RUN2 STDOUT:\n" & out2
            raise
        check doc2["schema"].getStr == "crisol/run/v2"

        var selectedPaths: seq[string]
        for ep in doc2["entrypoints"].getElems():
          selectedPaths.add ep["path"].getStr()
        echo "CLI-SMOKE-CASECHANGED: RUN2 selected entrypoints = ", $selectedPaths

        check "tests/unit/test_dependent.nim" in selectedPaths
        check "tests/unit/test_independent.nim" notin selectedPaths
        check selectedPaths.len == 1
        check doc2["summary"]["total"].getInt == 1
        check doc2["summary"]["counts"]["passed"].getInt == 1

        # Clean up.
        removeDir(repo)
        removeDir(workDir)
        removeDir(nimcache)

  when isMainModule:
    echo "test_windows_cli_smoke done"

else:
  when isMainModule:
    echo "test_windows_cli_smoke: skipped (not windows)"
