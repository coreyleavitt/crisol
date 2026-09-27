## test_issue26_promotion_interrupt.nim — issue #26: a run that ends
## between recording an entrypoint's closure and promoting its binary must
## not leave the new depgraph entry beside the OLD stable binary.
##
## `finalizeSlot` records a freshly-compiled entrypoint's closure (and
## persists the depgraph) at the compile→run transition, before the test
## runs; the stable binary is promoted only once the run has finished. A run
## that ends in between — an interrupt, a `kill -9`, a crash, a run-phase
## spawn failure — used to leave the NEW entry next to the PREVIOUS stable
## binary. `decideCompile` never asks which compile a binary came from, so
## the next run compile-skipped, ran the old binary, and reported PASS for
## code that now fails (and could store that PASS in the result cache under
## the new key).
##
## Each case below: run 1 passes (version A) and leaves a stable binary;
## the test is edited to fail (version B); run 2 is cut short after its
## compile, in the run phase; run 3, with no further edit, must recompile
## and FAIL. RED before the fix: run 3 passed, running version A.
##
##   * SIGINT to the real CLI during the run phase (POSIX);
##   * SIGKILL to the real CLI during the run phase (POSIX), or
##     TerminateProcess on Windows — nothing of crisol's runs after it;
##   * a run-phase spawn failure (library `execute`, provoked by pointing the
##     temp directory at a path that does not exist right after the closure
##     is recorded, so `transitionToRun` cannot create the run's scratch
##     directory).
##
## The guard itself — `runner.retireThenRecordClosure` retires the previous
## stable binary before the new entry is persisted — is also driven where
## the retire FAILS: the entry must be dropped (in memory and on disk), not
## persisted beside the old binary, so the next plan does not compile-skip.
## Portably through its `retireFn` seam, both directly and through a real
## `execute()` run (`execute*`'s `retireFn` param, which `finalizeSlot`
## forwards); on Windows also for real, with the old binary held open (as
## root on POSIX, permissions cannot block it).
##
## R19: the failure is reported once, on stderr and in the structured
## warnings, where it happens -- so a blocked stable path prints ONE warning
## (the unrecorded binary is never promoted, so no promotion failure
## follows), a run-phase spawn failure after it still reports it, and a
## promotion that fails with the closure recorded reports its own
## "promote-binary" warning.
##
## R20-S1: with retries, the warning reports the run's outcome: an attempt
## that fails to record while another could still record it holds the
## warning; a later attempt that records withdraws it (no warning, binary
## promoted), and otherwise it is reported once -- when the last attempt is
## decided (every attempt failed; a run-phase spawn failure, never retried)
## or when the run stops before the retry (fail-fast).
##
## R21-S1: reporting a warning never raises. With fd 2 unwritable, a run
## whose last attempt settles its warning returns normally (the structured
## copy kept), and an exception unwinding `execute` past a held warning is
## the one the caller sees, not the `finally` sweep's failed stderr write.
## R22-D2: those cases are load-bearing on POSIX only. The MSVC CRT never
## reports a failed stderr write (`withStderrUnwritable`'s doc), so on the
## Windows leg they pass vacuously: nothing raises with or without the fix.
##
## R22-D1: a seam that raises after the compile child is reaped (a retire
## or a closure recorder) reaches the caller as itself, not as the
## teardown's AssertionDefect for the consumed ChildId.
##
## Run with:
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue26_promotion_interrupt.nim

import std/[json, monotimes, options, os, osproc, streams, strutils, tables, times, unittest]
import crisol/[types, runner, depgraph, planner, closure, toolrun]
from crisol/headerprobe import siteResolver
import "../support/testep"
import "../support/driversite"
import "../support/capture"

when defined(windows):
  import std/winlean

const
  repoRoot  = currentSourcePath().parentDir().parentDir().parentDir()
  StartWaitMs = 180_000
    ## How long run 2 may take to reach its run phase (it compiles first).
  RunWaitMs = 240_000

proc versionA(): string =
  "echo \"version A\"\nquit(0)\n"

proc versionB(startedFile, holdFile: string): string =
  ## Signals that the run phase has started (its pid), then fails — after
  ## holding while `holdFile` exists, so run 2 can be cut short mid-run.
  "import std/os\n" &
  "writeFile(" & escape(startedFile & ".tmp") & ", $getCurrentProcessId())\n" &
  "moveFile(" & escape(startedFile & ".tmp") & ", " & escape(startedFile) & ")\n" &
  "echo \"version B\"\n" &
  "var i = 0\n" &
  "while fileExists(" & escape(holdFile) & ") and i < 1200:\n" &
  "  sleep(50)\n" &
  "  inc i\n" &
  "quit(1)\n"

proc readPid(path: string): int =
  if not fileExists(path): return -1
  try: parseInt(readFile(path).strip()) except ValueError, IOError: -1

proc waitPidOrExit(path: string; p: Process; waitMs: int): int =
  ## The pid in `path` once it appears, or -1 when `p` exits first or the
  ## wait runs out.
  let start = getMonoTime()
  while (getMonoTime() - start).inMilliseconds < waitMs:
    let pid = readPid(path)
    if pid > 0: return pid
    if p.peekExitCode() != -1: return -1
    sleep(20)
  -1

