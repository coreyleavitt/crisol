## breakaway_attempt.nim — rfc-0007 D1b-iii fixture: the breakaway-
## containment proof (Evidence.escapees's "`@[]` is CORRECT, not a stub"
## claim, process/windows.nim's module header).
##
## argv convention: argv[1] == "sleeper" selects SLEEPER mode (this exe,
## re-invoked as its own grandchild); anything else in argv[1] is a MARKER
## PATH and selects PARENT mode (the default entrypoint shape — same
## "argv[1] = marker path" convention detach_console.nim/
## ctrl_break_handler.nim use, with a distinct sentinel value carved out for
## sleeper mode so the two can never collide).
##
## `when defined(windows)`:
##   PARENT mode spawns a grandchild — THIS SAME EXE (`paramStr(0)`), told
##   to run in sleeper mode — first with `CREATE_BREAKAWAY_FROM_JOB or
##   CREATE_SUSPENDED`. The enclosing Job (crisol's own `spawnChild`, which
##   NEVER sets `JOB_OBJECT_LIMIT_BREAKAWAY_OK`) DENIES this: `CreateProcessW`
##   returns 0 (`GetLastError` ERROR_ACCESS_DENIED, 1350). That failure IS
##   the containment proof, not an error to route around — it demonstrates
##   the grandchild could not leave the Job just by asking to. On that
##   failure the fixture retries WITHOUT `CREATE_BREAKAWAY_FROM_JOB` (still
##   `CREATE_SUSPENDED`), which succeeds (a plain child/grandchild is a Job
##   member by default, no opt-in needed), then `ResumeThread`s it. Because
##   breakaway never actually happened, the grandchild is STILL inside the
##   parent's (and therefore crisol's) Job — `snapshotTree` sees it, and it
##   can never be an escapee. Only once the grandchild is confirmed resumed
##   does the fixture write the ready marker (argv[1]) — the caller's sole
##   synchronization point, same discipline as detach_console.nim/
##   ctrl_break_handler.nim: it must never observe "ready" before the
##   grandchild is genuinely live and contained. PARENT then sleeps in
##   bounded ~30s ticks (the expected path is the caller force-killing the
##   whole Job long before that bound).
##
##   SLEEPER mode (argv[1] == "sleeper") just sleeps in bounded ~30s ticks
##   and exits 0 if never killed first — it writes no marker of its own;
##   PARENT's marker write is the caller's only synchronization point.
##
## `else`: ordinary cross-platform Nim so `compileFixture`
## (tests/conformance/helpers.nim) and the nimble test task's self-
## discovery build this on any host — PARENT mode writes the marker and
## exits quickly; SLEEPER mode is never reached (nothing on this platform
## ever re-invokes the exe with that argv), since this fixture is consumed
## solely by the `when defined(windows)` arm of
## test_windows_containment.nim.
import std/os

when defined(windows):
  import std/winlean

  const
    CREATE_BREAKAWAY_FROM_JOB = 0x01000000'i32
    CREATE_SUSPENDED          = 0x00000004'i32

  proc sleepTicks() =
    for _ in 1 .. 600:   # bounded ~30s (600 * 50ms) — never an unbounded hang
      sleep(50)

  if paramCount() >= 1 and paramStr(1) == "sleeper":
    # SLEEPER (grandchild) mode — guarded FIRST so this sentinel can never
    # be mistaken for a marker path in PARENT mode below.
    sleepTicks()
    quit(0)   # only reached if the caller never force-killed the Job

  # PARENT mode — argv[1] is the marker path.
  let markerPath = paramStr(1)
  let selfExe = paramStr(0)

  var si: STARTUPINFO
  si.cb = int32(sizeof(si))
  var pi: PROCESS_INFORMATION
  var cmdWide = newWideCString(quoteShellWindows(selfExe) & " sleeper")

  let breakawayFlags: int32 = CREATE_BREAKAWAY_FROM_JOB or CREATE_SUSPENDED
  var ok = createProcessW(nil, cmdWide, nil, nil, 0'i32, breakawayFlags,
                           nil, nil, si, pi)
  if ok == 0'i32:
    # EXPECTED: breakaway denied (the enclosing Job never sets
    # JOB_OBJECT_LIMIT_BREAKAWAY_OK) — this failure IS the containment
    # proof, not an error path to avoid. Retry without breakaway so the
    # grandchild still runs, genuinely contained in the same Job.
    var cmdWide2 = newWideCString(quoteShellWindows(selfExe) & " sleeper")
    var pi2: PROCESS_INFORMATION
    ok = createProcessW(nil, cmdWide2, nil, nil, 0'i32, CREATE_SUSPENDED,
                         nil, nil, si, pi2)
    if ok == 0'i32:
      quit(1)   # honest failure — could not spawn the grandchild at all
    pi = pi2

  discard resumeThread(pi.hThread)
  discard closeHandle(pi.hThread)
  # pi.hProcess is deliberately left open (never closed, never tracked
  # further): closing a HANDLE does not terminate the process it names, and
  # the grandchild must stay alive and discoverable in the Job for the
  # test's snapshotTree assertion — nothing is gained by closing it here,
  # and the whole Job (this handle included) is torn down by the caller's
  # eventual forceKill regardless.

  writeFile(markerPath, "ready\n")   # the sync point — see header

  sleepTicks()
  quit(0)   # only reached if the caller never force-killed the Job
else:
  let markerPath = paramStr(1)
  writeFile(markerPath, "ready\n")
  sleep(50)
  quit(0)
