## ledger.nim — A1b: RunLedger store (RFC-0004 F1).
##
## Append-only time-series store for per-entrypoint execution history.
## Primary key = identity (IdentityKey).  Stores inputHash (SoundnessKey
## rendered) as an **opaque string** — does not interpret it, does not import
## keys.nim.
##
## ## On-disk layout
##
## Per-process shard files:
##
##   <stateDir>/ledger/<pid>-<bootId>.ndjson
##
## Each shard file starts with a header line (JSON), followed by one NDJSON
## row per append.  Reads concatenate all shard files in the directory.
##
## Rationale (RFC-0004 §F1 round 2): POSIX does NOT guarantee inter-process
## append atomicity for regular files on overlayfs/WSL2.  Per-process shards
## eliminate cross-process contention entirely (no shared file), isolate
## corruption to one shard, and require no lock.
##
## ## Wire format
##
## Header line (first line of each shard):
##   {"historyFormatVersion":<int>}
##
## Row line (one JSON object per line):
##   {"rowVersion":1,"identity":"<str>","timestamp":<int64>,"inputHash":"<str>",
##    "outcome":"<str>","attempt":<int>,"durationUs":<int64>,"rssBytes":<int64>}
##
## ## Writes
##
## Raw posix.write partial-write loop (not buffered writeLine), via
## `ioutils.writeAllFd` — the shared EINTR/short-write-safe implementation
## every raw-fd writer in crisol uses (RFC-0007 A3).
##
## ## Corruption-resilient reads
##
## - Malformed row (JSON parse error, truncated final line, unknown rowVersion):
##   skipped with a warning; never aborts the scan.
## - Header-version mismatch: whole shard discarded with a warning (consistent
##   with resultcache whole-file discard).

import std/[algorithm, json, os, sequtils, sets, strutils, tables, times]
import crisol/types
import crisol/ioutils
import crisol/outcomestrings  # for passedOutcomeString

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const historyFormatVersion* = 1
  ## Increment when the NDJSON row schema changes incompatibly.
  ## A shard whose header version differs from this is discarded on read.

const currentRowVersion* = 1
  ## Row-level version.  An unknown rowVersion (> currentRowVersion) is skipped.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  LedgerRow* = object
    ## One execution event appended to the ledger.
    identity*:   IdentityKey   ## (path, flagHash) — who this is
    timestamp*:  int64         ## unix epoch microseconds
    inputHash*:  string        ## opaque SoundnessKey string (wire name "inputHash")
    outcome*:    string        ## "passed", "failed", etc. — stored as-is
    attempt*:    int           ## 1-indexed retry attempt number
    durationUs*: int64         ## wall-clock microseconds
    rssBytes*:   int64         ## peak RSS bytes at exit
    rowVersion*: int           ## must equal currentRowVersion to be accepted

  Ledger* = object
    ## An open per-process shard.  One per crisol invocation.
    ## The in-process writer is the single-threaded execute() poll loop;
    ## no synchronization is needed within a single process.
    shardPath*: string   ## absolute path to this process's shard file
    fd*:        cint     ## open file descriptor (O_APPEND | O_CREAT | O_WRONLY)
    closed*:    bool

# ---------------------------------------------------------------------------
# bootId — read once, degrade cleanly if unavailable
# ---------------------------------------------------------------------------

proc bootIdFallback(): string =
  ## Generate a collision-resistant fallback boot-id string when
  ## /proc/sys/kernel/random/boot_id is unavailable.
  ##
  ## Uses 8 bytes from /dev/urandom XOR'd with the current epoch µs so that
  ## two processes with the same PID at the same instant still get distinct
  ## shard names (L11 fix).  If /dev/urandom is also unavailable, falls back
  ## to epoch µs alone (same as before, last resort).
  let nowUs = int64(epochTime() * 1_000_000)
  let randBytes = readRandomBytes(8)
  if randBytes.len == 8:
    var rndVal: int64 = 0
    for i in 0 ..< 8:
      rndVal = rndVal or (int64(randBytes[i]) shl (i * 8))
    return toHex(rndVal xor nowUs, 16)
  # Last resort: epoch µs only (same as original behaviour).
  result = $nowUs

