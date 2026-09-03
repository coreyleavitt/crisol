## shardedledger.nim — RFC-0006 code-review R3 (subsumes R12): generic
## sharded-NDJSON ledger substrate.
##
## `artifactledger.nim` and `compilecost.nim` (originally also
## `objcachestats.nim`, removed with RFC-0006 Stage R — see that stream's own
## history if resurrecting) each independently reimplemented an IDENTICAL
## sharded-NDJSON pattern (~400 lines each): bootId read (with
## `/dev/urandom` fallback), a per-process shard-sequence counter,
## `<pid>-<bootId>-<seq>.ndjson` naming, a format-version header line +
## NDJSON row framing, corruption-tolerant parsing (malformed row ->
## skip+warn; header-version mismatch -> discard the whole shard), `scanX`
## (concatenate all shards + sort by timestamp), and `compactX` (merge ->
## age-filter -> write-one-shard -> remove-originals, crash-safe by
## write-then-remove ordering). This module is the extracted, parameterized
## substrate; each stream instantiates it with a small per-row codec (see
## `ShardedLedgerSpec`) and re-exposes the SAME public proc names/signatures
## it had before (thin typed wrappers — see each module's own file).
##
## `ledger.nim` (the pre-existing EXEC ledger) is DELIBERATELY not
## reimplemented over this substrate and stays untouched. The reason is a
## FIELD-SHAPE mismatch, not a behavioral one: `scanLedger`'s post-decode
## identity filter is not itself the obstacle (it runs after full decode,
## same cost as every other consumer's own post-scan filtering — an
## `identity`-filter rationale doesn't hold up). The real mismatch is that
## `LedgerRow` uses `identity` (not `entrypointIdentity`) and carries no
## `groupId`/`configHash` at all, so it doesn't fit this module's
## five-common-field assumption (see "Common row shape" below) without
## loosening the seam into awkward per-stream field-mapping — out of scope
## per the RFC-0006 review finding this module resolves.
##
## ## Common row shape (why the codec seam is small)
##
## Both consumer row types (`ArtifactRow`, `CompileCostRow`) share FIVE
## fields with identical semantics:
## `entrypointIdentity` (`IdentityKey`), `groupId`/`configHash`
## (segmentation strings), `timestamp` (unix epoch microseconds), and
## `rowVersion` (row-schema version, checked against a `currentRowVersion`
## the stream's spec supplies). This module owns encoding/decoding/
## validating those five fields directly against `row.<field>` — Nim
## generics are structurally typed per-instantiation (monomorphized like a
## C++ template), so this compiles against any `T` that actually has those
## fields, without a `concept`. Each stream supplies ONLY its own extra
## fields via `encodeExtra`/`decodeExtra`.
##
## ## Seam
##
## `ShardedLedgerSpec[T]{dirName, formatVersion, headerField,
## currentRowVersion, streamLabel, encodeExtra, decodeExtra}`:
##   - `dirName` names the `<stateDir>/ledger/<dirName>/` subdirectory.
##   - `formatVersion`/`headerField` are the shard header's JSON key/value
##     (a version mismatch on read discards the WHOLE shard).
##   - `currentRowVersion` bounds the per-row `rowVersion` field (a row
##     whose version is out of range is skipped, not the whole shard).
##   - `streamLabel` prefixes stderr warning text (e.g. `"artifact ledger"`).
##   - `encodeExtra(n, row)` writes the stream's own fields into the JSON
##     object (the five common fields are already set by the generic).
##   - `decodeExtra(n, rv, ident, groupId, configHash, timestamp)` builds
##     the full row `T`, given the five common fields already validated and
##     extracted by the generic plus the raw JSON node for its own fields.
##
## `decodeExtra` has no failure mode of its own in the current three
## streams (every extra field is read via `JsonNode.getStr`/`getInt`/
## `getBiggestInt` with a zero-value default, mirroring the pre-extraction
## modules exactly) — malformed/invalid-row detection is handled uniformly
## by the generic's own JSON-parse / not-an-object / rowVersion-range /
## missing-identity checks before `decodeExtra` is ever called.
##
## ## On-disk layout / wire format / corruption tolerance (preserved exactly)
##
## Per-process shard files, one subdirectory per stream:
##
##   <stateDir>/ledger/<dirName>/<pid>-<bootId>-<seq>.ndjson
##
## Header line first (JSON `{"<headerField>":<formatVersion>}`), then one
## NDJSON row per line. Reads concatenate all shard files in the directory.
## A malformed row is skipped with a warning; a header-version mismatch
## discards the whole shard; `scan` returns everything sorted by timestamp
## ascending; `compact` merges all shards, optionally age-filters, writes
## ONE new shard, then removes the originals (crash-safe: a crash between
## write and remove leaves harmless duplicates a later compaction
## deduplicates by replacing all shards again).
##
## ## Per-stream independent bootId / shard-sequence (preserved exactly)
##
## Each pre-extraction module had its OWN process-lifetime `bootId` global
## and its OWN shard-sequence counter, independent of the other streams'.
## This module preserves that exactly via `{.global.}` vars declared INSIDE
## generic procs: Nim monomorphizes a generic proc per unique type
## argument, so `streamBootId[ArtifactRow]` and
## `streamBootId[CompileCostRow]` are separate proc bodies, each with its
## OWN `{.global.}` state — i.e. one independent bootId read and one
## independent shard-sequence counter per STREAM (row type), exactly as
## before, with no shared/cross-stream state and no change in the number of
## `/proc/sys/kernel/random/boot_id` reads.

