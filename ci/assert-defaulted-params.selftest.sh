#!/usr/bin/env bash
# ci/assert-defaulted-params.selftest.sh — mutation proof for
# ci/assert-defaulted-params.sh.
#
# Usage (CWD = repository root):
#   ci/assert-defaulted-params.selftest.sh
#
# Every case copies `src/` into its own `mktemp -d` directory, mutates the COPY
# and runs the gate there; the working tree is never touched. Each mutation
# ends by grepping the copy for the text it was meant to produce, and a case
# whose mutation did not apply FAILS (a no-op mutation would otherwise "pass"
# any case that expects the baseline, and silently test nothing). Each case
# then pins the gate's EXACT exit code and at least one positive output line.
#
# Exit codes: 0 = every case behaved as pinned below; 1 = at least one case
# FAILED; 2 = cannot tell (not run from the repository root, or the gate is not
# green on the unmutated tree, so no mutation case could be judged).
#
# The cases pin the round-6 findings the gate was fixed for:
#   S2  a `(` / `)` / `#` inside a string, raw string, triple string, char
#       literal or block comment must NOT move the depth walk: the gate must
#       still see every later defaulted parameter, in that file and in every
#       later file (before the fix, one `"("` default blinded the rest of the
#       census with the gate still green or reporting a phantom drift).
#   S2  a file that ends with an open signature, generic section, triple
#       string or block comment is "cannot tell" (exit 2), never a pass or a
#       drift.
#   D2  a changed default VALUE is drift (exit 1) naming old and new value.
#   and the two directions the gate always had: a new defaulted parameter and a
#   removed one are both drift (exit 1).
# and the round-7 findings (each shape below was proven to compile under
# `nim check` when appended to src/crisol/types.nim, 2026-09-25):
#   R7-S2 M2   generic parameter section spanning lines
#   R7-S2 M16  routine name, line break, then `[T](...)`
#   R7-S2 M14  non-ASCII routine name
#   R7-S2 M6   routine after a statement on the same line (`discard 0; proc`)
#   R7-S2 M4   anonymous proc (lambda) with a defaulted parameter
#   R7-S2 M5   proc TYPE with a defaulted parameter, standalone and nested
#              inside another routine's parameter list
#   R7-S2 M7   object-field default (new field, and a changed value)
#   R7-S2      a routine keyword the scanner cannot resolve is cannot-tell
#   R7-L5      a raw string ending in `\` (`r"C:\"`) must end at that quote:
#              lexed as a NON-raw string, the `\"` would swallow the rest of
#              the list and lose `b`.
#   R7-L5      per-file reset: a file ENDING in a paramless routine header
#              followed by a file whose FIRST line holds a defaulted parameter;
#              state leaking across the file boundary loses that record.
# and the round-8 findings (each Nim shape below was proven under `nim r`,
# 2.2.10, 2026-09-25, to compile AND to apply its default -- `T()` / `default(T)`
# observed the pinned value; a `do` block's default compiles but its lambda
# TYPE drops it, see the gate's RECORD FORMAT):
#   R8-S2  `=` and `object` on different lines: `T* =` / `object`, a comment
#          after `=`, `= ref` / `object of B`, `=` / `ref object of B`
#   R8-L4  one case per object-field scanner arm no tree record exercises:
#          continuation absorption, `case` / `of` stripping, field-pragma
#          stripping, `ref` / `ptr object` recognition
#   R8-S4  tuple-field defaults (bracket and block form) and a `do` block
#   R8-D7  a lambda in a typed binding is labelled by the bound name; a new
#          field record's drift report says its reason opens with the bucket
#   R8-L5  the count backstop, reached by mutating a COPY of the gate
#
# Portable to the same environments as the gate (BusyBox dev image, mawk,
# gawk): no find, no xargs, no diff.
export LC_ALL=C
set -uo pipefail

