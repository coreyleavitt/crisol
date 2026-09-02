## junit.nim — C1 JUnit XML report emitter
##
## Public API:
##
##   escapeXml*(s: string): string
##     Pure: escape all XML-special characters in s for use in both element
##     content and attribute values.  Escapes: & < > " '
##     Also strips/replaces XML-illegal control characters (U+0000–U+0008,
##     U+000B, U+000C, U+000E–U+001F, U+FFFE, U+FFFF) with the Unicode
##     replacement character U+FFFD (encoded as UTF-8 \xEF\xBF\xBD).
##     Additionally VALIDATES UTF-8: any malformed/overlong/surrogate/truncated
##     byte sequence (inputs are UNTRUSTED test-binary stdout) is replaced with
##     U+FFFD so the output is always well-formed XML 1.0 character data.
##     This is the SINGLE escape entry point for all character data in the
##     emitter — names, classnames, messages, captured output, attribute values.
##
##   toJunitXml*(results: seq[EntrypointResult]; summary: Summary): string
##     Pure: returns a schema-valid JUnit XML string.  No I/O.
##
## Outcome → XML element mapping (documented). rfc-0007 A1c: the outcome
## consulted here is deriveOutcome(r), not the stored legacy field; oTimeout/
## oSignal never come out of that derivation (superseded by oKilled/oCrashed).
##   oPassed        → no child failure/error element (testcase is clean)
##   oFailed        → <failure message="exit N"> (normal test failure)
##   oCompileFailed → <error message="compile failed"> (infrastructure)
##   oKilled        → <error message="killed: <cause>"> (infrastructure) —
##                    cause-aware when a live run-phase ProcessResult was
##                    captured (e.g. "killed: runner timeout"), else "killed"
##   oCrashed       → <error message="crashed: <symbol>"> (infrastructure) —
##                    e.g. "crashed: SIGSEGV" when captured, else the legacy
##                    "killed by signal N" text
##   oSpawnError    → <error message="spawn error"> (infrastructure)
##
## Rationale for failure vs error split:
##   <failure> = the binary ran but reported a test failure (oFailed).
##   <error>   = crisol could not even run the binary normally
##               (compile-fail/timeout/signal/spawn-error); these are
##               infrastructure problems, not test failures per se.
##   This matches the JUnit convention used by most CI tools.
##
## Structure:
##   <testsuites> (root)
##     <testsuite name=ep.path tests=N failures=N errors=N skipped=N
##                time=secs [cached="true"]>  ← cached on testsuite when protocol
##       <testcase name=record.name classname=ep.path time=secs [cached="true"]>
##         [<failure .../>] | [<skipped/>] | [<error .../>]
##       </testcase>
##       ...
##       <system-out>captured output</system-out>
##     </testsuite>
##   </testsuites>
##
## For opaque entrypoints (no records):
##   A single <testcase name=ep.path classname=ep.path time=secs [cached="true"]>
##   is synthesized, carrying <failure> or <error> per the outcome mapping.
##   cached="true" goes on the testcase (not the testsuite) for opaque entrypoints,
##   because the testcase IS the entrypoint — there is no finer granularity.
##   For protocol entrypoints, cached="true" goes on the <testsuite> (the whole
##   suite was replayed from cache), and individual testcases do NOT carry it
##   (they have no independent cache identity).
##
## time attribute:
##   testsuite time = durationMs / 1000.0 (original run duration; cached results
##   carry the historical durationMs from the stored CachedResult).
##   testcase time = durationUs / 1_000_000.0 for protocol records;
##                 = durationMs / 1000.0 for the opaque synthetic testcase.
##   No special treatment needed for cached results: durationMs already holds the
##   original run duration (synthesized by A6 from CachedResult.durationMs).
##
## Control character handling:
##   XML 1.0 forbids U+0000–U+0008, U+000B, U+000C, U+000E–U+001F, U+FFFE, U+FFFF.
##   Tab (U+0009), LF (U+000A), CR (U+000D) are legal and are NOT replaced.
##   Illegal bytes are replaced with the UTF-8 encoding of U+FFFD (replacement char).
##   This is a ONE-WAY transform (lossless round-trip is not the goal; XML validity is).

