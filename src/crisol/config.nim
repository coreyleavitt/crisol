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

import std/[os, options, strutils]
import nkdl
import crisol/types

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const DefaultTimeoutSecs*        = 300
const DefaultCompileTimeoutSecs* = 600
const DefaultMaxOutputBytes*     = 10 * 1024 * 1024   # 10 MiB
const DefaultStateDir*           = ".crisol"

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

proc requireIntArg(n: KdlNode; label: string): int =
  let v = n.arg(0)
  if v.isNone or v.get.kind != kvInt:
    cfgErr("config: '" & label & "' requires an integer argument")
  int(v.get.intVal)

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
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvInt:
        cfgErr("config: group '" & name & "': 'timeout-secs' requires an integer argument")
      timeoutSecs = int(v.get.intVal)
      if timeoutSecs < 0:
        cfgErr("config: group '" & name & "': timeout-secs must be >= 0")
    of "max-jobs":
      # child node: max-jobs N  (N >= 1; 0 or negative is a config error)
      # Absence → none (uncapped). some(1) = serial. some(N) = cap at N.
      # 0 is NOT "uncapped" — absence is the only way to express uncapped.
      let v = child.arg(0)
      if v.isNone or v.get.kind != kvInt:
        cfgErr("config: group '" & name & "': 'max-jobs' requires an integer argument")
      let cap = int(v.get.intVal)
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
  )

# ---------------------------------------------------------------------------
# Validate a completed Config
# ---------------------------------------------------------------------------

proc validate(cfg: Config) =
  var seen: seq[string]
  for g in cfg.groups:
    if g.name in seen:
      cfgErr("config: duplicate group name '" & g.name & "'")
    seen.add g.name
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

  # First pass: collect all globals (so flag-merge is correct for groups).
  for n in doc.rootNodes:
    case n.name
    of "jobs":               jobs               = requireIntArg(n, "jobs")
    of "timeout-secs":       timeoutSecs        = requireIntArg(n, "timeout-secs")
    of "compile-timeout-secs": compileTimeoutSecs = requireIntArg(n, "compile-timeout-secs")
    of "max-output-bytes":   maxOutputBytes     = requireIntArg(n, "max-output-bytes")
    of "state-dir":          stateDir           = requireStrArg(n, 0, "state-dir")
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
    of "group":              discard
    else:
      warns.add makeConfigWarning(source, "top-level", n.name)

  # Second pass: parse groups (globalFlags now complete for merge).
  var groups: seq[Group]
  for n in doc.rootNodes:
    if n.name == "group":
      groups.add parseGroup(n, globalFlags, source, warns)

  result = Config(
    groups:             groups,
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
  )
  validate(result)

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
