## rlimit_nofile.nim — fixture for A4b integration tests
##
## Opens file descriptors until RLIMIT_NOFILE is exhausted.
## When the limit is hit, open(2) returns EMFILE; we check for that
## and exit with a non-zero code to signal the limit was hit.
##
## When no limit is in effect this fixture opens many fds and
## exits 0 (success) — proving no false positives.
##
## Design: we open /dev/null repeatedly.  With RLIMIT_NOFILE=10 (for
## example), we'll hit EMFILE well within our loop limit.  We track
## how many fds we opened; if we exhaust the limit we exit 1.
##
## Usage: run under forkExecEnvScratch with a small rlimitNofile.

import std/posix

const MaxAttempts = 2048  # far more than any small test limit

var opened = 0
for _ in 0 ..< MaxAttempts:
  let fd = posix.open("/dev/null".cstring, O_RDONLY)
  if fd < 0:
    # errno == EMFILE or ENFILE — we hit the limit
    quit(1)
  opened += 1

# Opened MaxAttempts fds without hitting a limit — no ceiling active.
quit(0)
