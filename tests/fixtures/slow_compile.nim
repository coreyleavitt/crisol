## slow_compile.nim — rfc-0007 code-review r5 fix-loop fixture: holds `nim c`
## open for a short, deterministic, CPU-speed-independent window via a
## compile-time `staticExec` sleep — same rationale as compile_interrupt.nim
## (wall-clock, not NimVM-computation-bound, so the delay doesn't vary with
## host CPU speed and won't flake the suite) but tuned to a shorter, fixed
## floor: this fixture is meant to compile SUCCESSFULLY (never killed mid-
## compile), just slowly enough that a concurrent sibling entrypoint's own
## (hook-driven) delay reliably outlasts it — see
## tests/integration/test_rfc0007_r5_drain_interrupt.nim.
static:
  discard staticExec("sleep 3")

quit(0)
