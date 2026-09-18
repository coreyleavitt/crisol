## cwd_marker.nim -- fixture for rfc-0007 code-review r20 (--chdir-into-scratch).
##
## Writes the child's own getCurrentDir() to the file path named by the
## CRISOL_R20_MARKER env var (injected via --env-pin, which reaches the
## child regardless of hermeticity/allowlist -- see sandbox.filterEnv's
## tail contract), then exits 0. When CRISOL_R20_MARKER is unset (e.g.
## called directly), does nothing but exit 0.

import std/os

let markerPath = getEnv("CRISOL_R20_MARKER", "")
if markerPath.len > 0:
  writeFile(markerPath, getCurrentDir())
quit(0)
