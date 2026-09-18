## test_rfc9_w2_longpath_e2e.nim — RFC-0009 wiring-audit F16: the REAL,
## on-disk, long-path E2E proof for paths.nim's `\\?\` prefixing
## (`applyWinLongPathPrefix`, invoked from `toNative` once a native path
## exceeds `winLongPathThreshold` = 260 chars, MAX_PATH).
##
## ## The gap this closes
##
## `toNative`'s `\\?\`/`\\?\UNC\` prefixing was, until this file, proven
## ONLY as a LEXICAL round-trip in tests/unit/test_paths.nim
## (`classify(toNative(tp)) == tp` against a FAKE `/fake/proj-native-2/...`
## root — no real directory, no real Win32 call). That proves the STRING
## TRANSFORM is correct; it proves nothing about whether the real
## `CreateFileW`/`GetFileAttributesExW` calls behind `fileExists`/`readFile`
## — what `planner.decideCompile` (steps 5/6) and `depgraph.isEntryStale`
## actually call on every one of `toNative`'s outputs — accept that prefix
## at the OS boundary for a path that genuinely exceeds MAX_PATH on a real
## volume, through a real compile and a real dep-graph persist/reload
## cycle. This file is that proof.
##
## ## Design
##
## A real git repo with:
##   - `tests/unit/test_dependent.nim`   — a SHALLOW entrypoint.
##   - `tests/unit/test_independent.nim` — SHALLOW, shares nothing.
##   - `deep/<segment>/<segment>/.../deep_leaf.nim` — a chain of nested,
##     otherwise-empty directories, grown at RUNTIME (not a hardcoded
##     segment count) until the absolute path to `deep_leaf.nim` clears the
##     260-char MAX_PATH threshold with a real margin. This is portable
##     across whatever `getTempDir()` happens to resolve to on a given
##     windows-latest runner ("check what the runner's own workspace path
##     length is" — this test measures its OWN fixture root instead of
##     assuming one).
##   - `test_dependent.nim` imports `deep_leaf` via a relative STRING
##     import path (`import "../../deep/seg.../.../deep_leaf"`) — a real
##     transitive dependency, so `deep_leaf.nim`'s `TrackedPath` becomes a
##     genuine closure member of `test_dependent`'s dep-graph entry exactly
##     like any other dependency.
##   - `test_independent.nim` imports nothing shared with `test_dependent`.
##
## The entrypoints themselves stay SHALLOW quite deliberately:
## `planner.cachePath`/`epSlug` derive the nimcache directory from the
## ENTRYPOINT's own `keyBytes`, never from a closure member's — so
## `--nimcache:<dir>` for both entrypoints stays SHORT regardless of how
## deep `deep_leaf.nim` is (crisol controls its own nimcache placement).
## This sidesteps an unrelated risk: if the nimcache directory itself were
## deep, Nim's C-codegen/link step could hit toolchain-internal path limits
## that have nothing to do with crisol's bug. What this test canNOT
## control is whether Nim's OWN compiler front-end can OPEN a source file
## whose path exceeds MAX_PATH in the first place (Nim's `std/os`-based
## file reads are not necessarily `\\?\`-aware) — see "what this proves,
## precisely" below.
##
## ## The three runs
##
##   RUN 1 (`crisol run --json`, fresh): both entrypoints compile for real.
##     `nim c` must open+compile `deep_leaf.nim` through its real long
##     native path; `recordClosure` must persist `deep_leaf.nim`'s
##     `TrackedPath` (via `keyBytes`) into `test_dependent`'s dep-graph
##     entry, and `saveDepGraph` writes it to `.crisol/depgraph`.
##
##   RUN 2 (`crisol run --json` again, NOTHING changed): `decideCompile`
##     (planner.nim, steps 5/6) calls `fileExists(toNative(deepTp))` and
##     `closureContentHash` (which `readFile`s via that SAME `toNative`
##     output) for `deep_leaf.nim` and must get the SAME answer as at
##     record time — POSITIVE proof that `toNative`'s `\\?\` prefix
##     resolves to the real file. Asserted via the JSON's
##     `compileSkipped: true` for BOTH entrypoints (binaries reused, `nim
##     c` not re-invoked).
##
##   Between RUN 2 and RUN 3: `deep_leaf.nim`'s CONTENT is edited
##     (uncommitted working-tree change).
##
##   RUN 3 (`crisol run --changed --base <initial-rev> --json`): exercises
##     the OTHER direction — `git diff` reports `deep/.../deep_leaf.nim`'s
##     REL path as changed; `changedFiles` classifies that raw string into
##     a `TrackedPath` (`classify`/`fromCanonical`), independent of how
##     `toNative` built its own spelling; `narrow`'s closure-membership
##     fold must match it against the dep-graph's PERSISTED closure member
##     (persisted at RUN 1, reloaded fresh here) — the "`keyBytes`
##     round-trips the deep rel" requirement: the identity computed from
##     git's string output and the identity reloaded from the depgraph's
##     JSON `closure` array must agree despite neither ever being compared
##     as raw strings by this test. NEGATIVE proof, in the same run:
##     `decideCompile` must ALSO now see the changed content hash and
##     recompile ONLY `test_dependent` (`compileSkipped: false`) while
##     `test_independent` — untouched, disjoint closure — is not even
##     selected by `--changed`.
##
## Compile-time gated to `defined(windows)`, mirroring
## test_windows_cli_smoke.nim: POSIX has no MAX_PATH cliff, so this is a
## windows-only property; the `else` branch below must still compile and
## exit cleanly cross-platform since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file regardless of host platform. Imports
## ONLY std/[...] — no crisol modules, no `./helpers` — same standalone
## convention as test_windows_cli_smoke.nim: this file drives the real
## compiled `crisol` binary as a subprocess, exactly like a user would.
##
## ## What this proves, precisely, and what remains open until CI
##
## PROVEN by this file, once it runs green on windows-latest: `toNative`'s
## `\\?\` prefix boundary is correct for every closure-member
## existence/content-hash check crisol's own code performs post-compile,
## for a REAL closure member whose native path genuinely exceeds MAX_PATH,
## AND that the identity survives a full persist/reload/git-diff round
## trip. NOT proven here (out of crisol's control, and not crisol's bug if
## it fails): whether Nim's OWN front-end can open a >MAX_PATH source file
## to compile it in the first place. If a real windows-latest CI run shows
## RUN 1 itself failing at the `nim c` step with a file-not-found/
## cannot-open error (as opposed to one of the checks below failing), that
## is a Nim toolchain limitation, not this test's subject — see
## docs/rfc/0009-path-identity-review.md row F16.
##
## The first real windows-latest run of this file (CI run 35311339453)
## failed, but NOT in the product surface under test: this file's OWN
## fixture setup (`buildDeepChain`'s `createDir`/`writeFile` on the deep
## tree) used plain `std/os` calls, which hit the same Win32 MAX_PATH
## ceiling `paths.toNative`'s `\\?\` prefixing exists to work around —
## `toNative` only prefixes paths the CRISOL BINARY under test builds for
## its own I/O, never this harness's fixture I/O. Fixed with a local,
## windows-only `winLongPath`/`removeDeepTree` pair (mirroring
## `paths.applyWinLongPathPrefix`, which stays unexported — duplicated here
## rather than exported for one test file) applied to every harness touch
## of the deep tree: creation, the content edit between RUN 2 and RUN 3,
## and recursive teardown. The crisol-binary invocations themselves
## continue to receive UNPREFIXED spellings — that is the product surface
## this file proves. The real windows-latest re-run against this fixed
## harness has not landed yet as of this writing; it lands on the next CI
## push.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_rfc9_w2_longpath_e2e.nim

