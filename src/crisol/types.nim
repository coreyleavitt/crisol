## types.nim — crisol canonical core types
##
## All types shared by discover, plan, and execute. Only what A1–A3 needs is
## defined here; later slices append without touching the existing definitions.

import std/[algorithm, options, random, sets]
# rfc-0007 A1c: dependency inversion. Outcome/HermeticLevel now live in
# process/types.nim (moved out of this module) because EntrypointResult below
# carries `compile`/`run: Phase` fields directly — process/types cannot import
# THIS module (that would cycle), so this module imports process/types
# instead and re-exports exactly Outcome + HermeticLevel so every existing
# `import crisol/types` consumer keeps compiling unchanged. A plain `import`
# (not the house `from ... import nil` convention used elsewhere — runner.nim,
# jsonout.nim, api.nim) is needed here: `Outcome`/`HermeticLevel` are used
# unqualified throughout the rest of THIS file, and `export` alone does not
# bind a name into its own defining module, only into importers. Everything
# else from process/types (Phase, ProcessResult, OutcomePolicy, ...) is used
# `ptypes.`-qualified below and is NOT re-exported.
import crisol/process/types as ptypes
export ptypes.Outcome, ptypes.HermeticLevel

type
  IdentityKey* = distinct string
    ## Stable locator for a test entrypoint: `(path, flagHash)`.
    ## Primary key of the RunLedger — stable across env/version changes.
    ## Derivation lives in `keys.nim`.

  SoundnessKey* = distinct string
    ## Chained-FNV-1a content fingerprint over all 9 soundness inputs.
    ## Primary key of the ExecutionCache.
    ## Wire/JSON name: ``inputHash``.  Internal Nim identifier only.
    ## Derivation lives in `keys.nim`.

proc `==`*(a, b: IdentityKey): bool {.borrow.}
proc `==`*(a, b: SoundnessKey): bool {.borrow.}
proc `$`*(k: IdentityKey): string {.borrow.}
proc `$`*(k: SoundnessKey): string {.borrow.}

type
  RlimitOverrides* = object
    ## Caller-supplied per-field rlimit overrides for ``resolveSandbox``.
    ## Bundling the five same-typed ``Option[int64]`` values into a named-field
    ## object makes a transposition (e.g. swapping the Fsize and Nofile args) a
    ## compile-visible misnomer instead of a silent positional bug.
    ## ``none`` for a field = no override; ``resolveSandbox`` then applies the
    ## built-in safe default for that limit when rlimits are active.
    limitAs*:     Option[int64]   ## override for RLIMIT_AS (virtual address space, bytes)
    limitCpu*:    Option[int64]   ## override for RLIMIT_CPU (CPU seconds)
    limitFsize*:  Option[int64]   ## override for RLIMIT_FSIZE (max file size, bytes)
    limitNofile*: Option[int64]   ## override for RLIMIT_NOFILE (max open fds)
    limitCore*:   Option[int64]   ## override for RLIMIT_CORE (core dump size)

  SandboxSpec* = object
    ## Resolved specification for a child sandbox.  Produced by ``resolveSandbox``.
    ## All boolean flags express what is *requested*.
    ##
    ## rfc-0007 A2a-iii (the Limits re-home, §1/§5): resource limits live in
    ## exactly ONE home — ``limits: Limits``, the enum-indexed shape shared
    ## with the process contract (``ChildSpec.limits``, ``ReapReport.limits``).
    ## The old ``rlimitConfig: RlimitConfig`` five-parallel-field struct is
    ## gone; ``core`` included in the single home like every other kind.
    ##
    ## ``SandboxAchieved`` is DELETED outright (§5): env/tmpdir are achieved
    ## BY CONSTRUCTION — the runner resolves them deterministically before
    ## the child exists (filtered env, mkdtemp'd scratch dir), nothing to
    ## probe or degrade — and only limits require kernel readback
    ## (``LimitsAchieved``, produced per-limit at spawn time and threaded
    ## through ``evidenceSatisfies`` below). ``netIso`` is NEVER wired
    ## (never-goal, §5/§6) — see ``evidenceSatisfies``'s note.
    level*:                HermeticLevel
    envScrub*:             bool          ## apply env allowlist filter
    tmpdir*:               bool          ## create isolated per-entrypoint scratch tmpdir
    rlimits*:              bool          ## apply config-declared rlimits (request gate;
                                         ## the per-kind ``limits.req`` Options are the
                                         ## load-bearing source of truth — this mirrors
                                         ## ``envScrub``/``tmpdir`` as a request flag, not
                                         ## a limit value)
    netIso*:               bool          ## unshare(CLONE_NEWNET) + loopback
    chdirIntoScratch*:     bool          ## chdir into scratch tmpdir (opt-in, default off)
    envAllowlist*:         seq[string]   ## exact env-var names to pass through (sorted)
    envAllowlistPrefixes*: seq[string]   ## prefix patterns (e.g. "LC_") to pass through
    limits*:               ptypes.Limits ## the SINGLE home for resource limits (§1)

