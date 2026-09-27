#!/usr/bin/env bash
# ci/source-soundness-gate.sh -- THE source soundness gate over src/.
#
# ONE copy, invoked from both places that enforce it:
#   * `./dev check`                        (host-side, inside the podman dev image)
#   * ci.yml's "Source soundness gate" step (inside `docker run`)
#
# R5-11: this used to be hand-duplicated in those two files, and the copies had
# already drifted -- different `--path:src`, different call-site counts in the
# prose, one echoing a success line and the other silent, and each contradicting
# itself about its own coverage. A shared script removes the drift class instead
# of re-syncing today's two copies.
#
# CONTRACT: `nim` on PATH, the repo root as CWD, no network needed. Nothing
# else -- it has to behave identically under podman (`./dev`) and docker (CI).
# Quiet on success, one honest line at the end.
#
# ---------------------------------------------------------------------------
# WHAT THE TWO FLAGS ARE FOR
# ---------------------------------------------------------------------------
# --warningAsError:Deprecated:on (R3-7): the deprecated compatibility overloads
# in src/ exist so that removing their soundness parameters' DEFAULTS cost zero
# call-site churn -- the overwhelming majority of those call sites are in tests,
# which compile with `--warnings:off` and stay silent. This flag is what makes
# the guarantee real for PRODUCTION code: src/ is at zero omissions, and a new
# one becomes a hard error here rather than a warning nobody reads. Tests are
# deliberately NOT held to this -- see the overloads' own doc comments.
#
# WHICH procs carry a companion is deliberately not listed here (R5-8(b)): this
# comment used to name four, and more have landed since in modules it did not
# mention. No count replaces it either -- a figure a human maintains in a comment
# is the defect class R5-9, R5-18 and R5-26 all found, and this file has now been
# on both sides of it. Measure instead, from the repo root:
#
#     grep -rn '{\.deprecated:' src/ | grep -c '\.} ='     # how many
#     grep -rln '{\.deprecated:' src/                      # which modules
#     bash ci/assert-defaulted-params.sh                   # the pinned census
#
# --warningAsError:UnusedImport:on (R4-6): crisol is build-time tooling consumed
# as a LIBRARY by sibling projects, at least one of which (amoxtli) builds with
# this flag, so an unused import in src/ is a HARD build failure for a CONSUMER
# while being invisible in crisol's own suite (`nimble test` compiles with
# `--warnings:off`). Precedent: the unused `ioutils` import in render.nim,
# recorded in docs/rfc/0004-incremental-hermetic-execution.handoff.md.
#
# ---------------------------------------------------------------------------
# WHY SEVERAL INVOCATIONS, AND WHY THREE --os TARGETS (R5-2)
# ---------------------------------------------------------------------------
# Both flags can only fire on code the compiler actually SEMCHECKS, so this
# gate's coverage is exactly the union of its invocations' compiled sets. Two
# things fall outside a single `nim check src/crisol.nim` on the host OS:
#
#   1. Modules that main module's import closure never reaches. They are never
#      compiled, so neither flag ever sees them. Four are out of closure on
#      every target (see OUT_OF_CLOSURE below) and are gated as their own main
#      files, which also gives a consumer that imports one DIRECTLY the same
#      guarantee.
#
#   2. Code behind `when defined(<some other os>):`. crisol carries ~34
#      `when defined(windows)` and ~13 `when defined(macosx)` blocks inside
#      modules that ARE in the closure, plus three modules only reachable at
#      all on their own OS (process/windows.nim, process/darwin.nim,
#      lock/windows.nim). A Linux-only gate is blind to every one of them:
#      R5-2 found NINE real unused imports sitting unnoticed on the macOS
#      target, which means a macOS consumer building with the very flag this
#      project recommends could not build crisol. Hence the cross-target
#      passes below -- `nim check` never invokes a C compiler, so cross-
#      targeting costs nothing but a few seconds and keeps the whole gate in
#      one job.
#
# It is NOT because of any cross-module `used` bookkeeping. An earlier version
# of this comment claimed the compiler records `used` on the IMPORTED module's
# symbol for the whole compilation, so one module's use of std/strutils would
# mask every sibling's unused import of it. That is FALSE on 2.2.10, verified
# by mutation (R5, Low): Nim records `used` per IMPORTING module -- an unused
# `import std/strutils` added to src/crisol/fnv.nim is caught by
# `nim check src/crisol.nim` even though 37 sibling modules use strutils. The
# reason for the extra invocations is closure reach and target reach, nothing
# else. That distinction matters for how the gate gets extended: adding a
# module to the lists below is only ever about reachability.
#
# COVERAGE IS MEASURED AND ASSERTED, not claimed in a comment (R5-11, round 5).
# The last section of this script re-derives which modules its invocations
# actually semchecked, and exits non-zero if any file under src/ is compiled by
# none of them. The numbers below therefore document a run; they are not the
# guarantee. As of round 5: src/ holds 78 .nim files, src/crisol.nim's closure
# reaches 71 of them on --os:linux, 66 on --os:windows and 70 on --os:macosx, and
# the only four out of closure on ALL THREE are the OUT_OF_CLOSURE list -- union
# 78 of 78, no exemptions.
#
# The denominator is what is ON DISK, not what git tracks, and right now those
# differ: ccidentity.nim and toolrun.nim are untracked. A consumer that vendors
# the tree compiles them all the same, so the check counts them all the same. An
# earlier draft of this header said "76 tracked .nim files ... 69/64/68", which is
# the git-tracked view and is what the first run of the machine check corrected.
#
# WHY THE CHECK EXISTS, given the numbers above were already believed true. The
# invocation list is chosen by hand. A new module landing out of closure on all
# three targets and not named in OUT_OF_CLOSURE would be in NO gate: every
# existing check would stay green, this header would still read "no exemptions",
# and a green run would mean only "the modules I happen to compile are clean".
# R5-2 is what that costs when it happens -- nine real unused imports standing on
# the macOS target, unnoticed, on a clean tree, under a comment claiming full
# coverage. A coverage claim maintained by a human instruction to re-measure is
# the same class of defect as the stale figures R5-9 and R5-18 found.
#
# The measurement is close to free: the three aggregator passes already have to
# compile everything, so they run as `nim c -d:nimBetterRun --compileOnly`
# instead of `nim check`, and the "depfiles" key of each nimcache's crisol.json
# IS the compiled-set manifest. Codegen also type-checks strictly MORE than
# `nim check` does, and all three targets cross-generate on any host because
# --compileOnly never invokes a C compiler.
#
# ---------------------------------------------------------------------------
# IF THIS GATE ERRORS ON A LINE NOBODY TOUCHED (round-4 review, R4-10)
# ---------------------------------------------------------------------------
# Nim charges a `{.deprecated.}` warning to whatever NAMES the symbol, not only
# to what CALLS it, and a symbol-specific re-export names all of its arities.
# So adding a deprecated companion to proc `f` in module `a` makes `export a.f`
# elsewhere fail HERE, on the export line -- a site with no argument to pass,
# and one that cannot be deleted without breaking consumers.
#
# The fix is a `{.push warning[Deprecated]: off.}` / `{.pop.}` around that ONE
# export statement, never dropping the flag. Verified on 2.2.10: `export a.f`
# trips, a whole-module `export a` does NOT, and a template companion behaves
# the same as a proc. That asymmetry is why R3-7 never hit this -- no module
# carrying a deprecated companion has its symbols re-exported one at a time
# (`grep -rln '{\.deprecated:' src` lists those modules; none appears in an
# `export mod.sym` statement).

