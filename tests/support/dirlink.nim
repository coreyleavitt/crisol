## tests/support/dirlink.nim — a directory alias a test can create WITHOUT
## privilege on every platform.
##
## A test that needs "the same directory reachable under a second, different
## absolute spelling" (a path ALIAS whose realpath differs from its lexical
## spelling) cannot use `createSymlink` on Windows: a directory symlink needs
## SeCreateSymbolicLinkPrivilege (or Developer Mode), which GitHub-hosted
## windows-latest runners and the MSVC container's ContainerAdministrator both
## lack ("Access is denied"). A directory JUNCTION (`mklink /J`, an
## IO_REPARSE_TAG_MOUNT_POINT reparse point) needs no privilege and is, for
## path identity, the same thing: crisol's Windows realpath primitive
## (`paths.safeExpandFilename` -> `winRealPath` -> GetFinalPathNameByHandleW,
## default flags) resolves every reparse point on the path, junctions
## included, exactly as it resolves a symlink.
##
## POSIX: a plain directory symlink (`createSymlink`) — no privilege needed.
##
## Teardown: never `removeDir` a tree containing a live dir link before
## unlinking it with `removeDirLink`. On Windows `removeDir` hands a
## directory reparse point to `removeFile` (DeleteFileW), which fails with
## ERROR_ACCESS_DENIED; only RemoveDirectoryW unlinks it (and it removes the
## link only, never the target's contents).
##
## std/os + std/osproc + std/winlean only (no std/posix — tests/support
## import purity, test_conformance_import_purity.nim).

import std/os
when defined(windows):
  import std/[osproc, strutils, winlean]

proc createDirLink*(target, link: string) =
  ## Makes `link` an alias of the existing directory `target`: a junction on
  ## Windows, a symlink elsewhere. Raises OSError on failure — a caller that
  ## needs the alias must not silently proceed without one.
  when defined(windows):
    let t = target.absolutePath.normalizedPath.replace('/', '\\')
    let l = link.absolutePath.normalizedPath.replace('/', '\\')
    let (output, code) = execCmdEx("cmd /c mklink /J " & quoteShell(l) &
                                   " " & quoteShell(t))
    if code != 0 or not symlinkExists(link):
      raise newException(OSError, "mklink /J " & l & " -> " & t &
        " failed (exit " & $code & "): " & output.strip)
  else:
    createSymlink(target, link)

proc removeDirLink*(link: string) =
  ## Unlinks a dir link made by `createDirLink`, leaving its target intact.
  ## No-op when `link` is absent. Raises OSError on failure.
  if not symlinkExists(link): return
  when defined(windows):
    if removeDirectoryW(newWideCString(link)) == 0:
      raiseOSError(osLastError(), link)
  else:
    removeFile(link)