proc evidenceSatisfies*(spec: SandboxSpec; ev: ptypes.Evidence): bool =
  ## Cache gate (rfc-0007 A6a, §6): named guarantees, never enum ordinals.
  ## Replaces the old ``isFullyAchieved`` outright — ``Evidence`` (not just
  ## the per-limit readback) is now the gate's real input, because §6 folds
  ## THREE axes into one verdict:
  ##
  ##   - ``netIso`` requested ⇒ never achieved (never wired, §5) — the same
  ##     unconditional refusal ``isFullyAchieved`` always gave ``hlNetwork``.
  ##     env/tmpdir are achieved BY CONSTRUCTION (the runner resolves them
  ##     deterministically before the child exists), so there is nothing
  ##     left to probe for either.
  ##   - observed escapees (``ev.escapees.len > 0``) ⇒ uncacheable — leaked
  ##     side effects already happened, even where a later tier (B1) goes
  ##     on to reap them; ``tree`` is a SEPARATE observability axis (§2) and
  ##     is deliberately not consulted here — an unobservable-but-empty-
  ##     escapees tier is cacheable-with-the-label, which is exactly "no
  ##     further condition on ``tree``".
  ##   - per-limit: ``lsFailed`` ⇒ uncacheable (the mechanism existed here
  ##     and broke); ``lsUnsupported``/``lsNotRequested``/``lsApplied`` all
  ##     satisfy — an unsupported tier is the SAME class as
  ##     ``toUnobservable``, not a failure (round-2 amendment #2, locked).
  ##     The achieved status alone is authoritative (no cross-check against
  ##     ``spec.limits.req``): a correct producer only ever stamps
  ##     ``lsNotRequested`` for a kind that was, in fact, not requested.
  if spec.netIso:
    return false
  if ev.escapees.len > 0:
    return false
  for kind in ptypes.LimitKind:
    if ev.limits[kind] == ptypes.lsFailed:
      return false
  true

