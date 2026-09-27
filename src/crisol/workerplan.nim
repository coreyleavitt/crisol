## workerplan.nim — RFC-0006: the plan.json schema + helpers for the
## measurement compile-slot worker (crisol/measureworker.nim).
##
## This module owns the plan schema + cross-cutting helpers the measurement
## worker, crisol.nim's internal-token dispatch, and runner.nim's
## `buildCompileWorkerPlan`/`spawnCompileStable` all depend on. (The
## RFC-0006 Stage R object cache and its cache-mode compile worker were
## removed after an end-to-end A/B showed the cache didn't pay off; this
## module now serves the measurement path only.)
##
## Contents:
##
##   `MeasurePlan` / `toJson` / `parseMeasurePlan` — the plan.json schema.
##     Authored by the parent (runner.nim's `buildCompileWorkerPlan`) and
##     read by the measurement worker (`--internal-measure-compile`).
##
##     Two entrypoint-path fields are DELIBERATE, not redundant:
##
##       `entrypointPath`    — `ep.tp.display()`, project-root-relative
##                              (entrypoints are always tag-0 — see
##                              `types.Entrypoint.tp`). This is the SAME
##                              path `runner.appendAttemptRow` feeds
##                              `identityKey` for `LedgerRow`, so
##                              `entrypointIdentity` (the measurement
##                              worker's `measurePlanIdentity`) is
##                              genuinely "the same IdentityKey RunLedger
##                              rows carry" (artifactledger.nim's own doc
##                              promise) — it must NOT be the per-slot
##                              absolute path.
##       `entrypointAbsPath` — the resolved absolute path actually fed to
##                              `nim c` (mirrors runner.nim's `epAbs`, R3).
##                              Using `entrypointPath` here instead would
##                              break under any CWD other than
##                              `projectRoot`.
##
##     The remaining fields are the plan's compile/ledger/segmentation
##     inputs: `flags` (ep.flags, appended verbatim — mirrors
##     `compiledriver.nimCompileArgs`, which runner.nim's `spawnCompileStable`
##     uses for the monolithic `nim c` argv), `nimcacheDir` (the private per-slot nimcache
##     dir — runner.nim's `cacheDir`), `outputBinPath` (the `-o:` path —
##     runner.nim's `binCompiled`), `groupId` (`ep.group`), `configHash`
##     (`flagHash(ep.flags)` rendered — artifactledger.nim's own doc says
##     this is exactly what `configHash` is), `stateDir` (artifact-
##     ledger root), and `projectRoot` (rfc-0007 A2c, issue #17 —
##     `config.projectRoot`, resolved absolute by the AUTHOR, `runner.nim`'s
##     `buildCompileWorkerPlan`). Unlike `entrypointAbsPath`, `flags` is
##     appended VERBATIM, so a root-relative flag such as `--path:src` is
##     only resolved correctly if the worker's own `nim --compileOnly`
##     invocation runs FROM `projectRoot` — `measureworker.
##     runMeasureCompileWorker` passes this field straight through as
##     `compiledriver.newMeasureDriver`'s `workingDir`.
##
##   `entryUnitBasename` — the entry unit's generated basename
##     ("@m<entrypointBasename>.nim.c"), the soundness-critical
##     discriminator used to keep the per-entrypoint entry unit
##     out of any cross-entrypoint reuse accounting (RFC-0006 §File
##     scoping: the entry unit carries NimMain/whole-program init and stays
##     private, never keyed).
##
##   `forceMeasurementCcEnv` — the ambient-toolchain-hygiene helper
##     (RFC-0006 §Ambient-toolchain hygiene): forces `CCACHE_DISABLE=1` in
##     this process's env before any compiler child is spawned.
##     `os.startProcess` (compiledriver's `realCompileOnly`/`defaultRunCc`/
##     `realLink`, all called without an explicit `env` table) inherits the
##     calling process's environment, so this single `putEnv` reaches every
##     `nim`/`cc`/link child the measurement worker's driver spawns for the
##     rest of this process's lifetime. Called by
##     `measureworker.runMeasureCompileWorker` before driving its
##     `CompileDriver`.
##
##   `WorkerWarningPrefix` / `MeasureWarningPrefix` /
##     `measureWorkerWarnings` — the worker's warning lines and how the
##     parent reads them back out of its captured output to relay them
##     (R11-L6). Matches only the narrower `MeasureWarningPrefix` and
##     neutralises control/escape bytes in every matched line before
##     returning it (R15-S5) -- the caller (`runner.nim`) must also scan the
##     captured file WHOLE, never head-capped, or a large compile log drops
##     the match entirely (R15-D3).
##
##   `InternalMeasureCompileToken` — the internal re-exec dispatch token
##     crisol.nim's `runMain` special-cases before subcommand validation
##     (see crisol.nim's `runMain` doc). Deliberately NOT listed in
##     crisol.nim's `usage()` text: this is an internal re-exec surface, not
##     a user-facing subcommand.
##
## See docs/rfc/0006-cross-entrypoint-compile-reuse.md ("Mechanism — a
## crisol compile-worker child") and measureworker.nim's own doc for the
## pipeline this schema feeds.

