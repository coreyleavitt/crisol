## detach_console.nim — rfc-0007 D1b-i fixture: the SOLE
## `cooperativeUnavailable: true` producer.
##
## argv: [markerPath]
##
## `when defined(windows)`: calls `FreeConsole()` FIRST — detaching this
## process from whatever console it inherited — THEN writes the ready
## marker (`paramStr(1)`), flushes+closes it, then sleeps in bounded 50ms
## ticks (up to ~30s) so the supervisor has time to spawn-observe the
## marker, probe (`GetConsoleProcessList`), find this pid absent from the
## caller's console, `requestStop` (a no-op: undeliverable, so
## `cooperativeUnavailable` is recorded and no CTRL_BREAK is sent), and
## `forceKill` it.
##
## FreeConsole MUST precede the marker write: the marker is the test's
## synchronization point (same discipline as `pass_fast`/
## `spawn_pgroup_child`) — if the marker existed before FreeConsole ran, the
## test could observe "ready" and probe while the child was still attached,
## an intermittent false negative for the exact producer this fixture
## exists to prove.
##
## `else`: ordinary cross-platform Nim so `compileFixture`
## (tests/conformance/helpers.nim) and the nimble test task's self-
## discovery build this on any host — writes the marker, sleeps briefly,
## and exits 0; never actually driven on non-Windows (this fixture is
## consumed solely by the `when defined(windows)` arm of
## tests/conformance/test_windows_coopstop.nim).
import std/os

when defined(windows):
  proc freeConsole(): int32 {.stdcall, dynlib: "kernel32", importc: "FreeConsole".}

  discard freeConsole()   ## MUST run before the marker write — see header

  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")   # open+write+close — the sync point

  for _ in 1 .. 600:   # bounded ~30s (600 * 50ms) — gives the supervisor
    sleep(50)           # time to probe + requestStop (no-op) + forceKill
  quit(0)   # only reached if the supervisor never forceKilled us
else:
  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")
  sleep(50)
  quit(0)