type
  Gate* = object
    ## A gate passes iff the named environment variable is set AND non-empty
    ## after stripping whitespace.  v1 supports `env` only; the typed wrapper
    ## lets v1.1 add `file`/`cmd` variants without a schema break.
    env*: string

  CacheableState* = enum
    ## Per-group cacheable tri-state (RFC-0004 §144, A9).
    ## An explicit 3-valued enum is preferred over Option[bool] because the three
    ## states have distinct names that document intent at the call site.
    csDefault  ## absent from config: inherit global policy (read+write iff global on + hermeticity gate)
    csTrue     ## cacheable #true:  cache iff global policy enabled AND hermeticity gate passes
    csFalse    ## cacheable #false: absolute opt-out — never cache (read or write) for this
               ## group, even when the global policy enables caching; overrides csTrue/csDefault
               ## and the hermeticity gate.
               ##   → both read AND write are blocked; entrypoints report cdmGroupOptOut (M8)

  Group* = object
    ## A named collection of test entrypoints sharing globs, compile flags,
    ## opt-in status, an optional gate, and an optional per-group timeout.
    name*:        string
    globs*:       seq[string]
    flags*:       seq[string]         # compile flags injected for every entrypoint
    optIn*:       bool                # true = only runs when explicitly requested
    gate*:        Option[Gate]
    timeoutSecs*: int                 ## Per-group run timeout in seconds.
                                      ## ``0`` = inherit from global ``config.timeoutSecs``.
                                      ## Uses a 0-sentinel (not Option) because 0 is
                                      ## meaningless as a timeout value — no test should
                                      ## be allowed 0 seconds to run.
    maxJobs*:     Option[int]         ## Per-group concurrency cap.
                                      ## ``none`` = uncapped (inherit global ``plan.jobs``).
                                      ## ``some(1)`` = serial (one slot at a time for this
                                      ## group); ``some(N)`` = cap at N.
                                      ## Encoded as ``Option[int]`` (not a 0-sentinel) because
                                      ## 0 is a meaningful "uncapped" value — ``none`` is the
                                      ## only way to express "no cap".  This deliberately
                                      ## differs from ``timeoutSecs``'s 0-sentinel: a 0-second
                                      ## timeout is nonsensical, but a 0-job cap would mean
                                      ## "never run", not "uncapped".
    cacheable*:   CacheableState      ## Per-group cacheable tri-state (RFC-0004 §144, A9).
                                      ## csDefault (absent) = inherit global policy;
                                      ## csTrue = cache iff global on + hermeticity gate;
                                      ## csFalse = never cache (absolute; blocks read + write).
    retries*:     int                 ## How many times to retry a failing entrypoint in this
                                      ## group before declaring it failed.  0 = no retry (default).
                                      ## maxAttempts = retries + 1.

  PerfCheckConfig* = object
    ## C6: perf-regression detection policy, derived from the `perf-check` KDL block.
    ##
    ## Sensitivity presets (RFC §F6):
    ##   none:         disabled — no detection.
    ##   conservative: k=4.0, sampleFloor=20, absFloorMs=10 — strict; fewer flags.
    ##   moderate:     k=3.0, sampleFloor=10, absFloorMs=5  — RFC-fixed default preset.
    ##   aggressive:   k=2.0, sampleFloor=5,  absFloorMs=2  — more sensitive.
    ##
    ## Individual `k`, `sample-floor`, `abs-floor-ms` child nodes override the preset.
    ##
    ## Precedence (highest wins):
    ##   1. `--perf-check` CLI flag (forces enabled with moderate preset if no config block).
    ##   2. Config `perf-check` block with sensitivity≠"none" (block present + not "none").
    ##   3. Absent config block / sensitivity="none" / no CLI flag → disabled.
    enabled*:      bool   ## false = detection off (default; no-op everywhere it is checked)
    k*:            float  ## MAD multiplier (higher → fewer flags; lower → more sensitive)
    sampleFloor*:  int    ## minimum history rows required to flag (below → always false)
    absFloorMs*:   int    ## minimum MAD expressed in ms (converted to µs in isRegression)

  ReuseCheckConfig* = object
    ## M-report PASS (b1): compile-reuse alerting policy, derived from the
    ## `reuse-check` KDL block. SEPARATE surface from the (unconditional)
    ## `compile` measurement block itself — per RFC-0006, the alerting
    ## policy's default-on-ness is gated on Stage R (the object cache) being
    ## adopted. Stage R was built, measured, and subsequently REMOVED (A/B
    ## proved it didn't pay off on the target consumer), so this stays OFF
    ## BY DEFAULT; only an explicit `reuse-check { … }` config block enables
    ## it (mirrors
    ## PerfCheckConfig's enabled-gate shape, but with no preset system —
    ## presence of the block alone turns it on).
    enabled*:    bool   ## false = no alerting (default; block absent)
    alertBelow*: float  ## rTime threshold: segments with rTime below this
                        ## value produce a reuseAlerts entry. Default 0.5
                        ## when the block is present without 'alert-below'.

  Config* = object
    ## Top-level runtime configuration parsed from the project config file or
    ## built by the consuming library / CLI.
    groups*:             seq[Group]
    jobs*:               int          # 0 = max(1, countProcessors() - 2)
    timeoutSecs*:        int          # per-entrypoint run timeout (default 300)
    compileTimeoutSecs*: int          # per-entrypoint compile timeout (default 600)
    maxOutputBytes*:     int          # output cap per entrypoint (default 10 MiB)
    stateDir*:           string       # default ".crisol" at project root
    projectRoot*:        string       # set by loadConfig (config file's directory, or fallback
                                     # root per config-discovery rules); hand-set in tests
    depRoots*:           seq[string]  # optional additional source roots beyond the project root
                                     # (e.g. a sibling library under co-development); stdlib and
                                     # nimble-package paths are always excluded regardless
    ## Memory-aware scheduling seeds (Feature B, RFC-0002 §Config keys).
    ## All are optional; none = unset (built-in defaults apply at wiring time).
    ## Option[int] (not int with 0-sentinel) matches Group.maxJobs / memAware encoding.
    memBudgetMb*:  Option[int]  ## CI determinism cap (MiB). none = use probe raw (no cap).
                                ## Unit boundary: stored in MiB; converted to bytes where
                                ## consumed (in initAdmission / refreshAvail).
    memPerJobMb*:  Option[int]  ## estJobPeak seed (MiB). none = 512 MiB built-in.
    memPerRunMb*:  Option[int]  ## cdSkipFresh run estimate seed (MiB). none = 64 MiB built-in.
    memAware*:     Option[bool] ## Kill switch / force-on.
                                ## none   = auto (probe-availability decides at wiring time, S6b).
                                ## some(true)  = force mem-aware on.
                                ## some(false) = force mem-aware off → today's fixed-pool behavior.
                                ## Option[bool] (not plain bool) because "unset" is meaningfully
                                ## different from "set to false": absence means auto-detect,
                                ## not "disabled". A plain bool with a false default would
                                ## conflate the two. Consistent with Group.maxJobs encoding.
    retries*:      int          ## Global default: how many times to retry a failing entrypoint.
                                ## 0 = no retry (default).  Per-group retries override this
                                ## when non-zero (group > 0 wins; 0 means "inherit global").
                                ## maxAttempts = effectiveRetries(ep) + 1.
    maxCacheEntries*: int       ## A1c: max result-cache entries before GC evicts oldest (LRU).
                                ## 0 = use DefaultMaxCacheEntries (10 000).
                                ## The soft-cap in storeCached uses this at write time (backstop);
                                ## cleanOrphans uses it at GC time (real eviction).
    cacheMaxAgeDays*: int       ## A1c: evict cache entries older than this many days.
                                ## 0 = disabled (no age-based eviction).
                                ## Generous default of 0 (disabled) so existing users are
                                ## unaffected; opt-in via config.  Recommended: 30.
    ledgerMaxAgeDays*: int      ## A1c: drop ledger rows older than this many days during
                                ## compaction.  0 = disabled (keep all rows).
                                ## Consistent with cacheMaxAgeDays: opt-in, 0=disabled.
    quarantine*:   HashSet[string]
                                ## B3: set of entrypoint paths whose failures are EXCLUDED from
                                ## the exit-1 decision.  Paths are project-root-relative, '/'
                                ## separated, matched by raw string equality against ep.path.
                                ## Populated from the top-level `quarantine { "path" … }` KDL
                                ## block.  Empty set = no quarantine (default).
    perfCheck*:    PerfCheckConfig
                                ## C6: perf-regression detection policy.  Default = disabled
                                ## (PerfCheckConfig zero-value has enabled=false).
    reuseCheck*:   ReuseCheckConfig
                                ## M-report PASS (b1): compile-reuse alerting policy.  Default
                                ## = disabled (ReuseCheckConfig zero-value has enabled=false) —
                                ## OFF regardless of measureCompileReuse until an explicit
                                ## `reuse-check` config block opts in (Stage R not yet adopted).
    flags*:        seq[string] ## Issue #3 / RFC-0001:409: the raw global `flags` set, kept
                                ## separately from `Group.flags` (which is already
                                ## globalFlags & groupFlags, pre-merged per group). Used ONLY
                                ## as the fallback for an ad-hoc entrypoint — an explicit CLI
                                ## path matching no configured group runs with global flags
                                ## only, not a configured group's flags.
    measureCompileReuse*: bool ## RFC-0006 M-artifact-identity PASS (b2): when true, a compile
                                ## slot's child is the `--internal-measure-compile` measurement
                                ## worker (split-compile measurement, writes ArtifactRows)
                                ## instead of a plain `nim c` invocation. The worker produces the
                                ## SAME runnable binary at the same path either way, so the run
                                ## phase is unaffected; a measurement-layer failure never fails
                                ## the compile (see measureworker.nim). Default false: the
                                ## monolithic `nim c` path is byte-for-byte unchanged until an
                                ## operator opts in (`--measure-compile-reuse` / `measure-compile-
                                ## reuse #true` in crisol.kdl).
    strictHygiene*: bool       ## rfc-0007 A6b: OutcomePolicy.strictHygiene, resolved. When true,
                                ## a would-be pass with an OBSERVED escapee (evidence.escapees.len
                                ## > 0) derives oFailed instead of oPassed at every REPORTING trust
                                ## boundary (summarize -> exit code, render, JSON/junit wire,
                                ## lastrun.json) — never at the cache's own outcome() call, which
                                ## stays DefaultPolicy always (the cache stores/derives unstrict,
                                ## RFC-0007 §2); nor at live scheduling decisions (retry
                                ## eligibility, quarantine matching, ledger rows), which read the
                                ## unstrict observation like the cache does. Default false:
                                ## byte-for-byte unchanged until an operator opts in
                                ## (`--strict-hygiene` / `strict-hygiene #true` in crisol.kdl).
    rlimitNofile*: Option[int64]
                                ## Config-declared override for RLIMIT_NOFILE (max open fds) in the
                                ## hermetic sandbox. none = use sandbox.DefaultRlimitNofile (1024).
                                ## Populated from the top-level `rlimit-nofile N` KDL node, and/or
                                ## strengthened per-run by `RunOptions.rlimitNofile` (RunOptions wins
                                ## when set, mirroring jobs/timeoutSecs precedence in planImpl).
                                ## Lets a consumer with an fd-heavy workload (e.g. one eventfd per
                                ## in-flight async call) raise the ceiling without patching crisol.
    verifyCachePct*: int        ## RFC-0005 B3c: the `--verify-cache` sample-percentage DEFAULT a
                                ## config file can set (`verify-cache-pct N` KDL node) so an
                                ## invocation-time `--verify-cache` (with no `--verify-cache-pct`
                                ## override) samples at the project's chosen rate rather than the
                                ## built-in 5. Only `pct` is a config key -- `enabled`/`seed`/
                                ## `strict` stay CLI-only per the RFC's config-additions list.
                                ## Always resolved to a concrete value by config.loadConfig
                                ## (defaults to config.DefaultVerifyCachePct when the KDL node is
                                ## absent) -- never a sentinel, mirroring timeoutSecs.
    workerBinary*: string       ## INTERNAL plumbing (not user-facing; no KDL node). Absolute path
                                ## to a binary whose `main()` dispatches the
                                ## `--internal-measure-compile` token (see measureworker.nim /
                                ## crisol.nim's runMain). Required for measureCompileReuse's
                                ## self-reexec worker to be sound: `getAppFilename()` returns the
                                ## CURRENTLY RUNNING process's binary, which is only the right
                                ## worker host when that process IS such a binary (i.e. the crisol
                                ## CLI). A library consumer's host process is NOT that binary, so
                                ## crisol must never call getAppFilename() on its behalf — doing so
                                ## makes the "worker" re-exec the host program itself (unbounded
                                ## recursive fork, only stopped by the compile watchdog). Default
                                ## "" = no sound worker available; spawnCompileStable degrades to
                                ## the monolithic `nim c` path (measurement skipped) instead of
                                ## guessing. The crisol CLI populates this with its own
                                ## `getAppFilename()`; library callers set it via
                                ## `RunOptions.workerBinary`.

  GroupSelectionKind* = enum
    gskDefault    ## run all non-opt-in groups
    gskNamed      ## run only the explicitly named groups
    gskAll        ## run every group, including opt-in ones
    gskFiles      ## run only the explicitly listed paths/globs (CLI positional args)

  GroupSelection* = object
    ## Describes which entrypoints to discover.  The variant field prevents an
    ## empty name/paths list from being confused with "run defaults".
    ## gskFiles carries the list of paths/globs given on the CLI; discover()
    ## synthesises a transient "paths" group from them (no mutation of Config).
    case kind*: GroupSelectionKind
    of gskNamed: names*: seq[string]
    of gskFiles:
      paths*: seq[string]
      withinGroups*: seq[string]
        ## Issue #3: the `--group` names given ALONGSIDE positional paths.
        ## Empty (the common case) = every configured group is a candidate
        ## owner for each path.  Non-empty = only these named groups are
        ## candidates; a path outside all of them is ad-hoc (RFC-0001:409),
        ## not silently dropped.
    else: discard

  Entrypoint* = object
    ## A single .nim file to be compiled and run as a test binary.
    ## Derived paths (nimcache dir, binary path) are computed by helpers —
    ## never stored — so a hand-built Entrypoint cannot carry a corrupt slug.
    path*:  string          # project-root-relative, '/' separated
    group*: string
    flags*: seq[string]     ## The EFFECTIVE compile flags: global then group, merged
                            ## at config-parse time (config.parseGroup).  (path, flags)
                            ## is the entrypoint's identity — slug, nimcache, result
                            ## cache and depgraph all key on it — so the same path
                            ## under two groups with different flags is two legs.
    runTimeoutSecs*: int    ## Per-entrypoint run timeout inherited from the group.
                            ## 0 = inherit from global config.timeoutSecs.
                            ## Does NOT participate in the depgraph key (path, flagHash);
                            ## freshness/impact selection are unaffected.

  CompileDecision* = enum
    cdNeverBuilt   ## no binary exists at the keyed path
    cdStale        ## binary exists but source/dep/flags/version changed
    cdSkipFresh    ## binary provably current — all freshness conditions met

  EntrypointDecision* = enum
    ## RFC-0004 F3: the single sealed sum over crisol's plan/run decision.
    ## Replaces the (CompileDecision × ExecutionDecision) product so illegal
    ## states like (cdNeverBuilt, edCached) are unrepresentable — edCached
    ## *requires* a fresh binary, so the domain is not a product.
    ##
    ## The execute loop branches on THIS single field.  External consumers that
    ## want the old compile view recover it via the mapping:
    ##   edNeverBuilt → cdNeverBuilt
    ##   edStale      → cdStale
    ##   edRunFresh   → cdSkipFresh
    ##   edCached     → cdSkipFresh  (freshness is implied)
    edNeverBuilt   ## no binary; compile + run
    edStale        ## binary stale; compile + run
    edRunFresh     ## binary fresh; skip compile, run
    edCached       ## binary fresh AND result cached; skip both (freshness implied)

  CacheDecision* = enum
    ## RFC-0004 F3: structural cache observability, ALWAYS populated on every
    ## EntrypointResult — answers "why did/didn't this cache?" without strace.
    ## Reporting/serialization of this field is A8; A6 only populates it.
    ##
    ## cdmNotEligible is FIRST (enum ord 0) so a default-constructed
    ## EntrypointResult reads as "cache not consulted" — the safe default; the
    ## runner overwrites it explicitly on every result it produces.
    ##
    ## M8 distinctions (previously conflated):
    ##   cdmKeyMiss vs cdmStored:   both are fresh runs on a miss; cdmStored means
    ##     the result was written to the cache; cdmKeyMiss means it ran but was NOT
    ##     stored, for a reason not covered by one of the other, more specific
    ##     variants below (cdmHermeticityDeg, cdmFlaky, cdmClosureUnrecorded each
    ##     split out of what would otherwise be cdmKeyMiss so a `--json` reader
    ##     can tell WHY a result wasn't cached without inferring from inputHash
    ##     presence or cross-referencing stderr).
    ##   cdmGroupOptOut vs cdmPolicyDisabled:  cdmGroupOptOut is the per-group
    ##     `cacheable #false` config knob (permanent, config-declared opt-out);
    ##     cdmPolicyDisabled is the invocation-level `--no-cache` flag.
    cdmNotEligible        ## edNeverBuilt/edStale; cache not consulted
    cdmHit                ## served from cache (plan-time hit)
    cdmStored             ## fresh run on a miss; result WAS written to the cache
    cdmKeyMiss            ## fresh run on a miss; result was NOT stored (see M8 notes)
    cdmHermeticityDeg     ## hermeticity degraded; gate blocked the write
    cdmGroupOptOut        ## per-group `cacheable #false` config; absolute cache opt-out
    cdmPolicyDisabled     ## invocation `--no-cache` flag; cache bypassed this run
    cdmFlaky              ## flaky-pass (attempt > 1); not stored
    cdmClosureUnrecorded  ## fresh run; store refused because the entrypoint's source
                           ## closure could not be recorded (see depgraph.recordClosure)
                           ## — the key would carry an empty closureContentHash and
                           ## could never be looked up
    cdmRecomputeMiss      ## rfc-0007 A1d-ii / §2: a cache entry EXISTED, but its
                           ## recomputed outcome (outcome(r), recomputed at the
                           ## trust boundary, never trusted from storage) is not
                           ## oPassed — e.g. a derivation/policy change since the
                           ## entry was stored.  Treated as a MISS and rerun; distinct
                           ## from cdmKeyMiss (no entry was found at all).

  PlannedEntrypoint* = object
    ## A single entrypoint annotated with its compile decision and reason.
    ep*:          Entrypoint
    edecision*:   EntrypointDecision  ## RFC F3 single sealed sum; execute branches on this.
                                      ## Set by planner.toEntrypointDecision(compileDecision);
                                      ## promoted to edCached by the plan-time cache lookup.
                                      ## M3: this is the canonical decision field; the old
                                      ## `decision: CompileDecision` field has been removed.
                                      ## Use compileView(pep) for the compile-only projection.
    reason*:      string         # human-readable detail; surfaced by list/--dry-run
    runTimeoutMs*: int           ## precomputed; set by plan() in planner.nim
    maxJobs*:      Option[int]   ## precomputed; set by plan() in planner.nim
    cacheable*:    CacheableState ## precomputed from group; set by plan() in planner.nim (A9)
                                  ## csDefault = inherit global policy; csTrue = cache iff
                                  ## global on + hermeticity gate; csFalse = never cache.
    retries*:      int            ## precomputed effective retry count (B1); set by plan().
                                  ## maxAttempts = retries + 1.  0 = no retry.

