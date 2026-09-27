## narrow.nim — D3+D4: diff ∩ closure selection with conservative fallback.
##
## `narrowByDiff` keeps only those entrypoints whose watched set (closure
## members plus recorded links) the changed-file set reaches. Its only I/O is
## rule 4's staleness check (`depgraph.isEntryStale`, i.e. `entryDrift`: a
## member's existence, each recorded link's target, and whether a directory
## on a member's path is now an unrecorded link); every other rule is pure
## (rule 5 is `depgraph.diffReach`).  The safe bias is the whole point:
## uncertainty ALWAYS includes; the ONLY exclusion path is a known-fresh-entry
## closure-miss.
##
## Why an entrypoint was included is not returned (R13-D6): nothing reads
## it, and `--json` reports the plan, not the rule. A caller that wants the
## evidence for rule 5 asks `depgraph.diffReach` (a typed `Hit`), and for
## rule 4 `depgraph.entryDrift` (a typed `Drift`).
##
## ## "Graph absent" vs "entry missing"
##
## `graph.entries.len == 0` is used to distinguish a globally absent/empty
## graph from a graph that is present but simply lacks an entry for this
## particular entrypoint.  A `loadDepGraph` on a missing file returns
## `initDepGraph`, which has an empty `.entries` table — so `len == 0` cleanly
## represents "the graph was never built or was invalidated wholesale".  A
## graph with entries but no key for *this* ep is "unknown closure".

import std/[options, sets, tables]
import crisol/types
import crisol/depgraph
import crisol/paths

# ---------------------------------------------------------------------------
# Public: the selector
# ---------------------------------------------------------------------------

proc narrowByDiff*(eps: seq[Entrypoint];
                   changed: HashSet[TrackedPath];
                   graph: DepGraph;
                   roots: TrackedRoots): seq[Entrypoint] =
  ## Returns the subset of `eps` that should be run given `changed`. Every
  ## path is resolved through `roots`.
  ##
  ## Rules for each `ep` (evaluated in order; the first that applies
  ## includes it):
  ##   1. graph absent  — graph.entries is empty.
  ##   2. own file      — ep.tp ∈ changed.
  ##   3. unknown       — no entry in graph for (ep.tp.display(), flagHash(ep.flags)).
  ##   4. stale         — isEntryStale returns true (`entryDrift`: a
  ##                      closure file vanished, a recorded link moved, or
  ##                      a directory on a member's path is now a link the
  ##                      entry did not record, R13-S1).
  ##   5. reached       — `depgraph.diffReach` finds the changed set
  ##                      reaching the fresh entry's watched set: a changed
  ##                      name is a member, is or contains or lies under a
  ##                      recorded link (R12-D1), or is a directory above a
  ##                      member (R13-S1: a submodule turned into a link is
  ##                      named by its own path alone).
  ##   (excluded)       — none of them → skip.
  ##
  ## Input order of `eps` is preserved.  The only file-system reads are
  ## `isEntryStale`'s (rule 4).
  result = newSeq[Entrypoint]()
  let graphAbsent = graph.entries.len == 0
  for ep in eps:
    # Rule 1: graph entirely absent → include everything.
    # Rule 2: the entrypoint's own source file was edited. `ep.tp` already
    # IS the entrypoint's TrackedPath identity.
    if graphAbsent or ep.tp in changed:
      result.add ep
      continue
    let key = entryKey(ep.tp, ep.flags)
    # Rule 3: no entry in graph for this key → unknown closure.
    # Rule 4: the entry has drifted from the file system → stale.
    # Rule 5: known fresh entry — include iff the changed set reaches its
    # watched set (`depgraph.diffReach`, the one diff-selection predicate).
    if key notin graph.entries or isEntryStale(graph, key, roots) or
        diffReach(graph.entries[key], changed, roots).isSome:
      result.add ep
    # else: closure miss → excluded (the only exclusion path)

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
  ## True iff the project root or any configured dep root has a
  ## case-folding policy, per the shared `paths.folds` predicate (RFC-0009
  ## wiring-audit W9m — the single source of truth for "does this policy
  ## fold case", also used by `paths.foldMatchesSomeRoot`, so the two can
  ## never silently disagree about what counts as folding). On the Linux
  ## default (every root genuinely case-sensitive, `fpNone` everywhere)
  ## this is always false, so `foldUntrusted` below is always false too —
  ## zero behavior change, one cheap call per root.
  if roots.project.foldPolicy.folds:
    return true
  for d in roots.deps:
    if d.foldPolicy.folds:
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
