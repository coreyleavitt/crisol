## access_violation.nim — rfc-0007 D1a fixture: a genuine hardware access
## violation on Windows, the `ekNtStatus` producer proof (§2's Windows exit
## partition: "The access-violation fixture lands HERE — it is ekNtStatus's
## producer proof, not serde-only coverage").
##
## Same unchecked-`ptr`-deref shape as crash_segv.nim's SIGSEGV producer:
## `ptr T` dereference is never nil-checked by Nim on any platform (that is
## the entire distinction between `ptr`, an unsafe pointer, and `ref`) — a
## raw memory load reaches the kernel/hardware trap directly. On POSIX that
## trap is SIGSEGV; on Windows nothing handles the resulting structured
## exception, so the OS terminates the process with STATUS_ACCESS_VIOLATION
## (NTSTATUS 0xC0000005) as the code `GetExitCodeProcess` reports — exactly
## the value `decodeExitCode`'s `>= 0xC0000000` partition (process/windows.nim)
## classifies as `ekNtStatus`. The runner never sends this fault, so
## `classifyCause` records no stop act and falls through to the
## default-disposition-crash-signal-equivalent branch: cbProcess, oCrashed.
##
## Windows-only in practice — referenced solely from windows-gated
## (`when defined(windows)`) test files, but the source itself is ordinary
## cross-platform Nim so `compileFixture` (tests/conformance/helpers.nim)
## can build it on any host without special-casing.
var p: ptr int = nil
echo p[]
