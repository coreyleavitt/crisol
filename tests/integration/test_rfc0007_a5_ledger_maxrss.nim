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
##   1. Live run (through the real entry point, api.runTests), off the
##      cgroup tier → the ledger row's `maxRssBytes` is a plausible nonzero
##      value and `rssMechanism` reads "wait4" — the wait4 producer (A1b)
##      reaching a NEW, honestly tagged column, not overwriting the
##      existing admission quantity.
##   2. rfc-0007 w4: the SAME live run, ON the delegated cgroup tier →
##      `rssMechanism` reads "memory.peak" instead — `ledgerRssObservation`
##      (ledger.nim) preferring the cgroup leaf's own leaf-wide peak over
##      wait4, tagged EXPLICITLY. Gated/self-skipping exactly like every
##      other cgroup-tier suite in this repo (delegation is only real in
##      the CI `cgroup` job — see tests/integration/test_rfc0007_b3_cgroup.
##      nim's header for the topology); this file's own suite 1 ALSO
##      skips when the cgroup tier is genuinely active, since production
##      selects the tier automatically for every spawn once delegation is
##      real — there is no per-run knob to force one tier while proving
##      the other, so the two suites below are mutually exclusive by
##      environment, never both exercising their live-run assertion in the
##      same process.
##   3. A hand-written OLD-format row (no maxRssBytes/rssMechanism keys at
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
import crisol/process

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

proc cgroupTierActive(): bool =
  ## rfc-0007 w4: mirrors `cgroupTierUsable` (process/posixcore.nim) — the
  ## EXACT predicate `spawnChild` gates the cgroup tier on. Inlined here
  ## rather than imported: `cgroupTierUsable` lives in
  ## `process/posixcore.nim`, which `process/posix.nim` does not
  ## re-export (only `export types`) — a caller outside `process/` cannot
  ## reach it directly. `capabilities()` (the cross-platform barrel
  ## export every backend provides) is the correct level for an
  ## integration test to consult, same as every other cgroup-gated
  ## integration test in this repo (e.g. test_rfc0007_w1_cgroup_kill_gate.
  ## nim's own `capabilities().cgroupDelegation` gate).
  let caps = capabilities()
  caps.cgroupDelegation and caps.cgroupKill

proc runPassAlwaysAndScanLedger(): seq[LedgerRow] =
  ## Shared by both live-run suites below (wait4-tier and cgroup-tier) —
  ## the exact same fixture/run/scan sequence, only the environment (and
  ## therefore the tier production selects) differs between them.
  withTempProject:
    let src = fixtureDir / "pass_always.nim"
    let dst = projectRoot / "tests" / "unit" / "test_pass_always.nim"
    copyFile(src, dst)

    let rr = runTests(baseOpts(projectRoot))
    doAssert rr.status == rsOk
    doAssert rr.exitCode == 0
    doAssert rr.results.len == 1

    let ep   = rr.results[0].ep
    let iKey = identityKey(ep.tp, rr.trackedRoots, flagHash(ep.flags))
    result = scanLedger(projectRoot / ".crisol", iKey)

# ---------------------------------------------------------------------------
# Suite 1 — live run, non-cgroup tier: ledger row carries a real,
# wait4-tagged maxRssBytes
# ---------------------------------------------------------------------------

suite "A5 — ledger row carries wait4-tagged maxRssBytes (distinct from rssBytes)":

  test "live pass_always run: ledger row maxRssBytes > 0, rssMechanism == \"wait4\"":
    if cgroupTierActive():
      # rfc-0007 w4: on a host where the cgroup tier is genuinely selected
      # (today: only the CI `cgroup` job's --privileged delegation), EVERY
      # spawn — including this one — takes the cgroup tier automatically,
      # so `memory.peak` now wins this row's mechanism tag per
      # `ledgerRssObservation`'s preference; this specific "wait4 is the
      # tag" assertion is proven only OFF that tier. The suite below
      # proves the cgroup-tier case explicitly. Skip here rather than
      # silently branching the assertion — the visible-skip convention
      # every other cgroup-gated test in this repo already uses.
      skip()
    else:
      let rows = runPassAlwaysAndScanLedger()
      require rows.len == 1
      check rows[0].maxRssBytes > 0
      check rows[0].rssMechanism == "wait4"

# ---------------------------------------------------------------------------
# Suite 1b — rfc-0007 w4: live run, delegated cgroup tier: ledger row
# carries a real, memory.peak-tagged maxRssBytes
# ---------------------------------------------------------------------------

suite "rfc-0007 w4 — cgroup tier: ledger row carries memory.peak-tagged maxRssBytes":

  test "live pass_always run on the delegated cgroup tier: ledger row maxRssBytes > 0, rssMechanism == \"memory.peak\"":
    if not cgroupTierActive():
      # PINNED here — compiles and self-skips honestly everywhere
      # delegation is absent (rootless dev/podman, every CI leg except
      # `cgroup`) — same convention as test_rfc0007_b3_cgroup.nim's every
      # suite. PROVEN only on the CI `cgroup` job (docker run
      # --privileged; see that file's header for the topology), where
      # this test actually runs the live-run branch below and asserts
      # against a real kernel-maintained `memory.peak`.
      skip()
    else:
      let rows = runPassAlwaysAndScanLedger()
      require rows.len == 1
      check rows[0].maxRssBytes > 0
      check rows[0].rssMechanism == "memory.peak"

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
