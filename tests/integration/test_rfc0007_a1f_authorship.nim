## test_rfc0007_a1f_authorship.nim — rfc-0007 A1f: authorship breadth, pinned
## with real fixtures. Every Cause-classification case classifyCause's table
## (A1a) already covers abstractly gets a real child process here.
##
## Two suites:
##   1. execute() (API level) — crash_segv, self_sigkill, term_cooperative
##      (THE soundness case), fsize requested+achieved, and the two
##      requested-vs-unrequested "external" pairs (SIGXCPU/SIGXFSZ sent by
##      a source the runner never authored).
##   2. the CLI (`crisol run --json`) — crash_segv, self_sigkill,
##      term_cooperative, same wire shape test_rfc0007_a1b_kill_path.nim
##      already established for the runner-authored-kill cases.
##
## SIGXCPU requested+achieved (needs a real CPU burn) and compile-interrupt
## (needs a real multi-second compile) are timing-sensitive and live in
## tests/timing/test_rfc0007_a1f_limit_timing.nim instead — see that file's
## header. fsize requested+achieved is NOT timing-sensitive (a single write()
## call past RLIMIT_FSIZE trips SIGXFSZ synchronously, verified empirically)
## so it stays here.
##
## No CLI coverage for the two rlimit-requested cases: crisol's CLI exposes
## `--rlimit-nofile` only (A2a-iii wires --rlimit-cpu/--rlimit-fsize); these
## two are execute()-only until that plumbing lands.

import std/[json, options, os, strutils, times, unittest]
import std/posix
import std/posix as posix_mod
import crisol/types
import crisol/runner
import crisol/depgraph
import crisol/sandbox
import crisol/process/types as ptypes
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc mkEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "test", flags: @[])

proc expectCoreDumped(): bool =
  ## rfc-0007 A1f: "assert the observation, don't fabricate" — coreDumped
  ## is NOT unconditionally false under RLIMIT_CORE=0. `man core(5)`: when
  ## `/proc/sys/kernel/core_pattern` begins with `|` (a pipe to a handler —
  ## e.g. systemd-coredump, the default on most modern systemd-based
  ## distros, including common CI images), the kernel invokes the handler
  ## and sets WCOREDUMP REGARDLESS of the dumping process's RLIMIT_CORE;
  ## the rlimit only gates the plain-file-pattern path. Verified empirically
  ## in this dev container: RLIMIT_CORE=0 is confirmed applied
  ## (LimitsAchieved[lkCore] == lsApplied / getrlimit readback) and no core FILE
  ## lands in the scratch dir, yet WCOREDUMP still reads true because
  ## core_pattern here is `|/lib/systemd/systemd-coredump ...`. Read the
  ## live pattern rather than hardcode either value.
  if fileExists("/proc/sys/kernel/core_pattern"):
    let pat = readFile("/proc/sys/kernel/core_pattern").strip()
    pat.len > 0 and pat[0] == '|'
  else:
    false  # no core_pattern file (non-Linux/unavailable): fall back to the
           # RLIMIT_CORE=0 expectation

