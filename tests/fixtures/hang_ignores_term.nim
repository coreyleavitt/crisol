## hang_ignores_term.nim — fixture that answers, then IGNORES SIGTERM.
##
## Round-3 review (R3-3): `toolexec.terminateAndReap` used to be
## `p.terminate()` followed by an UNBOUNDED `p.waitForExit()`. On POSIX
## `terminate()` is SIGTERM alone, so a tool that traps or ignores TERM turned
## the tool-invocation deadline straight back into the hang it was built to
## prevent — the caller printed its "giving up" warning and then blocked for the
## child's entire remaining lifetime.
##
## This fixture models exactly that tool: it prints a plausible version banner
## (so the drain has something to capture and the probe looks normal), ignores
## SIGTERM, and then stays alive well past any deadline under test. It DOES
## eventually exit, so a regression makes the test SLOW-then-failing rather than
## hung — the assertion is on elapsed wall-clock, which is the property at issue.
##
## POSIX only, and not by omission: on Windows `terminate()` is
## `TerminateProcess`, which cannot be ignored, so there is nothing to model.
import std/os

when defined(posix):
  import std/posix
  # SIG_IGN, not a handler: an ignored signal cannot be delivered at all, which
  # is the strongest form of the case (a trapping handler could still choose to
  # exit and accidentally pass the test).
  discard posix.signal(SIGTERM, SIG_IGN)

echo "hang_ignores_term (fixture) 1.2.3"
flushFile(stdout)

# Long enough that a broken `terminateAndReap` blocks far past the deadline
# under test, short enough that a RED run cannot wedge CI.
os.sleep(45_000)
