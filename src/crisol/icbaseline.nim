## icbaseline.nim — RFC-0006/RFC-0005 M-IC-baseline: probe Nim's `--incremental`
## (IC) repeat-compile baseline.
##
## Nim's `--incremental` flag persists a rod-file module DB across compiles of
## the SAME main module, aimed at speeding up edit/recompile loops. It does
## NOT share compiled state across DISTINCT main modules, so it cannot solve
## crisol's cross-entrypoint compile-cost problem on its own — a favorable
## result here does not close that RFC. IC is also perennially experimental
## under `--mm:orc`, so its viability must be EMPIRICALLY measured, never
## assumed. This module is a standalone, throwaway-friendly PROBE: it answers
## "does `--incremental` work with `--mm:orc` in this toolchain, and how much
## does it speed a repeat compile of the same entrypoint?" and records the
## real numbers. It is NOT wired into the production compile path (that stays
## the monolithic `nim c` in runner.nim, untouched) and it does NO caching —
## that would be Stage R, a separate, conditional slice.
##
## ## The IcRunProc seam (mirrors ccprobe.RunProc / compiledriver.CompileDriver)
##
## The actual `nim` invocation is an injectable closure so unit tests never
## spawn a real compiler: they inject a fake `IcRunProc` that returns
## canned `(exitCode, output)` pairs and assert on `probeIncremental`'s pure
## classification logic. `realIcRun` is the real argv-spawn default, used
## only by the integration test that exercises the actual toolchain.
##
## ## The IcTimeProc seam
##
## Wall-clock timing uses `std/monotimes.MonoTime` — the same clock
## `compiledriver.nim` uses — via an injectable `IcTimeProc` so unit tests can
## assert exact, deterministic `firstUs`/`secondUs`/`speedupPct` values
## without depending on how fast a fake closure happens to return. Tests
## build synthetic `MonoTime` values via `MonoTime.low + initDuration(...)`
## (the only publicly constructible `MonoTime`s — its `ticks` field is
## private to `std/monotimes`), not by sleeping real wall-clock time.
##
## ## CCACHE_DISABLE
##
## Mirrors `measureworker.forceMeasurementCcEnv`: a single `putEnv` in the
## calling process, inherited by every child `startProcess` this probe spawns
## (no explicit env table threaded through), so timings reflect the raw
## toolchain rather than a ccache hit.
##
## ## Classification
##
## `supported` = false only when the FIRST run's output looks like an
## option-parse rejection of `--incremental` itself (nonzero exit AND the
## output mentions both "incremental" and an invalid/unknown-option phrase).
## Otherwise the option was accepted by the parser: `supported = true`.
## `orcCompatible` = true only when BOTH compiles (same nimcache, so the
## second is the "repeat" the rod-file DB should accelerate) exit 0; a
## nonzero exit from either — having ruled out the option-rejection case —
## means the option was accepted but the build itself failed under
## `--mm:orc --incremental`, captured in `errorMsg`.

import std/[monotimes, os, osproc, streams, strutils, times]

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  IcRunProc* = proc(args: seq[string]): tuple[exitCode: int, output: string] {.closure.}
    ## Runs one compiler invocation given a full argv (args[0] is the
    ## executable, e.g. "nim"). Real impl (`realIcRun`): argv-array spawn, no
    ## shell. Never raises — a spawn failure surfaces as a nonzero exitCode
    ## with a descriptive message in `output`.

  IcTimeProc* = proc(): MonoTime {.closure.}
    ## Monotonic-clock read, injectable so unit tests can supply deterministic
    ## synthetic timestamps. Real impl: `realIcTimeNow` (= `getMonoTime`).

  IcProbeResult* = object
    supported*:     bool     ## `--incremental` was accepted by the option parser.
    orcCompatible*: bool     ## both compiles (same nimcache) exited 0.
    firstUs*:       int64    ## wall time of the cold compile, microseconds.
    secondUs*:      int64    ## wall time of the repeat compile, microseconds.
    speedupPct*:    float    ## (firstUs-secondUs)/firstUs*100; 0.0 if not applicable.
    errorMsg*:      string   ## captured failure output; empty on success.

