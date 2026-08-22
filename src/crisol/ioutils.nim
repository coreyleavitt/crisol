## ioutils.nim — low-level POSIX I/O helpers shared by ledger and resultcache,
## plus the one text sanitizer every user-facing stdout/stderr write uses.
##
## This module is intentionally minimal: it imports only std/posix (and
## std/os) so it sits at the very bottom of the crisol dependency graph and
## cannot create cycles — which is also why `sanitizeControlBytes` lives
## here rather than in render: crisol.nim, render.nim and depgraph.nim all
## need it and depgraph must not depend on render.
##
## ## sanitizeControlBytes
##
## Per-line control-byte neutralizer for untrusted-origin diagnostic text
## (config files, on-disk state, manifests) before it reaches a terminal or
## CI log; see its doc comment for the exact byte policy.
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
##
## ## atomicPutFile
##
## The atomic "write a whole file into place" mechanic that resultcache.nim
## implemented inline for its per-key JSON entries: write `data` to a
## PID-suffixed temp path with `O_CREAT|O_EXCL` (fails closed on a planted
## symlink/file), `writeAllFd` the bytes, then `moveFile`/`rename(2)` into
## place.  Lifted here (RFC-0006 R1) so resultcache.nim has exactly one
## correct implementation instead of an inline copy.
##
## Never raises: any open/write/rename failure returns `ok=false` (with a
## non-empty `error` naming the failing step and the underlying OS reason —
## see RFC-0006 review R10 below) and best-effort cleans up the temp file.  A
## pre-existing temp file at the SAME (finalPath, pid) is best-effort removed
## before the open — it can only be a leftover from an earlier attempt in
## this same process (a different process has a different pid, hence a
## different temp path; see resultcache's L10 note).
##
## ## RFC-0006 review R10 — the specific OS error is no longer swallowed
##
## Before the R1 factor-out, `resultcache.storeCached` logged the specific
## OSError message on a failed write (`"could not write cache entry '…': " &
## e.msg`).  Returning a bare `bool` regressed that diagnostic —
## exactly the detail an operator needs to tell "permission denied" from "disk full" from
## "EXDEV" from "a planted symlink" apart.  `atomicPutFile` now returns
## `tuple[ok: bool; error: string]`: `error` is `""` on success, and on
## failure names the step (create temp / write temp / rename into place) and
## carries the OS reason — `strerror(errno)` for the raw posix open/write
## calls (captured immediately after the failing syscall, before any other
## call can clobber `errno`, mirroring the idiom already used by
## `ledger.openLedger`/`ledger.append`), or the `OSError.msg` from
## `moveFile`'s rename(2).

import std/os
import std/posix as posix_mod

proc sanitizeControlBytes*(s: string): string =
  ## Sanitize untrusted-origin text before it reaches a terminal or CI log.
  ##
  ## Threat: crisol writes diagnostic text that can originate from
  ## untrusted-origin sources never meant to be terminal-safe — config file
  ## content (nkdl's `formatError` embeds the raw offending source line
  ## verbatim, including a caret pointer), on-disk state (group names,
  ## gate env-var names read back out of a crisol.kdl someone else wrote),
  ## or externally supplied manifests. Such text can carry ANSI escape
  ## sequences (cursor movement, screen clearing, spoofed prompts) or other
  ## control bytes that corrupt a CI log's capture. Writing it to
  ## stdout/stderr raw enables control/ANSI injection.
  ##
  ## Sanitization is applied PER LINE: every byte < 0x20 other than '\n'
  ## itself, and byte 0x7f (DEL), is replaced with '?'. '\n' is deliberately
  ## preserved — some of this text is legitimately multi-line (a config
  ## parse error's caret block spans several lines) and callers rely on that
  ## line structure surviving intact. This does mean an embedded '\n' in the
  ## untrusted text can splice an extra output line; that is accepted and
  ## documented here rather than treated as a defect — the spliced line is
  ## still fully sanitized text, not raw control bytes, so it cannot itself
  ## move the cursor or issue further escape sequences.
  ##
  ## Bytes 0x80-0x9F (the C1 control range) are deliberately left alone: in
  ## a UTF-8 byte stream these are ordinary continuation bytes of a
  ## multibyte character, so replacing them would corrupt legitimate UTF-8
  ## text (e.g. a test name or file path containing non-ASCII characters).
  ## Modern terminals and CI log viewers operating in UTF-8 mode do not
  ## interpret bare 8-bit C1 control codes either, so there is no
  ## equivalent injection risk to guard against here.
  result = newString(s.len)
  for i, c in s:
    if c == '\n':
      result[i] = c
    elif ord(c) < 0x20 or ord(c) == 0x7f:
      result[i] = '?'
    else:
      result[i] = c

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

