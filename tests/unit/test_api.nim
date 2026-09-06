## test_api.nim — boundary tests for crisol/api.nim (S1a–S1e, F1).
##
## Tests observable behavior through the public api surface only.
## No internal call sequences are tested.
##
## Covers (S1a):
##   - planTests() zero-opts / default-groups returns a PlanReport
##   - PlanReport entrypoints match what the default selection plans
##   - ResolvedSettings fields are populated correctly
##   - jobs / timeout overrides are reflected in settings
##   - Warnings from config are surfaced on PlanReport.warnings
##   - Selection constructors produce the correct GroupSelectionKind
##   - Narrowing constructors produce the correct NarrowingKind
##   - Structural problem (bad configPath) raises CrisolError
##   - ResultCallback type is accessible from crisol/api
##
## Covers (S1b):
##   - planTests namedGroups selects only that group's entrypoints
##   - unknown group name raises CrisolError(cekConfig)
##
## Covers (S1c):
##   - planTests failedOnly() plans only entrypoints that failed in the prior run
##   - failedOnly() that matches nothing (prior run exists) → empty plan (not structural)
##
## Covers (S1d):
##   - changedOnly("") → plans only entrypoints affected by diff vs HEAD
##   - changedOnly("ref") → plans only entrypoints affected by diff vs ref
##   - changedOnly outside a git repo → raises CrisolError(cekEnvironment)
##   - failedOrChanged → UNION; superset of each individually
##   - noNarrowing() is the default → plans everything
##
## Covers (S1e):
##   - PlanReport.warnings surfaces config warnings (explicit assertion)
##   - bad config path raises CrisolError (already in S1a; confirmed here)
##   - unknown group raises CrisolError(cekConfig) (already in S1b; confirmed here)
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_api.nim

import std/[base64, json, options, os, osproc, strutils, tables, times, unittest]
from std/posix as posix_mod import nil  # RFC-0005 code-review L2's captureStderr
                                         # only -- `import nil` so `Rusage` etc.
                                         # never collide unqualified with
                                         # crisol/process/types's own
import crisol/api
import crisol/render     # RFC-0005 code-review D1: renderCacheStats
import crisol/types
import crisol/process/types as ptypes
# RFC-0005 A3b — E2E-A-trust: runTestsWith/CacheDeps injects a real
# CacheRuntime built directly from the cache-internal modules (memory
# tiers + a controllable mock TrustPolicy) -- these are NOT part of the
# contracted `crisol/api` facade (runTestsWith/CacheDeps are themselves
# documented-uncontracted), so the test reaches past api.nim on purpose,
# exactly as this slice's own design intends.
import crisol/cacheport      # TrustPolicy, StoredEntry, Attestation, SigAlg, CacheVerdict
import crisol/cachetier      # Tier, TieredCache
import crisol/cachememory    # memory()
import crisol/cacheregistry  # CacheRuntime
import crisol/cachewire      # RFC-0005 C3b E2E-3: HttpRequest/HttpReply/HttpFetcher, jsonCacheSerializer
import crisol/cachetelemetry # NilSink
import crisol/resultcache    # RFC-0005 C4 E2E-2: payloadFromJson/canonicalPayload/cacheVersionDirAt
import crisol/fnv            # RFC-0005 C4 E2E-2: fnv1a64/toHex16 (recompute payloadChecksum by hand)
# RFC-0005 code-review SO4/SO5 -- drives runner.execute()/verifyCachePass
# directly (bypassing the planner entirely, same precedent as
# test_cachedispatch.nim's own B2a suite) so a sampled cdmHit's promoted
# stable binary can be deleted BETWEEN two execute() calls without a
# decideCompile re-plan silently self-healing it first (a full `crisol run`
# / runTests() round trip re-derives `edecision` from disk state on every
# invocation, so a deleted-then-recreated stable binary is invisible to a
# black-box CLI-level test -- this is why SO4/SO5 are exercised at this
# layer, not through runTests()).
import crisol/runner         # execute() -- drives a real run directly (no planner)
import crisol/cachedispatch  # defaultCachePolicy/cacheEnabled/keyContext/realSeams
import crisol/sandbox        # resolveSandbox
import crisol/depgraph       # emptyDepGraph, depgraphPath, loadStoredDepGraph, DepGraphDiscard
import crisol/planner        # binPath/binName -- the stable per-entrypoint binary path
import crisol/config         # loadConfig -- to derive a Config for depgraphPath/binPath
import sello                 # RFC-0005 C5a: test-only fixture construction (Seed/
                              # Keypair/PublicKey) for the real ed25519Policy E2E,
                              # same precedent as test_cdep_crypto_smoke.nim --
                              # cachetrust.nim stays the only PRODUCTION module
                              # importing sello.

# rfc-0007 A1d-i: run/v2's `outcome` (and --failed's loadLastRun narrowing,
# which reads it) is sourced from deriveOutcome(r), which walks the real
# compile/run Phase pair -- a fixture must carry a coherent Phase, not just
# the legacy `outcome` field, or every entry silently derives oSpawnError
# (Phase defaults to pkSkipped) and gets treated as failed.
proc okPhase(code: int = 0): ptypes.Phase =
  ptypes.Phase(kind: ptypes.pkRan, res: ptypes.ProcessResult(
    exit: ptypes.Exit(kind: ptypes.ekExited, code: code),
    cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: ptypes.Evidence(killDomain: ptypes.kdsProcessGroup,
                              tree: ptypes.toUnobservable,
                              hermetic: ptypes.hlIsolated),
    rusage: none(ptypes.Rusage),
    durationUs: 1000,
  ))

# Helper: import the test support module (path relative to project root)
import "../support/helpers"

# ---------------------------------------------------------------------------
# Selection constructors
# ---------------------------------------------------------------------------

suite "selection constructors":

  test "defaultGroups() → gskDefault":
    let s = defaultGroups()
    check s.kind == gskDefault

  test "namedGroups() → gskNamed with correct names":
    let s = namedGroups("unit", "integration")
    check s.kind == gskNamed
    check s.names == @["unit", "integration"]

  test "namedGroups() with zero args → gskNamed with empty names":
    let s = namedGroups()
    check s.kind == gskNamed
    check s.names.len == 0

  test "allGroups() → gskAll":
    let s = allGroups()
    check s.kind == gskAll

  test "filesSelection() → gskFiles with correct paths":
    let s = filesSelection("tests/unit/test_foo.nim", "tests/unit/test_bar.nim")
    check s.kind == gskFiles
    check s.paths == @["tests/unit/test_foo.nim", "tests/unit/test_bar.nim"]

# ---------------------------------------------------------------------------
# Narrowing constructors
# ---------------------------------------------------------------------------

suite "narrowing constructors":

  test "noNarrowing() → nkNone":
    let n = noNarrowing()
    check n.kind == nkNone
    check n.baseRef == ""

  test "failedOnly() → nkFailed":
    let n = failedOnly()
    check n.kind == nkFailed
    check n.baseRef == ""

  test "changedOnly() default baseRef → nkChanged, baseRef empty":
    let n = changedOnly()
    check n.kind == nkChanged
    check n.baseRef == ""

  test "changedOnly(baseRef) → nkChanged with ref":
    let n = changedOnly("origin/main")
    check n.kind == nkChanged
    check n.baseRef == "origin/main"

  test "failedOrChanged() → nkFailedOrChanged":
    let n = failedOrChanged()
    check n.kind == nkFailedOrChanged
    check n.baseRef == ""

  test "failedOrChanged(baseRef) → nkFailedOrChanged with ref":
    let n = failedOrChanged("HEAD~1")
    check n.kind == nkFailedOrChanged
    check n.baseRef == "HEAD~1"

# ---------------------------------------------------------------------------
# planTests — zero-opts / default-groups
# ---------------------------------------------------------------------------

suite "planTests — default-groups path":

  test "planTests with explicit minimal config → PlanReport with entrypoints field":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      # No .nim files in the fixture dir → empty entrypoints (correct discovery).
      check pr.entrypoints.len == 0
      check pr.gatedOut.len == 0

  test "planTests settings.projectRoot is set":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.settings.projectRoot == projectRoot

  test "planTests settings.stateDir is absolute and contains .crisol":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check isAbsolute(pr.settings.stateDir)
      check pr.settings.stateDir.endsWith(".crisol") or
            ".crisol" in pr.settings.stateDir

  test "planTests settings.jobs is resolved (never 0)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.settings.jobs >= 1

  test "planTests jobs override is reflected in settings.jobs":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            jobs: 7)
      let pr = planTests(opts)
      check pr.settings.jobs == 7

  test "planTests timeoutSecs override is reflected in settings.timeoutSecs":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            timeoutSecs: 42)
      let pr = planTests(opts)
      check pr.settings.timeoutSecs == 42

  test "planTests warnings from unknown config keys are surfaced":
    withTempProject:
      # Write a config with an unrecognized key.
      let kdlWithUnknown = """
group "unit" {
    globs "tests/unit/test_*.nim"
    unknown-key "hello"
}
"""
      writeFile(projectRoot / "crisol.kdl", kdlWithUnknown)
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.warnings.len >= 1
      check pr.warnings[0].key == "unknown-key"

  test "planTests PlanReport.jobs matches plan.jobs (inlined field)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            jobs: 3)
      let pr = planTests(opts)
      check pr.jobs == 3

# ---------------------------------------------------------------------------
# planTests — structural error raises CrisolError
# ---------------------------------------------------------------------------

suite "planTests — structural errors raise":

  test "bad configPath raises CrisolError":
    var raised = false
    var kind: CrisolErrorKind
    try:
      discard planTests(RunOptions(configPath: "/nonexistent/path/crisol.kdl"))
    except CrisolError as e:
      raised = true
      kind   = e.kind
    check raised
    check kind in {cekConfig, cekEnvironment}

  test "failedOnly with no prior run raises CrisolError":
    withTempProject:
      var raised = false
      try:
        discard planTests(RunOptions(
          configPath: projectRoot / "crisol.kdl",
          narrowing:  failedOnly(),
        ))
      except CrisolError:
        raised = true
      check raised

# ---------------------------------------------------------------------------
# planTests — S1b: named-group selection
# ---------------------------------------------------------------------------

suite "planTests — failedOnly() narrowing":

  test "failedOnly plans only entrypoints that failed in the prior run":
    withTempProject:
      # Place two fixture entrypoints.
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      writeFile(projectRoot / "tests" / "unit" / "test_b.nim", "echo \"ok\"\n")
      # Seed: test_a failed, test_b passed.
      let results = @[
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"), compile: okPhase(), run: okPhase(1)),
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_b.nim", group: "unit"), compile: okPhase(), run: okPhase()),
      ]
      let summary = Summary(total: 2, passed: 1, failed: 1)
      seedLastRun(projectRoot, results, summary)
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        narrowing:  failedOnly(),
      )
      let pr = planTests(opts)
      # Only test_a (the failed one) should be planned.
      check pr.entrypoints.len == 1
      check pr.entrypoints[0].ep.path == "tests/unit/test_a.nim"

  test "failedOnly with prior run but nothing failed → empty plan (not structural)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      # Seed: everything passed.
      let results = @[
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"), compile: okPhase(), run: okPhase()),
      ]
      let summary = Summary(total: 1, passed: 1)
      seedLastRun(projectRoot, results, summary)
      # Should NOT raise — empty plan is valid (rsOk territory in runTests).
      var raised = false
      var pr: PlanReport
      try:
        pr = planTests(RunOptions(
          configPath: projectRoot / "crisol.kdl",
          narrowing:  failedOnly(),
        ))
      except CrisolError:
        raised = true
      check not raised
      check pr.entrypoints.len == 0

