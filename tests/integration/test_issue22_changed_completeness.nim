## tests/integration/test_issue22_changed_completeness.nim — issue #22's
## completion gate.
##
## `--changed` selection is only as sound as the changed-file set it narrows
## against. `gitdiff.runGit` captured git's stdout with `streams.readAll`,
## which on Windows stops at the child's first flush (see
## `crisol/toolexec`'s module doc) — so a diff that arrives in more than one
## burst yields a SHORT list that is indistinguishable from a genuinely small
## diff: no error, exit code 0, just fewer tests selected than the change
## actually touched. This is the user-visible consequence the rest of issue
## #22 exists to prevent, so it is asserted through the real entry point.
##
## Real `git` cannot be asked to chunk its output, so `tests/fixtures/
## fake_git.nim` goes first on PATH under the name `git`. `gitdiff` resolves
## it through its own unmodified `startProcess("git", …, {poUsePath})` — no
## seam, no injection, production call path throughout.
##
## This file mutates PATH for its whole process, which is exactly why it is a
## file of its own: crisol's harness runs each test file as a separate
## process, so the fake `git` cannot leak into any other suite.

import std/[options, os, osproc, sets, strutils, tempfiles, unittest]
import crisol             # runMain
import crisol/[gitdiff, paths, types]
import ../fixtures/fake_git
import ../support/[capture, deadline]

const
  NameCount  = 50    # under the ~4 KB pipe buffer; see fake_git.nim
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  fakeBinDir = fixtureDir / "bin" / "fakegit"
  cacheDir   = fixtureDir / "nimcache" / "fakegit"
  srcDir     = currentSourcePath().parentDir().parentDir().parentDir() / "src"

proc installFakeGit(): string =
  ## Compile the fixture as `git`/`git.exe` into a directory of its own and
  ## put that directory first on PATH. Returns the binary's path.
  createDir(fakeBinDir)
  let bin = fakeBinDir / "git".addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cacheDir &
                          " -o:" & bin & " " & (fixtureDir / "fake_git.nim"))
  doAssert rc == 0, "fake_git compile failed:\n" & o
  doAssert fileExists(bin), "fake_git compiled but produced no binary at " & bin
  putEnv("PATH", fakeBinDir & $PathSep & getEnv("PATH"))
  bin

# NOT `fakeGit`: Nim identifier equality ignores underscores, so that name
# collides with the imported `fake_git` module.
let fakeGitBin = installFakeGit()

let probeBin = block:
  let b = fakeBinDir.parentDir / "gitdiff_probe".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "gitdiff_probe", b, srcDir)
  b

suite "issue #22 — --changed sees every changed file":

  test "changedFiles returns all names when git's diff arrives in two bursts":
    putEnv("CRISOL_FAKE_GIT_NAMES", $NameCount)
    putEnv("CRISOL_FAKE_GIT_DELAY_MS", "150")
    let projectRoot = createTempDir("crisol_i22_", "_root")
    defer:
      removeDir(projectRoot)
      delEnv("CRISOL_FAKE_GIT_NAMES")
      delEnv("CRISOL_FAKE_GIT_DELAY_MS")

    # Guard the premise: if the real git were being found instead of the
    # fixture, every assertion below would be meaningless.
    check fakeGitBin.parentDir == fakeBinDir

    let roots = initTrackedRoots(projectRoot, @[], "")
    let changed = changedFiles(projectRoot, roots)

    # The load-bearing assertion. A truncating capture returns only the names
    # in git's FIRST flush — one, here — and reports success.
    check changed.len == NameCount
    for name in fakeGitNames(NameCount):
      let tp = fromCanonical(name, roots)
      check tp.isSome
      check tp.get in changed

  test "a git whose stderr overruns the pipe buffer neither wedges nor is truncated":
    # The defect: `runGit` read stdout to EOF and only THEN touched stderr, so
    # a git that filled the ~4 KB stderr pipe blocked forever — it could not
    # finish writing stderr, so it never closed stdout, so the read never
    # returned. gitdiff's own comment dismissed this on the grounds that git's
    # stderr is "a few short warning lines"; `core.autocrlf` emits one PER
    # FILE, so a large checkout is nowhere near that bound.
    #
    # A deadlock cannot be asserted from inside the deadlocked process, so the
    # call runs in `gitdiff_probe` under a deadline out here.
    const StderrBytes = 256 * 1024
    putEnv("CRISOL_FAKE_GIT_STDERR_BYTES", $StderrBytes)
    let projectRoot = createTempDir("crisol_i22_err_", "_root")
    defer:
      removeDir(projectRoot)
      delEnv("CRISOL_FAKE_GIT_STDERR_BYTES")

    let (finished, line) = runWithDeadline(probeBin, @[projectRoot], 60_000)
    check finished                      # RED: the probe wedges and is killed
    if finished:
      # Not merely "it returned": the whole of git's stderr has to reach the
      # error message, or the diagnostic a user sees is a fragment.
      check line.startsWith("RAISED")
      let lenTag = "len="
      let lenStart = line.find(lenTag) + lenTag.len
      let lenEnd = line.find(' ', lenStart)
      check parseInt(line[lenStart ..< lenEnd]) >= StderrBytes