set -euo pipefail

if [ ! -f src/crisol.nim ]; then
    echo "source-soundness-gate: run me from the repo root (src/crisol.nim not found)" >&2
    exit 2
fi

# The three OS targets crisol is consumed on, and the three its own CI has legs
# for. `nim check` cross-targets without a cross toolchain, so all three run
# from whichever host invoked this script.
TARGETS="linux windows macosx"

# Every module src/crisol.nim's import closure fails to reach on ALL THREE
# targets, gated as its own main file (per target -- each of these has its own
# platform-conditional code too).
OUT_OF_CLOSURE="depparse icbaseline report unittest_shim"

# Scratch space for the aggregator passes' nimcaches, one per target. Per-target
# and never shared: a shared --nimcache across entrypoints is the ORC link-
# collision bug this project exists to respect, and here it would also have the
# three targets overwrite each other's manifest.
MANIFEST_DIR="$(mktemp -d)"
trap 'rm -rf "${MANIFEST_DIR}"' EXIT

# Nim's own error names a file and line but not WHICH of this script's
# invocations produced it -- the same module is semchecked by up to four of them
# (three aggregator targets plus a direct gate), and an error behind
# `when defined(windows)` reads identically to a host-OS one. So every
# invocation runs through here: silent on success (the one-line contract above),
# and on failure it names the pass, the main file and the --os target, and
# points at the header sections that document the remedy. Fail-fast, exactly as
# before -- this changes what a failure SAYS, not what is gated.
#
# $1 = pass label, $2 = target os, $3 = main file, rest = the command.
run_pass() {
    local label="$1" target="$2" main="$3"
    shift 3
    local rc=0
    "$@" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        {
            echo
            echo "source-soundness-gate: FAILED (exit ${rc}) in the ${label}: ${main} --os:${target}"
            echo "  The Nim error above came from this invocation. Read it first: it may be"
            echo "  an ordinary compile error (a type error, an undeclared identifier), which"
            echo "  you fix like any other. Every pass also compiles with"
            echo "  --warningAsError:Deprecated:on and --warningAsError:UnusedImport:on;"
            echo "  if it is a deprecation or unused-import error, see the header of"
            echo "  ci/source-soundness-gate.sh --"
            echo "    \"WHAT THE TWO FLAGS ARE FOR\": a deprecated-overload call or an unused"
            echo "      import in src/; pass the soundness argument / delete the import."
            echo "    \"IF THIS GATE ERRORS ON A LINE NOBODY TOUCHED\": a qualified"
            echo "      'export mod.sym' naming a deprecated companion; wrap that ONE export in"
            echo "      {.push warning[Deprecated]: off.} / {.pop.}. Never drop the flag."
            if [ "${target}" != "linux" ]; then
                echo "  --os:${target} is a cross-target semcheck: the offending code is likely"
                echo "  behind 'when defined(${target})' and invisible to a host-OS build."
            fi
        } >&2
        exit "${rc}"
    fi
}

