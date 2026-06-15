## protocol_two_fails.nim — fixture for B4 per-test quarantine integration test.
##
## Emits two named rsFail records via the report API, then exits with code 1.
## Under the OR-rule, both fail records + exit 1 → oFailed.
##
## Named records:
##   "known flaky test A"   — can be individually quarantined
##   "known flaky test B"   — can be individually quarantined
##
## When BOTH names are in config.quarantine: entrypoint is quarantined → exit 0 for crisol.
## When only ONE name is quarantined:         real failure → exit 1 for crisol.

import crisol/report
import crisol/types
import std/options

initReport("tests/fixtures/protocol_two_fails.nim")

emit(TestRecord(
  name:       "known flaky test A",
  status:     rsFail,
  durationUs: 100,
  msg:        some("B4: this failure should be quarantined"),
))

emit(TestRecord(
  name:       "known flaky test B",
  status:     rsFail,
  durationUs: 120,
  msg:        some("B4: this failure should also be quarantined"),
))

# Exit 1 — OR-rule: fail records + nonzero exit → oFailed (as expected).
quit(1)
