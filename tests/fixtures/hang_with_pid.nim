## hang_with_pid.nim — test fixture for A6 signal handling.
##
## Writes the running binary's PID to the file named in HANG_PID_FILE
## (if set), then hangs forever.  Used by test_signal.nim to detect when the
## child process has started before sending a signal.

import std/[os, posix]

let pidFile = getEnv("HANG_PID_FILE")
if pidFile.len > 0:
  writeFile(pidFile, $int(getpid()) & "\n")

while true:
  discard posix.sleep(cint(1000))
