## test_B3_quarantine_jsonout.nim — B3 unit tests: jsonout quarantine + flaky/attempts fields
##
## Covers:
##   1. Each entrypoint carries `quarantined` boolean (default false)
##   2. Quarantined result serializes quarantined=true
##   3. Each entrypoint carries `flaky` boolean (B1 field, was missing from run/v1)
##   4. Each entrypoint carries `attempts` integer (B1 field, was missing from run/v1)
##   5. Summary carries `quarantined` integer count
##   6. RunV1Revision is >= 3 (was 3 after B3 bump; C5 bumped to 4)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_B3_quarantine_jsonout.nim

import std/[json, unittest]
import crisol/types
import crisol/jsonout

proc makeEp(path: string): Entrypoint =
  Entrypoint(path: path, group: "unit", flags: @[])

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "B3 jsonout — quarantine + flaky/attempts fields":

  test "non-quarantined result has quarantined=false":
    let r = EntrypointResult(ep: makeEp("tests/unit/test_a.nim"),
                             outcome: oPassed, exitCode: 0,
                             durationMs: 100, quarantined: false)
    let node = toJson(@[r], Summary(total: 1, passed: 1))
    let ep = node["entrypoints"][0]
    check ep.hasKey("quarantined")
    check ep["quarantined"].getBool == false

  test "quarantined result has quarantined=true":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: true)
    let s = Summary(total: 1, quarantined: 1)
    let node = toJson(@[r], s)
    let ep = node["entrypoints"][0]
    check ep["quarantined"].getBool == true

  test "default EntrypointResult has quarantined=false (absence-default)":
    let r = EntrypointResult(ep: makeEp("tests/unit/test_b.nim"),
                             outcome: oPassed, exitCode: 0, durationMs: 10)
    let node = toJson(@[r], Summary(total: 1, passed: 1))
    check node["entrypoints"][0]["quarantined"].getBool == false

  test "each entrypoint carries flaky boolean (B1 field, now in run/v1)":
    let rFlaky = EntrypointResult(ep: makeEp("tests/unit/test_c.nim"),
                                  outcome: oPassed, exitCode: 0,
                                  durationMs: 100, flaky: true, attempts: 2)
    let rClean = EntrypointResult(ep: makeEp("tests/unit/test_d.nim"),
                                  outcome: oPassed, exitCode: 0,
                                  durationMs: 50, flaky: false, attempts: 1)
    let node = toJson(@[rFlaky, rClean], Summary(total: 2, passed: 2, flaky: 1))
    check node["entrypoints"][0].hasKey("flaky")
    check node["entrypoints"][0]["flaky"].getBool == true
    check node["entrypoints"][1]["flaky"].getBool == false

  test "each entrypoint carries attempts integer (B1 field, now in run/v1)":
    let r = EntrypointResult(ep: makeEp("tests/unit/test_e.nim"),
                             outcome: oPassed, exitCode: 0,
                             durationMs: 80, attempts: 3)
    let node = toJson(@[r], Summary(total: 1, passed: 1))
    check node["entrypoints"][0].hasKey("attempts")
    check node["entrypoints"][0]["attempts"].getInt == 3

  test "default attempts is 0 (not yet run / cached)":
    ## Cached results have attempts=0 per the B1 spec.
    let r = EntrypointResult(ep: makeEp("tests/unit/test_f.nim"),
                             outcome: oPassed, exitCode: 0,
                             durationMs: 20, cached: true, attempts: 0)
    let node = toJson(@[r], Summary(total: 1, passed: 1))
    check node["entrypoints"][0]["attempts"].getInt == 0

  test "summary carries quarantined integer count":
    let r = EntrypointResult(ep: makeEp("tests/integration/test_x.nim"),
                             outcome: oFailed, exitCode: 1,
                             durationMs: 50, quarantined: true)
    let s = Summary(total: 1, quarantined: 1)
    let node = toJson(@[r], s)
    check node["summary"].hasKey("quarantined")
    check node["summary"]["quarantined"].getInt == 1

  test "RunV1Revision is at least 3 (B3 bump; C5 bumped further to 4)":
    ## B3 adds quarantined (per-ep + summary) and flaky/attempts (per-ep).
    ## C5 bumped it further to 4 for peakRssBytes.
    check RunV1Revision >= 3
    let node = toJson(@[], Summary())
    check node["schemaRevision"].getInt == RunV1Revision

when isMainModule:
  echo "B3 jsonout quarantine/flaky/attempts tests passed."