import std/[options, strutils]
import crisol/types
# rfc-0007 A1c: cause-aware <error> text for oKilled/oCrashed. `import nil`
# so nothing unqualified leaks in.
from crisol/process/types as ptypes import nil

# ---------------------------------------------------------------------------
# Single XML escape proc (the ONLY path for all character data)
# ---------------------------------------------------------------------------

const XmlReplacementChar = "\xEF\xBF\xBD"  ## UTF-8 U+FFFD REPLACEMENT CHARACTER

proc escapeXml*(s: string): string =
  ## Escape all XML-special characters for use in element content and
  ## attribute values.  This is the SINGLE escape entry point used by
  ## every toJunitXml output path.
  ##
  ## Replacements:
  ##   &  → &amp;
  ##   <  → &lt;
  ##   >  → &gt;
  ##   "  → &quot;
  ##   '  → &apos;
  ##
  ## XML-illegal control chars (per XML 1.0 §2.2):
  ##   U+0000–U+0008, U+000B, U+000C, U+000E–U+001F  → U+FFFD
  ##   U+FFFE, U+FFFF → U+FFFD.
  ##
  ## Legal whitespace chars (tab U+0009, LF U+000A, CR U+000D) pass through.
  ##
  ## UTF-8 validation (inputs are UNTRUSTED test-binary stdout):
  ##   The byte stream above U+007F is decoded as UTF-8 and validated against the
  ##   well-formed encoding rules (RFC 3629 / Unicode Table 3-7).  ANY malformed
  ##   sequence — overlong encoding (e.g. C0 80), a lone surrogate half
  ##   (U+D800–U+DFFF, e.g. ED A0 80), a truncated multibyte sequence (e.g. a
  ##   leading E2 82 at end of input), an out-of-range codepoint (> U+10FFFF), or
  ##   a bare continuation/invalid byte (e.g. 0xFF) — is replaced with U+FFFD and
  ##   decoding resynchronizes at the next byte.  This guarantees the output is
  ##   always well-formed XML 1.0 character data regardless of the input bytes.
  ##   Validated codepoints U+FFFE/U+FFFF (XML-illegal) are also mapped to U+FFFD.
  result = newStringOfCap(s.len + s.len div 4)
  let n = s.len
  var i = 0
  while i < n:
    let b0 = ord(s[i])
    if b0 < 0x80:
      # ASCII fast path: XML-special escapes + control-char scrub.
      case s[i]
      of '&':  result.add "&amp;"
      of '<':  result.add "&lt;"
      of '>':  result.add "&gt;"
      of '"':  result.add "&quot;"
      of '\'': result.add "&apos;"
      of '\x00'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F':
        # XML 1.0 §2.2 illegal control chars (tab/LF/CR are legal and skip here).
        result.add XmlReplacementChar
      else:
        result.add s[i]
      inc i
      continue

    # Multibyte UTF-8 lead byte.  Determine sequence length, the minimum
    # codepoint (overlong guard), and decode + validate the continuation bytes.
    var seqLen: int
    var cp: int
    var minCp: int
    if b0 in 0xC2..0xDF:
      seqLen = 2; cp = b0 and 0x1F; minCp = 0x80
    elif b0 in 0xE0..0xEF:
      seqLen = 3; cp = b0 and 0x0F; minCp = 0x800
    elif b0 in 0xF0..0xF4:
      seqLen = 4; cp = b0 and 0x07; minCp = 0x10000
    else:
      # 0x80..0xBF stray continuation, or 0xC0/0xC1 (always overlong),
      # or 0xF5..0xFF (out of range / invalid).  Replace one byte, resync.
      result.add XmlReplacementChar
      inc i
      continue

    if i + seqLen > n:
      # Truncated multibyte sequence at end of input.
      result.add XmlReplacementChar
      inc i
      continue

    var ok = true
    for k in 1 ..< seqLen:
      let bk = ord(s[i + k])
      if (bk and 0xC0) != 0x80:    # not a 0x80..0xBF continuation byte
        ok = false
        break
      cp = (cp shl 6) or (bk and 0x3F)

    if not ok:
      # A continuation byte was malformed; replace the lead and resync at i+1
      # (do NOT consume the bad byte — it may begin a valid sequence).
      result.add XmlReplacementChar
      inc i
      continue

    # Validated structure; now reject overlong, surrogates, out-of-range, and
    # the XML-illegal noncharacters U+FFFE/U+FFFF.
    if cp < minCp or                       # overlong encoding
       (cp >= 0xD800 and cp <= 0xDFFF) or  # lone surrogate half
       cp > 0x10FFFF or                    # out of Unicode range
       cp == 0xFFFE or cp == 0xFFFF:       # XML-illegal noncharacters
      result.add XmlReplacementChar
    else:
      # Well-formed, XML-legal codepoint: emit its bytes verbatim.
      for k in 0 ..< seqLen:
        result.add s[i + k]
    i += seqLen

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc fmtSecs(ms: int64): string =
  ## Format milliseconds as a decimal seconds string with 3 decimal places.
  ## e.g. 1234 ms → "1.234"
  let whole = ms div 1000
  let frac  = ms mod 1000
  $whole & "." & align($frac, 3, '0')

