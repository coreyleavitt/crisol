## test_ledger.nim — A1b: RunLedger store (RFC-0004 F1).
##
## TDD: tests written first (RED), then ledger.nim written to make them pass.
##
## Coverage:
##   1. roundtrip: append rows → scanLedger returns them equal, time-ordered.
##   2. identity filter: scanLedger(identity) returns only that identity's rows;
##      multiple identities coexist in the same shard.
##   3. cross-shard reads: two Ledger handles (two shard files) → scan sees both.
##   4. torn-row-skip: hand-appended malformed line → scan skips it (warns),
##      good rows still returned, no exception raised.
##   5. unknown rowVersion → row skipped, others returned.
##   6. header-version mismatch shard → whole shard discarded; other shards read.
##   7. concurrent-invocation (no torn rows): two Ledger handles appending
##      interleaved rows both survive intact — the per-shard design precludes
##      cross-shard contention.

import std/[os, sequtils, strutils]
import crisol/types
import crisol/ledger

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_ledger_" & name)
  removeDir(result)
  createDir(result)

proc sampleRow(identity: IdentityKey; ts: int64; inputHash = "abc123";
               outcome = "passed"; attempt = 1; dur = 5000i64; rss = 12000i64): LedgerRow =
  LedgerRow(
    identity:   identity,
    timestamp:  ts,
    inputHash:  inputHash,
    outcome:    outcome,
    attempt:    attempt,
    durationUs: dur,
    rssBytes:   rss,
    rowVersion: 1,
  )

# ---------------------------------------------------------------------------
# 1. roundtrip
# ---------------------------------------------------------------------------

block test_roundtrip:
  let sd = freshStateDir("roundtrip")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_foo.nim::")
  var led = openLedger(sd)
  let r1 = sampleRow(ident, 1000)
  let r2 = sampleRow(ident, 2000, outcome = "failed", attempt = 2)
  append(led, r1)
  append(led, r2)
  closeLedger(led)

  let rows = scanLedger(sd, ident)
  assert rows.len == 2, "roundtrip: expected 2 rows, got " & $rows.len
  # time-ordered
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 2000
  assert rows[0].identity == ident
  assert rows[0].outcome == "passed"
  assert rows[0].attempt == 1
  assert rows[0].durationUs == 5000
  assert rows[0].rssBytes == 12000
  assert rows[1].outcome == "failed"
  assert rows[1].attempt == 2

# ---------------------------------------------------------------------------
# 2. identity filter
# ---------------------------------------------------------------------------

block test_identity_filter:
  let sd = freshStateDir("identity")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_alpha.nim::")
  let identB = IdentityKey("tests/unit/test_beta.nim::")

  var led = openLedger(sd)
  append(led, sampleRow(identA, 100))
  append(led, sampleRow(identB, 200))
  append(led, sampleRow(identA, 300))
  closeLedger(led)

  let rowsA = scanLedger(sd, identA)
  assert rowsA.len == 2, "identity filter A: expected 2, got " & $rowsA.len
  for r in rowsA:
    assert r.identity == identA, "identity filter: got wrong identity"

  let rowsB = scanLedger(sd, identB)
  assert rowsB.len == 1, "identity filter B: expected 1, got " & $rowsB.len
  assert rowsB[0].timestamp == 200

# ---------------------------------------------------------------------------
# 3. cross-shard reads
# ---------------------------------------------------------------------------

block test_cross_shard:
  let sd = freshStateDir("crossshard")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_x.nim::")

  # Simulate two separate process invocations via two Ledger handles.
  # Each writes its own shard file (different pid-bootId name).
  var led1 = openLedger(sd)
  append(led1, sampleRow(ident, 1000))
  closeLedger(led1)

  # Second handle — openLedger generates a fresh shard name.
  # We force a distinct name by waiting a microsecond or simply rely on the
  # implementation using a unique handle ID per open.
  var led2 = openLedger(sd)
  append(led2, sampleRow(ident, 2000))
  closeLedger(led2)

  let rows = scanLedger(sd, ident)
  # Both shards contribute their row.
  assert rows.len == 2, "cross-shard: expected 2 rows, got " & $rows.len
  let ts = rows.mapIt(it.timestamp)
  assert 1000 in ts, "cross-shard: missing row from shard 1"
  assert 2000 in ts, "cross-shard: missing row from shard 2"

# ---------------------------------------------------------------------------
# 4. torn-row-skip
# ---------------------------------------------------------------------------

