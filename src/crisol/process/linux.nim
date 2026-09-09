## process/linux.nim — rfc-0007 §1: the Linux backend.
##
## A shell (import posix; export posix): every Linux-specific mechanism
## lives in `process/posixcore.nim`'s `when defined(linux):` branches, not
## here — this module exists so `process.nim`'s selection ladder has a
## named Linux arm to import, distinct from the generic POSIX one `macosx`
## and the `else` arm still use. B1 landed `PR_SET_CHILD_SUBREAPER` +
## the `waitid(P_ALL, WNOWAIT)` orphan sweep; B2 landed pidfd+epoll+timerfd
## event-driven `next` (falls back to the original poll(2) tier on
## non-Linux, or under `CRISOL_FORCE_POLL`); B3 adds per-slot cgroup v2
## delegation (`clone3(CLONE_INTO_CGROUP)`, `cgroup.kill`, `memory.peak`)
## and `lkMemory` (§1 module-layout comment; A2a-i bullet).
import crisol/process/posix
export posix
