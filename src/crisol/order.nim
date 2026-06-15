## order.nim — C4: history-based entrypoint prioritization (--order).
##
## Implements `OrderMode` enum, `parseOrderMode`, and the two-layer design:
##   • `orderBy`       — PURE proc: takes pre-built signal tables, returns a
##                       reordered (permuted) seq[Entrypoint].
##   • `orderByHistory` — I/O wrapper: reads the ledger, builds the two tables,
##                        calls `orderBy`.
##
## ## Semantics
##
## omNone (default):
##   Identity — return eps unchanged.  No I/O.  Pipeline-parity guarantee:
##   with omNone the pipeline is byte-for-byte identical to the unordered case.
##
## omRecentFail:
##   Entrypoints with a more recent last-failure timestamp come FIRST (descending
##   `lastFail` timestamp).  Entrypoints with no recorded failure come AFTER all
##   that have one.  Within the same tier, tie-break by lexicographic ep.path.
##   Cold-start (empty lastFail table) → lexicographic ep.path order.
##   Goal: surface recently-failing tests first (APFD).
##
## omDuration:
##   Order by historical median duration DESCENDING (longest-first — start the
##   big jobs early to minimise total wall-clock under bounded parallelism).
##   Tie-break by lexicographic ep.path.
##   Eps with no duration history sort as if duration=0 (i.e. last, after all
##   eps that have a measured duration), tie-broken lexicographically.
##   Cold-start (empty medianDur table) → lexicographic ep.path order.
##
## ## Cold-start rule
##
## When the ledger yields NO signal for the requested mode (every relevant
## table empty), omRecentFail and omDuration fall back to stable lexicographic
## ep.path order — NOT input order.  omNone stays identity in all cases.
##
## ## Failure outcomes
##
## An outcome string is a failure if it is one of:
##   "exitNonZero", "compileFailed", "timedOut", "signaled", "spawnError"
## i.e. any outcome != "passed" that is a terminal outcome.
## These match the stable wire strings in jsonout.nim / outcomeString.
##
## "compileFailed" rows are ALSO excluded from the duration median computation
## (their durationUs reflects only the compiler, not the test-binary run time)
## — consistent with C3 sharding's outcome filter in shard.nim.
##
## ## Tables
##
## `lastFail[ep.path]`  = max timestamp among failure rows for that ep.
## `medianDur[ep.path]` = median durationUs of non-compileFailed rows for that ep.
##
## Both tables are keyed by ep.path (project-root-relative string), matching
## how Entrypoint.path is stored and how shard.nim keys its duration table.

import std/[algorithm, sequtils, tables]
import crisol/types
import crisol/ledger         # for scanLedger, LedgerRow, currentRowVersion
import crisol/keys           # for identityKey
import crisol/depgraph       # for flagHash
import crisol/stats          # for median (C6: shared stats module)
import crisol/outcomestrings # for isFailureOutcomeString, isCompileFailedOutcomeString

# ---------------------------------------------------------------------------
# Public: OrderMode enum
# ---------------------------------------------------------------------------

type
  OrderMode* = enum
    omNone       ## default: no reorder; identity on the runnable seq
    omRecentFail ## recent-fail-first: most recently failed ep runs earliest
    omDuration   ## duration-first: longest historical ep runs earliest

# ---------------------------------------------------------------------------
# Public: parseOrderMode
# ---------------------------------------------------------------------------

proc parseOrderMode*(raw: string): OrderMode =
  ## Parse a --order value string to an OrderMode.
  ## Raises ValueError with a descriptive message on unknown values.
  ## Callers that map ValueError to exit-3 (the CLI) catch as needed.
  case raw
  of "none":        omNone
  of "recent-fail": omRecentFail
  of "duration":    omDuration
  else:
    raise newException(ValueError,
      "--order: unknown mode '" & raw &
      "'; valid values: none, recent-fail, duration")

# ---------------------------------------------------------------------------
# Internal: failure outcome predicate — delegates to outcomestrings
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Public: orderBy — PURE ordering function
# ---------------------------------------------------------------------------

