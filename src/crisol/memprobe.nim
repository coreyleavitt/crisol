## memprobe.nim — memory availability probe (B1, S4).
##
## Effectful I/O, Linux-oriented.  All file reads go through an injectable
## `read` proc seam so unit tests can supply synthetic file contents without
## touching the real filesystem.  On Windows, `availableMemBytes` bypasses
## this seam entirely — there is no /proc or cgroup there — and instead
## queries `GlobalMemoryStatusEx` directly for the live available-physical-
## memory figure (see the `when defined(windows)` branch below).
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
# Windows FFI — GlobalMemoryStatusEx
# ---------------------------------------------------------------------------
#
# rfc-0007 D2a-3: Windows has no /proc or cgroup — the injectable `read` seam
# above is a Linux construct. MEMORYSTATUSEX's layout MUST match the Win32
# struct exactly (two DWORDs, then seven DWORDLONGs, in this order) or
# ullAvailPhys reads garbage; dwLength must be set to sizeof(MEMORYSTATUSEX)
# before the call or GlobalMemoryStatusEx fails.
when defined(windows):
  type MEMORYSTATUSEX = object
    dwLength: uint32
    dwMemoryLoad: uint32
    ullTotalPhys: uint64
    ullAvailPhys: uint64
    ullTotalPageFile: uint64
    ullAvailPageFile: uint64
    ullTotalVirtual: uint64
    ullAvailVirtual: uint64
    ullAvailExtendedVirtual: uint64
  proc globalMemoryStatusEx(buffer: ptr MEMORYSTATUSEX): int32
    {.stdcall, dynlib: "kernel32", importc: "GlobalMemoryStatusEx".}

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

proc parseOwnCgroupV2Path*(content: string): string =
  ## rfc-0007 code-review r50: pure parse of /proc/self/cgroup's unified
  ## (v2) line ("0::<path>") — the same slicing
  ## `process/cgroup.ownCgroupV2Path` does against the real filesystem, but
  ## seam-testable here against injected content (mirrors this module's own
  ## `read`-seam convention rather than importing that Linux-only module,
  ## which would tie memprobe's cross-platform build to a `when
  ## defined(linux)` re-export just for one string parse). Returns "" when
  ## no "0::" line is present (unreadable file, or a genuinely non-cgroup-v2
  ## host) — `cgroupV2MinAlongPath` below treats that identically to "at
  ## the cgroupfs root", which degrades to exactly the pre-r50 root-only
  ## read.
  for line in content.splitLines():
    if line.startsWith("0::"):
      return line[3 .. ^1]
  ""

proc cgroupV2AncestorChain*(ownPath: string): seq[string] =
  ## rfc-0007 code-review r50: pure — the process's own cgroup-v2 leaf
  ## directory, then each ancestor up to (and including) the cgroupfs
  ## root, most-specific first. `ownPath == ""` (root, or unresolved)
  ## degenerates to the single-element `@["/sys/fs/cgroup"]` chain, i.e.
  ## the exact pre-r50 root-only behaviour.
  result = @[]
  let normalized = if ownPath == "/": "" else: ownPath
  var cur = "/sys/fs/cgroup" & normalized
  while true:
    result.add cur
    if cur == "/sys/fs/cgroup": break
    let p = cur.parentDir
    if p.len == 0 or not (p == "/sys/fs/cgroup" or p.startsWith("/sys/fs/cgroup/")):
      break   # defensive: never climb above the cgroupfs root
    cur = p

