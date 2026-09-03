## noisy_output.nim — fixture for the rfc-0007 A2a-ii conformance suite's
## output-cap item (§1 StdioSink: "by PATH, never by fd... the backend opens
## it however it must" — the contract makes no promise about SIZE, only
## about the sink being a real file at a known path). Writes
## CRISOL_NOISY_BYTES bytes (default 200_000) of a deterministic,
## easily-verified a-z repeating pattern to stdout, then exits 0 — the same
## binary drives both the over-cap and under-cap conformance cases via the
## env var, so the pattern is checkable byte-for-byte on either side of the
## cap (never a coincidental-length false pass).
import std/[os, strutils]

let n = block:
  try: parseInt(getEnv("CRISOL_NOISY_BYTES", "200000"))
  except ValueError: 200000

var buf = newString(n)
for i in 0 ..< n:
  buf[i] = char(ord('a') + (i mod 26))
stdout.write(buf)
quit(0)