suite "planTests — changedOnly / failedOrChanged narrowing":

  test "changedOnly outside a git repo raises CrisolError(cekEnvironment)":
    withTempProject:
      # withTempProject does NOT init a git repo, so changedFiles will raise.
      var raised = false
      var kind: CrisolErrorKind
      try:
        discard planTests(RunOptions(
          configPath: projectRoot / "crisol.kdl",
          narrowing:  changedOnly(),
        ))
      except CrisolError as e:
        raised = true
        kind = e.kind
      check raised
      check kind == cekEnvironment

  test "changedOnly in a git repo returns a PlanReport without raising":
    withTempGitProject:
      # Place an entrypoint in the fixture repo and commit it.
      let testA = gitRoot / "tests" / "unit" / "test_a.nim"
      writeFile(testA, "echo \"ok\"\n")
      discard execCmdEx("git add -A", workingDir = gitRoot)
      discard execCmdEx("git commit -m init", workingDir = gitRoot)
      # Working-tree modification so diff is non-empty.
      writeFile(testA, "echo \"changed\"\n")
      var raised = false
      var pr: PlanReport
      try:
        pr = planTests(RunOptions(
          configPath: gitRoot / "crisol.kdl",
          narrowing:  changedOnly(),
        ))
      except CrisolError:
        raised = true
      # changedOnly in a git repo must not raise; plan is returned.
      check not raised
      # The changed entrypoint must appear in the plan (dep graph absent →
      # conservative: all discovered entrypoints are included).
      check pr.entrypoints.len >= 1

  test "changedOnly with baseRef diffs against that commit":
    withTempGitProject:
      let testA = gitRoot / "tests" / "unit" / "test_a.nim"
      writeFile(testA, "echo \"v1\"\n")
      discard execCmdEx("git add -A", workingDir = gitRoot)
      discard execCmdEx("git commit -m v1", workingDir = gitRoot)
      let (ref1, _) = execCmdEx("git rev-parse HEAD", workingDir = gitRoot)
      let baseRef = ref1.strip()
      # Second commit: change test_a.
      writeFile(testA, "echo \"v2\"\n")
      discard execCmdEx("git add -A", workingDir = gitRoot)
      discard execCmdEx("git commit -m v2", workingDir = gitRoot)
      let opts = RunOptions(
        configPath: gitRoot / "crisol.kdl",
        narrowing:  changedOnly(baseRef),
      )
      let pr = planTests(opts)
      check pr.entrypoints.len == 1
      check "test_a.nim" in pr.entrypoints[0].ep.path

  test "noNarrowing plans all entrypoints (regression)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      writeFile(projectRoot / "tests" / "unit" / "test_b.nim", "echo \"ok\"\n")
      let pr = planTests(RunOptions(
        configPath: projectRoot / "crisol.kdl",
        narrowing:  noNarrowing(),
      ))
      check pr.entrypoints.len == 2

  test "failedOrChanged is superset of failedOnly individually":
    withTempGitProject:
      let testA = gitRoot / "tests" / "unit" / "test_a.nim"
      let testB = gitRoot / "tests" / "unit" / "test_b.nim"
      writeFile(testA, "echo \"ok\"\n")
      writeFile(testB, "echo \"ok\"\n")
      discard execCmdEx("git add -A", workingDir = gitRoot)
      discard execCmdEx("git commit -m init", workingDir = gitRoot)
      # Seed: only test_b failed; test_a passed.
      let results = @[
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"), compile: okPhase(), run: okPhase()),
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_b.nim", group: "unit"), compile: okPhase(), run: okPhase(1)),
      ]
      seedLastRun(gitRoot, results, Summary(total: 2, passed: 1, failed: 1))
      # failedOnly → test_b only (1 entrypoint).
      let prFailed = planTests(RunOptions(
        configPath: gitRoot / "crisol.kdl",
        narrowing:  failedOnly(),
      ))
      # failedOrChanged → UNION of failed + changed (all when graph absent).
      let prUnion = planTests(RunOptions(
        configPath: gitRoot / "crisol.kdl",
        narrowing:  failedOrChanged(),
      ))
      check prFailed.entrypoints.len == 1
      # Union must be at least as wide as failedOnly.
      check prUnion.entrypoints.len >= prFailed.entrypoints.len

suite "planTests — named-group selection":

  test "namedGroups selects only that group (entrypoints have that group name)":
    withTempProject:
      # Write a two-group config so we can verify group selection.
      let twoGroupKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
group "integration" {
    globs "tests/integration/test_*.nim"
}
"""
      writeFile(projectRoot / "crisol.kdl", twoGroupKdl)
      # Create both dirs so discover() doesn't error.
      createDir(projectRoot / "tests" / "integration")
      # Place a fixture .nim in each dir so discovery finds real entrypoints.
      writeFile(projectRoot / "tests" / "unit" / "test_u.nim",
                "echo \"ok\"\n")
      writeFile(projectRoot / "tests" / "integration" / "test_i.nim",
                "echo \"ok\"\n")
      let opts = RunOptions(
        configPath: projectRoot / "crisol.kdl",
        selection:  namedGroups("unit"),
      )
      let pr = planTests(opts)
      # All planned entrypoints must belong to the "unit" group.
      check pr.entrypoints.len == 1
      for pep in pr.entrypoints:
        check pep.ep.group == "unit"

  test "unknown group name raises CrisolError(cekConfig)":
    withTempProject:
      var raised = false
      var kind: CrisolErrorKind
      try:
        discard planTests(RunOptions(
          configPath: projectRoot / "crisol.kdl",
          selection:  namedGroups("nonexistent"),
        ))
      except CrisolError as e:
        raised = true
        kind = e.kind
      check raised
      check kind == cekConfig

# ---------------------------------------------------------------------------
# planTests — S1e: warnings and structural raises
# ---------------------------------------------------------------------------

suite "planTests — S1e warnings and structural raises":

  test "PlanReport.warnings surfaces unknown config key (explicit S1e assertion)":
    withTempProject:
      let kdlWithUnknown = """
group "unit" {
    globs "tests/unit/test_*.nim"
    totally-unknown-key "ignored"
}
"""
      writeFile(projectRoot / "crisol.kdl", kdlWithUnknown)
      let pr = planTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      check pr.warnings.len >= 1
      check pr.warnings[0].key == "totally-unknown-key"

  test "KDL parse error raises CrisolError(cekConfig)":
    withTempProject:
      # Write syntactically invalid KDL.
      writeFile(projectRoot / "crisol.kdl", "group {{{ BAD KDL !!!")
      var raised = false
      var kind: CrisolErrorKind
      try:
        discard planTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      except CrisolError as e:
        raised = true
        kind = e.kind
      check raised
      check kind == cekConfig

  test "bad configPath raises CrisolError with cekConfig or cekEnvironment (S1e confirm)":
    var raised = false
    var kind: CrisolErrorKind
    try:
      discard planTests(RunOptions(configPath: "/no/such/path/crisol.kdl"))
    except CrisolError as e:
      raised = true
      kind = e.kind
    check raised
    check kind in {cekConfig, cekEnvironment}

  test "unknown group name raises CrisolError(cekConfig) (S1e confirm)":
    withTempProject:
      var raised = false
      var kind: CrisolErrorKind
      try:
        discard planTests(RunOptions(
          configPath: projectRoot / "crisol.kdl",
          selection:  namedGroups("no-such-group"),
        ))
      except CrisolError as e:
        raised = true
        kind = e.kind
      check raised
      check kind == cekConfig

# ---------------------------------------------------------------------------
# ResultCallback type accessibility
# ---------------------------------------------------------------------------

suite "api type surface":

  test "ResultCallback type is accessible from crisol/api":
    # A proc that accepts the callback type should compile.
    proc acceptCb(cb: ResultCallback) = discard
    proc myCallback(r: EntrypointResult) = discard
    acceptCb(myCallback)  # must compile; type is exported

  test "RunOptions default-constructs without error":
    let o = RunOptions()
    check o.configPath == ""
    check o.startDir   == ""
    check o.jobs       == 0
    check o.failFast   == false
    check o.narrowing.kind == nkNone

  test "RunReport and PlanReport types exist and default-construct":
    let pr = PlanReport()
    let rr = RunReport()
    check pr.entrypoints.len == 0
    check rr.status == rsOk

# ---------------------------------------------------------------------------
# rfc-0007 A1c: runResult / failureLine digest helpers over a real Phase
# ---------------------------------------------------------------------------

suite "rfc-0007 A1c — runResult / failureLine over a captured run phase":
  test "runResult(r): some(ProcessResult) for a live run (pkRan)":
    var r = EntrypointResult(ep: Entrypoint(path: "t.nim", group: "unit"))
    r.compile = Phase(kind: pkSkipped)
    r.run = Phase(kind: pkRan, res: ProcessResult(
      exit: Exit(kind: ekSignaled, sig: 11, coreDumped: false),
      cause: Cause(by: cbProcess),
      evidence: Evidence(),
      rusage: none(Rusage),
      durationUs: 1000,
    ))
    let rr = runResult(r)
    check rr.isSome
    check rr.get.exit.sig == 11
    check failureLine(r) == "crashed: SIGSEGV"

  test "failureLine 'killed: ...' for a runner-authored kill (cause.by == cbRunner)":
    var r = EntrypointResult(ep: Entrypoint(path: "t.nim", group: "unit"))
    r.compile = Phase(kind: pkSkipped)
    r.run = Phase(kind: pkRan, res: ProcessResult(
      exit: Exit(kind: ekSignaled, sig: 15, coreDumped: false),
      cause: Cause(by: cbRunner, reason: krTimeout, escalated: false),
      evidence: Evidence(),
      rusage: none(Rusage),
      durationUs: 1000,
    ))
    check runResult(r).isSome
    check failureLine(r) == "killed: runner timeout"

  test "failureLine(r) == \"\" for a passing result":
    var r = EntrypointResult(ep: Entrypoint(path: "t.nim", group: "unit"))
    r.compile = Phase(kind: pkSkipped)
    r.run = Phase(kind: pkRan, res: ProcessResult(
      exit: Exit(kind: ekExited, code: 0),
      cause: Cause(by: cbProcess),
      evidence: Evidence(),
      rusage: none(Rusage),
      durationUs: 1000,
    ))
    check failureLine(r) == ""

# ---------------------------------------------------------------------------
# Nim-version soundness seam (High finding): api MUST supply a REAL Nim
# version, never "".  A "" version makes the depgraph staleness check and the
# soundness-key nimVersion component both no-ops, so a Nim compiler upgrade
# does not invalidate stale binaries or stale cached results.
# ---------------------------------------------------------------------------

suite "nim-version soundness seam":
  test "api exposes a real Nim version (not the empty-string no-op)":
    # The version threaded into buildRunPlan/loadDepGraph/plan/execute/realSeams
    # must fingerprint the compiler.  It is sourced from system.NimVersion.
    check crisolNimVersion.len > 0
    check crisolNimVersion != ""
    check crisolNimVersion == NimVersion
    # Sanity: looks like a dotted version (e.g. "2.2.0").
    check '.' in crisolNimVersion

# ---------------------------------------------------------------------------
# R13 (code review, RFC-0006) — an explicit --measure-compile-reuse request
# that will silently degrade to the monolithic compile path (no workerBinary
# configured) must be visible in the STRUCTURED warnings channel, not just
# runner.nim's one-shot stderr write. A CI consumer whose stderr is
# swallowed would otherwise see a complete, silent no-op of a feature it
# explicitly asked for -- compileBlock simply absent from the report,
# indistinguishable from "nobody asked".
# ---------------------------------------------------------------------------

suite "R13 — measure-compile-reuse requested with no workerBinary surfaces a structured warning":

  test "planTests: measureCompileReuse=true, workerBinary unset -> structured warning (context=measure-compile-reuse, key=workerBinary)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            measureCompileReuse: true)
      let pr = planTests(opts)
      var found = false
      for w in pr.warnings:
        if w.context == "measure-compile-reuse" and w.key == "workerBinary":
          found = true
      check found

  test "planTests: workerBinary SET -> no workerBinary warning (sound path, nothing to warn about)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            measureCompileReuse: true, workerBinary: "/usr/bin/true")
      let pr = planTests(opts)
      for w in pr.warnings:
        check w.key != "workerBinary"

  test "planTests: measureCompileReuse not requested, workerBinary unset -> no workerBinary warning at all":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      for w in pr.warnings:
        check w.key != "workerBinary"

  test "runTests: measureCompileReuse=true, workerBinary unset -> run still succeeds monolithically AND the warning is present on RunReport.plan.warnings":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            measureCompileReuse: true)
      let rr = runTests(opts)
      check rr.status == rsOk
      check rr.exitCode == 0
      check rr.results.len == 1
      check rr.results[0].outcome == oPassed
      var found = false
      for w in rr.plan.warnings:
        if w.context == "measure-compile-reuse" and w.key == "workerBinary":
          found = true
      check found

# ---------------------------------------------------------------------------
# rfc-0007 A6b — --strict-hygiene / strict-hygiene config parity + precedence
# ---------------------------------------------------------------------------

suite "rfc-0007 A6b — strict-hygiene resolution (RunOptions.strictHygiene x config)":

  test "opts.strictHygiene=true (config absent) -> resolved settings.strictHygiene == true":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", strictHygiene: true)
      let pr = planTests(opts)
      check pr.settings.strictHygiene == true

  test "config strict-hygiene #true, opts.strictHygiene=false -> STILL true (config wins; strengthen-only)":
    withTempProject:
      writeFile(projectRoot / "crisol.kdl", """
strict-hygiene #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", strictHygiene: false)
      let pr = planTests(opts)
      check pr.settings.strictHygiene == true

  test "neither opts nor config set -> resolved settings.strictHygiene == false (default off)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.settings.strictHygiene == false

# ---------------------------------------------------------------------------
# RFC-0005 B1c — --explain-miss / explain-miss config parity + precedence
# ---------------------------------------------------------------------------

suite "RFC-0005 B1c — explain-miss resolution (RunOptions.explainMiss x config)":

  test "opts.explainMiss=true (config absent) -> resolved settings.explainMiss == true":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", explainMiss: true)
      let pr = planTests(opts)
      check pr.settings.explainMiss == true

  test "config explain-miss #true, opts.explainMiss=false -> STILL true (config wins; strengthen-only)":
    withTempProject:
      writeFile(projectRoot / "crisol.kdl", """
explain-miss #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", explainMiss: false)
      let pr = planTests(opts)
      check pr.settings.explainMiss == true

  test "neither opts nor config set -> resolved settings.explainMiss == false (default off)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.settings.explainMiss == false

  test "--explain-miss-verbose (CLI-only, no KDL key) resolves via opts.explainMiss OR'd in by the caller":
    ## explainMissVerbose has no KDL key of its own (RFC's config-additions
    ## list omits it); the CLI resolves "verbose implies explain" BEFORE
    ## building RunOptions (opts.explainMiss = flag OR verboseFlag), so a
    ## library caller reproduces the same behavior by setting explainMiss
    ## itself when it wants verbose. This test pins that explainMissVerbose
    ## alone (with explainMiss left false) does NOT retroactively resolve
    ## settings.explainMiss -- planImpl only ever reads opts.explainMiss.
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            explainMiss: false, explainMissVerbose: true)
      let pr = planTests(opts)
      check pr.settings.explainMiss == false

# ---------------------------------------------------------------------------
# RFC-0005 B2b — --cache-stats / cache-stats config parity + precedence
# ---------------------------------------------------------------------------

suite "RFC-0005 B2b — cache-stats resolution (RunOptions.cacheStats x config)":

  test "opts.cacheStats=true (config absent) -> resolved settings.cacheStats == true":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let pr = planTests(opts)
      check pr.settings.cacheStats == true

  test "config cache-stats #true, opts.cacheStats=false -> STILL true (config wins; strengthen-only)":
    withTempProject:
      writeFile(projectRoot / "crisol.kdl", """
cache-stats #true
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: false)
      let pr = planTests(opts)
      check pr.settings.cacheStats == true

  test "neither opts nor config set -> resolved settings.cacheStats == false (default off)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      check pr.settings.cacheStats == false

