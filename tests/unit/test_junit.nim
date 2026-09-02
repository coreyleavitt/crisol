## test_junit.nim — unit tests for crisol/junit (C1 slice)
##
## Covers:
##   1. escapeXml: ~20 adversarial table-driven inputs
##   2. toJunitXml: opaque passing, opaque failing, opaque infrastructure errors,
##      protocol records (pass+fail+skip), cached entrypoints, empty results
##   3. Well-formedness round-trip: parseXml must not error on hostile content
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_junit.nim

import std/[options, streams, strutils, unittest, xmlparser, xmltree]
import crisol/types
import crisol/junit
import crisol/process/types as ptypes  # rfc-0007 A1c: coherent Phase fixtures

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc makeEp(path: string; group: string = "unit"): Entrypoint =
  Entrypoint(path: path, group: group, flags: @[])

proc makeRecord(name: string; status: RecordStatus;
                msg: string = "";
                durationUs: int64 = 10_000): TestRecord =
  TestRecord(
    name:       name,
    status:     status,
    durationUs: durationUs,
    msg:        if msg.len > 0: some(msg) else: none(string),
    tags:       @[],
  )

proc ranPhase(cause: ptypes.Cause; exit: ptypes.Exit): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: cause, evidence: default(ptypes.Evidence),
    rusage: none(ptypes.Rusage), durationUs: 0))

const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)
const cbProcess = ptypes.Cause(by: ptypes.cbProcess)

proc stampPhase(r: var EntrypointResult; outcome: Outcome; exitCode, signal: int) =
  ## rfc-0007 §2: junit displays outcome(r), not a stored field — stamp a
  ## coherent `compile`/`run: Phase` pair that derives the outcome each
  ## fixture names, mirroring runner.execute's real captured shape.
  case outcome
  of oPassed, oFailed:
    r.compile = skippedPhase
    r.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: exitCode))
  of oCompileFailed:
    # A "compile failed" fixture's exitCode param (when given) describes the
    # RUN phase in other branches; here it may be left at its 0 default (the
    # legacy field, not the compile's own code), which would derive as a
    # SUCCESSFUL compile. Force a nonzero compile exit so outcome(r) agrees.
    let code = if exitCode != 0: exitCode else: 1
    r.compile = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: code))
    r.run = skippedPhase
  of oKilled:
    r.compile = skippedPhase
    r.run = ranPhase(
      ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false),
      ptypes.Exit(kind: ptypes.ekSignaled, sig: signal, coreDumped: false))
  of oCrashed:
    r.compile = skippedPhase
    r.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekSignaled, sig: signal, coreDumped: false))
  of oSpawnError:
    r.compile = skippedPhase
    r.run = ptypes.Phase(kind: ptypes.pkSpawnFailed, spawnError: "spawn error")

proc opaqueResult(path: string; outcome: Outcome;
                  exitCode: int = 0; signal: int = 0;
                  durationMs: int64 = 100;
                  output: string = "";
                  cached: bool = false): EntrypointResult =
  result = EntrypointResult(
    ep:         makeEp(path),
    durationMs: durationMs,
    output:     output,
    records:    @[])
  stampPhase(result, outcome, exitCode, signal)
  # rfc-0007 A1e-i: cached(r) derives from run.kind == pkCached -- the `cached`
  # param used to set a legacy stored field; now it re-kinds the SAME
  # ProcessResult stampPhase just built (a cache hit replays the real
  # observation verbatim, never a fabricated one -- pass-only store, §2).
  if cached:
    result.run = ptypes.Phase(kind: ptypes.pkCached, res: result.run.res)

proc recordResult(path: string; records: seq[TestRecord];
                  outcome: Outcome = oPassed;
                  durationMs: int64 = 200;
                  output: string = "";
                  cached: bool = false): EntrypointResult =
  let exitCode = if outcome == oPassed: 0 else: 1
  result = EntrypointResult(
    ep:         makeEp(path),
    durationMs: durationMs,
    output:     output,
    records:    records)
  stampPhase(result, outcome, exitCode, 0)
  if cached:
    result.run = ptypes.Phase(kind: ptypes.pkCached, res: result.run.res)

