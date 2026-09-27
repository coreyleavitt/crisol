## tests/integration/test_tool_capture_deadline.nim — CR4 (code review
## 2026-09-21): a deadline on the tool-invocation capture layer.
##
## The original capture loops waited for genuine EOF with no bound (the POSIX
## arm polled with an INFINITE timeout, the Windows arm spun forever), and
## every caller then called `waitForExit()` with no timeout and never
## terminated the child. `toolrun`'s probes and `gitdiff`'s git calls run in
## the HOST PROCESS during plan-building, entirely outside RFC-0007's
## Supervisor, so a `git` blocked on a credential prompt, or a wedged
## `cc --version`, hung the whole invocation.
##
## Three production paths are exercised, one per capture shape and caller:
##   1. `toolrun.realRunMerged` (merged streams, one pipe)
##   2. `toolrun.realRun`       (separate streams, two pipes)
##   3. `gitdiff.changedFiles`  (separate streams, via `runGit`)
##
## A hang cannot be asserted from inside the process that would be hung, so
## each call runs in a small driver fixture (`capture_probe_merged.nim`,
## `capture_probe.nim`, `gitdiff_probe.nim`) under `tests/support/deadline`'s
## OUTER wall-clock bound -- a second, independent deadline so a bug in the
## capture cannot re-hang the suite.
##
## RED (a capture with no deadline): the driver hangs, the OUTER bound trips
## first and `finished` comes back `false`. GREEN: the driver's own deadline
## (`toolrun.ToolProbeTimeoutMs` / `gitdiff.GitToolTimeoutMs`, both 10 s) is
## reached well inside the outer bound and the run reports a timeout.

import std/[os, osproc, strutils, unittest]
import ../support/deadline

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin" / "cr4"
  cacheDir   = fixtureDir / "nimcache" / "cr4"
  srcDir     = currentSourcePath().parentDir().parentDir().parentDir() / "src"
  # Outer safety bound: comfortably above ccprobe/gitdiff's own 10 s internal
  # deadline, so GREEN never races it, and far below "actually hangs forever"
  # so RED fails FAST rather than wedging the suite.
  OuterBoundMs = 30_000

let hangBin = block:
  createDir(binDir)
  let b = binDir / "hang_forever".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "hang_forever", b, srcDir)
  b

let mergedProbeBin = block:
  let b = binDir / "capture_probe_merged".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "capture_probe_merged", b, srcDir)
  b

let separateProbeBin = block:
  let b = binDir / "capture_probe".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "capture_probe", b, srcDir)
  b

let gitProbeBin = block:
  let b = binDir / "gitdiff_probe".addFileExt(ExeExt)
  compileFixtureWithSrc(fixtureDir, cacheDir, "gitdiff_probe", b, srcDir)
  b

let fakeGitBin = block:
  let dir = binDir / "fakegit"
  createDir(dir)
  let b = dir / "git".addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & (cacheDir / "fakegit") &
                          " -o:" & b & " " & (fixtureDir / "fake_git.nim"))
  doAssert rc == 0, "fake_git compile failed:\n" & o
  doAssert fileExists(b), "fake_git compiled but produced no binary at " & b
  (bin: b, dir: dir)

suite "CR4 — the tool-invocation capture layer gives up on a child that never exits":

  test "toolrun.realRunMerged (one pipe) gives up on a child that never exits":
    let (finished, line) = runWithDeadline(mergedProbeBin, @[hangBin], OuterBoundMs)
    check finished   # RED: an unbounded capture waits forever
    if finished:
      check line == "OK ending=reTimedOut exit=-1 outLen=0"

  test "toolrun.realRun (two pipes) gives up on a child that never exits":
    let (finished, line) = runWithDeadline(separateProbeBin, @[hangBin], OuterBoundMs)
    check finished   # RED: an unbounded capture waits forever
    if finished:
      check line == "OK ending=reTimedOut exit=-1 outLen=0"

  test "gitdiff.changedFiles (two pipes, via runGit) gives up on a git that never answers":
    putEnv("PATH", fakeGitBin.dir & $PathSep & getEnv("PATH"))
    putEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND", "rev-parse")
    defer:
      delEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND")
    let projectRoot = binDir / "not_a_real_git_call_target"
    createDir(projectRoot)
    let (finished, line) = runWithDeadline(gitProbeBin, @[projectRoot], OuterBoundMs)
    check finished   # RED: an unbounded capture waits forever
    if finished:
      check line.startsWith("RAISED")
      # `gitdiff_probe` prints only the message's last 32 chars (`tail=`);
      # the raised message is worded to end with this fixed marker so the
      # timeout path is identifiable regardless of `projectRoot`'s length.
      check "[git timeout]" in line
