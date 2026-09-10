## process/darwin.nim — rfc-0007 §1: the macOS backend, born in C1b.
##
## A shell (import posix; export posix), modeled exactly on
## `process/linux.nim`: every macOS-specific mechanism — kqueue
## `EVFILT_PROC` event-driven `next`, libproc process-table forensics
## (`walkProcTable`/`readVmRssBytes`, macOS has no `/proc`), and the
## `kqueue` capability probe — lives in `process/posixcore.nim`'s
## `when defined(macosx):` branches, not here (Nim has no partial module
## override — a backend cannot "re-export posix plus two procs" — the §1
## module-layout comment's sharing mechanism). `process.nim`'s selection
## ladder gives `macosx` this named arm so it is distinct from the generic
## POSIX `else` arm (poll(2) + a `/proc`-shaped walk that simply finds
## nothing on Darwin), the same reason `linux.nim` exists as its own arm
## rather than reusing `posix.nim` directly.
##
## The RFC's "own Supervisor embedding PosixCore" is satisfied transitively:
## `process/posix.nim` defines `Supervisor* = object` embedding `PosixCore`
## and every §1 proc as a one-line delegation onto it; this module
## re-exports that same `Supervisor` unchanged — darwin.nim needs no
## Supervisor of its own because the mechanism underneath it now differs
## (kqueue/libproc instead of epoll/pidfd//proc), not the wrapper shape.
import crisol/process/posix
export posix
