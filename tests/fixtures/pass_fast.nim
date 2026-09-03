## pass_fast.nim — fixture that writes a marker file, then exits 0 immediately.
##
## Used by the rfc-0007 A1e-ii SIGINT/SIGTERM E2E (tests/timing): the marker
## file is the sync point that proves THIS entrypoint has genuinely FINISHED
## before the parent test sends the signal — the non-vacuous half of the
## interrupt partial-results proof (the other half, hang_forever.nim, is
## still in flight when the signal arrives).
import std/os

let markerFile = getEnv("CRISOL_PASS_FAST_MARKER")
if markerFile.len > 0:
  writeFile(markerFile, "done\n")
quit(0)