proc pollForFile(path: string; timeoutMs: int): bool =
  let step = 50
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(path): return true
    os.sleep(step)
    elapsed += step
  false

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Same idiom as test_rfc0007_a1b_kill_path.nim's captureStdout — not
  ## imported, so this file has no test-to-test dependency.
  let outPath = getTempDir() / ("crisol_a1f_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc firstEntrypoint(jsonText: string): JsonNode =
  let doc = parseJson(jsonText)
  check doc["entrypoints"].len == 1
  doc["entrypoints"][0]

# ---------------------------------------------------------------------------
# Suite 1 — execute() (API level)
# ---------------------------------------------------------------------------

suite "rfc-0007 A1f — authorship breadth via execute()":

  test "crash_segv: oCrashed / cbProcess / SIGSEGV / coreDumped matches the observed core_pattern":
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "crash_segv.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 10)
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    # Default cache/spec: hlIsolated, RLIMIT_CORE=0 — the "default path" the
    # RFC bullet's coreDumped claim is about; the expected VALUE is verified
    # against the live kernel core_pattern rather than assumed — see
    # expectCoreDumped()'s doc.
    let results = execute(p, config = cfg, graph = g)

    check results.len == 1
    check results[0].outcome == oCrashed
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.cause.by == ptypes.cbProcess
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGSEGV)
    check results[0].run.res.exit.coreDumped == expectCoreDumped()

  test "self_sigkill: oCrashed / cbExternal (the runner never sent this SIGKILL)":
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "self_sigkill.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 10)
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)

    check results.len == 1
    check results[0].outcome == oCrashed
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.cause.by == ptypes.cbExternal
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGKILL)

  test "term_cooperative: THE soundness case — traps SIGTERM, exits 0, still reports killed":
    ## A test that fakes a clean pass inside the runner's kill grace window
    ## must never read as a pass: cbRunner/krTimeout/escalated:false wins
    ## over the observed exit.kind:exited/code:0 (§2's "authorship has ONE
    ## owner" rule — classifyCause never consults the exit once a stop act
    ## is recorded).
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "term_cooperative.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 1)  # short: force the kill
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g)

    check results.len == 1
    check results[0].outcome == oKilled       # NEVER oPassed
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.cause.by == ptypes.cbRunner
    check results[0].run.res.cause.reason == ptypes.krTimeout
    check results[0].run.res.cause.escalated == false
    check results[0].run.res.exit.kind == ptypes.ekExited
    check results[0].run.res.exit.code == 0

  test "fsize requested+achieved: small RLIMIT_FSIZE ⇒ cbLimit(lkFileSize), SIGXFSZ":
    ## Honest observation (verified empirically, not assumed): a single
    ## write() call past a small RLIMIT_FSIZE trips SIGXFSZ synchronously —
    ## not the EFBIG-return/exit-nonzero path rlimit_fsize.nim's own doc
    ## comment lists as the OTHER possibility.
    let fdir = fixtureDir()
    let eps  = @[mkEp(fdir / "rlimit_fsize.nim")]
    let cfg  = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 10)
    let p    = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let spec = resolveSandbox(level = hlIsolated,
      rlimits = RlimitOverrides(limitFsize: some(4096'i64)))
    let results = execute(p, config = cfg, graph = g, cache = cacheDisabled(spec))

    check results.len == 1
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGXFSZ)
    check results[0].run.res.cause.by == ptypes.cbLimit
    check results[0].run.res.cause.limit == ptypes.lkFileSize

  test "SIGXCPU without the limit requested: an external SIGXCPU ⇒ cbExternal, never cbLimit":
    ## hlIsolated's default sandbox never requests RLIMIT_CPU (unset by
    ## default per RFC-0004 §F2) — a real SIGXCPU sent by a source OUTSIDE
    ## the runner (this test's own watcher fork, standing in for an
    ## operator/another tool) must classify cbExternal, the documented
    ## "signals we did not send" heuristic (§2).
    let fdir     = fixtureDir()
    let tmpDir   = getTempDir() / ("crisol_a1f_cpu_ext_" & $int(getpid()))
    let pidFile  = tmpDir / "hang_pid.txt"
    createDir(tmpDir)
    defer: (try: removeDir(tmpDir) except: discard)
    if fileExists(pidFile): removeFile(pidFile)

    putEnv("HANG_PID_FILE", pidFile)
    let spec = resolveSandbox(passthroughs = @["HANG_PID_FILE"])  # hlIsolated; cpu unrequested

    let watcherPid = fork()
    check watcherPid >= 0
    if watcherPid == 0:
      # Watcher: wait for the grandchild's PID, then send SIGXCPU — a signal
      # the runner never authored — and exit.
      discard pollForFile(pidFile, 30_000)
      if fileExists(pidFile):
        let targetPid = Pid(parseInt(readFile(pidFile).strip()))
        discard kill(targetPid, SIGXCPU)
      exitnow(0)

    let eps = @[mkEp(fdir / "hang_with_pid.nim")]
    let cfg = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 20)
    let p   = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g, cache = cacheDisabled(spec))

    var ws: cint = 0
    discard waitpid(watcherPid, ws, 0)

    check results.len == 1
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGXCPU)
    check results[0].run.res.cause.by == ptypes.cbExternal

  test "SIGXFSZ without the limit requested: hlNone (no sandbox at all) ⇒ cbExternal, never cbLimit":
    ## hlIsolated always REQUESTS a default RLIMIT_FSIZE (256 MiB, RFC-0004
    ## §F2) — to get a genuinely unrequested lkFileSize this case needs
    ## hlNone (fully unsandboxed) rather than hlIsolated.
    let fdir     = fixtureDir()
    let tmpDir   = getTempDir() / ("crisol_a1f_fsize_ext_" & $int(getpid()))
    let pidFile  = tmpDir / "hang_pid.txt"
    createDir(tmpDir)
    defer: (try: removeDir(tmpDir) except: discard)
    if fileExists(pidFile): removeFile(pidFile)

    putEnv("HANG_PID_FILE", pidFile)
    let spec = resolveSandbox(level = hlNone)  # no rlimits requested at all
    doAssert spec.limits == ptypes.Limits()

    let watcherPid = fork()
    check watcherPid >= 0
    if watcherPid == 0:
      discard pollForFile(pidFile, 30_000)
      if fileExists(pidFile):
        let targetPid = Pid(parseInt(readFile(pidFile).strip()))
        discard kill(targetPid, SIGXFSZ)
      exitnow(0)

    let eps = @[mkEp(fdir / "hang_with_pid.nim")]
    let cfg = Config(jobs: 1, compileTimeoutSecs: 30, timeoutSecs: 20)
    let p   = plan(cfg, eps, emptyDepGraph())
    var g = emptyDepGraph()
    let results = execute(p, config = cfg, graph = g, cache = cacheDisabled(spec))

    var ws: cint = 0
    discard waitpid(watcherPid, ws, 0)

    check results.len == 1
    check results[0].run.kind == ptypes.pkRan
    check results[0].run.res.exit.kind == ptypes.ekSignaled
    check results[0].run.res.exit.sig == int(SIGXFSZ)
    check results[0].run.res.cause.by == ptypes.cbExternal

