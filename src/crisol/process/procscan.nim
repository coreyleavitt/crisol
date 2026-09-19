## process/procscan.nim — rfc-0007 §3/§7 the process-table scan, split out
## of posixcore.nim (code-review finding r27): the ONE shared source both
## the pgid-only tier (`scanProcessGroup`, pre-B1) and B1's subreaper-tier
## escapee/orphan discovery (`posixcore.discoverAndReapEscapees`/
## `sweepAdoptedOrphan`) fold over, so the two never drift onto separate
## readings of the same instant. Per-OS: `/proc` on Linux and every other
## posix backend this file feeds (`process/posix.nim`'s generic arm), the
## `libproc` equivalent on macOS (rfc-0007 C1b — Darwin has no `/proc` at
## all).
##
## Narrow interface: `ProcStatInfo`/`walkProcTable` (raw per-pid yield),
## `parseStatLine` (the `/proc/<pid>/stat` field-splitter, also reused
## directly by `process/cgroup.nim`'s `cgroupLeafSurvivors` and by
## posixcore's own orphan-attribution reads), `readVmRssBytes` (per-pid RSS,
## same per-OS split), and `scanProcessGroup` (the pgid-filtered fold over
## `walkProcTable`, producing `ProcSnapshot` — the wire type every kill/reap
## forensics call site ultimately returns). Nothing here reaches into
## `PosixCore` or `Capabilities` — a pure scan of whatever `/proc`(-like)
## state the OS exposes right now.

import std/[os, posix, strutils]
import crisol/process/types

type
  ProcStatInfo* = object
    ## One /proc walk's raw yield per live pid.
    pid*, ppid*, pgrp*: int
    comm*: string
    starttime*: int64

proc parseStatLine*(content: string): tuple[ppid, pgrp: int; comm: string; starttime: int64] =
  ## /proc/<pid>/stat: "pid (comm) state ppid pgrp ... starttime ...". comm
  ## may itself contain spaces/parens, so split on the LAST ')' (same
  ## technique test_pgroup.nim already uses for the same reason). Exported
  ## (rfc-0007 B1) so its field-counting is unit-testable directly — see
  ## tests/unit/test_rfc0007_b1_stat_parsing.nim.
  ##
  ## Field numbering (man proc(5), 1-indexed): 1 pid, 2 comm, 3 state,
  ## 4 ppid, 5 pgrp, ..., 22 starttime. The post-')' remainder's tokens
  ## start at field 3 (state), so token index `k` is field `3 + k`;
  ## starttime (field 22) is token index 19 — the 20th token after comm.
  let openIdx = content.find('(')
  let closeIdx = content.rfind(')')
  let comm = if openIdx >= 0 and closeIdx > openIdx: content[openIdx + 1 ..< closeIdx]
             else: ""
  var ppid = -1
  var pgrp = -1
  var starttime = int64(-1)
  if closeIdx >= 0 and closeIdx + 2 < content.len:
    let rest = content[closeIdx + 2 .. ^1]
    let parts = rest.splitWhitespace()
    if parts.len >= 3:
      try: ppid = parseInt(parts[1])
      except ValueError: discard
      try: pgrp = parseInt(parts[2])
      except ValueError: discard
    if parts.len >= 20:
      try: starttime = parseBiggestInt(parts[19])
      except ValueError: discard
  (ppid, pgrp, comm, starttime)

