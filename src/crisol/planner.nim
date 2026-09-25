## planner.nim — pure planning: slug/path helpers, compile-freshness decision,
## and the plan() entry point.  No subprocess; fileExists is allowed (read-only).
##
## This module is the pure half of the runner split (HIGH-1).  It carries
## everything the plan phase needs so that consumers (pipeline.nim) can import
## the planner WITHOUT transitively pulling in spawn/signals (the effectful
## executor lives in runner.nim).
##
## Public API:
##   slug*(tp, roots, flags): string             — stable bin/cache dir key
##   binName*(ep): string                      — compiled binary basename
##   binPath*(ep, config): string              — stable bin directory
##   cachePath*(ep, config): string            — stable nimcache directory
##   emptyDepGraph*(): DepGraph                 — convenience empty graph
##   decideCompile*(...): (CompileDecision, string)
##   plan*(config, eps, graph, nimVersion, forceCompile, ccVersion): RunPlan

import std/[algorithm, options, os, sets, strutils, tables]
import std/cpuinfo
import crisol/[types, config, depgraph, scheduler]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const CrisolProtocolMajor* = 1
  ## The crisol structured-result protocol major version, encoded in depgraph
  ## entries so that a protocol bump invalidates cached binaries.

# ---------------------------------------------------------------------------
# Pure slug / path helpers
# ---------------------------------------------------------------------------

proc slugify(path: string): string =
  ## Convert a file path to a safe directory-name component.
  ## Replaces non-alphanumeric chars (except '-' and '_') with '__'.
  result = newStringOfCap(path.len)
  for c in path:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      result.add c
    else:
      result.add "__"

proc slug*(tp: TrackedPath; roots: TrackedRoots; flags: seq[string]): string =
  ## Stable, readable slug for a (tp, flags) pair — the KEY for bin and
  ## cache directories under stateDir.
  ##
  ## Format: `<readablePrefix>-<hash16>`
  ##   readablePrefix: keyBytes(tp, roots) with non-alphanum chars (except
  ##                   '-' and '_') → '__'
  ##   hash16: 64-bit FNV-1a over `keyBytes & NUL & sorted-flags-joined-by-0x1f`
  ##           → 16 hex
  ##
  ## RFC-0009 A5b-i: derives the WHOLE slug (readable prefix AND hash) from
  ## `keyBytes(tp, roots)` rather than a raw native path string, so the
  ## readable prefix and the hash can never disagree about which root the
  ## entrypoint belongs to. Byte-identical to the pre-A-final-ii string
  ## overload for tag-0/project members (entrypoints are always tag-0).
  let keyPath = string(keyBytes(tp, roots))
  let readablePrefix = slugify(keyPath)
  var sortedFlags = flags
  sortedFlags.sort()
  let hashInput = keyPath & "\x00" & sortedFlags.join("\x1f")
  let hash16 = toHex16(fnv1a64(hashInput))
  result = readablePrefix & "-" & hash16

proc epSlug*(ep: Entrypoint; roots: TrackedRoots): string =
  ## An entrypoint's slug, derived from its TrackedPath identity
  ## (`discover` always sets `ep.tp`).
  slug(ep.tp, roots, ep.flags)

proc binName*(ep: Entrypoint): string =
  ## Basename of the compiled binary (no extension).
  string(ep.tp.display()).extractFilename().changeFileExt("")

proc binPath*(ep: Entrypoint; config: Config): string =
  ## Absolute path to the directory containing the stable compiled binary.
  stateDirOf(config) / "bin" / epSlug(ep, config.trackedRoots)

