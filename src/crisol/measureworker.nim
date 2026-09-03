## measureworker.nim — RFC-0006 M-artifact-identity: the MEASURE-mode
## compile-slot worker.
##
## crisol re-execs ITSELF as `crisol --internal-measure-compile <plan.json>`
## (RFC-0006 §Stage R "Mechanism — a crisol compile-worker child"; M-artifact-
## identity's handoff DECISION: the worker, not the parent, writes the
## ArtifactRows, since it alone holds the per-unit cc times and `.c` content).
## This module IS that worker's `main` — `runMeasureCompileWorker` — plus its
## measure-only recording steps. It ties together already-built, UNTOUCHED
## modules:
##
##   `workerplan.{MeasurePlan, parseMeasurePlan, forceMeasurementCcEnv,
##   entryUnitBasename}` — the plan schema + helpers this worker uses — see
##   workerplan.nim's own doc.
##   `compiledriver.runMeasured`  — split-compile measurement driver (M-driver)
##   `closure.parseCompileManifest` / `artifactid.{normalize,ccIncludeClosure,
##   artifactKeyHash}` — the pure identity core (pass (a))
##   `artifactledger.{openArtifactLedger,append,closeArtifactLedger}` — the
##   append-only artifact stream
##
## PASS (b1) scope originally covered only direct/test invocation against a
## hand-authored `plan.json`. Wiring it as a slot's compile CHILD —
## `runner.nim`'s `spCompiling`→`spRunning` transition spawning THIS worker
## via the existing argv-array `forkExec`, measurement-mode-gated — landed in
## PASS (b2): `runner.nim` now authors `plan.json` and dispatches this
## measurement worker.
##
## Split out of the original fused measureworker.nim (RFC-0006 review R8,
## structural-only — no behavior change): this module owns the measure-mode
## worker (`runMeasureCompileWorker` + `recordArtifactRows` +
## `recordCompileCostRow`). The plan schema + shared helpers live in
## `workerplan.nim`. (RFC-0006 Stage R's cache-mode worker, formerly in
## `cacheworker.nim`, was removed entirely — an end-to-end A/B showed the
## object cache didn't pay off on the target consumer.)
##
## ## Pipeline (`runMeasureCompileWorker`)
##
## 1. Parse `plan.json` (`workerplan.parseMeasurePlan`) — a parse/field-
##    presence failure is a hard failure (there is no entrypoint to compile
##    at all): exit non-zero, mirroring a compile failure.
## 2. Force `CCACHE_DISABLE=1` in THIS process's env
##    (`workerplan.forceMeasurementCcEnv`) — RFC-0006 §Ambient-toolchain-
##    hygiene. `startProcess` (compiledriver's `realCompileOnly`/
##    `defaultRunCc`/`realLink`) inherits the parent env whenever no explicit
##    `env` table is passed, so one `putEnv` here reaches every `nim`/`cc`/
##    link child the driver spawns.
## 3. Run `compiledriver.newMeasureDriver(workingDir = plan.projectRoot)` +
##    `runMeasured` on the entrypoint — `workingDir` (rfc-0007 A2c, issue
##    #17) makes the compile cwd-correct for a root-relative flag such as
##    `--path:src` regardless of where this worker process started. A
##    compile/link failure here IS a real failure: exit non-zero, no
##    measurement attempted (there is no manifest to read).
## 4. On a successful compile, attempt to RECORD artifact rows
##    (`recordArtifactRows`): parse the manifest, compute the reusable set
##    (every unit except the entry unit — RFC-0006 §File scoping), and for
##    each, `normalize()` + `ccIncludeClosure()` + `artifactKeyHash()`, then
##    append one `ArtifactRow` to the artifact ledger under `plan.stateDir`.
##    ANY error in this step (manifest parse, cc -M failure, ledger I/O) is
##    caught, logged to stderr, and does NOT change the exit code — a
##    measurement-layer failure must never fail a compile that actually
##    produced a runnable binary (RFC-0006's escape-hatch philosophy; this
##    describes the MEASURE-mode worker above).
## 5. Also on a successful compile, attempt to RECORD ONE compile-cost row
##    (`recordCompileCostRow`, RFC-0006 M-cost-split): the raw codegen/cc/link
##    µs split already computed by `runMeasured` into `spans`, appended to the
##    SEPARATE compile-cost stream (`compilecost.nim`) under the SAME
##    identity (`identityKey(plan.entrypointPath, plan.configHash)`)
##    `recordArtifactRows` used, so a future M-report can join the two
##    streams. Wrapped in its own try/except with the identical never-fail-
##    the-compile contract as step 4 — independent of whether step 4 itself
##    succeeded or failed.
##
## Exit status mirrors a compile: 0 iff a runnable binary was produced
## (regardless of whether recording succeeded), non-zero iff the compile
## itself failed.

import std/[os, tables, times]
import crisol/types
import crisol/keys
import crisol/closure
import crisol/compiledriver
import crisol/artifactid
import crisol/artifactledger
import crisol/compilecost
import crisol/workerplan

# ---------------------------------------------------------------------------
# recordArtifactRows — the measurement-recording step
# ---------------------------------------------------------------------------

