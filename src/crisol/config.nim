## config.nim — crisol.kdl config loading (C1)
##
## `loadConfig` resolves a `crisol.kdl` file (explicit path, walk-up
## from cwd, or convention fallback) and returns a validated `Config`.
##
## ## Config-file format  (KDL v2, parsed by nkdl)
##
## ```kdl
## // optional globals — all are optional; omit any to use the default
## jobs 8
## timeout-secs 300
## compile-timeout-secs 600
## max-output-bytes 10485760
## state-dir ".crisol"
## flags "-d:release" "--mm:orc"        // repeated node = more global flags
## dep-roots "../sibling/src"           // repeated node = more dep roots
## quarantine "tests/integration/test_x.nim"  // B3: failure excluded from exit-1
## rlimit-nofile 2048                   // Fix 1: override sandbox RLIMIT_NOFILE (default 1024)
## verify-cache-pct 5                   // RFC-0005 B3c: --verify-cache sample-percent default
## explain-miss #true                   // RFC-0005 B1c: ↔ --explain-miss (config < CLI;
##                                       // --explain-miss-verbose is CLI-only, no KDL key)
## cache-stats #true                     // RFC-0005 B2b: ↔ --cache-stats (config < CLI)
## env-pin "USER" "ci-runner"            // RFC-0005 A0: pin NAME=VALUE into every child env
##                                       // (repeatable node = more pins); the pinned value,
##                                       // not the host's own, enters the soundness key.
##
## group "unit" {
##     globs "tests/unit/test_*.nim"
## }
## group "integration" {
##     opt-in #true
##     gate "MY_ENV_VAR"               // env-gate arg = env-var name
##     timeout-secs 120
##     flags "-d:integration"
##     globs "tests/integration/test_*.nim" "tests/integration/**/it_*.nim"
## }
##
## remote-cache "team-s3" {              // RFC-0005 A3c-i: a named tier appended after
##                                       // local L1; repeatable, order-preserving
##     url "s3://ci-cache/crisol"       // required; SCHEME selects the adapter, validated
##                                       // against types.knownCacheSchemes (file/http/
##                                       // https/s3 -- memory:// is a config error here)
##     endpoint "http://minio.local:9000"  // RFC-0005 C3a: s3 only; absent = AWS default host
##     path-style #true                 // RFC-0005 C3a: s3 only; default #true iff endpoint set
##     verify-trust #true               // optional; absent = policy != "none" default,
##                                       // resolved by configuredCache (A3c-ii). Unsigned
##                                       // s3:// with no verifying policy is a config error
##                                       // (RFC-0005 C3a §Secure-by-default).
##     backfill-on-hit #true            // optional; KDL default #true
## }
## remote-cache "mirror" {
##     url "https://cache.example.com/crisol"  // http: bearer token from
##                                       // $CRISOL_CACHE_TOKEN_MIRROR (or $CRISOL_CACHE_TOKEN)
##                                       // -- RFC-0005 C3b; never in config, env only
## }
## // --no-remote-cache (CLI-only, no KDL key -- a config-file remote-cache
## // block describes what a fleet SHOULD use, not a one-run override) drops
## // every configured remote-cache tier for one run; l1 stays active.
##
## cache-trust {                         // RFC-0005 C4/C5a: CACHE-GLOBAL (one
##                                       // policy per TieredCache); optional,
##                                       // default policy "none"
##     policy "ed25519"                 // none | hmac | ed25519
##     key-id "ci-2026"                 // hmac only: the operator-chosen signer label,
##                                       // bound into the signed envelope; the secret
##                                       // itself is NEVER in config -- $CRISOL_CACHE_HMAC_KEY
##     pinned-key "MCowBQ...="          // ed25519 only; repeatable -- one base64
##                                       // ed25519 public key per node; policy
##                                       // "ed25519" with zero pinned-keys is a
##                                       // config error. Signing (if any) uses
##                                       // $CRISOL_CACHE_SIGN_KEY (base64 of the
##                                       // 32-byte seed) -- absent, this host
##                                       // still verifies (read-only participant).
## }
## ```
##
## ## Design notes
##
## - **DOM walk** (nkdl `parse` → `KdlDoc`) rather than typed decode: the
##   top-level KDL is a heterogeneous node list that doesn't collapse into a
##   single typed object.  `types.nim` stays free of nkdl pragmas.
## - **Flag merge**: `Group.flags` = globalFlags ++ groupFlags (global first,
##   group last-wins, matching Nim CLI precedence per RFC §Compile-flag
##   precedence).  The merge happens here so downstream (discover, plan) just
##   reads `group.flags`.
## - **Errors**: parse/validation failures raise `CrisolError(cekConfig)`.
##   A missing config (no `--config`, no file found) is NOT an error.

import std/[os, options, sets, strutils]
import nkdl
import crisol/types

# ---------------------------------------------------------------------------
# stateDirOf — single authoritative resolver for crisol's on-disk state dir
# ---------------------------------------------------------------------------

proc stateDirOf*(cfg: Config): string =
  ## Single source of truth for crisol's on-disk state directory (absolute).
  ## CRISOL_STATE_DIR, when set, OVERRIDES the config's project-root-relative
  ## `state-dir` — this is how a sandboxed container redirects crisol's build
  ## cache onto a mounted volume (e.g. /cache/crisol) that lives outside the
  ## project tree. Resolution order:
  ##   1. CRISOL_STATE_DIR set (non-empty) -> absolutePath(env)
  ##   2. cfg.stateDir empty -> "" (caller signalled "no state dir"; e.g. some
  ##      runEntrypoint callers leave it unset and want the ledger disabled)
  ##   3. cfg.stateDir absolute -> use as-is
  ##   4. otherwise -> absolutePath(cfg.projectRoot / cfg.stateDir)
  let env = getEnv("CRISOL_STATE_DIR")
  if env.len > 0: return absolutePath(env)
  if cfg.stateDir.len == 0: return ""
  if cfg.stateDir.isAbsolute: return cfg.stateDir
  absolutePath(cfg.projectRoot / cfg.stateDir)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const DefaultTimeoutSecs*        = 300
