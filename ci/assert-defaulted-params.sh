#!/usr/bin/env bash
# ci/assert-defaulted-params.sh — round-5 review R5-15(b): the defaulted-
# soundness-parameter CENSUS, made structurally capable of finding a NEW one.
#
# Usage:
#   ci/assert-defaulted-params.sh            # gate: exact-set equality, exit 1 on drift
#   ci/assert-defaulted-params.sh --list     # print the observed set, one record per
#                                            # line, sorted (for re-pinning); exit 0
#   ci/assert-defaulted-params.sh --help
#
# CWD must be the repository root (the script only ever reads `src/`).
#
# ## WHY THIS SCRIPT EXISTS
#
# crisol has a named anti-pattern from the round-2 review, the DEFAULTED
# SOUNDNESS PARAMETER: a parameter that governs correctness (a cache key, a
# staleness comparison, a trust gate) while carrying a convenient default, so a
# call site that omits it silently selects the UNSOUND value and the omission is
# invisible in review because the short call simply looks short. Defect L1 was
# exactly that. The adopted remedy (R3-7, extended by R4-4) is: remove the
# default from the full-arity proc, add a `{.deprecated.}` companion carrying
# the old signature so call-site churn is zero, and let
# `--warningAsError:Deprecated:on` over `src/` hold the tree to zero omissions.
#
# The census METHOD, however, was `grep -rl "SOUNDNESS-PARAMETER WARNING" src/`
# (prescribed in `planner.nim`). That grep can only ever return sites somebody
# ALREADY annotated — it is structurally incapable of finding an unannotated
# one. Rounds 2, 3 and 4 each declared their population complete and round 5
# found a fourth (`artifactid.artifactKeyHash`'s `normalizedCcCmd`), which is
# the predictable outcome of a census whose instrument can only see what has
# already been censused.
#
# This script replaces that grep with an enumeration that starts from the
# LANGUAGE, not from the annotations: every `proc`/`func`/`template`/`method`/
# `converter`/`iterator`/`macro` signature under `src/` — INCLUDING multi-line
# ones, anonymous ones, `do` blocks and proc types — is parsed and every
# parameter carrying a default is emitted, and so is every object-field and
# tuple-field default. The
# resulting set is then compared against the pinned allowlist below by EXACT-SET
# EQUALITY, failing in BOTH directions.
#
# ## WHY EXACT-SET EQUALITY AND NOT A JUDGEMENT
#
# Direction-judging is NOT mechanisable. The question that separates a defect
# from a non-defect is "which way does omitting this default fail?":
#
#   * UNDER-invalidation (the defect class): omitting the default weakens a
#     cache key, a staleness comparison, or a trust gate, so a stale or foreign
#     artifact can be SERVED. crisol's L2 tier is shared across hosts, so this
#     is cross-host poisoning, not a local inefficiency. These must not have
#     defaults.
#   * OVER-invalidation / fail-safe (not a defect): omitting the default makes
#     the code decide "stale", "miss", "not trusted", "recompute" — the safe
#     direction, costing at most a cache miss. `depgraph.updateEntry`'s
#     `closureHash = ""` is the canonical example: the empty hash forces
#     `cdStale`, so forgetting it recompiles rather than mis-serves.
#   * Seam / injection defaults (not a defect): a `= realRun`, `= readFile`,
#     `= realFileReader` default names the REAL implementation; the default IS
#     production behavior and a test overrides it. Omitting it is the sound
#     choice by construction.
#   * Capacity / policy / telemetry knobs (not a defect): jobs, timeouts,
#     retries, buffer sizes, progress intervals, sink/prefetch no-ops. Wrong
#     value = wrong performance or wrong reporting, never a wrong artifact.
#   * Direction named, still not THIS defect (the narrowest margin): the default
#     does pick the more permissive or the narrower behavior, but the
#     consequence is a dropped policy opt-out, a shorter test list or a followed
#     symlink — not a stale or foreign artifact served under a weakened key.
#     These are bucket E below and each carries its own reason; they are the
#     entries to re-read first if one of them ever becomes identity material.
#
# A machine cannot tell those apart. A HUMAN classifies; this script's ONLY job
# is to answer "has any defaulted parameter APPEARED, VANISHED or CHANGED ITS
# DEFAULT since a human last classified the set". It deliberately does not judge
# severity, read intent, or infer a direction. Same shape as
# `ci/assert-subset-honesty.sh` (the local precedent): enumerate mechanically,
# pin by name AND default value, diff both ways.
#
# The allowlist below is organised into six blocks: the five buckets above (A
# seams, B fail-safe, C knobs, D documented soundness exception, E direction
# named), then block F, the object- and tuple-FIELD defaults, which is grouped
# by record class rather than by bucket: every F reason OPENS with the letter
# of the bucket (A-E) it was classified into, so the bucket's shared argument
# applies to it. Each block carries its shared argument; each record carries a
# one-line reason.
#
# One further marker may open a reason in place of a bucket letter:
#
#   PENDING COREY (<finding-id>):  the record is pinned but NOT classified. Its
#       direction is disputed or depends on a decision only the project owner
#       can make, and <finding-id> is the review finding that raised it. The
#       pin keeps the gate exact (a value change or a new sibling is still
#       drift) but the reason is a statement of the open question, not a
#       classification: it must not be cited as precedent for another record.
#       It is closed by moving the record into a bucket or removing the
#       default, never by rewording the marker away.
#
# Failing in BOTH directions is load-bearing:
#   * a NEW record (allowlist has no entry) => an unclassified defaulted
#     parameter reached `src/` — the R5-15 miss, now loud.
#   * a MISSING record (allowlist entry with no site) => a stale pin, i.e. the
#     allowlist is asserting a fact about code that no longer exists, which is
#     how an allowlist rots into decoration.
#   * a CHANGED value (same parameter, different default) => the reason on that
#     record is a claim about a value the code no longer has.
#
# Exit codes: 0 = observed census equals the pinned allowlist; 1 = drift (any of
# the three above); 2 = cannot tell (no src/, zero files or signatures, awk
# failure, a file the scanner could not balance, or a routine keyword it could
# not resolve to a known header shape -- see the scanner contract).
#
# ## RECORD FORMAT
#
# Three record classes, one allowlist:
#
#   <path-under-src>:<routine-name>:<parameter-name> = <default-value>
#   <path-under-src>:anon_<keyword>(<binder>):<parameter-name> = <default-value>
#   <path-under-src>:<Type>.<field> = <default-value>
#
# The second is a parameter of an ANONYMOUS routine -- a lambda
# (`let cb = proc (x = 1) = ...`), a proc TYPE (`F = proc (x = 1)
# {.nimcall.}`, or `cb: proc (x = 1)` nested in another parameter list) or a
# `do` block (`run do (x: int, strict = true): ...`, keyword `do`) -- or a
# field of a TUPLE type (`T = tuple[a: int = 1]`, or the block form `T = tuple`
# with one field per indented line; keyword `tuple`, since `default(T)` applies
# a tuple-field default exactly as an omitting call applies a parameter one --
# round-8 finding S4). It
# has no name, so its identity is its BINDER: the identifier directly before
# the `=` / `:` that precedes the keyword on its own line (`cb`, `F`), or `_`
# when there is none (a lambda passed straight as an argument, which is every
# `do` block). For a TYPED binding (`let h: Handler = proc (y = 2)`) the binder
# is the bound variable or field `h`, never the annotation's type `Handler`
# (round-8 finding D7). Chosen over a
# line number (`<anon@LINE>` rots on every unrelated edit above it, the exact
# citation rot the no-line-numbers rule below exists to avoid) and over the
# enclosing routine (which a line scanner cannot determine reliably); the
# binder is what a reader searches for, and moves only when the declaration
# itself is renamed. Records still compare as a multiset, so two same-binder
# anonymous routines in one file are both counted.
#
# The third is a Nim 2 OBJECT-FIELD default (`field*: T = value` in an
# `object` body): an object-construction literal that omits the field gets the
# default exactly as a short call gets a parameter default, so it is the same
# defect class and is pinned the same way, value included (round-7 finding
# S2, shape M7). `var`/`let`/`const` initialisers are NOT defaults -- nothing
# can "omit" them -- and are not recorded.
#
# `do` blocks are recorded although their defaults are, today, unreachable:
# `nim r` (2.2.10, 2026-09-25) shows the lambda's TYPE drops the default
# (`proc (x: int, strict: bool)`), so a proc-typed parameter receiving it
# never applies it. A template or macro taking the block `untyped` can splice
# it anywhere, however, and recording costs one line per site. Such a record
# is classified like any other; its reason may cite the unreachability, which
# a reviewer can then check at that one site instead of trusting a blanket
# exemption here. (src/ held no `do` block when this was decided.)
#
# The DEFAULT VALUE is part of the record (round-6 finding D2). Every reason in
# the allowlist is a claim about the value -- "0o600 is the RESTRICTIVE mode",
# "hlIsolated, the STRICTEST hermeticity level", "false = continue-on-failure"
# -- so a record keyed on the parameter NAME alone stayed green when the value
# the classification was ABOUT changed (`0o600` -> `0o666`, `hlIsolated` ->
# `hlNone`). Now a changed value is drift: the gate exits 1 and names the
# pinned and the observed value side by side. The value is the source text
# after the separator `=`, with whitespace outside literals (line breaks of a
# multi-line default included) collapsed to single spaces; literal contents are
# kept exactly.
#
# Deliberately NO line numbers: citations in this repo rot within a single
# review round. Records are emitted ONCE PER OCCURRENCE and compared as a
# MULTISET, not a set — several overloads of one routine in one file that each
# default the same parameter name get their own line, so a NEW overload that adds
# another defaulted parameter of an existing name still trips the gate instead of
# collapsing into an existing record. `sort | uniq -d` over `--list` output names
# the repeats; today they are `paths.classify`'s `expandCandidate` (the
# `string` and `ReportedPath` overloads) and `pipeline.buildRunPlan`'s nine (its
# own full-arity form plus its R4-4 `{.deprecated.}` companion). That is why some records below
# appear twice; the repeat is the point, not a copy-paste slip.
#
# ## WHAT TO DO WHEN THIS GATE FAILS
#
# The failure message spells it out; the short version is: classify the
# parameter's DIRECTION (the buckets above), then either
#   (a) it is under-invalidating => remove the default, add a `{.deprecated.}`
#       companion overload with the old signature, and annotate the full-arity
#       proc with a `SOUNDNESS-PARAMETER WARNING` block (see
#       `pipeline.buildRunPlan` for the canonical shape); or
#   (b) it fails safe => add the record to ALLOWLIST below with a one-line
#       reason naming WHY omitting it is safe.
# Never add a record without a reason. The reason is the classification; the
# record without it is the grep this script exists to replace.

