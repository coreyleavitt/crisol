## ioutils.nim — low-level POSIX I/O helpers shared by ledger and resultcache,
## plus the one text sanitizer every user-facing stdout/stderr write uses.
##
## This module is intentionally minimal: it imports only std/posix (and
## std/os) so it sits at the very bottom of the crisol dependency graph and
## cannot create cycles — which is also why `sanitizeControlBytes` lives
## here rather than in render: crisol.nim, render.nim and depgraph.nim all
## need it and depgraph must not depend on render.
##
## ## RFC-0007 A3 — sole owner of raw file I/O
##
## `ioutils` is the ONE place in `src/` (outside `crisol/process/`, `lock.nim`
## and `signals.nim` — the process-supervision/locking/signal-handling posix
## usage the RFC keeps separate on purpose) that calls `posix.open`/`write`/
## `close` directly. `depgraph`, `jsonout`, `ledger`, `shardedledger`, and
## `crisol.nim`'s `init` writer all migrated their hand-rolled opens onto the
## primitives below — see `tests/unit/test_rfc7_a3_ioutils_ownership.nim` for
## the grep-test that keeps this true. The four RFC-pinned primitives are
## `exclusiveCreate`, `appendOpen`, `atomicPublish`, `writeAllFd`; four more
## were added because real call sites needed them and an exemption marker
## would have been a lie about what the code does (deep module, small
## interface — each earns its place below with the site that needs it):
##
##   - `closeFd`         — close a raw fd. `ledger`/`shardedledger` keep an
##                          fd open across many appends (not a single
##                          open-write-close), so they need to close it
##                          themselves without importing `std/posix` just for
##                          that one call.
##   - `lastErrorString` — `strerror(errno)`, captured by THIS module
##                          immediately when called. Lets a caller that just
##                          got `false` back from `writeAllFd` (a cross-module
##                          call already, even before A3) report the specific
##                          OS reason without importing posix itself — errno
##                          survives the plain Nim proc-call boundary in
##                          between, the same assumption `ledger.nim` already
##                          made about `writeAllFd` pre-A3, now made explicit.
##   - `createOverwrite`  — `O_CREAT|O_WRONLY|O_TRUNC` open (no `O_EXCL`):
##                          ledger/shardedledger compaction writes a
##                          freshly-named, process-owned compacted shard and
##                          wants "create or replace", not "must not already
##                          exist".
##   - `readRandomBytes`  — `/dev/urandom` read for the boot-id fallback.
##                          `ledger.nim` and `shardedledger.nim` had BYTE-FOR-
##                          BYTE identical open/read/close blocks for this;
##                          consolidating them here is the same "exactly one
##                          correct implementation" motive as `writeAllFd`.
##   - `writeGuardedFile` — `crisol.nim init`'s writer: create-or-truncate
##                          (per `--force`) while refusing to follow a
##                          symlink at the final path component
##                          (`O_NOFOLLOW`), then write and close. Composed
##                          from `exclusiveCreate`/`createOverwrite` +
##                          `writeAllFd` + `closeFd` rather than hand-rolled,
##                          so `crisol.nim` itself needs zero posix calls of
##                          its own.
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
## ## atomicPublish
##
## The atomic "write a whole file into place" mechanic that resultcache.nim
## implemented inline for its per-key JSON entries: write `data` to a
## PID-suffixed temp path with `O_CREAT|O_EXCL` (fails closed on a planted
## symlink/file), `writeAllFd` the bytes, then `moveFile`/`rename(2)` into
## place.  Lifted here (RFC-0006 R1, named `atomicPublish` per RFC-0007 A3)
## so resultcache.nim has exactly one correct implementation instead of an
## inline copy; A3 additionally migrated depgraph.nim's and jsonout.nim's own
## near-identical inline copies onto this same call.
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
## "EXDEV" from "a planted symlink" apart.  `atomicPublish` now returns
## `tuple[ok: bool; error: string]`: `error` is `""` on success, and on
## failure names the step (create temp / write temp / rename into place) and
## carries the OS reason — `strerror(errno)` for the raw posix open/write
## calls (captured immediately after the failing syscall, before any other
## call can clobber `errno`, mirroring the idiom already used by
## `ledger.openLedger`/`ledger.append`), or the `OSError.msg` from
## `moveFile`'s rename(2).

