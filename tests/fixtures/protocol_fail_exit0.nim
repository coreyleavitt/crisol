## protocol_fail_exit0.nim — fixture for R1 protocol integration test.
##
## Emits an rsFail record via the report API but calls quit(0).
## Under the OR-rule, a fail record takes precedence over exit 0 → oFailed.
## Also emits one rsPass record so records.len is 2.

import crisol/report
import crisol/types
import std/options

initReport("tests/fixtures/protocol_fail_exit0.nim")

emit(TestRecord(
  name:       "deliberately failing test",
  status:     rsFail,
  durationUs: 100,
  msg:        some("OR-rule: fail record + exit 0 = oFailed"),
  tags:       @["or-rule"],
))

emit(TestRecord(
  name:       "a passing test",
  status:     rsPass,
  durationUs: 50,
))

# Exit 0 — but the OR-rule should classify this as oFailed.
quit(0)
