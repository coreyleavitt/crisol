#!/usr/bin/env bash
# ci/assert-subset-honesty.sh — RFC-0009 B4b completion-gate assertion.
#
# Usage: ci/assert-subset-honesty.sh <captured-harness-log> <leg-name>
#   <leg-name> is "windows" or "macos" — the two legs whose CRISOL_TEST_DIRS
#   includes tests/unit:tests/conformance (B4b widens the windows leg to
#   match the macos leg's own long-standing unit+conformance scope) and
#   therefore actually exercise the posix-gated skip/run behavior this
#   script checks. It is not meaningful on the Linux `test`/`cgroup`/`timing`
#   jobs: those never run the widened tests/unit:tests/conformance sweep as
#   a single pass, and posix is always defined there, so nothing in scope
#   ever hits an `else` skip branch.
#
# Asserts three things, by NAME rather than by count (RFC-0009 round-3 R3-19
# — a count-equality check would pass against a DIFFERENT set of skips,
# hiding a regression where a load-bearing identity test silently starts
# skipping while an unrelated file starts running in its place):
#
#   1. EXPECTED-SKIP: the set of `CRISOL-SKIP: <path>` markers observed in
#      the harness log exactly equals the pinned per-leg expected-skip set
#      below (whole-FILE self-skips: the entrypoint prints nothing else).
#   2. EXPECTED-SKIP-TEST (S5 wiring-audit fix; broadened by the CR6/CR2-
#      followup/W5d honesty-defect fixes, 2026-09-21): the set of
#      `CRISOL-SKIP-TEST: <path>#<label>` markers observed exactly equals the
#      pinned per-leg expected set below (per-test/per-block self-skips
#      inside a file whose other tests still run for real). The ORIGINAL S5
#      instances all share one shape: the file calls
#      tests/support/symlinkprobe.nim's `symlinksAvailable()` and self-skips
#      only the individual test/block via unittest `skip()` when this
#      environment cannot create a symlink (windows-latest lacks
#      SeCreateSymbolicLinkPrivilege in some historical runs, so these were
#      EXPECTED there; macos-latest (APFS) has it, so these MUST run for
#      real there — same leg-aware shape as A5c below; empirically, per the
#      windows-leg comment below, the CURRENT windows-latest image also has
#      the privilege, so even the symlink-gated set is EMPTY today). The
#      CR6/CR2-followup/W5d fixes reuse the SAME `CRISOL-SKIP-TEST` marker
#      for other per-test self-skip REASONS that are not symlink-shaped at
#      all (a POSIX-only assertion, a documented Windows-only known
#      divergence, a case-fold-volume-dependent fixture, an
#      environment-capability probe such as hardlink/random-byte
#      availability) — the vocabulary is "this ONE test in an otherwise-live
#      file self-skipped, honestly, for a NAMED reason", not "symlinks
#      specifically"; see each pinned entry below for its own reason.
#   3. MUST-EXECUTE: the three load-bearing identity conformance tests
#      (A3b-ii, A4b, A5c) ran their REAL body, not a self-skip.
#
# Source of truth for what CAN skip: tests/conformance/test_rfc9_bucket_
# inventory.nim's B2 (process/signal) and B3b (rlimit) buckets — the only
# buckets that are WHOLE-FILE `when defined(posix)` gated (B1 and the bulk
# of B3a were converted to run for real everywhere; B3a's one remaining
# posix import, tests/unit/test_ioutils.nim, gates only two of its ~20
# blocks, so the file as a whole still runs real assertions and is
# deliberately NOT in either EXPECTED_SKIP list below). Every EXPECTED_SKIP
# entry here is a B2/B3b file that additionally happens to live under
# tests/unit/ or tests/conformance/ — the only two directories either leg's
# CRISOL_TEST_DIRS actually sweeps; the rest of B2/B3b lives under
# tests/fixtures/, tests/integration/, or tests/timing/, which are out of
# scope for both legs (see ci.yml's B4b step comment) and never emit a
# CRISOL-SKIP marker into either leg's harness log.
set -uo pipefail