proc waitExit(p: Process; waitMs: int): int =
  let start = getMonoTime()
  while (getMonoTime() - start).inMilliseconds < waitMs:
    let c = p.peekExitCode()
    if c != -1: return c
    sleep(20)
  p.kill()
  discard p.waitForExit()
  -1

proc killHard(pid: int) =
  ## SIGKILL / TerminateProcess, ignoring a pid that is already gone. (No
  ## std/posix import: the kill(1) of the shell does it, keeping this file
  ## out of the RFC-0009 posix-import sweep.)
  when defined(windows):
    let h = openProcess(PROCESS_TERMINATE, 0, DWORD(pid))
    if h != 0:
      discard terminateProcess(h, 1)
      discard closeHandle(h)
  else:
    discard execCmdEx("kill -KILL " & $pid)

# ---------------------------------------------------------------------------
# The real CLI, cut short in run 2's run phase.
# ---------------------------------------------------------------------------

let crisolBin = block:
  let b = getTempDir() / "crisol_issue26_bin" / "crisol".addFileExt(ExeExt)
  createDir(b.parentDir)
  let (o, rc) = execCmdEx("nim c --hints:off --warnings:off --mm:orc --nimcache:" &
                          quoteShell(getTempDir() / "crisol_issue26_nimcache") &
                          " -o:" & quoteShell(b) & " " &
                          quoteShell(repoRoot / "src" / "crisol.nim"))
  doAssert rc == 0, "crisol build failed:\n" & o
  b

proc freshProject(tag: string): string =
  result = getTempDir() / ("crisol_issue26_proj_" & tag & "_" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")
  writeFile(result / "tests" / "unit" / "test_a.nim", versionA())
  writeFile(result / "crisol.kdl",
            "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

proc runArgs(root: string): seq[string] =
  @["run", "--config", root / "crisol.kdl", "--jobs", "1"]

proc runCli(root: string; extra: seq[string] = @[]):
            tuple[output: string; code: int] =
  let p = startProcess(crisolBin, workingDir = root, args = runArgs(root) & extra,
                       options = {poStdErrToStdOut})
  defer: p.close()
  var output = ""
  let outS = p.outputStream
  var line = ""
  while outS.readLine(line):
    output.add line & "\n"
  (output, p.waitForExit())

type Cut = enum cutInterrupt, cutKill

template cutRunTwo(cut: Cut) =
  ## A template, not a proc: `check`/`require` must land in the calling test.
  let root = freshProject($cut)
  defer: removeDir(root)
  let startedFile = root / "started.pid"
  let holdFile    = root / "hold"

  let r1 = runCli(root)
  checkpoint("run 1 (version A), exit " & $r1.code & ":\n" & r1.output)
  require r1.code == 0

  writeFile(root / "tests" / "unit" / "test_a.nim", versionB(startedFile, holdFile))
  writeFile(holdFile, "")
  let p = startProcess(crisolBin, workingDir = root, args = runArgs(root),
                       options = {poStdErrToStdOut})
  let childPid = waitPidOrExit(startedFile, p, StartWaitMs)
  if childPid <= 0:
    let c = waitExit(p, 1_000)
    p.close()
    doAssert false, "run 2 never reached its run phase (exit " & $c & ")"
  case cut
  of cutInterrupt:
    when defined(windows):
      doAssert false, "unreachable: the interrupt case is POSIX only"
    else:
      let (o, rc) = execCmdEx("kill -INT " & $p.processID)
      doAssert rc == 0, "kill -INT failed: " & o
  of cutKill:
    p.kill()   # SIGKILL on POSIX, TerminateProcess on Windows
  let c2 = waitExit(p, RunWaitMs)
  p.close()
  checkpoint("run 2 (version B, " & $cut & ") exit " & $c2)
  # The run child is crisol's to end on an interrupt; after a hard kill it
  # may outlive crisol. Either way, let nothing of run 2 linger.
  removeFile(holdFile)
  killHard(childPid)
  removeFile(startedFile)

  let r3 = runCli(root)
  checkpoint("run 3 (version B, no further edit), exit " & $r3.code & ":\n" & r3.output)
  check r3.code != 0
  check "version B" in r3.output
  check "version A" notin r3.output

suite "issue #26 — a run cut short between closure record and promotion":
  when not defined(windows):
    test "SIGINT during the run phase: the next run recompiles and fails":
      cutRunTwo(cutInterrupt)

  test "a hard kill (SIGKILL / TerminateProcess) during the run phase: " &
       "the next run recompiles and fails":
    cutRunTwo(cutKill)

# ---------------------------------------------------------------------------
# A run-phase spawn failure, through the library `execute`.
# ---------------------------------------------------------------------------

const TmpVars = ["TMPDIR", "TMP", "TEMP"]
var savedTmp: seq[(string, bool, string)]

proc breakTempDir() =
  savedTmp.setLen(0)
  for v in TmpVars:
    savedTmp.add (v, existsEnv(v), getEnv(v))
    putEnv(v, getTempDir() / "crisol_issue26_no_such_dir" / "nested")

proc restoreTempDir() =
  for (v, had, val) in savedTmp:
    if had: putEnv(v, val) else: delEnv(v)
  savedTmp.setLen(0)

proc recordThenBreakTemp(graph: var DepGraph; config: Config; ep: Entrypoint;
                         nimcacheDir, binaryName: string;
                         protocolMajor: int; index: SourceIndex;
                         driver: DriverResolver;
                         ccRun: RunProc): tuple[ok: bool, error: string] =
  ## The real `recordClosure` — the new entry IS persisted — after which the
  ## run phase cannot create its scratch directory, so its spawn fails.
  result = recordClosure(graph, config, ep, nimcacheDir, binaryName,
                         protocolMajor, index, driver, ccRun)
  breakTempDir()

suite "issue #26 — a run-phase spawn failure after the closure is recorded":
  test "a run-phase spawn failure: the next run recompiles and fails":
    let root = getTempDir() / ("crisol_issue26_spawn_" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "tests")
    defer: removeDir(root)
    var cfg = Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
                     timeoutSecs: 60, compileTimeoutSecs: 180,
                     maxOutputBytes: 65_536)
    cfg.trackedRoots = initTrackedRoots(root, @[], "")
    let ep = testEp("tests/test_a.nim", group = "default", flags = @[])

    writeFile(root / "tests" / "test_a.nim", versionA())
    var graph = initDepGraph("")
    let r1 = execute(plan(cfg, @[ep], graph), config = cfg, graph = graph,
                     nimVersion = "", showProgress = false,
                     toolchain = unprobedToolchain()).results
    require r1.len == 1
    require r1[0].outcome == oPassed

    writeFile(root / "tests" / "test_a.nim",
              versionB(root / "started.pid", root / "hold"))
    let plan2 = plan(cfg, @[ep], graph)
    require plan2.entrypoints[0].edecision == edStale
    var r2: seq[EntrypointResult]
    try:
      r2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                   showProgress = false, recordClosureFn = recordThenBreakTemp,
                   toolchain = unprobedToolchain()).results
    finally:
      restoreTempDir()
    require r2.len == 1
    checkpoint("run 2 output: " & r2[0].output)
    require r2[0].outcome == oSpawnError

    var graph3 = loadDepGraph(cfg, "", "")
    let plan3 = plan(cfg, @[ep], graph3)
    checkpoint("run 3 decision: " & $plan3.entrypoints[0].edecision & " (" &
               plan3.entrypoints[0].reason & ")")
    check plan3.entrypoints[0].edecision != edRunFresh
    let r3 = execute(plan3, config = cfg, graph = graph3, nimVersion = "",
                     showProgress = false, toolchain = unprobedToolchain()).results
    require r3.len == 1
    checkpoint("run 3 output: " & r3[0].output)
    check r3[0].outcome == oFailed
    check "version B" in r3[0].output

