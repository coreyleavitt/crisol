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

import std/[options, strutils, unittest]
import crisol/types
import crisol/render
import crisol/runner  # for summarize
import crisol/process/types as ptypes  # rfc-0007 A1c: coherent Phase fixtures

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit")

proc noColorOpts(): RenderOpts = RenderOpts(color: false, slowestN: 5)
proc withColorOpts(): RenderOpts = RenderOpts(color: true, slowestN: 5)

# rfc-0007 A1c: render displays deriveOutcome(r), not the stored legacy
# `outcome` field — every fixture below also stamps a coherent `run: Phase`
# (compile stays the pkSkipped zero-value default; only the run phase
# matters for these fixtures' exitCode-only outcomes) so deriveOutcome
# agrees with the legacy `outcome` each literal names.
proc ranPhase(exitCode: int): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit:       ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
    cause:      ptypes.Cause(by: ptypes.cbProcess),
    evidence:   default(ptypes.Evidence),
    rusage:     none(ptypes.Rusage),
    durationUs: 0))

proc cachedPhase(exitCode: int): ptypes.Phase =
  ## rfc-0007 A1e-i: `cached(r)` derives from `run.kind == pkCached` — there
  ## is no separate `cached` field to stamp any more.
  ptypes.Phase(kind: ptypes.pkCached, res: ptypes.ProcessResult(
    exit:       ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
    cause:      ptypes.Cause(by: ptypes.cbProcess),
    evidence:   default(ptypes.Evidence),
    rusage:     none(ptypes.Rusage),
    durationUs: 0))

suite "B3 render — [QUARANTINED] label":

  test "quarantined FAILED result shows [QUARANTINED]":
    var r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             durationMs: 50, quarantined: true)
    r.run = ranPhase(1)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" in rendered

  test "quarantined PASSED result also shows [QUARANTINED]":
    ## A quarantined entrypoint is labeled regardless of outcome.
    var r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             durationMs: 100, quarantined: true)
    r.run = ranPhase(0)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" in rendered

  test "non-quarantined result does NOT show [QUARANTINED]":
    var r = EntrypointResult(ep: makeEp("tests/unit/test_a.nim"),
                             durationMs: 50, quarantined: false)
    r.run = ranPhase(1)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[QUARANTINED]" notin rendered

  test "quarantined failure shows outcome label AND [QUARANTINED] together":
    var r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             durationMs: 50, quarantined: true)
    r.run = ranPhase(1)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[FAIL]"        in rendered
    check "[QUARANTINED]" in rendered

  test "quarantined with color=true shows [QUARANTINED] in ANSI-colored form":
    var r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             durationMs: 50, quarantined: true)
    r.run = ranPhase(1)
    let s = summarize(@[r])
    let rendered = render(@[r], s, withColorOpts())
    # ANSI escapes present and the literal text is still there
    check "\x1b[" in rendered
    check "QUARANTINED" in rendered

  test "quarantined cached result shows both [CACHED] and [QUARANTINED]":
    var r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             durationMs: 100, quarantined: true)
    r.run = cachedPhase(0)
    let s = summarize(@[r])
    let rendered = render(@[r], s, noColorOpts())
    check "[CACHED]"      in rendered
    check "[QUARANTINED]" in rendered

when isMainModule:
  echo "B3 render quarantine tests passed."
