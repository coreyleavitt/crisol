## render.nim — B4 rich reporting for crisol
##
## Public API:
##
##   RenderOpts* = object
##     color*:     bool          -- emit ANSI color sequences (caller computes from isatty+NO_COLOR)
##     slowestN*:  int           -- how many slowest tests/entrypoints to list (default 5)
##     filterTag*: Option[string] -- C3: when set, show ONLY records whose tags contains it
##
##   render*(results, summary, opts): string
##     Pure: produces the full human-readable report.
##     Takes seq[EntrypointResult] + Summary; never performs I/O.
##     When opts.filterTag is set, only matching test records are shown and their
##     displayed counts reflect the filtered view.  Entrypoint outcomes, summary
##     verdict, and exit code are NEVER altered by the filter — they are
##     determined from the full unfiltered run.
##
##   filterRecordsByTag*(records: seq[TestRecord]; tag: string): seq[TestRecord]
##     Pure: return only records whose tags seq contains `tag`.
##
##   hasZeroTagMatches*(results: seq[EntrypointResult]; tag: string): bool
##     Pure: true iff no record across all entrypoints carries `tag`.
##     Zero-match detection predicate — testable without I/O.
##
##   MemThrottleSignalMs*: int
##     Threshold (ms) after which continuous memory-throttling is shown in the
##     progress line.  Default 5000 (5 seconds).
##
##   memThrottleActive*(throttledSince, now, thresholdMs): bool
##     Pure: true iff throttledSince.isSome AND (now - throttledSince.get) > thresholdMs.
##     Pass synthetic MonoTime values for deterministic unit testing (no real sleep needed).
##
##   formatProgressLine*(inFlight: seq[(string, int64)]; memThrottled: bool): string
##     Pure: format one "still running" line from a list of (name, elapsedMs) pairs.
##     When memThrottled=true, appends " [mem-throttled]" to the line.
##     Empty inFlight → returns "".
##
## Color gating (RFC B4):
##   Color is emitted ONLY when opts.color == true.  The CLI sets opts.color from
##   terminal.shouldEnableColor(isatty(stdout.getFileHandle())).  Render itself is
##   fully pure — no isatty call and no env reads inside.
##
## Slowest-N granularity:
##   When records are present in ANY result, slowest-N is computed at test
##   granularity (by durationUs).  When NO result carries records (all opaque
##   binaries), slowest-N falls back to entrypoint granularity (by durationMs).
##   Mixed runs (some results have records, some don't) use test-granularity for
##   the record-bearing results only.
##
## C3 filter semantics:
##   The filter is a REPORTING LENS — it never changes execution or verdict.
##   What changes: which test record lines are displayed; per-entrypoint record
##   counts in the summary line; the aggregate test-record counts section.
##   What does NOT change: entrypoint outcome labels ([OK]/[FAIL]/…); the
##   PASSED/FAILED verdict; the exit code; the slowest-N section (computed on
##   ALL records, not filtered, so "slowest" is not a distorted filtered view).

import std/[algorithm, monotimes, os, options, sequtils, strutils, times]
import crisol/types

# ---------------------------------------------------------------------------
# C3 pure filter predicates
# ---------------------------------------------------------------------------

proc filterRecordsByTag*(records: seq[TestRecord]; tag: string): seq[TestRecord] =
  ## Pure: return only records whose tags seq contains `tag`.
  ## Empty tag → returns all records unchanged (safety guard; callers
  ## should not call with an empty tag — use Option[string] at the boundary).
  if tag.len == 0: return records
  records.filterIt(tag in it.tags)

proc hasZeroTagMatches*(results: seq[EntrypointResult]; tag: string): bool =
  ## Pure: true iff no TestRecord across all EntrypointResults carries `tag`.
  ## This is the zero-match detection predicate for the C3 warning.
  if tag.len == 0: return false
  for r in results:
    for rec in r.records:
      if tag in rec.tags: return false
  true

# ---------------------------------------------------------------------------
# ANSI color codes — applied only when opts.color = true
# ---------------------------------------------------------------------------

const
  Ansi_Reset*   = "\e[0m"
  Ansi_Green*   = "\e[32m"
  Ansi_Red*     = "\e[31m"
  Ansi_Yellow*  = "\e[33m"
  Ansi_Cyan*    = "\e[36m"
  Ansi_Bold*    = "\e[1m"
  Ansi_Dim*     = "\e[2m"

# ---------------------------------------------------------------------------
# RenderOpts
# ---------------------------------------------------------------------------

