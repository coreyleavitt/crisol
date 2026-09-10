## test_windows_lock.nim — rfc-0007 D2a-2: windows advisory lock
## (LockFileEx) via crisol/lock's real public interface.
##
## Drives `crisol/lock` directly (not a backend module) — the ladder
## (`when defined(windows): import crisol/lock/windows`) picks the windows
## backend under test here, mirroring how consumers (crisol.nim, api.nim)
## only ever see `crisol/lock`.
##
## Two properties pinned:
##   - contention within one process proves the lock is REAL: Windows
##     byte-range locks are mandatory and per-handle, so a second
##     acquireLock on the same stateDir from the same process fails with
##     cekEnvironment (ERROR_LOCK_VIOLATION) while the first is held, and a
##     fresh acquireLock succeeds again once the first is released — proving
##     release actually drops the lock (not just that the raise path works).
##   - releaseLock is safe on a default-constructed (never-acquired) handle
##     and idempotent on a real one — api.nim relies on both in some paths.
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[os, unittest]
  import crisol/lock
  import crisol/types

  suite "rfc-0007 D2a-2 — windows advisory lock (LockFileEx)":

    test "contention: second acquireLock fails while first is held, succeeds after release":
      let dir = getTempDir() / ("crisol_win_lock_test_" & $getCurrentProcessId())
      removeDir(dir)

      let a = acquireLock(dir)

      var contended = false
      try:
        discard acquireLock(dir)
      except CrisolError as e:
        contended = true
        check e.kind == cekEnvironment
      check contended

      var aVar = a
      releaseLock(aVar)

      # Released — a fresh acquire must succeed now.
      let b = acquireLock(dir)
      var bVar = b
      releaseLock(bVar)

      removeDir(dir)

    test "releaseLock is a safe no-op on a default handle, and idempotent on a real one":
      var empty: LockHandle
      releaseLock(empty)   # must not raise, must not touch a bogus handle
      releaseLock(empty)   # still a no-op

      let dir = getTempDir() / ("crisol_win_lock_test2_" & $getCurrentProcessId())
      removeDir(dir)
      var h = acquireLock(dir)
      releaseLock(h)
      releaseLock(h)       # double release on a real handle is safe
      removeDir(dir)

  when isMainModule:
    echo "test_windows_lock done"

else:
  when isMainModule:
    echo "test_windows_lock: skipped (not windows)"
