## test_fold_probe.nim — RFC-0009 A1 windows-leg runtime probe test (round-3,
## R3-18.1). Asserts `probeFoldPolicy` (crisol/paths) answers `fpAsciiLower`
## on the CI runner's real NTFS volume — the probe's first runtime evidence,
## landed in the SAME slice as the type family it belongs to, four slices
## before anything load-bearing (A3b-ii) stacks on top of it.
##
## Self-skips on a case-sensitive volume (this container's Linux ext4, and
## any other case-sensitive leg) via a RUNTIME case-insensitivity probe —
## the same technique tests/conformance/test_spike_import_case.nim uses —
## rather than a `when defined(windows)` compile-time gate: case-sensitivity
## is a property of the VOLUME (docs/rfc/0009-path-identity.md §3), not of
## the platform, so this is a no-op on Linux/podman and live on
## `windows-latest` NTFS (and, incidentally, on any case-insensitive
## `macos-latest` APFS leg it might run under too).
##
## Self-contained: imports `crisol/paths` only (the module under test) plus
## std/unittest — no other `crisol/*` surface, matching this directory's
## D2a-6 pattern.

import std/[os, unittest]
import crisol/paths

proc isCaseInsensitiveVolume(dir: string): bool =
  ## Creates a lowercase-named temp file directly under `dir` and checks
  ## whether its UPPERCASE spelling also resolves.
  let lowerPath = dir / "foldprobe_casetest.tmp"
  let upperPath = dir / "FOLDPROBE_CASETEST.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)
  removeFile(lowerPath)

suite "RFC-0009 A1 — probeFoldPolicy real-volume runtime evidence":

  test "probeFoldPolicy answers fpAsciiLower on a real case-insensitive volume":
    let root = getTempDir() / ("crisol_fold_probe_" & $getCurrentProcessId())
    createDir(root)
    defer:
      try: removeDir(root)
      except OSError: discard

    if not isCaseInsensitiveVolume(root):
      echo "FOLD-PROBE SKIPPED: case-sensitive volume — probeFoldPolicy's " &
           "fpAsciiLower answer is only meaningful on a case-insensitive one"
      skip()
    else:
      let stateDir = root / ".crisol-state"
      let policy = probeFoldPolicy(root, stateDir)
      echo "FOLD-PROBE OBSERVATION: probeFoldPolicy(", root, ") = ", $policy
      check policy == fpAsciiLower

when isMainModule:
  echo "test_fold_probe done"