proc fmtSecsUs(us: int64): string =
  ## Format microseconds as a decimal seconds string with 6 decimal places.
  ## e.g. 1234567 us → "1.234567"
  let whole = us div 1_000_000
  let frac  = us mod 1_000_000
  $whole & "." & align($frac, 6, '0')

# ---------------------------------------------------------------------------
# Outcome → failure/error XML fragment
# ---------------------------------------------------------------------------

proc killedMessage(r: EntrypointResult): string =
  ## rfc-0007 A1c: cause-aware message for a runner-authored kill — "killed:
  ## runner timeout", "killed: runner interrupt (escalated)" — when the run
  ## phase captured a live ProcessResult (pkRan); "killed" alone otherwise
  ## (the documented never-fabricate corners in runner.pollSlot, or the
  ## legacy oTimeout arm predating this window).
  if r.run.kind == ptypes.pkRan: "killed: " & ptypes.causeLabel(r.run.res.cause)
  else: "killed"

proc crashedMessage(r: EntrypointResult): string =
  ## rfc-0007 A1c: cause-aware message for a signal/ntstatus the runner did
  ## not send — "crashed: SIGSEGV" via the real Exit symbol when captured;
  ## falls back to the legacy signal-number text otherwise.
  if r.run.kind == ptypes.pkRan: "crashed: " & ptypes.symbol(r.run.res.exit)
  else: "killed by signal " & $r.signal

proc outcomeChildXml(r: EntrypointResult): string =
  ## Returns the inner child element for the synthetic opaque testcase, or ""
  ## when the (derived) outcome is oPassed (clean testcase, no child needed).
  ## rfc-0007 A1c: cased over deriveOutcome(r), not the stored legacy field;
  ## oTimeout/oSignal are dead legacy arms (deriveOutcome never returns them)
  ## kept only so this case stays exhaustive until A1e-i deletes them.
  case deriveOutcome(r)
  of oPassed:
    ""
  of oFailed:
    let msg = "exit " & $r.exitCode
    "        <failure message=\"" & escapeXml(msg) & "\">" &
    escapeXml(r.output) & "</failure>\n"
  of oCompileFailed:
    "        <error message=\"compile failed\">" &
    escapeXml(r.output) & "</error>\n"
  of oSpawnError:
    "        <error message=\"spawn error\">" &
    escapeXml(r.output) & "</error>\n"
  of oTimeout, oKilled:
    "        <error message=\"" & escapeXml(killedMessage(r)) & "\">" &
    escapeXml(r.output) & "</error>\n"
  of oSignal, oCrashed:
    "        <error message=\"" & escapeXml(crashedMessage(r)) & "\">" &
    escapeXml(r.output) & "</error>\n"

proc recordChildXml(rec: TestRecord): string =
  ## Returns the inner child element for a protocol record testcase, or "".
  case rec.status
  of rsPass: ""
  of rsSkip: "        <skipped/>\n"
  of rsFail:
    let msg = if rec.msg.isSome: rec.msg.get else: "test failed"
    "        <failure message=\"" & escapeXml(msg) & "\"/>\n"

# ---------------------------------------------------------------------------
# toJunitXml — pure emitter
# ---------------------------------------------------------------------------