import std/os
import std/posix as posix_mod

# O_NOFOLLOW is a Linux extension not declared in Nim's std/posix. Pulled
# from <fcntl.h> via the emit+importc pattern — formerly crisol.nim's own
# declaration (its `init` writer was the only user); A3 moved it here so
# `crisol.nim` itself needs zero raw file-open machinery of its own.
{.emit: "#include <fcntl.h>".}
var O_NOFOLLOW_FLAG {.importc: "O_NOFOLLOW", nodecl.}: cint

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
  ## Bare bytes 0x80-0x9F (the C1 control range) are left alone: in a UTF-8
  ## byte stream these only ever appear as CONTINUATION bytes of a multibyte
  ## character, so replacing one in isolation would corrupt legitimate UTF-8
  ## text (e.g. a test name or file path containing non-ASCII characters).
  ##
  ## The UTF-8 *encoding* of a C1 control code point is a different matter
  ## and IS neutralized: the two-byte sequence 0xC2 followed by 0x80-0x9F
  ## decodes to U+0080-U+009F, and a terminal or CI log viewer operating in
  ## UTF-8 mode decodes it exactly that way — e.g. 0xC2 0x9B decodes to
  ## U+009B (CSI), which xterm treats as an escape-sequence introducer just
  ## like the raw ESC-`[` two-byte form. No legitimate printable text uses
  ## U+0080-U+009F, so this 2-byte sequence is always replaced with a single
  ## '?' (collapsing both bytes, not just the second one) rather than passed
  ## through. A bare 0xC2 not followed by a byte in 0x80-0x9F — including a
  ## lone trailing 0xC2 with nothing after it — is left untouched: it is
  ## either the lead byte of an unrelated 2-byte character (e.g. 0xC2 0xA0 =
  ## U+00A0 NBSP) or malformed/truncated UTF-8, neither of which decodes to
  ## a C1 control.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\n':
      result.add c
      inc i
    elif ord(c) < 0x20 or ord(c) == 0x7f:
      result.add '?'
      inc i
    elif ord(c) == 0xc2 and i + 1 < s.len and ord(s[i + 1]) in 0x80 .. 0x9f:
      result.add '?'
      i += 2
    else:
      result.add c
      inc i

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

proc closeFd*(fd: cint) =
  ## Close a raw posix fd. Idempotent is the CALLER's responsibility (mirrors
  ## `posix.close`'s own contract — calling this twice on the same fd number
  ## is undefined once the fd has been reused by another open). Exists so
  ## that a module holding an fd obtained from `appendOpen`/`exclusiveCreate`/
  ## `createOverwrite` (e.g. `ledger`/`shardedledger`, which keep one open
  ## across many appends rather than a single open-write-close) never needs
  ## `import std/posix` merely to close it.
  discard posix_mod.close(fd)

proc lastErrorString*(): string =
  ## `strerror(errno)`, read the instant this is called. Only meaningful
  ## immediately after a failing ioutils call with no OTHER syscall run in
  ## between (the same "capture errno before anything else can clobber it"
  ## discipline every proc in this module already follows internally) — lets
  ## a caller that just got `false`/`fd < 0` back from `writeAllFd`/an open
  ## primitive report the specific OS reason without importing `std/posix`
  ## itself for `strerror`/`errno`.
  $posix_mod.strerror(posix_mod.errno)

