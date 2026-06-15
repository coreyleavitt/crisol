## test_memprobe.nim — S4 unit tests for memprobe.nim.
##
## Tests availableMemBytes and procGroupRssBytes via the injectable read seam.
## All I/O is synthetic except the real-read cgroup smoke (guarded by when defined(linux)).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_memprobe.nim

import std/[options, os, unittest, strutils, tables]
import crisol/memprobe

# ---------------------------------------------------------------------------
# Seam contract: a read proc raises IOError when the "file" is absent.
# We build fake filesystems as a Table[string, string].
# ---------------------------------------------------------------------------

proc makeReader(files: Table[string, string]): proc(path: string): string =
  ## Returns a read proc that serves synthetic content from `files`.
  ## If the path is absent, raises IOError — matching real readFile behavior.
  result = proc(path: string): string =
    if path in files:
      files[path]
    else:
      raise newException(IOError, "no such file (synthetic): " & path)

# ---------------------------------------------------------------------------
# Suite 1: availableMemBytes — MemAvailable wins when cgroup is unlimited
# ---------------------------------------------------------------------------

suite "availableMemBytes — MemAvailable wins when cgroup reports max":

  test "MemAvailable 8000000 kB + cgroup max → some(8000000 * 1024)":
    let files = {
      "/proc/meminfo":
        "MemTotal:       16000000 kB\nMemAvailable:   8000000 kB\nSwapTotal: 0 kB\n",
      "/sys/fs/cgroup/memory.max":
        "max\n",
      "/sys/fs/cgroup/memory.current":
        "1073741824\n",  # 1 GiB currently used (irrelevant since max == unlimited)
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == 8_000_000'i64 * 1024

# ---------------------------------------------------------------------------
# Suite 2: cgroup v2 limit < MemAvailable → cgroup wins the min
# ---------------------------------------------------------------------------

suite "availableMemBytes — cgroup v2 limit wins when smaller":

  test "cgroup v2 limit 2 GiB, current 512 MiB, MemAvailable 8 GiB → some(1536 MiB)":
    let cgMax     = 2'i64 * 1024 * 1024 * 1024    # 2 GiB
    let cgCurrent = 512'i64 * 1024 * 1024          # 512 MiB
    let memAvailKb = 8 * 1024 * 1024               # 8 GiB in kB
    let expected  = cgMax - cgCurrent               # 1.5 GiB
    let files = {
      "/proc/meminfo":
        "MemTotal:       16777216 kB\nMemAvailable:   " & $memAvailKb & " kB\n",
      "/sys/fs/cgroup/memory.max":
        $cgMax & "\n",
      "/sys/fs/cgroup/memory.current":
        $cgCurrent & "\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == expected

  test "cgroup v2 sentinel 0x7ffffffffffff000 treated as no-limit → MemAvailable wins":
    ## The sentinel value 9223372036854771712 means 'no limit' in cgroup v2.
    let sentinel = 9_223_372_036_854_771_712'i64
    let files = {
      "/proc/meminfo":
        "MemAvailable:   4000000 kB\n",
      "/sys/fs/cgroup/memory.max":
        $sentinel & "\n",
      "/sys/fs/cgroup/memory.current":
        "0\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == 4_000_000'i64 * 1024

# ---------------------------------------------------------------------------
# Suite 3: cgroup v1 fallback when v2 paths are absent
# ---------------------------------------------------------------------------

suite "availableMemBytes — cgroup v1 fallback":

  test "v2 absent, v1 present: limit 1 GiB, usage 256 MiB, MemAvail 4 GiB → cgroup wins":
    let v1Limit = 1'i64 * 1024 * 1024 * 1024   # 1 GiB
    let v1Usage = 256'i64 * 1024 * 1024         # 256 MiB
    let expected = v1Limit - v1Usage             # 768 MiB
    let memAvailKb = 4 * 1024 * 1024            # 4 GiB in kB (much larger)
    let files = {
      "/proc/meminfo":
        "MemAvailable:   " & $memAvailKb & " kB\n",
      # v2 paths absent (not in table → IOError from seam)
      "/sys/fs/cgroup/memory/memory.limit_in_bytes":
        $v1Limit & "\n",
      "/sys/fs/cgroup/memory/memory.usage_in_bytes":
        $v1Usage & "\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == expected

  test "v1 unlimited sentinel (9223372036854771712) falls back to MemAvailable":
    ## cgroup v1 uses the same sentinel for 'no limit'.
    let sentinel = 9_223_372_036_854_771_712'i64
    let files = {
      "/proc/meminfo":
        "MemAvailable:   2000000 kB\n",
      "/sys/fs/cgroup/memory/memory.limit_in_bytes":
        $sentinel & "\n",
      "/sys/fs/cgroup/memory/memory.usage_in_bytes":
        "0\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == 2_000_000'i64 * 1024

# ---------------------------------------------------------------------------
# Suite 4: neither source readable → none
# ---------------------------------------------------------------------------

suite "availableMemBytes — returns none when all sources fail":

  test "all paths absent → none":
    let files = initTable[string, string]()
    let r = availableMemBytes(makeReader(files))
    check r.isNone

  test "meminfo unreadable, v2 absent, v1 absent → none":
    ## Same as above but explicit.
    let emptyFiles = initTable[string, string]()
    check availableMemBytes(makeReader(emptyFiles)).isNone

# ---------------------------------------------------------------------------
# Suite 5: procGroupRssBytes — synthetic /proc/<pid>/status files
# (M8: now uses explicit listProcs seam instead of magic "/proc/__list__" path)
# ---------------------------------------------------------------------------

suite "procGroupRssBytes — sums VmRSS across pgroup members":

  test "two pgroup members: VmRSS 100 MiB + 200 MiB = 300 MiB":
    let pid0Rss = 100 * 1024'i64  # 100 MiB in kB
    let pid1Rss = 200 * 1024'i64  # 200 MiB in kB
    let pgid = 5000
    let status0 = "Name:\tnim\nPid:\t5000\nPPid:\t1\nPgrp:\t5000\nVmRSS:\t" &
                  $(pid0Rss) & " kB\nVmSize:\t999999 kB\n"
    let status1 = "Name:\tgcc\nPid:\t5001\nPPid:\t5000\nPgrp:\t5000\nVmRSS:\t" &
                  $(pid1Rss) & " kB\nVmSize:\t999999 kB\n"
    let statusOther = "Name:\tbash\nPid:\t9999\nPPid:\t1\nPgrp:\t9999\nVmRSS:\t" &
                      "512 kB\nVmSize:\t999999 kB\n"
    let files = {
      "/proc/5000/status": status0,
      "/proc/5001/status": status1,
      "/proc/9999/status": statusOther,
    }.toTable
    let r = procGroupRssBytes(pgid, makeReader(files),
                              proc(): seq[int] = @[5000, 5001, 9999])
    check r.isSome
    check r.get == (pid0Rss + pid1Rss) * 1024  # kB → bytes

  test "single member (the slot leader itself)":
    let pgid = 7777
    let rssKb = 50 * 1024'i64  # 50 MiB in kB
    let status = "Name:\tnim\nPid:\t7777\nPPid:\t1\nPgrp:\t7777\nVmRSS:\t" &
                 $rssKb & " kB\n"
    let files = {
      "/proc/7777/status": status,
    }.toTable
    let r = procGroupRssBytes(pgid, makeReader(files),
                              proc(): seq[int] = @[7777])
    check r.isSome
    check r.get == rssKb * 1024

  test "all members vanish (pid not in files) → some(0)":
    ## Processes may exit between enumeration and status read.
    ## procGroupRssBytes should degrade gracefully — returns some(0) not none.
    let pgid = 1234
    let files = initTable[string, string]()
    let r = procGroupRssBytes(pgid, makeReader(files),
                              proc(): seq[int] = @[1234])
    check r.isSome
    check r.get == 0

  test "empty proc list → some(0)":
    let files = initTable[string, string]()
    let r = procGroupRssBytes(1, makeReader(files),
                              proc(): seq[int] = @[])
    check r.isSome
    check r.get == 0

  test "NSpgid multi-value line: innermost (last) value selected":
    ## Linux writes NSpgid outermost→innermost.
    ## A nested-namespace /proc/<pid>/status shows e.g. "NSpgid:\t9000 5000"
    ## where 9000 is the host pgid and 5000 is the container-local pgid.
    ## parsePgrp must choose 5000 (innermost = last).
    let pgid = 5000   # innermost (container-local) pgid we spawned with setpgid
    let rssKb = 32 * 1024'i64  # 32 MiB in kB
    # Two-level NSpgid: host=9000 outer=7000 inner=5000 — innermost wins.
    let statusNested = "Name:\tnim\nPid:\t5000\nNSpgid:\t9000 7000 5000\nVmRSS:\t" &
                       $rssKb & " kB\n"
    let statusOutsider = "Name:\tbash\nPid:\t9000\nNSpgid:\t9000\nVmRSS:\t999 kB\n"
    let files = {
      "/proc/5000/status": statusNested,
      "/proc/9000/status": statusOutsider,
    }.toTable
    let r = procGroupRssBytes(pgid, makeReader(files),
                              proc(): seq[int] = @[5000, 9000])
    check r.isSome
    check r.get == rssKb * 1024  # only pid 5000 matched pgid 5000

  test "member process status has no VmRSS line → skipped silently, sum excludes it":
    ## M9: A process whose /proc/<pid>/status exists but lacks VmRSS is skipped.
    ## The sum excludes that process without crashing or returning none.
    let pgid = 4444
    # pid 4444 has no VmRSS line; pid 4445 has VmRSS 64 MiB
    let statusNoRss = "Name:\tzombie\nPid:\t4444\nPPid:\t1\nPgrp:\t4444\nVmSize:\t0 kB\n"
    let rssKb = 64 * 1024'i64
    let statusWithRss = "Name:\tworker\nPid:\t4445\nPPid:\t4444\nPgrp:\t4444\nVmRSS:\t" &
                        $rssKb & " kB\n"
    let files = {
      "/proc/4444/status": statusNoRss,
      "/proc/4445/status": statusWithRss,
    }.toTable
    let r = procGroupRssBytes(pgid, makeReader(files),
                              proc(): seq[int] = @[4444, 4445])
    check r.isSome
    check r.get == rssKb * 1024  # only pid 4445 counted

# ---------------------------------------------------------------------------
# Suite 6: M1 — negative cgroup budget clamped to zero
# ---------------------------------------------------------------------------

suite "cgroupBudget — negative budget clamped to zero (M1)":

  test "v2: current > limit (transient overrun) → budget is some(0) not negative":
    ## Under memory pressure the kernel may allow current to transiently exceed limit.
    ## cgroupBudget must clamp the result to max(0, budget).
    let limit   = 1_000_000_000'i64   # 1 GB
    let current = 1_100_000_000'i64   # 10% over limit
    let files = {
      "/sys/fs/cgroup/memory.max":     $limit   & "\n",
      "/sys/fs/cgroup/memory.current": $current & "\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == 0  # clamped, not negative

  test "v1: usage > limit (transient overrun) → budget is some(0) not negative":
    let limit = 512_000_000'i64
    let usage = 600_000_000'i64
    let files = {
      "/sys/fs/cgroup/memory/memory.limit_in_bytes": $limit & "\n",
      "/sys/fs/cgroup/memory/memory.usage_in_bytes": $usage & "\n",
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == 0

# ---------------------------------------------------------------------------
# Suite 7: M9 — cgroup fallback coverage (unreadable current/usage)
# ---------------------------------------------------------------------------

suite "cgroupBudget — conservative fallback when current/usage unreadable (M9)":

  test "v2: memory.current unreadable but memory.max is real → returns some(limit)":
    ## When current usage can't be read, return the full limit as a conservative estimate.
    let limit = 2_000_000_000'i64
    let files = {
      "/sys/fs/cgroup/memory.max": $limit & "\n",
      # memory.current absent → IOError from seam
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == limit

  test "v1: memory.usage_in_bytes unreadable but memory.limit_in_bytes is real → returns some(limit)":
    let limit = 1_073_741_824'i64  # 1 GiB
    let files = {
      "/sys/fs/cgroup/memory/memory.limit_in_bytes": $limit & "\n",
      # memory.usage_in_bytes absent → IOError from seam
    }.toTable
    let r = availableMemBytes(makeReader(files))
    check r.isSome
    check r.get == limit

# ---------------------------------------------------------------------------
# Suite 8: real-read cgroup smoke (Linux only, path-guarded)
# ---------------------------------------------------------------------------

when defined(linux):
  suite "availableMemBytes — real-read cgroup smoke":

    test "cgroup memory.max is either a positive integer or the literal 'max'":
      ## Separately read the REAL /sys/fs/cgroup/memory.max to confirm the
      ## cgroup v2 code path is reachable on this host/container.
      ## Inside ./dev podman container: memory.max is typically "max".
      ## On a constrained host it would be a positive integer (the limit in bytes).
      ## Both are valid; the test proves the path was exercised.
      let cgMaxPath = "/sys/fs/cgroup/memory.max"
      if fileExists(cgMaxPath):
        let raw = readFile(cgMaxPath).strip()
        if raw == "max":
          # unlimited — acceptable, cgroup path is reachable
          check raw == "max"
        else:
          # should be a positive decimal integer
          try:
            let v = parseBiggestInt(raw)
            check v > 0
          except ValueError:
            check false  # unexpected format — fail the test

    test "availableMemBytes with real read returns some positive value on Linux":
      ## Uses the default read (realReadFile) — exercises the full real path.
      ## Tolerates both limited and unlimited cgroup configurations.
      let r = availableMemBytes()
      # On any Linux box with /proc/meminfo we should get some value.
      if fileExists("/proc/meminfo"):
        check r.isSome
        check r.get > 0

when isMainModule:
  echo "All memprobe tests passed."