const DefaultCompileTimeoutSecs* = 600
const DefaultMaxOutputBytes*     = 10 * 1024 * 1024   # 10 MiB
const DefaultStateDir*           = ".crisol"
const DefaultVerifyCachePct*     = 5   # RFC-0005 B3c: --verify-cache-pct's default;
                                        # matches api.verifySample's own pct default.

let DefaultGroups*: seq[Group] = @[
  Group(name: "unit",        globs: @["tests/unit/test_*.nim"]),
  Group(name: "integration", globs: @["tests/integration/test_*.nim"]),
]

# ---------------------------------------------------------------------------
# Convention-fallback config (no crisol.kdl found)
# ---------------------------------------------------------------------------

proc conventionConfig(root: string): Config =
  Config(
    groups:             DefaultGroups,
    jobs:               0,
    timeoutSecs:        DefaultTimeoutSecs,
    compileTimeoutSecs: DefaultCompileTimeoutSecs,
    maxOutputBytes:     DefaultMaxOutputBytes,
    stateDir:           DefaultStateDir,
    projectRoot:        root,
    perfCheck:          PerfCheckConfig(enabled: false),
    reuseCheck:         ReuseCheckConfig(enabled: false),
    verifyCachePct:     DefaultVerifyCachePct,
    workerBinary:       "",
  )

# ---------------------------------------------------------------------------
# Walk-up: search for crisol.kdl from startDir upward → "" if not found
# ---------------------------------------------------------------------------

proc findConfigFile(startDir: string): string =
  var dir = absolutePath(startDir)
  while true:
    let candidate = dir / "crisol.kdl"
    if fileExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir: break
    dir = parent
  ""

# ---------------------------------------------------------------------------
# Walk-up: find nearest enclosing .git dir → "" if not found
# ---------------------------------------------------------------------------

proc findGitRoot(startDir: string): string =
  var dir = absolutePath(startDir)
  while true:
    if dirExists(dir / ".git") or fileExists(dir / ".git"):
      return dir
    let parent = parentDir(dir)
    if parent == dir: break
    dir = parent
  ""

# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------

proc cfgErr(msg: string) {.noReturn.} =
  raise newCrisolError(cekConfig, msg)

proc validateStateDir(dir: string) =
  ## Reject any state-dir that is absolute or contains ".." components.
  ## Both forms can redirect crisol's entire state tree outside the project
  ## root via os.joinPath's "absolute second operand replaces first" semantics.
  if isAbsolute(dir):
    cfgErr("config: 'state-dir' must be a relative path, got '" & dir & "'")
  # Split on both / and \\ (portable) and scan for ".." components.
  let parts = dir.replace("\\", "/").split("/")
  for p in parts:
    if p == "..":
      cfgErr("config: 'state-dir' must not contain '..' path components, got '" & dir & "'")

proc requireIntArg(n: KdlNode; label: string): int =
  let v = n.arg(0)
  if v.isNone:
    cfgErr("config: '" & label & "' requires an integer argument")
  case v.get.kind
  of kvBigInt:
    cfgErr("config: '" & label & "' value is too large (overflows 64-bit integer)")
  of kvInt:
    discard
  else:
    cfgErr("config: '" & label & "' requires an integer argument")
  int(v.get.intVal)

proc requireFloatArg(n: KdlNode; label: string): float =
  ## Like requireIntArg but accepts a float or integer KDL argument.
  ## Returns a float64.  Malformed → cfgErr.
  let v = n.arg(0)
  if v.isNone:
    cfgErr("config: '" & label & "' requires a numeric argument")
  case v.get.kind
  of kvFloat:
    result = v.get.floatVal
  of kvInt:
    result = float(v.get.intVal)
  of kvBigInt:
    cfgErr("config: '" & label & "' value is too large")
  else:
    cfgErr("config: '" & label & "' requires a numeric argument")

proc requireStrArg(n: KdlNode; idx: int; label: string): string =
  let v = n.arg(idx)
  if v.isNone or v.get.kind != kvString:
    cfgErr("config: '" & label & "' argument " & $idx & " must be a string")
  v.get.strVal

proc collectStrArgs(n: KdlNode; label: string): seq[string] =
  for v in n.arguments:
    if v.kind != kvString:
      cfgErr("config: '" & label & "' arguments must be strings, got " & $v.kind)
    result.add v.strVal

# ---------------------------------------------------------------------------
# Parse a single `group` node → Group  (globalFlags already collected)
# ---------------------------------------------------------------------------

proc makeConfigWarning(source, context, key: string): ConfigWarning =
  ## Compose a ConfigWarning with a pre-formatted human message.
  ConfigWarning(
    source:  source,
    context: context,
    key:     key,
    message: "unknown config key '" & key & "' in " & context & " (ignored)",
  )

