## test_rfc0007_a5_ledger_maxrss.nim — rfc-0007 A5: the ledger gains a
## mechanism-tagged post-exit maxRss column.
##
## §7 "Rusage is a new quantity, not a replacement": the ledger's existing
## `rssBytes` column stays the SAMPLED GROUP-SUM (RFC-0002's admission
## quantity, fed by groupRssBytes poll sampling) — admission/memprobe keep
## consuming exactly that column, unchanged. This slice adds a SECOND,
## DIFFERENT quantity: the per-process max RSS wait4 hands back at reap
## time, folded over reaped descendants — tagged with the mechanism that
## produced it (`"wait4"` today) so a future cgroup `memory.peak` producer
## can supersede it EXPLICITLY (a different mechanism string), never
## silently (the same field quietly meaning something else).
##
## Coverage:
##   1. Live run (through the real entry point, api.runTests) → the ledger
##      row's `maxRssBytes` is a plausible nonzero value and `rssMechanism`
##      reads "wait4" — the wait4 producer (A1b) reaching a NEW, honestly
##      tagged column, not overwriting the existing admission quantity.
##   2. A hand-written OLD-format row (no maxRssBytes/rssMechanism keys at
##      all — the pre-A5 shard shape) parses via the existing
##      getOrDefault-style compat rule: maxRssBytes defaults to 0,
##      rssMechanism defaults to "" (the honest "no mechanism recorded"
##      sentinel) — no crash, no fabricated value.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a5_ledger_maxrss.nim

import std/[os, unittest]
import crisol/api
import crisol/types
import crisol/ledger
import crisol/keys
import crisol/depgraph

import "../support/helpers"

let fixtureDir = currentSourcePath().parentDir().parentDir() / "fixtures"

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        false,
    showProgress:   false,
  )

# ---------------------------------------------------------------------------
# Suite 1 — live run: ledger row carries a real, mechanism-tagged maxRssBytes
# ---------------------------------------------------------------------------

suite "A5 — ledger row carries wait4-tagged maxRssBytes (distinct from rssBytes)":

  test "live pass_always run: ledger row maxRssBytes > 0, rssMechanism == \"wait4\"":
    withTempProject:
      let src = fixtureDir / "pass_always.nim"
      let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
      copyFile(src, dst)

      let rr = runTests(baseOpts(projectRoot))
      check rr.status == rsOk
      check rr.exitCode == 0
      require rr.results.len == 1

      let ep   = rr.results[0].ep
      let iKey = identityKey(ep.path, flagHash(ep.flags))
      let rows = scanLedger(projectRoot / ".crisol", iKey)
      require rows.len == 1
      check rows[0].maxRssBytes > 0
      check rows[0].rssMechanism == "wait4"

# ---------------------------------------------------------------------------
# Suite 2 — old-format row (pre-A5 shape) parses with honest defaults
# ---------------------------------------------------------------------------

suite "A5 — pre-A5 ledger rows (no maxRssBytes/rssMechanism keys) parse cleanly":

  test "hand-written old-format row: maxRssBytes defaults 0, rssMechanism defaults \"\"":
    let sd = getTempDir() / "crisol_a5_ledger_oldformat"
    removeDir(sd)
    createDir(sd)
    defer: removeDir(sd)

    let ident = IdentityKey("tests/unit/test_old.nim::")
    createDir(sd / "ledger")
    let shardPath = sd / "ledger" / "1-oldformat.ndjson"
    writeFile(shardPath,
      "{\"historyFormatVersion\":1}\n" &
      "{\"rowVersion\":1,\"identity\":\"tests/unit/test_old.nim::\",\"timestamp\":1000," &
      "\"inputHash\":\"abc\",\"outcome\":\"passed\",\"attempt\":1,\"durationUs\":5000," &
      "\"rssBytes\":12000}\n")

    let rows = scanLedger(sd, ident)
    require rows.len == 1
    check rows[0].rssBytes == 12000      # unaffected: the pre-existing column
    check rows[0].maxRssBytes == 0       # absent key -> honest default, not fabricated
    check rows[0].rssMechanism == ""     # absent key -> "no mechanism recorded"

when isMainModule:
  echo "test_rfc0007_a5_ledger_maxrss done"
