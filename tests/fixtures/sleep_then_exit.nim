## sleep_then_exit.nim — rfc-0007 B2 fixture: sleeps CRISOL_SLEEP_MS
## milliseconds (default 0) then exits 0. Same env-var-parametrized idiom as
## noisy_output.nim's CRISOL_NOISY_BYTES — one binary, a controllable exit
## time, used by the B2 event-driven-wait latency conformance case to prove
## `next()` observes an exit promptly rather than waiting out the old
## poll(2) tick.
import std/[os, strutils]

let ms = block:
  try: parseInt(getEnv("CRISOL_SLEEP_MS", "0"))
  except ValueError: 0

sleep(ms)
quit(0)