# ---------------------------------------------------------------------------
# The previous stable binary cannot be removed: `retireThenRecordClosure`
# must drop the entry instead of persisting it.
# ---------------------------------------------------------------------------

var recorderCalls = 0

proc persistingRecorder(graph: var DepGraph; config: Config; ep: Entrypoint;
                        nimcacheDir, binaryName: string;
                        protocolMajor: int; index: SourceIndex;
                        driver: DriverResolver;
                        ccRun: RunProc): tuple[ok: bool, error: string] =
  ## Stands in for a successful recording: persists the graph as it holds
  ## (the entry from run 1 included) and reports ok. Reaching it at all
  ## after a failed retire is the defect.
  inc recorderCalls
  discard saveDepGraph(graph, config)
  (ok: true, error: "")

var retiredPaths: seq[string]

proc failingRetire(path: string): tuple[ok: bool, error: string] =
  retiredPaths.add path
  (ok: false, error: "simulated: the file is in use")

proc failingRetireBreakTemp(path: string): tuple[ok: bool, error: string] =
  ## A failed retire, after which the run phase cannot create its scratch
  ## directory, so its spawn fails.
  result = failingRetire(path)
  breakTempDir()

proc blockingRetire(path: string): tuple[ok: bool, error: string] =
  ## The real retire, which succeeds; then a directory takes the stable
  ## path, so the closure records but the promotion after the run fails.
  result = retireStableBinary(path)
  createDir(path)
  writeFile(path / "keep", "")

proc passOnce(tag: string): tuple[root: string; cfg: Config; ep: Entrypoint;
                                  graph: DepGraph] =
  ## Run 1 (version A) through the library `execute`: a persisted entry and
  ## a stable binary built from it.
  let root = getTempDir() / ("crisol_issue26_" & tag & "_" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "tests")
  var cfg = Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
                   timeoutSecs: 60, compileTimeoutSecs: 180,
                   maxOutputBytes: 65_536)
  cfg.trackedRoots = initTrackedRoots(root, @[], "")
  let ep = testEp("tests/test_a.nim", group = "default", flags = @[])
  writeFile(root / "tests" / "test_a.nim", versionA())
  var graph = initDepGraph("")
  let r1 = execute(plan(cfg, @[ep], graph), config = cfg, graph = graph,
                   nimVersion = "", showProgress = false,
                   toolchain = unprobedToolchain()).results
  doAssert r1.len == 1 and r1[0].outcome == oPassed, "run 1 did not pass"
  doAssert fileExists(stableBinPath(ep, cfg)), "run 1 left no stable binary"
  (root, cfg, ep, graph)

