## compiledriver.nim — RFC-0006 M-driver: split-compile MEASUREMENT driver.
##
## crisol compiles each entrypoint as one opaque `nim c ... -o:<bin> <ep>`
## (runner.nim:379 builds the nimcache arg, runner.nim:393 forkExec's it).
## That hides the codegen/cc/link cost split RFC-0006's Stage M needs to
## report `cc%` and per-unit cc wall-time (the inputs to the whole
## Stage R/S decision gate — see docs/rfc/0006). This module drives ONE
## entrypoint's compile as three OBSERVABLE phases instead:
##
##   1. `nim c --compileOnly <ep>`      — codegen only: emits `.c` files +
##                                        `<nimcache>/<bin>.json` (no cc, no link).
##   2. replay each `(cFile, ccCmd)` from the manifest, reproducing Nim's own
##      `execCmdsInParallel` concurrency (§Concurrency below) — so the
##      measured cc-phase wall-time matches a real `nim c`, not summed CPU time.
##   3. run the manifest's `linkcmd`.
##
## It records OVERLAP-AWARE spans (codegen, cc-as-real-wall-clock-of-the-
## parallel-phase, link) plus PER-UNIT cc wall-time. `newMeasureDriver`
## (measure mode) does NO caching; `newCacheDriver` (Stage R, below) is the
## CACHE-mode driver over the same seam. Both are MEASUREMENT/CACHE-GATED:
## the default production compile path (runner.nim's spawnCompileStable)
## stays the monolithic `nim c` unless measurement or `--objcache` is
## explicitly opted into.
##
## ## The CompileDriver seam (one seam, two modes — RFC-0006 §Stage R)
##
## Every effectful step is an injectable proc field, mirroring ccprobe.nim's
## `RunProc` idiom: the seam never raises, failure surfaces via an `ok` flag,
## and tests inject synthetic procs so the span-accounting/orchestration logic
## in `runMeasured` is exercised without a slow real `nim c` invocation.
## `newMeasureDriver` builds the real MEASURE-mode seam; `newCacheDriver`
## (Stage R, below) builds the real CACHE-mode seam over the SAME
## `CompileDriver` shape — `runCc` becomes objcache-lookup-or-compile-and-
## store — reusing this driver, not reinventing it.
##
## ## Concurrency (matching Nim's own compiler — verified against vendored
## source, Nim 2.2.10)
##
## `compiler/extccomp.nim:877 execCmdsInParallel` calls `std/osproc.
## execProcesses` (`lib/pure/osproc.nim:341`) with `n = conf.numberOfProcessors`,
## which defaults (when unset — the common case, no `--parallelBuild`) to
## `countProcessors()` (`extccomp.nim:883`). `defaultRunCc` below calls that
## SAME `std/osproc.execProcesses` primitive — not a reimplementation — so the
## measured overlap is Nim's actual scheduling: a sliding window of at most
## `concurrency` processes, reaped via `waitpid(-1, ...)` as any one exits and
## immediately replaced by the next pending command (`osproc.nim:398-437`),
## never a fixed batch-of-N. `execProcesses` also runs each command through
## the shell (`poEvalCommand`) — matching Nim's own cc-command invocation,
## which is why replaying the manifest's cc strings this way is a faithful
## reproduction, not a soundness-relevant shell-injection surface (the manifest
## is crisol's own trusted `nim c` output, not external input).
##
## ## Error handling
##
## `runMeasured` aborts on the first phase that fails (non-zero compileOnly,
## any cc unit, or link) and returns `CompileSpans(ok: false, errorMsg: ...)`.
## It never fabricates a span for a phase that did not complete; spans for
## phases that DID complete before the failure are preserved (e.g. a link
## failure still reports real codegen/cc spans).

