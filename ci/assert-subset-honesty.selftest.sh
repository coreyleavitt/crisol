#!/usr/bin/env bash
# ci/assert-subset-honesty.selftest.sh — mutation proof for the per-file drift
# check in ci/assert-subset-honesty.sh (R12-D9).
#
# Usage (CWD = repository root):
#   ci/assert-subset-honesty.selftest.sh
#
# The drift check parses the windows and macos jobs of .github/workflows/ci.yml
# and fails when a per-file `nim r ... tests/<x>.nim | tee -a harness.log` step
# has no require_per_file block in the script, or a block names a file with no
# step. Every case below mutates a COPY of ci.yml (pointed at through
# CRISOL_CI_WORKFLOW) or a COPY of the script, in its own `mktemp -d`
# directory; the working tree is never touched. Each mutation ends by grepping
# the copy for the text it was meant to produce, and a case whose mutation did
# not apply FAILS (a no-op mutation would otherwise "pass" any case that
# expects the baseline, and silently test nothing). Each case pins the
# script's exact exit code and at least one output line.
#
# The harness logs the cases run against are BUILT, not hand-kept: starting
# from an empty log, the script is run and every line its failures name as
# missing (an `[OK]` line, a `done` or real-body marker, a pinned skip marker,
# the backend line) is appended, until it passes. A hand-kept passing log
# would be a third copy of the lists this check exists to keep single. A leg
# whose log does not converge is "cannot tell" (exit 2): the unmutated tree
# must pass before any mutation case can be judged.
#
# Exit codes: 0 = every case behaved as pinned below; 1 = at least one case
# FAILED; 2 = cannot tell (not run from the repository root, or no passing log
# could be built for a leg).
#
# Portable to the same environments as the script: bash, mktemp, sed, grep,
# awk, sort, comm. No python.
export LC_ALL=C
set -uo pipefail

if [ ! -f .github/workflows/ci.yml ] || [ ! -f ci/assert-subset-honesty.sh ]; then
  echo "assert-subset-honesty.selftest.sh: run from the repository root" >&2
  exit 2
fi
GATE="$(pwd)/ci/assert-subset-honesty.sh"
WF="$(pwd)/.github/workflows/ci.yml"
FAILS=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# needed_lines: read the script's stderr on stdin, print the log lines that
# would satisfy each failure it names.
needed_lines() {
  # A5c's message trails a parenthetical after the quoted marker; drop it so
  # the quoted text ends the line like every other message's.
  sed "s/' (did not reach [^']*\$/'/" |
  sed -n \
    -e "s/.*missing '\\(.*\\)'\$/\\1/p" \
    -e "s/.*(missing '\\(.*\\)')\$/\\1/p" \
    -e "s/.*(missing \\/\\(.*\\)\\/)\$/\\1/p" \
    -e "s/.*expected exactly '\\(.*\\)'\$/CRISOL-CC-BACKEND: \\1/p" \
    -e 's/^< \(.*#.*\)$/CRISOL-SKIP-TEST: \1/p' \
    -e 's/^< \(.*\)$/CRISOL-SKIP: \1/p' |
  # A real-body regex such as `RFC9-A3BII MODE (1|2|3)`: take its first
  # alternative.
  sed 's/(\([^|)]*\)|[^)]*)/\1/'
}

# build_log <leg> <out>: grow <out> until the unmutated script passes on it.
build_log() {
  local leg="$1" out="$2" i err add
  : > "$out"
  for i in $(seq 1 20); do
    err="$(CRISOL_CI_WORKFLOW="$WF" bash "$GATE" "$out" "$leg" 2>&1 >/dev/null)" && return 0
    add="$(printf '%s\n' "$err" | needed_lines | sed '/^$/d')"
    [ -n "$add" ] || break
    printf '%s\n' "$add" >> "$out"
  done
  echo "assert-subset-honesty.selftest.sh: CANNOT TELL, no passing $leg log could be built; the script's last failures:" >&2
  CRISOL_CI_WORKFLOW="$WF" bash "$GATE" "$out" "$leg" 2>&1 | sed 's/^/    | /' >&2
  exit 2
}

build_log windows "$WORK/windows.log"
build_log macos "$WORK/macos.log"