LOG="${1:?usage: assert-subset-honesty.sh <harness-log-path> <leg-name>}"
LEG="${2:?usage: assert-subset-honesty.sh <harness-log-path> <leg-name>}"

if [ ! -f "$LOG" ]; then
  echo "assert-subset-honesty.sh: harness log not found: $LOG" >&2
  exit 1
fi

fail=0

case "$LEG" in
  windows)
    # windows-latest is NOT posix: every `when defined(posix)` whole-file
    # gate (B2 + B3b) takes its `else` branch. Of that set, these files
    # fall inside tests/unit:tests/conformance (W1's cgroup-kill-gate unit
    # test joined 2026-09-18 — posix-only, whole-file gated).
    # test_conformance.nim is the POSIX process-backend conformance suite: it
    # COMPILES on windows (B3a-ii de-POSIX'd its imports) but its assertions
    # are POSIX-semantic (ekSignaled/.sig, rlimit lsApplied, process-group
    # kill domains), so it self-skips `when not defined(posix)` — the Windows
    # backend is proven by the per-file test_windows_* suite instead. It is
    # NOT in the B2/B3b import buckets (it imports no std/posix any more), but
    # it IS a posix-backend-category skip on windows, so it belongs here.
    #
    # W5b/W5c (code-review ledger, 2026-09-21): test_memprobe.nim and
    # test_rfc0007_b2_fd_leak.nim are both whole-file `when defined(linux):`
    # gated (real /proc+cgroup parsing and pidfd/epoll fd-leak introspection
    # respectively — neither has a portable equivalent), so both take their
    # `else` branch and self-skip on windows exactly like the B2/B3b files
    # above. Newly marked with CRISOL-SKIP; previously silent (W5b a bespoke
    # unmarked echo, W5c missing an else branch entirely — its `done` line
    # printed unconditionally, asserting nothing).
    EXPECTED_SKIP="$(cat <<'EOF'