suite "RunReport.cacheStats — RFC-0005 B2b end-to-end (real runTests, no CLI)":

  test "cacheStats not requested -> RunReport.cacheStats is the zero value (no sink installed)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      check rr.status == rsOk
      check rr.cacheStats.total == 0
      check rr.cacheStats.l1Hits == 0
      check rr.cacheStats.hitPct == 0.0

  test "cacheStats requested, cold run -> a genuine miss (misses > 0, hitPct 0.0)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true))
      check rr.status == rsOk
      check rr.cacheStats.misses > 0
      check rr.cacheStats.l1Hits == 0
      check rr.cacheStats.hitPct == 0.0

  test "cacheStats requested, warm rerun -> a genuine hit (hits > 0, hitPct > 0)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      discard runTests(RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true))
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true))
      check rr.status == rsOk
      check rr.cacheStats.l1Hits > 0
      check rr.cacheStats.hitPct > 0.0

# ---------------------------------------------------------------------------
# RFC-0005 code-review L2: the RFC-pinned UNCONDITIONAL per-tier 100%-error/
# breaker stderr warning must fire on a DEFAULT run too, not only under
# --cache-stats (the sole erroredTiers caller was gated behind
# `if statsSink != nil`, which is nil unless --cache-stats is on).
# ---------------------------------------------------------------------------

proc alwaysOfflineBackend(): CacheBackend =
  ## Every `get`/`put` transport-fails (cvOffline) -- a minimal double for
  ## forcing the per-tier 100%-error diagnostic without any real filesystem
  ## fault (mirrors test_cachedispatch.nim's own `offlinePutBackend`,
  ## extended to `get` since this diagnostic is READ-side, `cachetelemetry.
  ## erroredTiers`'s own scope note).
  CacheBackend(
    scheme: "test-always-offline",
    get:  proc(key: SoundnessKey): Fetched[StoredEntry] = Fetched[StoredEntry](verdict: cvOffline),
    put:  proc(entry: StoredEntry): CacheVerdict = cvOffline,
    probe: nil,
  )

proc offlineTierDeps(): CacheDeps =
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int): CacheRuntime =
    discard cfg; discard stateDir; discard maxEntries
    CacheRuntime(
      cache: TieredCache(
        tiers: @[Tier(name: "l1", backend: alwaysOfflineBackend(), backfillOnHit: false, verifyTrust: false)],
        trust: nonePolicy(),
      ),
      sink: NilSink[TelemetryEvent](),
    ))

proc captureStderr(body: proc()): string =
  ## fd-level stderr redirect (mirrors test_b2b_cache_stats_cli.nim's own
  ## `captureBoth`) -- works regardless of whether the write goes through
  ## Nim's `stderr` object or a lower-level handle, since it swaps the real
  ## OS file descriptor 2, not a Nim-level reference.
  let tag = $getCurrentProcessId() & "_" & $epochTime().int64
  let errPath = getTempDir() / ("crisol_l2_err_" & tag & ".txt")
  let errF = open(errPath, fmWrite)
  let errFd: cint = errF.getFileHandle.cint
  let savedErrFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(errFd, 2.cint)
  errF.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod.dup2(savedErrFd, 2.cint)
    discard posix_mod.close(savedErrFd)
  result = readFile(errPath)
  try: removeFile(errPath) except CatchableError: discard

suite "RFC-0005 code-review L2 — unconditional per-tier 100%-error warning":

  test "default run (cacheStats off), always-offline l1 -> stderr carries the warning":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      var rr: RunReport
      let errText = captureStderr(proc() = rr = runTestsWith(opts, offlineTierDeps()))
      check rr.status == rsOk
      check "cache tier 'l1' errored on every consulted read this run" in errText

  test "--cache-stats on, always-offline l1 -> warning present exactly once (no dup)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      var rr: RunReport
      let errText = captureStderr(proc() = rr = runTestsWith(opts, offlineTierDeps()))
      check rr.status == rsOk
      check errText.count("cache tier 'l1' errored on every consulted read this run") == 1

  test "healthy tier -> no per-tier warning":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      var rr: RunReport
      let errText = captureStderr(proc() = rr = runTestsWith(opts, productionCacheDeps()))
      check rr.status == rsOk
      check "errored on every consulted read" notin errText

# ---------------------------------------------------------------------------
# RFC-0005 code-review D1: a LOCAL ("l1") put failure must never be folded
# into remoteErrors/"N remote-errors" -- it goes to the new, additive
# `localErrors` count instead (`cachetelemetry.CacheStats.localErrors`,
# run/v2 rev 22). Reuses `offlineTierDeps()`/`alwaysOfflineBackend()` from
# the L2 suite above: a single-tier ("l1"-only, zero remote configured)
# runtime whose every get/put transport-fails.
# ---------------------------------------------------------------------------

suite "RFC-0005 code-review D1 — local (l1) put failures count as localErrors, not remoteErrors":

  test "local-only run, forced l1 put failure -> cacheStats.localErrors == 1, remoteErrors == 0":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let rr = runTestsWith(opts, offlineTierDeps())
      check rr.status == rsOk
      check rr.cacheStats.localErrors == 1
      check rr.cacheStats.remoteErrors == 0

      # Wire-level assertion (not just the in-process struct): the run/v2
      # JSON `cacheStats` object under --cache-stats.
      let node = parseJson(toJsonString(rr.results, rr.summary,
                                        cacheStats = rr.cacheStats, showCacheStats = true))
      check node["cacheStats"]["localErrors"].getInt == 1
      check node["cacheStats"]["remoteErrors"].getInt == 0

      # Human-render: "N local-errors" appears, distinct from remote-errors.
      let line = renderCacheStats(rr.cacheStats)
      check "1 local-errors" in line
      check "0 remote-errors" in line

# ---------------------------------------------------------------------------
# RFC-0005 code-review SO4 — a verify re-execution that never produced an
# observation (its promoted stable binary vanished between the main run
# and the verify sub-run) must be reported as "could not re-execute", a
# category DISTINCT from a divergence -- never counted toward
# `verifyDivergences` (so --verify-cache-strict, which gates on
# `verifyDivergences.len`, never trips for it), never silent (a stderr
# warning still names the entrypoint).
#
# Driven via `runner.execute()` + the public `verifyCachePass()` facade
# directly (crisol/cachedispatch's real `localOnlyCache`/`realSeams`, same
# precedent as test_cachedispatch.nim's own B2a suite), bypassing the
# planner (`decideCompile`) entirely -- a full `crisol run` / `runTests()`
# round trip re-derives `edecision` fresh from ON-DISK state on every
# invocation, so deleting a stable binary BETWEEN two separate `runTests()`
# calls gets silently "healed" by a real recompile + post-compile-consult
# re-promotion before the verify pass ever runs (empirically confirmed
# while writing this test). Going through `execute()` directly sidesteps
# this entirely: `PlannedEntrypoint.edecision` is a value THIS TEST sets
# once, immune to any disk-state re-derivation, so deleting the stable
# binary after run 2's cdmHit is exactly the TOCTOU this fix defends
# against, reproduced deterministically.
# ---------------------------------------------------------------------------

suite "RFC-0005 code-review SO4 — verify-cache could-not-reexec is never a divergence":

  test "sampled hit whose promoted stable binary is missing at verify-sub-run time":
    let dir = getTempDir() / ("crisol_so4_couldnotreexec_" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let epPath = dir / "test_pass.nim"
    writeFile(epPath, "quit(0)\n")

    let cfg = Config(projectRoot: dir, stateDir: ".crisol",
                     compileTimeoutSecs: 120, timeoutSecs: 60)
    let spec = sandbox.resolveSandbox(ptypes.hlIsolated)
    var g = emptyDepGraph()
    let rt = localOnlyCache(dir / ".crisol", maxEntries = 0)
    let ctx = keyContext(nimVersion = "2.2.10", ccVersion = "gcc 13.2.0", spec = spec,
                         parentEnv = @[("HOME", "/root")], protocolMajor = 1)

    # Run 1: edNeverBuilt -- compiles + runs live, stores via the real cache
    # (also promotes the stable binary + records its closure into `g`).
    let pep1 = PlannedEntrypoint(ep: Entrypoint(path: epPath, group: "unit", flags: @[]),
                                 edecision: edNeverBuilt, runTimeoutMs: 60_000)
    let results1 = execute(
      RunPlan(entrypoints: @[pep1], jobs: 1), config = cfg, graph = g, showProgress = false,
      cache = cacheEnabled(spec, defaultCachePolicy(), realSeams(ctx, addr g, rt)))
    check results1.len == 1
    check results1[0].cacheDecision == cdmStored

    # Run 2: edRunFresh -- `g` now has epPath's closureHash, so lookupAtPlan
    # derives the SAME key -> cdmHit (a plan-time hit; no fresh execution,
    # no touching of the stable binary either way).
    let pep2 = PlannedEntrypoint(ep: Entrypoint(path: epPath, group: "unit", flags: @[]),
                                 edecision: edRunFresh, runTimeoutMs: 60_000)
    let results2 = execute(
      RunPlan(entrypoints: @[pep2], jobs: 1), config = cfg, graph = g, showProgress = false,
      cache = cacheEnabled(spec, defaultCachePolicy(), realSeams(ctx, addr g, rt)))
    check results2.len == 1
    check results2[0].cacheDecision == cdmHit

    # Delete the promoted STABLE binary the verify sub-run's spawnRunDirect
    # needs to reuse (SO5's fix) -- the CACHE's own stored blob (which run
    # 2's cdmHit synthesis read) is untouched; only the per-entrypoint
    # stable path is gone.
    let stableBin = binPath(pep2.ep, cfg) / binName(pep2.ep)
    check fileExists(stableBin)
    removeFile(stableBin)

    # The verify pass: buildVerifyPlan forces edRunFresh (SO5) -> dispatch
    # tries spawnRunDirect -> the binary is gone -> pkSpawnFailed -> SO4's
    # distinct category.
    var divergences: seq[VerifyDivergence]
    let errText = captureStderr(proc () =
      divergences = verifyCachePass(
        results2, @[pep2], verifySample(pct = 100), cfg, g,
        "2.2.10", "gcc 13.2.0", spec))

    check divergences.len == 0   # SO4: never misfiled as a divergence
    check epPath in errText
    check "could not re-execute" in errText.toLowerAscii
    # Never ALSO reported via the divergence wording ("--verify-cache
    # divergence for ... diverged from the cached result") -- distinct
    # from the could-not-reexec message's own use of the word
    # "divergence" (as in "not counted as a divergence").
    check "--verify-cache divergence for" notin errText
    check "diverged from the cached result" notin errText

# ---------------------------------------------------------------------------
# RFC-0005 A3b — runTestsWith / CacheDeps: the internal injection seam.
# ---------------------------------------------------------------------------

suite "runTestsWith / CacheDeps — production parity":

  test "runTests(opts) == runTestsWith(opts, productionCacheDeps()) in observable outcome":
    ## runTests is now a thin wrapper -- prove the delegation is real, not
    ## a second, silently-diverging code path.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let rr = runTestsWith(opts, productionCacheDeps())
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmStored

  test "productionCacheDeps().buildRuntime scrubs $CRISOL_CACHE_TOKEN[_<TIER>] from the process env (RFC-0005 C6/D5)":
    ## Mirrors the existing hmac/sign-key scrub proofs (E2E-2, below) for
    ## the bearer-token vars specifically: `resolveCacheSecrets` (api.nim)
    ## captures BOTH the bare and suffixed forms, then delEnv's the whole
    ## `CRISOL_CACHE_*` namespace unconditionally. No remote-cache tier is
    ## configured here, so `configuredCache` never resolves a backend and
    ## no real socket is ever touched -- this proves only the env
    ## capture-then-scrub half.
    ##
    ## RFC-0005 code-review D5: `resolveCacheSecrets()` now runs LAZILY,
    ## inside the closure `buildRuntime` returns -- calling
    ## `productionCacheDeps()` alone (as this test did before D5) no longer
    ## touches the environment at all; the scrub only happens once
    ## `buildRuntime` is actually invoked (which `runTestsWith` only does
    ## when `not opts.noCache` -- see the D5 suite below for the
    ## `noCache:true` half of this proof).
    putEnv("CRISOL_CACHE_TOKEN", "should-be-scrubbed")
    putEnv("CRISOL_CACHE_TOKEN_MIRROR", "should-also-be-scrubbed")
    defer:
      delEnv("CRISOL_CACHE_TOKEN")
      delEnv("CRISOL_CACHE_TOKEN_MIRROR")
    let deps = productionCacheDeps()
    discard deps.buildRuntime(CacheConfig(), getTempDir() / "crisol_d5_scrub_state", 0)
    check getEnv("CRISOL_CACHE_TOKEN") == ""
    check getEnv("CRISOL_CACHE_TOKEN_MIRROR") == ""

# ---------------------------------------------------------------------------
# RFC-0005 code-review D5: `runTests()` eagerly called `productionCacheDeps()`
# -> `resolveCacheSecrets()` (a scan + delEnv of the WHOLE CRISOL_CACHE_*
# namespace) even under `noCache: true` -- an undocumented host-process
# mutation for a library embedder that asked for NO caching at all. Fixed
# by moving the resolution inside `buildRuntime`'s own closure (see the
# test immediately above), which `runTestsWith` only ever calls when `not
# opts.noCache`.
# ---------------------------------------------------------------------------

suite "RFC-0005 code-review D5 — no env mutation under opts.noCache":

  test "noCache: true -> CRISOL_CACHE_* env is left untouched":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      putEnv("CRISOL_CACHE_TOKEN", "must-survive-noCache")
      defer: delEnv("CRISOL_CACHE_TOKEN")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl", noCache: true))
      check rr.status == rsOk
      check getEnv("CRISOL_CACHE_TOKEN") == "must-survive-noCache"

  test "cache-enabled (default, noCache: false) -> CRISOL_CACHE_* env IS scrubbed (existing behavior, pinned)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      putEnv("CRISOL_CACHE_TOKEN", "should-be-scrubbed-cache-on")
      defer: delEnv("CRISOL_CACHE_TOKEN")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      check rr.status == rsOk
      check getEnv("CRISOL_CACHE_TOKEN") == ""

# ---------------------------------------------------------------------------
# RFC-0005 A3b — E2E-A-trust (RFC §Definition of done, verbatim): two
# `memory` tiers via `runTestsWith`, a mock `TrustPolicy` returning
# `cvTrustBadSignature` ⇒ live execution, `cacheLookup == "trustBadSignature"`,
# `cacheDecision == cdmStored`, the rejected entry never served.
#
# End-to-end through the REAL entry path (runTestsWith -> planImpl -> execute
# -> the hit/live stamps -> jsonout render), not a unit test of TieredCache
# or the mock policy in isolation (those are test_cachetier.nim's job).
# ---------------------------------------------------------------------------

suite "RFC-0005 A3b — E2E-A-trust: runTestsWith, two memory tiers + mock TrustPolicy":

  proc mockRejectPolicy(): TrustPolicy =
    ## `sign` always attaches an Attestation (so a fresh store's put rule
    ## accepts on BOTH verifyTrust tiers -- warming the cache); `verify`
    ## ALWAYS rejects (cvTrustBadSignature), so nothing stored under this
    ## policy can ever be served back -- the security-meaningful case
    ## `nonePolicy` cannot exercise (A3a's own rationale for the mock).
    TrustPolicy(
      name: "mock-reject",
      verify: proc(entry: StoredEntry): CacheVerdict = cvTrustBadSignature,
      sign: proc(entry: var StoredEntry) =
        entry.attestation = some(Attestation(sigAlg: saHmacSha256, signer: "mock-signer",
                                              signature: "sig", signedAt: 0)),
    )

  test "trust-rejected entry on both tiers -> live execution, cacheLookup trustBadSignature, cacheDecision stored, never served":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
      let l1 = memory()
      let l2 = memory()
      let deps = CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int): CacheRuntime =
        discard cfg; discard stateDir; discard maxEntries
        CacheRuntime(
          cache: TieredCache(
            tiers: @[
              Tier(name: "l1", backend: l1, backfillOnHit: false, verifyTrust: true),
              Tier(name: "l2", backend: l2, backfillOnHit: false, verifyTrust: true),
            ],
            trust: mockRejectPolicy(),
          ),
          sink: NilSink[TelemetryEvent](),
        ))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")

      # First call: both memory tiers start empty -> genuine miss -> live
      # run -> shouldStore publishes (sign attaches an attestation, so the
      # put rule accepts on both verifyTrust tiers) -- warms both tiers'
      # backing Tables (which persist across calls: `deps` closes over the
      # SAME `l1`/`l2` backend values on every call).
      let rr1 = runTestsWith(opts, deps)
      check rr1.status == rsOk
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      # First-ever compile: the entrypoint is edNeverBuilt at plan time, not
      # edRunFresh -- lookupAtPlan's OWN plan-time gate never runs a real
      # consult for it (no binary exists yet to serve from cache). But
      # RFC-0005 A2c-ii adds a SECOND real consult, post-compile, for
      # exactly this case (finalizeSlot's consultPostCompile, right after
      # THIS compile finishes) -- both memory tiers are still genuinely
      # empty at that instant (this is the very first store), so it is a
      # real, consulted MISS, not the "never consulted" degenerate default.
      check rr1.results[0].cacheLookup == cvMiss

      # Second call: SAME backends, SAME mock policy -- `verify` now
      # rejects the entry on EVERY consulted tier, so the waterfall finds
      # nothing servable and the entrypoint reruns live.
      let rr2 = runTestsWith(opts, deps)
      check rr2.status == rsOk
      check rr2.results.len == 1
      let r2 = rr2.results[0]
      check r2.cacheDecision == cdmStored          # the live rerun re-publishes (self-healing)
      check r2.cacheLookup == cvTrustBadSignature
      check r2.cacheTier == ""                     # never served from any tier
      check r2.run.kind == ptypes.pkRan            # a genuine LIVE run, not a cache replay

      # Wire-level assertion (RFC's own DoD wording, verbatim): the run/v2
      # render, not just the in-process EntrypointResult.
      let node = parseJson(toJsonString(rr2.results, rr2.summary))
      let epNode = node["entrypoints"][0]
      check epNode["cacheLookup"].getStr == "trustBadSignature"
      check epNode["cacheDecision"].getStr == "stored"

