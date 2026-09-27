## test_library_interrupt_rerun.nim — a library host that goes on calling
## `runTests` (`installSignals = true`) after an interrupt (round 13).
##
## A library host outlives any one run: an IDE, a watch loop. Pinned here:
##
##   * R13-D2: an interrupt is a fact about the run it landed in. After an
##     interrupted run, `shutdownRequested()` reads none again, and the next
##     run, with no signal, consults the cache as usual (it used to skip
##     every lookup, so every test re-ran, and to drop its remote puts, for
##     the rest of the process: the signal was sticky).
##   * R13-L3: the Nim fingerprint probe refused because of that interrupt is
##     not memoized: the next run's fingerprint is the real `nim --version`
##     (it used to be `<nim-version-unavailable>` for the rest of the process,
##     which discarded the depgraph and changed every cache key).
##   * R13-D1: a signal that lands after execute() has returned (here, during
##     the `--verify-cache` sub-run) ends the call `rsInterrupted` with
##     128 + n, keeping the run's results (it used to return `rsOk`, and the
##     host never learned of the signal).
##
## In every case crisol's handler, not the host's, takes the signal.
##
## POSIX (Linux) only: it sends real signals. The Windows console control
## handler is not exercised (the container gives no shared console).
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_library_interrupt_rerun.nim

