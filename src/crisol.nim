## crisol.nim — CLI entry point (A5 + B6 + B7 + C2 + C3)
##
## Thin shell: parse argv → apply overrides → wire pipeline → exit.
## No business logic lives here; all orchestration is in the library.
##
## Usage:
##   crisol run [<path>...]
##     --group <name>    run named group(s) instead of defaults (repeatable)
##     --all-groups      include opt-in groups (gates still apply)
##     --jobs <N>        parallel job cap (default: max(1, cpu-2))
##     --timeout <secs>  per-entrypoint run-timeout override
##     --fail-fast       stop launching new entrypoints on first failure
##     --dry-run         compute & print the plan; do NOT compile or run
##     --json            machine-readable output
##     --failed          re-run only entrypoints that failed in the last run
##     --filter-tag TAG  reporting-level filter: show only records tagged TAG;
##                       emits a warning to stderr when no records match
##   crisol list [<path>...] [--group <name>] [--all-groups]
##     --json            machine-readable plan output
##   crisol clean [--all]
##     --all             remove entire .crisol/ state dir (no lock needed)
##
## --group and --all-groups are mutually exclusive: specifying both is a usage
## error (exit 3).  Precedence: error is cleaner than silent last-wins because
## the two flags are semantically contradictory (named subset vs. full set).
##
## `list` and `run --dry-run` are the SAME pure plan phase (discover →
## applyGates → plan) with execution skipped — they share pipeline.buildRunPlan
## and emitPlan (CLI); neither spawns a subprocess.
##
## Exit codes (per RFC §CLI Surface):
##   0   all entrypoints passed (or a pure listing succeeded)
##   1   one or more entrypoints failed / compile-failed / timed-out / signaled
##   2   crisol internal error (should never occur in normal operation)
##   3   environment/configuration error: bad args, zero entrypoints discovered,
##       --failed with no prior run (lastrun.json absent)

import std/[options, os, sets, strutils]
from std/posix import isatty
import crisol/[types, config, runner, signals, render, jsonout, planview, lock, clean, gitdiff, terminal, pipeline]

# ---------------------------------------------------------------------------
# Exit codes (RFC §CLI Surface)
# ---------------------------------------------------------------------------

const
  ExitOk*          = 0
  ExitTestFailure* = 1
  ExitInternal*    = 2
  ExitEnvironment* = 3

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

proc usage(): string =
  """crisol — host-side test runner

Usage:
  crisol run  [<path>...] [--group <name>]... [--all-groups]
              [--jobs <N>] [--timeout <secs>] [--fail-fast]
              [--dry-run] [--json] [--force-compile]
              [--failed] [--changed [--base <ref>]]
              [--filter-tag <tag>]
  crisol list [<path>...] [--group <name>]... [--all-groups] [--json]

  crisol --help | -h

Subcommands:
  run    Discover, compile, and run test entrypoints.
  list   Show what WOULD run (the plan) without compiling or running anything.

Options for 'run' and 'list':
  <path>...       Restrict discovery to these paths/globs (default: convention
                  globs from config — tests/unit/test_*.nim, etc.).
  --group <name>  Run only the named group(s); repeatable.  Mutually exclusive
                  with --all-groups (specifying both is a usage error).
  --all-groups    Include opt-in groups (gates still apply).

Additional options for 'run':
  --jobs N        Parallel job cap.  Default: max(1, cpu_count - 2).
  --timeout S     Per-entrypoint run timeout in seconds.  Default: 300.
  --fail-fast     Stop launching new entrypoints after the first failure.
  --dry-run       Print the plan (selection + per-entrypoint compile decisions)
                  and exit; compile and run NOTHING.
  --json          Emit machine-readable JSON to stdout instead of human output.
  --failed        Re-run only entrypoints that failed in the last run
                  (reads .crisol/lastrun.json; exit 3 if absent).
  --changed       Impact selection: run only entrypoints whose dependency
                  closure intersects the git diff.  Requires a git work tree
                  (exit 3 otherwise).  Combined with --failed, selects the
                  UNION of the two narrowed sets.
  --base <ref>    With --changed, diff the working tree against <ref> instead
                  of HEAD (includes uncommitted edits).  Ignored (with a
                  warning) when --changed is absent.
  --force-compile Force recompilation of all entrypoints even when fresh.
  --filter-tag T  Reporting-level filter: show ONLY test records tagged T.
                  Entrypoints still run in full; only the report is filtered.
                  Emits a warning to stderr when no records match the tag.
                  Exit code is unchanged by the filter.

Additional options for 'list':
  --json          Emit the crisol/plan/v1 JSON document instead of human output.

Exit codes:
  0   All selected entrypoints passed (or a pure listing succeeded).
  1   One or more entrypoints failed / compile-failed / timed-out / signaled.
  2   Crisol internal error (should not occur in normal operation).
  3   Environment / configuration error (bad args, no entrypoints found, etc.).
"""

