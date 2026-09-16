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

proc removeSymlinkSafe*(path: string) =
  ## Unlink a symlink created by a test, correctly on every platform. Nim's
  ## os.removeDir walks a tree and calls removeFile() on any entry — but on
  ## Windows removeFile() is DeleteFileW, which returns ERROR_ACCESS_DENIED for
  ## a DIRECTORY-type reparse point (only RemoveDirectoryW can unlink one). So
  ## a test that createSymlink()'d a directory and then let removeDir() clean up
  ## crashes with "Access is denied" on Windows. Call this on each symlink path
  ## BEFORE removing the enclosing directory. No std/posix (import-purity).
  if not (fileExists(path) or dirExists(path) or symlinkExists(path)):
    return
  when defined(windows):
    # A directory symlink must go via removeDir (RemoveDirectoryW); a file
    # symlink via removeFile. dirExists follows the link, so a dangling one
    # falls through to removeFile.
    if dirExists(path):
      try: removeDir(path) except CatchableError: (try: removeFile(path) except CatchableError: discard)
    else:
      try: removeFile(path) except CatchableError: discard
  else:
    try: removeFile(path) except CatchableError: discard
