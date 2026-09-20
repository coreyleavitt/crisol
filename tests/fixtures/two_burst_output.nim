## two_burst_output.nim — fixture for issue #22 (child-output capture
## completeness).
##
## Reproduces, deterministically and on every platform, the flush pattern that
## makes `streams.readAll` truncate a child's output: a SHORT first write
## (fewer bytes than readAll's 1024-byte buffer), a pause long enough that the
## reader is guaranteed to see that short read as a *complete* read, and only
## then the bulk payload. `readAll` treats any read shorter than its buffer as
## EOF, so a truncating capture returns the banner alone AND reports success —
## short-but-valid output plus exit code 0, which is why this class of bug is
## silent. cl.exe hits exactly this pattern in the wild: it flushes its
## source-name banner immediately and its dependency report ~100ms later.
##
## The banner deliberately carries NO newline: `stdout` is a text-mode stream
## on Windows, so an embedded `\n` would become `\r\n` there and make an exact
## byte-length assertion platform-dependent. The payload is the same a-z
## repeating pattern `noisy_output.nim` uses, so a test can check it
## byte-for-byte and never pass on a coincidental length.
##
## Env knobs (all optional):
##   CRISOL_BURST_BYTES         bulk stdout payload size, bytes (default 8192)
##   CRISOL_BURST_STDERR_BYTES  bulk stderr payload size, bytes (default 0)
##   CRISOL_BURST_DELAY_MS      pause between the two bursts, ms (default 150)
##
## NOTE on sizing — this trips people up. A caller that still truncates stops
## reading after the banner, so if the bulk payload exceeds the OS pipe buffer
## this fixture wedges on its own `write` and the caller HANGS instead of
## failing an assertion. The usable budget is much smaller than the usual
## 64 KB folklore: Nim's `osproc.createPipeHandles` calls `CreatePipe` with
## `nSize = 0` (osproc.nim:664), i.e. the Windows system default of ~4 KB.
## A test that must fail rather than hang keeps banner+CRISOL_BURST_BYTES
## under that; a test that deliberately exercises backpressure (and therefore
## requires a caller that drains correctly) goes well above it.

import std/[os, strutils]

const BurstBanner* = "[two-burst-banner]"

proc burstPayload*(n: int): string =
  ## The deterministic a-z repeating payload, shared with the tests so the
  ## expected bytes can never drift from the produced ones.
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(ord('a') + (i mod 26))

proc envInt(name: string; fallback: int): int =
  try: parseInt(getEnv(name, $fallback))
  except ValueError: fallback

when isMainModule:
  let outBytes = envInt("CRISOL_BURST_BYTES", 8192)
  let errBytes = envInt("CRISOL_BURST_STDERR_BYTES", 0)
  let delayMs  = envInt("CRISOL_BURST_DELAY_MS", 150)

  stdout.write(BurstBanner)
  stdout.flushFile()
  if errBytes > 0:
    stderr.write(BurstBanner)
    stderr.flushFile()

  sleep(delayMs)

  stdout.write(burstPayload(outBytes))
  stdout.flushFile()
  if errBytes > 0:
    stderr.write(burstPayload(errBytes))
    stderr.flushFile()
  quit(0)
