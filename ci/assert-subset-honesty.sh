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
#      (A3b-ii, A4b, A5c) ran their REAL body, not a self-skip, and every
#      per-file step ci.yml appends into harness.log ran each of its tests.
#   4. PER-FILE DRIFT (R12-D9): ci.yml is the one list of per-file steps. The
#      script parses this leg's job in it and fails when a per-file step has
#      no require_per_file block here, or a block names a file with no step.
#      ci/assert-subset-honesty.selftest.sh mutation-tests that check.
#   5. INTEGRATION COVERAGE (R15-D11): every tests/integration/*.nim
#      entrypoint is run by at least one leg -- the Linux `test` job's
#      default sweep, a windows/macos per-file step (this script's own
#      require_per_file / per_file_pinned_skip blocks, either leg), or a
#      documented exemption -- so a file that slips past all three (most
#      concretely, a future edit narrowing the Linux job's own sweep) is
#      caught here instead of quietly running nowhere.
#
# R15-S3: point 4's parse is line-oriented text, not a YAML+shell
# interpreter, and refuses to guess at four shapes that could otherwise hide
# an unjudged per-file test: a YAML anchor/alias/merge key, a `for` loop, two
# producers on one line, or a bare MENTION of run-tests.sh/this script's own
# name where only the exact anchored invocation used to be exempt. Each
# exits "cannot tell" (2, not the usual 0/1) rather than a false pass -- see
# that section's own comment.
#
# Run from the repository root (ci.yml runs it there); CRISOL_CI_WORKFLOW
# overrides the workflow path.
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
# R15-S3: a distinct verdict from fail -- "this run could not be judged" --
# rather than a false 0 (clean) or a false 1 (a specific, named defect). Set
# below by PER-FILE DRIFT's parse; checked once at the very end of the
# script, where it takes priority over $fail (exit 2, not 0 or 1).
cannot_tell=0

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
    # it no longer uses a symlink on windows at all -- its dep-root alias
    # is a privilege-free directory junction -- and it has no skip path;
    # its real body is MUST-EXECUTE on every leg, below.) For re-pinning,
    # list the marker-bearing sites from the tree rather than from a copy
    # here (a hand-kept list and its count had already drifted, R2-11):
    #   grep -rn 'echo "CRISOL-SKIP-TEST: ' tests/unit tests/conformance
    # and take the symlinksAvailable()-gated ones.
    #
    # CR6/W5d (code-review ledger, 2026-09-21): per-test skips that are NOT
    # symlink-gated (see the header comment above) and, unlike the symlink
    # set immediately above, DO fire on this leg today. (The issue #23
    # POSIX-only compiler-digest skip is gone: since round 9 the compiler
    # half carries a content digest on every platform, and
    # test_issue23_cc_identity.nim asserts it here too.)
    #
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
    # test_real_cl_identity.nim's three labels
    # (#real_cl_identified_under_cl_env, #real_cl_value_moves_key,
    # #real_cl_config_nims_putenv) are DELIBERATELY absent from this set: the
    # file's real body is MUST-EXECUTE below, so any skip marker of it on this leg is a
    # failure here.
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
    #
    # R10-L7 (code-review round 10): test_ccidentity.nim's "the real probe
    # (POSIX host)" suite is `when defined(posix)`-gated; its `else:` branch
    # prints #real_probe_posix_host, so on this leg it fires EVERY run -- a
    # compile-time platform fact, not a capability probe, so the pin cannot
    # flap. The Windows real probe is exercised by test_real_cl_identity.nim
    # (MUST-EXECUTE below). macOS is posix, so the suite runs there and the
    # label is correctly absent from that leg's pin.
    #
    # --changed and links (R12-D1): test_changed_symlink.nim and
    # test_changed_submodule.nim have no platform gate. Their directory
    # links are junctions on this leg (tests/support/dirlink.nim), so every
    # case runs here and none is pinned; both are MUST-EXECUTE below.
    EXPECTED_SKIP_TEST="$(cat <<'EOF'
tests/unit/test_ccidentity.nim#real_probe_posix_host
tests/unit/test_source_index.nim#mangling_escape_colon_hash_windows_excluded
tests/unit/test_paths.nim#classify_symlinked_deproot_realabs_windows_known_divergence
tests/unit/test_fold_probe_tiers.nim#t2_flipped_absent
tests/unit/test_fold_probe_tiers.nim#t2_flipped_distinct
tests/unit/test_ccprobe.nim#realrun_execv_no_shell_splitting
tests/unit/test_ccprobe.nim#realrunin_subprocess_cwd
tests/unit/test_ccprobe.nim#erroutput_w9a_nonmerged
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
    # symlinksAvailable()-gated test/block (every test_source_index.nim one
    # included, and test_paths.nim's
    # ..._no_symlink_privilege arm added by the W5d fix) runs its real body
    # here.
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
    # tests/integration/test_real_cl_identity.nim probes a real MSVC
    # toolchain under `CL` and is Windows-only, so all three of its tests
    # self-skip here EVERY run -- a platform fact, not a capability probe, so
    # the pin cannot flap. ci.yml runs it as a per-file step on this leg
    # precisely so this pin exists: a new label appearing, or these three
    # vanishing, is drift the gate reports. On windows the same labels are in
    # NO pin and the real body is MUST-EXECUTE (below).
    #
    # tests/unit/test_ccidentity.nim#cfg_cc_selects_gcc_or_clang compares a
    # project nim.cfg `cc = gcc` against `cc = clang` and needs them to be two
    # different compilers. On macOS `gcc` is Apple clang, so it skips every
    # run -- a platform fact, not a probe that can flap. (UNMEASURED on this
    # leg: pinned from the known Xcode layout, not from a macOS log.) The
    # nim.cfg-reaches-the-probe property itself runs for real here, in the
    # test before it.
    EXPECTED_SKIP_TEST="$(cat <<'EOF'
