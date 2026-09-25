## tests/integration/test_cr4_tool_deadline.nim — CR4 (code review
## 2026-09-21): a deadline on the tool-invocation capture layer.
##
## `toolexec.drainToEof`/`drainBoth` loop until genuine EOF -- the POSIX arm
## of `drainBoth` polls with an INFINITE timeout, the Windows arm spins
## forever -- and every caller then calls `waitForExit()` with no timeout and
## never terminates the child. `toolrun.runViaOsproc` and `gitdiff.runGit` run
## in the HOST PROCESS during plan-building, entirely outside RFC-0007's
## Supervisor (`compileTimeoutMs`, tree-kill) -- so a `git` blocked on an
## SSH/credential prompt, or a wedged `cc --version`, hangs the whole
## invocation forever. See docs/handoff/msvc-selection-layer.md's CR4 row.
##
## Three production paths are exercised, matching CR4's two exposed callers
## and toolexec's two drain shapes:
##   1. `toolrun.realRunMerged` (merged stream -> `toolexec.drainToEofDeadline`)
##   2. `toolrun.realRun`       (separate streams -> `toolexec.drainBothDeadline`)
##   3. `gitdiff.changedFiles`  (separate streams -> `toolexec.drainBothDeadline`,
##      via `runGit`)
##
## A hang cannot be asserted from inside the process that would be hung, so
## each call runs in a small driver fixture (`capture_probe_merged.nim`,
## `capture_probe.nim`, `gitdiff_probe.nim`) under `tests/support/deadline`'s
## OUTER wall-clock bound -- a second, independent deadline so a bug in this
## fix cannot re-hang the suite the way the original defect would.
##
## RED (pre-fix): every driver process itself hangs forever (the old
## `drainToEof`/`drainBoth` + `waitForExit()` never give up), so the OUTER
## `runWithDeadline` bound trips first and kills the driver -- `finished`
## comes back `false`. GREEN (post-fix): the driver's own internal deadline
## (`toolrun.ToolProbeTimeoutMs` / `gitdiff.GitToolTimeoutMs`, both 10 s) is
## reached well inside the outer bound, so the driver exits cleanly and
## `finished` is `true`.

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

  test "toolrun.realRunMerged (drainToEofDeadline) gives up on a child that never exits":
    let (finished, line) = runWithDeadline(mergedProbeBin, @[hangBin], OuterBoundMs)
    check finished   # RED pre-fix: realRunMerged waits on drainToEof + waitForExit forever
    if finished:
      check line == "OK ok=false outLen=0"

  test "toolrun.realRun (drainBothDeadline) gives up on a child that never exits":
    let (finished, line) = runWithDeadline(separateProbeBin, @[hangBin], OuterBoundMs)
    check finished   # RED pre-fix: realRun waits on drainBoth + waitForExit forever
    if finished:
      check line == "OK ok=false outLen=0"

  test "gitdiff.changedFiles (drainBothDeadline via runGit) gives up on a git that never answers":
    putEnv("PATH", fakeGitBin.dir & $PathSep & getEnv("PATH"))
    putEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND", "rev-parse")
    defer:
      delEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND")
    let projectRoot = binDir / "not_a_real_git_call_target"
    createDir(projectRoot)
    let (finished, line) = runWithDeadline(gitProbeBin, @[projectRoot], OuterBoundMs)
    check finished   # RED pre-fix: changedFiles waits on runGit's drainBoth + waitForExit forever
    if finished:
      check line.startsWith("RAISED")
      # `gitdiff_probe` prints only the message's last 32 chars (`tail=`);
      # the raised message is worded to end with this fixed marker so the
      # timeout path is identifiable regardless of `projectRoot`'s length.
      check "CR4 git timeout" in line