type
  RenderOpts* = object
    color*:     bool           ## emit ANSI color codes
    slowestN*:  int            ## how many slowest items to show (0 → use default of 5)
    filterTag*: Option[string] ## C3: when set, only records with this tag are displayed

proc defaultOpts*(): RenderOpts =
  RenderOpts(color: false, slowestN: 5, filterTag: none(string))

# ---------------------------------------------------------------------------
# Color helpers (kept thin; render logic uses these)
# ---------------------------------------------------------------------------

proc col*(text: string; code: string; enabled: bool): string {.inline.} =
  if enabled: code & text & Ansi_Reset else: text

# ---------------------------------------------------------------------------
# formatProgressLine — PURE (M4: memThrottled signal)
# ---------------------------------------------------------------------------

const
  MemThrottleSignalMs* = 5000
    ## Threshold (ms) of continuous memory-throttling before the progress line
    ## shows the "[mem-throttled]" signal (M4 finding).  Named so it can be
    ## referenced in tests without magic numbers.

proc memThrottleActive*(throttledSince: Option[MonoTime]; now: MonoTime;
                        thresholdMs: int): bool =
  ## Pure: true iff memory-throttling has been continuously active longer than
  ## thresholdMs milliseconds.
  ##
  ## throttledSince: Some(t) = the MonoTime when throttling became active;
  ##                 None    = throttling is not currently active.
  ## now:            the current MonoTime (injected by the caller — never read
  ##                 from the clock here; keeps this function deterministically
  ##                 testable with synthetic MonoTime values).
  ## thresholdMs:    threshold in milliseconds (strictly greater than).
  ##
  ## Returns false immediately when throttledSince.isNone.
  if throttledSince.isNone:
    return false
  let elapsedMs = (now - throttledSince.get).inMilliseconds
  elapsedMs > int64(thresholdMs)

proc formatProgressLine*(inFlight: seq[(string, int64)];
                         memThrottled: bool = false): string =
  ## Pure: format one "still running" stderr progress line.
  ## inFlight is a list of (entrypoint path, elapsedMs) pairs.
  ## memThrottled: when true, appends " [mem-throttled]" to the line.
  ## Returns "" when inFlight is empty.
  if inFlight.len == 0:
    return ""

  var parts: seq[string]
  for (name, ms) in inFlight:
    let secStr =
      if ms < 1000:
        $ms & "ms"
      else:
        $(ms div 1000) & "s"
    parts.add name.extractFilename & " (" & secStr & ")"

  result = "crisol: still running: " & parts.join(", ")
  if memThrottled:
    result.add " [mem-throttled]"

# ---------------------------------------------------------------------------
# Outcome label helpers
# ---------------------------------------------------------------------------

proc outcomeLabel(o: Outcome): string =
  case o
  of oPassed:        "[OK]     "
  of oFailed:        "[FAIL]   "
  of oCompileFailed: "[COMPILE]"
  of oTimeout:       "[TIMEOUT]"
  of oSignal:        "[SIGNAL] "
  of oSpawnError:    "[SPAWN]  "

proc outcomeColor(o: Outcome): string =
  case o
  of oPassed:        Ansi_Green
  of oFailed:        Ansi_Red
  of oCompileFailed: Ansi_Yellow
  of oTimeout:       Ansi_Yellow
  of oSignal:        Ansi_Red
  of oSpawnError:    Ansi_Red

# ---------------------------------------------------------------------------
# Per-entrypoint record counts
# ---------------------------------------------------------------------------

type RecordCounts = object
  total:  int
  passed: int
  failed: int
  skipped: int

proc countRecords(records: seq[TestRecord]): RecordCounts =
  result.total = records.len
  for r in records:
    case r.status
    of rsPass: inc result.passed
    of rsFail: inc result.failed
    of rsSkip: inc result.skipped

# ---------------------------------------------------------------------------
# render — PURE
# ---------------------------------------------------------------------------

proc gateSkipMessages*(gatedOut: seq[tuple[group: string; reason: string]]): seq[string] =
  ## PURE: convert a gatedOut list (from applyGates) into human-readable
  ## skip message lines.  Each line names the gated group and the reason.
  ## Empty input → empty result (no-op).
  ## Example output line: "skipped group \"integration\" — env FRESCO_DB_URL not set"
  for entry in gatedOut:
    result.add "skipped group \"" & entry.group & "\" — " & entry.reason

