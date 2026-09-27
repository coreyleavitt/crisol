## nimprobe.nim — Nim compiler version + binary-content probe (soundness fix).
##
## Mirrors `ccidentity.nim`'s shape exactly: effectful I/O behind an
## injectable seam, never raises, sentinel fallback on failure, memoised
## per-process accessor.
##
## ## Why this exists
##
## `api.crisolNimVersion` (= `system.NimVersion`, e.g. "2.2.10") is crisol's
## OWN compile-time Nim version string — not necessarily a fully sound
## discriminator for the Nim that actually compiles target entrypoints.  Two
## builds of Nim can share the same version STRING (a stock 2.2.10 and a
## locally-patched 2.2.10) while producing different codegen; a cache/
## freshness check keyed only on that string cannot tell them apart, which
## is a soundness gap symmetric to the one `ccidentity.nim` already closes for
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
## `run` — reuses `toolrun.RunProc`/`toolrun.realRun` verbatim (same idiom,
## same contract: never raises; only an `ok` run is read). CR7 split this
## seam out of the old `ccprobe.nim` into its own module (`crisol/toolrun`)
## precisely because this module's reliance on it was the tell that the seam
## was never a "cc" concern to begin with.
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
## outputs) so it's called freely in tests.  A `NimMemo` keeps the first
## answer that is a fact about the compiler, and never one an interrupt
## decided; `cachedNimFingerprint` is the process's memo over the real seams.
##
## R13-L3, R14-D3: once an interrupt has landed in the open scope, crisol
## refuses every new tool (`tooltrees.registerTool` kills it at once), so a
## `nim --version` asked for then fails for a reason that has nothing to do
## with the compiler. Memoizing that answer poisoned the process: a library
## host's every later run carried `<nim-version-unavailable>`, discarded its
## depgraph, recompiled everything and wrote the placeholder into the
## depgraph header and the cache keys. The run itself says so: it ends
## `reInterrupted` (`toolexec.runTool`), and a probe derived from such a run
## (`NimProbe.interrupted`) is returned but not kept, so the next lookup
## probes again. Nothing persists it either: a run reaches persistence only
## through `execute`, and `runcore.runTestsWith` returns `rsInterrupted`
## before `execute` whenever the scope's signal is set, which it stays for
## the rest of the scope; `crisol clean` stops before pruning by it. A
## `nim --version` that genuinely fails is still the placeholder, memoized
## as before.

import std/[os, strutils]
import crisol/toolrun    # CR7: RunProc/realRun -- the process-execution seam,
                          # split out of the old ccprobe.nim into its own
                          # module because this module's need for it was never
                          # a "cc" concern; see toolrun.nim's own doc.
import crisol/depgraph   # re-uses fnv1a64, toHex16; never reimplement hashing

export toolrun.RunProc
export toolrun.realRun

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
  ## Trim every line, drop blank lines, rejoin with "\n".  Unlike ccidentity's
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

type
  NimProbe* = object
    ## One probe of the Nim compiler.
    fingerprint*: string  ## `nimFingerprint`'s value
    known*: bool
      ## Both parts identified the compiler: `nim --version` answered, and
      ## the binary on PATH was read. False when either part is its
      ## placeholder (`NimVersionSentinel`, `NimBinSentinel`): such a
      ## fingerprint names no toolchain any run recorded, so nothing may be
      ## judged stale by it (`clean.cleanOrphans`, R14-D4).
    interrupted*: bool
      ## `nim --version` ended `reInterrupted`: the placeholder in
      ## `fingerprint` says nothing about the compiler, so the answer must
      ## not be kept (R13-L3, R14-D3).

proc probeNim*(run: RunProc; hashBin: BinHashProc): NimProbe =
  ## `nimFingerprint`, and whether an interrupt, not the compiler, decided
  ## it. Never raises.
  let ver = run("nim", ["--version"])
  let verNorm = if ver.ok: normalizeOutput(ver.output) else: ""
  let verPart = if verNorm.len > 0: verNorm else: NimVersionSentinel

  let binPath = resolveNimBin()
  let binPart = hashBin(binPath)

  NimProbe(fingerprint: verPart & "|" & binPart,
           known: verNorm.len > 0 and binPart != NimBinSentinel,
           interrupted: ver.ending == reInterrupted)

proc nimFingerprint*(run: RunProc = realRun; hashBin: BinHashProc = realBinHash): string =
  ## Derive a stable, binary-distinguishing fingerprint for the Nim compiler.
  ## Both probes go through the injected seams; defaults are the real
  ## runner + real file hash.  Never raises.
  probeNim(run, hashBin).fingerprint

# ---------------------------------------------------------------------------
# cachedNimFingerprint — memoised startup accessor (uses the real seams)
# ---------------------------------------------------------------------------

type
  NimMemo* = object
    ## One kept `probeNim` answer, or none yet.
    kept: NimProbe
    hasKept: bool

proc lookupProbe*(m: var NimMemo; run: RunProc; hashBin: BinHashProc): NimProbe =
  ## The kept probe, or a fresh `probeNim` through the given seams. The ONE
  ## memo rule: an answer derived from an interrupted tool run
  ## (`NimProbe.interrupted`) is returned but never kept, so the next lookup
  ## probes again; any other answer, an ordinary failure's placeholder
  ## included, is kept. Never raises.
  if m.hasKept:
    return m.kept
  let probe = probeNim(run, hashBin)
  if not probe.interrupted:
    m.kept = probe
    m.hasKept = true
  probe

proc lookup*(m: var NimMemo; run: RunProc; hashBin: BinHashProc): string =
  ## `lookupProbe(...).fingerprint`.
  m.lookupProbe(run, hashBin).fingerprint

var nimMemo: NimMemo

proc cachedNimProbe*(): NimProbe =
  ## The process's `NimMemo` over the real seams (module doc): the
  ## fingerprint and whether it identifies the compiler. Unit tests drive a
  ## `NimMemo` of their own with injected seams instead.
  nimMemo.lookupProbe(realRun, realBinHash)

proc cachedNimFingerprint*(): string =
  ## `cachedNimProbe().fingerprint`.
  cachedNimProbe().fingerprint
