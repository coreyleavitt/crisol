## test_rfc9_bucket_inventory.nim — RFC-0009 Stage B `B-inventory`.
##
## The AUDITABLE work order for the Windows de-POSIX sweep (B1..B3c). Every
## test file that imports `std/posix` is pinned into exactly one bucket by the
## posix API it actually calls, and this meta-test asserts that the union of
## the buckets equals the LIVE result of the pinned sweep regex over `tests/**`
## — so no file can silently fall through the cracks, and any newly-added
## `std/posix` import fails this test until it is triaged into a bucket.
##
## The sweep regex (RFC-0009 round-3, R3-26): `^\s*(import|from).*\bposix\b`.
## A literal `std/posix` substring undercounts (59); a looser match overcounts
## (78); this regex is the one the inventory is defined against.
##
## Buckets and their Stage-B treatment:
##   B1  — Category E: the file's ONLY posix use is `getpid()` (temp-path
##         uniqueness). Fix: `os.getCurrentProcessId`. Trivial, compiles on
##         Windows and RUNS there.
##   B2  — Categories A+B: process-control + signal (fork/exec/waitpid/kill/
##         setsid/setpgid/sigaction/SIG*). These legitimately exercise the
##         POSIX process backend; wrapped `when defined(posix)` with an else
##         skip — they COMPILE on Windows and skip by design.
##   B3a — Category C: filesystem / FD plumbing (stat/S_IS*/open/close/dup).
##         The dominant sub-idiom is `captureBoth` (dup/dup2 this process's own
##         stdout/stderr onto a temp file around an in-process `runMain`); its
##         intent is portable output capture, so it converts to std/syncio and
##         the CLI test RUNS on Windows. Genuinely POSIX-only FD-redirection
##         stays gated.
##   B3b — Category C: rlimit. Gated `when defined(posix)`.
##
## Audited 2026-09-14 (RFC-0009 A-final-ii follow-on). The counts below
## supersede the RFC's informal estimates (B1 ~3, B2 52, B3a ≤16, B3b ~3):
## classifying by the literal dominant posix API — reading past comments,
## docstrings, and test-name strings — yields 13/23/38/1 at the B4 audit; rfc-0007 review round 1 (2026-09-18) added five B2 files (r2/r3/r5 tests + reparented-helper fixtures) -> 13/28/38/1 (test_conformance_timing.nim moved B1->B2 during B1: it uses SIGKILL/SIGINT, not getpid-only). The two large
## shifts are real: `getpid`-only tests (B1) and the `captureBoth` FD-capture
## idiom (B3a) are each far more common than the thematic estimate assumed,
## and NO test in-tree calls `setrlimit` directly (limits flow through
## crisol's own `RlimitOverrides`/`--rlimit-*` API), so B3b is one fixture.
##
## B3c (hidden posix-ASSUMING tests: hard-coded /tmp, /bin/sh, /proc, chmod,
## /dev/null, and the createSymlink sub-bucket) is deliberately NOT part of
## this union — those files are import-clean (they do not match the sweep
## regex) and are inventoried by their own slice.

import std/[os, strutils, algorithm, sequtils, unittest]

const thisDir = currentSourcePath().parentDir()
const repoRoot = thisDir.parentDir.parentDir
const testsRoot = repoRoot / "tests"

# --- B1: getpid-only (13) --------------------------------------------------
const B1 = [
  "tests/integration/test_closure_record_failure.nim",
  "tests/integration/test_closure_searchpath.nim",
  "tests/integration/test_nimcache_persistence_real.nim",
  "tests/integration/test_rfc0007_a2c_projectroot_cwd.nim",
  "tests/integration/test_env_scrub_integration.nim",
  "tests/integration/test_rfc0007_a2a_supervisor.nim",
  "tests/integration/test_scratch_tmpdir.nim",
  "tests/integration/test_m6_teardown.nim",
  "tests/unit/test_c0_clean_stores.nim",
  "tests/unit/test_a1c_gc.nim",
  "tests/unit/test_artifactledger_gc.nim",
  "tests/unit/test_compilecost_gc.nim",
  "tests/fixtures/hang_with_pid.nim",
]

