## crash_segv.nim — fixture for rfc-0007 A1f authorship breadth.
##
## Dereferences a nil pointer, which the kernel turns into a real SIGSEGV.
## Nim's default crash handler prints a traceback and lets the signal reach
## the process (verified: the child dies with WIFSIGNALED/SIGSEGV, not a
## converted clean exit) — the runner never sent this signal, so
## classifyCause has no recorded stop act and falls through to the
## default-disposition-crash-signal branch: cbProcess, oCrashed.
var p: ptr int = nil
echo p[]
