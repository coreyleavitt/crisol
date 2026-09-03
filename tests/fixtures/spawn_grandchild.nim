## spawn_grandchild.nim — rfc-0007 A6a fixture: leaks a same-pgroup
## grandchild and exits 0.
##
## crisol's own compile+run substrate never passes argv to an entrypoint
## (no CLI mechanism for it — Group.flags are COMPILE flags), so
## coordination with the grandchild uses a marker file at a FIXED name
## relative to the current directory. The run child's cwd defaults to
## `config.projectRoot` (rfc-0007 A2c; chdirIntoScratch is opt-in, off by
## default), which the calling test controls (a fresh scratch dir per
## test) — so the marker name only needs to be fixed WITHIN one entrypoint,
## never globally unique.
##
## The parent forks a grandchild WITHOUT calling setpgid — the grandchild
## inherits the parent's process group at fork() (before it runs a single
## instruction of its own code), so it is visible to a pgid scan from the
## instant it exists. The grandchild signals readiness (writes its own pid
## to the marker) before sleeping, and the parent waits for that signal
## before exiting — this removes any race between "the entrypoint has
## exited and been reaped" and "the grandchild is actually alive in the
## group" from the caller's perspective.
##
## The entrypoint itself is a clean, fast PASS (exit 0, no kill/timeout
## involved) — the OBSERVABLE escapee a pgid scan can actually see (A6a's
## post-reap scan), never calling setpgid/setsid: contrast
## spawn_grandchild_setsid.nim, which is invisible by construction.
import std/[os, posix]

const MarkerName = "spawn_grandchild.pid"

proc writeMarker(path, s: string) =
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  if fd >= 0:
    discard posix.write(fd, s.cstring, s.len)
    discard posix.close(fd)

let gcPid = fork()
if gcPid < 0:
  quit(1)
if gcPid == 0:
  # GRANDCHILD — same pgroup (no setpgid/setsid). Signal readiness, then
  # sleep long enough for the parent's reaper to scan the group before
  # this process would exit on its own.
  writeMarker(MarkerName, $getpid())
  for i in 1 .. 30: discard posix.sleep(1)
  quit(0)

# PARENT — wait for the grandchild's readiness signal, then exit fast.
var waitedMs = 0
while not fileExists(MarkerName) and waitedMs < 2000:
  os.sleep(10)
  waitedMs += 10
quit(0)