proc stableBinPath*(ep: Entrypoint; config: Config): string =
  ## Absolute path to the STABLE, on-disk compiled binary that `decideCompile`
  ## checks for freshness, that `promoteCompiledBinary` copies the fresh
  ## per-slot binary to, and that a `cdSkipFresh` run spawns directly.
  ##
  ## `binName(ep)` is deliberately extensionless — it doubles as the
  ## nimcache-manifest base name (`<bare>.json`) and must stay that way (see
  ## `binName`'s own doc comment) — but the actual file the linker produces,
  ## and the path a child-process spawn needs, both require the platform
  ## executable extension: on native Windows, `CreateProcessW` does not
  ## reliably resolve/execute a fully-qualified path to an extensionless PE
  ## file, so an extensionless stable binary is silently unspawnable there
  ## (RFC-0009 B4a: this is what produced `rsStructural`/zero results in
  ## `test_api`'s fresh runs — the run child never started).
  ##
  ## This is the ONE place that appends the extension to the stable binary's
  ## path, so the promotion target (copyFile dest), the freshness/eligibility
  ## check (decideCompile's `fileExists`), and the direct-run spawn target
  ## all agree on every platform. `addFileExt` is a no-op when `ExeExt == ""`
  ## (POSIX) — POSIX byte-identical.
  addFileExt(binPath(ep, config) / binName(ep), ExeExt)

proc toolchainFingerprint*(nimVersion: string; ccVersion: string): string =
  ## Short, stable fingerprint of the compiler toolchain (RFC-0006 nimcache-
  ## persistence soundness rule).
  ##
  ## Nim's own nimcache invalidation tracks source content + compile flags but
  ## NOT the cc/ldd binary version (crisol's `SoundnessKey` DOES track both —
  ## see keys.nim). Folding this fingerprint into the PERSISTENT nimcache path
  ## (`cachePath`, below) means a toolchain upgrade lands on a fresh directory
  ## automatically — a persistent cache can never silently reuse an object
  ## file built by a different compiler; the old directory is simply orphaned
  ## for GC (clean.cleanOrphans).
  ##
  ## Both inputs empty ⇒ "" (the sentinel meaning "no fingerprint known" —
  ## callers that don't have a toolchain probe get the pre-fingerprint bare
  ## path shape from `cachePath`/`cleanOrphans`; this is the same "" = "no
  ## toolchain probe available" convention these two values carry everywhere
  ## else in crisol — in `depgraph.loadDepGraph`, where a stored header that is
  ## itself "" then never trips the nim/cc staleness arms, and in `plan`, where
  ## since R3-8 (round 5) they select nothing at all: `decideCompile` was
  ## `plan`'s only reader of them and no longer takes them).
  if nimVersion.len == 0 and ccVersion.len == 0:
    return ""
  toHex16(fnv1a64(nimVersion & "\x00" & ccVersion))

# SOUNDNESS-PARAMETER WARNING (round-2 review R2-7; ENFORCED round 3, R3-7):
# `toolchainFp` is a soundness parameter of the shape that produced defect L1 --
# omitting it silently yields the unsound value, invisibly. It no longer carries
# a default: the compiler now says so at the call site, via the deprecated
# compatibility overload below. Pass it EXPLICITLY, including "" when you mean
# "no probe available". Full rationale on that overload and at R2-7/R3-7 in
# docs/handoff/msvc-selection-layer.md.
proc cachePath*(ep: Entrypoint; config: Config; toolchainFp: string): string =
  ## Absolute path to the STABLE, PERSISTENT nimcache directory for this
  ## entrypoint.
  ##
  ## Stability: a pure function of (ep.tp, ep.flags, toolchainFp) — NOT plan
  ## position. This is the fix for the RFC-0006 nimcache-persistence bug:
  ## previously runner.nim suffixed this path with the entrypoint's index in
  ## the plan (`_<pepIdx>`), so `--changed`/subset runs (where the affected
  ## set shifts run-to-run) gave the SAME entrypoint a DIFFERENT nimcache dir
  ## every run, defeating Nim's own incremental compile. Two calls with the
  ## same arguments always return the same path, regardless of what plan or
  ## what position the entrypoint occupies in it.
  ##
  ## toolchainFp (see `toolchainFingerprint`) is folded into the path so a
  ## cc/nim upgrade lands on a fresh directory rather than reusing a
  ## potentially-stale object. Passing `""` selects the pre-fingerprint bare
  ## path shape (callers with no toolchain probe, e.g. `crisol clean` invoked
  ## without real nimVersion/ccVersion, and existing tests) — say it
  ## explicitly; it is no longer a default (R3-7).
  let suffix = if toolchainFp.len > 0: "-" & toolchainFp else: ""
  stateDirOf(config) / "cache" / (epSlug(ep, config.trackedRoots) & suffix)

