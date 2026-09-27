## test_changed_symlink.nim — R11-L1, R12-D1 and R11-S2 (review rounds 11
## and 12): `--changed` must never answer "nothing changed" for a change it
## cannot see, and must not refuse a change it can.
##
## R11-L1: `git diff` names a tracked SYMLINK by its own path alone
## (`vend`), never the files behind it, while a closure records the files the
## compiler actually opened, under the link's resolved target
## (`libs/a/dep.nim`). Repointing the link (`vend -> libs/a` becomes
## `vend -> libs/b`) therefore produced a changed set the closure shared no
## member with, and `run --changed` selected nothing and exited 0. Round 11
## closed that by refusing `--changed` (exit 3) for any changed link.
##
## R12-D1: each dependency-graph entry now records the links its closure was
## reached through (issue #25), so a link the diff names selects exactly the
## tests reached through it (`depgraph.diffReach`), and the refusal is
## gone. A repointed `docs` link no test crosses no longer refuses the run.
## The case the record's own freshness check (`entryDrift`, `dkMoved`) cannot see is the
## committed repoint with the graph recorded AFTER it: the recorded target is
## the current one, yet `--base HEAD~1` spans the repoint, so the test must
## still be selected.
##
## R13-S1 (round 13): a real directory replaced by a link with the same
## content was read through the link by the next run, which compile-skipped
## and never recorded the link, so a later repoint or target edit selected
## nothing. A directory on a member's path that is now an unrecorded link
## makes the entry stale, and the recompile records the link.
##
## On Windows the directory links here are junctions
## (`tests/support/dirlink.nim`), which git treats as ordinary directories:
## it names the files seen through a junction (`vend/dep.nim`), never the
## junction itself. A changed name UNDER a recorded link selects as well, so
## the same assertions hold on every platform.
##
## R11-S2: `--base <ref>` reached `git diff` with nothing after it. A ref
## that does not resolve but names an existing path (a `release/` directory
## and no `release` ref, as in a shallow CI checkout) was read as a
## pathspec: git diffed the work tree against the index for that path,
## exited 0 with nothing, and `--changed` selected nothing. The base must now
## resolve to a commit, or `--changed` refuses (exit 3).
##
## The portable index-link cases record a link the way git does on a
## checkout without symlink support (`core.symlinks=false`): mode 120000 in
## the index, the target text as the file's content. No compile can cross
## such a link, so they prove only that the link neither refuses nor
## selects anything by itself.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_changed_symlink.nim

import std/[json, os, osproc, strutils, unittest]
import crisol
import ../support/[capture, dirlink]

proc git(root: string; args: string): string {.discardable.} =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o
  o.strip()

proc initRepo(root: string) =
  git(root, "init -q")
  git(root, "config user.email crisol@test.local")
  git(root, "config user.name crisol-test")
  git(root, "config commit.gpgsign false")
  git(root, "config core.autocrlf false")

const ProjectKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const DepA = "proc answer*(): int = 1\n"
const DepB = "proc answer*(): int = 2\n"

const LinkTest = """
import ../../vend/dep
doAssert answer() > 0
"""

const ExactTest = """
import ../../vend/dep
doAssert answer() == 1
"""

const OtherTest = """
doAssert 1 + 1 == 2
"""

proc newProject(tag: string): string =
  ## A project with `libs/a/dep.nim`, `libs/b/dep.nim`, an empty `libs/c`
  ## and one plain test.
  result = getTempDir() / ("crisol_r12_link_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / "libs" / "a")
  createDir(result / "libs" / "b")
  createDir(result / "libs" / "c")
  initRepo(result)
  writeFile(result / "crisol.kdl", ProjectKdl)
  writeFile(result / ".gitignore", ".crisol/\n")
  writeFile(result / "libs" / "a" / "dep.nim", DepA)
  writeFile(result / "libs" / "b" / "dep.nim", DepB)
  writeFile(result / "libs" / "c" / "keep.txt", "c\n")
  writeFile(result / "tests" / "unit" / "test_other.nim", OtherTest)

proc repoint(root, link, target: string) =
  ## Point the directory link `link` at `target` (both project-relative).
  removeDirLink(root / link)
  createDirLink(root / target, root / link)

proc stageIndexLink(root, name, target: string) =
  ## Record `name` as a symlink to `target` the way a checkout without
  ## symlink support holds one: mode 120000 in the index, the target text as
  ## the work-tree file. Portable: needs no symlink privilege.
  git(root, "config core.symlinks false")
  writeFile(root / name, target)
  let sha = git(root, "hash-object -w " & quoteShell(name))
  git(root, "update-index --add --cacheinfo 120000," & sha & "," & name)

proc fullRun(root: string) =
  var code = 0
  let output = captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
  doAssert code == 0, "the baseline full run failed:\n" & output

proc changedRun(root: string; extra: seq[string] = @[]): tuple[code: int, output: string] =
  var code = 0
  let output = captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl",
                     "--changed", "--dry-run", "--json"] & extra))
  (code: code, output: output)

