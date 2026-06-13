## report.nim — crisol in-process result emitter (B2 slice)
##
## Provides the emitter API a test binary calls to report structured results
## to the crisol orchestrator over the sink-file protocol (NDJSON).
##
## Usage (one-time at startup):
##   initReport("tests/unit/test_foo.nim")   # explicit entrypoint label
##   initReport()                            # ep defaults to ""
##   emit(TestRecord(...))
##
## Transport: path is read from CRISOL_SINK env var.  When unset or empty
## the emitter is a complete no-op — every call is a single branch-not-taken
## with no file I/O, no allocation, and no exceptions.
##
## Threading: single-threaded assumption — the emitter uses module-global state
## and performs no locking.  Test binaries are single-threaded; concurrent
## multi-threaded emit is not supported and not needed.
##
## Lifecycle:
##   1. Call initReport once before any emit calls.
##   2. Emit records with emit() as tests complete.
##   3. The file handle is flushed+closed via exitprocs.addExitProc at process exit.
##      Explicit close is not required, but resetReport() (testing only) is safe.

import std/[exitprocs, os]
import crisol/protocol
import crisol/types

# ---------------------------------------------------------------------------
# Module-global state
# ---------------------------------------------------------------------------

var gFile:    File    ## open sink file handle; only valid when gEnabled = true
var gEnabled: bool    ## true iff CRISOL_SINK was set at initReport time

# ---------------------------------------------------------------------------
# Exit hook
# ---------------------------------------------------------------------------

proc closeOnExit() {.noconv.} =
  ## Flush and close the sink file at process exit.
  if gEnabled:
    try:
      flushFile(gFile)
      close(gFile)
    except:
      discard
    gEnabled = false

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc initReport*(ep: string = "") =
  ## Initialise the emitter.  Must be called exactly once before any emit().
  ##
  ## If CRISOL_SINK is set and non-empty:
  ##   • Opens (truncates/creates) that file for writing.
  ##   • Writes the header line (ep, current PID) followed by an immediate flush.
  ##   • Registers closeOnExit via exitprocs.addExitProc.
  ##
  ## If CRISOL_SINK is unset or empty:
  ##   • Sets disabled state; all subsequent emit() calls are no-ops.
  ##   • No file is created or touched.
  let sinkPath = getEnv("CRISOL_SINK")
  if sinkPath.len == 0:
    gEnabled = false
    return

  # Open sink file — truncate if it exists, create if it doesn't.
  if not open(gFile, sinkPath, fmWrite):
    # Cannot open sink — fall back to no-op rather than crashing the test binary.
    gEnabled = false
    return

  gEnabled = true

  # Write header line and flush immediately.
  let headerLine = encodeHeader(ep, getCurrentProcessId()) & "\n"
  write(gFile, headerLine)
  flushFile(gFile)

  exitprocs.addExitProc(closeOnExit)

proc emit*(rec: TestRecord) =
  ## Serialize rec and write it to the sink file, flushing immediately.
  ## No-op when the emitter is disabled (CRISOL_SINK was unset at initReport).
  ##
  ## Flush-per-record durability: a crash loses at most the record currently
  ## being written; all prior records are durable on disk.
  if not gEnabled:
    return
  let line = encodeRecord(rec) & "\n"
  write(gFile, line)
  flushFile(gFile)

proc resetReport*() =
  ## Close any open handle and reset to disabled state.
  ##
  ## FOR TESTING ONLY — allows multiple initReport calls in the same process
  ## without leaking file handles.  Not part of the production API.
  if gEnabled:
    try:
      flushFile(gFile)
      close(gFile)
    except:
      discard
  gEnabled = false