# --- B2: process-control + signal → when defined(posix) gate (28) ----------
const B2 = [
  "tests/fixtures/self_sigkill.nim",
  "tests/fixtures/spawn_grandchild.nim",
  "tests/fixtures/spawn_reparented_helper.nim",
  "tests/fixtures/spawn_reparented_helper_peer.nim",
  "tests/fixtures/spawn_grandchild_setsid.nim",
  "tests/fixtures/spawn_late_orphan.nim",
  "tests/fixtures/spawn_pgroup_child.nim",
  "tests/fixtures/term_cooperative.nim",
  "tests/fixtures/term_ignores.nim",
  "tests/integration/test_cachelocalfs_concurrent.nim",
  "tests/integration/test_clean.nim",
  "tests/integration/test_rfc0007_a1f_authorship.nim",
  "tests/integration/test_rfc0007_a4_signals.nim",
  "tests/integration/test_rfc0007_a6a_cli.nim",
  "tests/integration/test_rfc0007_a6b_cli.nim",
  "tests/integration/test_rfc0007_r5_drain_interrupt.nim",
  "tests/integration/test_signal.nim",
  "tests/integration/test_so2_drain_interrupt.nim",
  "tests/timing/test_interrupt_e2e.nim",
  "tests/timing/test_rfc0007_a1f_limit_timing.nim",
  "tests/timing/test_rfc0007_a2b_shared_grace.nim",
  "tests/timing/test_rfc0007_b1b_late_orphan.nim",
  "tests/unit/test_rfc0007_a6a_escapee_evidence.nim",
  "tests/unit/test_rfc0007_r2_cross_slot_escapee.nim",
  "tests/unit/test_run_tests.nim",
  "tests/unit/test_process_capabilities.nim",
  "tests/conformance/test_conformance_timing.nim",
  "tests/conformance/test_rfc0007_r3_library_embedding.nim",
]

# --- B3a: filesystem / FD plumbing → std/os,syncio (or gate) (38) ----------
const B3a = [
  # captureBoth dup2 stdout-capture idiom (28)
  "tests/integration/test_a0_env_pin_cli.nim",
  "tests/integration/test_a3c2_no_remote_cache_cli.nim",
  "tests/integration/test_b1c_explain_miss_cli.nim",
  "tests/integration/test_b2b_cache_stats_cli.nim",
  "tests/integration/test_b3b_verify_cache.nim",
  "tests/integration/test_b3c_verify_cache_cli.nim",
  "tests/integration/test_changed.nim",
  "tests/integration/test_cli_closure.nim",
  "tests/integration/test_cli_group.nim",
  "tests/integration/test_cli_list.nim",
  "tests/integration/test_cli_run.nim",
  "tests/integration/test_cli_s4.nim",
  "tests/integration/test_cli_s5.nim",
  "tests/integration/test_issue11_closure_inputs.nim",
  "tests/integration/test_issue11_externals.nim",
  "tests/integration/test_issue12_clean_gc.nim",
  "tests/integration/test_issue13_load_guard.nim",
  "tests/integration/test_issue13_persist_failure.nim",
  "tests/integration/test_issue14_render_sanitize.nim",
  "tests/integration/test_issue16_headers.nim",
  "tests/integration/test_matrix_legs.nim",
  "tests/integration/test_rfc0007_a1d2_cache_replay.nim",
  "tests/integration/test_rfc0007_a5_rusage_limits_wire.nim",
  "tests/integration/test_rfc0007_a7_substrate_cli.nim",
  "tests/integration/test_rfc9_a2_trackedroots_cli.nim",
  "tests/integration/test_verifycache_records_diverge.nim",
  "tests/integration/test_zero_runnable.nim",
  "tests/unit/test_resultcache.nim",
  # other filesystem / FD (9)
  "tests/integration/test_cli_s6.nim",
  "tests/integration/test_httpraw_real.nim",
  "tests/integration/test_rfc0007_a1b_kill_path.nim",
  "tests/integration/test_rfc0007_b3_cgroup.nim",
  "tests/unit/test_depgraph.nim",
  "tests/unit/test_ioutils.nim",
  "tests/unit/test_api.nim",
  "tests/unit/test_jsonout.nim",
  "tests/fixtures/overlap_probe.nim",
  # RFC-mandated explicit inclusion — the harness itself (1)
  "tests/conformance/test_conformance.nim",
]

