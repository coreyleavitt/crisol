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

import std/[os, sets, json, tables]
import crisol/types
import crisol/depgraph

proc makeTmpConfig(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol")

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
  assert suspiciousPath notin loadedClosure,
    "M10: absolute path outside projectRoot must be dropped on load. Got: " & $loadedClosure
  assert legitimatePath in loadedClosure,
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
  assert absInsideRoot in loadedClosure,
    "M10: absolute path INSIDE projectRoot should be kept. Got: " & $loadedClosure

block test_m10_relative_dotdot_escape_dropped_on_load:
  ## Issue #13.1: a RELATIVE path is admitted unchecked today, so
  ## "../../etc/passwd" (and any other relative path that normalizes to a
  ## location outside projectRoot) escapes the guard entirely -- then
  ## closureContentHash (projectRoot / relPath) reads outside the root.
  ##
  ## Issue #13.1: normalize every path (absolute: as-is; relative: projectRoot / p)
  ## and keep iff the normalized candidate is projectRoot or a depRoot, or
  ## lives under one of them. A relative path that normalizes INSIDE the
  ## root is kept VERBATIM (not renormalized) -- see the second assertion
  ## below.
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

  assert legit in loadedClosure,
    "M10: legitimate relative path must be kept. Got: " & $loadedClosure
  assert dotdotEscape notin loadedClosure,
    "M10: '../../etc/passwd' must be dropped. Got: " & $loadedClosure
  assert dotdotEscape2 notin loadedClosure,
    "M10: 'src/../../escape.nim' must be dropped. Got: " & $loadedClosure
  assert dotdotEscape3 notin loadedClosure,
    "M10: 'a/../../b.nim' must be dropped. Got: " & $loadedClosure

  # Issue #13.1: a relative path that normalizes INSIDE the root is kept VERBATIM --
  # not renormalized to "src/x.nim".
  assert insideVerbatim in loadedClosure,
    "M10: relative path normalizing inside root must be kept, VERBATIM. Got: " & $loadedClosure
  assert "src/x.nim" notin loadedClosure,
    "M10: kept relative path must NOT be renormalized. Got: " & $loadedClosure

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
  assert "src/linked.nim" in loadedClosure,
    "M10/#13.2: symlinked source (lexical path in root) must be retained. Got: " & $loadedClosure

  # A warm run stays fresh: closureContentHash must succeed (hash through
  # the link) rather than raise because the guard silently dropped it.
  let h = closureContentHash(@["src/linked.nim"], root)
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
  # loadDepGraph reads the depgraph file directly (not via a separate config
  # save), so writing the depgraph and setting depRoots in-process is enough
  # -- loadDepGraph takes `config` directly, no config-file round trip needed.
  let g = loadDepGraph(cfg, "2.2.10")

  let key = ("tests/unit/test_ep.nim", flagHash(@[]))
  assert key in g.entries,
    "M10/#13.2: entry with an absolute path under a symlinked depRoot must be retained"
  let loadedClosure = g.entries[key].closure
  assert absClosurePath in loadedClosure,
    "M10/#13.2: absolute path under symlinked depRoot must be retained. Got: " & $loadedClosure

echo "PASS test_soundness_m10"
