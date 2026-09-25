## capture_probe.nim — fixture for issue #22's stderr-drain case.
##
## Runs `toolrun.realRun` on the program named in argv[1] and reports the
## outcome on a single line, then exits. Like `gitdiff_probe.nim`, it exists so
## a test can put a DEADLINE around a call whose defect is a deadlock.
##
## Usage: capture_probe <program>
## Prints: OK ok=<true|false> outLen=<n>

import std/os
import crisol/toolrun

when isMainModule:
  let (output, ok) = realRun(paramStr(1), [])
  echo "OK ok=", ok, " outLen=", output.len
