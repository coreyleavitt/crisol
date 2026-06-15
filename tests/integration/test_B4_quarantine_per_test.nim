## test_B4_quarantine_per_test.nim — B4 integration: per-test quarantine via execute().
##
## Uses the `protocol_two_fails.nim` fixture, which emits two named rsFail records:
##   "known flaky test A" and "known flaky test B"
## and exits with code 1.
##
## B4 scenarios:
##   1. Quarantine BOTH names → entrypoint quarantined, exitCode=0 for crisol.
##   2. Quarantine only ONE name → real failure (one unquarantined record), exitCode=1.
##   3. Quarantine NEITHER name → real failure, exitCode=1.
##   4. Quarantine the entrypoint PATH (B3) → quarantined, exitCode=0 (B3 unchanged).
##   5. Opaque fixture (fail_always, no records) + record names in quarantine
##      → per-test rule N/A; only B3 path-match can downgrade → NOT quarantined.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_B4_quarantine_per_test.nim

import std/[os, sets, unittest]
import crisol/types
import crisol/runner
import crisol/depgraph

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc makeCfg(q: HashSet[string] = initHashSet[string]()): Config =
  Config(
    compileTimeoutSecs: 60,
    timeoutSecs:        30,
    maxOutputBytes:     65_536,
    projectRoot:        getCurrentDir(),
    quarantine:         q,
  )

proc runFixture(fixturePath: string;
                q: HashSet[string] = initHashSet[string]()): seq[EntrypointResult] =
  let ep  = Entrypoint(path: fixturePath, group: "test", flags: @[])
  let cfg = makeCfg(q)
  let p   = plan(cfg, @[ep], emptyDepGraph())
  var g   = emptyDepGraph()
  execute(p, config = cfg, graph = g)

const RecA = "known flaky test A"
const RecB = "known flaky test B"

# ---------------------------------------------------------------------------
# Suite 1: B4 per-test quarantine with protocol_two_fails fixture
# ---------------------------------------------------------------------------

suite "B4 — per-test quarantine: both records quarantined → exit 0":

  test "both failing record names quarantined → quarantined=true, summary exit 0":
    let src = fixtureDir() / "protocol_two_fails.nim"
    check fileExists(src)

    let q = toHashSet([RecA, RecB])
    let results = runFixture(src, q)
    require results.len == 1
    let r = results[0]

    # The fixture uses the protocol → records should be populated.
    check r.records.len == 2
    check r.outcome == oFailed          # still oFailed — quarantine is reporting overlay
    check r.quarantined == true         # B4: all failing records are quarantined

    # summarize must exclude this from exit-contributing buckets.
    let s = summarize(results)
    check s.quarantined == 1
    check s.failed      == 0
    check exitCode(s)   == 0

suite "B4 — per-test quarantine: one record NOT quarantined → exit 1":

  test "only one of two failing records quarantined → NOT quarantined, exit 1":
    let src = fixtureDir() / "protocol_two_fails.nim"
    check fileExists(src)

    # Only quarantine RecA, not RecB → real failure.
    let q = toHashSet([RecA])
    let results = runFixture(src, q)
    require results.len == 1
    let r = results[0]

    check r.outcome == oFailed
    check r.quarantined == false        # RecB is not quarantined → real failure

    let s = summarize(results)
    check s.failed      == 1
    check s.quarantined == 0
    check exitCode(s)   == 1

suite "B4 — per-test quarantine: neither record quarantined → exit 1":

  test "no records in quarantine set → real failure, exit 1":
    let src = fixtureDir() / "protocol_two_fails.nim"
    check fileExists(src)

    let q = initHashSet[string]()   # empty quarantine
    let results = runFixture(src, q)
    require results.len == 1
    let r = results[0]

    check r.outcome == oFailed
    check r.quarantined == false

    let s = summarize(results)
    check s.failed == 1
    check exitCode(s) == 1

suite "B4 — B3 path rule still applies alongside B4":

  test "entrypoint path in quarantine → quarantined (B3 path rule unchanged)":
    let src = fixtureDir() / "protocol_two_fails.nim"
    check fileExists(src)

    # Quarantine by path (B3), NOT by test names.
    let q = toHashSet([src])
    let results = runFixture(src, q)
    require results.len == 1
    let r = results[0]

    check r.quarantined == true         # B3 path-match fired
    let s = summarize(results)
    check s.quarantined == 1
    check exitCode(s)   == 0

suite "B4 — opaque binary: per-test rule N/A without protocol records":

  test "opaque fail_always + test names in quarantine → NOT quarantined (no records)":
    ## fail_always.nim emits no protocol records (opaque). Even if test names
    ## happened to be in the quarantine set, per-test rule does not fire because
    ## there are no rsFail records. Only B3 path-match could downgrade it.
    let src = fixtureDir() / "fail_always.nim"
    check fileExists(src)

    # Quarantine some test names (irrelevant — opaque binary has no records).
    let q = toHashSet(["any test name", "another test name"])
    let results = runFixture(src, q)
    require results.len == 1
    let r = results[0]

    check r.outcome == oFailed
    check r.records.len == 0           # opaque: no records
    check r.quarantined == false        # per-test rule N/A; B3 path not matched

    let s = summarize(results)
    check s.failed == 1
    check exitCode(s) == 1

when isMainModule:
  echo "B4 per-test quarantine integration tests done."