import std/[algorithm, json, os, strutils, times]
import crisol/types
import crisol/ioutils

# ---------------------------------------------------------------------------
# Seam types
# ---------------------------------------------------------------------------

type
  ShardedLedgerSpec*[T] = object
    ## Per-stream codec/config seam. See module doc.
    dirName*:           string
    formatVersion*:      int
    headerField*:        string
    currentRowVersion*:  int
    streamLabel*:        string
    encodeExtra*:        proc(n: var JsonNode; row: T) {.closure.}
    decodeExtra*:        proc(n: JsonNode; rv: int; ident: IdentityKey;
                               groupId, configHash: string; timestamp: int64): T {.closure.}

  ShardedLedger*[T] = object
    ## An open per-process shard, generic over the stream's row type.
    shardPath*: string
    fd*:        cint
    closed*:    bool

  CompactReport* = tuple[shardsRemoved: int; rowsKept: int]
    ## Summary of a `compactShardedLedger` run.

# ---------------------------------------------------------------------------
# bootId — read once per STREAM (per-T instantiation), degrade cleanly if
# unavailable. Body identical to the pre-extraction ledger.nim /
# artifactledger.nim / compilecost.nim / objcachestats.nim copies.
# ---------------------------------------------------------------------------

proc genericBootIdFallback(): string =
  let nowUs = int64(epochTime() * 1_000_000)
  let randBytes = readRandomBytes(8)
  if randBytes.len == 8:
    var rndVal: int64 = 0
    for i in 0 ..< 8:
      rndVal = rndVal or (int64(randBytes[i]) shl (i * 8))
    return toHex(rndVal xor nowUs, 16)
  result = $nowUs

proc genericReadBootId(): string =
  const bootIdPath = "/proc/sys/kernel/random/boot_id"
  try:
    let raw = readFile(bootIdPath)
    result = raw.strip().replace("-", "")
    if result.len == 0:
      raise newException(IOError, "empty boot_id")
  except CatchableError:
    result = genericBootIdFallback()

proc streamBootId[T](): string =
  ## Memoized once PER STREAM (per unique T) — see module doc.
  var cached {.global.}: string = genericReadBootId()
  result = cached

proc nextStreamShardSeq[T](): int =
  ## Per-stream (per unique T) shard-sequence counter, incremented only by
  ## live-shard opens (never by compaction — mirrors the pre-extraction
  ## `xCompactName` procs, which deliberately do NOT bump the counter).
  var counter {.global.}: int = 0
  inc counter
  result = counter