if [ ! -d src ] || [ ! -f ci/assert-defaulted-params.sh ]; then
  echo "assert-defaulted-params.selftest.sh: run from the repository root" >&2
  exit 2
fi
GATE="$(pwd)/ci/assert-defaulted-params.sh"
SRC="$(pwd)/src"
FAILS=0

# case <name> <expected-rc> <mutation-fn> [+pattern | -pattern | =N:pattern]...
#   +P  output must contain the fixed string P
#   -P  output must NOT contain a line starting with P
#   =N:P  exactly N output lines start with P
# The mutation function runs inside the copy and must return 0 only when its
# own post-check grep found the mutated text.
case_() {
  local name="$1" want="$2" mutate="$3"; shift 3
  local w out rc mrc ok=1 a p n got
  w="$(mktemp -d)"
  cp -R "$SRC" "$w/src"
  ( cd "$w" && "$mutate" ); mrc=$?
  # A mutation may also mutate the GATE: it writes a copy to ./gate.sh in the
  # work dir (never the real script), and that copy is what runs.
  if [ -f "$w/gate.sh" ]; then
    out="$(cd "$w" && bash ./gate.sh 2>&1)"; rc=$?
  else
    out="$(cd "$w" && bash "$GATE" 2>&1)"; rc=$?
  fi
  rm -rf "$w"
  [ "$mrc" -eq 0 ] || { ok=0; echo "  mutation did not apply (its post-check grep failed)"; }
  [ "$rc" -eq "$want" ] || { ok=0; echo "  expected exit $want, got $rc"; }
  for a in "$@"; do
    case "$a" in
      +*) p="${a#+}"; printf '%s\n' "$out" | grep -qF -- "$p" || { ok=0; echo "  missing: $p"; } ;;
      -*) p="${a#-}"; if printf '%s\n' "$out" | grep -q "^$p"; then ok=0; echo "  unexpected line starting: $p"; fi ;;
      =*) n="${a#=}"; p="${n#*:}"; n="${n%%:*}"
          got="$(printf '%s\n' "$out" | grep -c "^$p")"
          [ "$got" -eq "$n" ] || { ok=0; echo "  expected $n line(s) starting '$p', got $got"; } ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then
    echo "PASS  $name (exit $rc)"
  else
    echo "FAIL  $name (exit $rc)"; printf '%s\n' "$out" | sed 's/^/    | /'
    FAILS=$((FAILS + 1))
  fi
}

# append <file> <text>: append text (after a blank line) and verify it landed.
append() { printf '\n%s\n' "$2" >> "$1" && grep -qF -- "$2" "$1"; }

m_none() { :; }

# S2: literal and comment brackets ahead of every pinned record. admission.nim
# is the first file under src/crisol/, so a leak would blind almost the whole
# census; the gate must report exactly the probe's own new records and no
# stale pin anywhere.
m_literals() {
  local f=src/crisol/admission.nim t
  t="$(mktemp)"
  {
    printf '%s\n' '#[ block ( comment #[ nested ( ]# still ( in it'
    printf '%s\n' '   ( ]#'
    printf '%s\n' 'const zzTriple = """ ( multi'
    printf '%s\n' 'line ( """'
    printf '%s\n' "proc zzLexProbe*(a = \"(\", b = r\"C:\\(\", c = '(', d = \"\"\"(\"\"\","
    printf '%s\n' "                 e = \"\\\")\", f = \"#\", g = 0o600'u32) = discard"
    cat "$f"
  } > "$t"
  cat "$t" > "$f"; rm -f "$t"
  grep -qF 'proc zzLexProbe*(' "$f"
}

# D2: flip values the reasons are about.
m_values() {
  sed -i 's/= hlIsolated;/= hlNone;/' src/crisol/sandbox.nim
  sed -i 's/mode: int = 0o600/mode: int = 0o666/' src/crisol/ioutils.nim
  grep -q '= hlNone;' src/crisol/sandbox.nim && grep -q 'mode: int = 0o666' src/crisol/ioutils.nim
}

