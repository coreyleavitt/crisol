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
import crisol/ioutils  # sanitizeControlBytes — issue #14: report-body field sanitization
# rfc-0007 A1c: cause-aware detail for killed/crashed lines. `import nil` so
# nothing unqualified leaks in.
from crisol/process/types as ptypes import nil

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
    explainMiss*:        bool  ## RFC-0005 B1c: --explain-miss -- render the per-entrypoint
                                ## miss-explanation block for a genuine cache-miss decision.
    explainMissVerbose*: bool  ## RFC-0005 B1c: --explain-miss-verbose -- full raw component
                                ## values instead of the terse truncated form. The CLI ensures
                                ## this implies explainMiss=true; render() itself only ever
                                ## consults explainMiss to decide WHETHER to render.

proc defaultOpts*(): RenderOpts =
  RenderOpts(color: false, slowestN: 5, filterTag: none(string),
             explainMiss: false, explainMissVerbose: false)

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
  of oKilled:         "[KILLED] "
  of oCrashed:         "[CRASH]  "
  of oSpawnError:     "[SPAWN]  "

proc outcomeColor(o: Outcome): string =
  case o
  of oPassed:        Ansi_Green
  of oFailed:        Ansi_Red
  of oCompileFailed: Ansi_Yellow
  of oKilled:  Ansi_Yellow
  of oCrashed: Ansi_Red
  of oSpawnError:     Ansi_Red

proc causeDetail(r: EntrypointResult): string =
  ## rfc-0007 §2: cause-aware one-line detail for a killed/crashed run, when
  ## the run phase actually captured a live ProcessResult (pkRan — the common
  ## path). "" when no observation exists yet: pkSkipped/pkSpawnFailed (the
  ## documented never-fabricate corners in runner.pollSlot) or pkCached (a
  ## cache-hit synthesis — never reaches here in practice, since only passes
  ## are ever cached).
  if r.run.kind == ptypes.pkRan:
    ptypes.causeLabel(r.run.res.cause)
  else:
    ""

proc exitCodeDetail(r: EntrypointResult): int =
  ## Derived (A1e-i): the display-grade exit code for an oFailed result.
  ## oFailed is only ever derived when the run phase exited normally
  ## (exit.kind == ekExited) AND the phase captured a live observation
  ## (pkRan — a cache hit never replays a fail, only a pass) — same
  ## never-fabricate posture as causeDetail above.
  if r.run.kind == ptypes.pkRan and r.run.res.exit.kind == ptypes.ekExited:
    r.run.res.exit.code
  else:
    0

proc signalDetail(r: EntrypointResult): string =
  ## Derived (A1e-i): the display-grade signal label for an oCrashed result.
  ## "" (falls back to "signal") for the documented never-fabricate corners.
  if r.run.kind == ptypes.pkRan and r.run.res.exit.kind == ptypes.ekSignaled:
    "SIG#" & $r.run.res.exit.sig
  else:
    ""

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
# RFC-0005 B1c: miss-explanation rendering (--explain-miss[-verbose])
#
# Component-aware, per RFC-0005 §Miss-explanation (line 377, corrected):
#   kcNimVersion — value is "<multi-line `nim --version` text>|<16-hex binary
#     content hash>" (nimprobe.nimFingerprint). Terse: first line of the
#     text + first-8-hex of the hash on each side; when only the hash
#     differs (text identical), "compiler binary differs" instead.
#   kcCcVersion — value is "<cc --version first line>|<ldd --version first
#     line>" (ccprobe.ccVersion) — NOT a multi-line+hash shape like
#     kcNimVersion, despite RFC-0005's now-corrected line 377. Split on the
#     pipe; name cc/ldd independently, no truncation (already single lines).
#   kcHermeticEnv — lists envNames (never values).
#   kcLimits — per-LimitKind diff over the "<kind>=<v>|..." fold string.
#   kcArgv — already a plain joined argv string; shown in full.
#   kcClosure/kcFlags/kcFixtures/kcProtocol — opaque: "changed (<a> → <b>)",
#     truncated to 8 chars terse, full under --explain-miss-verbose.
#
# All pure — no I/O — so vector-testable without running anything. A
# returned line MAY itself contain embedded '\n' (verbose nimVersion raw
# text); callers split on lines again before applying their own indent.
# ---------------------------------------------------------------------------

proc hash8*(h: string): string =
  ## First 8 characters of an opaque hash string, or the whole string when
  ## shorter — the terse-mode truncation shared by every opaque component.
  if h.len > 8: h[0 ..< 8] else: h

