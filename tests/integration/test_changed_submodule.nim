## test_changed_submodule.nim — R10-S5 and R12-D2 (review rounds 10 and
## 12): a file changed inside a git submodule is visible to `--changed`, and
## only that file.
##
## `git diff --name-only` names a changed submodule by its GITLINK path alone
## (`vendor/lib`), never the files inside it, and `git ls-files --others`
## prints nothing for a new file inside one. A test whose closure holds
## `vendor/lib/dep.nim` was therefore never selected when `dep.nim` changed:
## the closure and the changed set shared no member. Worse, `git diff`
## honours `diff.ignoreSubmodules` and a `.gitmodules` `ignore =` setting, so
## a submodule configured `ignore = all` was not even named.
##
## R12-D2: a submodule present on both sides of the diff is asked, through
## its own git, what changed inside it against the commit the base records
## for it, and ONLY those names count: editing one file selects only the
## tests that read that file. A link inside it that its diff names selects
## the tests reached through it, exactly as a link in the project does. A
## checked-out submodule whose recorded commit is missing locally cannot
## answer and refuses (exit 3). R15-D1: an uninitialised submodule whose
## recorded commit moved since `--base` holds nothing a test can read, and
## no longer refuses; a test that read a file there is selected because the
## file is missing (`depgraph.entryDrift`, `dkMissing`, narrow rule 4).
##
## R13-S1 / R13-L4 (round 13): a submodule checkout replaced by a link is
## named by its gitlink path alone, and that name selects the tests with a
## member under it. A submodule on both sides no longer adds its own path,
## so an edit beside a link inside it selects no test reached through the
## link.
##
## Proven through the real CLI entry point (runMain) against a real temp
## repository with a real submodule: a full run records the closure, the
## submodule changes, and `run --changed --dry-run` must plan the dependent
## test and nothing else.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_changed_submodule.nim

import std/[json, os, osproc, strutils, unittest]
import crisol
import ../support/[capture, dirlink]

proc git(root: string; args: string) =
  # `protocol.file.allow=always`: `submodule add` from a local path is
  # refused by default since git 2.38.1.
  let (o, rc) = execCmdEx("git -c protocol.file.allow=always -C " &
                          quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

proc gitOut(root: string; args: string): string =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o
  o.strip()

proc stageIndexLink(repo, name, target: string) =
  ## Record `name` as a symlink to `target` the way a checkout without
  ## symlink support holds one: mode 120000 in the index, the target text as
  ## the work-tree file. Portable: needs no symlink privilege.
  git(repo, "config core.symlinks false")
  writeFile(repo / name, target)
  let sha = gitOut(repo, "hash-object -w " & quoteShell(name))
  git(repo, "update-index --add --cacheinfo 120000," & sha & "," & name)

proc commitLinkInSub(root, name, target: string) =
  ## Commit a mode-120000 `name` inside the submodule, then record the moved
  ## gitlink in the project.
  let sub = root / "vendor" / "lib"
  stageIndexLink(sub, name, target)
  git(sub, "commit -q -m link")
  git(root, "add vendor/lib")
  git(root, "commit -q -m bump")

proc changedCode(root: string; extra: seq[string]): int =
  var code = 0
  discard captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl",
                     "--changed", "--dry-run", "--json"] & extra))
  code

proc initRepo(root: string) =
  git(root, "init -q")
  git(root, "config user.email crisol@test.local")
  git(root, "config user.name crisol-test")
  git(root, "config commit.gpgsign false")

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

const SubOtherTest = """
import ../../vendor/lib/other
doAssert other() > 0
"""

const NestedTest = """
import ../../nested/n
doAssert n() > 0
"""

const SubLinkTest = """
import ../../vendor/lib/vend/dep
doAssert answer() > 0
"""

const OtherTest = """
doAssert 1 + 1 == 2
"""

proc newProject(tag: string): tuple[base, root: string] =
  ## `<base>/lib` is the submodule's upstream, `<base>/top` the project that
  ## vendors it at `vendor/lib`.
  let base = getTempDir() / ("crisol_r10_sub_" & tag & "_" & $getCurrentProcessId())
  removeDir(base)
  let lib = base / "lib"
  let root = base / "top"
  createDir(lib)
  createDir(root / "tests" / "unit")
  initRepo(lib)
  writeFile(lib / "dep.nim", DepV1)
  git(lib, "add -A")
  git(lib, "commit -q -m lib")

  initRepo(root)
  writeFile(root / "crisol.kdl", ProjectKdl)
  writeFile(root / ".gitignore", ".crisol/\n")
  writeFile(root / "tests" / "unit" / "test_sub.nim", SubTest)
  writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest)
  git(root, "submodule add -q " & quoteShell(lib) & " vendor/lib")
  git(root / "vendor" / "lib", "config user.email crisol@test.local")
  git(root / "vendor" / "lib", "config user.name crisol-test")
  git(root / "vendor" / "lib", "config commit.gpgsign false")
  git(root, "add -A")
  git(root, "commit -q -m baseline")
  (base: base, root: root)

