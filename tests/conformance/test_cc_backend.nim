## test_cc_backend.nim — wiring-audit W2: the C backend this build actually
## used, asserted rather than assumed.
##
## The windows CI leg is the MSVC leg. It becomes one by a shell step that
## APPENDS `cc = vcc` to the fetched toolchain's own `config/nim.cfg`
## (`.github/workflows/ci.yml`), and until this file existed nothing checked
## that the append took effect: the step immediately after it is *named*
## "Toolchain sanity (patched build, vcc backend)" and greps `nim --version`
## for the version string alone.
##
## That mattered because every MSVC capability in crisol dispatches on
## RUNTIME facts, never on `defined(vcc)` — `ccprobe.ccFamilyOfDriver` reads
## the manifest's driver token, `closure.ObjectExtensions` accepts both
## spellings unconditionally, `paths.classify` keys on the root's probed
## fold policy. That is the right design (a gcc-built crisol must be able to
## read a cl-produced nimcache), and its consequence is that a leg which
## silently reverted to mingw-gcc would take the GNU arm everywhere and
## PASS EVERY TEST GREEN while proving nothing about MSVC. The two files
## that are the sole CI producers for issues #21 and #23 would both go green
## for the wrong reason.
##
## The idiom here is the repo's existing one, not a new invention: like
## `CRISOL_EXPECT_FOLD` (`tests/conformance/test_rfc9_a3bii_fold_selection.nim`,
## wired at `ci.yml`'s a3bii step), an unset variable means "no claim, just
## report" and a set one turns the observation into a HARD assertion. It
## lives in `tests/conformance/` rather than in a shell step so that it runs
## inside the `ci/run-tests.sh` sweep whose log `ci/assert-subset-honesty.sh`
## audits — a bare CI-step check would sit outside the honesty regime
## entirely.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_cc_backend.nim
##   CRISOL_EXPECT_CC=vcc nim r ... tests/conformance/test_cc_backend.nim

import std/[os, strutils, unittest]

# The C compiler Nim selected for THIS build. Nim's `setCC` defines a symbol
# named for the backend whether it was chosen on the command line
# (`--cc:vcc`) or in a config file (`cc = vcc`) — verified both ways — so
# this reflects the appended toolchain config, which is precisely the
# mechanism under test.
const ActualCc* =
  when defined(vcc): "vcc"
  elif defined(clang_cl): "clang_cl"
  elif defined(clang): "clang"
  elif defined(gcc): "gcc"
  elif defined(icl): "icl"
  elif defined(icc): "icc"
  elif defined(tcc): "tcc"
  elif defined(bcc): "bcc"
  else: "unknown"

suite "wiring-audit W2 — the C backend is asserted, not assumed":

  test "this build's backend is reported, and matches CRISOL_EXPECT_CC when pinned":
    # Unconditional, so the harness log always records which backend a given
    # leg actually built with. A future regression is then visible in the log
    # even on a leg that pins nothing.
    echo "CRISOL-CC-BACKEND: " & ActualCc

    let expected = getEnv("CRISOL_EXPECT_CC").strip()
    if expected.len == 0:
      # No claim on this leg (the Linux/macOS legs build with whatever the
      # image ships). Not a skip: the report above is the real body.
      check ActualCc != "unknown"
    else:
      checkpoint "CRISOL_EXPECT_CC=" & expected & " but this build used " & ActualCc
      check ActualCc == expected

when isMainModule:
  echo "test_cc_backend done"
