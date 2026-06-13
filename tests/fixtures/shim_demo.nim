## shim_demo.nim — fixture for test_shim.nim (B3 integration test)
##
## A minimal test program that uses crisol/unittest_shim. It exercises the
## three result paths the shim must handle: pass, fail, and skip.
##
## Compiled by test_shim.nim at test time (not by tests/fixtures/build.nim)
## because it needs --path:src to find crisol/unittest_shim.
##
## Expected behaviour:
##   - Under CRISOL_SINK: emits 3 records (pass, fail, skip) to the sink.
##   - Standalone       : same console output as vanilla unittest; no sink file.
##   - Exit code: non-zero (std/unittest exits 1 when any test fails).

import std/os
import crisol/unittest_shim

suite "shim demo":
  test "always passes":
    # A brief sleep so the pass record has a measurable durationUs.
    sleep(2)
    check 1 + 1 == 2

  test "always fails":
    check 1 + 1 == 3   # deliberate failure

  test "always skips":
    skip()