# case_ <name> <leg> <expected-rc> <mutation-fn> [+pattern | -pattern]...
#   +P  output must contain the fixed string P
#   -P  output must NOT contain the fixed string P
# The mutation function runs inside a work dir holding ci.yml (a copy of the
# workflow) and must return 0 only when its own post-check grep found the
# mutated text. It may also write ./gate.sh (a mutated copy of the script),
# and that copy is what runs.
case_() {
  local name="$1" leg="$2" want="$3" mutate="$4"; shift 4
  local w out rc mrc ok=1 a p gate
  w="$(mktemp -d)"
  cp "$WF" "$w/ci.yml"
  ( cd "$w" && "$mutate" ); mrc=$?
  gate="$GATE"
  [ -f "$w/gate.sh" ] && gate="$w/gate.sh"
  out="$(CRISOL_CI_WORKFLOW="$w/ci.yml" bash "$gate" "$WORK/$leg.log" "$leg" 2>&1)"; rc=$?
  rm -rf "$w"
  [ "$mrc" -eq 0 ] || { ok=0; echo "  mutation did not apply (its post-check grep failed)"; }
  [ "$rc" -eq "$want" ] || { ok=0; echo "  expected exit $want, got $rc"; }
  for a in "$@"; do
    case "$a" in
      +*) p="${a#+}"; printf '%s\n' "$out" | grep -qF -- "$p" || { ok=0; echo "  missing: $p"; } ;;
      -*) p="${a#-}"; if printf '%s\n' "$out" | grep -qF -- "$p"; then ok=0; echo "  unexpected: $p"; fi ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then
    echo "PASS  $name (exit $rc)"
  else
    echo "FAIL  $name (exit $rc)"; printf '%s\n' "$out" | sed 's/^/    | /'
    FAILS=$((FAILS + 1))
  fi
}

STEP_PREFIX='        run: nim r --hints:off --warnings:off --path:src'

# insert_after <anchor-fixed-string> <line>: insert <line> after the FIRST line
# of ci.yml containing the anchor, and verify it landed.
# R15-D11: awk's `-v var=value` runs ANSI-C escape processing on the value,
# which silently drops a value's own trailing, unescaped backslash (as a
# `CRISOL_TEST_DIRS=... \` line-continuation ends in) -- no prior mutation
# here ended a line that way, so this never surfaced before. ENVIRON[] reads
# the environment verbatim, with no such processing, so pass through env
# instead of -v.
insert_after() {
  ANCHOR="$1" LINE="$2" awk '
    { print }
    !done && index($0, ENVIRON["ANCHOR"]) { print ENVIRON["LINE"]; done = 1 }
  ' ci.yml > ci.yml.new && mv ci.yml.new ci.yml && grep -qF -- "$2" ci.yml
}

m_none() { :; }

# A new windows per-file step that nobody wrote a block for.
m_new_windows_step() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    "$STEP_PREFIX tests/integration/test_selftest_new_step.nim 2>&1 | tee -a harness.log"
}

# A windows step deleted (name, if and run lines) while its block stays.
m_drop_windows_step() {
  awk '
    { buf[NR] = $0 }
    index($0, "tests/integration/test_tool_env_scrub.nim 2>&1 | tee -a harness.log") { drop[NR] = drop[NR-1] = drop[NR-2] = 1 }
    END { for (i = 1; i <= NR; i++) if (!drop[i]) print buf[i] }
  ' ci.yml > ci.yml.new && mv ci.yml.new ci.yml &&
    ! grep -qF 'test_tool_env_scrub.nim' ci.yml && grep -qF 'test_tool_interrupt.nim' ci.yml
}

# A windows step kept but no longer appended into harness.log.
m_untee_windows_step() {
  sed -i 's#tests/integration/test_tool_tree_termination.nim 2>&1 | tee -a harness.log#tests/integration/test_tool_tree_termination.nim#' ci.yml &&
    grep -qE 'test_tool_tree_termination\.nim$' ci.yml
}

# A block deleted from the script while its step stays (the script copy runs).
m_drop_block() {
  awk '
    index($0, "require_per_file \"tests/integration/test_tool_tree_termination.nim\"") { skip = 1 }
    skip && /^[[:space:]]*$/ { skip = 0 }
    !skip { print }
  ' "$GATE" > gate.sh &&
    ! grep -qF 'test_tool_tree_termination.nim' gate.sh && grep -qF 'test_tool_env_scrub.nim' gate.sh
}

