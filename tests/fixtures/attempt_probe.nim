## attempt_probe.nim — fixture for B0 CRISOL_ATTEMPT injection tests.
##
## Reads CRISOL_ATTEMPT from the environment and prints it to stdout,
## then exits 0.  The output format is "CRISOL_ATTEMPT=<value>" so the
## test can assert the exact value the child observed.
##
## When CRISOL_ATTEMPT is unset (e.g. called directly), prints "<UNSET>".

import std/os

let val = getEnv("CRISOL_ATTEMPT", "<UNSET>")
echo "CRISOL_ATTEMPT=" & val
quit(0)