# ---------------------------------------------------------------------------
# RFC-0005 A3c-ii — E2E-1: `configuredCache` wired live through the REAL
# entry path (runTests -> planImpl -> configuredCache -> execute), driven by
# a REAL crisol.kdl `remote-cache "<name>" { url "file://..." }` block —
# not a hand-built CacheDeps override (E2E-A-trust's job, above).
#
# Scoping (RFC's own FORK-2 note, "E2E-1 (two-tier file://; lands in A3c —
# form depends on FORK-2)"): FORK-2 resolved (a) — the FULL cold-host
# three-run sequence needs A2c's post-compile consult, which is NOT this
# slice (A2c lands after A3c-ii; see the RFC's own stage list). What DOES
# land here, for real, through this exact entry path:
#   1. the offline variant (verbatim from the RFC, FORK-independent):
#      url -> a plain FILE at the path -> ENOTDIR -> run proceeds live,
#      cacheLookup == "offline", the per-tier 100%-error stat is nonzero.
#   2. a genuine two-tier file:// flow that already works TODAY (warm
#      binary + depgraph, only l1 wiped): a remote hit backfills l1 and
#      serves — proving configuredCache's wiring is live end to end.
#   3. the deferred-put flush: run 1's remote tier receives its entry only
#      by END of run (the join point), never inline during dispatch.
# ---------------------------------------------------------------------------

proc remoteHasAnyEntry(root: string): bool =
  if not dirExists(root): return false
  for f in walkDirRec(root):
    if f.endsWith(".json"): return true
  false

proc anyFileUnder(root: string): bool =
  ## Generic version of remoteHasAnyEntry for directories whose entries are
  ## not `.json` (e.g. `<stateDir>/bin/<slug>/<binName>`).
  if not dirExists(root): return false
  for f in walkDirRec(root):
    if fileExists(f): return true
  false

const RemoteCacheProjectFixture = "quit(0)\n"

suite "RFC-0005 A3c-ii — E2E-1: offline file:// remote (ENOTDIR)":

  test "url blocked by a plain file -> ENOTDIR -> run proceeds live, cacheLookup offline, remoteErrors > 0":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let blockedPath = projectRoot / "blocked_remote"
      writeFile(blockedPath, "not a directory")
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "broken" {
    url "file://""" & blockedPath & """"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)

      # Run 1: first-ever compile (edNeverBuilt at plan time). RFC-0005
      # A2c-ii's post-compile consult DOES run for it now (right after this
      # compile finishes) -- l1 genuinely misses (cold) and the "broken"
      # remote is ENOTDIR-offline, so this run's own cacheLookup is itself
      # cvOffline too (not asserted here -- this test's own target is run
      # 2's LOOKUP path, below). Either way the live run still stores into
      # l1 fine; the broken remote is merely QUEUED and fails at the
      # end-of-run flush (harmless -- proves nothing about the offline
      # lookup path this test targets).
      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results[0].cacheDecision == cdmStored

      # Wipe l1 only -- binary + depgraph stay warm, so run 2 IS a real
      # edRunFresh consult: l1 misses (wiped), the broken remote is
      # ENOTDIR-offline -> no hit anywhere -> live run, cacheLookup ==
      # offline (the aggregate worst() over {cvMiss, cvOffline}).
      removeDir(projectRoot / ".crisol" / "cache")

      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      check rr2.results[0].cacheLookup == cvOffline
      check rr2.cacheStats.remoteErrors > 0
      # RFC-0005 code-review D1: the "broken" tier is a genuinely REMOTE
      # (configured `remote-cache`) tier, so its failure stays remoteErrors
      # -- never localErrors, which is reserved for the pinned "l1" tier.
      check rr2.cacheStats.localErrors == 0
      # Zero network, zero crypto: still just the local-fs adapter, offline.

suite "RFC-0005 A3c-ii — E2E-1: genuine two-tier file:// flow (warm host) + deferred-put flush":

  test "run 1 publishes to the remote by end of run (flush); run 2 (l1 wiped) hits the remote and backfills l1":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_a3cii_e2e1_remote_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)  # a configured remote is never auto-created (RFC "Local-fs root")
      defer: removeDir(remoteRoot)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")

      # Run 1: cold everywhere -> live run. L1 is written SYNCHRONOUSLY at
      # finalize; the remote tier is queued and flushed at the end-of-run
      # join point (RFC-0005 "Deferred remote puts") -- asserting on the
      # POST-run filesystem state is exactly what proves the flush ran.
      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      # the deferred-put flush must have published to the remote tier by end of run
      check remoteHasAnyEntry(remoteRoot)

      # Wipe ONLY the local l1 cache. The stable binary + depgraph stay
      # warm, so lookupAtPlan's real consult still runs this run (the
      # "warm bin+graph" case the RFC's own Summary already supports —
      # A2c's post-compile consult is for the COLD-host case only).
      removeDir(projectRoot / ".crisol" / "cache")

      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.results[0].cacheTier == "mirror"

      # Wire-level assertion: the run/v2 render, not just the in-process
      # EntrypointResult -- proves configuredCache's wiring reaches the
      # actual JSON provenance, not merely an in-memory field.
      let node = parseJson(toJsonString(rr2.results, rr2.summary))
      let epNode = node["entrypoints"][0]
      check epNode["cacheTier"].getStr == "mirror"
      check epNode["cacheDecision"].getStr == "hit"

      # backfill-on-hit (KDL default #true) must have re-seeded l1.
      check remoteHasAnyEntry(projectRoot / ".crisol" / "cache")

# ---------------------------------------------------------------------------
# RFC-0005 C4 -- E2E-2 (RFC's own acceptance text, verbatim): "two file://
# tiers, cache-trust { policy "hmac" key-id "t" }, secret via env, L2
# verifying (default). Run 1 publishes an attested entry to L2. Flip one
# payload byte in the L2 file and recompute payloadChecksum; delete
# S/cache/v<N>/ only. Run 2: verify fails -> miss -> live ->
# cacheLookup == "trustBadSignature", cacheDecision == cdmStored (self-heal
# re-publish), cacheStats distinguishes it from a cold miss. Negative
# control: bare byte-flip -> cacheLookup == "corrupt"."
#
# Through the REAL entry point (runTests -> planImpl -> configuredCache ->
# execute), a REAL crisol.kdl `cache-trust` block, the REAL `hmacPolicy`
# (`cachetrust.nim`), and the REAL `$CRISOL_CACHE_HMAC_KEY` env var (proving
# api.nim's CacheSecrets resolution end to end) -- not a hand-built
# CacheDeps override (test_cachetrust.nim's job is the policy in
# isolation; this is the load-bearing slice property).
# ---------------------------------------------------------------------------

proc findStoredEntryJson(root: string): string =
  ## The one `.json` entry a single-entrypoint fixture publishes under a
  ## configured remote root (RFC-0005 "Local-fs root": entries live at
  ## `<root>/v<N>/<key>.json`). A CONFIGURED REMOTE never has a sidecar dir
  ## (sidecars are tier-0/local-fs-adapter only -- `cachedispatch.realSeams`
  ## gates `writeSidecar` on `rt.localRoot`, which is always l1), but an
  ## l1 root (RFC-0005 C5c's backfill assertions pass one here too) CAN
  ## carry a `v<N>/inputs/<fnv(path)>.json` explain-miss sidecar alongside
  ## the real entry -- skip that subdirectory explicitly so a caller always
  ## gets the STORED ENTRY, never the sidecar, regardless of which root or
  ## which `walkDirRec` traversal order the filesystem happens to produce.
  let sidecarMarker = DirSep & "inputs" & DirSep
  for f in walkDirRec(root):
    if f.endsWith(".json") and sidecarMarker notin f: return f
  doAssert false, "expected exactly one stored entry under " & root

suite "RFC-0005 C4 -- E2E-2: a forged entry is never served (hmacPolicy over two file:// tiers)":

  test "tamper + recompute payloadChecksum -> cacheLookup trustBadSignature, self-heal republish":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_c4_e2e2_badsig_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)
      defer: removeDir(remoteRoot)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
cache-trust {
    policy "hmac"
    key-id "t"
}
""")
      putEnv("CRISOL_CACHE_HMAC_KEY", "e2e2-secret")
      defer: delEnv("CRISOL_CACHE_HMAC_KEY")  # safety net; api.nim scrubs it itself on the happy path
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)

      # Run 1: cold -> live -> publishes an ATTESTED entry to L2 (the
      # "mirror" remote) by end of run (the deferred-put flush).
      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      check remoteHasAnyEntry(remoteRoot)

      # $CRISOL_CACHE_HMAC_KEY must be gone from THIS process's env by now
      # (api.nim's resolveCacheSecrets scrubs it immediately after
      # resolving it) -- proves the delEnv half of C4's scope, not just
      # the sign/verify half.
      check getEnv("CRISOL_CACHE_HMAC_KEY") == ""

      let entryPath = findStoredEntryJson(remoteRoot)
      let original = parseJson(readFile(entryPath))
      # run 1 must have signed the entry it published to a verifying tier
      check original.hasKey("attestation")

      # Flip one payload byte AND recompute payloadChecksum (RFC's own
      # E2E-2 wording, verbatim) -- integrity (the FNV checksum) now
      # matches the tampered bytes, but the HMAC signature (bound to the
      # OLD payload's SHA-256) no longer verifies.
      var tampered = original
      tampered["payload"]["cachedAt"] = newJInt(tampered["payload"]["cachedAt"].getBiggestInt + 1)
      let retampered = payloadFromJson(tampered["payload"])
      check retampered.isSome
      tampered["payloadChecksum"] = newJString(toHex16(fnv1a64(canonicalPayload(retampered.get))))
      writeFile(entryPath, $tampered)

      # Delete S/cache/v<N>/ ONLY (wipe l1) -- the tampered L2 is now the
      # only place a hit could come from.
      removeDir(projectRoot / ".crisol" / "cache")

      # api.nim's resolveCacheSecrets delEnv's the var after run 1 already
      # resolved it (proven above) -- a SECOND in-process `runTests` call
      # needs it set again, exactly as a fresh CLI process would read it
      # fresh from its own environment.
      putEnv("CRISOL_CACHE_HMAC_KEY", "e2e2-secret")
      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      let r2 = rr2.results[0]
      check r2.cacheLookup == cvTrustBadSignature
      check r2.cacheTier == ""              # never served from any tier
      check r2.cacheDecision == cdmStored    # self-heal: the live rerun re-publishes
      check r2.run.kind == ptypes.pkRan      # a genuine LIVE run, not a cache replay

      # Wire-level assertion (RFC's own DoD wording, verbatim): the run/v2
      # render, not just the in-process EntrypointResult.
      let node = parseJson(toJsonString(rr2.results, rr2.summary))
      let epNode = node["entrypoints"][0]
      check epNode["cacheLookup"].getStr == "trustBadSignature"
      check epNode["cacheDecision"].getStr == "stored"

      # RFC-0005 code-review T8: the RFC's own E2E-2 acceptance text (this
      # suite's own doc comment, above) claims "cacheStats distinguishes it
      # from a cold miss". Empirically it does NOT: aggregateCacheStats
      # (cachetelemetry.nim) folds `l1Hits`/`remoteHits`/`misses`/`total`/
      # `notConsulted` purely from each entrypoint's FINAL `cacheDecision`
      # (+`cacheTier`) — never from `cacheLookup`/the tier verdicts. A
      # trust-rejected read's `PlanLookup.decision` is `cdmKeyMiss` at
      # lookup time (cachedispatch.lookupAtPlan: `l.hit.isNone` — "nothing
      # servable" — is the SAME code path a genuine empty-cache cold miss
      # takes), then `cdmStored` after the self-heal republish — EXACTLY
      # the same two decisions a first-ever cold run produces. The
      # trust-rejection verdict IS captured on the wire (`tekMiss.verdicts`
      # carries it), but `aggregateCacheStats`'s `tekMiss` arm is a bare
      # `discard` (miss COUNT is decision-sourced; the verdict itself is
      # simply never folded into any `CacheStats` field). `tekRemoteErr`/
      # `tekBackfillErr` (the only other candidates, feeding
      # `remoteErrors`/`localErrors`) are PUT/backfill-failure events only
      # — a READ-side trust rejection never emits either. This test PINS
      # the actual (gap) shape rather than silently asserting the RFC's
      # claim: `misses` reads 1 either way — a trust-rejected-then-healed
      # run is byte-for-byte cacheStats-identical to a genuine cold miss
      # in an equally-tiered setup (compare this to the plain "cold run"
      # case in the "cache-stats resolution" suite above: same
      # l1Hits/remoteHits/misses/hitPct shape). BLOCKER finding for the
      # RFC text / a follow-up slice, not something this fix silently
      # redefines.
      check rr2.cacheStats.misses == 1
      check rr2.cacheStats.l1Hits == 0
      check rr2.cacheStats.remoteHits == 0
      check rr2.cacheStats.remoteErrors == 0   # NOT counted as a remote error
      check rr2.cacheStats.localErrors == 0    # NOT counted as a local error either
      check rr2.cacheStats.hitPct == 0.0

  test "negative control: bare byte-flip (checksum NOT fixed) -> cacheLookup corrupt, not trust":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_c4_e2e2_corrupt_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)
      defer: removeDir(remoteRoot)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
