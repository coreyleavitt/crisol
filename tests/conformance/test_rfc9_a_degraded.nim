## test_rfc9_a_degraded.nim — RFC-0009 A-degraded, SUB-SLICE 1 tracer (D3).
##
## Proves D3 (pipeline.buildRunPlan's forced-full narrowing under a degraded
## run) end-to-end through the real product entry point (`api.runTests`),
## against a real git repository, injecting an ALWAYS-`none` fold-policy
## probe via `RunOptions.foldProbe` (RFC-0009 §3 seam). "Degraded" here means
## the fold-policy probe GENUINELY failed (D1: `Option[FoldPolicy]` `none`),
## distinct from a legitimate `fpNone` (a real case-sensitive volume) — see
## docs/rfc/0009-path-identity.md §3.
##
## ## Fixture (three entrypoints under tests/unit/)
##
##   test_a.nim — a real, deliberately FAILING test (`check false`). RUN 1
##                (the fixture-building run) records it as the lone entry in
##                the persisted lastrun.json failed set, so `--failed`
##                narrowing keys on it.
##   test_b.nim — passes on RUN 1; its content is edited (UNCOMMITTED) right
##                after, so a git diff (working tree vs HEAD) shows it
##                changed — `srOwnFileChanged` (Rule 2, narrow.nim), no
##                dep-graph closure needed.
##   test_c.nim — passes on RUN 1; NEVER touched again. Neither failed nor
##                changed — the entry that proves narrowing is non-vacuous: a
##                healthy run must EXCLUDE it; the degraded run must NOT.
##
## Narrowing requested is `failedOrChanged()` (`nkFailedOrChanged`) so BOTH
## `--failed` AND `--changed` narrowing are simultaneously live for every
## run below — proving D3 overrides both kinds at once, not just one.
##
## Two independent fixture instances (`buildFixture` called once per
## variant) so neither run's own lastrun.json persistence (`persist: false`
## anyway, but belt-and-suspenders) can cross-contaminate the other.
##
## ## SUB-SLICE 1 scope (D3, done)
##
## D7 assertion #1 (full selection under degrade, proven non-vacuous
## against a healthy control).
##
## ## SUB-SLICE 2 scope (D4, this slice)
##
## D7 assertion #2 (cache bypassed entirely — zero stores, zero reads —
## proven non-vacuous against the SAME healthy control, which DOES
## populate the cache) and assertion #5 (`configuredCache`/
## `rootInsideStateDir` fail CLOSED on a `file://` remote when fed a
## degraded `TrackedRoots`, same pole as A5c's `not populated` fail-closed
## — proven non-vacuous against the healthy control's own trackedRoots,
## which accepts a genuinely-outside remote).
##
## ## SUB-SLICE 3 scope (D5/D6, this slice)
##
## D7 assertion #3 (no depgraph persisted under degrade — `depgraph.
## saveDepGraph` short-circuits false, D5 — proven non-vacuous against the
## healthy control, whose real compiles DO persist a depgraph via
## `recordClosure`) and assertion #4 (the degraded run's `--json` evidence
## — `jsonout.toJson` over the library `RunReport`'s own `results`/
## `summary`/`trackedRoots` — carries the top-level `degraded` object with
## a non-empty `reason`, D6).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_rfc9_a_degraded.nim

import std/[json, monotimes, options, os, osproc, sequtils, tables, unittest]
import crisol/types
import crisol/paths
import crisol/api
import crisol/cacheregistry    # RFC-0009 D4: configuredCache/rootInsideStateDir fail-closed probe
import crisol/cacheport        # NilSink
import crisol/cachetelemetry   # TelemetryEvent
import crisol/config           # Config — D7 #3's depgraph-path construction
import crisol/depgraph         # depgraphPath — D7 #3
import crisol/jsonout          # toJson — D7 #4's --json degraded-evidence check

# ---------------------------------------------------------------------------
# Helpers — modeled on tests/conformance/test_rfc9_a3bii_fold_selection.nim.
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  result = getTempDir() / ("crisol_a_degraded_" & tag & "_" & $mono.ticks)
  createDir(result)

