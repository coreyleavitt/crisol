## capture_probe_merged.nim — fixture for CR4's merged-stream (`drainToEof`)
## deadline case.
##
## Runs `toolrun.realRunMerged` on the program named in argv[1] and reports
## the outcome on a single line, then exits. `realRunMerged` is the MERGED-
## stream path (`poStdErrToStdOut` -> `toolexec.drainToEofDeadline`), the
## counterpart to `capture_probe.nim`'s separate-stream (`drainBothDeadline`)
## path. Like `capture_probe.nim`/`gitdiff_probe.nim`, it exists so a test can
## put a DEADLINE around a call whose pre-fix defect is an unbounded hang.
##
## Usage: capture_probe_merged <program>
## Prints: OK ok=<true|false> outLen=<n>

import std/os
import crisol/toolrun

when isMainModule:
  let (output, ok) = realRunMerged(paramStr(1), [])
  echo "OK ok=", ok, " outLen=", output.len
