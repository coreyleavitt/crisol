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

import std/[os, osproc, strutils, unittest]
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