tests/conformance/test_conformance.nim
tests/conformance/test_conformance_timing.nim
tests/unit/test_memprobe.nim
tests/unit/test_process_capabilities.nim
tests/unit/test_rfc0007_a6a_escapee_evidence.nim
tests/unit/test_rfc0007_b2_fd_leak.nim
tests/unit/test_rfc0007_r2_cross_slot_escapee.nim
tests/unit/test_rfc0007_r9_probe_flock.nim
tests/unit/test_rfc0007_r10_cgroup_kill_degrade.nim
tests/unit/test_rfc0007_r11_bounded_readback.nim
tests/unit/test_rfc0007_r12_cgroup_killsnapshot.nim
tests/unit/test_rfc0007_r59_cgroup_reap_backstop.nim
tests/unit/test_rfc0007_w4_cgroup_memory_peak.nim
tests/unit/test_rfc0007_r60_preexisting_identity.nim
tests/unit/test_rfc0007_r69_signal_restore.nim
tests/unit/test_rfc0007_w1_cgroup_kill_gate.nim
tests/unit/test_run_tests.nim
tests/conformance/test_rfc0007_r3_library_embedding.nim
EOF
)"
    # S5 wiring-audit fix, re-pinned empirically (CI run 35207827512,
    # 2026-09-17): the current windows-latest image CAN create symlinks in
    # the temp-dir probes (`symlinkprobe.nim`'s file symlink AND
    # test_closure_a4a's directory symlink both succeed), so every
    # symlinksAvailable()-gated test/block runs its REAL body on this leg
    # and the expected per-test skip set is EMPTY — the markers exist so
    # that a future runner-image regression (privilege revoked again)
    # fails THIS gate loudly instead of skipping silently; re-pin the set
    # below to the observed markers if that happens. (A5c is unrelated:
    # its own in-fixture directory-symlink probe still fails on this
    # image and its documented skip is accepted leg-aware, below.) The
    # six marker-bearing sites, for re-pinning:
    #   tests/unit/test_depgraph.nim#test_saveDepGraph_symlink_write_through_protection
    #   tests/unit/test_discover.nim#symlinked_dir_not_followed
    #   tests/unit/test_ioutils.nim#test_createoverwrite_nofollow_refuses_symlink
    #   tests/unit/test_ioutils.nim#test_writeguardedfile_overwrite_true_still_refuses_symlink
    #   tests/unit/test_jsonout.nim#p3_symlink_safe_temp_write
    #   tests/unit/test_rfc9_a2_config.nim#dep_roots_alias_symlink_cekConfig
    #
    # CR6/W5d (code-review ledger, 2026-09-21): four NEW per-test skips that
    # are NOT symlink-gated (see the header comment above) and, unlike the
    # symlink set immediately above, DO fire on this leg today:
    #
    #   - tests/integration/test_issue23_cc_identity.nim#posix_cc_half_content_fingerprint
    #     (CR6) is `when defined(posix): ... else: skip()` -- windows is
    #     never posix, so this ALWAYS fires here. Reaches this log only
    #     because the wiring-audit W9i fix now appends that per-file step's
    #     output into harness.log; before that fix this marker existed in
    #     the test binary's own stdout but had no producer into the log the
    #     gate reads at all.
    #   - tests/unit/test_source_index.nim#mangling_escape_colon_hash_windows_excluded
    #     is `when defined(windows): skip()` (unconditional on this leg) --
    #     NTFS categorically forbids ':' in a filename, so this ALWAYS fires.
    #   - tests/unit/test_paths.nim#classify_symlinked_deproot_realabs_windows_known_divergence
    #     is likewise `when defined(windows): skip()` (a documented,
    #     undiagnosed Windows-only divergence in `classify`'s realAbs match
    #     -- see the test's own comment) -- ALWAYS fires here. Its sibling
    #     per-test label (`..._no_symlink_privilege`, the nested
    #     `if not symlinksAvailable(): skip()` in the file's `else` arm) is
    #     deliberately NOT pinned: windows always takes the `when
    #     defined(windows)` branch above it first, so that second skip()
    #     site is unreachable code on this leg and can never emit its own
    #     marker here.
    #   - tests/unit/test_fold_probe_tiers.nim#t2_flipped_absent and
    #     tests/unit/test_fold_probe_tiers.nim#t2_flipped_distinct both skip
    #     `if volumeIsCaseInsensitive` -- windows-latest NTFS is
    #     case-insensitive (same fact the A3b-ii/A4b steps above rely on),
    #     so both ALWAYS fire here. test_fold_probe_tiers.nim's other six
    #     skip() sites (same-file/hardlink fold, dangling-symlink
    #     fall-through, root-unwritable, pre-placed-symlink-refused,
    #     probe-basename-random-suffix) each depend on a capability
    #     (hardlink creation, symlink creation, chmod actually restricting a
    #     non-root user, a working RNG) that this leg genuinely HAS, so none
    #     of those six are expected to skip here and none are pinned.
    #   - tests/integration/test_issue16_headers.nim#gcc_clang_case_mismatch_producer
    #     (CR2-followup) skips `if not gccCaseVolumeIsInsensitive()` -- NTFS
    #     IS case-insensitive, so this does NOT skip on windows (it runs for
    #     real, same as the file's other suites) and is deliberately NOT
    #     pinned here.
    #
    # R8-L1 (round-8 review, 2026-09-25): test_r8_real_cl_refusal.nim's two
    # labels (#real_cl_refused_under_cl_env, #real_cl_known_without_cl_env)
    # are DELIBERATELY absent from this set. ci.yml's windows step imports
    # vcvars64 so `cl` resolves, and the file's real body is MUST-EXECUTE
    # below; either skip marker appearing on this leg is a failure here.
    #
    # R3-5 (code-review round 3, 2026-09-24): test_depgraph_guard.nim's
    # "unreadable-but-present depgraph" case gates on
    # `fileExists("/proc/self/mem")` and there is no procfs on windows, so it
    # skips here every run. It was a BARE `skip()` — printing nothing, therefore
    # invisible to this gate in BOTH directions — and it predates the
    # workstream, so the W5 audit that added eight marker sites walked past it.
    # Now marked and pinned on this leg and on macos (neither has /proc; the
    # trigger is a platform fact, not a capability probe, so the pin cannot
    # flap).
    EXPECTED_SKIP_TEST="$(cat <<'EOF'