proc toJunitXml*(results: seq[EntrypointResult]; summary: Summary): string =
  ## Pure: serialize results and summary to a JUnit XML string.
  ## No I/O; returns the complete XML document as a string.
  ##
  ## Structure: <testsuites> → one <testsuite> per entrypoint → <testcase>s.
  ## Opaque entrypoints (no records) → one synthetic testcase per entrypoint.
  ## Protocol entrypoints (records present) → one testcase per record.
  ##
  ## cached="true" placement:
  ##   Opaque entrypoint:   on the <testcase> (it IS the entrypoint).
  ##   Protocol entrypoint: on the <testsuite> (the whole suite was cached).
  ##   Non-cached: attribute is omitted (clean additive default).

  var buf = newStringOfCap(4096)
  buf.add "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  buf.add "<testsuites>\n"

  for r in results:
    let epPath = escapeXml(r.ep.path)
    let timeSecs = fmtSecs(r.durationMs)
    let derived = deriveOutcome(r)  # rfc-0007 A1c

    if r.records.len == 0:
      # Opaque entrypoint: one synthetic testcase
      let isErr = derived in {oCompileFailed, oKilled, oCrashed, oSpawnError}
      let errors   = if isErr: 1 else: 0
      let failures = if derived == oFailed: 1 else: 0

      # testsuite: no cached attr (the testcase carries it for opaque)
      buf.add "  <testsuite name=\"" & epPath & "\""
      buf.add " tests=\"1\""
      buf.add " failures=\"" & $failures & "\""
      buf.add " errors=\"" & $errors & "\""
      buf.add " skipped=\"0\""
      buf.add " time=\"" & timeSecs & "\""
      buf.add ">\n"

      # synthetic testcase
      buf.add "    <testcase name=\"" & epPath & "\""
      buf.add " classname=\"" & epPath & "\""
      buf.add " time=\"" & timeSecs & "\""
      if r.cached:
        buf.add " cached=\"true\""
      buf.add ">\n"

      let child = outcomeChildXml(r)
      if child.len > 0:
        buf.add child

      buf.add "    </testcase>\n"

      # system-out for captured output (already escaped inside outcomeChildXml
      # for the failure/error child, but we also emit it here unconditionally so
      # parsers that read <system-out> get the raw output even on pass)
      if r.output.len > 0:
        buf.add "    <system-out>" & escapeXml(r.output) & "</system-out>\n"

      buf.add "  </testsuite>\n"

    else:
      # Protocol entrypoint: one testcase per record
      var testsCount   = r.records.len
      var failuresCount = 0
      var errorsCount   = 0
      var skippedCount  = 0
      for rec in r.records:
        case rec.status
        of rsFail: inc failuresCount
        of rsSkip: inc skippedCount
        of rsPass: discard
      # Infrastructure error at the entrypoint level (e.g. the binary exited non-zero
      # with protocol records — oFailed — is represented via failures in the records;
      # but oCompileFailed etc. with records should not occur in practice since the
      # binary never ran; we handle it defensively by adding an error count).
      if derived in {oCompileFailed, oKilled, oCrashed, oSpawnError}:
        inc errorsCount

      # testsuite: cached attr goes here for protocol entrypoints
      buf.add "  <testsuite name=\"" & epPath & "\""
      buf.add " tests=\"" & $testsCount & "\""
      buf.add " failures=\"" & $failuresCount & "\""
      buf.add " errors=\"" & $errorsCount & "\""
      buf.add " skipped=\"" & $skippedCount & "\""
      buf.add " time=\"" & timeSecs & "\""
      if r.cached:
        buf.add " cached=\"true\""
      buf.add ">\n"

      for rec in r.records:
        let recName = escapeXml(rec.name)
        let recTime = fmtSecsUs(rec.durationUs)
        buf.add "    <testcase name=\"" & recName & "\""
        buf.add " classname=\"" & epPath & "\""
        buf.add " time=\"" & recTime & "\""
        buf.add ">\n"

        let child = recordChildXml(rec)
        if child.len > 0:
          buf.add child

        buf.add "    </testcase>\n"

      if r.output.len > 0:
        buf.add "    <system-out>" & escapeXml(r.output) & "</system-out>\n"

      buf.add "  </testsuite>\n"

  buf.add "</testsuites>\n"
  result = buf