cache-trust {
    policy "hmac"
    key-id "t"
}
""")
      putEnv("CRISOL_CACHE_HMAC_KEY", "e2e2-secret")
      defer: delEnv("CRISOL_CACHE_HMAC_KEY")  # safety net; api.nim scrubs it itself on the happy path
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)

      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check remoteHasAnyEntry(remoteRoot)

      let entryPath = findStoredEntryJson(remoteRoot)
      var node = parseJson(readFile(entryPath))
      # Bare tamper -- the payload changes but payloadChecksum is left
      # stale: caught at the INTEGRITY layer (cvCorrupt), before trust
      # verification is ever reached (RFC "Integrity vs. trust").
      node["payload"]["cachedAt"] = newJInt(node["payload"]["cachedAt"].getBiggestInt + 1)
      writeFile(entryPath, $node)

      removeDir(projectRoot / ".crisol" / "cache")

      putEnv("CRISOL_CACHE_HMAC_KEY", "e2e2-secret")  # see the sibling test's comment
      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      check rr2.results[0].cacheLookup == cvCorrupt
      check rr2.results[0].cacheDecision == cdmStored  # self-heal here too

      # RFC-0005 code-review T8 (see the sibling "tamper + recompute
      # payloadChecksum" test's comment for the full analysis): `cvCorrupt`
      # takes the SAME `l.hit.isNone` ("nothing servable") path through
      # lookupAtPlan as a genuine cold miss, so it lands in the identical
      # cacheStats bucket -- confirmed here for the INTEGRITY-layer verdict
      # too, not just the trust-layer one.
      check rr2.cacheStats.misses == 1
      check rr2.cacheStats.l1Hits == 0
      check rr2.cacheStats.remoteHits == 0
      check rr2.cacheStats.remoteErrors == 0
      check rr2.cacheStats.localErrors == 0

# ---------------------------------------------------------------------------
# RFC-0005 C5a -- ed25519 sign+verify happy path through the REAL entry
# point (runTests -> planImpl -> configuredCache -> execute), a REAL
# crisol.kdl `cache-trust { policy "ed25519" }` block with a `pinned-key`,
# the REAL `ed25519Policy` (`cachetrust.nim`), and the REAL
# `$CRISOL_CACHE_SIGN_KEY` env var (proving `api.nim`'s `CacheSecrets`
# resolution for the ed25519 seed end to end). The full rejection matrix
# (tamper / unpinned / signer-mismatch / unknown-alg) is C5b's job -- out
# of scope here; this proves the HAPPY sign, then no-seed VERIFY-ONLY,
# path only.
# ---------------------------------------------------------------------------

suite "RFC-0005 C5a -- ed25519 sign+verify through the real entry point (two file:// tiers)":

  test "run 1 (signer) publishes an attested entry; run 2 (verify-only, no seed) hits + verifies it":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_c5a_e2e_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)
      defer: removeDir(remoteRoot)

      let seedBytes: array[32, byte] = [
        byte 11, 22, 33, 44, 55, 66, 77, 88, 99, 100, 111, 122, 133,
        144, 155, 166, 177, 188, 199, 210, 221, 232, 243, 254,
        9, 8, 7, 6, 5, 4, 3, 2]
      let seedB64 = base64.encode(seedBytes)
      let pubKeyB64 = base64.encode(toBytes(keypair(toSeed(seedBytes)).public))
      # Precomputed separately (ordinary escaped string, not the triple-
      # quoted KDL doc below) so the base64 splice needs no fragile
      # quote-counting inside the triple-quoted literal.
      let pinnedKeyLine = "pinned-key \"" & pubKeyB64 & "\""

      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
cache-trust {
    policy "ed25519"
    """ & pinnedKeyLine & """

}
""")
      putEnv("CRISOL_CACHE_SIGN_KEY", seedB64)
      defer: delEnv("CRISOL_CACHE_SIGN_KEY")  # safety net; api.nim scrubs it itself on the happy path
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")

      # Run 1 (signer): cold -> live -> publishes an ATTESTED entry to L2
      # (the "mirror" remote) by end of run (the deferred-put flush).
      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      check remoteHasAnyEntry(remoteRoot)

      # $CRISOL_CACHE_SIGN_KEY must be gone from THIS process's env by now
      # (api.nim's resolveCacheSecrets scrubs it immediately after
      # resolving it) -- proves the delEnv half of C5a's scope too.
      check getEnv("CRISOL_CACHE_SIGN_KEY") == ""

      let entryPath = findStoredEntryJson(remoteRoot)
      let stored = parseJson(readFile(entryPath))
      check stored.hasKey("attestation")
      check stored["attestation"]["sigAlg"].getStr == "ed25519"
      check stored["attestation"]["signer"].getStr == pubKeyB64

      # Wipe l1 -- only the remote (verifying) tier can serve now.
      removeDir(projectRoot / ".crisol" / "cache")

      # Run 2: a READ-ONLY (verify-only) participant -- deliberately NO
      # $CRISOL_CACHE_SIGN_KEY set at all (RFC-0005 "no-seed verify-only
      # mode" proven through the real entry point, not just the policy in
      # isolation). It still verifies what run 1 signed, using only the
      # pinned public key already in crisol.kdl.
      check getEnv("CRISOL_CACHE_SIGN_KEY") == ""
      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      let r2 = rr2.results[0]
      check r2.cacheDecision == cdmHit
      check r2.cacheTier == "mirror"
      check r2.cacheLookup == cvOk

      # Wire-level assertion (RFC's own DoD wording, verbatim): the run/v2
      # render, not just the in-process EntrypointResult.
      let node = parseJson(toJsonString(rr2.results, rr2.summary))
      let epNode = node["entrypoints"][0]
      check epNode["cacheTier"].getStr == "mirror"
      check epNode["cacheDecision"].getStr == "hit"

      # RFC-0005 C5c: backfill-only-after-verify, through the real entry
      # point. Run 2's hit came from "mirror" (a verifying tier) -- the
      # verified-bit backfill rule (`cachetier.nim`) says a VERIFIED hit
      # may re-seed l1, and "a backfilled entry is re-stored WITH the
      # attestation it arrived with" (RFC-0005 "One TrustPolicy per
      # TieredCache"). Prove BOTH halves against the real, on-disk l1
      # entry -- not just the in-process CacheLookup.
      check remoteHasAnyEntry(projectRoot / ".crisol" / "cache")
      let backfilledPath = findStoredEntryJson(projectRoot / ".crisol" / "cache")
      let backfilled = parseJson(readFile(backfilledPath))
      check backfilled.hasKey("attestation")
      check backfilled["attestation"]["sigAlg"].getStr == "ed25519"
      check backfilled["attestation"]["signer"].getStr == pubKeyB64

      # Run 3: l1 is warm now (nothing wiped) -- the waterfall serves the
      # backfilled entry DIRECTLY from l1, and it verifies again under the
      # same pinned key, genuinely, from disk.
      let rr3 = runTests(opts)
      check rr3.status == rsOk
      check rr3.results.len == 1
      check rr3.results[0].cacheDecision == cdmHit
      check rr3.results[0].cacheTier == "l1"
      check rr3.results[0].cacheLookup == cvOk

# ---------------------------------------------------------------------------
# RFC-0005 C5b -- E2E-2 repeated under ed25519 with an unpinned second
# signer (RFC's own wording, verbatim): "a forged entry is never served" --
# here "forged" means "genuinely, validly signed, but by a key this
# consumer project does not trust". `crisol.kdl` pins ONLY key A the whole
# time; run 1 plays a DIFFERENT party who happens to hold key B's secret
# (never pinned here) and publishes a real, validly-signed entry to the
# shared "mirror" remote -- exactly as an untrusted or since-rotated-out
# publisher might. Run 2 is this project's own consumer: cold L1, no
# signing secret of its own, `$CRISOL_CACHE_SIGN_KEY` unset entirely. Its
# lookup must reject the remote entry as `cvTrustUnpinnedSigner` (key B is
# a valid signer, just not one THIS project trusts), never serve it, and
# fall through to a genuine live run (self-heal republish to l1, same
# shape as the C4/C5a E2E-2 self-heal).
# ---------------------------------------------------------------------------

