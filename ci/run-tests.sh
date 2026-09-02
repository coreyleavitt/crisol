#!/usr/bin/env bash
# ci/run-tests.sh — honest-exit wrapper around `nimble test` (rfc-0007 slice A0).
#
# WHY THIS EXISTS: nimble 0.22.2's custom-task dispatch does NOT propagate a
# failing task into a nonzero process exit code. Concretely (verified by
# reading nimble.nim/nimscriptwrapper.nim/nimscriptexecutor.nim/common.nim at
# tag v0.22.2, and reproduced with a two-line throwaway task):
#
#   - A failing custom task's underlying `nim e <task>.nims` subprocess DOES
#     exit nonzero (confirmed directly with `nim e` on a `quit(1)` script).
#   - nimscriptwrapper.execScript sees that nonzero subprocess exit and raises
#     `nimbleError(...)`, i.e. a `NimbleError = object of CatchableError`.
#   - nimble.nim's `when isMainModule` block only turns an exception into a
#     nonzero `exitCode` via `except NimbleQuit as quit: exitCode = quit.exitCode`.
#     `NimbleQuit = object of Defect` is raised solely by nimble's own
#     built-in commands (e.g. `check()`) — never reachable from inside a
#     NimScript task body. The generic `except CatchableError as error:`
#     branch that actually catches our task's failure prints the error but
#     never assigns `exitCode`, which therefore stays QuitSuccess (0).
#
#   Net effect: `nimble test` (as a custom task) ALWAYS exits 0 at the
#   process level, no matter what the task itself does — quit(1) included.
#   This is a nimble defect, not a crisol.nimble bug, and it is NOT specific
#   to crisol's task logic.
#
# WORKAROUND: crisol.nimble's `test` task writes an explicit "OK"/"FAIL"
# marker file (.crisol-test-result, gitignored) as its last action before
# quitting. This script runs `nimble test`, deliberately ignores nimble's own
# unreliable exit code, and derives the real exit code from the marker file.
# A missing marker (nimble crashed before the task ran to completion, the
# .nimble file itself fails to parse, etc.) is treated as failure —
# fail-closed, never a false pass.
#
# Runs inside the toolchain container (nim/nimble only exist there). Used by
# `./dev test`, `./dev timing`, and every CI step that would otherwise run
# `nimble test` directly.

set -uo pipefail

MARKER=".crisol-test-result"
rm -f "${MARKER}"

nimble test
# Intentionally ignore nimble's own exit code here — see header. The marker
# file is the only trustworthy signal.

if [ -f "${MARKER}" ] && [ "$(cat "${MARKER}")" = "OK" ]; then
    rm -f "${MARKER}"
    exit 0
else
    rm -f "${MARKER}"
    echo "run-tests.sh: FAIL (no OK marker from crisol.nimble's test task — see output above)" >&2
    exit 1
fi