m_open_sig()     { append src/crisol/toolexec.nim 'proc zzOpen*(a: int = 1,'; }
m_open_generic() { append src/crisol/toolexec.nim 'proc zzOpenG*[T: SomeInteger;'; }
m_open_block()   { append src/crisol/toolexec.nim '#[ never closed'; }
m_open_triple()  { append src/crisol/toolexec.nim 'const zz = """ open'; }
m_add()          { append src/crisol/types.nim 'proc zzNew*(x: int = 7) = discard'; }
m_remove() {
  sed -i 's/^  failFast:         bool = false;/  failFast:         bool;/' src/crisol/runner.nim
  grep -q '^  failFast:         bool;' src/crisol/runner.nim
}

# R7-S2 shapes. Each one was a defaulted parameter the round-6 scanner counted
# (or never saw) and dropped, with the gate still green.
m_m2()  { append src/crisol/types.nim "$(printf '%s\n%s' 'proc zzGen*[T: SomeInteger;' '            U](x: T; trusted: bool = true) = discard')"; }
m_m16() { append src/crisol/types.nim "$(printf '%s\n%s' 'proc zzGen16*' '    [T](x: T, trusted: bool = true) = discard')"; }
m_m14() { append src/crisol/types.nim "$(printf 'proc \303\261zz*(trusted: bool = true) = discard')"; }
m_m6()  { append src/crisol/types.nim 'discard 0; proc zzSemi*(trusted: bool = true) = discard'; }
m_m4()  { append src/crisol/types.nim 'let zzLam* = proc (trusted: bool = true): bool = trusted'; }
m_m5()  { append src/crisol/types.nim 'type ZzF* = proc (trusted: bool = true) {.nimcall.}'; }
m_m5b() { append src/crisol/types.nim 'proc zzOuter*(cb: proc (x: int = 1) {.nimcall.} = nil) = discard'; }
m_m7()  { append src/crisol/types.nim "$(printf '%s\n%s' 'type ZzObj* = object' '  trusted*: bool = true')"; }
m_m7v() {
  sed -i 's/^    claimOrphans\*: bool = true/    claimOrphans*: bool = false/' src/crisol/process/types.nim
  grep -q '^    claimOrphans\*: bool = false' src/crisol/process/types.nim
}
# Not valid Nim: the scanner's own contract (a keyword it cannot resolve to a
# known header shape is cannot-tell, never silently dropped).
m_unparsed() { append src/crisol/types.nim 'proc zzOdd* zzJunk'; }

# R7-L5: raw string whose last character is a backslash.
m_raw() { append src/crisol/types.nim 'proc zzRaw*(a = r"C:\", b = 2) = discard'; }

# R7-L5: per-file reset. File A (admission.nim) ENDS in a routine header with
# no parameter list; file B, the next file the gate reads (computed, not
# hard-coded, from the same sorted globstar order the gate uses), gets a
# defaulted parameter on its FIRST line.
m_reset() {
  local a=src/crisol/admission.nim b t
  shopt -s globstar nullglob
  b="$(printf '%s\n' src/**/*.nim | sort | grep -A1 -xF "$a" | sed -n 2p)"
  [ -n "$b" ] || return 1
  append "$a" 'proc zzTail* {.importc: "zzTail", nodecl.}' || return 1
  t="$(mktemp)"
  { printf '%s\n' 'proc zzFirst*(a: int = 3) = discard'; cat "$b"; } > "$t"
  cat "$t" > "$b"; rm -f "$t"
  [ "$(tail -n 1 "$a")" = 'proc zzTail* {.importc: "zzTail", nodecl.}' ] &&
    [ "$(head -n 1 "$b")" = 'proc zzFirst*(a: int = 3) = discard' ]
}

# append_lines <file> <line>...: append a multi-line snippet (after a blank
# line) and verify EVERY line of it landed.
append_lines() {
  local f="$1" l; shift
  printf '\n' >> "$f"
  printf '%s\n' "$@" >> "$f"
  for l in "$@"; do grep -qxF -- "$l" "$f" || return 1; done
}