proc git(repo: string; args: string): tuple[output: string; exitCode: int] =
  execCmdEx("git " & args, workingDir = repo)

proc initRepo(repo: string) =
  discard git(repo, "init -q")
  discard git(repo, "config user.email crisol@test.local")
  discard git(repo, "config user.name crisol-test")
  discard git(repo, "config commit.gpgsign false")

proc writeF(repo, rel, content: string) =
  let p = repo / rel
  createDir(p.parentDir)
  writeFile(p, content)

const PassBody = """
import std/unittest
suite "s":
  test "ok": check true
"""

const FailBody = """
import std/unittest
suite "s":
  test "ok": check false
"""

proc alwaysNoneProbe(rootAbs, stateDir: string): Option[FoldPolicy] =
  ## The RFC-0009 A-degraded probe-injection seam (D1): a probe that ALWAYS
  ## genuinely fails, for every root, unconditionally — forcing
  ## `TrackedRoots.degraded = true` on any run it governs (D2).
  none(FoldPolicy)

proc buildFixture(tag: string): string =
  ## Builds the three-entrypoint fixture repo and runs the fixture-building
  ## RUN 1 (real facade, default/real probe, persist=true) so lastrun.json
  ## exists with exactly test_a.nim recorded failed. Then edits test_b.nim's
  ## content, uncommitted, so it shows up in a working-tree-vs-HEAD diff.
  ## Returns the repo path.
  let repo = uniqueTmpDir(tag)
  initRepo(repo)
  # .crisol/ is untracked run-state; gitignored so it never pollutes the
  # untracked-file half of gitdiff's changed-set scan.
  writeF(repo, ".gitignore", ".crisol/\n")
  writeF(repo, "tests/unit/test_a.nim", FailBody)
  writeF(repo, "tests/unit/test_b.nim", PassBody)
  writeF(repo, "tests/unit/test_c.nim", PassBody)
  discard git(repo, "add -A")
  discard git(repo, "commit -q -m initial")

  let r1 = runTests(RunOptions(startDir: repo, jobs: 1))
  check r1.status == rsOk
  check r1.summary.total == 3
  check r1.summary.failed == 1   # test_a.nim only

  # Uncommitted content edit: test_b.nim now differs from HEAD.
  writeF(repo, "tests/unit/test_b.nim", PassBody & "# edited, uncommitted\n")

  result = repo

# ---------------------------------------------------------------------------
# The tracer.
# ---------------------------------------------------------------------------