import std/[json, os, strutils]
import crisol/types
from crisol/ccprobe import DriverSite, DriverSearch
  # `MeasurePlan.driverSite` (R10-S6); ccprobe is a pure leaf, no cycle.
export DriverSite, DriverSearch

# ---------------------------------------------------------------------------
# The internal dispatch token (crisol.nim routes this before normal
# subcommand validation — see crisol.nim's runMain). Deliberately NOT listed
# in crisol.nim's usage() text: this is an internal re-exec surface, not a
# user-facing subcommand.
# ---------------------------------------------------------------------------

const InternalMeasureCompileToken* = "--internal-measure-compile"

# ---------------------------------------------------------------------------
# The worker's warnings, as the parent reads them back (R11-L6)
# ---------------------------------------------------------------------------

const
  WorkerWarningPrefix* = "crisol: warning: "
    ## The root string every real worker warning starts with. NOT itself the
    ## match `measureWorkerWarnings` scans for (R15-S5, below): the worker's
    ## own compile subprocess (`compiledriver.defaultRunCc`'s cc phase runs
    ## with `poParentStreams` -- RFC's own §Concurrency doc -- so cc's raw
    ## output is inherited straight into the SAME captured stream this scan
    ## reads, unmediated by any crisol code) can put arbitrary attacker- or
    ## dependency-controlled text in that stream, and this short, generic
    ## string is cheap for such text to collide with by construction (a
    ## `{.emit: "#warning \"crisol: warning: ...\"".}` or similar). Kept as
    ## the shared root `MeasureWarningPrefix` is built from, and because it
    ## is still what every real warning happens to start with -- just not a
    ## safe-enough match on its own.
  MeasureWarningPrefix* = WorkerWarningPrefix & "measure-compile: "
    ## The worker's own warnings (`measureworker`) -- and, today, the ONLY
    ## prefix any real `warn()` call site in `measureworker.nim` ever writes
    ## (see that module's `WorkerWarn` doc). Longer and more specific than
    ## `WorkerWarningPrefix` alone, so `measureWorkerWarnings` matches THIS,
    ## narrowing (though, per the doc above, not eliminating) the surface a
    ## merged compiler/linker stream can spoof.

proc sanitizeRelayedLine(line: string): string =
  ## R15-S5: neutralise every C0 control byte and DEL before a line this
  ## module hands back is ever written to a real terminal. `line` was read
  ## out of a captured compile-output file that is not exclusively crisol's
  ## own writes (see `WorkerWarningPrefix`'s doc) -- ESC (0x1B) in particular
  ## can smuggle an arbitrary terminal escape sequence through what looks
  ## like an ordinary one-line warning relay (cursor moves, screen/scrollback
  ## clears, title-bar or clipboard writes on terminals that honor OSC).
  ## `splitLines` has already stripped the line's own trailing EOL, so this
  ## never needs to preserve one.
  result = newStringOfCap(line.len)
  for ch in line:
    if ch.ord < 0x20 or ch.ord == 0x7f:
      result.add '?'
    else:
      result.add ch

proc measureWorkerWarnings*(workerOutput: string): seq[string] =
  ## The warning lines in a measurement worker's captured output, in order:
  ## what the parent relays to its own stderr after a successful measure
  ## compile, whose output is otherwise discarded, so a unit the worker
  ## could not record (an unresolved driver, a failed header probe, an
  ## unwritable ledger) is not dropped from the artifact ledger silently.
  ## A failed compile's output is shown whole and needs no relay.
  ##
  ## R15-S5: matches `MeasureWarningPrefix`, not the shorter/generic
  ## `WorkerWarningPrefix` -- see that constant's doc for why the shorter one
  ## is not a safe-enough match on a stream that is not exclusively crisol's
  ## own writes -- and every matched line is passed through
  ## `sanitizeRelayedLine` before being returned, so a control/escape byte
  ## that made it past the (narrower) prefix match still cannot reach a
  ## terminal unneutralised.
  for line in workerOutput.splitLines:
    if line.startsWith(MeasureWarningPrefix):
      result.add sanitizeRelayedLine(line)

# ---------------------------------------------------------------------------
# MeasurePlan — plan.json schema
# ---------------------------------------------------------------------------

