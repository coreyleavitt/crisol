## overlap_probe.nim — fixture for S3 max-jobs overlap integration test.
##
## Writes two lines to the file named by CRISOL_TEST_OVERLAP_FILE:
##   1. "{pid}\tstart\t{monotonic_ns}"   — written before the sleep
##   2. "{pid}\tend\t{monotonic_ns}"     — written after the 150ms sleep
##
## Each line is written as a single posix.write() syscall to an O_APPEND-opened
## fd (line < PIPE_BUF = 4096 bytes → atomic across concurrent processes, no
## interleave corruption).
##
## The 150ms sleep ensures concurrently-dispatched processes reliably overlap
## in wall time even on a single-core container.  Without it, instant-exit
## children would never produce overlapping intervals → false green on the
## no-cap test.

import std/[os, monotimes, strutils]
import std/posix

proc writeAtomicLine(fd: cint; line: string) =
  ## Write `line` as a single POSIX write(2) syscall.
  ## Line must include the trailing newline and must be < PIPE_BUF (4096)
  ## to be atomic when fd was opened O_APPEND.
  let buf = line
  discard posix.write(fd, buf.cstring, buf.len)

proc main() =
  let outPath = getEnv("CRISOL_TEST_OVERLAP_FILE")
  if outPath.len == 0:
    quit("overlap_probe: CRISOL_TEST_OVERLAP_FILE not set", 1)

  # Open with O_APPEND | O_WRONLY | O_CREAT so all probes share the file atomically.
  let fd = posix.open(outPath.cstring,
                      O_WRONLY or O_CREAT or O_APPEND,
                      Mode(0o644))
  if fd < 0:
    quit("overlap_probe: cannot open '" & outPath & "'", 1)

  let pid = $int(getpid())

  let startNs = $getMonoTime().ticks
  writeAtomicLine(fd, pid & "\tstart\t" & startNs & "\n")

  # 150ms sleep — ensures concurrent probes overlap in wall-clock time.
  os.sleep(150)

  let endNs = $getMonoTime().ticks
  writeAtomicLine(fd, pid & "\tend\t" & endNs & "\n")

  discard posix.close(fd)

main()
