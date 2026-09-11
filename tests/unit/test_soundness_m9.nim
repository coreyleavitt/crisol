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

import std/[options, os, osproc, sequtils, sets, strutils]
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

# RFC-0009 A3b-i: changedFiles now returns HashSet[TrackedPath] and needs a
# TrackedRoots to reduce against. The empty/nonexistent/file-as-root tests
# below all raise before roots is ever consulted, so a roots value built
# from a real, harmless directory (getTempDir() itself) is safe to reuse
# across all three -- it is never touched by the code path under test.
let dummyRoots = initTrackedRoots(getTempDir(), @[], "")

# ---------------------------------------------------------------------------
# M9 test 1: empty string projectRoot → cekEnvironment
# ---------------------------------------------------------------------------

block test_m9_empty_projectRoot:
  var raised = false
  var kind: CrisolErrorKind
  try:
    discard changedFiles("", dummyRoots)
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
    discard changedFiles(bogus, dummyRoots)
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
    discard changedFiles(tmpFile, dummyRoots)
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
  let repoDir = expandFilename(getTempDir()) / "crisol_m9_valid_repo"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)
  let roots = initTrackedRoots(repoDir, @[], "")

  # Modify the tracked README.md so there is something to diff.
  writeFile(repoDir / "README.md", "# changed content")

  var changed: HashSet[TrackedPath]
  var raised = false
  try:
    changed = changedFiles(repoDir, roots)
  except CrisolError as e:
    raised = true
    echo "M9: unexpected CrisolError: ", e.msg

  assert not raised,
    "M9: valid git repo with existing dir must NOT raise CrisolError"
  let readme = fromCanonical("README.md", roots)
  assert readme.isSome, "M9: precondition: 'README.md' must reduce cleanly"
  assert readme.get in changed,
    "M9: modified tracked file must appear in changedFiles as a TrackedPath. Got: " &
    $(changed.mapIt(it.display))

# ---------------------------------------------------------------------------
# M9 test 5 (RFC-0009 A3b-i): -z NUL-separated output survives a non-ASCII
# name intact, undistorted by core.quotepath's default octal-escaping.
# ---------------------------------------------------------------------------

block test_m9_nonascii_name_survives_quotepath:
  let repoDir = expandFilename(getTempDir()) / "crisol_m9_nonascii"
  defer: removeDir(repoDir)
  initGitRepo(repoDir)
  # Force core.quotepath on explicitly (it defaults to true, but pin it so
  # this test is not hostage to the ambient git config) -- without `-z`,
  # git would emit this name as a double-quoted, octal-escaped literal
  # (e.g. "caf\303\251.nim") rather than the raw UTF-8 bytes.
  discard execCmdEx("git config core.quotepath true", workingDir = repoDir)
  let roots = initTrackedRoots(repoDir, @[], "")

  let nonAsciiName = "caf\xC3\xA9.nim"   # "café.nim" -- UTF-8 multibyte
  writeFile(repoDir / nonAsciiName, "echo 1\n")
  discard execCmdEx("git add -A", workingDir = repoDir)
  discard execCmdEx("git commit -m addnonascii", workingDir = repoDir)
  # Modify so there is something to diff against HEAD.
  writeFile(repoDir / nonAsciiName, "echo 1\necho 2\n")

  let changed = changedFiles(repoDir, roots)
  let expected = fromCanonical(nonAsciiName, roots)
  assert expected.isSome, "M9: precondition: non-ASCII name must reduce cleanly"
  assert expected.get in changed,
    "M9: non-ASCII name must survive -z output undistorted. Got: " &
    $(changed.mapIt(it.display))

echo "PASS test_soundness_m9"