import std/[monotimes, options, os, osproc, sequtils, streams, strutils, tables, times]
import crisol/closure
import crisol/objcache
import crisol/artifactid   # shellSplit — review Finding 2: shell-aware, not splitWhitespace

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  CompileOnlyProc* = proc(entrypoint: string; flags: seq[string];
                          nimcacheDir, outputBinPath: string):
                            tuple[ok: bool; output: string] {.closure.}
    ## Runs codegen only. Real impl (`realCompileOnly`): argv-array spawn, no
    ## shell — mirrors runner.nim's forkExec compile-arg construction
    ## (runner.nim:379-393), plus `--compileOnly`.

  CompileUnit* = tuple[basename: string; ccCmd: string]
    ## One entry from the manifest's raw `compile` array (see
    ## `closure.parseCompileManifest`): the generated `.c`'s basename (e.g.
    ## "@mpass_always.nim.c") + its full cc command string.

  CcUnitResult* = object
    basename*:  string
    ok*:        bool
    ccTimeUs*:  int64        ## wall time for this single unit, monotonic clock

  RunCcResult* = object
    ok*:        bool         ## true iff every unit exited 0
    units*:     seq[CcUnitResult]
    ccSpanUs*:  int64        ## overlap-aware wall time of the WHOLE cc phase
                              ## (max end - min start across all units) — NOT
                              ## the sum of per-unit ccTimeUs.
    decisions*: seq[tuple[basename: string; decision: ObjCacheDecision]]
      ## ADDITIVE (Stage R, R2a): per-unit objcache decision. Empty in
      ## measure mode (`defaultRunCc`/`newMeasureDriver` never populate this —
      ## there is no cache to decide against). Only `newCacheDriver`'s runCc
      ## populates it. A unit whose underlying compile itself FAILED gets no
      ## entry here (no cache decision was ever made for it — see
      ## `newCacheDriver`'s doc); order is not guaranteed to match `units`,
      ## look up by `basename`.

  RunCcProc* = proc(units: seq[CompileUnit]): RunCcResult {.closure.}
    ## Runs every unit's cc command. Real measure-mode impl (`defaultRunCc`,
    ## below): never caches. Stage R's cache mode implements this as
    ## objcache-lookup-or-compile-and-store — see `newCacheDriver`, below.

  LinkProc* = proc(linkCmd: string): tuple[ok: bool; output: string] {.closure.}
    ## Runs the manifest's `linkcmd`. Real impl (`realLink`): shell-evaluates
    ## the string (matches Nim's own `execLinkCmd`, which also shell-invokes it).

  CompileDriver* = object
    ## Closure-field seam object (crisol idiom — mirrors ccprobe.RunProc).
    ## ONE seam, TWO modes: measure (`newMeasureDriver`) and Stage R's cache
    ## mode (`newCacheDriver`, below). Never two abstractions.
    compileOnly*: CompileOnlyProc
    runCc*:       RunCcProc
    link*:        LinkProc

  CompileSpans* = object
    ## Result of one `runMeasured` call.
    ok*:            bool
    errorMsg*:       string     ## meaningful only when ok == false
    codegenSpanUs*:  int64
    ccSpanUs*:       int64
    linkSpanUs*:     int64
    ccUnitTimesUs*:  Table[string, int64]   ## basename -> ccTimeUs
    decisions*:      seq[tuple[basename: string; decision: ObjCacheDecision]]
      ## ADDITIVE (Stage R, R5a): `RunCcResult.decisions` copied through
      ## verbatim. Empty for measure-mode callers (`defaultRunCc`/
      ## `newMeasureDriver` never populate `RunCcResult.decisions`) — only
      ## `newCacheDriver`'s runCc populates it. Copied on both the cc-phase
      ## failure early-return and the normal-completion path (same places
      ## `ccUnitTimesUs` is populated), so a cache-mode caller sees whatever
      ## decisions were made even for units processed before a later unit's
      ## compile failed.

# ---------------------------------------------------------------------------
# Cache-mode helper: parseCcOutputObj
# ---------------------------------------------------------------------------

proc parseCcOutputObj*(ccCmd: string): string =
  ## Extract the cc `-o <path>` object-output argument from a manifest
  ## `ccCmd` string — the `.o` the compile writes and `linkcmd` later
  ## references. Handles both the space-separated `-o <path>` form (the one
  ## real Nim-generated cc commands use — see `artifactid.nim`'s test
  ## fixtures) and the concatenated `-o<path>` form. Returns "" if no `-o`
  ## flag is present, if `-o` is the final token with nothing after it, or if
  ## `ccCmd` cannot be cleanly shell-tokenized (an unterminated quote — same
  ## fail-safe degrade as `artifactid.deriveCcMInvocation`). Never raises.
  ##
  ## **Review Finding 2:** tokenizes via `artifactid.shellSplit` — shell-AWARE
  ## (matching `deriveCcMInvocation`'s own tokenization of the SAME `ccCmd`
  ## shape), not a naive `splitWhitespace()`. A plain whitespace split
  ## silently corrupts a shell-quoted `-o <path>` whose path contains a space
  ## (realistic under WSL2 — a mounted toolchain's nimcache/bin dir inherits
  ## the space, and Nim shell-quotes the argument before this string is ever
  ## generated), truncating the extracted object path at the embedded space —
  ## which made objcache silently no-op under a whitespace stateDir/project
  ## path (every unit's `-o` extraction failed to find its real target).
  let (toks, ok) = artifactid.shellSplit(ccCmd)
  if not ok: return ""
  for i, t in toks:
    if t == "-o":
      if i + 1 < toks.len: return toks[i + 1]
      else: return ""
    elif t.startsWith("-o") and t.len > 2:
      return t[2 .. ^1]
  ""

