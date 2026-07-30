## cacheworker.nim — RFC-0006 Stage R, R2b1: the CACHE-mode compile-slot
## worker, plus its monolithic escape hatch.
##
## `crisol --internal-compile-worker <plan.json>` — the CACHE-MODE sibling of
## `measureworker.nim`'s `--internal-measure-compile` worker. Reuses the
## SAME `workerplan.MeasurePlan`/`parseMeasurePlan` (no schema change: R2b1's
## plan carries exactly what measure mode's plan carries — see
## test_measureworker.nim's round-trip pin). Where the measure worker drives
## `compiledriver.newMeasureDriver()` (no caching, just spans), this worker
## drives `compiledriver.newCacheDriver()` (objcache.nim's
## `<stateDir>/objcache/v1/` cross-entrypoint object store) over the SAME
## `runMeasured` orchestration — R2a's driver is reused, not reinvented.
##
## Split out of the original fused measureworker.nim (RFC-0006 review R8,
## structural-only — no behavior change): this module now owns the
## cache-mode worker (`runCompileCacheWorker` + `runMonolithicCompile` +
## `buildCacheKeyOf` + `captureToolchainCcVersion` + `recordObjCacheStatsRow`).
## The plan schema + shared helpers (`MeasurePlan`, `entryUnitBasename`,
## `forceMeasurementCcEnv`, both internal tokens) live in `workerplan.nim`;
## the measure-mode sibling worker lives in `measureworker.nim`. See those
## modules' own docs for their scope.
##
## ## buildCacheKeyOf — entry unit stays private, reusable units get the full
## ## R stage key (exported + seam-injectable — see its own doc below)
##
## `workerplan.entryUnitBasename(plan.entrypointAbsPath)` names the entry unit
## (`@m<entrypoint>.nim.c` — RFC-0006 §File scoping's soundness invariant:
## it carries NimMain/whole-program init and must never be cached). The
## returned `ObjKeyOfProc` yields an EMPTY keyHash for it —
## `compiledriver.newCacheDriver`'s R2b1 additive branch (see that module)
## treats an empty keyHash as NON-CACHEABLE: the unit is compiled but never
## looked up or stored.
##
## Every OTHER unit gets `objkey.stageRKey` — the full Stage-R soundness key
## (normalize(ccCmd) ⊕ normalize(cContent) ⊕ cc -M include closure ⊕
## nimVersion ⊕ ccVersion). `nimVersion`/`ccVersion` are captured ONCE, up
## front (see `captureFirstVersionLine`/`captureToolchainCcVersion` below) —
## NOT per-unit — since the toolchain is fixed for the whole worker
## invocation and re-probing per unit would be wasted subprocess spawns for
## an identical answer every time.
##
## **R1 (soundness-critical): `stageRKey`'s `ok` flag is checked, not just its
## `keyHash`/`preimage`.** If a reusable unit's `.c` content can't be read,
## its cc command carries no discoverable `-o` object path
## (`compiledriver.parseCcOutputObj` returns ""), OR `stageRKey.ok = false`
## (the `cc -M` include-closure probe itself failed — R1's finding: this
## case was previously NOT checked, so a failed probe silently folded an
## empty closure component into an otherwise-normal, non-empty key), that ONE
## unit degrades to non-cacheable (empty keyHash) rather than raising OR
## being handed a wrong-but-plausible key — a per-unit oddity must not abort
## the whole compile NOR silently weaken its soundness (mirrors
## `measureworker.recordArtifactRows`'s own per-unit degrade-and-continue
## idiom).
##
## ## The escape hatch (RFC-0006's own philosophy: "a split-compile bug must
## NEVER become an unbypassable compile failure")
##
## The entire split-cache attempt — from `keyOf`'s closure setup through
## `runMeasured` — is wrapped in ONE try/except. On ANY exception, OR on
## `not spans.ok` (a cache-path compile/link failure that `runMeasured`
## reports normally, no exception involved), this worker falls back to
## `runMonolithicCompile`: the exact single-shot `nim c --mm:orc --hints:off
## --nimcache:<dir> -o:<bin> <flags> <entrypoint>` invocation
## `runner.spawnCompileStable`'s own monolithic path uses (same argv-array,
## no shell — mirrors `realCompileOnly`'s spawn idiom, just without
## `--compileOnly`), and returns ITS exit status. The binary still gets
## built; only the cross-entrypoint object-cache benefit is lost for this
## compile.
##
## ## Decision-summary emission
##
## `compiledriver.CompileSpans` (what `runMeasured` returns) does NOT surface
## per-unit `RunCcResult.decisions` — that detail lives one layer down, inside
## `newCacheDriver`'s own closure. Persisting hit/miss/store COUNTS is R5
## (decision persistence / run-report aggregation), explicitly out of this
## slice's scope. So, on a successful cache-mode compile, this worker emits
## ONE minimal stderr summary line — "crisol: objcache: <n> reusable units
## processed" — where `n` is the reusable-set size (every unit in `spans.
## ccUnitTimesUs` except the entry unit), a plain byproduct of information
## this worker already has, not a new decision-tracking mechanism.
##
## ## Artifact-ledger scope (R16 / R9-final): this worker NEVER calls
## `measureworker.recordArtifactRows`
##
## A cache-mode HIT does no compilation for that unit — there is no genuine
## `ccTimeUs` to record. An earlier pass (R9) had this worker also call
## `recordArtifactRows` (reusing the SAME manifest/spans it already had) so a
## single `--objcache` run could populate both sides of the M-report's drift
## comparison (potential `rTime` alongside realized `hitRate`) from one run.
## R16 found the flaw: a HIT's ArtifactRow necessarily carries `ccTimeUs=0`,
## which (a) skews the cc-time-weighted potential-`rTime` computation and (b)
## permanently pollutes the append-only artifact ledger — it is scanned
## CUMULATIVELY across every future run, so a zero-cost row written once
## never stops distorting later reports. R16's fix REVERTS the R9 addition:
## the artifact ledger is written ONLY by `measureworker.
## runMeasureCompileWorker` (a real, uncached compile — every unit's
## `ccTimeUs` is genuine). This worker records realized reuse via
## `recordObjCacheStatsRow` alone. The drift comparison (potential vs
## realized) is now necessarily a CROSS-RUN correlation — see
## `compilereport.nim`'s module doc ("Drift tie-in") for the honest framing.

