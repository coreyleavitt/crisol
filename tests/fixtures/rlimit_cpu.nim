## rlimit_cpu.nim — fixture for A4c integration tests
##
## Spins the CPU in an infinite loop until RLIMIT_CPU delivers SIGXCPU.
##
## When RLIMIT_CPU is set the kernel sends SIGXCPU to the process when it
## has consumed that many seconds of CPU time.  The default disposition for
## SIGXCPU is to terminate the process (on Linux, exit with signal 24).
##
## Strategy:
##   Spin in a tight loop that can never exit on its own.  With a small
##   RLIMIT_CPU (e.g. 1 second) the kernel sends SIGXCPU deterministically
##   within that many seconds of CPU time, terminating the process.
##
## Exit via signal SIGXCPU (24 on Linux) = limit enforced — expected.
## If somehow exited normally (loop ended) = unexpected, exits 0.
##
## Usage: run under forkExecEnvScratch with a small limitCpu (e.g. 1 second).
## The supervise() call will observe signal = SIGXCPU (24).

# Tight infinite spin — no I/O, no sleep, no yield.
# The only way out is SIGXCPU from the kernel.
var counter: uint64 = 0
while true:
  counter += 1
  # Prevent the optimizer from eliminating the loop body.
  # A volatile-style access: write to a module-level var that might be
  # observed externally, which prevents dead-code elimination.
  if counter == 0:
    break  # never true, but visible to the compiler so loop is live
