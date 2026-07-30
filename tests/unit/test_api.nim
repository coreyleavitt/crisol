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

import std/[json, os, osproc, strutils, times, unittest]
import crisol/api
import crisol/types

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
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"),
          outcome: oFailed,
        ),
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_b.nim", group: "unit"),
          outcome: oPassed,
        ),
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
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"),
          outcome: oPassed,
        ),
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
          ep:      Entrypoint(path: "tests/unit/test_a.nim", group: "unit"),
          outcome: oPassed,
        ),
        EntrypointResult(
          ep:      Entrypoint(path: "tests/unit/test_b.nim", group: "unit"),
          outcome: oFailed,
        ),
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
# resolveObjCache — RFC-0006 Stage R, R2b2: pure precedence resolution for
# Config.objCache from a config-file value plus RunOptions overrides.
# Precedence (highest wins): --no-objcache > --objcache/config-true > configValue.
#
# The formula itself, `(optIn or configValue) and not optOut`, is UNCHANGED
# by the default-on flip -- re-verified below, cell by cell. What changed is
# the CALLER: config.loadConfig now feeds this function configValue=true
# when the KDL `objcache` node is absent (docToConfig's local default flipped
# true; see test_config.nim's "absent objcache -> cfg.objCache == true"). So
# the case previously labeled "the default" (all-false) is now just one
# valid data point -- an explicit `objcache #false` config block with no CLI
# overrides -- and "configValue alone -> true" is now the scenario that
# actually reflects the NEW default (absent config -> configValue=true).
# ---------------------------------------------------------------------------

suite "resolveObjCache — objcache precedence (RFC-0006 Stage R R2b2, re-verified for default-on)":

  test "configValue=false (explicit objcache #false), no CLI overrides -> false":
    check resolveObjCache(configValue = false, optIn = false, optOut = false) == false

  test "optIn alone -> true":
    check resolveObjCache(configValue = false, optIn = true, optOut = false) == true

  test "configValue=true (the NEW default when KDL objcache node is absent, or explicit objcache #true), no CLI overrides -> true":
    check resolveObjCache(configValue = true, optIn = false, optOut = false) == true

  test "optOut overrides optIn -> false":
    check resolveObjCache(configValue = false, optIn = true, optOut = true) == false

  test "optOut overrides configValue -> false (--no-objcache wins even against the new default-on configValue)":
    check resolveObjCache(configValue = true, optIn = false, optOut = true) == false

  test "optOut overrides BOTH optIn and configValue -> false":
    check resolveObjCache(configValue = true, optIn = true, optOut = true) == false

  test "optOut alone (configValue and optIn both false) -> false":
    check resolveObjCache(configValue = false, optIn = false, optOut = true) == false

# ---------------------------------------------------------------------------
# Issue-1 fix — effective objCache (as planImpl actually computes it):
# `resolveObjCache(configValue, optIn, optOut) and not measureCompileReuse`.
# resolveObjCache itself stays measureCompileReuse-agnostic (single-purpose,
# unit-tested above); the composed formula below is planImpl's ACTUAL line
# (api.nim, `cfg.objCache = resolveObjCache(...) and not cfg.measureCompileReuse`),
# mirrored here as a pure function so the suppression is independently
# unit-testable without going through config loading or a real compile --
# same rationale resolveObjCache itself was extracted for.
# ---------------------------------------------------------------------------

suite "effective objCache — measure-compile-reuse suppression (Issue-1 fix)":

  proc effectiveObjCache(configValue, optIn, optOut, measureCompileReuse: bool): bool =
    ## Mirrors planImpl's exact composition (api.nim): resolveObjCache's
    ## precedence formula, then suppressed to false whenever measurement is
    ## requested. Kept LOCAL to this test (not exported from api.nim) --
    ## it's a one-line composition of an already-tested pure function, not a
    ## new public seam.
    resolveObjCache(configValue, optIn, optOut) and not measureCompileReuse

  test "measureCompileReuse=true suppresses an otherwise-true objCache (default-on config, no explicit flags)":
    check effectiveObjCache(configValue = true, optIn = false, optOut = false,
                            measureCompileReuse = true) == false

  test "measureCompileReuse=true suppresses an explicit --objcache too":
    check effectiveObjCache(configValue = false, optIn = true, optOut = false,
                            measureCompileReuse = true) == false

  test "measureCompileReuse=false leaves resolveObjCache's result untouched (true case)":
    check effectiveObjCache(configValue = true, optIn = false, optOut = false,
                            measureCompileReuse = false) == true

  test "measureCompileReuse=false leaves resolveObjCache's result untouched (false case)":
    check effectiveObjCache(configValue = false, optIn = false, optOut = false,
                            measureCompileReuse = false) == false

  test "measureCompileReuse=true over an already-false objCache stays false (no-op suppression)":
    check effectiveObjCache(configValue = false, optIn = false, optOut = true,
                            measureCompileReuse = true) == false

