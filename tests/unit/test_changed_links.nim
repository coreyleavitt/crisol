## test_changed_links.nim — R12-D1 and R12-D2 (review round 12): the two
## pure decisions behind `--changed` for links and submodules.
##
## `depgraph.diffReach` says how a changed set reaches an entry's watched
## set (its closure members and recorded links): a member, a recorded link
## itself or a directory above it, a name under it (git sees a Windows
## junction as a plain directory and names the files through it), or a
## directory above a member. `narrow.narrowByDiff` selects such an entry even
## when its closure members are untouched and the entry is fresh.
##
## `gitdiff.nameVerdict` decides what one changed name, or one index
## gitlink, contributes: its name, the submodule's own records, or nothing
## (R15-D1: one classifier, one table, for the diff and the index walk). A
## directory changed as a whole contributes its name alone (R14-D8):
## `hkAncestor` reaches every member under it, including one under a
## dependency root nested there.
##
## R13-S1 (round 13): a directory replaced by a link after the record.
## `diffReach` selects an entry when a changed name is a directory above a
## closure member (`hkAncestor`: git names a submodule turned into a link by
## its gitlink path alone), and `depgraph.entryDrift` makes an entry stale
## when a directory on a member's path is now a link it did not record
## (`dkUnrecorded`), as it does for a missing member or a moved recorded
## link. R13-L4: an expanded submodule no longer adds its own name, which
## `nameVerdict` itself now says (R14-D7).
##
## R15-L1: under a case fold a `Hit` reports the changed name in the diff's
## spelling and the watched path in the entry's.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_changed_links.nim

import std/[options, os, sets, tables, unittest]
import crisol/[closure, depgraph, gitdiff, narrow, paths, types]
import "../support/rfc9_narrow_support"
import "../support/testep"
import "../support/dirlink"

let roots = mkRoots(getCurrentDir())

proc tp(rel: string): TrackedPath =
  for t in changedTp(roots, rel): return t

proc link(rel: string): ClosureLink =
  ## A recorded link at `rel` whose target is what `rel` resolves to now,
  ## so `entryDrift` finds it unchanged.
  ClosureLink(path: tp(rel), target: linkTargetSpelling(
    safeExpandFilename(toNative(tp(rel), roots)), roots))

proc entryWith(links: varargs[string]): DepGraphEntry =
  for l in links: result.links.add link(l)

proc hitStr(h: Option[Hit]): string =
  ## "" for none, else "<kind> <changed name> -> <watched path>".
  if h.isNone: return ""
  $h.get.kind & " " & string(h.get.name.display) & " -> " &
    string(h.get.watched.display)

proc driftStr(d: Option[Drift]): string =
  ## "" for none, else "<kind> <path>".
  if d.isNone: return ""
  $d.get.kind & " " & string(d.get.path.display)

suite "R12-D1 — diffReach: a changed name that reaches a recorded link":

  test "the link itself (hkLink)":
    check hitStr(diffReach(entryWith("src/crisol"),
                           changedTp(roots, "src/crisol"), roots)) ==
      "hkLink src/crisol -> src/crisol"

  test "a directory above the link (hkLink)":
    check hitStr(diffReach(entryWith("src/crisol"), changedTp(roots, "src"),
                           roots)) == "hkLink src -> src/crisol"

  test "a name under the link, as git reports a file seen through a junction (hkUnderLink)":
    check hitStr(diffReach(entryWith("src/crisol"),
                           changedTp(roots, "src/crisol/narrow.nim"),
                           roots)) ==
      "hkUnderLink src/crisol/narrow.nim -> src/crisol"

  test "CONTROL a sibling that shares a prefix but not a component":
    check diffReach(entryWith("src/crisol"),
                    changedTp(roots, "src/crisolx", "src/crisol.nim"),
                    roots).isNone

  test "CONTROL an entry with no links, and an empty changed set":
    check diffReach(entryWith(), changedTp(roots, "src"), roots).isNone
    check diffReach(entryWith("src/crisol"), changedTp(roots), roots).isNone