proc exclusiveCreate*(path: string; mode: int = 0o600; noFollow = false):
    tuple[fd: cint; error: string; alreadyExists: bool] =
  ## Open `path` for writing with `O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC`: fails
  ## closed if ANYTHING already exists at `path` — a file, a directory, or a
  ## symlink, even a dangling one (POSIX `open(2)` makes `O_EXCL` fail on any
  ## of these without needing `O_NOFOLLOW`). `noFollow` additionally sets
  ## `O_NOFOLLOW` — redundant with `O_EXCL` for the "nothing exists yet" case
  ## this proc is for, but kept as an explicit opt-in so the flag is visible
  ## at the call site rather than silently assumed.
  ##
  ## On success `fd >= 0`, `error == ""`, `alreadyExists == false`. On
  ## failure `fd == -1`; `error` names the OS reason (`strerror(errno)`,
  ## captured immediately after the failing `open(2)`); `alreadyExists` is
  ## true iff the failure was `EEXIST` or `ELOOP` — letting a caller phrase
  ## "already exists" distinctly from a genuine I/O error without importing
  ## `std/posix` for the errno constants itself.
  var flags = posix_mod.O_CREAT or posix_mod.O_EXCL or posix_mod.O_WRONLY or
              posix_mod.O_CLOEXEC
  if noFollow: flags = flags or O_NOFOLLOW_FLAG
  let fd = posix_mod.open(path.cstring, flags, posix_mod.Mode(mode))
  if fd < 0:
    let err = posix_mod.errno
    return (cint(-1), $posix_mod.strerror(err), err == EEXIST or err == ELOOP)
  (fd, "", false)

proc createOverwrite*(path: string; mode: int = 0o600; noFollow = false):
    tuple[fd: cint; error: string; alreadyExists: bool] =
  ## Open `path` for writing with `O_CREAT|O_WRONLY|O_TRUNC|O_CLOEXEC`,
  ## overwriting any existing regular file in place (no `O_EXCL`: unlike
  ## `exclusiveCreate`, an existing file at `path` is expected and fine).
  ## `noFollow` sets `O_NOFOLLOW` so a symlink at `path` is refused rather
  ## than followed and written through — REQUIRED whenever `path` might be
  ## attacker- or accident-planted (`crisol.nim init --force`, via
  ## `writeGuardedFile`); harmless, and left off by default, when the caller
  ## already owns the path outright (ledger/shardedledger compaction, whose
  ## compacted-shard name is a fresh `<pid>-<bootId>` composite only this
  ## process could have produced).
  ##
  ## Same success/failure shape as `exclusiveCreate`; `alreadyExists` here is
  ## true iff the failure was `ELOOP` (an `O_TRUNC` open never fails with
  ## `EEXIST` — that errno is specifically `O_EXCL`'s signal).
  var flags = posix_mod.O_CREAT or posix_mod.O_WRONLY or posix_mod.O_TRUNC or
              posix_mod.O_CLOEXEC
  if noFollow: flags = flags or O_NOFOLLOW_FLAG
  let fd = posix_mod.open(path.cstring, flags, posix_mod.Mode(mode))
  if fd < 0:
    let err = posix_mod.errno
    return (cint(-1), $posix_mod.strerror(err), err == ELOOP)
  (fd, "", false)

proc appendOpen*(path: string; mode: int = 0o600): tuple[fd: cint; error: string] =
  ## Open `path` for writing with `O_CREAT|O_WRONLY|O_APPEND|O_CLOEXEC`,
  ## creating it if absent and appending to any existing content — the
  ## ledger/shardedledger shard-file open (one fd held open across many
  ## `writeAllFd` appends, then closed via `closeFd`).
  ##
  ## On success `fd >= 0` and `error == ""`. On failure `fd == -1` and
  ## `error` names the OS reason (`strerror(errno)`, captured immediately
  ## after the failing `open(2)`).
  let flags = posix_mod.O_CREAT or posix_mod.O_WRONLY or posix_mod.O_APPEND or
              posix_mod.O_CLOEXEC
  let fd = posix_mod.open(path.cstring, flags, posix_mod.Mode(mode))
  if fd < 0:
    return (cint(-1), $posix_mod.strerror(posix_mod.errno))
  (fd, "")

