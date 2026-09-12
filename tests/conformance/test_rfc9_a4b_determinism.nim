## test_rfc9_a4b_determinism.nim — RFC-0009 A4b (D5): the load-bearing
## determinism property (R3-11/R3-12), moved here from A3c-ii per the RFC:
## crisol records a closure member in the ON-DISK real case, deterministically,
## cold and warm — regardless of which importer's case spelled the import.
##
## Recipe (modeled on tests/conformance/test_rfc9_a3bii_fold_selection.nim's
## initRepo/writeF-style fixture helpers and
## tests/conformance/test_spike_import_case.nim's case-fixture approach):
##
##   - One real on-disk dependency, `src/widget.nim` (lowercase, the definite
##     real case).
##   - TWO entrypoints with DIVERGENT importer case: `tests/test_lower.nim`
##     does `import widget`; `tests/test_upper.nim` does `import Widget`.
##     Both compile only on a case-INSENSITIVE volume — on ext4 (this dev
##     container), `import Widget` fails to resolve to on-disk `widget.nim`,
##     so this test depends on the Nim COMPILER's own resolution, never a
##     crisol fold policy simulating it (no policy can be injected to make
##     this compile on ext4 — the premise is a filesystem property, not a
##     crisol setting).
##
## Volume guard: detects case-insensitivity the same way
## test_rfc9_a3bii_fold_selection.nim / test_spike_import_case.nim do (write
## a lowercase temp file, check whether its uppercase spelling also
## resolves). SKIPS with a clear line on a case-sensitive volume — the real
## verdict is the windows-latest/macos-latest CI legs (ci.yml).
##
## Driven through the REAL product path: `runner.plan`/`runner.execute` (the
## same pair tests/integration/test_skipfresh.nim and
## tests/integration/test_nimcache_persistence_real.nim use for a real,
## non-synthetic compile-and-record cycle) — never a hand-rolled nimcache
## manifest. COLD run: fresh `DepGraph`, both entrypoints `edNeverBuilt`,
## `execute()` compiles both for real and persists the graph (issue #5's
## `recordClosure`, now returning `HashSet[TrackedPath]` post-A4b). WARM run:
## `loadDepGraph` reloads the PERSISTED graph with no recompile at all.
##
## The recorded spelling is read from the persisted `DepGraph` itself
## (`DepGraphEntry.closure: HashSet[TrackedPath]`, the same surface
## `api.closureReport`'s `ClosureEntry.closure` wire projects) — since
## `TrackedPath`'s `==`/`hash` are FOLDED (paths.nim's `==` doc comment: two
## members that differ only by ASCII case are the SAME identity under a
## case-insensitive fold policy), membership alone (`in`) cannot distinguish
## "src/widget.nim" from "src/Widget.nim" — only inspecting the located
## member's `display` (its stored, never-folded `.rel`) proves the ON-DISK
## real case was recorded, not the importer's spelling.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_rfc9_a4b_determinism.nim

import std/[os, options, sets, tables, unittest]
import crisol/types
import crisol/paths
import crisol/depgraph
import crisol/runner

