## pipeline.nim — crisol plan pipeline (R8: internal plan-phase orchestration)
##
## This module is an internal module; the public library entry point is api.nim.
## Given a Config and a GroupSelection it runs the full pure plan phase and
## returns a RunPlanView that runcore.nim can inspect and feed into execute().
##
## ## Pipeline invariant
##
##   discover(cfg, selection)
##     → applyGates(discovered, cfg, gateState)
##       → [optional narrowing: --failed ∩ failedKeys, --changed ∩ diff]
##         → plan(cfg, runnable, graph, forceCompile)
##
## All steps are pure (no I/O beyond the file-system reads in discover/plan).
## The effectful seams — loadGateState, loadDepGraph — are called here once
## and the results are passed to the pure steps.
##
## ## Public API
##
##   RunPlanView* = object
##     plan*:     RunPlan             ## fully annotated, ready to execute
##     gatedOut*: seq[GatedEntry]     ## discovered-but-gated-out entries
##     runnable*: int                 ## count of entrypoints that will run
##     graph*:    DepGraph            ## the dep graph (may be updated by execute)
##
##   buildRunPlan*(cfg, selection, …): RunPlanView
##     Pure plan phase. No subprocess is spawned. No I/O beyond reading the
##     dep graph and gate env vars. CLI-only concerns (arg parsing, exit code
##     mapping, stdout writing) are NOT present here.

import std/[sequtils, sets]
import crisol/[types, config, discover, depgraph, planner, narrow, shard, order]
import crisol/ccidentity  # CcProbeContext -- what the C toolchain probe reads

# ---------------------------------------------------------------------------
# ccProbeContextOf -- the C toolchain probe's view of a configuration
# ---------------------------------------------------------------------------

proc ccProbeContextOf*(cfg: Config): CcProbeContext =
  ## What the C toolchain probe reads from a loaded configuration: the project
  ## root (the discovery compile's cwd), the absolute state directory (its
  ## scratch space) and the global crisol.kdl flags (which can change the
  ## compiler Nim selects). The run's plan phase (`runcore.planImpl`) and the
  ## CLI's `clean` both build the probe's context here.
  CcProbeContext(projectRoot: cfg.projectRoot, stateDir: stateDirOf(cfg),
                 flags: cfg.flags)

# ---------------------------------------------------------------------------
# Public result type
# ---------------------------------------------------------------------------

type
  RunPlanView* = object
    ## The output of buildRunPlan.  Passed to the CLI for rendering and
    ## (for `run`) handed to execute() for execution.
    plan*:     RunPlan
    gatedOut*: seq[GatedEntry]
    runnable*: int                 ## count of runnable entrypoints AFTER narrowing
    graph*:    DepGraph            ## caller may mutate (depgraph recording)
    warnings*: seq[ConfigWarning]  ## config warnings (unknown keys etc.) from loadConfig
    adHocPaths*:     seq[string]   ## Issue #3 / RFC-0001:409: from discover()'s gskFiles
                                   ## resolution — paths that matched no candidate group.

# ---------------------------------------------------------------------------
# buildRunPlan — the SHARED pure plan phase
# ---------------------------------------------------------------------------