type
  MeasurePlan* = object
    entrypointPath*:    string       ## ep.path — project-root-relative; IDENTITY input
    entrypointAbsPath*: string       ## resolved absolute path actually compiled
    flags*:             seq[string]  ## ep.flags, appended verbatim
    nimcacheDir*:        string      ## private per-slot nimcache dir (== known cacheDir string)
    outputBinPath*:      string      ## -o: path (parentDir == known binDir string)
    groupId*:            string      ## ep.group — segmentation
    configHash*:         string      ## flagHash(ep.flags) rendered — segmentation
    stateDir*:           string      ## artifact-ledger root
    projectRoot*:        string      ## rfc-0007 A2c (#17): resolved absolute
                                      ## config.projectRoot — the worker's own
                                      ## `nim --compileOnly` cwd
    toolchainFp*:        string      ## W9l: planner.toolchainFingerprint(nimVersion,
                                      ## ccVersion), computed ONCE by the parent
                                      ## (runner.execute's ExecCtx.toolchainFp) and
                                      ## passed down — the worker must NEVER re-probe
                                      ## ccVersion itself (ccidentity.cachedToolchainProbe() is
                                      ## deliberately not imported/called here; see
                                      ## runner.buildCompileWorkerPlan's W9l doc: the
                                      ## value is the SAME one execute() already keys
                                      ## the persistent nimcache with). Threaded
                                      ## straight through into the ArtifactRow/
                                      ## CompileCostRow rows the worker records, so
                                      ## `--measure-compile-reuse` aggregation can tell
                                      ## a toolchain upgrade apart from a code change.
                                      ## OPTIONAL on read (defaults to "") for the same
                                      ## back-compat reason `groupId`/`configHash` are.
    driverSite*:         DriverSite
                                      ## R10-S6: where the build's nim finds its
                                      ## compilers (`ccidentity.ToolchainProbe.site`),
                                      ## learned ONCE by the parent for the same W9l
                                      ## reason as `toolchainFp`: the worker's header
                                      ## probes (`artifactid.ccIncludeClosure`) resolve
                                      ## each compile command's own driver token
                                      ## against it (`headerprobe.siteResolver`),
                                      ## never by the worker's own search, and the
                                      ## worker never re-runs the discovery. Absent on
                                      ## read, or malformed, parses as unknown: every
                                      ## probe then refuses and no artifact row is
                                      ## recorded (fail closed).

proc toJson*(plan: MeasurePlan): JsonNode =
  ## Serialize a MeasurePlan to plan.json's JSON shape. Exported so the
  ## worker's parent (`runner.nim`) and the worker's own tests can author a
  ## `plan.json` without hand-building JSON.
  result = newJObject()
  result["entrypointPath"]    = newJString(plan.entrypointPath)
  result["entrypointAbsPath"] = newJString(plan.entrypointAbsPath)
  var flagsArr = newJArray()
  for f in plan.flags:
    flagsArr.add newJString(f)
  result["flags"]         = flagsArr
  result["nimcacheDir"]   = newJString(plan.nimcacheDir)
  result["outputBinPath"] = newJString(plan.outputBinPath)
  result["groupId"]       = newJString(plan.groupId)
  result["configHash"]    = newJString(plan.configHash)
  result["stateDir"]      = newJString(plan.stateDir)
  result["projectRoot"]   = newJString(plan.projectRoot)
  result["toolchainFp"]   = newJString(plan.toolchainFp)
  var site = newJObject()
  site["known"] = newJBool(plan.driverSite.known)
  if plan.driverSite.known:
    site["nimExe"]     = newJString(plan.driverSite.nimExe)
    site["nimCwd"]     = newJString(plan.driverSite.nimCwd)
    site["search"]     = newJString($plan.driverSite.search)
    site["pathVar"]    = newJString(plan.driverSite.pathVar)
    site["systemRoot"] = newJString(plan.driverSite.systemRoot)
  else:
    site["why"] = newJString(plan.driverSite.why)
  result["driverSite"] = site

proc parseDriverSite(site: JsonNode): DriverSite =
  ## `toJson`'s `driverSite` object back; unknown, with a reason, when it
  ## is absent or malformed.
  proc unknown(): DriverSite =
    let why = if site != nil and site.kind == JObject: site{"why"}.getStr("") else: ""
    DriverSite(known: false, why:
      (if why.len > 0: why
       else: "the measure-compile plan carries no usable C compiler driver site"))
  if site == nil or site.kind != JObject or not site{"known"}.getBool(false):
    return unknown()
  for key in ["nimExe", "nimCwd", "search", "pathVar", "systemRoot"]:
    if site{key} == nil or site{key}.kind != JString: return unknown()
  var search: DriverSearch
  case site{"search"}.getStr("")
  of $dsPosix: search = dsPosix
  of $dsWindows: search = dsWindows
  else: return unknown()
  DriverSite(known: true, nimExe: site{"nimExe"}.getStr(""),
             nimCwd: site{"nimCwd"}.getStr(""), search: search,
             pathVar: site{"pathVar"}.getStr(""),
             systemRoot: site{"systemRoot"}.getStr(""))