proc cachePath*(ep: Entrypoint; config: Config): string
    {.deprecated: "R3-7: pass toolchainFp explicitly (\"\" when no toolchain probe is available) — omitting it silently selects the un-fingerprinted path shape".} =
  ## Deprecated compatibility overload — see R3-7 below.
  ##
  ## R3-7 (round-3 review) — WHY A DEPRECATED OVERLOAD RATHER THAN A REMOVED
  ## DEFAULT. `toolchainFp` governs cache-key soundness, and R2-7 recorded the
  ## whole class: a soundness parameter carrying a convenient default, so
  ## omission silently yields the unsound value AND is invisible in review.
  ## That is what produced defect L1. Removing the defaults outright was
  ## deferred as too much churn to apply by hand: 353 call sites across the six
  ## procs carrying such a default, 326 of them in tests (re-measured R5-9; the
  ## round-2 figure of 527 counted comment prose as calls, and the corrected
  ## number does not change the conclusion).
  ##
  ## Deprecation gets the compile-time signal at zero call-site churn: the
  ## full-arity proc above loses its default, this overload keeps every
  ## existing call compiling, and a caller that omits the parameter is told so
  ## AT ITS OWN file:line. Verified against Nim 2.2.10: an explicit call
  ## resolves to the full overload with no warning and no ambiguity; a
  ## positional, named, or named-tail omission resolves here and warns;
  ## `--warnings:off` (which every test invocation in this repo passes) silences
  ## it entirely, so the test call sites counted above stay quiet; and
  ## `--warningAsError:Deprecated:on` promotes it to a hard error, which is how
  ## `src/` can be held to zero omissions.
  ##
  ## It also puts the signal where the author is. A `#` comment above a proc is
  ## read by whoever opens that file; a deprecation warning is read by whoever
  ## CALLS it — including the five sibling projects that consume crisol as a
  ## library and never open this file at all.
  cachePath(ep, config, "")

proc duplicateSlugs*(p: RunPlan; roots: TrackedRoots): HashSet[string] =
  ## Return the set of slugs that appear MORE THAN ONCE across `p`'s
  ## entrypoints — i.e. the same (path, flags) pair scheduled at ≥ 2 distinct
  ## plan positions in a single run.
  ##
  ## This is the rare "same entrypoint twice in one plan" case the old
  ## `_<pepIdx>` suffix incidentally guarded (two slots compiling the same
  ## slug concurrently → nimcache write race). With `cachePath` now stable,
  ## DIFFERENT entrypoints are already isolated by distinct slugs; only a
  ## genuine duplicate needs a fallback (runner.nim falls back to a
  ## pepIdx-suffixed dir for slugs in this set, preserving the old
  ## concurrency-safe behavior ONLY where it's still needed).
  var seen = initHashSet[string]()
  for pep in p.entrypoints:
    let s = epSlug(pep.ep, roots)
    if s in seen:
      result.incl s
    else:
      seen.incl s

# ---------------------------------------------------------------------------
# emptyDepGraph convenience wrapper
# ---------------------------------------------------------------------------

proc emptyDepGraph*(): DepGraph =
  ## Return an empty DepGraph (nimVersion = "").
  ## Convenience wrapper used by tests and the CLI until a real graph is loaded.
  initDepGraph("", "")

