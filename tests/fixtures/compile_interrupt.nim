## compile_interrupt.nim — fixture for rfc-0007 A1f authorship breadth.
##
## Holds `nim c` open for several real wall-clock seconds via a compile-time
## `staticExec` sleep, giving a SIGINT/SIGTERM sent during the compile phase
## a generous, host-CPU-speed-independent window to land while the compiler
## (and its staticExec child) are still alive. Deliberately wall-clock, not
## NimVM-computation-bound (e.g. a recursive `static:` fibonacci), which
## would vary with host CPU speed and risk flaking the timing leg.
static:
  discard staticExec("sleep 5")

echo "should never run to completion under the compile-interrupt test"
