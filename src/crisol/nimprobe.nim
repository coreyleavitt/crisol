## nimprobe.nim — Nim compiler version + binary-content probe (soundness fix).
##
## Mirrors `ccprobe.nim`'s shape exactly: effectful I/O behind an injectable
## seam, never raises, sentinel fallback on failure, memoised per-process
## accessor.
##
## ## Why this exists
##
## `api.crisolNimVersion` (= `system.NimVersion`, e.g. "2.2.10") is crisol's
## OWN compile-time Nim version string — not necessarily a fully sound
## discriminator for the Nim that actually compiles target entrypoints.  Two
## builds of Nim can share the same version STRING (a stock 2.2.10 and a
## locally-patched 2.2.10) while producing different codegen; a cache/
## freshness check keyed only on that string cannot tell them apart, which
## is a soundness gap symmetric to the one `ccprobe.nim` already closes for
## the C compiler (a RUNTIME probe, not a compile-time constant).
##
## `nimFingerprint` closes the same gap for Nim by combining:
##   (a) the FULL normalized `nim --version` output (every line — this
##       captures the version, the "Compiled at" build date, and the
##       "active boot switches" line, not just the version number), and
##   (b) a content hash of the ACTUAL nim compiler binary that crisol's own
##       compile invocations resolve via PATH (see `compiledriver.
##       realCompileOnly` / `runner.nim`'s monolithic compile path — both
##       shell out to the bare command name "nim", resolved via `poUsePath`).
##       A stock→patched swap at the same version string changes this hash
##       even when (a) is byte-identical.
##
## ## Seam contract
##
## `run` — reuses `ccprobe.RunProc`/`ccprobe.realRun` verbatim (same idiom,
## same contract: `ok=false` on any failure, never raises).
##
## `hashBin` has signature:
##   proc(path: string): string
## Given a filesystem path, returns a stable non-empty hash string, or a
## documented sentinel if the path is empty / unreadable.  Never raises.
## Tests inject a fake `hashBin` that ignores its `path` argument and
## returns canned content-derived strings, so probing runs with no real
## nim binary on disk.
##
## Public API
## ----------
##   nimFingerprint*(run = realRun; hashBin = realBinHash): string
##     Combines normalized `nim --version` output with the resolved nim
##     binary's content hash, joined with "|".  Never raises.
##
##   resolveNimBin*(): string
##     Resolves the SAME nim binary crisol's compile invocations would pick
##     up (PATH lookup of the bare "nim" command, via `os.findExe`).  Returns
##     "" if not found on PATH.
##
##   realBinHash*(path: string): string
##     Default `hashBin` seam: content-hashes the file at `path` using
##     crisol's existing FNV-1a primitive (`depgraph.fnv1a64` — never
##     std/hashes, which is not stable across Nim versions).  Never raises.
##
## Sentinel values (exported for consumer awareness):
##   NimVersionSentinel* = "<nim-version-unavailable>"
##   NimBinSentinel*     = "<nim-bin-unavailable>"
##
## Caching
## -------
## `nimFingerprint` is seam-injectable and pure-ish (given fixed seam
## outputs) so it's called freely in tests.  `cachedNimFingerprint` is a
## thin memoised wrapper — probes exactly once per process, using the real
## seams — mirroring `ccprobe.cachedCcVersion`.

import std/[os, strutils]
import crisol/ccprobe
import crisol/depgraph   # re-uses fnv1a64, toHex16; never reimplement hashing

export ccprobe.RunProc
export ccprobe.realRun

# ---------------------------------------------------------------------------
# Sentinels
# ---------------------------------------------------------------------------

const
  NimVersionSentinel* = "<nim-version-unavailable>"
  NimBinSentinel*     = "<nim-bin-unavailable>"

# ---------------------------------------------------------------------------
# Seam type
# ---------------------------------------------------------------------------

type
  BinHashProc* = proc(path: string): string {.closure.}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc normalizeOutput(s: string): string =
  ## Trim every line, drop blank lines, rejoin with "\n".  Unlike ccprobe's
  ## `firstLine`, this keeps ALL lines — the "Compiled at" date and "active
  ## boot switches" lines (beyond line 1) are exactly what distinguishes a
  ## patched build from a stock one at the same version number.
  var lines: seq[string] = @[]
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0:
      lines.add t
  lines.join("\n")

# ---------------------------------------------------------------------------
# resolveNimBin — resolve the SAME nim binary crisol's compile path uses
# ---------------------------------------------------------------------------

proc resolveNimBin*(): string =
  ## crisol's compile invocations (`compiledriver.realCompileOnly`,
  ## `runner.nim`'s monolithic `nim c` path) shell out to the bare command
  ## name "nim" via `startProcess(..., {poUsePath})` — i.e. PATH resolution,
  ## no configured/absolute path.  `findExe` performs the identical PATH
  ## lookup, so this resolves the exact binary those invocations would run.
  ## Returns "" if "nim" is not found on PATH.
  findExe("nim")

# ---------------------------------------------------------------------------
# realBinHash — default hashBin seam
# ---------------------------------------------------------------------------

proc realBinHash*(path: string): string =
  ## Content-hash the file at `path` with crisol's FNV-1a primitive.
  ## Never raises: an empty path, missing file, unreadable file, or empty
  ## content all yield `NimBinSentinel`.
  if path.len == 0:
    return NimBinSentinel
  try:
    let content = readFile(path)
    if content.len == 0:
      return NimBinSentinel
    toHex16(fnv1a64(content))
  except CatchableError:
    NimBinSentinel

# ---------------------------------------------------------------------------
# nimFingerprint — pure derivation (injectable)
# ---------------------------------------------------------------------------

proc nimFingerprint*(run: RunProc = realRun; hashBin: BinHashProc = realBinHash): string =
  ## Derive a stable, binary-distinguishing fingerprint for the Nim compiler.
  ## Both probes go through the injected seams; defaults are the real
  ## runner + real file hash.  Never raises.
  let (verOut, verOk) = run("nim", ["--version"])
  let verNorm = if verOk: normalizeOutput(verOut) else: ""
  let verPart = if verNorm.len > 0: verNorm else: NimVersionSentinel

  let binPath = resolveNimBin()
  let binPart = hashBin(binPath)

  verPart & "|" & binPart

# ---------------------------------------------------------------------------
# cachedNimFingerprint — memoised startup accessor (uses the real seams)
# ---------------------------------------------------------------------------

var nimFingerprintCache: string = ""

proc cachedNimFingerprint*(): string =
  ## Probe exactly once; return the cached value on subsequent calls.
  ## Always uses the real seams — unit tests should call `nimFingerprint`
  ## directly with injected seams instead.
  if nimFingerprintCache.len == 0:
    nimFingerprintCache = nimFingerprint()
  nimFingerprintCache