proc shardFileName[T](): string =
  $getCurrentProcessId() & "-" & streamBootId[T]() & "-" & $nextStreamShardSeq[T]() & ".ndjson"

proc compactFileName[T](): string =
  "compact-" & $getCurrentProcessId() & "-" & streamBootId[T]() & "-c.ndjson"

# ---------------------------------------------------------------------------
# Path helper
# ---------------------------------------------------------------------------

proc shardedLedgerDir[T](spec: ShardedLedgerSpec[T]; stateDir: string): string {.inline.} =
  stateDir / "ledger" / spec.dirName

# ---------------------------------------------------------------------------
# Header + row serialization
# ---------------------------------------------------------------------------

proc makeShardedHeaderLine[T](spec: ShardedLedgerSpec[T]): string {.inline.} =
  "{\"" & spec.headerField & "\":" & $spec.formatVersion & "}\n"

proc shardedRowToJsonLine[T](spec: ShardedLedgerSpec[T]; row: T): string =
  ## Serialize a row to a single NDJSON line (no trailing newline — caller
  ## appends \n via writeAllFd to keep it atomic with the data). The five
  ## common fields are set here; the stream's own fields come from
  ## `encodeExtra`. Field ORDER in the emitted object is not part of the
  ## contract (JSON objects are unordered; nothing reads shard bytes
  ## positionally — every consumer parses via `parseJson` + field access).
  var n = newJObject()
  n["rowVersion"]         = newJInt(row.rowVersion)
  n["entrypointIdentity"] = newJString($row.entrypointIdentity)
  n["groupId"]            = newJString(row.groupId)
  n["configHash"]         = newJString(row.configHash)
  spec.encodeExtra(n, row)
  n["timestamp"]          = newJInt(row.timestamp)
  result = $n & "\n"

# ---------------------------------------------------------------------------
# Public: openShardedLedger
# ---------------------------------------------------------------------------

proc openShardedLedger*[T](spec: ShardedLedgerSpec[T]; stateDir: string): ShardedLedger[T] =
  ## Create and open this process's own shard file under
  ## `<stateDir>/ledger/<dirName>/<pid>-<bootId>-<seq>.ndjson`. Writes the
  ## header line immediately. On any I/O error, warns to stderr and returns
  ## a `ShardedLedger[T]` with fd == -1 (subsequent appends no-op; never
  ## raises).
  let dir = shardedLedgerDir(spec, stateDir)
  try:
    createDir(dir)
  except OSError as e:
    stderr.write("crisol: warning: could not create " & spec.streamLabel & " dir '" &
                 dir & "': " & e.msg & "\n")
    return ShardedLedger[T](shardPath: "", fd: -1, closed: true)

  let path = dir / shardFileName[T]()
  let (fd, openErr) = appendOpen(path)
  if fd < 0:
    stderr.write("crisol: warning: could not open " & spec.streamLabel & " shard '" &
                 path & "': " & openErr & "\n")
    return ShardedLedger[T](shardPath: path, fd: -1, closed: true)

  result = ShardedLedger[T](shardPath: path, fd: fd, closed: false)
  let hdr = makeShardedHeaderLine(spec)
  if not writeAllFd(fd, hdr):
    let err = lastErrorString()
    stderr.write("crisol: warning: could not write " & spec.streamLabel & " header to '" &
                 path & "': " & err & "\n")
    closeFd(fd)
    result.fd = -1
    result.closed = true

# ---------------------------------------------------------------------------
# Public: appendRow / closeShardedLedger
# ---------------------------------------------------------------------------

proc appendRow*[T](spec: ShardedLedgerSpec[T]; led: var ShardedLedger[T]; row: T) =
  ## Append one row to the shard. No-ops silently if the ledger is closed or
  ## the fd is invalid.
  if led.closed or led.fd < 0:
    return
  let line = shardedRowToJsonLine(spec, row)
  if not writeAllFd(led.fd, line):
    let err = lastErrorString()
    stderr.write("crisol: warning: could not write to " & spec.streamLabel & " shard '" &
                 led.shardPath & "': " & err & "\n")

