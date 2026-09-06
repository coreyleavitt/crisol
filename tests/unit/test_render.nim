## test_render.nim — unit tests for crisol/render (B4 slice)
##
## All tests are pure: no I/O, no subprocess, no real TTY.
## Color is injected via RenderOpts.color.
## shouldEnableColor is tested by injecting the tty bool + controlling NO_COLOR.
##
## Covers:
##   1. Per-entrypoint outcome labels — all 6 outcomes present
##   2. Failure detail — fail msg from records; compile output; opaque output
##   3. Skip reasons — appear in output for passed entrypoints with skip records
##   4. Per-test aggregate counts — correct total/passed/failed/skipped
##   5. Slowest-N — test-level granularity (records present), correct order + cap
##   6. Slowest-N — entrypoint-level fallback (no records anywhere)
##   7. Summary footer — PASSED / FAILED verdicts with correct counts
##   8. Color on — ANSI escapes present
##   9. Color off — no ANSI escapes present
##  10. shouldEnableColor — NO_COLOR set → false; unset + tty=true → true;
##                          unset + tty=false → false
##  11. formatProgressLine — non-empty list → names + durations in output
##  12. formatProgressLine — empty list → ""

import std/[monotimes, options, os, strutils, times, unittest]
import crisol/types
import crisol/render
import crisol/terminal  # for shouldEnableColor
import crisol/runner  # for summarize
import crisol/process/types as ptypes  # rfc-0007 A1c: coherent Phase fixtures
import crisol/cachetelemetry  # RFC-0005 B2b: CacheStats — renderCacheStats

# ---------------------------------------------------------------------------
# Helpers — build synthetic results
#
# rfc-0007 A1c: render now displays deriveOutcome(r), not the stored legacy
# `outcome` field — every fixture below also stamps a coherent `compile`/
# `run: Phase` pair (the same shape runner.execute's dual-write produces) so
# deriveOutcome agrees with the legacy outcome each helper names.
# ---------------------------------------------------------------------------

proc makeEp(path: string; group = "unit"): Entrypoint =
  Entrypoint(path: path, group: group)

proc ranPhase(cause: ptypes.Cause; exit: ptypes.Exit): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: exit, cause: cause, evidence: default(ptypes.Evidence),
    rusage: none(ptypes.Rusage), durationUs: 0))

const skippedPhase = ptypes.Phase(kind: ptypes.pkSkipped)
const cbProcess = ptypes.Cause(by: ptypes.cbProcess)

proc passedResult(path: string; durationMs: int64 = 100;
                  records: seq[TestRecord] = @[]): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), durationMs: durationMs, records: records)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 0))

proc failedResult(path: string; records: seq[TestRecord] = @[];
                  output = ""; durationMs: int64 = 50): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), durationMs: durationMs,
                   records: records, output: output)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 1))

proc compileFailedResult(path: string;
                          output = "error: undeclared id 'Foo'"): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), output: output, durationMs: 200)
  result.compile = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekExited, code: 1))
  result.run = skippedPhase

proc timeoutResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), durationMs: 300_000)
  result.compile = skippedPhase
  result.run = ranPhase(
    ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: false),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 9, coreDumped: false))

proc signalResult(path: string; sig = 11): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path), durationMs: 80)
  result.compile = skippedPhase
  result.run = ranPhase(cbProcess, ptypes.Exit(kind: ptypes.ekSignaled, sig: sig, coreDumped: false))

proc escalatedKillResult(path: string): EntrypointResult =
  ## rfc-0007 A1f: SIGTERM ignored -> escalated to SIGKILL (term_ignores'
  ## shape) — the render line must show escalation, not just cause.
  result = EntrypointResult(ep: makeEp(path), durationMs: 5_000)
  result.compile = skippedPhase
  result.run = ranPhase(
    ptypes.Cause(by: ptypes.cbRunner, reason: ptypes.krTimeout, escalated: true),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 9, coreDumped: false))

proc limitCrashedResult(path: string): EntrypointResult =
  ## rfc-0007 A1f: SIGXCPU with the limit requested+achieved — cbLimit.
  result = EntrypointResult(ep: makeEp(path), durationMs: 1_000)
  result.compile = skippedPhase
  result.run = ranPhase(
    ptypes.Cause(by: ptypes.cbLimit, limit: ptypes.lkCpu),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 24, coreDumped: false))

proc externalCrashedResult(path: string): EntrypointResult =
  ## rfc-0007 A1f: SIGKILL the runner did not send — cbExternal.
  result = EntrypointResult(ep: makeEp(path), durationMs: 1_000)
  result.compile = skippedPhase
  result.run = ranPhase(ptypes.Cause(by: ptypes.cbExternal),
    ptypes.Exit(kind: ptypes.ekSignaled, sig: 9, coreDumped: false))