tests/integration/test_issue23_cc_identity.nim#posix_cc_half_content_fingerprint
tests/unit/test_source_index.nim#mangling_escape_colon_hash_windows_excluded
tests/unit/test_paths.nim#classify_symlinked_deproot_realabs_windows_known_divergence
tests/unit/test_fold_probe_tiers.nim#t2_flipped_absent
tests/unit/test_fold_probe_tiers.nim#t2_flipped_distinct
tests/unit/test_ccprobe.nim#cc_half_content_fingerprint_realenv
tests/unit/test_ccprobe.nim#realrun_execv_no_shell_splitting
tests/unit/test_ccprobe.nim#realrunin_subprocess_cwd
tests/unit/test_ccprobe.nim#lastprobestderr_w9a_nonmerged
tests/unit/test_depgraph_guard.nim#f4_unreadable_depgraph_needs_procfs
EOF
)"
    ;;
  macos)
    # macos-latest (Darwin) IS posix: every `when defined(posix)` gate takes
    # its REAL branch here, same as Linux — nothing in B2/B3b skips on this
    # leg, so the expected-skip set is empty. (test_conformance_timing.nim
    # separately self-gates on CRISOL_TIMING_TESTS, unset in the
    # unit+conformance step this script is invoked from, and `quit(0)`s
    # before printing either marker — correctly absent from both
    # EXPECTED_SKIP and MUST-EXECUTE on this leg.)
    # rfc-0007 review round 1 (2026-09-18): r2/r3 tests exercise the Linux
    # subreaper tier specifically (PR_SET_CHILD_SUBREAPER reparenting; Darwin
    # reparents orphans to launchd), so both are whole-file linux-gated and
    # correctly skip on this leg.
    #
    # W5b/W5c (code-review ledger, 2026-09-21): same reasoning as the
    # windows leg's own W5b/W5c entry above -- test_memprobe.nim and
    # test_rfc0007_b2_fd_leak.nim are both whole-file `when defined(linux):`
    # gated (real /proc+cgroup parsing; pidfd/epoll fd-leak introspection),
    # and macOS/Darwin is not Linux either, so both self-skip here too.
    EXPECTED_SKIP="$(cat <<'EOF'
