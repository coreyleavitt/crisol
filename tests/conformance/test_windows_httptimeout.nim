## test_windows_httptimeout.nim — rfc-0007 D2a-5: windows socket-timeout
## de-POSIX (winsock `SO_RCVTIMEO`/`SO_SNDTIMEO` DWORD-milliseconds optval).
##
## `httpraw.nim`'s `setTimeoutOpt` is private, so this is not a call into
## that proc directly -- it is the "lighter, honest" fallback the D2a-5
## brief allows: a tiny live proof that the WINSOCK MECHANISM `httpraw.nim`
## now relies on for windows actually works the way its comments claim --
## `SO_RCVTIMEO` takes a `DWORD` (4-byte) milliseconds value, not a
## `struct timeval` the way posix's identically-named option does. A wrong
## optval size/layout there is exactly the failure mode that would make a
## real windows leg either error out of `setsockopt` or silently arm the
## WRONG timeout (e.g. reading only the low half of a `timeval`-shaped
## write as a `DWORD`) -- this proves `setsockopt` accepts the DWORD form
## and `getsockopt` reads back the SAME value, on a real socket.
##
## Standing up a stalling TCP listener and driving `rawHttpFetcher`'s
## public entry point against it (the brief's heavier option) would additionally
## prove end-to-end wiring, but `httpraw.nim`'s own deadline-remainder
## machinery (`remainingMs`/the re-arm-before-every-syscall discipline) is
## platform-agnostic std/net-level logic already exercised on Linux by
## `tests/integration/test_httpraw_real.nim`'s scenario 3 (connect-timeout)
## and scenario 4 (recv-timeout); the ONLY windows-specific fact left
## unproven by that Linux coverage is "does the DWORD-ms optval round-trip
## through a real winsock socket" -- exactly what this file checks, at a
## fraction of the complexity (no background thread, no listener).
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_availmem.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[net, unittest, winlean]

  const
    SOL_SOCKET: cint = 0xffff'i32
    SO_RCVTIMEO: cint = 0x1006'i32
      ## winsock2.h values -- same constants `httpraw.setTimeoutOpt` uses
      ## (that proc is private, hence the local redeclaration here rather
      ## than an import).

  suite "rfc-0007 D2a-5 — windows SO_RCVTIMEO is a DWORD-ms optval":

    test "setsockopt(SO_RCVTIMEO, DWORD ms) succeeds; getsockopt reads it back":
      let socket = newSocket()
      defer: socket.close()
      let fd = winlean.SocketHandle(socket.getFd())

      var wantMs: int32 = 1234
      let setRc = winlean.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                                      addr wantMs, SockLen(sizeof(wantMs)))
      check setRc == 0  # 0 == SOCKET_ERROR would be nonzero on failure

      var gotMs: int32 = 0
      var gotLen: SockLen = SockLen(sizeof(gotMs))
      let getRc = winlean.getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                                      addr gotMs, addr gotLen)
      check getRc == 0
      check gotMs == wantMs

  when isMainModule:
    echo "test_windows_httptimeout done"

else:
  when isMainModule:
    echo "test_windows_httptimeout: skipped (not windows)"
