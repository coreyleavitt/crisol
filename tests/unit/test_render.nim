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

# ---------------------------------------------------------------------------
# Helpers — build synthetic results
# ---------------------------------------------------------------------------

proc makeEp(path: string; group = "unit"): Entrypoint =
  Entrypoint(path: path, group: group)

proc passedResult(path: string; durationMs: int64 = 100;
                  records: seq[TestRecord] = @[]): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oPassed,
                   exitCode: 0, durationMs: durationMs, records: records)

proc failedResult(path: string; records: seq[TestRecord] = @[];
                  output = ""; durationMs: int64 = 50): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oFailed,
                   exitCode: 1, durationMs: durationMs,
                   records: records, output: output)

proc compileFailedResult(path: string;
                          output = "error: undeclared id 'Foo'"): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oCompileFailed,
                   exitCode: 1, output: output, durationMs: 200)

proc timeoutResult(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oTimeout,
                   signal: 9, durationMs: 300_000)

proc signalResult(path: string; sig = 11): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oSignal,
                   signal: sig, durationMs: 80)

proc spawnResult(path: string): EntrypointResult =
  EntrypointResult(ep: makeEp(path), outcome: oSpawnError,
                   output: "fork failed", durationMs: 0)

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
    check "[TIMEOUT]" in rendered
    check "[SIGNAL]"  in rendered
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
    check "1 timed-out"     in rendered

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

# ---------------------------------------------------------------------------
# sanitizeForTerminal — control/ANSI injection guard for untrusted-origin
# diagnostic text (config warnings, on-disk state, manifests) before it
# reaches stderr.
# ---------------------------------------------------------------------------

suite "render — sanitizeForTerminal":

  test "replaces ESC/newline/control bytes with '?', no truncation":
    check sanitizeForTerminal("\e[31mred\e[0m\n") == "?[31mred?[0m?"

  test "plain text with no control bytes is unchanged":
    check sanitizeForTerminal("unknown config key 'foo' in unit (ignored)") ==
          "unknown config key 'foo' in unit (ignored)"

  test "DEL (0x7f) is also replaced":
    check sanitizeForTerminal("a\x7fb") == "a?b"

# ---------------------------------------------------------------------------
# renderClosure (crisol/closure/v1 human rendering)
# ---------------------------------------------------------------------------

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
