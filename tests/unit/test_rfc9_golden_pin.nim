## test_rfc9_golden_pin.nim — RFC-0009 A0: golden-pin harness.
##
## Captures Linux golden vectors of crisol's CURRENT (pre-Stage-A) key-
## derivation outputs — `identityKey`, `soundnessKey`, `planner.slug`,
## `cachelocalfs.sidecarPath`, `fnv.chainedContentHash` — over a FIXED
## fixture set, plus one real fixture run's actual on-disk cache slugs.
## This file does not change with each Stage-A slice; each subsequent
## slice RE-RUNS it (via `./dev test`) as the regression net proving it
## kept Linux byte-identical (RFC-0009, "Gates & cadence").
##
## Fixture set (RFC-0009 A0 bullet's two required shapes, both under
## tests/fixtures/rfc9_golden_pin/, committed, fixed — do not edit their
## content without also recomputing every literal pin below):
##
##   simple/    — a trivial single-file project (path-RELATIVE, host-
##                invariant): tests/simple_ep.nim.
##   maxdepth/  — a MAX-DEPTH entrypoint, ten directories deep under
##                tests/ (still path-relative/host-invariant):
##                tests/a/b/c/d/e/f/g/h/i/j/deep_ep.nim.
##   deproot/   — the depRoot vector: deproot/project/ is the projectRoot,
##                deproot/depstore/dep/ is a depRoot OUTSIDE projectRoot.
##                A hand-written nimcache manifest (mirroring
##                tests/unit/test_soundness_r7.nim's convention — no real
##                `nim c` invocation needed) drives PRODUCTION
##                `closure.extractClosure` so the depRoot member's absolute
##                native path is discovered through main's OWN ingestion
##                path, never hand-typed independently (R3-29's "don't let
##                shared plumbing cancel out" rule).
##
## LITERAL byte-pins (RFC-0009 A0 bullet, round-3 R3-29; flipped fully to
## literal pins at A5a):
##
##   - `simple`/`maxdepth` vectors are path-RELATIVE: `identityKey`,
##     `planner.slug`, `cachelocalfs.sidecarPath`, and
##     `fnv.chainedContentHash` are genuinely host-invariant, so they are
##     LITERAL byte-pins below.
##   - the `deproot` vector's `chainedContentHash` USED TO chain the
##     depRoot member's ABSOLUTE native path directly (pre-A5a), which
##     embedded the checkout location — NOT host-invariant, so its golden
##     check was "production's live output equals a FROZEN, vendored
##     reference implementation's output on the SAME raw inputs"
##     (`tests/support/rfc9_vendored_reference.nim`), a preservation oracle
##     rather than a literal pin. RFC-0009 A5a reworked the hash to chain
##     the PORTABLE `keyBytes` spelling instead (a dep-root member's key is
##     now `"dep:name/rel"`, never the absolute path) while still reading
##     file content from the absolute native path — so the resulting hash
##     is host-invariant too. The `deproot` vector (and its
##     `identityKey`/`planner.slug`/`flagHash` siblings, which never
##     touched the depRoot member's absolute path even pre-A5a) are now
##     LITERAL byte-pins like every other vector here, and
##     `rfc9_vendored_reference.nim` — whose own doc comment scoped it to
##     "A1 through A4b ONLY" — has been deleted.
##
## `soundnessKey` (RFC-0009 A0 bullet): embeds `nimVersion`/`ccVersion`,
## so a REAL run's key is valid only inside the pinned container leg
## that produced it — never portable across toolchains. This harness
## sidesteps that entirely by feeding `soundnessKey` SYNTHETIC, fixed
## `nimVersion`/`ccVersion` strings (never probed from the real
## toolchain) — exactly `test_nimcache_persistence.nim`'s existing
## `toolchainFingerprint("2.2.10", "gcc 13.2.0")`-style convention — so
## the resulting literal pin is a real regression net over the 9-
## component fold ORDER/SHAPE, host- and toolchain-independent by
## construction. It does NOT (and cannot) prove any real run's actual
## end-to-end `soundnessKey` is stable across containers — that was never
## a true property to begin with (a toolchain upgrade is SUPPOSED to
## change it, RFC-0006's nimcache-persistence soundness rule) — so a real
## run's `soundnessKey` must never be compared against this pin.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc9_golden_pin.nim

