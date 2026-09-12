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
## Absolute paths under projectRoot are also fine (though unusual in practice).

import std/[os, sets, json, tables, options]
import crisol/types
import crisol/depgraph

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

block test_m10_absolute_path_inside_root_kept_on_load:
  ## An absolute path that IS under projectRoot should be kept.
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

  assert g.entries.len == 1, "entry should be loaded"
  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  let loadedClosure = g.entries[key].closure
  let pc = classify(absInsideRoot, cfg.trackedRoots)
  assert pc.kind == pcTracked, "test precondition: absInsideRoot must classify under the tracked root"
  assert pc.tp in loadedClosure,
    "M10: absolute path INSIDE projectRoot should be kept. Got: " & $loadedClosure

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
  ## RFC-0009 A3c-ii: the ORIGINAL (pre-retype) guard kept a surviving
  ## relative path VERBATIM -- the on-disk string was never renormalized.
  ## Once `closure` is `HashSet[TrackedPath]`, that string-level distinction
  ## no longer exists to preserve: `classify`'s `TrackedPath.rel` is ALWAYS
  ## the canonical, dot-free spelling (RFC-0009 A1) -- there is no verbatim
  ## form left in the type at all. The invariant this test actually needs
  ## (a path that normalizes INSIDE the root is KEPT, not dropped) survives
  ## intact below: `insideVerbatim` and its canonical spelling "src/x.nim"
  ## are proven to be the SAME TrackedPath identity, and that identity is
  ## proven present in the loaded closure.
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
  let insideVerbatim  = "src/../src/x.nim"  # normalizes inside root; kept AS-IS

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

  # Escaping members classify pcOutside -- they cannot be represented as a
  # TrackedPath at all, so there is no identity to look up in
  # `loadedClosure`; classifying pcOutside IS the proof they were dropped.
  for escaped in [dotdotEscape, dotdotEscape2, dotdotEscape3]:
    assert classify(escaped, roots).kind == pcOutside,
      "M10: '" & escaped & "' must classify outside every tracked root"

  # A relative path that normalizes INSIDE the root is kept -- its
  # TrackedPath identity is the SAME as its canonical spelling's (RFC-0009
  # A1: `TrackedPath.rel` is always canonical; there is no separate
  # verbatim/renormalized pair of identities left to distinguish).
  let insideVerbatimTp = classify(insideVerbatim, roots).tp
  let canonicalTp      = fromCanonical("src/x.nim", roots).get
  assert insideVerbatimTp == canonicalTp,
    "M10: 'src/../src/x.nim' must canonicalize to the same identity as 'src/x.nim'"
  assert insideVerbatimTp in loadedClosure,
    "M10: relative path normalizing inside root must be kept. Got: " & $loadedClosure

  # Exactly two survivors: legit + the canonicalized insideVerbatim.
  assert loadedClosure.len == 2,
    "M10: expected exactly 2 surviving closure members. Got: " & $loadedClosure

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

block test_m10_depRoot_via_symlink_absolute_path_retained:
  ## Issue #13.2 pin: a configured depRoot that is ITSELF a symlink to
  ## a directory outside root must still admit a stored ABSOLUTE closure
  ## path inside it -- lexically, the path is under the depRoot as
  ## configured, so it is retained (no realpath resolution).
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
  # RFC-0009 A3c-ii: the closure-path M10 filter now runs via `classify`
  # against `cfg.trackedRoots` (NOT `cfg.depRoots`, which only the
  # externals filter still consults) -- register the same dep root there
  # too, or this dep root would be invisible to the closure guard.
  cfg.trackedRoots = initTrackedRoots(root, @[("x", depRootLink)], ".crisol")
  # loadDepGraph reads the depgraph file directly (not via a separate config
  # save), so writing the depgraph and setting depRoots in-process is enough
  # -- loadDepGraph takes `config` directly, no config-file round trip needed.
  let g = loadDepGraph(cfg, "2.2.10")

  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key in g.entries,
    "M10/#13.2: entry with an absolute path under a symlinked depRoot must be retained"
  let loadedClosure = g.entries[key].closure
  let pc = classify(absClosurePath, cfg.trackedRoots)
  assert pc.kind == pcTracked,
    "test precondition: absClosurePath must classify under the symlinked dep root"
  assert pc.tp in loadedClosure,
    "M10/#13.2: absolute path under symlinked depRoot must be retained. Got: " & $loadedClosure

echo "PASS test_soundness_m10"