template checkEntryDropped(cfg: Config; ep: Entrypoint; graph: DepGraph;
                           rec: tuple[ok: bool, error: string]) =
  ## A template, not a proc: `check` must land in the calling test.
  let key = entryKey(ep.tp, ep.flags)
  checkpoint("result: " & $rec)
  check not rec.ok
  check "could not remove the previous binary" in rec.error
  check stableBinPath(ep, cfg) in rec.error
  check recorderCalls == 0
  check key notin graph.entries
  var onDisk = loadDepGraph(cfg, "", "")
  check key notin onDisk.entries
  let next = plan(cfg, @[ep], onDisk)
  checkpoint("next decision: " & $next.entrypoints[0].edecision & " (" &
             next.entrypoints[0].reason & ")")
  check next.entrypoints[0].edecision != edRunFresh

suite "issue #26 — the previous stable binary cannot be removed":
  test "a failed retire drops the entry instead of persisting it":
    var (root, cfg, ep, graph) = passOnce("retire_seam")
    defer: removeDir(root)
    require entryKey(ep.tp, ep.flags) in graph.entries
    recorderCalls = 0
    let rec = retireThenRecordClosure(
      graph, cfg, ep, root / "nimcache",
      buildSourceIndex(cfg), siteResolver(unprobedSite()), realRunIn(root),
      persistingRecorder, failingRetire)
    checkEntryDropped(cfg, ep, graph, rec)

  test "a failed retire through execute(): the entry is dropped and the " &
       "next run recompiles the new source":
    var (root, cfg, ep, graph) = passOnce("retire_execute")
    defer: removeDir(root)
    let key = entryKey(ep.tp, ep.flags)
    require key in graph.entries
    writeFile(root / "tests" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
    let plan2 = plan(cfg, @[ep], graph)
    require plan2.entrypoints[0].edecision == edStale
    retiredPaths.setLen(0)
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                     showProgress = false, retireFn = failingRetire,
                     toolchain = unprobedToolchain()))
    let r2 = rep2.results
    checkpoint("run 2 stderr:\n" & err2)
    # The injected retire is the one `finalizeSlot` calls, on the stable path.
    check retiredPaths == @[stableBinPath(ep, cfg)]
    require r2.len == 1
    check r2[0].outcome == oPassed
    # The closure warning names the binary that could not be removed.
    check ("could not remove the previous binary " & stableBinPath(ep, cfg)) in err2
    # R18-D1: the same fact on the structured channel (cache off here), with
    # the very message stderr carried.
    checkpoint("run 2 warnings: " & $rep2.warnings)
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "closure-record"
    check rep2.warnings[0].key == string(ep.tp.display())
    check ("could not remove the previous binary " & stableBinPath(ep, cfg)) in
          rep2.warnings[0].message
    check ("crisol: warning: " & rep2.warnings[0].message) in err2
    # The entry is dropped, in memory and on disk.
    check key notin graph.entries
    var graph3 = loadDepGraph(cfg, "", "")
    check key notin graph3.entries
    let plan3 = plan(cfg, @[ep], graph3)
    checkpoint("run 3 decision: " & $plan3.entrypoints[0].edecision & " (" &
               plan3.entrypoints[0].reason & ")")
    check plan3.entrypoints[0].edecision != edRunFresh
    let r3 = execute(plan3, config = cfg, graph = graph3, nimVersion = "",
                     showProgress = false, toolchain = unprobedToolchain()).results
    require r3.len == 1
    checkpoint("run 3 output: " & r3[0].output)
    check not r3[0].compileSkipped
    check r3[0].outcome == oPassed
    check "version B" in r3[0].output
    check "version A" notin r3[0].output

  test "a failed retire through the CLI with --json: the unrecorded closure " &
       "is in the warnings array":
    # R18-D1: the real retire, failing on every platform (and as root): a
    # directory stands where the previous stable binary was, so removeFile
    # refuses it. Run 2's `--json` document is read the way a consumer whose
    # stderr is swallowed reads it -- cache off, so no `cacheDecision`
    # carries the fact either.
    let root = freshProject("json")
    defer: removeDir(root)
    let r1 = runCli(root)
    checkpoint("run 1 (version A), exit " & $r1.code & ":\n" & r1.output)
    require r1.code == 0
    var stable = ""
    for f in walkDirRec(root / ".crisol" / "bin"):
      if f.extractFilename == "test_a".addFileExt(ExeExt): stable = f
    require stable.len > 0
    removeFile(stable)
    createDir(stable)
    writeFile(stable / "keep", "")
    writeFile(root / "tests" / "unit" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
    let r2 = runCli(root, @["--json", "--no-cache"])
    checkpoint("run 2 (--json --no-cache), exit " & $r2.code & ":\n" & r2.output)
    check r2.code == 0
    var doc: JsonNode = nil
    for line in r2.output.splitLines:
      if line.startsWith("{"): doc = parseJson(line)
    require doc != nil
    var found: seq[JsonNode]
    for w in doc["warnings"]:
      if w["context"].getStr == "closure-record": found.add w
    require found.len == 1
    check found[0]["key"].getStr == "tests/unit/test_a.nim"
    # The binary named by its slug directory: the root's own spelling may
    # differ from the resolved state dir's (a /private/var symlink, an 8.3
    # name), so not by its whole path.
    check "could not remove the previous binary " in found[0]["message"].getStr
    check stable.parentDir.extractFilename in found[0]["message"].getStr
    require doc["entrypoints"].len == 1
    check doc["entrypoints"][0]["cacheDecision"].getStr != "closureUnrecorded"

  test "a blocked stable path through the CLI: one warning line on stderr " &
       "and one structured entry, no promotion warning":
    # R19-D1/L1: the retire fails on a directory at the stable path; the
    # unrecorded binary is not promoted, so no second "could not promote"
    # line follows the closure-record one -- in human mode or with --json.
    let root = freshProject("blocked")
    defer: removeDir(root)
    let r1 = runCli(root)
    checkpoint("run 1 (version A), exit " & $r1.code & ":\n" & r1.output)
    require r1.code == 0
    var stable = ""
    for f in walkDirRec(root / ".crisol" / "bin"):
      if f.extractFilename == "test_a".addFileExt(ExeExt): stable = f
    require stable.len > 0
    removeFile(stable)
    createDir(stable)
    writeFile(stable / "keep", "")
    writeFile(root / "tests" / "unit" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
    for extra in [newSeq[string](), @["--json", "--no-cache"]]:
      let r = runCli(root, extra)
      checkpoint("run " & $extra & ", exit " & $r.code & ":\n" & r.output)
      check r.code == 0
      var lines: seq[string]
      for line in r.output.splitLines:
        if "crisol: warning:" in line: lines.add line
      check lines.len == 1
      if lines.len == 1:
        check "could not record its source closure" in lines[0]
      check "could not promote" notin r.output
      if extra.len > 0:
        var doc: JsonNode = nil
        for line in r.output.splitLines:
          if line.startsWith("{"): doc = parseJson(line)
        require doc != nil
        var closureRecord, promote = 0
        for w in doc["warnings"]:
          case w["context"].getStr
          of "closure-record": inc closureRecord
          of "promote-binary": inc promote
          else: discard
        check closureRecord == 1
        check promote == 0

  test "a failed retire, then a run-phase spawn failure: the unrecorded " &
       "closure is still reported":
    # R19-D3: the warning is raised when the retire fails, not when the
    # binary would have been promoted, so a run that never gets there (here
    # a run-phase spawn failure) still reports it on both channels.
    var (root, cfg, ep, graph) = passOnce("retire_spawn")
    defer: removeDir(root)
    writeFile(root / "tests" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
    let plan2 = plan(cfg, @[ep], graph)
    require plan2.entrypoints[0].edecision == edStale
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      try:
        rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                       showProgress = false, retireFn = failingRetireBreakTemp,
                       toolchain = unprobedToolchain())
      finally:
        restoreTempDir())
    checkpoint("run 2 stderr:\n" & err2)
    require rep2.results.len == 1
    check rep2.results[0].outcome == oSpawnError
    checkpoint("run 2 warnings: " & $rep2.warnings)
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "closure-record"
    check rep2.warnings[0].key == string(ep.tp.display())
    var lines: seq[string]
    for line in err2.splitLines:
      if "crisol: warning:" in line: lines.add line
    check lines == @["crisol: warning: " & rep2.warnings[0].message]

  when defined(windows):
    test "an open previous binary (windows): the real retire fails and the " &
         "entry is dropped":
      var (root, cfg, ep, graph) = passOnce("retire_open")
      defer: removeDir(root)
      require entryKey(ep.tp, ep.flags) in graph.entries
      recorderCalls = 0
      # The CRT opens without FILE_SHARE_DELETE, so the file cannot be
      # deleted while this handle is open.
      var held = open(stableBinPath(ep, cfg))
      let rec =
        try:
          retireThenRecordClosure(
            graph, cfg, ep, root / "nimcache",
            buildSourceIndex(cfg), siteResolver(unprobedSite()), realRunIn(root),
            persistingRecorder, retireStableBinary)
        finally:
          held.close()
      checkEntryDropped(cfg, ep, graph, rec)

# ---------------------------------------------------------------------------
# R20-S1: an unrecorded closure across the retries of one run. The warning
# reports the run's outcome for the entrypoint, so an attempt that fails to
# record while another could still record it holds its warning rather than
# raising it: a later attempt that records withdraws it; otherwise it is
# raised once, when the entrypoint's last attempt is decided or when the run
# stops without one.
# ---------------------------------------------------------------------------

var retireCalls = 0

proc failFirstRetire(path: string): tuple[ok: bool, error: string] =
  ## The first retire fails (a binary held open, say); every later one is
  ## the real retire.
  inc retireCalls
  if retireCalls == 1: (ok: false, error: "simulated: the file is in use")
  else: retireStableBinary(path)

var failRetireAt = ""

proc failRetireAtPath(path: string): tuple[ok: bool, error: string] =
  ## Fails the retire of one stable path only; the real retire elsewhere.
  if path == failRetireAt: (ok: false, error: "simulated: the file is in use")
  else: retireStableBinary(path)

proc warningLines(err: string): seq[string] =
  for line in err.splitLines:
    if "crisol: warning:" in line: result.add line

proc retryPlan(tag, versionB: string): tuple[root: string; cfg: Config;
                                             ep: Entrypoint; graph: DepGraph;
                                             plan2: RunPlan] =
  ## Run 1 passes (`passOnce`); the test is then edited to `versionB` and
  ## replanned with one retry.
  var (root, cfg, ep, graph) = passOnce(tag)
  writeFile(root / "tests" / "test_a.nim", versionB)
  cfg.retries = 1
  let plan2 = plan(cfg, @[ep], graph)
  doAssert plan2.entrypoints[0].edecision == edStale
  doAssert plan2.entrypoints[0].retries == 1
  (root, cfg, ep, graph, plan2)

suite "issue #26 — an unrecorded closure across the retries of one run (R20-S1)":
  test "a retry that records the closure: no closure-record warning, and " &
       "its binary is promoted":
    # Version B fails, so attempt 1 is retried. Attempt 1's retire fails,
    # attempt 2's succeeds: the run ends with attempt 2's entry on disk and
    # its binary at the stable path, which no warning may contradict.
    var (root, cfg, ep, graph, plan2) =
      retryPlan("retry_recovers", "echo \"version B\"\nquit(1)\n")
    defer: removeDir(root)
    let key = entryKey(ep.tp, ep.flags)
    retireCalls = 0
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                     showProgress = false, retireFn = failFirstRetire,
                     toolchain = unprobedToolchain()))
    checkpoint("run 2 stderr:\n" & err2)
    checkpoint("run 2 warnings: " & $rep2.warnings)
    check retireCalls == 2
    require rep2.results.len == 1
    check rep2.results[0].attempts == 2
    check rep2.results[0].outcome == oFailed
    check rep2.warnings.len == 0
    check warningLines(err2).len == 0
    # Attempt 2 recorded its closure and its binary was promoted.
    check key in graph.entries
    var graph3 = loadDepGraph(cfg, "", "")
    check key in graph3.entries
    check fileExists(stableBinPath(ep, cfg))
    # ...so the next run compile-skips and runs it: version B.
    let plan3 = plan(cfg, @[ep], graph3)
    checkpoint("run 3 decision: " & $plan3.entrypoints[0].edecision & " (" &
               plan3.entrypoints[0].reason & ")")
    check plan3.entrypoints[0].edecision == edRunFresh
    let r3 = execute(plan3, config = cfg, graph = graph3, nimVersion = "",
                     showProgress = false, toolchain = unprobedToolchain()).results
    require r3.len == 1
    checkpoint("run 3 output: " & r3[0].output)
    check r3[0].compileSkipped
    check "version B" in r3[0].output

  test "every attempt fails to record: exactly one closure-record warning":
    var (root, cfg, ep, graph, plan2) =
      retryPlan("retry_never", "echo \"version B\"\nquit(1)\n")
    defer: removeDir(root)
    let key = entryKey(ep.tp, ep.flags)
    retiredPaths.setLen(0)
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                     showProgress = false, retireFn = failingRetire,
                     toolchain = unprobedToolchain()))
    checkpoint("run 2 stderr:\n" & err2)
    checkpoint("run 2 warnings: " & $rep2.warnings)
    check retiredPaths.len == 2
    require rep2.results.len == 1
    check rep2.results[0].attempts == 2
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "closure-record"
    check rep2.warnings[0].key == string(ep.tp.display())
    check "will not be kept" in rep2.warnings[0].message
    check warningLines(err2) == @["crisol: warning: " & rep2.warnings[0].message]
    check key notin graph.entries
    var graph3 = loadDepGraph(cfg, "", "")
    check key notin graph3.entries
    check plan(cfg, @[ep], graph3).entrypoints[0].edecision != edRunFresh

  test "a held warning whose retry never comes (a run-phase spawn failure): " &
       "reported once":
    # Attempt 1's retire fails while a retry is still possible, so the
    # warning is held; its run cannot spawn, which is never retried, so
    # attempt 1 is the last and the held warning is the run's outcome.
    var (root, cfg, ep, graph, plan2) =
      retryPlan("retry_spawn", "echo \"version B\"\nquit(0)\n")
    defer: removeDir(root)
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      try:
        rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                       showProgress = false, retireFn = failingRetireBreakTemp,
                       toolchain = unprobedToolchain())
      finally:
        restoreTempDir())
    checkpoint("run 2 stderr:\n" & err2)
    checkpoint("run 2 warnings: " & $rep2.warnings)
    require rep2.results.len == 1
    check rep2.results[0].outcome == oSpawnError
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "closure-record"
    check rep2.warnings[0].key == string(ep.tp.display())
    check warningLines(err2) == @["crisol: warning: " & rep2.warnings[0].message]

  test "a held warning whose retry fail-fast never dispatches: still " &
       "reported once":
    # Two entrypoints, two slots, fail-fast. A (one retry) fails to record
    # and holds its warning; its test waits for B to have run, then fails.
    # B (no retry) fails first, so fail-fast stops the run before A's retry
    # is dispatched: A is never finalized, and its held warning is reported
    # as the run ends.
    let root = getTempDir() / ("crisol_issue26_failfast_" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "tests")
    defer: removeDir(root)
    let marker = root / "b_ran"
    writeFile(root / "tests" / "test_a.nim",
              "import std/os\n" &
              "var waited = 0\n" &
              "while not fileExists(r\"" & marker & "\") and waited < 120_000:\n" &
              "  sleep(50)\n  waited += 50\n" &
              "sleep(2000)\n" &
              "quit(1)\n")
    writeFile(root / "tests" / "test_b.nim",
              "writeFile(r\"" & marker & "\", \"\")\nquit(1)\n")
    var cfg = Config(projectRoot: root, stateDir: ".crisol", jobs: 2,
                     timeoutSecs: 180, compileTimeoutSecs: 180,
                     maxOutputBytes: 65_536, memAware: some(false),
                     groups: @[Group(name: "retrying", retries: 1),
                               Group(name: "default")])
    cfg.trackedRoots = initTrackedRoots(root, @[], "")
    let epA = testEp("tests/test_a.nim", group = "retrying", flags = @[])
    let epB = testEp("tests/test_b.nim", group = "default", flags = @[])
    var graph = initDepGraph("")
    let plan1 = plan(cfg, @[epA, epB], graph)
    require plan1.entrypoints[0].retries == 1
    require plan1.entrypoints[1].retries == 0
    failRetireAt = stableBinPath(epA, cfg)
    var rep: ExecuteReport
    let err = captureStderr(proc() =
      rep = execute(plan1, config = cfg, graph = graph, nimVersion = "",
                    failFast = true, showProgress = false,
                    retireFn = failRetireAtPath,
                    toolchain = unprobedToolchain()))
    checkpoint("stderr:\n" & err)
    checkpoint("results: " & $rep.results)
    checkpoint("warnings: " & $rep.warnings)
    # B finished; A's retry was never dispatched.
    require rep.results.len == 1
    check rep.results[0].ep.tp.display() == epB.tp.display()
    check rep.notStarted == 1
    require rep.warnings.len == 1
    check rep.warnings[0].context == "closure-record"
    check rep.warnings[0].key == string(epA.tp.display())
    check warningLines(err) == @["crisol: warning: " & rep.warnings[0].message]

