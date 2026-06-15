## memprobe.nim — memory availability probe (B1, S4).
##
## Effectful I/O, Linux-oriented.  All file reads go through an injectable
## `read` proc seam so unit tests can supply synthetic file contents without
## touching the real filesystem.
##
## Seam contract
## -------------
## The `read` proc has the same signature and behaviour as `readFile`:
##   - On success: returns the file's full contents as a string.
##   - On failure (file absent, unreadable, etc.): RAISES `IOError`.
## Callers catch `IOError` (and `Exception` for defense-in-depth) and treat
## the raised path as "source unavailable".
##
## Public API
## ----------
##   availableMemBytes*(read = realReadFile): Option[int64]
##     Returns the available memory budget in bytes as the MIN of:
##       (a) MemAvailable from /proc/meminfo (kB → bytes), and
##       (b) cgroup limit − current usage:
##             cgroup v2: /sys/fs/cgroup/memory.max & memory.current
##             cgroup v1: /sys/fs/cgroup/memory/memory.limit_in_bytes
##                        & .../memory.usage_in_bytes
##     "No limit" is the literal string "max" OR the sentinel value
##     9223372036854771712 (0x7ffffffffffff000) — either case contributes
##     nothing to the min (only real limits are considered).
##     Returns none only if NEITHER /proc/meminfo NOR any cgroup source
##     is readable.
##     Never raises.
##
##   procGroupRssBytes*(pid: int, read = realReadFile,
##                      listProcs: proc(): seq[int] = nil): Option[int64]
##     Sums VmRSS (in bytes) over all processes whose Pgrp matches `pid`
##     (i.e. the slot's process group, set via setpgid(0,0) in spawn.nim).
##     When `listProcs` is non-nil (unit tests), it is called to supply the
##     list of pids to inspect; when nil, /proc is walked on the real filesystem.
##     Never raises; returns some(0) for an empty or fully-vanished pgroup.
##
## Cgroup v2 paths (preferred):
##   /sys/fs/cgroup/memory.max
##   /sys/fs/cgroup/memory.current
##
## Cgroup v1 paths (fallback when v2 absent):
##   /sys/fs/cgroup/memory/memory.limit_in_bytes
##   /sys/fs/cgroup/memory/memory.usage_in_bytes

import std/[options, os, strutils]

# ---------------------------------------------------------------------------
# realReadFile — default seam (wraps std readFile)
# ---------------------------------------------------------------------------

proc realReadFile*(path: string): string =
  ## Thin wrapper around readFile; raises IOError on failure (matches seam contract).
  readFile(path)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  CgroupV2Max*     = "/sys/fs/cgroup/memory.max"
  CgroupV2Current* = "/sys/fs/cgroup/memory.current"
  CgroupV1Limit*   = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
  CgroupV1Usage*   = "/sys/fs/cgroup/memory/memory.usage_in_bytes"
  MemInfoPath*     = "/proc/meminfo"

  ## cgroup v2 (and v1) sentinel meaning "no limit".
  ## = 0x7ffffffffffff000 = page-rounded max for 64-bit Linux.
  CgroupNoLimitSentinel*: int64 = 9_223_372_036_854_771_712'i64

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc parseMemAvailKb(content: string): Option[int64] =
  ## Parse the MemAvailable line from /proc/meminfo content.
  ## Returns the value in kibibytes, or none on parse failure.
  for line in content.splitLines():
    if line.startsWith("MemAvailable:"):
      let parts = line.splitWhitespace()
      # Expected format: "MemAvailable:   N kB"
      # splitWhitespace collapses runs of whitespace, giving
      #   ["MemAvailable:", "N", "kB"]
      if parts.len >= 2:
        try:
          let kb = parseBiggestInt(parts[1])
          return some(int64(kb))
        except ValueError:
          return none(int64)
  none(int64)

