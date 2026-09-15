## tests/support/symlinkprobe.nim — RFC-0009 Stage B (B3c).
##
## Probes ONCE (memoized) whether this process can actually create a symlink.
## createSymlink succeeds on POSIX but throws on Windows without
## SeCreateSymbolicLinkPrivilege — GitHub-hosted windows runners are not
## reliably Developer-Mode-enabled — so a test that creates a real symlink
## must skip itself when the capability is absent rather than hard-fail.
##
## std/os ONLY: tests/support/*.nim may never import std/posix
## (test_conformance_import_purity.nim enforces this), and this probe needs
## nothing more — createSymlink/getTempDir/removeDir are all portable.
##
## Usage:
##   in a unittest `test:` block —  if not symlinksAvailable(): skip()
##   in a bare `block name:` script — if not symlinksAvailable():
##                                       echo "SKIP: symlinks unavailable"; break

import std/os

var probed = false
var cached = false

proc symlinksAvailable*(): bool =
  ## True iff this environment can create a symlink (memoized after first call).
  if probed: return cached
  probed = true
  let dir = getTempDir() / ("crisol_symlink_probe_" & $getCurrentProcessId())
  try:
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "target", "probe")
    createSymlink(dir / "target", dir / "link")
    cached = true
  except OSError, IOError:
    cached = false
  finally:
    try: removeDir(dir) except CatchableError: discard
  cached
