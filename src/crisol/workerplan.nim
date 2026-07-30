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
##       `entrypointPath`    — `ep.path`, project-root-relative (see
##                              discover.nim `path: relPath`). This is the
##                              SAME string `runner.appendAttemptRow` feeds
##                              `identityKey` for `LedgerRow`, so
##                              `entrypointIdentity` (both workers) is
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
##     runner.nim:382-384), `nimcacheDir` (the private per-slot nimcache
##     dir — runner.nim's `cacheDir`), `outputBinPath` (the `-o:` path —
##     runner.nim's `binCompiled`), `groupId` (`ep.group`), `configHash`
##     (`flagHash(ep.flags)` rendered — artifactledger.nim's own doc says
##     this is exactly what `configHash` is), and `stateDir` (artifact-
##     ledger root).
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
##   `InternalMeasureCompileToken` — the internal re-exec dispatch token
##     crisol.nim's `runMain` special-cases before subcommand validation
##     (see crisol.nim's `runMain` doc). Deliberately NOT listed in
##     crisol.nim's `usage()` text: this is an internal re-exec surface, not
##     a user-facing subcommand.
##
## See docs/rfc/0006-cross-entrypoint-compile-reuse.md ("Mechanism — a
## crisol compile-worker child") and measureworker.nim's own doc for the
## pipeline this schema feeds.

import std/[json, os]
import crisol/types

# ---------------------------------------------------------------------------
# The internal dispatch token (crisol.nim routes this before normal
# subcommand validation — see crisol.nim's runMain). Deliberately NOT listed
# in crisol.nim's usage() text: this is an internal re-exec surface, not a
# user-facing subcommand.
# ---------------------------------------------------------------------------

const InternalMeasureCompileToken* = "--internal-measure-compile"

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

proc parseMeasurePlan*(jsonPath: string): MeasurePlan =
  ## Parse `jsonPath` into a MeasurePlan. Mirrors `closure.
  ## parseCompileManifest`'s error idiom: raises `CrisolError(cekEnvironment)`
  ## on a missing file, unparseable JSON, or a missing/empty required field
  ## (`entrypointPath`, `entrypointAbsPath`, `nimcacheDir`, `outputBinPath`,
  ## `stateDir`) — never a bare/uncatchable exception. `flags`/`groupId`/
  ## `configHash` default to empty when absent (a legitimately empty flag set
  ## or ungrouped entrypoint is not malformed).
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
  result.groupId    = node{"groupId"}.getStr("")
  result.configHash = node{"configHash"}.getStr("")

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