tests/unit/test_memprobe.nim
tests/unit/test_rfc0007_b2_fd_leak.nim
tests/unit/test_rfc0007_r2_cross_slot_escapee.nim
tests/unit/test_rfc0007_r12_cgroup_killsnapshot.nim
tests/unit/test_rfc0007_w4_cgroup_memory_peak.nim
tests/conformance/test_rfc0007_r3_library_embedding.nim
EOF
)"
    # macos-latest (APFS) HAS symlink-create privilege, so every
    # symlinksAvailable()-gated test/block above (including the six NEW
    # source_index.nim ones and test_paths.nim's
    # ..._no_symlink_privilege arm added by the W5d fix) runs its real body
    # here — same shape as A5c below.
    #
    # W5d (code-review ledger, 2026-09-21): test_fold_probe_tiers.nim's
    # #t2_flipped_absent and #t2_flipped_distinct both skip `if
    # volumeIsCaseInsensitive` -- macOS/APFS IS case-insensitive (the same
    # fact the A3b-ii/A4b CRISOL_EXPECT_FOLD=fpAsciiLower env pins above rely
    # on), so both fire here too, same as the windows leg. Its other six
    # skip() sites each depend on a capability (hardlink creation, symlink
    # creation, chmod genuinely restricting a non-root user, a working RNG)
    # this leg genuinely has, so none of those six are pinned. Neither
    # test_issue23_cc_identity.nim (windows-only per-file step; this file
    # never runs on the macOS leg at all) nor
    # test_issue16_headers.nim#gcc_clang_case_mismatch_producer (APFS is
    # case-insensitive, so the CR2 suite's own premise holds and it runs for
    # real here, its intended leg) belong in this set.
    #
    # R3-5 (code-review round 3, 2026-09-24): test_depgraph_guard.nim's
    # /proc/self/mem case is pinned here for the same reason as on the windows
    # leg -- Darwin has no procfs either, so it skips every run. See that leg's
    # own R3-5 comment for how it went undetected (a bare `skip()` emits
    # nothing, so this gate was blind to it in both directions).
    #
    # R8-L1 (round-8 review, 2026-09-25): tests/integration/
    # test_r8_real_cl_refusal.nim drives R7-S1's real trigger (a real `cl`
    # under CL=/W4) and needs `cl` on PATH. macOS has no MSVC, so both of its
    # tests self-skip here EVERY run -- a platform fact, not a capability
    # probe, so the pin cannot flap. ci.yml runs it as a per-file step on this
    # leg precisely so this pin exists: a THIRD label appearing, or these two
    # vanishing, is drift the gate reports. On windows the same labels are in
    # NO pin and the real body is MUST-EXECUTE (below).
    EXPECTED_SKIP_TEST="$(cat <<'EOF'
tests/unit/test_fold_probe_tiers.nim#t2_flipped_absent
tests/unit/test_fold_probe_tiers.nim#t2_flipped_distinct
tests/unit/test_depgraph_guard.nim#f4_unreadable_depgraph_needs_procfs
tests/integration/test_r8_real_cl_refusal.nim#real_cl_refused_under_cl_env
tests/integration/test_r8_real_cl_refusal.nim#real_cl_known_without_cl_env
EOF
)"
    ;;
  *)
    echo "assert-subset-honesty.sh: unknown leg '$LEG' (expected windows|macos)" >&2
    exit 1
    ;;
esac

ACTUAL_SKIP="$(grep -o 'CRISOL-SKIP: [^[:space:]]*' "$LOG" | sed 's/^CRISOL-SKIP: //' | sort -u)"
EXPECTED_SORTED="$(printf '%s\n' "$EXPECTED_SKIP" | sed '/^$/d' | sort -u)"

if [ "$ACTUAL_SKIP" != "$EXPECTED_SORTED" ]; then
  echo "SUBSET-HONESTY FAILED ($LEG): observed skip set (by NAME) != expected skip set" >&2
  echo "--- diff: '<' expected-only (missing skip -- a file that should skip but ran)," >&2
  echo "          '>' actual-only (unexpected skip -- a file skipping that should have run) ---" >&2
  diff <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$ACTUAL_SKIP") >&2
  fail=1