suite "diffReach: a changed closure member (hkMember)":

  test "a changed member":
    var e: DepGraphEntry
    e.closure = closureTp(roots, "src/crisol/narrow.nim", "src/crisol/types.nim")
    check hitStr(diffReach(e, changedTp(roots, "src/crisol/types.nim",
                                         "docs/x.md"), roots)) ==
      "hkMember src/crisol/types.nim -> src/crisol/types.nim"

  test "CONTROL a changed name that is not a member, above one, or a link":
    var e: DepGraphEntry
    e.closure = closureTp(roots, "src/crisol/narrow.nim")
    check diffReach(e, changedTp(roots, "src/crisol/types.nim", "docs"),
                    roots).isNone

proc selectedBy(e: Entrypoint; g: DepGraph; changed: HashSet[TrackedPath]):
    string =
  ## "" when `narrowByDiff` excludes `e`, else the `diffReach` kind that
  ## included it, after checking that no fallback rule could have: the entry
  ## is known and fresh, and its own file is not in `changed`.
  if narrowByDiff(@[e], changed, g, roots).len == 0: return ""
  let key = entryKey(e.tp, e.flags)
  doAssert e.tp notin changed and key in g.entries and
    not isEntryStale(g, key, roots), "included by a fallback rule"
  let hit = diffReach(g.entries[key], changed, roots)
  if hit.isNone: "<included without a hit>" else: $hit.get.kind

suite "R12-D1 — narrowByDiff selects a fresh entry through a changed link":

  proc graphFor(e: Entrypoint): DepGraph =
    result = initDepGraph("2.2.10")
    result.updateEntry(string(e.tp.display()), flagHash(e.flags),
                       closureTp(roots, "src/crisol/narrow.nim"),
                       @[link("src/crisol")])

  test "a changed link selects the entry reached through it":
    let e = testEp("tests/unit/test_via_link.nim", group = "default")
    let g = graphFor(e)
    check selectedBy(e, g, changedTp(roots, "src/crisol")) == "hkLink"

  test "CONTROL a change elsewhere does not":
    let e = testEp("tests/unit/test_via_link.nim", group = "default")
    let g = graphFor(e)
    check selectedBy(e, g, changedTp(roots, "docs/rfc")) == ""

suite "R15-D1 — nameVerdict: one table for the diff and the index walk":

  test "a gitlink that is checked out is asked for its own records":
    check nameVerdict(gitlink = true, psRepo) == vExpand

  test "a gitlink with content and no repository adds its name, named or not":
    check nameVerdict(gitlink = true, psStranded) == vAddName

  test "an uninitialised gitlink contributes nothing, named or not":
    check nameVerdict(gitlink = true, psEmpty) == vNothing

  test "a gitlink replaced on disk, or gone, adds its name":
    check nameVerdict(gitlink = true, psLink) == vAddName
    check nameVerdict(gitlink = true, psFile) == vAddName
    check nameVerdict(gitlink = true, psAbsent) == vAddName

  test "any other name is its name alone, whatever is on disk":
    for state in PathState:
      checkpoint($state)
      check nameVerdict(gitlink = false, state) == vAddName

  test "no cell refuses, and the zero value adds the name":
    for gitlink in [false, true]:
      for state in PathState:
        check nameVerdict(gitlink, state) in {vAddName, vExpand, vNothing}
    check NameVerdict.default == vAddName

suite "R13-S1 — diffReach: a changed name above a closure member (hkAncestor)":

  proc entryOf(members: varargs[string]): DepGraphEntry =
    result.closure = closureTp(roots, members)

  test "a changed directory above a member":
    check hitStr(diffReach(entryOf("vendor/lib/dep.nim"),
                           changedTp(roots, "vendor/lib"), roots)) ==
      "hkAncestor vendor/lib -> vendor/lib/dep.nim"
    check hitStr(diffReach(entryOf("vendor/lib/dep.nim"),
                           changedTp(roots, "vendor"), roots)) ==
      "hkAncestor vendor -> vendor/lib/dep.nim"

  test "CONTROL a sibling that shares a prefix but not a component":
    check diffReach(entryOf("vendor/lib/dep.nim"),
                    changedTp(roots, "vendor/li", "vendor/libx"),
                    roots).isNone

  test "the member itself is hkMember, not its own ancestor":
    check hitStr(diffReach(entryOf("vendor/lib/dep.nim"),
                           changedTp(roots, "vendor/lib/dep.nim"), roots)) ==
      "hkMember vendor/lib/dep.nim -> vendor/lib/dep.nim"

  test "CONTROL a name below a member's directory, and an empty changed set":
    check diffReach(entryOf("vendor/lib/dep.nim"),
                    changedTp(roots, "vendor/lib/sub/x.nim"), roots).isNone
    check diffReach(entryOf("vendor/lib/dep.nim"), changedTp(roots),
                    roots).isNone

  test "narrowByDiff selects a fresh entry whose submodule became a link":
    # `:160000 120000 T vendor/lib` names only the gitlink. Here the named
    # directory (`src/crisol`) is a plain one, so rule 4 finds the entry
    # fresh and only `diffReach`'s `hkAncestor` can select it.
    let e = testEp("tests/unit/test_sub.nim", group = "default")
    var g = initDepGraph("2.2.10")
    g.updateEntry(string(e.tp.display()), flagHash(e.flags),
                  closureTp(roots, "src/crisol/narrow.nim",
                            "tests/unit/test_changed_links.nim"), @[])
    check selectedBy(e, g, changedTp(roots, "src/crisol")) == "hkAncestor"