proc readRandomBytes*(n: Natural): seq[byte] =
  ## Best-effort read of up to `n` bytes from `/dev/urandom`. Returns fewer
  ## than `n` bytes — possibly an empty seq — if the device cannot be opened
  ## or the read is short; NEVER raises. `ledger.nim`'s and
  ## `shardedledger.nim`'s boot-id fallback (used when
  ## `/proc/sys/kernel/random/boot_id` is unreadable) both had a
  ## byte-for-byte identical inline open/read/close block for this before
  ## A3; consolidated here for the same "exactly one correct implementation"
  ## reason as `writeAllFd`. Callers already degrade gracefully (falling
  ## back to the epoch-microsecond timestamp alone) on a short/empty result.
  if n == 0: return @[]
  let fd = posix_mod.open("/dev/urandom".cstring, posix_mod.O_RDONLY)
  if fd < 0: return @[]
  result = newSeq[byte](n)
  let got = posix_mod.read(fd, addr result[0], n)
  discard posix_mod.close(fd)
  if got != n:
    result = if got > 0: result[0 ..< got] else: @[]

proc atomicPublish*(finalPath: string; data: string): tuple[ok: bool; error: string] =
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
    let (fd, openErr, _) = exclusiveCreate(tmpPath)
    tmpFd = fd
    if tmpFd < 0:
      return (false, "could not create temp file '" & tmpPath & "': " & openErr)

    let writeOk = writeAllFd(tmpFd, data)
    if not writeOk:
      # Immediate-errno-capture idiom: writeAllFd's own failing write(2) is
      # the last posix call before we read errno here — closeFd (a bare
      # close(2)) does not clobber it before the read completes.
      let err = lastErrorString()
      closeFd(tmpFd)
      tmpFd = -1
      try: removeFile(tmpPath) except CatchableError: discard
      return (false, "could not write temp file '" & tmpPath & "': " & err)

    closeFd(tmpFd)
    tmpFd = -1
    moveFile(tmpPath, finalPath)
    return (true, "")
  except OSError as e:
    if tmpFd >= 0: closeFd(tmpFd)
    try: removeFile(tmpPath) except CatchableError: discard
    return (false, "could not rename temp file to '" & finalPath & "': " & e.msg)
  except Exception as e:
    if tmpFd >= 0: closeFd(tmpFd)
    try: removeFile(tmpPath) except CatchableError: discard
    return (false, e.msg)

proc writeGuardedFile*(path: string; data: string; mode: int; overwrite: bool):
    tuple[ok: bool; error: string; alreadyExists: bool] =
  ## Write `data` to a fresh file at `path`, refusing to follow a symlink at
  ## the final path component (`O_NOFOLLOW`) on every branch. This is
  ## `crisol.nim init`'s writer: a human-authored template file, not
  ## machine-managed state, so it wants the symlink guard but NOT
  ## `atomicPublish`'s tmp+rename dance — nothing else is concurrently
  ## reading this path mid-write, so there is no torn-read hazard to protect
  ## against, and `init` writes exactly the path the user named, never a
  ## sibling tmp file.
  ##
  ##   `overwrite == false`: `exclusiveCreate` — fails (`alreadyExists =
  ##     true`) if ANYTHING already exists at `path` (file, dir, or symlink,
  ##     even dangling).
  ##   `overwrite == true`:  `createOverwrite` — replaces an existing regular
  ##     file in place; a symlink at `path` is still refused
  ##     (`alreadyExists = true`) rather than written through.
  ##
  ## Returns `(true, "", false)` on success. On any failure returns
  ## `(false, <reason>, <alreadyExists>)` and never raises; `<reason>` is
  ## `strerror(errno)` for the failing open/write syscall, captured
  ## immediately after it.
  let (fd, openErr, alreadyExists) =
    if overwrite: createOverwrite(path, mode, noFollow = true)
    else:         exclusiveCreate(path, mode, noFollow = true)
  if fd < 0:
    return (false, openErr, alreadyExists)

  let writeOk = writeAllFd(fd, data)
  if not writeOk:
    let err = lastErrorString()
    closeFd(fd)
    return (false, err, false)

  closeFd(fd)
  (true, "", false)