else
  n=$(printf '%s\n' "$EXPECTED_SORTED" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "SUBSET-HONESTY OK ($LEG): skip set matches by name (${n} file(s))"
fi

# --- EXPECTED-SKIP-TEST: per-test/per-block symlink self-skips (S5) ---
ACTUAL_SKIP_TEST="$(grep -o 'CRISOL-SKIP-TEST: [^[:space:]]*' "$LOG" | sed 's/^CRISOL-SKIP-TEST: //' | sort -u)"
EXPECTED_TEST_SORTED="$(printf '%s\n' "$EXPECTED_SKIP_TEST" | sed '/^$/d' | sort -u)"

if [ "$ACTUAL_SKIP_TEST" != "$EXPECTED_TEST_SORTED" ]; then
  echo "SUBSET-HONESTY FAILED ($LEG): observed per-test skip set (by NAME) != expected per-test skip set" >&2
  echo "--- diff: '<' expected-only (missing skip -- a test that should skip but ran)," >&2
  echo "          '>' actual-only (unexpected skip -- a test skipping that should have run) ---" >&2
  diff <(printf '%s\n' "$EXPECTED_TEST_SORTED") <(printf '%s\n' "$ACTUAL_SKIP_TEST") >&2
  fail=1
else
  n=$(printf '%s\n' "$EXPECTED_TEST_SORTED" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "SUBSET-HONESTY OK ($LEG): per-test skip set matches by name (${n} test(s))"
fi

# --- MUST-EXECUTE: the three identity conformance tests ran their REAL body
check_must_execute() {
  local label="$1" donePattern="$2" realPattern="$3" skipPattern="$4"
  if ! grep -qF "$donePattern" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): $label did not complete (missing '$donePattern')" >&2
    fail=1
    return
  fi
  if grep -qF "$skipPattern" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): $label ran but SKIPPED its real body (found '$skipPattern')" >&2
    fail=1
    return
  fi
  if ! grep -qE "$realPattern" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): $label showed no real-body marker (missing /$realPattern/)" >&2
    fail=1
    return
  fi
  echo "MUST-EXECUTE OK ($LEG): $label ran its real body"
}

# crisol#21 interim: under the MSVC toolchain (CRISOL_CC=vcc, exported by
# the windows leg's install step) the dep probe has no cc -M to run, so the
# closure-dependent identity tests self-skip with their documented markers
# until the /showIncludes adapter lands. The skip is sanctioned ONLY under
# vcc -- any other configuration keeps the strict must-execute contract.
check_must_execute_or_vcc_skip() {
  local label="$1" donePattern="$2" realPattern="$3" skipPattern="$4"
  if [ "${CRISOL_CC:-}" = "vcc" ]; then
    if grep -qF "$skipPattern" "$LOG" && grep -qF "crisol#21" "$LOG"; then
      echo "MUST-EXECUTE OK ($LEG): $label vcc-interim skip (crisol#21: cc -M unavailable under MSVC)"
      return
    fi
    # vcc AND the real body ran (the adapter landed): fall through to strict.
  fi
  check_must_execute "$label" "$donePattern" "$realPattern" "$skipPattern"
}

check_must_execute_or_vcc_skip \
  "A3b-ii fold-membership selection (test_rfc9_a3bii_fold_selection.nim)" \
  "test_rfc9_a3bii_fold_selection done" \
  "RFC9-A3BII MODE (1|2|3)" \
  "RFC9-A3BII SKIPPED"

check_must_execute_or_vcc_skip \
  "A4b closure member on-disk-case determinism (test_rfc9_a4b_determinism.nim)" \
  "test_rfc9_a4b_determinism done" \
  "RFC9-A4B COLD" \
  "RFC9-A4B SKIPPED"

