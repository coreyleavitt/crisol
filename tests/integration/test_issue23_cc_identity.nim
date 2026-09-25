## tests/integration/test_issue23_cc_identity.nim — issue #23.
##
## The soundness key's C-toolchain component must IDENTIFY the toolchain that
## is actually installed here. This drives the real production accessor
## (`ccidentity.cachedCcVersion` — `$cachedCcFingerprint()`, the memoised
## probe api.nim's `planImpl`/`runTestsWith` default their `ccProbe` seam to
## and that crisol.nim's `clean` handler calls directly — with the real
## runner and no seam injected), not the seam-injectable
## derivation, because the defect is precisely that the real probe finds
## nothing on Windows and the injectable one cannot show that.
##
## ## This test CANNOT fail on Linux — take its RED in the MSVC container
##
## On POSIX `cc` and `ldd` both answer, so the fingerprint already names a real
## compiler and this file is green at HEAD. On Windows neither command exists
## under any toolchain (`where cc`, `where gcc`, `where ldd` all fail in
## `ghcr.io/coreyleavitt/nim:2.2.10-windows`), so every Windows host folds to
## the constant `<cc-unavailable>|<ldd-unavailable>` — an mingw-gcc cache entry
## and an MSVC one share a key. Same trap as issue #22's capture tests: a green
## run here proves nothing unless it ran on Windows. See
## `docs/handoff/msvc-selection-layer.md` for the container invocation.

import std/[strutils, unittest]
import crisol/ccidentity

proc ccHalfOf(fingerprint: string): string =
  ## The component before the first '|'. Deliberately hand-rolled rather than
  ## reusing `render.splitFirstPipe`: this test asserts on the PROBE's output,
  ## and must not be able to pass or fail because of a rendering change.
  let idx = fingerprint.find('|')
  if idx < 0: fingerprint else: fingerprint[0 ..< idx]

proc namesAVersion(s: string): bool =
  ## True iff `s` carries a dotted version token (digits '.' digits) — the
  ## locale-proof discriminator. A real banner has one ("cc (SUSE Linux)
  ## 16.2.0", "Microsoft (R) ... Version 19.44.35228 for x64"); a sentinel and
  ## a usage line do not.
  for i in 1 ..< s.len - 1:
    if s[i] == '.' and s[i-1] in Digits and s[i+1] in Digits:
      return true
  false

proc runtimeHalfOf(fingerprint: string): string =
  ## The component after the first '|'. Hand-rolled for the same reason as
  ## `ccHalfOf`: this asserts on the PROBE, not on `render`.
  let idx = fingerprint.find('|')
  if idx < 0: "" else: fingerprint[idx + 1 .. ^1]

proc carriesContentDigest(s: string): bool =
  ## True iff `s` ends with ` #` and sixteen hex digits -- the shape every
  ## content-fingerprinted half has (`ccidentity.realFileHash` -> `toHex16`).
  ## A sentinel (`<runtime-unidentified>`, `<artifact-unreadable>`) does not,
  ## and neither does a bare version string.
  const digestLen = 16
  if s.len < digestLen + 2: return false
  if s[s.len - digestLen - 2 .. s.len - digestLen - 1] != " #": return false
  for c in s[s.len - digestLen .. ^1]:
    if c notin HexDigits: return false
  true

suite "issue #23 — the soundness key identifies this host's C toolchain":

  test "the fingerprint's cc half names a C compiler actually installed here":
    let fingerprint = cachedCcVersion()
    let ccHalf = ccHalfOf(fingerprint)

    checkpoint("ccVersion() = " & fingerprint)

    # The whole defect in one line: on Windows this is the sentinel, so every
    # toolchain on the host produces the same soundness key.
    check ccHalf != CcSentinel
    check namesAVersion(ccHalf)

  test "the fingerprint's runtime half identifies the C runtime by content":
    ## The second half must name the C runtime library this toolchain will
    ## LINK, and carry a hash of that runtime's bytes -- not a version string
    ## alone. A version string cannot see a distro glibc backport (RFC-0006
    ## Soundness), and on Windows there is no version string to read at all:
    ## Nim+vcc links the CRT statically, so the runtime is a set of .lib files
    ## and the only thing that identifies them is their content.
    let fingerprint = cachedCcVersion()
    let runtimeHalf = runtimeHalfOf(fingerprint)

    checkpoint("runtime half = " & runtimeHalf)

    # The Windows half of the defect: this platform had no runtime probe at
    # all, so every toolchain on it folded to the same constant
    # `<ldd-unavailable>`. That sentinel no longer exists -- a value meaning
    # "we did not look" is indistinguishable, inside a soundness key, from
    # two hosts genuinely agreeing.
    check runtimeHalf != RuntimeSentinel
    check carriesContentDigest(runtimeHalf)


  test "on POSIX the cc half is content-fingerprinted too":
    ## The compiler driver's BYTES, not only its banner -- a distro that
    ## rebuilds gcc with a codegen fix and moves no version string still
    ## invalidates. Proven here through the real accessor, because the
    ## driver is resolved with `findExe` and no seam intercepts that.
    ##
    ## POSIX only, deliberately. Windows uses `cdVersionOnly`: which drivers
    ## answer there depends on whether the shell is a Developer Command
    ## Prompt, so a per-driver hash would make the key shell-dependent. See
    ## `WindowsCcProfile`.
    when defined(posix):
      check carriesContentDigest(ccHalfOf(cachedCcVersion()))
    else:
      # RFC-0009 S5 wiring-audit convention: a per-test skip() (the suite's
      # other two tests keep running for real on Windows) must emit the
      # CRISOL-SKIP-TEST marker, not vanish silently -- see
      # ci/assert-subset-honesty.sh's EXPECTED_SKIP_TEST manifest.
      echo "CRISOL-SKIP-TEST: tests/integration/test_issue23_cc_identity.nim#posix_cc_half_content_fingerprint"
      skip()


when isMainModule:
  echo "test_issue23_cc_identity done"