import std/[json, options, os, sets, unittest]
import crisol/types
import crisol/keys
import crisol/planner
import crisol/cachelocalfs
import crisol/fnv
import crisol/paths
import crisol/closure
import crisol/depgraph
import crisol/config
import crisol/runner
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Fixture locations
# ---------------------------------------------------------------------------

let projectRootOfThisRepo = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/unit/; up 2 -> repo root (mirrors test_golden_reuse.nim).
let fixtureBase = projectRootOfThisRepo / "tests" / "fixtures" / "rfc9_golden_pin"
let simpleFixtureRoot   = fixtureBase / "simple"
let maxdepthFixtureRoot = fixtureBase / "maxdepth"
let deprootProjectRoot  = fixtureBase / "deproot" / "project"
let deprootDepDir       = fixtureBase / "deproot" / "depstore" / "dep"

const simplePath = "tests/simple_ep.nim"
const deepPath   = "tests/a/b/c/d/e/f/g/h/i/j/deep_ep.nim"
let deepFlags = @["--define:rfc9golden", "--threads:on"]

# ===========================================================================
# 1. identityKey — literal byte-pins (path-relative, host-invariant)
# ===========================================================================

suite "rfc9_golden_pin — identityKey literal byte-pins":

  test "simple (trivial single-file project, no flags)":
    let fh = depgraph.flagHash(@[])
    check fh == "cbf29ce484222325"
    check $keys.identityKey(simplePath, fh) == "26750bd0d11426e3"

  test "maxdepth (ten dirs deep, non-trivial flags)":
    let fh = depgraph.flagHash(deepFlags)
    check fh == "8bbbbdc2240c935b"
    check $keys.identityKey(deepPath, fh) == "afb4ab06919d3527"

# ===========================================================================
# 2. planner.slug — literal byte-pins (path-relative, host-invariant)
# ===========================================================================

suite "rfc9_golden_pin — planner.slug literal byte-pins":

  test "simple":
    check planner.slug(simplePath, @[]) == "tests__simple_ep__nim-3c8259c27679bbbb"

  test "maxdepth":
    check planner.slug(deepPath, deepFlags) ==
      "tests__a__b__c__d__e__f__g__h__i__j__deep_ep__nim-745b86e3ced9efb7"

# ===========================================================================
# 3. cachelocalfs.sidecarPath — literal byte-pins (pure string function;
#    the `root` param is caller-supplied and never touches disk here, so a
#    fixed placeholder string is legitimate — sidecarPath does no I/O).
# ===========================================================================

suite "rfc9_golden_pin — cachelocalfs.sidecarPath literal byte-pins":

  test "simple":
    check sidecarPath("state-root", simplePath) ==
      "state-root/v3/inputs/e8559c40017309d9.json"

  test "maxdepth":
    check sidecarPath("state-root", deepPath) ==
      "state-root/v3/inputs/56b57a6a7f7a269c.json"

# ===========================================================================
# 4. fnv.chainedContentHash — literal byte-pins over REAL committed
#    fixture file content (path-relative, host-invariant).
# ===========================================================================

suite "rfc9_golden_pin — fnv.chainedContentHash literal byte-pins":

  test "simple: single relative file, real committed content":
    check fnv.chainedContentHash(@[(key: simplePath, nativePath: simpleFixtureRoot / simplePath)]) ==
      "e8db44ccb4e1f06f"

  test "maxdepth: single relative file ten dirs deep, real committed content":
    check fnv.chainedContentHash(@[(key: deepPath, nativePath: maxdepthFixtureRoot / deepPath)]) ==
      "406ac69776627725"

# ===========================================================================
# 5. soundnessKey — literal byte-pin over SYNTHETIC, fixed component
#    values (nimVersion/ccVersion are made-up strings, never probed —
#    see module doc comment). Proves the 9-component fold order/shape is
#    unchanged; says nothing about any real run's actual key.
# ===========================================================================