suite "issue #26 — a promotion that fails after the closure recorded":
  test "a promotion failure with a recorded closure: one promote-binary warning":
    # R19-D1: the new entry is on disk but its binary cannot be installed;
    # that is reported once, on stderr and in the structured warnings, and
    # the next run recompiles rather than trusting the stable path.
    var (root, cfg, ep, graph) = passOnce("promote_fail")
    defer: removeDir(root)
    let key = entryKey(ep.tp, ep.flags)
    writeFile(root / "tests" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
    let plan2 = plan(cfg, @[ep], graph)
    require plan2.entrypoints[0].edecision == edStale
    var rep2: ExecuteReport
    let err2 = captureStderr(proc() =
      rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                     showProgress = false, retireFn = blockingRetire,
                     toolchain = unprobedToolchain()))
    checkpoint("run 2 stderr:\n" & err2)
    require rep2.results.len == 1
    check rep2.results[0].outcome == oPassed
    # The closure recorded: the entry for this compile is kept.
    check key in graph.entries
    checkpoint("run 2 warnings: " & $rep2.warnings)
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "promote-binary"
    check rep2.warnings[0].key == string(ep.tp.display())
    check "could not promote its compiled binary" in rep2.warnings[0].message
    # The directory is still there, and the message says so.
    check stableBinPath(ep, cfg) in rep2.warnings[0].message
    check "it will be recompiled next run" in rep2.warnings[0].message
    var lines: seq[string]
    for line in err2.splitLines:
      if "crisol: warning:" in line: lines.add line
    check lines == @["crisol: warning: " & rep2.warnings[0].message]
    # ...and the next run does recompile.
    var graph3 = loadDepGraph(cfg, "", "")
    let plan3 = plan(cfg, @[ep], graph3)
    checkpoint("run 3 decision: " & $plan3.entrypoints[0].edecision & " (" &
               plan3.entrypoints[0].reason & ")")
    check plan3.entrypoints[0].edecision != edRunFresh