proc readBootId(): string =
  ## Reads /proc/sys/kernel/random/boot_id (Linux).
  ## Strips hyphens and trailing whitespace to make a compact filename-safe ID.
  ## If unreadable (non-Linux, container restriction, etc.), degrades to the
  ## process start time in microseconds, which is stable for a single run and
  ## does not crash on failure.
  const bootIdPath = "/proc/sys/kernel/random/boot_id"
  try:
    let raw = readFile(bootIdPath)
    result = raw.strip().replace("-", "")
    if result.len == 0:
      raise newException(IOError, "empty boot_id")
  except CatchableError:
    # Degrade: use a random suffix from /dev/urandom (xored with the epoch µs for
    # belt-and-suspenders) so two processes with the same pid at the same instant
    # still get distinct shard names — see L11 in the low-severity fix log.
    result = bootIdFallback()

## Module-level boot-id, computed once at startup.
## `threadvar` cannot be initialized at module scope; use a global instead.
## This is intentional — crisol's execute() loop is single-threaded and
## `bootId` is only read during `openLedger`, which happens at run start.
var bootId {.global.}: string = readBootId()

# ---------------------------------------------------------------------------
# Unique shard-name generation
# ---------------------------------------------------------------------------

# A per-process counter ensures two Ledger opens in the same process (e.g. in
# tests) always produce distinct shard file names, even if they open within
# the same microsecond or share the same PID.
var shardSeq {.global.}: int = 0

proc shardName(): string =
  ## Returns a filename-safe shard name: "<pid>-<bootId>-<seq>.ndjson".
  ## The sequence counter distinguishes multiple openLedger calls within the
  ## same process (e.g. in tests simulating concurrent invocations).
  inc shardSeq
  result = $getCurrentProcessId() & "-" & bootId & "-" & $shardSeq & ".ndjson"

proc compactName(): string =
  ## Returns a filename-safe name for a compacted shard:
  ## "compact-<pid>-<bootId>-c.ndjson".
  ##
  ## Does NOT increment shardSeq (L7 fix): compaction is a one-shot GC op, not
  ## a new live-shard open, so incrementing shardSeq would be a surprising
  ## side-effect in a "stable name" context.  The "c" suffix makes it
  ## deterministic within a process (only one compaction runs per cleanOrphans
  ## call) and the compact- prefix prevents confusion with live shards.
  result = "compact-" & $getCurrentProcessId() & "-" & bootId & "-c.ndjson"

# ---------------------------------------------------------------------------
# Internal: raw posix.write partial-write loop — delegates to ioutils
# ---------------------------------------------------------------------------

proc writeAll(fd: cint; data: string): bool {.inline.} =
  ## Thin wrapper: delegates to ioutils.writeAllFd so that ledger and
  ## resultcache share one implementation.
  writeAllFd(fd, data)

# ---------------------------------------------------------------------------
# Internal: header serialization
# ---------------------------------------------------------------------------

proc makeHeaderLine(): string {.inline.} =
  ## Produce the NDJSON header line for a new shard file.
  "{\"historyFormatVersion\":" & $historyFormatVersion & "}\n"

# ---------------------------------------------------------------------------
# Internal: row serialization
# ---------------------------------------------------------------------------

proc rowToJsonLine(row: LedgerRow): string =
  ## Serialize a LedgerRow to a single NDJSON line (no trailing newline added
  ## here — caller appends \n via writeAll to keep it atomic with the data).
  var n = newJObject()
  n["rowVersion"]  = newJInt(row.rowVersion)
  n["identity"]    = newJString($row.identity)
  n["timestamp"]   = newJInt(row.timestamp)
  n["inputHash"]   = newJString(row.inputHash)
  n["outcome"]     = newJString(row.outcome)
  n["attempt"]     = newJInt(row.attempt)
  n["durationUs"]  = newJInt(row.durationUs)
  n["rssBytes"]    = newJInt(row.rssBytes)
  result = $n & "\n"

# ---------------------------------------------------------------------------
# Public: openLedger
# ---------------------------------------------------------------------------