import std/[os, osproc, streams, strutils, tables, times]
import crisol/types
import crisol/keys
import crisol/closure
import crisol/compiledriver
import crisol/artifactid
import crisol/objcachestats
import crisol/objcache
import crisol/objkey
import crisol/ccprobe
import crisol/workerplan

# ---------------------------------------------------------------------------
# recordObjCacheStatsRow — RFC-0006 Stage R, R5a: realized objcache
# hit/miss/store telemetry (CACHE-MODE worker only)
# ---------------------------------------------------------------------------

proc recordObjCacheStatsRow(plan: MeasurePlan; spans: CompileSpans) =
  ## Tally `spans.decisions` (populated only by a CACHE-MODE compile — see
  ## `compiledriver.newCacheDriver`/`runMeasured`'s R5a addition) into one
  ## `ObjCacheStatsRow` and append it to the objcache-stats stream. See
  ## `objcachestats.nim`'s module doc "Counting convention" for exactly what
  ## `hits`/`misses`/`stored`/`disabled` count — in short: `hits =
  ## count(ocdHit)`, `stored = count(ocdStored)`, `misses =
  ## count(ocdMissCompiled) + count(ocdStored)` (both are cache-misses that
  ## had to compile; `stored` is the persisted subset), `disabled =
  ## count(ocdDisabled)`.
  ##
  ## `reusedBytes` sums the on-disk `.o` size at each HIT unit's object-output
  ## path (re-derived from the manifest's cc command via
  ## `compiledriver.parseCcOutputObj`, mirroring `newCacheDriver`'s own
  ## lookup-then-copy path) — best-effort, contributes 0 for any unit whose
  ## `.o` can't be stat'd rather than raising (mirrors
  ## `measureworker.recordArtifactRows`'s own best-effort `getFileSize`
  ## idiom).
  ##
  ## `entrypointIdentity`/`groupId`/`configHash` are derived EXACTLY as
  ## `measureworker.recordArtifactRows`/`recordCompileCostRow` derive them,
  ## so all three streams share identity and a future report can join them.
  ## May raise (manifest parse, unexpected I/O) — the CALLER wraps this in
  ## try/except so a stats-recording failure never fails a successful
  ## compile (mirrors those procs' own contract).
  let manifestPath = plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json"
  let manifest = parseCompileManifest(manifestPath)
  var ccCmdByBasename: Table[string, string]
  for pair in manifest.compile:
    ccCmdByBasename[pair.cPath.extractFilename] = pair.ccCmd

  var hits, misses, stored, disabled = 0
  var reusedBytes: int64 = 0
  for d in spans.decisions:
    case d.decision
    of ocdHit:
      inc hits
      let ccCmd = ccCmdByBasename.getOrDefault(d.basename, "")
      if ccCmd.len > 0:
        let objPath = parseCcOutputObj(ccCmd)
        if objPath.len > 0:
          try:
            reusedBytes += getFileSize(objPath)
          except CatchableError:
            discard  # unstattable — leave this unit's contribution at 0
    of ocdMissCompiled:
      inc misses
    of ocdStored:
      inc misses
      inc stored
    of ocdDisabled:
      inc disabled
    of ocdSoftCapSkipped, ocdCollisionReject:
      # newCacheDriver never emits these as a UNIT decision today (see
      # objcache.nim's ObjCacheDecision doc + objcachestats.nim's module doc)
      # — included here only for exhaustive-case-match completeness.
      discard

  let identity = identityKey(plan.entrypointPath, plan.configHash)
  let nowUs = int64(epochTime() * 1_000_000)

  var led = openObjCacheStatsLedger(plan.stateDir)
  defer: closeObjCacheStatsLedger(led)

  let row = ObjCacheStatsRow(
    entrypointIdentity: identity,
    groupId:            plan.groupId,
    configHash:         plan.configHash,
    hits:               hits,
    misses:             misses,
    stored:             stored,
    disabled:           disabled,
    reusedBytes:        reusedBytes,
    timestamp:          nowUs,
    rowVersion:         currentObjCacheStatsRowVersion,
  )
  append(led, row)