proc isNoLimit(value: int64): bool =
  ## True when the cgroup value represents "unlimited".
  value == CgroupNoLimitSentinel

proc readInt64(path: string; read: proc(p: string): string): Option[int64] =
  ## Read a file via the seam and parse its content as int64.
  ## Returns none on IOError or parse failure.
  try:
    let raw = read(path).strip()
    if raw == "max":
      return none(int64)  # literal "max" → no limit → none
    let v = parseBiggestInt(raw)
    return some(int64(v))
  except CatchableError:
    return none(int64)

proc cgroupBudget(read: proc(p: string): string): Option[int64] =
  ## Compute (limit − current) from cgroup v2, falling back to v1.
  ## Budget is clamped to max(0, budget) to handle transient kernel overruns.
  ## Returns none when no cgroup path yields a real limit.

  # --- Try cgroup v2 first ---
  # We need to distinguish "file absent" (v2 not present, fall through to v1)
  # from "file present but value is sentinel/max" (v2 present but unlimited).
  # Read memory.max exactly once; catch IOError to detect file absence.
  try:
    let raw = read(CgroupV2Max).strip()
    # v2 file is present.
    if raw == "max":
      # v2 present but unlimited — no cgroup constraint; skip v1, return none.
      return none(int64)
    let limitVal = parseBiggestInt(raw)
    let limit = int64(limitVal)
    if isNoLimit(limit):
      return none(int64)
    # Limit is real — read current usage.
    let currentOpt = readInt64(CgroupV2Current, read)
    if currentOpt.isSome:
      let budget = limit - currentOpt.get
      return some(max(0'i64, budget))
    else:
      # Current unreadable but limit is known; return limit as conservative budget.
      return some(limit)
  except CatchableError:
    discard  # v2 absent or unreadable — fall through to v1

  # --- Fallback: cgroup v1 ---
  try:
    let raw = read(CgroupV1Limit).strip()
    if raw == "max":
      return none(int64)
    let limitVal = parseBiggestInt(raw)
    let limit = int64(limitVal)
    if isNoLimit(limit):
      return none(int64)
    let usageOpt = readInt64(CgroupV1Usage, read)
    if usageOpt.isSome:
      return some(max(0'i64, limit - usageOpt.get))
    else:
      return some(limit)
  except CatchableError:
    return none(int64)

# ---------------------------------------------------------------------------
# availableMemBytes
# ---------------------------------------------------------------------------

proc availableMemBytes*(read: proc(path: string): string = realReadFile): Option[int64] =
  ## Returns the available memory budget in bytes.
  ## Result is min(MemAvailable, cgroupBudget) across the readable sources.
  ## Returns none only when neither /proc/meminfo nor any cgroup path is readable.
  ## Never raises.

  var memAvailBytes: Option[int64] = none(int64)
  var cgroupBytes:   Option[int64] = none(int64)

  # --- (a) /proc/meminfo ---
  try:
    let content = read(MemInfoPath)
    let kbOpt = parseMemAvailKb(content)
    if kbOpt.isSome:
      memAvailBytes = some(kbOpt.get * 1024'i64)
  except CatchableError:
    discard

  # --- (b) cgroup budget ---
  try:
    cgroupBytes = cgroupBudget(read)
  except CatchableError:
    discard

  # Return the minimum of the two sources.
  if memAvailBytes.isNone and cgroupBytes.isNone:
    return none(int64)
  elif memAvailBytes.isNone:
    return cgroupBytes
  elif cgroupBytes.isNone:
    return memAvailBytes
  else:
    return some(min(memAvailBytes.get, cgroupBytes.get))

# ---------------------------------------------------------------------------
# procGroupRssBytes
# ---------------------------------------------------------------------------

proc parseVmRssKb(content: string): Option[int64] =
  ## Extract VmRSS in kB from /proc/<pid>/status content.
  ## /proc/<pid>/status uses tab separators; splitWhitespace handles
  ## both tabs and multiple spaces robustly.
  for line in content.splitLines():
    if line.startsWith("VmRSS:"):
      let parts = line.splitWhitespace()
      # Format: "VmRSS:\tN kB"  → ["VmRSS:", "N", "kB"]
      if parts.len >= 2:
        try:
          return some(int64(parseBiggestInt(parts[1])))
        except ValueError:
          return none(int64)
  none(int64)

proc parsePgrp(content: string): int =
  ## Extract Pgrp (or NSpgid, the namespace-local equivalent) from
  ## /proc/<pid>/status content.  Returns -1 on failure.
  ##
  ## Kernel note: in a PID namespace (e.g. inside a Docker/Podman container),
  ## /proc/<pid>/status shows namespace-relative IDs under keys like NSpgid,
  ## NSpid, NStgid — NOT the global Pgrp field.  We look for both forms so
  ## that procGroupRssBytes works correctly both on bare Linux and inside
  ## containers.  If both exist, the FIRST match wins (Pgrp is typically
  ## listed first in older kernels, NSpgid first in namespace-aware kernels).
  ##
  ## NSpgid ordering: the kernel writes values outermost→innermost (host pgid
  ## first, innermost namespace pgid last).  We want the INNERMOST (last) value
  ## because that is the pgid visible within our container.  For single-level
  ## containers (only one value) parts[^1] == parts[1], so this is correct in
  ## both the single-level and nested cases.
  for line in content.splitLines():
    if line.startsWith("Pgrp:") or line.startsWith("NSpgid:"):
      let parts = line.splitWhitespace()
      # Format: "Pgrp:\tN"        → ["Pgrp:", "N"]
      # Format: "NSpgid:\tN M ..."→ ["NSpgid:", "outermost", ..., "innermost"]
      # Use parts[^1] (last = innermost namespace value).
      if parts.len >= 2:
        try:
          return parseInt(parts[^1])
        except ValueError:
          return -1
  -1

proc procGroupRssBytes*(pid: int;
                        read: proc(path: string): string = realReadFile;
                        listProcs: proc(): seq[int] = nil): Option[int64] =
  ## Sum VmRSS (bytes) over all processes in the process group with pgid == pid.
  ##
  ## Enumeration strategy:
  ##   1. If `listProcs` is non-nil (unit-test seam), call it to get the pid list.
  ##   2. Otherwise, walk /proc/<n>/status on the real filesystem using walkDir.
  ##
  ## Processes may vanish between enumeration and status read — IOError is caught
  ## and the process is simply skipped.
  ##
  ## Returns some(sum) — even some(0) for an empty or fully-vanished pgroup.
  ## Never raises.

  var totalRssBytes: int64 = 0

  # --- Determine pid list ---
  var pids: seq[int] = @[]

  if listProcs != nil:
    # Unit-test seam: caller supplies the pid list directly.
    pids = listProcs()
  else:
    # Real filesystem: walk /proc looking for numeric directories.
    try:
      for entry in walkDir("/proc"):
        if entry.kind == pcDir:
          let name = entry.path.extractFilename
          try:
            pids.add parseInt(name)
          except ValueError:
            discard  # skip non-numeric entries (e.g. "self", "sys", etc.)
    except CatchableError:
      return some(0'i64)  # /proc unreadable — safe degradation

  # --- Sum VmRSS for pgroup members ---
  for p in pids:
    try:
      let statusPath = "/proc/" & $p & "/status"
      let content = read(statusPath)
      let pgrp = parsePgrp(content)
      if pgrp == pid:
        let rssKbOpt = parseVmRssKb(content)
        if rssKbOpt.isSome:
          totalRssBytes += rssKbOpt.get * 1024'i64  # kB → bytes
        # If rssKbOpt is none (no VmRSS line), skip this process silently.
    except CatchableError:
      discard  # process vanished or read error — skip it

  some(totalRssBytes)