# ---------------------------------------------------------------------------
# R13 (code review, RFC-0006) — an explicit --objcache / --measure-compile-
# reuse request that will silently degrade to the monolithic compile path
# (no workerBinary configured) must be visible in the STRUCTURED warnings
# channel, not just runner.nim's one-shot stderr write. A CI consumer whose
# stderr is swallowed would otherwise see a complete, silent no-op of a
# feature it explicitly asked for -- compileBlock simply absent from the
# report, indistinguishable from "nobody asked".
# ---------------------------------------------------------------------------

suite "R13 — objcache/measure-compile-reuse requested with no workerBinary surfaces a structured warning":

  test "planTests: objCache=true, workerBinary unset -> structured warning (context=objcache, key=workerBinary)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", objCache: true)
      let pr = planTests(opts)
      var found = false
      for w in pr.warnings:
        if w.context == "objcache" and w.key == "workerBinary":
          found = true
          check "no worker binary" in w.message.toLowerAscii or
                "not honored" in w.message.toLowerAscii
      check found

  test "planTests: measureCompileReuse=true, workerBinary unset -> structured warning (context=measure-compile-reuse, key=workerBinary)":
    withTempProject:
      # Issue-1 fix (default-on objCache starving --measure-compile-reuse):
      # planImpl now suppresses cfg.objCache to false whenever
      # cfg.measureCompileReuse resolves true, so measureCompileReuse alone
      # is ENOUGH to isolate this test from objCache's now-default-on state
      # -- noObjCache is kept anyway as belt-and-suspenders documentation of
      # intent (explicitly, not just implicitly, off), not because it's
      # load-bearing anymore.
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            measureCompileReuse: true, noObjCache: true)
      let pr = planTests(opts)
      var found = false
      for w in pr.warnings:
        if w.context == "measure-compile-reuse" and w.key == "workerBinary":
          found = true
      check found

  test "planTests: workerBinary SET -> no workerBinary warning (sound path, nothing to warn about)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            objCache: true, workerBinary: "/usr/bin/true")
      let pr = planTests(opts)
      for w in pr.warnings:
        check w.key != "workerBinary"

  test "planTests: neither objCache nor measureCompileReuse explicitly requested, workerBinary unset -> objCache's now-default-on state STILL surfaces the workerBinary warning (RFC-0006 default-on flip: 'not set' no longer means 'off')":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let pr = planTests(opts)
      var found = false
      for w in pr.warnings:
        if w.context == "objcache" and w.key == "workerBinary":
          found = true
      check found

  test "planTests: --no-objcache (genuine opt-out), measureCompileReuse also unset, workerBinary unset -> no workerBinary warning at all":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", noObjCache: true)
      let pr = planTests(opts)
      for w in pr.warnings:
        check w.key != "workerBinary"

  test "planTests: BOTH objCache and measureCompileReuse true, workerBinary unset -> exactly ONE workerBinary warning, now carrying measure-compile-reuse's context (Issue-1 fix: measurement wins, not objcache)":
    ## Precedence INVERTED by the Issue-1 fix: cfg.objCache is suppressed to
    ## false whenever cfg.measureCompileReuse is true (planImpl, above), so
    ## by the time the no-workerBinary check runs, only the
    ## measure-compile-reuse branch can ever fire -- objcache's own
    ## no-workerBinary warning is structurally unreachable when both flags
    ## are requested together. The "exactly ONE" invariant survives the
    ## precedence flip (still only one of the two mutually-exclusive workers
    ## can be the slot's compile child), but WHICH one now differs.
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            objCache: true, measureCompileReuse: true)
      let pr = planTests(opts)
      var count = 0
      var sawMeasureContext = false
      for w in pr.warnings:
        if w.key == "workerBinary":
          inc count
          if w.context == "measure-compile-reuse": sawMeasureContext = true
      check count == 1
      check sawMeasureContext

  test "planTests: BOTH --objcache and --measure-compile-reuse EXPLICITLY requested (contradictory) -> a distinct ConfigWarning says objcache is ignored during measurement":
    ## New warning (Issue-1 fix): distinct from the workerBinary-absent
    ## warnings above -- fires purely because the CALLER explicitly asked
    ## for both mutually-exclusive modes on the same run, independent of
    ## whether a sound workerBinary is configured.
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            objCache: true, measureCompileReuse: true)
      let pr = planTests(opts)
      var found = false
      for w in pr.warnings:
        if w.context == "objcache" and w.key == "measure-compile-reuse":
          found = true
          check "ignored" in w.message.toLowerAscii or
                "precedence" in w.message.toLowerAscii
      check found

  test "planTests: --objcache explicit + --measure-compile-reuse explicit + workerBinary SET -> only the contradictory-flags warning fires (no workerBinary warning; the sound path)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            objCache: true, measureCompileReuse: true,
                            workerBinary: "/usr/bin/true")
      let pr = planTests(opts)
      var sawContradiction = false
      for w in pr.warnings:
        check w.key != "workerBinary"   # sound worker -> that class never fires
        if w.context == "objcache" and w.key == "measure-compile-reuse":
          sawContradiction = true
      check sawContradiction

  test "planTests: objCache NOT explicitly requested (default-on only) + --measure-compile-reuse explicit -> NO contradictory-flags warning (the default silently steps aside, not a user contradiction)":
    withTempProject:
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                            measureCompileReuse: true,
                            workerBinary: "/usr/bin/true")
      let pr = planTests(opts)
      for w in pr.warnings:
        check not (w.context == "objcache" and w.key == "measure-compile-reuse")

  test "runTests: objCache=true, workerBinary unset -> run still succeeds monolithically AND the warning is present on RunReport.plan.warnings":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl", objCache: true)
      let rr = runTests(opts)
      check rr.status == rsOk
      check rr.exitCode == 0
      check rr.results.len == 1
      check rr.results[0].outcome == oPassed
      var found = false
      for w in rr.plan.warnings:
        if w.context == "objcache" and w.key == "workerBinary":
          found = true
      check found

  test "LIBRARY-SAFETY (RFC-0006 default-on flip): runTests() with NO objCache/noObjCache/workerBinary set at all still succeeds monolithically (no fork-bomb, no hard-fail); the default-on request is visible via the structured warning":
    ## The most important regression the default-on flip introduces: a
    ## library consumer that never touches RunOptions.objCache/workerBinary
    ## at all (the overwhelming common case pre-flip) now gets objCache=true
    ## from the config default rather than false. spawnCompileStable's
    ## no-worker degrade path (never calling getAppFilename() on the host's
    ## behalf — see types.Config.workerBinary's doc) must still apply: this
    ## run must compile and run normally, monolithically, exactly as it did
    ## before the flip, and must NOT hang/fork-bomb/hard-fail. The one
    ## observable difference is the new R13 structured warning, present here
    ## specifically because objCache is now ON by default with no worker
    ## configured.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let opts = RunOptions(configPath: projectRoot / "crisol.kdl")
      let t0 = epochTime()
      let rr = runTests(opts)
      let elapsed = epochTime() - t0
      check rr.status == rsOk
      check rr.exitCode == 0
      check rr.results.len == 1
      check rr.results[0].outcome == oPassed
      check elapsed < 30.0  # a fork-bomb would hang until the compile watchdog fires
      var found = false
      for w in rr.plan.warnings:
        if w.context == "objcache" and w.key == "workerBinary":
          found = true
      check found