# ---------------------------------------------------------------------------
# Color decision: pure helper + isatty wrapper
# ---------------------------------------------------------------------------

proc computeColorEnabled(): bool =
  ## Returns true iff stdout is a TTY AND NO_COLOR is unset.
  let tty = isatty(1.cint) != 0   # fd 1 = stdout
  shouldEnableColor(tty)

# ---------------------------------------------------------------------------
# emitPlan — CLI display path for list and run --dry-run.
# ---------------------------------------------------------------------------

proc emitPlan(pv: RunPlanView; jsonMode, colorEnabled: bool; cfg: Config) =
  if jsonMode:
    stdout.write(planToJsonString(pv.plan, pv.gatedOut, pv.warnings, cfg))
    stdout.write("\n")
  else:
    let opts = RenderOpts(color: colorEnabled, slowestN: 5)
    stdout.write(renderPlan(pv.plan, pv.gatedOut, opts))

# ---------------------------------------------------------------------------
# runMain — testable entry; returns the process exit code
# ---------------------------------------------------------------------------

proc runMain*(args: seq[string]): int =
  ## Parse `args` (argv without the program name), execute the pipeline,
  ## and return the exit code.  Does NOT call quit().

  # R2/A6: install signal handlers so SIGINT/SIGTERM set the volatile flag that
  # execute()'s poll loop checks.  Installed near the top of runMain so they
  # are active for the full duration of the CLI's lifetime.
  installSignalHandlers()

  if args.len == 0:
    stderr.write(usage())
    return ExitEnvironment

  let sub = args[0]

  if sub in ["-h", "--help"]:
    stdout.write(usage())
    return ExitOk

  if sub notin ["run", "list", "clean"]:
    stderr.write("crisol: unknown subcommand '" & sub & "'\n\n")
    stderr.write(usage())
    return ExitEnvironment

  let isList  = sub == "list"
  let isClean = sub == "clean"

  # -------------------------------------------------------------------------
  # `clean` subcommand: orphan pruning (+ --all).
  # Handled early, before the shared run/list flag parser.
  # -------------------------------------------------------------------------

  if isClean:
    var doCleanAll = false
    let cleanArgs = args[1..^1]
    for a in cleanArgs:
      if a == "--all":
        doCleanAll = true
      else:
        stderr.write("crisol: unknown flag for clean: '" & a & "'\n")
        return ExitEnvironment

    let (cfg, _) = loadConfig(configPath = "")
    let stateDir = cfg.projectRoot / cfg.stateDir

    if doCleanAll:
      # --all: remove the whole state dir — no lock needed.
      try:
        cleanAll(cfg)
      except Exception as e:
        stderr.write("crisol: clean --all failed: " & e.msg & "\n")
        return ExitInternal
      return ExitOk

    # Acquire the lock before mutating shared state.
    var lockHandle: LockHandle
    try:
      lockHandle = acquireLock(stateDir)
    except CrisolError as e:
      stderr.write("crisol: " & e.msg & "\n")
      return ExitEnvironment

    defer: releaseLock(lockHandle)

    try:
      let r = cleanOrphans(cfg)
      stdout.write("crisol clean: pruned " & $r.cacheDeleted &
                   " cache dir(s), " & $r.binDeleted &
                   " bin dir(s), " & $r.graphEntriesDropped &
                   " depgraph entry(ies)\n")
    except CrisolError as e:
      stderr.write("crisol: clean error: " & e.msg & "\n")
      return ExitEnvironment
    except Exception as e:
      stderr.write("crisol: clean unexpected error: " & e.msg & "\n")
      return ExitInternal

    return ExitOk

  # -------------------------------------------------------------------------
  # Parse flags (run + list share most; run adds jobs/timeout/fail-fast/dry-run)
  # -------------------------------------------------------------------------

  var
    paths:        seq[string]
    groupNames:   seq[string]   # collected from --group (repeatable)
    allGroups:    bool = false  # set by --all-groups
    configPath:   string = ""   # C1: --config <path> override
    jobs:         int  = 0
    timeout:      int  = 0
    failFast:     bool = false
    jsonMode:     bool = false
    dryRun:       bool = false
    useFailed:    bool = false
    useChanged:   bool = false  # D5: impact selection via git diff
    baseRef:      string = ""   # D5: --base <ref>; "" means diff vs HEAD
    forceCompile: bool = false
    filterTag:    string = ""   # C3: reporting-level record filter

  let runArgs = args[1..^1]
  var i = 0
  while i < runArgs.len:
    let a = runArgs[i]
    if a.startsWith("--"):
      let flagBody = a[2..^1]
      var key = flagBody
      var valInline = ""
      var hasInline = false
      let eq = flagBody.find('=')
      if eq >= 0:
        key = flagBody[0..<eq]
        valInline = flagBody[eq+1..^1]
        hasInline = true

      proc nextVal(name: string): string =
        if hasInline: return valInline
        if i + 1 < runArgs.len and not runArgs[i+1].startsWith("-"):
          inc i
          return runArgs[i]
        stderr.write("crisol: --" & name & " requires a value\n")
        return ""

      # Flags valid only for `run`.
      if key in ["jobs", "timeout", "fail-fast", "dry-run", "failed", "changed",
                 "base", "force-compile", "filter-tag"] and isList:
        stderr.write("crisol: '--" & key & "' is not valid for 'list'\n\n")
        stderr.write(usage())
        return ExitEnvironment

      case key
      of "config":
        let raw = nextVal("config")
        if raw == "":
          stderr.write("crisol: --config requires a file path\n")
          return ExitEnvironment
        configPath = raw
      of "group":
        let raw = nextVal("group")
        if raw == "":
          stderr.write("crisol: --group requires a group name\n")
          return ExitEnvironment
        groupNames.add raw
      of "all-groups":
        allGroups = true
      of "jobs":
        let raw = nextVal("jobs")
        if raw == "":
          stderr.write(usage()); return ExitEnvironment
        try:
          jobs = parseInt(raw)
          if jobs < 1:
            stderr.write("crisol: --jobs must be >= 1\n"); return ExitEnvironment
        except ValueError:
          stderr.write("crisol: --jobs: invalid integer '" & raw & "'\n")
          return ExitEnvironment
      of "timeout":
        let raw = nextVal("timeout")
        if raw == "":
          stderr.write(usage()); return ExitEnvironment
        try:
          timeout = parseInt(raw)
          if timeout < 1:
            stderr.write("crisol: --timeout must be >= 1\n"); return ExitEnvironment
        except ValueError:
          stderr.write("crisol: --timeout: invalid integer '" & raw & "'\n")
          return ExitEnvironment
      of "fail-fast":
        failFast = true
      of "dry-run":
        dryRun = true
      of "json":
        jsonMode = true
      of "failed":
        useFailed = true
      of "changed":
        useChanged = true
      of "base":
        let raw = nextVal("base")
        if raw == "":
          stderr.write("crisol: --base requires a git ref\n")
          return ExitEnvironment
        baseRef = raw
      of "force-compile":
        forceCompile = true
      of "filter-tag":
        let raw = nextVal("filter-tag")
        if raw == "":
          stderr.write("crisol: --filter-tag requires a tag name\n")
          return ExitEnvironment
        filterTag = raw
      else:
        stderr.write("crisol: unknown flag '--" & key & "'\n\n")
        stderr.write(usage())
        return ExitEnvironment
    elif a.startsWith("-") and a.len > 1:
      let key = a[1..^1]
      proc nextVal2(name: string): string =
        if i + 1 < runArgs.len and not runArgs[i+1].startsWith("-"):
          inc i
          return runArgs[i]
        stderr.write("crisol: -" & name & " requires a value\n")
        return ""
      if key in ["j", "t"] and isList:
        stderr.write("crisol: '-" & key & "' is not valid for 'list'\n\n")
        stderr.write(usage())
        return ExitEnvironment
      case key
      of "j":
        let raw = nextVal2("j")
        if raw == "":
          stderr.write(usage()); return ExitEnvironment
        try:
          jobs = parseInt(raw)
          if jobs < 1:
            stderr.write("crisol: --jobs must be >= 1\n"); return ExitEnvironment
        except ValueError:
          stderr.write("crisol: --jobs: invalid integer '" & raw & "'\n")
          return ExitEnvironment
      of "t":
        let raw = nextVal2("t")
        if raw == "":
          stderr.write(usage()); return ExitEnvironment
        try:
          timeout = parseInt(raw)
          if timeout < 1:
            stderr.write("crisol: --timeout must be >= 1\n"); return ExitEnvironment
        except ValueError:
          stderr.write("crisol: --timeout: invalid integer '" & raw & "'\n")
          return ExitEnvironment
      else:
        stderr.write("crisol: unknown flag '-" & key & "'\n\n")
        stderr.write(usage())
        return ExitEnvironment
    else:
      paths.add a
    inc i

  # -------------------------------------------------------------------------
  # Build config and apply CLI overrides
  # -------------------------------------------------------------------------

  # --group and --all-groups are mutually exclusive: they are semantically
  # contradictory (named subset vs. full set), so we error rather than silently
  # picking a winner.
  if groupNames.len > 0 and allGroups:
    stderr.write("crisol: --group and --all-groups are mutually exclusive\n\n")
    stderr.write(usage())
    return ExitEnvironment

  var cfg: Config
  var cfgWarnings: seq[ConfigWarning]
  try:
    (cfg, cfgWarnings) = loadConfig(configPath = configPath)
  except CrisolError as e:
    case e.kind
    of cekConfig:
      stderr.write("crisol: config error: " & e.msg & "\n")
      return ExitEnvironment
    of cekEnvironment:
      stderr.write("crisol: environment error: " & e.msg & "\n")
      return ExitEnvironment
    of cekInternal:
      stderr.write("crisol: internal error: " & e.msg & "\n")
      return ExitInternal
  # Emit config warnings to stderr (forward-compat: warn, never fail).
  for w in cfgWarnings:
    stderr.write("warning: " & w.message & "\n")
  if jobs > 0:    cfg.jobs = jobs
  if timeout > 0: cfg.timeoutSecs = timeout

  # Build the GroupSelection from the parsed flags.  Positional paths take
  # precedence: when paths are given they use gskFiles (discover synthesises a
  # transient "paths" group — Config is NOT mutated).
  # RFC: "naming a file is the strongest possible opt-in".
  var selection: GroupSelection
  if paths.len > 0:
    selection = GroupSelection(kind: gskFiles, paths: paths)
  elif allGroups:
    selection = GroupSelection(kind: gskAll)
  elif groupNames.len > 0:
    selection = GroupSelection(kind: gskNamed, names: groupNames)
  else:
    selection = GroupSelection(kind: gskDefault)

  let colorEnabled = computeColorEnabled()

  # -------------------------------------------------------------------------
  # --failed: load the failed (path,group) set from lastrun.json.
  # Exit 3 if the file is absent or malformed.
  # This is run-only; isList always has useFailed=false (flagged above).
  # -------------------------------------------------------------------------

  var failedKeys = initHashSet[tuple[path, group: string]]()
  if useFailed:
    var lr: tuple[found: bool; failed: HashSet[tuple[path, group: string]]]
    try:
      lr = loadLastRun(cfg)
    except CrisolError as e:
      stderr.write("crisol: " & e.msg & "\n")
      return ExitEnvironment
    if not lr.found:
      stderr.write("crisol: no previous run found — run `crisol run` first\n")
      return ExitEnvironment
    failedKeys = lr.failed

  # -------------------------------------------------------------------------
  # --changed: compute the changed-file set via git (D5).  Applied as
  # impact-selection narrowing in buildPlanView (same seam as --failed).
  #
  # --base without --changed is meaningless: warn and ignore the ref.
  # A non-repo / missing-git surfaces as CrisolError(cekEnvironment) → exit 3.
  # -------------------------------------------------------------------------

  if baseRef.len > 0 and not useChanged:
    stderr.write("crisol: warning: --base has no effect without --changed; " &
                 "ignoring '--base " & baseRef & "'\n")

  var changedSet = initHashSet[string]()
  if useChanged:
    try:
      changedSet = changedFiles(cfg.projectRoot, baseRef)
    except CrisolError as e:
      # cekEnvironment (git missing / not a repo) → exit 3, consistent with
      # every other environment failure.
      case e.kind
      of cekEnvironment:
        stderr.write("crisol: environment error: " & e.msg & "\n")
        return ExitEnvironment
      of cekConfig:
        stderr.write("crisol: config error: " & e.msg & "\n")
        return ExitEnvironment
      of cekInternal:
        stderr.write("crisol: internal error: " & e.msg & "\n")
        return ExitInternal

  # -------------------------------------------------------------------------
  # PLAN phase — shared by `list`, `run --dry-run`, and `run`.
  # No subprocess is spawned by buildRunPlan.
  # failedKeys is empty for non-`--failed` runs (no narrowing).
  # -------------------------------------------------------------------------

  var pv: RunPlanView
  try:
    pv = buildRunPlan(cfg, selection, failedKeys,
                      useFailed = useFailed, useChanged = useChanged,
                      changed = changedSet,
                      nimVersion = "", forceCompile = forceCompile,
                      warnings = cfgWarnings)
  except CrisolError as e:
    case e.kind
    of cekConfig:
      stderr.write("crisol: config error: " & e.msg & "\n")
      return ExitEnvironment
    of cekEnvironment:
      stderr.write("crisol: environment error: " & e.msg & "\n")
      return ExitEnvironment
    of cekInternal:
      stderr.write("crisol: internal error: " & e.msg & "\n")
      return ExitInternal

  # `list` and `--dry-run`: render the plan and exit WITHOUT executing.
  # Read-only commands do NOT acquire the lock.
  if isList or dryRun:
    emitPlan(pv, jsonMode, colorEnabled, cfg)
    return ExitOk

  # -------------------------------------------------------------------------
  # `run`: acquire advisory lock BEFORE compiling (plan already done above).
  # RFC: "plan() runs after acquisition" — here plan ran first (it's pure and
  # read-only), then we acquire before the first compile subprocess is spawned.
  # list/--dry-run are intentionally excluded above (read-only, lock-free).
  # -------------------------------------------------------------------------

  let stateDir = cfg.projectRoot / cfg.stateDir
  var runLock: LockHandle
  try:
    runLock = acquireLock(stateDir)
  except CrisolError as e:
    stderr.write("crisol: " & e.msg & "\n")
    return ExitEnvironment

  # Lock is held from here through depgraph finalization inside execute.
  # On normal exit we release explicitly; on process death the kernel releases.
  defer: releaseLock(runLock)

  # -------------------------------------------------------------------------
  # `run`: validate selection, then EXECUTE.
  # -------------------------------------------------------------------------

  if pv.runnable == 0:
    if useChanged:
      # Clean tree (or nothing affected) → exit 0 with a clear message.
      # Per the RFC exit-code table: "--changed selects zero entrypoints on a
      # clean tree → exit 0 with nothing affected".
      stdout.write("crisol: nothing affected by the changes — nothing to run\n")
      return ExitOk
    elif useFailed:
      # All previously-failed entrypoints are gone (deleted/renamed/all passed).
      # Per RFC exit-code table, this parallels --changed with zero affected →
      # exit 0 with a clear message (conservative: no unknown failure).
      stdout.write("crisol: no previously-failed entrypoints to re-run\n")
      return ExitOk
    elif pv.gatedOut.len > 0:
      for g in pv.gatedOut:
        stderr.write("crisol: '" & g.path & "' [" & g.group & "] gated out: " &
                     g.reason & "\n")
      stdout.write("crisol: all groups gated out — nothing to run\n")
      return ExitOk
    else:
      stderr.write("crisol: no entrypoints matched — check config/globs\n")
      return ExitEnvironment

  let runPlan          = pv.plan
  let totalPlanned     = runPlan.entrypoints.len
  var runGraph         = pv.graph   # mutable copy for depgraph recording

  var results: seq[EntrypointResult]
  var memThrottled = 0  # S6b: populated by execute via memThrottledOut
  try:
    # M1: timeouts and output cap are derived from cfg inside execute().
    results = execute(
      runPlan,
      config           = cfg,
      graph            = runGraph,
      nimVersion       = "",
      onResult         = noopResult,
      failFast         = failFast,
      showProgress     = not jsonMode,
      progressIntervalMs = 30_000,
      memThrottledOut  = addr memThrottled,
    )
  except CrisolInterrupted as e:
    # R2/A6: SIGINT or SIGTERM interrupted the run.  Exit with 128 + signum
    # (shell convention: killed by signal N → exit 128+N).
    # Children were already killed and reaped inside execute()'s handleInterrupt.
    releaseLock(runLock)
    return 128 + int(e.signum)
  except CrisolError as e:
    case e.kind
    of cekEnvironment:
      stderr.write("crisol: environment error: " & e.msg & "\n")
      return ExitEnvironment
    of cekConfig:
      stderr.write("crisol: config error: " & e.msg & "\n")
      return ExitEnvironment
    of cekInternal:
      stderr.write("crisol: internal error: " & e.msg & "\n")
      return ExitInternal
  except Exception as e:
    stderr.write("crisol: unexpected error: " & e.msg & "\n")
    return ExitInternal

  if failFast and results.len < totalPlanned:
    let skipped = totalPlanned - results.len
    stderr.write("crisol: fail-fast — stopped after first failure; " &
                 $skipped & " entrypoint(s) not started\n")

  let s = summarize(results)
  persistLastRun(results, s, cfg, warnings = pv.warnings,
                 memThrottledSlots = memThrottled)

  # C3: zero-match warning is emitted regardless of --json mode (always stderr).
  if filterTag.len > 0 and hasZeroTagMatches(results, filterTag):
    stderr.write("crisol: warning: no test records matched tag \"" &
                 filterTag & "\"\n")

  if jsonMode:
    stdout.write(toJsonString(results, s, filterTag, pv.warnings, memThrottled))
    stdout.write("\n")
  else:
    let opts = RenderOpts(color: colorEnabled, slowestN: 5,
                          filterTag: if filterTag.len > 0: some(filterTag)
                                     else: none(string))
    stdout.write(render(results, s, opts))
    # Emit gate-skip summary lines AFTER the results block.
    # Gate-skips are informational — they don't affect exit code.
    # Aggregate by group (one line per gated group, not per entrypoint).
    if pv.gatedOut.len > 0:
      # Deduplicate by group name to get one reason per group.
      var seenGroups: seq[string]
      var groupReasons: seq[tuple[group: string; reason: string]]
      for g in pv.gatedOut:
        if g.group notin seenGroups:
          seenGroups.add g.group
          groupReasons.add (group: g.group, reason: g.reason)
      for line in gateSkipMessages(groupReasons):
        stdout.write(line & "\n")

  return exitCode(s)

# ---------------------------------------------------------------------------
# Binary entry point
# ---------------------------------------------------------------------------

when isMainModule:
  let code = runMain(commandLineParams())
  quit(code)