# ## PORTABILITY (empirically pinned against the dev container, 2026-09-24)
#
# This must run BOTH under `./dev` (podman, ghcr.io/coreyleavitt/nim:2.2.10) and
# in CI (docker, GitHub-hosted). The dev image is BusyBox-based and is missing
# more than the documented `find`:
#
#   find   NOT on PATH   (already known; hence bash globstar — see below)
#   xargs  NOT on PATH   (so files are passed to awk from a bash array)
#   diff   NOT on PATH   (so the two-way report is built with `comm`, which IS
#                         present, and which handles duplicate lines correctly
#                         for the multiset comparison this gate needs)
#   awk    = BusyBox awk (user functions, gsub, substr, /dev/stderr all OK)
#
# `LC_ALL=C` is set below and is NOT cosmetic: the gate compares two SORTED
# multiline strings for equality, so a collation difference between the
# environment that pinned the allowlist and the one checking it would fail the
# gate for no reason at all.
export LC_ALL=C

set -uo pipefail

MODE="gate"
case "${1:-}" in
  --list) MODE="list" ;;
  --help|-h)
    # Print this file's header block, whatever its length: stop at the first
    # line that is not a comment. A fixed `sed -n '2,120p'` range silently
    # truncates the moment the header grows, which is the same rot-by-hand
    # failure this whole script exists to remove.
    awk 'NR == 1 { next } /^[^#]/ { exit } { sub(/^# ?/, ""); print }' "$0"
    exit 0 ;;
  "") ;;
  *)
    echo "assert-defaulted-params.sh: unknown argument '$1' (expected --list or --help)" >&2
    exit 2 ;;
esac

if [ ! -d src ]; then
  echo "assert-defaulted-params.sh: no src/ directory — run from the repository root" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# File enumeration. `find` is NOT on PATH in the dev container, so this uses
# bash `globstar`.
#
# NOT `git ls-files`, which was the first attempt and was WRONG (caught by
# running this script in the dev container while building it, 2026-09-24):
# `git ls-files` lists only TRACKED files, and on the tree this gate was pinned
# against it silently skipped two brand-new, still-untracked modules
# (`src/crisol/ccidentity.nim`, `src/crisol/toolrun.nim`) carrying 11 defaulted
# parameters between them — 76 files enumerated instead of 78. A NEW module is
# the single most likely place for a NEW defaulted parameter to arrive, so an
# enumerator that cannot see one before `git add` is an enumerator that
# under-reports exactly when it matters. Globstar enumerates the WORKING TREE,
# which is what the compiler reads.
#
# `git ls-files` survives only as a fallback for a shell too old for globstar
# (bash < 4). If that fallback ever fires, it is strictly weaker; the warning
# below says so out loud rather than quietly returning a smaller census.
# --------------------------------------------------------------------------
list_nim_files() {
  if shopt -s globstar 2>/dev/null; then
    shopt -s nullglob
    printf '%s\n' src/**/*.nim
  elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    echo "assert-defaulted-params.sh: WARNING — this shell has no globstar, so the" >&2
    echo "  census falls back to 'git ls-files', which CANNOT see untracked .nim" >&2
    echo "  files under src/. Run this under bash 4+ before trusting a pass." >&2
    git ls-files 'src/*.nim' 'src/**/*.nim'
  else
    echo "assert-defaulted-params.sh: no globstar and no git — cannot enumerate src/" >&2
    return 1
  fi
}

NIMFILES=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  NIMFILES+=("$_f")
done < <(list_nim_files | sort)