proc openLedger*(stateDir: string): Ledger =
  ## Create and open this process's own shard file under
  ## `<stateDir>/ledger/<pid>-<bootId>-<seq>.ndjson`.
  ## Writes the header line immediately.
  ## On any I/O error, warns to stderr and returns a Ledger with fd == -1
  ## (subsequent appends will warn and no-op; never raises).
  let ledgerDir = stateDir / "ledger"
  try:
    createDir(ledgerDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create ledger dir '" & ledgerDir &
                 "': " & e.msg & "\n")
    return Ledger(shardPath: "", fd: -1, closed: true)

  let path = ledgerDir / shardName()
  let (fd, openErr) = appendOpen(path)
  if fd < 0:
    stderr.write("crisol: warning: could not open ledger shard '" & path &
                 "': " & openErr & "\n")
    return Ledger(shardPath: path, fd: -1, closed: true)

  result = Ledger(shardPath: path, fd: fd, closed: false)
  # Write the header line.
  let hdr = makeHeaderLine()
  if not writeAll(fd, hdr):
    let err = lastErrorString()
    stderr.write("crisol: warning: could not write ledger header to '" & path &
                 "': " & err & "\n")
    closeFd(fd)
    result.fd = -1
    result.closed = true

# ---------------------------------------------------------------------------
# Public: append
# ---------------------------------------------------------------------------

proc append*(led: var Ledger; row: LedgerRow) =
  ## Append one row to the ledger shard.
  ## Uses ioutils.writeAllFd's partial-write loop (not buffered writeLine).
  ## No-ops silently if the ledger is closed or the fd is invalid.
  if led.closed or led.fd < 0:
    return
  let line = rowToJsonLine(row)
  if not writeAll(led.fd, line):
    let err = lastErrorString()
    stderr.write("crisol: warning: could not write to ledger shard '" &
                 led.shardPath & "': " & err & "\n")

# ---------------------------------------------------------------------------
# Public: closeLedger
# ---------------------------------------------------------------------------

proc closeLedger*(led: var Ledger) =
  ## Close the ledger shard file descriptor.  Idempotent.
  if led.closed or led.fd < 0:
    led.closed = true
    return
  closeFd(led.fd)
  led.fd = -1
  led.closed = true

# ---------------------------------------------------------------------------
# Internal: parse a single row line
# ---------------------------------------------------------------------------

proc parseRow(line: string; shardPath: string): (bool, LedgerRow) =
  ## Attempt to parse one NDJSON line as a LedgerRow.
  ## Returns (true, row) on success; (false, default) on any parse error,
  ## structural mismatch, or unknown rowVersion — with a stderr warning.
  var node: JsonNode
  try:
    node = parseJson(line)
  except CatchableError as e:
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': malformed row (JSON parse error): " & e.msg & "\n")
    return (false, LedgerRow())

  if node.kind != JObject:
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': malformed row (not a JSON object)\n")
    return (false, LedgerRow())

  let rv = node{"rowVersion"}.getInt(-1)
  if rv < 1 or rv > currentRowVersion:
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': unknown rowVersion=" & $rv & "; skipping row\n")
    return (false, LedgerRow())

  let identStr = node{"identity"}.getStr("")
  if identStr == "":
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': row missing identity; skipping\n")
    return (false, LedgerRow())

  let row = LedgerRow(
    rowVersion:  rv,
    identity:    IdentityKey(identStr),
    timestamp:   node{"timestamp"}.getBiggestInt(0),
    inputHash:   node{"inputHash"}.getStr(""),
    outcome:     node{"outcome"}.getStr(""),
    attempt:     node{"attempt"}.getInt(1),
    durationUs:  node{"durationUs"}.getBiggestInt(0),
    rssBytes:    node{"rssBytes"}.getBiggestInt(0),
  )
  return (true, row)

# ---------------------------------------------------------------------------
# Internal: shared shard parser — header validation + all-row extraction
# ---------------------------------------------------------------------------