suite "rfc9_golden_pin — soundnessKey literal byte-pin (synthetic inputs)":

  test "fixed synthetic KeyInputs":
    let inp = KeyInputs(
      closureContentHash: "rfc9-golden-closure-hash",
      flagHash:            "rfc9-golden-flag-hash",
      nimVersion:          "2.2.10-golden-fixture",
      ccVersion:           "gcc-golden-fixture-13.2.0",
      fixtureHash:         "",
      argv:                @["--rfc9", "golden"],
      limits:              ptypes.Limits(),
      hermeticEnvHash:     "rfc9-golden-hermetic-env",
      protocolMajor:       1,
    )
    check $soundnessKey(inp) == "1d5ba6892b56015d"

# ===========================================================================
# 6. depRoot vector — literal byte-pins (RFC-0009 A5a flipped this from the
#    pre-A5a vendored-reference compute-at-runtime oracle; see module doc
#    comment).
#
# Drives PRODUCTION `closure.extractClosure` over a hand-written nimcache
# manifest (test_soundness_r7.nim's convention) whose `depfiles` array
# names the depRoot member by its REAL absolute path — main's OWN
# ingestion path discovers and carries that absolute path into the
# returned closure set; this test never constructs it independently.
# ===========================================================================

proc writeDeprootManifest(nimcacheDir, bname, epAbs, depMemberAbs: string) =
  ## One `link` entry: the entrypoint's own `@m`-mangled module object
  ## (resolves trivially to `epAbs` itself — same shape
  ## tests/unit/test_soundness_r7.nim/tests/unit/test_golden_reuse.nim's
  ## fixtures use for an entrypoint's own compile unit).
  ## One `depfiles` entry: the depRoot member's real absolute path —
  ## `depfiles` entries are recorded as absolute paths verbatim by Nim, no
  ## @m/@p/@n decoding involved, so this is the simplest real vehicle for
  ## the fnv.nim:68 fall-through case (a depRoot member OUTSIDE
  ## projectRoot, carried through unchanged since `toProjectRelative`
  ## cannot strip a projectRoot prefix that isn't there).
  let epBase = epAbs.extractFilename  # "ep_with_dep.nim"
  let mangledObj = nimcacheDir / ("@m" & epBase & ".c.o")

  let node = newJObject()
  node["compile"] = newJArray()
  let linkArr = newJArray()
  linkArr.add newJString(mangledObj)
  node["link"] = linkArr
  let depfilesArr = newJArray()
  let pair = newJArray()
  pair.add newJString(depMemberAbs)
  pair.add newJString("")
  depfilesArr.add pair
  node["depfiles"] = depfilesArr

  createDir(nimcacheDir)
  writeFile(nimcacheDir / bname & ".json", $node)