if [ ${#NIMFILES[@]} -eq 0 ]; then
  echo "assert-defaulted-params.sh: enumerated ZERO .nim files under src/ — the" >&2
  echo "  enumerator is broken or the tree is empty; refusing to report a clean" >&2
  echo "  census over nothing (that is the silent under-report this gate exists" >&2
  echo "  to prevent)." >&2
  exit 2
fi

# --------------------------------------------------------------------------
# The enumerator.
#
# A hand-rolled scanner rather than a regex, because the shape that silently
# under-reports is the MULTI-LINE signature and this repo is full of them
# (`runner.execute` spans ~70 lines with `##` doc comments BETWEEN parameters;
# `artifactid.ccIncludeClosure` spans 4; `paths.classify` spans 3). A per-line
# regex sees only the line a default happens to sit on and misses every
# parameter whose `=` landed on a continuation line, which is exactly the
# failure mode that would make this gate quietly useless.
#
# Scanner contract:
#   * A LEXER runs first, over every line of every file, and produces two
#     equal-length views of the line: REAL (comments removed, literals intact)
#     and MASK (the same, but every character of every string / char literal
#     replaced by `x`). ALL structural decisions -- the opener test, bracket
#     depth, `;`/`,` splitting, the `:` and `=` separators -- are made on MASK;
#     the routine name, parameter name and default VALUE are sliced out of REAL
#     at the same indices. So a `(`, `)`, `,`, `;`, `=` or `#` inside a literal
#     can never move the depth walk. (Before this, one `(` inside a string
#     default -- `sep = "("` -- left the depth walk permanently open, which hid
#     every later defaulted parameter in that file AND in every later file,
#     with no error: round-6 finding S2.)
#     The lexer knows: `"..."` with `\` escapes; RAW strings `r"..."` and every
#     generalized raw literal `ident"..."` (no `\` escapes, `""` is a quote);
#     `"""..."""` triple strings, which may span lines; char literals `'c'`,
#     `'\n'`, `'\x27'`; a `'` directly after an identifier/digit character is a
#     numeric-literal SUFFIX (`0o600'u32`), not a char literal; `#` line
#     comments and `##` doc comments; `#[ ... ]#` block comments (NESTED, may
#     span lines) and `##[ ... ]##` doc block comments.
#   * Lexer and scanner state are reset at the first line of EVERY file, so
#     nothing -- not an unclosed signature, not an unterminated triple string
#     or block comment -- can leak from one file into the next. Each file is
#     lexed into a per-file line store and scanned from that store alone
#     (NL bounds the cursor), BEFORE the next file's state is cleared.
#   * A file that ENDS with a signature still open (a parameter list, generic
#     section or term-rewriting pattern whose brackets never return to 0), or
#     inside a triple string or block comment, is reported as UNBALANCED /
#     UNTERMINATED with its file:line and the gate exits 2 (cannot tell). The
#     census of that file is not trustworthy, so it must not be reported as a
#     pass OR as a drift.
#   * A routine keyword is `proc|func|template|method|converter|iterator|macro`
#     or `do` (a `do` block is an anonymous routine: `do (x = 1):` has a
#     parameter list, `do:` has none) as a WHOLE WORD of code (on MASK, so never inside a literal or comment)
#     ANYWHERE on a line -- not only at its start. Round-6 anchored the opener
#     at `^[[:space:]]*` and required a name on the same line, which silently
#     dropped (round-7 finding S2): a routine after a statement on the same
#     line (`discard 0; proc f*(...)`, M6), every anonymous routine and proc
#     type (M4 / M5), a proc type nested in another parameter list, a
#     non-ASCII name (M14), a generic section spanning lines (M2) and a name
#     whose `[T](...)` began on the next line (M16). A keyword preceded by an
#     identifier character, a backtick or `.`, or followed by an identifier
#     character (`macros`, `procCall`), is not a keyword.
#   * From the keyword the scanner walks a CURSOR across line breaks: name
#     (identifier, non-ASCII included, or a backtick-quoted operator such as
#     `==`), optional `*`, optional term-rewriting pattern `{...}`, optional
#     generic section `[...]` (balanced, may span lines), then the parameter
#     list `(...)` (balanced, may span lines). No name = ANONYMOUS (a lambda or
#     a proc type), recorded under its binder -- see RECORD FORMAT.
#   * Every keyword resolves to EXACTLY ONE outcome: a parameter list read
#     (with-parameter-lists), no parameter list followed by a token that can
#     legally end a header (`:` `=` `{` `;` `)` `]` `,` or end of file:
#     `template t: T`, `proc p = ...`, `proc {.nimcall.}`, a bare `proc`
#     typeclass -- no-parameter-list), UNBALANCED, or UNPARSED (anything else,
#     e.g. an identifier where the header should end). UNPARSED is exit 2
#     naming file:line, and the gate also asserts
#     `signatures == with-parameter-lists + no-parameter-list` (exit 2 on
#     mismatch): round 6 COUNTED both of its numbers and never compared them.
#     Every path through `header` counts exactly once, so on a correct scanner
#     the equation holds by construction and only a SCANNER BUG (a path that
#     forgets its count) can break it: it is defense in depth, and the
#     self-test makes it observable by deleting one count in a copy of this
#     script and requiring the backstop's own message (round-8 finding L5).
#   * Within a parameter list, `(`/`[`/`{` all nest, so a `;` inside
#     `tuple[content: string; ok: bool]` or a `,` inside `@[1, 2]` /
#     `NilSink[TelemetryEvent]()` is never read as a parameter separator. A
#     proc type NESTED in a parameter (`cb: proc (x = 1) = nil`) yields both
#     the outer record (`cb = nil`) and, as its own keyword, the inner one.
#   * Tuple-field defaults, bracket form: a whole-word `tuple` followed
#     (across line breaks) by `[` reads that balanced group exactly as a
#     parameter list, recorded as `anon_tuple(<binder>):<field>`.
#   * Object-field defaults: a whole-word `object` (or a `tuple` that ENDS its
#     line, the block form) is a type body when walking BACK from it -- across
#     whitespace, line breaks and comments, over at most one `ref` / `ptr` word
#     -- reaches a separator `=`. So `T* = object`, `T* =` / `object`,
#     `T* = # c` / `object`, `T* = ref` / `object of B` and
#     `T* =` / `ref object of B` are all recognised (round-8 finding S2: the
#     round-7 regex demanded `= [ref|ptr] object` on ONE line and missed the
#     other four with the gate green). The type name is read from the line
#     holding that `=`, and the body is every non-blank line after the keyword
#     indented deeper than that line. Each field
#     line (with `case` stripped; `of`/`else`/`elif`/`when` heads cut at their
#     `:`) absorbs its continuation lines -- while a bracket is open, and every
#     following line indented deeper than itself -- so a default starting on
#     the next line is still read. A top-level `=` makes each name before the
#     `:` (`a, b*: int = 0`, field pragmas dropped) a `<Type>.<field>` record
#     (`anon_tuple(<Type>):<field>` for a block-form tuple).
#   * Parameters split on `;` or `,` at depth 0. A fragment carrying neither a
#     top-level `:` nor a top-level `=` is a BARE NAME sharing the next
#     fragment's type and default (`proc f(a, b: int = 5)` defaults BOTH), so it
#     is held pending and emitted with that group.
#   * The separator `=` is the first `=` at depth 0 that is not part of `==`,
#     `<=`, `>=`, `!=` or `=>`. The default VALUE is everything after it, with
#     every whitespace run OUTSIDE literals (including the line breaks of a
#     multi-line default) collapsed to one space; literal contents are kept
#     byte-for-byte.
#
# Portability: POSIX awk only -- no gawk extensions, no regex interval
# expressions (`{2,}`), no `\x` escapes in awk strings (the single quote the
# lexer needs is passed in with `-v SQ="'"`); the one escape used is the POSIX
# octal `"\200"` (isident's non-ASCII test). Verified under BusyBox awk (dev
# image), mawk 1.3.4 (Debian/Ubuntu default, i.e. CI) and gawk 5.3, both the
# gate and its self-test, 2026-09-25.
# --------------------------------------------------------------------------
LEXER='
# An identifier character. Every byte >= 0x80 counts: Nim identifiers may hold
# any non-ASCII letter, and under LC_ALL=C each byte of its UTF-8 encoding
# compares >= "\200" (octal escape: POSIX; checked under BusyBox, mawk, gawk).
# Without this a routine NAMED `ñzz` was counted as a signature and then
# dropped with its parameters unread (round-7 finding S2, shape M14).
function isident(ch) { return (ch != "" && (ch >= "\200" || index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_", ch) > 0)) }
function isws(ch)    { return (ch == " " || ch == "\t" || ch == "\r" || ch == "\n") }
function xs(k,    o) { o = ""; while (k-- > 0) o = o "x"; return o }

# lex(s): sets LREAL / LMASK for one physical line. Cross-line state: LX is ""
# (code), "s3" (inside a triple-quoted string) or "bc" (inside a block comment,
# nesting depth LBD, LDOC = opened as a ##[ doc block).
function lex(s,    i, n, c, raw, j, k) {
  LREAL = ""; LMASK = ""; i = 1; n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (LX == "bc") {
      if (c == "]" && substr(s, i + 1, 1) == "#") {
        i += 2; LBD--
        if (LBD == 0) {
          if (LDOC && substr(s, i, 1) == "#") i++
          LX = ""; LREAL = LREAL " "; LMASK = LMASK " "
        }
        continue
      }
      if (c == "#" && substr(s, i + 1, 1) == "[") { i += 2; LBD++; continue }
      i++; continue
    }
    if (LX == "s3") {
      if (substr(s, i, 3) == "\"\"\"") {
        j = i; while (substr(s, j, 1) == "\"") j++
        k = j - i; LREAL = LREAL substr(s, i, k); LMASK = LMASK xs(k); i = j
        LX = ""; continue
      }
      LREAL = LREAL c; LMASK = LMASK "x"; i++; continue
    }
    if (c == "#") {
      if (substr(s, i + 1, 1) == "[") { LX = "bc"; LBD = 1; LDOC = 0; i += 2; continue }
      if (substr(s, i + 1, 2) == "#[") { LX = "bc"; LBD = 1; LDOC = 1; i += 3; continue }
      break                                     # line / doc comment: rest of line
    }
    if (c == "\"") {
      raw = isident(substr(s, i - 1, 1))        # r"..." / ident"..." are raw
      if (substr(s, i, 3) == "\"\"\"") {
        LREAL = LREAL "\"\"\""; LMASK = LMASK "xxx"; i += 3; LX = "s3"; continue
      }
      LREAL = LREAL c; LMASK = LMASK "x"; i++
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && !raw) { LREAL = LREAL substr(s, i, 2); LMASK = LMASK xs(length(substr(s, i, 2))); i += 2; continue }
        if (c == "\"") {
          if (raw && substr(s, i + 1, 1) == "\"") { LREAL = LREAL "\"\""; LMASK = LMASK "xx"; i += 2; continue }
          LREAL = LREAL c; LMASK = LMASK "x"; i++; break
        }
        LREAL = LREAL c; LMASK = LMASK "x"; i++
      }
      continue
    }
    if (c == SQ && !isident(substr(s, i - 1, 1))) {
      # char literal: 'c' / '\c' / '\xHH' / '\ddd' -- find its close within a
      # few characters; a lone quote with no close is left as code.
      j = i + 1
      while (j <= n && j - i <= 6 && substr(s, j, 1) != SQ) j += (substr(s, j, 1) == "\\") ? 2 : 1
      if (j <= n && substr(s, j, 1) == SQ && j > i + 1) {
        k = j - i + 1; LREAL = LREAL substr(s, i, k); LMASK = LMASK xs(k); i = j + 1; continue
      }
    }
    LREAL = LREAL c; LMASK = LMASK c; i++
  }
}

# Whitespace-normalised REAL text: whitespace runs OUTSIDE literals (per MASK)
# collapse to one space; leading/trailing whitespace dropped.
function norm(r, m,    i, n, o, pend) {
  o = ""; pend = 0; n = length(m)
  for (i = 1; i <= n; i++) {
    if (isws(substr(m, i, 1))) { pend = 1; continue }
    if (pend && o != "") o = o " "
    pend = 0; o = o substr(r, i, 1)
  }
  return o
}
'

ENUMERATOR='
# Whitespace-free form, for a parameter NAME (an identifier can never contain
# any). The accumulator joins continuation lines with a space, so a parameter
# whose name and `:` landed on different lines arrives here as "name ".
function squash(s) { gsub(/[ \t\r\n]+/, "", s); return s }

# Number of leading whitespace characters of m.
function lead_ws(m,    i, n) { n = length(m); for (i = 1; i <= n && isws(substr(m, i, 1)); i++) ; return i - 1 }

# Net bracket depth change of a (masked) line.
function depth(m,    i, n, c, d) {
  n = length(m); d = 0
  for (i = 1; i <= n; i++) {
    c = substr(m, i, 1)
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
  }
  return d
}

# Index of the first separator "=" at depth 0 in a (masked) fragment, or 0.
function sep_eq(m,    i, n, c, d, p, nx) {
  n = length(m); d = 0
  for (i = 1; i <= n; i++) {
    c = substr(m, i, 1)
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
    else if (c == "=" && d == 0) {
      p  = (i > 1) ? substr(m, i - 1, 1) : ""
      nx = (i < n) ? substr(m, i + 1, 1) : ""
      if (nx == "=" || nx == ">") continue
      if (p == "=" || p == "<" || p == ">" || p == "!") continue
      return i
    }
  }
  return 0
}

# Index of the first ":" at depth 0 in a (masked) fragment, or 0.
function sep_colon(m,    i, n, c, d) {
  n = length(m); d = 0
  for (i = 1; i <= n; i++) {
    c = substr(m, i, 1)
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
    else if (c == ":" && d == 0) return i
  }
  return 0
}

# Leading parameter name of a fragment (REAL text before the first top-level
# ":" or "=", whichever comes first; positions found on MASK).
function lead_name(r, m,    ci, ei, cut) {
  ci = sep_colon(m); ei = sep_eq(m)
  cut = 0
  if (ci > 0 && ei > 0) cut = (ci < ei) ? ci : ei
  else if (ci > 0)      cut = ci
  else if (ei > 0)      cut = ei
  if (cut > 0) r = substr(r, 1, cut - 1)
  return squash(r)
}

function emit_group(names, cnt, val,    i) {
  for (i = 1; i <= cnt; i++) print curfile ":" routine ":" names[i] " = " val
}

# Split a complete parameter list (REAL p, MASK mp) and emit every defaulted
# parameter with its normalised default value.
function scan_params(p, mp,    i, n, c, d, st, fr, fm, nf, k, names, cnt, nm, ei) {
  n = length(mp); d = 0; nf = 0; st = 1
  for (i = 1; i <= n; i++) {
    c = substr(mp, i, 1)
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
    else if (d == 0 && (c == ";" || c == ",")) {
      nf++; fr[nf] = substr(p, st, i - st); fm[nf] = substr(mp, st, i - st); st = i + 1
    }
  }
  nf++; fr[nf] = substr(p, st); fm[nf] = substr(mp, st)

  cnt = 0
  for (k = 1; k <= nf; k++) {
    if (norm(fr[k], fm[k]) == "") continue
    ei = sep_eq(fm[k])
    if (sep_colon(fm[k]) == 0 && ei == 0) {       # bare name, group continues
      names[++cnt] = squash(fr[k])
      continue
    }
    nm = lead_name(fr[k], fm[k])
    if (nm != "") names[++cnt] = nm
    if (ei > 0) emit_group(names, cnt, norm(substr(fr[k], ei + 1), substr(fm[k], ei + 1)))
    cnt = 0
  }
}

# ---- the per-file cursor. The whole file is held as LR[1..NL] (REAL) and
# ---- LM[1..NL] (MASK); the cursor (CK = line, CC = column) walks it ACROSS
# ---- line breaks, which it reports as "\n". Deliberately a line array and not
# ---- one joined string: BusyBox substr() is O(length) per call, so walking a
# ---- 180 KB joined buffer a character at a time would be quadratic.
function cch()  { if (CK > NL) return ""; if (CC > length(LM[CK])) return "\n"; return substr(LM[CK], CC, 1) }
function cchr() { if (CK > NL) return ""; if (CC > length(LR[CK])) return "\n"; return substr(LR[CK], CC, 1) }
function cadv() { if (CC > length(LM[CK])) { CK++; CC = 1 } else CC++ }
function cskip(    c) { while ((c = cch()) != "" && isws(c)) cadv() }

# From an opening bracket under the cursor, collect the balanced group into
# GR (REAL) / GM (MASK), line breaks joined as one space. 1 = closed, 0 = EOF.
function cgroup(    c, d) {
  GR = ""; GM = ""; d = 0
  while ((c = cch()) != "") {
    if (c == "\n") { GR = GR " "; GM = GM " "; cadv(); continue }
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
    GR = GR cchr(); GM = GM c; cadv()
    if (d == 0) return 1
  }
  return 0
}

function unbalanced(k, what) {
  unbal++
  print "UNBALANCED " curfile ":" k ": the " what " of `" routine "` never closes before end of file" > "/dev/stderr"
}
function unparsed(k, what) {
  unpar++
  print "UNPARSED " curfile ":" k ": `" routine "`: " what > "/dev/stderr"
}

# The identity of an ANONYMOUS routine / proc type is the name it is BOUND to
# on its own line: the identifier directly before the `=` or `:` that precedes
# the keyword (`F* = proc (...)` -> F, `let cb = proc (...)` -> cb,
# `onDone: proc (...)` -> onDone, `T*[X] = proc` -> T). "_" when there is none
# (a lambda passed straight as an argument).
#
# A TYPED binding (`let h: Handler = proc (...)`, `cb*: Handler = proc`) binds
# the VARIABLE / FIELD `h`, not the type `Handler`: after the identifier before
# `=`, a `:` one step further back marks that identifier as a type annotation,
# and the binder is the name before the `:` (round-8 finding D7 -- labelling by
# type name moved the record whenever an unrelated type was renamed, and gave
# every lambda bound to one type the same label).
function binder(k, c,    m, s, n, ch, nm, t) {
  m = substr(LM[k], 1, c - 1); s = substr(LR[k], 1, c - 1); n = length(m)
  while (n > 0 && isws(substr(m, n, 1))) n--
  ch = substr(m, n, 1)
  if (ch != "=" && ch != ":") return "_"
  if (n > 1 && index("=<>!:", substr(m, n - 1, 1)) > 0) return "_"
  nm = ident_back(m, s, n - 1)
  if (nm == "") return "_"
  if (ch == "=") {
    n = BN
    while (n > 0 && isws(substr(m, n, 1))) n--
    if (n > 0 && substr(m, n, 1) == ":" && (n == 1 || substr(m, n - 1, 1) != ":")) {
      t = ident_back(m, s, n - 1)
      if (t != "") return t
    }
  }
  return nm
}

# Walking BACK from index n of MASK m (REAL s): whitespace, an optional
# generic section / pragma group, an optional export `*`, then an identifier,
# which is returned ("" when there is none). BN = the index just before it.
function ident_back(m, s, n,    ch, d, e) {
  while (n > 0 && isws(substr(m, n, 1))) n--
  ch = substr(m, n, 1)
  if (ch == "]" || ch == "}") {                   # generic section / pragma
    d = 0
    for (; n > 0; n--) {
      ch = substr(m, n, 1)
      if (ch == "]" || ch == "}" || ch == ")") d++
      else if (ch == "[" || ch == "{" || ch == "(") { d--; if (d == 0) { n--; break } }
    }
    while (n > 0 && isws(substr(m, n, 1))) n--
  }
  if (substr(m, n, 1) == "*") n--
  e = n
  while (n > 0 && isident(substr(m, n, 1))) n--
  BN = n
  if (n == e) return ""
  return substr(s, n + 1, e - n)
}

# One routine keyword at line k, column c. Every path through here counts the
# keyword into exactly ONE of withparams / noparams / unbal / unpar, which is
# what makes `signatures == with-parameter-lists + no-parameter-list` an
# honest self-check (the gate exits 2 when it does not hold).
function header(k, c, kw,    ch, j, name) {
  sigs++
  CK = k; CC = c + length(kw)
  routine = kw
  cskip(); ch = cch()
  if (ch == "`") {                                # operator name in backticks
    j = index(substr(LM[CK], CC + 1), "`")
    if (j == 0) { unparsed(k, "backtick name does not close on its line"); return }
    routine = substr(LR[CK], CC + 1, j - 1); CC += j + 1
    name = 1
  } else if (isident(ch)) {                       # plain name, non-ASCII included
    routine = ""
    while (isident(ch = cch())) { routine = routine cchr(); cadv() }
    name = 1
  } else {                                        # anonymous: lambda or proc type
    routine = "anon_" kw "(" binder(k, c) ")"
    anons++
    name = 0
  }
  if (name) {
    cskip(); if (cch() == "*") cadv()
    cskip()
    if (cch() == "{" && substr(LM[CK], CC + 1, 1) != ".") {   # term-rewriting pattern
      if (!cgroup()) { unbalanced(k, "pattern"); return }
      cskip()
    }
    if (cch() == "[") {                           # generic parameter section
      if (!cgroup()) { unbalanced(k, "generic parameter section"); return }
      cskip()
    }
  }
  ch = cch()
  if (ch == "(") {
    if (!cgroup()) { unbalanced(k, "parameter list"); return }
    withparams++
    if (length(GM) > 2) scan_params(substr(GR, 2, length(GR) - 2), substr(GM, 2, length(GM) - 2))
    return
  }
  # No parameter list. Accepted only where a routine header can legally end
  # without one (`template t: T`, `proc p = ...`, `proc {.nimcall.}`, a bare
  # `proc` typeclass before `]` / `,` / `;` / `)`, or end of file). Anything
  # else is a shape this scanner does not model: cannot tell.
  if (ch == "" || index(":={;)],", ch) > 0) { noparams++; return }
  if (ch == "\n") ch = "end of line"
  unparsed(k, "neither a parameter list nor a header terminator follows (next: " ch ")")
}

# Every routine keyword in line k, as a WHOLE WORD of code (the MASK has no
# literals or comments), anywhere on the line: after `;`, inside another
# signature, as a lambda or as a proc type. `macros`, `procCall`, a backticked
# `func` or a `.proc` field are not keywords.
function find_keywords(k,    m, off, p, kw, pre, post) {
  m = LM[k]; off = 0
  while (match(substr(m, off + 1), /(proc|func|template|method|converter|iterator|macro|do)/)) {
    p = off + RSTART; kw = substr(m, p, RLENGTH); off = p + RLENGTH - 1
    pre = (p > 1) ? substr(m, p - 1, 1) : ""
    post = substr(m, p + RLENGTH, 1)
    if (isident(pre) || pre == "`" || pre == "." || isident(post)) continue
    header(k, p, kw)
  }
}

# Bracket-form tuple types, `tuple[a: T = v; ...]`: a field default there is
# applied by `default(T)` exactly as an object-field default is by an omitting
# construction literal (round-8 finding S4), so every one is recorded, in the
# anonymous class under its binder: `anon_tuple(<binder>):<field>`. A tuple is
# structural in Nim -- the name it is bound to is an alias, not its identity.
function find_tuples(k,    m, off, p, pre, post) {
  m = LM[k]; off = 0
  while (match(substr(m, off + 1), /tuple/)) {
    p = off + RSTART; off = p + RLENGTH - 1
    pre = (p > 1) ? substr(m, p - 1, 1) : ""
    post = substr(m, p + RLENGTH, 1)
    if (isident(pre) || pre == "`" || pre == "." || isident(post)) continue
    CK = k; CC = p + 5
    cskip()
    if (cch() != "[") continue
    routine = "anon_tuple(" binder(k, p) ")"
    if (!cgroup()) { unbalanced(k, "field list"); continue }
    tuples++
    if (length(GM) > 2) scan_params(substr(GR, 2, length(GR) - 2), substr(GM, 2, length(GM) - 2))
  }
}

# ---- object-field defaults (Nim 2 `field*: T = value`). An object body is
# ---- every non-blank line after a `... = [ref|ptr] object` line that is
# ---- indented deeper than it.
function field_line(t, tm, pfx,    i, ei, ci, head, hm, val, n, fr, fm, st, d, c, nm, pg) {
  i = lead_ws(tm); t = substr(t, i + 1); tm = substr(tm, i + 1)
  if (match(tm, /^(of|else|elif|when)([^A-Za-z0-9_]|$)/)) {
    ci = sep_colon(tm); if (ci == 0) return
    t = substr(t, ci + 1); tm = substr(tm, ci + 1)
  } else if (match(tm, /^case[ \t]/)) {
    t = substr(t, 6); tm = substr(tm, 6)
  }
  ei = sep_eq(tm); if (ei == 0) return
  head = substr(t, 1, ei - 1); hm = substr(tm, 1, ei - 1)
  ci = sep_colon(hm); if (ci > 0) { head = substr(head, 1, ci - 1); hm = substr(hm, 1, ci - 1) }
  val = norm(substr(t, ei + 1), substr(tm, ei + 1))
  n = length(hm); d = 0; st = 1
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? substr(hm, i, 1) : ","
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") d--
    else if (c == "," && d == 0) {
      fr = substr(head, st, i - st); fm = substr(hm, st, i - st); st = i + 1
      pg = index(fm, "{"); if (pg > 0) fr = substr(fr, 1, pg - 1)     # field pragma
      nm = squash(fr); sub(/\*$/, "", nm)
      if (nm != "") { fields++; print curfile ":" pfx nm " = " val }
    }
  }
}

# ---- a BACKWARD cursor (BK = line, BC = column, pointing AT a character) over
# ---- the same line store, reporting a line boundary as "\n". The object
# ---- recognizer walks it from the `object` / `tuple` keyword back to the `=`
# ---- that makes it a type definition, across line breaks and comments.
function bch() { if (BK < 1) return ""; if (BC < 1) return "\n"; return substr(LM[BK], BC, 1) }
function bback() { if (BC < 1) { BK--; if (BK >= 1) BC = length(LM[BK]) } else BC-- }
function bskip(    c) { while ((c = bch()) != "" && isws(c)) bback() }
function bword(    w) { w = ""; while (BK >= 1 && BC >= 1 && isident(substr(LM[BK], BC, 1))) { w = substr(LM[BK], BC, 1) w; BC-- }; return w }

# Is the whole-word `object` / `tuple` at line k, column p the body keyword of
# a type definition? Walk back over whitespace, line breaks and comments (the
# MASK has none), an optional `ref` / `ptr` word, and more whitespace, to a
# separator `=`. On success DK / DC hold that `=`. Round-8 finding S2: the
# round-7 recognizer matched `= [ref|ptr] object` on ONE line only, so
# `T* =` / `object`, `T* = # c` / `object` and `T* = ref` / `object of B` --
# all valid Nim whose field defaults ARE applied -- hid with the gate green.
function typedef_eq(k, p,    sk, sc, w) {
  BK = k; BC = p - 1
  bskip()
  sk = BK; sc = BC
  w = bword()
  if (w != "ref" && w != "ptr") { BK = sk; BC = sc }
  bskip()
  if (bch() != "=") return 0
  if (BC > 1 && index("=<>!:", substr(LM[BK], BC - 1, 1)) > 0) return 0
  DK = BK; DC = BC
  return 1
}

# Object-field defaults, and the block-form tuple (`T = tuple` then one field
# per indented line). The body is every following non-blank line indented
# deeper than the line holding the `=` (the line naming the type).
function scan_objects(    k, k2, m, off, p, kw, pre, post, ind, tname, pfx, t, tm, d, fi, isfield) {
  for (k = 1; k <= NL; k++) {
    m = LM[k]; off = 0; p = 0
    while (match(substr(m, off + 1), /(object|tuple)/)) {
      p = off + RSTART; kw = substr(m, p, RLENGTH); off = p + RLENGTH - 1
      pre = (p > 1) ? substr(m, p - 1, 1) : ""
      post = substr(m, p + RLENGTH, 1)
      if (isident(pre) || pre == "`" || pre == "." || isident(post)) { p = 0; continue }
      # `tuple[...]` is the bracket form (find_tuples); only a `tuple` that ENDS
      # its line opens a block body here.
      if (kw == "tuple" && norm(substr(LR[k], p + 5), substr(m, p + 5)) != "") { p = 0; continue }
      if (typedef_eq(k, p)) break
      p = 0
    }
    if (p == 0) continue
    if (kw == "object") objects++; else tupleblocks++
    tname = substr(LR[DK], 1, DC - 1)
    sub(/^[ \t]*/, "", tname); sub(/^type[ \t]+/, "", tname)
    if (match(tname, /^[^ \t*[{=]+/)) tname = substr(tname, 1, RLENGTH); else tname = "_"
    pfx = (kw == "object") ? tname "." : "anon_tuple(" tname "):"
    ind = lead_ws(LM[DK])
    k2 = k + 1
    while (k2 <= NL) {
      if (norm(LR[k2], LM[k2]) == "") { k2++; continue }        # blank / comment-only
      if (lead_ws(LM[k2]) <= ind) break
      # A logical field line absorbs its continuation lines: while a bracket is
      # open, and (for a plain field line) every following line indented deeper
      # than itself, so a default that starts on the NEXT line is still seen.
      t = LR[k2]; tm = LM[k2]; d = depth(tm); fi = lead_ws(tm)
      isfield = !match(substr(tm, fi + 1), /^(of|else|elif|when|case)([^A-Za-z0-9_]|$)/)
      while (k2 < NL) {
        if (d <= 0 && !isfield) break
        if (d <= 0 && norm(LR[k2 + 1], LM[k2 + 1]) != "" && lead_ws(LM[k2 + 1]) <= fi) break
        if (d <= 0 && norm(LR[k2 + 1], LM[k2 + 1]) == "") break
        k2++; t = t " " LR[k2]; tm = tm " " LM[k2]; d += depth(LM[k2])
      }
      field_line(t, tm, pfx)
      k2++
    }
    k = k2 - 1
  }
}

# End-of-file audit: an open multi-line literal / comment means the census of
# that file is unknown.
function eof_audit() {
  if (LX == "s3")
    print "UNTERMINATED " curfile ": file ends inside a triple-quoted string" > "/dev/stderr"
  if (LX == "bc")
    print "UNTERMINATED " curfile ": file ends inside a #[ block comment ]#" > "/dev/stderr"
}

function process_file(    k) {
  if (curfile == "") return
  for (k = 1; k <= NL; k++) { find_keywords(k); find_tuples(k) }
  scan_objects()
  eof_audit()
}

BEGIN { sigs = 0; withparams = 0; noparams = 0; anons = 0; unbal = 0; unpar = 0; objects = 0; fields = 0; tuples = 0; tupleblocks = 0; curfile = "" }

# Per-file reset: the previous file is fully processed from its own line store
# BEFORE any state is cleared, and the new file starts from an empty lexer and
# an empty store (NL = 0 bounds the cursor, so no stale line is ever read).
FNR == 1 { process_file(); curfile = FILENAME; NL = 0; LX = ""; LBD = 0; LDOC = 0 }

{ lex($0); NL++; LR[NL] = LREAL; LM[NL] = LMASK }

END {
  process_file()
  printf("STATS signatures=%d withparams=%d noparams=%d anonymous=%d unbalanced=%d unparsed=%d objects=%d objectfields=%d tuples=%d tupleblocks=%d\n", sigs, withparams, noparams, anons, unbal, unpar, objects, fields, tuples, tupleblocks) > "/dev/stderr"
}
'

# One awk pass over every file (no `xargs`: it is absent from the dev image).
# Records go to stdout, the self-check line to stderr, captured separately so a
# broken enumerator cannot hide behind an empty-but-successful census.
TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t crisol-defparams)"
trap 'rm -rf "$TMPD"' EXIT
awk -v SQ="'" "$LEXER$ENUMERATOR" "${NIMFILES[@]}" >"$TMPD/records" 2>"$TMPD/stats"
AWK_RC=$?
if [ "$AWK_RC" -ne 0 ]; then
  echo "assert-defaulted-params.sh: the enumerator (awk) exited $AWK_RC — refusing" >&2
  echo "  to report a census it did not finish. awk stderr follows:" >&2
  cat "$TMPD/stats" >&2
  exit 2
fi
# A file whose signature never closed, that ended inside a triple string or
# block comment, or that holds a routine keyword the scanner could not resolve
# to a known header shape, has an UNKNOWN census: the scanner cannot say which
# of its parameters (if any) carry defaults. Neither "pass" nor "drift" is
# honest, so this is "cannot tell" -- exit 2, naming the file(s) and line(s).
if grep -E '^(UNBALANCED|UNTERMINATED|UNPARSED) ' "$TMPD/stats" >"$TMPD/unbalanced"; then
  echo "assert-defaulted-params.sh: CANNOT TELL — the scanner could not balance or" >&2
  echo "  parse the following site(s), so their defaulted-parameter census is unknown:" >&2
  sed 's/^/  /' "$TMPD/unbalanced" >&2
  echo "  Either the file does not compile (fix it first) or it uses a form this" >&2
  echo "  scanner does not model (extend the LEXER / ENUMERATOR in this script)." >&2
  exit 2
fi
OBSERVED="$(sort "$TMPD/records")"
STATLINE="$(grep '^STATS ' "$TMPD/stats")"
stat() { printf '%s\n' "$STATLINE" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
N_SIGS="$(stat signatures)"; N_WITH="$(stat withparams)"; N_NONE="$(stat noparams)"
STATS="signatures=${N_SIGS:-?} with-parameter-lists=${N_WITH:-?} no-parameter-list=${N_NONE:-?} anonymous=$(stat anonymous) object-types=$(stat objects) tuple-types=$(stat tuples)+$(stat tupleblocks) object-field-defaults=$(stat objectfields)"
if [ -z "$N_SIGS" ] || [ -z "$N_WITH" ] || [ -z "$N_NONE" ] || [ "$N_SIGS" -eq 0 ]; then
  echo "assert-defaulted-params.sh: the enumerator saw ${#NIMFILES[@]} file(s) but found" >&2
  echo "  ZERO routine signatures (or printed no STATS line). That is a broken" >&2
  echo "  enumerator, not a clean tree; reporting it as a pass is the silent" >&2
  echo "  under-report this gate exists to prevent." >&2
  exit 2
fi
# Round-7 finding S2: the enumerator always COUNTED both numbers and never
# compared them, so a signature it recognised but could not read (a multi-line
# generic section, a non-ASCII name, ...) vanished with its parameters while
# the gate said OK. Every routine keyword must now resolve to exactly one of
# "parameter list read" or "legitimately has none"; any other outcome is
# cannot-tell. (The UNPARSED/UNBALANCED lines above normally name the site
# first; this is the arithmetic backstop should a scanner path ever forget to.
# Unreachable on a correct scanner -- only a scanner bug can trip it -- so the
# self-test reaches it by deleting `withparams++` in a COPY of this script and
# pins this message; round-8 finding L5.)
if [ "$N_SIGS" -ne $((N_WITH + N_NONE)) ]; then
  echo "assert-defaulted-params.sh: CANNOT TELL — $N_SIGS routine keyword(s) seen but" >&2
  echo "  only $((N_WITH + N_NONE)) resolved ($N_WITH with a parameter list, $N_NONE" >&2
  echo "  without); the census of the rest is unknown. ($STATS)" >&2
  exit 2
fi

if [ "$MODE" = "list" ]; then
  printf '%s\n' "$OBSERVED"
  echo "# --- enumerator stats: $STATS ---" >&2
  exit 0
fi

# --------------------------------------------------------------------------
# THE PINNED ALLOWLIST.
#
# Every line is one of the three RECORD FORMAT classes followed by
# `  # <reason>` (object fields live in block F, each reason opening with its
# bucket letter A-E or the `PENDING COREY (<finding>)` marker). The
# reason is the HUMAN CLASSIFICATION of the default's DIRECTION and is the
# entire value of this file — a record without one is the annotation-grep this
# script replaces. Reasons are grouped by classification bucket; the comment
# above each block carries the shared argument so individual lines stay
# one-liners. Padding before `#` is cosmetic (whitespace is normalised before
# the comparison).
#
# Classified 2026-09-24 (round-5 review, R5-15(b)); default VALUES added and
# every reason re-checked against its value 2026-09-24 (round-6 finding D2).
# The record count is not quoted here because a hand-copied count rots; it is
# MEASURED on every run (the OK line prints it) and reproduced by
#   ci/assert-defaulted-params.sh --list | wc -l
# (197 records over 1010 signatures when the values were pinned; 197 routine
# records plus 34 object-field records over 1128 keywords, 114 of them
# anonymous, when round 7 widened the scanner -- no anonymous routine in src/
# carried a default then; still 231 records over 1131 keywords and 128 tuple
# types, none carrying a field default, when round 8 added multi-line object
# headers, tuple fields and `do` blocks). A record
# appearing more than once is a second overload of the same routine defaulting
# the same parameter name to the same value — see the RECORD FORMAT section.
# --------------------------------------------------------------------------
ALLOWLIST="$(cat <<'EOF'
# --- A. INJECTION SEAMS: the default names the REAL production
# --- implementation, so omitting it IS production behavior. Tests override
# --- it; a forgotten override can only make a test less realistic, never
# --- make production less sound.
src/crisol/admission.nim:initAdmission:probe = nil                                        # nil selects the real memory probe (memprobe); tests inject a synthetic one
src/crisol/artifactid.nim:ccIncludeClosure:expandCandidate = safeExpandFilename           # = safeExpandFilename, the real on-disk case probe
src/crisol/artifactid.nim:ccIncludeClosure:readFile = realFileReader                      # = realFileReader
src/crisol/artifactid.nim:ccIncludeClosure:run = realRun                                  # = realRun, the real process-execution seam
src/crisol/artifactid.nim:includeClosureContentHash:readFile = realFileReader             # = realFileReader
src/crisol/artifactid.nim:normalize:readFile = realFileReader                             # = realFileReader, the real std/os reader
src/crisol/cacheregistry.nim:configuredCache:foldProbe = probeFoldPolicy                  # = probeFoldPolicy
src/crisol/cacheregistry.nim:productionRegistry:fetcher = rawHttpFetcher()                # = rawHttpFetcher(), the real HTTP transport
src/crisol/cacheregistry.nim:rootInsideStateDir:probe = probeFoldPolicy                   # = probeFoldPolicy, the real on-disk fold probe
src/crisol/closure.nim:extractCompileInputs:ccRun = realRunIn(config.projectRoot.absolutePath.normalizedPath)  # = realRunIn(projectRoot), the real cc dependency probe
src/crisol/compiledriver.nim:defaultRunCc:concurrency = countProcessors()                 # = countProcessors(), the real host answer
src/crisol/config.nim:conventionConfig:probe = probeFoldPolicy                            # = probeFoldPolicy
src/crisol/config.nim:docToConfig:probe = probeFoldPolicy                                 # = probeFoldPolicy
src/crisol/config.nim:loadConfig:probe = probeFoldPolicy                                  # = probeFoldPolicy
src/crisol/config.nim:parseConfigFile:probe = probeFoldPolicy                             # = probeFoldPolicy
src/crisol/depgraph.nim:recordClosure:ccRun = realRunIn(config.projectRoot.absolutePath.normalizedPath)  # = realRunIn(projectRoot)
src/crisol/icbaseline.nim:probeIncremental:timeNow = realIcTimeNow                        # = realIcTimeNow, the real clock
src/crisol/memprobe.nim:availableMemBytes:read = realReadFile                             # = realReadFile, the real /proc reader
src/crisol/memprobe.nim:procGroupRssBytes:listProcs = nil                                 # nil selects the real process enumerator
src/crisol/memprobe.nim:procGroupRssBytes:read = realReadFile                             # = realReadFile
src/crisol/nimprobe.nim:nimFingerprint:hashBin = realBinHash                              # = realBinHash, the real binary hasher
src/crisol/nimprobe.nim:nimFingerprint:run = realRun                                      # = realRun
src/crisol/paths.nim:classify:expandCandidate = safeExpandFilename                        # = safeExpandFilename, the real on-disk case probe (both overloads)
src/crisol/paths.nim:classify:expandCandidate = safeExpandFilename                        # = safeExpandFilename, the real on-disk case probe (both overloads)
src/crisol/paths.nim:initTrackedRoots:probe = probeFoldPolicy                             # = probeFoldPolicy
src/crisol/process/windows.nim:probeCapabilities:nesting = probeJobObjectNesting()        # = probeJobObjectNesting(), the real capability probe
src/crisol/runner.nim:execute:onResult = noopResult                                       # = noopResult: no observer installed, an observation-only seam
src/crisol/runner.nim:execute:recordClosureFn = recordClosure                             # = recordClosure, the real one; tests inject a synthetic failure
src/crisol/runner.nim:execute:retireFn = retireStableBinary                               # = retireStableBinary, the real removeFile; tests inject a failing retire (issue #26)
# --- B. FAIL-SAFE: omitting the default drives the decision toward stale /
# --- miss / untrusted / recompute / widest-selection -- OVER-invalidation,
# --- which costs at most a cache miss or a longer run.
src/crisol/cachedispatch.nim:keyContext:roots = TrackedRoots()                            # unpopulated roots make key identity fall back to the plain ABSOLUTE path, i.e. location-sensitive -> a relocated tree MISSES rather than hits
src/crisol/cacheregistry.nim:configuredCache:trackedRoots = TrackedRoots()                # same direction as keyContext's roots: unpopulated means location-sensitive identity, which over-invalidates
src/crisol/cachetier.nim:drainPending:budget = high(int)                                  # = high(int): drain everything rather than leave work pending
src/crisol/depgraph.nim:saveDepGraph:preserveHeaderRoots = false                          # false RE-STAMPS header.roots from the current config; true (GC-only path) is the skip, and only cleanOrphans passes it
src/crisol/depgraph.nim:updateEntry:closureHash = ""                                      # "" forces cdStale on the next compare -> recompile, never a mis-serve
src/crisol/depgraph.nim:updateEntry:externals = @[]                                       # empty externals cannot certify anything fresh; the sole src/ caller (recordClosure) passes the real set
src/crisol/depgraph.nim:updateEntry:protocolMajor = 0                                     # 0 is the legacy/unknown protocol; it can never match a real major, so it fails toward stale
src/crisol/order.nim:orderByHistory:roots = TrackedRoots()                                # ordering only; a mismatched identity re-orders the plan, it cannot change which tests run
src/crisol/pipeline.nim:buildRunPlan:changed = initHashSet[TrackedPath]()                 # inert while useChanged is false; an empty set can only widen, never narrow
src/crisol/pipeline.nim:buildRunPlan:changed = initHashSet[TrackedPath]()                 # inert while useChanged is false; an empty set can only widen, never narrow
src/crisol/pipeline.nim:buildRunPlan:failedKeys = initHashSet[tuple[tp: TrackedPath, group: string]]()  # inert while useFailed is false; an empty set can only widen, never narrow
src/crisol/pipeline.nim:buildRunPlan:failedKeys = initHashSet[tuple[tp: TrackedPath, group: string]]()  # inert while useFailed is false; an empty set can only widen, never narrow
src/crisol/pipeline.nim:buildRunPlan:forceCompile = false                                 # false = honour the graph's own staleness verdict; true only ADDS recompiles
src/crisol/pipeline.nim:buildRunPlan:forceCompile = false                                 # false = honour the graph's own staleness verdict; true only ADDS recompiles
src/crisol/pipeline.nim:buildRunPlan:shardK = 0                                           # 0 with shardN=1 means the single whole-suite shard: nothing is dropped
src/crisol/pipeline.nim:buildRunPlan:shardK = 0                                           # 0 with shardN=1 means the single whole-suite shard: nothing is dropped
src/crisol/pipeline.nim:buildRunPlan:shardN = 1                                           # 1 = one shard = the whole suite runs
src/crisol/pipeline.nim:buildRunPlan:shardN = 1                                           # 1 = one shard = the whole suite runs
src/crisol/pipeline.nim:buildRunPlan:useChanged = false                                   # false = no --changed filter = run EVERYTHING (widest selection)
src/crisol/pipeline.nim:buildRunPlan:useChanged = false                                   # false = no --changed filter = run EVERYTHING (widest selection)
src/crisol/pipeline.nim:buildRunPlan:useFailed = false                                    # false = no --failed filter = run EVERYTHING (widest selection)
src/crisol/pipeline.nim:buildRunPlan:useFailed = false                                    # false = no --failed filter = run EVERYTHING (widest selection)
src/crisol/planner.nim:plan:forceCompile = false                                          # false = honour the graph's verdict; true only ADDS recompiles
src/crisol/runner.nim:appendAttemptRow:roots = TrackedRoots()                             # ledger/history rows only; a mismatched identity loses history (order/perf-check degrade), it cannot serve a result
src/crisol/runner.nim:execute:cache = cacheDisabled(resolveSandbox())                     # = cacheDisabled(resolveSandbox()): caching OFF neither reads nor publishes -- the fail-safe direction
src/crisol/runner.nim:execute:config = Config()                                           # = Config(): the zero config. Its one identity-bearing field (trackedRoots) unpopulated falls back to plain ABSOLUTE-path identity, which is location-sensitive, i.e. over-invalidating
src/crisol/sandbox.nim:resolveSandbox:envPins = @[]                                       # empty = no pinned env tail = strictest
src/crisol/sandbox.nim:resolveSandbox:level = hlIsolated                                  # = hlIsolated, the STRICTEST hermeticity level; omitting it cannot loosen the sandbox
src/crisol/sandbox.nim:resolveSandbox:passthroughs = @[]                                  # empty = fewest env vars passed through = strictest
src/crisol/shard.nim:balancedShardOf:roots = TrackedRoots()                               # as shardOf: tag-0-inert, and partition-complete within one invocation
src/crisol/shard.nim:shardOf:roots = TrackedRoots()                                       # RFC-0009 A5b-ii: inert for production entrypoints (always tag-0; keyBytes' tag-0 branch never reads roots), and one invocation shards every entrypoint under the SAME value, so the partition stays complete
src/crisol/shard.nim:shardWithHistory:roots = TrackedRoots()                              # as shardOf: tag-0-inert, and partition-complete within one invocation
# --- C. CAPACITY / POLICY / TELEMETRY / REPORTING KNOBS: a wrong value
# --- costs performance, retention or reporting detail. None of these is a
# --- cache key, a staleness comparison or a trust gate input.
src/crisol.nim:runMain:selfWorkerBinary = ""                                              # "" is the library value; the ONE CLI entrypoint passes getAppFilename() explicitly (see its own comment)
src/crisol/admission.nim:initAdmission:estJobPeakMb = 0                                   # memory-admission capacity knob
src/crisol/admission.nim:initAdmission:memPerRunMb = 0                                    # memory-admission capacity knob
src/crisol/admission.nim:initAdmission:safetyMb = 0                                       # memory-admission capacity knob
src/crisol/runcore.nim:closureReport:opts = RunOptions()                                      # = RunOptions(): the documented default option set
src/crisol/runcore.nim:failureLine:policy = ptypes.DefaultPolicy                              # reporting strictness for one rendered line
src/crisol/runcore.nim:planTests:opts = RunOptions()                                          # = RunOptions(): the documented default option set
src/crisol/runcore.nim:planToJsonString:substrate = ptypes.Capabilities()                     # reported capability block only
src/crisol/api.nim:runTests:opts = RunOptions()                                           # = RunOptions(): the documented default option set
src/crisol/runcore.nim:verifyCachePass:installSignals = false                                 # false = do not touch the caller's signal disposition (library-safe)
src/crisol/runcore.nim:verifyCachePass:sink = NilSink[TelemetryEvent]()                       # = NilSink: telemetry off, observation only
src/crisol/runcore.nim:verifySample:pct = -1                                                  # --verify-cache sampling knob (-1 = unset)
src/crisol/runcore.nim:verifySample:seed = none(int64)                                        # --verify-cache sampling knob
src/crisol/runcore.nim:verifySample:strict = false                                            # --verify-cache reporting knob
src/crisol/cachedispatch.nim:cacheEnabled:outcomePolicy = ptypes.DefaultPolicy            # = DefaultPolicy: REPORTING strictness, applied identically on read and store, so it cannot make the two disagree
src/crisol/cachedispatch.nim:cacheEnabled:prefetch = noopPrefetch                         # = noopPrefetch: prefetch is an optimisation, never a correctness input
src/crisol/cachedispatch.nim:cacheEnabled:sink = NilSink[TelemetryEvent]()                # = NilSink: telemetry off, observation only
src/crisol/cachedispatch.nim:consultPostCompile:sink = NilSink[TelemetryEvent]()          # = NilSink: telemetry off
src/crisol/cachedispatch.nim:lookupAtPlan:explainDiag = false                             # --explain-miss diagnostic seam consult only
src/crisol/cachedispatch.nim:lookupAtPlan:sink = NilSink[TelemetryEvent]()                # = NilSink: telemetry off
src/crisol/cachehttp.nim:httpBackend:bodyCapBytes = DefaultBodyCapBytes                   # transport size cap
src/crisol/cachehttp.nim:httpBackend:token = ""                                           # "" = no bearer token; an unauthenticated tier fails its own fetch, it cannot forge a trusted one
src/crisol/cachelocalfs.nim:writeSidecar:maxRecords = DefaultMaxSidecarRecords            # sidecar retention cap
src/crisol/caches3.nim:s3Backend:bodyCapBytes = DefaultBodyCapBytes                       # transport size cap
src/crisol/caches3.nim:s3Backend:endpoint = ""                                            # transport endpoint knob
src/crisol/caches3.nim:s3Backend:pathStyle = true                                         # transport addressing knob
src/crisol/caches3.nim:s3Backend:prefix = ""                                              # bucket-layout knob
src/crisol/cachetier.nim:drainPending:abandoned = proc(): bool = false                    # never-abandoned predicate; cancellation responsiveness only
src/crisol/cachetier.nim:resolveProbes:abandoned = proc(): bool = false                   # never-abandoned predicate; cancellation responsiveness only
src/crisol/cachewire.nim:upsertSidecarRecord:maxRecords = DefaultMaxSidecarRecords        # sidecar retention cap
src/crisol/compiledriver.nim:newMeasureDriver:concurrency = countProcessors()             # = countProcessors(): capacity
src/crisol/compiledriver.nim:newMeasureDriver:workingDir = ""                             # "" = inherit; the measure worker passes the real one
src/crisol/nimargv.nim:nimCompileArgs:compileOnly = false                               # selects --compileOnly for the measure driver; a build-shape knob
src/crisol/compilereport.nim:buildCompileBlock:ambientCcacheDetected = false              # reported compile block field
src/crisol/compilereport.nim:buildCompileBlock:compileRegressions = nil                   # reported compile block field
src/crisol/compilereport.nim:buildCompileBlock:currentRunStartUs = 0                      # reported compile block field
src/crisol/compilereport.nim:buildCompileBlock:lowConfidenceMinEntrypoints = LowConfidenceMinEntrypoints  # confidence-labelling threshold (telemetry)
src/crisol/compilereport.nim:computeCompileRegressions:absFloorMs = CompileRegressionAbsFloorMs  # compile-regression detector threshold (telemetry)
src/crisol/compilereport.nim:computeCompileRegressions:k = CompileRegressionK             # compile-regression detector threshold (telemetry)
src/crisol/compilereport.nim:computeCompileRegressions:sampleFloor = CompileRegressionSampleFloor  # compile-regression detector threshold (telemetry)
src/crisol/config.nim:loadConfig:configPath = ""                                          # "" = discover by convention, the documented default
src/crisol/config.nim:loadConfig:startDir = ""                                            # "" = current directory, the documented default
src/crisol/depgraph.nim:sanitizeHeaderField:pipeAware = false                             # output-escaping knob for one header field
src/crisol/discover.nim:discover:selection = GroupSelection(kind: gskDefault)             # = gskDefault: the documented default group set; the CLI always passes the resolved selection
src/crisol/httpraw.nim:rawHttpFetcher:bodyCapBytes = DefaultBodyCapBytes                  # transport size cap
src/crisol/httpraw.nim:rawHttpFetcher:connectTimeoutMs = DefaultConnectTimeoutMs          # transport timeout
src/crisol/httpraw.nim:rawHttpFetcher:recvTimeoutMs = DefaultRecvTimeoutMs                # transport timeout
src/crisol/ioutils.nim:appendOpen:mode = 0o600                                            # 0o600 is the RESTRICTIVE mode
src/crisol/ioutils.nim:createOverwrite:mode = 0o600                                       # 0o600 is the RESTRICTIVE mode
src/crisol/ioutils.nim:exclusiveCreate:mode = 0o600                                       # 0o600 is the RESTRICTIVE mode; omitting it cannot widen permissions
src/crisol/jsonout.nim:toJson:cacheStats = CacheStats()                                   # report field
src/crisol/jsonout.nim:toJson:compileBlock = nil                                          # report field
src/crisol/jsonout.nim:toJson:explainMiss = false                                         # report field
src/crisol/jsonout.nim:toJson:filterTag = ""                                              # report field
src/crisol/jsonout.nim:toJson:interrupted = false                                         # report field
src/crisol/jsonout.nim:toJson:lateOrphansReaped = 0                                       # report field
src/crisol/jsonout.nim:toJson:memThrottledSlots = 0                                       # report field
src/crisol/jsonout.nim:toJson:policy = ptypes.DefaultPolicy                               # reporting strictness for the rendered outcome
src/crisol/jsonout.nim:toJson:reuseAlerts = nil                                           # report field
src/crisol/jsonout.nim:toJson:showCacheStats = false                                      # report field
src/crisol/jsonout.nim:toJson:substrate = ptypes.Capabilities()                           # report field
src/crisol/jsonout.nim:toJson:trackedRoots = default(TrackedRoots)                        # report field: used to RENDER paths, never to key anything
src/crisol/jsonout.nim:toJson:verifyFails = 0                                             # report field
src/crisol/jsonout.nim:toJson:warnings = @[]                                              # report field
src/crisol/jsonout.nim:toJsonString:explainMiss = false                                   # report field
src/crisol/jsonout.nim:toJsonString:filterTag = ""                                        # report field
src/crisol/jsonout.nim:toJsonString:showCacheStats = false                                # report field
src/crisol/junit.nim:outcomeChildXml:policy = ptypes.DefaultPolicy                        # reporting strictness in the JUnit projection
src/crisol/junit.nim:toJunitXml:policy = ptypes.DefaultPolicy                             # reporting strictness in the JUnit projection
src/crisol/pipeline.nim:buildRunPlan:order = omNone                                       # = omNone: execution ORDER only; every selected entrypoint still runs
src/crisol/pipeline.nim:buildRunPlan:order = omNone                                       # = omNone: execution ORDER only; every selected entrypoint still runs
src/crisol/pipeline.nim:buildRunPlan:warnings = @[]                                       # collected warning strings for the report
src/crisol/pipeline.nim:buildRunPlan:warnings = @[]                                       # collected warning strings for the report
src/crisol/planview.nim:planToJson:substrate = Capabilities()                             # report field
src/crisol/planview.nim:planToJson:warnings = @[]                                         # report field
src/crisol/planview.nim:planToJsonString:substrate = Capabilities()                       # report field
src/crisol/planview.nim:planToJsonString:warnings = @[]                                   # report field
src/crisol/process/posix.nim:initSupervisor:installSignals = true                         # signal-disposition ownership; the caller's choice, not a key input
src/crisol/process/types.nim:classifyCause:limitKilled = none(LimitKind)                  # cause-classification evidence for REPORTING
src/crisol/process/types.nim:classifyCause:memoryOomKill = false                          # cause-classification evidence for REPORTING; the honest-result model records what it has
src/crisol/process/windows.nim:initSupervisor:installSignals = true                       # signal-disposition ownership; the caller's choice, not a key input
src/crisol/protocol.nim:readSink:maxBytes = DefaultSinkMaxBytes                           # sink read cap
src/crisol/render.nim:formatProgressLine:memThrottled = false                             # progress-line field
src/crisol/render.nim:pathFlagsWarnings:withinGroups = @[]                                # warning-rendering scope
src/crisol/render.nim:render:policy = ptypes.DefaultPolicy                                # reporting strictness
src/crisol/report.nim:initReport:ep = ""                                                  # "" = unnamed report shell; every real record names its entrypoint
src/crisol/resultcache.nim:storeCached:maxCacheEntries = DefaultMaxCacheEntries           # L1 retention cap
src/crisol/resultcache.nim:storeCachedAt:maxCacheEntries = DefaultMaxCacheEntries         # L1 retention cap
src/crisol/runner.nim:appendAttemptRow:memoryPeakBytes = none(int64)                      # ledger telemetry field
src/crisol/runner.nim:appendAttemptRow:peakRssBytes = 0                                   # ledger telemetry field
src/crisol/runner.nim:execute:explainMiss = false                                         # --explain-miss diagnostic output only
src/crisol/runner.nim:execute:failFast = false                                            # false = continue-on-failure, crisol's documented default
src/crisol/runner.nim:execute:installSignals = false                                      # false = do not touch the caller's signal disposition (library-safe)
src/crisol/runner.nim:execute:progressIntervalMs = 30_000                                 # progress reporting only
src/crisol/runner.nim:execute:recordLedger = true                                         # ledger history only
src/crisol/runner.nim:execute:showProgress = true                                         # progress reporting only
src/crisol/runner.nim:handleChildExited:blockTransition = false                           # scheduler state-machine guard, internal
src/crisol/runner.nim:runEntrypoint:compileTimeoutMs = 30_000                             # timeout knob
src/crisol/runner.nim:runEntrypoint:maxOutputBytes = 65_536                               # output cap knob
src/crisol/runner.nim:runEntrypoint:runTimeoutMs = 30_000                                 # timeout knob
src/crisol/runner.nim:summarize:policy = ptypes.DefaultPolicy                             # reporting strictness
src/crisol/runner.nim:toProcessResult:hermetic = ptypes.hlNone                            # records which hermeticity level the observation was made under; reporting
src/crisol/sandbox.nim:resolveSandbox:chdirIntoScratch = false                            # scratch-dir cwd knob
src/crisol/sandbox.nim:resolveSandbox:memoryLimit = none(int64)                           # memory cap; capacity
src/crisol/sandbox.nim:resolveSandbox:rlimits = RlimitOverrides()                         # rlimit overrides; capacity
src/crisol/types.nim:exitCode:failOnFlaky = false                                         # exit-code policy knob; the CLI passes the resolved value
src/crisol/types.nim:flaky:policy = ptypes.DefaultPolicy                                  # reporting strictness; see `outcome`
src/crisol/types.nim:outcome:policy = ptypes.DefaultPolicy                                # reporting strictness; the SAME policy is applied on read and store (SO1), so it cannot make the two disagree
# --- D. DOCUMENTED SOUNDNESS EXCEPTION: a genuine soundness default that
# --- survives by an explicit, argued, in-file exception. Each of these HAS a
# --- SOUNDNESS-PARAMETER WARNING block; read it before touching the call.
src/crisol/runner.nim:execute:nimVersion = ""                                             # the R2-7/R3-7/R4-7/R5-8 exception, argued at length in this file's SOUNDNESS-PARAMETER WARNING above `execute`
# --- E. DIRECTION NAMED, NOT A CACHE-KEY / STALENESS / TRUST DEFAULT. These
# --- are the census's narrowest-margin entries: the default does select the
# --- more permissive or narrower behavior, but the consequence is a dropped
# --- policy opt-out, a shorter test list, or a followed symlink -- never a
# --- stale or foreign artifact served under a weakened key. Re-examine each
# --- if it ever becomes an input to identity material.
src/crisol/runcore.nim:changedOnly:baseRef = ""                                               # as gitdiff.changedFiles's base: "" diffs the working tree against HEAD; a narrower changed set under-SELECTS, and narrowByDiff force-includes any entrypoint with no closure record
src/crisol/runcore.nim:failedOrChanged:baseRef = ""                                           # as changedOnly's baseRef
src/crisol/cachedispatch.nim:shouldStore:cacheable = csDefault                            # csDefault == csTrue for this gate; only csFalse (a group's config opt-out) differs, so omitting PUBLISHES a correctly-keyed entry the config asked to skip -- an eligibility miss, never a wrong artifact served. The production store gate passes the group's real state
src/crisol/discover.nim:matchGlob:fold = fpNone                                           # fpNone is BYTE-EXACT matching, so omitting can only match FEWER paths -- it under-selects a test into a visibly shorter plan, it never widens a cache key's equivalence class
src/crisol/gitdiff.nim:changedFiles:base = ""                                             # "" diffs the working tree against HEAD; a caller meaning "since <ref>" must say so. A narrower changed set under-SELECTS (shorter plan), and narrowByDiff force-includes any entrypoint with no closure record
src/crisol/ioutils.nim:createOverwrite:noFollow = false                                   # as exclusiveCreate: false follows symlinks; the refusing call sites pass true explicitly and are test-pinned
src/crisol/ioutils.nim:exclusiveCreate:noFollow = false                                   # false = follow symlinks (the plain open() default); the symlink-REFUSING call sites pass true explicitly and are pinned by tests/unit/test_ioutils.nim's nofollow suites
# --- F. OBJECT-FIELD DEFAULTS (Nim 2 `field*: T = value`), record class
# --- `<path>:<Type>.<field> = <default>` (a tuple field, `anon_tuple(...)`,
# --- is filed here too). The same defect class as a
# --- defaulted parameter, one level up: an object-construction literal that
# --- OMITS the field silently gets this value, exactly as a short call gets a
# --- parameter default. Each reason opens with the bucket letter (A-E above)
# --- it was classified into, and the bucket's shared argument applies -- or
# --- with `PENDING COREY (<finding>)`, an UNCLASSIFIED pin (see the header's
# --- definition of that marker). Classified
# --- 2026-09-25 (round-7 finding S2, shape M7) from each field's doc comment
# --- and its consumers.
src/crisol/runcore.nim:RunOptions.cacheStats = false                   # C: --cache-stats; gates a telemetry sink only (planImpl merges it opt-in-only into cfg.cacheStats)
src/crisol/runcore.nim:RunOptions.chdirIntoScratch = false             # C: child cwd stays projectRoot (the A2c contract); a behavioral toggle its own doc calls "not a safety property"
src/crisol/runcore.nim:RunOptions.configPath = ""                      # C: "" = discover crisol.kdl by convention, the documented default
src/crisol/runcore.nim:RunOptions.envPassthroughs = @[]                # B: empty = no env var added to DefaultEnvAllowlist = strictest env, as resolveSandbox's passthroughs
src/crisol/runcore.nim:RunOptions.envPins = @[]                        # B: empty = nothing pinned beyond Config.envPins, as resolveSandbox's envPins
src/crisol/runcore.nim:RunOptions.explainMiss = false                  # C: --explain-miss gates RENDERING of keyDiff only; the producer runs regardless
src/crisol/runcore.nim:RunOptions.explainMissVerbose = false           # C: as explainMiss; verbose only adds detail to an already-shown block
src/crisol/runcore.nim:RunOptions.failFast = false                     # C: false = continue-on-failure, crisol's documented default
src/crisol/runcore.nim:RunOptions.failOnFlaky = false                  # C: exit-code policy for flaky passes; the CLI passes the resolved value
src/crisol/runcore.nim:RunOptions.foldProbe = nil                      # A: nil selects the real probeFoldPolicy; tests inject a forced probe
src/crisol/runcore.nim:RunOptions.forceCompile = false                 # B: false = honour the graph's staleness verdict; true only ADDS recompiles
src/crisol/runcore.nim:RunOptions.hermeticLevel = hlIsolated           # B: hlIsolated, the STRICTEST level that runs cached (hlNetwork degrades and is never cached); omitting cannot loosen the sandbox
src/crisol/runcore.nim:RunOptions.installSignals = false               # C: false = do not replace the host's signal handlers (library-safe)
src/crisol/runcore.nim:RunOptions.jobs = 0                             # C: <= 0 defers to config/built-in concurrency; capacity
src/crisol/runcore.nim:RunOptions.limitMemory = none(int64)            # C: none defers to Config.limitMemory; a memory ceiling, capacity
src/crisol/runcore.nim:RunOptions.manageLock = true                    # B: true TAKES the advisory inter-process lock; omitting keeps concurrent runs serialised
src/crisol/runcore.nim:RunOptions.measureCompileReuse = false          # C: false = plain `nim c`, byte-for-byte the pre-RFC-0006 build; opt-in measurement only
src/crisol/runcore.nim:RunOptions.noCache = false                      # C: caching ON is the documented product default (CLI and library alike); soundness lives in the cache KEY and trust gates, which this does not touch
src/crisol/runcore.nim:RunOptions.noRemoteCache = false                # C: configured remote tiers stay in use; each already passed configuredCache's trust/transport gates
src/crisol/runcore.nim:RunOptions.onResult = nil                       # A: nil = no observer (noop), an observation-only seam, as runner.execute's onResult
src/crisol/runcore.nim:RunOptions.order = omNone                       # C: execution ORDER only; every selected entrypoint still runs
src/crisol/runcore.nim:RunOptions.perfCheckForce = false               # C: perf-regression detection override; telemetry
src/crisol/runcore.nim:RunOptions.persist = true                       # C: writes lastrun.json (history for --failed/order); reporting
src/crisol/runcore.nim:RunOptions.progressIntervalMs = 30_000          # C: progress reporting only
src/crisol/runcore.nim:RunOptions.retries = -1                         # C: -1 = use the config's retry count
src/crisol/runcore.nim:RunOptions.shardK = 0                           # B: 0 = no sharding = the whole suite runs
src/crisol/runcore.nim:RunOptions.shardN = 1                           # B: 1 = one shard = the whole suite runs
src/crisol/runcore.nim:RunOptions.showProgress = false                 # C: stderr progress line only
src/crisol/runcore.nim:RunOptions.startDir = ""                        # C: "" = walk up from cwd, the documented default
src/crisol/runcore.nim:RunOptions.strictHygiene = false                # C: reporting strictness (OutcomePolicy.strictHygiene); applied by the SAME resolved policy at report and serve (SO1), and it can only strengthen a config-file true
src/crisol/runcore.nim:RunOptions.timeoutSecs = 0                      # C: <= 0 defers to config/built-in timeout; capacity
src/crisol/runcore.nim:RunOptions.workerBinary = ""                    # C: "" = no self-reexec worker, which its doc calls always safe (degrades to monolithic compile)
src/crisol/process/types.nim:ChildSpec.claimOrphans = true         # B: true = the STRICT containment claim (reparented orphans are reaped as this child's escapees); only the runner's compile spawns opt out, explicitly
EOF
)"

# Strip reasons/section comments for the comparison; keep them in the file.
# Stripped with the SAME lexer the enumerator uses, not `sed 's/#.*//'`: a
# pinned VALUE may itself contain `#` inside a string literal (`sep = "#"`),
# and a naive strip would cut the record there. Whitespace is normalised the
# same way the enumerator normalises it, so column alignment is free.
ALLOWED="$(printf '%s\n' "$ALLOWLIST" \
  | awk -v SQ="'" "$LEXER"'{ LX = ""; lex($0); o = norm(LREAL, LMASK); if (o != "") print o }' \
  | sort)"

if [ "$OBSERVED" = "$ALLOWED" ]; then
  n=$(printf '%s\n' "$ALLOWED" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "DEFAULTED-PARAMS OK: observed census matches the pinned allowlist exactly (${n} record(s); $STATS)"
  exit 0
fi

echo "DEFAULTED-PARAMS FAILED: the set of defaulted parameters under src/ has drifted" >&2
echo "  from the pinned, human-classified allowlist in ci/assert-defaulted-params.sh." >&2
echo "  (enumerator: $STATS)" >&2
echo >&2
# `comm`, not `diff`: diff is absent from the dev container. Both inputs are
# already sorted, and comm's merge handles repeated lines, so this is a true
# multiset two-way report. A stale record and a new record with the SAME
# `<path>:<routine>:<param>` key are then paired up as a VALUE CHANGE, so the
# report names the old and the new default side by side.
printf '%s\n' "$ALLOWED"  > "$TMPD/allowed"
printf '%s\n' "$OBSERVED" > "$TMPD/observed"
comm -23 "$TMPD/allowed" "$TMPD/observed" | sed '/^$/d' > "$TMPD/stale"
comm -13 "$TMPD/allowed" "$TMPD/observed" | sed '/^$/d' > "$TMPD/new"
awk -v out="$TMPD" '
  function key(s) { sub(/ = .*$/, "", s); return s }
  function val(s) { if (index(s, " = ") == 0) return ""; return substr(s, index(s, " = ") + 3) }
  # FILENAME, not the FNR == NR idiom: the stale file is empty whenever the
  # drift is additions only, and FNR == NR would then read the NEW file as
  # the stale one.
  FILENAME == ARGV[1] { k = key($0); ns[k]++; S[k, ns[k]] = $0; next }
            { k = key($0); nn[k]++; N[k, nn[k]] = $0 }
  END {
    for (k in ns) {
      p = (k in nn) ? ((ns[k] < nn[k]) ? ns[k] : nn[k]) : 0
      for (i = 1; i <= ns[k]; i++)
        if (i <= p) print "  ~ " k ": pinned `= " val(S[k, i]) "`, observed `= " val(N[k, i]) "`" > (out "/changed")
        else        print "  < " S[k, i] > (out "/stale.only")
    }
    for (k in nn) {
      p = (k in ns) ? ((ns[k] < nn[k]) ? ns[k] : nn[k]) : 0
      for (i = p + 1; i <= nn[k]; i++) print "  > " N[k, i] > (out "/new.only")
    }
  }' "$TMPD/stale" "$TMPD/new"
report_section() {  # $1 = title, $2 = file
  echo "--- $1 ---" >&2
  if [ -s "$2" ]; then sort "$2" >&2; else echo "  (none)" >&2; fi
}
report_section "VALUE CHANGED: same parameter, different default than the one classified" "$TMPD/changed"
report_section "STALE PINS: allowlisted, but no such defaulted parameter in src/" "$TMPD/stale.only"
report_section "UNCLASSIFIED: in src/, but not in the allowlist" "$TMPD/new.only"
echo >&2
echo "WHAT TO DO:" >&2
echo >&2
echo "  A '~' line is a default whose VALUE changed. Every reason in the allowlist" >&2
echo "  is a claim about the value (\"0o600 is the RESTRICTIVE mode\", \"hlIsolated" >&2
echo "  is the STRICTEST level\"), so a new value voids the classification. Re-read" >&2
echo "  the record's reason against the NEW value: if it still holds, update the" >&2
echo "  pinned value (and the reason's wording if it quotes the value); if it no" >&2
echo "  longer holds, treat the parameter exactly like a '>' line below." >&2
echo >&2
echo "  A '>' line is a defaulted parameter in src/ that NO human has classified." >&2
echo "  Classify its DIRECTION -- what happens if a call site OMITS it?" >&2
echo >&2
echo "    * Does omitting it weaken a CACHE KEY, a STALENESS COMPARISON, or a" >&2
echo "      TRUST GATE, so that a stale or foreign artifact could be SERVED?" >&2
echo "      That is UNDER-invalidation. crisol's L2 tier is shared across hosts," >&2
echo "      so this is cross-host cache poisoning, not a local inefficiency." >&2
echo "      => REMOVE THE DEFAULT. Add a '{.deprecated.}' companion overload" >&2
echo "         carrying the old signature (zero call-site churn; the compiler" >&2
echo "         reports each omission at the CALLER's own file:line, and" >&2
echo "         --warningAsError:Deprecated:on makes it a hard error in src/)," >&2
echo "         and annotate the full-arity proc with a SOUNDNESS-PARAMETER" >&2
echo "         WARNING block. Canonical shape: pipeline.buildRunPlan." >&2
echo >&2
echo "    * Or does omitting it fail SAFE -- forcing stale/miss/untrusted/" >&2
echo "      recompute, naming a real production seam, or moving only capacity," >&2
echo "      policy or telemetry? Then it is not this defect class." >&2
echo "      => ADD THE RECORD to ALLOWLIST in this script, WITH a one-line" >&2
echo "         reason naming why omitting it is safe. The reason IS the" >&2
echo "         classification; a record without one re-creates the" >&2
echo "         annotation-grep this gate replaced." >&2
echo >&2
echo "  A '<Type>.<field>' record is an OBJECT-FIELD default: a construction" >&2
echo "  literal that omits the field gets it. Same question, same two outcomes," >&2
echo "  except the unsound case is fixed by deleting the field default (every" >&2
echo "  literal then states the value, or a constructor proc takes it as a" >&2
echo "  required parameter) -- there is no deprecated-companion trick for fields." >&2
echo "  Pin it in block F, and OPEN its reason with the bucket letter it was" >&2
echo "  classified into ('B: ...'), so the bucket's shared argument visibly" >&2
echo "  applies; if the direction needs the project owner's decision, open it" >&2
echo "  with 'PENDING COREY (<finding>):' instead (defined in the header)." >&2
echo "  An 'anon_<kw>(<binder>)' record is a lambda, proc type or 'do' block --" >&2
echo "  classify it like any other parameter -- or, for 'anon_tuple', a tuple" >&2
echo "  FIELD, which 'default(T)' applies: treat it like an object field." >&2
echo >&2
echo "  A '<' line is a STALE PIN: the allowlist asserts a fact about a" >&2
echo "  defaulted parameter that no longer exists (renamed, re-signatured, or" >&2
echo "  the default was correctly removed). Delete that line." >&2
echo >&2
echo "  Re-pin the whole set with: ci/assert-defaulted-params.sh --list" >&2
echo "  -- but read every new line before you paste it. Pasting the observed" >&2
echo "  set without classifying it is exactly the failure this gate exists to" >&2
echo "  prevent." >&2
exit 1
