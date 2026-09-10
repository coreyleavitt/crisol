## rss_hog.nim — fixture that allocates ~8 MiB of heap, holds it for 150ms, then exits 0.
## Used by C5 tests to verify peak RSS telemetry is captured > 0 and > 1 MiB.
## Allocation is explicitly touched (written) so the OS actually maps the pages.
## Sleeps 150ms AFTER allocation so the poll loop (25ms interval) is guaranteed
## to sample at least 2 ticks while the allocation is live.
import std/os
const AllocBytes = 8 * 1024 * 1024  # 8 MiB
var buf = newSeq[byte](AllocBytes)
# Touch every page to force physical mapping (avoid lazy allocation).
var i = 0
while i < AllocBytes:
  buf[i] = byte(i and 0xff)
  i += 4096  # one write per 4 KiB page
# Hold the allocation for 1500ms. The window must be wide enough that a
# consumer's forensics sample lands while the pages are resident AND the
# process is still live even on a noisy CI runner where process startup +
# ORC init + page-fault-in can lag well past a fixed short delay (the
# 2026-09-10 macOS forensics flake: an 8 MiB touch was not yet resident when
# sampled at a fixed 60ms). Consumers poll-until-plausible within this window.
sleep(1500)
# Prevent optimizer from eliminating the allocation.
if buf[0] == 0xff and buf[4096] == 0xff:
  quit(1)  # never taken, but the condition references buf
quit(0)