proc compileView*(pep: PlannedEntrypoint): CompileDecision =
  ## M3: Pure accessor that derives the compile-only view FROM edecision.
  ## Replaces the removed `decision: CompileDecision` field.
  ## Use this when reporting code needs to distinguish compile decisions
  ## without caring about cache status.
  ##   edNeverBuilt → cdNeverBuilt
  ##   edStale      → cdStale
  ##   edRunFresh   → cdSkipFresh
  ##   edCached     → cdSkipFresh  (edCached implies a fresh binary)
  case pep.edecision
  of edNeverBuilt: cdNeverBuilt
  of edStale:      cdStale
  of edRunFresh:   cdSkipFresh
  of edCached:     cdSkipFresh

type
  RunPlan* = object
    ## The output of plan(): a fully annotated, ready-to-execute list.
    entrypoints*: seq[PlannedEntrypoint]
    jobs*:        int          # resolved by plan(); never 0

  RecordStatus* = enum rsPass, rsFail, rsSkip
    ## Per-test-record status from the structured result protocol.
    ## Named RecordStatus (not TestStatus) to avoid clashing with
    ## std/unittest's internal TestStatus enum in test files.

  TestRecord* = object
    name*:       string
    status*:     RecordStatus
    durationUs*: int64
    msg*:        Option[string]  # failure message or skip reason
    tags*:       seq[string]

  EntrypointResult* = object
    ## Canonical per-entrypoint result produced by execute().
    ep*:             Entrypoint
    compile*, run*:  ptypes.Phase  ## rfc-0007 §2: the ONE observation this result
                                   ## carries — every reported verdict (outcome,
                                   ## exit code, signal, cause, cached-ness, flaky-
                                   ## ness) is derived from these two Phase values
                                   ## (+ attempts, below), never stored redundantly.
                                   ## Zero-value default (kind: pkSkipped for
                                   ## both) for any result predating this
                                   ## window (e.g. a cache-hit synthesis) —
                                   ## cachedispatch.synthesize populates a
                                   ## minimal honest replay from the fields
                                   ## it has (see that module).
    records*:        seq[TestRecord]  ## empty when the protocol was not used
    output*:         string        ## captured stdout+stderr, capped at maxOutputBytes
    outputTruncated*: bool         ## maxOutputBytes cap hit
    compileSkipped*: bool          ## cdSkipFresh: nim c was not invoked
    durationMs*:     int64         ## wall-clock milliseconds (A3 uses ms; A4+ switches to Us)
    inputHash*:      string        ## RFC F3 (A8): the soundnessKey string for this entrypoint —
                                   ## the content fingerprint over all soundness inputs.  Wire/JSON
                                   ## name "inputHash".  Populated wherever the key is derived
                                   ## (cache hit, fresh-run store gate, and plan-time lookup); "" when
                                   ## caching was not consulted (edNeverBuilt/edStale, --no-cache, or
                                   ## no seams wired).
    cacheDecision*:  CacheDecision ## RFC F3: ALWAYS populated; why this did/didn't cache.
                                   ## Default field value is cdmNotEligible (enum ord 0, the
                                   ## safe "cache not consulted" default); the runner sets it
                                   ## explicitly on every result it produces.
    attempts*:       int              ## B1: how many attempts were made (1 on a clean pass;
                                      ## > 1 means at least one prior attempt failed).
                                      ## Populated by execute(); 0 for cached results (no run).
    quarantined*:    bool             ## B3: true iff ep.path ∈ Config.quarantine.
                                      ## A quarantined failure is REPORTED but excluded from
                                      ## Summary.failed and the exit-1 decision.
                                      ## A quarantined pass is harmless (quarantined=true, passes
                                      ## normally).  Set by execute() post-result, not by compile
                                      ## or run logic — pure reporting overlay.
    regressed*:      bool             ## C6: true iff perf-check is enabled AND this entrypoint's
                                      ## current duration exceeded median+k·MAD of its prior history.
                                      ## Always false when perf-check is disabled or edCached.
    perfBaselineUs*: int64            ## C6: historical median used for regression comparison (µs).
                                      ## 0 when perf-check is disabled or sampleFloor not met.
    perfThresholdUs*: int64           ## C6: median + k·MAD threshold (µs).
                                      ## 0 when perf-check is disabled or sampleFloor not met.

  Summary* = object
    ## Raw aggregate counts — constructible in tests, no strings.
    total*:        int
    passed*:       int
    failed*:       int
    compileFailed*: int
    spawnErrors*:  int
    flaky*:        int   ## B1: count of flaky-passes (passed AND attempts > 1)
    quarantined*:  int   ## B3: count of FAILED results whose failure is excluded from exit-1
                         ## because ep.path ∈ Config.quarantine.  Quarantined failures are NOT
                         ## counted in failed/compileFailed/spawnErrors/counts[oKilled]/
                         ## counts[oCrashed]. Quarantined passes count normally in `passed`.
    noTestsRan*:   bool  ## e.g. every entrypoint failed to compile
    counts*:       array[Outcome, int]
                         ## rfc-0007 A1e-i: derived-outcome counts (outcome(r)
                         ## folded over every non-quarantined-failure result;
                         ## same quarantine exclusion as the hand-maintained
                         ## counters above). The ONLY accounting for the killed/
                         ## crashed buckets — there is no scalar counterpart
                         ## (the legacy timedOut/signaled counters are gone).
    notStarted*:   int   ## rfc-0007 A1d-i: count of entries OMITTED from the
                         ## emission set because their next phase never
                         ## started (queued, or compile-done-run-unstarted) —
                         ## §2's "no representable 'run never started' state"
                         ## rule.  Always 0 until A1e-ii wires real interrupt
                         ## partial-run omission; summarize() does not yet
                         ## produce a non-zero value (it only ever sees the
                         ## already-emitted result set), so this is an honest
                         ## placeholder, not a fabricated zero.

  GateStateEntry* = tuple[name: string; value: string]
    ## Internal element of GateState; exported so discover.nim can read it.
    ## External consumers have no documented contract on this type — it is an
    ## implementation detail; only initGateState/loadGateState/applyGates are
    ## part of the public API.

  GateState* = object
    ## Opaque snapshot of gate env-var values captured once by loadGateState.
    ## Tests use initGateState; production code uses loadGateState.
    ## The internal seq maps env-var name → trimmed value (empty when unset or
    ## blank at capture time).  Treat as opaque; use only through the documented
    ## API (loadGateState, initGateState, applyGates).
    vars*: seq[GateStateEntry]

  DiscoveredSet* = object
    ## Returned exclusively by discover(); consumed exclusively by applyGates().
    ## Wrapping `entries` in a dedicated (non-seq-compatible) type enforces
    ## gate-application by type — silently skipping applyGates() is a compile
    ## error, not a runtime surprise.
    entries*:        seq[Entrypoint]
    adHocPaths*:      seq[string]
      ## Issue #3 / RFC-0001:409: gskFiles paths that matched no configured
      ## group (or none of `GroupSelection.withinGroups` when given) — they
      ## ran as an ad-hoc "paths" entrypoint with global flags only.  discover()
      ## stays pure (no stderr writes); the CLI layer reads this to print the
      ## RFC-0001:409 warning.  Always empty outside a gskFiles selection.
      ## (A path owned by several groups is not ambiguous — it is several
      ## legs, one per group, issue #10 — so nothing is recorded for it.)

  GatedEntry* = tuple[path: string; group: string; reason: string]
    ## One discovered-but-gated-out entrypoint with its gate reason.
    ## Produced by applyGates (discover); surfaced by buildRunPlan; consumed by
    ## planview (rendering) and jsonout.

  ClosureEntry* = object
    ## Issue #9 slice A: one planned entrypoint's depgraph record, as read
    ## back by the `crisol closure` CLI subcommand / api.closureReport().
    ## A downstream consumer (e.g. amoxtli) reads this instead of
    ## re-implementing the depgraph loader (nim-version probe mismatch would
    ## otherwise silently yield an empty graph) or group/flag resolution.
    path*:        string          ## entrypoint path, as planned (project-relative)
    group*:       string          ## resolved group name
    flagHash*:    string          ## flagHash(ep.flags); 16 hex chars
    recorded*:    bool            ## true iff the depgraph has an entry for (path, flagHash)
    closure*:     seq[string]     ## sorted closure paths as stored in the depgraph:
                                   ## project-root-relative with forward slashes for
                                   ## files inside the project root; ABSOLUTE for
                                   ## files under a configured dep-root (outside the
                                   ## project root — see depgraph.DepGraphEntry.closure).
                                   ## Empty when `recorded` is false.
    closureHash*: string          ## 16 hex chars; "" when not recorded

  ClosureReport* = object
    ## Output of api.closureReport(): one ClosureEntry per planned entrypoint
    ## (one per group/flag-set it belongs to), plus any config warnings from
    ## the underlying plan phase.
    entries*:         seq[ClosureEntry]
    warnings*:        seq[ConfigWarning]
    adHocPaths*:      seq[string]
      ## gskFiles paths that matched no configured group (ran ad-hoc,
      ## global flags only) — mirrors PlanReport.adHocPaths / DiscoveredSet.
      ## Always empty for `--all` (gskAll selection). The CLI layer turns
      ## this into warning lines via render.pathFlagsWarnings, same as
      ## `run`/`list`.
    gatedOut*:        seq[GatedEntry]
      ## Discovered-but-gated-out entrypoints — mirrors PlanReport.gatedOut.
      ## A positional path whose only match is gated out lands HERE, not in
      ## `entries`; the CLI treats that the same as `run`'s zrkAllGated exit-0
      ## branch rather than as "no entrypoints matched".

  SelectionReason* = enum
    srClosureHit     ## Known fresh closure that intersects `changed` → run it.
    srUnknownClosure ## Graph present but no entry for this (path, flagHash) key.
    srStaleEntry     ## Entry exists but a closure file is missing on disk.
    srOwnFileChanged ## The entrypoint's own source file appears in `changed`.
    srGraphAbsent    ## The graph is entirely absent/empty — no information at all.

  SelectionResult* = tuple[ep: Entrypoint; reason: SelectionReason]
    ## A selected entrypoint annotated with why it was included.

  ConfigWarning* = object
    ## A diagnostic emitted when an unrecognized key is found in the config
    ## file.  The human message is composed once at the warning site so neither
    ## the CLI (stderr) nor the JSON schema need to duplicate the formatting.
    source*:  string   ## config file path; "" = convention fallback
    context*: string   ## "top-level" or the group name
    key*:     string   ## the unrecognized node name
    message*: string   ## fully composed: "unknown config key '<key>' in <context> (ignored)"

  CrisolErrorKind* = enum
    cekConfig       ## bad config, unknown group, overlapping identical-flag globs
    cekEnvironment  ## nim/git missing, temp-dir failure, lock held
    cekInternal     ## invariant violation; should never occur in normal operation

  CrisolError* = object of CatchableError
    kind*: CrisolErrorKind

  # rfc-0007 A1e-ii: CrisolInterrupted is RETIRED — a SIGINT/SIGTERM is no
  # longer an exception, it is an honest partial result (§2). execute()
  # reports it via the `interruptedOut: ptr bool` out-param instead, and
  # api.nim's RunReport gains `interrupted: bool` (see api.nim/runner.nim).

  ResultCallback* = proc(r: EntrypointResult) {.closure.}
    ## Per-entrypoint progress callback.  Called by execute() with the result
    ## of each entrypoint as soon as it completes.  Exported here (types.nim)
    ## so `import crisol/api` exposes the callback type without pulling in runner.

