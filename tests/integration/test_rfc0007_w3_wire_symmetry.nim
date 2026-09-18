## test_rfc0007_w3_wire_symmetry.nim — rfc-0007 wiring-audit item W3: the
## LASTRUN half of the run/v2 wire must carry the SAME substrate/
## trackedRoots evidence as the STDOUT half of the identical run --
## persistLastRun's own doc claim ("the persisted file matches the stdout
## JSON path exactly", the M3 fix) already promised this for warnings/
## memThrottledSlots/policy; before this slice it was never extended to
## substrate/trackedRoots, so persistLastRun rendered toJson's zero-value
## defaults (an all-false Capabilities() node, a project-only trackedRoots)
## regardless of what the SAME run's stdout reported.
##
## This file proves the LASTRUN half agrees with the stdout half; it does
## NOT re-prove the stdout half itself -- that's already pinned by
## test_rfc0007_a7_substrate_cli.nim (substrate) and
## test_rfc9_a2_trackedroots_cli.nim (trackedRoots, non-vacuous via a
## configured dep-root -- the same dep-root technique is reused here for
## the same non-vacuousness reason: the zero-value default(TrackedRoots)
## ALSO renders a project-only entry on any case-sensitive filesystem, so a
## project-root-only fixture would pass whether or not lastrun.json's
## trackedRoots is real).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_w3_wire_symmetry.nim

import std/[json, os, strutils, unittest]
import crisol         # imports runMain
import crisol/process/resultjson  # capabilitiesToJson: the ONE substrate-node owner
import crisol/process/types as ptypes  # Capabilities() zero-value default
import ../support/capture

const PassFixture = "quit(0)\n"

proc freshProjectRoot(name: string): string =
  result = getTempDir() / ("crisol_w3_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")

suite "rfc-0007 W3 — lastrun.json substrate/trackedRoots match the SAME run's stdout":

  let root = freshProjectRoot("live")
  let depParent = getTempDir() / ("crisol_w3_dep_" & $getCurrentProcessId())
  removeDir(depParent)
  let depDir = depParent / "mydep"
  createDir(depDir)

  writeFile(root / "tests" / "unit" / "test_a.nim", PassFixture)
  let cfgPath = root / "crisol.kdl"
  writeFile(cfgPath, """
dep-roots "$1" name="mydep"
group "unit" {
    globs "tests/unit/*.nim"
}
""" % [depDir])

  var code = 0
  let stdoutText = captureStdout(proc() = code = runMain(@["run", "--config", cfgPath,
                                       "--jobs", "1", "--json"]))
  let stdoutDoc = parseJson(stdoutText)

  let lastRunPath = root / ".crisol" / "lastrun.json"
  let lastRunExists = fileExists(lastRunPath)
  let lastRunDoc = if lastRunExists: parseJson(readFile(lastRunPath)) else: newJNull()

  test "exit 0 and lastrun.json was persisted":
    check code == 0
    check lastRunExists

  test "lastrun substrate equals the SAME run's stdout substrate, and both differ from the all-false default":
    require stdoutDoc.hasKey("substrate")
    require lastRunDoc.hasKey("substrate")
    check lastRunDoc["substrate"] == stdoutDoc["substrate"]
    # Non-vacuous regardless of which tier this runs on (dev/ci-linux/
    # ci-cgroup each pin a different, tier-specific true subset -- see
    # test_rfc0007_a7_substrate_cli.nim's checkTierPins): compare against
    # the LITERAL all-false zero-value node instead of a single hardcoded
    # key, so this assertion holds on every tier without guessing which
    # bit that tier happens to probe true.
    let defaultNode = capabilitiesToJson(ptypes.Capabilities())
    check stdoutDoc["substrate"] != defaultNode
    check lastRunDoc["substrate"] != defaultNode

  test "lastrun trackedRoots equals the SAME run's stdout trackedRoots, both carrying the configured dep root":
    require stdoutDoc.hasKey("trackedRoots")
    require lastRunDoc.hasKey("trackedRoots")
    check lastRunDoc["trackedRoots"] == stdoutDoc["trackedRoots"]
    # Non-vacuous: the zero-value default(TrackedRoots) renders a single
    # project-only entry (len == 1, RFC-0009 A2's own default posture); the
    # REAL cfg.trackedRoots (threaded from the "dep-roots" node above)
    # renders both roots.
    check stdoutDoc["trackedRoots"].len == 2
    check stdoutDoc["trackedRoots"][1]["name"].getStr == "mydep"

  removeDir(root)
  removeDir(depParent)

when isMainModule:
  echo "All rfc0007_w3_wire_symmetry tests passed."
