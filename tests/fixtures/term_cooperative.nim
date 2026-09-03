## term_cooperative.nim — fixture for rfc-0007 A1f authorship breadth.
##
## THE soundness case (§2 "Authorship has ONE owner"): traps SIGTERM and
## exits 0 promptly, inside the runner's kill grace window
## (spawn.GracePeriodMs, 400 ms) — trying to fake a clean pass in the face
## of a runner-requested stop. `exitnow` (posix `_exit()`) is called
## directly from the handler: async-signal-safe, no Nim runtime/GC/alloc,
## same convention as spawn.nim's post-execvp-failure exit and
## test_signal.nim's child-side exits.
##
## A stop act IS recorded for this child (the runner sent SIGTERM), so
## classifyCause's authorship rule wins regardless of how the child actually
## died: cbRunner/krTimeout/escalated:false, oKilled — never a pass, even
## though the observed Exit is ekExited/code:0.
import std/posix

proc onTerm(sig: cint) {.noconv.} =
  exitnow(0)

var sa: Sigaction
sa.sa_handler = onTerm
discard sigemptyset(sa.sa_mask)
sa.sa_flags = 0
discard sigaction(SIGTERM, sa, nil)

while true:
  discard posix.sleep(cint(1000))