suite "issue #26 — reporting a warning on a broken stderr (R21-S1)":
  # R22-D2: POSIX is where these two can fail. Under MSVC a write to the
  # unwritable fd 2 is dropped without an error, so nothing raises either
  # way and both pass vacuously on the Windows leg.
  test "an unwritable stderr: execute() does not raise and still keeps the " &
       "warning":
    # Every attempt fails to record, so the held warning is settled when the
    # last attempt is final -- a stderr write inside the dispatch loop.
    var (root, cfg, ep, graph, plan2) =
      retryPlan("stderr_broken", "echo \"version B\"\nquit(1)\n")
    defer: removeDir(root)
    var rep2: ExecuteReport
    var raised = ""
    withStderrUnwritable(proc() =
      try:
        rep2 = execute(plan2, config = cfg, graph = graph, nimVersion = "",
                       showProgress = false, retireFn = failingRetire,
                       toolchain = unprobedToolchain())
      except CatchableError as e:
        raised = $e.name & ": " & e.msg)
    checkpoint("raised: " & raised)
    check raised == ""
    require rep2.results.len == 1
    check rep2.results[0].attempts == 2
    require rep2.warnings.len == 1
    check rep2.warnings[0].context == "closure-record"
    check rep2.warnings[0].key == string(ep.tp.display())

  test "an exception unwinding execute() past a held warning: an unwritable " &
       "stderr does not replace it":
    # A (one retry) fails to record its closure, so its warning is held; its
    # test then signals B and sleeps. B passes, and the `onResult` for B
    # raises: the exception unwinds `execute` while A still holds its
    # warning, which the `finally` sweep then reports -- to a stderr that
    # cannot be written. The caller must see the callback's exception.
    let root = getTempDir() / ("crisol_issue26_unwind_" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "tests")
    defer: removeDir(root)
    let marker = root / "a_ran"
    writeFile(root / "tests" / "test_a.nim",
              "import std/os\n" &
              "writeFile(r\"" & marker & "\", \"\")\n" &
              "sleep(120_000)\n" &
              "quit(1)\n")
    writeFile(root / "tests" / "test_b.nim",
              "import std/os\n" &
              "var waited = 0\n" &
              "while not fileExists(r\"" & marker & "\") and waited < 120_000:\n" &
              "  sleep(50)\n  waited += 50\n" &
              "quit(0)\n")
    var cfg = Config(projectRoot: root, stateDir: ".crisol", jobs: 2,
                     timeoutSecs: 180, compileTimeoutSecs: 180,
                     maxOutputBytes: 65_536, memAware: some(false),
                     groups: @[Group(name: "retrying", retries: 1),
                               Group(name: "default")])
    cfg.trackedRoots = initTrackedRoots(root, @[], "")
    let epA = testEp("tests/test_a.nim", group = "retrying", flags = @[])
    let epB = testEp("tests/test_b.nim", group = "default", flags = @[])
    var graph = initDepGraph("")
    let plan1 = plan(cfg, @[epA, epB], graph)
    require plan1.entrypoints[0].retries == 1
    failRetireAt = stableBinPath(epA, cfg)
    var sawB = false
    var raised = ""
    withStderrUnwritable(proc() =
      try:
        discard execute(plan1, config = cfg, graph = graph, nimVersion = "",
                        showProgress = false, retireFn = failRetireAtPath,
                        toolchain = unprobedToolchain(),
                        onResult = proc(r: EntrypointResult) =
                          if r.ep.tp.display() == epB.tp.display():
                            sawB = true
                            raise newException(ValueError, "callback for B"))
      except CatchableError as e:
        raised = $e.name & ": " & e.msg)
    checkpoint("raised: " & raised)
    check sawB
    check raised == "ValueError: callback for B"