proc firstLine*(s: string): string =
  ## First non-empty line of a (possibly multi-line) string; "" if none.
  for line in s.splitLines():
    if line.len > 0: return line
  ""

proc splitLastPipe(s: string): tuple[left, right: string, ok: bool] =
  ## Split on the LAST '|'. kcNimVersion's left segment is multi-line
  ## `nim --version` text that could in principle itself contain a '|'; the
  ## trailing binary-hash segment never does. `ok=false` (no '|' at all —
  ## a malformed/foreign value) lets the caller fall back to the generic
  ## opaque render instead of misparsing.
  let idx = s.rfind('|')
  if idx < 0: return ("", "", false)
  (s[0 ..< idx], s[idx+1 .. ^1], true)

proc splitFirstPipe(s: string): tuple[left, right: string, ok: bool] =
  ## Split on the FIRST '|'. kcCcVersion is exactly two already-single-line
  ## segments (`ccprobe.ccVersion`: "<cc first line>|<ldd first line>").
  let idx = s.find('|')
  if idx < 0: return ("", "", false)
  (s[0 ..< idx], s[idx+1 .. ^1], true)

proc renderOpaqueChanged(label: string; prev, curr: string; verbose: bool): string =
  ## Generic opaque-hash render, shared by every component with no
  ## dedicated renderer AND as the malformed-value fallback for
  ## kcNimVersion/kcCcVersion.
  if verbose:
    label & ": changed (" & prev & " → " & curr & ")"
  else:
    label & ": changed (" & hash8(prev) & "… → " & hash8(curr) & "…)"

proc renderNimVersionLine(d: KeyDiff; verbose: bool): string =
  let (prevText, prevHash, prevOk) = splitLastPipe(d.prev)
  let (currText, currHash, currOk) = splitLastPipe(d.curr)
  if not prevOk or not currOk:
    return renderOpaqueChanged("kcNimVersion", d.prev, d.curr, verbose)
  if verbose:
    return "kcNimVersion prev:\n" & prevText & "\n  hash: " & prevHash &
           "\nkcNimVersion curr:\n" & currText & "\n  hash: " & currHash
  let prevLine = firstLine(prevText)
  let currLine = firstLine(currText)
  if prevLine == currLine:
    "kcNimVersion: compiler binary differs (" & hash8(prevHash) & "… → " & hash8(currHash) & "…)"
  else:
    "kcNimVersion: " & prevLine & " (" & hash8(prevHash) & "…) → " &
                        currLine & " (" & hash8(currHash) & "…)"

proc renderCcVersionLines(d: KeyDiff; verbose: bool): seq[string] =
  ## No verbose/terse distinction on the NORMAL path: cc/ldd segments are
  ## already single lines (coordinator ruling) — always shown in full,
  ## never truncated. `verbose` is only consulted on the malformed-value
  ## fallback, mirroring kcNimVersion's fallback.
  let (prevCc, prevLdd, prevOk) = splitFirstPipe(d.prev)
  let (currCc, currLdd, currOk) = splitFirstPipe(d.curr)
  if not prevOk or not currOk:
    return @[renderOpaqueChanged("kcCcVersion", d.prev, d.curr, verbose)]
  result = @[]
  if prevCc != currCc:
    result.add "kcCcVersion: cc: " & prevCc & " → " & currCc
  if prevLdd != currLdd:
    result.add "kcCcVersion: ldd: " & prevLdd & " → " & currLdd
  if result.len == 0:
    # Defensive: the component is only ever emitted (keys.explainMiss) when
    # the combined value differs, so a diff with both segments equal should
    # not occur — fall back rather than render nothing.
    result.add renderOpaqueChanged("kcCcVersion", d.prev, d.curr, verbose)

proc renderHermeticEnvLine(d: KeyDiff; verbose: bool): string =
  let names = if d.envNames.len > 0: d.envNames.join(", ")
              else: "(unable to identify which variable)"
  if verbose:
    "kcHermeticEnv: " & names & " (hash " & d.prev & " → " & d.curr & ")"
  else:
    "kcHermeticEnv: " & names

proc parseLimitsFold(s: string): seq[(string, string)] =
  ## Parse keys.limitsFoldString's "<kind>=<v>|..." shape back into
  ## (kind, value) pairs, in fold order.
  for part in s.split('|'):
    let eq = part.find('=')
    if eq >= 0:
      result.add (part[0 ..< eq], part[eq+1 .. ^1])

proc findLimitVal(parts: seq[(string, string)]; kind: string): string =
  for (k, v) in parts:
    if k == kind: return v
  "-"