proc fullRun(root: string) =
  var code = 0
  discard captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl", "--json"]))
  doAssert code == 0, "the baseline full run failed"

proc plannedPaths(root: string; extra: seq[string] = @[]): seq[string] =
  var code = 0
  let output = captureStdout(proc() =
    code = runMain(@["run", "--config", root / "crisol.kdl",
                     "--changed", "--dry-run", "--json"] & extra))
  doAssert code == 0, "--changed --dry-run failed:\n" & output
  for ep in parseJson(output.strip())["entrypoints"]:
    result.add ep["path"].getStr

proc selectsOnly(planned: seq[string]; suffix: string): bool =
  planned.len == 1 and planned[0].endsWith(suffix)

proc selectsOnlySub(planned: seq[string]): bool =
  selectsOnly(planned, "tests/unit/test_sub.nim")

proc commitInSub(root, msg: string) =
  ## Commit everything in the submodule, then record the moved gitlink along
  ## with anything else the project has pending.
  let sub = root / "vendor" / "lib"
  git(sub, "add -A")
  git(sub, "commit -q -m " & msg)
  git(root, "add -A")
  git(root, "commit -q -m bump-" & msg)

suite "R10-S5 — --changed sees changes inside a git submodule":

  test "an uncommitted edit inside the submodule selects its dependent test":
    let (base, root) = newProject("dirty")
    defer: removeDir(base)
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)   # RED: [] -- only `vendor/lib` was changed

  test "a commit made inside the submodule selects its dependent test":
    let (base, root) = newProject("commit")
    defer: removeDir(base)
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    git(root / "vendor" / "lib", "commit -q -am v2")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)

  test "a submodule configured `ignore = all` is still seen":
    let (base, root) = newProject("ignored")
    defer: removeDir(base)
    git(root, "config -f .gitmodules submodule.vendor/lib.ignore all")
    git(root, "config diff.ignoreSubmodules all")
    git(root, "commit -q -am ignore-all")
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)   # RED even with gitlink expansion alone

  test "a one-file edit inside the submodule selects only the tests that read that file":
    let (base, root) = newProject("onefile")
    defer: removeDir(base)
    writeFile(root / "vendor" / "lib" / "other.nim", "proc other*(): int = 3\n")
    writeFile(root / "tests" / "unit" / "test_sub2.nim", SubOtherTest)
    commitInSub(root, "other")
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)   # RED: test_sub2 too, every file counted

  test "an untracked directory link inside a changed submodule selects nothing by itself":
    let (base, root) = newProject("dirlink")
    defer: removeDir(base)
    fullRun(root)
    let sub = root / "vendor" / "lib"
    createDir(base / "elsewhere")
    writeFile(base / "elsewhere" / "x.nim", "discard\n")
    createDirLink(base / "elsewhere", sub / "linked")
    defer: removeDirLink(sub / "linked")
    writeFile(sub / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)   # RED: exit 3

  test "an index-recorded link retargeted inside a submodule selects nothing by itself":
    let (base, root) = newProject("sublink")
    defer: removeDir(base)
    commitLinkInSub(root, "vend", "a")
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "vend", "b")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check planned.len == 0   # RED: exit 3

  test "a link repointed in a submodule commit selects the test reached through it":
    let (base, root) = newProject("sublinkhit")
    defer: removeDir(base)
    let sub = root / "vendor" / "lib"
    createDir(sub / "a")
    createDir(sub / "b")
    writeFile(sub / "a" / "dep.nim", DepV1)
    # A different SIZE from `a/dep.nim`: on Windows git sees the junction as
    # a directory and trusts a matching size and mtime, so a same-size file
    # written in the same tick made the repoint commit "nothing to commit".
    writeFile(sub / "b" / "dep.nim", DepV2 & "# b\n")
    createDirLink(sub / "a", sub / "vend")
    defer: removeDirLink(sub / "vend")
    writeFile(root / "tests" / "unit" / "test_sublink.nim", SubLinkTest)
    commitInSub(root, "link")
    removeDirLink(sub / "vend")
    createDirLink(sub / "b", sub / "vend")
    commitInSub(root, "repoint")
    # Recorded after the repoint: only the diff says `vend` changed.
    fullRun(root)
    let planned = plannedPaths(root, @["--base", "HEAD~1"])
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_sublink.nim")   # RED: exit 3

  test "CONTROL an unchanged link inside a changed submodule does not refuse":
    let (base, root) = newProject("sublinkctl")
    defer: removeDir(base)
    commitLinkInSub(root, "vend", "a")
    fullRun(root)
    writeFile(root / "vendor" / "lib" / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)

  test "CONTROL an unchanged directory link inside a changed submodule does not refuse":
    let (base, root) = newProject("subdirlinkctl")
    defer: removeDir(base)
    let sub = root / "vendor" / "lib"
    createDir(sub / "real")
    writeFile(sub / "real" / "x.nim", "discard\n")
    createDirLink(sub / "real", sub / "inc")
    defer: removeDirLink(sub / "inc")
    commitInSub(root, "dirlink")
    fullRun(root)
    writeFile(sub / "dep.nim", DepV2)
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)

  test "a moved submodule that is not checked out does not refuse, and selects the test that read it":
    let (base, root) = newProject("deinit")
    defer: removeDir(base)
    fullRun(root)
    let sub = root / "vendor" / "lib"
    writeFile(sub / "dep.nim", DepV2)
    git(sub, "commit -q -am v2")
    git(root, "add vendor/lib")
    git(root, "commit -q -m bump")
    git(root, "submodule deinit -q -f vendor/lib")
    check changedCode(root, @["--base", "HEAD~1"]) == 0   # RED: 3
    let planned = plannedPaths(root, @["--base", "HEAD~1"])
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)

  test "a submodule whose recorded commit is missing locally refuses --changed (exit 3)":
    let (base, root) = newProject("gone")
    defer: removeDir(base)
    let sub = root / "vendor" / "lib"
    writeFile(sub / "dep.nim", DepV2)
    commitInSub(root, "v2")
    let recorded = gitOut(sub, "rev-parse HEAD")
    git(sub, "reset -q --hard HEAD~1")
    git(sub, "reflog expire --expire=now --all")
    git(sub, "gc -q --prune=now")
    let (_, present) = execCmdEx("git -C " & quoteShell(sub) &
                                 " cat-file -e " & recorded & "^{commit}")
    doAssert present != 0, "the recorded commit survived the prune"
    check changedCode(root, @[]) == 3

  test "an untracked nested repository counts every file in it as changed":
    let (base, root) = newProject("nested")
    defer: removeDir(base)
    let nested = root / "nested"
    createDir(nested)
    initRepo(nested)
    writeFile(nested / "n.nim", "proc n*(): int = 1\n")
    writeFile(root / "tests" / "unit" / "test_nested.nim", NestedTest)
    git(root, "add tests")
    git(root, "commit -q -m nested-test")
    fullRun(root)
    writeFile(nested / "n.nim", "proc n*(): int = 2\n")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_nested.nim")

  test "a submodule checkout replaced by a link selects its dependent test":
    # R13-S1: git names only `:160000 120000 T vendor/lib`. The member
    # `vendor/lib/dep.nim` is still readable through the new link, so no
    # member is missing and the entry recorded no link: the gitlink name
    # alone has to select (`depgraph.diffReach`, `hkAncestor`), and the link on the
    # member's path makes the entry stale (`depgraph.entryDrift`, `dkUnrecorded`).
    let (base, root) = newProject("sub2link")
    defer: removeDir(base)
    fullRun(root)
    createDir(base / "other")
    writeFile(base / "other" / "dep.nim", DepV2)
    removeDir(root / "vendor" / "lib")
    createDirLink(base / "other", root / "vendor" / "lib")
    defer: removeDirLink(root / "vendor" / "lib")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnlySub(planned)   # RED: [] and exit 0

  test "an edit beside a link inside the submodule selects no test reached through the link":
    # R13-L4: the gitlink's own name used to be added before the
    # submodule's own records, and "a changed name above a recorded link"
    # then selected every test reached through any link in the submodule.
    let (base, root) = newProject("sublinknote")
    defer: removeDir(base)
    let sub = root / "vendor" / "lib"
    createDir(sub / "a")
    writeFile(sub / "a" / "dep.nim", DepV1)
    writeFile(sub / "note.txt", "x")
    createDirLink(sub / "a", sub / "vend")
    defer: removeDirLink(sub / "vend")
    writeFile(root / "tests" / "unit" / "test_sublink.nim", SubLinkTest)
    commitInSub(root, "link")
    fullRun(root)
    writeFile(sub / "note.txt", "y")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check planned.len == 0   # RED: test_sublink.nim

  test "CONTROL a change outside the submodule does not select its dependent test":
    let (base, root) = newProject("control")
    defer: removeDir(base)
    fullRun(root)
    writeFile(root / "tests" / "unit" / "test_other.nim", OtherTest & "\n# touched\n")
    let planned = plannedPaths(root)
    checkpoint("planned: " & $planned)
    check selectsOnly(planned, "tests/unit/test_other.nim")

when isMainModule:
  echo "test_changed_submodule done"