tests/unit/test_ccidentity.nim#cfg_cc_selects_gcc_or_clang
tests/unit/test_fold_probe_tiers.nim#t2_flipped_absent
tests/unit/test_fold_probe_tiers.nim#t2_flipped_distinct
tests/unit/test_depgraph_guard.nim#f4_unreadable_depgraph_needs_procfs
tests/integration/test_real_cl_identity.nim#real_cl_identified_under_cl_env
tests/integration/test_real_cl_identity.nim#real_cl_value_moves_key
tests/integration/test_real_cl_identity.nim#real_cl_config_nims_putenv
EOF
)"
    ;;
  *)
    echo "assert-subset-honesty.sh: unknown leg '$LEG' (expected windows|macos)" >&2
    exit 1
    ;;
esac

# set_diff <expected> <actual>: two sorted name lists, one per line. Prints
# each expected-only name as "< name" and each actual-only name as "> name".
# comm, not diff: the BusyBox dev image has no diff.
set_diff() {
  comm -23 <(printf '%s\n' "$1" | sed '/^$/d') <(printf '%s\n' "$2" | sed '/^$/d') | sed 's/^/< /'
  comm -13 <(printf '%s\n' "$1" | sed '/^$/d') <(printf '%s\n' "$2" | sed '/^$/d') | sed 's/^/> /'
}

ACTUAL_SKIP="$(grep -o 'CRISOL-SKIP: [^[:space:]]*' "$LOG" | sed 's/^CRISOL-SKIP: //' | sort -u)"
EXPECTED_SORTED="$(printf '%s\n' "$EXPECTED_SKIP" | sed '/^$/d' | sort -u)"

if [ "$ACTUAL_SKIP" != "$EXPECTED_SORTED" ]; then
  echo "SUBSET-HONESTY FAILED ($LEG): observed skip set (by NAME) != expected skip set" >&2
  echo "--- diff: '<' expected-only (missing skip -- a file that should skip but ran)," >&2
  echo "          '>' actual-only (unexpected skip -- a file skipping that should have run) ---" >&2
  set_diff "$EXPECTED_SORTED" "$ACTUAL_SKIP" >&2
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
  set_diff "$EXPECTED_TEST_SORTED" "$ACTUAL_SKIP_TEST" >&2
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

# A5c (test_rfc9_a5c_cache_portability.nim) has no isMainModule "done" echo --
# it is a plain std/unittest suite with the default console reporter, so the
# suite's own "[OK] <test name>" line is the proof the real body ran to
# completion (a failed `check` prints [FAILED] instead).
#
# A5c is MUST-EXECUTE on EVERY leg, windows included (R10-L1, issue #21). Its
# fixture needs a dep root reachable under an ALIAS whose realpath differs
# from its lexical spelling. It used to build that alias with a directory
# symlink and self-skip ("SKIP test_rfc9_a5c_cache_portability: symlink
# creation failed") where the process lacks SeCreateSymbolicLinkPrivilege --
# which windows-latest (CI 35491097764) and the MSVC container's
# ContainerAdministrator both do, so the windows leg could never run the
# body. It now uses tests/support/dirlink.nim: a symlink on POSIX, a
# privilege-free directory JUNCTION on windows, which crisol's windows
# realpath (paths.safeExpandFilename -> GetFinalPathNameByHandleW) resolves
# exactly like a symlink. There is no skip path left, so the legacy SKIP
# line is a failure on every leg, and the "RFC9-A5C ALIAS <kind>" marker pins
# WHICH alias mechanism ran: "junction" on windows, "symlink" elsewhere.
a5cOk="[OK] a depRoot closure member's cache key survives relocating the project tree"
if [ "$LEG" = "windows" ]; then
  a5cAlias="RFC9-A5C ALIAS junction"
else
  a5cAlias="RFC9-A5C ALIAS symlink"
fi
if grep -qF "SKIP test_rfc9_a5c_cache_portability" "$LOG"; then
  echo "MUST-EXECUTE FAILED ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) SKIPPED its real body; it has no legitimate skip on any leg" >&2
  fail=1
elif ! grep -qF "$a5cAlias" "$LOG"; then
  echo "MUST-EXECUTE FAILED ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) is missing '$a5cAlias' (did not reach its real body, or aliased its dep root by the wrong mechanism)" >&2
  fail=1
elif ! grep -qF "$a5cOk" "$LOG"; then
  echo "MUST-EXECUTE FAILED ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) is missing '$a5cOk'" >&2
  fail=1
else
  echo "MUST-EXECUTE OK ($LEG): A5c cache-portability E2E (test_rfc9_a5c_cache_portability.nim) ran its real body ($a5cAlias)"
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
  check_must_execute \
    "W2 case-variant --changed argv-path selection (test_windows_cli_smoke.nim)" \
    "test_windows_cli_smoke done" \
    "CLI-SMOKE-CASECHANGED REAL" \
    "CLI-SMOKE-CASECHANGED SKIPPED"
fi

# The real MSVC identity probe under `CL` (test_real_cl_identity.nim).
# WINDOWS-ONLY as a MUST-EXECUTE: the macos leg has no MSVC and its three
# per-test skips are pinned above instead. "R9-REAL-CL REAL" is echoed before
# any test runs; each test's own skip marker is the skip pattern. The three
# [OK] lines are checked as well, because the file's `done` marker prints
# after a FAILED test too.
if [ "$LEG" = "windows" ]; then
  check_must_execute \
    "R9-D1c real cl identified under CL (test_real_cl_identity.nim)" \
    "test_real_cl_identity done" \
    "R9-REAL-CL REAL" \
    "CRISOL-SKIP-TEST: tests/integration/test_real_cl_identity.nim#"
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

