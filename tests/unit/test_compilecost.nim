## test_compilecost.nim — RFC-0006 M-cost-split: compile-cost telemetry.
##
## TDD: tests written first (RED), then compilecost.nim written to make them
## pass.
##
## Coverage (this file):
##   1. costSplit: pure codegen/cc/link percentage split from a CompileSpans.
##   2. CompileCostRow round-trip: append rows -> scanCompileCostLedger
##      returns them with fields intact; malformed line tolerated.
##
## Compaction/GC coverage lives in test_compilecost_gc.nim (mirrors the
## artifactledger.nim / test_artifactledger_gc.nim split).

import std/[os, strutils, tables]
import crisol/types
import crisol/compiledriver
import crisol/compilecost

# ---------------------------------------------------------------------------
# 1. costSplit — pure percentage split
# ---------------------------------------------------------------------------

block test_costsplit_basic:
  let spans = CompileSpans(ok: true, codegenSpanUs: 200, ccSpanUs: 600, linkSpanUs: 200)
  let split = costSplit(spans)
  assert abs(split.codegenPct - 0.2) < 1e-9, "codegenPct wrong: " & $split.codegenPct
  assert abs(split.ccPct - 0.6) < 1e-9, "ccPct wrong: " & $split.ccPct
  assert abs(split.linkPct - 0.2) < 1e-9, "linkPct wrong: " & $split.linkPct
  let total = split.codegenPct + split.ccPct + split.linkPct
  assert abs(total - 1.0) < 1e-9, "pcts must sum to ~1.0, got " & $total

block test_costsplit_zero_total:
  let spans = CompileSpans(ok: true, codegenSpanUs: 0, ccSpanUs: 0, linkSpanUs: 0)
  let split = costSplit(spans)
  assert split.codegenPct == 0.0
  assert split.ccPct == 0.0
  assert split.linkPct == 0.0

# ---------------------------------------------------------------------------
# 2. CompileCostRow round-trip through the shard stream
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_compilecost_" & name)
  removeDir(result)
  createDir(result)

proc sampleCompileCostRow(ident: IdentityKey; ts: int64;
                          groupId = "unit"; configHash = "cfg0000000000000";
                          codegenUs = 100_000i64; ccUs = 400_000i64;
                          linkUs = 50_000i64): CompileCostRow =
  CompileCostRow(
    entrypointIdentity: ident,
    groupId:            groupId,
    configHash:         configHash,
    codegenUs:          codegenUs,
    ccUs:               ccUs,
    linkUs:             linkUs,
    timestamp:          ts,
    rowVersion:         currentCompileCostRowVersion,
  )

block test_roundtrip:
  let sd = freshStateDir("roundtrip")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_foo.nim::")
  var led = openCompileCostLedger(sd)
  let row = sampleCompileCostRow(ident, 1000)
  append(led, row)
  closeCompileCostLedger(led)

  let rows = scanCompileCostLedger(sd)
  assert rows.len == 1, "roundtrip: expected 1 row, got " & $rows.len
  assert rows[0].entrypointIdentity == ident
  assert rows[0].groupId == "unit"
  assert rows[0].configHash == "cfg0000000000000"
  assert rows[0].codegenUs == 100_000
  assert rows[0].ccUs == 400_000
  assert rows[0].linkUs == 50_000
  assert rows[0].timestamp == 1000
  assert rows[0].rowVersion == currentCompileCostRowVersion

# ---------------------------------------------------------------------------
# 3. writer isolation: shard lives under ledger/compilecost/, a SIBLING of
#    both ledger/ (exec) and ledger/artifacts/ (artifact stream), never
#    inside either.
# ---------------------------------------------------------------------------

block test_writer_isolation:
  let sd = freshStateDir("isolation")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_iso.nim::")
  var led = openCompileCostLedger(sd)
  append(led, sampleCompileCostRow(ident, 1000))
  closeCompileCostLedger(led)

  var directLedgerShards: seq[string]
  for kind, p in walkDir(sd / "ledger"):
    if kind == pcFile and p.endsWith(".ndjson"):
      directLedgerShards.add p
  assert directLedgerShards.len == 0,
    "writer isolation: expected 0 shards directly under ledger/, got " &
    $directLedgerShards.len

  var costShards: seq[string]
  for kind, p in walkDir(sd / "ledger" / "compilecost"):
    if kind == pcFile and p.endsWith(".ndjson"):
      costShards.add p
  assert costShards.len == 1,
    "writer isolation: expected exactly 1 compilecost shard, got " & $costShards.len

# ---------------------------------------------------------------------------
# 4. torn-row-skip: malformed line tolerated, good rows survive
# ---------------------------------------------------------------------------

block test_torn_row_skip:
  let sd = freshStateDir("tornrow")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_y.nim::")

  var led = openCompileCostLedger(sd)
  append(led, sampleCompileCostRow(ident, 1000))
  closeCompileCostLedger(led)

  var shardFiles: seq[string]
  for kind, p in walkDir(sd / "ledger" / "compilecost"):
    if kind == pcFile and p.endsWith(".ndjson"):
      shardFiles.add p
  assert shardFiles.len == 1, "torn-row-skip: expected exactly 1 shard"
  let shardPath = shardFiles[0]

  let f = open(shardPath, fmAppend)
  f.write("{\"rowVersion\":1,\"entrypointIdentity\":\"tests/unit/test_y.nim::\",\"torn\n")
  f.close()

  var led2 = openCompileCostLedger(sd)
  append(led2, sampleCompileCostRow(ident, 3000))
  closeCompileCostLedger(led2)

  let rows = scanCompileCostLedger(sd)
  assert rows.len == 2, "torn-row-skip: expected 2 good rows, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 3000

echo "test_compilecost: all blocks passed"
