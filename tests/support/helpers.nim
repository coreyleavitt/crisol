## tests/support/helpers.nim — shared S1a-prep test helpers for api boundary tests.
##
## These are built once (S1a-prep) and reused across S1c–S2d so each slice
## does not reinvent setup.
##
## Exported:
##
##   withTempProject(body): template
##     Creates a minimal valid crisol fixture project under a temp directory,
##     executes `body` with the project root injected as `projectRoot: string`,
##     then tears down the temp dir (deferred).
##     The minimal config declares a single "unit" group with a glob that can
##     match real fixture binaries placed under <root>/tests/unit/.
##
##   seedLastRun(projectRoot, results): void
##     Write lastrun.json via the real persistLastRun so that failedOnly()
##     narrowing tests have valid prior-run state without hand-written JSON
##     (schema drift would make loadLastRun raise).

import std/[os, osproc, tempfiles]
import crisol/[types, config, jsonout]

# ---------------------------------------------------------------------------
# Minimal crisol.kdl content for fixture projects
# ---------------------------------------------------------------------------

const MinimalCrisolKdl* = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

# ---------------------------------------------------------------------------
# withTempProject — temp root + minimal config + state dir + teardown
# ---------------------------------------------------------------------------

template withTempProject*(body: untyped): untyped =
  ## Creates a temp directory tree suitable for planTests/runTests fixture use.
  ##
  ## Injects `projectRoot: string` into the body scope — the absolute path to
  ## the temp project root.  Tears down on exit (deferred removeDir).
  ##
  ## Layout created:
  ##   <root>/crisol.kdl          — minimal valid config
  ##   <root>/.crisol/            — state dir (created so persistLastRun works)
  ##   <root>/tests/unit/         — empty; callers add fixture binaries as needed
  let projectRoot {.inject.} = createTempDir("crisol_api_test_", "")
  defer: removeDir(projectRoot)

  # Write minimal config.
  writeFile(projectRoot / "crisol.kdl", MinimalCrisolKdl)

  # Pre-create state dir so persistLastRun / loadLastRun do not fail on a
  # missing parent directory in tests that call seedLastRun.
  createDir(projectRoot / ".crisol")

  # Pre-create tests/unit/ so discover() finds the glob dir.
  createDir(projectRoot / "tests" / "unit")

  body

# ---------------------------------------------------------------------------
# seedLastRun — write lastrun.json via persistLastRun (never hand-written JSON)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# withTempGitProject — temp root + git init + minimal config + state dir
# ---------------------------------------------------------------------------

template withTempGitProject*(body: untyped): untyped =
  ## Like withTempProject but also runs `git init` so changedFiles tests have a
  ## real git work tree.  Injects `gitRoot: string` into the body scope.
  ##
  ## Layout created:
  ##   <root>/crisol.kdl          — minimal valid config
  ##   <root>/.crisol/            — state dir
  ##   <root>/tests/unit/         — empty; callers add fixture files as needed
  ##   <root>/.git/               — git-init'd with a dummy identity
  let gitRoot {.inject.} = createTempDir("crisol_git_test_", "")
  defer: removeDir(gitRoot)

  # Write minimal config.
  writeFile(gitRoot / "crisol.kdl", MinimalCrisolKdl)
  createDir(gitRoot / ".crisol")
  createDir(gitRoot / "tests" / "unit")

  # Git init with minimal identity so commits work in the container.
  discard execCmdEx("git init -q", workingDir = gitRoot)
  discard execCmdEx("git config user.email crisol@test.local", workingDir = gitRoot)
  discard execCmdEx("git config user.name crisol-test", workingDir = gitRoot)
  discard execCmdEx("git config commit.gpgsign false", workingDir = gitRoot)

  # Initial commit so HEAD exists (git diff vs HEAD needs at least one commit).
  writeFile(gitRoot / ".gitkeep", "")
  discard execCmdEx("git add -A", workingDir = gitRoot)
  discard execCmdEx("git commit -m root", workingDir = gitRoot)

  body

# ---------------------------------------------------------------------------
# seedLastRun — write lastrun.json via persistLastRun (never hand-written JSON)
# ---------------------------------------------------------------------------

proc seedLastRun*(projectRoot: string; results: seq[EntrypointResult];
                  summary: Summary = Summary()) =
  ## Persist a prior run's results under <projectRoot>/.crisol/lastrun.json
  ## by calling the real persistLastRun.
  ##
  ## Always uses the default DefaultStateDir (".crisol") relative to projectRoot.
  ## Callers should use withTempProject so the state dir already exists.
  let cfg = Config(
    projectRoot: projectRoot,
    stateDir:    DefaultStateDir,
    timeoutSecs: DefaultTimeoutSecs,
  )
  persistLastRun(results, summary, cfg)