# --- PER-FILE STEPS: ci.yml's `nim r tests/<x>.nim ... | tee -a harness.log`
# steps. tests/integration/ is outside both legs' sweep, so each such file is
# run by its own step and appended into harness.log (wiring-audit W9i). A step
# whose file stops compiling, stops running, or loses a test would otherwise go
# unjudged here. Each [OK] line is required individually, because an
# isMainModule `done` marker prints after a FAILED test too; a `done` marker,
# where the file has one, proves the file ran to its end. `forbid` names a skip
# marker that must NOT appear ("" for none).
#
# Every judged file is recorded in JUDGED, and the per-file drift check at the
# end of this script compares that record with the steps ci.yml actually has
# for this leg (R12-D9), so the step list and these blocks cannot drift apart.
# `require_in_log` judges a file without recording it, for a file the B4b
# sweep runs rather than a per-file step (test_cc_backend.nim, below).
JUDGED=""

require_in_log() {
  local file="$1" done="$2" forbid="$3"
  shift 3
  local ok=1 line
  if [ -n "$done" ] && ! grep -qF "$done" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): $file did not complete (missing '$done')" >&2
    ok=0
  fi
  if [ -n "$forbid" ] && grep -qF "$forbid" "$LOG"; then
    echo "MUST-EXECUTE FAILED ($LEG): $file SKIPPED its real body (found '$forbid')" >&2
    ok=0
  fi
  for line in "$@"; do
    if ! grep -qF "[OK] $line" "$LOG"; then
      echo "MUST-EXECUTE FAILED ($LEG): $file is missing '[OK] $line'" >&2
      ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "MUST-EXECUTE OK ($LEG): $file ran all $# test(s)"
  else
    fail=1
  fi
}

# require_per_file <repo-relative path> <done> <forbid> <ok line>...
require_per_file() {
  JUDGED="${JUDGED}$1
"
  require_in_log "$@"
}

# per_file_pinned_skip <repo-relative path>: a per-file step whose file
# self-skips on this leg, judged by the EXPECTED_SKIP_TEST pin above rather
# than by [OK] lines. The pin must actually name the file, or the claim that
# the pin judges it is false.
per_file_pinned_skip() {
  JUDGED="${JUDGED}$1
"
  if printf '%s\n' "$EXPECTED_SKIP_TEST" | grep -qF "$1#"; then
    echo "MUST-EXECUTE OK ($LEG): $1 is judged by this leg's per-test skip pin"
  else
    echo "MUST-EXECUTE FAILED ($LEG): $1 is declared pin-judged, but EXPECTED_SKIP_TEST names none of its tests" >&2
    fail=1
  fi
}

