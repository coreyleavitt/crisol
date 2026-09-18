## passthrough_marker.nim -- fixture for rfc-0007 code-review r21
## (--env-passthrough / env-passthrough KDL key).
##
## Reads the env var NAMED by CRISOL_R21_PROBE_NAME (injected via
## --env-pin, which reaches the child regardless of hermeticity/allowlist),
## and writes "<value>" (or "<UNSET>" if absent) to the file path named by
## CRISOL_R21_MARKER (also an --env-pin), then exits 0. This lets a test
## assert exactly what the sandboxed child observed for an arbitrary,
## test-chosen env var NAME without needing that NAME on
## sandbox.DefaultEnvAllowlist.

import std/os

let probeName  = getEnv("CRISOL_R21_PROBE_NAME", "")
let markerPath = getEnv("CRISOL_R21_MARKER", "")
if markerPath.len > 0 and probeName.len > 0:
  writeFile(markerPath, getEnv(probeName, "<UNSET>"))
quit(0)
