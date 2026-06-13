## test_soundness_r4.nim — R4: isEntryStale must resolve relative paths against projectRoot.
##
## Bug: isEntryStale called fileExists(f) directly on each closure path, which
## resolves against CWD rather than projectRoot. When CWD != projectRoot:
##   - a same-named file in CWD can FALSELY suppress staleness → under-selection.
##   - files in projectRoot that don't exist in CWD look stale either way (over-select),
##     but a file present in CWD but not projectRoot will FALSELY suppress staleness.
##
## Fix: resolve relative paths against projectRoot before the fileExists check.

import std/[os, sets]
import crisol/types
import crisol/depgraph

block test_r4_relative_missing_under_projectRoot:
  ## A closure containing a relative path that does NOT exist under projectRoot → stale.
  let root = getTempDir() / "crisol_r4_a"
  createDir(root)
  defer: removeDir(root)

  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_ep.nim"
  let fh = flagHash(@[])
  # Store a project-root-relative path that does NOT exist under root.
  let relPath = "src/util_r4_does_not_exist.nim"
  updateEntry(g, path, fh, toHashSet([relPath]))

  let key = (path, fh)
  assert isEntryStale(g, key, root),
    "R4: relative closure path missing under projectRoot must → stale"

block test_r4_relative_exists_under_projectRoot:
  ## A closure containing a relative path that EXISTS under projectRoot → not stale.
  let root = getTempDir() / "crisol_r4_b"
  createDir(root)
  defer: removeDir(root)
  createDir(root / "src")
  writeFile(root / "src" / "util_r4_real.nim", "# real file")

  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_ep.nim"
  let fh = flagHash(@[])
  let relPath = "src/util_r4_real.nim"
  updateEntry(g, path, fh, toHashSet([relPath]))

  let key = (path, fh)
  assert not isEntryStale(g, key, root),
    "R4: relative closure path that exists under projectRoot must → not stale"

block test_r4_cwd_vs_projectRoot_distinction:
  ## CRITICAL: the core R4 scenario.
  ## projectRoot = tmpRoot, CWD = test runner's directory (not tmpRoot).
  ## We store a relative closure path. The file exists in /tmp (accessible by
  ## relative path only if CWD happens to be /tmp), but NOT under tmpRoot.
  ## With the bug (fileExists(f) resolves vs CWD), this might return false (not stale).
  ## With the fix (fileExists(projectRoot/f)), this correctly returns true (stale).
  let root = getTempDir() / "crisol_r4_c"
  createDir(root)
  defer: removeDir(root)

  # The file exists in /tmp as an absolute path, but NOT under root.
  let tmpFile = getTempDir() / "r4_shadow_check.nim"
  writeFile(tmpFile, "# shadow")
  defer: removeFile(tmpFile)

  var g = initDepGraph("2.2.10")
  let path = "tests/unit/test_ep.nim"
  let fh = flagHash(@[])
  # Store just the basename "r4_shadow_check.nim" as a relative path.
  # The file does not exist under root/r4_shadow_check.nim.
  # It only "exists" if CWD = /tmp and we do fileExists("r4_shadow_check.nim").
  let relPath = "r4_shadow_check.nim"
  updateEntry(g, path, fh, toHashSet([relPath]))

  let key = (path, fh)
  # Must be stale because root/"r4_shadow_check.nim" doesn't exist.
  assert isEntryStale(g, key, root),
    "R4: relative path must be resolved against projectRoot, not CWD. " &
    "File exists in tmp dir but not under projectRoot → must be stale"

echo "PASS test_soundness_r4"
