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

  test "failureOutcomeStrings has NO extra strings beyond isFailure + the two sanctioned legacy strings":
    ## No string should be in failureOutcomeStrings unless it maps back to an
    ## isFailure Outcome — OR is one of the two rfc-0007 A1e-i legacy-string
    ## exceptions (see the dedicated suite below), which by construction have
    ## no Outcome value to map back to any more (the enum values are gone).
    ## Guards against stale constants staying after a rename.
    for s in failureOutcomeStrings:
      if s in [LegacyTimedOutOutcomeString, LegacySignaledOutcomeString]:
        continue
      var found = false
      for o in Outcome:
        if types.outcomeString(o) == s:
          check o.isFailure
          found = true
          break
      check found  # every non-legacy failure string must be reachable from the enum

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

suite "rfc-0007 A1e-i — ledger legacy-string compat rule":
  ## A ledger row written by a pre-rfc-0007 crisol persists the OLD `outcome`
  ## strings ("timedOut"/"signaled") forever — the ledger's own
  ## `historyFormatVersion` does not change for this RFC.  A1e-i deleted the
  ## legacy `oTimeout`/`oSignal` Outcome VALUES outright (superseded by
  ## `oKilled`/`oCrashed`), so `failureOutcomeStrings` can no longer derive
  ## these two wire strings from the enum — they are the ONE sanctioned
  ## exception, hardcoded in outcomestrings.nim as
  ## `LegacyTimedOutOutcomeString`/`LegacySignaledOutcomeString`. shard.nim's
  ## duration-median computation (isCompileFailedOutcomeString) and any other
  ## string-domain ledger reader must keep classifying them exactly as before.

  test "legacy \"timedOut\" string is still classified as a failure":
    check LegacyTimedOutOutcomeString == "timedOut"
    check isFailureOutcomeString(LegacyTimedOutOutcomeString)
    check isFailureOutcomeString("timedOut")

  test "legacy \"signaled\" string is still classified as a failure":
    check LegacySignaledOutcomeString == "signaled"
    check isFailureOutcomeString(LegacySignaledOutcomeString)
    check isFailureOutcomeString("signaled")

  test "the two legacy strings are the ONLY failureOutcomeStrings entries not reachable from Outcome":
    ## Every OTHER entry in failureOutcomeStrings must still be reachable
    ## from a real Outcome value (guards against unrelated stale constants);
    ## the two legacy strings are the one documented, named exception.
    var unreachable: seq[string]
    for s in failureOutcomeStrings:
      var found = false
      for o in Outcome:
        if types.outcomeString(o) == s:
          found = true
          break
      if not found:
        unreachable.add s
    check unreachable.len == 2
    check LegacyTimedOutOutcomeString in unreachable
    check LegacySignaledOutcomeString in unreachable

  test "ledger historyFormatVersion is NOT bumped by this RFC":
    ## rfc-0007 A1d-ii changes nothing about how a ledger row is written or
    ## read (only the result CACHE's format bumped) -- pinned so a future
    ## change to this constant surfaces as an intentional decision, not a
    ## silent side effect of an unrelated slice.
    check historyFormatVersion == 1

when isMainModule:
  echo "test_outcomestrings done"
