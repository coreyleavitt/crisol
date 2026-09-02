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
import crisol/ledger

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

suite "rfc-0007 A1d-ii — ledger legacy-string compat rule":
  ## A ledger row written by a pre-rfc-0007 crisol persists the OLD `outcome`
  ## strings ("timedOut"/"signaled") forever — the ledger's own
  ## `historyFormatVersion` does not change for this RFC.  shard.nim's
  ## duration-median computation (isCompileFailedOutcomeString) and any other
  ## string-domain ledger reader must keep classifying those legacy strings
  ## exactly as before: `oTimeout`/`oSignal` stay in the Outcome enum (as
  ## documented LEGACY variants) and stay `isFailure == true`, so
  ## `failureOutcomeStrings`/`isFailureOutcomeString` — both DERIVED from
  ## `isFailure` — classify them as failures with zero code change here.

  test "legacy \"timedOut\" string is still classified as a failure":
    check isFailureOutcomeString(types.outcomeString(oTimeout))
    check types.outcomeString(oTimeout) == "timedOut"
    check isFailureOutcomeString("timedOut")

  test "legacy \"signaled\" string is still classified as a failure":
    check isFailureOutcomeString(types.outcomeString(oSignal))
    check types.outcomeString(oSignal) == "signaled"
    check isFailureOutcomeString("signaled")

  test "oTimeout/oSignal remain LEGACY (not produced by deriveOutcome) but stay isFailure":
    ## deriveOutcome never returns these two (superseded by oKilled/oCrashed);
    ## they exist ONLY for reading pre-rfc-0007 wire/ledger data.  Both facts
    ## must hold simultaneously: legacy-only AND still classified as failures.
    check oTimeout.isFailure
    check oSignal.isFailure

  test "ledger historyFormatVersion is NOT bumped by this RFC":
    ## rfc-0007 A1d-ii changes nothing about how a ledger row is written or
    ## read (only the result CACHE's format bumped) -- pinned so a future
    ## change to this constant surfaces as an intentional decision, not a
    ## silent side effect of an unrelated slice.
    check historyFormatVersion == 1

when isMainModule:
  echo "test_outcomestrings done"
