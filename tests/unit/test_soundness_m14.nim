## test_soundness_m14.nim — M14: changedFiles must include untracked (un-staged) files.
##
## Bug: changedFiles uses `git diff --name-only HEAD` which only reports
## tracked-file changes. A newly created, not-yet-`git add`-ed .nim file that
## a test now imports is invisible → not in changedFiles → not in closure intersection
## → entrypoint not selected → under-selection.
##
## Fix: also run `git ls-files --others --exclude-standard` to get untracked-but-not-
## ignored files, and union them into changedFiles.

import std/[os, osproc, sets, strutils]
import crisol/types
import crisol/gitdiff

proc initGitRepo(dir: string) =
  ## Initialize a bare git repo with an initial commit.
  createDir(dir)
  discard execCmdEx("git init", workingDir = dir)
  discard execCmdEx("git config user.email test@example.com", workingDir = dir)
  discard execCmdEx("git config user.name Test", workingDir = dir)
  # Create an initial commit so HEAD exists
  writeFile(dir / "README.md", "# test")
  discard execCmdEx("git add README.md", workingDir = dir)
  discard execCmdEx("git commit -m 'init'", workingDir = dir)

block test_m14_untracked_file_included:
  ## Create a git repo, then add an un-staged new file.
  ## changedFiles must include it.
  let repoDir = getTempDir() / "crisol_m14_a"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  # Create a new file that is NOT added to git (untracked, not ignored)
  let newFile = repoDir / "src" / "new_untracked.nim"
  createDir(repoDir / "src")
  writeFile(newFile, "# new untracked")

  let changed = changedFiles(repoDir)
  assert "src/new_untracked.nim" in changed,
    "M14: untracked new file must appear in changedFiles. Got: " & $changed

block test_m14_gitignored_file_not_included:
  ## An untracked file that matches .gitignore must NOT be included.
  let repoDir = getTempDir() / "crisol_m14_b"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  # Create a .gitignore that ignores *.tmp files
  writeFile(repoDir / ".gitignore", "*.tmp\n")
  discard execCmdEx("git add .gitignore", workingDir = repoDir)
  discard execCmdEx("git commit -m 'add gitignore'", workingDir = repoDir)

  # Create an ignored file
  let ignoredFile = repoDir / "temp.tmp"
  writeFile(ignoredFile, "# ignored")

  let changed = changedFiles(repoDir)
  assert "temp.tmp" notin changed,
    "M14: gitignored untracked file must NOT appear in changedFiles. Got: " & $changed

block test_m14_tracked_modified_file_still_included:
  ## Regression: tracked files that are modified still appear.
  let repoDir = getTempDir() / "crisol_m14_c"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  # Modify the tracked README.md
  writeFile(repoDir / "README.md", "# changed")

  let changed = changedFiles(repoDir)
  assert "README.md" in changed,
    "M14: modified tracked file must still appear in changedFiles. Got: " & $changed

block test_m14_clean_repo_no_phantom_untracked:
  ## A completely clean repo with no untracked files → changedFiles is empty.
  let repoDir = getTempDir() / "crisol_m14_d"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  let changed = changedFiles(repoDir)
  # Only README.md is committed and unchanged; no untracked files.
  assert "README.md" notin changed,
    "M14: clean tracked file must not appear as changed. Got: " & $changed

block test_p2_dash_ref_rejected_before_git_invocation:
  ## P2: a --base ref beginning with '-' must be rejected with cekEnvironment
  ## before any git invocation, to prevent git flag-injection.
  ## We use a real git repo so the path past the probe check is exercised,
  ## but the rejection must happen before changedFiles ever calls `git diff`.
  let repoDir = getTempDir() / "crisol_p2_a"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  var caught = false
  var kind: CrisolErrorKind
  var msg = ""
  try:
    discard changedFiles(repoDir, base = "--output=/tmp/evil")
  except CrisolError as e:
    caught = true
    kind = e.kind
    msg = e.msg

  assert caught, "P2: dash-leading ref must raise CrisolError"
  assert kind == cekEnvironment, "P2: kind must be cekEnvironment, got " & $kind
  assert "--base" in msg or "ref" in msg,
    "P2: error message must mention the flag, got: " & msg

block test_p2_single_dash_also_rejected:
  ## A single '-' is also a git flag prefix; must be rejected.
  let repoDir = getTempDir() / "crisol_p2_b"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  var caught = false
  try:
    discard changedFiles(repoDir, base = "-p")
  except CrisolError:
    caught = true
  assert caught, "P2: single-dash ref '-p' must raise CrisolError"

block test_p2_normal_ref_still_accepted:
  ## A normal SHA-like or branch-like ref must NOT be rejected.
  ## Use "HEAD" which exists in our freshly-initialised repo.
  let repoDir = getTempDir() / "crisol_p2_c"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  # Should not raise — HEAD is a valid ref, starts with 'H' not '-'.
  var raised = false
  try:
    discard changedFiles(repoDir, base = "HEAD")
  except CrisolError:
    raised = true
  assert not raised, "P2: normal ref 'HEAD' must not be rejected"

echo "PASS test_soundness_m14"