proc cgroupV2MinAlongPath(read: proc(p: string): string):
    tuple[limit: Option[int64], present: bool, ownDir: string] =
  ## rfc-0007 code-review r50: `cgroupBudget`'s old v2 arm read the
  ## cgroupfs ROOT `memory.max` only — a systemd-slice `MemoryMax` set on
  ## an ANCESTOR between the process's own leaf and the root (the common
  ## delegated/systemd-managed case) is invisible to a root-only read, even
  ## though `ownCgroupV2Path` (process/cgroup.nim) already existed to
  ## resolve exactly the path needed to see it — just never wired to this
  ## admission-facing probe. Resolves the process's own leaf via
  ## /proc/self/cgroup, walks the chain from there up to the root, and
  ## takes the MINIMUM real (non-"max"/non-sentinel) `memory.max` seen
  ## along the way — "max" at any one level means only THAT level is
  ## unlimited, not the whole chain. `present` tracks whether ANY level's
  ## `memory.max` was readable at all, so the caller can still distinguish
  ## "v2 active but unlimited everywhere" (present, limit none — never
  ## fall through to v1) from "v2 not mounted at all" (not present — fall
  ## through to v1), exactly the distinction the old root-only code made
  ## with a single read. `ownDir` is the chain's own (most-specific) entry
  ## — the caller reads `memory.current` there, not at an ancestor or the
  ## root, since usage must be measured at the process's own residency.
  var ownPath = ""
  try:
    ownPath = parseOwnCgroupV2Path(read("/proc/self/cgroup"))
  except CatchableError:
    discard   # unreadable (non-Linux, or genuinely absent) — ownPath stays
              # "", and the chain below degrades to the root-only read.
  let chain = cgroupV2AncestorChain(ownPath)
  var minLimit = none(int64)
  var present = false
  for dir in chain:
    try:
      let raw = read(dir / "memory.max").strip()
      present = true   # this level's memory.max file exists — v2 is active
      if raw == "max": continue
      let v = int64(parseBiggestInt(raw))
      if isNoLimit(v): continue
      if minLimit.isNone or v < minLimit.get:
        minLimit = some(v)
    except CatchableError:
      discard   # this level's file absent/unreadable — skip it, not proof
                # v2 is absent overall (an ancestor further up may still
                # be readable)
  (limit: minLimit, present: present, ownDir: chain[0])

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
  # rfc-0007 code-review r50: `cgroupV2MinAlongPath` resolves the process's
  # OWN cgroup-v2 leaf (via /proc/self/cgroup) and walks UP to the root,
  # taking the MINIMUM real memory.max along the chain — a systemd-slice
  # MemoryMax set on an ancestor is now visible, not just a root-level
  # limit. When own-path resolution fails (non-Linux, unreadable, or
  # genuinely at the root) the chain degenerates to the single-element
  # root-only read, i.e. the exact pre-r50 behaviour — no separate
  # fallback branch needed. `present` preserves the original "file absent
  # → fall through to v1" vs. "file present but unlimited → stop, no v1"
  # distinction the old single-read code made.
  try:
    let v2 = cgroupV2MinAlongPath(read)
    if v2.present:
      if v2.limit.isNone:
        # v2 active, but every level walked reported "max"/sentinel —
        # no cgroup constraint anywhere in the chain; skip v1, return none.
        return none(int64)
      let limit = v2.limit.get
      # Limit is real — read current usage at the process's OWN leaf (not
      # an ancestor, not the root): usage must be measured where this
      # process actually resides.
      let currentOpt = readInt64(v2.ownDir / "memory.current", read)
      if currentOpt.isSome:
        return some(max(0'i64, limit - currentOpt.get))
      else:
        # Current unreadable but limit is known; return limit as conservative budget.
        return some(limit)
    # v2.present == false: memory.max was unreadable at EVERY level in the
    # chain (most commonly: v2 not mounted at all) — fall through to v1.
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
  when defined(windows):
    ## Windows has no /proc or cgroup — the injectable `read` seam is a
    ## Linux construct; go straight to GlobalMemoryStatusEx.ullAvailPhys
    ## (the live available-physical-RAM figure admission needs). `read` is
    ## unused here by construction (documented), kept only for signature
    ## parity with the Linux/POSIX branch.
    var msx: MEMORYSTATUSEX
    msx.dwLength = uint32(sizeof(MEMORYSTATUSEX))
    if globalMemoryStatusEx(addr msx) != 0'i32:
      return some(int64(msx.ullAvailPhys))
    return none(int64)
  else:
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
