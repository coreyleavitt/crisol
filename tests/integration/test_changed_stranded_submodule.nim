## test_changed_stranded_submodule.nim — R13-S3 (review round 13): a
## submodule whose `.git` entry was removed is still seen by `--changed`.
##
## A gitlink in the index whose directory holds no repository is, to git,
## an unchanged submodule: `git diff` does not name it, and `git ls-files
## --others` never lists anything under a gitlink path. After `rm
## vendor/lib/.git`, an edit to `vendor/lib/dep.nim` left the changed set
## empty, and `--changed` planned nothing while the dependent test failed.
##
## `gitdiff.changedFiles` now reads the index's gitlinks (`ls-files
## --stage`): one whose directory is present, holds no `.git` entry and is
## not empty has no base to diff against, so its name alone joins the changed
## set and selects every test with a member under it (`depgraph.diffReach`,
## `hkAncestor`). A checked-out submodule's own gitlinks are read the same
## way. An uninitialised submodule (an empty directory) holds nothing a
## test can read, and contributes nothing.
##
## R15-D1 (review round 15): the diff names a submodule whose recorded
## commit moved since `--base`. Such a submodule used to refuse `--changed`
## unless it was checked out, although the index walk above already decided
## the same directory. One table now decides both: a stranded one adds its
## name, and an uninitialised one contributes nothing (a test that read a
## file there is stale, `depgraph.entryDrift` `dkMissing`), named or not.
##
## R15-S7: a `.git` entry that is an empty directory is no repository; git
## itself refuses to diff the project then, so `--changed` refuses (exit 3)
## instead of reading the directory's gitlink as its own child forever.
##
## Proven through the real CLI entry point (runMain) against a real temp
## repository with a real submodule.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_changed_stranded_submodule.nim

import std/[json, os, osproc, strutils, unittest]
import crisol
import ../support/capture

