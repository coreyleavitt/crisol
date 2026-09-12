## test_closure_a4a.nim — RFC-0009 A4a: symlinked dep-root under-selection
## proof (under-selection bug #2 in the slice's design brief).
##
## Bug (pre-A4a): closure.nim's `underAnyRoot` matched a candidate against
## each tracked root's LEXICAL absolute path ONLY — `SourceIndex.roots`
## deliberately never recorded a dep root's realpath-expanded form (see
## `buildSourceIndex`'s doc comment for why: adding it would have
## short-circuited the `@m`/`@p` byReal RECOVERY mechanisms those branches
## rely on). A manifest entry that named a candidate's realpath DIRECTLY —
## with no `@m`/`@p` mangling to decode and therefore no recovery fallback
## available (e.g. a `depfiles` entry, or a `{.link.}`d prebuilt object) —
## had no path back to a tracked root when that realpath differed from
## every root's LEXICAL spelling (a symlinked dep root). It classified as
## "outside every tracked root" and was silently DROPPED: an
## under-selection, since a later change to that exact file would never
## trigger re-selection of the entrypoint.
##
## Fix (D1/D2, closure.nim): every candidate now routes through
## `SourceIndex.tracked` / `paths.classify`, which matches a dep root's
## `realAbs` (its `expandFilename`'d form, probed once at
## `initTrackedRoots` construction) in addition to its lexical `abs` — so
## this exact candidate is recognized as tracked on the FIRST pass, no
## recovery fallback needed, and is retained in the closure.

import std/[os, sets, json]
import crisol/types
import crisol/paths
import crisol/closure

proc writeManifestWithDepfile(dir, bname: string; depfilePath: string) =
  ## `link` carries only the entrypoint's own module object (so
  ## `analyzeManifest` doesn't raise on an empty `link`); the candidate
  ## under test is named directly in `depfiles` — a raw absolute path, no
  ## `@m`/`@p` mangling — so no decode/recovery machinery is exercised: this
  ## isolates the under-tracked-root gate itself (D2/`index.tracked`).
  let node = newJObject()
  node["compile"] = newJArray()
  let linkArr = newJArray()
  linkArr.add newJString(dir / bname & ".nim.c.o")
  node["link"] = linkArr
  let dfArr = newJArray()
  let pair = newJArray()
  pair.add newJString(depfilePath)
  pair.add newJString("")
  dfArr.add pair
  node["depfiles"] = dfArr
  createDir(dir)
  writeFile(dir / bname & ".json", $node)

block test_a4a_symlinked_dep_root_realpath_candidate_classifies_tracked:
  ## Direct `index.tracked` proof: a candidate reached ONLY via a dep root's
  ## realAbs (its realpath differs from its own lexical, configured spelling)
  ## classifies `pcTracked`, dep-tagged.
  let projRoot = getTempDir() / "crisol_a4a_proj"
  let realDepDir = getTempDir() / "crisol_a4a_dep_real"
  let symlinkDepRoot = getTempDir() / "crisol_a4a_dep_symlink"
  removeDir(projRoot)
  removeDir(realDepDir)
  if symlinkExists(symlinkDepRoot) or fileExists(symlinkDepRoot):
    removeFile(symlinkDepRoot)
  createDir(projRoot / "tests")
  createDir(realDepDir / "lib")
  writeFile(realDepDir / "lib" / "widget.nim", "# widget\n")

  try:
    createSymlink(realDepDir, symlinkDepRoot)
  except OSError as e:
    echo "SKIP test_closure_a4a: symlink creation failed in this environment: " & e.msg
    removeDir(projRoot)
    removeDir(realDepDir)
    quit(0)

  defer:
    removeDir(projRoot)
    removeDir(realDepDir)
    removeFile(symlinkDepRoot)

  var cfg = Config(projectRoot: projRoot, stateDir: ".crisol",
                   depRoots: @[symlinkDepRoot])
  cfg.trackedRoots = initTrackedRoots(projRoot, @[(name: "dep", native: symlinkDepRoot)],
                                      ".crisol")

  let index = buildSourceIndex(cfg)

  # The realpath-through-the-symlink candidate: what a compiler that
  # canonicalizes via realpath (or a depfiles entry naming the resolved
  # path directly) would hand back — NOT the lexical `symlinkDepRoot`-based
  # spelling.
  let realCandidate = expandFilename(symlinkDepRoot / "lib" / "widget.nim")
  doAssert realCandidate != (symlinkDepRoot / "lib" / "widget.nim").normalizedPath,
    "fixture bug: realpath must differ from the lexical symlinked-dep-root path"

  let pc = index.tracked(realCandidate)
  assert pc.kind == pcTracked,
    "A4a bug #2: a dep root reached via a symlink must classify its " &
    "realpath-through-the-symlink candidates as pcTracked (matched via " &
    "the dep root's realAbs), not pcOutside. Got: " & $pc.kind
  assert not isProject(pc.tp),
    "the realCandidate is under the DEP root (via realAbs), not the project root"

  # Retention proof: a manifest naming this exact realpath candidate in
  # `depfiles` (no @m/@p mangling, so no byReal recovery machinery is
  # exercised — isolates the under-tracked-root gate itself) must retain it
  # in the extracted closure, not silently drop it.
  let ep = projRoot / "tests" / "t.nim"
  writeFile(ep, "# ep\n")
  let nc = projRoot / "nimcache"
  writeManifestWithDepfile(nc, "t", realCandidate)

  let closureSet = extractClosure(nc, "t", ep, cfg, index)
  let expectedSpelling = toNative(pc.tp, cfg.trackedRoots)
  assert expectedSpelling in closureSet,
    "A4a bug #2: the symlinked-dep-root realpath candidate must be RETAINED " &
    "in the closure (dep-tagged member spells as its absolute native path, " &
    "RFC-0009 A4a corrected-D5). Got: " & $closureSet

echo "PASS test_closure_a4a"