proc parseGroup(n: KdlNode; globalFlags: seq[string];
                source: string; warns: var seq[ConfigWarning]): Group =
  ## Parse a `group` DOM node → crisol Group.
  ##
  ## The group node format is:
  ##   group "name" {
  ##       opt-in #true          // child node with bool arg
  ##       gate "ENV_VAR"        // child node with string arg
  ##       timeout-secs 120      // child node with int arg
  ##       flags "-d:foo"        // child node with variadic string args
  ##       globs "tests/**/*.nim"// child node with variadic string args
  ##   }
  if n.arg(0).isNone or n.arg(0).get.kind != kvString:
    cfgErr("config: 'group' requires a string name as its first argument")
  let name = n.arg(0).get.strVal
  if name.len == 0:
    cfgErr("config: group name must not be empty")

  var optIn:       bool = false
  var timeoutSecs: int  = 0
  var maxJobs:     Option[int]
  var globs:       seq[string]
  var groupFlags:  seq[string]
  var gate:        Option[Gate]
  var cacheable:   CacheableState = csDefault
  var retries:     int  = 0

  for child in n.children:
    case child.name
    of "opt-in":
      # child node: opt-in #true  or  opt-in #false
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: group '" & name & "': 'opt-in' requires a boolean argument (#true/#false)")
      optIn = v.get.boolVal
    of "timeout-secs":
      # child node: timeout-secs 120
      timeoutSecs = requireIntArg(child, "group '" & name & "': 'timeout-secs'")
      if timeoutSecs < 0:
        cfgErr("config: group '" & name & "': timeout-secs must be >= 0")
    of "max-jobs":
      # child node: max-jobs N  (N >= 1; 0 or negative is a config error)
      # Absence → none (uncapped). some(1) = serial. some(N) = cap at N.
      # 0 is NOT "uncapped" — absence is the only way to express uncapped.
      let cap = requireIntArg(child, "group '" & name & "': 'max-jobs'")
      if cap <= 0:
        cfgErr("config: group '" & name & "': max-jobs must be >= 1 (use absence to express uncapped)")
      maxJobs = some(cap)
    of "globs":
      globs.add collectStrArgs(child, "globs (group '" & name & "')")
    of "flags":
      groupFlags.add collectStrArgs(child, "flags (group '" & name & "')")
    of "gate":
      if gate.isSome:
        cfgErr("config: group '" & name & "' has duplicate 'gate' entries")
      if child.arg(0).isNone or child.arg(0).get.kind != kvString:
        cfgErr("config: group '" & name & "': 'gate' requires a string env-var name")
      let env = child.arg(0).get.strVal.strip()
      if env.len == 0:
        cfgErr("config: group '" & name & "': gate env-var name must not be empty")
      gate = some(Gate(env: env))
    of "cacheable":
      # child node: cacheable #true  or  cacheable #false  (absent = csDefault)
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: group '" & name & "': 'cacheable' requires a boolean argument (#true/#false)")
      cacheable = if v.get.boolVal: csTrue else: csFalse
    of "retries":
      # child node: retries N  (N >= 0)
      let v = requireIntArg(child, "group '" & name & "': 'retries'")
      if v < 0:
        cfgErr("config: group '" & name & "': retries must be >= 0, got " & $v)
      retries = v
    else:
      warns.add makeConfigWarning(source, name, child.name)

  if globs.len == 0:
    cfgErr("config: group '" & name & "' has no 'globs' — at least one glob is required")

  # Flag merge: global first, group last (last-wins, RFC §Compile-flag precedence)
  Group(
    name:        name,
    globs:       globs,
    flags:       globalFlags & groupFlags,
    optIn:       optIn,
    gate:        gate,
    timeoutSecs: timeoutSecs,
    maxJobs:     maxJobs,
    cacheable:   cacheable,
    retries:     retries,
  )

# ---------------------------------------------------------------------------
# RFC-0005 A3c-i: parse a single `remote-cache` node → RemoteTier
# ---------------------------------------------------------------------------

proc parseRemoteCache(n: KdlNode; source: string;
                      warns: var seq[ConfigWarning]): RemoteTier =
  ## Parse a `remote-cache "<name>" { ... }` DOM node → RemoteTier.
  ## Modelled on `parseGroup` — `n.children` makes it trivial.
  ##
  ##   remote-cache "team-s3" {
  ##       url "file:///mnt/shared/crisol"   // required; scheme selects the adapter
  ##       verify-trust #true                // optional; absent = none(bool) — the
  ##                                          // config-layer default (policy != "none")
  ##                                          // is resolved by configuredCache (A3c-ii),
  ##                                          // NOT here.
  ##       backfill-on-hit #true             // optional; KDL default #true
  ##   }
  ##
  ## A3c-i scope only: `endpoint`/`path-style` (s3-only) arrive in C3a, and
  ## scheme-allowlist validation (`memory://` etc. as a config error) is also
  ## C3a's job — this proc only rejects a url with no scheme at all.
  ##
  ## RFC-0005 C3a: `endpoint`/`path-style` (s3-only settings, harmless if
  ## present on a non-s3 remote — nothing reads them) and scheme-allowlist
  ## validation against `types.knownCacheSchemes` (`memory://` etc. ⇒
  ## config error even though `cacheregistry.testRegistry()` resolves it —
  ## see that const's doc comment).
  if n.arg(0).isNone or n.arg(0).get.kind != kvString:
    cfgErr("config: 'remote-cache' requires a string name as its first argument")
  let name = n.arg(0).get.strVal
  if name.len == 0:
    cfgErr("config: remote-cache name must not be empty")

  var url: Option[string]
  var endpoint: Option[string]
  var pathStyle: Option[bool]
  var verifyTrust: Option[bool]
  var backfillOnHit = true  # KDL default #true

  for child in n.children:
    case child.name
    of "url":
      if url.isSome:
        cfgErr("config: remote-cache '" & name & "' has duplicate 'url' entries")
      url = some(requireStrArg(child, 0, "remote-cache '" & name & "': 'url'"))
    of "endpoint":
      if endpoint.isSome:
        cfgErr("config: remote-cache '" & name & "' has duplicate 'endpoint' entries")
      endpoint = some(requireStrArg(child, 0, "remote-cache '" & name & "': 'endpoint'"))
    of "path-style":
      # child node: path-style #true  or  path-style #false
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: remote-cache '" & name & "': 'path-style' requires a boolean argument (#true/#false)")
      pathStyle = some(v.get.boolVal)
    of "verify-trust":
      # child node: verify-trust #true  or  verify-trust #false
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: remote-cache '" & name & "': 'verify-trust' requires a boolean argument (#true/#false)")
      verifyTrust = some(v.get.boolVal)
    of "backfill-on-hit":
      # child node: backfill-on-hit #true  or  backfill-on-hit #false
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: remote-cache '" & name & "': 'backfill-on-hit' requires a boolean argument (#true/#false)")
      backfillOnHit = v.get.boolVal
    else:
      warns.add makeConfigWarning(source, "remote-cache " & name, child.name)

  if url.isNone or url.get.len == 0:
    cfgErr("config: remote-cache '" & name & "' has no 'url' — a url is required")
  let schemeIdx = url.get.find("://")
  if schemeIdx <= 0:
    cfgErr("config: remote-cache '" & name & "': 'url' must include a scheme " &
           "(e.g. 'file://', 'https://'), got '" & url.get & "'")
  let scheme = url.get[0 ..< schemeIdx]
  if scheme notin knownCacheSchemes:
    cfgErr("config: remote-cache '" & name & "': unsupported url scheme '" & scheme &
           "' in '" & url.get & "' (expected one of: " & knownCacheSchemes.join(", ") & ")")

  RemoteTier(
    name:          name,
    url:           url.get,
    endpoint:      endpoint,
    pathStyle:     pathStyle,
    verifyTrust:   verifyTrust,
    backfillOnHit: backfillOnHit,
  )

# ---------------------------------------------------------------------------
# RFC-0005 C4: parse the CACHE-GLOBAL `cache-trust` block → TrustConfig
# ---------------------------------------------------------------------------

proc parseCacheTrust(n: KdlNode; source: string;
                     warns: var seq[ConfigWarning]): TrustConfig =
  ## Parse the `cache-trust { ... }` DOM node → TrustConfig.
  ##
  ##   cache-trust {
  ##       policy "hmac"      // required domain: none | hmac | ed25519
  ##       key-id "ci-2026"   // hmac only; optional (empty string if absent)
  ##   }
  ##
  ## RFC-0005 C5a: `pinned-key` (ed25519, repeatable, order-preserving) is
  ## the RAW base64 config string, unvalidated here -- decoding it into a
  ## `PublicKey` (rejecting a malformed entry) is `cacheregistry.
  ## buildTrustPolicy`'s job, the same layering `RemoteTier.url`'s scheme
  ## validation already uses (`config.nim` must not import the cache
  ## modules).
  ##
  ## Cross-field rejections that need MORE than this block alone (hmac
  ## with no `$CRISOL_CACHE_HMAC_KEY`; ed25519 with zero `pinned-key`s; an
  ## explicit `verify-trust #true` under policy "none") are
  ## `configuredCache`'s job (`cacheregistry.nim`) -- see that module's
  ## doc comment ("Misconfiguration is a config error, not a silent dead
  ## tier").
  var policy = "none"  # KDL default (RFC "optional, default none")
  var keyId = ""
  var pinnedKeys: seq[string] = @[]

  for child in n.children:
    case child.name
    of "policy":
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvString:
        cfgErr("config: 'cache-trust': 'policy' requires a string argument")
      let p = v.get.strVal
      if p notin ["none", "hmac", "ed25519"]:
        cfgErr("config: 'cache-trust': unknown policy '" & p &
               "' -- must be none, hmac, or ed25519")
      policy = p
    of "key-id":
      keyId = requireStrArg(child, 0, "cache-trust: 'key-id'")
    of "pinned-key":
      pinnedKeys.add requireStrArg(child, 0, "cache-trust: 'pinned-key'")
    else:
      warns.add makeConfigWarning(source, "cache-trust", child.name)

  TrustConfig(policy: policy, keyId: keyId, pinnedKeys: pinnedKeys)

# ---------------------------------------------------------------------------
# C6: Sensitivity presets → (k, sampleFloor, absFloorMs)
# ---------------------------------------------------------------------------

type PerfCheckPreset = tuple[k: float; sampleFloor: int; absFloorMs: int]

proc sensitivityPreset(name: string): PerfCheckPreset =
  ## Map a sensitivity string to its preset values.
  ## "none" is handled at the call site (sets enabled=false); not reached here.
  case name
  of "conservative": result = (k: 4.0, sampleFloor: 20, absFloorMs: 10)
  of "moderate":     result = (k: 3.0, sampleFloor: 10, absFloorMs: 5)
  of "aggressive":   result = (k: 2.0, sampleFloor: 5,  absFloorMs: 2)
  else:
    cfgErr("config: 'perf-check': unknown sensitivity '" & name &
           "' — must be none, conservative, moderate, or aggressive")

proc parsePerfCheck(n: KdlNode; source: string;
                    warns: var seq[ConfigWarning]): PerfCheckConfig =
  ## Parse the `perf-check { … }` block.
  ## Returns a PerfCheckConfig; enabled=false iff sensitivity="none".
  ##
  ## Schema:
  ##   perf-check {
  ##       sensitivity "moderate"   // none|conservative|moderate|aggressive
  ##       k 3.0                    // optional: override MAD multiplier
  ##       sample-floor 10          // optional: override minimum history count
  ##       abs-floor-ms 5           // optional: override MAD floor in ms
  ##   }
  ##
  ## sensitivity is required; individual overrides are applied after the preset.

  var sensitivity = "moderate"  # default if absent
  var kOverride:           float = -1.0  # -1.0 = not set
  var sampleFloorOverride: int   = -1    # -1   = not set
  var absFloorMsOverride:  int   = -1    # -1   = not set

  for child in n.children:
    case child.name
    of "sensitivity":
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvString:
        cfgErr("config: 'perf-check': 'sensitivity' requires a string argument")
      sensitivity = v.get.strVal
    of "k":
      let v = requireFloatArg(child, "perf-check.k")
      if v <= 0.0:
        cfgErr("config: 'perf-check': 'k' must be > 0, got " & $v)
      kOverride = v
    of "sample-floor":
      let v = requireIntArg(child, "perf-check.sample-floor")
      if v < 1:
        cfgErr("config: 'perf-check': 'sample-floor' must be >= 1, got " & $v)
      sampleFloorOverride = v
    of "abs-floor-ms":
      let v = requireIntArg(child, "perf-check.abs-floor-ms")
      if v < 0:
        cfgErr("config: 'perf-check': 'abs-floor-ms' must be >= 0, got " & $v)
      absFloorMsOverride = v
    else:
      warns.add makeConfigWarning(source, "perf-check", child.name)

  # "none" sensitivity → disabled; no further processing.
  if sensitivity == "none":
    return PerfCheckConfig(enabled: false)

  # Resolve preset, then apply overrides.
  let preset = sensitivityPreset(sensitivity)
  PerfCheckConfig(
    enabled:     true,
    k:           if kOverride > 0.0: kOverride else: preset.k,
    sampleFloor: if sampleFloorOverride >= 1: sampleFloorOverride else: preset.sampleFloor,
    absFloorMs:  if absFloorMsOverride >= 0: absFloorMsOverride else: preset.absFloorMs,
  )

# ---------------------------------------------------------------------------
# M-report PASS (b1): reuse-check alerting policy block
# ---------------------------------------------------------------------------

proc parseReuseCheck(n: KdlNode; source: string;
                     warns: var seq[ConfigWarning]): ReuseCheckConfig =
  ## Parse the `reuse-check { … }` block.
  ##
  ##   reuse-check {
  ##       alert-below 0.5   // optional: rTime threshold below which to alert
  ##   }
  ##
  ## Unlike perf-check, there is no "none" sensitivity sentinel: presence of
  ## the block alone means enabled=true; alertBelow defaults to 0.5 when
  ## 'alert-below' is absent. Absence of the whole block (never called) means
  ## disabled — the caller leaves the Config field at its zero-value default.

  var alertBelow = 0.5  # default when absent

  for child in n.children:
    case child.name
    of "alert-below":
      let v = requireFloatArg(child, "reuse-check.alert-below")
      if v < 0.0 or v > 1.0:
        cfgErr("config: 'reuse-check': 'alert-below' must be within [0.0, 1.0], got " & $v)
      alertBelow = v
    else:
      warns.add makeConfigWarning(source, "reuse-check", child.name)

  ReuseCheckConfig(enabled: true, alertBelow: alertBelow)

# ---------------------------------------------------------------------------
# Validate a completed Config
# ---------------------------------------------------------------------------

proc validate(cfg: Config; source: string; warns: var seq[ConfigWarning]) =
  var seen: seq[string]
  for g in cfg.groups:
    if g.name in seen:
      cfgErr("config: duplicate group name '" & g.name & "'")
    seen.add g.name
  var seenTiers: seq[string]
  let cacheVerifies = cfg.cache.trust.policy != "none"
  for t in cfg.cache.remotes:
    if t.name in seenTiers:
      cfgErr("config: duplicate remote-cache name '" & t.name & "'")
    seenTiers.add t.name
    # RFC-0005 review fix (L1/T-guard): mirrors `cacheregistry.
    # configuredCache`'s own identical rejection (defense in depth, same
    # "authority note" pattern as the s3/http checks below — a programmatic
    # `CacheConfig` caller that never goes through KDL cannot bypass either
    # copy). A binary compiled WITHOUT `-d:ssl` cannot dial `https://` at
    # all (`httpraw.rawHttpFetcher`'s `when not defined(ssl)` branch, see
    # that module's doc comment) — this is a HARD config error here too,
    # not a silent dead tier discovered only once a run actually misses.
    when not defined(ssl):
      if t.url.startsWith("https://"):
        cfgErr("config: remote-cache '" & t.name & "': url '" & t.url &
               "' requires TLS, but this crisol build lacks TLS support " &
               "(-d:ssl) -- the produced crisol binary has -d:ssl by " &
               "default (see src/crisol.nim.cfg); an embedding project " &
               "must pass -d:ssl in its own build, or point 'url' at a " &
               "non-https scheme")
    # RFC-0005 C3a / §Secure-by-default: unsigned S3/MinIO has no
    # transport-level write authorization at all (no SigV4 -> no credential
    # is ever transmitted), so a verifying `cache-trust` policy is a HARD
    # requirement whenever an `s3://` tier is configured -- otherwise
    # "poison the shared cache" is structurally possible (RFC "a verifying
    # tier with a non-'none' policy is a hard requirement whenever the
    # unsigned-s3 adapter is used"). The effective per-tier verify-trust
    # mirrors `cacheregistry.configuredCache`'s own resolution rule
    # (explicit override wins; absent -> cache-trust.policy != "none").
    # **Authority note (SEC5):** this is the CLI-facing plan-time error;
    # `cacheregistry.configuredCache` carries the SAME rejection (defense
    # in depth) so a programmatic `CacheConfig` caller that never goes
    # through KDL cannot bypass it either -- the two are independent, not
    # one delegating to the other.
    if t.url.startsWith("s3://"):
      let effectiveVerifyTrust = t.verifyTrust.get(cacheVerifies)
      if not effectiveVerifyTrust:
        cfgErr("config: remote-cache '" & t.name & "': unsigned s3:// requires a " &
               "verifying 'cache-trust' policy (policy != \"none\", and no explicit " &
               "'verify-trust #false' on this tier) -- unsigned S3/MinIO has no " &
               "transport-level write authorization")
    # SEC1: an unkeyed FNV-1a-64 checksum (the only integrity guard a
    # `none`-policy tier has) is trivially attacker-computable -- exactly
    # the read-side spoofing/MITM exposure the s3 rule above closes for
    # writes. Symmetric rule, same rationale style: `http://` (no
    # transport authentication at all) under a non-verifying effective
    # trust is a hard config error. `https://` is NOT rejected here — TLS
    # authenticates the CHANNEL (the bytes really came from that server),
    # it just doesn't make the SERVER trustworthy about cache *content*
    # under `policy "none"` — so that combination is a warning, not an
    # error (below), and the authority note above applies here too:
    # `configuredCache` carries the same http:// rejection independently.
    if t.url.startsWith("http://"):
      let effectiveVerifyTrust = t.verifyTrust.get(cacheVerifies)
      if not effectiveVerifyTrust:
        cfgErr("config: remote-cache '" & t.name & "': unsigned http:// requires a " &
               "verifying 'cache-trust' policy (policy != \"none\", and no explicit " &
               "'verify-trust #false' on this tier) -- an unkeyed FNV-1a-64 checksum " &
               "is attacker-computable and a 'none' trust policy serves anything " &
               "requested of it (read-side spoofing/MITM)")
    # Cross-ref SEC2 (`cacheregistry.configuredCache`): the token-over-http
    # check deliberately lives ONLY there, never here -- secrets resolve
    # lazily (D5), and plan-time `validate` must not force an eager env scan.
    elif t.url.startsWith("https://"):
      let effectiveVerifyTrust = t.verifyTrust.get(cacheVerifies)
      if not effectiveVerifyTrust:
        warns.add ConfigWarning(
          source:  source,
          context: "remote-cache " & t.name,
          key:     "verify-trust",
          message: "remote-cache '" & t.name & "': cache-trust policy is \"none\" -- " &
                   "the https:// server operator at '" & t.url & "' is fully trusted " &
                   "(TLS authenticates the channel, not the content)",
        )
  if cfg.timeoutSecs < 0:
    cfgErr("config: timeout-secs must be >= 0")
  if cfg.compileTimeoutSecs < 0:
    cfgErr("config: compile-timeout-secs must be >= 0")
  if cfg.maxOutputBytes < 0:
    cfgErr("config: max-output-bytes must be >= 0")

# ---------------------------------------------------------------------------
# Walk a KdlDoc → Config
# ---------------------------------------------------------------------------

proc docToConfig(doc: KdlDoc; projectRoot: string; source: string;
                 warns: var seq[ConfigWarning]): Config =
  var
    jobs               = 0
    timeoutSecs        = DefaultTimeoutSecs
    compileTimeoutSecs = DefaultCompileTimeoutSecs
    maxOutputBytes     = DefaultMaxOutputBytes
    stateDir           = DefaultStateDir
    globalFlags: seq[string]
    depRoots:   seq[string]
    # Memory-aware scheduling seeds (Feature B, RFC-0002 §Config keys).
    # All default to none; initAdmission resolves built-in fallbacks.
    memBudgetMb: Option[int]  = none(int)
    memPerJobMb: Option[int]  = none(int)
    memPerRunMb: Option[int]  = none(int)
    memAware:    Option[bool] = none(bool)
    # B1: global retry count (default 0 = no retry).
    retries: int = 0
    # B3: entrypoint paths whose failures are excluded from exit-1.
    # Paths are project-root-relative with '/' separators; matched by raw string
    # equality against ep.path (which is also root-relative, '/' separated).
    quarantine: HashSet[string]
    # C6: perf-check policy block — parsed in second pass (block has children).
    perfCheck: PerfCheckConfig   # default zero-value = disabled
    # M-report PASS (b1): reuse-check policy block — parsed in second pass
    # (block has children), same shape as perf-check.
    reuseCheck: ReuseCheckConfig # default zero-value = disabled
    # A1c: result-cache GC config.
    maxCacheEntries: int = 0    # 0 = use DefaultMaxCacheEntries
    cacheMaxAgeDays: int = 0    # 0 = disabled (no age eviction)
    ledgerMaxAgeDays: int = 0   # 0 = disabled (keep all rows)
    # RFC-0006 M-artifact-identity PASS (b2): gate the measurement worker into
    # the compile slot. Default false (unlike mem-aware's Option[bool] tristate,
    # this is a plain bool — there is no "auto" mode, only explicit opt-in).
    measureCompileReuse: bool = false
    # rfc-0007 A6b: OutcomePolicy.strictHygiene. Default false (same
    # strengthen-only opt-in shape as measure-compile-reuse above).
    strictHygiene: bool = false
    # Fix 1 (RLIMIT_NOFILE plumbing): config-declared override for the
    # sandbox's max-open-fds ceiling. none = use sandbox.DefaultRlimitNofile.
    rlimitNofile: Option[int64] = none(int64)
    # RFC-0005 B3c: --verify-cache-pct's config-file default. Always a
    # concrete value (never a sentinel) -- DefaultVerifyCachePct until the
    # KDL node overrides it, mirroring timeoutSecs above.
    verifyCachePct: int = DefaultVerifyCachePct
    # RFC-0005 B1c: --explain-miss's config-file default (`explain-miss
    # #true`). Same strengthen-only opt-in shape as measure-compile-reuse/
    # strict-hygiene above -- api.planImpl OR's the CLI flag in, never
    # overrides a config `true` back to `false`.
    explainMiss: bool = false
    # RFC-0005 B2b: --cache-stats's config-file default (`cache-stats
    # #true`). Same strengthen-only opt-in shape as explainMiss above.
    cacheStats: bool = false
    # RFC-0005 A0: repeatable `env-pin "NAME" "VALUE"` nodes -> NAME=VALUE
    # pairs pinned into every child env (see sandbox.filterEnv's tail).
    envPins: seq[(string, string)]
    # RFC-0005 A3c-i: repeatable `remote-cache "<name>" { }` blocks — parsed
    # in the second pass below (the block has children, same as perfCheck/
    # reuseCheck). Order-preserving; empty = single-tier local.
    remoteCaches: seq[RemoteTier]
    # RFC-0005 C4: the CACHE-GLOBAL `cache-trust { }` block — parsed in the
    # second pass (has children). Zero-value TrustConfig has policy == ""
    # (Nim's default), so this starts at the KDL default "none" explicitly
    # rather than relying on the zero value -- see below.
    trustCfg: TrustConfig = TrustConfig(policy: "none")

  # First pass: collect all globals (so flag-merge is correct for groups).
  for n in doc.rootNodes:
    case n.name
    of "jobs":               jobs               = requireIntArg(n, "jobs")
    of "timeout-secs":       timeoutSecs        = requireIntArg(n, "timeout-secs")
    of "compile-timeout-secs": compileTimeoutSecs = requireIntArg(n, "compile-timeout-secs")
    of "max-output-bytes":   maxOutputBytes     = requireIntArg(n, "max-output-bytes")
    of "state-dir":
      stateDir = requireStrArg(n, 0, "state-dir")
      validateStateDir(stateDir)
    of "flags":              globalFlags.add      collectStrArgs(n, "flags")
    of "dep-roots":          depRoots.add         collectStrArgs(n, "dep-roots")
    of "mem-budget-mb":
      let v = requireIntArg(n, "mem-budget-mb")
      if v < 0:
        cfgErr("config: 'mem-budget-mb' must be >= 0, got " & $v)
      memBudgetMb = some(v)
    of "mem-per-job-mb":
      let v = requireIntArg(n, "mem-per-job-mb")
      if v <= 0:
        cfgErr("config: 'mem-per-job-mb' must be > 0, got " & $v)
      memPerJobMb = some(v)
    of "mem-per-run-mb":
      let v = requireIntArg(n, "mem-per-run-mb")
      if v <= 0:
        cfgErr("config: 'mem-per-run-mb' must be > 0, got " & $v)
      memPerRunMb = some(v)
    of "mem-aware":
      # bool node: mem-aware #true  or  mem-aware #false
      let v = n.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: 'mem-aware' requires a boolean argument (#true/#false)")
      memAware = some(v.get.boolVal)
    of "retries":
      # global: retries N  (N >= 0)
      let v = requireIntArg(n, "retries")
      if v < 0:
        cfgErr("config: 'retries' must be >= 0, got " & $v)
      retries = v
    of "quarantine":
      # B3: `quarantine "path1" "path2" …` — zero or more string arguments.
      # Paths are stored as-written; matched by raw string equality vs ep.path.
      for p in collectStrArgs(n, "quarantine"):
        quarantine.incl p
    of "max-cache-entries":
      let v = requireIntArg(n, "max-cache-entries")
      if v < 0:
        cfgErr("config: 'max-cache-entries' must be >= 0, got " & $v)
      maxCacheEntries = v
    of "cache-max-age-days":
      let v = requireIntArg(n, "cache-max-age-days")
      if v < 0:
        cfgErr("config: 'cache-max-age-days' must be >= 0, got " & $v)
      cacheMaxAgeDays = v
    of "ledger-max-age-days":
      let v = requireIntArg(n, "ledger-max-age-days")
      if v < 0:
        cfgErr("config: 'ledger-max-age-days' must be >= 0, got " & $v)
      ledgerMaxAgeDays = v
    of "measure-compile-reuse":
      # bool node: measure-compile-reuse #true  or  measure-compile-reuse #false
      let v = n.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: 'measure-compile-reuse' requires a boolean argument (#true/#false)")
      measureCompileReuse = v.get.boolVal
    of "strict-hygiene":
      # bool node: strict-hygiene #true  or  strict-hygiene #false
      let v = n.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: 'strict-hygiene' requires a boolean argument (#true/#false)")
      strictHygiene = v.get.boolVal
    of "rlimit-nofile":
      let v = requireIntArg(n, "rlimit-nofile")
      if v < 1:
        cfgErr("config: 'rlimit-nofile' must be >= 1, got " & $v)
      rlimitNofile = some(int64(v))
    of "verify-cache-pct":
      # RFC-0005 B3c: sample-percentage default for --verify-cache; only
      # meaningful when --verify-cache is passed on the CLI (enabled is
      # CLI-only, per the RFC's config-additions list) and no
      # --verify-cache-pct override was given.
      let v = requireIntArg(n, "verify-cache-pct")
      if v < 0:
        cfgErr("config: 'verify-cache-pct' must be >= 0, got " & $v)
      verifyCachePct = v
    of "explain-miss":
      # bool node: explain-miss #true  or  explain-miss #false
      let v = n.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: 'explain-miss' requires a boolean argument (#true/#false)")
      explainMiss = v.get.boolVal
    of "cache-stats":
      # bool node: cache-stats #true  or  cache-stats #false
      let v = n.arg(0)
      if v.isNone or v.get.kind != kvBool:
        cfgErr("config: 'cache-stats' requires a boolean argument (#true/#false)")
      cacheStats = v.get.boolVal
    of "env-pin":
      # RFC-0005 A0: `env-pin "NAME" "VALUE"` -- exactly 2 string args.
      # Repeatable: each node contributes ONE pin (unlike `flags`/`dep-roots`,
      # which flatten every arg of every occurrence into one list).
      let args = collectStrArgs(n, "env-pin")
      if args.len != 2:
        cfgErr("config: 'env-pin' requires exactly 2 string arguments " &
               "(NAME VALUE), got " & $args.len)
      if args[0].len == 0:
        cfgErr("config: 'env-pin' NAME must not be empty")
      envPins.add (args[0], args[1])
    of "group":        discard
    of "perf-check":   discard  # C6: parsed in second pass (has children)
    of "reuse-check":  discard  # M-report (b1): parsed in second pass (has children)
    of "remote-cache": discard  # RFC-0005 A3c-i: parsed in second pass (has children)
    of "cache-trust":  discard  # RFC-0005 C4: parsed in second pass (has children)
    else:
      warns.add makeConfigWarning(source, "top-level", n.name)

  # Second pass: parse groups, the perf-check block, and the reuse-check block
  # (globalFlags now complete for merge; both blocks have children so need
  # their own pass).
  var groups: seq[Group]
  for n in doc.rootNodes:
    if n.name == "group":
      groups.add parseGroup(n, globalFlags, source, warns)
    elif n.name == "perf-check":
      perfCheck = parsePerfCheck(n, source, warns)
    elif n.name == "reuse-check":
      reuseCheck = parseReuseCheck(n, source, warns)
    elif n.name == "remote-cache":
      remoteCaches.add parseRemoteCache(n, source, warns)
    elif n.name == "cache-trust":
      trustCfg = parseCacheTrust(n, source, warns)

  result = Config(
    groups:             groups,
    flags:              globalFlags,
    jobs:               jobs,
    timeoutSecs:        timeoutSecs,
    compileTimeoutSecs: compileTimeoutSecs,
    maxOutputBytes:     maxOutputBytes,
    stateDir:           stateDir,
    projectRoot:        projectRoot,
    depRoots:           depRoots,
    memBudgetMb:        memBudgetMb,
    memPerJobMb:        memPerJobMb,
    memPerRunMb:        memPerRunMb,
    memAware:           memAware,
    retries:            retries,
    quarantine:         quarantine,
    perfCheck:          perfCheck,
    reuseCheck:         reuseCheck,
    maxCacheEntries:    maxCacheEntries,
    cacheMaxAgeDays:    cacheMaxAgeDays,
    ledgerMaxAgeDays:   ledgerMaxAgeDays,
    measureCompileReuse: measureCompileReuse,
    strictHygiene:      strictHygiene,
    rlimitNofile:       rlimitNofile,
    verifyCachePct:     verifyCachePct,
    explainMiss:        explainMiss,
    cacheStats:         cacheStats,
    envPins:            envPins,
    cache:              CacheConfig(remotes: remoteCaches, trust: trustCfg),
    workerBinary:       "",  # INTERNAL plumbing; not user-facing, no KDL node — the CLI/library
                             # caller sets this post-load (see api.planImpl / crisol.nim).
  )
  validate(result, source, warns)

# ---------------------------------------------------------------------------
# parseConfigFile — read + parse a crisol.kdl path → Config
# ---------------------------------------------------------------------------

proc parseConfigFile(path: string): (Config, seq[ConfigWarning]) =
  let src =
    try: readFile(path)
    except IOError, OSError:
      raise newCrisolError(cekEnvironment,
        "config: cannot read '" & path & "': " & getCurrentExceptionMsg())

  let r = parse(src, path)
  if r.isErr:
    raise newCrisolError(cekConfig,
      "config: parse error in '" & path & "':\n" &
      r.getErr.formatError(src, path))

  var warns: seq[ConfigWarning]
  let cfg = docToConfig(r.get, parentDir(absolutePath(path)), path, warns)
  (cfg, warns)

# ---------------------------------------------------------------------------
# loadConfig — the stable public seam
# ---------------------------------------------------------------------------

proc loadConfig*(configPath: string = ""; startDir: string = ""):
                (Config, seq[ConfigWarning]) =
  ## Resolve and load the crisol configuration.
  ##
  ## Returns a tuple of the parsed Config and any ConfigWarnings accumulated
  ## while parsing (e.g. unrecognized keys for forward-compatibility).
  ##
  ## Resolution order:
  ##   1. `configPath` non-empty → use that path (must exist → cekEnvironment
  ##      if absent; parse error → cekConfig).
  ##   2. Walk up from `startDir` (defaults to cwd) looking for `crisol.kdl`.
  ##   3. Convention fallback: built-in unit+integration groups, rooted at the
  ##      nearest enclosing `.git` dir (or cwd if none). NOT an error.
  if configPath.len > 0:
    if not fileExists(configPath):
      raise newCrisolError(cekEnvironment,
        "config: --config path does not exist: '" & configPath & "'")
    return parseConfigFile(configPath)

  let origin = if startDir.len > 0: startDir else: getCurrentDir()
  let found  = findConfigFile(origin)
  if found.len > 0:
    return parseConfigFile(found)

  # Convention fallback — not an error; no warnings (no file to have unknown keys)
  let gitRoot = findGitRoot(origin)
  (conventionConfig(if gitRoot.len > 0: gitRoot else: origin), @[])
