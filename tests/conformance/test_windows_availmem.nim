## test_windows_availmem.nim — rfc-0007 D2a-3: windows availableMemBytes
## via GlobalMemoryStatusEx.
##
## A live liveness proof that the Windows branch of
## `crisol/memprobe.availableMemBytes` returns a real available-physical-
## memory figure rather than the degraded `none` a Linux-only /proc read
## would produce there. A running CI runner always has some free RAM, so
## `isSome and > 0` is a sound assertion; an upper sanity bound catches a
## mis-laid-out MEMORYSTATUSEX (which would read a wild/implausible value
## out of `ullAvailPhys`) without pinning to any particular runner's RAM.
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[options, unittest]
  import crisol/memprobe

  suite "rfc-0007 D2a-3 — windows availableMemBytes (GlobalMemoryStatusEx)":

    test "returns some(available RAM), a plausible positive value":
      let a = availableMemBytes()
      check a.isSome
      check a.get > 0
      # Sanity bound: 2 TiB — a mis-laid-out struct reads garbage far
      # outside any real machine's physical RAM. Lenient by design.
      check a.get < 2_199_023_255_552'i64  # 2 TiB

  when isMainModule:
    echo "test_windows_availmem done"

else:
  when isMainModule:
    echo "test_windows_availmem: skipped (not windows)"
