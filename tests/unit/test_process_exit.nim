## test_process_exit.nim — rfc-0007 A1a: Exit (lossless observation) + its
## pure helpers (symbol, isSuccess).
import std/unittest
import crisol/process/types as ptypes

suite "process/types — Exit":

  test "ekExited carries the exit code":
    let e = Exit(kind: ekExited, code: 0)
    check e.kind == ekExited
    check e.code == 0

  test "ekSignaled carries the signal number and coreDumped bit":
    let e = Exit(kind: ekSignaled, sig: 11, coreDumped: false)
    check e.kind == ekSignaled
    check e.sig == 11
    check e.coreDumped == false

  test "ekNtStatus carries the raw NTSTATUS":
    let e = Exit(kind: ekNtStatus, status: 0xC0000005'u32)
    check e.kind == ekNtStatus
    check e.status == 0xC0000005'u32

  test "isSuccess is true only for ekExited with code 0":
    check isSuccess(Exit(kind: ekExited, code: 0)) == true
    check isSuccess(Exit(kind: ekExited, code: 1)) == false
    check isSuccess(Exit(kind: ekSignaled, sig: 15, coreDumped: false)) == false
    check isSuccess(Exit(kind: ekNtStatus, status: 0'u32)) == false

  test "symbol names common POSIX crash/kill signals":
    check symbol(Exit(kind: ekSignaled, sig: 11, coreDumped: false)) == "SIGSEGV"
    check symbol(Exit(kind: ekSignaled, sig: 9, coreDumped: false)) == "SIGKILL"
    check symbol(Exit(kind: ekSignaled, sig: 15, coreDumped: false)) == "SIGTERM"
    check symbol(Exit(kind: ekSignaled, sig: 6, coreDumped: false)) == "SIGABRT"

  test "symbol falls back to a numeric label for an unnamed signal":
    check symbol(Exit(kind: ekSignaled, sig: 253, coreDumped: false)) == "SIG253"

  test "symbol on ekExited names the exit code, not a signal":
    check symbol(Exit(kind: ekExited, code: 0)) == "exit 0"
    check symbol(Exit(kind: ekExited, code: 1)) == "exit 1"

  test "symbol names common NTSTATUS crash codes":
    check symbol(Exit(kind: ekNtStatus, status: 0xC0000005'u32)) == "STATUS_ACCESS_VIOLATION"
    check symbol(Exit(kind: ekNtStatus, status: 0xC00000FD'u32)) == "STATUS_STACK_OVERFLOW"

  test "symbol falls back to a hex label for an unnamed NTSTATUS":
    check symbol(Exit(kind: ekNtStatus, status: 0xC0000999'u32)) == "STATUS_0xC0000999"