# ---------------------------------------------------------------------------
# R22-D1: the compile child is reaped before the closure is recorded, so from
# that point the slot holds no live child. A seam that raises between the
# reap and the run spawn must reach the caller as itself -- not as the
# teardown's AssertionDefect for a consumed ChildId.
# ---------------------------------------------------------------------------

proc raisingRetire(path: string): tuple[ok: bool, error: string] =
  raise newException(ValueError, "simulated: retire raised")

proc raisingRecorder(graph: var DepGraph; config: Config; ep: Entrypoint;
                     nimcacheDir, binaryName: string;
                     protocolMajor: int; index: SourceIndex;
                     driver: DriverResolver;
                     ccRun: RunProc): tuple[ok: bool, error: string] =
  raise newException(ValueError, "simulated: recordClosure raised")

proc executeRaisedAs(tag: string; retire: RetireBinaryProc;
                     recorder: RecordClosureProc): string =
  ## Run 2 of `passOnce`'s project, edited so it recompiles, with the given
  ## seams; returns "<name>: <msg>" of whatever `execute` raised ("" if it
  ## returned). A Defect is caught too, so a masked failure reads as RED
  ## instead of aborting the file.
  var (root, cfg, ep, graph) = passOnce(tag)
  defer: removeDir(root)
  writeFile(root / "tests" / "test_a.nim", "echo \"version B\"\nquit(0)\n")
  let plan2 = plan(cfg, @[ep], graph)
  doAssert plan2.entrypoints[0].edecision == edStale
  try:
    discard execute(plan2, config = cfg, graph = graph, nimVersion = "",
                    showProgress = false, retireFn = retire,
                    recordClosureFn = recorder,
                    toolchain = unprobedToolchain())
  except CatchableError as e:
    result = $e.name & ": " & e.msg
  except Defect as e:
    result = $e.name & ": " & e.msg

suite "issue #26 — a seam raising after the compile child is reaped (R22-D1)":
  test "a raising retire: execute() surfaces the seam's exception, not " &
       "an AssertionDefect":
    let raised = executeRaisedAs("raise_retire", raisingRetire, recordClosure)
    checkpoint("raised: " & raised)
    check raised == "ValueError: simulated: retire raised"

  test "a raising closure recorder: execute() surfaces the seam's " &
       "exception, not an AssertionDefect":
    let raised = executeRaisedAs("raise_record", retireStableBinary,
                                 raisingRecorder)
    checkpoint("raised: " & raised)
    check raised == "ValueError: simulated: recordClosure raised"

when isMainModule:
  echo "test_issue26_promotion_interrupt done"
