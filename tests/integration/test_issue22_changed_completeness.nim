## tests/integration/test_issue22_changed_completeness.nim — issue #22's
## completion gate.
##
## `--changed` selection is only as sound as the changed-file set it narrows
## against. `gitdiff.runGit` captured git's stdout with `streams.readAll`,
## which on Windows stops at the child's first flush (see
## `crisol/toolexec.drainToEof`) — so a diff that arrives in more than one
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
import crisol/[gitdiff, paths, types]
import ../fixtures/fake_git
import ../support/deadline

const
  NameCount  = 100
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
