## self_sigkill.nim — fixture for rfc-0007 A1f authorship breadth.
##
## Sends itself SIGKILL. The runner never requested this stop, so
## classifyCause records no stop act; SIGKILL is the documented
## "we did not send it" case — cbExternal (OOM killer, operator, unknown —
## indistinguishable from a real self-kill), oCrashed.
import std/posix

discard kill(getpid(), SIGKILL)
# Unreachable if the kill above succeeds (it always does for SIGKILL to
# self). Kept only so the file has a well-defined fallback exit if somehow
# the signal were ever blocked/lost.
quit(1)