proc gateSkipMessages*(gatedOut: seq[GatedEntry]): seq[string] =
  ## Overload accepting GatedEntry (path+group+reason). Deduplicates by group.
  var seen: seq[string]
  var deduped: seq[tuple[group: string; reason: string]]
  for g in gatedOut:
    if g.group notin seen:
      seen.add g.group
      deduped.add (group: g.group, reason: g.reason)
  gateSkipMessages(deduped)

proc pathFlagsWarnings*(adHocPaths: seq[string];
                         withinGroups: seq[string] = @[]): seq[string] =
  ## PURE: convert DiscoveredSet.adHocPaths (from a gskFiles discover()) into
  ## human-readable RFC-0001:409 warning lines.  Same pattern as
  ## gateSkipMessages — discover() stays pure; this is the only place the data
  ## is turned into text, and the CLI is the only place that text is written
  ## to stderr.
  ##
  ##   adHocPaths   — paths that matched no candidate group; ran with global
  ##                  flags under the ad-hoc "paths" group.  When
  ##                  `withinGroups` is non-empty (a --group was given
  ##                  alongside the path), the message names the mismatch
  ##                  against those groups rather than "no configured group".
  ##
  ## A path owned by several groups is not warned about: it runs as one leg
  ## per owning group (issue #10), which the plan listing shows explicitly.
  for p in adHocPaths:
    if withinGroups.len > 0:
      result.add "path \"" & p & "\" is not in group " & withinGroups.join(", ") &
                 "; using global flags"
    else:
      result.add "path \"" & p & "\" matched no configured group; using global flags"