proc recordArtifactRows(plan: MeasurePlan; spans: CompileSpans) =
  ## Compute + append one ArtifactRow per reusable unit (every generated
  ## unit in the manifest EXCEPT the entry unit — §Soundness invariant: the
  ## entry unit carries NimMain/whole-program init and stays private, never
  ## keyed). May raise (manifest parse, unexpected I/O) — the CALLER wraps
  ## this in try/except so a measurement-layer failure never fails a
  ## successful compile (see module doc).
  ##
  ## `openArtifactLedger`/`append`/`closeArtifactLedger` themselves never
  ## raise (an unwritable stateDir degrades to a silent no-op with a stderr
  ## warning) — the try/except here is defense-in-depth for
  ## `parseCompileManifest` (which DOES raise on a missing/malformed
  ## manifest) and any unexpected `readFile`/`getFileSize` failure.
  let manifestPath = plan.nimcacheDir / plan.outputBinPath.extractFilename & ".json"
  let manifest = parseCompileManifest(manifestPath)
  let entryBasename = entryUnitBasename(plan.entrypointAbsPath)
  let knownStrings = @[plan.nimcacheDir, plan.outputBinPath.parentDir()]
  let identity = identityKey(plan.entrypointPath, plan.configHash)
  let nowUs = int64(epochTime() * 1_000_000)

  var led = openArtifactLedger(plan.stateDir)
  defer: closeArtifactLedger(led)

  for pair in manifest.compile:
    let basename = pair.cPath.extractFilename
    if basename == entryBasename:
      continue  # entry unit stays private — never keyed (soundness invariant)

    var rawContent: string
    try:
      rawContent = readFile(pair.cPath)
    except CatchableError as e:
      stderr.write("crisol: warning: measure-compile: could not read '" &
                   pair.cPath & "' for artifact identity: " & e.msg & "; skipping\n")
      continue

    let normalized = normalize(rawContent, knownStrings)
    let normalizedCcCmd = normalize(pair.ccCmd, knownStrings)
    let closureRes = ccIncludeClosure(pair.ccCmd)
    if not closureRes.ok:
      stderr.write("crisol: warning: measure-compile: cc -M include-closure " &
                   "probe failed for '" & basename & "'; skipping\n")
      continue

    var sizeBytes: int64 = 0
    try:
      sizeBytes = getFileSize(pair.cPath)
    except CatchableError:
      discard  # leave 0; non-fatal (RFC's own escape-hatch philosophy)

    let row = ArtifactRow(
      entrypointIdentity: identity,
      groupId:            plan.groupId,
      configHash:         plan.configHash,
      artifactBasename:   basename,
      # R5: fold the normalized cc command so this M-key is a true PREFIX of
      # Stage-R's stageRKey (see artifactid.artifactKeyHash's module doc).
      keyHash:            artifactKeyHash(normalized, closureRes.contentHash, normalizedCcCmd),
      sizeBytes:          sizeBytes,
      ccTimeUs:           spans.ccUnitTimesUs.getOrDefault(basename, 0),
      timestamp:          nowUs,
      rowVersion:         currentArtifactRowVersion,
    )
    append(led, row)

# ---------------------------------------------------------------------------
# recordCompileCostRow — the RFC-0006 M-cost-split recording step
# ---------------------------------------------------------------------------

proc recordCompileCostRow(plan: MeasurePlan; spans: CompileSpans) =
  ## Append ONE `CompileCostRow` for this compile, carrying the raw
  ## codegen/cc/link µs split from `spans`. `entrypointIdentity` is derived
  ## EXACTLY as `recordArtifactRows` derives it (`identityKey(plan.
  ## entrypointPath, plan.configHash)`) so the two streams share identity and
  ## a future M-report can join them. May raise (unexpected ledger I/O) — the
  ## CALLER wraps this in try/except so a measurement-layer failure never
  ## fails a successful compile (mirrors `recordArtifactRows`'s own contract;
  ## see module doc).
  let identity = identityKey(plan.entrypointPath, plan.configHash)
  let nowUs = int64(epochTime() * 1_000_000)

  var led = openCompileCostLedger(plan.stateDir)
  defer: closeCompileCostLedger(led)

  let row = CompileCostRow(
    entrypointIdentity: identity,
    groupId:            plan.groupId,
    configHash:         plan.configHash,
    codegenUs:          spans.codegenSpanUs,
    ccUs:               spans.ccSpanUs,
    linkUs:             spans.linkSpanUs,
    timestamp:          nowUs,
    rowVersion:         currentCompileCostRowVersion,
  )
  append(led, row)

# ---------------------------------------------------------------------------
# runMeasureCompileWorker — the worker's main
# ---------------------------------------------------------------------------

proc runMeasureCompileWorker*(planPath: string): int =
  ## The `--internal-measure-compile <plan.json>` worker main. See module
  ## doc for the full pipeline and exit-status contract.
  var plan: MeasurePlan
  try:
    plan = parseMeasurePlan(planPath)
  except CrisolError as e:
    stderr.write("crisol: measure-compile: " & e.msg & "\n")
    return 1
  except CatchableError as e:
    stderr.write("crisol: measure-compile: could not read plan '" &
                 planPath & "': " & e.msg & "\n")
    return 1

  forceMeasurementCcEnv()

  # rfc-0007 A2c (#17): the worker's own `nim --compileOnly` must run from
  # plan.projectRoot, not wherever this worker process happens to have
  # started — see workerplan.MeasurePlan.projectRoot's doc.
  let driver = newMeasureDriver(workingDir = plan.projectRoot)
  let spans = runMeasured(driver, plan.entrypointAbsPath, plan.flags,
                          plan.nimcacheDir, plan.outputBinPath)
  if not spans.ok:
    stderr.write("crisol: measure-compile: compile failed: " & spans.errorMsg & "\n")
    return 1

  try:
    recordArtifactRows(plan, spans)
  except CatchableError as e:
    stderr.write("crisol: warning: measure-compile: artifact-identity " &
                 "recording failed (binary still built): " & e.msg & "\n")

  try:
    recordCompileCostRow(plan, spans)
  except CatchableError as e:
    stderr.write("crisol: warning: measure-compile: compile-cost " &
                 "recording failed (binary still built): " & e.msg & "\n")

  return 0
