## access_violation.nim — rfc-0007 D1a fixture: a genuine hardware access
## violation on Windows, the `ekNtStatus` producer proof (§2's Windows exit
## partition: "The access-violation fixture lands HERE — it is ekNtStatus's
## producer proof, not serde-only coverage").
##
## A raw load from a NON-nil, unmapped address, with checks off and (via the
## sibling `access_violation.nim.cfg`) Nim's signal handler suppressed, so a
## genuine hardware trap reaches the OS untouched:
##   - A *nil* `ptr` deref does NOT reliably fault here: Nim's `--checks:on`
##     (default) inserts a nil-check that raises a catchable `NilAccessDefect`
##     BEFORE the hardware load, so the process quits with an ordinary exit
##     code (ekExited), not an NTSTATUS. Using a non-nil bad address with
##     `{.checks: off.}` bypasses that and forces a real memory fault.
##   - Nim installs a default SIGSEGV handler and the Windows CRT maps a
##     hardware access violation (0xC0000005) onto SIGSEGV, so the handler
##     would otherwise catch the fault and quit cleanly. `noSignalHandler`
##     (access_violation.nim.cfg) suppresses that, letting the structured
##     exception terminate the process with STATUS_ACCESS_VIOLATION
##     (NTSTATUS 0xC0000005) as the code `GetExitCodeProcess` reports —
##     exactly `decodeExitCode`'s `>= 0xC0000000` → `ekNtStatus` partition
##     (process/windows.nim). The runner never sends this fault, so
##     `classifyCause` records no stop act and falls through to cbProcess,
##     oCrashed (§2).
##
## Windows-only in practice — referenced solely from windows-gated
## (`when defined(windows)`) test files, but ordinary cross-platform Nim so
## `compileFixture` (tests/conformance/helpers.nim) builds it on any host.
{.push checks: off.}
let p = cast[ptr int](0xDEAD0000'u)   # non-nil, unmapped — a genuine fault, not a nil-check
echo p[]                              # `echo` consumes the load so it cannot be elided
{.pop.}