suite "RFC-0005 C5b -- E2E-2 repeat: ed25519 unpinned second signer never served (two file:// tiers)":

  test "consumer pins only key A; a valid entry signed by unpinned key B -> cacheLookup trustUnpinnedSigner, live run":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_c5b_e2e2_unpinned_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)
      defer: removeDir(remoteRoot)

      let seedBytesA: array[32, byte] = [
        byte 11, 22, 33, 44, 55, 66, 77, 88, 99, 100, 111, 122, 133,
        144, 155, 166, 177, 188, 199, 210, 221, 232, 243, 254,
        9, 8, 7, 6, 5, 4, 3, 2]
      let seedBytesB: array[32, byte] = [
        byte 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
        213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
        1, 2, 3, 4, 5, 6, 7, 8]
      let seedB64B = base64.encode(seedBytesB)
      let pubKeyB64A = base64.encode(toBytes(keypair(toSeed(seedBytesA)).public))
      let pubKeyB64B = base64.encode(toBytes(keypair(toSeed(seedBytesB)).public))
      # Precomputed separately, same reason as the C5a test above (a
      # fragile quote-counted splice inside the triple-quoted KDL literal).
      let pinnedKeyLine = "pinned-key \"" & pubKeyB64A & "\""

      # This crisol.kdl -- pinning ONLY key A -- is used, unmodified, by
      # BOTH runs below; only the signing env var differs between them.
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
cache-trust {
    policy "ed25519"
    """ & pinnedKeyLine & """

}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")

      # Run 1 (a DIFFERENT party, holding key B's secret -- never pinned by
      # this crisol.kdl): cold cache regardless -> live -> publishes a
      # genuinely, validly-signed entry to the "mirror" remote.
      putEnv("CRISOL_CACHE_SIGN_KEY", seedB64B)
      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results.len == 1
      check rr1.results[0].cacheDecision == cdmStored
      check remoteHasAnyEntry(remoteRoot)

      # api.nim's resolveCacheSecrets scrubs the var after run 1 resolves it.
      check getEnv("CRISOL_CACHE_SIGN_KEY") == ""

      let entryPath = findStoredEntryJson(remoteRoot)
      let stored = parseJson(readFile(entryPath))
      check stored.hasKey("attestation")
      check stored["attestation"]["sigAlg"].getStr == "ed25519"
      # Confirms the test actually set up what it claims: the published
      # entry is signed by B, NOT A.
      check stored["attestation"]["signer"].getStr == pubKeyB64B
      check stored["attestation"]["signer"].getStr != pubKeyB64A

      # Wipe l1 -- only the remote (verifying) tier can serve now.
      removeDir(projectRoot / ".crisol" / "cache")

      # Run 2: this project's own consumer -- deliberately NO
      # $CRISOL_CACHE_SIGN_KEY at all (a read-only participant, same as
      # C5a's verify-only run). It pins only key A via the SAME
      # crisol.kdl -- key B was never trusted.
      check getEnv("CRISOL_CACHE_SIGN_KEY") == ""
      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results.len == 1
      let r2 = rr2.results[0]
      check r2.cacheLookup == cvTrustUnpinnedSigner
      check r2.cacheTier == ""              # never served from any tier
      check r2.cacheDecision == cdmStored    # self-heal: the live rerun re-publishes (to l1 only -- no secret to attest a mirror write)
      check r2.run.kind == ptypes.pkRan      # a genuine LIVE run, not a cache replay

      # Wire-level assertion (RFC's own DoD wording, verbatim): the run/v2
      # render, not just the in-process EntrypointResult.
      let node = parseJson(toJsonString(rr2.results, rr2.summary))
      let epNode = node["entrypoints"][0]
      check epNode["cacheLookup"].getStr == "trustUnpinnedSigner"
      check epNode["cacheDecision"].getStr == "stored"

      # RFC-0005 C5c: the contrast to C5a's backfill proof above -- an
      # UNTRUSTED remote entry must never backfill l1, even though a NEW
      # l1 entry now exists (the self-heal live rerun's own store, just
      # asserted via cacheDecision == cdmStored). Prove the l1 file on
      # disk is that fresh, genuinely UNATTESTED live result (this
      # consumer holds no signing secret) -- not a copy of key B's
      # rejected, validly-signed-but-untrusted attestation; a real
      # backfill would have carried key B's attestation onto l1 instead.
      check remoteHasAnyEntry(projectRoot / ".crisol" / "cache")
      let l1Path = findStoredEntryJson(projectRoot / ".crisol" / "cache")
      let l1Entry = parseJson(readFile(l1Path))
      # no L1 backfill of the unpinned remote entry may occur -- the l1
      # file must be the consumer's own unattested live store, never key B's
      check not l1Entry.hasKey("attestation")

# ---------------------------------------------------------------------------
# RFC-0005 A2c-ii — the post-compile consult, through the REAL entry point
# (runTests -> planImpl -> execute -> finalizeSlot's consultPostCompile),
# driven by a REAL crisol.kdl file:// remote -- the load-bearing consumer
# the A2c-i reorder exists for. A genuinely NEVER-BUILT entrypoint (its own
# project root, its own stateDir -- no binary, no depgraph, no L1 entry
# anywhere) can ONLY be served from cache through the post-compile consult:
# lookupAtPlan's plan-time gate never even looks (edNeverBuilt, not
# edRunFresh). The full three-run cold-host E2E-1 sequence is A2c-iii's
# acceptance test, not this one -- this proves the HIT mechanism itself
# fires end to end: the compile genuinely runs, the run phase never spawns,
# and the promoted binary + depgraph are trustworthy afterward.
# ---------------------------------------------------------------------------

suite "RFC-0005 A2c-ii — post-compile consult: a genuinely cold project hits a remote already holding this closure":

  test "P2's first-ever compile of an unseen entrypoint HITS the remote P1 published to -- no run child spawned":
    let remoteRoot = getTempDir() / ("crisol_a2cii_e2e_remote_" & $getCurrentProcessId())
    removeDir(remoteRoot)
    createDir(remoteRoot)
    defer: removeDir(remoteRoot)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n" &
              "remote-cache \"mirror\" {\n    url \"file://" & remoteRoot & "\"\n}\n"

    # Project P1: an ordinary live run publishes this exact closure to the
    # shared remote (own project root, own stateDir -- P2 below shares
    # NOTHING with it except the remote).
    let p1 = getTempDir() / ("crisol_a2cii_e2e_p1_" & $getCurrentProcessId())
    removeDir(p1)
    createDir(p1 / "tests" / "unit")
    defer: removeDir(p1)
    writeFile(p1 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p1 / "crisol.kdl", kdl)
    let rr1 = runTests(RunOptions(configPath: p1 / "crisol.kdl"))
    check rr1.status == rsOk
    check rr1.results[0].cacheDecision == cdmStored
    check remoteHasAnyEntry(remoteRoot)

    # Project P2: a SEPARATE project root + stateDir, IDENTICAL source
    # content (same closure -> same soundness key), never built before --
    # a genuinely cold host for this entrypoint. Its compile is
    # edNeverBuilt at plan time: no binary, no depgraph entry, no P2-local
    # cache entry exist anywhere. The post-compile consult (A2c-ii) is the
    # ONLY mechanism that can possibly serve this from cache -- the
    # plan-time lookupAtPlan gate never even runs for it.
    let p2 = getTempDir() / ("crisol_a2cii_e2e_p2_" & $getCurrentProcessId())
    removeDir(p2)
    createDir(p2 / "tests" / "unit")
    defer: removeDir(p2)
    writeFile(p2 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p2 / "crisol.kdl", kdl)
    let rr2 = runTests(RunOptions(configPath: p2 / "crisol.kdl"))
    check rr2.status == rsOk
    check rr2.results.len == 1
    let r2 = rr2.results[0]
    check r2.cacheDecision == cdmHit
    check r2.cacheTier == "mirror"
    # RFC-0005 A2c re-baseline: the compile genuinely ran (compile =
    # Phase(pkRan, ...), compileSkipped == false) even though the run phase
    # never spawned (run = Phase(pkCached, ...) -- the stored observation
    # replayed verbatim).
    check r2.compileSkipped == false
    check r2.compile.kind == ptypes.pkRan
    check r2.run.kind == ptypes.pkCached
    check outcome(r2) == oPassed

    # Wire-level assertion: the run/v2 render, not just the in-process
    # EntrypointResult.
    let node = parseJson(toJsonString(rr2.results, rr2.summary))
    let epNode = node["entrypoints"][0]
    check epNode["cacheTier"].getStr == "mirror"
    check epNode["cacheDecision"].getStr == "hit"

    # The just-compiled binary WAS promoted to P2's own stable path (B3's
    # "every cdmHit has a stable binary" invariant) even though no run
    # child was ever spawned for it -- proven behaviorally: P2's NEXT run
    # sees a fresh binary + depgraph entry and skips compiling entirely
    # (edRunFresh / cdSkipFresh), which is only possible if A2c-ii's hit
    # path left P2's on-disk state exactly as a real compile+run would have.
    let rr3 = runTests(RunOptions(configPath: p2 / "crisol.kdl"))
    check rr3.status == rsOk
    check rr3.results[0].compileSkipped == true

# ---------------------------------------------------------------------------
# RFC-0005 A2c-iii — E2E-1, the RFC's own acceptance text verbatim ("E2E-1
# under (a)", §FORK-2): the cold-host three-run sequence + the secondary
# L1-evict refallback. The A2c-ii suite above proves the post-compile HIT
# MECHANISM fires end to end (no run child spawned, binary promoted); this
# suite is the full E2E-1 clause-by-clause acceptance:
#
#   Run 1 (P1/S1): live -> cdmStored, an entry in L1 AND L2.
#   Run 2 (P2/S2 -- a separate project root/stateDir, identical source, a
#     genuinely cold host: no binary, no depgraph, no P2-local cache entry
#     anywhere): compileSkipped == false, cacheDecision == cdmHit, cacheTier
#     == the remote's configured name ("mirror" -- this codebase names
#     tiers by KDL name; "l1" is reserved for the pinned local tier, see
#     cacheregistry.nim -- the RFC's "l2" is a generic placeholder for
#     "the second/remote tier", already the convention the landed A3c-ii
#     warm-host test uses), attempts == 0, the binary now present under
#     S2/bin, and S2's own L1 backfilled.
#   Run 3 (P2/S2, now warm everywhere -- binary, depgraph, AND L1): cacheTier
#     == "l1", compileSkipped == true.
#   Secondary: evict S2's L1 only (binary + depgraph stay warm) -> cacheTier
#     == the remote's name again (L2 refallback + re-backfill).
#
# This completes slice A2c: nothing about E2E-1 remains deferred after this
# test.
# ---------------------------------------------------------------------------

suite "RFC-0005 A2c-iii — E2E-1: the cold-host three-run sequence (+ secondary L1-evict refallback)":

  test "run 1 (P1) stores to L1+L2; run 2 (cold P2) hits L2 post-compile & backfills L1; run 3 (warm P2) hits L1; evicting P2's L1 falls back to L2":
    let remoteRoot = getTempDir() / ("crisol_a2ciii_e2e1_remote_" & $getCurrentProcessId())
    removeDir(remoteRoot)
    createDir(remoteRoot)  # a configured remote is never auto-created
    defer: removeDir(remoteRoot)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n" &
              "remote-cache \"mirror\" {\n    url \"file://" & remoteRoot & "\"\n}\n"

    # --- Run 1: project P1 / stateDir S1 -- an ordinary live run. ----------
    let p1 = getTempDir() / ("crisol_a2ciii_e2e1_p1_" & $getCurrentProcessId())
    removeDir(p1)
    createDir(p1 / "tests" / "unit")
    defer: removeDir(p1)
    writeFile(p1 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p1 / "crisol.kdl", kdl)
    let rr1 = runTests(RunOptions(configPath: p1 / "crisol.kdl"))
    check rr1.status == rsOk
    check rr1.results.len == 1
    check rr1.results[0].cacheDecision == cdmStored
    check anyFileUnder(p1 / ".crisol" / "cache")  # entry in L1 (P1's own)
    check remoteHasAnyEntry(remoteRoot)           # entry in L2 (the shared remote)

    # --- Run 2: project P2 / stateDir S2 -- a SEPARATE project root, ------
    # identical source content (same closure -> same soundness key), never
    # built before: no binary, no depgraph entry, no P2-local cache entry
    # anywhere -- a genuinely cold host for this entrypoint. edNeverBuilt at
    # plan time; only A2c-ii's post-compile consult can serve this hit.
    let p2 = getTempDir() / ("crisol_a2ciii_e2e1_p2_" & $getCurrentProcessId())
    removeDir(p2)
    createDir(p2 / "tests" / "unit")
    defer: removeDir(p2)
    writeFile(p2 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p2 / "crisol.kdl", kdl)
    let rr2 = runTests(RunOptions(configPath: p2 / "crisol.kdl", cacheStats: true))
    check rr2.status == rsOk
    check rr2.results.len == 1
    let r2 = rr2.results[0]
    check r2.compileSkipped == false
    check r2.cacheDecision == cdmHit
    check r2.cacheTier == "mirror"
    check r2.attempts == 0
    # the compiled binary WAS promoted to P2's own stable path (B3's "every
    # cdmHit has a stable binary" invariant) even though no run child was
    # ever spawned for it.
    check anyFileUnder(p2 / ".crisol" / "bin")
    # backfill-on-hit (KDL default #true) re-seeded P2's OWN L1.
    check anyFileUnder(p2 / ".crisol" / "cache")
    check rr2.cacheStats.hitPct == 100.0
    # RFC-0005 C-dep rider: this hit was SERVED FROM "mirror" (a remote
    # tier), not "l1" -- aggregateCacheStats must attribute it to
    # remoteHits, not fold it into l1Hits (the pre-rider mislabel).
    check rr2.cacheStats.remoteHits == 1
    check rr2.cacheStats.l1Hits == 0

    # Wire-level assertion: the run/v2 render, not just the in-process
    # EntrypointResult. Threading cacheStats through the SAME render path
    # `crisol run --json` uses proves the rider's fix is visible on the
    # wire, not just in the in-process CacheStats struct.
    let node2 = parseJson(toJsonString(rr2.results, rr2.summary,
                                       cacheStats = rr2.cacheStats, showCacheStats = true))
    let epNode2 = node2["entrypoints"][0]
    check epNode2["cacheTier"].getStr == "mirror"
    check epNode2["cacheDecision"].getStr == "hit"
    check node2["cacheStats"]["remoteHits"].getInt == 1
    check node2["cacheStats"]["l1Hits"].getInt == 0

    # --- Run 3: P2/S2 again -- binary + depgraph + P2's L1 all warm now. --
    let rr3 = runTests(RunOptions(configPath: p2 / "crisol.kdl", cacheStats: true))
    check rr3.status == rsOk
    check rr3.results.len == 1
    let r3 = rr3.results[0]
    check r3.compileSkipped == true
    check r3.cacheDecision == cdmHit
    check r3.cacheTier == "l1"
    check rr3.cacheStats.hitPct == 100.0
    # This hit was served from "l1" -- the mirror image of the rr2 check
    # above (an l1 hit must land in l1Hits, not remoteHits).
    check rr3.cacheStats.l1Hits == 1
    check rr3.cacheStats.remoteHits == 0

    let node3 = parseJson(toJsonString(rr3.results, rr3.summary,
                                       cacheStats = rr3.cacheStats, showCacheStats = true))
    let epNode3 = node3["entrypoints"][0]
    check epNode3["cacheTier"].getStr == "l1"
    check epNode3["cacheDecision"].getStr == "hit"
    check node3["cacheStats"]["l1Hits"].getInt == 1
    check node3["cacheStats"]["remoteHits"].getInt == 0

    # --- Secondary: evict P2's L1 only -- binary + depgraph stay warm. ----
    removeDir(p2 / ".crisol" / "cache")
    let rr4 = runTests(RunOptions(configPath: p2 / "crisol.kdl", cacheStats: true))
    check rr4.status == rsOk
    check rr4.results.len == 1
    let r4 = rr4.results[0]
    check r4.compileSkipped == true          # binary + depgraph still warm
    check r4.cacheDecision == cdmHit
    check r4.cacheTier == "mirror"            # L2 refallback (L1 was empty)
    check rr4.cacheStats.hitPct == 100.0
    # L2 refallback is a remote-served hit again -- remoteHits, not l1Hits.
    check rr4.cacheStats.remoteHits == 1
    check rr4.cacheStats.l1Hits == 0
    check anyFileUnder(p2 / ".crisol" / "cache")  # re-backfilled

