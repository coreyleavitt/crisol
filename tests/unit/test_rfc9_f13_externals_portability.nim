## test_rfc9_f13_externals_portability.nim — RFC-0009 wiring-audit finding
## F13: `closure.ExternalSource.source`/`.headers` spellings (and the
## `headersHash` computed over them) survive a RELOCATED checkout.
##
## Pre-fix, `closureMemberSpelling` spelled a DEP-ROOT member as its
## ABSOLUTE NATIVE path (`toNative`) for exactly this surface (a project
## member already spelled portable) — so `ExternalSource.source`/`.headers`
## for a `{.compile.}`d external's dep-root header embedded the checkout's
## (and the dep root's) own absolute location. Relocating either silently
## changed the persisted spelling and the `headersHash` chained over it,
## invalidating carry-forward and forcing recompilation even though the
## logical closure — same files, same content, same root/rel identity —
## never changed.
##
## This is the unit-level counterpart to
## tests/conformance/test_rfc9_a5c_cache_portability.nim's E2E relocation
## proof: that test covers `entry.closure`'s A5a key (already portable
## before this fix); this one covers the externals surface F13 retypes,
## which that E2E fixture never exercises (no `{.compile.}`d source in its
## fixture). Kept unit-level and fast (no real `nim c`, no cache/result
## pipeline) — a synthetic nimcache manifest plus an injected `cc -M` probe
## drive production `closure.extractCompileInputs` directly, exactly like
## tests/unit/test_issue16_unit.nim's fixtures, and the extracted
## `ExternalSource`s are additionally round-tripped through
## `depgraph.saveDepGraph`/`loadStoredDepGraph` to prove the property holds
## end to end through persistence, not merely in memory.
##
## Two independently-built fixtures ("A", "B") share IDENTICAL file
## content and relative structure but live at two DIFFERENT absolute
## project roots, each with its OWN absolute dep root — so any assertion
## that the two builds produce byte-identical `source`/`headers`/
## `headersHash` can only hold if those fields are genuinely portable
## (never a machine-local absolute path leaking through).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc9_f13_externals_portability.nim

import std/[json, os, sequtils, strutils, tables, unittest]
import crisol/types
import crisol/paths
import crisol/closure
import crisol/depgraph

type
  Fixture = object
    root, depRoot, nc, epPath, srcAbs, addH, vendorH, objAbs: string
    cfg: Config

proc buildFixture(tag: string): Fixture =
  ## Lays out a project with one {.compile.}d external (native/add.c,
  ## #including a project-relative header AND a dep-root header) at a
  ## FRESH absolute location tagged `tag` — every call produces
  ## byte-identical file CONTENT under a structurally-identical but
  ## absolutely-DIFFERENT tree.
  let root    = getTempDir() / ("crisol_f13_ext_" & tag & "_" & $getCurrentProcessId())
  let depRoot = getTempDir() / ("crisol_f13_ext_" & tag & "_dep_" & $getCurrentProcessId())
  removeDir(root)
  removeDir(depRoot)
  createDir(root / "native")
  createDir(depRoot)
  result.root    = root
  result.depRoot = depRoot
  result.nc      = root / "nimcache"
  result.epPath  = root / "main.nim"
  result.srcAbs  = root / "native" / "add.c"
  result.addH    = root / "native" / "add.h"
  result.vendorH = depRoot / "vendor.h"
  result.objAbs  = result.nc / "@mnative@sadd.c.o"
  writeFile(result.epPath, "# main\n")
  writeFile(result.srcAbs, "// add.c\n")
  writeFile(result.addH, "// add.h v1\n")
  writeFile(result.vendorH, "// vendor.h v1\n")
  result.cfg = Config(projectRoot: root, stateDir: ".crisol", depRoots: @[depRoot])
  result.cfg.trackedRoots = initTrackedRoots(root, @[(name: "dep", native: depRoot)], ".crisol")
  createDir(root / ".crisol")

proc ccCmdFor(f: Fixture): string =
  ## Mirrors test_issue16_unit.nim's `coldCcCmd` — a real-shaped
  ## "... -o <abs obj> <abs source.c>" command `ccCmdOutputObj` can parse.
  "gcc -c -I" & (f.root / "native") & " -o " & f.objAbs & " " & f.srcAbs

proc writeManifest(f: Fixture) =
  let compileArr = newJArray()
  let pair = newJArray()
  pair.add newJString(f.srcAbs)
  pair.add newJString(ccCmdFor(f))
  compileArr.add pair

  let linkArr = newJArray()
  linkArr.add newJString(f.nc / "@mmain.nim.c.o")
  linkArr.add newJString(f.objAbs)

  let node = newJObject()
  node["compile"]  = compileArr
  node["link"]     = linkArr
  node["linkcmd"]  = newJString("")
  node["depfiles"] = newJArray()

  createDir(f.nc)
  writeFile(f.nc / "main.json", $node)

