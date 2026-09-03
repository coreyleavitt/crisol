## process/linux.nim — rfc-0007 §1: the Linux backend.
##
## A shell today (import posix; export posix) — B1 adds pidfd/epoll event-
## driven wait and `PR_SET_CHILD_SUBREAPER`; B2 adds per-slot cgroup v2
## delegation (`clone3(CLONE_INTO_CGROUP)`, `cgroup.kill`, `memory.peak`);
## B3 adds `lkMemory`. Until then Linux runs the shared POSIX poll backend
## unchanged — the "processGroup+subreaper" tier's baseline slice, and the
## home B1-B3 land in (§1 module-layout comment; A2a-i bullet).
import crisol/process/posix
export posix
