## test_soundness_m10.nim — M10: deserialized closure paths must be re-validated.
##
## Bug: fromJson loads closure paths from the on-disk depgraph without checking
## whether they resolve under a tracked root. A tampered/corrupt depgraph could
## carry absolute paths like /etc/shadow, which would then be read by closureContentHash.
##
## Fix: when loading closure entries from JSON, drop any path that:
##   - Is absolute AND does NOT resolve under projectRoot or any depRoot.
##
## Soundness note: dropping a tampered path is safe (it wasn't a legitimate dep).
## A legitimate relative path like "src/foo.nim" is project-root-relative and fine.
##
## RFC-0009 W1 update: the read side (depgraph.nim's `fromJson`) no longer
## uses `classify` (a native-spelling classifier, total over ANY OS path
## shape) to parse a persisted closure string -- it uses `paths.fromKeyBytes`
## (the `keyBytes` grammar's inverse), which treats persisted text as
## ALREADY-canonical. This is STRICTER than the original M10 fix: an
## absolute path is now dropped EVEN IF it resolves under projectRoot or a
## depRoot (no v7-format file ever legitimately contains one -- `keyBytes`
## only ever emits a relative spelling), and a `.`/`..`-bearing relative
## path is dropped without renormalization (ditto -- `TrackedPath.rel` is
## always dot-free). Both narrowings are exercised below, superseding this
## file's older "kept" pins for the same fixtures.

import std/[os, sets, json, tables, options]
import crisol/types
import crisol/depgraph
import ../support/symlinkprobe

proc makeTmpConfig(root: string): Config =
  ## RFC-0009 A3c-ii: unlike test_depgraph.nim's/test_depgraph_guard.nim's
  ## same-named helper, THIS file's `cfg.trackedRoots` must be REAL (not the
  ## zero-value/vacuous root) -- M10 soundness is exactly a root-BOUNDARY
  ## test (inside vs. outside a tracked root), and the vacuous root's
  ## `project.abs == ""` degenerately treats every absolute path as "inside"
  ## (see classify/underRoot), which would silently defeat every "must be
  ## dropped" assertion below. `initTrackedRoots` probes `root` for real
  ## (the default `probeFoldPolicy`) -- callers must `createDir(root)`
  ## before calling this.
  result = Config(projectRoot: root, stateDir: ".crisol")
  result.trackedRoots = initTrackedRoots(root, @[], ".crisol")

block test_m10_absolute_path_outside_root_dropped_on_load:
  ## A depgraph JSON containing an absolute path outside projectRoot must have
  ## that path silently dropped when loaded. The closure that survives must only
  ## contain paths under projectRoot.
  let root = getTempDir() / "crisol_m10_a"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")

  # Manually construct a depgraph JSON with a tampered absolute path.
  let suspiciousPath = "/etc/passwd"  # clearly outside projectRoot
  let legitimatePath = "src/legit.nim"  # project-root-relative (legitimate)

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": [suspiciousPath, legitimatePath],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }

  let depgraphFile = root / ".crisol" / "depgraph"
  writeFile(depgraphFile, $jsonDoc)

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")

  assert g.entries.len == 1, "entry should be loaded"
  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key in g.entries, "entry key must be present"

  let loadedClosure = g.entries[key].closure
  # RFC-0009 A3c-ii: `loadedClosure` is `HashSet[TrackedPath]` -- a member
  # can only exist in it via `classify`'s `pcTracked` arm, so a path that
  # classifies `pcOutside` (like `suspiciousPath`, below) cannot possibly be
  # represented in it at all; proving it was dropped is proving the
  # surviving closure is EXACTLY the legitimate member, no more.
  assert classify(suspiciousPath, cfg.trackedRoots).kind == pcOutside,
    "test precondition: suspiciousPath must classify outside the tracked root"
  let expectedLegit = fromCanonical(legitimatePath, cfg.trackedRoots).get
  assert loadedClosure.len == 1,
    "M10: absolute path outside projectRoot must be dropped on load. Got: " & $loadedClosure
  assert expectedLegit in loadedClosure,
    "M10: legitimate relative path must be preserved. Got: " & $loadedClosure