proc uniqueTmpDir(tag: string): string =
  result = getTempDir() / ("crisol_a4b_determinism_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc isCaseInsensitiveVolume(dir: string): bool =
  ## Same technique as test_rfc9_a3bii_fold_selection.nim / test_spike_import_case.nim:
  ## write a lowercase temp file directly under `dir`, then check whether its
  ## uppercase spelling also resolves. `dir` must already exist.
  let lowerPath = dir / "a4bdet_casetest.tmp"
  let upperPath = dir / "A4BDET_CASETEST.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)
  removeFile(lowerPath)

proc makeIsolatedConfig(root: string): Config =
  ## Mirrors tests/integration/test_skipfresh.nim's makeIsolatedConfig: REAL
  ## (not vacuous) trackedRoots matching `root` -- decideCompile/recordClosure
  ## reconstruct closure members' native paths against this exact root.
  result = Config(
    projectRoot:        root,
    stateDir:           ".crisol_a4b_determinism_test",
    timeoutSecs:        60,
    compileTimeoutSecs: 120,
    maxOutputBytes:     65_536,
    jobs:               1,
  )
  result.trackedRoots = initTrackedRoots(root, @[], "")

proc widgetSpelling(closure: HashSet[TrackedPath]; roots: TrackedRoots): string =
  ## Locate the closure member fold-EQUIVALENT to "src/widget.nim" (`in`/`==`
  ## on TrackedPath fold, per paths.nim's `==` doc comment) and return its
  ## RAW, never-folded spelling (`display` = the stored `.rel`) — the
  ## on-disk-case proof this test exists for. "" if absent (the caller
  ## asserts non-empty separately, for a clearer failure than an empty-string
  ## equality mismatch).
  let expected = fromCanonical("src/widget.nim", roots).get
  for tp in closure:
    if tp == expected:
      return display(tp)
  ""

proc runDeterminismBody(root: string) =
  createDir(root / "src")
  createDir(root / "tests")
  writeFile(root / "src" / "widget.nim", "proc widgetValue*(): int = 42\n")
  writeFile(root / "tests" / "test_lower.nim",
    "import std/unittest\nimport widget\nsuite \"lower\":\n" &
    "  test \"ok\": check widgetValue() == 42\n")
  writeFile(root / "tests" / "test_upper.nim",
    "import std/unittest\nimport Widget\nsuite \"upper\":\n" &
    "  test \"ok\": check widgetValue() == 42\n")

  let cfg      = makeIsolatedConfig(root)
  let pathFlag = "--path:" & (root / "src")
  let epLower  = Entrypoint(path: "tests/test_lower.nim", group: "default", flags: @[pathFlag])
  let epUpper  = Entrypoint(path: "tests/test_upper.nim", group: "default", flags: @[pathFlag])

  # --- COLD: fresh graph, both entrypoints never built; a REAL compile ---
  var graph = initDepGraph("")
  let p = plan(cfg, @[epLower, epUpper], graph, "", false)
  check p.entrypoints.len == 2
  for pep in p.entrypoints:
    check pep.edecision == edNeverBuilt

  let results = execute(p, config = cfg, graph = graph, nimVersion = "",
                        showProgress = false)
  check results.len == 2
  for r in results:
    check r.outcome == oPassed

  let fh        = flagHash(@[])
  let keyLower  = ("tests/test_lower.nim", fh)
  let keyUpper  = ("tests/test_upper.nim", fh)
  check keyLower in graph.entries
  check keyUpper in graph.entries

  let coldLowerSpelling = widgetSpelling(graph.entries[keyLower].closure, cfg.trackedRoots)
  let coldUpperSpelling = widgetSpelling(graph.entries[keyUpper].closure, cfg.trackedRoots)

  echo "RFC9-A4B COLD: test_lower.nim's recorded widget member spelling = '", coldLowerSpelling, "'"
  echo "RFC9-A4B COLD: test_upper.nim's recorded widget member spelling = '", coldUpperSpelling, "'"

  check coldLowerSpelling.len > 0
  check coldUpperSpelling.len > 0
  check coldLowerSpelling == "src/widget.nim"    # the on-disk real case
  check coldUpperSpelling == "src/widget.nim"    # NEVER "src/Widget.nim" — the importer's case
  check coldLowerSpelling == coldUpperSpelling   # same spelling for both entrypoints

  # --- WARM: reload the PERSISTED graph, no recompile at all ---
  let warmGraph = loadDepGraph(cfg, "")
  check keyLower in warmGraph.entries
  check keyUpper in warmGraph.entries

  let warmLowerSpelling = widgetSpelling(warmGraph.entries[keyLower].closure, cfg.trackedRoots)
  let warmUpperSpelling = widgetSpelling(warmGraph.entries[keyUpper].closure, cfg.trackedRoots)

  echo "RFC9-A4B WARM: test_lower.nim's recorded widget member spelling = '", warmLowerSpelling, "'"
  echo "RFC9-A4B WARM: test_upper.nim's recorded widget member spelling = '", warmUpperSpelling, "'"

  check warmLowerSpelling == coldLowerSpelling   # byte-identical cold vs warm
  check warmUpperSpelling == coldUpperSpelling

suite "RFC-0009 A4b — closure member on-disk-case determinism, cold vs warm":

  test "the recorded widget.nim spelling is on-disk real case for BOTH importers, cold and warm":
    let probeDir = uniqueTmpDir("volprobe")
    let insensitive = isCaseInsensitiveVolume(probeDir)
    removeDir(probeDir)

    if not insensitive:
      echo "RFC9-A4B SKIPPED: case-sensitive volume — 'import Widget' resolving to " &
           "on-disk 'widget.nim' depends on the Nim COMPILER, which no crisol fold " &
           "policy can simulate here. The real verdict is the windows-latest/" &
           "macos-latest CI legs (ci.yml)."
      skip()
    else:
      let root = uniqueTmpDir("proj")
      defer: removeDir(root)
      runDeterminismBody(root)

when isMainModule:
  echo "test_rfc9_a4b_determinism done"