suite "RFC-0009 A-degraded — D3 forces full selection, D4 bypasses the cache, under degrade":

  test "healthy control run narrows (non-vacuous); degraded run forces full despite an identical failedOrChanged() request":
    let ctrlRepo = buildFixture("control")
    defer:
      try: removeDir(ctrlRepo)
      except OSError: discard
    let degrRepo = buildFixture("degraded")
    defer:
      try: removeDir(degrRepo)
      except OSError: discard

    # D7 #3 prep: `buildFixture`'s own RUN 1 (real probe, healthy) already
    # persisted a depgraph for each repo as a side effect of compiling the
    # fixture — deleting it here would perturb decideCompile/narrowByDiff
    # (an unknown closure force-includes its entrypoint, corrupting the D3
    # narrowing assertions above/below). Instead, SNAPSHOT each repo's
    # depgraph file content now, before the runs under test, so afterward
    # a byte-for-byte content DIFF (not mere presence) attributes any
    # change specifically to THIS test's own rControl/rDegraded invocation.
    let ctrlDepgraphPath = depgraphPath(Config(projectRoot: ctrlRepo, stateDir: ".crisol"))
    let degrDepgraphPath = depgraphPath(Config(projectRoot: degrRepo, stateDir: ".crisol"))
    require fileExists(ctrlDepgraphPath)
    require fileExists(degrDepgraphPath)
    let ctrlDepgraphBefore = readFile(ctrlDepgraphPath)
    let degrDepgraphBefore = readFile(degrDepgraphPath)

    # --- CONTROL: real/default probe (healthy), both narrowings requested ---
    let rControl = runTests(RunOptions(startDir: ctrlRepo, jobs: 1,
                                        narrowing: failedOrChanged(),
                                        persist: false,
                                        cacheStats: true))
    check rControl.status == rsOk
    check not rControl.trackedRoots.degraded
    let controlPaths = rControl.plan.entrypoints.mapIt(it.ep.path)
    echo "A-DEGRADED CONTROL selected: ", $controlPaths
    check "tests/unit/test_a.nim" in controlPaths   # via --failed
    check "tests/unit/test_b.nim" in controlPaths   # via --changed (srOwnFileChanged)
    # MANDATORY NEGATIVE CONTROL — proves the fixture is non-vacuous: a
    # healthy run genuinely narrows (excludes an entry neither criterion hits).
    check "tests/unit/test_c.nim" notin controlPaths

    # --- DEGRADED: identical narrowing request, but the probe ALWAYS fails ---
    let rDegraded = runTests(RunOptions(startDir: degrRepo, jobs: 1,
                                         narrowing: failedOrChanged(),
                                         persist: false,
                                         cacheStats: true,
                                         foldProbe: alwaysNoneProbe))
    check rDegraded.status == rsOk
    check rDegraded.trackedRoots.degraded
    check rDegraded.trackedRoots.degradedReason.len > 0
    echo "A-DEGRADED degradedReason: ", rDegraded.trackedRoots.degradedReason
    let degradedPaths = rDegraded.plan.entrypoints.mapIt(it.ep.path)
    echo "A-DEGRADED DEGRADED selected: ", $degradedPaths
    # D3: FULL selection despite BOTH --changed and --failed being requested.
    check "tests/unit/test_a.nim" in degradedPaths
    check "tests/unit/test_b.nim" in degradedPaths
    check "tests/unit/test_c.nim" in degradedPaths   # the D3 proof itself

    # -----------------------------------------------------------------
    # D7 #2 (D4, api.nim pole): the cache pipeline is bypassed ENTIRELY
    # under degrade — zero stores, zero reads. Both runs above requested
    # `cacheStats: true`, so `RunReport.cacheStats` is populated for each.
    # -----------------------------------------------------------------
    echo "A-DEGRADED CONTROL cacheStats: ", $rControl.cacheStats
    echo "A-DEGRADED DEGRADED cacheStats: ", $rDegraded.cacheStats
    # Non-vacuous: the healthy control run (same fixture shape, a real —
    # i.e. `some(...)` — probe) DOES populate the cache. `published` counts
    # every successful `putLocal` (cachedispatch.realSeams.store's
    # `tekPublish` emission fires on tier "l1" too, not only a configured
    # remote — see that proc's own doc comment), so this is exactly "l1
    # stores" for a run with no remote tier configured.
    check rControl.cacheStats.published > 0
    # The degraded run: no CacheRuntime was ever constructed (api.nim's
    # `if not opts.noCache and not cfg.trackedRoots.degraded:` gate, D4) —
    # so nothing was stored, and nothing could have been read either.
    check rDegraded.cacheStats.published == 0
    check rDegraded.cacheStats.l1Hits == 0

    # -----------------------------------------------------------------
    # D7 #5 (D4, cacheregistry.nim pole): `configuredCache`/
    # `rootInsideStateDir` fail CLOSED — reject a `file://` remote — when
    # fed a DEGRADED `TrackedRoots`, the same rejection pole A5c already
    # uses for an unpopulated one. Fed the REAL `TrackedRoots` each E2E run
    # above actually produced (not a hand-built one), closing the loop
    # end-to-end: api.nim's own gate means a degraded `runTests` call never
    # reaches `configuredCache` at all (D7 #2 already proves that), so this
    # is the defense-in-depth half of D4 — proving that even a caller which
    # DID reach `configuredCache` with this run's own degraded trackedRoots
    # could never admit the remote either.
    #
    # A remote genuinely OUTSIDE either repo's state dir isolates the
    # DEGRADED flag itself as the cause of rejection, not mere geometric
    # containment (already proven independently by A5c's own pre-existing
    # tests) — mirrors test_cachetier.nim's own
    # `test_configured_cache_degraded_trackedroots_rejects_even_an_outside_root`.
    let outsideRemote = uniqueTmpDir("d7_5_outside_remote")
    createDir(outsideRemote)
    let cfg5 = CacheConfig(remotes: @[RemoteTier(name: "mirror", url: "file://" & outsideRemote)])

    # Healthy control's REAL trackedRoots: a genuinely-outside remote is
    # ALLOWED (non-vacuous — proves the rejection below isn't simply
    # because file:// remotes never work at all).
    let rtHealthy = configuredCache(cfg5, ctrlRepo / ".crisol", maxEntries = 0,
                                    reg = productionRegistry(), secrets = CacheSecrets(),
                                    sink = NilSink[TelemetryEvent](),
                                    trackedRoots = rControl.trackedRoots)
    check rtHealthy.cache.tiers.len == 2
    check rtHealthy.cache.tiers[1].name == "mirror"

    # Degraded run's REAL trackedRoots: the SAME genuinely-outside remote is
    # REJECTED — D4's fail-closed pole.
    var rejected5 = false
    try:
      discard configuredCache(cfg5, degrRepo / ".crisol", maxEntries = 0,
                              reg = productionRegistry(), secrets = CacheSecrets(),
                              sink = NilSink[TelemetryEvent](),
                              trackedRoots = rDegraded.trackedRoots)
    except CrisolError as e:
      rejected5 = true
      check e.kind == cekConfig
    check rejected5

    # -----------------------------------------------------------------
    # D7 #3 (D5, depgraph.nim pole): NO depgraph is persisted under
    # degrade. Both runs above ran real compiles (default `runTests`, no
    # `--no-run`/dry-run): test_b.nim's uncommitted edit means BOTH runs
    # attempt at least one real recompile + `recordClosure` call, so this
    # is not a vacuous "nothing happened either way" comparison. Rather
    # than a bare fileExists/entries-count check (the depgraph file the
    # fixture-building RUN 1 already left behind, snapshotted above,
    # would make either outcome look identical), this asserts on the
    # file's byte CONTENT relative to its pre-run snapshot: the healthy
    # control run's `recordClosure` genuinely calls `saveDepGraph` and
    # rewrites the file (non-vacuous — proves the fixture and the
    # snapshot-diff technique both actually detect a real write); the
    # degraded run reaches the exact same `recordClosure` call sites, but
    # `saveDepGraph`'s own degraded short-circuit (D5) means the on-disk
    # bytes are left EXACTLY as RUN 1 wrote them — byte-identical, not
    # merely "still present".
    check fileExists(ctrlDepgraphPath)
    check readFile(ctrlDepgraphPath) != ctrlDepgraphBefore  # non-vacuous: healthy DOES rewrite it
    check fileExists(degrDepgraphPath)
    check readFile(degrDepgraphPath) == degrDepgraphBefore  # D5: degraded run wrote NOTHING at all

    # -----------------------------------------------------------------
    # D7 #4 (D6, jsonout.nim pole): the degraded run's `--json` evidence
    # carries the top-level `degraded` object with a non-empty reason.
    # This exercises the real library path (`jsonout.toJson` over the
    # `RunReport`'s own `results`/`summary`/`trackedRoots` — the same
    # values a CLI `--json` invocation would serialize) rather than
    # hand-building a JsonNode. Non-vacuous: the healthy control's own
    # report, run through the identical call, omits the key entirely.
    let controlJson = toJson(rControl.results, rControl.summary,
                              trackedRoots = rControl.trackedRoots)
    check not controlJson.hasKey("degraded")

    let degradedJson = toJson(rDegraded.results, rDegraded.summary,
                               trackedRoots = rDegraded.trackedRoots)
    require degradedJson.hasKey("degraded")
    check degradedJson["degraded"]["reason"].getStr.len > 0
    check degradedJson["degraded"]["reason"].getStr == rDegraded.trackedRoots.degradedReason

when isMainModule:
  echo "test_rfc9_a_degraded done"
