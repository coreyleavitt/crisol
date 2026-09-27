## test_artifactid_real.nim — RFC-0006 M-artifact-identity (pass (a)): ONE
## real live `cc -M` integration check.
##
## Everything in tests/unit/test_artifactid.nim and tests/unit/
## test_golden_reuse.nim exercises `artifactid.nim` with injected synthetic
## seams (no real `cc` invocation anywhere). This is the single deliberately-
## budgeted exception (mirrors ccprobe/compiledriver precedent — see
## test_compiledriver_real.nim): drive REAL `cc -M`, via `ccIncludeClosure`'s
## default `toolrun.realRun` seam, against the golden fixture's COMMITTED
## `fixture.c` (which really `#include`s `include/fixture.h` — the one file
## in this fixture that has a companion header at all, per M-golden-fixture's
## design), and prove the include closure genuinely contains it.
##
## The committed manifest's `ccCmd` for `fixture.c` embeds this project's own
## absolute in-container path (`/workspace/...` — the fixture was generated,
## and this suite always runs, inside the `./dev` podman image, which mounts
## the project at exactly `/workspace`; see `dev`'s `--volume ...:/workspace`
## / `--workdir /workspace`), so the manifest's `ccCmd` can be fed to
## `deriveDepInvocation`/`ccIncludeClosure` UNMODIFIED and will resolve for
## real.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_artifactid_real.nim

import std/[json, os, strutils, unittest]
import crisol/artifactid
import crisol/paths   # CR10: ccIncludeClosure's `roots` no longer defaults --
                       # this suite passes a REAL, populated TrackedRoots over
                       # this project's own root. R15-D6: `probeReportedHeaders`
                       # now refuses a reported header against an unpopulated
                       # TrackedRoots (`hpfRootsUnpopulated`) rather than hash
                       # it unresolved, so an empty `TrackedRoots()` here would
                       # refuse the very fixture.h this suite exists to prove
                       # is in the closure. This is still not about CASE
                       # resolution -- fixture.h's reported and on-disk
                       # spellings already agree on every host this runs on --
                       # that residual is tests/unit/test_artifactid.nim's CR3
                       # suite's, with injected roots and a mis-cased fixture.

let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
  # test is at tests/integration/; go up 2 -> project root (mirrors
  # test_compiledriver_real.nim's idiom).
let fixtureDir = projectRoot / "tests" / "fixtures" / "golden_reuse"
let manifestPath = fixtureDir / "generated" / "ep_a" / "ep_a.json"
let realRoots = initTrackedRoots(projectRoot, @[], "")
  # The one production call site (`measureworker.recordArtifactRows`) always
  # passes the run's real roots too -- mirrored here rather than the
  # unpopulated zero value (R15-D6).

proc realDriver(ccCmd: string): DriverResolver =
  ## The fixture's driver as this host's PATH finds it: these tests are
  ## about the real probe's report, not about driver resolution (R10-S6).
  # Not followed: nim runs the link's own name (`/usr/bin/gcc`, not the
  # `gcc-16` it points at).
  discard ccCmd
  result = proc(driver: string): DriverLocation =
    let exe = findExe(driver, followSymlinks = false)
    if exe.len > 0: DriverLocation(found: true, path: exe)
    else: DriverLocation(found: false, why: "not on PATH")

proc fixtureCcCmd(): string =
  ## Pull the COMMITTED, real ccCmd for `fixture.c` straight out of the
  ## committed manifest (not reconstructed) — this proves the real pipeline
  ## end to end, from the actual `nim c` output crisol would read.
  let node = parseJson(readFile(manifestPath))
  for pair in node["compile"]:
    if pair[0].getStr().endsWith("fixture.c"):
      return pair[1].getStr()
  raise newException(ValueError, "fixture.c entry not found in " & manifestPath)

suite "ccIncludeClosure — real cc -M against the golden fixture's committed fixture.c":

  test "the real #include closure of fixture.c contains include/fixture.h":
    let ccCmd = fixtureCcCmd()
    check ccCmd.len > 0

    let res = ccIncludeClosure(ccCmd, roots = realRoots, driver = realDriver(ccCmd))   # default run/readFile seams: real cc -M, real file reads
    check res.ok
    check res.contentHash.len > 0

    var sawFixtureHeader = false
    for h in res.headers:
      if h.endsWith("include" / "fixture.h") or h.endsWith("fixture.h"):
        sawFixtureHeader = true
        break
    check sawFixtureHeader

  test "re-running the same invocation is deterministic (same headers, same content hash)":
    let ccCmd = fixtureCcCmd()
    let res1 = ccIncludeClosure(ccCmd, roots = realRoots, driver = realDriver(ccCmd))
    let res2 = ccIncludeClosure(ccCmd, roots = realRoots, driver = realDriver(ccCmd))
    check res1.ok and res2.ok
    check res1.headers.len == res2.headers.len
    check res1.contentHash == res2.contentHash

when isMainModule:
  echo "All artifactid real cc -M tests passed."
