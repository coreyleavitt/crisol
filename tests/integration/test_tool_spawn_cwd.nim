## test_tool_spawn_cwd.nim -- R12-L1: a tool run with a working directory
## never moves crisol's own cwd, whether or not the spawn succeeds.
##
## THE FINDING. On POSIX, `osproc.startProcess`'s posix_spawn path changes
## the PARENT's cwd to `workingDir` before spawning, and changes it back only
## when the spawn succeeds. A spawn that fails (`posix_spawnp` ENOENT: the
## tool is not on PATH, or a relative driver path that does not resolve from
## `workingDir`) left crisol inside `workingDir`. The C toolchain probe runs
## its tools in a scratch directory it then deletes, so the next
## `getCurrentDir` raised and every command died ("unexpected error during
## plan: No such file or directory"; `crisol list` exited 1).
##
## WHAT THIS FILE PINS. `toolexec.runTool` with a `workingDir`:
##   * a command not on PATH ends `reNotStarted` and crisol's cwd is unchanged;
##   * so does a relative command path that does not exist from `workingDir`;
##   * with `workingDir` deleted afterwards (the probe's scratch lifecycle),
##     `getCurrentDir` still answers;
##   * CONTROL: a spawn that succeeds runs in `workingDir` and leaves crisol's
##     cwd unchanged.
## Windows passes the directory to `CreateProcess` and never moved the
## parent; the same assertions hold there.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_tool_spawn_cwd.nim

import std/[os, osproc, strutils, tempfiles, unittest]
import crisol/toolexec

const
  Cap = 1 shl 20
  Deadline = 30_000

let home = getCurrentDir()

suite "R12-L1 -- a tool spawn never moves crisol's cwd":

  setup:
    # Each test starts from the same cwd, so one that fails does not leave
    # the next inside a deleted directory.
    setCurrentDir(home)

  test "a command not on PATH: reNotStarted, cwd unchanged, even after the dir is gone":
    let before = getCurrentDir()
    let scratch = createTempDir("r12l1_scratch_", "")
    let r = runTool("crisol-no-such-tool-r12l1", ["--version"], scratch,
                    {poUsePath}, "", Deadline, Cap)
    check r.ending == reNotStarted
    check getCurrentDir() == before
    removeDir(scratch)
    check getCurrentDir() == before     # raised before the fix: cwd was scratch

  test "a relative command path that does not resolve from workingDir: cwd unchanged":
    let before = getCurrentDir()
    let scratch = createTempDir("r12l1_scratch_", "")
    defer: removeDir(scratch)
    let r = runTool("wbin" / "crisol-no-such-tool-r12l1", [], scratch,
                    {poUsePath}, "", Deadline, Cap)
    check r.ending == reNotStarted
    check getCurrentDir() == before

  test "a bounded and an unbounded failed spawn both leave the cwd alone":
    let before = getCurrentDir()
    let scratch = createTempDir("r12l1_scratch_", "")
    defer: removeDir(scratch)
    for timeout in [Deadline, NoDeadline]:
      checkpoint $timeout
      let r = runTool("crisol-no-such-tool-r12l1", [], scratch,
                      {poUsePath, poStdErrToStdOut}, "", timeout, Cap)
      check r.ending == reNotStarted
      check getCurrentDir() == before

  test "CONTROL a spawn that succeeds runs in workingDir and leaves crisol's cwd":
    let before = getCurrentDir()
    let scratch = createTempDir("r12l1_scratch_", "")
    defer: removeDir(scratch)
    writeFile(scratch / "r12l1_marker.txt", "")
    let r = when defined(windows):
        runTool("cmd.exe", ["/c", "dir", "/b"], scratch, {poUsePath}, "",
                Deadline, Cap)
      else:
        runTool("ls", [], scratch, {poUsePath}, "", Deadline, Cap)
    check r.ok
    check "r12l1_marker.txt" in r.output
    check getCurrentDir() == before

echo "test_tool_spawn_cwd done"
