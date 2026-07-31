## test_nimcache_persistence.nim — RFC-0006 nimcache-persistence lever:
## pure invariants for the stable, toolchain-fingerprinted nimcache path and
## duplicate-slug detection (runner.nim's rare same-entrypoint-twice-in-plan
## concurrency guard).
##
## Scope: this file tests the PURE planner-level building blocks only
## (`toolchainFingerprint`, `cachePath`, `duplicateSlugs`). The effectful
## persistence-across-runs + GC behavior is covered by integration tests
## (tests/integration/test_nimcache_persistence_real.nim and
## tests/integration/test_clean.nim's toolchain-fp GC cases).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_nimcache_persistence.nim

import std/[options, sets, unittest]
import crisol/types
import crisol/planner

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkEp(path: string; flags: seq[string] = @[]): Entrypoint =
  Entrypoint(path: path, group: "default", flags: flags)

proc mkCfg(): Config =
  Config(projectRoot: "/proj", stateDir: ".crisol")

proc mkPep(ep: Entrypoint): PlannedEntrypoint =
  PlannedEntrypoint(ep: ep, edecision: edNeverBuilt, reason: "r")

# ---------------------------------------------------------------------------
# toolchainFingerprint — pure derivation
# ---------------------------------------------------------------------------

suite "toolchainFingerprint — pure derivation":

  test "both empty ⇒ empty string (the 'no fingerprint known' sentinel)":
    check toolchainFingerprint("", "") == ""

  test "non-empty inputs ⇒ non-empty, stable fingerprint":
    let fp1 = toolchainFingerprint("2.2.10", "gcc 13.2.0|ldd 2.35")
    check fp1.len > 0
    # Deterministic: same inputs ⇒ same output.
    check fp1 == toolchainFingerprint("2.2.10", "gcc 13.2.0|ldd 2.35")

  test "different nimVersion ⇒ different fingerprint":
    let a = toolchainFingerprint("2.2.10", "gcc 13.2.0")
    let b = toolchainFingerprint("2.3.0",  "gcc 13.2.0")
    check a != b

  test "different ccVersion ⇒ different fingerprint (THE SOUNDNESS RULE)":
    ## A cc/ldd upgrade with source+flags unchanged must land on a different
    ## fingerprint so a persistent nimcache lands on a fresh directory rather
    ## than reusing a .o built by the old compiler.
    let a = toolchainFingerprint("2.2.10", "gcc 13.2.0|ldd 2.35")
    let b = toolchainFingerprint("2.2.10", "gcc 14.0.0|ldd 2.35")
    check a != b

  test "one side empty, other non-empty ⇒ still non-empty (not the sentinel)":
    check toolchainFingerprint("2.2.10", "").len > 0
    check toolchainFingerprint("", "gcc 13.2.0").len > 0

# ---------------------------------------------------------------------------
# cachePath — stable + toolchain-keyed
# ---------------------------------------------------------------------------

