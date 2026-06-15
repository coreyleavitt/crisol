## test_B3_quarantine_render.nim — B3 unit tests: render [QUARANTINED] label
##
## Covers:
##   1. Quarantined FAILED result shows [QUARANTINED] label
##   2. Quarantined PASSED result shows [QUARANTINED] label (harmless, but labeled)
##   3. Non-quarantined result does NOT show [QUARANTINED]
##   4. [QUARANTINED] appears alongside the outcome label (e.g. [FAIL] + [QUARANTINED])
##   5. Quarantined result with color=true shows [QUARANTINED] with ANSI color
##   6. Quarantined cached result shows both [CACHED] and [QUARANTINED]
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_B3_quarantine_render.nim

import std/[strutils, unittest]
import crisol/types
import crisol/render
import crisol/runner  # for summarize

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

proc noColorOpts(): RenderOpts = RenderOpts(color: false, slowestN: 5)
proc withColorOpts(): RenderOpts = RenderOpts(color: true, slowestN: 5)

suite "B3 render — [QUARANTINED] label":

  test "quarantined FAILED result shows [QUARANTINED]":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: true)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" in rendered

  test "quarantined PASSED result also shows [QUARANTINED]":
    ## A quarantined entrypoint is labeled regardless of outcome.
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oPassed, exitCode: 0,
                             durationMs: 100, quarantined: true)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" in rendered

  test "non-quarantined result does NOT show [QUARANTINED]":
    let r = EntrypointResult(ep: makeEp("tests/unit/test_a.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: false)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" notin rendered

  test "quarantined failure shows outcome label AND [QUARANTINED] together":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: true)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[FAIL]"        in rendered
    check "[QUARANTINED]" in rendered

  test "quarantined with color=true shows [QUARANTINED] in ANSI-colored form":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: true)
    let s = summarize(@[r])
    let rendered = render(@[r], s, withColorOpts())
    # ANSI escapes present and the literal text is still there
    check "\x1b[" in rendered
    check "QUARANTINED" in rendered

  test "quarantined cached result shows both [CACHED] and [QUARANTINED]":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oPassed, exitCode: 0,
                             durationMs: 100, cached: true, quarantined: true)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[CACHED]"      in rendered
    check "[QUARANTINED]" in rendered

when isMainModule:
  echo "B3 render quarantine tests passed."