# R8-S2: an object type whose `=` and `object` are on DIFFERENT lines. Each
# was a field default Nim applies (`nim r`: the default is observed) that the
# round-7 one-line regex never saw, with the gate green.
m_r8_split() {
  append_lines src/crisol/types.nim 'type' '  ZzSplit* =' '    object' '      trusted*: bool = true'
}
m_r8_comment() {
  append_lines src/crisol/types.nim 'type' '  ZzCmt* = # a comment after the separator' '    object' '      trusted*: bool = true'
}
m_r8_refsplit() {
  append_lines src/crisol/types.nim 'type' '  ZzRefSplit* = ref' '    object of RootObj' '      trusted*: bool = true'
}
m_r8_refof() {
  append_lines src/crisol/types.nim 'type' '  ZzRefOf* {.inheritable.} =' '    ref object of RootObj' '      trusted*: bool = true'
}

# R8-L4: one case per object-field scanner arm no tree record exercised.
m_r8_cont() {      # continuation absorption: the value starts on the NEXT line
  append_lines src/crisol/types.nim 'type ZzCont* = object' '  trusted*: bool =' '    true'
}
m_r8_variant() {   # `case` / `of` prefix stripping on one-line variant fields
  append_lines src/crisol/types.nim 'type ZzVar* = object' '  case kind*: bool = true' \
    '  of true: trusted*: bool = true' '  of false: discard'
}
m_r8_pragma() {    # a field pragma between the name and its `:`
  append_lines src/crisol/types.nim 'type ZzPrag* = object' '  trusted* {.deprecated.}: bool = true'
}
m_r8_refptr() {    # `= ref object` / `= ptr object` on one line
  append_lines src/crisol/types.nim 'type' '  ZzRef* = ref object' '    trusted*: bool = true' \
    '  ZzPtr* = ptr object' '    trusted*: bool = true'
}

# R8-S4: tuple-field defaults (applied by default(T)), both forms, and a `do`
# block's defaulted parameter.
m_r8_tuple() {
  append_lines src/crisol/types.nim 'type ZzTup* = tuple[a: int, trusted: bool = true]'
}
m_r8_tupleblk() {
  append_lines src/crisol/types.nim 'type ZzTupBlk* = tuple' '  a: int' '  trusted: bool = true'
}
m_r8_do() {
  append_lines src/crisol/types.nim 'proc zzRun(f: proc (x: int, strict: bool)) = f(1, false)' \
    'zzRun do (x: int, strict: bool = true):' '  discard strict'
}

# R8-D7: a lambda in a TYPED binding is recorded under the bound name.
m_r8_typed() {
  append_lines src/crisol/types.nim 'type ZzH* = proc (y: int) {.nimcall.}' \
    'let zzH*: ZzH = proc (y: int = 2) = discard'
}

# R8-L5: the `signatures == with + without` backstop is unreachable on a
# correct scanner, so it is reached by breaking the scanner: a COPY of the gate
# (./gate.sh, which case_ then runs) whose parameter-list count never moves.
m_r8_backstop() {
  cp "$GATE" gate.sh || return 1
  sed -i 's/^    withparams++$/    withparams += 0/' gate.sh
  [ "$(grep -c '^    withparams += 0$' gate.sh)" -eq 1 ] && ! grep -q '^    withparams++$' gate.sh
}

# Every mutation case below asserts the EXACT drift report, so it needs a tree
# that is green to begin with; on a drifted tree it would only report noise.
if ! (bash "$GATE" >/dev/null 2>&1); then
  echo "assert-defaulted-params.selftest.sh: the gate is not green on the current" >&2
  echo "  tree (run ci/assert-defaulted-params.sh); the mutation cases need a green" >&2
  echo "  baseline. Cannot tell." >&2
  exit 2
