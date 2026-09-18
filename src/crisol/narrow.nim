## narrow.nim — D3+D4: diff ∩ closure selection with conservative fallback taxonomy.
##
## `narrowByDiff` is a PURE function (no I/O beyond `isEntryStale`'s
## file-existence probes) that keeps only those entrypoints whose dependency
## closure intersects the changed-file set.  The safe bias is the whole point:
## uncertainty ALWAYS includes; the ONLY exclusion path is a known-fresh-entry
## closure-miss.
##
## D3 covers the known-closure case (entry present in graph).
## D4 adds the full uncertainty taxonomy (graph absent / own-file-changed /
## unknown closure / stale entry) with per-ep selection reasons and a
## human-facing summary-message helper.
##
## ## "Graph absent" vs "entry missing"
##
## `graph.entries.len == 0` is used to distinguish a globally absent/empty
## graph from a graph that is present but simply lacks an entry for this
## particular entrypoint.  A `loadDepGraph` on a missing file returns
## `initDepGraph`, which has an empty `.entries` table — so `len == 0` cleanly
## represents "the graph was never built or was invalidated wholesale".  A
## graph with entries but no key for *this* ep is "unknown closure".

import std/[sets, strutils, tables]
import crisol/types
import crisol/depgraph
import crisol/paths

# ---------------------------------------------------------------------------
# Public: selection-reason taxonomy
# SelectionReason and SelectionResult are defined in types.nim and re-exported
# from there so callers need only `import crisol/types`.

# ---------------------------------------------------------------------------
# Public: detailed selector (D4)
# ---------------------------------------------------------------------------

proc selectByDiff*(eps: seq[Entrypoint];
                   changed: HashSet[TrackedPath];
                   graph: DepGraph;
                   roots: TrackedRoots;
                   projectRoot: string): seq[SelectionResult] =
  ## Detailed selector: returns each included entrypoint with its
  ## `SelectionReason`.  Entrypoints that are excluded (known-fresh closure
  ## miss) do NOT appear in the result.
  ##
  ## Rule precedence for each `ep` (evaluated in order; first match wins):
  ##   1. **srGraphAbsent**    — graph.entries is empty (graph absent/empty).
  ##   2. **srOwnFileChanged** — ep.tp ∈ changed.
  ##   3. **srUnknownClosure** — no entry in graph for (ep.tp.display(), flagHash(ep.flags)).
  ##   4. **srStaleEntry**     — isEntryStale returns true (a closure file vanished).
  ##   5. **srClosureHit**     — known fresh closure ∩ changed ≠ ∅ (both already
  ##                             `HashSet[TrackedPath]` — RFC-0009 A3c-ii;
  ##                             `entry.closure` is compared directly, no
  ##                             string->TrackedPath reduction needed) → include.
  ##   (excluded)              — known fresh closure ∩ changed = ∅  → skip.
  ##
  ## Input order of `eps` is preserved.  The only side effect is the
  ## `fileExists` calls inside `isEntryStale` (D2's responsibility).
  result = newSeq[SelectionResult]()
  let graphAbsent = graph.entries.len == 0
  for ep in eps:
    # Rule 1: graph entirely absent → force-include everything.
    if graphAbsent:
      result.add (ep: ep, reason: srGraphAbsent)
      continue

    # Rule 2: entrypoint's own source file was edited → always run.
    # `ep.tp` already IS the entrypoint's TrackedPath identity — no
    # re-derivation via `fromCanonical` needed.
    if ep.tp in changed:
      result.add (ep: ep, reason: srOwnFileChanged)
      continue

    let key = entryKey(ep.tp, ep.flags)

    # Rule 3: no entry in graph for this key → unknown closure.
    if key notin graph.entries:
      result.add (ep: ep, reason: srUnknownClosure)
      continue

    # Rule 4: entry exists but a closure file has been deleted → stale.
    if isEntryStale(graph, key, projectRoot, roots):
      result.add (ep: ep, reason: srStaleEntry)
      continue

    # Rule 5: known fresh closure — include iff it intersects `changed`.
    # RFC-0009 A3c-ii: `graph.entries[key].closure` is already
    # `HashSet[TrackedPath]` (classified at load, `depgraph.fromJson`) —
    # compared directly against `changed`, no reduction step.
    if not disjoint(graph.entries[key].closure, changed):
      result.add (ep: ep, reason: srClosureHit)
    # else: closure miss → excluded (the only exclusion path)

# ---------------------------------------------------------------------------
# Public: summary message helper (D4)
# ---------------------------------------------------------------------------

proc fallbackNotes*(selected: seq[SelectionResult]; totalDiscovered: int): string =
  ## Pure function: given the detailed selection result and the total number of
  ## discovered entrypoints, return a human-facing notes string describing any
  ## conservative over-selection.
  ##
  ## Emits (in order, each on its own line, only when applicable):
  ##   "dep graph absent — full run"
  ##     → when every selected ep carries srGraphAbsent.
  ##   "N entrypoint(s) force-included: K unknown closure, J stale, I own-file"
  ##     → when any ep was conservatively included for non-hit reasons.
  ##
  ## Returns "" when the selection was entirely precise (only srClosureHit,
  ## or nothing selected at all with no conservative inclusions).
  var
    graphAbsentCount  = 0
    ownFileCount      = 0
    unknownCount      = 0
    staleCount        = 0
    closureHitCount   = 0
  for item in selected:
    case item.reason
    of srGraphAbsent:    inc graphAbsentCount
    of srOwnFileChanged: inc ownFileCount
    of srUnknownClosure: inc unknownCount
    of srStaleEntry:     inc staleCount
    of srClosureHit:     inc closureHitCount

  var lines: seq[string] = @[]

  # When the entire run is driven by absent graph, say so explicitly.
  if graphAbsentCount > 0 and graphAbsentCount == selected.len:
    lines.add "dep graph absent — full run"
  elif graphAbsentCount > 0:
    # Mixed: some srGraphAbsent among others (shouldn't occur given rule 1
    # short-circuits everything, but be safe).
    lines.add "dep graph absent — full run"

  # Conservative force-inclusions beyond the graph-absent case.
  let forceCount = ownFileCount + unknownCount + staleCount
  if forceCount > 0:
    var parts: seq[string] = @[]
    if unknownCount > 0: parts.add $unknownCount & " unknown closure"
    if staleCount   > 0: parts.add $staleCount   & " stale"
    if ownFileCount > 0: parts.add $ownFileCount  & " own-file"
    lines.add $forceCount & " entrypoint(s) force-included: " & parts.join(", ")

  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public: pipeline API (D3+D4 combined; RFC signature)