when defined(windows):
  import std/[json, os, osproc, streams, strutils, unittest]

  const projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    ## tests/conformance/test_rfc9_w2_longpath_e2e.nim -> tests/conformance
    ## -> tests -> repo root.

  const winMaxPathThreshold = 260
    ## Mirrors src/crisol/paths.nim's own `winLongPathThreshold` constant.
    ## Deliberately duplicated rather than imported (this file stays
    ## crisol-module-free, same convention as test_windows_cli_smoke.nim):
    ## the fixture must clear the SAME threshold `applyWinLongPathPrefix`
    ## gates on, not an arbitrary "big" number.

  const segName = "longpath_segment_fixture"   # 25 chars, arbitrary but fixed

  proc winLongPath(path: string): string =
    ## CI-fix round (2026-09-17/18): local, windows-only mirror of
    ## `crisol/paths.nim`'s own (unexported — single internal caller,
    ## `toNative`) `applyWinLongPathPrefix`. `toNative`'s `\\?\` handling
    ## covers only paths the CRISOL BINARY under test builds for ITS OWN
    ## I/O; it has no bearing on THIS TEST HARNESS's own fixture
    ## setup/teardown (`createDir`/`writeFile`/`removeDir`/`walkDir` on the
    ## deep tree), which hits the exact same Win32 MAX_PATH ceiling and
    ## must prefix itself independently. Duplicated rather than exported
    ## from the product module for one test file's use (same convention as
    ## `winMaxPathThreshold` above). Idempotent (a path already carrying the
    ## `\\?\` prefix is returned unchanged) so it composes safely with
    ## `walkDir`'s own child-path joining during recursive removal below.
    if path.len >= 4 and path[0 ..< 4] == "\\\\?\\":
      return path
    if path.len <= winMaxPathThreshold:
      path
    elif path.len >= 2 and path[0] == '\\' and path[1] == '\\':
      "\\\\?\\UNC\\" & path[2 .. ^1]
    else:
      "\\\\?\\" & path

  proc removeDeepTree(path: string) =
    ## Recursive removal that extended-length-prefixes EVERY enumerate/
    ## delete call as it descends. Plain `std/os.removeDir` IS already
    ## recursive, but its own internal recursion builds child paths without
    ## ever adding the `\\?\` prefix, so it hits the SAME MAX_PATH ceiling
    ## the creation loop below works around -- this walks manually so every
    ## call at every depth is prefixed.
    let p = winLongPath(path)
    if not dirExists(p):
      return
    for kind, child in walkDir(p):
      case kind
      of pcFile, pcLinkToFile:
        removeFile(winLongPath(child))
      of pcDir:
        removeDeepTree(child)
      of pcLinkToDir:
        removeDir(winLongPath(child))  # don't recurse through a dir symlink
    removeDir(p)

  proc buildDeepChain(repo: string):
      tuple[leafAbsPath, leafRelPath: string; segCount: int] =
    ## Grows a chain of nested directories `deep/<segName>/<segName>/.../`
    ## under `repo`, stopping once the absolute path to the leaf module
    ## `deep_leaf.nim` clears `winMaxPathThreshold` with a 60-char margin
    ## (comfortably past the cliff, not a coin-flip a couple of bytes
    ## either side of it). The segment count is computed from `repo`'s OWN
    ## measured length rather than hardcoded, so this is portable across
    ## whatever `getTempDir()` resolves to on a given windows-latest
    ## runner.
    var segs: seq[string]
    var dir = repo / "deep"
    while true:
      segs.add segName
      dir = dir / segName
      let leafAbs = dir / "deep_leaf.nim"
      if leafAbs.len > winMaxPathThreshold + 60:
        # Both calls below touch the deep chain itself, past MAX_PATH --
        # extended-length-prefixed, unlike the shallow `writeRepoFile`
        # helper (its targets never grow deep).
        createDir(winLongPath(dir))
        writeFile(winLongPath(leafAbs), "proc deepLeafValue*(): int = 42\n")
        let leafRel = "deep/" & segs.join("/") & "/deep_leaf.nim"
        return (leafAbsPath: leafAbs, leafRelPath: leafRel, segCount: segs.len)

  proc buildCrisolBinary(workDir: string): string =
    ## Compiles the real crisol CLI binary into an isolated workDir/nimcache
    ## pair (mirrors test_windows_cli_smoke.nim's build step).
    removeDir(workDir)
    createDir(workDir)
    result = workDir / "crisol"
    let nimcache = workDir & "_nimcache"
    removeDir(nimcache)
    let buildCmd = "nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                   nimcache.quoteShell &
                   " --path:" & (projectRoot / "src").quoteShell &
                   " -o:" & result.quoteShell & " " &
                   (projectRoot / "src" / "crisol.nim").quoteShell
    let (buildOut, buildCode) = execCmdEx(buildCmd)
    if buildCode != 0:
      echo "W2-LONGPATH BUILD OUTPUT:\n" & buildOut
    check buildCode == 0   # if this fails, the CLI didn't compile on windows

  proc runCrisol(bin, cwd: string; args: seq[string]): JsonNode =
    ## Spawns the real crisol binary as a subprocess (cwd = the project
    ## root, exactly how a user invokes it from a shell), asserts a clean
    ## exit, and parses its single --json stdout document.
    let p = startProcess(bin, workingDir = cwd, args = args, options = {})
    let outText = p.outputStream.readAll()
    let errText = p.errorStream.readAll()
    let code = p.waitForExit()
    close(p)
    if code != 0:
      echo "W2-LONGPATH STDERR:\n" & errText
      echo "W2-LONGPATH STDOUT:\n" & outText
    check code == 0
    try:
      result = parseJson(outText)
    except CatchableError:
      echo "W2-LONGPATH STDERR:\n" & errText
      echo "W2-LONGPATH STDOUT:\n" & outText
      raise

  proc compileSkippedFor(doc: JsonNode; relPath: string): bool =
    ## `false` (never a silently-passing default) unless `relPath` is
    ## actually present in `doc["entrypoints"]` with `compileSkipped: true`.
    for ep in doc["entrypoints"].getElems():
      if ep["path"].getStr() == relPath:
        return ep["compileSkipped"].getBool()
    echo "W2-LONGPATH: entrypoint not found in run output: ", relPath
    check false
    false

  suite "rfc-0009 wiring-audit F16 — real long-path E2E through toNative":

    test "deep closure member survives compile, freshness-skip, and --changed selection past MAX_PATH":
      echo "W2-LONGPATH REAL: constructing a real >MAX_PATH directory chain and driving the compiled crisol binary through it"

      let repo = getTempDir() / ("crisol_w2_longpath_repo_" & $getCurrentProcessId())
      removeDeepTree(repo)  # best-effort: a stale previous run may have left a >MAX_PATH tree
      createDir(repo)

      proc git(args: string): tuple[output: string; exitCode: int] =
        execCmdEx("git " & args, workingDir = repo)

      proc writeRepoFile(rel, content: string) =
        let p = repo / rel
        createDir(p.parentDir)
        writeFile(p, content)

      discard git("init -q")
      discard git("config user.email crisol@test.local")
      discard git("config user.name crisol-test")
      discard git("config commit.gpgsign false")
      discard git("config core.autocrlf false")
      # Git for Windows' OWN internal file operations (checkout/add/mv/diff)
      # are subject to the SAME 260-char MAX_PATH ceiling at the Win32 API
      # level unless `core.longpaths` is enabled, which makes git use
      # `\\?\`-prefixed calls internally for ITS OWN I/O. This is completely
      # independent of crisol's `applyWinLongPathPrefix` (paths.nim) — even
      # a perfectly long-path-safe crisol would fail this fixture's `git
      # add`/`git diff` without it — so it is set explicitly on the fixture
      # repo (never relying on the runner's global gitconfig).
      let longpathsCfg = git("config core.longpaths true")
      check longpathsCfg.exitCode == 0

      let (leafAbs, leafRel, segCount) =
        try:
          buildDeepChain(repo)
        except OSError as e:
          echo "W2-LONGPATH FIXTURE SETUP FAILED (buildDeepChain: creating/writing the deep tree itself -- NOT a product assertion): ", e.msg
          raise
      echo "W2-LONGPATH REAL: deep_leaf.nim absolute path length = ", leafAbs.len,
           " (", segCount, " nested segments; MAX_PATH threshold = ", winMaxPathThreshold, ")"
      check leafAbs.len > winMaxPathThreshold

      let relImportNoExt = "../../" & leafRel[0 ..< leafRel.len - len(".nim")]

      writeRepoFile(".gitignore", ".crisol/\n")
      writeRepoFile("crisol.kdl", "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
      writeRepoFile("tests/unit/test_dependent.nim",
                    "import std/unittest\n" &
                    "import \"" & relImportNoExt & "\"\n" &
                    "suite \"dependent\":\n" &
                    "  test \"ok\": check deepLeafValue() > 0\n")
      # The dependent test's assertion is deliberately value-INDEPENDENT
      # (mirrors test_windows_cli_smoke.nim's case-variant scenario): it
      # must pass both before and after deep_leaf.nim's content edit below
      # — the subject here is compile/selection behavior, never whether the
      # fixture's arithmetic changed.
      writeRepoFile("tests/unit/test_independent.nim",
                    "import std/unittest\nsuite \"independent\":\n  test \"ok\": check true\n")
      discard git("add -A")
      let cmt = git("commit -q -m initial")
      check cmt.exitCode == 0
      let initialRev = git("rev-parse HEAD").output.strip()

      let workDir = getTempDir() / ("crisol_w2_longpath_bin_" & $getCurrentProcessId())
      let crisolBin = buildCrisolBinary(workDir)

      # RUN 1: fresh compile, both entrypoints. Real `nim c` must open+
      # compile deep_leaf.nim through its long native path; recordClosure
      # must persist its TrackedPath into test_dependent's graph entry.
      let doc1 = runCrisol(crisolBin, repo, @["run", "--jobs", "1", "--json"])
      check doc1["schema"].getStr == "crisol/run/v2"
      check doc1["summary"]["total"].getInt == 2
      check doc1["summary"]["counts"]["passed"].getInt == 2
      check compileSkippedFor(doc1, "tests/unit/test_dependent.nim") == false
      check compileSkippedFor(doc1, "tests/unit/test_independent.nim") == false

      # Sanity check: the persisted depgraph's closure array for
      # test_dependent really does carry deep_leaf.nim's full (long) rel
      # spelling — keyBytes was computed over the REAL deep path, not
      # silently truncated or elided on the way to disk.
      let depgraphPath = repo / ".crisol" / "depgraph"
      check fileExists(depgraphPath)
      let depgraphDoc = parseJson(readFile(depgraphPath))
      var sawDeepMember = false
      for entryNode in depgraphDoc["entries"].getElems():
        if entryNode["path"].getStr() == "tests/unit/test_dependent.nim":
          for c in entryNode["closure"].getElems():
            if c.getStr().endsWith("deep_leaf.nim") and
               c.getStr().len > winMaxPathThreshold - 20:
              sawDeepMember = true
      echo "W2-LONGPATH: persisted depgraph carries the deep closure member = ", sawDeepMember
      check sawDeepMember

      # RUN 2: nothing changed. decideCompile (planner.nim, steps 5/6) must
      # fileExists+readFile deep_leaf.nim through toNative's REAL \\?\
      # prefix and get the SAME answer as at record time — POSITIVE proof.
      let doc2 = runCrisol(crisolBin, repo, @["run", "--jobs", "1", "--json"])
      check doc2["summary"]["counts"]["passed"].getInt == 2
      echo "W2-LONGPATH: RUN2 compileSkipped(dependent)=",
           compileSkippedFor(doc2, "tests/unit/test_dependent.nim"),
           " compileSkipped(independent)=",
           compileSkippedFor(doc2, "tests/unit/test_independent.nim")
      check compileSkippedFor(doc2, "tests/unit/test_dependent.nim") == true
      check compileSkippedFor(doc2, "tests/unit/test_independent.nim") == true

      # Edit deep_leaf.nim's CONTENT — uncommitted working-tree change, the
      # thing RUN 3's --changed must see via git AND decideCompile must see
      # via toNative's content-hash read. This is this HARNESS's own I/O on
      # the deep path, extended-length-prefixed like buildDeepChain's above.
      try:
        writeFile(winLongPath(leafAbs), "proc deepLeafValue*(): int = 4242\n")
      except OSError as e:
        echo "W2-LONGPATH FIXTURE SETUP FAILED (editing deep_leaf.nim content -- NOT a product assertion): ", e.msg
        raise

      # Lightweight negative-control-lite (independent of crisol's own git
      # invocation): confirm git itself really does see the deep path as
      # changed, framing-agnostic split same as test_windows_cli_smoke.nim's
      # own control.
      let rawDiff = git("diff --no-renames --relative --name-only " & initialRev).output
      var diffEntries: seq[string]
      for entry in rawDiff.split({'\0', '\n', '\r'}):
        let e = entry.strip()
        if e.len > 0: diffEntries.add e
      echo "W2-LONGPATH: raw git diff entries = ", $diffEntries
      check leafRel in diffEntries

      # RUN 3: the REAL argv path — `crisol run --changed --base
      # <initialRev> --json`. Exercises classify/fromCanonical on the deep
      # rel string git reports, the closure-membership fold against the
      # PERSISTED (RUN 1) graph reloaded fresh here, and decideCompile's
      # content-hash recheck.
      let doc3 = runCrisol(crisolBin, repo,
                            @["run", "--changed", "--base", initialRev,
                              "--jobs", "1", "--json"])
      check doc3["schema"].getStr == "crisol/run/v2"
      var selectedPaths: seq[string]
      for ep in doc3["entrypoints"].getElems():
        selectedPaths.add ep["path"].getStr()
      echo "W2-LONGPATH: RUN3 selected entrypoints = ", $selectedPaths
      check "tests/unit/test_dependent.nim" in selectedPaths
      check "tests/unit/test_independent.nim" notin selectedPaths
      check selectedPaths.len == 1
      check doc3["summary"]["total"].getInt == 1
      check doc3["summary"]["counts"]["passed"].getInt == 1
      # NEGATIVE proof: the content genuinely changed, so decideCompile must
      # have recompiled — a fold that only ever matched vacuously (or a
      # content-hash read that silently failed and defaulted to "same")
      # would leave this `true` instead.
      check compileSkippedFor(doc3, "tests/unit/test_dependent.nim") == false

      # Clean up. `repo`'s own subtree grows past MAX_PATH (the deep chain),
      # so it needs the prefixed recursive remover, not plain `removeDir`;
      # teardown failure is reported but does not overturn a verdict the
      # checks above already reached.
      try:
        removeDeepTree(repo)
        removeDir(workDir)
        removeDir(workDir & "_nimcache")
      except OSError as e:
        echo "W2-LONGPATH: cleanup (teardown, not a product assertion) failed: ", e.msg

  when isMainModule:
    echo "test_rfc9_w2_longpath_e2e done"

else:
  when isMainModule:
    echo "test_rfc9_w2_longpath_e2e: skipped (not windows)"