fi
shopt -s globstar nullglob
RESET_B="$(cd "$SRC/.." && printf '%s\n' src/**/*.nim | sort | grep -A1 -xF src/crisol/admission.nim | sed -n 2p)"
shopt -u globstar nullglob

case_ "baseline: current tree matches the pin set" 0 m_none \
  "+DEFAULTED-PARAMS OK"

case_ "S2: brackets/# inside literals and comments do not blind the census" 1 m_literals \
  '=7:  > src/crisol/admission.nim:zzLexProbe:' \
  '+  > src/crisol/admission.nim:zzLexProbe:a = "("' \
  '+  > src/crisol/admission.nim:zzLexProbe:b = r"C:\("' \
  "+  > src/crisol/admission.nim:zzLexProbe:c = '('" \
  '+  > src/crisol/admission.nim:zzLexProbe:d = """("""' \
  '+  > src/crisol/admission.nim:zzLexProbe:e = "\")"' \
  '+  > src/crisol/admission.nim:zzLexProbe:f = "#"' \
  "+  > src/crisol/admission.nim:zzLexProbe:g = 0o600'u32" \
  '-  < ' '-  ~ '

case_ "D2: a changed default value is drift naming old and new" 1 m_values \
  '+  ~ src/crisol/sandbox.nim:resolveSandbox:level: pinned `= hlIsolated`, observed `= hlNone`' \
  '+  ~ src/crisol/ioutils.nim:appendOpen:mode: pinned `= 0o600`, observed `= 0o666`' \
  '=4:  ~ ' '-  < ' '-  > '

case_ "S2: signature open at end of file is cannot-tell" 2 m_open_sig \
  "+UNBALANCED src/crisol/toolexec.nim:" "+the parameter list of \`zzOpen\`"
case_ "S2: generic section open at end of file is cannot-tell" 2 m_open_generic \
  "+UNBALANCED src/crisol/toolexec.nim:" "+the generic parameter section of \`zzOpenG\`"
case_ "S2: block comment open at end of file is cannot-tell" 2 m_open_block \
  "+UNTERMINATED src/crisol/toolexec.nim"
case_ "S2: triple string open at end of file is cannot-tell" 2 m_open_triple \
  "+UNTERMINATED src/crisol/toolexec.nim"

case_ "new defaulted parameter is drift" 1 m_add \
  "+  > src/crisol/types.nim:zzNew:x = 7" '=1:  > ' '-  < ' '-  ~ '

case_ "removed pinned default is drift" 1 m_remove \
  "+  < src/crisol/runner.nim:execute:failFast = false" '=1:  < ' '-  > ' '-  ~ '

case_ "R7-S2 M2: multi-line generic section is drift" 1 m_m2 \
  "+  > src/crisol/types.nim:zzGen:trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M16: name, line break, [T](...) is drift" 1 m_m16 \
  "+  > src/crisol/types.nim:zzGen16:trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M14: non-ASCII routine name is drift" 1 m_m14 \
  "+$(printf '  > src/crisol/types.nim:\303\261zz:trusted = true')" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M6: routine after a statement on the same line is drift" 1 m_m6 \
  "+  > src/crisol/types.nim:zzSemi:trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M4: anonymous proc (lambda) is drift under its binder" 1 m_m4 \
  "+  > src/crisol/types.nim:anon_proc(zzLam):trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M5: proc type is drift under its type name" 1 m_m5 \
  "+  > src/crisol/types.nim:anon_proc(ZzF):trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M5: proc type nested in a parameter list is drift" 1 m_m5b \
  "+  > src/crisol/types.nim:anon_proc(cb):x = 1" \
  "+  > src/crisol/types.nim:zzOuter:cb = nil" '=2:  > ' '-  < ' '-  ~ '
case_ "R7-S2 M7: new object-field default is drift" 1 m_m7 \
  "+  > src/crisol/types.nim:ZzObj.trusted = true" '=1:  > ' '-  < ' '-  ~ ' \
  "+OPEN its reason with the bucket letter it was"