proc realChangedCode(root: string): int =
  ## Exit code of a real (not dry) `run --changed`.
  var code = 0
  discard captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl", "--changed",
                     "--json"]))
  code

proc plannedPaths(output: string): seq[string] =
  for ep in parseJson(output.strip())["entrypoints"]:
    result.add ep["path"].getStr

proc plansOnly(r: tuple[code: int, output: string]; suffix: string): bool =
  ## Exit 0 and exactly one planned entrypoint, ending in `suffix`.
  if r.code != 0: return false
  let planned = plannedPaths(r.output)
  planned.len == 1 and planned[0].endsWith(suffix)

proc plansNothing(r: tuple[code: int, output: string]): bool =
  r.code == 0 and plannedPaths(r.output).len == 0

suite "R12-D1 — a changed link selects the tests reached through it":

  test "an uncommitted repoint of a crossed link selects its test, not the other":
    let root = newProject("repoint")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", LinkTest)
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    repoint(root, "vend", "libs/b")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: exit 3

  test "a committed repoint recorded after the repoint is still selected across --base HEAD~1":
    let root = newProject("committed")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", LinkTest)
    # R15-L4: git on Windows reads the junction as a directory and sees the
    # repoint only as `vend/dep.nim` changing. A target of the same size
    # can pass its stat check under load, leaving nothing to commit; a
    # different size never does.
    writeFile(root / "libs" / "b" / "dep.nim", DepB & "# a different size\n")
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    repoint(root, "vend", "libs/b")
    git(root, "add -A")
    git(root, "commit -q --allow-empty -m repoint")
    # Recorded after the repoint: the entry's link target is the current
    # one, so the entry is fresh, and only the diff says `vend` changed.
    fullRun(root)
    let r = changedRun(root, @["--base", "HEAD~1"])
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: exit 3, then []

  test "a repointed link no test crosses selects nothing and does not refuse":
    let root = newProject("docs")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", LinkTest)
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    # `docs` leads to `libs/b`, which no closure reads.
    createDirLink(root / "libs" / "b", root / "docs")
    defer: removeDirLink(root / "docs")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    repoint(root, "docs", "libs/c")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "a real directory replaced by a link selects the test that read it":
    let root = newProject("dir2link")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", LinkTest)
    createDir(root / "vend")
    writeFile(root / "vend" / "dep.nim", DepA)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    removeDir(root / "vend")
    createDirLink(root / "libs" / "b", root / "vend")
    defer: removeDirLink(root / "vend")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: exit 3

  test "a real directory replaced by a same-content link, run, then its target edited, is selected":
    # R13-S1: the run after the swap read the same bytes through the link,
    # so it compile-skipped and the entry kept `vend/dep.nim` and no link.
    # With the swap committed, an edit to the link's target names only
    # `libs/a/dep.nim`, which that entry never held. The unrecorded link now
    # makes the run after the swap recompile, recording `libs/a/dep.nim`
    # and the link (`depgraph.entryDrift`, `dkUnrecorded`).
    let root = newProject("dir2linkedit")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", ExactTest)
    createDir(root / "vend")
    writeFile(root / "vend" / "dep.nim", DepA)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    removeDir(root / "vend")
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    git(root, "add -A")
    # A junction over the same files is invisible to git on Windows.
    git(root, "commit -q --allow-empty -m tolink")
    fullRun(root)
    writeFile(root / "libs" / "a" / "dep.nim", DepB)
    let r = changedRun(root)
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: [] and exit 0
    check realChangedCode(root) == 1   # RED: 0

  test "a real directory replaced by a same-content link, run, then repointed, is selected":
    # R13-S1: as above, then the link is repointed. On Windows the link is a
    # junction, which git reads as a plain directory: the swap and the
    # repoint can both be invisible to it, and only the link recorded by
    # the run after the swap can see the repoint (`dkMoved`, rule 4).
    let root = newProject("dir2linkrun")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", ExactTest)
    createDir(root / "vend")
    writeFile(root / "vend" / "dep.nim", DepA)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    removeDir(root / "vend")
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    fullRun(root)
    repoint(root, "vend", "libs/b")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: [] and exit 0
    # And the real run fails, as a plain run does.
    check realChangedCode(root) == 1   # RED: 0

  test "the same swap, committed, then a committed repoint, is selected across --base HEAD~1":
    # On POSIX the diff names `vend`, above the lexical member. On Windows
    # both commits are empty (git reads the junction as the directory it
    # replaced, and did not name the repoint either), so only the link
    # recorded by the run after the swap can see the repoint (`dkMoved`,
    # rule 4): without `dkUnrecorded` this plans [] and exits 0.
    let root = newProject("dir2linkbase")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", ExactTest)
    createDir(root / "vend")
    writeFile(root / "vend" / "dep.nim", DepA)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    removeDir(root / "vend")
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    git(root, "add -A")
    # A junction over the same files is invisible to git on Windows.
    git(root, "commit -q --allow-empty -m tolink")
    fullRun(root)
    repoint(root, "vend", "libs/b")
    git(root, "add -A")
    git(root, "commit -q --allow-empty -m repoint")
    let r = changedRun(root, @["--base", "HEAD~1"])
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_link.nim")   # RED: [] and exit 0

  test "an untracked directory link no test crosses selects nothing":
    let root = newProject("untracked")
    defer: removeDir(root)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    createDirLink(root / "libs" / "b", root / "alias")
    defer: removeDirLink(root / "alias")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "an index-recorded link repointed without a crossing test selects nothing":
    let root = newProject("indexrepoint")
    defer: removeDir(root)
    stageIndexLink(root, "vend", "libs/a")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    writeFile(root / "vend", "libs/b")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "an index-recorded link repointed in a commit selects nothing across --base HEAD~1":
    let root = newProject("indexcommitted")
    defer: removeDir(root)
    stageIndexLink(root, "vend", "libs/a")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    writeFile(root / "vend", "libs/b")
    git(root, "add -A")
    git(root, "commit -q -m repoint")
    fullRun(root)
    let r = changedRun(root, @["--base", "HEAD~1"])
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "a deleted index-recorded link selects nothing":
    let root = newProject("deleted")
    defer: removeDir(root)
    stageIndexLink(root, "vend", "libs/a")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    removeFile(root / "vend")
    git(root, "rm -q --cached vend")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "an index-recorded link replaced by a regular file selects nothing":
    let root = newProject("typechange")
    defer: removeDir(root)
    stageIndexLink(root, "vend.nim", "libs/a/dep.nim")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    git(root, "rm -q --cached vend.nim")
    writeFile(root / "vend.nim", DepB)
    git(root, "add vend.nim")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansNothing(r)   # RED: exit 3

  test "CONTROL a newly added link to a file is a new file":
    let root = newProject("addedfile")
    defer: removeDir(root)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    stageIndexLink(root, "alias.nim", "libs/a/dep.nim")
    check plansNothing(changedRun(root))

  test "CONTROL an unchanged crossed link does not select its test for an unrelated change":
    let root = newProject("unrelated")
    defer: removeDir(root)
    writeFile(root / "tests" / "unit" / "test_link.nim", LinkTest)
    createDirLink(root / "libs" / "a", root / "vend")
    defer: removeDirLink(root / "vend")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    fullRun(root)
    writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest & "# touched\n")
    let r = changedRun(root)
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_other.nim")

suite "R11-S2 — an unresolvable --base refuses instead of becoming a pathspec":

  test "--base naming a directory but no ref refuses (exit 3)":
    let root = newProject("pathspec")
    defer: removeDir(root)
    createDir(root / "release")
    writeFile(root / "release" / "notes.txt", "v1\n")
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest & "# touched\n")
    let r = changedRun(root, @["--base", "release"])
    checkpoint(r.output)
    check r.code == 3   # RED: 0 with nothing planned

  test "CONTROL a resolvable --base still selects the changed test":
    let root = newProject("goodbase")
    defer: removeDir(root)
    git(root, "add -A")
    git(root, "commit -q -m baseline")
    git(root, "tag release")
    writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest & "# touched\n")
    let r = changedRun(root, @["--base", "release"])
    checkpoint(r.output)
    check plansOnly(r, "tests/unit/test_other.nim")

when isMainModule:
  echo "test_changed_symlink done"
