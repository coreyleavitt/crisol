## outcomestrings.nim — Outcome wire-string helpers for string-domain consumers.
##
## Single source of truth: `types.outcomeString(o: Outcome)` is the canonical
## Outcome→wire-string mapping.  All constants and predicates here are DERIVED
## from that mapping so that adding a new Outcome enum variant requires editing
## exactly ONE place (types.nim Outcome enum + outcomeString case).
##
## Consumers that work in the Outcome domain (jsonout, runner) should call
## types.outcomeString directly.  Consumers that classify RAW wire strings read
## from NDJSON without deserializing to Outcome (ledger, order, shard) use the
## string-domain predicates below.
import std/strutils
import crisol/types

const passedOutcomeString* = outcomeString(oPassed)
  ## Wire string for oPassed.  Derived from types.outcomeString.

const compileFailedOutcomeString* = outcomeString(oCompileFailed)
  ## Wire string for oCompileFailed.  Derived from types.outcomeString.

## Failure outcomes: all Outcome values for which isFailure is true.
## Derived from types.Outcome + types.isFailure + types.outcomeString so that
## adding a new failure variant requires only editing types.nim.
const failureOutcomeStrings* = block:
  var a: seq[string]
  for o in Outcome:
    if o.isFailure:
      a.add outcomeString(o)
  a

proc isFailureOutcomeString*(s: string): bool =
  ## Returns true iff s is a failure outcome wire string.
  s in failureOutcomeStrings

proc isCompileFailedOutcomeString*(s: string): bool =
  ## Returns true iff s represents a compile-failed outcome.
  s.startsWith(compileFailedOutcomeString)