# A new macos step: the macos leg fails, and the windows leg (whose job does
# not have it) is unaffected -- the parse is scoped to the leg's own job.
m_new_macos_step() {
  # The anchor step exists in both jobs; insert after the macos job's copy.
  awk -v line="$STEP_PREFIX tests/integration/test_selftest_macos_step.nim 2>&1 | tee -a harness.log" '
      { print }
      /^  macos:/ { inmac = 1 }
      inmac && !done && index($0, "test_toolchainfp_producer_chain.nim 2>&1 | tee -a harness.log") { print line; done = 1 }
    ' ci.yml > ci.yml.new && mv ci.yml.new ci.yml &&
    grep -qF 'test_selftest_macos_step.nim' ci.yml &&
    [ "$(awk '/^  macos:/{m=1} m && /test_selftest_macos_step/' ci.yml | wc -l)" -eq 1 ]
}

# Something other than a `nim r tests/<x>.nim` step writes into harness.log.
m_unrecognised_writer() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    '        run: ./tools/selftest-probe.exe 2>&1 | tee -a harness.log'
}

# The windows job is renamed: a parse that finds no job must fail, not pass
# with an empty step set.
m_rename_job() {
  sed -i 's/^  windows:$/  windows-msvc:/' ci.yml && grep -q '^  windows-msvc:$' ci.yml
}

# A COMMENT that looks like a per-file step is not a step.
m_comment_step() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    "      # $STEP_PREFIX tests/integration/test_selftest_commented.nim 2>&1 | tee -a harness.log"
}

# A per-file step in ANOTHER job (the linux `test` job) is not the windows
# leg's.
m_other_job_step() {
  awk -v line="$STEP_PREFIX tests/integration/test_selftest_other_job.nim 2>&1 | tee -a harness.log" '
    { print }
    /^  test:$/ { intest = 1 }
    intest && !done && /^    runs-on:/ { print "    steps:"; print "      - name: selftest"; print line; done = 1 }
  ' ci.yml > ci.yml.new && mv ci.yml.new ci.yml && grep -qF 'test_selftest_other_job.nim' ci.yml
}

# A pin-judged declaration whose pin does not name the file is false.
m_false_pin() {
  sed 's#per_file_pinned_skip "tests/integration/test_real_cl_identity.nim"#per_file_pinned_skip "tests/integration/test_selftest_unpinned.nim"#' \
    "$GATE" > gate.sh && grep -qF 'test_selftest_unpinned.nim' gate.sh
}

# R15-S3: a `for ... in` loop in the job -- the parse cannot tell whether it
# drives `nim r` against a shell variable, so it must not silently resolve
# either way.
m_forloop() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    '        for f in tests/integration/test_selftest_forloop.nim; do'
}

# R15-S3: two producers on one line -- match() would otherwise only ever
# name the first and never even mention the second.
m_multi() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    "$STEP_PREFIX tests/integration/test_selftest_multi_a.nim 2>&1 | tee -a harness.log && nim r --hints:off --warnings:off --path:src tests/integration/test_selftest_multi_b.nim 2>&1 | tee -a harness.log"
}

# R15-S3: a bare MENTION of run-tests.sh on an otherwise-real per-file step
# line -- only the exact, anchored invocation is exempt; a trailing comment
# naming the script must not exempt a real step alongside it.
m_runtests_mention() {
  insert_after 'tests/integration/test_tool_interrupt.nim 2>&1 | tee -a harness.log' \
    "$STEP_PREFIX tests/integration/test_selftest_mention.nim 2>&1 | tee -a harness.log # ci/run-tests.sh"
}

# R15-S3: a YAML anchor/alias/merge key anywhere in the file -- this parse
# only reads a job's own text and cannot resolve what such a line runs.
m_yaml_alias() {
  insert_after 'jobs:' '  x_selftest_shared: &selftest_shared_step'
}

# R15-D11: the Linux `test` job's own sweep step narrowed to drop
# tests/integration -- every file that relies solely on that default sweep
# (no windows/macos per-file step, no exemption) becomes an orphan.
m_narrow_linux_sweep() {
  insert_after '-e CRISOL_TIER=ci-linux \' \
    '            -e CRISOL_TEST_DIRS=tests/unit:tests/conformance \'
}

# R15-D11: a stale INTEGRATION_NO_LEG_EXEMPT entry (naming a file no longer
# on disk under tests/integration/) is drift, same as everywhere else in
# this script.
m_stale_exempt() {
  awk '
    { print }
    index($0, "INTEGRATION_NO_LEG_EXEMPT=") && !done { print "test_selftest_nonexistent.nim"; done = 1 }
  ' "$GATE" > gate.sh &&
    grep -qF 'test_selftest_nonexistent.nim' gate.sh
}