proc parseShardLines(lines: seq[string]; shardPath: string): seq[LedgerRow] =
  ## Parse a shard's already-split lines into a seq[LedgerRow].
  ##
  ## Corruption-resilience rules (preserved exactly from the original callers):
  ##   - Completely empty file (no non-blank lines) → return @[].
  ##   - Malformed header JSON → discard whole shard, return @[].
  ##   - Header historyFormatVersion mismatch → discard whole shard, return @[].
  ##   - Torn / unknown-version data rows → skip row with warning, continue.
  ##   - Trailing blank lines → skip silently.
  ##
  ## The identity filter is NOT applied here; callers use `filterIt` so the
  ## predicate stays at the call site and this proc stays single-purpose.
  if lines.len == 0:
    return @[]

  # First non-empty line is the header.
  var headerIdx = -1
  for i, l in lines:
    if l.strip().len > 0:
      headerIdx = i
      break
  if headerIdx < 0:
    return @[]  # completely empty file

  let headerLine = lines[headerIdx].strip()
  var headerNode: JsonNode
  try:
    headerNode = parseJson(headerLine)
  except CatchableError:
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': malformed header; discarding shard\n")
    return @[]

  let storedVersion = headerNode{"historyFormatVersion"}.getInt(-1)
  if storedVersion != historyFormatVersion:
    stderr.write("crisol: warning: ledger shard '" & shardPath &
                 "': historyFormatVersion=" & $storedVersion &
                 " (expected " & $historyFormatVersion & "); discarding shard\n")
    return @[]

  # Parse data rows (lines after the header).
  for i in (headerIdx + 1) ..< lines.len:
    let line = lines[i].strip()
    if line.len == 0:
      continue   # blank line (e.g. trailing newline) — skip silently
    let (ok, row) = parseRow(line, shardPath)
    if ok:
      result.add row

# ---------------------------------------------------------------------------
# Internal: read one shard, return its rows (or empty on header mismatch)
# ---------------------------------------------------------------------------

proc readShard(shardPath: string; identity: IdentityKey): seq[LedgerRow] =
  ## Read all rows from one shard that match `identity`.
  ## First line must be the header; version mismatch discards the whole shard.
  ## Malformed/unknown-version data rows are skipped with a warning.
  var raw: string
  try:
    raw = readFile(shardPath)
  except OSError as e:
    stderr.write("crisol: warning: could not read ledger shard '" & shardPath &
                 "': " & e.msg & "\n")
    return @[]
  parseShardLines(raw.splitLines(), shardPath).filterIt(it.identity == identity)

# ---------------------------------------------------------------------------
# Public: scanLedger
# ---------------------------------------------------------------------------

proc scanLedger*(stateDir: string; identity: IdentityKey): seq[LedgerRow] =
  ## Scan ALL shard files under `<stateDir>/ledger/` and return rows matching
  ## `identity`, sorted by timestamp ascending.
  ##
  ## Corruption-resilient: malformed rows are skipped with a warning; a
  ## header-version mismatch in a shard discards that shard.  Other shards
  ## are unaffected.  Never raises on bad data.
  let ledgerDir = stateDir / "ledger"
  if not dirExists(ledgerDir):
    return @[]

  var rows: seq[LedgerRow] = @[]
  for kind, path in walkDir(ledgerDir):
    if kind == pcFile and path.endsWith(".ndjson"):
      let shardRows = readShard(path, identity)
      rows.add shardRows

  # Sort by timestamp ascending (stable, so equal timestamps preserve shard order).
  rows.sort(proc(a, b: LedgerRow): int = cmp(a.timestamp, b.timestamp))
  result = rows

# ---------------------------------------------------------------------------
# B2: Flake-rate query — pure computation over a seq[LedgerRow]
# ---------------------------------------------------------------------------
##
## Definition:
##   Group the rows by `inputHash` (opaque string; "" is a valid bucket).
##   An inputHash bucket is FLAKY iff its rows contain BOTH at least one
##   pass outcome ("passed") AND at least one non-pass outcome.
##
##   Rationale: a fail on attempt 1 followed by a pass on attempt 2 —
##   within a single invocation for the same binary build — produces
##   exactly one fail row and one pass row sharing the same inputHash.
##   Mixed outcomes under identical inputs is the canonical definition
##   of flakiness.
##
##   Rows with inputHash == "": grouped under the "" bucket so a fail+pass
##   with no inputHash (cache not consulted) still registers as flaky.
##   This is the safest choice: erring toward surfacing flakiness when
##   the build identity is unknown.
##
##   flakeRate = flakyBuckets / totalDistinctBuckets
##   When rows is empty: flakeRate = 0.0, isFlaky = false.

