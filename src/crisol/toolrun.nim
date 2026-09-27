## toolrun.nim -- the process-execution seam for short-lived HOST TOOL probes.
##
## Import this module if you spawn a SHORT-LIVED HOST TOOL and need its
## output: a compiler driver's version banner, `ldd`, the MSVC
## `vccexe ... /link /VERBOSE:LIB` probe, a replayed `cc -M` /
## `/sourceDependencies-` invocation, the Nim compiler's own `--version`.
## Import nothing here if you spawn a compile or run CHILD -- those belong to
## RFC-0007's Supervisor (`crisol/process`), and the
## `# process-contract-exempt` marker below draws exactly that line.
##
## Every probe takes a `RunProc` rather than calling a process primitive
## directly, so each is testable without a subprocess. The seam never
## raises; its result says whether the command ran at all.
##
## A std-only leaf: `crisol/toolexec` (the only crisol import) imports no
## crisol module, so `crisol/ccidentity`, `crisol/ccprobe` and
## `crisol/closure` can all import this module with no risk of a cycle.
##
## Public API
## ----------
##   RunProc*
##     The seam: `proc(cmd, args): RunResult`.
##   RunEnd*, RunResult*, ran*, notRun*, ok*, describe*
##     Re-exported from `crisol/toolexec`, which owns the one result type
##     every tool run in `src/` returns: a case object on `RunEnd` whose only
##     `reExited` branch carries an exit code and output, so a capture from a
##     run that did not finish cannot be read by mistake.
##   ToolProbeTimeoutMs*
##     The deadline every real run through this module is bounded by.
##   realRun*, realRunIn*(workingDir)
##     Separate streams: `output` is stdout, `errOutput` is stderr.
##   realRunMerged*, realRunMergedIn*(workingDir)
##     Merged streams (`poStdErrToStdOut`): `output` is both, interleaved as
##     written; `errOutput` is "". For version banners, which a compiler may
##     print to either stream.
##   realRunWithStdinIn*(workingDir, input)
##     Separate streams, with `input` written to the command's stdin.
##   RunWatch*, watch*
##     Whether any run through a set of runners ended `reInterrupted`: a
##     memoised probe that runs several tools keeps no answer an interrupt
##     decided (R14-D3).
##
## The runners write nothing to the terminal. A caller that has something
## to say about a run that did not finish says it with `describe`.
##
## Caching
## -------
## None. Each memoised probe (`ccidentity.cachedToolchainProbe`,
## `nimprobe.cachedNimFingerprint`, ...) lives in the module that owns the
## value being cached.

import std/osproc  # process-contract-exempt: this module IS the process-execution seam for short-lived TOOL invocations (cc/ldd/nim/cc -M probes), not the compile/run children RFC-0007's Supervisor governs (RFC-0007 §Scope)
import crisol/toolexec  # runTool and the RunResult it returns
export RunEnd, RunResult, ran, notRun, ok, describe

const
  ToolProbeTimeoutMs* = 10_000
    ## Bound on ONE run through this module, drain and exit wait together.
    ## Every caller runs in the host process during plan-building, outside
    ## RFC-0007's Supervisor, so nothing else bounds it.
    ##
    ## Measured: the slowest single spawn in `cachedToolchainProbe` is the
    ## `nim c --compileOnly` driver discovery, about 0.7 s on Windows/MSVC
    ## (the whole fingerprint is about 1.5 s there, about 0.2 s on Linux).
    ## 10 s is over 10x the slowest spawn, so a slow-but-working probe is
    ## never at risk, while a wedged one is bounded.

# ---------------------------------------------------------------------------
# Seam type
# ---------------------------------------------------------------------------

type
  RunProc* = proc(cmd: string, args: openArray[string]): RunResult
    ## Run `cmd` with `args`. Never raises.
    ##
    ## CONTRACT: `reNotStarted` only when the command did not start. Every
    ## other ending means a process was spawned -- a present tool, whatever
    ## it then did. `ccidentity.ccProbeWith` relies on this to tell a present
    ## driver that failed (or wedged) from an absent one, so a fake must not
    ## report `reExited` for a command that never ran (a shell's `command not
    ## found`, say). Pinned against the real runners by
    ## `tests/integration/test_probe_presence_contract.nim`.

type
  RunWatch* = ref object
    ## What the runners `watch` wrapped have seen. Shared by every runner one
    ## probe uses, so the probe's answer can say whether an interrupt, not
    ## the tools, decided any part of it.
    interrupted*: bool
      ## Some run through a watched runner ended `reInterrupted`.

proc watch*(w: RunWatch; run: RunProc): RunProc =
  ## `run`, recording in `w` whether a run ended `reInterrupted`. The result
  ## is passed through unchanged.
  proc watched(cmd: string, args: openArray[string]): RunResult =
    result = run(cmd, args)
    if result.ending == reInterrupted: w.interrupted = true
  watched

# ---------------------------------------------------------------------------
# Real runners
# ---------------------------------------------------------------------------

proc runViaOsproc(cmd: string; args: openArray[string]; workingDir: string;
                  merged: bool; input: string): RunResult =
  ## Shared body of the real runners: an explicit argv (never a shell;
  ## `poUsePath` resolves a bare name like `cc` via PATH), bounded by
  ## `ToolProbeTimeoutMs`. `toolexec.runTool`'s result, untranslated.
  var opts = {poUsePath}
  if merged: opts.incl poStdErrToStdOut
  runTool(cmd, args, workingDir, opts, input, ToolProbeTimeoutMs,
          MaxToolOutputBytes)

proc realRun*(cmd: string, args: openArray[string]): RunResult =
  ## Separate streams, the caller's cwd. The runner for probes whose stdout is
  ## PARSED (a `cc -M` reply with a warning spliced into it is corrupt).
  runViaOsproc(cmd, args, "", false, "")

proc realRunMerged*(cmd: string, args: openArray[string]): RunResult =
  ## Merged streams, the caller's cwd. The runner for VERSION-BANNER probes:
  ## `cl` and `vccexe` print their banner to stderr (measured: cl with no
  ## arguments writes `usage: cl [ option... ]` to stdout and the banner to
  ## stderr), gcc/clang to stdout.
  runViaOsproc(cmd, args, "", true, "")

proc realRunIn*(workingDir: string): RunProc =
  ## `realRun` with `workingDir` as the SUBPROCESS's cwd, never the calling
  ## process's own. `closure.extractCompileInputs` binds it to
  ## `config.projectRoot` so a `cc -M` replay resolves a relative header from
  ## the same directory the real compile ran `cc` from.
  proc run(cmd: string, args: openArray[string]): RunResult =
    runViaOsproc(cmd, args, workingDir, false, "")
  run

proc realRunMergedIn*(workingDir: string): RunProc =
  ## `realRunMerged` with `workingDir` as the subprocess's cwd.
  ## `ccidentity`'s MSVC runtime probe builds in its own scratch directory.
  proc run(cmd: string, args: openArray[string]): RunResult =
    runViaOsproc(cmd, args, workingDir, true, "")
  run

proc realRunWithStdinIn*(workingDir, input: string): RunProc =
  ## `realRunIn(workingDir)` with `input` written to the command's stdin,
  ## then closed. `input` is at most `toolexec.MaxToolInputBytes`.
  ## `ccidentity`'s compiler discovery compiles a module read from stdin.
  proc run(cmd: string, args: openArray[string]): RunResult =
    runViaOsproc(cmd, args, workingDir, false, input)
  run