block test_m10_absolute_path_inside_root_dropped_on_load:
  ## RFC-0009 W1: a v7-format closure member is ALWAYS a `paths.keyBytes`
  ## spelling -- a bare project-relative rel, a dep-root `dep:<name>/<rel>`,
  ## or the `./dep:*` escape -- never a raw absolute native path.
  ## `saveDepGraph`/`toJson` never emit one (`keyBytes`'s rootTag-0 arm
  ## returns `tp.rel`, always relative; the tag>0 arm returns
  ## `dep:<name>/<rel>`), so an absolute path reaching this file can only be
  ## hand-tampered/hand-crafted text -- corrupt by construction under this
  ## format, regardless of whether it happens to resolve under a tracked
  ## root. `fromKeyBytes` (the keyBytes grammar's inverse, which replaced
  ## `classify` in the read path -- see depgraph.nim's `fromJson` doc)
  ## accordingly rejects it outright: it is neither `dep:*` nor `./*`, so it
  ## falls to the plain-rel arm, and `fromCanonical` rejects any leading
  ## `/` as a shape violation. This SUPERSEDES the pre-W1 version of this
  ## test (same closure content, `classify`-based read side, "kept"),
  ## which relied on `classify` being TOTAL over any native spelling --
  ## exactly the property that made it unable to distinguish a legitimate
  ## persisted spelling from a phantom/corrupt one (the W1 defect).
  let root = getTempDir() / "crisol_m10_b"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")

  let absInsideRoot = root / "src" / "inside.nim"  # absolute, under root

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": [absInsideRoot],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }

  writeFile(root / ".crisol" / "depgraph", $jsonDoc)

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")

  # The sole closure member is dropped as corrupt (not a keyBytes spelling)
  # -- NONEMPTY-CLOSURE then removes the whole entry, exactly like
  # test_m10_relative_all_escaping_drops_entry, below.
  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key notin g.entries,
    "M10/W1: an absolute path is never a legitimate v7 closure spelling, " &
    "even one under projectRoot -- entry must be dropped. entries.len=" & $g.entries.len
  # Sanity: this ISN'T a root-boundary rejection -- absInsideRoot genuinely
  # classifies pcTracked under the live roots. It is the STRING SHAPE
  # (absolute, not a keyBytes spelling), not root membership, that
  # `fromKeyBytes` rejects.
  assert classify(absInsideRoot, cfg.trackedRoots).kind == pcTracked,
    "test precondition: absInsideRoot must classify under the tracked root"