# SOUNDNESS-PARAMETER WARNING (round-4 review, R4-4, 2026-09-24): `nimVersion`
# below is a soundness parameter and no longer carries a default. What it
# governs FROM HERE is the dep-graph FRESHNESS view: it is handed to
# `loadDepGraph` below, and a caller that passes "" also persists a header
# stamped "", so every later load compares "" against "" and "the Nim compiler
# moved" can never be observed — a graph built by a DIFFERENT Nim is accepted
# as fresh.
#
# CORRECTED round 5 (R5-7, 2026-09-24): this note used to claim a second
# surface — that `nimVersion` "flows through `plan` into
# `planner.toolchainFingerprint` and thence `planner.cachePath`". It does not,
# and did not when that sentence was written (R4-4, round 4): `plan` has never
# called either proc, and since R5-24 it does not take `nimVersion`/`ccVersion`
# at all. The persistent-nimcache
# key is computed inside `runner.execute` (and `clean.cleanOrphans`) from the
# `nimVersion`/`ccVersion` arguments THOSE procs are handed directly. The
# reason to pass a real value here is nonetheless the same one: runcore.nim feeds
# this proc and `execute` the SAME probes (`nimprobe.cachedNimFingerprint()`
# and the `toolchainwarn.toolchainIdentity` of the `RunDeps.ccProbe`
# result, in production the memoised `ccidentity.cachedToolchainProbe`), so
# "" here means a caller is running a real toolchain's compiles against a
# freshness view that checks no toolchain at all for a ""-stamped graph. A
# real-stamped graph is discarded once -- `loadDepGraph`'s version-mismatch
# arms return an EMPTY graph re-stamped "" -- and once the caller saves that,
# every later "" load accepts it unchecked. The L2 result cache is
# shared across hosts, which makes key soundness a security property rather
# than a performance one — the cache-key half of that lives on
# `planner.toolchainFingerprint`/`runner.execute`, not here.
#
# Its old `""` default was justified in this proc's own doc with "every
# production caller of IT already threads a real value and has since before W3"
# — verbatim the premise round 2 catalogued at R2-7 as the defaulted-soundness-
# parameter disguise, and this is the very proc defect L1 happened on: the
# sibling `ccVersion` carried the identical default under the identical
# justification and shipped dark, its staleness check never firing on a real
# run. "Every caller already passes it" is a fact about today's tree, not an
# invariant the compiler enforces; the default is what guarantees the NEXT
# caller's omission is silent.
#
# The deprecated compatibility overload below keeps every existing call
# compiling (all 27 call sites in the tree — 1 in src/, 26 in tests/ — pass
# their arguments BY NAME, so each binds to exactly one of the two arities with
# no ambiguity) while the compiler reports an omission at the CALLER's own
# file:line. `--warnings:off`, which every test invocation in this repo passes,
# silences it, so no test output moves; `dev check`'s
# `--warningAsError:Deprecated:on` promotes it to a hard error, which is how
# `src/` is held to zero omissions. Pass it EXPLICITLY, including `""` when you
# genuinely mean "no probe available". What `""` actually does is narrower than
# "disable both checks": a graph stamped with a real identity is discarded (and
# replaced by an empty graph stamped `""`); only a `""`-stamped graph -- which
# is what that replacement becomes once saved -- is then accepted with no
# toolchain check at all. Full rationale on
# `planner.cachePath`'s deprecated overload and at R2-7/R3-7/R4-4 in
# docs/handoff/msvc-selection-layer.md.
proc buildRunPlan*(
  cfg:          Config;
  selection:    GroupSelection;
  failedKeys:   HashSet[tuple[tp: TrackedPath, group: string]] = initHashSet[tuple[tp: TrackedPath, group: string]]();
  useFailed:    bool = false;
  useChanged:   bool = false;
  changed:      HashSet[TrackedPath] = initHashSet[TrackedPath]();
  nimVersion:   string;
  ccVersion:    string;
  forceCompile: bool = false;
  warnings:     seq[ConfigWarning] = @[];
  shardK:       int = 0;          ## C2: shard index (1-indexed); 0 = no sharding
  shardN:       int = 1;          ## C2: total shard count; only used when shardK > 0
  order:        OrderMode = omNone; ## C4: history-based execution order; omNone = no reorder
): RunPlanView =
  ## Pure plan phase: discover → applyGates → [narrowing] → plan.
  ##
  ## Parameters:
  ##   cfg          — project configuration (not mutated).
  ##   selection    — which groups/paths to discover.
  ##   failedKeys   — (path, group) pairs from the prior run; used when useFailed.
  ##   useFailed    — when true, keep only entrypoints in failedKeys.
  ##   useChanged   — when true, keep only entrypoints whose closure ∩ changed ≠ ∅.
  ##   changed      — set of changed files, as TrackedPath (RFC-0009 A3b-i);
  ##                  required when useChanged. Passed straight through to
  ##                  narrowByDiff (RFC-0009 A3b-ii retyped narrow's own
  ##                  membership test to compare TrackedPath directly).
  ##   nimVersion   — Nim compiler fingerprint for freshness checks; the api
  ##                  boundary threads the RUNTIME probe
  ##                  (nimprobe.cachedNimFingerprint()), not the compile-time
  ##                  api.crisolNimVersion string — see api.nim's module-doc
  ##                  note on why a version STRING alone is not a sound
  ##                  discriminator.  REQUIRED (no default, R4-4): "" means
  ##                  no probe — a header stamped "" then passes
  ##                  loadDepGraph's nim-version check unexamined, while one
  ##                  stamped with a real version is discarded — so it is a
  ##                  test/cold-start-only choice that must be stated at the
  ##                  call site — see the SOUNDNESS-PARAMETER note above this
  ##                  proc. It does NOT reach the persistent-nimcache key from
  ##                  here: that key is built by runner.execute /
  ##                  clean.cleanOrphans from their own arguments (R5-7
  ##                  correction to an R4-4 claim).
  ##   ccVersion    — C toolchain fingerprint (W3), nimVersion's sibling for
  ##                  freshness checks; threaded to loadDepGraph/plan the
  ##                  same way. REQUIRED (no default) — this is the exact
  ##                  parameter whose "" default let the W3 fix ship dark:
  ##                  runcore.nim's only production call site compiled cleanly
  ##                  while silently never passing a real value, so every real
  ##                  run wrote AND read the dep-graph header with
  ##                  `ccVersion == ""` and depgraph.loadDepGraph's
  ##                  `dgdCcVersion` discard arm could never observe a
  ##                  mismatch. That arm is the live mechanism — see
  ##                  `depgraph.loadDepGraph`'s discard arms, the
  ##                  dgdNimVersion/dgdCcVersion blocks in
  ##                  tests/unit/test_depgraph.nim, and the end-to-end
  ##                  tests/integration/test_cc_depgraph_liveness.nim. (This bullet
  ##                  used to point at planner.decideCompile's own cc-version
  ##                  check; round 5's R3-8 removed that check as unreachable,
  ##                  so there is nothing to see there.) Pass "" explicitly
  ##                  when there is no probe (test/cold-start callers that
  ##                  don't care about toolchain freshness): a ""-stamped
  ##                  graph is then accepted with no cc check, and a graph
  ##                  stamped with a real cc identity is discarded — that is
  ##                  now a conscious choice at the call site, never a
  ##                  silent fallback. `nimVersion` above is REQUIRED on the
  ##                  same terms (R4-4): it was previously left defaulted on
  ##                  the grounds that "every production caller of IT already
  ##                  threads a real value and has since before W3", which is
  ##                  the exact premise R2-7 catalogued as the defaulted-
  ##                  soundness-parameter disguise -- a property of today's
  ##                  call graph, not an invariant, and it is what let
  ##                  ccVersion's own identical omission ship dark on THIS
  ##                  proc. Neither half has a default now.
  ##   forceCompile — when true, skip freshness checks (recompile everything).
  ##   shardK       — C2: shard index (1-indexed, 1..shardN); 0 = no sharding.
  ##   shardN       — C2: total shard count; only used when shardK > 0.
  ##   order        — C4: history-based execution order mode (default omNone = no reorder).
  ##                  Applied AFTER the shard step so shard membership is stable.
  ##                  With omNone the pipeline is byte-for-byte identical to the
  ##                  pre-C4 pipeline (no ledger reads, no reordering).
  ##
  ## When both useFailed and useChanged are true, the UNION of both narrowed
  ## sets is used (conservative: an entrypoint runs if EITHER criterion selects it).
  ##
  ## When shardK > 0, the shard step is applied LAST (after --failed/--changed
  ## narrowing) so --shard composes with --changed: diff narrows first, then the
  ## shard partitions the narrowed set.
  ##
  ## No CLI-only concerns here: no arg parsing, no exit-code logic, no stdout.

  let discovered = discover(cfg, selection)
  let gateState  = loadGateState(cfg)
  let gated      = applyGates(discovered, cfg, gateState)

  # applyGates now returns one GatedEntry (path, group, reason) per gated-out
  # entrypoint, so the rendering list is just its gatedOut field — no need to
  # re-walk the DiscoveredSet via unsafeToSeq (which would leak the gate seam).
  let gatedEntries: seq[GatedEntry] = gated.gatedOut

  # Load the persisted dep graph (D6 freshness; D5 impact selection).
  var discarded: DepGraphDiscard
  let graph = loadDepGraph(cfg, nimVersion, discarded, ccVersion)

  # A discarded depgraph (nimVersion/formatVersion mismatch, or an
  # unreadable/malformed file) must be a visible, structured diagnostic —
  # not a silent empty-graph fallback that leaves `run`/`list`/`closure`
  # indistinguishable from "never ran". Reuses the existing ConfigWarning
  # shape (see runcore.nim's measure-compile-reuse warning for the precedent of
  # a runtime, not config-parse, diagnostic). `key`/`message` are
  # depgraph.nim's single formatting authority for this fact — no case
  # statement here.
  var planWarnings = warnings
  if discarded.kind != dgdNone:
    planWarnings.add ConfigWarning(
      source:  depgraphPath(cfg),
      context: "depgraph",
      key:     discarded.key,
      message: discarded.message,
    )

  # Narrowing: applied AFTER applyGates, BEFORE plan (pipeline invariant).
  #
  #   useFailed  → keep only entrypoints whose (path,group) is in failedKeys.
  #   useChanged → keep only entrypoints selected by narrowByDiff (diff ∩
  #                closure, with the conservative fallback taxonomy of D4).
  #   both       → UNION: an entrypoint runs if EITHER criterion includes it
  #                (conservative — intersection could miss a newly broken
  #                 entrypoint absent from the prior run).
  # RFC-0009 A-degraded (D3): a degraded run (some root's fold-policy probe
  # genuinely failed) forces the FULL set, skipping narrowing entirely —
  # overriding useFailed/useChanged/both alike. `--failed`'s keys are
  # (TrackedPath, group) pairs from a PRIOR run; joining them under a
  # safe-pole fpNone this run could silently DROP a last-run-failed
  # entrypoint whose persisted spelling case-differs post-rename (an unsound
  # miss). Full run = sound over-selection, the same posture an absent dep
  # graph already takes. Shard/order still run after (pessimize only).
  # RFC-0009 "Risks accepted" NFC/NFD mitigation (docs/rfc/0009-path-
  # identity.md, "Risks accepted" NFC/NFD bullet) — IMPLEMENTED here, not
  # merely documented: a non-ASCII byte in the --changed changed-set's
  # spelling, on a config where some tracked root actively folds, means the
  # ASCII-only fold (`paths.fold`, `fpAsciiLower == toLowerAscii`) cannot be
  # trusted to have deduped an NFC/NFD twin pair for that name — narrowing
  # is skipped and the full discovered set runs instead, same posture as
  # the `degraded` fallback just below. `narrow.foldUntrusted` is a
  # deliberately SEPARATE, narrower signal than `cfg.trackedRoots.degraded`:
  # every probe answered definitively this run (nothing genuinely failed),
  # so only the narrowing decision is distrusted — NOT the cache
  # (runcore.nim's `not cfg.trackedRoots.degraded` cache gates), NOT dep-graph
  # persistence (RFC-0009 A-degraded D4/D5). fpNone-everywhere (Linux
  # default): `narrow.anyRootFolds` is always false, so this is always
  # false and costs one cheap scan of an (ordinarily empty) set.
  let changedSetFoldUntrusted = foldUntrusted(changed, cfg.trackedRoots)
  if changedSetFoldUntrusted:
    planWarnings.add ConfigWarning(
      source:  "",
      context: "changed-set-fold",
      key:     "nonAsciiChangedName",
      message: "a non-ASCII name in the --changed changed set, on a " &
               "config where some tracked root folds, cannot be trusted " &
               "under crisol's ASCII-only fold (NFC/NFD risk -- see " &
               "docs/rfc/0009-path-identity.md, \"Risks accepted\") -- " &
               "narrowing skipped this run; running the full discovered " &
               "set instead",
    )

  var runnable = gated.run
  if (useFailed or useChanged) and not cfg.trackedRoots.degraded and
     not changedSetFoldUntrusted:
    let failedNarrowed =
      if useFailed:
        gated.run.filterIt((tp: it.tp, group: it.group) in failedKeys)  # RFC-0009 A3d-i: fold-aware failed-key membership (TrackedPath)
      else:
        newSeq[Entrypoint]()
    let changedNarrowed =
      if useChanged:
        # RFC-0009 A3b-ii: narrow.nim compares TrackedPath directly (folded
        # membership, the selection-soundness axis) -- `changed` is handed
        # straight through, no adapter.
        narrowByDiff(gated.run, changed, graph, cfg.trackedRoots)
      else:
        newSeq[Entrypoint]()

    # Union over the two narrowed sets, preserving gated.run input order.
    # RFC-0009 A3d-iii: the keep-set is keyed by TrackedPath identity (ep.tp),
    # not a raw path string — the last string-keyed selection surface in the
    # pipeline joins to the live identity like every other narrowing step.
    var keep = initHashSet[tuple[tp: TrackedPath, group: string]]()
    for ep in failedNarrowed:  keep.incl (tp: ep.tp, group: ep.group)
    for ep in changedNarrowed: keep.incl (tp: ep.tp, group: ep.group)
    runnable = gated.run.filterIt((tp: it.tp, group: it.group) in keep)

  # C3: Shard step — LAST step of selection, AFTER narrowing and BEFORE plan.
  # Applied only when shardK > 0 (i.e. --shard was passed).
  # Composes with --changed: diff narrows first, shard partitions the result.
  # Uses ledger-aware balanced sharding (LPT bin-pack) when history exists;
  # falls back to C2 path-hash partition on cold start (no ledger rows).
  if shardK > 0:
    let resolvedStateDir = stateDirOf(cfg)
    runnable = shardWithHistory(runnable, shardK, shardN, resolvedStateDir, cfg.trackedRoots)

  # C4: Order step — AFTER shard (shard membership is stable), BEFORE plan.
  # Applied only when order != omNone.  With omNone (default) this block is
  # entirely skipped: zero I/O, no reordering, pipeline parity with pre-C4.
  # The ordering step always runs after shard assignment so shard membership
  # is stable regardless of the --order fallback (RFC §F5 line 159).
  if order != omNone:
    let resolvedStateDir = stateDirOf(cfg)
    runnable = orderByHistory(runnable, order, resolvedStateDir, cfg.trackedRoots)

  let runPlan = plan(cfg, runnable, graph, forceCompile)
  RunPlanView(
    plan:     runPlan,
    gatedOut: gatedEntries,
    runnable: runnable.len,
    graph:    graph,
    warnings: planWarnings,
    adHocPaths:     discovered.adHocPaths,
  )

