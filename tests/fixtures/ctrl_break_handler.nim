## ctrl_break_handler.nim — rfc-0007 D1b-i fixture: the cooperative-stop
## SUCCESS case (the `term_cooperative` analog for Windows).
##
## argv: [markerPath]
##
## `when defined(windows)`: installs a `SetConsoleCtrlHandler` callback
## FIRST — on `CTRL_BREAK_EVENT` it exits the process with code 0 directly
## from the handler (Win32 runs ctrl handlers on their own OS thread the
## system creates, same "runs independently of the main flow" shape as
## `term_cooperative`'s async-signal-safe `exitnow` from a POSIX signal
## handler). ONLY AFTER the handler is installed does it write the ready
## marker (`paramStr(1)`) and flush+close it — the test's synchronization
## point, same discipline as `pass_fast`/`spawn_pgroup_child`: the marker
## must never appear before the handler that is supposed to catch the
## incoming CTRL_BREAK is actually live. It then sleeps in bounded 50ms
## ticks (up to ~30s) — the expected path is the handler firing and exiting
## long before that bound is reached; hitting the bound is an honest
## failure (exit 1), never a hang.
##
## `else`: ordinary cross-platform Nim so `compileFixture`
## (tests/conformance/helpers.nim) and the nimble test task's self-
## discovery build this on any host — writes the marker and exits 0
## immediately; never actually driven on non-Windows (this fixture is
## consumed solely by the `when defined(windows)` arm of
## tests/conformance/test_windows_coopstop.nim).
import std/os

when defined(windows):
  type WINBOOL = int32
  type ConsoleCtrlHandlerProc = proc (dwCtrlType: int32): WINBOOL {.stdcall.}

  proc setConsoleCtrlHandler(handlerRoutine: ConsoleCtrlHandlerProc;
                              add: WINBOOL): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleCtrlHandler".}

  const CTRL_BREAK_EVENT = 1'i32

  proc onCtrl(dwCtrlType: int32): WINBOOL {.stdcall.} =
    if dwCtrlType == CTRL_BREAK_EVENT:
      quit(0)   # handled — cooperative success, exactly what this fixture proves
    return 0'i32  # not ours: let any other handler in the chain see it

  discard setConsoleCtrlHandler(onCtrl, 1'i32)

  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")   # open+write+close — the sync point

  for _ in 1 .. 600:   # bounded ~30s (600 * 50ms) — never an unbounded hang
    sleep(50)
  quit(1)   # the handler never fired within the bound — an honest failure
else:
  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")
  quit(0)