block test_m10_relative_dotdot_escape_dropped_on_load:
  ## Issue #13.1: a RELATIVE path is admitted unchecked today, so
  ## "../../etc/passwd" (and any other relative path that normalizes to a
  ## location outside projectRoot) escapes the guard entirely -- then
  ## closureContentHash (projectRoot / relPath) reads outside the root.
  ##
  ## Issue #13.1: normalize every path (absolute: as-is; relative: projectRoot / p)
  ## and keep iff the normalized candidate is projectRoot or a depRoot, or
  ## lives under one of them.
  ##
  ## RFC-0009 W1 supersedes A3c-ii's own note here: the read side no longer
  ## renormalizes a persisted string at all (`classify`, which resolved
  ## `.`/`..` segments via `nativeCanonicalize`, is no longer in the read
  ## path -- see depgraph.nim's `fromJson` doc). `fromKeyBytes`/
  ## `fromCanonical` treat persisted text as ALREADY-canonical: a `.` or
  ## `..` segment is a shape violation, full stop, regardless of where the
  ## path would resolve if renormalized. `keyBytes`/`display` never emit a
  ## dotted rel (a TrackedPath's `rel` is always dot-free by construction),
  ## so a `.`/`..` segment reaching this file is corrupt/hand-crafted text,
  ## exactly like the absolute-path cases above -- `insideVerbatim` below
  ## is now dropped too, not renormalized-and-kept.
  let root = getTempDir() / "crisol_m10_c"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")
  createDir(root / "src")
  writeFile(root / "src" / "legit.nim", "# legit\n")

  let legit          = "src/legit.nim"
  let dotdotEscape    = "../../etc/passwd"
  let dotdotEscape2   = "src/../../escape.nim"
  let dotdotEscape3   = "a/../../b.nim"
  let insideVerbatim  = "src/../src/x.nim"  # renormalizes inside root; still DROPPED (W1)

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": [legit, dotdotEscape, dotdotEscape2, dotdotEscape3, insideVerbatim],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }
  writeFile(root / ".crisol" / "depgraph", $jsonDoc)

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")

  assert g.entries.len == 1, "entry should be loaded"
  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key in g.entries, "entry key must be present"
  let loadedClosure = g.entries[key].closure
  let roots = cfg.trackedRoots

  let legitTp = fromCanonical(legit, roots).get
  assert legitTp in loadedClosure,
    "M10: legitimate relative path must be kept. Got: " & $loadedClosure

  # Escaping members classify pcOutside -- proof (independent of W1's
  # shape rejection) that they'd never have been legitimate root members
  # even if `fromCanonical` tolerated dots.
  for escaped in [dotdotEscape, dotdotEscape2, dotdotEscape3]:
    assert classify(escaped, roots).kind == pcOutside,
      "M10: '" & escaped & "' must classify outside every tracked root"

  # RFC-0009 W1: `insideVerbatim` contains a ".." segment -- not a
  # `fromCanonical`-legal shape -- so it is dropped as corrupt REGARDLESS
  # of the fact that it would renormalize inside the root. Sanity: this is
  # a SHAPE rejection, not a root-boundary one (classify, which DOES
  # renormalize, agrees it resolves inside root).
  let insideVerbatimTp = classify(insideVerbatim, roots).tp
  let canonicalTp      = fromCanonical("src/x.nim", roots).get
  assert insideVerbatimTp == canonicalTp,
    "M10: 'src/../src/x.nim' must canonicalize to the same identity as 'src/x.nim'"
  assert canonicalTp notin loadedClosure,
    "M10/W1: a dotted rel must be dropped even though it renormalizes inside root. Got: " & $loadedClosure

  # Exactly one survivor: legit only.
  assert loadedClosure.len == 1,
    "M10/W1: expected exactly 1 surviving closure member. Got: " & $loadedClosure

block test_m10_relative_all_escaping_drops_entry:
  ## A closure consisting ONLY of escaping relative paths must have the
  ## whole entry removed (the existing empty-after-filter rule).
  let root = getTempDir() / "crisol_m10_d"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": ["../../etc/passwd", "src/../../escape.nim"],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }
  writeFile(root / ".crisol" / "depgraph", $jsonDoc)

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")

  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key notin g.entries,
    "M10: an entry whose closure is entirely escaping relative paths must be removed"

block test_m10_symlinked_source_inside_root_retained:
  ## Issue #13.2 pin: the M10 guard is deliberately LEXICAL, matching
  ## the closure extractor's `underAnyRoot` tracking policy (see
  ## crisol/closure.nim). A source file that is a SYMLINK to a target
  ## OUTSIDE every tracked root, but whose LEXICAL path lives inside the
  ## root, must be RETAINED (not resolved-and-dropped) -- and
  ## closureContentHash must still succeed against it (hashes through the
  ## link, exactly as the extractor recorded it).
  if not symlinksAvailable():
    echo "SKIP: symlinks unavailable"
    break
  let root = getTempDir() / "crisol_m10_e"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")
  createDir(root / "src")

  let outsideDir = getTempDir() / "crisol_m10_e_outside"
  createDir(outsideDir)
  defer: removeDir(outsideDir)
  let outsideTarget = outsideDir / "outside_target.nim"
  writeFile(outsideTarget, "# outside content\n")

  let linkPath = root / "src" / "linked.nim"
  createSymlink(outsideTarget, linkPath)
  defer: removeSymlinkSafe(linkPath)

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": ["src/linked.nim"],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }
  writeFile(root / ".crisol" / "depgraph", $jsonDoc)

  let cfg = makeTmpConfig(root)
  let g = loadDepGraph(cfg, "2.2.10")

  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key in g.entries,
    "M10/#13.2: entry with a lexically-in-root symlinked source must be retained"
  let loadedClosure = g.entries[key].closure
  let linkedTp = fromCanonical("src/linked.nim", cfg.trackedRoots).get
  assert linkedTp in loadedClosure,
    "M10/#13.2: symlinked source (lexical path in root) must be retained. Got: " & $loadedClosure

  # A warm run stays fresh: closureContentHash must succeed (hash through
  # the link) rather than raise because the guard silently dropped it.
  let h = closureContentHash(@[(key: "src/linked.nim", nativePath: root / "src/linked.nim")])
  assert h.len == 16, "closureContentHash must succeed through the symlink. Got: " & h