if [ "$LEG" = "windows" ]; then
  # issue #22: child-output capture completeness through ccprobe/icbaseline.
  # Only Windows can regress it (POSIX fread loops to EOF). No skip path, no
  # isMainModule marker.
  require_per_file "tests/integration/test_issue22_capture.nim" "" "" \
    "realRun returns the payload a two-burst child writes after its banner" \
    "realRunMerged returns both bursts of both streams, in write order" \
    "realRunMerged captures a two-burst child whose output overruns the pipe buffer" \
    "realIcRun returns both bursts when the child's streams are merged" \
    "a child whose stderr overruns the pipe buffer neither wedges the probe nor loses its stdout"

  # issue #22: --changed sees every changed file, and an incomplete
  # untracked-file scan fails closed. No skip path, no isMainModule marker.
  require_per_file "tests/integration/test_issue22_changed_completeness.nim" "" "" \
    "changedFiles returns all names when git's diff arrives in two bursts" \
    "a git whose stderr overruns the pipe buffer neither wedges nor is truncated" \
    "control: a clean ls-files puts every untracked name in the changed set" \
    "ls-files exiting non-zero raises instead of returning a diff-only set" \
    "crisol run --changed refuses (exit 3) when ls-files exits non-zero" \
    "crisol run --changed refuses (exit 3) when ls-files never answers"

  # issue #23: the soundness key identifies this host's C toolchain by
  # content. No skip path.
  require_per_file "tests/integration/test_issue23_cc_identity.nim" \
    "test_issue23_cc_identity done" "" \
    "the compiler half names the configured compiler, by content" \
    "the runtime half identifies the C runtime by content" \
    "the accessor is memoised and serializes the same value"

  # The M-driver's real live compile (compileOnly, cc, link) under MSVC,
  # whose objects are `.obj`. No skip path.
  require_per_file "tests/integration/test_compiledriver_real.nim" \
    "All compiledriver real-compile tests passed." "" \
    "compileOnly -> cc -> link all run for real, in order, with positive spans" \
    "[RED-pin] workingDir=\"\" (pre-A2c default) fails to compile from an unrelated cwd" \
    "workingDir=projectRoot compiles successfully from an unrelated cwd"

  # CR4: the tool-capture deadline, whose Windows arm is the PeekNamedPipe
  # poll. No skip path, no isMainModule marker.
  require_per_file "tests/integration/test_tool_capture_deadline.nim" "" "" \
    "toolrun.realRunMerged (one pipe) gives up on a child that never exits" \
    "toolrun.realRun (two pipes) gives up on a child that never exits" \
    "gitdiff.changedFiles (two pipes, via runGit) gives up on a git that never answers"

  # The real MSVC identity probe under `CL`. Its REAL marker, `done` marker
  # and skip markers are judged by check_must_execute above; these are its
  # three [OK] lines.
  require_per_file "tests/integration/test_real_cl_identity.nim" "" "" \
    "CL=/W4: the configured cl is identified" \
    "a CL value moves the compiler half, not the runtime half" \
    "a config.nims putEnv(CL) is refused, not probed without it"

  # R9: toolexec's capture endings (reIoError / reOverflow / CONTROL reExited).
  require_per_file "tests/integration/test_tool_capture_endings.nim" \
    "test_tool_capture_endings done" "" \
    "a stdout pipe that fails mid-capture ends reIoError, never reExited" \
    "a child that writes past the byte cap ends reOverflow" \
    "CONTROL the same child under a cap it fits ends reExited with all of its output"

  # R10: toolrun's endings through each real-run entry point, and stdin EOF.
  require_per_file "tests/integration/test_toolrun_endings.nim" \
    "test_toolrun_endings done" "" \
    "realRun: a child past the output cap is reOverflow, never a finished run" \
    "realRunMerged: a child past the output cap is reOverflow, never a finished run" \
    "realRunWithStdinIn feeds the child its input, then EOF" \
    "with no input the child's stdin is closed, not left open"

  # W3: cc-identity liveness. No isMainModule marker; its one test self-skips
  # with the named marker below when no GNU shadow cc can be built, which
  # would leave the windows leg without the liveness proof, so that skip is
  # a failure here and the [OK] line is the proof the body ran.
  require_per_file "tests/integration/test_cc_depgraph_liveness.nim" \
    "" \
    "CRISOL-SKIP-TEST: tests/integration/test_cc_depgraph_liveness.nim#gnu_on_windows_no_shadow" \
    "Nim unchanged, cc identity changed -> recompile instead of cdSkipFresh"

  # R10/R12-D2: --changed sees edits and commits inside a git submodule,
  # and only the files its own diff names. No skip path; every case must
  # run.
  require_per_file "tests/integration/test_changed_submodule.nim" \
    "test_changed_submodule done" "" \
    "an uncommitted edit inside the submodule selects its dependent test" \
    "a commit made inside the submodule selects its dependent test" \
    "a submodule configured \`ignore = all\` is still seen" \
    "a one-file edit inside the submodule selects only the tests that read that file" \
    "an untracked directory link inside a changed submodule selects nothing by itself" \
    "an index-recorded link retargeted inside a submodule selects nothing by itself" \
    "a link repointed in a submodule commit selects the test reached through it" \
    "CONTROL an unchanged link inside a changed submodule does not refuse" \
    "CONTROL an unchanged directory link inside a changed submodule does not refuse" \
    "a moved submodule that is not checked out does not refuse, and selects the test that read it" \
    "a submodule whose recorded commit is missing locally refuses --changed (exit 3)" \
    "an untracked nested repository counts every file in it as changed" \
    "a submodule checkout replaced by a link selects its dependent test" \
    "an edit beside a link inside the submodule selects no test reached through the link" \
    "CONTROL a change outside the submodule does not select its dependent test"

  # R12-D1: a link in the diff selects the tests reached through it (the
  # links are junctions on this leg, which git sees as directories), and an
  # unresolvable --base refuses. No skip path; every case must run.
  require_per_file "tests/integration/test_changed_symlink.nim" \
    "test_changed_symlink done" "" \
    "an uncommitted repoint of a crossed link selects its test, not the other" \
    "a committed repoint recorded after the repoint is still selected across --base HEAD~1" \
    "a repointed link no test crosses selects nothing and does not refuse" \
    "a real directory replaced by a link selects the test that read it" \
    "a real directory replaced by a same-content link, run, then its target edited, is selected" \
    "a real directory replaced by a same-content link, run, then repointed, is selected" \
    "the same swap, committed, then a committed repoint, is selected across --base HEAD~1" \
    "an untracked directory link no test crosses selects nothing" \
    "an index-recorded link repointed without a crossing test selects nothing" \
    "an index-recorded link repointed in a commit selects nothing across --base HEAD~1" \
    "a deleted index-recorded link selects nothing" \
    "an index-recorded link replaced by a regular file selects nothing" \
    "CONTROL a newly added link to a file is a new file" \
    "CONTROL an unchanged crossed link does not select its test for an unrelated change" \
    "--base naming a directory but no ref refuses (exit 3)" \
    "CONTROL a resolvable --base still selects the changed test"

  # R13-S3: a submodule whose .git entry was removed, top-level and nested,
  # still has its edits seen by --changed; R15-D1: whether or not the diff
  # names it, and an uninitialised one never refuses. No skip path; every
  # case must run.
  require_per_file "tests/integration/test_changed_stranded_submodule.nim" \
    "test_changed_stranded_submodule done" "" \
    "an edit inside it selects its dependent test" \
    "an edit inside a nested submodule whose .git was removed selects its dependent test" \
    "a submodule bumped since --base, then its .git removed, selects its dependent test" \
    "an uninitialised submodule bumped since --base does not refuse and selects nothing by itself" \
    "a submodule whose .git is an empty directory refuses --changed (exit 3)" \
    "CONTROL an uninitialised submodule contributes nothing" \
    "CONTROL a checked-out submodule with no change selects nothing"

  # R10-L9: the mingw runtime identity, a `cc = gcc` project beside MSVC.
  # The file is `when defined(windows)` gated. Its no-gcc skip markers are
  # forbidden here: windows-latest ships MinGW-w64 gcc on PATH.
  require_per_file "tests/integration/test_mingw_runtime_identity.nim" \
    "test_mingw_runtime_identity done" \
    "CRISOL-SKIP-TEST: tests/integration/test_mingw_runtime_identity.nim#" \
    "a project \`cc = gcc\` is identified, and the runtime half is the mingw arm's" \
    "a real run under \`cc = gcc\` compiles, runs, and is served from the cache the second time"

  # R3-12: a descendant holding the tool's output -- the Job Object tree
  # kill. Its R5-19 zombie suite is Linux-only by construction, so only the
  # R3-12 pair runs here. No skip path.
  require_per_file "tests/integration/test_tool_tree_termination.nim" \
    "test_tool_tree_termination done" "" \
    "a tool whose descendant holds its separate output ends promptly, not as a finished run" \
    "a tool whose descendant holds its merged output ends promptly, not as a finished run"

  # CR18: tools never inherit the CRISOL_CACHE_* credentials, including a
  # lower-cased name. No skip path.
  require_per_file "tests/integration/test_tool_env_scrub.nim" \
    "test_tool_env_scrub done" "" \
    "runTool, bounded" \
    "runTool, NoDeadline" \
    "toolrun.realRun, the probe seam" \
    "crisol's own environment is left as it was"

  # R11-L4: an interrupt ends a running bounded tool through the live-tool
  # registry; R13-D3: a bounded tool refused at registration after an
  # interrupt closes its job handle (a `when defined(windows)` suite). The
  # signal suites (R11-L4's, R13-D5's) and R14-D3's refusal suite are
  # POSIX-only by construction and are compiled out here. No skip path.
  require_per_file "tests/integration/test_tool_interrupt.nim" \
    "test_tool_interrupt done" "" \
    "killLiveTools ends a running tool at once, and runTool reports it interrupted" \
    "a run the registry did not interrupt is unaffected" \
    "bounded tools refused at registration close their job handles"