proc newCrisolError*(kind: CrisolErrorKind; msg: string): ref CrisolError =
  ## Construct a CrisolError ready for `raise`.
  result = (ref CrisolError)(kind: kind, msg: msg)

# ---------------------------------------------------------------------------
# Outcome helpers
# ---------------------------------------------------------------------------

proc outcomeString*(o: Outcome): string =
  ## Returns the stable JSON wire string for an Outcome enum value.
  ## Single source of truth — outcomestrings.nim and jsonout.nim derive
  ## their constants and delegating proc from this mapping.
  ## Wire values are defined by the crisol/run/v2 schema and must never change.
  case o
  of oPassed:        "passed"
  of oFailed:        "exitNonZero"
  of oCompileFailed: "compileFailed"
  of oSpawnError:    "spawnError"
  of oKilled:        "killed"
  of oCrashed:       "crashed"

proc isFailure*(o: Outcome): bool =
  ## Returns true for any outcome that contributes to a non-zero exit code.
  o in {oFailed, oCompileFailed, oSpawnError, oKilled, oCrashed}

# ---------------------------------------------------------------------------
# rfc-0007 §2: the pure derivation over the real EntrypointResult (A1e-i).
#
# Lives HERE, not in process/types.nim: process/types cannot reference
# EntrypointResult (it is defined in THIS module, and process/types must not
# import this module — see the dependency-inversion note at the top of this
# file). Named `outcome` — safe now that the legacy `outcome` FIELD is gone
# (it used to silently shadow-collide with a same-named proc, hence this proc
# carried a differently-named placeholder during the A1a..A1d window; A1e-i
# is the rename to its permanent name).
# ---------------------------------------------------------------------------

