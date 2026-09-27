## test_library_interrupt_in_planning.nim — a library host's `runTests`
## with `installSignals = true` owns SIGINT/SIGTERM from its first act, so an
## interrupt while crisol is still planning ends the bounded tool it is
## running and returns (R12-D3).
##
## A bounded tool runs in a process group of its own, out of reach of the
## signal the host receives. Before the fix, `runTests` installed its
## handler only once execution began (the Supervisor's), so an interrupt
## during planning (nim discovery, the cc probe, git) went to the host's own
## handler, nothing killed the tool, and the run sat out the tool's whole
## run (measured: the full 25 s of a `nim` that hangs in the discovery
## compile). Pinned here, for SIGINT and SIGTERM sent to the host process
## alone while its discovery compile hangs:
##
##   * the hung tool is gone promptly, well inside its own lifetime;
##   * `runTests` returns promptly with the documented interrupted status
##     (`rsInterrupted`, `interrupted` true, exit code 128 + the signal);
##   * crisol's handler, not the host's, took the signal, and the host's
##     own handlers are back in place when `runTests` returns.
##
## POSIX (Linux) only: it sends real signals and reads /proc. The Windows
## console control handler is not exercised (a `GenerateConsoleCtrlEvent`
## needs a shared console the container run does not give);
## tests/integration/test_tool_interrupt.nim covers the registry's kill path
## there.
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_library_interrupt_in_planning.nim

