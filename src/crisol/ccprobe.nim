## ccprobe.nim — C compiler + libc version probe (RFC-0004, A2-pre).
##
## Effectful I/O, Linux-oriented.  All command execution goes through an
## injectable `run` proc seam so unit tests can supply synthetic output
## without spawning any real process.
##
## Seam contract
## -------------
## The `run` proc has signature:
##   proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
## where:
##   - `output` is the combined stdout of the command (stderr is not captured).
##   - `ok` is true when the command exited with code 0.
##   - On failure (command not found, non-zero exit, etc.): `ok = false`,
##     `output` may be empty or partial — callers must handle both gracefully.
## The seam never raises; all errors are surfaced via the `ok` flag.
##
## Public API
## ----------
##   ccVersion*(run = realRun): string
##     Returns a stable, normalized fingerprint combining:
##       - first line of `cc --version` output (C compiler identity)
##       - first line of `ldd --version` output (libc identity)
##     Joined with "|" as a fixed separator.  Each half is trimmed.
##     If a probe command fails or produces empty output the corresponding
##     half is replaced by a documented sentinel so the fingerprint is always
##     a stable non-empty string.  Never raises.
##
##   realRun*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]
##     Default seam: executes the command via osproc and returns its output.
##     Never raises.
##
## Sentinel values (exported for consumer awareness):
##   CcSentinel*  = "<cc-unavailable>"
##   LddSentinel* = "<ldd-unavailable>"
##
## Caching
## -------
## The pure derivation (`ccVersion`) is seam-injectable and can be called freely
## in tests.  The memoised accessor (`cachedCcVersion`) is a thin wrapper that
## calls the real probe exactly once at startup; tests bypass it entirely.

import std/[osproc, streams, strutils]

# ---------------------------------------------------------------------------
# Sentinels
# ---------------------------------------------------------------------------

const
  CcSentinel*  = "<cc-unavailable>"
  LddSentinel* = "<ldd-unavailable>"

# ---------------------------------------------------------------------------
# Seam type
# ---------------------------------------------------------------------------

type
  RunProc* = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool]

# ---------------------------------------------------------------------------
# realRun — default seam (wraps osproc)
# ---------------------------------------------------------------------------

proc realRun*(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
  ## Execute `cmd` with `args` using an explicit argv array — no shell interpretation.
  ## Uses startProcess with poUsePath so bare command names (e.g. "cc", "ldd") resolve
  ## via PATH.  poEvalCommand is intentionally NOT used (that is the shell path).
  ## Captures stdout; stderr is not captured (version strings from cc/ldd go to stdout).
  ## Never raises; failure (command not found, non-zero exit, OSError) surfaces as ok=false.
  try:
    var argSeq = newSeq[string](args.len)
    for i, a in args: argSeq[i] = a
    let p = startProcess(cmd, args = argSeq, options = {poUsePath})
    defer: p.close()   # R2-b: close on every exit path (readAll/waitForExit may raise)
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (output: output, ok: exitCode == 0)
  except CatchableError:
    result = (output: "", ok: false)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc firstLine(s: string): string =
  ## Return the first non-empty, trimmed line of `s`; empty string if none.
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0:
      return t
  ""

# ---------------------------------------------------------------------------
# ccVersion — pure derivation (injectable)
# ---------------------------------------------------------------------------

proc ccVersion*(run: RunProc = realRun): string =
  ## Derive a stable fingerprint from cc and ldd version probes.
  ## Both probes go through `run`; default is the real process runner.
  ## Never raises.

  # --- cc probe ---
  let (ccOut, ccOk) = run("cc", ["--version"])
  let ccLine = if ccOk: firstLine(ccOut) else: ""
  let ccPart = if ccLine.len > 0: ccLine else: CcSentinel

  # --- ldd probe ---
  let (lddOut, lddOk) = run("ldd", ["--version"])
  let lddLine = if lddOk: firstLine(lddOut) else: ""
  let lddPart = if lddLine.len > 0: lddLine else: LddSentinel

  ccPart & "|" & lddPart

# ---------------------------------------------------------------------------
# cachedCcVersion — memoised startup accessor (uses the real runner)
# ---------------------------------------------------------------------------

var ccVersionCache: string = ""

proc cachedCcVersion*(): string =
  ## Probe cc/ldd exactly once; return the cached value on subsequent calls.
  ## Always uses the real runner — unit tests should call ccVersion directly.
  if ccVersionCache.len == 0:
    ccVersionCache = ccVersion()
  ccVersionCache