proc render*(results: seq[EntrypointResult]; summary: Summary;
             opts: RenderOpts): string =
  ## Pure: produce the full human-readable report string.
  ## All I/O decisions (color, progress) are made by the caller and passed
  ## via opts; this function performs no I/O of its own.
  ##
  ## C3: when opts.filterTag is set, per-entrypoint record details and the
  ## aggregate test-record counts section reflect ONLY matching records.
  ## Entrypoint outcome labels, the PASSED/FAILED verdict, and the exit code
  ## are NEVER altered by the filter (they are derived from `summary` which is
  ## computed from the full unfiltered run).  Slowest-N is also computed on ALL
  ## records (unfiltered) so the "slowest" ranking is not distorted.

  let color  = opts.color
  let n      = if opts.slowestN > 0: opts.slowestN else: 5
  let tag    = if opts.filterTag.isSome: opts.filterTag.get else: ""
  let hasTag = tag.len > 0

  var buf = newStringOfCap(4096)

  # -------------------------------------------------------------------------
  # 1. Per-entrypoint lines
  # -------------------------------------------------------------------------
  for r in results:
    let label     = outcomeLabel(r.outcome)
    let labelCol  = col(label, outcomeColor(r.outcome), color)
    let epPath    = r.ep.path

    # C3: apply filter to the records used for display and counts.
    # The filter only affects what is SHOWN — the outcome label is unchanged.
    let displayRecords =
      if hasTag: filterRecordsByTag(r.records, tag)
      else:      r.records

    # Counts suffix — based on displayRecords (filtered view)
    let countsSuffix =
      if r.records.len > 0:
        # Even when filtered to zero we still use the filtered count so the
        # display is consistent with what follows (could be "0 tests" if tag
        # matches nothing in this entrypoint, which is fine — the zero-match
        # warning is at the global level).
        let c = countRecords(displayRecords)
        let durSec = if r.durationMs > 0: $(r.durationMs div 1000) & "s" else: ""
        let failPart =
          if c.failed > 0: $c.failed & "/" & $c.total & " failed"
          else: $c.total & " tests"
        let skipPart = if c.skipped > 0: ", " & $c.skipped & " skipped" else: ""
        let durPart  = if durSec.len > 0: ", " & durSec else: ""
        " (" & failPart & skipPart & durPart & ")"
      else:
        case r.outcome
        of oPassed:        " (" & $(r.durationMs div 1000) & "s)"
        of oCompileFailed: " (compile failed)"
        of oTimeout:       " (exceeded timeout)"
        of oSignal:
          let sigName = if r.signal > 0: "SIG#" & $r.signal else: "signal"
          " (" & sigName & ")"
        of oFailed:        " (exit " & $r.exitCode & ")"
        of oSpawnError:    " (spawn error)"

    # A8: mark results served from the ExecutionCache.  The [CACHED] tag sits
    # after the outcome label so a cached pass reads "[OK] … [CACHED]".  Cached
    # results report their HISTORICAL duration (carried on the synthesized
    # EntrypointResult), not the current invocation time.
    let cachedTag =
      if r.cached: "  " & col("[CACHED]", Ansi_Cyan, color)
      else: ""
    # B3: mark quarantined entrypoints.  [QUARANTINED] appears after [CACHED]
    # so the line reads "[FAIL] … [QUARANTINED]" or "[OK] … [CACHED] [QUARANTINED]".
    # Yellow matches the "degraded but not fatal" semantic (mirrors compile-fail color).
    let quarantinedTag =
      if r.quarantined: "  " & col("[QUARANTINED]", Ansi_Yellow, color)
      else: ""
    # C6: mark regressed entrypoints with [SLOW: <cur>µs > <threshold>µs].
    # Appears after [QUARANTINED]; uses yellow (warning, not fatal).
    let slowTag =
      if r.regressed:
        "  " & col("[SLOW: " & $(r.durationMs * 1000) & "µs > " &
                   $r.perfThresholdUs & "µs]", Ansi_Yellow, color)
      else: ""
    buf.add "  " & labelCol & "  " & epPath & countsSuffix & cachedTag & quarantinedTag & slowTag & "\n"

    # -----------------------------------------------------------------------
    # Failure / compile-fail / signal detail block
    # -----------------------------------------------------------------------
    case r.outcome
    of oFailed:
      # Show per-test failure messages first (from displayRecords).
      var failedRecords: seq[TestRecord]
      for rec in displayRecords:
        if rec.status == rsFail:
          failedRecords.add rec
      if failedRecords.len > 0:
        for rec in failedRecords:
          let indent = "           "
          buf.add indent & col("FAIL", Ansi_Red, color) & ": " & rec.name & "\n"
          if rec.msg.isSome:
            # Indent multi-line messages
            for line in rec.msg.get.splitLines:
              buf.add indent & "     " & line & "\n"
      elif r.output.len > 0 and not hasTag:
        # Opaque binary: show captured output (bounded display).
        # Suppress raw output when tag-filtering (tag filter only applies to
        # structured records; raw output is not tag-aware, so we omit it to
        # avoid confusion).
        let maxDisplay = 2000
        let outText = if r.output.len > maxDisplay:
                        r.output[0..<maxDisplay] & "\n[...truncated...]"
                      else: r.output
        for line in outText.splitLines:
          buf.add "           " & line & "\n"

    of oCompileFailed:
      if r.output.len > 0:
        let maxDisplay = 2000
        let outText = if r.output.len > maxDisplay:
                        r.output[0..<maxDisplay] & "\n[...truncated...]"
                      else: r.output
        buf.add "           " & col("Compiler output:", Ansi_Yellow, color) & "\n"
        for line in outText.splitLines:
          if line.len > 0:
            buf.add "           " & line & "\n"

    of oSignal:
      if r.output.len > 0:
        let maxDisplay = 1000
        let outText = if r.output.len > maxDisplay:
                        r.output[0..<maxDisplay] & "\n[...truncated...]"
                      else: r.output
        for line in outText.splitLines:
          if line.len > 0:
            buf.add "           " & line & "\n"

    of oTimeout:
      discard  # no extra detail needed; label is self-explanatory

    of oPassed:
      # Skip details shown only in verbose (not implemented in B4).
      # Show skip reasons from displayRecords for passes with skips.
      var skipRecords: seq[TestRecord]
      for rec in displayRecords:
        if rec.status == rsSkip:
          skipRecords.add rec
      if skipRecords.len > 0:
        for rec in skipRecords:
          let reason = if rec.msg.isSome: rec.msg.get else: "(no reason)"
          buf.add "           " & col("SKIP", Ansi_Dim, color) & ": " & rec.name &
                  " — " & reason & "\n"

    of oSpawnError:
      if r.output.len > 0:
        buf.add "           " & r.output & "\n"

  # -------------------------------------------------------------------------
  # 2. Slowest-N section
  # -------------------------------------------------------------------------
  # Slowest-N always operates on ALL records (unfiltered).  The filter is a
  # reporting lens; it should not distort the slowness ranking.
  let anyHaveRecords = results.anyIt(it.records.len > 0)

  if anyHaveRecords:
    # Collect (name, durationUs) from all records across all entrypoints.
    var allTests: seq[(string, int64, string)]  # (testName, durationUs, epPath)
    for r in results:
      for rec in r.records:
        allTests.add (rec.name, rec.durationUs, r.ep.path)

    if allTests.len > 0:
      # Sort descending by durationUs
      allTests.sort(proc(a, b: (string, int64, string)): int =
        cmp(b[1], a[1]))
      let topN = allTests[0 ..< min(n, allTests.len)]

      buf.add "\n"
      buf.add col("Slowest " & $topN.len & " tests:\n", Ansi_Dim, color)
      for (name, us, ep) in topN:
        let durStr =
          if us >= 1_000_000: $(us div 1_000_000) & "s"
          elif us >= 1_000:   $(us div 1_000) & "ms"
          else:               $us & "µs"
        buf.add "  " & col(durStr, Ansi_Cyan, color) & "  " & name &
                "  " & col("(" & ep.extractFilename & ")", Ansi_Dim, color) & "\n"
  else:
    # Entrypoint-level slowest-N (fallback for opaque binaries).
    var allEps: seq[(string, int64)]  # (path, durationMs)
    for r in results:
      allEps.add (r.ep.path, r.durationMs)
    if allEps.len > 0:
      allEps.sort(proc(a, b: (string, int64)): int = cmp(b[1], a[1]))
      let topN = allEps[0 ..< min(n, allEps.len)]

      buf.add "\n"
      buf.add col("Slowest " & $topN.len & " entrypoints:\n", Ansi_Dim, color)
      for (path, ms) in topN:
        let durStr =
          if ms >= 1_000: $(ms div 1_000) & "s"
          else:           $ms & "ms"
        buf.add "  " & col(durStr, Ansi_Cyan, color) & "  " & path & "\n"

  # -------------------------------------------------------------------------
  # 3. Aggregate test-record counts (when records present)
  # -------------------------------------------------------------------------
  # Counts reflect the filtered view (displayRecords per entrypoint).
  var totalTests  = 0
  var totalPassed = 0
  var totalFailed = 0
  var totalSkipped = 0
  for r in results:
    let displayRecords =
      if hasTag: filterRecordsByTag(r.records, tag)
      else:      r.records
    let c = countRecords(displayRecords)
    totalTests   += c.total
    totalPassed  += c.passed
    totalFailed  += c.failed
    totalSkipped += c.skipped

  if totalTests > 0:
    buf.add "\n"
    let testSummary =
      "Tests: " & $totalTests & " total  " &
      $totalPassed & " passed  " &
      (if totalFailed > 0:  $totalFailed  & " failed  " else: "") &
      (if totalSkipped > 0: $totalSkipped & " skipped" else: "")
    buf.add col(testSummary, Ansi_Dim, color) & "\n"

  # -------------------------------------------------------------------------
  # 4. Summary footer — NEVER altered by filter (derived from full-run summary)
  # -------------------------------------------------------------------------
  buf.add "\n"
  let isPass = exitCode(summary) == 0

  if isPass:
    let msg = "PASSED: " & $summary.passed & "/" & $summary.total & " entrypoint(s)"
    buf.add col(msg, Ansi_Green & Ansi_Bold, color) & "\n"
  else:
    var parts: seq[string]
    if summary.failed        > 0: parts.add $summary.failed        & " failed"
    if summary.compileFailed > 0: parts.add $summary.compileFailed & " compile-failed"
    if summary.timedOut      > 0: parts.add $summary.timedOut      & " timed-out"
    if summary.signaled      > 0: parts.add $summary.signaled      & " signaled"
    if summary.spawnErrors   > 0: parts.add $summary.spawnErrors   & " spawn-error"
    let msg = "FAILED: " & parts.join(", ") & " — see above"
    buf.add col(msg, Ansi_Red & Ansi_Bold, color) & "\n"

  result = buf

# ---------------------------------------------------------------------------
# renderClosure — issue #9 slice A: human rendering of `crisol closure`
# ---------------------------------------------------------------------------

proc renderClosure*(r: ClosureReport): string =
  ## Pure: minimal human-readable rendering of a ClosureReport.  No I/O, no
  ## color (this is a diagnostic listing, not the run/plan report).
  ##
  ## One line per entry: `path [group] flagHash recorded/unrecorded (N files)`
  ## followed by the closure paths, indented, one per line.
  var buf = newStringOfCap(1024)
  for e in r.entries:
    let status = if e.recorded: "recorded" else: "unrecorded"
    buf.add e.path & "  [" & e.group & "]  " & e.flagHash & "  " &
            status & "  (" & $e.closure.len & " files)\n"
    for f in e.closure:
      buf.add "  " & f & "\n"
  result = buf
