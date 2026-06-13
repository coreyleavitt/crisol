## test_soundness_m9.nim — M9: changedFiles must validate projectRoot and
## must not invoke git through a shell.
##
## Bug: changedFiles used execCmdEx which passes the command through /bin/sh,
## and never checked that projectRoot was a non-empty existing directory before
## passing it as workingDir to the shell.  A malformed/missing projectRoot
## yielded an opaque OS/shell error instead of a clear cekEnvironment.
##
## Fix:
##   1. Before invoking git, check projectRoot with dirExists; if it fails,
##      raise CrisolError(cekEnvironment) with a clear message.
##   2. Replace execCmdEx (shell) with osproc.startProcess using an explicit
##      args seq and {poUsePath} (no poEvalCommand), so no shell is involved.

import std/[os, osproc, sets, strutils]
import crisol/types
import crisol/gitdiff

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc initGitRepo(dir: string) =
  createDir(dir)
  discard execCmdEx("git init", workingDir = dir)
  discard execCmdEx("git config user.email test@example.com", workingDir = dir)
  discard execCmdEx("git config user.name Test", workingDir = dir)
  writeFile(dir / "README.md", "# test")
  discard execCmdEx("git add README.md", workingDir = dir)
  discard execCmdEx("git commit -m init", workingDir = dir)

# ---------------------------------------------------------------------------
# M9 test 1: empty string projectRoot → cekEnvironment
# ---------------------------------------------------------------------------

block test_m9_empty_projectRoot:
  var raised = false
  var kind: CrisolErrorKind
  try:
    discard changedFiles("")
  except CrisolError as e:
    raised = true
    kind = e.kind
  assert raised, "M9: empty projectRoot must raise CrisolError"
  assert kind == cekEnvironment,
    "M9: empty projectRoot must raise cekEnvironment, got: " & $kind

# ---------------------------------------------------------------------------
# M9 test 2: nonexistent projectRoot path → cekEnvironment
# ---------------------------------------------------------------------------

block test_m9_nonexistent_projectRoot:
  let bogus = getTempDir() / "crisol_m9_does_not_exist_xyzzy"
  # Ensure the path really doesn't exist.
  removeDir(bogus)
  assert not dirExists(bogus), "precondition: dir must not exist"

  var raised = false
  var kind: CrisolErrorKind
  try:
    discard changedFiles(bogus)
  except CrisolError as e:
    raised = true
    kind = e.kind
  assert raised,
    "M9: nonexistent projectRoot must raise CrisolError (got no exception)"
  assert kind == cekEnvironment,
    "M9: nonexistent projectRoot must raise cekEnvironment, got: " & $kind

# ---------------------------------------------------------------------------
# M9 test 3: path that is a FILE (not a directory) → cekEnvironment
# ---------------------------------------------------------------------------

block test_m9_file_as_projectRoot:
  let tmpFile = getTempDir() / "crisol_m9_file.txt"
  writeFile(tmpFile, "not a directory")
  defer: removeFile(tmpFile)

  var raised = false
  var kind: CrisolErrorKind
  try:
    discard changedFiles(tmpFile)
  except CrisolError as e:
    raised = true
    kind = e.kind
  assert raised,
    "M9: file path as projectRoot must raise CrisolError (got no exception)"
  assert kind == cekEnvironment,
    "M9: file path as projectRoot must raise cekEnvironment, got: " & $kind

# ---------------------------------------------------------------------------
# M9 test 4: valid git repo still works (regression guard)
# ---------------------------------------------------------------------------

block test_m9_valid_repo_works:
  let repoDir = getTempDir() / "crisol_m9_valid_repo"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)

  # Modify the tracked README.md so there is something to diff.
  writeFile(repoDir / "README.md", "# changed content")

  var changed: HashSet[string]
  var raised = false
  try:
    changed = changedFiles(repoDir)
  except CrisolError as e:
    raised = true
    echo "M9: unexpected CrisolError: ", e.msg

  assert not raised,
    "M9: valid git repo with existing dir must NOT raise CrisolError"
  assert "README.md" in changed,
    "M9: modified tracked file must appear in changedFiles. Got: " & $changed

echo "PASS test_soundness_m9"