proc parseDoc(xml: string): XmlNode =
  ## Parse xml via a StringStream so we get the errors parameter.
  ## Raises ValueError if there are parse errors.
  var errors: seq[string] = @[]
  let ss   = newStringStream(xml)
  let node = parseXml(ss, "doc", errors)
  if errors.len > 0:
    raise newException(ValueError, "XML parse errors: " & errors.join("; "))
  node

# ---------------------------------------------------------------------------
# Suite 1 — escapeXml adversarial table
# ---------------------------------------------------------------------------

suite "junit - escapeXml adversarial table":

  test "empty string → empty string":
    check escapeXml("") == ""

  test "plain text with no specials passes through unchanged":
    check escapeXml("hello world 123") == "hello world 123"

  test "ampersand → &amp;":
    check escapeXml("&") == "&amp;"

  test "less-than → &lt;":
    check escapeXml("<") == "&lt;"

  test "greater-than → &gt;":
    check escapeXml(">") == "&gt;"

  test "double-quote → &quot;":
    check escapeXml("\"") == "&quot;"

  test "single-quote → &apos;":
    check escapeXml("'") == "&apos;"

  test "all five specials in one string":
    check escapeXml("&<>\"'") == "&amp;&lt;&gt;&quot;&apos;"

  test "runs of ampersands: &&& → &amp;&amp;&amp;":
    check escapeXml("&&&") == "&amp;&amp;&amp;"

  test "already-escaped literal &amp; input → &amp;amp; (no double-escape)":
    ## Input is the 5-char string literal &amp; — the & must become &amp;
    ## giving &amp;amp; as output.  This is the double-escape correctness check.
    check escapeXml("&amp;") == "&amp;amp;"

  test "angle brackets forming fake tag <script>alert(1)</script>":
    let inp = "<script>alert(1)</script>"
    let esc = escapeXml(inp)
    check esc == "&lt;script&gt;alert(1)&lt;/script&gt;"
    check not esc.contains("<")
    check not esc.contains(">")

  test "quotes inside an attribute-like context":
    check escapeXml("name=\"value\" and 'other'") ==
          "name=&quot;value&quot; and &apos;other&apos;"

  test "combined adversarial string: Tom & Jerry < The & 'Cat'":
    check escapeXml("Tom & Jerry < The & 'Cat'") ==
          "Tom &amp; Jerry &lt; The &amp; &apos;Cat&apos;"

  test "unicode passthrough (no ASCII specials)":
    ## Non-ASCII UTF-8 bytes that aren't specials pass through unchanged.
    let s = "café ñoño 日本語"
    check escapeXml(s) == s

  test "tab, LF, CR are legal XML whitespace and pass through":
    check escapeXml("\t\n\r") == "\t\n\r"

  test "null byte U+0000 is replaced with U+FFFD":
    let s = "a\x00b"
    let esc = escapeXml(s)
    check not esc.contains("\x00")
    check esc.contains("\xEF\xBF\xBD")  # U+FFFD UTF-8

  test "control chars U+0001–U+0008 are replaced with U+FFFD":
    for b in 1..8:
      let s = "x" & $chr(b) & "y"
      let esc = escapeXml(s)
      check not esc.contains(chr(b))
      check esc.contains("\xEF\xBF\xBD")

  test "vertical tab U+000B replaced with U+FFFD":
    let esc = escapeXml("\x0B")
    check not esc.contains("\x0B")
    check esc.contains("\xEF\xBF\xBD")

  test "form feed U+000C replaced with U+FFFD":
    let esc = escapeXml("\x0C")
    check not esc.contains("\x0C")
    check esc.contains("\xEF\xBF\xBD")

  test "control chars U+000E–U+001F replaced with U+FFFD":
    for b in 14..31:
      let s = "x" & $chr(b) & "y"
      let esc = escapeXml(s)
      check not esc.contains(chr(b))
      check esc.contains("\xEF\xBF\xBD")

  test "UTF-8 encoding of U+FFFE (EF BF BE) replaced with U+FFFD":
    let s = "a\xEF\xBF\xBEb"
    let esc = escapeXml(s)
    # Should not contain the original 3-byte sequence EF BF BE
    check not esc.contains("\xEF\xBF\xBE")
    check esc.contains("\xEF\xBF\xBD")

  test "UTF-8 encoding of U+FFFF (EF BF BF) replaced with U+FFFD":
    let s = "a\xEF\xBF\xBFb"
    let esc = escapeXml(s)
    check not esc.contains("\xEF\xBF\xBF")
    check esc.contains("\xEF\xBF\xBD")

  test "benign EF byte that is NOT FFFE/FFFF passes through":
    ## EF B8 80 is a valid UTF-8 sequence (U+FE00, VARIATION SELECTOR-1)
    ## It must NOT be replaced since it's not FFFE or FFFF.
    let s = "\xEF\xB8\x80"
    check escapeXml(s) == s

