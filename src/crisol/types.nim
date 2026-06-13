## types.nim — crisol canonical core types
##
## All types shared by discover, plan, and execute. Only what A1–A3 needs is
## defined here; later slices append without touching the existing definitions.

import std/options

type
  Gate* = object
    ## A gate passes iff the named environment variable is set AND non-empty
    ## after stripping whitespace.  v1 supports `env` only; the typed wrapper
    ## lets v1.1 add `file`/`cmd` variants without a schema break.
    env*: string

  Group* = object
    ## A named collection of test entrypoints sharing globs, compile flags,
    ## opt-in status, an optional gate, and an optional per-group timeout.
    name*:        string
    globs*:       seq[string]
    flags*:       seq[string]         # compile flags injected for every entrypoint
    optIn*:       bool                # true = only runs when explicitly requested
    gate*:        Option[Gate]
    timeoutSecs*: int                 # 0 = inherit global timeout

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
    of gskFiles: paths*: seq[string]
    else: discard

  Entrypoint* = object
    ## A single .nim file to be compiled and run as a test binary.
    ## Derived paths (nimcache dir, binary path) are computed by helpers —
    ## never stored — so a hand-built Entrypoint cannot carry a corrupt slug.
    path*:  string          # project-root-relative, '/' separated
    group*: string
    flags*: seq[string]     # group.flags (global flags merged at plan time)

  CompileDecision* = enum
    cdNeverBuilt   ## no binary exists at the keyed path
    cdStale        ## binary exists but source/dep/flags/version changed
    cdSkipFresh    ## binary provably current — all freshness conditions met

  PlannedEntrypoint* = object
    ## A single entrypoint annotated with its compile decision and reason.
    ep*:       Entrypoint
    decision*: CompileDecision
    reason*:   string         # human-readable detail; surfaced by list/--dry-run

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

  Outcome* = enum
    oPassed         ## exit 0, no protocol failure records
    oFailed         ## exit non-zero, or ≥ 1 fail record from protocol
    oCompileFailed  ## nim c exited non-zero or timed out during compile
    oTimeout        ## run phase exceeded timeout
    oSignal         ## run phase killed by a signal (SIGSEGV, SIGABRT, …)
    oSpawnError     ## fork/exec failed at the OS level

  EntrypointResult* = object
    ## Canonical per-entrypoint result produced by execute().
    ep*:             Entrypoint
    outcome*:        Outcome
    exitCode*:       int           ## WEXITSTATUS when exited normally
    signal*:         int           ## POSIX signal number when outcome == oSignal
    records*:        seq[TestRecord]  ## empty when the protocol was not used
    output*:         string        ## captured stdout+stderr, capped at maxOutputBytes
    outputTruncated*: bool         ## maxOutputBytes cap hit
    compileSkipped*: bool          ## cdSkipFresh: nim c was not invoked
    durationMs*:     int64         ## wall-clock milliseconds (A3 uses ms; A4+ switches to Us)

  Summary* = object
    ## Raw aggregate counts — constructible in tests, no strings.
    total*:        int
    passed*:       int
    failed*:       int
    compileFailed*: int
    timedOut*:     int
    signaled*:     int
    spawnErrors*:  int
    noTestsRan*:   bool  ## e.g. every entrypoint failed to compile

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

  DiscoveredSet* = distinct seq[Entrypoint]
    ## Returned exclusively by discover(); consumed exclusively by applyGates().
    ## The distinct type enforces gate-application by type — silently skipping
    ## applyGates() is a compile error, not a runtime surprise.

  GatedEntry* = tuple[path: string; group: string; reason: string]
    ## One discovered-but-gated-out entrypoint with its gate reason.
    ## Produced by applyGates (discover); surfaced by buildRunPlan; consumed by
    ## planview (rendering) and jsonout.

  SelectionReason* = enum
    srClosureHit     ## Known fresh closure that intersects `changed` → run it.
    srUnknownClosure ## Graph present but no entry for this (path, flagHash) key.
    srStaleEntry     ## Entry exists but a closure file is missing on disk.
    srOwnFileChanged ## The entrypoint's own source file appears in `changed`.
    srGraphAbsent    ## The graph is entirely absent/empty — no information at all.

  SelectionResult* = tuple[ep: Entrypoint; reason: SelectionReason]
    ## A selected entrypoint annotated with why it was included.

  CrisolErrorKind* = enum
    cekConfig       ## bad config, unknown group, overlapping identical-flag globs
    cekEnvironment  ## nim/git missing, temp-dir failure, lock held
    cekInternal     ## invariant violation; should never occur in normal operation

  CrisolError* = object of CatchableError
    kind*: CrisolErrorKind

  CrisolInterrupted* = object of CatchableError
    ## Raised by execute() when a signal (SIGINT or SIGTERM) is received while
    ## the poll loop is running.  The signum field carries the raw signal number
    ## (e.g. 2 for SIGINT, 15 for SIGTERM) so the CLI can compute 128+signum.
    ## Tests that call execute() without installing signal handlers never see
    ## this exception.
    signum*: cint

proc newCrisolError*(kind: CrisolErrorKind; msg: string): ref CrisolError =
  ## Construct a CrisolError ready for `raise`.
  result = (ref CrisolError)(kind: kind, msg: msg)

proc newCrisolInterrupted*(signum: cint): ref CrisolInterrupted =
  ## Construct a CrisolInterrupted ready for `raise`.
  result = (ref CrisolInterrupted)(
    signum: signum,
    msg: "interrupted by signal " & $int(signum),
  )

# ---------------------------------------------------------------------------
# Outcome helpers
# ---------------------------------------------------------------------------

proc isFailure*(o: Outcome): bool =
  ## Returns true for any outcome that contributes to a non-zero exit code.
  o in {oFailed, oCompileFailed, oTimeout, oSignal, oSpawnError}

proc exitCode*(s: Summary): int =
  ## Returns 0 when all entrypoints passed; 1 when any failed.
  if s.failed > 0 or s.compileFailed > 0 or s.timedOut > 0 or
     s.signaled > 0 or s.spawnErrors > 0: 1
  else: 0