# --- B3b: rlimit → when defined(posix) gate (1) ----------------------------
const B3b = [
  "tests/fixtures/rlimit_nofile.nim",
]

proc allBucketed(): seq[string] =
  result = @B1 & @B2 & @B3a & @B3b

proc containsPosixWord(line: string): bool =
  ## `\bposix\b` — "posix" bounded by non-identifier chars.
  var i = 0
  while true:
    let idx = line.find("posix", i)
    if idx < 0: return false
    let before = if idx == 0: ' ' else: line[idx - 1]
    let afterIdx = idx + 5
    let after = if afterIdx >= line.len: ' ' else: line[afterIdx]
    proc isIdent(c: char): bool = c.isAlphaNumeric or c == '_'
    if not isIdent(before) and not isIdent(after): return true
    i = idx + 5

proc posixImporters(): seq[string] =
  ## LIVE sweep: repo-relative paths under tests/** whose source has a line
  ## matching `^\s*(import|from).*\bposix\b`.
  for path in walkDirRec(testsRoot):
    if not path.endsWith(".nim"): continue
    for line in lines(path):
      let s = line.strip()
      if (s.startsWith("import") or s.startsWith("from")) and containsPosixWord(s):
        result.add path.relativePath(repoRoot).replace('\\', '/')
        break
  result.sort()

suite "RFC-0009 B-inventory — posix-bucket work order":

  test "the four buckets are disjoint (no file in two buckets)":
    let seen = allBucketed()
    let uniq = seen.deduplicate()
    check seen.len == uniq.len
    if seen.len != uniq.len:
      for f in uniq:
        if seen.count(f) > 1: echo "  DUPLICATE across buckets: " & f

  test "bucket sizes match the audited inventory (13 / 28 / 38 / 1)":
    check B1.len == 13
    check B2.len == 28
    check B3a.len == 38
    check B3b.len == 1

  test "every file in the LIVE std/posix sweep is bucketed (completeness)":
    # COMPLETENESS, not equality: the buckets are a FROZEN audit of the 75
    # files that imported std/posix at B-inventory time, and they are the
    # permanent work order. As the sweep slices run, files leave the live set
    # — B1 (getpid→getCurrentProcessId) and the B3a captureBoth conversions
    # drop their posix import entirely, while B2/B3b stay in the sweep behind
    # a `when defined(posix)` gate. So `union == live` only held at
    # B-inventory time; the durable invariant is `live ⊆ union`: no test may
    # import std/posix without being in the inventory. A newly-added posix
    # import therefore fails this test until it is triaged into a bucket, and
    # the frozen `union.len == 75` pin below catches a mangled bucket const.
    let union = allBucketed()
    let live = posixImporters()
    var untracked: seq[string]
    for f in live:
      if f notin union: untracked.add f
    for f in untracked:
      echo "  IN SWEEP, NOT BUCKETED (triage into a B-bucket): " & f
    check untracked.len == 0
    echo "  (sweep progress: " & $live.len & "/" & $union.len &
         " audited files still import std/posix)"
    # (tests/support/ is kept posix-free by test_conformance_import_purity.nim,
    # RFC-0009 B-inventory's extension of the existing import-purity meta-test.)

  test "the audited inventory total is frozen at 80 (13 + 28 + 38 + 1)":
    check allBucketed().len == 80

when isMainModule:
  echo "test_rfc9_bucket_inventory done"
