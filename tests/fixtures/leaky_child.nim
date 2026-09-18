## leaky_child.nim — rfc-0007 review r4 fixture: a plain (non-breakaway)
## child spawned INSIDE crisol's Job that is STILL ALIVE when the PARENT
## (this fixture) exits 0. Mirrors POSIX's spawn_grandchild.nim (same
## shape: a clean pass that leaves a live descendant behind, marker-file
## synced, proven by test_rfc0007_a6a_escapee_evidence.nim's Suite 1) — the
## Windows analog for test_windows_escapees.nim.
##
## Contrast tests/fixtures/breakaway_attempt.nim (D1b-iii): that fixture
## proves a grandchild CANNOT LEAVE the Job (breakaway denied). This
## fixture proves the separate claim r4 fixes: a grandchild that never
## even tries to leave can still be a genuine SURVIVOR, observed alive at
## reap time, before the Job's KILL_ON_JOB_CLOSE eventually cleans it up.
## No breakaway is attempted here at all — a plain child is a Job member
## by construction, no opt-in needed.
##
## `when defined(windows)`:
##   PARENT mode (argv[1] == marker path) spawns a plain, CREATE_SUSPENDED
##   grandchild — THIS SAME EXE, told to run in sleeper mode — resumes it,
##   writes the ready marker once the grandchild is confirmed running, and
##   EXITS IMMEDIATELY (quit(0)) WITHOUT waiting for or killing the
##   grandchild. The grandchild is still alive, still a member of the SAME
##   Job, at the exact moment the caller observes the PARENT's exit and
##   calls `reap`.
##
##   SLEEPER mode (argv[1] == "sleeper") sleeps in bounded ~30s ticks and
##   exits 0 if never killed first — the caller's Job teardown
##   (KILL_ON_JOB_CLOSE, fired by `reap`'s `closeHandle(entry.hJob)`) is
##   expected to cut this short.
##
## `else`: ordinary cross-platform Nim (compileFixture builds this on any
## host — crisol.nimble's self-discovering test task never runs this file
## directly, but `helpers.compileFixture` invokes plain `nim c` on it
## regardless of host, same as every other fixture in this directory) —
## PARENT mode writes the marker and exits immediately; SLEEPER mode is
## never reached (nothing on a non-windows host ever re-invokes the exe
## with that argv), since this fixture is consumed solely by the
## `when defined(windows)` arm of test_windows_escapees.nim.
import std/os

when defined(windows):
  import std/winlean

  const CREATE_SUSPENDED = 0x00000004'i32

  proc sleepTicks() =
    for _ in 1 .. 600:   # bounded ~30s (600 * 50ms) -- never an unbounded hang
      sleep(50)

  if paramCount() >= 1 and paramStr(1) == "sleeper":
    # SLEEPER (grandchild) mode -- guarded FIRST so this sentinel can never
    # be mistaken for a marker path in PARENT mode below.
    sleepTicks()
    quit(0)   # only reached if the caller's Job teardown never fires

  # PARENT mode -- argv[1] is the marker path.
  let markerPath = paramStr(1)
  let selfExe = paramStr(0)

  var si: STARTUPINFO
  si.cb = int32(sizeof(si))
  var pi: PROCESS_INFORMATION
  var cmdWide = newWideCString(quoteShellWindows(selfExe) & " sleeper")

  let ok = createProcessW(nil, cmdWide, nil, nil, 0'i32, CREATE_SUSPENDED,
                           nil, nil, si, pi)
  if ok == 0'i32:
    quit(1)   # honest failure -- could not spawn the grandchild at all

  discard resumeThread(pi.hThread)
  discard closeHandle(pi.hThread)
  # pi.hProcess is deliberately left open (never closed, never waited on):
  # closing the HANDLE does not terminate the process it names, and the
  # grandchild must stay alive and discoverable in the Job right up until
  # the caller's own Job teardown -- nothing is gained by closing it here.

  writeFile(markerPath, "ready\n")   # sync point: grandchild confirmed resumed
  quit(0)   # PARENT exits NOW -- the grandchild is still alive, INSIDE the
            # same Job, at the exact instant the caller observes this exit
            # and calls reap().
else:
  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")
  sleep(50)
  quit(0)