proc closeShardedLedger*[T](led: var ShardedLedger[T]) =
  ## Close the shard file descriptor. Idempotent.
  if led.closed or led.fd < 0:
    led.closed = true
    return
  closeFd(led.fd)
  led.fd = -1
  led.closed = true

# ---------------------------------------------------------------------------
# Internal: parse a single row line
# ---------------------------------------------------------------------------

proc parseShardedRow[T](spec: ShardedLedgerSpec[T]; line: string; shardPath: string): (bool, T) =
  ## Attempt to parse one NDJSON line as a `T`. Returns (true, row) on
  ## success; (false, default(T)) on any parse error, structural mismatch,
  ## unknown rowVersion, or missing entrypointIdentity — with a stderr
  ## warning. Validates the five common fields; delegates the stream's own
  ## fields to `spec.decodeExtra`.
  var node: JsonNode
  try:
    node = parseJson(line)
  except CatchableError as e:
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': malformed row (JSON parse error): " & e.msg & "\n")
    return (false, default(T))

  if node.kind != JObject:
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': malformed row (not a JSON object)\n")
    return (false, default(T))

  let rv = node{"rowVersion"}.getInt(-1)
  if rv < 1 or rv > spec.currentRowVersion:
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': unknown rowVersion=" & $rv & "; skipping row\n")
    return (false, default(T))

  let identStr = node{"entrypointIdentity"}.getStr("")
  if identStr == "":
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': row missing entrypointIdentity; skipping\n")
    return (false, default(T))

  let groupId    = node{"groupId"}.getStr("")
  let configHash = node{"configHash"}.getStr("")
  let timestamp  = node{"timestamp"}.getBiggestInt(0)

  let row = spec.decodeExtra(node, rv, IdentityKey(identStr), groupId, configHash, timestamp)
  return (true, row)

# ---------------------------------------------------------------------------
# Internal: shared shard parser — header validation + all-row extraction
# ---------------------------------------------------------------------------

proc parseShardedLines[T](spec: ShardedLedgerSpec[T]; lines: seq[string];
                           shardPath: string): seq[T] =
  if lines.len == 0:
    return @[]

  var headerIdx = -1
  for i, l in lines:
    if l.strip().len > 0:
      headerIdx = i
      break
  if headerIdx < 0:
    return @[]

  let headerLine = lines[headerIdx].strip()
  var headerNode: JsonNode
  try:
    headerNode = parseJson(headerLine)
  except CatchableError:
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': malformed header; discarding shard\n")
    return @[]

  let storedVersion = headerNode{spec.headerField}.getInt(-1)
  if storedVersion != spec.formatVersion:
    stderr.write("crisol: warning: " & spec.streamLabel & " shard '" & shardPath &
                 "': " & spec.headerField & "=" & $storedVersion &
                 " (expected " & $spec.formatVersion & "); discarding shard\n")
    return @[]

  for i in (headerIdx + 1) ..< lines.len:
    let line = lines[i].strip()
    if line.len == 0:
      continue
    let (ok, row) = parseShardedRow(spec, line, shardPath)
    if ok:
      result.add row

# ---------------------------------------------------------------------------
# Internal: read one shard, return ALL its rows (R12 — the ONE shard reader;
# pre-extraction each stream had two byte-identical procs, `readXShard` and
# `readAllXShardRows`, used by `scanX`/`compactX` respectively — collapsed
# here into one, used by both `scanShardedLedger` and `compactShardedLedger`.)
# ---------------------------------------------------------------------------

proc readShardedShard[T](spec: ShardedLedgerSpec[T]; shardPath: string): seq[T] =
  var raw: string
  try:
    raw = readFile(shardPath)
  except OSError as e:
    stderr.write("crisol: warning: could not read " & spec.streamLabel & " shard '" &
                 shardPath & "': " & e.msg & "\n")
    return @[]
  parseShardedLines(spec, raw.splitLines(), shardPath)

