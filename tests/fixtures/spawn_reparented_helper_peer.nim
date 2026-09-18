## spawn_reparented_helper_peer.nim — rfc-0007 code-review r2 regression
## fixture: the FAST peer entrypoint run concurrently alongside
## spawn_reparented_helper.nim (jobs=2, shared scratch dir).
##
## First waits for the OTHER slot's grandchild-alive marker (written by
## spawn_reparented_helper.nim's G, once it has reparented to crisol and
## is genuinely visible in /proc) — a causal wait, not a sleep race,
## guaranteeing THIS slot's reap-phase `discoverAndReapEscapees` scan runs
## strictly AFTER G exists as a live, reparented candidate. Without this
## wait the two slots' independent compile times could let this fast slot
## finish (and get reaped) before G is even forked, which would pass
## vacuously on BOTH the buggy and the fixed code — never exercising the
## race r2 is about. Then writes its own "done" marker (the signal
## spawn_reparented_helper.nim's P waits on before exiting) and exits.
when defined(posix):
  import std/[os, posix]

  proc writeMarker(path, s: string) =
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    if fd >= 0:
      discard posix.write(fd, s.cstring, s.len)
      discard posix.close(fd)

  var waitedMs = 0
  while not fileExists("spawn_reparented_helper_g.pid") and waitedMs < 10_000:
    os.sleep(10)
    waitedMs += 10

  writeMarker("spawn_reparented_helper_peer_done.pid", $getpid())
  quit(0)
else:
  echo "CRISOL-SKIP: tests/fixtures/spawn_reparented_helper_peer.nim"