block test_torn_row_skip:
  let sd = freshStateDir("tornrow")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_y.nim::")

  var led = openLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeLedger(led)

  # Hand-inject a malformed line into the shard file.
  let shardFiles = block:
    var sf: seq[string]
    for kind, p in walkDir(sd / "ledger"):
      if kind == pcFile and p.endsWith(".ndjson"):
        sf.add p
    sf
  assert shardFiles.len == 1, "torn-row-skip: expected exactly 1 shard"
  let shardPath = shardFiles[0]

  # Append a truncated/malformed JSON line after the good row.
  let f = open(shardPath, fmAppend)
  f.write("{\"rowVersion\":1,\"identity\":\"tests/unit/test_y.nim::\",\"torn\n")
  f.close()

  # Append another valid row AFTER the torn one (requires a new shard or re-open).
  var led2 = openLedger(sd)
  append(led2, sampleRow(ident, 3000))
  closeLedger(led2)

  # scanLedger must skip the malformed line and return the two good rows.
  let rows = scanLedger(sd, ident)
  assert rows.len == 2, "torn-row-skip: expected 2 good rows, got " & $rows.len
  assert rows[0].timestamp == 1000
  assert rows[1].timestamp == 3000

# ---------------------------------------------------------------------------
# 5. unknown rowVersion → row skipped
# ---------------------------------------------------------------------------

block test_unknown_rowversion:
  let sd = freshStateDir("rowversion")
  defer: removeDir(sd)

  let ident = IdentityKey("tests/unit/test_z.nim::")

  var led = openLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeLedger(led)

  # Hand-inject a row with an unknown rowVersion (99).
  let shardFiles = block:
    var sf: seq[string]
    for kind, p in walkDir(sd / "ledger"):
      if kind == pcFile and p.endsWith(".ndjson"):
        sf.add p
    sf
  let shardPath = shardFiles[0]
  let f = open(shardPath, fmAppend)
  f.write("{\"rowVersion\":99,\"identity\":\"tests/unit/test_z.nim::\",\"timestamp\":2000,\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":5000,\"rssBytes\":12000}\n")
  f.close()

  let rows = scanLedger(sd, ident)
  assert rows.len == 1, "unknown rowVersion: expected 1 row (bad version skipped), got " & $rows.len
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 6. header-version mismatch → whole shard discarded
# ---------------------------------------------------------------------------

block test_header_version_mismatch:
  let sd = freshStateDir("hdrver")
  defer: removeDir(sd)

  # Create a good shard via the normal API.
  let ident = IdentityKey("tests/unit/test_hdr.nim::")
  var led = openLedger(sd)
  append(led, sampleRow(ident, 1000))
  closeLedger(led)

  # Manually create a second shard file with a mismatched header version.
  createDir(sd / "ledger")
  let badShardPath = sd / "ledger" / "99999-badbad.ndjson"
  let f = open(badShardPath, fmWrite)
  f.write("{\"historyFormatVersion\":9999}\n")
  f.write("{\"rowVersion\":1,\"identity\":\"tests/unit/test_hdr.nim::\",\"timestamp\":2000,\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":5000,\"rssBytes\":12000}\n")
  f.close()

  # Only the good shard's row should appear; the mismatched shard is discarded.
  let rows = scanLedger(sd, ident)
  assert rows.len == 1, "header-version mismatch: expected 1 row (bad shard discarded), got " & $rows.len
  assert rows[0].timestamp == 1000

# ---------------------------------------------------------------------------
# 7. concurrent-invocation (no torn rows)
# ---------------------------------------------------------------------------

block test_concurrent_no_torn_rows:
  ## Two Ledger handles append interleaved rows to SEPARATE shard files.
  ## After close, both shards are intact (no cross-contamination).
  ## This is the core design proof: per-shard isolation = no shared file =
  ## no cross-process contention, no torn rows.
  let sd = freshStateDir("concurrent")
  defer: removeDir(sd)

  let identA = IdentityKey("tests/unit/test_ca.nim::")
  let identB = IdentityKey("tests/unit/test_cb.nim::")

  var ledA = openLedger(sd)
  var ledB = openLedger(sd)

  # Interleave appends across both handles.
  for i in 1..5:
    append(ledA, sampleRow(identA, int64(i * 100)))
    append(ledB, sampleRow(identB, int64(i * 100 + 50)))

  closeLedger(ledA)
  closeLedger(ledB)

  # Each identity should have exactly 5 intact, contiguous rows.
  let rowsA = scanLedger(sd, identA)
  let rowsB = scanLedger(sd, identB)

  assert rowsA.len == 5, "concurrent: identA expected 5 rows, got " & $rowsA.len
  assert rowsB.len == 5, "concurrent: identB expected 5 rows, got " & $rowsB.len

  # Verify time-ordering and values are intact.
  for i in 0 ..< 5:
    assert rowsA[i].timestamp == int64((i + 1) * 100),
      "concurrent: identA row " & $i & " timestamp wrong"
    assert rowsB[i].timestamp == int64((i + 1) * 100 + 50),
      "concurrent: identB row " & $i & " timestamp wrong"

  # Verify no cross-contamination: identA rows have identA, identB rows have identB.
  for r in rowsA: assert r.identity == identA, "concurrent: cross-contamination in A"
  for r in rowsB: assert r.identity == identB, "concurrent: cross-contamination in B"
