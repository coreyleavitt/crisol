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

# ---------------------------------------------------------------------------
# Public: selection-reason taxonomy
# SelectionReason and SelectionResult are defined in types.nim and re-exported
# from there so callers need only `import crisol/types`.

# ---------------------------------------------------------------------------
# Public: detailed selector (D4)
# ---------------------------------------------------------------------------

proc selectByDiff*(eps: seq[Entrypoint];
                   changed: HashSet[string];
                   graph: DepGraph;
                   projectRoot: string): seq[SelectionResult] =
  ## Detailed selector: returns each included entrypoint with its
  ## `SelectionReason`.  Entrypoints that are excluded (known-fresh closure
  ## miss) do NOT appear in the result.
  ##
  ## Rule precedence for each `ep` (evaluated in order; first match wins):
  ##   1. **srGraphAbsent**    — graph.entries is empty (graph absent/empty).
  ##   2. **srOwnFileChanged** — ep.path ∈ changed.
  ##   3. **srUnknownClosure** — no entry in graph for (ep.path, flagHash(ep.flags)).
  ##   4. **srStaleEntry**     — isEntryStale returns true (a closure file vanished).
  ##   5. **srClosureHit**     — known fresh closure ∩ changed ≠ ∅  → include.
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
    if ep.path in changed:
      result.add (ep: ep, reason: srOwnFileChanged)
      continue

    let key = (ep.path, flagHash(ep.flags))

    # Rule 3: no entry in graph for this key → unknown closure.
    if key notin graph.entries:
      result.add (ep: ep, reason: srUnknownClosure)
      continue

    # Rule 4: entry exists but a closure file has been deleted → stale.
    if isEntryStale(graph, key, projectRoot):
      result.add (ep: ep, reason: srStaleEntry)
      continue

    # Rule 5: known fresh closure — include iff it intersects `changed`.
    let closure = graph.entries[key].closure
    if not disjoint(closure, changed):
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
                   changed: HashSet[string];
                   graph: DepGraph;
                   projectRoot: string): seq[Entrypoint] =
  ## PURE: returns the subset of `eps` that should be run given `changed`.
  ## Delegates to `selectByDiff` for the full D4 taxonomy; strips reasons for
  ## callers that only need the entrypoint list.
  ##
  ## Input order of `eps` is preserved in the output.
  let detailed = selectByDiff(eps, changed, graph, projectRoot)
  result = newSeq[Entrypoint]()
  for item in detailed:
    result.add item.ep