# ---------------------------------------------------------------------------
# Suite 1b — escapeXml hostile/malformed UTF-8 (L9)
# ---------------------------------------------------------------------------
#
# Test-binary stdout is UNTRUSTED.  escapeXml must validate UTF-8 and emit
# U+FFFD for any malformed/overlong/surrogate/truncated sequence so the result
# is always well-formed XML 1.0 char data.  Each case wraps the escaped output
# in a trivial element and round-trips it through parseXml to prove validity.

suite "junit - escapeXml hostile UTF-8 (L9)":

  proc roundTrips(escaped: string): bool =
    ## True iff <r>escaped</r> parses without error.
    var errors: seq[string] = @[]
    let ss = newStringStream("<r>" & escaped & "</r>")
    discard parseXml(ss, "doc", errors)
    errors.len == 0

  const Repl = "\xEF\xBF\xBD"  # U+FFFD UTF-8

  test "overlong 2-byte NUL (C0 80) → U+FFFD, well-formed":
    let esc = escapeXml("a\xC0\x80b")
    check not esc.contains("\xC0")
    check not esc.contains("\x80")
    check esc.contains(Repl)
    check esc == "a" & Repl & Repl & "b"  # C0 and 80 each become a replacement
    check roundTrips(esc)

  test "overlong 3-byte slash (E0 80 AF) → U+FFFD, well-formed":
    ## E0 80 AF is an overlong encoding of '/'.  The whole sequence is rejected.
    let esc = escapeXml("\xE0\x80\xAF")
    check esc.contains(Repl)
    check roundTrips(esc)

  test "lone high surrogate (ED A0 80 = U+D800) → U+FFFD, well-formed":
    let esc = escapeXml("x\xED\xA0\x80y")
    check not esc.contains("\xED\xA0\x80")
    check esc.contains(Repl)
    check roundTrips(esc)

  test "lone low surrogate (ED B0 80 = U+DC00) → U+FFFD, well-formed":
    let esc = escapeXml("\xED\xB0\x80")
    check esc.contains(Repl)
    check roundTrips(esc)

  test "truncated 3-byte sequence at EOF (E2 82) → U+FFFD, well-formed":
    let esc = escapeXml("price: \xE2\x82")
    check esc.startsWith("price: ")
    check esc.contains(Repl)
    check roundTrips(esc)

  test "truncated multibyte mid-string (E2 82 followed by ASCII) → U+FFFD":
    ## E2 expects two continuations; the following 'X' is not a continuation,
    ## so the lead is replaced and decoding resyncs at 'X' (preserved).
    let esc = escapeXml("\xE2\x82X")
    check esc.contains(Repl)
    check esc.endsWith("X")
    check roundTrips(esc)

  test "bare 0xFF (invalid lead) → U+FFFD, well-formed":
    let esc = escapeXml("\xFF")
    check not esc.contains("\xFF")
    check esc == Repl
    check roundTrips(esc)

  test "stray continuation byte 0x80 → U+FFFD, well-formed":
    let esc = escapeXml("\x80")
    check esc == Repl
    check roundTrips(esc)

  test "0xF5 lead (codepoint > U+10FFFF range) → U+FFFD, well-formed":
    let esc = escapeXml("\xF5\x80\x80\x80")
    check esc.contains(Repl)
    check roundTrips(esc)

  test "valid 4-byte emoji (F0 9F 98 80 = U+1F600) passes through unchanged":
    ## A well-formed astral-plane codepoint must NOT be mangled.
    let s = "\xF0\x9F\x98\x80"
    let esc = escapeXml(s)
    check esc == s
    check roundTrips(esc)

  test "malformed bytes interleaved with specials still escape specials":
    ## A '<' adjacent to garbage bytes must still become &lt; and the result
    ## must be well-formed.
    let esc = escapeXml("\xFF<\xC0\x80>")
    check esc.contains("&lt;")
    check esc.contains("&gt;")
    check not esc.contains("<")
    check not esc.contains(">")
    check roundTrips(esc)

