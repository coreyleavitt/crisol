## slow_compile2.nim — rfc-0007 code-review r58 fixture: a SECOND,
## independently-named `staticExec`-gated slow compile, distinct from
## slow_compile.nim so it can be dispatched as its own entrypoint alongside
## it in the same run without identity collision. Deliberately holds `nim c`
## open LONGER than slow_compile.nim's floor (8s vs 3s) so it is still
## genuinely COMPILING — a live child in the compile phase — at the moment a
## sibling entrypoint's shorter compile finishes and triggers the
## double-interrupt-during-drain scenario in
## tests/integration/test_rfc0007_r5_drain_interrupt.nim (r58's "mid-compile
## skip-grace victim" case). Same wall-clock, CPU-speed-independent
## rationale as slow_compile.nim.
static:
  discard staticExec("sleep 8")

quit(0)
