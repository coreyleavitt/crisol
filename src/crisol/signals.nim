## signals.nim — async-signal-safe flag for SIGINT/SIGTERM (A6).
##
## Design invariants:
##   • The handler ONLY sets a volatile flag — no Nim runtime, no GC, no alloc,
##     no string ops.  All cleanup work runs in the poll loop's normal context.
##   • Installation is opt-in via installSignalHandlers().  Tests that call
##     execute() directly never install the handler and therefore never hit the
##     interrupted path.
##   • gotSignal is a volatile cint (equivalent to sig_atomic_t).  The
##     {.volatile.} pragma prevents the compiler from caching the value.
##
## Public surface:
##   installSignalHandlers*()   — install for SIGINT and SIGTERM
##   pendingSignal*(): cint     — 0 when no signal received; signal number otherwise
##   clearSignal*()             — reset flag to 0 (for testing)

import std/posix

# ---------------------------------------------------------------------------
# Module-level volatile flag
# ---------------------------------------------------------------------------

var gotSignal {.global, volatile.}: cint = 0

# ---------------------------------------------------------------------------
# Handler — only writes to the flag; MUST be async-signal-safe
# ---------------------------------------------------------------------------

proc sigHandler(signum: cint) {.noconv.} =
  ## Only stores the signal number.  No Nim runtime, no alloc, no GC, no IO.
  gotSignal = signum

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc installSignalHandlers*() =
  ## Install sigHandler for SIGINT and SIGTERM using sigaction.
  ## SA_RESTART is set as defense-in-depth: blocked syscalls (e.g. waitpid in
  ## the poll loop) are automatically restarted so EINTR is rare, but the poll
  ## loop still handles EINTR explicitly for defense-in-depth.
  ## Safe to call multiple times; subsequent calls just re-install.
  var sa: Sigaction
  sa.sa_handler = sigHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = SA_RESTART
  discard sigaction(SIGINT,  sa, nil)
  discard sigaction(SIGTERM, sa, nil)

proc pendingSignal*(): cint =
  ## Returns the signal number that was received (SIGINT=2, SIGTERM=15),
  ## or 0 if no signal has been received.
  gotSignal

proc clearSignal*() =
  ## Reset the flag.  Intended for testing only.
  gotSignal = 0