# ---------------------------------------------------------------------------
# RFC-0005 code-review SO5 -- the --verify-cache pass must never persist the
# depgraph, including for a sampled hit that came from the POST-COMPILE
# consult (A2c-ii above) rather than a plan-time hit. Reuses the exact
# cold-host P1/P2 recipe the A2c-ii suite (immediately above) already
# proved produces a genuine post-compile-consult hit (`compileSkipped ==
# false`, `cacheDecision == cdmHit`) -- now with `--verify-cache` ALSO
# enabled on P2's own (single, cold) run, so the verify pass samples THAT
# SAME hit within the SAME runTests() call the post-compile consult fires
# in (the only way the SO5 scenario can occur at all -- see
# buildVerifyPlan's own fix comment, runner.nim).
# ---------------------------------------------------------------------------

suite "RFC-0005 code-review SO5 — verify-cache never persists the depgraph for a post-compile-consult hit":

  test "post-compile-consult hit + --verify-cache: depgraph is not written again after persistLastRun; state stays self-consistent":
    let remoteRoot = getTempDir() / ("crisol_so5_remote_" & $getCurrentProcessId())
    removeDir(remoteRoot)
    createDir(remoteRoot)
    defer: removeDir(remoteRoot)
    let kdl = "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n" &
              "remote-cache \"mirror\" {\n    url \"file://" & remoteRoot & "\"\n}\n"

    # P1: an ordinary live run publishes this exact closure to the shared remote.
    let p1 = getTempDir() / ("crisol_so5_p1_" & $getCurrentProcessId())
    removeDir(p1)
    createDir(p1 / "tests" / "unit")
    defer: removeDir(p1)
    writeFile(p1 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p1 / "crisol.kdl", kdl)
    let rr1 = runTests(RunOptions(configPath: p1 / "crisol.kdl"))
    check rr1.status == rsOk
    check rr1.results[0].cacheDecision == cdmStored
    check remoteHasAnyEntry(remoteRoot)

    # P2: a SEPARATE, genuinely cold project (own root, own stateDir) --
    # edNeverBuilt at plan time, so ONLY the post-compile consult (A2c-ii)
    # can serve this hit -- with --verify-cache ALSO enabled on this SAME
    # run, sampling that exact hit.
    let p2 = getTempDir() / ("crisol_so5_p2_" & $getCurrentProcessId())
    removeDir(p2)
    createDir(p2 / "tests" / "unit")
    defer: removeDir(p2)
    writeFile(p2 / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
    writeFile(p2 / "crisol.kdl", kdl)
    let rr2 = runTests(RunOptions(configPath: p2 / "crisol.kdl",
                                  verifyCache: verifySample(pct = 100)))
    check rr2.status == rsOk
    check rr2.results.len == 1
    let r2 = rr2.results[0]
    # Proves this hit genuinely came from the POST-COMPILE consult, not a
    # plan-time lookup (A2c-ii's own distinguishing signal).
    check r2.compileSkipped == false
    check r2.cacheDecision == cdmHit
    check r2.cacheTier == "mirror"
    # The sampled verify re-run reused the promoted stable binary cleanly
    # (SO5's fix) -- no false divergence, no could-not-reexec either.
    check rr2.verifyDivergences.len == 0
    check rr2.verifyCouldNotReexec.len == 0

    let (cfg2, cfg2Errs) = loadConfig(p2 / "crisol.kdl")
    doAssert cfg2Errs.len == 0, "loadConfig failed: " & $cfg2Errs

    # SO5's own ordering proof: `persistLastRun` (which writes lastrun.json)
    # runs strictly BEFORE the verify pass (RFC "Binary precondition... the
    # pass runs before releaseLock, after persistLastRun" -- already the
    # contract test_b3b_verify_cache.nim's "placement proof" pins via
    # lastrun.json's CONTENT). If the verify pass illegitimately recompiled
    # and re-persisted the depgraph (the SO5 bug), that second
    # `saveDepGraph` call would happen AFTER persistLastRun already wrote
    # lastrun.json -- so the depgraph's mtime would be STRICTLY LATER than
    # lastrun.json's. Fixed: the depgraph's last write is the MAIN run's own
    # legitimate post-compile-consult recordClosure, which happens BEFORE
    # persistLastRun -- so its mtime must be <= lastrun.json's.
    let depgraphMtime = getFileInfo(depgraphPath(cfg2)).lastWriteTime
    let lastrunMtime  = getFileInfo(p2 / ".crisol" / "lastrun.json").lastWriteTime
    check depgraphMtime <= lastrunMtime

    # State self-consistency: P2's depgraph correctly describes ONE entry
    # (not corrupted/duplicated by an extra write), and P2's NEXT run (still
    # no --verify-cache) sees it as fully warm -- exactly the same
    # regression-safety proof the A2c-ii suite's own run 3 draws, now run
    # AFTER a verify-cache-enabled run instead of a plain one.
    var discarded: DepGraphDiscard
    let onDisk = loadStoredDepGraph(cfg2, discarded)
    check onDisk.entries.len == 1

    let rr3 = runTests(RunOptions(configPath: p2 / "crisol.kdl"))
    check rr3.status == rsOk
    check rr3.results[0].compileSkipped == true

suite "RFC-0005 A3c-ii — RunOptions.noRemoteCache (--no-remote-cache)":

  test "noRemoteCache=true drops the configured remote tier; local (l1) caching stays active":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      let remoteRoot = getTempDir() / ("crisol_a3cii_noremote_" & $getCurrentProcessId())
      removeDir(remoteRoot)
      createDir(remoteRoot)  # exists and writable -- proves the miss is --no-remote-cache, not ENOTDIR
      defer: removeDir(remoteRoot)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "file://""" & remoteRoot & """"
}
""")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", noRemoteCache: true)

      let rr1 = runTests(opts)
      check rr1.status == rsOk
      check rr1.results[0].cacheDecision == cdmStored
      # --no-remote-cache must drop the remote tier entirely -- nothing ever queued or flushed to it
      check not remoteHasAnyEntry(remoteRoot)

      # l1 stays warm across the SAME opts (still noRemoteCache) -> a real hit.
      let rr2 = runTests(opts)
      check rr2.status == rsOk
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.results[0].cacheTier == "l1"

  test "an otherwise-rejected remote-cache config (l1-named) is never even validated when noRemoteCache is set":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "l1" {
    url "file:///nonexistent/wherever"
}
""")
      # Without --no-remote-cache this would be a structural cekConfig
      # failure (configuredCache rejects the reserved "l1" name); dropping
      # the remote before configuredCache ever sees it makes the run
      # succeed regardless of the (moot) remote's own misconfiguration.
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl", noRemoteCache: true))
      check rr.status == rsOk

# ---------------------------------------------------------------------------
# RFC-0005 C3b -- E2E-3 (RFC's own acceptance text, verbatim): "http/s3
# remote configured in KDL, driven through runTestsWith(testRegistry(fakeFetcher))
# -- hit / miss / offline (breaker trips once) / unauthorized-put /
# oversized-body paths; --no-remote-cache reverts to local-only."
#
# End-to-end through the REAL entry path (runTestsWith -> planImpl ->
# configuredCache -> execute), driven by a REAL crisol.kdl `remote-cache`
# block parsed by config.nim and resolved via cacheregistry.testRegistry(fake)
# -- NOT a hand-built Tier list (E2E-A-trust's job, above). Per-status
# verdict-mapping correctness is already exhaustively unit-tested in
# test_cachehttp.nim/test_caches3.nim (21/36 fake-driven blocks); this
# suite's job is proving the WIRING carries a real KDL-configured http/s3
# remote through a real run, end to end -- one fake `HttpFetcher`, driven
# through `CacheDeps.buildRuntime -> configuredCache(..., testRegistry(fake), ...)`.
# ---------------------------------------------------------------------------

type
  E2E3Server = ref object
    calls*: seq[HttpRequest]
    replies: seq[HttpReply]
    idx: int

proc newE2E3Server(replies: varargs[HttpReply]): E2E3Server =
  E2E3Server(calls: @[], replies: @replies, idx: 0)

proc e2e3Fetcher(fs: E2E3Server): HttpFetcher =
  result = proc(req: HttpRequest): HttpReply =
    fs.calls.add req
    if fs.idx < fs.replies.len:
      result = fs.replies[fs.idx]
      inc fs.idx
    else:
      result = fs.replies[^1]

proc e2e3OkReply(status: int; body = ""): HttpReply =
  HttpReply(transport: toOk, status: status,
            headers: @[("Content-Type", "application/json")], body: body)

proc e2e3UnreachableReply(): HttpReply = HttpReply(transport: toUnreachable)

proc e2e3SampleCachedResult(): CachedResult =
  ## Miniature of test_cachehttp.nim's own `sampleCachedResult` -- no
  ## import-graph reason for this file to depend on that one (same
  ## precedent that file itself documents).
  CachedResult(
    run: ptypes.ProcessResult(
      exit:  ptypes.Exit(kind: ptypes.ekExited, code: 0),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: ptypes.Evidence(
        killDomain: ptypes.kdsProcessGroup,
        tree:       ptypes.toComplete,
        escapees:   @[],
        limits:     default(ptypes.LimitsAchieved),
        hermetic:   ptypes.hlIsolated,
        killSnapshot: @[],
        cooperativeUnavailable: false,
      ),
      rusage: none(ptypes.Rusage),
      durationUs: 1_000,
    ),
    records: @[],
    cachedAt: 1_700_002_000'i64,
    payloadChecksum: "",
  )

proc e2e3EncodedHitBody(): string =
  ## The GET/lookup path stamps the REQUESTED key over whatever key this
  ## body encodes (`cachehttp.httpBackend`'s `get`: `e.key = key`), so any
  ## placeholder `SoundnessKey` here is fine. Used only where the tier's
  ## resolved `verify-trust` is `false` (the http suite's default -- no
  ## `cache-trust` block) -- an UNATTESTED entry under a VERIFYING tier
  ## would be rejected (`cvTrustNoAttestation`); the s3 suite's hit test
  ## needs a genuine attestation instead, so it drives a real two-run flow
  ## (see `E2E3Store`, below) rather than hand-signing a canned reply.
  let entry = StoredEntry(
    key:            SoundnessKey("0000000000000000"),
    keyInputs:      none(KeyInputs),
    result:         e2e3SampleCachedResult(),
    storageVersion: storageFormatVersion,
    attestation:    none(Attestation),
  )
  jsonCacheSerializer().encode(entry)

proc e2e3Deps(fs: E2E3Server; secrets = CacheSecrets()): CacheDeps =
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int): CacheRuntime =
    configuredCache(cfg, stateDir, maxEntries, testRegistry(fs.e2e3Fetcher),
                    secrets, NilSink[TelemetryEvent]()))

const E2E3SingleTestKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "mirror" {
    url "https://cache.example.com/crisol"
}
"""