# ---------------------------------------------------------------------------
# CompileDecision → EntrypointDecision mapping (RFC F3 — single sealed sum)
# ---------------------------------------------------------------------------

proc toEntrypointDecision*(cd: CompileDecision): EntrypointDecision =
  ## Map the compile-freshness decision onto the F3 sealed sum.  edCached is NOT
  ## produced here — it is promoted from edRunFresh by the plan-time cache lookup
  ## (A6) once a soundness-key hit is confirmed.
  ##   cdNeverBuilt → edNeverBuilt   (compile + run)
  ##   cdStale      → edStale        (compile + run)
  ##   cdSkipFresh  → edRunFresh     (skip compile, run; may become edCached)
  case cd
  of cdNeverBuilt: edNeverBuilt
  of cdStale:      edStale
  of cdSkipFresh:  edRunFresh

# ---------------------------------------------------------------------------
# decideCompile
# ---------------------------------------------------------------------------

proc decideCompile*(ep: Entrypoint;
                    graph: DepGraph;
                    config: Config;
                    forceCompile: bool;
                    currentProtocolMajor: int): (CompileDecision, string) =
  ## Determine whether ep needs to be compiled.
  ##
  ## Logic (in order):
  ##   1. Binary absent → cdNeverBuilt (always, regardless of forceCompile).
  ##   2. Entry absent from graph → cdStale.
  ##   3. Protocol major changed → cdStale.
  ##   4. Any closure file missing → cdStale.
  ##   5. Closure content hash changed → cdStale.
  ##   6. forceCompile → cdStale (binary exists, force requested).
  ##   7. → cdSkipFresh.
  ##
  ## TOOLCHAIN STALENESS IS NOT DECIDED HERE — do not come looking for it.
  ## "Nim compiler moved" and "C toolchain moved" (W3) are both decided by
  ## `depgraph.loadDepGraph`, which discards a graph whose header disagrees
  ## with the live `nimVersion`/`ccVersion` and hands back an empty
  ## `initDepGraph(nimVersion, ccVersion)`. Every entrypoint in that empty
  ## graph then lands on step 2 here and recompiles. `decideCompile`
  ## therefore sees only graphs whose header ALREADY matches the live
  ## toolchain, and took no `nimVersion`/`ccVersion` parameters as of round 5
  ## (see the R3-8 note below the protocol check). `plan` still takes both --
  ## they are the same values its caller hands `runner.execute`/`clean`, which
  ## do call `toolchainFingerprint` for nimcache-path keying: a separate,
  ## independently-correct half of the W3 fix that keeps a compile which
  ## actually HAPPENS from reusing an object file built by the old cc.

  # RFC-0009 B4a: the stable binary's real on-disk name (with the platform
  # executable extension on Windows) — see `stableBinPath`'s doc comment.
  let binFull = stableBinPath(ep, config)

  if not fileExists(binFull):
    if forceCompile:
      return (cdNeverBuilt, "binary absent (--force-compile)")
    else:
      return (cdNeverBuilt, "binary absent (first run or cache cleared)")

  let key = entryKey(ep.tp, ep.flags)

  if key notin graph.entries:
    return (cdStale, "no closure record in dep graph")

  let entry = graph.entries[key]

  if entry.protocolMajor != currentProtocolMajor:
    return (cdStale, "protocol major changed")

  # R3-8, RESOLVED round 5, 2026-09-24: the two toolchain-staleness arms that
  # used to sit here -- `graph.header.nimVersion != nimVersion` and its
  # `ccVersion` twin, each returning cdStale -- were REMOVED along with the two
  # parameters they read. They were unreachable. `depgraph.loadDepGraph`
  # discards a header-mismatched graph up front and, on the success path,
  # re-stamps `stored.header.nimVersion`/`.ccVersion` to the live values before
  # returning, so `graph.header.X == X` was a structural invariant at this point
  # and neither arm could fire (mutation-proved twice in round 3: disabling
  # `loadDepGraph`'s discard turns tests/integration/test_w3_cc_liveness.nim
  # RED, disabling the `ccVersion` arm here left it GREEN).
  #
  # Round 2 and round 3 kept them as defence in depth "for a graph built by
  # some other route -- a future caller might", and rejected a `doAssert` as
  # something that would crash a library consumer handing `plan` a raw stored
  # graph. That premise does not survive the project's own accepted RFCs:
  # RFC-0003 (docs/rfc/0003-library-facade-and-onboarding.md, Goal 2 and F1)
  # makes `crisol/api` THE documented, stable library surface and everything
  # else "an implementation detail a consumer need not import" / "importable
  # but uncontracted"; RFC-0001:933 adds only `crisol/report` and
  # `crisol/unittest_shim`. `crisol/planner` is on neither list, so there is no
  # contracted consumer path that supplies a raw stored graph, and the arms
  # were defending an interface crisol does not offer. Both internal callers
  # were re-verified unaffected: pipeline.nim passes a `loadDepGraph` result
  # (invariant holds) and runner.nim passes `emptyDepGraph()` with
  # nimVersion/ccVersion "" (the comparisons were "" == "").
  #
  # The live enforcement point for "toolchain moved -> recompile" is
  # `loadDepGraph`'s discard, driven end-to-end by
  # tests/integration/test_w3_cc_liveness.nim and at unit level by the
  # dgdNimVersion/dgdCcVersion blocks in tests/unit/test_depgraph.nim (where
  # test_freshness.nim's two former "version changed -> cdStale" cases moved).
  # Full history at R3-8 in docs/handoff/msvc-selection-layer.md.

  # Check that all closure files exist and compute content hash.
  #
  # RFC-0009 A3c-ii: `entry.closure` is `HashSet[TrackedPath]`. Existence is
  # checked via `toNative(tp, roots)` uniformly (project OR dep-root member
  # alike -- mirrors `depgraph.isEntryStale`'s identical fix, D4). The
  # content-hash INPUT is derived by the SHARED `depgraph.closureHashInputs`
  # helper -- the SAME derivation, over the SAME classify-filtered set,
  # `recordClosure` used at record time. Using any other derivation here
  # would fail the `entry.closureHash` comparison on every warm load and
  # spuriously recompile everything (the test_skipfresh regression).
  let roots = config.trackedRoots

  for tp in entry.closure:
    if not fileExists(toNative(tp, roots)):
      return (cdStale, "closure file missing: " & string(display(tp)))

  # Compute current content hash.
  var computedHash: string
  try:
    computedHash = closureContentHash(
      closureHashInputs(entry.closure, roots))
  except CatchableError:
    return (cdStale, "could not read closure files for content hash")

  if computedHash != entry.closureHash:
    return (cdStale, "closure content changed")

  if forceCompile:
    return (cdStale, "forced recompile (--force-compile)")

  return (cdSkipFresh, "binary fresh — all freshness conditions met")