proc git(root: string; args: string) =
  # `protocol.file.allow=always`: `submodule add` from a local path is
  # refused by default since git 2.38.1.
  let (o, rc) = execCmdEx("git -c protocol.file.allow=always -C " &
                          quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

proc initRepo(root: string) =
  git(root, "init -q")
  git(root, "config user.email crisol@test.local")
  git(root, "config user.name crisol-test")
  git(root, "config commit.gpgsign false")

proc commitRepo(root, msg: string) =
  git(root, "add -A")
  git(root, "commit -q -m " & msg)

const ProjectKdl = """
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

const DepV1 = "proc answer*(): int = 1\n"
const DepV2 = "proc answer*(): int = 2\n"

const SubTest = """
import ../../vendor/lib/dep
doAssert answer() > 0
"""

const InnerTest = """
import ../../vendor/lib/inner/deep
doAssert deep() > 0
"""

const OtherTest = """
doAssert 1 + 1 == 2
"""

proc newProject(tag: string; nested = false): tuple[base, root: string] =
  ## `<base>/lib` is the submodule's upstream, `<base>/top` the project that
  ## vendors it at `vendor/lib`. With `nested`, `lib` vendors `<base>/deep`
  ## at `inner` in turn, and a test reads a file in it.
  let base = getTempDir() / ("crisol_r13s3_" & tag & "_" & $getCurrentProcessId())
  removeDir(base)
  let lib = base / "lib"
  let root = base / "top"
  createDir(lib)
  createDir(root / "tests" / "unit")
  if nested:
    let deep = base / "deep"
    createDir(deep)
    initRepo(deep)
    writeFile(deep / "deep.nim", "proc deep*(): int = 1\n")
    commitRepo(deep, "deep")
  initRepo(lib)
  writeFile(lib / "dep.nim", DepV1)
  if nested:
    git(lib, "submodule add -q " & quoteShell(base / "deep") & " inner")
  commitRepo(lib, "lib")

  initRepo(root)
  writeFile(root / "crisol.kdl", ProjectKdl)
  writeFile(root / ".gitignore", ".crisol/\n")
  writeFile(root / "tests" / "unit" / "test_sub.nim", SubTest)
  writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest)
  if nested:
    writeFile(root / "tests" / "unit" / "test_inner.nim", InnerTest)
  git(root, "submodule add -q " & quoteShell(lib) & " vendor/lib")
  if nested:
    git(root, "submodule update -q --init --recursive")
  commitRepo(root, "baseline")
  (base: base, root: root)

proc fullRun(root: string) =
  var code = 0
  discard captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
  doAssert code == 0, "the baseline full run failed"

proc changedRun(root: string; extra: seq[string]): tuple[code: int; output: string] =
  var code = 0
  let output = captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl",
                     "--changed", "--dry-run", "--json"] & extra))
  (code: code, output: output)

proc plannedPaths(root: string; extra: seq[string] = @[]): seq[string] =
  let (code, output) = changedRun(root, extra)
  doAssert code == 0, "--changed --dry-run failed:\n" & output
  for ep in parseJson(output.strip())["entrypoints"]:
    result.add ep["path"].getStr

proc bumpSub(root: string) =
  ## Commit a new `dep.nim` in the submodule, then record the moved gitlink
  ## in the project: `--base HEAD~1` names `vendor/lib` from then on.
  let sub = root / "vendor" / "lib"
  git(sub, "config user.email crisol@test.local")
  git(sub, "config user.name crisol-test")
  git(sub, "config commit.gpgsign false")
  writeFile(sub / "dep.nim", DepV2)
  commitRepo(sub, "v2")
  git(root, "add vendor/lib")
  git(root, "commit -q -m bump")

proc selectsOnly(planned: seq[string]; suffix: string): bool =
  planned.len == 1 and planned[0].endsWith(suffix)

proc removeGitEntry(dir: string) =
  ## A submodule's `.git` is a gitdir pointer file; a nested clone's is a
  ## directory. Either way it goes.
  if fileExists(dir / ".git"): removeFile(dir / ".git")
  else: removeDir(dir / ".git")
  doAssert not fileExists(dir / ".git") and not dirExists(dir / ".git")

suite "R13-S3 — a submodule whose .git entry was removed":

  test "an edit inside it selects its dependent test":
    let (base, root) = newProject("edit")
    defer: removeDir(base)
    fullRun(root)
    removeGitEntry(root / "vendor" / "lib")
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_sub.nim")   # RED: []

  test "an edit inside a nested submodule whose .git was removed selects its dependent test":
    let (base, root) = newProject("nested", nested = true)
    defer: removeDir(base)
    fullRun(root)
    let inner = root / "vendor" / "lib" / "inner"
    removeGitEntry(inner)
    writeFile(inner / "deep.nim", "proc deep*(): int = 2\n")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_inner.nim")   # RED: []

  test "a submodule bumped since --base, then its .git removed, selects its dependent test":
    # R15-D1: the diff names `vendor/lib` (`:160000 160000`), which used to
    # refuse because it holds no repository.
    let (base, root) = newProject("bumped")
    defer: removeDir(base)
    fullRun(root)
    bumpSub(root)
    removeGitEntry(root / "vendor" / "lib")
    let planned = plannedPaths(root, @["--base", "HEAD~1"])   # RED: exit 3
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_sub.nim")

  test "an uninitialised submodule bumped since --base does not refuse and selects nothing by itself":
    # R15-D1: recorded after the deinit, so no entry has a member there.
    let (base, root) = newProject("bumpuninit")
    defer: removeDir(base)
    removeFile(root / "tests" / "unit" / "test_sub.nim")
    commitRepo(root, "no-sub-test")
    bumpSub(root)
    git(root, "submodule deinit -q -f vendor/lib")
    fullRun(root)
    let (code, output) = changedRun(root, @["--base", "HEAD~1"])
    checkpoint(output)
    check code == 0   # RED: 3
    check plannedPaths(root, @["--base", "HEAD~1"]).len == 0
    writeFile(root / "tests" / "unit" / "test_other.nim",
              OtherTest & "\n# touched\n")
    let planned = plannedPaths(root, @["--base", "HEAD~1"])
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_other.nim")

  test "a submodule whose .git is an empty directory refuses --changed (exit 3)":
    # R15-S7: git in such a directory finds the project's repository, whose
    # index lists the directory's own gitlink as `./`.
    let (base, root) = newProject("emptygit")
    defer: removeDir(base)
    fullRun(root)
    removeGitEntry(root / "vendor" / "lib")
    createDir(root / "vendor" / "lib" / ".git")
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let (code, output) = changedRun(root, @[])
    checkpoint(output)
    check code == 3

  test "CONTROL an uninitialised submodule contributes nothing":
    # `deinit` empties the checkout. Recorded after the deinit, so no entry
    # has a member there; a change elsewhere selects only its own test.
    let (base, root) = newProject("uninit")
    defer: removeDir(base)
    removeFile(root / "tests" / "unit" / "test_sub.nim")
    commitRepo(root, "no-sub-test")
    git(root, "submodule deinit -q -f vendor/lib")
    fullRun(root)
    writeFile(root / "tests" / "unit" / "test_other.nim",
              OtherTest & "\n# touched\n")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_other.nim")

  test "CONTROL a checked-out submodule with no change selects nothing":
    let (base, root) = newProject("clean", nested = true)
    defer: removeDir(base)
    fullRun(root)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check planned.len == 0

when isMainModule:
  echo "test_changed_stranded_submodule done"
