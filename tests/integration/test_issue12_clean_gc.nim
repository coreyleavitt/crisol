## test_issue12_clean_gc.nim — issue #12: `crisol clean` must GC the REAL
## depgraph.
##
## `cleanOrphans` used to call `loadDepGraph(config, "")` — an empty-string
## nimVersion. `fromJson` discards the WHOLE graph as "empty" whenever the
## stored header `nimVersion` differs from the requested one, and a graph
## written by the real pipeline is stamped with the probed Nim fingerprint
## (never ""), so on every real project `clean` loaded an empty graph, ran
## `gcDeletedEntrypoints` against it (a no-op — nothing to drop from
## nothing), and reported 0 entries dropped. The bug was invisible in
## `tests/integration/test_clean.nim`'s depgraph suite because that test
## seeds the graph with `initDepGraph("")` — the one nimVersion for which
## the mismatch never fires.
##
## This test proves the fix end to end through the real CLI entry point
## (`runMain`): a REAL run writes a REAL depgraph (real Nim fingerprint in
## the header), and `clean` must still GC it.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue12_clean_gc.nim

import std/[json, os, osproc, sets, strutils, tables, times, unittest]
import std/posix as posix_mod
import crisol
import crisol/[config, depgraph, nimprobe]

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue11_closure_inputs.nim
# — not imported, so this file has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_issue12_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_issue12_" & tag & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

const ProjectKdl = """
group "unit" {
    globs "tests/unit/t_*.nim"
}
"""

const KeepBody = "echo \"ok\"\n"
const GoneBody = "echo \"ok\"\n"

# ---------------------------------------------------------------------------
# End-to-end proof
# ---------------------------------------------------------------------------

suite "issue #12 — crisol clean GCs the real (fingerprinted) depgraph":

  test "clean drops the deleted entrypoint's depgraph entry and keeps the survivor's":
    let root = newProject("main")
    defer: removeDir(root)
    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n")
    let keepPath = root / "tests" / "unit" / "t_keep.nim"
    let gonePath = root / "tests" / "unit" / "t_gone.nim"
    writeFile(keepPath, KeepBody)
    writeFile(gonePath, GoneBody)

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    # Real run: compiles + runs BOTH entrypoints, writing a REAL depgraph
    # stamped with the REAL probed Nim fingerprint (never "").
    let full = captureStdout(@["run", "--config", cfgPath, "--json"])
    check full.code == 0
    let fullJson = parseJson(full.output.strip())
    check fullJson["entrypoints"].len == 2
    for epNode in fullJson["entrypoints"]:
      check epNode["outcome"].getStr == "passed"

    # Delete one entrypoint from disk (no need to touch git — clean
    # discovers via globs on disk, not via git).
    removeFile(gonePath)
    check not fileExists(gonePath)

    # `clean` must load the REAL (fingerprinted) depgraph, GC it against
    # discovery, and report exactly 1 dropped entry.
    let cln = captureStdout(@["clean", "--config", cfgPath])
    check cln.code == 0
    check "1 depgraph entry(ies)" in cln.output

    # Reload with the freshness view (same call shape as `run`) and verify
    # the on-disk graph itself was actually mutated: the gone entry is
    # gone, the kept entry survived, and the header's nimVersion (the
    # fingerprint) survived the clean's save — clean must never rewrite
    # the fingerprint, only the entries.
    let (cfg, _) = loadConfig(cfgPath)
    let fp = cachedNimFingerprint()
    let graph = loadDepGraph(cfg, fp)
    check graph.header.nimVersion == fp
    check ("tests/unit/t_gone.nim", flagHash(@[])) notin graph.entries
    check ("tests/unit/t_keep.nim", flagHash(@[])) in graph.entries

    # --- Slice 2 -------------------------------------------------------
    # (b) the freshness view still sees the survivor with a non-empty
    # closure after clean — i.e. clean did not stamp "" into the header
    # (which would make every subsequent freshness-view load discard the
    # graph as a nimVersion mismatch against the real fingerprint).
    check graph.entries[("tests/unit/t_keep.nim", flagHash(@[]))].closure.len > 0

    # (a) calling clean again with nothing left to drop must NOT rewrite
    # the depgraph file (issue #12: save iff dropped > 0). Compare content AND
    # mtime; sleep past filesystem mtime resolution first so a spurious
    # rewrite-with-identical-content would still be caught by mtime.
    let depPath = depgraphPath(cfg)
    let beforeContent = readFile(depPath)
    let beforeMtime   = getLastModificationTime(depPath)
    sleep(1100)

    let cln2 = captureStdout(@["clean", "--config", cfgPath])
    check cln2.code == 0
    check "0 depgraph entry(ies)" in cln2.output

    let afterContent = readFile(depPath)
    let afterMtime   = getLastModificationTime(depPath)
    check afterContent == beforeContent
    check afterMtime == beforeMtime
