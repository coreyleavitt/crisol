## gitdiff_probe.nim — fixture for issue #22's stderr-drain case.
##
## Calls `gitdiff.changedFiles` once and reports the outcome on a single line,
## then exits. It exists so a test can put a DEADLINE around that call: the
## defect it guards against is a deadlock, and a deadlock cannot be asserted
## from inside the process that is deadlocked.
##
## Usage: gitdiff_probe <projectRoot>
## Prints exactly one of:
##   OK count=<n>
##   RAISED len=<n> tail=<last 32 chars of the message>
##
## `git` is whatever the parent put first on PATH — see `fake_git.nim`.

import std/[os, sets]
import crisol/[gitdiff, types]

when isMainModule:
  let root = paramStr(1)
  let roots = initTrackedRoots(root, @[], "")
  try:
    let changed = changedFiles(root, roots)
    echo "OK count=", changed.len
  except CatchableError as e:
    let m = e.msg
    echo "RAISED len=", m.len, " tail=", m[max(0, m.len - 32) .. ^1]
