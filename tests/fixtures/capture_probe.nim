## capture_probe.nim — fixture for issue #22's stderr-drain case.
##
## Runs `toolrun.realRun` (separate stdout/stderr pipes) on the program named
## in argv[1] and reports the ending on a single line, then exits. Like
## `gitdiff_probe.nim`, it exists so a test can put a DEADLINE around a call
## whose defect is a deadlock or a hang.
##
## Usage: capture_probe <program>
## Prints: OK ending=<RunEnd> exit=<n> outLen=<n>
##   (`exit` is -1 and `outLen` 0 unless the ending is reExited)

import std/os
import crisol/toolrun

when isMainModule:
  let r = realRun(paramStr(1), [])
  if r.ending == reExited:
    echo "OK ending=", r.ending, " exit=", r.exitCode, " outLen=", r.output.len
  else:
    echo "OK ending=", r.ending, " exit=-1 outLen=0"
