## overlap_probe.nim — fixture for S3 max-jobs overlap integration test.
##
## Writes two lines to the file named by CRISOL_TEST_OVERLAP_FILE:
##   1. "{pid}\tstart\t{monotonic_ns}"   — written before the sleep
##   2. "{pid}\tend\t{monotonic_ns}"     — written after the 150ms sleep
##
## Each line is written via a single flushed write to an append-opened File
## (line < PIPE_BUF = 4096 bytes → atomic across concurrent processes, no
## interleave corruption, since the file is opened in append mode and each
## line is flushed immediately rather than left to buffer alongside another).
##
## The 150ms sleep ensures concurrently-dispatched processes reliably overlap
## in wall time even on a single-core container.  Without it, instant-exit
## children would never produce overlapping intervals → false green on the
## no-cap test.

import std/[os, monotimes, strutils, syncio]

proc writeAtomicLine(f: File; line: string) =
  ## Write `line` and flush immediately, so it lands as a single write at the
  ## OS level. Line must include the trailing newline and must be < PIPE_BUF
  ## (4096) to be atomic when the file was opened in append mode.
  f.write(line)
  f.flushFile()

proc main() =
  let outPath = getEnv("CRISOL_TEST_OVERLAP_FILE")
  if outPath.len == 0:
    quit("overlap_probe: CRISOL_TEST_OVERLAP_FILE not set", 1)

  # Open in append mode so all probes share the file atomically.
  var f: File
  try:
    f = open(outPath, fmAppend)
  except IOError:
    quit("overlap_probe: cannot open '" & outPath & "'", 1)

  let pid = $getCurrentProcessId()

  let startNs = $getMonoTime().ticks
  writeAtomicLine(f, pid & "\tstart\t" & startNs & "\n")

  # 150ms sleep — ensures concurrent probes overlap in wall-clock time.
  os.sleep(150)

  let endNs = $getMonoTime().ticks
  writeAtomicLine(f, pid & "\tend\t" & endNs & "\n")

  f.close()

main()