case_ "baseline: the tree's ci.yml and blocks agree (windows)" windows 0 m_none \
  "+PER-FILE DRIFT OK (windows)" "-PER-FILE DRIFT FAILED" \
  "+INTEGRATION COVERAGE OK (windows)" "-CANNOT TELL"
case_ "baseline: the tree's ci.yml and blocks agree (macos)" macos 0 m_none \
  "+PER-FILE DRIFT OK (macos)" "-PER-FILE DRIFT FAILED" \
  "+INTEGRATION COVERAGE OK (macos)" "-CANNOT TELL"
case_ "a new windows per-file step with no block is drift" windows 1 m_new_windows_step \
  "+per-file step(s) with no require_per_file block" \
  "+  tests/integration/test_selftest_new_step.nim"
case_ "a deleted windows step whose block remains is drift" windows 1 m_drop_windows_step \
  "+block(s) naming a file with no per-file step" \
  "+  tests/integration/test_tool_env_scrub.nim"
case_ "a windows step that stops appending into harness.log is drift" windows 1 m_untee_windows_step \
  "+block(s) naming a file with no per-file step" \
  "+  tests/integration/test_tool_tree_termination.nim"
case_ "a block deleted from the script while its step remains is drift" windows 1 m_drop_block \
  "+per-file step(s) with no require_per_file block" \
  "+  tests/integration/test_tool_tree_termination.nim"
case_ "a new macos per-file step with no block is drift (macos)" macos 1 m_new_macos_step \
  "+per-file step(s) with no require_per_file block" \
  "+  tests/integration/test_selftest_macos_step.nim"
case_ "a new macos per-file step is not the windows leg's" windows 0 m_new_macos_step \
  "+PER-FILE DRIFT OK (windows)" "-test_selftest_macos_step"
case_ "any other harness.log writer in the job is reported" windows 1 m_unrecognised_writer \
  "+write into harness.log but are not a 'nim r tests/<x>.nim' step" \
  "+  run: ./tools/selftest-probe.exe 2>&1 | tee -a harness.log"
case_ "a job the parse cannot find fails, never passes empty" windows 1 m_rename_job \
  "+has no 'windows' job"
case_ "a commented-out step is not a step" windows 0 m_comment_step \
  "+PER-FILE DRIFT OK (windows)" "-test_selftest_commented"
case_ "a per-file step in another job is not the leg's" windows 0 m_other_job_step \
  "+PER-FILE DRIFT OK (windows)" "-test_selftest_other_job"
case_ "a pin-judged file the pin does not name is a failure (macos)" macos 1 m_false_pin \
  "+tests/integration/test_selftest_unpinned.nim is declared pin-judged" \
  "+  tests/integration/test_real_cl_identity.nim"
case_ "a for loop in the job is cannot-tell, not silently resolved (R15-S3)" windows 2 m_forloop \
  "+CANNOT TELL" "+FORLOOP" "+test_selftest_forloop.nim"
case_ "two producers on one line hides the second from a bare pass (R15-S3)" windows 2 m_multi \
  "+CANNOT TELL" "+MULTI" "+test_selftest_multi_a.nim" "+test_selftest_multi_b.nim"
case_ "a bare mention of run-tests.sh beside a real step is cannot-tell (R15-S3)" windows 2 m_runtests_mention \
  "+CANNOT TELL" "+RUNTESTSMENTION" "+test_selftest_mention.nim"
case_ "a YAML anchor anywhere in the workflow is cannot-tell, not a pass (R15-S3)" windows 2 m_yaml_alias \
  "+CANNOT TELL" "+YAML anchor/alias/merge key" "+x_selftest_shared"
case_ "a Linux sweep narrowed to drop tests/integration orphans its files (R15-D11)" windows 1 m_narrow_linux_sweep \
  "+INTEGRATION COVERAGE FAILED" "+  test_changed.nim"
case_ "a stale INTEGRATION_NO_LEG_EXEMPT entry is drift (R15-D11)" windows 1 m_stale_exempt \
  "+INTEGRATION_NO_LEG_EXEMPT names file(s) not on disk" "+  test_selftest_nonexistent.nim"

if [ "$FAILS" -ne 0 ]; then
  echo "assert-subset-honesty.selftest.sh: $FAILS case(s) FAILED" >&2
  exit 1
fi
echo "assert-subset-honesty.selftest.sh: all cases passed"