# ---------------------------------------------------------------------------
# Suite 2 — toJunitXml structural + content correctness
# ---------------------------------------------------------------------------

suite "junit - toJunitXml opaque passing entrypoint":

  test "root element is testsuites":
    let r = opaqueResult("tests/unit/test_pass.nim", oPassed)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"

  test "one testsuite child per entrypoint":
    let r1 = opaqueResult("tests/unit/test_a.nim", oPassed)
    let r2 = opaqueResult("tests/unit/test_b.nim", oPassed)
    let xml = toJunitXml(@[r1, r2], Summary(total: 2, passed: 2))
    let doc = parseDoc(xml)
    var suiteCount = 0
    for child in doc:
      if child.kind == xnElement and child.tag == "testsuite":
        inc suiteCount
    check suiteCount == 2

  test "opaque passing: testsuite attributes (tests=1 failures=0 errors=0 skipped=0)":
    let r = opaqueResult("tests/unit/test_pass.nim", oPassed, durationMs = 123)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    let suite = doc[0]
    check suite.attr("tests")    == "1"
    check suite.attr("failures") == "0"
    check suite.attr("errors")   == "0"
    check suite.attr("skipped")  == "0"
    check suite.attr("time")     == "0.123"
    check suite.attr("name")     == "tests/unit/test_pass.nim"

  test "opaque passing: one testcase child with no failure/error child":
    let r = opaqueResult("tests/unit/test_pass.nim", oPassed)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    let suite = doc[0]
    var tcCount = 0
    var hasChild = false
    for child in suite:
      if child.kind == xnElement and child.tag == "testcase":
        inc tcCount
        for inner in child:
          if inner.kind == xnElement and inner.tag in ["failure", "error", "skipped"]:
            hasChild = true
    check tcCount == 1
    check hasChild == false

  test "opaque passing testcase: name classname time attributes":
    let r = opaqueResult("tests/unit/test_pass.nim", oPassed, durationMs = 456)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    let suite  = doc[0]
    var tc: XmlNode
    for child in suite:
      if child.kind == xnElement and child.tag == "testcase":
        tc = child
        break
    check tc.attr("name")      == "tests/unit/test_pass.nim"
    check tc.attr("classname") == "tests/unit/test_pass.nim"
    check tc.attr("time")      == "0.456"

