## gitdiff.nim — D5: changed-file extraction for impact selection.
##
## `changedFiles` calls git directly (via `osproc.startProcess` with an
## explicit `args` sequence and `workingDir = projectRoot`) to produce the
## set of project-root-relative paths that differ from a reference.  It is
## the I/O bridge that feeds `narrow.narrowByDiff` (the pure selection
## function).
##
## ## Git commands
##
## First, a repo probe (so a clear cekEnvironment error replaces git's own
## terse diagnostics):
##   `git rev-parse --is-inside-work-tree`
##
## Then the diff:
##   - No base → `git diff --no-renames --name-only --relative HEAD`
##       (all tracked modifications, staged + unstaged, vs the last commit)
##   - With base → `git diff --no-renames --name-only --relative <base>`
##       (working tree vs <base> — deliberately includes uncommitted edits;
##        over-selection is safe, under-selection is not)
##
## `--no-renames` is always present so a rename surfaces as delete + add.
## `--relative` makes git emit paths relative to the cwd (projectRoot), which
## is exactly the key shape the dep graph stores.
##
## ## Errors
##
## If `projectRoot` is not an existing directory, or git is missing, or the
## directory is not a git work tree, a `CrisolError(cekEnvironment, …)` is
## raised.  The CLI maps that to exit 3, consistent with every other
## environment failure.

import std/[os, osproc, sets, streams, strutils]  # process-contract-exempt: git is a short-lived tool invocation, not a compile/run child (RFC-0007 §Scope)
import crisol/types

# ---------------------------------------------------------------------------
# Internal helper: run git without a shell
# ---------------------------------------------------------------------------

proc runGit(args: seq[string]; workingDir: string): tuple[output: string; exitCode: int] =
  ## Invoke `git <args>` in `workingDir` without a shell intermediary.
  ## Uses `poUsePath` so `git` is found via PATH; `poStdErrToStdOut` merges
  ## stderr into the captured output so diagnostics are visible.
  ## Returns (output, exitCode); raises OSError if git cannot be exec'd at all.
  let p = startProcess("git", workingDir = workingDir, args = args,
                        options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  let output = p.outputStream.readAll()
  let code   = waitForExit(p)
  result = (output: output, exitCode: code)

# ---------------------------------------------------------------------------
# Public: changedFiles
# ---------------------------------------------------------------------------

proc changedFiles*(projectRoot: string; base: string = ""): HashSet[string] =
  ## Return the set of project-root-relative paths that git reports as changed.
  ##
  ## `base == ""` → diff working tree vs HEAD (staged + unstaged).
  ## `base != ""` → diff working tree vs the given ref.
  ##
  ## Raises `CrisolError(cekEnvironment, …)` when:
  ##   - `projectRoot` is empty or does not exist as a directory
  ##   - git is unavailable
  ##   - the directory is not a git work tree
  result = initHashSet[string]()

  # Validate projectRoot before touching git so the caller gets a clear
  # message rather than an opaque shell error.
  if projectRoot.len == 0 or not dirExists(projectRoot):
    raise newCrisolError(cekEnvironment,
      "projectRoot '" & projectRoot & "' is not an existing directory — " &
      "cannot invoke git")

  # Probe: is this a git work tree?  This both confirms `git` exists and that
  # projectRoot is inside a repository, so we can give a clear message instead
  # of letting git's own diagnostics leak through.
  var probeOut: string
  var probeCode: int
  try:
    (probeOut, probeCode) = runGit(
      @["rev-parse", "--is-inside-work-tree"],
      workingDir = projectRoot)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "git is not available (could not execute 'git'): " & e.msg)
  except Exception as e:
    raise newCrisolError(cekEnvironment,
      "git is not available (could not execute 'git'): " & e.msg)

  if probeCode != 0 or probeOut.strip() != "true":
    raise newCrisolError(cekEnvironment,
      "'" & projectRoot & "' is not a git repository — " &
      "--changed requires a git work tree")

  # Build the diff argv.
  let baseRef = base.strip()
  # Reject refs that start with '-': although startProcess uses argv (no shell,
  # so no shell injection), git itself interprets a leading '-' as a flag, e.g.
  # `--output=/path` would silently redirect git's output to an attacker-chosen
  # path with the user's permissions.
  if baseRef.len > 0 and baseRef[0] == '-':
    raise newCrisolError(cekEnvironment,
      "--base: ref must not start with '-': '" & baseRef & "'")
  let diffArgs =
    if baseRef.len == 0:
      @["diff", "--no-renames", "--name-only", "--relative", "HEAD"]
    else:
      @["diff", "--no-renames", "--name-only", "--relative", baseRef]

  var diffOut: string
  var diffCode: int
  try:
    (diffOut, diffCode) = runGit(diffArgs, workingDir = projectRoot)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "git diff failed to execute: " & e.msg)
  except Exception as e:
    raise newCrisolError(cekEnvironment,
      "git diff failed to execute: " & e.msg)

  if diffCode != 0:
    raise newCrisolError(cekEnvironment,
      "git diff exited with code " & $diffCode & ": " & diffOut.strip())

  for line in diffOut.splitLines():
    let p = line.strip()
    if p.len > 0:
      result.incl p

  # M14 soundness: include untracked-but-not-ignored files.
  # `git diff --name-only HEAD` only reports tracked-file changes.  A newly
  # created, not-yet-`git add`-ed .nim file that a test now imports is invisible
  # to `git diff` but is still a real source dependency.  Including untracked
  # files here ensures they appear in changedFiles so the closure∩diff
  # intersection can select the right entrypoints.
  #
  # `git ls-files --others --exclude-standard` lists untracked files that are
  # not excluded by .gitignore, .git/info/exclude, etc.  The output is relative
  # to the cwd (projectRoot), matching the key shape used elsewhere.
  var untrackedOut: string
  var untrackedCode: int
  try:
    (untrackedOut, untrackedCode) = runGit(
      @["ls-files", "--others", "--exclude-standard"],
      workingDir = projectRoot)
  except:
    # Best-effort: if ls-files fails for any reason, ignore (safe: over-selection
    # is not possible here; we just miss some untracked files).
    untrackedCode = -1

  if untrackedCode == 0:
    for line in untrackedOut.splitLines():
      let p = line.strip()
      if p.len > 0:
        result.incl p