proc hasFailRecords*(r: EntrypointResult): bool =
  ## true iff any PARSED protocol record is a failure. A truncated/corrupt
  ## stream never fabricates a failure — the reader stays conservative (§2).
  for rec in r.records:
    if rec.status == rsFail: return true
  false

proc outcome*(r: EntrypointResult;
             policy: ptypes.OutcomePolicy = ptypes.DefaultPolicy): Outcome =
  ## PURE over (result, policy) — §2's total case expression, verbatim.
  ## Recomputed at every crisol trust boundary (cache load, render, exit-code
  ## derivation) — there is no stored field to trust instead (A1e-i deleted it).
  case r.compile.kind
  of ptypes.pkSpawnFailed:
    return oSpawnError
  of ptypes.pkRan, ptypes.pkCached:
    let c = r.compile.res
    if c.cause.by == ptypes.cbRunner and c.cause.reason == ptypes.krInterrupt:
      return oKilled              ## Ctrl-C mid-compile is not a compile failure
    if c.cause.by != ptypes.cbProcess or not ptypes.isSuccess(c.exit):
      return oCompileFailed       ## incl. compile timeout — the cause is
                                   ## consulted, so a cooperative exit-0 inside
                                   ## a compile-kill grace window cannot
                                   ## masquerade as a good compile
  of ptypes.pkSkipped:
    discard                       ## fresh — nothing to prove
  case r.run.kind
  of ptypes.pkSpawnFailed:
    oSpawnError
  of ptypes.pkSkipped:
    oSpawnError                   ## unreachable in any EMITTED result: a good
                                   ## compile is always followed by a run phase
                                   ## (§2) — derives loudly rather than lying
  of ptypes.pkRan, ptypes.pkCached:
    let p = r.run.res
    if p.cause.by == ptypes.cbRunner:
      oKilled
    elif p.exit.kind != ptypes.ekExited:
      oCrashed                    ## signaled/ntstatus; cause may be limit
                                   ## or external
    elif p.exit.code == 0 and not r.hasFailRecords:
      if policy.strictHygiene and p.evidence.escapees.len > 0: oFailed
      else: oPassed
    else:
      oFailed