# ---------------------------------------------------------------------------
# R14-T6 (code review) — RunReport.compileBlock presence-gating expression.
# api.nim gates the compile block on `measureCompileReuse or objCache` (R5b
# fixed this from a narrower gate once already). A regression flipping
# `or` -> `and` would silently drop the report whenever only ONE flag is
# set (e.g. a plain --objcache run) -- covered here both as a cheap pure
# predicate test and as a real end-to-end proof across flag combinations.
# ---------------------------------------------------------------------------

suite "shouldReportCompileBlock — pure gate (R14-T6)":

  test "both false -> false":
    check shouldReportCompileBlock(false, false) == false

  test "measureCompileReuse alone -> true":
    check shouldReportCompileBlock(true, false) == true

  test "objCache alone -> true (the EXACT case an or->and regression would break)":
    check shouldReportCompileBlock(false, true) == true

  test "both true -> true":
    check shouldReportCompileBlock(true, true) == true

suite "RunReport.compileBlock presence — R14-T6 end-to-end across flag combinations":

  proc buildCrisolBinaryForApiTest(): string =
    ## Mirrors tests/integration/test_measure_compile_gate.nim's
    ## buildCrisolBinary(): --objcache/--measure-compile-reuse's self-reexec
    ## worker is only sound when the currently running process dispatches
    ## the internal token, which is true of the real crisol CLI binary,
    ## never of an arbitrary unittest binary (see that file's module doc for
    ## the full fork-bomb-hazard rationale) -- so proving "telemetry exists"
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

  test "neither flag set -> compileBlock absent (nil)":
    ## objCache now defaults ON (RFC-0006 Stage R flip), so
    ## shouldReportCompileBlock's gate is actually TRUE here -- but no
    ## workerBinary is configured, so the cache worker never dispatches, no
    ## telemetry stream is ever written, and buildCompileBlock's own
    ## nil-when-empty contract still yields nil. The gate answering "should
    ## we look" and there being data to find are independent, exactly as
    ## shouldReportCompileBlock's doc comment says.
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(configPath: projectRoot / "crisol.kdl"))
      check rr.status == rsOk
      check rr.compileBlock == nil

  test "measureCompileReuse=true alone, sound worker -> compileBlock present":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      # noObjCache=true kept as explicit documentation of intent; no longer
      # load-bearing after the Issue-1 fix (measureCompileReuse now suppresses
      # the now-default-on objCache automatically -- see the "effective
      # objCache" suite above).
      let rr = runTests(RunOptions(
        configPath:          projectRoot / "crisol.kdl",
        measureCompileReuse: true,
        noObjCache:          true,
        workerBinary:        crisolBinForApi,
      ))
      check rr.status == rsOk
      check rr.compileBlock != nil
      check rr.compileBlock.hasKey("segments")

  test "objCache=true ALONE (measureCompileReuse false), sound worker -> compileBlock present (the exact or->and regression case)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(
        configPath:   projectRoot / "crisol.kdl",
        objCache:     true,
        workerBinary: crisolBinForApi,
      ))
      check rr.status == rsOk
      check rr.compileBlock != nil
      check rr.compileBlock.hasKey("objcache")

  test "both flags true, sound worker -> compileBlock present, and it's the MEASURE worker's shape (Issue-1 fix: measurement wins over objcache)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(
        configPath:          projectRoot / "crisol.kdl",
        objCache:            true,
        measureCompileReuse: true,
        workerBinary:        crisolBinForApi,
      ))
      check rr.status == rsOk
      check rr.compileBlock != nil
      # The measure worker's own telemetry (compilecost -> segments) is
      # present; the cache worker's telemetry (objcachestats -> "objcache")
      # is absent -- the observable proof that measurement, not caching, was
      # the slot's compile child when both were explicitly requested.
      check rr.compileBlock.hasKey("segments")
      check not rr.compileBlock.hasKey("objcache")
      var sawContradiction = false
      for w in rr.plan.warnings:
        if w.context == "objcache" and w.key == "measure-compile-reuse":
          sawContradiction = true
      check sawContradiction

  test "flag set but workerBinary UNSET -> gate true but degrades monolithically -> no telemetry written -> compileBlock absent (nil)":
    withTempProject:
      writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "echo \"ok\"\n")
      let rr = runTests(RunOptions(
        configPath: projectRoot / "crisol.kdl",
        objCache:   true,
      ))
      check rr.status == rsOk
      check rr.compileBlock == nil
