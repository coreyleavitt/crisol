## planner.nim — pure planning: slug/path helpers, compile-freshness decision,
## and the plan() entry point.  No subprocess; fileExists is allowed (read-only).
##
## This module is the pure half of the runner split (HIGH-1).  It carries
## everything the plan phase needs so that consumers (pipeline.nim) can import
## the planner WITHOUT transitively pulling in spawn/signals (the effectful
## executor lives in runner.nim).
##
## Public API:
##   slug*(path, flags): string                — stable bin/cache dir key
##   binName*(ep): string                      — compiled binary basename
##   binPath*(ep, config): string              — stable bin directory
##   cachePath*(ep, config): string            — stable nimcache directory
##   emptyDepGraph*(): DepGraph                 — convenience empty graph
##   decideCompile*(...): (CompileDecision, string)
##   plan*(config, eps, graph, nimVersion, forceCompile): RunPlan

import std/[algorithm, options, os, sequtils, sets, strutils, tables]
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

proc slug*(path: string; flags: seq[string]): string =
  ## Stable, readable slug for a (path, flags) pair.
  ##
  ## Format: `<readablePrefix>-<hash16>`
  ##   readablePrefix: path with non-alphanum chars (except '-' and '_') → '__'
  ##   hash16: 64-bit FNV-1a over `path & NUL & sorted-flags-joined-by-0x1f` → 16 hex
  ##
  ## This is the KEY for bin and cache directories under stateDir.
  let readablePrefix = slugify(path)
  var sortedFlags = flags
  sortedFlags.sort()
  let hashInput = path & "\x00" & sortedFlags.join("\x1f")
  let hash16 = toHex16(fnv1a64(hashInput))
  result = readablePrefix & "-" & hash16

proc slug*(tp: TrackedPath; roots: TrackedRoots; flags: seq[string]): string =
  ## RFC-0009 A5b-i: TrackedPath overload. Derives the WHOLE slug (readable
  ## prefix AND hash) from `keyBytes(tp, roots)` rather than a raw native
  ## path string, so the readable prefix and the hash can never disagree
  ## about which root the entrypoint belongs to. Delegating to the string
  ## overload with `keyBytes` as the path is byte-identical to it for
  ## tag-0/project members (entrypoints are always tag-0).
  slug(string(keyBytes(tp, roots)), flags)

proc epSlug(ep: Entrypoint; roots: TrackedRoots): string =
  ## RFC-0009 A5b-i: an entrypoint's slug from its TrackedPath IDENTITY when
  ## populated (production — `discover` always sets `ep.tp`), falling back to
  ## the string `ep.path` for a hand-built ep whose `tp` is the zero value.
  ## This honors A3a-i's contract (hand-built fixtures do NOT set `tp` — the
  ## producer obligation is `discover`'s alone), so a fixture ep never collapses
  ## to a degenerate empty-`rel` slug (which would collide all such eps onto one
  ## bin/cache dir). For a tag-0 entrypoint `keyBytes == rel == path`, so both
  ## branches are byte-identical; the fallback only guards the zero-`tp` case.
  if ep.tp.display().len > 0: slug(ep.tp, roots, ep.flags)
  else:                       slug(ep.path, ep.flags)

proc binName*(ep: Entrypoint): string =
  ## Basename of the compiled binary (no extension).
  ep.path.extractFilename().changeFileExt("")

proc binPath*(ep: Entrypoint; config: Config): string =
  ## Absolute path to the directory containing the stable compiled binary.
  stateDirOf(config) / "bin" / epSlug(ep, config.trackedRoots)

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
  ## path shape from `cachePath`/`cleanOrphans`; this is the same "" =
  ## disable-this-check convention `plan(nimVersion="")` already uses).
  if nimVersion.len == 0 and ccVersion.len == 0:
    return ""
  toHex16(fnv1a64(nimVersion & "\x00" & ccVersion))

proc cachePath*(ep: Entrypoint; config: Config; toolchainFp: string = ""): string =
  ## Absolute path to the STABLE, PERSISTENT nimcache directory for this
  ## entrypoint.
  ##
  ## Stability: a pure function of (ep.path, ep.flags, toolchainFp) — NOT plan
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
  ## potentially-stale object. Default "" preserves the pre-fingerprint bare
  ## path shape (used by callers with no toolchain probe, e.g. `crisol clean`
  ## invoked without real nimVersion/ccVersion, and existing tests).
  let suffix = if toolchainFp.len > 0: "-" & toolchainFp else: ""
  stateDirOf(config) / "cache" / (epSlug(ep, config.trackedRoots) & suffix)

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
  initDepGraph("")

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
                    nimVersion: string;
                    forceCompile: bool;
                    currentProtocolMajor: int): (CompileDecision, string) =
  ## Determine whether ep needs to be compiled.
  ##
  ## Logic (in order):
  ##   1. Binary absent → cdNeverBuilt (always, regardless of forceCompile).
  ##   2. Entry absent from graph → cdStale.
  ##   3. Protocol major changed → cdStale.
  ##   4. Nim version changed → cdStale.
  ##   5. Any closure file missing → cdStale.
  ##   6. Closure content hash changed → cdStale.
  ##   7. forceCompile → cdStale (binary exists, force requested).
  ##   8. → cdSkipFresh.

  let binFull = binPath(ep, config) / binName(ep)

  if not fileExists(binFull):
    if forceCompile:
      return (cdNeverBuilt, "binary absent (--force-compile)")
    else:
      return (cdNeverBuilt, "binary absent (first run or cache cleared)")

  let fHash = flagHash(ep.flags)
  let key = (ep.path, fHash)

  if key notin graph.entries:
    return (cdStale, "no closure record in dep graph")

  let entry = graph.entries[key]

  if entry.protocolMajor != currentProtocolMajor:
    return (cdStale, "protocol major changed")

  if graph.header.nimVersion != nimVersion:
    return (cdStale, "nim version changed")

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
      return (cdStale, "closure file missing: " & display(tp))

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

proc plan*(config: Config; eps: seq[Entrypoint]; graph: DepGraph;
           nimVersion: string = ""; forceCompile: bool = false): RunPlan =
  ## Pure — no subprocess.
  ##
  ## Annotates every entrypoint with a CompileDecision via decideCompile.
  ## With an empty graph, every entrypoint is cdNeverBuilt.  The api boundary
  ## supplies the RUNTIME nim fingerprint (nimprobe.cachedNimFingerprint()),
  ## not the compile-time api.crisolNimVersion string; the "" default here is
  ## for tests / cold-start callers only and disables the nim-version
  ## staleness branch.
  ## The jobs field is resolved to at least 1; if config.jobs == 0 the A4
  ## default is max(1, cpuCount-2).

  var planned: seq[PlannedEntrypoint]
  for ep in eps:
    let (decision, reason) = decideCompile(
      ep, graph, config, nimVersion, forceCompile, CrisolProtocolMajor)
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