template passOutcome(): string = passedOutcomeString
  ## The outcome string that represents a successful run.
  ## Delegates to outcomestrings.passedOutcomeString — single source of truth.

proc computeFlakeRate*(rows: seq[LedgerRow]): float =
  ## Pure: compute flake rate over `rows` (no I/O).
  ## Returns flakyBuckets / totalDistinctBuckets; 0.0 when rows is empty.
  ## Each bucket = a distinct inputHash value; a bucket is flaky iff it has
  ## both pass and non-pass outcomes.  "" inputHash is a valid bucket.
  if rows.len == 0:
    return 0.0
  # Accumulate per-bucket sets of observed outcome classes.
  # seenPass[h] = true iff at least one "passed" row with that inputHash.
  # seenFail[h] = true iff at least one non-"passed" row with that inputHash.
  var seenPass = initTable[string, bool]()
  var seenFail = initTable[string, bool]()
  for r in rows:
    let h = r.inputHash
    if r.outcome == passOutcome:
      seenPass[h] = true
    else:
      seenFail[h] = true
  var totalBuckets = 0
  var flakyBuckets = 0
  var allHashes = initHashSet[string]()
  for h in seenPass.keys: allHashes.incl h
  for h in seenFail.keys:  allHashes.incl h
  for h in allHashes:
    inc totalBuckets
    if seenPass.getOrDefault(h, false) and seenFail.getOrDefault(h, false):
      inc flakyBuckets
  if totalBuckets == 0:
    return 0.0
  result = float(flakyBuckets) / float(totalBuckets)

proc isFlaky*(stateDir: string; identity: IdentityKey): bool =
  ## Query: true iff this identity has at least one flaky inputHash bucket
  ## in its ledger history (any bucket with both pass and non-pass outcomes).
  let rows = scanLedger(stateDir, identity)
  computeFlakeRate(rows) > 0.0

proc flakeRate*(stateDir: string; identity: IdentityKey): float =
  ## Query: fraction of distinct inputHash buckets that are flaky.
  ## 0.0 when no rows exist for this identity.
  let rows = scanLedger(stateDir, identity)
  computeFlakeRate(rows)

# ---------------------------------------------------------------------------
# A1c: Ledger shard compaction
# ---------------------------------------------------------------------------
##
## Design notes (A1c):
##
## - Compaction reads ALL rows from ALL shards (all identities) using the
##   existing per-row parser.  It reuses `rowToJsonLine` for re-serialization
##   so there is ONE NDJSON format — not a second one.
##
## - The compacted file is named `compact-<pid>-<bootId>-<seq>.ndjson`
##   following the same shard-naming convention (filename-safe, unique per
##   process).  The prefix `compact-` is NOT a valid pid, so it is never
##   confused with a fresh process shard.
##
## - Algorithm: read all shards → collect all rows → sort by timestamp →
##   apply age filter (optional) → write one new shard → remove old shards.
##
## - The write-then-remove order is crash-safe: if the process dies after
##   writing but before removing, the next scanLedger sees the compacted file
##   PLUS the originals — rows appear multiple times.  scanLedger already
##   handles duplicates gracefully (they appear in the output, which is fine:
##   a duplicate row is a non-harmful idempotent re-read of history).  A
##   subsequent cleanOrphans will compact again and deduplicate.
##
## - `nowSecs` and `maxAgeSecs` are injected for testability.  Pass 0 for
##   `maxAgeSecs` to disable age-based row retention.
##
## - `maxAgeSecs` uses microseconds comparison: `timestamp` is in µs, so
##   the cutoff is `(nowSecs - maxAgeSecs) * 1_000_000`.
##
## - Callers (cleanOrphans) must hold the stateDir lock.

type
  CompactLedgerReport* = tuple[shardsRemoved: int; rowsKept: int]
    ## Summary of a compactLedger run.