proc spawnResult(path: string): EntrypointResult =
  result = EntrypointResult(ep: makeEp(path),
                   output: "fork failed", durationMs: 0)
  result.compile = skippedPhase
  result.run = ptypes.Phase(kind: ptypes.pkSpawnFailed, spawnError: "fork failed")

proc passRecord(name: string; us: int64): TestRecord =
  TestRecord(name: name, status: rsPass, durationUs: us)

proc failRecord(name: string; us: int64; msg: string): TestRecord =
  TestRecord(name: name, status: rsFail, durationUs: us,
             msg: some(msg))

proc skipRecord(name: string; reason: string): TestRecord =
  TestRecord(name: name, status: rsSkip, durationUs: 0,
             msg: some(reason))

proc noColorOpts(): RenderOpts = RenderOpts(color: false, slowestN: 5)
proc withColorOpts(): RenderOpts = RenderOpts(color: true, slowestN: 5)

# ---------------------------------------------------------------------------
# Suite 1 — Per-entrypoint outcome labels
# ---------------------------------------------------------------------------

suite "render – outcome labels":
  test "all six outcome labels appear when each outcome is present":
    ## rfc-0007 A1c: labels are driven by deriveOutcome, so a coherently
    ## Phase-stamped timeoutResult/signalResult render as [KILLED]/[CRASH]
    ## (the derived vocabulary), not the legacy [TIMEOUT]/[SIGNAL] text.
    let results = @[
      passedResult("tests/unit/test_a.nim"),
      failedResult("tests/unit/test_b.nim"),
      compileFailedResult("tests/unit/test_c.nim"),
      timeoutResult("tests/unit/test_d.nim"),
      signalResult("tests/unit/test_e.nim"),
      spawnResult("tests/unit/test_f.nim"),
    ]
    let s = summarize(results)
    let rendered = render(results, s, noColorOpts())

    check "[OK]"      in rendered
    check "[FAIL]"    in rendered
    check "[COMPILE]" in rendered
    check "[KILLED]"  in rendered
    check "[CRASH]"   in rendered
    check "[SPAWN]"   in rendered

  test "entrypoint paths appear in output":
    let results = @[
      passedResult("tests/unit/test_parser.nim"),
      failedResult("tests/integration/test_store.nim"),
    ]
    let s = summarize(results)
    let rendered = render(results, s, noColorOpts())
    check "tests/unit/test_parser.nim"        in rendered
    check "tests/integration/test_store.nim"  in rendered

# ---------------------------------------------------------------------------
# Suite 2 — Failure detail
# ---------------------------------------------------------------------------