suite "RFC-0005 C3b -- E2E-3: http remote wired live through runTestsWith(testRegistry(fake))":

  test "hit: remote GET 200 -> served, cacheDecision hit, cacheTier == the configured name":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3Server(e2e3OkReply(200, e2e3EncodedHitBody()))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmHit
      check rr.results[0].cacheTier == "mirror"
      check rr.results[0].cacheLookup == cvOk
      check fs.calls.len == 1
      check fs.calls[0].meth == "GET"

  test "miss: remote GET 404 -> live run, cacheDecision stored, publish flushed to the remote by PUT":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3Server(e2e3OkReply(404), e2e3OkReply(200))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmStored
      check rr.results[0].cacheLookup == cvMiss
      check fs.calls.len == 2
      check fs.calls[0].meth == "GET"
      check fs.calls[1].meth == "PUT"

  test "offline (breaker trips once): two entrypoints, only ONE real fetcher call for the whole run":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "tests" / "unit" / "test_b.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3Server(e2e3UnreachableReply())
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 2
      for r in rr.results:
        check r.cacheLookup == cvOffline
        check r.cacheDecision == cdmStored
      check rr.cacheStats.remoteErrors > 0
      # The per-tier circuit breaker (cachetier.nim, RFC "Per-tier circuit
      # breaker") is a PERMANENT-for-the-run latch: the first offline reply
      # trips it, so every OTHER lookup/put against the SAME tier for the
      # rest of THIS run short-circuits without ever touching the fetcher
      # again -- proven here by the total call count staying at 1 despite
      # two entrypoints each needing a lookup AND a (queued) put.
      check fs.calls.len == 1

  test "unauthorized-put: remote PUT 401 -> local store still succeeds, remote publish rejected":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3Server(e2e3OkReply(404), e2e3OkReply(401))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmStored  # l1 wrote fine regardless of the remote
      check fs.calls.len == 2
      check fs.calls[1].meth == "PUT"
      check rr.cacheStats.remoteErrors > 0

  test "oversized-body: remote GET body over the cap -> cvCorrupt, run proceeds live":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let hugeBody = "x".repeat(9_000_000)  # over cachehttp.DefaultBodyCapBytes (8 MiB)
      let fs = newE2E3Server(e2e3OkReply(200, hugeBody), e2e3OkReply(200))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheLookup == cvCorrupt
      check rr.results[0].cacheDecision == cdmStored

  test "--no-remote-cache reverts to local-only: the fake fetcher is never even called":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3Server(e2e3OkReply(200, e2e3EncodedHitBody()))
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", noRemoteCache: true)
      let rr = runTestsWith(opts, e2e3Deps(fs))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmStored
      check rr.results[0].cacheTier == ""       # never served from any tier -- l1 only
      check fs.calls.len == 0                   # the remote was dropped before configuredCache saw it

type
  E2E3Store = ref object
    ## A tiny STATEFUL in-memory HTTP object store (GET/PUT over `req.url`
    ## as the key) -- unlike `E2E3Server`'s programmable reply queue, this
    ## one actually remembers what a prior PUT wrote, so a SECOND run's GET
    ## reads back whatever the FIRST run's live execution genuinely signed
    ## (RFC's own hmacPolicy, over the REAL soundness key) -- the same
    ## two-run pattern E2E-1's genuine file:// hit test uses, just over a
    ## fake http/s3 transport instead of a real filesystem.
    objects: Table[string, string]
    calls*:  seq[HttpRequest]

proc newE2E3Store(): E2E3Store = E2E3Store(objects: initTable[string, string](), calls: @[])

proc e2e3StoreFetcher(st: E2E3Store): HttpFetcher =
  result = proc(req: HttpRequest): HttpReply =
    st.calls.add req
    case req.meth
    of "GET":
      if st.objects.hasKey(req.url):
        HttpReply(transport: toOk, status: 200,
                  headers: @[("Content-Type", "application/json")], body: st.objects[req.url])
      else:
        HttpReply(transport: toOk, status: 404, headers: @[], body: "")
    of "PUT":
      st.objects[req.url] = req.body
      HttpReply(transport: toOk, status: 200, headers: @[], body: "")
    else:
      HttpReply(transport: toOk, status: 400, headers: @[], body: "")

proc e2e3StoreDeps(st: E2E3Store; secrets: CacheSecrets): CacheDeps =
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int): CacheRuntime =
    configuredCache(cfg, stateDir, maxEntries, testRegistry(st.e2e3StoreFetcher),
                    secrets, NilSink[TelemetryEvent]()))

suite "RFC-0005 C3b -- E2E-3: s3 remote wired live through runTestsWith(testRegistry(fake))":

  test "hit over s3 (path-style, endpoint set): remote GET 200 -> served, cacheTier == the configured name":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
}
remote-cache "team-s3" {
    url "s3://ci-cache/crisol"
    endpoint "http://minio.local:9000"
}
cache-trust {
    policy "hmac"
}
""")
      # `team-s3` resolves `verify-trust` to its default (`cache-trust.policy
      # != "none"` -- true here): a hand-canned unattested reply would be
      # REJECTED (cvTrustNoAttestation), not served, so this drives a
      # genuine two-run flow instead -- run 1 signs+publishes for real
      # (the real soundness key, the real hmacPolicy); run 2 (l1 wiped)
      # reads that SAME genuinely-signed object back.
      let st = newE2E3Store()
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let secrets = CacheSecrets(hmacKey: some("e2e3-s3-hmac-secret"))
      let deps = e2e3StoreDeps(st, secrets)

      let rr1 = runTestsWith(opts, deps)
      check rr1.status == rsOk
      check rr1.results[0].cacheDecision == cdmStored
      check st.objects.len == 1  # the deferred-put flush published to s3 by end of run

      removeDir(projectRoot / ".crisol" / "cache")  # wipe l1 only

      let rr2 = runTestsWith(opts, deps)
      check rr2.status == rsOk
      check rr2.results.len == 1
      check rr2.results[0].cacheDecision == cdmHit
      check rr2.results[0].cacheTier == "team-s3"
      # unsigned s3: no Authorization header ever, even with hmac secrets configured.
      var sawAuth = false
      for req in st.calls:
        for (k, _) in req.headers:
          if k == "Authorization": sawAuth = true
      check not sawAuth

# ---------------------------------------------------------------------------
# RFC-0005 C6 — secure-by-default credential scopes end to end: the RFC's
# own acceptance text, verbatim: "publish iff write-credentialed
# (cvUnauthorized put -> no-op, reads still serve)". A real KDL
# `remote-cache` block, driven through
# runTestsWith(testRegistry(fake)) exactly like the C3b E2E-3 suite above,
# but against an AUTH-VALIDATING fake server that actually inspects the
# `Authorization` header per verb (`E2E3Server`'s reply queue returns
# whatever a test scripts regardless of the request -- this double decides
# for itself, modeling a real server's read/write credential split). Per-
# status verdict-mapping is exhaustively unit-tested in
# test_cachehttp.nim's own C6 blocks; this suite's job is proving the
# WIRING carries a real read-scoped (or write-scoped) token, resolved
# exactly the way `api.resolveCacheSecrets`/`cacheregistry.httpTokenFor`
# resolve it, through a real run, end to end.
# ---------------------------------------------------------------------------

type
  E2E3AuthServer = ref object
    calls*: seq[HttpRequest]
    readTokens: seq[string]
    writeTokens: seq[string]
    getStatus: int
    getBody: string

proc newE2E3AuthServer(readTokens, writeTokens: seq[string];
                        getStatus = 404; getBody = ""): E2E3AuthServer =
  E2E3AuthServer(calls: @[], readTokens: readTokens, writeTokens: writeTokens,
                  getStatus: getStatus, getBody: getBody)

proc e2e3AuthBearer(req: HttpRequest): string =
  for (k, v) in req.headers:
    if k == "Authorization" and v.startsWith("Bearer "):
      return v["Bearer ".len .. ^1]
  ""

proc e2e3AuthFetcher(fs: E2E3AuthServer): HttpFetcher =
  result = proc(req: HttpRequest): HttpReply =
    fs.calls.add req
    let token = e2e3AuthBearer(req)
    case req.meth
    of "GET":
      if token in fs.readTokens or token in fs.writeTokens:
        e2e3OkReply(fs.getStatus, fs.getBody)
      else:
        e2e3OkReply(403)
    of "PUT":
      if token in fs.writeTokens:
        e2e3OkReply(200)
      else:
        e2e3OkReply(403)
    else:
      e2e3OkReply(400)

proc e2e3AuthDeps(fs: E2E3AuthServer; token: string): CacheDeps =
  let secrets = CacheSecrets(defaultHttpToken: some(token))
  CacheDeps(buildRuntime: proc(cfg: CacheConfig; stateDir: string; maxEntries: int): CacheRuntime =
    configuredCache(cfg, stateDir, maxEntries, testRegistry(fs.e2e3AuthFetcher),
                    secrets, NilSink[TelemetryEvent]()))

suite "RFC-0005 C6 -- secure-by-default credential scopes end to end (auth-validating fake server)":

  test "read-only token: GET hit serves normally, cacheTier == the configured name":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3AuthServer(readTokens = @["read-tok"], writeTokens = @["write-tok"],
                                  getStatus = 200, getBody = e2e3EncodedHitBody())
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let rr = runTestsWith(opts, e2e3AuthDeps(fs, "read-tok"))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmHit
      check rr.results[0].cacheTier == "mirror"
      check rr.results[0].cacheLookup == cvOk
      check fs.calls.len == 1
      check fs.calls[0].meth == "GET"

  test "read-only token: publish attempt refused (403) -> local store succeeds, run stays green, " &
       "breaker does not latch (a second entrypoint's publish is still attempted)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "tests" / "unit" / "test_b.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3AuthServer(readTokens = @["read-tok"], writeTokens = @["write-tok"])
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let rr = runTestsWith(opts, e2e3AuthDeps(fs, "read-tok"))
      check rr.status == rsOk
      check rr.results.len == 2
      for r in rr.results:
        check r.cacheDecision == cdmStored  # l1 wrote fine regardless of the remote refusal
      check rr.cacheStats.remoteErrors == 2  # each entrypoint's refused remote flush accounted
      check rr.cacheStats.published == 2     # l1's OWN publish still fires -- unaffected by the
                                              # remote refusal (tekPublish/tier "l1" is emitted at
                                              # live finalize, before the remote is ever touched)
      # Each entrypoint costs its own GET(miss)+PUT(refused): 2 entrypoints *
      # 2 calls = 4 -- NOT collapsed to fewer calls the way the plain-offline
      # E2E-3 scenario above collapses to 1. That collapse is the circuit
      # breaker; its ABSENCE here is the proof that cvUnauthorized never
      # trips it (cachetier.nim's tripBreaker only latches on
      # {cvOffline, cvTimeout} -- unit-proven directly in test_cachetier.nim).
      check fs.calls.len == 4

  test "write token: publish succeeds -> l1 AND remote publish both counted, no remoteErrors":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", RemoteCacheProjectFixture)
      writeFile(projectRoot / "crisol.kdl", E2E3SingleTestKdl)
      let fs = newE2E3AuthServer(readTokens = @["read-tok"], writeTokens = @["write-tok"])
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", cacheStats: true)
      let rr = runTestsWith(opts, e2e3AuthDeps(fs, "write-tok"))
      check rr.status == rsOk
      check rr.results.len == 1
      check rr.results[0].cacheDecision == cdmStored
      check fs.calls.len == 2
      check fs.calls[0].meth == "GET"
      check fs.calls[1].meth == "PUT"
      check rr.cacheStats.published == 2  # tier "l1" at live finalize + tier "mirror" at the
                                           # end-of-run deferred-put flush -- the write token
                                           # actually authorized the remote half this time.
      check rr.cacheStats.remoteErrors == 0

# ---------------------------------------------------------------------------
# R14-T6 (code review) — RunReport.compileBlock presence-gating expression.
# api.nim gates the compile block on `measureCompileReuse` alone. A
# regression that hardcoded this to `false` would silently drop the report
# whenever measurement is requested -- covered here both as a cheap pure
# predicate test and as a real end-to-end proof.
# ---------------------------------------------------------------------------

suite "shouldReportCompileBlock — pure gate (R14-T6)":

  test "false -> false":
    check shouldReportCompileBlock(false) == false

  test "measureCompileReuse alone -> true":
    check shouldReportCompileBlock(true) == true

suite "RunReport.compileBlock presence — R14-T6 end-to-end":

  proc buildCrisolBinaryForApiTest(): string =
    ## Mirrors tests/integration/test_measure_compile_gate.nim's
    ## buildCrisolBinary(): --measure-compile-reuse's self-reexec worker is
    ## only sound when the currently running process dispatches the
    ## internal token, which is true of the real crisol CLI binary, never of
    ## an arbitrary unittest binary (see that file's module doc for the full
    ## fork-bomb-hazard rationale) -- so proving "telemetry exists"
    ## end-to-end needs the real binary as RunOptions.workerBinary, exactly
    ## as the integration gate tests already do.
    let crisolRoot = currentSourcePath().parentDir.parentDir.parentDir
    result = getTempDir() / "crisol_test_api_r14t6_bin" / "crisol"
    createDir(result.parentDir)
    let cmd = "nim c --hints:off --warnings:off -d:release --mm:orc -o:" &
              result.quoteShell & " " & (crisolRoot / "src" / "crisol.nim").quoteShell
    let (output, code) = execCmdEx(cmd)
    doAssert code == 0, "failed to build crisol binary for R14-T6 test: " & output
    doAssert fileExists(result), "crisol binary not produced at " & result

  let crisolBinForApi = buildCrisolBinaryForApiTest()

  test "measureCompileReuse not set -> compileBlock absent (nil)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      check rr.status == rsOk
      check rr.compileBlock == nil

  test "measureCompileReuse=true, sound worker -> compileBlock present":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(
        configPath:          projectRoot / "crisol.kdl",
        measureCompileReuse: true,
        workerBinary:        crisolBinForApi,
      ))
      check rr.status == rsOk
      check rr.compileBlock != nil
      check rr.compileBlock.hasKey("segments")

  test "measureCompileReuse=true but workerBinary UNSET -> gate true but degrades monolithically -> no telemetry written -> compileBlock absent (nil)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(
        configPath:          projectRoot / "crisol.kdl",
        measureCompileReuse: true,
      ))
      check rr.status == rsOk
      check rr.compileBlock == nil
