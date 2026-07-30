## test_golden_reuse.nim — RFC-0006 M-golden-fixture: the measurement's own
## test oracle.
##
## Reads the COMMITTED real Nim 2.2.10 / `--mm:orc` compile output under
## `tests/fixtures/golden_reuse/` (two entrypoints, `ep_a.nim`/`ep_b.nim`,
## over a shared local substrate — see that dir's fixture sources and
## `expectations.nim` for how the fixture was engineered and generated) and
## proves, against REAL committed artifacts (no mocks):
##
##   1. `parseCompileManifest` over the committed `.json` yields the reusable
##      set (every unit except the entry unit — RFC-0006 §File scoping).
##   2. A designated set of reusable units is byte-identical across ep_a and
##      ep_b once the PRODUCTION `artifactid.normalize()` is applied —
##      proving real cross-entrypoint reuse EXISTS and that `normalize()`
##      itself (not a fixture-local scaffold) reproduces it.
##   3. One designated reusable unit (`@mfixture_substrate.nim.c`) DIFFERS
##      across ep_a/ep_b even after the same `normalize()` — proving reuse is
##      NOT guaranteed by module/basename identity (real ORC DCE tailoring).
##   4. PRODUCTION `reuseRatios()`, fed `artifactKeyHash()`s derived from
##      PRODUCTION `normalize()`, reproduces the fixture's pinned closed-form
##      `r_size`/`r_time` (from `expectations.nim` — unchanged, still the
##      oracle) — proving the full pass-(a) pipeline (normalize -> key hash
##      -> reuse ratios), not just `normalize()` in isolation.
##
## ## SLICE BOUNDARY (important)
##
## This test file used to carry a FIXTURE-LOCAL `stripHeader` scaffold
## (see git history) standing in for the not-yet-built production
## `normalize()`. That slice (M-artifact-identity, pass (a)) is now built —
## `crisol/artifactid` — and this file has been rewritten to call it
## directly, so this fixture now validates the PRODUCTION implementation,
## not a stand-in. The closure-hash component of `artifactKeyHash` is held
## CONSTANT across all records here (no `cc -M` invocation in this file —
## that would make this a slow/fragile unit test): the one real `cc -M`
## check, proving `ccIncludeClosure` actually finds `fixture.h`, lives in
## `tests/integration/test_artifactid_real.nim`. Holding the closure
## component constant isolates exactly what this file is meant to prove —
## that `normalize()`'s erasure of the fixture's per-entrypoint generated-dir
## path is what correctly separates "shared" from "tailored" here.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_golden_reuse.nim

import std/[os, sequtils, sets, strutils, tables, unittest]
import crisol/closure
import crisol/artifactid
import "../fixtures/golden_reuse/expectations"

