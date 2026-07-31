## shim_multifail.nim — fixture for test_shim.nim (Fix 2 regression coverage)
##
## A minimal test program with ONE test body containing TWO failing `check`s.
## std/unittest's `fail()` template calls `OutputFormatter.failureOccurred`
## once PER failing check (not once per test), resetting its checkpoints
## accumulator after each call. CrisolFormatter.failureOccurred used to
## OVERWRITE `pendingMsg` on each call, so only the LAST failing check's
## message survived into the structured TestRecord — the first failure's
## detail was silently lost. This fixture exercises that path: the emitted
## record's msg must contain evidence of BOTH failing checks.
##
## Distinct literal values (999 / 888) are used as unique markers so the test
## can assert each failure's checkpoint text is present independently.

import crisol/unittest_shim

suite "shim multifail demo":
  test "two failing checks in one test":
    let first  = 1
    let second = 2
    check first == 999    # first failure marker
    check second == 888   # second failure marker
