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

echo "PASS test_soundness_m10"