proc orderBy*(
  eps:       seq[Entrypoint];
  mode:      OrderMode;
  lastFail:  Table[string, int64];
  medianDur: Table[string, int64];
): seq[Entrypoint] =
  ## Pure ordering function.  Returns a PERMUTATION of `eps` — same set,
  ## same length, potentially different sequence.
  ##
  ## `lastFail`  — maps ep.path → max failure timestamp (unix epoch µs).
  ##               Built by the I/O wrapper; absent = no recorded failure.
  ## `medianDur` — maps ep.path → median durationUs (excluding compileFailed rows).
  ##               Built by the I/O wrapper; absent = no history.
  ##
  ## Precondition: eps, lastFail, medianDur are all consistent (same ep set);
  ## the caller (orderByHistory) is responsible for ensuring correctness.
  ## Postcondition: result is a permutation of eps (same length, same paths).
  case mode
  of omNone:
    # Identity — return unchanged (NOT a copy; callers get the same sequence).
    return eps

  of omRecentFail:
    ## Cold-start check: if lastFail is empty, every ep is in the "never-failed"
    ## tier, so the result is just lex-sorted eps.
    if lastFail.len == 0:
      var sorted = eps
      sorted.sort(proc(a, b: Entrypoint): int = cmp(a.path, b.path))
      return sorted

    ## Two-tier sort:
    ##   Tier 0 (has a recorded failure): descending lastFail timestamp; lex tie-break.
    ##   Tier 1 (never failed):           ascending ep.path.
    var withFail    = eps.filterIt(it.path in lastFail)
    var withoutFail = eps.filterIt(it.path notin lastFail)

    withFail.sort(proc(a, b: Entrypoint): int =
      let ta = lastFail[a.path]
      let tb = lastFail[b.path]
      if ta != tb: return cmp(tb, ta)   # DESC timestamp (more recent = smaller cmp result)
      cmp(a.path, b.path)               # ASC path tie-break
    )
    withoutFail.sort(proc(a, b: Entrypoint): int = cmp(a.path, b.path))

    return withFail & withoutFail

  of omDuration:
    ## Cold-start check: if medianDur is empty, all eps have duration=0 (no history)
    ## → just lex-sort.
    if medianDur.len == 0:
      var sorted = eps
      sorted.sort(proc(a, b: Entrypoint): int = cmp(a.path, b.path))
      return sorted

    ## Single-tier sort: descending medianDur; absent ep → 0; lex tie-break.
    ## Eps without history get 0, which sorts last (all measured > 0 nominally,
    ## and any tie at 0 is broken by lex path).
    var sorted = eps
    sorted.sort(proc(a, b: Entrypoint): int =
      let da = medianDur.getOrDefault(a.path, 0'i64)
      let db = medianDur.getOrDefault(b.path, 0'i64)
      if da != db: return cmp(db, da)   # DESC duration
      cmp(a.path, b.path)               # ASC path tie-break
    )
    return sorted

# ---------------------------------------------------------------------------
# Public: orderByHistory — ledger-aware I/O wrapper
# ---------------------------------------------------------------------------

proc orderByHistory*(
  eps:      seq[Entrypoint];
  mode:     OrderMode;
  stateDir: string;
): seq[Entrypoint] =
  ## Ledger-aware ordering wrapper.
  ##
  ## For omNone: returns eps unchanged without reading the ledger (zero I/O).
  ##
  ## For omRecentFail:
  ##   Reads scanLedger per ep, builds lastFail[ep.path] = max timestamp among
  ##   rows whose outcome is a failure (exitNonZero, compileFailed, timedOut,
  ##   signaled, spawnError).  Passes empty medianDur (not needed for this mode).
  ##
  ## For omDuration:
  ##   Reads scanLedger per ep, builds medianDur[ep.path] = median durationUs
  ##   of rows whose outcome does NOT start with "compileFailed" (same exclusion
  ##   rule as C3 shardWithHistory — compileFailed rows have 0 or tiny durationUs
  ##   that reflects only the compiler, not the test-binary run time).
  ##   Passes empty lastFail (not needed for this mode).
  ##
  ## stateDir: resolved absolute path to the state dir (caller must resolve
  ##   cfg.projectRoot / cfg.stateDir before calling; mirrors shardWithHistory).
  ##
  ## Cold-start (no rows for any ep → tables stay empty) → orderBy applies its
  ## lexicographic fallback for non-None modes.
  if mode == omNone:
    return eps   # zero I/O; identity

  var lastFail  = initTable[string, int64]()
  var medianDur = initTable[string, int64]()

  for ep in eps:
    let ik   = identityKey(ep.path, flagHash(ep.flags))
    let rows = scanLedger(stateDir, ik)

    case mode
    of omNone:
      discard  # unreachable; handled above
    of omRecentFail:
      # Build lastFail: max timestamp among failure rows.
      var maxTs = int64(-1)
      for r in rows:
        if isFailureOutcomeString(r.outcome):
          if r.timestamp > maxTs:
            maxTs = r.timestamp
      if maxTs >= 0:
        lastFail[ep.path] = maxTs

    of omDuration:
      # Build medianDur: median of non-compileFailed durationUs rows.
      # Mirrors C3 shardWithHistory's outcome filter.
      var durs: seq[int64] = @[]
      for r in rows:
        if not isCompileFailedOutcomeString(r.outcome):
          durs.add r.durationUs
      if durs.len > 0:
        medianDur[ep.path] = median(durs)

  orderBy(eps, mode, lastFail, medianDur)