case_ "R7-S2 M7: changed object-field default is drift naming old and new" 1 m_m7v \
  '+  ~ src/crisol/process/types.nim:ChildSpec.claimOrphans: pinned `= true`, observed `= false`' \
  '=1:  ~ ' '-  < ' '-  > '
case_ "R8-S2: \`T* =\` / \`object\` field default is drift" 1 m_r8_split \
  "+  > src/crisol/types.nim:ZzSplit.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-S2: comment after \`=\`, \`object\` on the next line is drift" 1 m_r8_comment \
  "+  > src/crisol/types.nim:ZzCmt.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-S2: \`= ref\` / \`object of B\` field default is drift" 1 m_r8_refsplit \
  "+  > src/crisol/types.nim:ZzRefSplit.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-S2: \`=\` / \`ref object of B\` (pragma'd name) is drift" 1 m_r8_refof \
  "+  > src/crisol/types.nim:ZzRefOf.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-L4: field default whose value starts on the next line is drift" 1 m_r8_cont \
  "+  > src/crisol/types.nim:ZzCont.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-L4: one-line \`case\` / \`of\` variant field defaults are drift" 1 m_r8_variant \
  "+  > src/crisol/types.nim:ZzVar.kind = true" \
  "+  > src/crisol/types.nim:ZzVar.trusted = true" '=2:  > ' '-  < ' '-  ~ '
case_ "R8-L4: field pragma before the \`:\` is stripped from the name" 1 m_r8_pragma \
  "+  > src/crisol/types.nim:ZzPrag.trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-L4: \`= ref object\` / \`= ptr object\` field defaults are drift" 1 m_r8_refptr \
  "+  > src/crisol/types.nim:ZzRef.trusted = true" \
  "+  > src/crisol/types.nim:ZzPtr.trusted = true" '=2:  > ' '-  < ' '-  ~ '
case_ "R8-S4: bracket-form tuple field default is drift" 1 m_r8_tuple \
  "+  > src/crisol/types.nim:anon_tuple(ZzTup):trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-S4: block-form tuple field default is drift" 1 m_r8_tupleblk \
  "+  > src/crisol/types.nim:anon_tuple(ZzTupBlk):trusted = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-S4: \`do\` block defaulted parameter is drift" 1 m_r8_do \
  "+  > src/crisol/types.nim:anon_do(_):strict = true" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-D7: typed binding labels the lambda by the bound name" 1 m_r8_typed \
  "+  > src/crisol/types.nim:anon_proc(zzH):y = 2" '=1:  > ' '-  < ' '-  ~ '
case_ "R8-L5: a scanner path that forgets its count trips the backstop" 2 m_r8_backstop \
  "+CANNOT TELL — " "+routine keyword(s) seen but" "+(0 with a parameter list" \
  '-DEFAULTED-PARAMS OK'

case_ "R7-S2: an unresolvable routine keyword is cannot-tell" 2 m_unparsed \
  "+UNPARSED src/crisol/types.nim:" "+\`zzOdd\`: neither a parameter list nor a header terminator follows"

case_ "R7-L5: raw string ending in a backslash ends at its quote" 1 m_raw \
  '+  > src/crisol/types.nim:zzRaw:a = r"C:\"' \
  "+  > src/crisol/types.nim:zzRaw:b = 2" '=2:  > ' '-  < ' '-  ~ '

case_ "R7-L5: per-file reset keeps the next file's first-line record" 1 m_reset \
  "+  > ${RESET_B}:zzFirst:a = 3" '=1:  > ' '-  < ' '-  ~ '

if [ "$FAILS" -ne 0 ]; then
  echo "assert-defaulted-params.selftest.sh: $FAILS case(s) FAILED" >&2
  exit 1
fi
echo "assert-defaulted-params.selftest.sh: all cases passed"
