## spawn_reparented_helper.nim — rfc-0007 code-review r2 regression fixture:
## a same-pgroup helper that DOUBLE-FORKS a long-lived grandchild before
## THIS slot's own reap ever runs.
##
## Marker-file coordination: see spawn_grandchild.nim's header (crisol's run
## substrate passes no argv; markers are fixed names relative to the run
## child's cwd, which the calling test's shared scratch dir isolates).
##
## P forks H; H immediately forks G, then H exits right away — G reparents
## to crisol (the subreaper) within microseconds, but NEITHER H nor G ever
## calls setpgid/setsid, so G keeps P's own pgid the whole time. G is
## exactly the pgid-preserving daemonized-helper case
## `discoverAndReapEscapees`'s cross-slot exclusion must protect: G
## satisfies the ppid==ownPid arm of ANY slot's candidate filter (it is
## reparented to crisol) while its pgrp still belongs to THIS (P's)
## still-live domain — a DIFFERENT, concurrently-reaping slot must never
## claim it.
##
## P then waits for the peer entrypoint's own "done" marker (written by
## spawn_reparented_helper_peer.nim, run concurrently in the SAME scratch
## dir under jobs=2) before exiting, plus a fixed buffer — so THIS
## entrypoint's own slot is guaranteed still registered/live at the moment
## the peer's reap runs (the precondition the r2 bug needs to manifest).
## G sleeps long enough to still be alive when P itself finally exits, so
## P's OWN later reap is the one that correctly discovers and kills it.
when defined(posix):
  import std/[os, posix]

  proc writeMarker(path, s: string) =
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    if fd >= 0:
      discard posix.write(fd, s.cstring, s.len)
      discard posix.close(fd)

  let hPid = fork()
  if hPid < 0: quit(1)
  if hPid == 0:
    let gPid = fork()
    if gPid < 0: quit(1)
    if gPid == 0:
      # GRANDCHILD — never setpgid/setsid; keeps P's pgid throughout.
      # Sleeps long enough to outlive the peer's entire run+reap AND P's
      # own remaining lifetime, so P's own later reap is the one that
      # finds it alive.
      writeMarker("spawn_reparented_helper_g.pid", $getpid())
      for i in 1 .. 10: discard posix.sleep(1)
      quit(0)
    quit(0)   # H exits immediately — G reparents to crisol right away.

  # PARENT — reap H immediately (it exits fast, right after forking G): an
  # un-reaped H would sit as P's own zombie child until P itself exits,
  # then reparent to crisol as a SECOND (spurious) candidate alongside G —
  # not the case this fixture exists to exercise. Only G, the genuinely
  # orphaned, still-alive grandchild, should remain a candidate.
  var hStatus: cint
  discard waitpid(hPid, hStatus, 0)

  # Wait for the peer's own done marker before exiting, so this slot stays
  # registered/live across the peer's entire run+reap.
  var waitedMs = 0
  while not fileExists("spawn_reparented_helper_peer_done.pid") and waitedMs < 10_000:
    os.sleep(10)
    waitedMs += 10
  # A generous buffer past the peer's own marker: the peer's crisol-side
  # reap runs essentially synchronously with its own exit, well under this.
  os.sleep(500)
  quit(0)
else:
  echo "CRISOL-SKIP: tests/fixtures/spawn_reparented_helper.nim"
