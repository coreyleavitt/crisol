## rss_oom.nim — rfc-0007 B3 fixture: allocates and TOUCHES real, resident
## RSS pages in small increments until killed.
##
## Contrast rlimit_as.nim (A4c): that fixture makes ONE large virtual
## reservation, so a tight RLIMIT_AS ceiling denies it at the mmap/alloc
## call itself (ENOMEM/OutOfMemDefect) before a single page is ever
## touched. This fixture instead commits memory a small chunk at a time and
## WRITES every page (forcing real physical residency, never a lazily-
## mapped no-op) — the shape needed to trigger a genuine cgroup-v2
## memory.max OOM kill (a REAL RSS ceiling, kernel-enforced via SIGKILL),
## which only the calling test's `ChildSpec.limits.req[lkMemory]` (never
## `lkAddressSpace`/RLIMIT_AS — a different, virtual-address-space-only
## mechanism this fixture is not testing) can trigger.
##
## Bounded to 512 MiB total / ~1s worst-case wall time so an environment
## where the ceiling never engages (no cgroup delegation; a control run)
## still exits promptly rather than consuming unbounded memory.
##
## Exit 0 with no kill = the ceiling never engaged (control case).
import std/os

const ChunkBytes = 1 * 1024 * 1024   # 1 MiB per chunk
const MaxChunks = 512                # 512 MiB safety cap (control case only)

var chunks: seq[seq[byte]] = @[]
for i in 0 ..< MaxChunks:
  var chunk = newSeq[byte](ChunkBytes)
  var off = 0
  while off < ChunkBytes:
    chunk[off] = byte(i and 0xff)   # force real physical residency per page
    off += 4096
  chunks.add chunk
  sleep(2)   # small pacing so a small ceiling's OOM kill lands well before
             # this loop could otherwise finish

quit(0)   # only reached if never killed (control case)