suite "cachePath — stable per-entrypoint, toolchain-keyed":

  test "no toolchainFp (default) ⇒ bare slug path, back-compat shape":
    let cfg = mkCfg()
    let ep  = mkEp("tests/unit/test_foo.nim")
    check cachePath(ep, cfg) == cachePath(ep, cfg, "")

  test "with toolchainFp ⇒ path is suffixed, distinct from the bare path":
    let cfg = mkCfg()
    let ep  = mkEp("tests/unit/test_foo.nim")
    let bare   = cachePath(ep, cfg, "")
    let keyed  = cachePath(ep, cfg, "abc123")
    check keyed != bare
    check keyed == bare & "-abc123"

  test "SOUNDNESS: different toolchainFp ⇒ different cache dir (cold, no stale reuse)":
    let cfg = mkCfg()
    let ep  = mkEp("tests/unit/test_foo.nim")
    let fp1 = toolchainFingerprint("2.2.10", "gcc 13.2.0")
    let fp2 = toolchainFingerprint("2.2.10", "gcc 14.0.0")  # simulated cc upgrade
    check cachePath(ep, cfg, fp1) != cachePath(ep, cfg, fp2)

  test "STABLE ACROSS PLAN POSITION: cachePath does not depend on pepIdx/plan shape":
    ## The bug this RFC fixes: the OLD scheme suffixed cacheDir with the
    ## entrypoint's index in the plan, so the same entrypoint got a
    ## DIFFERENT cache dir depending on which plan (full vs `--changed`
    ## subset) it appeared in. cachePath's signature has no plan-position
    ## input at all, so two calls for the same (ep, config, toolchainFp) are
    ## identical by construction — this is the load-bearing invariant.
    let cfg = mkCfg()
    let ep  = mkEp("tests/unit/test_foo.nim")
    let fp  = toolchainFingerprint("2.2.10", "gcc 13.2.0")

    # Simulate "full plan" (ep at index 0 of 3) vs "narrowed --changed plan"
    # (ep at index 0 of 1) — cachePath takes no plan/index argument, so both
    # calls are identical regardless of which plan surrounds the entrypoint.
    let inFullPlanPosition0     = cachePath(ep, cfg, fp)
    let inNarrowedPlanPosition0 = cachePath(ep, cfg, fp)
    check inFullPlanPosition0 == inNarrowedPlanPosition0

  test "ISOLATION: two different entrypoints get different cache dirs":
    let cfg = mkCfg()
    let epA = mkEp("tests/unit/test_a.nim")
    let epB = mkEp("tests/unit/test_b.nim")
    let fp  = toolchainFingerprint("2.2.10", "gcc 13.2.0")
    check cachePath(epA, cfg, fp) != cachePath(epB, cfg, fp)

  test "ISOLATION: same path, different flags ⇒ different cache dirs":
    let cfg = mkCfg()
    let ep1 = mkEp("tests/unit/test_a.nim", @["-d:release"])
    let ep2 = mkEp("tests/unit/test_a.nim", @["-d:debug"])
    let fp  = toolchainFingerprint("2.2.10", "gcc 13.2.0")
    check cachePath(ep1, cfg, fp) != cachePath(ep2, cfg, fp)

# ---------------------------------------------------------------------------
# duplicateSlugs — the rare same-entrypoint-twice-in-plan guard
# ---------------------------------------------------------------------------

suite "duplicateSlugs — rare concurrent-duplicate detection":

  test "empty plan ⇒ empty set":
    let p = RunPlan(jobs: 1, entrypoints: @[])
    check duplicateSlugs(p).len == 0

  test "all-unique plan ⇒ empty set (the common case)":
    let p = RunPlan(jobs: 2, entrypoints: @[
      mkPep(mkEp("tests/unit/test_a.nim")),
      mkPep(mkEp("tests/unit/test_b.nim")),
      mkPep(mkEp("tests/unit/test_c.nim")),
    ])
    check duplicateSlugs(p).len == 0

  test "same (path, flags) appearing twice ⇒ its slug is reported":
    let epA = mkEp("tests/unit/test_a.nim")
    let p = RunPlan(jobs: 2, entrypoints: @[
      mkPep(epA),
      mkPep(mkEp("tests/unit/test_b.nim")),
      mkPep(epA),  # duplicate: same path+flags as the first entry
    ])
    let dups = duplicateSlugs(p)
    check slug(epA.path, epA.flags) in dups
    check dups.len == 1

  test "same path but DIFFERENT flags ⇒ NOT a duplicate (different slug)":
    let p = RunPlan(jobs: 2, entrypoints: @[
      mkPep(mkEp("tests/unit/test_a.nim", @["-d:release"])),
      mkPep(mkEp("tests/unit/test_a.nim", @["-d:debug"])),
    ])
    check duplicateSlugs(p).len == 0

when isMainModule:
  echo "nimcache-persistence pure invariants done."
