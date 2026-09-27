## capture_probe_merged.nim — the merged-stream counterpart of
## `capture_probe.nim`.
##
## Runs `toolrun.realRunMerged` (`poStdErrToStdOut`: one pipe) on the program
## named in argv[1] and reports the ending on a single line, then exits, so
## a test can put a DEADLINE around a call whose defect is a hang.
##
## Usage: capture_probe_merged <program>
## Prints: OK ending=<RunEnd> exit=<n> outLen=<n>
##   (`exit` is -1 and `outLen` 0 unless the ending is reExited)

import std/os
import crisol/toolrun

when isMainModule:
  let r = realRunMerged(paramStr(1), [])
  if r.ending == reExited:
    echo "OK ending=", r.ending, " exit=", r.exitCode, " outLen=", r.output.len
  else:
    echo "OK ending=", r.ending, " exit=-1 outLen=0"