# ---------------------------------------------------------------------------
# Deprecated compatibility overload (R4-4)
# ---------------------------------------------------------------------------
#
# `nimVersion` on `buildRunPlan` above no longer defaults to "". It is the Nim
# half of the dep-graph freshness view (loadDepGraph's nim-version staleness
# branch). "" does not switch that check off -- it compares against "": a graph
# stamped with a real Nim version is discarded, the rebuilt graph the caller
# then saves is stamped "", and a ""-stamped graph is accepted by every later
# "" load with no nim-version check (R7-S4; the `{.deprecated.}` message below
# says the same). A soundness parameter with a convenient default, the shape
# R2-7 catalogued and defect L1 was caused by on this very proc. (It does NOT also feed the persistent-nimcache key;
# R5-7 corrected that R4-4 claim here and in the note above the full-arity
# proc — `plan` never called `planner.toolchainFingerprint`/`cachePath`, and
# `runner.execute`/`clean.cleanOrphans` build that key from their own
# arguments; the `{.deprecated.}` message below now names only the
# `loadDepGraph` freshness discard.) The default was what made an omission
# invisible, and
# the doc justification it carried ("every production caller of IT already
# threads a real value") is the disguise itself.
#
# This overload keeps every existing call site compiling while the compiler
# names the omission at the caller's own file:line. Full rationale on
# `planner.cachePath`'s deprecated overload (R3-7). No ambiguity with the
# full-arity proc above: that one REQUIRES `nimVersion`, and this one does not
# accept it at all, so each call shape binds to exactly one of the two. Every
# call site in the tree passes its arguments by NAME, so none of them can
# accidentally reach the arity where a trailing positional list would fit both.

proc buildRunPlan*(
  cfg:          Config;
  selection:    GroupSelection;
  failedKeys:   HashSet[tuple[tp: TrackedPath, group: string]] = initHashSet[tuple[tp: TrackedPath, group: string]]();
  useFailed:    bool = false;
  useChanged:   bool = false;
  changed:      HashSet[TrackedPath] = initHashSet[TrackedPath]();
  ccVersion:    string;
  forceCompile: bool = false;
  warnings:     seq[ConfigWarning] = @[];
  shardK:       int = 0;
  shardN:       int = 1;
  order:        OrderMode = omNone;
): RunPlanView
    {.deprecated: "R4-4: pass nimVersion explicitly (\"\" when no probe is available) — omitting it passes \"\" to depgraph.loadDepGraph, which accepts a \"\"-stamped graph with no nim-version check and discards one stamped with a real version".} =
  ## Deprecated compatibility overload — forwards the `""` that `nimVersion`
  ## used to default to (verified against base commit 630ecc6), so no behaviour
  ## moves for a caller that already omitted it.
  buildRunPlan(cfg, selection, failedKeys, useFailed, useChanged, changed,
               "", ccVersion, forceCompile, warnings, shardK, shardN, order)