# ---------------------------------------------------------------------------
# Suite 2 — the CLI (`crisol run --json`)
# ---------------------------------------------------------------------------

suite "rfc-0007 A1f — authorship breadth via the CLI (crisol run --json)":

  test "crash_segv: outcome crashed, run.cause.by process, run.exit SIGSEGV, coreDumped matches core_pattern":
    let fd = fixtureDir()
    let (_, output) = captureStdout(@["run", fd / "crash_segv.nim",
                                      "--timeout", "10", "--jobs", "1", "--json",
                                      "--no-cache"])
    let ep = firstEntrypoint(output)
    check ep["outcome"].getStr == "crashed"
    check ep["run"]["cause"]["by"].getStr == "process"
    check ep["run"]["exit"]["kind"].getStr == "signaled"
    check ep["run"]["exit"]["sig"].getInt == int(SIGSEGV)
    check ep["run"]["exit"]["coreDumped"].getBool == expectCoreDumped()

  test "self_sigkill: outcome crashed, run.cause.by external, run.exit SIGKILL":
    let fd = fixtureDir()
    let (_, output) = captureStdout(@["run", fd / "self_sigkill.nim",
                                      "--timeout", "10", "--jobs", "1", "--json",
                                      "--no-cache"])
    let ep = firstEntrypoint(output)
    check ep["outcome"].getStr == "crashed"
    check ep["run"]["cause"]["by"].getStr == "external"
    check ep["run"]["exit"]["kind"].getStr == "signaled"
    check ep["run"]["exit"]["sig"].getInt == int(SIGKILL)

  test "term_cooperative: outcome killed (never passed), run.cause runner/timeout, exit exited/0":
    let fd = fixtureDir()
    let (code, output) = captureStdout(@["run", fd / "term_cooperative.nim",
                                         "--timeout", "1", "--jobs", "1", "--json",
                                         "--no-cache"])
    let ep = firstEntrypoint(output)
    check ep["outcome"].getStr == "killed"
    check ep["run"]["cause"]["by"].getStr == "runner"
    check ep["run"]["cause"]["reason"].getStr == "timeout"
    check ep["run"]["cause"]["escalated"].getBool == false
    check ep["run"]["exit"]["kind"].getStr == "exited"
    check ep["run"]["exit"]["code"].getInt == 0
    # A killed entrypoint fails the run — non-zero exit code (exit-code
    # derivation consults outcome, so a faked "pass" cannot leak through here).
    check code != 0