when defined(linux):
  import std/[monotimes, os, osproc, posix, streams, strtabs, strutils, times, unittest]

  const
    fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"
    repoRoot   = currentSourcePath().parentDir().parentDir().parentDir()
    HangSecs = 25
      ## How long the hung discovery compile sleeps when nothing ends it.
    PidWaitMs = 60_000
      ## How long the discovery compile may take to start.
    RunWaitMs = 240_000
      ## How long one host invocation (up to two full runs) may take.

  let hostBin = block:
    let b = getTempDir() / "crisol_librerun_bin" / "library_interrupt_rerun_host"
    createDir(b.parentDir)
    let (o, rc) = execCmdEx("nim c --mm:orc --hints:off --warnings:off --path:" &
                            (repoRoot / "src") & " --nimcache:" &
                            (getTempDir() / "crisol_librerun_nimcache") & " -o:" &
                            b & " " & (fixtureDir / "library_interrupt_rerun_host.nim"))
    doAssert rc == 0, "library_interrupt_rerun_host compile failed:\n" & o
    b

  let wrapperDir = block:
    ## A `nim` that hangs on the stdin compile (the cc probe's discovery
    ## compile, `-` as the input file) ONCE: when CRISOL_TEST_HANG_PIDFILE is
    ## set and the flag file beside it exists, it removes the flag, records
    ## its pid there and hangs; it is the real nim otherwise. One-shot, so the
    ## host's second run sees the same environment as its first, and a probe
    ## memo keyed on the environment cannot hide a poisoned answer.
    let d = getTempDir() / "crisol_librerun_wrapper"
    createDir(d)
    let realNim = findExe("nim")
    doAssert realNim.len > 0
    writeFile(d / "nim", "#!/bin/sh\n" &
      "if [ -n \"$CRISOL_TEST_HANG_PIDFILE\" ] && " &
      "[ -e \"$CRISOL_TEST_HANG_PIDFILE.hang\" ]; then\n" &
      "  for a in \"$@\"; do\n" &
      "    if [ \"$a\" = \"-\" ]; then\n" &
      "      rm -f \"$CRISOL_TEST_HANG_PIDFILE.hang\"\n" &
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
    ## Two passing tests. `test_a` signals the host when the host has left its
    ## pid in `host.pid` and the test the signal number in `late.sig` (the
    ## `late` mode); otherwise it only passes.
    result = getTempDir() / ("crisol_librerun_proj_" & tag & "_" &
                             $getCurrentProcessId())
    removeDir(result)
    createDir(result / "tests" / "unit")
    writeFile(result / "tests" / "unit" / "test_a.nim",
      "import std/[os, posix, strutils]\n" &
      "const pidFile = " & escape(result / "host.pid") & "\n" &
      "const sigFile = " & escape(result / "late.sig") & "\n" &
      "if fileExists(pidFile) and fileExists(sigFile):\n" &
      "  discard kill(Pid(parseInt(readFile(pidFile).strip())),\n" &
      "               cint(parseInt(readFile(sigFile).strip())))\n" &
      "quit(0)\n")
    writeFile(result / "tests" / "unit" / "test_b.nim", "quit(0)\n")
    writeFile(result / "crisol.kdl",
              "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

  proc hostEnv(hangPidFile: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): result[k] = v
    result["PATH"] = wrapperDir & ":" & getEnv("PATH")
    if hangPidFile.len > 0:
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

  proc runHost(root, mode: string): tuple[code: int; output: string] =
    let p = startProcess(hostBin, workingDir = root, args = [root, mode],
                         env = hostEnv(""), options = {poStdErrToStdOut})
    defer: p.close()
    result.code = waitExit(p, RunWaitMs)
    result.output = try: p.outputStream.readAll() except CatchableError: ""

  suite "round 13 — a library host that runs again after an interrupt":
    test "R13-D2/R13-L3: after a planning interrupt, the next run hits the " &
         "cache under the real nim fingerprint and no signal is pending":
      let root = freshProject("intr")
      defer: removeDir(root)
      let warm = runHost(root, "warm")
      checkpoint("warm exit " & $warm.code & ":\n" & warm.output)
      require warm.code == 0
      require "warm status=rsOk exitCode=0" in warm.output

      let pidFile = getTempDir() / ("crisol_librerun_" & $getCurrentProcessId() & ".pid")
      removeFile(pidFile)
      removeFile(pidFile & ".tmp")
      writeFile(pidFile & ".hang", "")
      defer:
        removeFile(pidFile)
        removeFile(pidFile & ".hang")
      let p = startProcess(hostBin, workingDir = root, args = [root, "intr"],
                           env = hostEnv(pidFile), options = {poStdErrToStdOut})
      defer: p.close()
      let toolPid = waitPid(pidFile, PidWaitMs)
      doAssert toolPid > 0, "the discovery compile never started"
      discard posix.kill(Pid(p.processID), SIGINT)
      let code = waitExit(p, RunWaitMs)
      let output = try: p.outputStream.readAll() except CatchableError: ""
      checkpoint("intr exit " & $code & ":\n" & output)
      check code == 0
      check "run1 status=rsInterrupted exitCode=130" in output
      check "betweenShutdown=false" in output
      check "run2 status=rsOk exitCode=0" in output
      check output.count("run2 decision=cdmHit") == 2
      check "fingerprint=<nim-version-unavailable>" notin output
      check "fingerprint=Nim Compiler Version" in output
      check "markerFired=false" in output
      discard posix.kill(Pid(toolPid), SIGKILL)

    for (sig, want) in [(SIGINT, 130), (SIGTERM, 143)]:
      test "R13-D1: signal " & $sig & " during the verify sub-run, after " &
           "execute() returned, ends runTests rsInterrupted with " & $want:
        let root = freshProject("late" & $sig)
        defer: removeDir(root)
        let warm = runHost(root, "warm")
        checkpoint("warm exit " & $warm.code & ":\n" & warm.output)
        require warm.code == 0
        require "warm status=rsOk exitCode=0" in warm.output
        writeFile(root / "late.sig", $sig)
        let late = runHost(root, "late")
        checkpoint("late exit " & $late.code & ":\n" & late.output)
        check late.code == 0
        check ("late status=rsInterrupted exitCode=" & $want &
               " interrupted=true results=2") in late.output
        check "markerFired=false" in late.output

when isMainModule:
  echo "test_library_interrupt_rerun done"