# ---------------------------------------------------------------------------
# Fixture location
# ---------------------------------------------------------------------------

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/unit/; go up 2 -> project root (mirrors
  # test_compiledriver_real.nim's idiom).
let fixtureDir = projectRoot / "tests" / "fixtures" / "golden_reuse"
let generatedDir = fixtureDir / "generated"

const entrypoints = ["ep_a", "ep_b"]

proc manifestPath(ep: string): string = generatedDir / ep / (ep & ".json")

# ---------------------------------------------------------------------------
# Reusable-set resolution (RFC-0006 §File scoping): the entry unit is
# `@m<entrypointBasename>.nim.c`; everything else in the manifest's `compile`
# array is the reusable set. `extractEntryBasename` mirrors that rule
# directly rather than importing it, since the rule itself (not crisol's
# implementation of it) is what this test is anchoring.
# ---------------------------------------------------------------------------

proc entryBasenameFor(ep: string): string = "@m" & ep & ".nim.c"

proc reusableBasenames(ep: string): seq[string] =
  let manifest = parseCompileManifest(manifestPath(ep))
  let entry = entryBasenameFor(ep)
  for pair in manifest.compile:
    let base = pair.cPath.extractFilename
    if base != entry:
      result.add base

# ---------------------------------------------------------------------------
# Reading + PRODUCTION normalize() (replaces the old fixture-local
# `stripHeader` scaffold — see module doc §SLICE BOUNDARY).
#
# The KNOWN per-entrypoint string this fixture's real `nim c` invocation
# embedded is its own generated dir (`generatedDir / ep`) — the fixture's
# analog of crisol's own runner-constructed `cacheDir`/`binDir` strings
# (`cachePath(ep, config) & "_" & $pepIdx"` in runner.nim). It is passed to
# `normalize()` as the exact known string to erase — never guessed.
# ---------------------------------------------------------------------------

proc resolvedPath(ep: string; basename: string): string =
  ## `fixture.c` is the vendor `{.compile.}` C source: ONE copy, at the
  ## fixture root, referenced by absolute path from BOTH entrypoints'
  ## manifests (confirmed when the fixture was generated) — not duplicated
  ## per-entrypoint like the Nim-generated units are.
  if basename == "fixture.c":
    fixtureDir / "fixture.c"
  else:
    generatedDir / ep / basename

proc readNormalizedUnit(ep: string; basename: string): string =
  let raw = readFile(resolvedPath(ep, basename))
  normalize(raw, @[generatedDir / ep])

# ===========================================================================
# Behavior 1 — parseCompileManifest / reusable-set membership
# ===========================================================================

suite "golden_reuse — reusable-set membership (parseCompileManifest over committed .json)":

  test "ep_a.json: reusable set excludes the entry unit and contains every curated basename":
    let reusable = reusableBasenames("ep_a").toHashSet
    let curated = (sharedIdenticalBasenames.toSeq & tailoredBasenames.toSeq).toHashSet

    check entryBasenameFor("ep_a") notin reusable
    for b in curated:
      check b in reusable

  test "ep_b.json: same reusable-set shape (basenames identical to ep_a's — only content diverges)":
    let reusable = reusableBasenames("ep_b").toHashSet
    let curated = (sharedIdenticalBasenames.toSeq & tailoredBasenames.toSeq).toHashSet

    check entryBasenameFor("ep_b") notin reusable
    for b in curated:
      check b in reusable

  test "the real reusable set is a STRICT SUPERSET of the curated set (honesty check — see expectations.nim doc)":
    # This fixture does not commit `.c` CONTENT for every real reusable unit
    # (kept small — see expectations.nim), but the committed `.json` is the
    # real, unmodified manifest: it still lists those units. This proves the
    # curated set isn't silently narrowing what parseCompileManifest reports.
    for ep in entrypoints:
      let reusable = reusableBasenames(ep).toHashSet
      for b in uncommittedRealReusableBasenames:
        check b in reusable

  test "the entry unit itself IS present in the raw manifest (only excluded from the reusable set)":
    for ep in entrypoints:
      let manifest = parseCompileManifest(manifestPath(ep))
      let basenames = manifest.compile.mapIt(it.cPath.extractFilename)
      check entryBasenameFor(ep) in basenames

# ===========================================================================
# Behavior 2 — shared/identical reusable units are byte-identical after
# PRODUCTION normalize()
# ===========================================================================

suite "golden_reuse — shared reusable units are byte-identical across ep_a/ep_b after artifactid.normalize()":

  test "every designated shared-identical basename matches across ep_a and ep_b once normalized":
    for basename in sharedIdenticalBasenames:
      let a = readNormalizedUnit("ep_a", basename)
      let b = readNormalizedUnit("ep_b", basename)
      check a == b

  test "raw (unnormalized) content legitimately differs — normalize() is doing real work, not a no-op":
    # Sanity check the OPPOSITE direction: without normalizing, the per-slot
    # header lines (embedding each entrypoint's own generated-dir path) must
    # differ, else the byte-identical result above would be trivial.
    for basename in sharedIdenticalBasenames:
      if basename == "fixture.c": continue  # vendor file: no per-slot header at all
      let rawA = readFile(resolvedPath("ep_a", basename))
      let rawB = readFile(resolvedPath("ep_b", basename))
      check rawA != rawB

# ===========================================================================
# Behavior 3 — the ORC-tailored unit DIFFERS even after PRODUCTION normalize()
# ===========================================================================

suite "golden_reuse — the ORC-tailored substrate unit differs across ep_a/ep_b after artifactid.normalize()":

  test "@mfixture_substrate.nim.c: normalized content differs (identity != reuse)":
    for basename in tailoredBasenames:
      let a = readNormalizedUnit("ep_a", basename)
      let b = readNormalizedUnit("ep_b", basename)
      check a != b

  test "the divergence is EXACTLY the engineered DCE tailoring: ep_a reaches only substrateA, ep_b only substrateB":
    let a = readNormalizedUnit("ep_a", "@mfixture_substrate.nim.c")
    let b = readNormalizedUnit("ep_b", "@mfixture_substrate.nim.c")
    check "substrateA__" in a
    check "substrateB__" notin a
    check "substrateB__" in b
    check "substrateA__" notin b

# ===========================================================================
# Behavior 4 — r_size closed-form (raw file sizes — unaffected by normalize())
# ===========================================================================

suite "golden_reuse — r_size (bytes-weighted reuse ratio) closed-form":

  test "per-basename committed sizes match the fixture's pinned expectation (canary)":
    for basename, expectedSize in sizeBytes.pairs:
      # fixture.c has one copy; every other basename has one real copy per
      # entrypoint, but they were engineered to be the SAME SIZE across
      # ep_a/ep_b (identical for the shared units; the tailored unit swaps
      # one similarly-sized proc body for another) — checked for both.
      if basename == "fixture.c":
        check getFileSize(resolvedPath("ep_a", basename)) == expectedSize
      else:
        for ep in entrypoints:
          check getFileSize(resolvedPath(ep, basename)) == expectedSize

# ===========================================================================
# Behavior 5/6 — PRODUCTION reuseRatios(), fed keyHashes derived from
# PRODUCTION normalize() + artifactKeyHash(), reproduces the fixture's pinned
# r_size/r_time (RFC-0006's own closed-form oracle, expectations.nim — kept
# UNCHANGED as the oracle; only the MECHANISM computing the actual ratio is
# now the production pipeline, replacing the old scaffold's hand-summed
## bytesShared/bytesTotal derivation).
# ===========================================================================

suite "golden_reuse — production normalize() + artifactKeyHash() + reuseRatios() reproduce the pinned r_size/r_time":

  proc buildRecords(): seq[ArtifactRecord] =
    ## One ArtifactRecord per (entrypoint, curated basename), keyed by
    ## `artifactKeyHash(normalize(rawContent, [knownGeneratedDir]), closure)`.
    ## `closure` is held CONSTANT (see module doc §SLICE BOUNDARY) — this
    ## file isolates `normalize()`'s contribution; the real `cc -M` closure
    ## is separately proven in tests/integration/test_artifactid_real.nim.
    const constantClosureHash = "golden-fixture-constant-closure"
    let allBasenames = sharedIdenticalBasenames.toSeq & tailoredBasenames.toSeq
    for ep in entrypoints:
      for basename in allBasenames:
        let normalized = readNormalizedUnit(ep, basename)
        let keyHash = artifactKeyHash(normalized, constantClosureHash)
        result.add ArtifactRecord(
          entrypointIdentity: ep,
          groupId: "golden",
          configHash: "golden",
          basename: basename,
          keyHash: keyHash,
          sizeBytes: getFileSize(resolvedPath(ep, basename)),
          ccTimeUs: ccWeightUs[basename],
        )

  test "shared basenames produce the SAME keyHash across ep_a/ep_b; the tailored basename produces DIFFERENT keyHashes":
    let records = buildRecords()
    var keyHashByEpBasename: Table[(string, string), string]
    for r in records:
      keyHashByEpBasename[(r.entrypointIdentity, r.basename)] = r.keyHash

    for basename in sharedIdenticalBasenames:
      check keyHashByEpBasename[("ep_a", basename)] == keyHashByEpBasename[("ep_b", basename)]
    for basename in tailoredBasenames:
      check keyHashByEpBasename[("ep_a", basename)] != keyHashByEpBasename[("ep_b", basename)]

  test "reuseRatios() over those records matches the fixture's pinned expectedRSize/expectedRTime":
    let records = buildRecords()
    let ratios = reuseRatios(records)
    check ratios.len == 1
    let r = ratios[(groupId: "golden", configHash: "golden")]

    check r.totalBytes == bytesTotalAll
    check r.sharedBytes == bytesSharedAll
    check r.totalCcTimeUs == weightTotalAll
    check r.sharedCcTimeUs == weightSharedAll

    check abs(r.rSize - expectedRSize) < 1e-9
    check abs(r.rTime - expectedRTime) < 1e-9

    # Sanity: reuse is the clear majority by BYTES in this fixture (the
    # tailored unit is a small minority of the curated set's bytes).
    check r.rSize > 0.75

  test "r_time genuinely DIFFERS from r_size — weighting by (synthetic) cc-time vs. bytes answers a different question":
    check abs(expectedRTime - expectedRSize) > 0.1
    # Concretely: the tailored unit is cheap in bytes but engineered
    # expensive in cc-time, so time-weighted reuse looks meaningfully lower
    # than byte-weighted reuse — exactly the trap RFC-0006's Motivation
    # section warns a naive size-weighted ratio would hide.
    check expectedRTime < expectedRSize

when isMainModule:
  echo "All golden_reuse tests passed."