# ---------------------------------------------------------------------------
# Toolchain-version capture helpers
# ---------------------------------------------------------------------------

proc firstNonEmptyLine(s: string): string =
  ## Returns the first non-empty, trimmed line of `s`; "" if none. Mirrors
  ## `ccprobe.firstLine`'s idiom (module-private there, so duplicated here
  ## rather than pulling in `ccprobe` for this one string-parsing helper —
  ## same deliberate small-duplication call `artifactid.chainComponent`
  ## documents). `ccprobe` itself IS imported now (see `captureToolchainCcVersion`
  ## below, R2's fix) — just not for this substring-only helper.
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0: return t
  ""

proc captureFirstVersionLine(cmd: string): string =
  ## Best-effort `<cmd> --version`, first line only, "" on ANY failure
  ## (command not found, nonzero exit, spawn error) — never raises. Used ONLY
  ## to capture `nimVersion` (single-sourced: `nim` is the one compiler this
  ## worker itself drives, so a plain `nim --version` probe is the right
  ## fidelity). `ccVersion` capture is `captureToolchainCcVersion` below (R2
  ## fix) — cc's key material must ALSO fold the libc fingerprint, which a
  ## `cc --version`-only probe cannot see.
  try:
    let p = startProcess(cmd, args = @["--version"],
                         options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    discard p.waitForExit()
    result = firstNonEmptyLine(output)
  except CatchableError:
    result = ""

proc captureToolchainCcVersion*(run: ccprobe.RunProc = ccprobe.realRun): string =
  ## **R2 fix.** The worker's `ccVersion` key-material component. Previously
  ## a hand-rolled `<cmd> --version`-only probe (`captureFirstVersionLine
  ##("cc")`) — cc-identity only. RFC-0004's `ccprobe.ccVersion` (the SAME
  ## toolchain fingerprint `keys.soundnessKey` uses) deliberately folds BOTH
  ## `cc --version` AND `ldd --version`, because a libc-only upgrade (a base-
  ## image glibc bump, same cc binary) can change `nimbase.h`/runtime ABI
  ## layout even though `cc --version`'s own output is unchanged — exactly
  ## the same rationale `objkey.stageRKey`'s module doc gives for folding
  ## `nimVersion`/`ccVersion` at all. Reusing `ccprobe.ccVersion` directly
  ## (not reimplementing the fold) means the object-cache key and RFC-0004's
  ## `SoundnessKey` are provably sourced from the same toolchain-fingerprint
  ## logic. Exported + seam-injectable so a test can prove this without a
  ## real `cc`/`ldd` subprocess — see test_measureworker.nim.
  ccprobe.ccVersion(run)

proc buildCacheKeyOf*(entryBasename: string; knownStrings: seq[string];
                      nimVersion, ccVersion: string;
                      ccMRun: artifactid.RunProc = artifactid.realRun;
                      readFile: artifactid.FileReaderProc = artifactid.realFileReader):
    ObjKeyOfProc =
  ## Builds the `ObjKeyOfProc` closure `runCompileCacheWorker` hands to
  ## `compiledriver.newCacheDriver`. Exported + seam-injectable (`ccMRun`/
  ## `readFile`, mirroring `objkey.stageRKey`'s own seam params) so a unit
  ## test can drive every degrade branch — including R1's cc -M probe
  ## failure — without a real compile. See the module doc above
  ## ("buildCacheKeyOf" section) for the full per-unit degrade contract.
  result = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
    let objOutPath = parseCcOutputObj(unit.ccCmd)
    if unit.basename == entryBasename:
      # The entry unit stays PRIVATE — never keyed (RFC-0006 soundness
      # invariant). objOutPath is carried through for shape-completeness
      # only; newCacheDriver's non-cacheable branch never reads it.
      return (keyHash: "", preimage: "", objOutPath: objOutPath)

    if objOutPath.len == 0:
      # No discoverable -o object path — degrade to non-cacheable rather
      # than crash (module doc: a per-unit oddity must not abort the
      # whole compile).
      return (keyHash: "", preimage: "", objOutPath: objOutPath)

    # The unit's real .c path is the LAST whitespace-delimited token of
    # its own ccCmd — the SAME convention `artifactid.
    # deriveCcMInvocation` already relies on ("Targets the SAME source
    # file as the original command (its last ... token)"). This is NOT
    # always `nimcacheDir / unit.basename`: Nim-generated units coincide
    # with that (confirmed against the golden fixture's real manifest),
    # but a vendor `{.compile.}` unit (e.g. golden_reuse's `fixture.c`) is
    # compiled from its OWN source directory, never copied into
    # nimcacheDir — reading `nimcacheDir / basename` for one of those
    # fails outright. Deriving from ccCmd handles both uniformly, without
    # needing to special-case vendor units. A wrong/mis-tokenized cPath
    # here (e.g. from a naive splitWhitespace on a shell-quoted path — see
    # R1b's fix in `artifactid.deriveCcMInvocation`) simply fails to
    # resolve as a real file below and degrades to non-cacheable, same as
    # any other unreadable-.c case — inherently fail-safe.
    # Review Finding 2: tokenize via artifactid.shellSplit (shell-AWARE,
    # matching deriveCcMInvocation's own tokenization of this SAME ccCmd
    # shape), not a naive splitWhitespace() -- which silently mis-tokenizes a
    # shell-quoted path containing a space (realistic under WSL2:
    # nimcacheDir/outputBinPath inherit a space-containing stateDir/project
    # path, so BOTH the -o <path> arg and the trailing .c source arg do too)
    # and previously produced a WRONG-but-plausible truncated cPath that
    # silently failed to resolve as a real file -- degrading every unit to
    # non-cacheable on EVERY compile under such a path: a permanent, silent
    # objcache no-op, not merely a rare per-unit oddity. An unterminated-
    # quote/undecodable ccCmd still degrades to non-cacheable (fail-safe,
    # same as any other unreadable-.c case); it just no longer ALSO silently
    # mis-tokenizes a well-formed one.
    let (ccToks, splitOk) = artifactid.shellSplit(unit.ccCmd)
    let cPath = if splitOk and ccToks.len > 0: ccToks[^1] else: ""

    let (cContent, readOk) = readFile(cPath)
    if not readOk:
      # Same degrade-not-crash rule, for an unreadable/unresolvable .c.
      return (keyHash: "", preimage: "", objOutPath: objOutPath)

    let key = stageRKey(cContent, unit.ccCmd, knownStrings, nimVersion, ccVersion,
                        ccMRun, readFile)
    if not key.ok:
      # R1: the cc -M include-closure probe itself failed (or, per R1b/R4,
      # couldn't be cleanly derived). The closure component is UNKNOWN, not
      # empty — folding it in anyway would produce a normal-looking key that
      # could confirm-match a DIFFERENT unit's real header closure. Degrade
      # to non-cacheable, exactly like every other per-unit oddity here.
      return (keyHash: "", preimage: "", objOutPath: objOutPath)

    (keyHash: key.keyHash, preimage: key.preimage, objOutPath: objOutPath)

proc runMonolithicCompile(plan: MeasurePlan): int =
  ## The escape hatch's fallback: the SAME monolithic invocation
  ## `runner.spawnCompileStable` uses when `measureCompileReuse`/cache mode
  ## is off — an argv-array spawn (no shell), mirroring `compiledriver.
  ## realCompileOnly`'s spawn primitive minus `--compileOnly`. Captures
  ## combined stdout+stderr so a genuine compile failure is still
  ## diagnosable on stderr; never raises (a spawn failure itself surfaces as
  ## a nonzero return, matching a real compile failure's exit contract).
  var args = @["c", "--mm:orc", "--hints:off",
               "--nimcache:" & plan.nimcacheDir, "-o:" & plan.outputBinPath]
  for f in plan.flags: args.add f
  args.add plan.entrypointAbsPath
  try:
    let p = startProcess("nim", args = args, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    if exitCode != 0:
      stderr.write("crisol: compile-worker: monolithic fallback compile failed:\n" &
                   output & "\n")
    result = exitCode
  except CatchableError as e:
    stderr.write("crisol: compile-worker: monolithic fallback compile spawn failed: " &
                 e.msg & "\n")
    result = 1

proc runCompileCacheWorker*(planPath: string): int =
  ## The `--internal-compile-worker <plan.json>` worker main. See module doc
  ## for the full pipeline, the non-cacheable entry-unit rule, and the
  ## escape-hatch contract.
  var plan: MeasurePlan
  try:
    plan = parseMeasurePlan(planPath)
  except CrisolError as e:
    stderr.write("crisol: compile-worker: " & e.msg & "\n")
    return 1
  except CatchableError as e:
    stderr.write("crisol: compile-worker: could not read plan '" &
                 planPath & "': " & e.msg & "\n")
    return 1

  forceMeasurementCcEnv()

  let nimVersion = captureFirstVersionLine("nim")
  let ccVersion  = captureToolchainCcVersion()   # R2 fix: folds cc AND ldd (libc)

  var cacheSucceeded = false

  try:
    let knownStrings = @[plan.nimcacheDir, plan.outputBinPath.parentDir()]
    let entryBasename = entryUnitBasename(plan.entrypointAbsPath)

    let keyOf = buildCacheKeyOf(entryBasename, knownStrings, nimVersion, ccVersion)

    # review Finding 3: resolve the CONFIGURED write-time soft-cap inputs
    # (plan.objcacheMaxEntries/objcacheMaxBytes, threaded from Config by
    # runner.buildCompileWorkerPlan) rather than letting realObjCacheSeams
    # fall back to its own hardcoded default on every call — the exact same
    # "0 == use the backstop" resolution clean.cleanOrphans already applies
    # to the identical Config fields for gcObjCache, so the write-time cap
    # and the GC-time cap agree on what "unconfigured" means.
    let resolvedMaxEntries =
      if plan.objcacheMaxEntries > 0: plan.objcacheMaxEntries
      else: DefaultMaxObjCacheEntries
    let seams = realObjCacheSeams(plan.stateDir, resolvedMaxEntries, plan.objcacheMaxBytes)
    let driver = newCacheDriver(seams, keyOf)
    let spans = runMeasured(driver, plan.entrypointAbsPath, plan.flags,
                            plan.nimcacheDir, plan.outputBinPath)

    if not spans.ok:
      stderr.write("crisol: compile-worker: cache-mode compile failed (" &
                   spans.errorMsg & "); falling back to monolithic compile\n")
    else:
      cacheSucceeded = true
      var reusableProcessed = 0
      for basename in spans.ccUnitTimesUs.keys:
        if basename != entryBasename: inc reusableProcessed
      stderr.write("crisol: objcache: " & $reusableProcessed &
                   " reusable units processed\n")

      # R16 (R9-revert): a cache-mode compile does NO compilation on a HIT,
      # so an ArtifactRow recorded here would carry ccTimeUs=0 for that
      # unit — skewing the cc-time-weighted potential-rTime and permanently
      # polluting the append-only artifact ledger (it is scanned
      # cumulatively across ALL future runs, so the pollution never self-
      # heals). R9 had this worker also call `recordArtifactRows` so a
      # single `--objcache` run could populate both sides of the M-report's
      # drift comparison; that is the bug this revert fixes. The artifact
      # ledger is now written ONLY by `measureworker.runMeasureCompileWorker`
      # (which drives a REAL, uncached compile — every unit's ccTimeUs is
      # genuine). The drift comparison (potential rTime vs realized hitRate)
      # becomes a CROSS-RUN correlation instead — see compilereport.nim's
      # module doc ("Drift tie-in") for the honest framing and the R7
      # provenance fields that make each report's scope/as-of transparent
      # enough to support it.
      try:
        recordObjCacheStatsRow(plan, spans)
      except CatchableError as e:
        stderr.write("crisol: warning: compile-worker: objcache-stats " &
                     "recording failed (binary still built): " & e.msg & "\n")
  except CatchableError as e:
    stderr.write("crisol: compile-worker: cache-mode compile raised an exception (" &
                 e.msg & "); falling back to monolithic compile\n")

  if cacheSucceeded:
    return 0

  return runMonolithicCompile(plan)