proc renderLimitsLines(d: KeyDiff; verbose: bool): seq[string] =
  ## Per-LimitKind diff: only the kinds whose value actually changed, one
  ## line each — not the whole fold string (RFC-0005 line 377).
  let prevParts = parseLimitsFold(d.prev)
  let currParts = parseLimitsFold(d.curr)
  result = @[]
  for (k, pv) in prevParts:
    let cv = findLimitVal(currParts, k)
    if pv != cv:
      result.add "kcLimits: " & k & ": " & pv & " → " & cv
  if result.len == 0:
    result.add renderOpaqueChanged("kcLimits", d.prev, d.curr, verbose)

proc renderKeyDiffLines*(d: KeyDiff; verbose: bool): seq[string] =
  ## PURE, component-aware. One or more logical lines per KeyDiff; a line
  ## MAY itself contain embedded '\n' (verbose kcNimVersion raw text) —
  ## callers split on lines again before indenting.
  case d.component
  of kcNimVersion: @[renderNimVersionLine(d, verbose)]
  of kcCcVersion:  renderCcVersionLines(d, verbose)
  of kcHermeticEnv: @[renderHermeticEnvLine(d, verbose)]
  of kcLimits:     renderLimitsLines(d, verbose)
  of kcArgv:       @["kcArgv: " & d.prev & " → " & d.curr]
  of kcClosure, kcFlags, kcFixtures, kcProtocol:
    @[renderOpaqueChanged($d.component, d.prev, d.curr, verbose)]

proc explainMissLines*(diffs: seq[KeyDiff]; verbose: bool): seq[string] =
  ## PURE: format the whole miss-explanation block for one entrypoint.
  ## Degrades to a single "no prior inputs recorded" line when `diffs` is
  ## empty — B1b's documented degradation (no sidecar / no matching
  ## flagHash record), NOT a claim that nothing differs.
  if diffs.len == 0:
    return @["no prior inputs recorded"]
  result = @[]
  for d in diffs:
    result.add renderKeyDiffLines(d, verbose)

