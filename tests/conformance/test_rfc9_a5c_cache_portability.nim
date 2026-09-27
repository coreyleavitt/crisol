## test_rfc9_a5c_cache_portability.nim — RFC-0009 A5c: the cache-portability
## E2E (Fork C's load-bearing proof).
##
## Proves a depRoot closure member's cache key is HOST-PORTABLE: a run whose
## project tree (and dep root's own native spelling) relocates between two
## invocations still HITS the local ("l1") result cache on the second
## invocation, because the soundnessKey's content-hash input is now
## `keyBytes` (`dep:<name>/<rel>` — RFC-0009 A5a), never the dep member's
## absolute native path.
##
## Why relocating a SINGLE-root project would prove nothing (RFC-0009 A5c's
## own warning): a project-root (tag-0) member's `keyBytes` is ALREADY its
## bare relative path today, on `main`, pre-A5a — portable by construction.
## Only a DEP-root (tag>0) member's key had the pre-A5a absolute-path
## fall-through (`fnv.nim:68`) this slice fixes. So the fixture below puts
## the entrypoint's ONE dependency under a CONFIGURED DEP ROOT (never the
## project root) — `D/src/depmod.nim`, tracked as dep root "thedep" — making
## this test RED on `main` (misses on relocation) and GREEN only once A5a's
## `dep:name/rel` key is live.
##
## Fixture:
##   D  — a real directory, NEVER nested under the project (`src/depmod.nim`).
##   P1 — project v1. `P1/_deps/thedep` is a DIR LINK to `D` (R3-14: exercises
##        `NativeRoot.realAbs`'s under-selection fix end to end, not just
##        unit-tested — negative control 2, below). `crisol.kdl` configures
##        `dep-roots "_deps/thedep" name="thedep"` and a matching
##        project-relative `flags "--path:_deps/thedep/src"` so `import
##        depmod` resolves — BOTH relative to `projectRoot` (the compile
##        child's cwd is always `config.projectRoot`, `runner.nim`'s own
##        rfc-0007 A2c pin), so this KDL text is byte-identical whether it
##        lives at P1 or P2 below: the ONLY thing that varies between runs
##        is the PROJECT TREE'S OWN absolute location, never a compile flag
##        (which would otherwise confound `flagHash`, a SEPARATE component
##        of `SoundnessKey` — RFC-0005 `keys.nim` — and falsely explain any
##        miss having nothing to do with depRoot-key portability).
##   The result cache itself is pinned to a FIXED external directory via
##   `CRISOL_STATE_DIR` (`config.stateDirOf`'s own documented escape hatch
##   for "a sandboxed container redirects crisol's build cache onto a
##   mounted volume that lives outside the project tree") — exactly this
##   test's scenario: the cache must survive the project relocating.
##
## RUN 1 (P1, cold): stores exactly one local cache entry.
## RELOCATE: P1 is torn down; P2 is built fresh at a DIFFERENT absolute
##   path, with the SAME relative structure/content and a FRESH dir link at
##   `P2/_deps/thedep` pointing at the SAME `D` — so the dep root's
##   CONFIGURED (lexical) absolute spelling genuinely differs between runs
##   (negative control 1), while its logical identity (name "thedep", rel
##   "src/depmod.nim") and file content are unchanged.
## RUN 2 (P2, same CRISOL_STATE_DIR): must show `l1Hits == 1`, `misses ==
##   0`, and the cache directory must still hold exactly ONE stored entry
##   (reused, not a second one appended).
##
## The dir link (tests/support/dirlink.nim) is a symlink on POSIX and a
## directory JUNCTION on Windows (R10-L1, issue #21). A Windows directory
## symlink needs SeCreateSymbolicLinkPrivilege, which neither windows-latest
## nor the MSVC container's ContainerAdministrator holds, so a symlink
## fixture could only ever self-skip there. A junction needs no privilege and
## exercises the SAME property: the fixture needs an alias whose realpath
## differs from its lexical spelling, and crisol's Windows realpath
## (`safeExpandFilename` -> GetFinalPathNameByHandleW) resolves a junction
## exactly as it resolves a symlink. So there is no self-skip: this test runs
## its real body on every leg, and a link-creation failure is a FAILURE.

import std/[os, strutils, unittest]
import crisol/api
import crisol/types
import crisol/resultcache  # cacheVersionDirAt
import crisol/paths        # safeExpandFilename — crisol's own realpath
import "../support/dirlink"

const DepModBody = "proc depVal*(): int = 7\n"

const EntrypointBody = """
import depmod
doAssert depVal() == 7
"""

proc kdlFor(depRootRel: string): string =
  "flags \"--path:" & depRootRel & "/src\"\n" &
  "dep-roots \"" & depRootRel & "\" name=\"thedep\"\n" &
  "group \"unit\" {\n" &
  "    globs \"tests/unit/test_*.nim\"\n" &
  "}\n"

proc realOf(p: string): string =
  ## crisol's realpath (the primitive `NativeRoot.realAbs` is built from),
  ## forward-slash normalized. `expandFilename` would be wrong here: on
  ## Windows it is GetFullPathNameW, purely lexical, and never follows a
  ## reparse point.
  safeExpandFilename(p).replace('\\', '/')

