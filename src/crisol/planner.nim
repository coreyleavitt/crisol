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

import std/[algorithm, os, sequtils, sets, strutils, tables]
import std/cpuinfo
import crisol/[types, depgraph]

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

proc binName*(ep: Entrypoint): string =
  ## Basename of the compiled binary (no extension).
  ep.path.extractFilename().changeFileExt("")

proc binPath*(ep: Entrypoint; config: Config): string =
  ## Absolute path to the directory containing the stable compiled binary.
  config.projectRoot / config.stateDir / "bin" / slug(ep.path, ep.flags)

proc cachePath*(ep: Entrypoint; config: Config): string =
  ## Absolute path to the stable nimcache directory for this entrypoint.
  config.projectRoot / config.stateDir / "cache" / slug(ep.path, ep.flags)

# ---------------------------------------------------------------------------
# emptyDepGraph convenience wrapper
# ---------------------------------------------------------------------------

proc emptyDepGraph*(): DepGraph =
  ## Return an empty DepGraph (nimVersion = "").
  ## Convenience wrapper used by tests and the CLI until a real graph is loaded.
  initDepGraph("")

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
  var sortedClosure: seq[string] = toSeq(entry.closure)
  sortedClosure.sort()

  for f in sortedClosure:
    let absPath =
      if f.isAbsolute: f
      else: config.projectRoot / f
    if not fileExists(absPath):
      return (cdStale, "closure file missing: " & f)

  # Compute current content hash.
  var computedHash: string
  try:
    computedHash = closureContentHash(sortedClosure, config.projectRoot)
  except:
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
  ## With an empty graph (or nimVersion=""), every entrypoint is cdNeverBuilt.
  ## The jobs field is resolved to at least 1; if config.jobs == 0 the A4
  ## default is max(1, cpuCount-2).

  var planned: seq[PlannedEntrypoint]
  for ep in eps:
    let (decision, reason) = decideCompile(
      ep, graph, config, nimVersion, forceCompile, CrisolProtocolMajor)
    planned.add PlannedEntrypoint(
      ep:       ep,
      decision: decision,
      reason:   reason,
    )

  let resolvedJobs =
    if config.jobs > 0:
      config.jobs
    else:
      max(1, countProcessors() - 2)

  RunPlan(entrypoints: planned, jobs: resolvedJobs)