when defined(macosx):
  # rfc-0007 C1b: macOS has no `/proc` at all — `libproc` is the equivalent
  # for both the per-pid RSS read (readVmRssBytes) and the full-table walk
  # (walkProcTable) below. No stdlib wrapper exists, so `proc_listallpids`/
  # `proc_pidinfo` and the two payload types are importc'd directly against
  # the real macOS headers (named fields only — robust against padding/
  # field-order; the C compiler lays the struct out).
  proc proc_listallpids(buffer: pointer; buffersize: cint): cint
    {.importc: "proc_listallpids", header: "<libproc.h>".}
  proc proc_pidinfo(pid: cint; flavor: cint; arg: uint64; buffer: pointer;
                     buffersize: cint): cint
    {.importc: "proc_pidinfo", header: "<libproc.h>".}

  type
    ProcBsdInfo {.importc: "struct proc_bsdinfo", header: "<sys/proc_info.h>",
                  incompleteStruct, pure.} = object
      pbi_ppid {.importc: "pbi_ppid".}: uint32
      pbi_pgid {.importc: "pbi_pgid".}: uint32
      pbi_comm {.importc: "pbi_comm".}: array[16, char]  # MAXCOMLEN+1; may
                                                          # truncate — fine
                                                          # for forensics
      pbi_start_tvsec {.importc: "pbi_start_tvsec".}: uint64
    ProcTaskInfo {.importc: "struct proc_taskinfo", header: "<sys/proc_info.h>",
                   incompleteStruct, pure.} = object
      pti_resident_size {.importc: "pti_resident_size".}: uint64

  const
    PROC_PIDTBSDINFO = 3.cint   # -> ProcBsdInfo
    PROC_PIDTASKINFO = 4.cint   # -> ProcTaskInfo

  proc readVmRssBytes*(pid: int): int64 =
    ## rfc-0007 C1b: macOS has no `/proc` — `proc_pidinfo(PROC_PIDTASKINFO)`
    ## is the libproc equivalent. `pti_resident_size` is already BYTES
    ## (unlike /proc's kB), so no *1024 here. A denied/vanished pid returns
    ## a short/failed read — 0, honest, same as a zombie's VmRSS on Linux,
    ## never fabricated.
    ##
    ## A generously-sized raw buffer (never `sizeof(ProcTaskInfo)`): the
    ## payload types are `incompleteStruct`, so Nim's `sizeof` reflects only
    ## the FIELDS declared above, not the real C struct — passing that as
    ## `buffersize` under-sizes the buffer and `proc_pidinfo` rejects it
    ## (ENOSPC), which is exactly what left this empty on the first macos CI
    ## run. The kernel writes `sizeof(struct proc_taskinfo)` bytes and
    ## returns that count (> 0); field OFFSETS still come from the C header
    ## via the cast, which is all `incompleteStruct` was ever needed for.
    var buf: array[512, byte]
    let r = proc_pidinfo(pid.cint, PROC_PIDTASKINFO, 0'u64, addr buf[0],
                         cint(buf.len))
    if r <= 0: return 0'i64
    int64(cast[ptr ProcTaskInfo](addr buf[0]).pti_resident_size)

  proc walkProcTable*(): seq[ProcStatInfo] =
    ## rfc-0007 C1b: the libproc equivalent of the /proc walk below.
    ## `proc_listallpids(nil, 0)` returns a sizing hint (a pid count on some
    ## releases, a byte size on others); allocating `hint + 64` int32 slots
    ## over-allocates safely under BOTH readings (bytes ⇒ far more slack).
    ## The real call returns BYTES written, so `div sizeof(int32)` yields
    ## the live pid count — the documented two-call libproc idiom.
    ## `pbi_pgid` is exactly the process group id `scanProcessGroup(pgid)`'s
    ## `info.pgrp == pgid` filter needs — no change required there.
    ##
    ## Each `proc_pidinfo` reads into a generously-sized raw buffer, NOT a
    ## `var ProcBsdInfo` sized by `sizeof` — the type is `incompleteStruct`
    ## so Nim's `sizeof` counts only the declared fields (~a third of the
    ## real C struct), under-sizing the buffer and drawing an ENOSPC that
    ## skipped every pid on the first macos CI run (empty tree, zero RSS).
    ## The kernel returns `sizeof(struct proc_bsdinfo)` (> 0); field offsets
    ## come from the C header through the cast.
    result = @[]
    let want = proc_listallpids(nil, 0.cint)
    if want <= 0: return
    let cap = int(want) + 64   # over-allocate: safe whether `want` is count or bytes
    var pids = newSeq[int32](cap)
    let gotBytes = proc_listallpids(addr pids[0], cint(cap * sizeof(int32)))
    if gotBytes <= 0: return
    let n = int(gotBytes div cint(sizeof(int32)))
    var buf: array[512, byte]
    for i in 0 ..< n:
      let pid = pids[i]
      if pid <= 0: continue
      let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0'u64, addr buf[0],
                           cint(buf.len))
      if r <= 0: continue   # vanished/denied — skip, never fabricate
      let bi = cast[ptr ProcBsdInfo](addr buf[0])
      let comm = $cast[cstring](addr bi.pbi_comm[0])
      result.add ProcStatInfo(pid: int(pid), ppid: int(bi.pbi_ppid),
                              pgrp: int(bi.pbi_pgid), comm: comm,
                              starttime: int64(bi.pbi_start_tvsec))
else:
  proc readVmRssBytes*(pid: int): int64 =
    try:
      let content = readFile("/proc/" & $pid & "/status")
      for line in content.splitLines():
        if line.startsWith("VmRSS:"):
          let parts = line.splitWhitespace()
          if parts.len >= 2:
            return int64(parseBiggestInt(parts[1])) * 1024
    except CatchableError:
      discard
    0'i64

  proc walkProcTable*(): seq[ProcStatInfo] =
    result = @[]
    try:
      for kind, path in walkDir("/proc"):
        if kind != pcDir: continue
        var pid: int
        try: pid = parseInt(path.extractFilename)
        except ValueError: continue
        try:
          let stat = readFile(path / "stat")
          let (ppid, pgrp, comm, starttime) = parseStatLine(stat)
          result.add ProcStatInfo(pid: pid, ppid: ppid, pgrp: pgrp, comm: comm,
                                  starttime: starttime)
        except CatchableError:
          discard   # vanished between enumeration and read — skip it
    except CatchableError:
      discard         # /proc unreadable — empty snapshot, never fabricated

proc scanProcessGroup*(pgid: Pid): seq[ProcSnapshot] =
  ## Walk /proc, keep every pid whose pgrp == pgid. pgid-only tier — a
  ## setsid escape is invisible (§3); on the (non-Linux) tier where B1's
  ## subreaper mechanism never engages, `reapCore` reports
  ## `tree = treeObservationFor(kdsProcessGroup)` (always `toUnobservable`)
  ## regardless of what a given scan finds — observability is a property
  ## of the mechanism, not the scan.
  result = @[]
  for info in walkProcTable():
    if info.pgrp == int(pgid):
      result.add ProcSnapshot(pid: info.pid, ppid: info.ppid, command: info.comm,
                               rssBytes: readVmRssBytes(info.pid))