suite "entryDrift: a missing member, a moved link, an unrecorded link (R13-S1)":

  let base = getTempDir() / ("crisol_r13_unrec_" & $getCurrentProcessId())
  removeDir(base)
  createDir(base / "libs" / "a" / "real")
  createDir(base / "libs" / "b")
  createDir(base / "plain")
  for f in ["libs/a/m.nim", "libs/a/real/x.nim", "libs/b/x.nim",
            "plain/p.nim"]:
    writeFile(base / f, "discard")
  createDirLink(base / "libs" / "a", base / "vend")
  # A link nested behind `vend`: recorded at its real location
  # (`libs/a/nest`), never at the spelling through `vend`.
  createDirLink(base / "libs" / "b", base / "libs" / "a" / "nest")
  let troots = mkRoots(base)

  proc ttp(rel: string): TrackedPath =
    for t in changedTp(troots, rel): return t

  proc tlink(rel: string): ClosureLink =
    ClosureLink(path: ttp(rel), target: linkTargetSpelling(
      safeExpandFilename(toNative(ttp(rel), troots)), troots))

  proc closureOf(members: openArray[string]): HashSet[TrackedPath] =
    for m in members: result.incl ttp(m)

  proc tentry(members: openArray[string];
              links: openArray[string] = []): DepGraphEntry =
    for m in members: result.closure.incl ttp(m)
    for l in links: result.links.add tlink(l)

  test "a member whose directory is now an unrecorded link (dkUnrecorded)":
    check driftStr(entryDrift(tentry(["vend/m.nim"]), troots)) ==
      "dkUnrecorded vend"

  test "isEntryStale and so narrow rule 4 see it":
    var g = initDepGraph("2.2.10")
    g.entries[("tests/unit/test_mod.nim", "h")] = tentry(["vend/m.nim",
                                                          "plain/p.nim"])
    check isEntryStale(g, ("tests/unit/test_mod.nim", "h"), troots)

  test "CONTROL the same link, recorded":
    check entryDrift(tentry(["vend/m.nim"], ["vend"]), troots).isNone

  test "CONTROL a link nested behind a recorded link is covered by it":
    # `vend/nest` is a link, but only through `vend`: calling it
    # unrecorded would make the entry stale on every run.
    check entryDrift(tentry(["vend/nest/x.nim"], ["vend", "libs/a/nest"]),
                     troots).isNone

  test "CONTROL a realpath member and a plain directory cross no link":
    check entryDrift(tentry(["libs/a/real/x.nim", "plain/p.nim"]),
                     troots).isNone

  test "a recorded link that leads elsewhere now (dkMoved)":
    var e = tentry(["vend/m.nim"], ["vend"])
    e.links[0].target = "t:libs/b"
    check driftStr(entryDrift(e, troots)) == "dkMoved vend"

  test "a member that no longer exists (dkMissing) is checked first":
    # `vend` is an unrecorded link here too; the missing member wins.
    check driftStr(entryDrift(tentry(["vend/gone.nim"]), troots)) ==
      "dkMissing vend/gone.nim"

  test "updateEntry records the links it is given (R12-D6)":
    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/unit/test_mod.nim", "h", closureOf(["vend/m.nim"]),
                  @[tlink("vend")])
    check g.entries[("tests/unit/test_mod.nim", "h")].links.len == 1
    check not isEntryStale(g, ("tests/unit/test_mod.nim", "h"), troots)

  removeDirLink(base / "libs" / "a" / "nest")
  removeDirLink(base / "vend")
  removeDir(base)

