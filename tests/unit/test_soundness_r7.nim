## test_soundness_r7.nim — R7: @p resolution must not mis-attribute between tracked roots.
##
## Bug: resolveMangled for @p takes the FIRST root where the file exists.
## If projectRoot/src/shared.nim and depRoot/src/shared.nim both exist and have
## the same @p body, first-match returns projRoot. But if the actual import came
## from depRoot, a change to depRoot/src/shared.nim won't match the stored
## projRoot-relative path → under-selection.
##
## Fix (safe over-selection fallback): when @p body resolves under MULTIPLE tracked
## roots, record the file under ALL of them (over-selection). This ensures that a
## change to either root's copy triggers re-selection.
##
## When @p body resolves under exactly ONE tracked root, behavior is unchanged.

import std/[os, sets, json]
import crisol/types
import crisol/closure

proc writeNimcacheJson(dir: string; bname: string; pairs: seq[(string, string)]) =
  let compileArr = newJArray()
  for (c, cmd) in pairs:
    let pair = newJArray()
    pair.add newJString(c)
    pair.add newJString(cmd)
    compileArr.add pair
  # `link` mirrors `compile` (one object per C unit) — the shape Nim emits on a
  # cold compile; extractClosure reads `link` (issue #5).
  let linkArr = newJArray()
  for (c, _) in pairs: linkArr.add newJString(c & ".o")
  let node = newJObject()
  node["compile"] = compileArr
  node["link"]    = linkArr
  node["depfiles"] = newJArray()
  createDir(dir)
  writeFile(dir / bname & ".json", $node)

block test_r7_ambiguous_at_p_includes_all_matching_roots:
  ## shared.nim exists under BOTH projectRoot/src/ and depRoot/src/.
  ## The @p body "shared.nim" matches BOTH (via projRoot/src and depRoot/src roots).
  ## With first-match-wins (bug): only projRoot/src/shared.nim → "src/shared.nim".
  ## With over-selection fix: BOTH roots recorded → projRoot "src/shared.nim"
  ## AND depRoot "src/shared.nim" (stored as absolute depRoot path).
  ## This means the closure is larger → more selection, never under-select.
  let projRoot = getTempDir() / "crisol_r7_proj"
  let depRoot  = getTempDir() / "crisol_r7_dep"
  createDir(projRoot / "src")
  createDir(depRoot / "src")
  defer:
    removeDir(projRoot)
    removeDir(depRoot)

  # shared.nim exists under BOTH roots.
  writeFile(projRoot / "src" / "shared.nim", "# proj shared")
  writeFile(depRoot  / "src" / "shared.nim", "# dep shared")

  let epFile = projRoot / "tests" / "test_ep.nim"
  createDir(projRoot / "tests")
  writeFile(epFile, "# ep")

  let cFileName = "@pshared.nim.c"
  let nimcacheDir = projRoot / "nimcache"
  let bname = "test_ep"
  writeNimcacheJson(nimcacheDir, bname, @[
    (nimcacheDir / cFileName, "gcc"),
  ])

  let cfg = Config(
    projectRoot: projRoot,
    stateDir: ".crisol",
    depRoots: @[depRoot],
  )

  let closureSet = extractClosure(nimcacheDir, bname, epFile, cfg)

  # projRoot/src/shared.nim → "src/shared.nim" must be in closure.
  assert "src/shared.nim" in closureSet,
    "R7: projRoot/src/shared.nim must be in closure. Got: " & $closureSet

  # SOUNDNESS CHECK: depRoot/src/shared.nim must ALSO be in the closure.
  # With the over-selection fix, any @p body that matches multiple roots gets ALL recorded.
  # Since depRoot/src/shared.nim is under a tracked depRoot, it must also be in closure.
  # Its path in the closure will be either absolute (depRoot/src/shared.nim) or
  # relative to depRoot. Either way, the closure len must be > 1.
  assert closureSet.len > 1,
    "R7: when @p body matches both projRoot and depRoot, BOTH must be recorded. " &
    "Got only: " & $closureSet

block test_r7_unambiguous_at_p_exact_single_result:
  ## Only ONE root has the file → unambiguous → single entry in closure.
  let projRoot = getTempDir() / "crisol_r7_proj2"
  let depRoot  = getTempDir() / "crisol_r7_dep2"
  createDir(projRoot / "src")
  createDir(depRoot / "src")
  defer:
    removeDir(projRoot)
    removeDir(depRoot)

  # only.nim under projRoot/src ONLY (not in depRoot).
  writeFile(projRoot / "src" / "only.nim", "# only in proj")

  let epFile = projRoot / "tests" / "test_ep.nim"
  createDir(projRoot / "tests")
  writeFile(epFile, "# ep")

  let cFileName = "@ponly.nim.c"
  let nimcacheDir = projRoot / "nimcache"
  let bname = "test_ep"
  writeNimcacheJson(nimcacheDir, bname, @[
    (nimcacheDir / cFileName, "gcc"),
  ])

  let cfg = Config(
    projectRoot: projRoot,
    stateDir: ".crisol",
    depRoots: @[depRoot],
  )

  let closureSet = extractClosure(nimcacheDir, bname, epFile, cfg)
  assert "src/only.nim" in closureSet,
    "R7: unambiguous @p file under projectRoot/src must be in closure. Got: " & $closureSet
  assert closureSet.len == 1,
    "R7: unambiguous @p should yield exactly 1 closure entry. Got: " & $closureSet

echo "PASS test_soundness_r7"
