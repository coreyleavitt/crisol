## unittest_shim.nim — crisol B3 slice: std/unittest drop-in with structured emission
##
## One-line integration for test binaries:
##
##   import crisol/unittest_shim
##
## This re-exports all of std/unittest (suite, test, check, expect, skip, etc.)
## and registers a CrisolFormatter that emits structured TestRecords to the
## crisol sink (CRISOL_SINK env var) alongside the normal console formatter.
##
## Standalone behavior (CRISOL_SINK unset):
##   - The CrisolFormatter is registered but its emit() calls are no-ops.
##   - The default console formatter is NOT suppressed; output is unchanged.
##   - Exit code follows std/unittest semantics (1 when any test fails).
##
## Under crisol (CRISOL_SINK set):
##   - The default console formatter still runs → its output is captured by
##     the executor's dup2 to a per-entrypoint output file (human-readable).
##   - The CrisolFormatter emits to the separate sink file (not stdout).
##   - Both destinations coexist; no output is lost.
##
## Note: resetOutputFormatters() is NOT called. The crisol sink fd is a
## separate file — not stdout — so there is no reason to suppress console
## output. The default console formatter auto-registers lazily on the first
## suite/test if no formatter was present; registering CrisolFormatter here
## (before any suite/test executes) prevents that auto-registration, so the
## ordering is: CrisolFormatter first, then the default console formatter
## auto-registers on the first suite/test call (it checks len == 0 only when
## formatters is empty; since we added CrisolFormatter it WON'T auto-register).
##
## IMPORTANT: to keep console output intact under crisol, callers who want
## console output should NOT call resetOutputFormatters() themselves. The
## executor reads the console output from the captured output file, not the
## sink. The sink is for structured records only.
##
## Implementation note on console formatter: because CrisolFormatter is
## registered before any suite/test, std/unittest's ensureInitialized() sees
## formatters.len > 0 and does NOT auto-add the default console formatter.
## To preserve console output, this module explicitly adds the default console
## formatter after the CrisolFormatter. Order: CrisolFormatter emits first
## (structured), then console formatter (human-readable to stdout).

import std/[monotimes, options, strutils, times]
import std/unittest
export unittest

import crisol/report
import crisol/types

# ---------------------------------------------------------------------------
# CrisolFormatter
# ---------------------------------------------------------------------------

type
  CrisolFormatter* = ref object of OutputFormatter
    startTime*:  MonoTime
    pendingMsg*: string   ## failure detail accumulated in failureOccurred

method testStarted*(f: CrisolFormatter; testName: string) =
  f.startTime  = getMonoTime()
  f.pendingMsg = ""

method failureOccurred*(f: CrisolFormatter; checkpoints: seq[string];
                        stackTrace: string) =
  ## Stash failure detail — this is the ONLY hook that carries the failure
  ## message; TestResult in testEnded has no such field.
  ##
  ## std/unittest's `check` template calls `fail()` — and therefore this
  ## method — ONCE PER FAILING CHECK within a single test body, resetting its
  ## `checkpoints` accumulator after each call (see std/unittest's `fail`
  ## template). So a test with two failing `check`s invokes this method
  ## twice, each time with only that check's checkpoints. APPEND each call's
  ## detail to `pendingMsg` (reset once per test in testStarted) rather than
  ## overwriting it, so a multi-failure test surfaces every failed check
  ## instead of only the last one.
  let cpText = checkpoints.join("\n")
  let thisMsg =
    if stackTrace.len > 0: cpText & "\n" & stackTrace
    else: cpText
  if thisMsg.len > 0:
    if f.pendingMsg.len > 0:
      f.pendingMsg = f.pendingMsg & "\n" & thisMsg
    else:
      f.pendingMsg = thisMsg

method testEnded*(f: CrisolFormatter; r: TestResult) =
  let elapsed    = getMonoTime() - f.startTime
  let durationUs = elapsed.inMicroseconds   # int64; non-negative for forward time

  let status =
    case r.status
    of TestStatus.OK:      rsPass
    of TestStatus.FAILED:  rsFail
    of TestStatus.SKIPPED: rsSkip

  let msgOpt =
    if status in {rsFail, rsSkip} and f.pendingMsg.len > 0:
      some(f.pendingMsg)
    else:
      none(string)

  let rec = TestRecord(
    name:       r.testName,
    status:     status,
    durationUs: durationUs,
    msg:        msgOpt,
    tags:       @[],
  )
  emit(rec)
  f.pendingMsg = ""

# ---------------------------------------------------------------------------
# Module-level initialisation (runs before any suite/test template executes)
# ---------------------------------------------------------------------------

block:
  initReport()
  # Register CrisolFormatter first.
  addOutputFormatter(CrisolFormatter())
  # Explicitly add the default console formatter so that std/unittest's
  # ensureInitialized() — which only auto-adds it when formatters.len == 0 —
  # doesn't suppress it now that we've already added one formatter.
  addOutputFormatter(defaultConsoleFormatter())