# A5c (test_rfc9_a5c_cache_portability.nim) has no isMainModule "done" echo —
# it is a plain std/unittest suite with the default console reporter. Its
# self-skip path (no symlink privilege in this environment) prints
# "SKIP test_rfc9_a5c_cache_portability: ..." and then `quit(0)` MID-TEST,
# before unittest ever reports [OK]/[FAILED] for it — so presence of the
# suite's own "[OK] <test name>" line is already proof the real body ran to
# completion; the explicit SKIP check below just gives a clearer failure
# message than a bare "marker not found" would.
# A5c is leg-aware. Unlike A3b-ii/A4b (which need only a case-insensitive
# volume — present on both windows-latest NTFS and macos-latest APFS), A5c
# needs to CREATE a symlink (a symlinked depRoot). GitHub-hosted
# windows-latest runners lack SeCreateSymbolicLinkPrivilege / Developer
# Mode, so A5c self-skips there BY DESIGN (same convention as
# test_closure_a4a.nim / symlinkprobe.nim) — this is its DOCUMENTED skip
# (RFC-0009 line 555/A5c: "Self-skips only on an environment that cannot
# create symlinks at all"), and A5c's own slice was accepted green with
# exactly this windows self-skip (CI 34721929202). Its cache-portability
# property is proven on the macOS case-insensitive leg, which HAS symlink
# privilege and MUST run the real body. So: on macos the real body is
# mandatory; on windows a documented symlink self-skip is honest and
# accepted, but a SILENT disappearance (neither the [OK] line nor the
# documented SKIP) still fails — that is the R3-19 honesty guarantee.
if grep -qF "[OK] a depRoot closure member's cache key survives relocating the project tree" "$LOG"; then
  echo "MUST-EXECUTE OK ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) ran its real body"
elif grep -qF "SKIP test_rfc9_a5c_cache_portability: vcc toolchain" "$LOG" && [ "${CRISOL_CC:-}" = "vcc" ]; then
  echo "MUST-EXECUTE OK ($LEG): A5c vcc-interim skip (crisol#21: cc -M unavailable under MSVC)"
elif grep -qF "SKIP test_rfc9_a5c_cache_portability" "$LOG"; then
  if [ "$LEG" = "windows" ]; then
    echo "MUST-EXECUTE OK ($LEG): A5c self-skipped for its documented reason (no symlink-create privilege on windows-latest); cache-portability is proven on the macOS case-insensitive leg"
  else
    echo "MUST-EXECUTE FAILED ($LEG): A5c SKIPPED, but this leg can create symlinks and MUST run the real body" >&2
    fail=1
  fi
else
  echo "MUST-EXECUTE FAILED ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) marker not found (neither its [OK] line nor a documented SKIP present -- silent disappearance)" >&2
  fail=1
fi

# RFC-0009 wiring-audit W2 (slice S6): the spawned-binary argv path
# (`crisol run --changed <ref>`) for the load-bearing fold-membership
# selection property, proven by test_windows_cli_smoke.nim's second test.
# WINDOWS-ONLY, unlike A3b-ii/A4b/A5c above: the whole file is
# `when defined(windows)` gated (mirroring test_windows_smoke.nim), so on
# the macos leg it takes the `else` branch and never even compiles this
# test -- its isMainModule marker there is the different string
# "test_windows_cli_smoke: skipped (not windows)", not "... done". So this
# check only applies to the windows leg; it would misfire against macos's
# harness.log otherwise.
if [ "$LEG" = "windows" ]; then
  check_must_execute_or_vcc_skip \
    "W2 case-variant --changed argv-path selection (test_windows_cli_smoke.nim)" \
    "test_windows_cli_smoke done" \
    "CLI-SMOKE-CASECHANGED REAL" \
    "CLI-SMOKE-CASECHANGED SKIPPED"
fi

# R8-L1 (round-8 review, 2026-09-25): R7-S1's real trigger, on a real `cl`.
# WINDOWS-ONLY as a MUST-EXECUTE: the macos leg has no MSVC and its two
# per-test skips are pinned above instead. "R8-REAL-CL REAL" is echoed only
# when `cl` resolved on PATH, before either test runs; each test's own skip
# marker is the skip pattern. The two [OK] lines are checked as well, because
# the file's `done` marker prints after a FAILED test too -- the step's own
# exit code carries that failure, but this audit should not be the one place
# that would call a red body "executed".
if [ "$LEG" = "windows" ]; then
  check_must_execute \
    "R8-L1 real cl refused under CL=/W4 (test_r8_real_cl_refusal.nim)" \
    "test_r8_real_cl_refusal done" \
    "R8-REAL-CL REAL" \
    "CRISOL-SKIP-TEST: tests/integration/test_r8_real_cl_refusal.nim#"
  for okLine in \
      "[OK] CL=/W4: real cl exits non-zero and the compiler half is refused" \
      "[OK] CONTROL CL unset: the same real cl identifies itself"; do
    if ! grep -qF "$okLine" "$LOG"; then
      echo "MUST-EXECUTE FAILED ($LEG): test_r8_real_cl_refusal.nim is missing '$okLine'" >&2
      fail=1
    fi
  done