proc runEvidence*(r: EntrypointResult): ptypes.Evidence =
  ## rfc-0007 A6a: the run phase's real, backend-observed `Evidence` when
  ## there is one (pkRan/pkCached — a cache hit replays the STORED
  ## observation verbatim, §2); the ord-0 default (weakest claim, never a
  ## vouch) otherwise. The single derivation point `evidenceSatisfies`/
  ## `hasEscapees`/the render warning all read through — no separate
  ## "achieved" value is ever threaded alongside `res` again.
  case r.run.kind
  of ptypes.pkRan, ptypes.pkCached: r.run.res.evidence
  of ptypes.pkSkipped, ptypes.pkSpawnFailed: default(ptypes.Evidence)

proc hasEscapees*(r: EntrypointResult): bool =
  ## rfc-0007 A6a (§6): true iff the run phase observed same-pgroup
  ## survivors at reap time — the cache-gate fact and the render/CLI
  ## warning both key off this, never a separate bit.
  runEvidence(r).escapees.len > 0

proc cached*(r: EntrypointResult): bool =
  ## Derived (A1e-i): RFC F3 — true iff this result replays a stored
  ## ExecutionCache observation (edCached) rather than a live run this
  ## invocation. `run.kind == pkCached` IS the fact; no separate bit to drift.
  r.run.kind == ptypes.pkCached

