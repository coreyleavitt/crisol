## env_probe.nim — fixture for A5 + A4a integration tests
##
## Prints the values of selected env vars to stdout so the test can assert
## which vars were visible in the child process.  Uses getEnv so the output
## reflects the actual child environment (not the parent's).
##
## Output format (one line per var):
##   NAME=<value>      when set
##   NAME=<UNSET>      when not set
##
## Also prints:
##   CWD=<getCurrentDir()>   — the child's working directory

import std/os

const probeVars = ["PATH", "CRISOL_SECRET_XYZ", "HOME", "LC_ALL", "TMPDIR",
                   "CRISOL_CACHE_TOKEN"]
  ## RFC-0005 C3b: CRISOL_CACHE_TOKEN rides along here so
  ## test_env_scrub_integration.nim can assert the child NEVER sees it,
  ## even under hlNone (where CRISOL_SECRET_XYZ, above, DOES pass through).

for name in probeVars:
  let val = getEnv(name, "<UNSET>")
  echo name & "=" & val

echo "CWD=" & getCurrentDir()