suite "rfc9_golden_pin — depRoot vector (literal byte-pins, RFC-0009 A5a)":

  test "closure member outside projectRoot is carried as an absolute native path (fnv.nim:68 fall-through)":
    let epAbs = deprootProjectRoot / "tests" / "ep_with_dep.nim"
    let depMemberAbs = (deprootDepDir / "member.nim").absolutePath.normalizedPath
    let nimcacheDir = getTempDir() / "crisol_rfc9_deproot_nimcache"
    removeDir(nimcacheDir)
    defer: removeDir(nimcacheDir)
    let bname = "ep_with_dep"
    writeDeprootManifest(nimcacheDir, bname, epAbs, depMemberAbs)

    var cfg = Config(
      projectRoot: deprootProjectRoot,
      stateDir:    ".crisol",
      depRoots:    @[deprootDepDir],
    )
    cfg.trackedRoots = initTrackedRoots(deprootProjectRoot,
      @[(name: "dep", native: deprootDepDir)], ".crisol")

    let closureSet = extractClosure(nimcacheDir, bname, epAbs, cfg)

    # RFC-0009 A4b: closureSet is now HashSet[TrackedPath]. Build the
    # expected members the same way production spells them — never a
    # hand-computed absolute string.
    # Sanity: the entrypoint's own (relative) member is present.
    let expectedEp = fromCanonical("tests/ep_with_dep.nim", cfg.trackedRoots).get
    check expectedEp in closureSet
    # The depRoot member is present, classified via the SAME `classify` gate
    # production uses — main's own ingestion path (extractClosure), never
    # hand-typed by this test.
    let depMemberClass = classify(depMemberAbs, cfg.trackedRoots)
    check depMemberClass.kind == pcTracked
    check depMemberClass.tp in closureSet
    check depMemberAbs.isAbsolute

    # RFC-0009 A5a: chainedContentHash's inputs are `closureHashInputs`'
    # (key, nativePath) pairs — `key` is `keyBytes(tp, roots)` (project
    # member: byte-identical to the pre-A5a `display`; dep-root member: the
    # portable "dep:name/rel" spelling, chained into the hash instead of
    # `toNative`'s absolute path), `nativePath` is always `toNative(tp,
    # roots)` (content is still read from the absolute path).
    let filesSeq = closureHashInputs(closureSet, cfg.trackedRoots)

    # chainedContentHash: NOW a literal pin. Pre-A5a this could only be
    # checked against a frozen vendored reference (the chained key was
    # `depMemberAbs`, which embeds the checkout location). Post-A5a the
    # chained key is the portable "dep:dep/member.nim" spelling — the hash
    # no longer depends on where this checkout lives, so it is
    # host-invariant and can be pinned like the simple/maxdepth vectors.
    let prodHash = fnv.chainedContentHash(filesSeq)
    check prodHash == "b1d7296eb81f3100"
    check prodHash.len == 16  # sanity: a real 16-hex-char digest, not "" / a crash value

    # identityKey/slug/flagHash for this SAME entrypoint. These never
    # touched the depRoot member's absolute path even pre-A5a (see module
    # doc comment) — now that the vendored reference is retired (A5a),
    # they are literal-pinned directly like every other vector here.
    let flags = @["--define:rfc9dep"]
    let prodFH = depgraph.flagHash(flags)
    check prodFH == "1a176d1243dc2823"

    let prodIK = keys.identityKey("tests/ep_with_dep.nim", prodFH)
    check $prodIK == "20b5e9ee2fd4be01"

    let prodSlug = planner.slug("tests/ep_with_dep.nim", flags)
    check prodSlug == "tests__ep_with_dep__nim-3ec54c3652c17ed3"

# ===========================================================================
# 7. One fixture run's actual on-disk cache slugs — a REAL `execute()` over
#    a scratch copy of the committed `simple` fixture (never run directly
#    against the committed fixture dir, so no build artifact ever lands
#    under version control).
# ===========================================================================

suite "rfc9_golden_pin — one fixture run's actual on-disk cache slugs":

  test "real compile+run: cache/bin dirs land at planner.slug's pinned name":
    let scratchRoot = getTempDir() / "crisol_rfc9_golden_pin_run"
    removeDir(scratchRoot)
    copyDir(simpleFixtureRoot, scratchRoot)
    defer: removeDir(scratchRoot)

    var cfg = Config(projectRoot: scratchRoot, stateDir: ".crisol", jobs: 1,
                      timeoutSecs: 60, compileTimeoutSecs: 120,
                      maxOutputBytes: 65_536)
    cfg.trackedRoots = initTrackedRoots(scratchRoot, newSeq[tuple[name, native: string]](), ".crisol")
    let ep = Entrypoint(path: simplePath, group: "default", flags: @[])

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph, nimVersion = "",
                          showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "rfc9 golden-pin fixture run output:\n", results[0].output
    check results[0].outcome == oPassed

    let expectedSlug = planner.slug(ep.path, ep.flags)
    check expectedSlug == "tests__simple_ep__nim-3c8259c27679bbbb"

    check dirExists(stateDirOf(cfg) / "cache" / expectedSlug)
    check dirExists(stateDirOf(cfg) / "bin" / expectedSlug)

when isMainModule:
  echo "All rfc9_golden_pin tests passed."
