## signals.nim — rfc-0007 A4: process-global shutdown-signal query.
##
## Before A4 this module owned its OWN sigaction install (`gotSignal`,
## `installSignalHandlers`, `pendingSignal`, `clearSignal`) — a second,
## independent signal-handling mechanism that `runner.execute`'s Supervisor
## (`process/posixcore.nim`) never touched. A2b moved SIGINT/SIGTERM
## installation onto each `execute()` call's own Supervisor
## (`initSupervisor(installSignals)`, §1) and this module's old surface
## went unused in production — its only remaining callers were tests.
##
## A4 unifies the seam "for real" (posixcore.nim's own words): there is now
## exactly ONE sigaction install site (`process/posixcore.shutdownSigHandler`,
## wired through `initSupervisor(installSignals = true)`), and this module
## is a THIN VIEW over the same state that handler stamps — the process-
## global, level-triggered mirror that also feeds the Supervisor's
## `weShutdown` wait event and RFC-0003's `128+n` exit-code derivation.
##
## `shutdownRequested()` exists for library callers whose OWN `execute()`
## call passes `installSignals = false` (opting out — they don't want
## crisol replacing their host application's handlers for that call) but
## who still want to observe, from anywhere in the process, whether SOME
## Supervisor elsewhere (installSignals = true) has seen a shutdown signal
## — without needing a reference to that Supervisor, which `execute()`
## never exposes.
##
## Public surface:
##   shutdownRequested*(): Option[ShutdownSignal]  — `some` iff some
##     installSignals=true Supervisor in this process has observed
##     SIGINT/SIGTERM; carries the real signum (RFC-0003's 128+n needs
##     `n`). Sticky: once set, stays set for the life of the process —
##     there is no `clearSignal()` counterpart (nothing in production
##     reads this to decide whether to run; it is a pure observability
##     query for library callers).

import std/options
import crisol/process

export ShutdownSignal   # so callers can use the return value without a
                         # separate `import crisol/process/types`

proc shutdownRequested*(): Option[ShutdownSignal] =
  ## Process-global, level-triggered: `some(sig)` once any
  ## installSignals=true Supervisor in this process has observed
  ## SIGINT/SIGTERM, `none` otherwise. See module doc for the unification
  ## this delegates onto.
  process.globalShutdownSignal()