# ---------------------------------------------------------------------------
# Public: scanShardedLedger
# ---------------------------------------------------------------------------

proc scanShardedLedger*[T](spec: ShardedLedgerSpec[T]; stateDir: string): seq[T] =
  ## Scan ALL shard files under `<stateDir>/ledger/<dirName>/` and return ALL
  ## rows, sorted by timestamp ascending. Corruption-resilient: malformed
  ## rows are skipped with a warning; a header-version mismatch in a shard
  ## discards that shard. Never raises.
  let dir = shardedLedgerDir(spec, stateDir)
  if not dirExists(dir):
    return @[]

  var rows: seq[T] = @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".ndjson"):
      rows.add readShardedShard(spec, path)

  rows.sort(proc(a, b: T): int = cmp(a.timestamp, b.timestamp))
  result = rows

# ---------------------------------------------------------------------------
# Public: compactShardedLedger — compaction AND GC in one pass
# ---------------------------------------------------------------------------

proc compactShardedLedger*[T](spec: ShardedLedgerSpec[T]; stateDir: string;
                               maxAgeSecs: int64; nowSecs: int64): CompactReport =
  ## Merge ALL shard files under `<stateDir>/ledger/<dirName>/` into a
  ## single compacted segment, then remove the originals. Optionally drops
  ## rows older than `maxAgeSecs` seconds (0 = keep all rows). Same
  ## algorithm/crash-safety as the pre-extraction per-stream copies: read
  ## all shards -> collect all rows -> sort by timestamp -> apply age
  ## filter -> write one new shard -> remove old shards. Write-then-remove
  ## order means a crash between the two produces harmless duplicates on
  ## the next scan (a subsequent compaction deduplicates by replacing all
  ## shards again).
  ##
  ## Callers (`cleanOrphans`) must hold the stateDir lock.
  let dir = shardedLedgerDir(spec, stateDir)
  if not dirExists(dir):
    return (shardsRemoved: 0, rowsKept: 0)

  var shardPaths: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".ndjson"):
      shardPaths.add path

  if shardPaths.len == 0:
    return (shardsRemoved: 0, rowsKept: 0)

  var allRows: seq[T]
  for sp in shardPaths:
    allRows.add readShardedShard(spec, sp)

  allRows.sort(proc(a, b: T): int = cmp(a.timestamp, b.timestamp))

  if maxAgeSecs > 0:
    let cutoffUs = (nowSecs - maxAgeSecs) * 1_000_000
    var kept: seq[T]
    for r in allRows:
      if r.timestamp >= cutoffUs:
        kept.add r
    allRows = kept

  let compactedPath = dir / compactFileName[T]()

  let (compactedFd, openErr, _) = createOverwrite(compactedPath)
  if compactedFd < 0:
    stderr.write("crisol: warning: could not create compacted " & spec.streamLabel &
                 " file '" & compactedPath & "': " & openErr & "\n")
    return (shardsRemoved: 0, rowsKept: 0)

  var writeOk = true
  let hdr = makeShardedHeaderLine(spec)
  if not writeAllFd(compactedFd, hdr):
    writeOk = false

  if writeOk:
    for row in allRows:
      let line = shardedRowToJsonLine(spec, row)
      if not writeAllFd(compactedFd, line):
        writeOk = false
        break

  closeFd(compactedFd)

  if not writeOk:
    stderr.write("crisol: warning: error writing compacted " & spec.streamLabel &
                 "; keeping originals\n")
    try: removeFile(compactedPath) except CatchableError: discard
    return (shardsRemoved: 0, rowsKept: 0)

  var shardsRemoved = 0
  for sp in shardPaths:
    try:
      removeFile(sp)
      inc shardsRemoved
    except CatchableError as e:
      stderr.write("crisol: warning: could not remove " & spec.streamLabel & " shard '" &
                   sp & "': " & e.msg & "\n")

  result = (shardsRemoved: shardsRemoved, rowsKept: allRows.len)
