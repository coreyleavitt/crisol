## workerplan.nim — RFC-0006: the plan.json schema + helpers SHARED by both
## RFC-0006 compile-slot workers (crisol/measureworker.nim's MEASURE-mode
## worker and crisol/cacheworker.nim's CACHE-mode worker).
##
## Split out of the original fused measureworker.nim (RFC-0006 review R8,
## structural-only): this module owns the plan schema + cross-cutting
## helpers both workers, AND both external authors (crisol.nim's internal-
## token dispatch; runner.nim's `buildCompileWorkerPlan`/`spawnCompileStable`)
## depend on — so neither worker module needs to import the other's
## internals just to share a type, and crisol.nim/runner.nim don't need to
## pick one worker module arbitrarily to get the schema.
##
## Contents:
##
##   `MeasurePlan` / `toJson` / `parseMeasurePlan` — the plan.json schema.
##     Authored by the parent (runner.nim's `buildCompileWorkerPlan`) and
##     read by whichever worker the parent dispatches to
##     (`--internal-measure-compile` or `--internal-compile-worker`) — NO
##     schema difference between the two modes (RFC-0006 R2b1: "no schema
##     change: R2b1's plan carries exactly what measure mode's plan
##     carries" — pinned by test_measureworker.nim's round-trip test).
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
##     `objcacheMaxEntries` / `objcacheMaxBytes` (review Finding 3) — the
##     CACHE-mode worker's own write-time soft-cap inputs, threaded from
##     `Config.objcacheMaxEntries`/`Config.objcacheMaxBytes` at plan-build
##     time (`runner.buildCompileWorkerPlan`) so `cacheworker.
##     runCompileCacheWorker` can pass the user's CONFIGURED caps into
##     `objcache.realObjCacheSeams`/`storeObject`, instead of that call
##     silently falling back to the hardcoded `DefaultMaxObjCacheEntries`
##     (10 000) and an unbounded byte cap regardless of `crisol.kdl`. Both
##     default to `0` in an unset/default-constructed `MeasurePlan` — the
##     SAME "0" a fresh `Config` carries for these fields — and are resolved
##     to their real meaning at the point they're actually consulted
##     (`cacheworker.nim`), mirroring `clean.cleanOrphans`'s own resolution
##     of the identical `Config` fields for `gcObjCache`: `objcacheMaxEntries
##     == 0` means "use the `DefaultMaxObjCacheEntries` backstop" (an
##     unconfigured cap is not the same as "no cap" — the write path must
##     still have SOME bound), while `objcacheMaxBytes == 0` means "no byte
##     bound" (an unconfigured byte cap genuinely means unbounded — there
##     was never an automatic byte bound before this fields existed, so "0"
##     preserves that as the explicit default rather than inventing one).
##     The measure-mode worker never reads either field (it never calls
##     `objcache.storeObject`).
##
##   `entryUnitBasename` — the entry unit's generated basename
##     ("@m<entrypointBasename>.nim.c"), the soundness-critical
##     discriminator BOTH workers use to keep the per-entrypoint entry unit
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
##     `nim`/`cc`/link child either worker's driver spawns for the rest of
##     this process's lifetime. Called by BOTH workers before driving their
##     respective `CompileDriver`.
##
##   `InternalMeasureCompileToken` / `InternalCompileWorkerToken` — the two
##     internal re-exec dispatch tokens crisol.nim's `runMain` special-cases
##     before subcommand validation (see crisol.nim's `runMain` doc).
##     Deliberately NOT listed in crisol.nim's `usage()` text: these are
##     internal re-exec surfaces, not user-facing subcommands (RFC-0006
##     §Stage R "Mechanism").
##
## See docs/rfc/0006-cross-entrypoint-compile-reuse.md ("Mechanism — a
## crisol compile-worker child") and each worker module's own doc
## (measureworker.nim / cacheworker.nim) for the per-mode pipeline this
## schema feeds.

import std/[json, os]
import crisol/types

# ---------------------------------------------------------------------------
# The internal dispatch tokens (crisol.nim routes these before normal
# subcommand validation — see crisol.nim's runMain). Deliberately NOT listed
# in crisol.nim's usage() text: these are internal re-exec surfaces, not
# user-facing subcommands (RFC-0006 §Stage R "Mechanism").
# ---------------------------------------------------------------------------

const InternalMeasureCompileToken* = "--internal-measure-compile"
const InternalCompileWorkerToken* = "--internal-compile-worker"

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
    objcacheMaxEntries*: int         ## review Finding 3: Config.objcacheMaxEntries,
                                      ## threaded to the cache worker's write-time soft
                                      ## cap. 0 = use DefaultMaxObjCacheEntries backstop
                                      ## (matches clean.cleanOrphans's resolution).
    objcacheMaxBytes*:   int64       ## review Finding 3: Config.objcacheMaxBytes,
                                      ## threaded to the cache worker's write-time soft
                                      ## cap. 0 = unbounded (matches gcObjCache's own
                                      ## maxBytes convention).

proc toJson*(plan: MeasurePlan): JsonNode =
  ## Serialize a MeasurePlan to plan.json's JSON shape. Exported so a
  ## worker's parent (`runner.nim`) and both workers' own tests can author a
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
  result["objcacheMaxEntries"] = newJInt(plan.objcacheMaxEntries)
  result["objcacheMaxBytes"]   = newJInt(plan.objcacheMaxBytes)

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
  # review Finding 3: absent -> 0 (legitimately "unconfigured", the SAME
  # meaning a fresh Config carries for these fields — not malformed).
  result.objcacheMaxEntries = node{"objcacheMaxEntries"}.getInt(0)
  result.objcacheMaxBytes   = node{"objcacheMaxBytes"}.getBiggestInt(0)

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
  ## this single `putEnv` reaches every `nim`/`cc`/link child either
  ## worker's driver spawns for the rest of this process's lifetime —
  ## without threading an env parameter through `compiledriver.nim`. Called
  ## by BOTH `measureworker.runMeasureCompileWorker` and
  ## `cacheworker.runCompileCacheWorker`. Exported as a focused,
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
  ## filename"). Used by BOTH workers: `measureworker.recordArtifactRows`
  ## (to exclude the entry unit from artifact-identity recording) and
  ## `cacheworker.buildCacheKeyOf`/`recordObjCacheStatsRow` (to keep the
  ## entry unit non-cacheable).
  "@m" & entrypointAbsPath.extractFilename.changeFileExt("") & ".nim.c"