suite "R15-L1 — a Hit spells each side as its own set holds it":

  # A forced case fold, so `Widget.nim` in a diff equals `widget.nim` in a
  # closure. `diffReach` is pure: nothing here is read from disk.
  let froots = initTrackedRoots(getCurrentDir(), @[], "",
    proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(fpAsciiLower))

  proc ftp(rel: string): TrackedPath = fromCanonical(rel, froots).get

  proc fset(rels: varargs[string]): HashSet[TrackedPath] =
    for r in rels: result.incl ftp(r)

  proc flink(rel: string): ClosureLink =
    ClosureLink(path: ftp(rel), target: "t:elsewhere")

  proc fhit(e: DepGraphEntry; changed: HashSet[TrackedPath]): string =
    hitStr(diffReach(e, changed, froots))

  test "hkMember, a changed set smaller than the closure":
    var e: DepGraphEntry
    e.closure = fset("tests/unit/widget.nim", "tests/unit/a.nim",
                     "tests/unit/b.nim")
    check fhit(e, fset("tests/unit/Widget.nim")) ==
      "hkMember tests/unit/Widget.nim -> tests/unit/widget.nim"

  test "hkMember, a closure smaller than the changed set":
    var e: DepGraphEntry
    e.closure = fset("tests/unit/widget.nim")
    check fhit(e, fset("tests/unit/Widget.nim", "docs/a.md", "docs/b.md")) ==
      "hkMember tests/unit/Widget.nim -> tests/unit/widget.nim"

  test "hkLink":
    var e: DepGraphEntry
    e.links.add flink("vendor/lib")
    check fhit(e, fset("VENDOR/Lib")) == "hkLink VENDOR/Lib -> vendor/lib"
    check fhit(e, fset("Vendor")) == "hkLink Vendor -> vendor/lib"

  test "hkUnderLink":
    var e: DepGraphEntry
    e.links.add flink("vendor/lib")
    check fhit(e, fset("Vendor/LIB/dep.nim")) ==
      "hkUnderLink Vendor/LIB/dep.nim -> vendor/lib"

  test "hkAncestor":
    var e: DepGraphEntry
    e.closure = fset("vendor/lib/dep.nim")
    check fhit(e, fset("VENDOR/Lib")) ==
      "hkAncestor VENDOR/Lib -> vendor/lib/dep.nim"

suite "R14-D8 — a changed directory above a dependency root nested in the project":

  # A dependency root configured at `vendor/lib`, inside the project. A
  # changed directory above it (`vendor`, a new nested repository) or at it
  # (`vendor/lib`, a new submodule) is added by its name alone; the files
  # under it are not listed. That is enough only if a member under the
  # nested root is tagged to the PROJECT root, so `ancestorsOrSelf` climbs
  # past the nested root's boundary to the changed name.
  let base = getTempDir() / ("crisol_r14d8_" & $getCurrentProcessId())
  removeDir(base)
  createDir(base / "vendor" / "lib" / "sub")
  writeFile(base / "vendor" / "lib" / "sub" / "dep.nim", "discard")
  let droots = initTrackedRoots(base, @[(name: "lib",
                                         native: base / "vendor" / "lib")], "")

  proc member(): TrackedPath =
    ## The member as the closure records it: Nim's native path, classified.
    let pc = classify(base / "vendor" / "lib" / "sub" / "dep.nim", droots)
    doAssert pc.kind == pcTracked
    pc.tp

  test "a member under the nested root is tagged to the project root":
    check string(keyBytes(member(), droots)) == "vendor/lib/sub/dep.nim"

  test "a changed name above or at the nested root reaches it (hkAncestor)":
    var e: DepGraphEntry
    e.closure.incl member()
    for name in ["vendor", "vendor/lib", "vendor/lib/sub"]:
      checkpoint(name)
      check hitStr(diffReach(e, changedTp(droots, name), droots)) ==
        "hkAncestor " & name & " -> vendor/lib/sub/dep.nim"

  test "CONTROL a sibling directory does not":
    var e: DepGraphEntry
    e.closure.incl member()
    check diffReach(e, changedTp(droots, "vendor/other", "vendor/li"),
                    droots).isNone

  removeDir(base)

when isMainModule:
  echo "test_changed_links done"