block test_m10_depRoot_via_symlink_absolute_path_dropped_on_load:
  ## RFC-0009 W1: same rationale as
  ## test_m10_absolute_path_inside_root_dropped_on_load, above, for a
  ## dep-root member. Historically (pre-A3c-ii/pre-A5a) a dep-root member's
  ## on-disk spelling WAS a raw absolute native path (see depgraph.nim's
  ## DepGraphFormatVersion History) -- that convention is long gone: a v7
  ## dep-root member is ALWAYS `dep:<name>/<rel>` (`paths.keyBytes`). An
  ## absolute path in a v7 closure array -- even one that lexically
  ## resolves under a configured (here, symlinked) dep root -- is
  ## corrupt/hand-crafted text and is dropped, exactly like the
  ## project-root case above. This SUPERSEDES issue #13.2's original
  ## "must be retained" pin for this same fixture (`classify`-based read
  ## side, pre-W1).
  if not symlinksAvailable():
    echo "SKIP: symlinks unavailable"
    break
  let root = getTempDir() / "crisol_m10_f"
  createDir(root)
  defer: removeDir(root)
  createDir(root / ".crisol")
  createDir(root / "_deps")

  let outsideDepsDir = getTempDir() / "crisol_m10_f_outside_deps"
  createDir(outsideDepsDir)
  defer: removeDir(outsideDepsDir)
  writeFile(outsideDepsDir / "lib.nim", "# lib content\n")

  let depRootLink = root / "_deps" / "x"
  createSymlink(outsideDepsDir, depRootLink)
  defer: removeSymlinkSafe(depRootLink)

  let absClosurePath = depRootLink / "lib.nim"  # absolute, lexically under depRootLink

  let headerNode = %* {
    "nimVersion": "2.2.10",
    "formatVersion": DepGraphFormatVersion
  }
  let entryNode = %* {
    "path": "tests/unit/test_ep.nim",
    "flagHash": flagHash(@[]),
    "closure": [absClosurePath],
    "closureHash": "0000000000000000",
    "protocolMajor": 1
  }
  let jsonDoc = %* {
    "header": headerNode,
    "entries": [entryNode]
  }
  writeFile(root / ".crisol" / "depgraph", $jsonDoc)

  var cfg = makeTmpConfig(root)
  cfg.depRoots = @[depRootLink]
  # RFC-0009 A3c-ii: the closure-path M10 filter runs via `fromKeyBytes`
  # (W1) against `cfg.trackedRoots` (NOT `cfg.depRoots`, which only the
  # externals filter still consults) -- register the same dep root there
  # too, or this dep root would be invisible to the closure guard.
  cfg.trackedRoots = initTrackedRoots(root, @[("x", depRootLink)], ".crisol")
  # loadDepGraph reads the depgraph file directly (not via a separate config
  # save), so writing the depgraph and setting depRoots in-process is enough
  # -- loadDepGraph takes `config` directly, no config-file round trip needed.
  let g = loadDepGraph(cfg, "2.2.10")

  # The sole closure member is dropped as corrupt -- NONEMPTY-CLOSURE then
  # removes the whole entry.
  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key notin g.entries,
    "M10/W1: an absolute path under a symlinked depRoot is never a " &
    "legitimate v7 closure spelling -- entry must be dropped."
  # Sanity: this ISN'T a root-boundary rejection -- absClosurePath
  # genuinely classifies pcTracked under the symlinked dep root. It is the
  # STRING SHAPE, not root membership, that `fromKeyBytes` rejects.
  assert classify(absClosurePath, cfg.trackedRoots).kind == pcTracked,
    "test precondition: absClosurePath must classify under the symlinked dep root"

echo "PASS test_soundness_m10"
