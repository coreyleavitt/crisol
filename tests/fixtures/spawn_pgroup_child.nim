## spawn_pgroup_child.nim — rfc-0007 A2a-i test_pgroup fixture.
##
## argv: [gcPidFile, survivedFile]
##
## Ignores SIGTERM (forces the Supervisor's requestStop -> forceKill
## escalation path in the test driving this fixture), then forks a
## grandchild that inherits the SAME process group (never calls setpgid
## again) and the same SIGTERM-ignoring disposition. The grandchild writes
## its pid to gcPidFile, sleeps 30s, then — only if it survives — writes a
## SURVIVED marker to survivedFile. The marker must never appear if a
## domain-wide SIGKILL (killpg-equivalent) reaches every member of the group.
import std/[os, posix]

proc onTerm(sig: cint) {.noconv.} =
  discard   # ignore — do not exit; forces the caller to escalate to SIGKILL

var sa: Sigaction
sa.sa_handler = onTerm
discard sigemptyset(sa.sa_mask)
sa.sa_flags = 0
discard sigaction(SIGTERM, sa, nil)

let gcPidFile    = paramStr(1)
let survivedFile = paramStr(2)

proc writeLine(path, s: string) =
  let line = s & "\n"
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  discard posix.write(fd, line.cstring, line.len)
  discard posix.close(fd)

let gcPid = fork()
if gcPid < 0:
  quit(1)

if gcPid == 0:
  # GRANDCHILD — same pgroup as the parent (no setpgid call), inherits the
  # SIGTERM-ignore disposition set above. LOOPED sleep, not a single call:
  # posix.sleep(3) returns EARLY once the (ignored) SIGTERM interrupts it —
  # a bare `discard posix.sleep(30)` would fall through to the SURVIVED
  # write the instant SIGTERM arrives, even though the signal did nothing.
  writeLine(gcPidFile, $getpid())
  for i in 1 .. 30:
    discard posix.sleep(cint(1))
  # Only reached if NOT killed:
  writeLine(survivedFile, $getpid())
  quit(0)

# PARENT — the process the Supervisor spawned directly. Same looped-sleep
# reasoning as the grandchild above.
for i in 1 .. 30:
  discard posix.sleep(cint(1))
quit(0)
