## test_outcome_window.nim — rfc-0007 A1a: legacy Outcome window rule.
##
## The legacy `Outcome` enum (types.nim) gains the NEW values `oKilled`/
## `oCrashed` alongside the legacy `oTimeout`/`oSignal` pair for the dual-write
## window (A1a–A1e).  `outcomeString`/`isFailure` must stay TOTAL over the
## union — no consumer of this slice yet produces oKilled/oCrashed, but the
## wire mapping and failure classification must already be defined for them.
import std/unittest
import crisol/types

suite "legacy Outcome — window rule (rfc-0007 A1a)":

  test "oKilled and oCrashed exist alongside the legacy oTimeout/oSignal pair":
    ## Compile-time proof: all four values coexist in one enum during the window.
    let values = [oPassed, oFailed, oCompileFailed, oTimeout, oSignal,
                  oSpawnError, oKilled, oCrashed]
    check values.len == 8

  test "outcomeString(oKilled) == \"killed\"":
    check outcomeString(oKilled) == "killed"

  test "outcomeString(oCrashed) == \"crashed\"":
    check outcomeString(oCrashed) == "crashed"

  test "isFailure is true for oKilled and oCrashed":
    check isFailure(oKilled) == true
    check isFailure(oCrashed) == true

  test "outcomeString is total and injective over every Outcome value":
    ## Every value maps to a distinct, non-empty wire string — the case
    ## expression has no `else` escape hatch to hide a missing arm.
    var seen: seq[string]
    for o in Outcome:
      let s = outcomeString(o)
      check s.len > 0
      check s notin seen
      seen.add s
