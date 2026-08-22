## test_depgraph_guard.nim — issue #5 hardening of the depgraph writer.
##
## An EMPTY closure is never a plausible scan result for a real entrypoint
## (a compiled binary's closure contains at least the entrypoint itself).
## Recording one would make the entry permanently fresh: the content hash
## over nothing always matches, so decideCompile / the result-cache key /
## --changed selection could never observe a change. `updateEntry` therefore
## refuses an empty closure (cekInternal — it is a crisol defect, not a user
## error) and leaves any existing entry untouched.
##
## `invalidateEntry` is the writer-side companion: when a closure cannot be
## recorded after a successful compile, the runner must NOT keep serving the
## previous (arbitrarily stale) entry — it drops it, so the next plan sees
## "no closure record" (decideCompile → cdStale; narrow → unknown closure).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_depgraph_guard.nim

import std/[os, sets, tables, unittest]
import crisol/types
import crisol/depgraph

suite "depgraph writer guards (issue #5)":

  test "updateEntry refuses an empty closure and keeps the existing entry":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    let prior = toHashSet(["tests/t.nim", "src/a.nim"])
    g.updateEntry("tests/t.nim", fh, prior, "hash-prior", 1)

    var raised = false
    try:
      g.updateEntry("tests/t.nim", fh, initHashSet[string](), "hash-empty", 1)
    except CrisolError as e:
      raised = true
      check e.kind == cekInternal
    check raised
    check g.entries[("tests/t.nim", fh)].closure == prior
    check g.entries[("tests/t.nim", fh)].closureHash == "hash-prior"

  test "updateEntry refuses an empty closure even for a brand-new key":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    expect CrisolError:
      g.updateEntry("tests/new.nim", fh, initHashSet[string](), "h", 1)
    check ("tests/new.nim", fh) notin g.entries

  test "invalidateEntry drops the entry; absent key is a no-op":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    g.updateEntry("tests/t.nim", fh, toHashSet(["tests/t.nim"]), "h", 1)
    g.invalidateEntry("tests/t.nim", fh)
    check ("tests/t.nim", fh) notin g.entries
    g.invalidateEntry("tests/t.nim", fh)          # idempotent
    g.invalidateEntry("tests/never.nim", fh)      # never present
    check g.entries.len == 0

# ---------------------------------------------------------------------------
# Migration + load-side defense
# ---------------------------------------------------------------------------

proc graphRoot(tag: string): string =
  result = getTempDir() / ("crisol_depgraph_guard_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / ".crisol")

suite "depgraph load guards (issue #5 migration)":

  test "a formatVersion-2 graph (written by the compile-array extractor) loads as empty":
    ## Every v2 entry is suspect: any entry written after a warm recompile is
    ## truncated or empty and hash-matches itself forever, so upgrading does
    ## not self-heal it. Discard the whole graph once (one-time full recompile).
    let root = graphRoot("v2")
    defer: removeDir(root)
    writeFile(root / ".crisol" / "depgraph", """
    { "header": { "nimVersion": "2.2.10", "formatVersion": 2 },
      "entries": [ { "path": "tests/t.nim", "flagHash": "cbf29ce484222325",
                     "closure": ["tests/t.nim"], "closureHash": "abc", "protocolMajor": 1 } ] }
    """)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    check loadDepGraph(cfg, "2.2.10").entries.len == 0

  test "an entry with an empty closure is dropped on load":
    let root = graphRoot("emptycl")
    defer: removeDir(root)
    writeFile(root / ".crisol" / "depgraph", """
    { "header": { "nimVersion": "2.2.10", "formatVersion": """ & $DepGraphFormatVersion & """ },
      "entries": [
        { "path": "tests/empty.nim", "flagHash": "cbf29ce484222325",
          "closure": [], "closureHash": "abc", "protocolMajor": 1 },
        { "path": "tests/ok.nim", "flagHash": "cbf29ce484222325",
          "closure": ["tests/ok.nim"], "closureHash": "def", "protocolMajor": 1 } ] }
    """)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    let g = loadDepGraph(cfg, "2.2.10")
    check ("tests/empty.nim", "cbf29ce484222325") notin g.entries
    check ("tests/ok.nim", "cbf29ce484222325") in g.entries