suite "junit - toJunitXml opaque failing/infrastructure":

  test "oFailed: testsuite failures=1 errors=0":
    let r = opaqueResult("tests/unit/test_fail.nim", oFailed, exitCode = 1)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    check doc[0].attr("failures") == "1"
    check doc[0].attr("errors")   == "0"

  test "oFailed: testcase has <failure> child":
    let r = opaqueResult("tests/unit/test_fail.nim", oFailed, exitCode = 2)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    let suite = doc[0]
    var hasFailure = false
    for child in suite:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "failure":
            hasFailure = true
            check inner.attr("message") == "exit 2"
    check hasFailure

  test "oCompileFailed: testsuite errors=1 failures=0":
    let r = opaqueResult("tests/unit/test_ce.nim", oCompileFailed)
    let xml = toJunitXml(@[r], Summary(total: 1, compileFailed: 1))
    let doc = parseDoc(xml)
    check doc[0].attr("errors")   == "1"
    check doc[0].attr("failures") == "0"

  test "oCompileFailed: testcase has <error> child with correct message":
    let r = opaqueResult("tests/unit/test_ce.nim", oCompileFailed)
    let xml = toJunitXml(@[r], Summary(total: 1, compileFailed: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "error":
            found = true
            check inner.attr("message") == "compile failed"
    check found

  test "rfc-0007 A1c: oKilled (timeout) testcase has cause-aware <error message>":
    let r = opaqueResult("tests/integration/test_hang.nim", oKilled)
    let xml = toJunitXml(@[r], Summary(total: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "error":
            found = true
            check inner.attr("message") == "killed: runner timeout"
    check found

  test "rfc-0007 A1c: oCrashed (signal) testcase has cause-aware <error message>":
    let r = opaqueResult("tests/unit/test_segv.nim", oCrashed, signal = 11)
    let xml = toJunitXml(@[r], Summary(total: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "error":
            found = true
            check inner.attr("message") == "crashed: SIGSEGV"
    check found

  test "oSpawnError: testcase has <error message='spawn error'>":
    let r = opaqueResult("tests/unit/test_spawn.nim", oSpawnError)
    let xml = toJunitXml(@[r], Summary(total: 1, spawnErrors: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "error":
            found = true
            check inner.attr("message") == "spawn error"
    check found

  test "captured output in <system-out> for opaque entrypoint":
    let r = opaqueResult("tests/unit/test_out.nim", oPassed, output = "hello output")
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "system-out":
        found = true
        check child.innerText == "hello output"
    check found

suite "junit - toJunitXml protocol records (pass+fail+skip)":

  test "protocol entrypoint: one testcase per record":
    let recs = @[
      makeRecord("test alpha", rsPass),
      makeRecord("test beta",  rsFail, "expected 1 got 2"),
      makeRecord("test gamma", rsSkip, "not on linux"),
    ]
    let r = recordResult("tests/unit/test_proto.nim", recs)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    let suite = doc[0]
    check suite.attr("tests")    == "3"
    check suite.attr("failures") == "1"
    check suite.attr("skipped")  == "1"
    check suite.attr("errors")   == "0"
    var tcCount = 0
    for child in suite:
      if child.kind == xnElement and child.tag == "testcase":
        inc tcCount
    check tcCount == 3

  test "protocol: passing record → clean testcase":
    let recs = @[makeRecord("passes", rsPass)]
    let r = recordResult("tests/unit/test_p.nim", recs)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement:
            check inner.tag notin ["failure", "error"]

  test "protocol: failing record → <failure message=.../>":
    let recs = @[makeRecord("fails", rsFail, "assertion error")]
    let r = recordResult("tests/unit/test_f.nim", recs, outcome = oFailed)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "failure":
            found = true
            check inner.attr("message") == "assertion error"
    check found

  test "protocol: skipped record → <skipped/>":
    let recs = @[makeRecord("skipped", rsSkip)]
    let r = recordResult("tests/unit/test_s.nim", recs)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    var found = false
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        for inner in child:
          if inner.kind == xnElement and inner.tag == "skipped":
            found = true
    check found

  test "protocol record testcase: name classname time attributes":
    let recs = @[makeRecord("my test", rsPass, durationUs = 5_000)]
    let r = recordResult("tests/unit/test_q.nim", recs, durationMs = 10)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        check child.attr("name")      == "my test"
        check child.attr("classname") == "tests/unit/test_q.nim"
        check child.attr("time")      == "0.005000"

suite "junit - toJunitXml cached entrypoints":

  test "opaque cached: testcase carries cached=true":
    let r = opaqueResult("tests/unit/test_cached.nim", oPassed,
                         durationMs = 999, cached = true)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        check child.attr("cached") == "true"

  test "opaque cached: testsuite does NOT carry cached attr":
    let r = opaqueResult("tests/unit/test_cached.nim", oPassed,
                         durationMs = 999, cached = true)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    # For opaque entrypoints, cached goes on testcase not testsuite
    check doc[0].attr("cached") == ""

  test "opaque non-cached: testcase does NOT carry cached attr":
    let r = opaqueResult("tests/unit/test_live.nim", oPassed, cached = false)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    for child in doc[0]:
      if child.kind == xnElement and child.tag == "testcase":
        check child.attr("cached") == ""

  test "protocol cached: testsuite carries cached=true":
    let recs = @[makeRecord("ok", rsPass)]
    let r = recordResult("tests/unit/test_proto_cached.nim", recs, cached = true)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    check doc[0].attr("cached") == "true"

  test "protocol non-cached: testsuite does NOT carry cached attr":
    let recs = @[makeRecord("ok", rsPass)]
    let r = recordResult("tests/unit/test_proto_live.nim", recs, cached = false)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    check doc[0].attr("cached") == ""

  test "cached: time reflects original durationMs (not zero)":
    ## A6 synthesizes durationMs from the stored CachedResult.durationMs;
    ## so durationMs is the historical duration even for cached results.
    ## We just verify the time attribute uses durationMs correctly.
    let r = opaqueResult("tests/unit/test_cached.nim", oPassed,
                         durationMs = 1234, cached = true)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    let doc = parseDoc(xml)
    check doc[0].attr("time") == "1.234"

suite "junit - toJunitXml edge cases":

  test "empty results → valid XML with empty testsuites":
    let xml = toJunitXml(@[], Summary())
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"
    var suiteCount = 0
    for child in doc:
      if child.kind == xnElement and child.tag == "testsuite":
        inc suiteCount
    check suiteCount == 0

  test "mixed opaque and protocol entrypoints in same document":
    let opaque = opaqueResult("tests/unit/test_opaque.nim", oPassed)
    let recs   = @[makeRecord("test one", rsPass), makeRecord("test two", rsFail)]
    let proto  = recordResult("tests/unit/test_proto.nim", recs, outcome = oFailed)
    let xml = toJunitXml(@[opaque, proto], Summary(total: 2, passed: 1, failed: 1))
    let doc = parseDoc(xml)
    var suiteCount = 0
    for child in doc:
      if child.kind == xnElement and child.tag == "testsuite":
        inc suiteCount
    check suiteCount == 2

# ---------------------------------------------------------------------------
# Suite 3 — parseXml well-formedness round-trip with hostile content
# ---------------------------------------------------------------------------

suite "junit - parseXml well-formedness round-trip":

  test "hostile ep path with XML specials parses without error":
    let r = opaqueResult("tests/unit/test_<foo>&bar.nim", oPassed)
    let xml = toJunitXml(@[r], Summary(total: 1, passed: 1))
    # Must not raise
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"

  test "hostile record name with quotes and angle brackets parses without error":
    let recs = @[makeRecord("test \"<bad>\" & 'worse'", rsFail, "msg & <b>")]
    let r = recordResult("tests/unit/test_hostile.nim", recs, outcome = oFailed)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"

  test "hostile output with all XML specials parses without error":
    let hostile = "output: a<b>c&d\"e'f\nstderr: <error>boom</error>\n&amp;literal"
    let r = opaqueResult("tests/unit/test_out_hostile.nim", oFailed, exitCode = 1,
                         output = hostile)
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"

  test "output with null bytes and control chars parses without error":
    let r = opaqueResult("tests/unit/test_ctrl.nim", oFailed, exitCode = 1,
                         output = "start\x00middle\x01\x07end")
    let xml = toJunitXml(@[r], Summary(total: 1, failed: 1))
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"

  test "full synthetic results with hostile names round-trips parseXml":
    ## Exercise all outcome types + record types with hostile content.
    let results = @[
      opaqueResult("tests/unit/p&q<r>.nim",    oPassed,        output = "ok&fine"),
      opaqueResult("tests/unit/fail\"x\".nim", oFailed,        exitCode = 1,
                   output = "<fail>\"bad\"</fail>"),
      opaqueResult("tests/unit/ce'y'.nim",      oCompileFailed, output = "err&amp;"),
      opaqueResult("tests/unit/timeout.nim",    oKilled,        output = ""),
      opaqueResult("tests/unit/signal.nim",     oCrashed,       signal = 11),
    ]
    let proto = recordResult(
      "tests/unit/proto_hostile.nim",
      @[
        makeRecord("pass & check < >", rsPass),
        makeRecord("fail \"quoted\"",  rsFail, "got <nil> expected &amp;"),
        makeRecord("skip 'this'",      rsSkip),
      ],
      outcome = oFailed,
      output = "output\x00with\x01control\x07chars",
    )
    let allResults = results & @[proto]
    let summary = Summary(total: allResults.len, failed: 2,
                          compileFailed: 1)
    let xml = toJunitXml(allResults, summary)
    let doc = parseDoc(xml)
    check doc.tag == "testsuites"
    var suiteCount = 0
    for child in doc:
      if child.kind == xnElement and child.tag == "testsuite":
        inc suiteCount
    check suiteCount == allResults.len
