## cpu_spin.nim — rfc-0007 D1b-ii fixture: proves lkCpu
## (PerProcessUserTimeLimit) is a REAL, kernel-enforced Job limit on
## Windows, not just an install-succeeded bookkeeping fiction.
##
## argv: [markerPath]
##
## `when defined(windows)`: a tight, pure user-mode busy loop — no sleeps
## (sleeps do not accrue USER time, so a sleeping fixture would never trip
## PerProcessUserTimeLimit regardless of how much wall-clock elapses) —
## that never terminates on its own and NEVER writes the marker file. The
## marker's ABSENCE at reap is the proof this test drives: with a 1-second
## cpu limit genuinely enforced, the kernel kills this process long before
## it could ever reach a point where it deliberately writes one; if the
## marker existed, the limit did not fire. Same anti-dead-code-elimination
## idiom as `rlimit_cpu.nim` (the POSIX SIGXCPU analog this fixture
## mirrors): the loop increments a `uint64` counter and tests it against 0
## every iteration — a comparison the compiler cannot prove false without
## reasoning about 2^64 well-defined (never triggered in practice) wraps,
## so the loop body survives optimization.
##
## `else`: ordinary cross-platform Nim so `compileFixture`
## (tests/conformance/helpers.nim) and the nimble test task's self-
## discovery build this on any host — writes the marker and exits 0
## immediately; never actually driven on non-Windows (this fixture is
## consumed solely by the `when defined(windows)` arm of
## tests/conformance/test_windows_limits.nim).
import std/os

when defined(windows):
  var counter: uint64 = 0
  while true:
    counter += 1
    if counter == 0:
      break  # never true in practice, but visible to the compiler so the
             # loop is live — the marker below is intentionally unreachable
  let markerPath = paramStr(1)
  writeFile(markerPath, "unreachable\n")  # only reached if the cpu limit never fired
  quit(0)
else:
  let markerPath = paramStr(1)
  writeFile(markerPath, "done\n")
  quit(0)