proc flaky*(r: EntrypointResult;
           policy: ptypes.OutcomePolicy = ptypes.DefaultPolicy): bool =
  ## Derived (B1, A1e-i): true iff outcome(r, policy) == oPassed AND
  ## attempts > 1. A flaky-pass counts toward exit 0 by default;
  ## --fail-on-flaky promotes it to exit 1.
  r.attempts > 1 and outcome(r, policy) == oPassed

proc exitCode*(s: Summary; failOnFlaky: bool = false): int =
  ## Returns 0 when all entrypoints passed; 1 when any failed.
  ## When failOnFlaky is true, flaky-passes also contribute to exit 1.
  if s.failed > 0 or s.compileFailed > 0 or s.spawnErrors > 0 or
     s.counts[oKilled] > 0 or s.counts[oCrashed] > 0: return 1
  if failOnFlaky and s.flaky > 0: return 1
  0

# ---------------------------------------------------------------------------
# RFC-0005 B3a: pure --verify-cache sampler
# ---------------------------------------------------------------------------

proc sampleHitIndices*(decisions: openArray[CacheDecision]; pct: int;
                       seed: int64): seq[int] =
  ## Pure, deterministic sampler for the `--verify-cache` post-run pass
  ## (RFC-0005 Stage B). `decisions[i]` is the `cacheDecision` of the i'th
  ## entrypoint of the run being verified; the caller hands the parallel seq
  ## (never a PlannedEntrypoint/EntrypointResult directly) so this proc stays
  ## fixture-vector testable.
  ##
  ## Selection basis: the "hit set" is every index i where
  ## `decisions[i] == cdmHit`. Sample size is `max(1, pct*hits/100)`,
  ## applied whenever `pct > 0` AND the hit set is non-empty; the result is
  ## `@[]` otherwise (`pct <= 0`, or no hits at all — a caller must never see
  ## a synthetic 1-entry sample float out of a run with zero cache hits).
  ##
  ## Deterministic: the SAME `(decisions, pct, seed)` always returns the SAME
  ## seq, in ascending index order — no wall-clock/PID entropy anywhere in
  ## the selection, matching the RFC's "seeded PRNG" requirement (the default
  ## per-run seed is the CALLER's concern — B3c reports it in the summary
  ## line; this proc only consumes whatever seed it is given).
  var hits: seq[int]
  for i, d in decisions:
    if d == cdmHit: hits.add i
  if pct <= 0 or hits.len == 0:
    return @[]
  let sampleSize = max(1, (pct * hits.len) div 100)
  var rng = initRand(seed)
  rng.shuffle(hits)
  result = hits[0 ..< min(sampleSize, hits.len)]
  result.sort()