# ---------------------------------------------------------------------------
# plan — pure; fileExists allowed (no subprocess)
# ---------------------------------------------------------------------------

# SOUNDNESS-PARAMETER WARNING (round-3 review, R3-6): `nimVersion` and
# `ccVersion` below are defaulted soundness parameters of the same shape R2-7
# catalogued -- omitting one silently yields the unsound value, invisibly.
# (`grep -rl "SOUNDNESS-PARAMETER WARNING" src/` lists the annotated modules --
# `-l`, not `-n`, so this very sentence does not pad the answer; round 4, R4-7,
# 2026-09-24 replaced a literal count of the annotated sites here with that
# grep, because the count was already off by one when written and because
# R3-10 had just deleted another asserted census, in `toolrun.nim`, for rotting
# the same way.) This site was MISSED by R2-7's inventory even though it is the
# proc `pipeline.buildRunPlan` (whose own default L1 removed) calls, i.e. the
# instance one frame from the original defect. New callers must pass both
# EXPLICITLY, including "" when they mean "no probe available". Full rationale
# at `runner.execute`'s copy of this note and at R2-7/R3-6 in
# docs/handoff/msvc-selection-layer.md.
#
# NARROWED round 5, 2026-09-24 (R3-8), and left standing rather than deleted:
# `plan` itself no longer reads either value -- removing `decideCompile`'s two
# unreachable toolchain arms removed `plan`'s only read of them -- so at THIS
# site omitting one can no longer flip a decision. The warning stays because the
# parameters stay (the call-shape census below is why), because the shape is
# what a reader of `pipeline.buildRunPlan` -> `plan` -> `runner.execute` has to
# recognise, and because the values a caller assembles here are the same ones
# `execute` feeds to `toolchainFingerprint`, where omission IS still unsound.
# The live toolchain-staleness gate is `depgraph.loadDepGraph`; see the R3-8
# note in `decideCompile`.
#
# WHY `plan` STILL CARRIES ITS DEFAULTS while five sibling procs no longer do
# (round-4 review, R4-4, 2026-09-24 -- recording a reason that was previously
# absent here, so that the ledger's "five of six procs" line stops being the
# only account of this exclusion). R3-7's remedy -- drop the default, add a
# `{.deprecated.}` companion carrying the old signature -- is zero-churn only
# where the removed defaults are TRAILING, which is how it worked on
# `planner.cachePath`, `depgraph.initDepGraph`, both `depgraph.loadDepGraph`
# arities and `clean.cleanOrphans`. Here `forceCompile` sits BETWEEN the two
# defaulted parameters, so the call shapes that exist in the tree today do not
# collapse onto one companion:
# (each shape cited by a grep anchor, never a line number -- R4-7 found the
# line numbers in this file had already rotted, and one of the three citations
# that replaced them had rotted again by round 5):
#   - `plan(cfg, @[ep], emptyDepGraph())` omits all three -- by far the most
#     common shape in tests (`grep -rn "plan(cfg, @\[ep\], emptyDepGraph())"
#     tests/` lists them; `grep -rn "plan(" tests/` has every shape);
#   - `plan(cfg, @[ep], graph, nimVersion = "")` omits the last two
#     (`grep -rn 'graph, nimVersion = "")' tests/`);
#   - `plan(cfg, @[ep], graph, "", false)` omits only `ccVersion`
#     (`grep -rn 'graph, "", false)' tests/`);
#   - `plan(cfg, @[ep], graph, nimVersion = "nim-v1", ccVersion = "cc-OLD")`
#     supplies BOTH versions while skipping `forceCompile` in the middle
#     (`grep -rn 'ccVersion = "cc-OLD"' tests/`) -- that shape
#     must bind to the full-arity proc, which therefore has to keep
#     `forceCompile`'s own default; no companion overload can supply it.
# Covering the rest would take three overloads of a six-parameter signature,
# and hand-maintained copies of one signature are the same drift hazard that
# kept `runner.execute` out of the treatment (see the note there, and
# `clean.nim`'s R3-7 section, which chose an `auto` return for exactly this
# reason). So the warning above is the whole mechanism at this site,
# deliberately: a considered exception, not an oversight -- and not one to
# reverse without re-measuring the call shapes listed above.

