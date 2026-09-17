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
#   2. EXPECTED-SKIP-TEST (S5 wiring-audit fix): the set of
#      `CRISOL-SKIP-TEST: <path>#<label>` markers observed exactly equals the
#      pinned per-leg expected set below (per-test/per-block self-skips
#      inside a file whose other tests still run for real — these files each
#      call tests/support/symlinkprobe.nim's `symlinksAvailable()` and
#      self-skip only the individual test/block, via unittest `skip()` or a
#      bare `block`/`break`, when this environment cannot create a symlink.
#      windows-latest lacks SeCreateSymbolicLinkPrivilege, so these are
#      EXPECTED there; macos-latest (APFS) has it, so these MUST run for
#      real there — same leg-aware shape as A5c below).
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
    # gate (B2 + B3b) takes its `else` branch. Of that set, only these four
    # files fall inside tests/unit:tests/conformance.
    # test_conformance.nim is the POSIX process-backend conformance suite: it
    # COMPILES on windows (B3a-ii de-POSIX'd its imports) but its assertions
    # are POSIX-semantic (ekSignaled/.sig, rlimit lsApplied, process-group
    # kill domains), so it self-skips `when not defined(posix)` — the Windows
    # backend is proven by the per-file test_windows_* suite instead. It is
    # NOT in the B2/B3b import buckets (it imports no std/posix any more), but
    # it IS a posix-backend-category skip on windows, so it belongs here.
    EXPECTED_SKIP="$(cat <<'EOF'
tests/conformance/test_conformance.nim
tests/conformance/test_conformance_timing.nim
tests/unit/test_process_capabilities.nim
tests/unit/test_rfc0007_a6a_escapee_evidence.nim
tests/unit/test_run_tests.nim
EOF
)"
    # S5 wiring-audit fix: windows-latest also lacks symlink-create
    # privilege, so every test/block gated on symlinkprobe.nim's
    # `symlinksAvailable()` self-skips here too. test_closure_a4a.nim is its
    # own whole-file skip (its only block quit(0)s) and belongs in
    # EXPECTED_SKIP above, not here; these six are per-test/per-block skips
    # inside files whose OTHER tests run for real, so they get the distinct
    # CRISOL-SKIP-TEST marker instead.
    EXPECTED_SKIP_TEST="$(cat <<'EOF'
tests/unit/test_depgraph.nim#test_saveDepGraph_symlink_write_through_protection
tests/unit/test_discover.nim#symlinked_dir_not_followed
tests/unit/test_ioutils.nim#test_createoverwrite_nofollow_refuses_symlink
tests/unit/test_ioutils.nim#test_writeguardedfile_overwrite_true_still_refuses_symlink
tests/unit/test_jsonout.nim#p3_symlink_safe_temp_write
tests/unit/test_rfc9_a2_config.nim#dep_roots_alias_symlink_cekConfig
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
    EXPECTED_SKIP=""
    # macos-latest (APFS) HAS symlink-create privilege, so every
    # symlinksAvailable()-gated test/block above runs its real body here —
    # the expected CRISOL-SKIP-TEST set is empty, same shape as A5c below.
    EXPECTED_SKIP_TEST=""
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

check_must_execute \
  "A3b-ii fold-membership selection (test_rfc9_a3bii_fold_selection.nim)" \
  "test_rfc9_a3bii_fold_selection done" \
  "RFC9-A3BII MODE (1|2|3)" \
  "RFC9-A3BII SKIPPED"

check_must_execute \
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

exit $fail