# ---------------------------------------------------------------------------
# Real seam implementations
# ---------------------------------------------------------------------------

proc realIcRun*(args: seq[string]): tuple[exitCode: int, output: string] =
  ## Spawns `args` as an argv array (args[0] = executable, no shell) and
  ## captures combined stdout+stderr and the exit code. Never raises.
  try:
    let p = startProcess(args[0], args = args[1..^1],
                         options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (exitCode: exitCode, output: output)
  except CatchableError as e:
    result = (exitCode: -1, output: "icbaseline: spawn failed: " & e.msg)

proc realIcTimeNow*(): MonoTime =
  getMonoTime()

proc forceIcCcEnv*() =
  ## Force `CCACHE_DISABLE=1` in THIS process's environment before either
  ## compile child is spawned — mirrors `measureworker.forceMeasurementCcEnv`.
  ## `startProcess` (both `realIcRun` here and any real seam elsewhere)
  ## inherits the calling process's environment when no explicit `env` table
  ## is passed, so this single `putEnv` reaches every `nim`/`cc` child this
  ## probe spawns for the rest of the process's lifetime.
  putEnv("CCACHE_DISABLE", "1")

# ---------------------------------------------------------------------------
# Pure classification helpers
# ---------------------------------------------------------------------------

proc looksLikeOptionRejection(output: string): bool =
  ## True iff `output` reads like the option PARSER rejected `--incremental`
  ## itself (as opposed to accepting it and failing to build).
  let lower = output.toLowerAscii()
  "incremental" in lower and
    ("invalid command line option" in lower or
     "unknown option" in lower or
     "unrecognized option" in lower or
     "bad command line option" in lower)

proc computeSpeedupPct(firstUs, secondUs: int64): float =
  if firstUs <= 0:
    0.0
  else:
    (float(firstUs - secondUs) / float(firstUs)) * 100.0

# ---------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------

proc probeIncremental*(run: IcRunProc; entrypoint, nimcacheDir, outputBinPath: string;
                       timeNow: IcTimeProc = realIcTimeNow): IcProbeResult =
  ## Compiles `entrypoint` TWICE with `--mm:orc --incremental`, both times
  ## into the SAME `nimcacheDir` (so the rod-file DB persists between them —
  ## the whole point of measuring repeat-compile speedup), and classifies the
  ## outcome. See module doc §Classification.
  forceIcCcEnv()
  let args = @["nim", "c", "--mm:orc", "--incremental:on", "--hints:off",
               "--nimcache:" & nimcacheDir, "-o:" & outputBinPath, entrypoint]

  let t0 = timeNow()
  let first = run(args)
  let t1 = timeNow()
  let firstUs = (t1 - t0).inMicroseconds

  if looksLikeOptionRejection(first.output):
    return IcProbeResult(supported: false, orcCompatible: false,
                         firstUs: 0, secondUs: 0, speedupPct: 0.0,
                         errorMsg: first.output)

  if first.exitCode != 0:
    return IcProbeResult(supported: true, orcCompatible: false,
                         firstUs: firstUs, secondUs: 0, speedupPct: 0.0,
                         errorMsg: first.output)

  let t2 = timeNow()
  let second = run(args)
  let t3 = timeNow()
  let secondUs = (t3 - t2).inMicroseconds

  if second.exitCode != 0:
    return IcProbeResult(supported: true, orcCompatible: false,
                         firstUs: firstUs, secondUs: secondUs, speedupPct: 0.0,
                         errorMsg: second.output)

  IcProbeResult(supported: true, orcCompatible: true,
               firstUs: firstUs, secondUs: secondUs,
               speedupPct: computeSpeedupPct(firstUs, secondUs),
               errorMsg: "")
