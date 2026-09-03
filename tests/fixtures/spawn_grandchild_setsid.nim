## spawn_grandchild_setsid.nim — rfc-0007 A6a fixture: daemonizes a
## grandchild via setsid() — INVISIBLE to a pgid scan by construction.
##
## Marker-file coordination: see spawn_grandchild.nim's header (crisol's
## run substrate passes no argv; the marker is a fixed name relative to
## the run child's cwd, which the calling test's scratch dir isolates).
##
## Identical to spawn_grandchild.nim except the grandchild calls setsid()
## BEFORE signaling readiness — by the time the parent observes the
## readiness marker and exits, the grandchild already belongs to a NEW
## session and a NEW process group (its own pid), so the pgid scan over
## the entrypoint's original group can never see it. This is the same
## blindness §3 documents for a pgid-only macOS tier, pinned honest here
## as `tree = toUnobservable` with EMPTY escapees (contrast
## spawn_grandchild.nim's non-empty escapees) — B1's subreaper is where
## this flips to observed-and-reaped.
import std/[os, posix]

const MarkerName = "spawn_grandchild_setsid.pid"

proc writeMarker(path, s: string) =
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  if fd >= 0:
    discard posix.write(fd, s.cstring, s.len)
    discard posix.close(fd)

let gcPid = fork()
if gcPid < 0:
  quit(1)
if gcPid == 0:
  # GRANDCHILD — daemonizes into its own session/group BEFORE signaling
  # readiness, so the parent never exits while the grandchild is still
  # (even momentarily) a visible member of the entrypoint's process group.
  discard posix.setsid()
  writeMarker(MarkerName, $getpid())
  for i in 1 .. 30: discard posix.sleep(1)
  quit(0)

# PARENT — wait for the grandchild's readiness signal, then exit fast.
var waitedMs = 0
while not fileExists(MarkerName) and waitedMs < 2000:
  os.sleep(10)
  waitedMs += 10
quit(0)