# $1 = target os, $2 = main file. `--path:src` explicitly rather than relying on
# the root nim.cfg's injected `--path:"src"`, so the gate means the same thing
# regardless of CWD-relative config discovery.
gate() {
    run_pass "direct gate (nim check)" "$1" "$2" \
        nim check --hints:off \
        --os:"$1" \
        --warningAsError:Deprecated:on \
        --warningAsError:UnusedImport:on \
        --path:src "$2"
}

# Same flags, but driven through codegen so the run ALSO emits a depfiles
# manifest naming every module it semchecked. Codegen type-checks strictly more
# than `nim check`, and cross-targets on any host because --compileOnly never
# invokes a C compiler. $1 = target os.
gate_aggregator() {
    run_pass "aggregator pass (nim c --compileOnly, src/crisol.nim's whole import closure)" "$1" src/crisol.nim \
        nim c --hints:off \
        -d:nimBetterRun --compileOnly --nimcache:"${MANIFEST_DIR}/$1" \
        --os:"$1" \
        --warningAsError:Deprecated:on \
        --warningAsError:UnusedImport:on \
        --path:src src/crisol.nim
}

for target in ${TARGETS}; do
    gate_aggregator "${target}"
    for m in ${OUT_OF_CLOSURE}; do
        gate "${target}" "src/crisol/${m}.nim"
    done
done

# The per-OS backend modules under src/crisol/<area>/: process.nim and lock.nim
# pick one with `when defined(...)`, so each is reachable only on its own
# target. The matching aggregator pass above already compiles them, and these
# extra invocations are for the same direct-consumer reason as OUT_OF_CLOSURE --
# a sibling that imports `crisol/process/windows` itself gets the guarantee too.
#
# Found by GLOB, not a hardcoded list: a newly added
# `src/crisol/<area>/windows.nim` is gated the day it lands. (Hardcoded lists
# are exactly what drifted in R5-11.) The `linux`/`posix` backends need no entry
# here -- they are in the --os:linux aggregator closure already.
for f in src/crisol/*/windows.nim; do
    if [ -e "${f}" ]; then gate windows "${f}"; fi
done
for f in src/crisol/*/darwin.nim; do
    if [ -e "${f}" ]; then gate macosx "${f}"; fi
done


# ---------------------------------------------------------------------------
# COVERAGE ASSERTION (R5-11): every .nim under src/ is in at least one pass
# ---------------------------------------------------------------------------
# Everything above is a set of invocations chosen by hand. This closes the loop:
# it re-derives which modules those invocations actually semchecked and fails if
# any file under src/ is in none of them. The failure it exists to catch is a new
# module landing out of src/crisol.nim's closure on all three targets and not
# named in OUT_OF_CLOSURE -- in no gate at all, with every existing check still
# green and the header still claiming full coverage.
#
# Coverage is credited CONSERVATIVELY: an explicitly gated main file counts only
# for itself, never for its own closure. So the check can over-report (name a
# module that some secondary pass does in fact compile) but cannot under-report.
# A false alarm costs one line in OUT_OF_CLOSURE; a false pass costs R5-2.
#
# python3 is required rather than optional. A coverage check that skips itself
# when a tool is missing is the same darkness class ci/assert-subset-honesty.sh
# exists to audit: it would report success having verified nothing.
if ! command -v python3 >/dev/null 2>&1; then
    echo "source-soundness-gate: python3 not found; the coverage assertion cannot run." >&2
    echo "  Refusing to report success on a partial gate (R5-11)." >&2
    exit 2
fi

GATED_MAINS=""
for m in ${OUT_OF_CLOSURE}; do
    GATED_MAINS="${GATED_MAINS} src/crisol/${m}.nim"
done
for f in src/crisol/*/windows.nim src/crisol/*/darwin.nim; do
    if [ -e "${f}" ]; then GATED_MAINS="${GATED_MAINS} ${f}"; fi
done

MANIFEST_DIR="${MANIFEST_DIR}" GATED_MAINS="${GATED_MAINS}" TARGETS="${TARGETS}" \
    python3 ci/assert-gate-coverage.py
echo "OK: src/ is clean on linux, windows and macosx — zero deprecated-overload calls, zero unused imports"
