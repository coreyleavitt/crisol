## rlimit_fsize.nim — fixture for A4b integration tests
##
## Attempts to write a file larger than a small RLIMIT_FSIZE.
## When the kernel has RLIMIT_FSIZE active, writing past the limit causes
## the process to receive SIGXFSZ (default action: terminate) or for the
## write(2) syscall to return EFBIG.  Either way the process exits non-zero.
##
## We write LARGE_WRITE_BYTES to a file under TMPDIR.  The test sets
## RLIMIT_FSIZE to a small value (e.g. 4096 bytes) before exec, so this
## fixture deterministically hits the limit.
##
## Exit 0 = write succeeded (no limit active); killed by SIGXFSZ / exits
## non-zero = limit was hit.
##
## Usage: run under forkExecEnvScratch with a small rlimitFsize.

import std/os

const LargeWriteBytes = 1024 * 1024  # 1 MiB — well above any small test limit

let tmpDir = getEnv("TMPDIR", getTempDir())
let outPath = tmpDir / "rlimit_fsize_probe.bin"

let f = open(outPath, fmWrite)
var buf = newString(LargeWriteBytes)
for i in 0 ..< LargeWriteBytes:
  buf[i] = char(i mod 256)
f.write(buf)
f.close()