fi

# R8-L1 (round-8 review, 2026-09-25): toolrun's presence contract
# (tests/integration/test_r7_probe_presence_contract.nim) -- "not on PATH ->
# empty output, ran-and-failed -> non-empty output" -- which ccidentity's
# R7-S1 refusal rests on. Its header claims it is pinned on every platform;
# before ci.yml's per-file steps on both legs it ran only on Linux. BOTH legs:
# it has no skip path, so all three [OK] lines must be present. A plain
# unittest suite with no isMainModule marker, so the [OK] lines are the proof.
presence_ok=1
for okLine in \
    "[OK] a command that is not on PATH: empty output, not ok" \
    "[OK] a command that ran and exited non-zero: its output, not ok" \
    "[OK] CONTROL a command that ran and exited 0: its output, ok"; do
  if ! grep -qF "$okLine" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): test_r7_probe_presence_contract.nim is missing '$okLine'" >&2
    presence_ok=0
    fail=1
  fi
done
if [ "$presence_ok" -eq 1 ]; then
  echo "MUST-EXECUTE OK ($LEG): R7-S1 probe presence contract (test_r7_probe_presence_contract.nim) ran all three tests"
fi

# RFC-0009 wiring-audit F16: the real on-disk long-path E2E
# (test_rfc9_w2_longpath_e2e.nim) — a real >MAX_PATH (260-char) directory
# chain, compiled/run/reselected through the actual spawned crisol binary,
# proving `paths.toNative`'s `\\?\` prefix boundary against real
# CreateFileW-backed I/O rather than the lexical round-trip
# tests/unit/test_paths.nim already covers. WINDOWS-ONLY, same shape as W2
# immediately above: the whole file is `when defined(windows)` gated (POSIX
# has no MAX_PATH cliff), so on the macos leg it takes the `else` branch and
# never compiles this test at all — its isMainModule marker there is
# "test_rfc9_w2_longpath_e2e: skipped (not windows)", not "... done" — so
# this check only applies to the windows leg. This test has no legitimate
# per-environment self-skip (unlike the case-fold/symlink-privilege gated
# tests above): the fixture builds its own long path deterministically, so a
# SKIP marker appearing here would itself be a regression, not an honest
# environment fact. CI run 35315917270 (empirical): this runner's nim.exe
# cannot itself open a >MAX_PATH source, so the test runs an ADAPTIVE TIER B
# (graceful-degradation proof of crisol's own traversal/caching/structured-
# failure reporting) rather than TIER A's full compile-through proof — see
# the test file's own header doc comment. Neither tier touches these two
# markers: "W2-LONGPATH REAL" is echoed unconditionally at the very start of
# the test body, before either tier is selected, and "test_rfc9_w2_longpath_
# e2e done" is the unconditional isMainModule marker at the very end — both
# print regardless of which tier the run took, so this MUST-EXECUTE check
# stays tier-agnostic by construction and needs no per-tier marker.
if [ "$LEG" = "windows" ]; then
  check_must_execute \
    "F16 long-path E2E through toNative (test_rfc9_w2_longpath_e2e.nim)" \
    "test_rfc9_w2_longpath_e2e done" \
    "W2-LONGPATH REAL" \
    "W2-LONGPATH SKIPPED"
fi

exit $fail