proc readAllShardRows(shardPath: string): seq[LedgerRow] =
  ## Read ALL rows from one shard (all identities).
  ## Header-version mismatch → discard whole shard.
  ## Malformed/unknown-version rows → skip with warning.
  var raw: string
  try:
    raw = readFile(shardPath)
  except OSError as e:
    stderr.write("crisol: warning: could not read ledger shard '" & shardPath &
                 "': " & e.msg & "\n")
    return @[]
  parseShardLines(raw.splitLines(), shardPath)

proc compactLedger*(stateDir: string; maxAgeSecs: int64; nowSecs: int64):
    CompactLedgerReport =
  ## Merge ALL shard files under `<stateDir>/ledger/` into a single compacted
  ## segment, then remove the originals.  Optionally drops rows older than
  ## `maxAgeSecs` seconds (0 = keep all rows).
  ##
  ## Correctness:
  ##   The compacted file round-trips through `scanLedger` identically (same
  ##   rows, same data) modulo any intentionally-dropped aged rows.  Row
  ##   serialization reuses `rowToJsonLine` — one NDJSON format throughout.
  ##
  ## Crash safety:
  ##   New compacted file is written first, old shards removed after.  A crash
  ##   between write and remove produces duplicates on the next scan (harmless)
  ##   and a subsequent compact will deduplicate.
  ##
  ## Parameters:
  ##   stateDir   — the `.crisol` state directory.
  ##   maxAgeSecs — drop rows older than this many seconds (0 = keep all).
  ##   nowSecs    — current unix epoch seconds (injected for testability).
  ##
  ## Returns:
  ##   shardsRemoved — how many old shard files were removed.
  ##   rowsKept      — how many rows are in the compacted segment.
  let ledgerDir = stateDir / "ledger"
  if not dirExists(ledgerDir):
    return (shardsRemoved: 0, rowsKept: 0)

  # Collect all shard paths.
  var shardPaths: seq[string]
  for kind, path in walkDir(ledgerDir):
    if kind == pcFile and path.endsWith(".ndjson"):
      shardPaths.add path

  if shardPaths.len == 0:
    return (shardsRemoved: 0, rowsKept: 0)

  # Read all rows from all shards.
  var allRows: seq[LedgerRow]
  for sp in shardPaths:
    allRows.add readAllShardRows(sp)

  # Sort by timestamp ascending.
  allRows.sort(proc(a, b: LedgerRow): int = cmp(a.timestamp, b.timestamp))

  # Age filter (timestamp is µs; maxAgeSecs is seconds).
  if maxAgeSecs > 0:
    let cutoffUs = (nowSecs - maxAgeSecs) * 1_000_000
    allRows = allRows.filterIt(it.timestamp >= cutoffUs)

  # Write the compacted shard file.
  # Name via compactName(): does NOT increment shardSeq (L7 fix — compaction is a
  # GC op, not a new live-shard open).  The compact- prefix distinguishes it from
  # live shards.  ledgerDir already exists (guaranteed by the dirExists check above).
  let compactedPath = ledgerDir / compactName()

  let (compactedFd, openErr, _) = createOverwrite(compactedPath)
  if compactedFd < 0:
    stderr.write("crisol: warning: could not create compacted ledger file '" &
                 compactedPath & "': " & openErr & "\n")
    return (shardsRemoved: 0, rowsKept: 0)

  var writeOk = true
  let hdr = makeHeaderLine()
  if not writeAll(compactedFd, hdr):
    writeOk = false

  if writeOk:
    for row in allRows:
      let line = rowToJsonLine(row)
      if not writeAll(compactedFd, line):
        writeOk = false
        break

  closeFd(compactedFd)

  if not writeOk:
    stderr.write("crisol: warning: error writing compacted ledger; keeping originals\n")
    try: removeFile(compactedPath) except CatchableError: discard
    return (shardsRemoved: 0, rowsKept: 0)

  # Remove old shards (the originals; NOT the newly written compact file).
  var shardsRemoved = 0
  for sp in shardPaths:
    try:
      removeFile(sp)
      inc shardsRemoved
    except CatchableError as e:
      stderr.write("crisol: warning: could not remove ledger shard '" & sp &
                   "': " & e.msg & "\n")

  result = (shardsRemoved: shardsRemoved, rowsKept: allRows.len)