else
  # test_real_cl_identity.nim has no MSVC to drive here; its three tests
  # self-skip, and the EXPECTED_SKIP_TEST pin above judges exactly that.
  per_file_pinned_skip "tests/integration/test_real_cl_identity.nim"
fi

# issue #16/#21: a {.compile.}d source's #include'd headers are closure
# members. BOTH legs: the MSVC arm on windows; on macOS the gcc/clang
# include-case arm (CR2) too. That suite's premise, a case-insensitive
# volume, holds on NTFS and APFS alike, so no test in the file skips on either
# leg (a CR2 skip would also fail the per-test pin above). No isMainModule
# marker.
require_per_file "tests/integration/test_issue16_headers.nim" "" "" \
  "native/add.h appears in the closure after a full run; every closure path is root-relative" \
  "W1: a mixed-case header keeps its REAL case when the root spelling already case-matches the probe" \
  "R10-S1: a project root with a NON-ASCII letter keeps its headers, in their real case" \
  "editing only the header selects the includer under --changed --dry-run" \
  "T3: a header-only edit flips the probe's outcome on the next full run" \
  "T4: a header-only edit is busted even with a warm nimcache and no depgraph record" \
  "T5: an unchanged second run neither recompiles nor busts the external's object" \
  "T6: a carried-forward header record still busts correctly after a warm module-only recompile" \
  "a gcc/clang-reported #include spelling that mis-cases the on-disk header still resolves to real case"

# Issue #26: a run cut short between the closure record and the binary's
# promotion never leaves the old binary to run, and a previous binary that
# cannot be retired drops the entry (directly, through a real execute(), and
# through the CLI's --json, whose warnings array must carry it), reported
# once however the run ends (R19), and a failed promotion is reported too;
# with retries, only when no attempt of the run recorded it (R20-S1); and
# reporting it never raises on a broken stderr (R21-S1; vacuous on the
# Windows leg, where the MSVC CRT never reports a failed stderr write --
# load-bearing on macOS, R22-D2); and a seam raising after the compile
# child is reaped surfaces as itself, not as a teardown AssertionDefect
# (R22-D1).
# BOTH legs (R17-L1): the SIGINT case is POSIX only, so macOS runs it; the
# held-open-binary case is Windows only. No skip path; every case the leg
# compiles in must run.
case "$LEG" in
  windows) issue26_leg="an open previous binary (windows): the real retire fails and the entry is dropped" ;;
  *)       issue26_leg="SIGINT during the run phase: the next run recompiles and fails" ;;
esac
require_per_file "tests/integration/test_issue26_promotion_interrupt.nim" \
  "test_issue26_promotion_interrupt done" "" \
  "a hard kill (SIGKILL / TerminateProcess) during the run phase: the next run recompiles and fails" \
  "a run-phase spawn failure: the next run recompiles and fails" \
  "a failed retire drops the entry instead of persisting it" \
  "a failed retire through execute(): the entry is dropped and the next run recompiles the new source" \
  "a failed retire through the CLI with --json: the unrecorded closure is in the warnings array" \
  "a blocked stable path through the CLI: one warning line on stderr and one structured entry, no promotion warning" \
  "a failed retire, then a run-phase spawn failure: the unrecorded closure is still reported" \
  "a promotion failure with a recorded closure: one promote-binary warning" \
  "a retry that records the closure: no closure-record warning, and its binary is promoted" \
  "every attempt fails to record: exactly one closure-record warning" \
  "a held warning whose retry never comes (a run-phase spawn failure): reported once" \
  "a held warning whose retry fail-fast never dispatches: still reported once" \
  "an unwritable stderr: execute() does not raise and still keeps the warning" \
  "an exception unwinding execute() past a held warning: an unwritable stderr does not replace it" \
  "a raising retire: execute() surfaces the seam's exception, not an AssertionDefect" \
  "a raising closure recorder: execute() surfaces the seam's exception, not an AssertionDefect" \
  "$issue26_leg"

