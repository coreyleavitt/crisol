## test_tool_tree_termination.nim — how a tool run ends when the tool is not
## alone: R3-12 (a descendant that holds the capture pipes) and R5-19 (the
## reap half of `terminateAndReap`).
##
## R3-12. A tool that starts a helper which inherits its stdout and outlives
## it (a compiler server, a backgrounded wrapper step) leaves the capture
## pipes open after the tool itself has exited. The drain waited for an EOF
## that only the helper could deliver, so the run sat out its whole deadline,
## was reported as a TIMEOUT (for git: "may be blocked on a credential
## prompt", which it was not), and the helper was left running: termination
## was single-process. Pinned here:
##
##   * the run ends within `PostExitDrainMs` of the tool's exit, not at the
##     deadline;
##   * it is NOT a finished run (`reIoError`, saying the output was held
##     open): the pipes never reached EOF, so the capture cannot be shown to
##     be complete, and whatever the helper might still have written is
##     unknowable;
##   * the helper is dead afterwards: a bounded run owns its process tree
##     (its own process group on POSIX, a Job Object on Windows).
##
## R5-19 (Linux). `terminateAndReap` must REAP the child it kills. A test that
## scans `/proc/*/cmdline` cannot see a missed reap (a zombie's cmdline is
## empty), so this reads `/proc/<pid>/stat`'s state letter for the one pid
## the tool reported, and first proves that observation sees a zombie when
## one exists. Windows has no zombie state (closing the process handle is the
## whole of reaping), so that suite is Linux-only by construction.
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_tool_tree_termination.nim

import std/[monotimes, os, osproc, strutils, times, unittest]
import crisol/toolexec

when defined(windows):
  import std/winlean

const
  fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
  binDir     = fixtureDir / "bin" / "treeterm"
  cacheDir   = fixtureDir / "nimcache" / "treeterm"
  RunDeadlineMs = 10_000
    ## The run's own deadline. The held-pipe run must end far inside it.
  HeldCeilingMs = PostExitDrainMs + 2 * TerminateGraceMs + 1_500
    ## Worst case of the held-pipe path: the post-exit bound, then
    ## `terminateAndReap`'s two grace waits, plus spawn/scheduling headroom.
  DeathWaitMs = 3_000
    ## How long a killed descendant may take to be gone. It is not this
    ## process's child, so nothing here can wait on it; the kill is
    ## asynchronous on both platforms.

static:
  doAssert HeldCeilingMs < RunDeadlineMs,
    "the held-pipe ceiling must sit under the run deadline, or ending at " &
    "the deadline would pass"

let holderBin = block:
  createDir(binDir)
  let b = binDir / "pipe_holder".addFileExt(ExeExt)
  let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --nimcache:" &
                          (cacheDir / "pipe_holder") & " -o:" & b & " " &
                          (fixtureDir / "pipe_holder.nim"))
  doAssert rc == 0, "pipe_holder compile failed:\n" & o
  b

proc freshPidFile(tag: string): string =
  result = getTempDir() / ("crisol_treeterm_" & $getCurrentProcessId() &
                           "_" & tag & ".pid")
  removeFile(result)
  removeFile(result & ".tmp")

proc readPid(path: string): int =
  if not fileExists(path): return -1
  try: parseInt(readFile(path).strip()) except ValueError: -1

when defined(linux):
  proc procState(pid: int): string =
    ## `/proc/<pid>/stat`'s state letter, or "" when the pid is gone.
    let st = try: readFile("/proc" / $pid / "stat") except IOError: ""
    if st.len == 0: return ""
    let afterComm = st.rfind(')')   # comm is parenthesised and may hold spaces
    if afterComm < 0: return "?"
    let fields = st[afterComm + 1 .. ^1].splitWhitespace()
    if fields.len > 0: fields[0] else: "?"

proc descendantGone(pid: int; waitMs: int): bool =
  ## True once `pid` is no longer running (gone, or a zombie awaiting its
  ## new parent's reap), within `waitMs`.
  when defined(windows):
    let h = openProcess(SYNCHRONIZE, 0, DWORD(pid))
    if h == 0: return true   # no such process
    defer: discard closeHandle(h)
    waitForSingleObject(h, DWORD(waitMs)) == WAIT_OBJECT_0
  elif defined(linux):
    let start = getMonoTime()
    while true:
      let s = procState(pid)
      if s == "" or s == "Z": return true
      if (getMonoTime() - start).inMilliseconds >= waitMs: return false
      sleep(20)
  else:
    {.error: "descendantGone: no observation for this OS".}

suite "R3-12 — a descendant holding the tool's output":

  for merged in [false, true]:
    let label = if merged: "merged" else: "separate"
    test "a tool whose descendant holds its " & label &
         " output ends promptly, not as a finished run":
      let pidFile = freshPidFile("hold_" & label)
      var opts = {poUsePath}
      if merged: opts.incl poStdErrToStdOut
      let t0 = getMonoTime()
      let r = runTool(holderBin, ["hold", pidFile], "", opts, "",
                      RunDeadlineMs, MaxToolOutputBytes)
      let elapsedMs = (getMonoTime() - t0).inMilliseconds
      checkpoint("ending: " & describe(r) & " after " & $elapsedMs & "ms")
      check r.ending == reIoError
      check "held" in describe(r)
      check elapsedMs < HeldCeilingMs

      let gpid = readPid(pidFile)
      check gpid > 0   # the fixture really started the holder
      if gpid > 0:
        # The tree kill: the holder is not this process's child and was
        # re-parented when the tool exited, so only a group/job kill reaches it.
        check descendantGone(gpid, DeathWaitMs)
      removeFile(pidFile)

when defined(linux):
  suite "R5-19 — terminateAndReap reaps what it kills":

    test "the /proc state observation sees a zombie when one exists":
      ## Guards the next test against the vacuous green: an observation that
      ## never reports `Z` would "prove" every reap.
      let p = startProcess(holderBin, args = ["exit"], options = {})
      defer: p.close()
      let pid = p.processID
      var seen = ""
      let start = getMonoTime()
      while (getMonoTime() - start).inMilliseconds < 5_000:
        seen = procState(pid)
        if seen == "Z": break
        sleep(10)
      check seen == "Z"   # exited and not yet reaped: nothing waited on it
      discard p.waitForExit()
      check procState(pid) == ""   # and the reap removes it

    test "a timed-out tool is reaped before runTool returns, not left a zombie":
      let pidFile = freshPidFile("hang")
      let r = runTool(holderBin, ["hang", pidFile], "", {poUsePath}, "",
                      1_500, MaxToolOutputBytes)
      check r.ending == reTimedOut
      let pid = readPid(pidFile)
      check pid > 0
      if pid > 0:
        let s = procState(pid)
        checkpoint("state of the tool's pid after runTool returned: '" & s & "'")
        check s == ""   # "Z" is the missed reap; anything else is a survivor
      removeFile(pidFile)

when isMainModule:
  echo "test_tool_tree_termination done"