suite "render – failure detail":
  test "fail record msg appears under failed entrypoint":
    let records = @[
      passRecord("test_ok", 100),
      failRecord("test_broken", 200, "expected 42 got 0"),
    ]
    let results = @[failedResult("tests/unit/test_x.nim", records)]
    let rendered = render(results, summarize(results), noColorOpts())
    check "test_broken"        in rendered
    check "expected 42 got 0" in rendered

  test "compile output appears under compile-failed entrypoint":
    let results = @[compileFailedResult("tests/unit/test_c.nim",
                                         "error: undeclared identifier: 'badSym'")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "Compiler output:"                in rendered
    check "undeclared identifier: 'badSym'" in rendered

  test "captured output shown for opaque failed binary (no records)":
    let results = @[failedResult("tests/unit/test_op.nim", @[],
                                  "CRASH: null pointer deref")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "CRASH: null pointer deref" in rendered

  test "rfc-0007 A1c: a killed result's detail line names the cause":
    let results = @[timeoutResult("tests/unit/test_d.nim")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "[KILLED]" in rendered
    check "cause: runner timeout" in rendered

  test "rfc-0007 A1c: a crashed result's detail line names the cause":
    let results = @[signalResult("tests/unit/test_e.nim", sig = 11)]
    let rendered = render(results, summarize(results), noColorOpts())
    check "[CRASH]" in rendered
    check "cause: process" in rendered

  test "rfc-0007 A1f: an escalated kill's detail line shows the escalation, not just the cause":
    let results = @[escalatedKillResult("tests/unit/test_g.nim")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "[KILLED]" in rendered
    check "cause: runner timeout (escalated)" in rendered

  test "rfc-0007 A1f: a non-escalated kill's detail line shows no escalation marker":
    let results = @[timeoutResult("tests/unit/test_d.nim")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "cause: runner timeout" in rendered
    check "(escalated)" notin rendered

  test "rfc-0007 A1f: a limit-authored crash's detail line names the limit":
    ## causeLabel renders the LimitKind via Nim's `$` (its own render-layer
    ## convention, distinct from resultjson's wire string "cpu") — pinning
    ## the actual observed text, "limit lkCpu".
    let results = @[limitCrashedResult("tests/unit/test_h.nim")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "[CRASH]" in rendered
    check "cause: limit lkCpu" in rendered

  test "rfc-0007 A1f: an externally-signaled crash's detail line reads external":
    let results = @[externalCrashedResult("tests/unit/test_i.nim")]
    let rendered = render(results, summarize(results), noColorOpts())
    check "[CRASH]" in rendered
    check "cause: external" in rendered

# ---------------------------------------------------------------------------
# Suite 3 — Skip reasons
# ---------------------------------------------------------------------------

suite "render – skip reasons":
  test "skip reason from rsSkip record appears in output":
    let records = @[
      passRecord("test_normal", 50),
      skipRecord("test_needs_db", "requires DATABASE_URL env var"),
    ]
    let results = @[passedResult("tests/unit/test_skips.nim",
                                  durationMs = 30, records = records)]
    let rendered = render(results, summarize(results), noColorOpts())
    check "test_needs_db"                 in rendered
    check "requires DATABASE_URL env var" in rendered

# ---------------------------------------------------------------------------
# Suite 4 — Per-test aggregate counts
# ---------------------------------------------------------------------------

suite "render – aggregate test counts":
  test "correct total/passed/failed/skipped in output":
    let recs1 = @[passRecord("a", 10), passRecord("b", 20)]
    let recs2 = @[failRecord("c", 30, "boom"), skipRecord("d", "reason")]
    let results = @[
      passedResult("tests/unit/ep1.nim", records = recs1),
      failedResult("tests/unit/ep2.nim", records = recs2),
    ]
    let rendered = render(results, summarize(results), noColorOpts())
    # 4 total tests, 2 passed, 1 failed, 1 skipped
    check "4"         in rendered
    check "2 passed"  in rendered
    check "1 failed"  in rendered
    check "1 skipped" in rendered

# ---------------------------------------------------------------------------
# Suite 5 — Slowest-N (test-level when records present)
# ---------------------------------------------------------------------------

suite "render – slowest-N test-level":
  test "lists slowest tests descending, capped at N":
    let records = @[
      passRecord("fast_test",   1_000),
      passRecord("medium_test", 50_000),
      passRecord("slow_test",   500_000),
      passRecord("sluggish",    200_000),
      passRecord("crawling",    800_000),
      passRecord("tiny",        500),
    ]
    let opts = RenderOpts(color: false, slowestN: 3)
    let results = @[passedResult("tests/unit/ep.nim", records = records)]
    let rendered = render(results, summarize(results), opts)

    # Should list slowest 3: crawling (800ms), slow_test (500ms), sluggish (200ms)
    check "crawling"  in rendered
    check "slow_test" in rendered
    check "sluggish"  in rendered
    # We check ordering: crawling before slow_test before sluggish
    let posCrawling  = rendered.find("crawling")
    let posSlowTest  = rendered.find("slow_test")
    let posSluggish  = rendered.find("sluggish")
    check posCrawling  < posSlowTest
    check posSlowTest  < posSluggish

  test "slowest section header mentions N":
    let records = @[passRecord("t1", 1000), passRecord("t2", 2000)]
    let opts = RenderOpts(color: false, slowestN: 2)
    let results = @[passedResult("tests/unit/ep.nim", records = records)]
    let rendered = render(results, summarize(results), opts)
    check "Slowest 2 tests" in rendered

# ---------------------------------------------------------------------------
# Suite 6 — Slowest-N (entrypoint-level fallback when no records)
# ---------------------------------------------------------------------------

suite "render – slowest-N entrypoint-level":
  test "falls back to entrypoint durations when no records present":
    let results = @[
      passedResult("tests/unit/fast.nim",   durationMs = 100),
      passedResult("tests/unit/slow.nim",   durationMs = 5000),
      passedResult("tests/unit/medium.nim", durationMs = 2000),
    ]
    let opts = RenderOpts(color: false, slowestN: 2)
    let rendered = render(results, summarize(results), opts)
    check "Slowest 2 entrypoints" in rendered
    # slow.nim should appear before medium.nim
    let posSlow   = rendered.find("slow.nim")
    let posMedium = rendered.find("medium.nim")
    check posSlow < posMedium

# ---------------------------------------------------------------------------
# Suite 7 — Summary footer
# ---------------------------------------------------------------------------

suite "render – summary footer":
  test "PASSED verdict when all pass":
    let results = @[passedResult("tests/unit/t.nim")]
    let s = summarize(results)
    let rendered = render(results, s, noColorOpts())
    check "PASSED" in rendered
    check "FAILED" notin rendered

  test "FAILED verdict with correct failure type counts":
    let results = @[
      passedResult("tests/unit/t1.nim"),
      failedResult("tests/unit/t2.nim"),
      compileFailedResult("tests/unit/t3.nim"),
      timeoutResult("tests/unit/t4.nim"),
    ]
    let s = summarize(results)
    let rendered = render(results, s, noColorOpts())
    check "FAILED"          in rendered
    check "1 failed"        in rendered
    check "1 compile-failed" in rendered
    # rfc-0007 §2: "timed-out" was the legacy scalar-counter label; a
    # runner-authored kill now renders under the honest "killed" bucket
    # (summary.counts[oKilled] — there is no scalar counterpart any more).
    check "1 killed"        in rendered

# ---------------------------------------------------------------------------
# Suite 8 & 9 — Color on / off
# ---------------------------------------------------------------------------

suite "render – color":
  test "color=true emits ANSI escape sequences":
    let results = @[passedResult("tests/unit/t.nim")]
    let s = summarize(results)
    let rendered = render(results, s, withColorOpts())
    check "\e[" in rendered

  test "color=false emits no ANSI escape sequences":
    let results = @[
      passedResult("tests/unit/pass.nim"),
      failedResult("tests/unit/fail.nim"),
      compileFailedResult("tests/unit/compile.nim"),
    ]
    let s = summarize(results)
    let rendered = render(results, s, noColorOpts())
    check "\e[" notin rendered

# ---------------------------------------------------------------------------
# Suite 10 — shouldEnableColor
# ---------------------------------------------------------------------------

suite "render – shouldEnableColor":
  test "NO_COLOR set → false regardless of tty state":
    putEnv("NO_COLOR", "1")
    defer: delEnv("NO_COLOR")
    check shouldEnableColor(true)  == false
    check shouldEnableColor(false) == false

  test "NO_COLOR unset + tty=true → true":
    delEnv("NO_COLOR")
    check shouldEnableColor(true) == true

  test "NO_COLOR unset + tty=false → false":
    delEnv("NO_COLOR")
    check shouldEnableColor(false) == false

  test "NO_COLOR empty string → treated as unset, follows tty":
    putEnv("NO_COLOR", "")
    defer: delEnv("NO_COLOR")
    # getEnv returns "" for both unset and empty, so this matches unset behavior
    check shouldEnableColor(true)  == true
    check shouldEnableColor(false) == false

# ---------------------------------------------------------------------------
# Suite 11 & 12 — formatProgressLine
# ---------------------------------------------------------------------------

suite "render – formatProgressLine":
  test "non-empty list contains each entrypoint name and a duration":
    let inFlight = @[
      ("tests/unit/test_foo.nim",         5_000'i64),
      ("tests/integration/test_bar.nim", 35_000'i64),
    ]
    let line = formatProgressLine(inFlight, memThrottled = false)
    check "test_foo.nim"  in line
    check "test_bar.nim"  in line
    # 5000ms → 5s; 35000ms → 35s
    check "5s"  in line
    check "35s" in line
    check "still running" in line

  test "durations under 1s shown in ms":
    let inFlight = @[("tests/unit/test_fast.nim", 500'i64)]
    let line = formatProgressLine(inFlight, memThrottled = false)
    check "500ms" in line

  test "empty inFlight returns empty string":
    let line = formatProgressLine(@[], memThrottled = false)
    check line == ""

  test "single entry line is well-formed":
    let inFlight = @[("tests/unit/test_only.nim", 62_000'i64)]
    let line = formatProgressLine(inFlight, memThrottled = false)
    check "test_only.nim" in line
    check "62s"           in line

# ---------------------------------------------------------------------------
# Suite 13 — formatProgressLine with memThrottled signal (M4)
# ---------------------------------------------------------------------------

suite "render – formatProgressLine memThrottled signal":
  test "memThrottled=true appends the mem-throttled signal":
    let inFlight = @[("tests/unit/test_foo.nim", 5_000'i64)]
    let line = formatProgressLine(inFlight, memThrottled = true)
    check "[mem-throttled]" in line

  test "memThrottled=false omits the mem-throttled signal":
    let inFlight = @[("tests/unit/test_foo.nim", 5_000'i64)]
    let line = formatProgressLine(inFlight, memThrottled = false)
    check "[mem-throttled]" notin line

  test "memThrottled=true on empty inFlight still returns empty string":
    # empty inFlight → "" regardless of memThrottled (no progress line to annotate)
    let line = formatProgressLine(@[], memThrottled = true)
    check line == ""

# ---------------------------------------------------------------------------
# Suite 14 — memThrottleActive pure decision function (M4)
# ---------------------------------------------------------------------------

suite "render – memThrottleActive":
  test "none throttledSince → false regardless of threshold":
    let now = getMonoTime()
    check memThrottleActive(none(MonoTime), now, MemThrottleSignalMs) == false

  test "throttledSince recent (below threshold) → false":
    let t0  = getMonoTime()
    let now = t0 + initDuration(milliseconds = 1000)  # only 1s elapsed
    check memThrottleActive(some(t0), now, MemThrottleSignalMs) == false

  test "throttledSince exactly at threshold → false (exclusive >)":
    let t0  = getMonoTime()
    let now = t0 + initDuration(milliseconds = MemThrottleSignalMs)
    check memThrottleActive(some(t0), now, MemThrottleSignalMs) == false

  test "throttledSince over threshold → true":
    let t0  = getMonoTime()
    let now = t0 + initDuration(milliseconds = MemThrottleSignalMs + 1)
    check memThrottleActive(some(t0), now, MemThrottleSignalMs) == true

  test "custom threshold: above custom threshold → true":
    let t0  = getMonoTime()
    let now = t0 + initDuration(milliseconds = 200)
    check memThrottleActive(some(t0), now, 100) == true

  test "custom threshold: below custom threshold → false":
    let t0  = getMonoTime()
    let now = t0 + initDuration(milliseconds = 50)
    check memThrottleActive(some(t0), now, 100) == false

suite "render — issue #14: report bodies carry no raw control bytes":

  proc rawControlBytes(s: string): int =
    for c in s:
      if (c.ord < 0x20 and c != '\n') or c.ord == 0x7f: inc result

  test "run report: entrypoint path, group and protocol record names/messages are sanitized":
    ## Paths/groups are config-origin; record names and messages come from
    ## the test binary's protocol stream.  All are identifiers meant for one
    ## line of terminal output, so each is sanitized at the render layer.
    var failing = failedResult("tests/unit/test_\x1b[2Jx.nim", records = @[
      failRecord("suite\tone\x1b[31m", 1200, "boom\x1bm"),
      skipRecord("sk\x7fip", "why\x1b"),
      passRecord("fast\x1bname", 10),
    ])
    failing.ep.group = "grp\x1b[0m"
    let results = @[failing, passedResult("tests/unit/test_ok.nim", records = @[
      passRecord("slow\x1bone", 900_000)])]
    let rendered = render(results, summarize(results), noColorOpts())
    check rawControlBytes(rendered) == 0
    check "tests/unit/test_?[2Jx.nim" in rendered
    check "suite?one?[31m" in rendered
    check "boom?m" in rendered
    check "sk?ip" in rendered
    check "slow?one" in rendered   # slowest-tests section

  test "closure listing: path, group and closure file paths are sanitized":
    let report = ClosureReport(entries: @[
      ClosureEntry(path: "tests/unit/test_\x1bx.nim", group: "g\tr\x1b[2Jp",
                   flagHash: "0123456789abcdef", recorded: true,
                   closure: @["lib/de\x7fp.nim", "tests/unit/test_\x1bx.nim"],
                   closureHash: "fedcba9876543210")])
    let rendered = renderClosure(report)
    check rawControlBytes(rendered) == 0
    check "tests/unit/test_?x.nim  [g?r?[2Jp]  0123456789abcdef  recorded  (2 files)" in rendered
    check "  lib/de?p.nim" in rendered

suite "render — renderClosure":

  test "renders path, group, flagHash, closure files, and a distinct recorded/unrecorded marker":
    let report = ClosureReport(
      entries: @[
        ClosureEntry(
          path:        "tests/unit/test_a.nim",
          group:       "unit",
          flagHash:    "0123456789abcdef",
          recorded:    true,
          closure:     @["lib/dep.nim", "tests/unit/test_a.nim"],
          closureHash: "fedcba9876543210",
        ),
        ClosureEntry(
          path:        "tests/unit/test_b.nim",
          group:       "unit",
          flagHash:    "1111111111111111",
          recorded:    false,
          closure:     @[],
          closureHash: "",
        ),
      ],
    )
    let lines = renderClosure(report).splitLines

    # One header line per entry, then one indented line per closure file:
    # entry 1 (recorded, 2 files) occupies lines[0..2]; entry 2 (unrecorded,
    # 0 files) occupies line[3] only, followed by the trailing "" from the
    # final newline.
    check lines.len == 5
    check lines[0] == "tests/unit/test_a.nim  [unit]  0123456789abcdef  recorded  (2 files)"
    check lines[1] == "  lib/dep.nim"
    check lines[2] == "  tests/unit/test_a.nim"
    check lines[3] == "tests/unit/test_b.nim  [unit]  1111111111111111  unrecorded  (0 files)"

# ---------------------------------------------------------------------------
# RFC-0005 B1c: miss-explanation rendering — pure component vectors
# ---------------------------------------------------------------------------

suite "render — isCacheMissDecision":

  test "the six miss variants are true":
    for cd in [cdmStored, cdmKeyMiss, cdmHermeticityDeg, cdmFlaky,
               cdmClosureUnrecorded, cdmRecomputeMiss]:
      check isCacheMissDecision(cd)

  test "cdmHit and every not-consulted variant are false":
    for cd in [cdmHit, cdmNotEligible, cdmGroupOptOut, cdmPolicyDisabled]:
      check not isCacheMissDecision(cd)

suite "render — explainMissLines (degraded case)":

  test "empty diffs -> 'no prior inputs recorded', gated by nothing (caller decides whether to call)":
    check explainMissLines(@[], verbose = false) == @["no prior inputs recorded"]
    check explainMissLines(@[], verbose = true) == @["no prior inputs recorded"]

suite "render — renderKeyDiffLines: opaque-hash components":

  test "kcClosure terse: truncated to 8 chars on each side":
    let d = KeyDiff(component: kcClosure,
                     prev: "a1b2c3d4e5f6a7b8", curr: "9988776655443322")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcClosure: changed (a1b2c3d4… → 99887766…)"]

  test "kcFlags verbose: full untruncated values":
    let d = KeyDiff(component: kcFlags,
                     prev: "a1b2c3d4e5f6a7b8", curr: "9988776655443322")
    check renderKeyDiffLines(d, verbose = true) ==
          @["kcFlags: changed (a1b2c3d4e5f6a7b8 → 9988776655443322)"]

  test "kcFixtures and kcProtocol use the same generic renderer":
    let fx = KeyDiff(component: kcFixtures, prev: "aaaaaaaaaaaaaaaa", curr: "bbbbbbbbbbbbbbbb")
    check renderKeyDiffLines(fx, verbose = false) ==
          @["kcFixtures: changed (aaaaaaaa… → bbbbbbbb…)"]
    let pr = KeyDiff(component: kcProtocol, prev: "1", curr: "2")
    check renderKeyDiffLines(pr, verbose = false) == @["kcProtocol: changed (1… → 2…)"]

  test "short hash (< 8 chars) is shown in full, not padded, terse mode":
    let d = KeyDiff(component: kcClosure, prev: "ab", curr: "cd")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcClosure: changed (ab… → cd…)"]

suite "render — renderKeyDiffLines: kcNimVersion":

  test "version TEXT differs: first line of each side + 8-hex hash, terse":
    let d = KeyDiff(component: kcNimVersion,
      prev: "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at ...|a1b2c3d4e5f6a7b8",
      curr: "Nim Compiler Version 2.4.0 [Linux: amd64]\nCompiled at ...|9988776655443322")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcNimVersion: Nim Compiler Version 2.2.10 [Linux: amd64] (a1b2c3d4…) → " &
            "Nim Compiler Version 2.4.0 [Linux: amd64] (99887766…)"]

  test "only the binary hash differs (text identical): 'compiler binary differs', terse":
    let d = KeyDiff(component: kcNimVersion,
      prev: "Nim Compiler Version 2.2.10 [Linux: amd64]|a1b2c3d4e5f6a7b8",
      curr: "Nim Compiler Version 2.2.10 [Linux: amd64]|9988776655443322")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcNimVersion: compiler binary differs (a1b2c3d4… → 99887766…)"]

  test "verbose: full multi-line text and full hash on both sides":
    let d = KeyDiff(component: kcNimVersion,
      prev: "line1\nline2|a1b2c3d4e5f6a7b8",
      curr: "line1\nline3|9988776655443322")
    let lines = renderKeyDiffLines(d, verbose = true)
    check lines.len == 1
    let physLines = lines[0].splitLines()
    check physLines == @["kcNimVersion prev:", "line1", "line2",
                          "  hash: a1b2c3d4e5f6a7b8", "kcNimVersion curr:",
                          "line1", "line3", "  hash: 9988776655443322"]

  test "malformed (no pipe) falls back to the generic opaque render, never crashes":
    let d = KeyDiff(component: kcNimVersion, prev: "no-pipe-here", curr: "also-no-pipe")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcNimVersion: changed (no-pipe-… → also-no-…)"]

suite "render — renderKeyDiffLines: kcCcVersion (accurate two-segment shape, NOT a binary hash)":

  test "only cc differs: names cc, full values, no truncation":
    let d = KeyDiff(component: kcCcVersion,
      prev: "cc (GCC) 12.2.0|ldd (GNU libc) 2.36",
      curr: "cc (GCC) 13.1.0|ldd (GNU libc) 2.36")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcCcVersion: cc: cc (GCC) 12.2.0 → cc (GCC) 13.1.0"]

  test "only ldd differs: MUST name ldd, MUST NOT say 'compiler binary differs'":
    let d = KeyDiff(component: kcCcVersion,
      prev: "cc (GCC) 12.2.0|ldd (GNU libc) 2.36",
      curr: "cc (GCC) 12.2.0|ldd (GNU libc) 2.38")
    let lines = renderKeyDiffLines(d, verbose = false)
    check lines == @["kcCcVersion: ldd: ldd (GNU libc) 2.36 → ldd (GNU libc) 2.38"]
    for l in lines:
      check "compiler binary differs" notin l
      check "ldd" in l

  test "both cc and ldd differ: two lines, both named":
    let d = KeyDiff(component: kcCcVersion,
      prev: "cc (GCC) 12.2.0|ldd (GNU libc) 2.36",
      curr: "cc (GCC) 13.1.0|ldd (GNU libc) 2.38")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcCcVersion: cc: cc (GCC) 12.2.0 → cc (GCC) 13.1.0",
            "kcCcVersion: ldd: ldd (GNU libc) 2.36 → ldd (GNU libc) 2.38"]

  test "verbose makes no difference (already single lines, per coordinator ruling)":
    let d = KeyDiff(component: kcCcVersion,
      prev: "cc (GCC) 12.2.0|ldd (GNU libc) 2.36",
      curr: "cc (GCC) 12.2.0|ldd (GNU libc) 2.38")
    check renderKeyDiffLines(d, verbose = true) == renderKeyDiffLines(d, verbose = false)

  test "malformed (no pipe) falls back to the generic opaque render":
    let d = KeyDiff(component: kcCcVersion, prev: "no-pipe", curr: "still-no-pipe")
    let lines = renderKeyDiffLines(d, verbose = false)
    check lines.len == 1
    check "kcCcVersion: changed (" in lines[0]

suite "render — renderKeyDiffLines: kcHermeticEnv":

  test "terse: lists envNames only, never the digest values":
    let d = KeyDiff(component: kcHermeticEnv, prev: "aaaa1111", curr: "bbbb2222",
                     envNames: @["LANG", "TERM"])
    check renderKeyDiffLines(d, verbose = false) == @["kcHermeticEnv: LANG, TERM"]

  test "verbose: names plus the full digest values":
    let d = KeyDiff(component: kcHermeticEnv, prev: "aaaa1111", curr: "bbbb2222",
                     envNames: @["TERM"])
    check renderKeyDiffLines(d, verbose = true) ==
          @["kcHermeticEnv: TERM (hash aaaa1111 → bbbb2222)"]

  test "no envNames identified: honest fallback, not a crash or empty string":
    let d = KeyDiff(component: kcHermeticEnv, prev: "aaaa1111", curr: "bbbb2222", envNames: @[])
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcHermeticEnv: (unable to identify which variable)"]

suite "render — renderKeyDiffLines: kcLimits (per-LimitKind diff)":

  test "one kind changed: only that kind is named":
    let d = KeyDiff(component: kcLimits,
      prev: "lkAddressSpace=-|lkCpu=300|lkFileSize=-|lkOpenFiles=1024|lkCore=-",
      curr: "lkAddressSpace=-|lkCpu=600|lkFileSize=-|lkOpenFiles=1024|lkCore=-")
    check renderKeyDiffLines(d, verbose = false) == @["kcLimits: lkCpu: 300 → 600"]

  test "two kinds changed: one line per kind":
    let d = KeyDiff(component: kcLimits,
      prev: "lkAddressSpace=-|lkCpu=300|lkFileSize=-|lkOpenFiles=1024|lkCore=-",
      curr: "lkAddressSpace=-|lkCpu=300|lkFileSize=-|lkOpenFiles=4096|lkCore=0")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcLimits: lkOpenFiles: 1024 → 4096", "kcLimits: lkCore: - → 0"]

suite "render — renderKeyDiffLines: kcArgv":

  test "full joined argv shown on both sides, never truncated":
    let d = KeyDiff(component: kcArgv, prev: "unit/x/testx --seed 1", curr: "unit/x/testx --seed 2")
    check renderKeyDiffLines(d, verbose = false) ==
          @["kcArgv: unit/x/testx --seed 1 → unit/x/testx --seed 2"]

suite "render — explainMissLines: multi-component ordering":

  test "one line per diff, in the order given":
    let diffs = @[
      KeyDiff(component: kcFlags, prev: "a1b2c3d4e5f6a7b8", curr: "9988776655443322"),
      KeyDiff(component: kcHermeticEnv, prev: "aaaa1111", curr: "bbbb2222", envNames: @["TERM"]),
    ]
    check explainMissLines(diffs, verbose = false) ==
          @["kcFlags: changed (a1b2c3d4… → 99887766…)", "kcHermeticEnv: TERM"]

suite "render — miss-explanation integration into render()":

  proc missResult(path: string; cd: CacheDecision; keyDiff: seq[KeyDiff] = @[]): EntrypointResult =
    result = passedResult(path)
    result.cacheDecision = cd
    result.keyDiff = keyDiff

  test "opts.explainMiss=false: no explain lines even for a miss decision with a diff":
    let r = missResult("tests/unit/test_a.nim", cdmKeyMiss,
                        @[KeyDiff(component: kcFlags, prev: "aaaa1111", curr: "bbbb2222")])
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(explainMiss: false))
    check "explain:" notin rendered

  test "opts.explainMiss=true, terse: shows the component-aware line for a miss":
    let r = missResult("tests/unit/test_a.nim", cdmStored,
                        @[KeyDiff(component: kcFlags, prev: "aaaa1111", curr: "bbbb2222")])
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(explainMiss: true))
    check "explain: kcFlags: changed (aaaa1111… → bbbb2222…)" in rendered

  test "opts.explainMiss=true: a HIT gets no explain block (nothing to explain)":
    let r = missResult("tests/unit/test_a.nim", cdmHit)
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(explainMiss: true))
    check "explain:" notin rendered

  test "opts.explainMiss=true: a miss with an empty diff shows the degraded message":
    let r = missResult("tests/unit/test_a.nim", cdmKeyMiss)
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(explainMiss: true))
    check "explain: no prior inputs recorded" in rendered

  test "opts.explainMissVerbose=true implies full values in the report":
    let r = missResult("tests/unit/test_a.nim", cdmKeyMiss,
                        @[KeyDiff(component: kcFlags, prev: "aaaa1111", curr: "bbbb2222")])
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(explainMiss: true, explainMissVerbose: true))
    check "explain: kcFlags: changed (aaaa1111 → bbbb2222)" in rendered

suite "render — renderCacheStats (RFC-0005 B2b)":

  test "renders every field, in the RFC's own order":
    let s = CacheStats(l1Hits: 3, remoteHits: 0, misses: 1, remoteErrors: 2,
                       localErrors: 4, total: 4, notConsulted: 5, hitPct: 75.0,
                       wallSavedMs: 120, published: 3, verifyFails: 1,
                       trustRejects: 0, corruptReads: 0)
    let line = renderCacheStats(s)
    check "3 l1 hits" in line
    check "0 remote hits" in line
    check "1 misses" in line
    check "0 trust-rejects" in line
    check "0 corrupt-reads" in line
    check "4 local-errors" in line
    check "2 remote-errors" in line
    check "4 consulted" in line
    check "5 not consulted" in line
    check "75.0% hit rate" in line
    check "120ms saved" in line
    check "3 published" in line
    check "1 verify-fails" in line

  test "RFC-0005 code-review D1: local-errors and remote-errors render independently":
    let s = CacheStats(localErrors: 1, remoteErrors: 0)
    let line = renderCacheStats(s)
    check "1 local-errors" in line
    check "0 remote-errors" in line

  test "RFC-0005 code-review R2-T8b: trust-rejects and corrupt-reads render independently, as a subset of misses":
    let s = CacheStats(misses: 3, trustRejects: 1, corruptReads: 2)
    let line = renderCacheStats(s)
    check "3 misses (1 trust-rejects, 2 corrupt-reads)" in line

  test "zero value renders 0.0% hit rate, never NaN":
    check "0.0% hit rate" in renderCacheStats(CacheStats())

suite "render — cache-stats integration into render()":

  test "opts.showCacheStats=false: no 'cache:' line even when cacheStats is set":
    let r = passedResult("tests/unit/test_a.nim")
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(showCacheStats: false,
                          cacheStats: CacheStats(l1Hits: 1)))
    check "cache:" notin rendered

  test "opts.showCacheStats=true: the summary line appears after PASSED/FAILED":
    let r = passedResult("tests/unit/test_a.nim")
    let s = summarize(@[r])
    let rendered = render(@[r], s, RenderOpts(showCacheStats: true,
                          cacheStats: CacheStats(l1Hits: 1, total: 1, hitPct: 100.0)))
    check "cache: 1 l1 hits" in rendered
    let passedIdx = rendered.find("PASSED:")
    let cacheIdx  = rendered.find("cache: 1 l1 hits")
    check passedIdx >= 0
    check cacheIdx > passedIdx