proc isCacheMissDecision*(cd: CacheDecision): bool =
  ## PURE: true iff `cd` is a genuine "ran live because the cache was
  ## consulted and did not serve a hit" decision — the set explain-miss
  ## rendering applies to. Excludes cdmHit (nothing to explain) and every
  ## "cache not even consulted" variant (cdmNotEligible/cdmGroupOptOut/
  ## cdmPolicyDisabled) — explaining "why did this miss" is meaningless
  ## when the cache was never asked.
  cd in {cdmStored, cdmKeyMiss, cdmHermeticityDeg, cdmFlaky,
         cdmClosureUnrecorded, cdmRecomputeMiss}

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
             opts: RenderOpts;
             policy: ptypes.OutcomePolicy = ptypes.DefaultPolicy): string =
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
  ##
  ## rfc-0007 A6b: `policy` is a REPORTING trust boundary (RFC-0007 §2) — the
  ## caller (crisol.nim) threads the SAME resolved OutcomePolicy used to
  ## build `summary`, so a per-entrypoint [OK]/[FAIL] label here never
  ## disagrees with the aggregate counts / exit code. Defaults to
  ## DefaultPolicy so every existing caller is unchanged.

  let color  = opts.color
  let n      = if opts.slowestN > 0: opts.slowestN else: 5
  let tag    = if opts.filterTag.isSome: opts.filterTag.get else: ""
  let hasTag = tag.len > 0

  var buf = newStringOfCap(4096)

  # -------------------------------------------------------------------------
  # 1. Per-entrypoint lines
  # -------------------------------------------------------------------------
  for r in results:
    let derived   = outcome(r, policy)  # rfc-0007 §2/A6b: display driven by the pure derivation
    let label     = outcomeLabel(derived)
    let labelCol  = col(label, outcomeColor(derived), color)
    # Issue #14: entrypoint paths (config/disk-origin) and protocol record
    # names/messages (test-binary-origin) are one-line identifiers headed for
    # a terminal or CI log — sanitize each at the render layer (the stdout
    # sink must pass crisol's own ANSI color codes through).  The raw
    # captured `output` tail is deliberately NOT sanitized: it is the
    # binary's own output and may legitimately be colored.
    let epPath    = sanitizeControlBytes(r.ep.path)

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
        case derived
        of oPassed:        " (" & $(r.durationMs div 1000) & "s)"
        of oCompileFailed: " (compile failed)"
        of oFailed:        " (exit " & $exitCodeDetail(r) & ")"
        of oSpawnError:    " (spawn error)"
        of oKilled:
          " (killed)"
        of oCrashed:
          let sig = signalDetail(r)
          let sigName = if sig.len > 0: sig else: "signal"
          " (" & sigName & ")"

    # A8: mark results served from the ExecutionCache.  The [CACHED] tag sits
    # after the outcome label so a cached pass reads "[OK] … [CACHED]".  Cached
    # results report their HISTORICAL duration (carried on the synthesized
    # EntrypointResult), not the current invocation time.
    let cachedTag =
      if cached(r): "  " & col("[CACHED]", Ansi_Cyan, color)
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
    # rfc-0007 A6a (§6): a first-class warning when the run observed a
    # same-pgroup survivor — leaked side effects already happened, and the
    # result was refused by the cache gate for exactly this reason
    # (evidenceSatisfies). Appears after [SLOW]; yellow matches the other
    # "degraded but not fatal" tags — the verdict itself is never changed
    # by hygiene (crisol does not judge test semantics, §6).
    let escapeeTag =
      if hasEscapees(r): "  " & col("[ESCAPEE]", Ansi_Yellow, color)
      else: ""
    buf.add "  " & labelCol & "  " & epPath & countsSuffix & cachedTag & quarantinedTag & slowTag & escapeeTag & "\n"

    # -----------------------------------------------------------------------
    # Failure / compile-fail / signal detail block
    # -----------------------------------------------------------------------
    case derived
    of oFailed:
      # Show per-test failure messages first (from displayRecords).
      var failedRecords: seq[TestRecord]
      for rec in displayRecords:
        if rec.status == rsFail:
          failedRecords.add rec
      if failedRecords.len > 0:
        for rec in failedRecords:
          let indent = "           "
          buf.add indent & col("FAIL", Ansi_Red, color) & ": " &
                  sanitizeControlBytes(rec.name) & "\n"
          if rec.msg.isSome:
            # Indent multi-line messages
            for line in sanitizeControlBytes(rec.msg.get).splitLines:
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

    of oKilled:
      # rfc-0007 §2: cause-aware detail when a run-phase ProcessResult was
      # captured (the common live path); "" for the exempted never-fabricate
      # corners (causeDetail's fallback).
      let cause = causeDetail(r)
      if cause.len > 0:
        buf.add "           " & col("cause: " & cause, Ansi_Dim, color) & "\n"

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
          buf.add "           " & col("SKIP", Ansi_Dim, color) & ": " &
                  sanitizeControlBytes(rec.name) & " — " &
                  sanitizeControlBytes(reason) & "\n"

    of oSpawnError:
      if r.output.len > 0:
        buf.add "           " & r.output & "\n"

    of oCrashed:
      if r.output.len > 0:
        let maxDisplay = 1000
        let outText = if r.output.len > maxDisplay:
                        r.output[0..<maxDisplay] & "\n[...truncated...]"
                      else: r.output
        for line in outText.splitLines:
          if line.len > 0:
            buf.add "           " & line & "\n"
      # rfc-0007 §2: cause-aware detail, same pattern as oKilled above.
      let cause = causeDetail(r)
      if cause.len > 0:
        buf.add "           " & col("cause: " & cause, Ansi_Dim, color) & "\n"

    # -----------------------------------------------------------------------
    # RFC-0005 B1c: miss-explanation detail (--explain-miss[-verbose])
    # -----------------------------------------------------------------------
    if opts.explainMiss and isCacheMissDecision(r.cacheDecision):
      for blk in explainMissLines(r.keyDiff, opts.explainMissVerbose):
        for physLine in blk.splitLines():
          buf.add "           " & col("explain: ", Ansi_Dim, color) & physLine & "\n"

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
        allTests.add (sanitizeControlBytes(rec.name), rec.durationUs,
                      sanitizeControlBytes(r.ep.path))

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
      allEps.add (sanitizeControlBytes(r.ep.path), r.durationMs)
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
    if summary.failed             > 0: parts.add $summary.failed             & " failed"
    if summary.compileFailed      > 0: parts.add $summary.compileFailed      & " compile-failed"
    if summary.counts[oKilled]  > 0: parts.add $summary.counts[oKilled]  & " killed"
    if summary.counts[oCrashed] > 0: parts.add $summary.counts[oCrashed] & " crashed"
    if summary.spawnErrors        > 0: parts.add $summary.spawnErrors        & " spawn-error"
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
    # Issue #14: path/group (config-origin) and closure paths (depgraph-origin,
    # on-disk state) are sanitized at the render layer.
    buf.add sanitizeControlBytes(e.path) & "  [" & sanitizeControlBytes(e.group) &
            "]  " & e.flagHash & "  " & status & "  (" & $e.closure.len & " files)\n"
    for f in e.closure:
      buf.add "  " & sanitizeControlBytes(f) & "\n"
  result = buf