proc teardownProject(root: string) =
  ## Unlinks the dep-root dir link BEFORE removing the tree: `removeDir`
  ## cannot unlink a Windows junction (see tests/support/dirlink.nim).
  removeDirLink(root / "_deps" / "thedep")
  removeDir(root)

proc buildProject(root, depRootAbs: string) =
  ## Lays out a fresh project tree at `root`, with `_deps/thedep` a dir link
  ## (symlink on POSIX, junction on Windows) to `depRootAbs`.
  teardownProject(root)
  createDir(root / "tests" / "unit")
  writeFile(root / "crisol.kdl", kdlFor("_deps/thedep"))
  writeFile(root / "tests" / "unit" / "test_uses_dep.nim", EntrypointBody)
  createDir(root / "_deps")
  createDirLink(depRootAbs, root / "_deps" / "thedep")

proc countStoredEntries(cacheRoot: string): int =
  ## Mirrors `cachelocalfs.countEntries`/`resultcache.countCacheEntries`
  ## exactly (both private): count `*.json` files directly inside the
  ## version dir, non-recursive (the "inputs" explain-miss sidecar sits in
  ## its own subdirectory and is never touched by this walk).
  let dir = cacheVersionDirAt(cacheRoot)
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      inc result

suite "RFC-0009 A5c — cache-portability E2E (depRoot member, relocated tree)":

  test "a depRoot closure member's cache key survives relocating the project tree":
    let base = getTempDir() / ("crisol_a5c_" & $getCurrentProcessId())
    let d       = base / "dep_real"       # D — never nested under P1/P2
    let p1      = base / "proj_v1"
    let p2      = base / "proj_v2"
    let sharedStateDir = base / "shared_state"   # CRISOL_STATE_DIR target

    removeDir(base)
    createDir(d / "src")
    writeFile(d / "src" / "depmod.nim", DepModBody)
    createDir(sharedStateDir)

    putEnv("CRISOL_STATE_DIR", sharedStateDir)
    defer:
      delEnv("CRISOL_STATE_DIR")
      try: removeDirLink(p1 / "_deps" / "thedep")
      except CatchableError: discard
      try: removeDirLink(p2 / "_deps" / "thedep")
      except CatchableError: discard
      removeDir(base)

    # --- RUN 1: P1, dir-linked dep root -> D ----------------------------
    buildProject(p1, d)

    let p1DepRootLexical = p1 / "_deps" / "thedep"
    # Negative control 2 (realAbs != lexical prefix): the configured dep
    # root is a REAL alias -- its realpath resolves to D, genuinely
    # different from its own lexical, configured spelling. Proves
    # `NativeRoot.realAbs`'s fix (RFC-0009 A4a) is exercised END TO END by
    # this very fixture, not merely by a unit test. The "differs" side is
    # measured against the realpath of the link's PARENT plus its own leaf,
    # so a realpath that merely rewrites the temp-dir prefix (macOS
    # /var -> /private/var, a Windows 8.3 RUNNER~1 component, separator
    # style) cannot satisfy it — only the link itself being resolved can.
    check realOf(p1DepRootLexical) != realOf(p1DepRootLexical.parentDir) & "/thedep"
    check realOf(p1DepRootLexical) == realOf(d)
    echo "RFC9-A5C ALIAS " & (when defined(windows): "junction" else: "symlink")

    let rr1 = runTests(RunOptions(configPath: p1 / "crisol.kdl", jobs: 1,
                                  cacheStats: true))
    check rr1.status == rsOk
    check rr1.results.len == 1
    check rr1.results[0].outcome == oPassed
    check rr1.cacheStats.misses == 1
    check rr1.cacheStats.l1Hits == 0

    let cacheRoot = sharedStateDir / "cache"
    check countStoredEntries(cacheRoot) == 1

    # --- RELOCATE: tear down P1, build P2 elsewhere, SAME dep content ---
    let p2DepRootLexical = p2 / "_deps" / "thedep"
    teardownProject(p1)
    buildProject(p2, d)

    # Negative control 1: the two runs' raw native dep-root spellings
    # genuinely differ -- so a HIT below cannot be a filesystem coincidence
    # (identical absolute paths reused), only the portable `dep:name/rel`
    # key (RFC-0009 A5a) explains it.
    check p1DepRootLexical.absolutePath.normalizedPath !=
          p2DepRootLexical.absolutePath.normalizedPath
    check realOf(p2DepRootLexical) != realOf(p2DepRootLexical.parentDir) & "/thedep"
    check realOf(p2DepRootLexical) == realOf(d)

    # --- RUN 2: P2, same CRISOL_STATE_DIR --------------------------------
    let rr2 = runTests(RunOptions(configPath: p2 / "crisol.kdl", jobs: 1,
                                  cacheStats: true))
    check rr2.status == rsOk
    check rr2.results.len == 1
    check rr2.results[0].outcome == oPassed
    check rr2.cacheStats.l1Hits == 1
    check rr2.cacheStats.misses == 0

    # Reused, not appended: still exactly one stored entry.
    check countStoredEntries(cacheRoot) == 1

    teardownProject(p2)