# ---------------------------------------------------------------------------

proc narrowByDiff*(eps: seq[Entrypoint];
                   changed: HashSet[TrackedPath];
                   graph: DepGraph;
                   roots: TrackedRoots;
                   projectRoot: string): seq[Entrypoint] =
  ## PURE: returns the subset of `eps` that should be run given `changed`.
  ## Delegates to `selectByDiff` for the full D4 taxonomy; strips reasons for
  ## callers that only need the entrypoint list.
  ##
  ## Input order of `eps` is preserved in the output.
  let detailed = selectByDiff(eps, changed, graph, roots, projectRoot)
  result = newSeq[Entrypoint]()
  for item in detailed:
    result.add item.ep

# ---------------------------------------------------------------------------
# Public: NFC/NFD changed-set fold-trust lever (RFC-0009 "Risks accepted")
# ---------------------------------------------------------------------------
##
## docs/rfc/0009-path-identity.md, "Risks accepted" (NFC/NFD bullet): the
## fold is deliberately ASCII-only (`paths.fold`, `fpAsciiLower ==
## toLowerAscii`). On a folding root, HFS+/APFS-style Unicode normalization
## (NFC vs NFD) can make a `--changed` diff name and the on-disk spelling of
## the SAME file fold to two DISTINCT `TrackedPath`s — a silent
## under-selection the ASCII fold cannot see, because the two byte
## sequences never compare equal under `toLowerAscii` either. The accepted
## mitigation: when the changed set contains a non-ASCII name AND some
## tracked root actually folds, do not trust fold-based narrowing for this
## run at all — fall back to the full discovered set, mirroring the
## conservative lever `pipeline.buildRunPlan` already applies for a
## genuinely degraded probe (`TrackedRoots.degraded`).
##
## `foldUntrusted` is a SEPARATE, narrower signal than `degraded`: every
## probe answered definitively here (nothing failed) — only the *diff-driven
## narrowing decision* is untrusted for this run, not the probe, the cache,
## or dep-graph persistence. Setting `TrackedRoots.degraded` instead would
## have piggy-backed on unrelated behavior (cache bypass, no depgraph
## persist — RFC-0009 A-degraded D4/D5) that this residual risk does not
## warrant.

proc changedSetHasNonAscii*(changed: HashSet[TrackedPath]): bool =
  ## True iff some member of `changed` has a non-ASCII byte anywhere in its
  ## stored spelling (`display`, the real-case, root-relative spelling —
  ## RFC-0009 A1).
  ##
  ## Deliberately checks the ALREADY-REDUCED `TrackedPath`, not the raw git
  ## diff name string: `gitdiff.reduceChangedName` (`fromCanonical`/
  ## `classify`) only decides WHICH tracked root a name falls under — it
  ## never strips, re-encodes, or otherwise transforms a byte of the name
  ## — so this is byte-for-byte equivalent to scanning the raw diff name,
  ## with one deliberate difference that is exactly the desired scoping: a
  ## name that resolves OUTSIDE every tracked root never becomes a
  ## `TrackedPath` at all (`gitdiff.reduceChangedName` drops it), so it can
  ## never spuriously trigger this lever. Over-triggering on a genuinely
  ## unrelated non-ASCII name elsewhere in the repo is therefore not
  ## possible — only names within a tracked root's textual reach count.
  for tp in changed:
    for ch in string(display(tp)):
      if ord(ch) > 127:
        return true
  false

proc anyRootFolds*(roots: TrackedRoots): bool =
  ## True iff the project root or any configured dep root has an active
  ## (non-`fpNone`) fold policy. On the Linux default (every root
  ## genuinely case-sensitive, `fpNone` everywhere) this is always false,
  ## so `foldUntrusted` below is always false too — zero behavior change,
  ## one cheap enum comparison per root.
  if roots.project.foldPolicy != fpNone:
    return true
  for d in roots.deps:
    if d.foldPolicy != fpNone:
      return true
  false

proc foldUntrusted*(changed: HashSet[TrackedPath]; roots: TrackedRoots): bool =
  ## PURE: true iff the accepted NFC/NFD mitigation should force a full run
  ## instead of trusting fold-based `--changed` narrowing this run — i.e.
  ## `changed` carries a non-ASCII name AND some tracked root actually
  ## folds. See the section doc comment above for the full rationale and
  ## why this is a separate signal from `TrackedRoots.degraded`.
  ##
  ## Safe to call unconditionally (including when `--changed` was never
  ## requested): an empty `changed` set always answers false.
  anyRootFolds(roots) and changedSetHasNonAscii(changed)
