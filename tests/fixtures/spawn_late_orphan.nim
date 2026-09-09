## spawn_late_orphan.nim — rfc-0007 B1b fixture: exercises BOTH
## `weOrphanReaped` destinations (§3) in a single process tree.
##
## Marker-file coordination: see spawn_grandchild.nim's header (crisol's run
## substrate passes no argv; markers are fixed names relative to the run
## child's cwd, which the calling test's scratch dir isolates). Timing
## between the two chains below is real wall-clock sleep, not marker
## handshakes — deliberately timing-sensitive; the calling test file
## (tests/timing/test_rfc0007_b1b_late_orphan.nim) is gated on
## CRISOL_TIMING_TESTS and run serially via `./dev timing`. This entrypoint
## is paired with a SECOND one (pass_after_delay.nim) purely to keep
## crisol's event loop alive long enough to observe chain 2's late death —
## see that fixture's own doc comment.
##
## Two independent descendant chains, both same-pgroup as P unless noted:
##
##   Chain 1 (G1 via H1) — "fold into a still-live slot's pending escapees":
##     P forks H1. H1 immediately forks G1, then H1 exits right away — G1
##     (still same-pgroup as P; never setpgid/setsid) reparents to crisol
##     within microseconds (H1 is not a subreaper, so the kernel skips
##     straight to crisol). G1 sleeps a SHORT beat (500ms) then exits ON
##     ITS OWN while P is still alive/registered (P sleeps 2000ms) —
##     crisol's async waitid(P_ALL, WNOWAIT) sweep discovers it, matches
##     its pgid against P's still-live domain pgid (ownedBy = some(P)),
##     and folds it into P's pending escapees (reaped well before P itself
##     exits).
##
##   Chain 2 (G2 via H2) — "run-level late orphan, owner already emitted":
##     P forks H2. H2 immediately forks G2, which calls setsid() (own new
##     pgroup) before sleeping a LONGER beat (2500ms) then exiting. H2
##     itself just sleeps far longer than P's own lifetime — it stays P's
##     live, same-pgroup child until P itself exits at 2000ms. When P
##     exits, crisol's B1a owning-slot scan finds H2 (same pgroup,
##     reparented) and kills+reaps it as P's own escapee — WHICH is what
##     orphans G2 (H2's child) onto crisol, mid-run, well after P's own
##     result has already been reaped and emitted. G2 (setsid — no pgid
##     matches any live slot once P is gone) is unattributable by
##     construction, and by the time it dies (2500ms) P is long gone: the
##     async sweep counts it at RUN level (lateOrphansReaped), never
##     retro-fitted into P's already-emitted result.
##
## P itself sleeps 2000ms then exits 0 — long enough for chain 1 to
## resolve while P is still live, short enough to keep the fixture's
## overall wall-clock bounded for a timing test.
import std/[os, posix]

proc writeMarker(path, s: string) =
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  if fd >= 0:
    discard posix.write(fd, s.cstring, s.len)
    discard posix.close(fd)

# ---------------------------------------------------------------------------
# Chain 1 — G1 via H1 (dies while P is still live).
# ---------------------------------------------------------------------------
let h1Pid = fork()
if h1Pid < 0: quit(1)
if h1Pid == 0:
  let g1Pid = fork()
  if g1Pid < 0: quit(1)
  if g1Pid == 0:
    writeMarker("spawn_late_orphan_g1.pid", $getpid())
    sleep(500)
    quit(0)
  quit(0)   # H1 exits immediately — G1 reparents to crisol right away.

# ---------------------------------------------------------------------------
# Chain 2 — G2 via H2 (setsid; dies well after P has already been reaped).
# ---------------------------------------------------------------------------
let h2Pid = fork()
if h2Pid < 0: quit(1)
if h2Pid == 0:
  let g2Pid = fork()
  if g2Pid < 0: quit(1)
  if g2Pid == 0:
    discard posix.setsid()
    writeMarker("spawn_late_orphan_g2.pid", $getpid())
    sleep(2500)
    quit(0)
  sleep(30_000)   # H2 outlives P; SIGKILLed by crisol's B1a mechanism at
                  # P's own reap, long before this would finish naturally.
  quit(0)

writeMarker("spawn_late_orphan.pid", $getpid())
sleep(2000)
quit(0)