# ---------------------------------------------------------------------------
# The untracked-file scan must fail closed.
#
# `git ls-files --others --exclude-standard` is the only thing that puts a
# new, not-yet-`git add`-ed source file into the changed set (M14): `git diff`
# cannot see it. When that scan does not deliver a complete, successful
# answer -- it exits non-zero, times out, cannot be started, overflows, or
# hits an I/O error -- the changed set is missing an unknown number of names,
# and `--changed` narrows against it anyway: an entrypoint whose closure
# holds only the untracked file drops out of the plan. That is an
# UNDER-selection, the one direction crisol's soundness rule forbids, so the
# scan is held to exactly the standard `rev-parse` and `diff` already are:
# anything but a clean exit raises `cekEnvironment` (CLI exit 3). Refusal
# only costs the user a rerun; a silently short plan costs a missed failure.
# ---------------------------------------------------------------------------

const PlainTestBody = """
import std/unittest
test "ok":
  check true
"""

proc lsFilesProject(tag: string): string =
  ## A throwaway project root with one entrypoint so `crisol run --changed
  ## --dry-run` gets as far as selection. The fake `git` answers `rev-parse`
  ## with "true" for any directory, so no real repository is needed.
  result = createTempDir("crisol_i22_ls_" & tag & "_", "_root")
  createDir(result / "tests" / "unit")
  writeFile(result / "tests" / "unit" / "test_a.nim", PlainTestBody)

proc runChangedDryRun(projectRoot: string): tuple[code: int; err: string] =
  ## `crisol run --changed --dry-run` through the real CLI entry point, run
  ## from inside `projectRoot` so config discovery roots there.
  let oldCwd = getCurrentDir()
  setCurrentDir(projectRoot)
  defer: setCurrentDir(oldCwd)
  var code = -1
  let (_, errText) = captureBoth(proc() = code = runMain(@["run", "--changed", "--dry-run"]))
  (code: code, err: errText)

suite "issue #22 — an incomplete untracked-file scan fails --changed closed":

  setup:
    putEnv("CRISOL_FAKE_GIT_NAMES", "2")
    putEnv("CRISOL_FAKE_GIT_DELAY_MS", "0")
    putEnv("CRISOL_FAKE_GIT_UNTRACKED", "2")

  teardown:
    delEnv("CRISOL_FAKE_GIT_NAMES")
    delEnv("CRISOL_FAKE_GIT_DELAY_MS")
    delEnv("CRISOL_FAKE_GIT_UNTRACKED")
    delEnv("CRISOL_FAKE_GIT_LS_FILES_EXIT")
    delEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND")

  test "control: a clean ls-files puts every untracked name in the changed set":
    let projectRoot = lsFilesProject("ok")
    defer: removeDir(projectRoot)
    let roots = initTrackedRoots(projectRoot, @[], "")
    let changed = changedFiles(projectRoot, roots)
    for name in fakeGitUntrackedNames(2):
      let tp = fromCanonical(name, roots)
      check tp.isSome
      check tp.get in changed
    check changed.len == 4

  test "ls-files exiting non-zero raises instead of returning a diff-only set":
    putEnv("CRISOL_FAKE_GIT_LS_FILES_EXIT", "2")
    let projectRoot = lsFilesProject("rc")
    defer: removeDir(projectRoot)
    let roots = initTrackedRoots(projectRoot, @[], "")
    var raised = false
    try:
      let changed = changedFiles(projectRoot, roots)
      # RED: the untracked names git printed were dropped without a word, and
      # the tracked diff alone came back as if it were the whole change.
      checkpoint "changedFiles returned " & $changed.len & " names"
    except CrisolError as e:
      raised = true
      check e.kind == cekEnvironment
      check "ls-files" in e.msg
      check "exited with code 2" in e.msg
      check "index file corrupt" in e.msg   # git's own stderr reaches the user
    check raised

  test "crisol run --changed refuses (exit 3) when ls-files exits non-zero":
    putEnv("CRISOL_FAKE_GIT_LS_FILES_EXIT", "2")
    let projectRoot = lsFilesProject("cli_rc")
    defer: removeDir(projectRoot)
    let r = runChangedDryRun(projectRoot)
    checkpoint "stderr: " & r.err
    check r.code == 3                        # RED: 0, a plan narrowed on a partial set
    check "ls-files" in r.err

  test "crisol run --changed refuses (exit 3) when ls-files never answers":
    putEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND", "ls-files")
    let projectRoot = lsFilesProject("cli_hang")
    defer: removeDir(projectRoot)
    let r = runChangedDryRun(projectRoot)
    checkpoint "stderr: " & r.err
    check r.code == 3                        # RED: 0 plus a warning nobody acts on
    check "ls-files" in r.err
    check "[git timeout]" in r.err