# ---------------------------------------------------------------------------
# Real (measure-mode) seam implementations
# ---------------------------------------------------------------------------

proc realCompileOnly*(entrypoint: string; flags: seq[string];
                      nimcacheDir, outputBinPath: string):
                        tuple[ok: bool; output: string] =
  ## Spawns `nim c --mm:orc --hints:off --compileOnly --nimcache:<dir>
  ## -o:<outputBinPath> <flags> <entrypoint>` via an argv array (no shell —
  ## same construction as runner.nim's compile path, plus `--compileOnly`).
  ## Never raises; failure surfaces as `ok = false`.
  var args = @["c", "--mm:orc", "--hints:off", "--compileOnly",
               "--nimcache:" & nimcacheDir, "-o:" & outputBinPath]
  for f in flags: args.add f
  args.add entrypoint
  try:
    let p = startProcess("nim", args = args, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (ok: exitCode == 0, output: output)
  except CatchableError as e:
    result = (ok: false, output: "nim --compileOnly spawn failed: " & e.msg)

proc defaultRunCc*(units: seq[CompileUnit];
                   concurrency: int = countProcessors()): RunCcResult =
  ## Real cc-phase execution. Calls `std/osproc.execProcesses` directly — the
  ## exact primitive Nim's own `execCmdsInParallel` calls (see module doc
  ## §Concurrency) — so the sliding-window scheduling matches Nim's, not an
  ## approximation of it. Records, via `std/monotimes`, each unit's own
  ## [start, end) and derives:
  ##   - `ccTimeUs` per unit (end - start for that unit alone)
  ##   - `ccSpanUs` for the whole phase (max end - min start across ALL units
  ##     — overlap-aware: N fully-parallel units of duration D span ≈ D, not
  ##     N*D)
  ## Never raises; a spawn/exit failure is reflected in `ok`/`units[i].ok`.
  if units.len == 0:
    return RunCcResult(ok: true, units: @[], ccSpanUs: 0)

  var starts = newSeq[MonoTime](units.len)
  var ends   = newSeq[MonoTime](units.len)
  var oks    = newSeq[bool](units.len)
  let cmds   = units.mapIt(it.ccCmd)

  let before = proc(idx: int) =
    starts[idx] = getMonoTime()
  let after = proc(idx: int, p: Process) =
    ends[idx] = getMonoTime()
    oks[idx] = p.peekExitCode() == 0

  let n = max(1, concurrency)
  discard execProcesses(cmds, {poStdErrToStdOut, poUsePath, poParentStreams},
                        n, before, after)

  result.units = newSeq[CcUnitResult](units.len)
  var allOk     = true
  var spanStart = starts[0]
  var spanEnd   = ends[0]
  for i in 0 ..< units.len:
    let dur = (ends[i] - starts[i]).inMicroseconds
    result.units[i] = CcUnitResult(basename: units[i].basename, ok: oks[i], ccTimeUs: dur)
    if not oks[i]: allOk = false
    if starts[i] < spanStart: spanStart = starts[i]
    if ends[i]   > spanEnd:   spanEnd   = ends[i]
  result.ok = allOk
  result.ccSpanUs = (spanEnd - spanStart).inMicroseconds

proc realLink*(linkCmd: string): tuple[ok: bool; output: string] =
  ## Shell-evaluates the manifest's `linkcmd` string (matches Nim's own
  ## `execLinkCmd` -> `execExternalProgram`, which also shell-invokes it).
  ## Never raises; failure surfaces as `ok = false`.
  try:
    let p = startProcess(linkCmd, options = {poEvalCommand, poStdErrToStdOut, poUsePath})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    result = (ok: exitCode == 0, output: output)
  except CatchableError as e:
    result = (ok: false, output: "link spawn failed: " & e.msg)

proc newMeasureDriver*(concurrency: int = countProcessors()): CompileDriver =
  ## The measure-mode `CompileDriver`: real compileOnly/cc/link, no caching.
  CompileDriver(
    compileOnly: realCompileOnly,
    runCc: proc(units: seq[CompileUnit]): RunCcResult = defaultRunCc(units, concurrency),
    link: realLink,
  )

# ---------------------------------------------------------------------------
# Cache-mode driver (Stage R, R2a)
# ---------------------------------------------------------------------------

type
  ObjKeyOfProc* = proc(unit: CompileUnit):
    tuple[keyHash, preimage, objOutPath: string] {.closure.}
    ## Derives the `(keyHash, preimage, objOutPath)` a compile unit maps to.
    ## Real production wiring (R2b) closes over `objkey.stageRKey` plus
    ## `parseCcOutputObj` (for `objOutPath`) and the manifest's `.c` content;
    ## R2a's tests inject a synthetic proc — this module never computes a key
    ## itself, it only consumes one (mirroring how `objcache.nim` takes
    ## `keyHash`/`keyPreimage` as given).
    ##
    ## An EMPTY `keyHash` (R2b1) is a deliberate signal, not an error: it
    ## marks the unit as NON-CACHEABLE — `newCacheDriver`'s `runCc` skips
    ## both `seams.lookup` and `seams.store` for it entirely and simply
    ## compiles it via `ccRunner` (decision `ocdDisabled`). This is how the
    ## entry unit (`@m<entrypoint>.nim.c`) stays PRIVATE — RFC-0006: "the
    ## entry .c + link stay private" — without `newCacheDriver` itself
    ## needing to know what an "entry unit" is; the caller's `keyOf`
    ## encodes that decision.

proc newCacheDriver*(seams: ObjCacheSeams; keyOf: ObjKeyOfProc;
                     concurrency: int = countProcessors();
                     ccRunner: RunCcProc = nil): CompileDriver =
  ## The cache-mode `CompileDriver`: same `compileOnly`/`link` as measure mode
  ## (`realCompileOnly`/`realLink` — caching only touches the cc phase), but
  ## `runCc` becomes objcache-lookup-or-compile-and-store, per unit:
  ##
  ##   1. `(keyHash, preimage, objOut) = keyOf(unit)`.
  ##   2. `seams.lookup(keyHash, preimage)`:
  ##      - `some(cachedPath)` — a HIT: copy `cachedPath` -> `objOut` (so
  ##        `linkcmd` finds it there, matching what a real compile would have
  ##        produced), record `ocdHit`, `ok = (copy succeeded)`,
  ##        `ccTimeUs = 0` (no compile ran). The underlying compiler is NEVER
  ##        invoked for a hit unit.
  ##      - `none` — a MISS: the unit is handed to `ccRunner` (defaults to
  ##        the same `defaultRunCc` primitive measure mode uses, bound to
  ##        `concurrency` — so MISS units of one `runCc` call still overlap
  ##        exactly like measure mode's cc phase; tests inject a synthetic
  ##        `ccRunner` so no real subprocess runs). `ccRunner` is gated on
  ##        exit status: a nonzero/killed compile means `ok = false` and
  ##        NOTHING is written to the cache — a failed/partial compile must
  ##        never be stored (no truncated `.o`). On success, `objOut`'s bytes
  ##        are handed to `seams.store(keyHash, preimage, objOut)` (store
  ##        itself reads the file — same contract as `objcache.storeObject`);
  ##        the decision is `ocdStored` if `store` returned true, else
  ##        `ocdMissCompiled`.
  ##
  ## Preserves `RunCcResult.ok` (true iff every unit — hit or miss — is ok)
  ## and overlap-aware `ccSpanUs` (the MISS-phase span alone; hit units cost
  ## ~0 wall time and contribute nothing to it — mirrors `defaultRunCc`'s own
  ## overlap-aware accounting, just over the miss subset). Populates
  ## `RunCcResult.decisions`.
  ##
  ## `ccRunner`'s contract mirrors `RunCcProc`/`defaultRunCc` EXACTLY,
  ## including 1:1 index-order correspondence between its input `units` and
  ## its returned `RunCcResult.units` — required so this driver can map each
  ## miss result back to the `(keyHash, preimage, objOut)` `keyOf` computed
  ## for it.
  let runner: RunCcProc =
    if ccRunner == nil:
      proc(units: seq[CompileUnit]): RunCcResult = defaultRunCc(units, concurrency)
    else:
      ccRunner

  let cacheRunCc = proc(units: seq[CompileUnit]): RunCcResult =
    type KeyInfo = tuple[keyHash, preimage, objOutPath: string]
    var keyInfos = newSeq[KeyInfo](units.len)
    for i, u in units:
      keyInfos[i] = keyOf(u)

    var unitResults = newSeq[CcUnitResult](units.len)
    var decisions: seq[tuple[basename: string; decision: ObjCacheDecision]]
    var missUnits: seq[CompileUnit]
    var missOrigIdx: seq[int]   # units[] index for each entry in missUnits, in order
    var nonCacheable = newSeq[bool](units.len)
      ## R2b1: units whose `keyOf` returned an empty keyHash — never looked
      ## up, never stored (see `ObjKeyOfProc`'s doc); tracked by index so the
      ## post-ccRunner pass below can route them to `ocdDisabled` instead of
      ## the normal store-gate logic.

    for i, u in units:
      let k = keyInfos[i]
      if k.keyHash.len == 0:
        # Non-cacheable (R2b1): skip lookup AND store entirely, just compile.
        nonCacheable[i] = true
        missUnits.add u
        missOrigIdx.add i
        continue
      let cached = seams.lookup(k.keyHash, k.preimage)
      if cached.isSome:
        var copyOk = true
        try:
          copyFile(cached.get, k.objOutPath)
        except OSError as e:
          copyOk = false
          stderr.write("crisol: warning: objcache hit copy to '" & k.objOutPath &
                       "' failed for '" & u.basename & "': " & e.msg & "\n")
        unitResults[i] = CcUnitResult(basename: u.basename, ok: copyOk, ccTimeUs: 0)
        decisions.add (basename: u.basename, decision: ocdHit)
      else:
        missUnits.add u
        missOrigIdx.add i

    let missRes =
      if missUnits.len > 0: runner(missUnits)
      else: RunCcResult(ok: true, units: @[], ccSpanUs: 0)

    # 1:1 index correspondence with missUnits (RunCcProc's contract — see
    # defaultRunCc, which fills result.units by input index).
    for j, mu in missRes.units:
      let origIdx = missOrigIdx[j]
      unitResults[origIdx] = mu
      if mu.ok:
        if nonCacheable[origIdx]:
          decisions.add (basename: mu.basename, decision: ocdDisabled)
        else:
          let k = keyInfos[origIdx]
          let stored = seams.store(k.keyHash, k.preimage, k.objOutPath)
          decisions.add (basename: mu.basename,
                         decision: (if stored: ocdStored else: ocdMissCompiled))
      # else: the compile itself failed — no cache decision is made, store is
      # NOT called (see module doc: never cache a failed/truncated compile).

    var allOk = true
    for r in unitResults:
      if not r.ok: allOk = false

    result = RunCcResult(ok: allOk, units: unitResults,
                         ccSpanUs: missRes.ccSpanUs, decisions: decisions)

  CompileDriver(
    compileOnly: realCompileOnly,
    runCc: cacheRunCc,
    link: realLink,
  )

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

proc runMeasured*(driver: CompileDriver; entrypoint: string; flags: seq[string];
                  nimcacheDir, outputBinPath: string): CompileSpans =
  ## Drives one entrypoint through compileOnly -> parse manifest -> runCc ->
  ## link, recording overlap-aware spans + per-unit cc wall-time via
  ## `std/monotimes` (never wall/`Date`). Aborts on the first failing phase —
  ## see module doc §Error handling.
  let binName = outputBinPath.extractFilename

  let t0 = getMonoTime()
  let (coOk, coOut) = driver.compileOnly(entrypoint, flags, nimcacheDir, outputBinPath)
  let t1 = getMonoTime()
  if not coOk:
    return CompileSpans(ok: false, errorMsg: "compileOnly failed: " & coOut)

  let jsonPath = nimcacheDir / binName & ".json"
  let manifest = parseCompileManifest(jsonPath)   # raises CrisolError on bad JSON

  let units = manifest.compile.mapIt(
    (basename: it.cPath.extractFilename, ccCmd: it.ccCmd))
  let ccResult = driver.runCc(units)
  if not ccResult.ok:
    result = CompileSpans(ok: false, errorMsg: "cc phase failed")
    result.codegenSpanUs = (t1 - t0).inMicroseconds
    result.ccSpanUs      = ccResult.ccSpanUs
    for u in ccResult.units: result.ccUnitTimesUs[u.basename] = u.ccTimeUs
    result.decisions     = ccResult.decisions
    return result

  let t2 = getMonoTime()
  let (linkOk, linkOut) = driver.link(manifest.linkcmd)
  let t3 = getMonoTime()

  result = CompileSpans(ok: linkOk)
  result.codegenSpanUs = (t1 - t0).inMicroseconds
  result.ccSpanUs      = ccResult.ccSpanUs
  for u in ccResult.units: result.ccUnitTimesUs[u.basename] = u.ccTimeUs
  result.decisions     = ccResult.decisions
  if not linkOk:
    result.errorMsg = "link failed: " & linkOut
  else:
    result.linkSpanUs = (t3 - t2).inMicroseconds
