## flaky_once.nim — fixture for B1 retry/flaky tests.
##
## Reads CRISOL_ATTEMPT from the environment.
## - On attempt 1 (or if unset): exits with code 1 (failure).
## - On attempt >= 2: exits with code 0 (success).
##
## This models a test that is transiently flaky on the first try but
## reliably passes on retry — exactly the flaky-once scenario B1 tests for.

import std/[os, strutils]

let raw = getEnv("CRISOL_ATTEMPT", "1")
let attempt =
  try: parseInt(raw)
  except ValueError: 1

if attempt >= 2:
  quit(0)   # pass on retry
else:
  quit(1)   # fail on first attempt
