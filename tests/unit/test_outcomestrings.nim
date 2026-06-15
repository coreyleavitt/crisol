## test_outcomestrings.nim — R2-3: single-source outcome wire strings.
##
## All constants and predicates in outcomestrings.nim are DERIVED from
## types.outcomeString.  These tests assert that derivation is consistent —
## adding a new Outcome variant and updating the single case in types.nim is
## sufficient; no manual sync of failureOutcomeStrings is needed.
import std/unittest
import crisol/types
import crisol/outcomestrings
import crisol/jsonout

suite "outcomestrings — single source of truth (types.outcomeString)":

  test "passedOutcomeString matches types.outcomeString(oPassed)":
    ## Derived constant must equal the canonical mapping.
    check passedOutcomeString == types.outcomeString(oPassed)

  test "compileFailedOutcomeString matches types.outcomeString(oCompileFailed)":
    check compileFailedOutcomeString == types.outcomeString(oCompileFailed)

  test "failureOutcomeStrings is derived: contains exactly types.outcomeString(o) for isFailure outcomes":
    ## If a new failure Outcome is added and types.outcomeString is updated, this
    ## test proves failureOutcomeStrings automatically contains the new string.
    for o in Outcome:
      if o.isFailure:
        check types.outcomeString(o) in failureOutcomeStrings
      else:
        check types.outcomeString(o) notin failureOutcomeStrings

  test "failureOutcomeStrings has NO extra strings beyond what isFailure covers":
    ## No string should be in failureOutcomeStrings unless it maps back to an
    ## isFailure Outcome.  Guards against stale constants staying after a rename.
    for s in failureOutcomeStrings:
      var found = false
      for o in Outcome:
        if types.outcomeString(o) == s:
          check o.isFailure
          found = true
          break
      check found  # every failure string must be reachable from the enum

  test "passedOutcomeString NOT in failureOutcomeStrings":
    check passedOutcomeString notin failureOutcomeStrings

  test "isFailureOutcomeString(types.outcomeString(o)) == o.isFailure for every Outcome":
    ## Core single-source invariant: the predicate and the mapping agree for all variants.
    for o in Outcome:
      check isFailureOutcomeString(types.outcomeString(o)) == o.isFailure

  test "jsonout.outcomeString delegates to types.outcomeString (same result for all)":
    ## jsonout.outcomeString is a thin inline delegate; both must agree.
    for o in Outcome:
      check jsonout.outcomeString(o) == types.outcomeString(o)

  test "isCompileFailedOutcomeString true only for compileFailed":
    check isCompileFailedOutcomeString("compileFailed") == true
    check isCompileFailedOutcomeString("passed") == false
    check isCompileFailedOutcomeString("exitNonZero") == false

  test "FailureOutcomeStrings in jsonout equals failureOutcomeStrings":
    for s in FailureOutcomeStrings:
      check isFailureOutcomeString(s)
    for s in failureOutcomeStrings:
      check s in FailureOutcomeStrings

when isMainModule:
  echo "test_outcomestrings done"
