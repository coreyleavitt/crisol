## test_rfc9_w1_deproot_roundtrip.nim — RFC-0009 wiring-audit W1: dep-root
## closure members survive the depgraph persist/load round trip.
##
## Tracer conformance test, end to end through the public facade. Before
## this fix: a dep-root closure member was serialized (`depgraph.nim`'s
## `toJson`) as a bare `display(tp)` rel — no root qualifier — and
## reconstructed on load via `classify(s, roots)`, whose project-first
## relative join re-tags EVERY persisted member as a phantom tag-0 project
## path (`paths.classify` is total: any bare rel classifies as project-
## relative unless it's under a dep root's OWN absolute native path, which a
## persisted rel string never is). Two consequences, both exercised below:
##
##   1. `api.closureReport` (reads the LOADED graph) emits the phantom
##      member's bare rel instead of the documented `dep:<name>/rel` wire
##      spelling (crisol/closure/v1 rev 3).
##   2. `planner.decideCompile` on a warm second plan treats the phantom
##      member as a DIFFERENT file than the real dep-root file the fresh
##      closure just computed — `edStale` forever, even though nothing
##      changed. The nimcache-persistence lever (MEMORY:
##      nimcache-persistence-lever) is dead for exactly the milpa-CAS
##      dep-root configs it was built for.
##
## Fixture: a project root with ONE dep root ("thedep", a plain sibling
## directory — no symlink; the symlink-realAbs machinery is
## test_rfc9_a5c_cache_portability.nim's concern, not this one's) and one
## entrypoint that imports a module living under that dep root via a
## dep-root-relative `--path` flag (mirrors the KDL grammar and RunOptions
## fixture conventions of test_rfc9_a5c_cache_portability.nim).
##
## Windows/macos-safe: pure-Nim fixture (no std/posix, no shell, no /tmp
## literal — `getTempDir()` + a pid suffix), jobs: 1.

import std/[os, sequtils, strutils, unittest]
import crisol/api
import crisol/types

const DepModBody = "proc depVal*(): int = 7\n"

const EntrypointBody = """
import depmod
doAssert depVal() == 7
"""

const KdlBody = """
flags "--path:../dep_real/src"
dep-roots "../dep_real" name="thedep"
group "unit" {
    globs "tests/unit/test_*.nim"
}
"""

suite "RFC-0009 W1 — dep-root closure member survives depgraph persist/load":

  test "cold run passes; warm closureReport carries dep:<name>/ spelling; warm planTests is not edStale":
    let base = getTempDir() / ("crisol_w1_deproot_" & $getCurrentProcessId())
    let depReal = base / "dep_real"
    let proj    = base / "proj"

    removeDir(base)
    createDir(depReal / "src")
    writeFile(depReal / "src" / "depmod.nim", DepModBody)
    createDir(proj / "tests" / "unit")
    writeFile(proj / "crisol.kdl", KdlBody)
    writeFile(proj / "tests" / "unit" / "test_uses_dep.nim", EntrypointBody)
    defer: removeDir(base)

    let opts = RunOptions(configPath: proj / "crisol.kdl", jobs: 1)

    # --- 1. cold run: real compile + run, must be green -------------------
    let rr = runTests(opts)
    check rr.status == rsOk
    check rr.results.len == 1
    check rr.results[0].outcome == oPassed

    # --- 2. warm closureReport: dep-root member must carry the documented
    #        `dep:<name>/rel` wire spelling (crisol/closure/v1 rev 3), never
    #        a bare rel (the phantom-tag-0 symptom of the pre-fix defect).
    let cr = closureReport(opts)
    check cr.entries.len == 1
    let entry = cr.entries[0]
    check entry.path == "tests/unit/test_uses_dep.nim"
    check entry.recorded
    check entry.closure.anyIt(it == "dep:thedep/src/depmod.nim")
    check not entry.closure.anyIt(it.endsWith("depmod.nim") and
                                   not it.startsWith("dep:"))

    # --- 3. warm planTests: the entrypoint's decision must NOT be edStale
    #        — a fresh warm graph, not the phantom-member "closure file
    #        missing" / "closure content changed" false staleness.
    let pr = planTests(opts)
    check pr.entrypoints.len == 1
    let pep = pr.entrypoints[0]
    check pep.ep.tp.display() == "tests/unit/test_uses_dep.nim"
    check pep.edecision != edStale