# Issue #25: a retargeted directory link on an import path forces a
# recompile, and the index walk records the link. BOTH legs (R18-L1): a
# junction on windows, a symlink on macOS (tests/support/dirlink.nim); the
# file has no platform-gated case, so every case runs on each. No skip path.
require_per_file "tests/integration/test_issue25_symlink_retarget.nim" \
  "test_issue25_symlink_retarget done" "" \
  "a plain run after the repoint recompiles and reports the real failure" \
  "--no-cache after the repoint does not reuse the stale binary" \
  "repointing back recompiles again and passes" \
  "a link crossed BEFORE another link on the import path is tracked too" \
  "CONTROL repointing a link the test never crossed keeps the skip" \
  "CONTROL an unchanged link keeps the compile skip and the cache hit" \
  "the entry records the link, isEntryStale sees the repoint, a bad link drops the entry" \
  "a link inside a dot-directory is recorded and its repoint recompiles" \
  "a link inside a nimcache-named directory is recorded and its repoint recompiles" \
  "a link inside a relative dep root outside the project is recorded and its repoint recompiles"

# R8-L1: toolrun's presence contract -- "not on PATH -> reNotStarted,
# ran-and-failed -> reExited with its exit code" -- which ccidentity's
# fail-closed probes rest on. BOTH legs: no skip path, no isMainModule marker.
require_per_file "tests/integration/test_probe_presence_contract.nim" "" "" \
  "a command that is not on PATH: not started" \
  "a command that ran and exited non-zero: ran, its exit code and output" \
  "CONTROL a command that ran and exited 0: ran, its output, ok"

# R7-L6: the toolchainFp producer chain, a real measured run through the
# self-reexec measure worker. BOTH legs. No skip path.
require_per_file "tests/integration/test_toolchainfp_producer_chain.nim" \
  "test_toolchainfp_producer_chain done" "" \
  "the fingerprint is derived from nim + the injected cc identity and reaches rows AND the compile block" \
  "a different cc identity yields a different fingerprint at every hop (no constant fold)" \
  "the default probe stamps the REAL host toolchain identity" \
  "execute() threads toolchainFingerprint(nimVersion, ccVersion) to both row streams; nim alone moves it"

# R6-S5: the C backend each leg built its B4b sweep with
# (tests/conformance/test_cc_backend.nim, swept in on both legs, with
# CRISOL_EXPECT_CC pinned in each sweep's env). The file hard-asserts the
# pin itself; this check makes the gate see it too, so a sweep that stops
# running the file, or runs it unpinned, or on another backend, fails here.
# Exactly one distinct backend line, and it is this leg's.
case "$LEG" in
  windows) want_cc=vcc ;;
  *)       want_cc=clang ;;
esac
seen_cc="$(grep -o 'CRISOL-CC-BACKEND: [^[:space:]]*' "$LOG" | sed 's/^CRISOL-CC-BACKEND: //' | sort -u | paste -sd ' ' -)"
if [ "$seen_cc" != "$want_cc" ]; then
  echo "MUST-EXECUTE FAILED ($LEG): test_cc_backend.nim reported backend(s) '${seen_cc}', expected exactly '$want_cc'" >&2
  fail=1
else
  echo "MUST-EXECUTE OK ($LEG): test_cc_backend.nim reported the $want_cc backend"
fi
require_in_log "tests/conformance/test_cc_backend.nim" \
  "test_cc_backend done" "" \
  "this build's backend is reported, and matches CRISOL_EXPECT_CC when pinned"

# --- PER-FILE DRIFT (R12-D9): the per-file steps ci.yml gives this leg's job
# and the require_per_file / per_file_pinned_skip blocks above must name the
# same files. A per-file step is a non-comment line of the job that runs
# `nim r ... tests/<x>.nim` and writes into harness.log. Any OTHER line of the
# job that writes into harness.log, except the B4b sweep and this audit, is
# reported rather than passed over, so a new kind of producer cannot slip past
# the parse; and a job with no per-file step at all is a parse that went blind,
# not a pass. Steps that do not write into harness.log are out of scope:
# nothing they print reaches this script. CRISOL_CI_WORKFLOW overrides the
# workflow path (ci/assert-subset-honesty.selftest.sh points it at mutated
# copies).
WORKFLOW="${CRISOL_CI_WORKFLOW:-.github/workflows/ci.yml}"
if [ ! -f "$WORKFLOW" ]; then
  echo "PER-FILE DRIFT FAILED ($LEG): workflow not found: $WORKFLOW (run from the repository root)" >&2
  fail=1