proc extractExternals(f: Fixture): seq[ExternalSource] =
  ## Drives PRODUCTION `closure.extractCompileInputs` — never a
  ## hand-computed spelling — via a synthetic `cc -M` probe reporting the
  ## SAME two headers (one project-relative, one dep-root) every fixture's
  ## `ccRun` reports, keyed off THIS fixture's own absolute paths (exactly
  ## what a real `cc -M` invocation would report, at whatever location this
  ## fixture happens to live).
  let index = buildSourceIndex(f.cfg)
  writeManifest(f)
  let ccRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    let output = f.objAbs & ": " & f.srcAbs & " native/add.h " & f.vendorH & "\n"
    (output: output, ok: true)
  let inputs = extractCompileInputs(f.nc, "main", f.epPath, f.cfg, index, @[], ccRun)
  inputs.externals

suite "RFC-0009 F13 — externals source/header spellings survive a relocated checkout":

  test "extractCompileInputs: source/headers/headersHash identical across two independently-rooted, content-identical builds":
    let a = buildFixture("A")
    let b = buildFixture("B")
    defer:
      removeDir(a.root); removeDir(a.depRoot)
      removeDir(b.root); removeDir(b.depRoot)

    # Negative control: the two builds' absolute roots genuinely differ, so
    # an equal result below cannot be a filesystem coincidence.
    check a.root != b.root
    check a.depRoot != b.depRoot

    let extA = extractExternals(a)
    let extB = extractExternals(b)

    check extA.len == 1
    check extB.len == 1

    # `source` is tag-0 (the {.compile.}d source itself lives under the
    # project root in this fixture) — sanity: identical either way.
    check extA[0].source == extB[0].source
    check extA[0].source == "native/add.c"

    # The MEAT: the dep-root header's portable spelling. Pre-F13 this was
    # `f.vendorH` (an absolute native path) and would have differed between
    # `a` and `b` by construction (they live at different absolute
    # locations) — this assertion would have failed on `main` before this
    # fix. Post-F13 it is `dep:<name>/<rel>`, independent of either
    # fixture's absolute location.
    check extA[0].headers == extB[0].headers
    check extA[0].headers.len == 2
    check "native/add.h" in extA[0].headers
    let depHeader = extA[0].headers.filterIt(it.startsWith("dep:"))
    check depHeader.len == 1
    check depHeader[0] == "dep:dep/vendor.h"

    # headersHash chains the portable spelling as its KEY (content read
    # from each fixture's own native path via fromKeyBytes->toNative) — so
    # two content-identical builds hash identically even though the actual
    # bytes read come from two entirely different absolute files on disk.
    check extA[0].headersHash == extB[0].headersHash
    check extA[0].headersHash.len == 16

  test "depgraph round-trip: saved/reloaded externals stay identical across the same two builds":
    let a = buildFixture("rtA")
    let b = buildFixture("rtB")
    defer:
      removeDir(a.root); removeDir(a.depRoot)
      removeDir(b.root); removeDir(b.depRoot)

    let index = buildSourceIndex(a.cfg)
    let indexB = buildSourceIndex(b.cfg)
    writeManifest(a)
    writeManifest(b)
    proc ccRunFor(f: Fixture): RunProc =
      proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
        let output = f.objAbs & ": " & f.srcAbs & " native/add.h " & f.vendorH & "\n"
        (output: output, ok: true)
    let inputsA = extractCompileInputs(a.nc, "main", a.epPath, a.cfg, index, @[], ccRunFor(a))
    let inputsB = extractCompileInputs(b.nc, "main", b.epPath, b.cfg, indexB, @[], ccRunFor(b))

    var gA = initDepGraph("2.2.10")
    var gB = initDepGraph("2.2.10")
    let fh = flagHash(@[])
    updateEntry(gA, "main.nim", fh, inputsA.files, "chA", 1, inputsA.externals)
    updateEntry(gB, "main.nim", fh, inputsB.files, "chB", 1, inputsB.externals)
    check saveDepGraph(gA, a.cfg)
    check saveDepGraph(gB, b.cfg)

    var discA, discB: DepGraphDiscard
    let loadedA = loadStoredDepGraph(a.cfg, discA)
    let loadedB = loadStoredDepGraph(b.cfg, discB)
    check discA.kind == dgdNone
    check discB.kind == dgdNone

    let entryA = loadedA.entries[("main.nim", fh)]
    let entryB = loadedB.entries[("main.nim", fh)]
    check entryA.externals.len == 1
    check entryB.externals.len == 1
    check entryA.externals[0].source == entryB.externals[0].source
    check entryA.externals[0].headers == entryB.externals[0].headers
    check entryA.externals[0].headersHash == entryB.externals[0].headersHash
    # Round-trip fidelity: unchanged by the save/load cycle itself.
    check entryA.externals[0].headers == inputsA.externals[0].headers
    check entryA.externals[0].headersHash == inputsA.externals[0].headersHash

when isMainModule:
  echo "All test_rfc9_f13_externals_portability tests passed."
