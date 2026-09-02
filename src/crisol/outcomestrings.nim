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

## rfc-0007 A1e-i: LEDGER COMPAT — persisted-STRING-domain exception.
## The two legacy timeout/signal Outcome values are gone from the `Outcome`
## enum outright (superseded by the runner-authored-kill / crashed values),
## so `failureOutcomeStrings` below can no longer DERIVE these two wire
## strings from the enum. Ledger rows written before this slice still carry
## them on disk, though, and history must stay warm: a row classified as a
## failure yesterday must still classify as a failure today. These two
## constants are the ONE place the legacy strings survive — hardcoded
## literals, not sourced from any Outcome value, because there is no longer
## an Outcome value to source them from. Grep-test allowance: this is the
## sanctioned exception the src/ grep-test for legacy names carves out.
const LegacyTimedOutOutcomeString* = "timedOut"
const LegacySignaledOutcomeString* = "signaled"

## Failure outcomes: all Outcome values for which isFailure is true, PLUS the
## two legacy persisted strings above. Derived from types.Outcome +
## types.isFailure + types.outcomeString so that adding a new failure variant
## requires only editing types.nim.
const failureOutcomeStrings* = block:
  var a: seq[string]
  for o in Outcome:
    if o.isFailure:
      a.add outcomeString(o)
  a.add LegacyTimedOutOutcomeString
  a.add LegacySignaledOutcomeString
  a

proc isFailureOutcomeString*(s: string): bool =
  ## Returns true iff s is a failure outcome wire string.
  s in failureOutcomeStrings

proc isCompileFailedOutcomeString*(s: string): bool =
  ## Returns true iff s represents a compile-failed outcome.
  s.startsWith(compileFailedOutcomeString)