else
  # R15-S3: a YAML anchor/alias/merge key can move a step's REAL text
  # somewhere this parse never scopes into (a job it resolves into by
  # reference, not by the text lying in that job's own lines) -- checked
  # once, over the whole file, not per leg. Scoped to the canonical
  # `key: &name` / `key: *name` / `<<:` shapes (colon-anchored, end of
  # line) rather than a bare `&`/`*` search, which would flag every `&&` and
  # `tests/*.nim` glob in this file's own bash bodies.
  yamlalias="$(grep -nE ':[[:space:]]*[&*][A-Za-z_][A-Za-z0-9_]*[[:space:]]*$|<<:' "$WORKFLOW" || true)"
  if [ -n "$yamlalias" ]; then
    echo "PER-FILE DRIFT CANNOT TELL ($LEG): $WORKFLOW uses a YAML anchor/alias/merge key -- this parse only reads a job's own text and cannot resolve what such a line actually runs:" >&2
    # R15-S3: printf '  %s\n' "$multiline" only recycles its format across
    # SEPARATE positional args -- a single quoted string with embedded
    # newlines substitutes once, so every line past the first would print
    # unindented. sed prefixes every line regardless of count.
    printf '%s\n' "$yamlalias" | sed 's/^/  /' >&2
    cannot_tell=1
  fi

  parsed="$(awk -v job="$LEG" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob = ($1 == job ":"); if (injob) found = 1; next }
    /^[^[:space:]#]/ { injob = 0; next }
    !injob { next }
    # R15-S3: a `for ... in` loop can drive `nim r` against a shell
    # variable on a LATER line -- checked over the whole job (not just
    # harness.log lines: the loop header itself rarely mentions it) so the
    # blind spot is caught at its source, not only if a driven line happens
    # to also spell out a literal tests/*.nim path.
    /^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/ { print "CANNOTTELL FORLOOP " $0; next }
    /^[[:space:]]*#/ || $0 !~ /harness\.log/ { next }
    # R15-S3: the original exclusion was a bare substring test, so a
    # COMMENT or a step-name aside merely mentioning either scripts name
    # exempted the line as readily as a real invocation. Only the exact,
    # anchored, whitespace-trimmed invocation shape is exempt now; any
    # OTHER mention on a line this parse would otherwise judge is reported
    # instead of silently passed over.
    $0 ~ /run-tests\.sh|assert-subset-honesty\.sh/ && $0 !~ /^[[:space:]]*bash ci\/(run-tests|assert-subset-honesty)\.sh([[:space:]]|$)/ { print "CANNOTTELL RUNTESTSMENTION " $0; next }
    /^[[:space:]]*bash ci\/(run-tests|assert-subset-honesty)\.sh([[:space:]]|$)/ { next }
    /nim r / {
      n = 0; rest = $0; first = ""
      while (match(rest, /tests\/[^[:space:]]*\.nim/)) {
        n++
        if (n == 1) first = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
      # R15-S3: match() only ever returns the FIRST tests/*.nim substring on
      # a line -- two producers on one line (`nim r a.nim ... && nim r
      # b.nim ...`, both into harness.log) would otherwise silently STEP the
      # first and never even mention the second, not just leave it unjudged.
      if (n > 1) { print "CANNOTTELL MULTI " $0; next }
      if (n == 1) { print "STEP " first; next }
    }
    { sub(/^[[:space:]]+/, ""); print "UNRECOGNISED " $0 }
    END { if (!found) print "NOJOB" }
  ' "$WORKFLOW")"

  jobcannottell="$(printf '%s\n' "$parsed" | sed -n 's/^CANNOTTELL //p')"
  if [ -n "$jobcannottell" ]; then
    echo "PER-FILE DRIFT CANNOT TELL ($LEG): the '$LEG' job has a construct this parse refuses to judge:" >&2
    printf '%s\n' "$jobcannottell" | sed 's/^/  /' >&2
    cannot_tell=1
  fi

  steps="$(printf '%s\n' "$parsed" | sed -n 's/^STEP //p' | sort -u)"
  judged="$(printf '%s' "$JUDGED" | sed '/^$/d' | sort -u)"
  drift=0
  if printf '%s\n' "$parsed" | grep -q '^NOJOB$'; then
    echo "PER-FILE DRIFT FAILED ($LEG): $WORKFLOW has no '$LEG' job" >&2
    drift=1
  elif [ -z "$steps" ] && [ -z "$jobcannottell" ]; then
    echo "PER-FILE DRIFT FAILED ($LEG): found no per-file harness.log step in the '$LEG' job of $WORKFLOW (the parse went blind)" >&2
    drift=1
  fi
  unrecognised="$(printf '%s\n' "$parsed" | sed -n 's/^UNRECOGNISED //p')"
  if [ -n "$unrecognised" ]; then
    echo "PER-FILE DRIFT FAILED ($LEG): lines in the '$LEG' job write into harness.log but are not a 'nim r tests/<x>.nim' step:" >&2
    printf '  %s\n' "$unrecognised" >&2
    drift=1
  fi
  unjudged="$(comm -23 <(printf '%s\n' "$steps") <(printf '%s\n' "$judged") | sed '/^$/d')"
  if [ -n "$unjudged" ]; then
    echo "PER-FILE DRIFT FAILED ($LEG): per-file step(s) with no require_per_file block in this script:" >&2
    printf '  %s\n' "$unjudged" >&2
    drift=1
  fi
  stepless="$(comm -13 <(printf '%s\n' "$steps") <(printf '%s\n' "$judged") | sed '/^$/d')"
  if [ -n "$stepless" ]; then
    echo "PER-FILE DRIFT FAILED ($LEG): require_per_file block(s) naming a file with no per-file step in the '$LEG' job:" >&2
    printf '  %s\n' "$stepless" >&2
    drift=1
  fi
  if [ "$drift" -eq 1 ]; then
    fail=1
  elif [ -z "$jobcannottell" ] && [ -z "$yamlalias" ]; then
    n=$(printf '%s\n' "$steps" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "PER-FILE DRIFT OK ($LEG): ${n} per-file step(s) in $WORKFLOW, each with its block"
  fi
fi

# --- INTEGRATION COVERAGE (R15-D11): every tests/integration/*.nim
# entrypoint discovered by crisol.nimble's own `task test` (a *.nim file
# directly under tests/integration/ whose basename starts with "test_" --
# helpers and fixtures live under tests/support/ and tests/fixtures/,
# outside this directory, and that task's walkDirRec+filter never discovers
# them either) must be run by AT LEAST ONE leg:
#   - the Linux `test` job's default nimble sweep -- unconditional on file
#     name, so it counts for every file, PROVIDED that job's own
#     `ci/run-tests.sh` step still has no CRISOL_TEST_DIRS override, or has
#     one whose value still names tests/integration;
#   - a windows or macos per-file step -- this script's own
#     require_per_file / per_file_pinned_skip blocks, named literally,
#     grepped from THIS SCRIPT's own source (not re-derived from $JUDGED,
#     which only holds the CURRENT leg's blocks) so a shared,
#     leg-unconditional block counts for either leg; or
#   - an explicit, documented exemption below.
# Without this, a file that slips past all three -- most concretely, a
# future edit to the Linux job's own step that narrows CRISOL_TEST_DIRS and
# forgets tests/integration -- would silently stop running EVERYWHERE.
# R7-L6 and R17-L1 were exactly this shape (a file that never ran on the
# windows/macos legs), found only by hand; this makes the Linux-sweep half
# of that same risk fail here instead. Leg-independent (source text only,
# like PER-FILE DRIFT above), so it runs identically on both invocations of
# this script; it does not depend on $WORKFLOW parsing cleanly above (a
# YAML-alias/for-loop/etc CANNOTTELL there does not by itself make this
# section wrong, since it reasons about the Linux job, not the windows/macos
# job that check inspects) but still needs $WORKFLOW to exist.
#
# INTEGRATION_NO_LEG_EXEMPT: bare filenames ("test_x.nim") exempted from the
# rule above even though no leg runs them for real, with the reason recorded
# here rather than beside each entry (matching this script's own house
# style for a pinned allowlist). Empty today; a stale entry (naming a file
# no longer on disk under tests/integration/) is drift, same as everywhere
# else in this script.
INTEGRATION_NO_LEG_EXEMPT="$(cat <<'EOF'
EOF
)"

if [ -f "$WORKFLOW" ]; then
  job_test="$(awk '
    /^  test:[[:space:]]*$/ { grab = 1; print; next }
    grab && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    grab { print }
  ' "$WORKFLOW")"
  # A step is the lines from one `      - name:` up to (not including) the
  # next. A step "counts" when its own text mentions run-tests.sh AND
  # either never mentions CRISOL_TEST_DIRS= at all (the default dirs apply,
  # which include tests/integration) or mentions it with a value that still
  # names tests/integration. Comment lines are skipped outright: a step's
  # DOCUMENTING comment sits textually BEFORE its own `- name:` line, i.e.
  # inside the PRECEDING step's accumulated text, so a comment mentioning
  # run-tests.sh (as prose, about the step it precedes) would otherwise
  # credit the wrong step -- and once `done` latches true it never resets,
  # so one misattributed credit near the top of the job would silently mask
  # every real narrowing after it.
  linux_sweeps_integration="$(printf '%s\n' "$job_test" | awk '
    /^      - name:/ { if (saw_run && ok_dirs) done = 1; saw_run = 0; ok_dirs = 1; next }
    /^[[:space:]]*#/ { next }
    /run-tests\.sh/ { saw_run = 1 }
    /CRISOL_TEST_DIRS=/ { ok_dirs = ($0 ~ /tests\/integration/) }
    END { if (saw_run && ok_dirs) done = 1; print (done ? 1 : 0) }
  ')"

  SELF="${BASH_SOURCE[0]:-$0}"
  # R15-D11: neither `find` nor `xargs` is present in the CI nim container
  # (a minimal image) -- basename via sed's `.*/` strip and a bash glob loop
  # instead, so this check does not silently go vacuous there.
  PERFILE_NAMED="$(grep -oE '(require_per_file|per_file_pinned_skip) "tests/integration/[^"]+\.nim"' "$SELF" | grep -oE 'tests/integration/[^"]+\.nim' | sed 's#.*/##' | sort -u)"
  EXEMPT_SORTED="$(printf '%s\n' "$INTEGRATION_NO_LEG_EXEMPT" | sed '/^$/d' | sort -u)"
  ON_DISK="$(
    for f in tests/integration/test_*.nim; do
      [ -f "$f" ] && printf '%s\n' "${f##*/}"
    done | sort -u
  )"

  stale_exempt="$(comm -23 <(printf '%s\n' "$EXEMPT_SORTED") <(printf '%s\n' "$ON_DISK") | sed '/^$/d')"
  if [ -n "$stale_exempt" ]; then
    echo "INTEGRATION COVERAGE FAILED ($LEG): INTEGRATION_NO_LEG_EXEMPT names file(s) not on disk under tests/integration/:" >&2
    printf '%s\n' "$stale_exempt" | sed 's/^/  /' >&2
    fail=1
  fi

  if [ "$linux_sweeps_integration" = "1" ]; then
    n=$(printf '%s\n' "$ON_DISK" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "INTEGRATION COVERAGE OK ($LEG): the Linux test job's default sweep covers every tests/integration/ file (${n})"
  else
    orphans="$(comm -23 <(printf '%s\n' "$ON_DISK") <(printf '%s\n' "$PERFILE_NAMED" "$EXEMPT_SORTED" | sed '/^$/d' | sort -u))"
    if [ -n "$orphans" ]; then
      echo "INTEGRATION COVERAGE FAILED ($LEG): the Linux test job no longer sweeps tests/integration/ by default, and no leg runs (or exempts) these file(s):" >&2
      printf '%s\n' "$orphans" | sed 's/^/  /' >&2
      fail=1
    else
      echo "INTEGRATION COVERAGE OK ($LEG): the Linux sweep is narrowed, but every tests/integration/ file is covered by a per-file step or a documented exemption"
    fi
  fi
fi

if [ "$cannot_tell" -eq 1 ]; then
  exit 2
fi
exit $fail