when defined(linux):
  import std/[monotimes, os, osproc, posix, streams, strtabs, strutils, times, unittest]

  const
    fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
    repoRoot   = currentSourcePath().parentDir().parentDir().parentDir()
    HangSecs = 25
      ## How long the hung discovery compile sleeps when nothing ends it.
    PromptMs = 5_000
      ## How long an interrupt may take to end the tool and the run.
    DeathWaitMs = 3_000
    PidWaitMs = 60_000
      ## How long the discovery compile may take to start.

  static:
    doAssert PromptMs < HangSecs * 1000 div 2

  let hostBin = block:
    let b = getTempDir() / "crisol_libintr_bin" / "library_interrupt_host"
    createDir(b.parentDir)
    let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --warnings:off --path:" &
                            (repoRoot / "src") & " --nimcache:" &
                            (getTempDir() / "crisol_libintr_nimcache") & " -o:" &
                            b & " " & (fixtureDir / "library_interrupt_host.nim"))
    doAssert rc == 0, "library_interrupt_host compile failed:\n" & o
    b

  let wrapperDir = block:
    ## A `nim` that hangs on the stdin compile (the cc probe's discovery
    ## compile, `-` as the input file) when CRISOL_TEST_HANG_PIDFILE is set,
    ## recording its pid there, and is the real nim otherwise.
    let d = getTempDir() / "crisol_libintr_wrapper"
    createDir(d)
    let realNim = findExe("nim")
    doAssert realNim.len > 0
    writeFile(d / "nim", "#!/bin/sh\n" &
      "if [ -n \"$CRISOL_TEST_HANG_PIDFILE\" ]; then\n" &
      "  for a in \"$@\"; do\n" &
      "    if [ \"$a\" = \"-\" ]; then\n" &
      "      echo $$ > \"$CRISOL_TEST_HANG_PIDFILE.tmp\"\n" &
      "      mv \"$CRISOL_TEST_HANG_PIDFILE.tmp\" \"$CRISOL_TEST_HANG_PIDFILE\"\n" &
      "      exec sleep " & $HangSecs & "\n" &
      "    fi\n" &
      "  done\n" &
      "fi\n" &
      "exec " & quoteShell(realNim) & " \"$@\"\n")
    setFilePermissions(d / "nim", {fpUserRead, fpUserWrite, fpUserExec,
                                   fpGroupRead, fpGroupExec, fpOthersRead,
                                   fpOthersExec})
    d

  proc freshProject(tag: string): string =
    result = getTempDir() / ("crisol_libintr_proj_" & tag & "_" &
                             $getCurrentProcessId())
    removeDir(result)
    createDir(result / "tests" / "unit")
    writeFile(result / "tests" / "unit" / "test_a.nim", "quit(0)\n")
    writeFile(result / "crisol.kdl",
              "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

  proc hostEnv(hangPidFile: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): result[k] = v
    result["PATH"] = wrapperDir & ":" & getEnv("PATH")
    result["CRISOL_TEST_HANG_PIDFILE"] = hangPidFile

  proc readPid(path: string): int =
    if not fileExists(path): return -1
    try: parseInt(readFile(path).strip()) except ValueError: -1

  proc waitPid(path: string; waitMs: int): int =
    let start = getMonoTime()
    while (getMonoTime() - start).inMilliseconds < waitMs:
      let pid = readPid(path)
      if pid > 0: return pid
      sleep(20)
    -1

  proc procState(pid: int): string =
    ## `/proc/<pid>/stat`'s state letter, or "" when the pid is gone.
    let st = try: readFile("/proc" / $pid / "stat") except IOError: ""
    if st.len == 0: return ""
    let afterComm = st.rfind(')')
    if afterComm < 0: return "?"
    let fields = st[afterComm + 1 .. ^1].splitWhitespace()
    if fields.len > 0: fields[0] else: "?"

  proc toolGone(pid: int; waitMs: int): bool =
    ## True once `pid` is no longer running (gone, or a zombie awaiting a
    ## reap), within `waitMs`.
    let start = getMonoTime()
    while true:
      let s = procState(pid)
      if s == "" or s == "Z": return true
      if (getMonoTime() - start).inMilliseconds >= waitMs: return false
      sleep(20)

  proc waitExit(p: Process; waitMs: int): int =
    ## `p`'s exit code within `waitMs`, or -1 (and `p` killed) past it.
    let start = getMonoTime()
    while (getMonoTime() - start).inMilliseconds < waitMs:
      let c = p.peekExitCode()
      if c != -1: return c
      sleep(20)
    p.kill()
    discard p.waitForExit()
    -1

  suite "R12-D3 — a library host interrupted while runTests is planning":
    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "signal " & $sig & " ends the hung tool and runTests returns " &
           "interrupted with exit code " & $want & ", host handlers restored":
        let root = freshProject($sig)
        defer: removeDir(root)
        let pidFile = getTempDir() / ("crisol_libintr_" & $getCurrentProcessId() &
                                      "_" & $sig & ".pid")
        removeFile(pidFile)
        removeFile(pidFile & ".tmp")
        defer: removeFile(pidFile)
        let p = startProcess(hostBin, workingDir = root, args = [root],
                             env = hostEnv(pidFile),
                             options = {poStdErrToStdOut})
        defer: p.close()
        let toolPid = waitPid(pidFile, PidWaitMs)
        doAssert toolPid > 0, "the discovery compile never started"
        let t0 = getMonoTime()
        # The host alone, not its group: the tool is in a group of its own
        # either way, and only crisol's handler can reach it.
        discard posix.kill(Pid(p.processID), sig)
        let gone = toolGone(toolPid, PromptMs)
        let code = waitExit(p, HangSecs * 1000 + 10_000)
        let afterMs = (getMonoTime() - t0).inMilliseconds
        let output = try: p.outputStream.readAll() except CatchableError: ""
        checkpoint("host exit " & $code & " after " & $afterMs &
                   "ms; output:\n" & output)
        check gone
        check afterMs < PromptMs
        check code == 0
        check ("status=rsInterrupted exitCode=" & $want & " interrupted=true") in output
        check "restored=true" in output
        check "markerFired=false" in output
        if not gone: discard posix.kill(Pid(toolPid), SIGKILL)

when isMainModule:
  echo "test_library_interrupt_in_planning done"
