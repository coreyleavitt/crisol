## signals.nim — rfc-0007 A4: the shutdown-signal query.
##
## crisol has ONE SIGINT/SIGTERM handler (a console Ctrl-C/Ctrl-Break handler
## on Windows): `crisol/process/tooltrees`'. It is installed for as long as
## an interrupt scope is open (`tooltrees.enterInterruptScope`, R12-D3). Three
## owners open one: `runcore.runTestsWith` with `RunOptions.installSignals`
## (for its whole call, planning included), the CLI (around its whole
## `runMain`), and every `initSupervisor(installSignals = true)` (for the
## Supervisor's life; inside a run's scope it nests). The handler records the
## signal for the scope, kills every live bounded tool and wakes the attached
## Supervisor, whose `next()` reports `weShutdown`.
##
## This module is the query-only VIEW over that record, for code with no
## Supervisor handle in reach: the cache layer asks it whether to abandon
## more cache I/O on the way out of an interrupted run
## (`cachetier.resolveProbes`'s plan-time prefetch, `runner.execute`'s
## plan-time consult loop, and `runcore.runTestsWith`'s end-of-run deferred-
## put drain), and a main path asks it whether to stop early. It never
## decides a run's verdict: the scope's owner takes that from
## `tooltrees.leaveInterruptScope` (R14-S1).
##
## Public surface:
##   shutdownRequested*(): Option[ShutdownSignal]  — `some` iff crisol's
##     handler has observed SIGINT/SIGTERM in the open interrupt scope;
##     carries the real signum (RFC-0003's 128+n needs `n`). Level-triggered
##     within the scope, and `none` outside every scope: the outermost scope
##     clears the record when it opens and takes it out when it closes. An
##     interrupt is a fact about the run it landed in, delivered to the host
##     as that run's `rsInterrupted` report; it is never carried into the
##     host's next run (R13-D2: a process-lifetime latch made every later run
##     in a library host skip its cache lookups and drop its remote puts). A
##     caller that passes `installSignals = false` and opens no scope of its
##     own therefore always reads `none`: crisol owns no signal for it.
##
## It is `tooltrees.shutdownRequested` itself, re-exported: the one reader of
## the record, with no layer between it and the atomic load (R14-D5).

import crisol/process/tooltrees
import crisol/process/types

export shutdownRequested
export ShutdownSignal   # so callers can use the return value without a
                         # separate `import crisol/process/types`
