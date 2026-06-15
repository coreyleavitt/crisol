## ioutils.nim — low-level POSIX I/O helpers shared by ledger and resultcache.
##
## This module is intentionally minimal: it imports only std/posix so it sits
## at the very bottom of the crisol dependency graph and cannot create cycles.
##
## ## writeAllFd
##
## POSIX write(2) may return fewer bytes than requested on any fd type:
##
##   - Short write: the kernel accepted only part of the buffer (e.g. pipe
##     buffer full, socket send-buffer limit, or some device limits).
##   - EINTR: interrupted by a signal before ANY bytes were transferred.
##     crisol's poll loop does NOT use SA_RESTART for all signals, so EINTR
##     is realistically possible under signal load.
##
## The single-call pattern `write(fd, ptr, n)` used historically in
## resultcache.storeCached (and the old ledger path) silently drops the cache
## entry whenever the kernel returns EINTR or a short count.  `writeAllFd`
## fixes this with a loop that:
##   - Retries immediately on EINTR (no byte progress, no offset advance).
##   - Advances the offset + decrements remaining on a successful partial write.
##   - Returns false on a genuine error (n < 0, errno != EINTR) or a zero-byte
##     return (which should not occur on regular files/pipes but is guarded).
##
## Both ledger.nim and resultcache.nim replace their write calls with this
## helper so that there is exactly ONE correct implementation.

import std/posix as posix_mod

proc writeAllFd*(fd: cint; data: string): bool =
  ## Write all bytes of `data` to `fd` using raw posix.write.
  ##
  ## Handles:
  ##   - Short writes  : advance offset, continue.
  ##   - EINTR (-1)    : retry without advancing.
  ##   - Real errors   : return false immediately.
  ##
  ## Returns true when every byte has been written; false on the first
  ## unrecoverable error.  An empty `data` string is a no-op that returns true.
  var remaining = data.len
  var offset    = 0
  while remaining > 0:
    let n = posix_mod.write(fd,
                             cast[pointer](unsafeAddr data[offset]),
                             remaining)
    if n < 0:
      if posix_mod.errno == EINTR:
        continue        # interrupted before any bytes — retry
      return false      # genuine error (EBADF, ENOSPC, EIO, …)
    elif n == 0:
      return false      # should not happen, but guard anyway
    offset    += n
    remaining -= n
  true