proc atomicPutFile*(finalPath: string; data: string): tuple[ok: bool; error: string] =
  ## Atomically write `data` into `finalPath`.
  ##
  ## Mechanic (identical to resultcache.storeCached's former inline block):
  ##   1. Best-effort remove any leftover `<finalPath>.<ourPid>.tmp` from a
  ##      previous attempt in this same process.
  ##   2. Open `<finalPath>.<ourPid>.tmp` with O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC,
  ##      mode 0o600 — O_EXCL fails closed on a planted symlink/file.
  ##   3. `writeAllFd` the bytes (handles EINTR + short writes).
  ##   4. `moveFile` (rename(2)) the tmp into `finalPath`.
  ##
  ## Returns `(true, "")` iff the file is fully in place at `finalPath`.
  ## Returns `(false, <reason>)` — and NEVER raises — on any open/write/rename
  ## failure, cleaning up the tmp file first.  `<reason>` names the failing
  ## step and the underlying OS error text (see module docs, RFC-0006 review
  ## R10) so callers can log a diagnostic that actually explains a production
  ## failure (permission denied, disk full, EXDEV, a planted symlink, …)
  ## instead of a bare "could not write" with no cause.  This helper is
  ## reused for resultcache's JSON entries; it does not itself write to
  ## stderr — callers log using the returned `error`.
  let tmpPath = finalPath & "." & $posix_mod.getpid() & ".tmp"

  # Best-effort removal of our own PID-specific leftover .tmp (a retry within
  # this same process).  A different process has a different pid, hence a
  # different tmpPath, so this never races another live writer.
  try: removeFile(tmpPath) except CatchableError: discard

  var tmpFd: cint = -1
  try:
    let flags = posix_mod.O_CREAT or posix_mod.O_EXCL or posix_mod.O_WRONLY or
                posix_mod.O_CLOEXEC
    tmpFd = posix_mod.open(tmpPath.cstring, flags, posix_mod.Mode(0o600))
    if tmpFd < 0:
      # Capture errno IMMEDIATELY — no other posix call happens between the
      # failing open(2) and this read, mirroring ledger.openLedger's idiom.
      let err = $posix_mod.strerror(posix_mod.errno)
      return (false, "could not create temp file '" & tmpPath & "': " & err)

    let writeOk = writeAllFd(tmpFd, data)
    if not writeOk:
      # Same immediate-errno-capture idiom: writeAllFd's own failing write(2)
      # is the last posix call before we read errno here.
      let err = $posix_mod.strerror(posix_mod.errno)
      discard posix_mod.close(tmpFd)
      tmpFd = -1
      try: removeFile(tmpPath) except CatchableError: discard
      return (false, "could not write temp file '" & tmpPath & "': " & err)

    discard posix_mod.close(tmpFd)
    tmpFd = -1
    moveFile(tmpPath, finalPath)
    return (true, "")
  except OSError as e:
    if tmpFd >= 0: discard posix_mod.close(tmpFd)
    try: removeFile(tmpPath) except CatchableError: discard
    return (false, "could not rename temp file to '" & finalPath & "': " & e.msg)
  except Exception as e:
    if tmpFd >= 0: discard posix_mod.close(tmpFd)
    try: removeFile(tmpPath) except CatchableError: discard
    return (false, e.msg)