proc plan*(config: Config; eps: seq[Entrypoint]; graph: DepGraph;
           nimVersion: string = ""; forceCompile: bool = false;
           ccVersion: string = ""): RunPlan =
  ## Pure — no subprocess.
  ##
  ## Annotates every entrypoint with a CompileDecision via decideCompile.
  ## With an empty graph, every entrypoint is cdNeverBuilt.  The api boundary
  ## supplies the RUNTIME nim fingerprint (nimprobe.cachedNimFingerprint()),
  ## not the compile-time api.crisolNimVersion string; the "" default here is
  ## for tests / cold-start callers only.
  ## `ccVersion` (W3) is nimVersion's cc sibling, and the same convention
  ## applies (appended as a trailing default parameter, not placed next to
  ## `nimVersion`, so every pre-W3 positional call site, e.g.
  ## `plan(cfg, eps, graph, nimVersion, forceCompile)`, keeps compiling
  ## unchanged).
  ##
  ## NEITHER VALUE REACHES A STALENESS DECISION FROM HERE (R3-8, round 5,
  ## 2026-09-24). `decideCompile` no longer takes them: "toolchain moved ->
  ## recompile" is decided once, by `depgraph.loadDepGraph`, which discards a
  ## header-mismatched graph before `plan` ever sees it — so an empty graph is
  ## how a toolchain change arrives here, and step 2 of `decideCompile` turns it
  ## into a recompile. Pass both anyway, `""` included when you genuinely have
  ## no probe: the parameters remain part of this signature (see the call-shape
  ## census in the `#` comment above), a caller threading real probe values
  ## documents its own soundness posture, and the values are what
  ## `runner.execute`/`clean` feed to `toolchainFingerprint` for nimcache-path
  ## keying. This sentence is in the `##` doc deliberately -- generated docs and
  ## editor hover show only these lines, so a note that lives in a `#` comment
  ## above the proc never reaches a consumer of crisol-as-a-library at all.
  ## The jobs field is resolved to at least 1; if config.jobs == 0 the A4
  ## default is max(1, cpuCount-2).

  var planned: seq[PlannedEntrypoint]
  for ep in eps:
    # `nimVersion`/`ccVersion` are NOT threaded into `decideCompile`: as of
    # R3-8 (round 5) it does not take them, because the graph's header already
    # agrees with them by `loadDepGraph`'s invariant. `decideCompile` was
    # `plan`'s ONLY reader of the two, so `plan` now reads NEITHER value
    # anywhere in its body -- in particular it never calls
    # `toolchainFingerprint`/`cachePath`, and never did. The nimcache-path
    # fingerprint is computed by `runner.execute` and `clean.cleanOrphans`
    # from their OWN `nimVersion`/`ccVersion` arguments (the same values api
    # hands each of them separately: `nimprobe.cachedNimFingerprint()` and
    # `$ccProbe()`, whose default is the memoised
    # `ccidentity.cachedCcFingerprint`), so it is unaffected by what `plan`
    # does with these two. Why they stay in the signature regardless: the
    # call-shape census in the `#` block above this proc.
    let (decision, reason) = decideCompile(
      ep, graph, config, forceCompile, CrisolProtocolMajor)
    let groupMaxJobs = block:
      var mj: Option[int] = none(int)
      for g in config.groups:
        if g.name == ep.group:
          mj = g.maxJobs
          break
      mj
    let groupCacheable = block:
      var cs = csDefault
      for g in config.groups:
        if g.name == ep.group:
          cs = g.cacheable
          break
      cs
    # B1: effective retries = group retries if > 0, else global config retries.
    let groupRetries = block:
      var r = 0
      for g in config.groups:
        if g.name == ep.group:
          r = g.retries
          break
      r
    let effectiveRetries = if groupRetries > 0: groupRetries else: config.retries
    planned.add PlannedEntrypoint(
      ep:           ep,
      edecision:    toEntrypointDecision(decision),
      reason:       reason,
      runTimeoutMs: effectiveRunTimeoutMs(ep, config),
      maxJobs:      groupMaxJobs,
      cacheable:    groupCacheable,
      retries:      effectiveRetries,
    )

  let resolvedJobs =
    if config.jobs > 0:
      config.jobs
    else:
      max(1, countProcessors() - 2)

  RunPlan(entrypoints: planned, jobs: resolvedJobs)