proc parseMeasurePlan*(jsonPath: string): MeasurePlan =
  ## Parse `jsonPath` into a MeasurePlan. Mirrors `closure.
  ## parseCompileManifest`'s error idiom: raises `CrisolError(cekEnvironment)`
  ## on a missing file, unparseable JSON, or a missing/empty required field
  ## (`entrypointPath`, `entrypointAbsPath`, `nimcacheDir`, `outputBinPath`,
  ## `stateDir`, `projectRoot`) — never a bare/uncatchable exception.
  ## `flags`/`groupId`/`configHash` default to empty when absent (a
  ## legitimately empty flag set or ungrouped entrypoint is not malformed).
  if not fileExists(jsonPath):
    raise newCrisolError(cekEnvironment,
      "measure-compile plan not found: " & jsonPath)

  var node: JsonNode
  try:
    node = parseJson(readFile(jsonPath))
  except CatchableError as e:
    raise newCrisolError(cekEnvironment,
      "failed to parse measure-compile plan at " & jsonPath & ": " & e.msg)

  if node.kind != JObject:
    raise newCrisolError(cekEnvironment,
      "measure-compile plan at " & jsonPath & " is not a JSON object")

  proc reqStr(key: string): string =
    let v = node{key}.getStr("")
    if v.len == 0:
      raise newCrisolError(cekEnvironment,
        "measure-compile plan at " & jsonPath & " missing required field '" & key & "'")
    v

  result.entrypointPath    = reqStr("entrypointPath")
  result.entrypointAbsPath = reqStr("entrypointAbsPath")
  result.nimcacheDir       = reqStr("nimcacheDir")
  result.outputBinPath     = reqStr("outputBinPath")
  result.stateDir          = reqStr("stateDir")
  result.projectRoot       = reqStr("projectRoot")
  result.groupId    = node{"groupId"}.getStr("")
  result.configHash = node{"configHash"}.getStr("")
  # W9l: OPTIONAL -- a plan.json authored before this field existed (or a
  # hand-built test fixture) parses with toolchainFp == "" rather than
  # failing required-field validation.
  result.toolchainFp = node{"toolchainFp"}.getStr("")
  # R10-S6: anything but a known site whose every field is a string and
  # whose search rule is one this build knows is unknown.
  result.driverSite = parseDriverSite(node{"driverSite"})

  result.flags = @[]
  let flagsNode = node{"flags"}
  if flagsNode != nil and flagsNode.kind == JArray:
    for f in flagsNode:
      if f.kind == JString:
        result.flags.add f.getStr("")

# ---------------------------------------------------------------------------
# Ambient-toolchain hygiene (RFC-0006 §Ambient-toolchain hygiene)
# ---------------------------------------------------------------------------

proc forceMeasurementCcEnv*() =
  ## Force `CCACHE_DISABLE=1` in THIS process's environment before any
  ## compiler child is spawned. `os.startProcess` (compiledriver's
  ## `realCompileOnly`/`defaultRunCc`/`realLink`, all called without an
  ## explicit `env` table) inherits the calling process's environment, so
  ## this single `putEnv` reaches every `nim`/`cc`/link child the
  ## measurement worker's driver spawns for the rest of this process's
  ## lifetime — without threading an env parameter through
  ## `compiledriver.nim`. Called by
  ## `measureworker.runMeasureCompileWorker`. Exported as a focused,
  ## independently-testable seam.
  putEnv("CCACHE_DISABLE", "1")

# ---------------------------------------------------------------------------
# Reusable-set discrimination (RFC-0006 §File scoping)
# ---------------------------------------------------------------------------

proc entryUnitBasename*(entrypointAbsPath: string): string =
  ## The entry unit's generated basename: "@m<entrypointBasename>.nim.c",
  ## where entrypointBasename is the entrypoint's own filename with its
  ## extension stripped. Mirrors tests/unit/test_golden_reuse.nim's
  ## `entryBasenameFor` — the RFC's own anchor for this rule (RFC-0006
  ## §File scoping: "the one whose basename matches the entrypoint's own
  ## filename"). Used by `measureworker.recordArtifactRows` to exclude the
  ## entry unit from artifact-identity recording.
  "@m" & entrypointAbsPath.extractFilename.changeFileExt("") & ".nim.c"
