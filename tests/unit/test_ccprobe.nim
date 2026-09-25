## test_ccprobe.nim -- unit tests for BOTH halves of the old ccprobe.nim
## (RFC-0004, A2-pre): CR7 (code review 2026-09-21) split that module into
## `crisol/ccidentity` (cc toolchain/runtime IDENTITY) and `crisol/ccprobe`
## (cc dependency-header PROBING), but kept this one physical test file for
## both -- see the import block below for why.
##
## Almost every test here is synthetic: it injects a fake `run` seam that
## returns hard-coded strings, a fake hash seam, and (for the Windows
## profile) a canned linker trace, so no real `cc`, `ldd` or `vccexe`
## process is spawned. Those suites therefore run on BOTH platforms, which
## issue #23 slice 7 made true: this file used to sit inside one file-wide
## `when defined(posix)` and ran ZERO assertions on Windows -- including the
## two suites whose entire subject is how a Windows toolchain keys.
##
## Only the last three suites stay POSIX-gated, at the bottom, because they
## touch the real environment: 3f needs a `cc` that actually resolves on PATH
## (the driver is found with `findExe`, which no seam intercepts), and 4 and 5
## run binaries at absolute POSIX paths to pin process behaviour.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_ccprobe.nim

import std/[os, unittest, sequtils, strutils]
import crisol/ccidentity  # CR7: cc-identity half of the old ccprobe.nim --
                           # ccVersion/PosixCcProfile/WindowsCcProfile/
                           # FileHashSentinel/etc.
import crisol/ccprobe     # CR7: cc-dependency-probing half of the old
                           # ccprobe.nim -- ccFamilyOfDriver/deriveDepInvocation/
                           # depIncludeHeaders/parseCcMDeps/etc. This file keeps
                           # BOTH concerns' tests in one physical file rather
                           # than splitting to mirror the source split: the
                           # `when not defined(posix):` block at the bottom of
                           # this file (unchanged, per this repo's own
                           # constraint) emits four CRISOL-SKIP-TEST markers
                           # whose `tests/unit/test_ccprobe.nim#...` paths are
                           # pinned VERBATIM in ci/assert-subset-honesty.sh,
                           # which this fix may not edit. One of those four
                           # (`#cc_half_content_fingerprint_realenv`) names a
                           # cc-IDENTITY suite; moving identity tests to a new
                           # tests/unit/test_ccidentity.nim would have moved
                           # that suite out from under its own pinned marker
                           # path. Keeping this a single file sidesteps that
                           # entirely -- no marker needed to move.
import crisol/toolrun      # CR7: RunProc/realRun/realRunMerged/realRunIn/
                           # lastProbeStderr -- the process-execution seam,
                           # exercised directly by this file's own posix-only
                           # seam suites (below).
import crisol/paths     # CR10: ReportedPath -- depIncludeHeaders/parseCcMDeps
                         # now yield this type; tests unwrap via string(...)/
                         # mapIt for comparison against plain string literals.
import crisol/closure  # CR9: ccCmdOutputObj, driven from the same ccCmd
                        # fixtures as ccprobe.deriveDepInvocation, so the two
                        # can no longer disagree about the GNU -o grammar
                        # without a test catching it

# ---------------------------------------------------------------------------
# Seam helpers
# ---------------------------------------------------------------------------

const
  TestLibcPath = "/usr/lib64/libc.so.6"
  TestDigest   = "aaaaaaaaaaaaaaaa"

proc makeFixedHash(digest: string): BinHashProc =
  ## A hash seam returning `digest` for any non-empty path, so a test can
  ## vary an artifact's CONTENT without putting bytes on disk. An empty path
  ## still degrades, because that is a real outcome the probe must handle.
  result = proc(path: string): string =
    if path.len == 0: FileHashSentinel else: digest

proc makeRun(ccOut: string, ccOk: bool,
             lddOut: string, lddOk: bool): RunProc =
  ## Synthetic output keyed by command name. `cc` answers both of the things
  ## the POSIX profile asks it: `--version`, and `-print-file-name=` for the
  ## runtime artifact's location.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cc":
      if args.len > 0 and args[0].startsWith("-print-file-name="):
        (output: TestLibcPath, ok: ccOk)
      else:
        (output: ccOut, ok: ccOk)
    of "ldd":
      (output: lddOut, ok: lddOk)
    else:
      (output: "", ok: false)

proc posixFp(run: RunProc; digest = TestDigest): string =
  ## `ccVersion` under the POSIX profile with a deterministic hash seam.
  ccVersion(run, PosixCcProfile, makeFixedHash(digest))

proc makeLinkProbe(output: string): LinkProbeProc =
  ## A canned `link /VERBOSE:LIB` trace. Every Windows-profile test supplies
  ## one: the default probe writes a translation unit to a scratch
  ## directory and spawns `vccexe`, which a unit test must never do.
  result = proc(): string = output

proc winFp(run: RunProc; linkOut = ""; digest = TestDigest): string =
  ## `ccVersion` under the WINDOWS profile, fully sealed -- no process, no
  ## disk. `linkOut = ""` models a host where the linker probe could not
  ## run at all, which is what the compiler-half suites want.
  ccVersion(run, WindowsCcProfile, makeFixedHash(digest),
            makeLinkProbe(linkOut))

proc driverDigestFor(digest: string): string =
  ## The compiler driver's content hash AS THE SEAM WILL REPORT IT here:
  ## the injected digest when `cc` resolves on PATH, `FileHashSentinel`
  ## when it does not. Computed rather than assumed, so this suite states
  ## the same fact on a host that has no `cc` -- the driver is resolved
  ## with the real `findExe` (the `nimprobe.resolveNimBin` idiom), which no
  ## seam intercepts.
  if resolveDriver("cc").len > 0: digest else: FileHashSentinel

proc expectFp(cc, runtimeLabel: string; digest = TestDigest): string =
  ## The fingerprint's shape, in one place:
  ## `<cc> #<driver hash>|<runtime text> #<runtime hash>`.
  ##
  ## RFC-0004 originally specified the second segment as `ldd --version`'s
  ## first line alone. Issue #23 changed it to carry a CONTENT hash of the
  ## runtime artifact as well, because a distro backport patches
  ## `libc.so.6` without moving the version `ldd` reports. The expectations
  ## below are written through this helper so the shape change is visible in
  ## one place rather than smeared over twenty string literals.
  cc & " #" & driverDigestFor(digest) & "|" & runtimeLabel & " #" & digest

# ---------------------------------------------------------------------------
# Suite 1: normal operation — both probes succeed
# ---------------------------------------------------------------------------

suite "ccVersion — both probes succeed":

  test "combines the cc version line and the runtime identity with '|'":
    let run = makeRun(
      "gcc (GCC) 13.2.0\nCopyright (C) ...",  true,
      "ldd (GNU libc) 2.38\nCopyright (C) ...", true)
    check posixFp(run) == expectFp("gcc (GCC) 13.2.0", "ldd (GNU libc) 2.38")

  test "takes only the version line of a multi-line compiler banner":
    let ccBanner = "cc (Ubuntu 12.3.0-1ubuntu1~22.04) 12.3.0\n" &
                   "Copyright (C) 2022 Free Software Foundation, Inc.\n" &
                   "This is free software; see the source for copying conditions."
    let lddBanner = "ldd (Ubuntu GLIBC 2.35-0ubuntu3.7) 2.35\n" &
                    "Copyright (C) 2022 Free Software Foundation, Inc."
    check posixFp(makeRun(ccBanner, true, lddBanner, true)) ==
          expectFp("cc (Ubuntu 12.3.0-1ubuntu1~22.04) 12.3.0",
                   "ldd (Ubuntu GLIBC 2.35-0ubuntu3.7) 2.35")

  test "trims trailing whitespace and newlines from each version line":
    let run = makeRun(
      "gcc (GCC) 13.2.0  \n",  true,
      "ldd (GNU libc) 2.38  \n", true)
    let v = posixFp(run)
    check v == expectFp("gcc (GCC) 13.2.0", "ldd (GNU libc) 2.38")
    check not v.endsWith(" ")
    check not v.endsWith("\n")

  test "trims leading whitespace from each version line":
    let run = makeRun(
      "  gcc (GCC) 13.2.0\n",  true,
      "  ldd (GNU libc) 2.38\n", true)
    check posixFp(run) == expectFp("gcc (GCC) 13.2.0", "ldd (GNU libc) 2.38")

# ---------------------------------------------------------------------------
# Suite 2: graceful degradation when probes fail
# ---------------------------------------------------------------------------

suite "ccVersion — probe failures yield sentinels":

  test "cc probe failure (ok=false) substitutes CcSentinel, runtime survives":
    ## `cc` failing takes the artifact lookup down with it — it is the same
    ## driver — so the runtime keeps only the text `ldd` supplied.
    let v = posixFp(makeRun("", false, "ldd (GNU libc) 2.38", true))
    check v == CcSentinel & "|ldd (GNU libc) 2.38 #" & FileHashSentinel
    check v.len > 0

  test "ldd missing (musl, or a Windows-hosted gcc) still identifies the runtime":
    ## The behaviour that replaced a sentinel-on-failure: no version text,
    ## but the artifact is still resolved and hashed, so the fingerprint
    ## still moves when the runtime's BYTES move. That is the whole point of
    ## content-addressing this half.
    let v = posixFp(makeRun("gcc (GCC) 13.2.0", true, "", false))
    check v == expectFp("gcc (GCC) 13.2.0", LibcArtifact)
    check v.len > 0

  test "nothing answers at all → a clearly-unidentified, stable, non-empty string":
    let v = posixFp(makeRun("", false, "", false))
    check v == CcSentinel & "|" & RuntimeSentinel
    check v.len > 0

  test "cc probe succeeds but returns empty output → CcSentinel substituted":
    let v = posixFp(makeRun("", true, "ldd (GNU libc) 2.38", true))
    check v == CcSentinel & "|ldd (GNU libc) 2.38 #" & TestDigest

  test "ldd probe succeeds but returns empty output → artifact name stands in":
    let v = posixFp(makeRun("gcc (GCC) 13.2.0", true, "", true))
    check v == expectFp("gcc (GCC) 13.2.0", LibcArtifact)

# ---------------------------------------------------------------------------
# Suite 3: determinism
# ---------------------------------------------------------------------------

suite "ccVersion — determinism":

  test "same inputs → identical output (pure function of injected output)":
    let run = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    check posixFp(run) == posixFp(run)

  test "different cc version output → different fingerprint":
    let run1 = makeRun("gcc (GCC) 12.0.0", true, "ldd (GNU libc) 2.38", true)
    let run2 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    check posixFp(run1) != posixFp(run2)

  test "different ldd version output → different fingerprint":
    let run1 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.35", true)
    let run2 = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
    check posixFp(run1) != posixFp(run2)

  test "output with only whitespace/newline lines → sentinel substituted":
    ## A probe that returns only blank lines should be treated as empty output.
    let v = posixFp(makeRun("   \n  \n", true, "ldd (GNU libc) 2.38", true))
    check v == CcSentinel & "|ldd (GNU libc) 2.38 #" & TestDigest

# ---------------------------------------------------------------------------
# Suite 3b: cross-toolchain separation on Windows (issue #23)
# ---------------------------------------------------------------------------
##
## Issue #21's design notes assert that "gcc-closure and cl-closure results
## key apart by construction". That premise is what this suite pins. It was
## false on Windows: neither `cc` nor `ldd` exists there under any toolchain,
## so every Windows host folded to `<cc-unavailable>|<ldd-unavailable>` and an
## mingw-built cache entry shared a soundness key with an MSVC-built one.
##
## Driven through the seam with the WINDOWS candidate set, so the behaviour is
## exercised on every platform rather than only in the MSVC container. The
## container still owns the end-to-end proof
## (`tests/integration/test_issue23_cc_identity.nim`); this owns the property.

proc makeMsvcRun(): RunProc =
  ## A host with Visual Studio and no GNU toolchain. `cl` and `vccexe` both
  ## answer, with the SAME banner — measured shape: banner on stderr, usage
  ## line on stdout, exit 0, which `realRunMerged` delivers as one string.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe":
      (output: "Microsoft (R) C/C++ Optimizing Compiler Version " &
               "19.44.35228 for x64\n" &
               "Copyright (C) Microsoft Corporation.  All rights reserved.\n" &
               "usage: cl [ option... ] filename... [ /link linkoption... ]",
       ok: true)
    else:
      (output: "", ok: false)

proc makeMingwRun(): RunProc =
  ## A host with mingw and no Visual Studio: `gcc` answers, `cl`/`vccexe` do
  ## not, and there is still no `cc` and no `ldd`.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "gcc":
      (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
               "Copyright (C) 2023 Free Software Foundation, Inc.",
       ok: true)
    else:
      (output: "", ok: false)

suite "ccVersion — Windows toolchains key apart":

  test "an MSVC host and a mingw host produce different fingerprints":
    let msvc  = winFp(makeMsvcRun())
    let mingw = winFp(makeMingwRun())
    checkpoint("msvc  = " & msvc)
    checkpoint("mingw = " & mingw)
    check msvc != mingw

  test "neither collapses to the all-sentinel constant":
    ## The defect stated exactly: before this, BOTH of these were
    ## "<cc-unavailable>|<ldd-unavailable>" and therefore equal.
    let blind = CcSentinel & "|" & RuntimeSentinel
    check winFp(makeMsvcRun())  != blind
    check winFp(makeMingwRun()) != blind

# ---------------------------------------------------------------------------
# Suite 3c: banner extraction is content-selected (issue #23)
# ---------------------------------------------------------------------------
##
## Two properties that a "take the first line" rule cannot have.
##
## ORDERING. The version probe merges the child's stderr into its stdout,
## because a compiler's banner has no fixed stream (cl writes its banner to
## stderr and its usage line to stdout; gcc writes its banner to stdout).
## Which of the two pipes lands first in the merged stream is a buffering
## detail of the child, not a contract — assuming one is precisely the
## mistake issue #22 was.
##
## LOCALE. cl's banner is translated in a localized Visual Studio. Matching
## on "Microsoft" or "Compiler" is the trap CMake ships a whole probe to work
## around for `/showIncludes`. The version NUMBER survives translation.

proc makeSingleDriverRun(driver, output: string): RunProc =
  ## Only `driver` answers; every other candidate (and `ldd`) fails.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    if cmd == driver: (output: output, ok: true)
    else:             (output: "", ok: false)

suite "ccVersion — the banner is found by content, not by position":

  test "the version is found when the usage line arrives first":
    let merged = "usage: cl [ option... ] filename... [ /link linkoption... ]\n" &
                 "Microsoft (R) C/C++ Optimizing Compiler Version " &
                 "19.44.35228 for x64\n" &
                 "Copyright (C) Microsoft Corporation.  All rights reserved."
    let v = winFp(makeSingleDriverRun("cl", merged))
    check v.startsWith("Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228")

  test "a localized banner still yields its version":
    ## Not one English token to key on — only the version number.
    let merged = "使用法: cl [ オプション... ] ファイル名...\n" &
                 "Microsoft (R) C/C++ Optimizing Compiler Version " &
                 "19.44.35228 (x64) 用コンパイラ\n" &
                 "著作権 (C) Microsoft Corporation.  All rights reserved."
    let v = winFp(makeSingleDriverRun("cl", merged))
    check "19.44.35228" in v
    check not v.startsWith("使用法")

  test "two toolsets differing only in version still key apart":
    ## The point of extracting the version line rather than any line: the
    ## fingerprint has to move when the toolset moves.
    let older = "usage: cl [ option... ]\n" &
                "Microsoft (R) C/C++ Optimizing Compiler Version 19.29.30153 for x64"
    let newer = "usage: cl [ option... ]\n" &
                "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64"
    check winFp(makeSingleDriverRun("cl", older)) !=
          winFp(makeSingleDriverRun("cl", newer))

  test "versionLine survives CRLF-terminated banner lines (CR14)":
    ## `versionLine` is one of the four parsers CR14's CRLF audit named as
    ## CRLF-safe BY DESIGN (`splitLines()` + `.strip()`) rather than by
    ## incidental tolerance. Under `WindowsCcProfile` (`cdVersionOnly`) the
    ## line is now selected by `bannerLine`, which uses the same idiom, so
    ## this pins THAT selector: a future narrowing of its `.strip()` -- the
    ## exact regression CR14 worries about -- fails here. `versionLine`'s own
    ## `.strip()` is reached only under `cdVersionAndBinary` (the POSIX profile).
    let merged = "usage: cl [ option... ]\r\n" &
                 "Microsoft (R) C/C++ Optimizing Compiler Version " &
                 "19.44.35228 for x64\r\n" &
                 "Copyright (C) Microsoft Corporation.  All rights reserved.\r\n"
    let v = winFp(makeSingleDriverRun("cl", merged))
    check v.startsWith("Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228")

# ---------------------------------------------------------------------------
# Suite 3c-ii: ok=true with no usable version text is a real degraded state,
# on the WINDOWS arm specifically (CR13, code review 2026-09-21)
# ---------------------------------------------------------------------------
##
## `ccIdentity` does NOT treat `ok=true` with no extractable version line like
## `ok=false` on this arm: under `cdVersionOnly` it fails
## `namesCompilerVersion`, sets `sawUnidentifiable`, and degrades the whole
## half to `cfsUnavailable` (R4-1/R5-5), while `not ok` is still dropped
## silently. Nothing exercised that Windows candidate shape before this
## suite (CR13). `makeMsvcRun`/`makeMingwRun`
## above only ever model "not found" (`ok=false`); the handoff measured a
## real driver that exits 0 and answers with nothing usable at all
## (`vccexe.exe /Zs --platform:amd64 /nologo /Qzzzbogus unit.c` -> rc=0,
## stdout="unit.c\n", the real diagnostic on stderr where `ccIdentity`'s
## version probe never looks). A regression narrowing this handling on the
## Windows arm specifically would ship undetected without a test that
## actually exercises it there.
##
## Asserted on the STRUCTURED `CcHalf` (`ccIdentity`'s own return value),
## never just a rendered string shape -- the point is to pin the
## `cfsUnavailable`/`cfsKnown` discriminant itself.

suite "ccIdentity (Windows) — ok=true with no usable text is a real degraded state (CR13)":

  test "ok=true with EMPTY output degrades to cfsUnavailable, not a hollow cfsKnown":
    let half = ccIdentity(makeSingleDriverRun("cl", ""), WindowsCcProfile,
                          makeFixedHash(TestDigest))
    check half.state == cfsUnavailable

  test "ok=true with ONLY whitespace/newlines also degrades to cfsUnavailable":
    let half = ccIdentity(makeSingleDriverRun("cl", "   \r\n  \r\n"), WindowsCcProfile,
                          makeFixedHash(TestDigest))
    check half.state == cfsUnavailable

  test "ok=true with a bare source-filename banner degrades to cfsUnavailable (R3-1)":
    ## Measured against real cl (docs/handoff/msvc-selection-layer.md #23):
    ## a driver can exit 0 and write only the source's own basename to
    ## stdout, with no version token anywhere in it. `versionLine` has no way
    ## to tell "the compiler's own source-name echo" apart from a genuine
    ## one-line banner once `hasDottedVersion` fails to match -- its fallback
    ## unconditionally takes the first non-blank line.
    ##
    ## This test previously pinned the CONSEQUENCE of that as characterized
    ## behaviour (a `cfsKnown` half whose "identity" text was the bare
    ## filename), explicitly stating it was "what the code does today, not a
    ## claim that it is the right answer", because `versionLine`/`ccIdentity`
    ## were outside the owning fix's surface. The round-3 review made it the
    ## right answer: under `cdVersionOnly` the compiler half carries no content
    ## digest, so text that identifies nothing is dropped from the fold
    ## (R3-1), and a host where no candidate is identifiable now reaches
    ## `cfsUnavailable` honestly instead of publishing a hollow `cfsKnown` to
    ## the shared tier.
    let half = ccIdentity(makeSingleDriverRun("cl", "unit.c\n"), WindowsCcProfile,
                          makeFixedHash(TestDigest))
    check half.state == cfsUnavailable

  test "ONE versioned driver does not launder an unversioned sibling -- the HALF degrades (R4-1)":
    ## The laundering case, and the reason the check lives at the producer
    ## rather than in `toolchainUnsound`: `ccIdentity` folds every surviving
    ## candidate line with "; " BEFORE the predicate sees anything, so an
    ## existential check over the joined text lets one honest driver vouch for
    ## every other driver's output. Real trigger (security lens, round 3):
    ## `CL=/nologo` in the environment makes a real `cl` print
    ## `D8003 : missing source filename` -- and the probes inherit the parent
    ## env -- while windows-latest also ships mingw `gcc`. (R7-S1, round-7
    ## review: that cl EXITS 2, not 0 -- measured with `!ERRORLEVEL!`; the
    ## rc=0 on record was a parse-time `%ERRORLEVEL%` expansion. This fixture
    ## keeps `ok = true` because it pins the "answered with exit 0 and no
    ## banner" arm; the real exit-2 shape is pinned in
    ## `test_cc_banner_selection.nim`'s R7-S1 suite.)
    ##
    ## WHAT THIS TEST USED TO ASSERT, AND WHY IT WAS TOO WEAK (R4-1, round-4
    ## review 2026-09-24). It checked `half.state == cfsKnown`, `"13.2.0" in
    ## half.text` and `"D8003" notin half.text` -- i.e. it ACCEPTED a half that
    ## names a BYSTANDER. Dropping cl's line from the fold does not make the
    ## remaining text describe the toolchain: on this host `cc = vcc`, so MSVC
    ## compiles and mingw gcc merely happens to be installed. A `cfsKnown` half
    ## carrying only gcc's banner leaves `toolchainUnsound` false, and the run
    ## publishes to the SHARED L2 tier under a key that says nothing about the
    ## compiler that produced the artifact -- the exact cross-host
    ## under-invalidation the R3-1 filter was added to close. The old assertion
    ## therefore pinned the defect in place.
    ##
    ## The STRONGER property, asserted below: a driver that ANSWERS (`ok`) and
    ## will not name a version is positive evidence that the probe cannot
    ## enumerate this host's toolchain, so the whole half degrades to
    ## `cfsUnavailable` no matter how many siblings did identify themselves.
    ## Over-invalidation costs one cache miss; under-invalidation poisons a
    ## tier shared across hosts.
    let run = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      case cmd
      of "cl", "vccexe":
        (output: "cl : Command line error D8003 : missing source filename\n", ok: true)
      of "gcc":
        (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n", ok: true)
      else:
        (output: "", ok: false)
    let half = ccIdentity(run, WindowsCcProfile, makeFixedHash(TestDigest))
    check half.state == cfsUnavailable
    # `cfsUnavailable` is a case-object branch with no `text` field at all, so
    # there is nothing left to assert about the banner -- "the half does not
    # name gcc" is enforced by the TYPE here, not by a string check. The
    # end-to-end consequence (`toolchainUnsound` -> no L2 publish) is pinned in
    # suite 3c-iii below, which runs the whole `ccVersion` derivation.

  test "a healthy multi-compiler host is NOT degraded and still carries every banner (R4-1 control)":
    ## The over-correction guard on the answering side. Visual Studio AND mingw
    ## AND clang, every one of them answering with a real version banner: the
    ## half must stay `cfsKnown` and fold ALL of them, exactly as
    ## `WindowsCcCandidates` intends ("every distinct answer is folded in --
    ## deliberately not first-match-wins"). If R4-1's degrade fired on anything
    ## other than an unidentifiable ANSWER, this host -- the ordinary
    ## windows-latest shape -- would stop publishing to the cache entirely.
    let run = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      case cmd
      of "cl", "vccexe":
        (output: "Microsoft (R) C/C++ Optimizing Compiler Version " &
                 "19.44.35228 for x64\n" &
                 "Copyright (C) Microsoft Corporation.  All rights reserved.\n" &
                 "usage: cl [ option... ] filename... [ /link linkoption... ]",
         ok: true)
      of "gcc":
        (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
                 "Copyright (C) 2023 Free Software Foundation, Inc.", ok: true)
      of "clang":
        (output: "clang version 17.0.6\n" &
                 "Target: x86_64-pc-windows-msvc", ok: true)
      else:
        (output: "", ok: false)
    let half = ccIdentity(run, WindowsCcProfile, makeFixedHash(TestDigest))
    check half.state == cfsKnown
    checkpoint("text = " & half.text)
    check "19.44.35228" in half.text
    check "13.2.0" in half.text
    check "17.0.6" in half.text
    # Three folded entries, not four: `cl` and `vccexe` return byte-identical
    # banners and dedup on TEXT, which is what keeps one toolchain on one key
    # whether or not crisol was launched from a Developer Command Prompt.
    check half.text.split("; ").len == 3

  test "an ABSENT candidate (ok=false) is still dropped silently, banner and all (R4-1 control)":
    ## The over-correction guard on the FAILING side, and the one that matters
    ## most: `WindowsCcCandidates` asks five drivers precisely because it does
    ## not know which exist, so on EVERY real host most of them fail. If R4-1's
    ## degrade were placed before the `not ok` check -- or keyed on "no version
    ## token in the output" rather than on "a successful answer with no version
    ## token" -- no Windows host would ever publish again.
    ##
    ## Written so it genuinely exercises the `not ok` path rather than merely
    ## co-existing with it:
    ##   - the absent drivers are RECORDED as asked, so the assertion below
    ##     proves the seam was called for them and answered `ok = false` (a
    ##     candidate list that silently stopped asking would fail here);
    ##   - their failure output is EMPTY, which is what the real seam returns
    ##     for a driver that is not on PATH (R7-S1, round-7 review: measured
    ##     through `realRunMerged` in the MSVC image -- spawn failure is
    ##     `ok = false` with output `""`). This fixture used to answer "bash:
    ##     gcc: command not found", a shell's reply the no-shell seam never
    ##     produces; since R7-S1, `ok = false` WITH output is a driver that was
    ##     spawned and exited non-zero -- present, not absent. See `ccIdentity`
    ##     and `tests/integration/test_r7_probe_presence_contract.nim`.
    var asked: seq[string] = @[]
    var failedFor: seq[string] = @[]
    let run = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      asked.add cmd
      case cmd
      of "cl", "vccexe":
        (output: "Microsoft (R) C/C++ Optimizing Compiler Version " &
                 "19.44.35228 for x64", ok: true)
      else:
        failedFor.add cmd
        (output: "", ok: false)
    let half = ccIdentity(run, WindowsCcProfile, makeFixedHash(TestDigest))
    checkpoint("asked = " & $asked & "  failed = " & $failedFor)
    check asked == @["cl", "vccexe", "gcc", "clang", "cc"]
    check failedFor == @["gcc", "clang", "cc"]   # the not-ok path really ran
    check half.state == cfsKnown
    check "19.44.35228" in half.text
    check not half.answeredUnidentified

# ---------------------------------------------------------------------------
# Suite 3d: the runtime half is a CONTENT fingerprint (issue #23)
# ---------------------------------------------------------------------------
##
## RFC-0004 defined this half as `ldd --version`'s first line. A version
## string cannot see a distro backport: RHEL and Debian both ship glibc
## patches that change `libc.so.6` without moving the version `ldd` reports,
## and RFC-0006 §Soundness already makes exactly this argument about headers
## — "a distro header backport that patches a struct layout without moving a
## version string must invalidate". So the old definition was a live
## soundness hole on LINUX, not only on Windows.
##
## The half now carries the version text AND a content hash of the artifact
## the driver says it will link — the same idiom `nimprobe` already uses for
## the nim binary, and which `nimprobe`'s own module doc wrongly claims
## `ccprobe` was already using.
##
## The artifact path is obtained from the driver (`cc -print-file-name=`),
## never guessed, and only its CONTENT reaches the fingerprint — never its
## path, so two hosts that install the same glibc at different prefixes
## still agree (RFC-0005 key portability).

proc makePosixRun(ccBanner, lddBanner, libcPath: string): RunProc =
  ## A POSIX host: `cc` answers both `--version` and `-print-file-name=`,
  ## `ldd` answers `--version`.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cc":
      if args.len > 0 and args[0].startsWith("-print-file-name="):
        (output: libcPath, ok: true)
      else:
        (output: ccBanner, ok: true)
    of "ldd":
      (output: lddBanner, ok: true)
    else:
      (output: "", ok: false)

suite "ccVersion — the runtime half is a content fingerprint":

  test "two libc builds reporting the SAME ldd version still key apart":
    ## The Linux hole, stated exactly. Same compiler, same `ldd --version`
    ## text, different `libc.so.6` bytes — a distro backport.
    let run = makePosixRun("cc (GCC) 13.2.0", "ldd (GNU libc) 2.38", TestLibcPath)
    let before = ccVersion(run, PosixCcProfile, makeFixedHash("1111111111111111"))
    let after  = ccVersion(run, PosixCcProfile, makeFixedHash("2222222222222222"))
    checkpoint("before = " & before)
    checkpoint("after  = " & after)
    check before != after

  test "the ldd version text is still carried, so a miss stays legible":
    ## The hash makes it sound; the text keeps `--explain-miss` readable.
    let run = makePosixRun("cc (GCC) 13.2.0", "ldd (GNU libc) 2.38", TestLibcPath)
    let v = ccVersion(run, PosixCcProfile, makeFixedHash(TestDigest))
    check "ldd (GNU libc) 2.38" in v
    check TestDigest in v

  test "the artifact's PATH never reaches the fingerprint":
    ## Two hosts, same glibc, different install prefix. If the path leaked
    ## in, an L2 cache shared between them would miss on every entry.
    let hereRun  = makePosixRun("cc (GCC) 13.2.0", "ldd (GNU libc) 2.38",
                                "/usr/lib64/libc.so.6")
    let thereRun = makePosixRun("cc (GCC) 13.2.0", "ldd (GNU libc) 2.38",
                                "/nix/store/xxxx-glibc-2.38/lib/libc.so.6")
    check ccVersion(hereRun,  PosixCcProfile, makeFixedHash(TestDigest)) ==
          ccVersion(thereRun, PosixCcProfile, makeFixedHash(TestDigest))

  test "firstLine strips a CRLF-terminated -print-file-name= reply before it reaches hashFile (CR14)":
    ## `firstLine` (the POSIX `rpPrintFileName` arm's path extractor) is one
    ## of the four parsers CR14's CRLF audit names as CRLF-safe by design.
    ## Pinned by CAPTURING the exact path `hashFile` is called with, the same
    ## technique `libPathIn`'s CR1 fixture uses -- the runtime TEXT half never
    ## echoes the path back, so this is the only observable window onto what
    ## `firstLine` actually handed downstream.
    var seenPath = ""
    let capture = proc(path: string): string =
      seenPath = path
      TestDigest
    let run = makePosixRun("cc (GCC) 13.2.0", "ldd (GNU libc) 2.38",
                           TestLibcPath & "\r\nsome trailing D9002-style line\r\n")
    discard ccVersion(run, PosixCcProfile, capture)
    check seenPath == TestLibcPath


# ---------------------------------------------------------------------------
# Suite 3e: the MSVC runtime half is a content fingerprint (issue #23)
# ---------------------------------------------------------------------------
##
## Windows has no `ldd` and, under Nim+vcc, no libc DLL either: the CRT is
## linked STATICALLY (measured -- `dumpbin /dependents` on a `nim c --cc:vcc`
## binary lists KERNEL32.dll alone). The runtime IS a set of `.lib` files, so
## the only thing that can identify it is their content.
##
## Asking the linker rather than guessing is what closes the actual gap.
## `LIBCMT.lib` and `libvcruntime.lib` ship with the VC toolset, so cl's
## banner already moves with them -- but `libucrt.lib` ships with the WINDOWS
## SDK and is versioned independently of cl. A cl-banner-only fingerprint
## leaves precisely that library invisible.
##
## The traces below are the measured `/VERBOSE:LIB` output from
## `ghcr.io/coreyleavitt/nim:2.2.10-windows`, repeats included.

const
  MsvcVerboseTrace = """Searching libraries
    Searching C:\msvc\vc\lib\LIBCMT.lib:
    Searching C:\msvc\vc\lib\OLDNAMES.lib:
    Searching C:\msvc\sdk\lib\um\kernel32.lib:
    Searching C:\msvc\vc\lib\libvcruntime.lib:
    Searching C:\msvc\sdk\lib\ucrt\libucrt.lib:
    Searching C:\msvc\sdk\lib\um\uuid.lib:
Finished searching libraries

Searching libraries
    Searching C:\msvc\vc\lib\LIBCMT.lib:
    Searching C:\msvc\vc\lib\OLDNAMES.lib:
    Searching C:\msvc\sdk\lib\um\kernel32.lib:
    Searching C:\msvc\vc\lib\libvcruntime.lib:
    Searching C:\msvc\sdk\lib\ucrt\libucrt.lib:
    Searching C:\msvc\sdk\lib\um\uuid.lib:
Finished searching libraries

Searching libraries
    Searching C:\msvc\vc\lib\LIBCMT.lib:
    Searching C:\msvc\vc\lib\OLDNAMES.lib:
    Searching C:\msvc\sdk\lib\um\kernel32.lib:
    Searching C:\msvc\vc\lib\libvcruntime.lib:
Finished searching libraries"""

  MsvcVerboseTraceCRLF =
    "Searching libraries\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\LIBCMT.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\OLDNAMES.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\um\\kernel32.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\libvcruntime.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\ucrt\\libucrt.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\um\\uuid.lib:\r\n" &
    "Finished searching libraries"
    ## CR14 (code review 2026-09-21): a CRLF-terminated variant of
    ## `MsvcVerboseTrace`'s single-pass shape. Real Windows console/subprocess
    ## capture is typically CRLF; before this fixture, ZERO MSVC trace in this
    ## file carried a raw CR byte, so `parseVerboseLibPaths`'s
    ## `splitLines()`+`.strip()` CRLF-safety rested on nothing but design
    ## intent. Built by explicit `\r\n` concatenation rather than a raw
    ## triple-quoted string, so the CR bytes are visible in the literal
    ## rather than living in the file's own line endings.

  RelocatedTrace = """Searching libraries
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\LIBCMT.lib:
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\OLDNAMES.lib:
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\kernel32.lib:
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\libvcruntime.lib:
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\libucrt.lib:
    Searching C:\Program Files\Microsoft Visual Studio\2022\VC\lib\uuid.lib:
Finished searching libraries"""
    ## The same six libraries under a path with a SPACE in it, as a default
    ## Visual Studio install has.

  LocalizedTrace = """Suche in libraries
    Suche in C:\msvc\vc\lib\LIBCMT.lib:
    Suche in C:\msvc\vc\lib\OLDNAMES.lib:
    Suche in C:\msvc\sdk\lib\um\kernel32.lib:
    Suche in C:\msvc\vc\lib\libvcruntime.lib:
    Suche in C:\msvc\sdk\lib\ucrt\libucrt.lib:
    Suche in C:\msvc\sdk\lib\um\uuid.lib:
Finished suche in libraries"""
    ## A localized toolset translates the verb; it does not translate a
    ## drive letter or a library's name.

  UncLocalizedTrace = """Suche jetzt in libraries
    Suche jetzt in \\vcbuild\share\vc\lib\LIBCMT.lib:
    Suche jetzt in \\vcbuild\share\vc\lib\OLDNAMES.lib:
    Suche jetzt in \\vcbuild\share\sdk\lib\um\kernel32.lib:
    Suche jetzt in \\vcbuild\share\vc\lib\libvcruntime.lib:
    Suche jetzt in \\vcbuild\share\sdk\lib\ucrt\libucrt.lib:
    Suche jetzt in \\vcbuild\share\sdk\lib\um\uuid.lib:
Finished suche jetzt in libraries"""
    ## CR1 (code review 2026-09-21): a library reached over a UNC share has
    ## no drive letter and no colon at all, so `libPathIn`'s drive-letter
    ## anchor never fires for it. Combined with a TWO-OR-MORE-WORD localized
    ## verb phrase ("Suche jetzt in" -- "now searching in", modelled on
    ## `LocalizedTrace`'s one-word "Suche in"), an unfixed `libPathIn` falls
    ## to its drop-one-leading-word fallback, which strips only "Suche",
    ## leaving "jetzt in \\vcbuild\share\...": a leading garbage token in
    ## front of the path `hashFile` receives.

  UncCleanPaths = [
    r"\\vcbuild\share\vc\lib\LIBCMT.lib",
    r"\\vcbuild\share\vc\lib\OLDNAMES.lib",
    r"\\vcbuild\share\sdk\lib\um\kernel32.lib",
    r"\\vcbuild\share\vc\lib\libvcruntime.lib",
    r"\\vcbuild\share\sdk\lib\ucrt\libucrt.lib",
    r"\\vcbuild\share\sdk\lib\um\uuid.lib",
  ]
    ## The paths `UncLocalizedTrace` names, exactly as a correctly-anchored
    ## `libPathIn` must hand them to `hashFile` -- no leading verb word, no
    ## trailing colon.

proc libBase(path: string): string =
  ## Final path component, splitting on either separator -- the test's own,
  ## so it cannot pass because production and test share a helper.
  for i in countdown(path.high, 0):
    if path[i] in {'\\', '/'}: return path[i+1 .. ^1]
  path

proc makeLibHash(bumped = ""): BinHashProc =
  ## Content keyed by the library's BASENAME, so the same library at two
  ## different paths has the same content -- which is the situation two
  ## hosts running the same toolset are actually in. `bumped` names one
  ## library whose CONTENT differs, everything else being equal.
  result = proc(path: string): string =
    let name = libBase(path).toLowerAscii
    if name == bumped.toLowerAscii: "bbbbbbbbbbbbbbbb" & name
    else:                           "aaaaaaaaaaaaaaaa" & name

proc msvcFp(trace: string; bumped = ""): string =
  ccVersion(makeMsvcRun(), WindowsCcProfile, makeLibHash(bumped),
            makeLinkProbe(trace))

proc makeUncLibHash(bumped = ""): BinHashProc =
  ## Unlike `makeLibHash`, keyed on the EXACT, fully-qualified path --
  ## mirroring `realFileHash`, which opens a path or fails, and does not
  ## recover a basename from a mangled one. Only the six paths in
  ## `UncCleanPaths` resolve to content; anything else -- in particular a
  ## path still carrying a leading garbage token from a parse failure --
  ## behaves exactly as an unreadable file does and degrades to
  ## `FileHashSentinel`, same as `realFileHash`'s `except` arm for a path
  ## that does not exist. This is what makes the fixture catch CR1: an
  ## unfixed `libPathIn` hands every entry a garbage path, every entry
  ## degrades to the SAME sentinel, and two traces differing only in one
  ## library's content fold to an IDENTICAL fingerprint.
  result = proc(path: string): string =
    if path notin UncCleanPaths: return FileHashSentinel
    let name = libBase(path).toLowerAscii
    if name == bumped.toLowerAscii: "bbbbbbbbbbbbbbbb" & name
    else:                           "aaaaaaaaaaaaaaaa" & name

proc uncFp(trace: string; bumped = ""): string =
  ccVersion(makeMsvcRun(), WindowsCcProfile, makeUncLibHash(bumped),
            makeLinkProbe(trace))

suite "ccVersion — the MSVC runtime half is a content fingerprint":

  test "the libraries the linker searched are named, once each":
    ## Dedup is not tidiness: the linker repeats its search list once per
    ## resolution pass, and the number of passes is a property of the
    ## program being linked -- here, of the probe's own translation unit.
    ## Folding the repeats would make the fingerprint depend on the probe.
    let runtimeHalf = msvcFp(MsvcVerboseTrace).split('|')[1]
    checkpoint("runtime half = " & runtimeHalf)
    check runtimeHalf.startsWith(
      "kernel32+libcmt+libucrt+libvcruntime+oldnames+uuid #")
    check runtimeHalf.count("libcmt") == 1

  test "two SDKs differing only in libucrt.lib CONTENT key apart":
    ## THE property. `libucrt.lib` comes from the Windows SDK, so cl's
    ## banner is byte-identical across this change and the compiler half
    ## cannot see it. Before issue #23 the whole Windows fingerprint was a
    ## constant, and both of these were the same key.
    check msvcFp(MsvcVerboseTrace) !=
          msvcFp(MsvcVerboseTrace, bumped = "libucrt.lib")

  test "the library PATHS never reach the fingerprint":
    ## Two hosts with the same toolset installed at different prefixes --
    ## `C:\msvc` and the default `C:\Program Files\...` -- must agree, or
    ## RFC-0005's shared cache cannot be shared. This also pins that a path
    ## containing a SPACE parses: anchoring on the drive letter survives it,
    ## splitting the line on whitespace would not.
    check msvcFp(MsvcVerboseTrace) == msvcFp(RelocatedTrace)

  test "a localized linker still yields its libraries":
    ## Selected by content -- a line naming a `.lib` -- not by matching the
    ## English word "Searching". Issue #21 is the standing reminder of what
    ## matching a translated prefix costs.
    check msvcFp(LocalizedTrace) == msvcFp(MsvcVerboseTrace)

  test "a CRLF-terminated linker trace parses identically to its LF counterpart (CR14)":
    ## Pins that `parseVerboseLibPaths` is CRLF-safe BY DESIGN
    ## (`splitLines()` already separates on `\r\n`, and `.strip()` removes
    ## any leftover `\r`), not merely by incidental tolerance. A future
    ## narrowing of either has to fail this test.
    check msvcFp(MsvcVerboseTraceCRLF) == msvcFp(MsvcVerboseTrace)

  test "a UNC library path under a two-word localized verb carries no leading garbage token (CR1)":
    ## Property (a). The drive-letter anchor never fires on a UNC path --
    ## no colon, no drive letter -- so before the fix this fell to the
    ## drop-one-leading-word fallback, which a ONE-word localized verb
    ## survives (as `LocalizedTrace` proves) but a TWO-OR-MORE-word one
    ## does not. Checked directly: capture every path `hashFile` is asked
    ## to open and assert each is exactly one of `UncCleanPaths`.
    var seen: seq[string] = @[]
    let capture = proc(path: string): string =
      seen.add(path)
      FileHashSentinel
    discard ccVersion(makeMsvcRun(), WindowsCcProfile, capture,
                       makeLinkProbe(UncLocalizedTrace))
    checkpoint("paths seen = " & $seen)
    check seen.len == 6
    for p in seen:
      check p in UncCleanPaths

  test "two UNC-hosted SDKs differing only in libucrt.lib CONTENT key apart, even under a localized verb (CR1)":
    ## Property (b), the real soundness property. Before the fix every
    ## entry's path is garbage, every entry degrades to the SAME
    ## `FileHashSentinel`, and the two traces -- despite naming a
    ## genuinely different `libucrt.lib` -- fold to an IDENTICAL
    ## fingerprint: an under-invalidation soundness-key collision, the
    ## exact defect class issue #23 exists to eliminate.
    check uncFp(UncLocalizedTrace) !=
          uncFp(UncLocalizedTrace, bumped = "libucrt.lib")

  test "a linker that named nothing degrades to RuntimeSentinel":
    ## Never an empty half, and never a plausible-looking one: a probe that
    ## learned nothing has to SAY it learned nothing.
    check msvcFp("LINK : fatal error LNK1561: entry point must be defined")
            .endsWith("|" & RuntimeSentinel)


# ---------------------------------------------------------------------------
# Suite 3c-iii: a poisoned `cl` beside a versioned bystander refuses to PUBLISH
# (R4-1, round-4 review 2026-09-24)
# ---------------------------------------------------------------------------
##
## Suite 3c-ii pins the `CcHalf` discriminant at the producer. This suite pins
## the CONSEQUENCE, through the whole `ccVersion` derivation with a genuinely
## identified runtime half -- which is what makes the finding a soundness bug
## rather than a cosmetic one. `toolchainUnsound` is what
## `cachedispatch.shouldStore` consults (via `api.nim`) before publishing to the
## SHARED L2 tier, and it is reached here through the real serialization +
## `parseCcFingerprint`, not through a hand-built `CcFingerprint` literal: the
## point is that a real probe on a real host shape ends up refusing.
##
## The runtime half deliberately uses the MEASURED `MsvcVerboseTrace` above, so
## it is `cfsKnown` with a real content digest. A degenerate runtime half would
## have made `toolchainUnsound` true on its own and proved nothing about the
## compiler half.

proc makePoisonedClRun(withGcc, exitOk: bool): RunProc =
  ## The windows-latest shape the finding names. `CL=/nologo` is in the
  ## environment and the probes inherit it, so a REAL `cl` answers
  ## `Command line error D8003 : missing source filename` (no version token
  ## anywhere in it). `withGcc` adds the mingw `gcc` that windows-latest also
  ## ships -- the bystander whose banner used to be published in MSVC's place.
  ##
  ## `exitOk`: round 4 recorded that exit as 0, and it is 2 (R7-S1, round-7
  ## review, measured with `!ERRORLEVEL!` in the MSVC image). `exitOk = false`
  ## is the REAL shape; `exitOk = true` keeps the "answered with exit 0 and no
  ## banner" arm pinned, which a differently-configured driver still reaches.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe":
      (output: "cl : Command line error D8003 : missing source filename\n", ok: exitOk)
    of "gcc":
      if withGcc:
        (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
                 "Copyright (C) 2023 Free Software Foundation, Inc.", ok: true)
      else:
        (output: "", ok: false)
    else:
      (output: "", ok: false)

proc makeGccOnlyRun(): RunProc =
  ## The same host with `cl`/`vccexe` genuinely ABSENT (`ok = false`) instead of
  ## poisoned. Nothing is wrong here, so this one must still publish.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "gcc":
      (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
               "Copyright (C) 2023 Free Software Foundation, Inc.", ok: true)
    else:
      (output: "", ok: false)

proc parsedFp(run: RunProc): CcFingerprint =
  ## `ccVersion` under the Windows profile with the measured linker trace,
  ## round-tripped back through THE single parser. Fails loudly rather than
  ## silently returning a zero value if the grammar ever stops round-tripping.
  let v = ccVersion(run, WindowsCcProfile, makeLibHash(), makeLinkProbe(MsvcVerboseTrace))
  let parsed = parseCcFingerprint(v)
  doAssert parsed.ok, "fingerprint did not round-trip: " & v
  parsed.fp

suite "ccVersion — a poisoned cl beside a versioned gcc refuses to publish (R4-1)":

  test "poisoned cl + versioned mingw gcc: compiler half cfsUnavailable, toolchain UNSOUND":
    ## The reviewer's live scenario, verbatim. Before the fix this measured
    ## `compilerState: cfsKnown, digestKind: cdkNone, toolchainUnsound: false`
    ## and STORED to L2 with gcc's banner standing in for the MSVC toolset that
    ## actually compiled (`cc = vcc`).
    let fp = parsedFp(makePoisonedClRun(withGcc = true, exitOk = true))
    checkpoint("fingerprint = " & $fp)
    # The runtime half IS identified -- so nothing but the compiler half can be
    # what trips the gate. Without this the test would pass for the wrong reason.
    check fp.runtime.state == cfsKnown
    check fp.runtime.digest.kind == cdkKnown
    check fp.compiler.state == cfsUnavailable
    check toolchainUnsound(fp)            # -> shouldStore's cdmToolchainUnidentified
    # And the bystander's identity is nowhere in the serialized key.
    check "13.2.0" notin $fp
    check ($fp).startsWith(CcSentinel & "|")

  test "poisoned cl ALONE (no bystander) is unsound too -- unchanged by R4-1":
    ## The only case R3-1's original drop-and-continue already handled: with no
    ## surviving candidate, `found.len == 0` reached `ccUnavailable()` anyway.
    ## Kept as a regression guard so a future refactor cannot fix the
    ## multi-candidate case by breaking the zero-candidate one.
    let fp = parsedFp(makePoisonedClRun(withGcc = false, exitOk = true))
    check fp.compiler.state == cfsUnavailable
    check toolchainUnsound(fp)

  test "the MEASURED shape -- cl EXITS 2 -- beside a versioned gcc: UNSOUND, gcc nowhere (R7-S1)":
    ## Before R7-S1 `ccIdentity` read `ok = false` as "absent" and dropped cl,
    ## so this measured `cfsKnown` on gcc's banner and published -- the same
    ## laundering as above, reached through the exit code instead of the text.
    for withGcc in [true, false]:
      let fp = parsedFp(makePoisonedClRun(withGcc = withGcc, exitOk = false))
      checkpoint("withGcc = " & $withGcc & "  fingerprint = " & $fp)
      check fp.runtime.state == cfsKnown
      check fp.compiler.state == cfsUnavailable
      check toolchainUnsound(fp)
      check "13.2.0" notin $fp
    # The reason lives only on the probe's own value (serialization drops it --
    # see `refusedDrivers`), so ask `ccIdentity` for it directly.
    let half = ccIdentity(makePoisonedClRun(withGcc = true, exitOk = false),
                          WindowsCcProfile, makeFixedHash(TestDigest))
    check half.answeredUnidentified
    check toolchainUnsoundReason(CcFingerprint(
      compiler: half, runtime: parsedFp(makeGccOnlyRun()).runtime)) == turCompilerRefused

  test "the SAME host with cl merely absent still publishes (R4-1 control)":
    ## The discriminator: `cl`/`vccexe` failing (`ok = false`) rather than
    ## answering unidentifiably leaves a perfectly honest single-compiler host,
    ## and it must still key on gcc and publish. This is what proves the degrade
    ## above is caused by the POISONED ANSWER and not by the candidate list, the
    ## runtime trace, or the `cdVersionOnly` profile's missing driver digest.
    let fp = parsedFp(makeGccOnlyRun())
    checkpoint("fingerprint = " & $fp)
    check fp.compiler.state == cfsKnown
    check "13.2.0" in fp.compiler.text
    check not toolchainUnsound(fp)


# ---------------------------------------------------------------------------
# Suite 3c-iv: an EMPTY `ok = true` answer degrades the half even beside a
# versioned bystander (R5-5, round-5 review 2026-09-24)
# ---------------------------------------------------------------------------
##
## R4-1 put the `line.len == 0` skip BELOW its degrade check on purpose: a
## driver that exits 0 and writes its diagnostic to a stream the version probe
## never reads (measured: `vccexe.exe /Zs --platform:amd64 /nologo /Qzzzbogus
## unit.c`) is the SAME "a driver is present and will not identify itself"
## situation as one that prints unidentifiable text, not a milder one.
##
## R5-5: nothing in the tree observed that ordering. The empty-output fixtures
## that already existed (suite 3c-ii's first two tests) have NO other answering
## candidate, so `found.len == 0` reaches `ccUnavailable()` for the other reason
## and the two orderings are indistinguishable there -- hoisting the skip back
## above the check (the pre-R4-1 order, and what a tidying refactor naturally
## produces) left every suite in the tree GREEN.
##
## A VERSIONED BYSTANDER is what makes the orders differ, so these fixtures
## supply one. Hoisted, `cl` is skipped, mingw gcc's banner stands alone, the
## half stays `cfsKnown`, and the host publishes to the SHARED L2 tier under a
## compiler that did not build the artifact.

proc makeEmptyAnswerRun(clOut: string): RunProc =
  ## `cl`/`vccexe` ANSWER (`ok = true`) with `clOut` -- which has no non-empty
  ## line, so `bannerLine` returns `""` -- while the mingw `gcc` that
  ## windows-latest also ships answers with a real banner.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe":
      (output: clOut, ok: true)
    of "gcc":
      (output: "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
               "Copyright (C) 2023 Free Software Foundation, Inc.", ok: true)
    else:
      (output: "", ok: false)

suite "ccIdentity (Windows) — an empty ok=true answer degrades the half, bystander or not (R5-5)":

  test "EMPTY output (ok=true) beside a versioned mingw gcc: the WHOLE half degrades":
    let half = ccIdentity(makeEmptyAnswerRun(""), WindowsCcProfile,
                          makeFixedHash(TestDigest))
    check half.state == cfsUnavailable

  test "blank-lines-only output (ok=true) beside the same bystander: identical outcome":
    ## Same arm, reached through `bannerLine`'s own `""` return rather than
    ## through a literally empty capture.
    let half = ccIdentity(makeEmptyAnswerRun("   \r\n\t\r\n"), WindowsCcProfile,
                          makeFixedHash(TestDigest))
    check half.state == cfsUnavailable

  test "end to end: that host refuses to publish, and gcc's identity is not in the key":
    let fp = parsedFp(makeEmptyAnswerRun(""))
    checkpoint("fingerprint = " & $fp)
    # The runtime half IS identified, so only the compiler half can be the
    # trigger -- without this the test could pass for the wrong reason.
    check fp.runtime.state == cfsKnown
    check fp.runtime.digest.kind == cdkKnown
    check fp.compiler.state == cfsUnavailable
    check toolchainUnsound(fp)
    check "13.2.0" notin $fp

# ---------------------------------------------------------------------------
# Suite 3c-v: a dotted token is not a banner -- an INCIDENTAL one does not
# identify a compiler (R5-4, round-5 review 2026-09-24)
# ---------------------------------------------------------------------------
##
## R4-1 documented itself as "a candidate that answered and will not identify
## itself degrades the half" but IMPLEMENTED `not hasDottedVersion(line)`,
## where `line` is `versionLine(output)` -- and those are different sets.
## `versionLine` returns the first line carrying a dotted token IF ANY LINE
## DOES, so the implemented test only fired when no `<digit>.<digit>` appeared
## ANYWHERE in the whole capture. One incidental token was enough to pass it:
## `CL`/`_CL_` routinely carry vcpkg/Qt/Python/SDK paths, and `cl : Command
## line warning D9024` echoes the offending token back verbatim.
##
## MEASURED before the fix (real `src/`, unmutated, `WindowsCcProfile`):
##   A  poison with no dotted token + mingw gcc -> cfsUnavailable, UNSOUND true
##   B  the same poison + ONE dotted token      -> cfsKnown,       UNSOUND false
##      fingerprint: `cl : Command line warning D9024 : unrecognized source
##      file type '10.0.22621.0', object file assumed; gcc.exe (Rev3, Built by
##      MSYS2 project) 13.2.0|libcmt+libucrt+libvcruntime #<digest>`
##   D  the same poison, NO bystander           -> cfsKnown,       UNSOUND false
##
## B is R4-1's own named laundering scenario verbatim. D is worse in one way:
## the half's whole text is a pure diagnostic that cannot vary with the
## installed toolset, so two hosts with DIFFERENT MSVC toolsets fold to an
## IDENTICAL compiler half -- and both publish to the shared tier.
##
## The same token also disarmed the declared backstop: `toolchainUnsound`'s
## third disjunct tested the same `hasDottedVersion` predicate, and under
## `cdVersionOnly` there is no content digest behind it. Both sites now ask
## `namesCompilerVersion` (a banner-shaped version token AND no diagnostic
## shape). R6 (round-6 review 2026-09-24) then made the line that is SELECTED
## the line that is judged, and tightened the predicate so every line has to
## be refused on its own merits; that matrix, and one isolating fixture per
## refusal arm, live in `tests/unit/test_cc_banner_selection.nim`.

const
  PoisonedClDotted =
    "cl : Command line warning D9024 : unrecognized source file type " &
    "'10.0.22621.0', object file assumed\n"
    ## Case B/D's poison. Real shape: D9024 ECHOES the token it did not
    ## recognise, and a Windows SDK version is exactly the kind of thing a
    ## `CL`/`_CL_` environment puts there.

  PoisonedClWrapped =
    "cl : Command line warning D9024 : unrecognized source file type\n" &
    "'10.0.22621.0', object file assumed\n"
    ## The same diagnostic WRAPPED, so the continuation line carries the
    ## dotted token alone -- no `cl : ` prefix, no diagnostic code and no
    ## English diagnostic phrase on it. Under R5-4 only "the version token is
    ## QUOTED" refused it; since R6 the quote, the token's glued left and right
    ## sides all do, so this is no longer an isolating fixture -- the per-arm
    ## ones are in `tests/unit/test_cc_banner_selection.nim`.

  PoisonedClDottedDe =
    "cl : Befehlszeilenwarnung D9024 : Unbekannter Quelldateityp " &
    "'10.0.22621.0', Objektdatei wird angenommen\n"
    ## The German form: MSVC translates the PROSE and leaves the program name,
    ## the ` : ` separator and the code `D9024` alone. Pins that the refusal
    ## does not rest on English words.

  VccexeToolchainError =
    "vccexe: could not find the Microsoft Visual C++ 14.0 toolchain\n"
    ## A diagnostic whose dotted token is NOT quoted. Under R5-4 only the
    ## DIAGNOSTIC SHAPE (`vccexe: ` -- a tool-colon prefix) refused it; since
    ## R6 its two-component `14.0` is refused as well, so the isolating
    ## fixture for the prefix arm moved to
    ## `tests/unit/test_cc_banner_selection.nim`.

  MingwGccBanner =
    "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
    "Copyright (C) 2023 Free Software Foundation, Inc."

  ClBannerEn =
    "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64\n" &
    "Copyright (C) Microsoft Corporation.  All rights reserved.\n" &
    "usage: cl [ option... ] filename... [ /link linkoption... ]"

  ClBannerDe =
    "Microsoft (R) C/C++-Optimierungscompiler Version 19.44.35228 für x64\n" &
    "Copyright (C) Microsoft Corporation. Alle Rechte vorbehalten.\n" &
    "Syntax: cl [ Option... ] Dateiname... [ /link Linkeroption... ]"
    ## Fabricated but plausible: every word around the number is translated and
    ## only the digits are kept, which is precisely the invariant
    ## `hasDottedVersion` was written for. If a diagnostic-shape test ever
    ## starts resting on an English word a banner could contain, this control
    ## is what fails.

  ClBannerJa =
    "使用法: cl [ オプション... ] ファイル名...\n" &
    "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 (x64) 用コンパイラ\n" &
    "著作権 (C) Microsoft Corporation.  All rights reserved."

proc makeWinRun(clOut: string; clOk = true; gccOut = ""): RunProc =
  ## `cl`/`vccexe` answer `clOut` with `ok = clOk`; `gcc` answers `gccOut` when
  ## that is non-empty and FAILS otherwise; every other candidate fails. One
  ## fixture for the whole suite so each test differs only in the strings that
  ## the finding is about.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe":
      (output: clOut, ok: clOk)
    of "gcc":
      if gccOut.len > 0: (output: gccOut, ok: true)
      else:              (output: "", ok: false)
    else:
      (output: "", ok: false)

proc winHalf(run: RunProc): CcHalf =
  ccIdentity(run, WindowsCcProfile, makeFixedHash(TestDigest))

suite "ccIdentity (Windows) — an incidental dotted token does not identify a compiler (R5-4)":

  test "case B: a DIAGNOSTIC's echoed token + a versioned gcc -- the whole half degrades":
    ## R4-1's own laundering scenario, with the one token that used to defeat
    ## it. Nothing about this output states a compiler version; the `10.0.22621.0`
    ## in it is a Windows SDK number the diagnostic quoted back.
    check winHalf(makeWinRun(PoisonedClDotted, gccOut = MingwGccBanner)).state ==
          cfsUnavailable

  test "case B end to end: UNSOUND, and neither the bystander nor the SDK token is in the key":
    let fp = parsedFp(makeWinRun(PoisonedClDotted, gccOut = MingwGccBanner))
    checkpoint("fingerprint = " & $fp)
    check fp.runtime.state == cfsKnown       # only the compiler half can trip it
    check fp.runtime.digest.kind == cdkKnown
    check fp.compiler.state == cfsUnavailable
    check toolchainUnsound(fp)               # -> cdmToolchainUnidentified, no L2 store
    check "13.2.0" notin $fp
    check "10.0.22621.0" notin $fp

  test "case D: the same diagnostic with NO bystander degrades too -- no constant-folded key":
    ## Worse than B in one respect: this text is a pure diagnostic, so it cannot
    ## vary with the installed toolset at all. Two hosts on DIFFERENT MSVC
    ## toolsets produced the identical `cfsKnown` compiler half here and both
    ## published. Now neither does.
    let half = winHalf(makeWinRun(PoisonedClDotted))
    check half.state == cfsUnavailable
    check winFp(makeWinRun(PoisonedClDotted)).startsWith(CcSentinel & "|")

  test "a LOCALIZED diagnostic degrades too -- the anchors are punctuation and digits":
    ## Same host as case B with a German toolset. The prose is translated; the
    ## program name, the ` : ` separator and `D9024` are not, which is why the
    ## refusal survives translation.
    check winHalf(makeWinRun(PoisonedClDottedDe, gccOut = MingwGccBanner)).state ==
          cfsUnavailable

  test "an UNQUOTED version token in diagnostic-shaped text still degrades":
    ## `14.0` here is not quoted, so R5-4's "unquoted dotted token" half of the
    ## condition was satisfied and only `vccexe: ` -- a tool-colon prefix --
    ## refused it. Since R6 the two-component token is refused too, so this is
    ## a regression pin, no longer the isolating case (see
    ## `tests/unit/test_cc_banner_selection.nim` for one fixture per arm).
    check winHalf(makeWinRun(VccexeToolchainError, gccOut = MingwGccBanner)).state ==
          cfsUnavailable

  test "a QUOTED version token in otherwise unremarkable text still degrades":
    ## The dotted line is a wrapped diagnostic's continuation
    ## (`'10.0.22621.0', object file assumed`), which carries no prefix, no code
    ## and no English phrase. A regression pin since R6, when the quote and the
    ## glued token sides began refusing it independently (see
    ## `tests/unit/test_cc_banner_selection.nim` for one fixture per arm).
    check winHalf(makeWinRun(PoisonedClWrapped, gccOut = MingwGccBanner)).state ==
          cfsUnavailable

  test "CONTROL a localized cl banner is still accepted -- de and ja":
    ## The over-correction guard that matters most: locale-proofing is the whole
    ## reason `hasDottedVersion` exists, and R5-4 must not undo it. Every word
    ## around the number is translated in both of these; only the digits are
    ## invariant, and only the digits (plus punctuation) are what the condition
    ## looks at.
    for banner in [ClBannerDe, ClBannerJa]:
      let half = winHalf(makeWinRun(banner))
      checkpoint("banner = " & banner)
      check half.state == cfsKnown
      check "19.44.35228" in half.text
      # ...and it publishes: the tightened backstop disjunct must not refuse a
      # digest-less (`cdVersionOnly`) half whose text IS a real banner.
      let fp = parsedFp(makeWinRun(banner))
      check fp.compiler.state == cfsKnown
      check fp.compiler.digest.kind == cdkNone
      check not toolchainUnsound(fp)

  test "CONTROL a healthy MSVC + mingw host still folds BOTH banners and publishes":
    let half = winHalf(makeWinRun(ClBannerEn, gccOut = MingwGccBanner))
    checkpoint("text = " & half.text)
    check half.state == cfsKnown
    check "19.44.35228" in half.text
    check "13.2.0" in half.text
    check half.text.split("; ").len == 2
    check not toolchainUnsound(parsedFp(makeWinRun(ClBannerEn, gccOut = MingwGccBanner)))

  test "a cl that EXITED NON-ZERO with a dotted diagnostic is present, and refuses the half (R7-S1)":
    ## This test used to be a CONTROL asserting the opposite -- "an ABSENT
    ## candidate whose FAILURE output is a dotted diagnostic is dropped
    ## silently", on the premise that absent candidates answer `ok = false`
    ## with arbitrary stderr. Measured (R7-S1, round-7 review), that premise is
    ## false: through `realRunMerged` an absent driver is `ok = false` with
    ## EMPTY output (spawn failure), and `ok = false` WITH output is a driver
    ## that was spawned and exited non-zero -- exactly what a real cl does
    ## under a non-empty `CL`. The old assertion pinned the defect: gcc's
    ## banner stood in for the cl that compiles.
    let half = winHalf(makeWinRun(PoisonedClDotted, clOk = false,
                                  gccOut = MingwGccBanner))
    check half.state == cfsUnavailable
    check half.answeredUnidentified

  test "CONTROL a cl that is ABSENT (empty output, not ok) is still dropped silently":
    ## The half of the old control that was true: absence says nothing about
    ## the host, so gcc is believed.
    let half = winHalf(makeWinRun("", clOk = false, gccOut = MingwGccBanner))
    check half.state == cfsKnown
    check "13.2.0" in half.text
    check not half.answeredUnidentified

  test "a real banner beside a dotted diagnostic is believed in EITHER order (R6)":
    ## This test used to CHARACTERIZE the opposite: selection was `versionLine`
    ## (first dotted line), so banner-first was believed and warning-first
    ## refused -- the verdict rested on which of two merged pipes flushed
    ## first, the positional dependence issue #22 exists to remove. R6 selects
    ## BY the acceptor (`bannerLine`), so the banner line is found wherever it
    ## sits and is the whole folded text either way; `bannerLine`'s doc argues
    ## why the diagnostic beside it is not grounds to refuse it.
    let bannerFirst = ClBannerEn & "\n" & PoisonedClDotted
    let warningFirst = PoisonedClDotted & ClBannerEn
    let a = winHalf(makeWinRun(bannerFirst))
    let b = winHalf(makeWinRun(warningFirst))
    check a.state == cfsKnown
    check b.state == cfsKnown
    check a == b
    check "19.44.35228" in b.text
    check "D9024" notin b.text

  test "the BACKSTOP disjunct no longer accepts a diagnostic-shaped digest-less half":
    ## `toolchainUnsound`'s third disjunct tested the same `hasDottedVersion`
    ## predicate as the producer, so the one input that slipped past the
    ## producer also disarmed the backstop. Pinned here as a pure predicate over
    ## a hand-built value -- the same way R3-2 pinned the disjunct it added --
    ## with a differential so a regression that stops consulting the text cannot
    ## hide. (`tests/unit/test_cachedispatch.nim` owns the rest of this
    ## predicate's input space; every case there is single-segment text with no
    ## diagnostic shape, so it is unaffected by this tightening.)
    proc winFingerprint(compilerText: string): CcFingerprint =
      CcFingerprint(
        compiler: CcHalf(state: cfsKnown, text: compilerText,
                         digest: CcDigest(kind: cdkNone)),
        runtime: CcHalf(state: cfsKnown, text: "kernel32+libcmt+libucrt",
                        digest: CcDigest(kind: cdkKnown, hex: "abc123abc123abc1")))
    check toolchainUnsound(winFingerprint(
      "cl : Command line warning D9024 : unrecognized source file type " &
      "'10.0.22621.0', object file assumed"))
    check not toolchainUnsound(winFingerprint(
      "Microsoft (R) C/C++-Optimierungscompiler Version 19.44.35228 für x64"))


# -----------------------------------------------------------------------------
# Everything below this line touches the REAL environment: a `cc` that must
# resolve on PATH, and binaries at absolute POSIX paths. Everything above is
# sealed behind seams and states the same facts on both platforms -- which is
# what issue #23 slice 7 restored. This file used to sit inside one file-wide
# `when defined(posix)` and ran ZERO assertions on Windows, including the two
# suites whose entire subject is how a Windows toolchain keys.
# -----------------------------------------------------------------------------
when defined(posix):
  # ---------------------------------------------------------------------------
  # Suite 3f: the cc half is a content fingerprint too (issue #23)
  # ---------------------------------------------------------------------------
  ##
  ## The same argument slice 4a made about `ldd`, applied to `cc`. A distro
  ## that rebuilds gcc with a codegen fix and does not move the version string
  ## produces a compiler that generates DIFFERENT OBJECT CODE while reporting
  ## `gcc (GCC) 13.2.0` either way -- and crisol would serve the old artifact.
  ##
  ## `nimprobe` has closed exactly this gap for the nim binary since RFC-0005,
  ## and its module doc justifies itself as "symmetric to the one
  ## `ccprobe.nim` already closes for the C compiler" -- which was FALSE until
  ## this slice. `docs/rfc/0005-distributed-cache-and-trust.md:389` recorded
  ## the asymmetry deliberately: `(ccprobe.nim -- no binary hash)`.
  ##
  ## The driver is resolved with `os.findExe`, exactly as
  ## `nimprobe.resolveNimBin` resolves nim: the compile path spawns the bare
  ## name through `poUsePath`, so a PATH lookup names the binary that will
  ## actually run. These tests therefore need a real `cc` on PATH -- true in
  ## `ghcr.io/coreyleavitt/nim:2.2.10`, where this suite runs. Without one the
  ## driver hash degrades to a sentinel and these tests FAIL rather than
  ## silently passing, which is the correct way round.

  proc makeSplitHash(libc, driver: string): BinHashProc =
    ## Distinct content for the runtime artifact and for the compiler driver,
    ## so a test can move one without moving the other.
    result = proc(path: string): string =
      if path.len == 0:        FileHashSentinel
      elif path == TestLibcPath: libc
      else:                    driver

  suite "ccVersion — the cc half is a content fingerprint":

    test "two gcc builds reporting the SAME version still key apart":
      ## The driver's bytes moved; its banner did not.
      let run = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
      let a = ccVersion(run, PosixCcProfile, makeSplitHash(TestDigest, "1111111111111111"))
      let b = ccVersion(run, PosixCcProfile, makeSplitHash(TestDigest, "2222222222222222"))
      checkpoint("a = " & a)
      checkpoint("b = " & b)
      check a != b

    test "the version text is still carried, so a miss stays legible":
      ## `--explain-miss` has to read: "gcc 13.2.0 -> 13.3.0", not two digests.
      let run = makeRun("gcc (GCC) 13.2.0", true, "ldd (GNU libc) 2.38", true)
      let v = ccVersion(run, PosixCcProfile, makeSplitHash(TestDigest, "1111111111111111"))
      check v.startsWith("gcc (GCC) 13.2.0 #")

  # ---------------------------------------------------------------------------
  # Suite 4: realRun — arg safety (no shell interpretation, M9 fix)
  # ---------------------------------------------------------------------------
  ##
  ## Verifies that realRun does NOT pass args through a shell (i.e. does NOT use
  ## execCmdEx with join-on-space).  The discriminator: run
  ##   /bin/sh -c 'echo $#' -- "one two"
  ## With a correct execv-style call, sh receives exactly ONE positional parameter
  ## ("one two" as a single atom) and prints "1".
  ## With the old shell-join (execCmdEx), the shell command becomes:
  ##   /bin/sh -c echo $# -- one two
  ## which runs `echo` as the -c script and counts 4 positional params, printing "4".

  suite "realRun — execv-style, no shell splitting":

    test "arg containing a space arrives as ONE argument, not split by shell":
      ## M9: realRun must use startProcess (no poEvalCommand), not execCmdEx.
      ## If realRun still uses execCmdEx (join-on-space), this test fails because
      ## sh would count 4 positional params instead of 1.
      let (output, ok) = realRun("/bin/sh", ["-c", "echo $#", "--", "one two"])
      check ok
      let trimmed = output.strip()
      check trimmed == "1"

    test "realRun returns ok=true for a command that exits 0":
      ## rfc-0007 C1a: `true`/`false` live at /bin/true and /bin/false on
      ## Linux but only at /usr/bin/true and /usr/bin/false on macOS — a
      ## PATH lookup is the portable spelling on both, not a platform branch.
      let (_, ok) = realRun(findExe("true"), [])
      check ok

    test "realRun returns ok=false for a command that exits non-zero":
      let (_, ok) = realRun(findExe("false"), [])
      check not ok

    test "realRun captures stdout output":
      let (output, ok) = realRun("/bin/echo", ["hello"])
      check ok
      check output.strip() == "hello"

  # ---------------------------------------------------------------------------
  # Suite 5: realRunIn — rfc-0007 A2c (issue #17): the returned RunProc always
  # spawns its subprocess with the GIVEN workingDir, regardless of the calling
  # process's own cwd.
  # ---------------------------------------------------------------------------

  suite "realRunIn — subprocess cwd is the given workingDir, not the caller's":

    test "the subprocess sees workingDir as its cwd even when the caller's cwd differs":
      let target = getTempDir() / "crisol_ccprobe_realrunin_target"
      createDir(target)
      defer: removeDir(target)

      let savedCwd = getCurrentDir()
      setCurrentDir(getTempDir())   # deliberately NOT `target`
      defer: setCurrentDir(savedCwd)

      let run = realRunIn(target)
      let (output, ok) = run("/bin/pwd", [])
      check ok
      # rfc-0007 C1a: compare against the REALPATH (symlinks resolved), not
      # the lexical absolutePath — `chdir`'s effective cwd (what `pwd`
      # actually observes via getcwd(2)) is inherently the resolved path.
      # On Linux getTempDir() ("/tmp") is not itself a symlink, so this is a
      # no-op there; on macOS getTempDir() routes through /var ->
      # /private/var, so the two forms genuinely differ.
      check output.strip() == target.expandFilename.normalizedPath

    test "workingDir = \"\" behaves exactly like realRun (inherits the caller's cwd)":
      let run = realRunIn("")
      let (output, ok) = run("/bin/echo", ["hello"])
      check ok
      check output.strip() == "hello"

  # ---------------------------------------------------------------------------
  # W9a: `lastProbeStderr()` -- the side channel a caller reads after a
  # non-merged `RunProc` call to recover the driver's own diagnostic, since
  # `RunProc` itself carries only `output`/`ok` and is not to be widened.
  # ---------------------------------------------------------------------------

  suite "lastProbeStderr — W9a: a non-merged run's stderr survives the RunProc boundary":

    test "a non-merged run's stderr is readable via lastProbeStderr right after the call":
      let (output, ok) = realRun("/bin/sh", ["-c", "echo out-line; echo err-line 1>&2"])
      check ok
      check output.strip() == "out-line"
      check lastProbeStderr().strip() == "err-line"

    test "exit 0 with nothing useful on stdout still surfaces its stderr (the D9002 shape)":
      ## Models the measured old-cl behaviour: `ok = true`, stdout is a bare
      ## banner, and the real explanation ("ignoring unknown option") is on
      ## stderr where a caller could never see it before W9a.
      let (output, ok) = realRun("/bin/sh",
        ["-c", "echo banner-only; echo cl : warning D9002 : ignoring unknown option 1>&2"])
      check ok
      check output.strip() == "banner-only"
      check "D9002" in lastProbeStderr()

    test "resets on the NEXT call -- never echoes a stale value from an earlier probe":
      discard realRun("/bin/sh", ["-c", "echo one 1>&2"])
      check lastProbeStderr().strip() == "one"
      discard realRun("/bin/echo", ["quiet"])
      check lastProbeStderr().strip() == ""

    test "a MERGED run (realRunMerged) clears the side channel -- no separate stderr to report":
      discard realRun("/bin/sh", ["-c", "echo leftover 1>&2"])
      check lastProbeStderr().strip() == "leftover"
      discard realRunMerged("/bin/echo", ["hello"])
      check lastProbeStderr().strip() == ""


# ---------------------------------------------------------------------------
# Issue #21 slice 2 -- "no usable dependency report" is LOUD, and is a
# different thing from "this translation unit includes nothing".
#
# This distinction is the entire reason `/sourceDependencies` was chosen over
# `/showIncludes`, which cannot express it: with `/showIncludes`, a probe that
# never ran and a source with no includes both produce zero lines. Before
# #21 the vcc path did exactly that -- cl answered `-M` with a D9002 warning
# on stderr, exited 0, printed only its banner, and the make-rule parser
# turned that banner into a single bogus "header". Not an error, not an empty
# set: a silently WRONG one, vouched for by a soundness key.
#
# The banner-only fixture below is measured, not invented. Inside
# ghcr.io/coreyleavitt/nim:2.2.10-windows (cl 19.44.35228):
#
#   vccexe.exe /Zs --platform:amd64 /nologo /Qzzzbogus unit.c
#     rc     = 0
#     stdout = "unit.c\n"
#     stderr = "cl : Command line warning D9002 : ignoring unknown option ..."
#
# rc is ZERO and stdout is a bare banner, so `ranOk` is true and nothing in
# the run's own result says anything went wrong. `realRunIn`'s capture is
# stdout-only, so the D9002 is dropped. The STRUCTURAL absence of the
# document is therefore the only signal that exists -- which is why it has
# to be the one that fails the probe.
# ---------------------------------------------------------------------------

const
  MsvcBannerOnly = "unit.c\n"
    ## Exactly what an older cl (< 19.27) or clang-cl leaves on stdout: the
    ## source-name banner and no document at all.

  MsvcRealReport = """unit.c
{
    "Version": "1.2",
    "Data": {
        "Source": "c:\\p\\native\\add.c",
        "ProvidedModule": "",
        "Includes": [
            "c:\\p\\native\\add.h",
            "c:\\msvc\\vc\\include\\stdint.h"
        ]
    }
}
"""
    ## A real capture, paths localised: cl's one banner line, then the pretty
    ## document beginning at a line that is exactly `{`.

  MsvcBannerOnlyCRLF = "unit.c\r\n"
    ## CR14 (code review 2026-09-21): CRLF-terminated `MsvcBannerOnly`. Real
    ## Windows console/subprocess capture is typically CRLF; before this
    ## fixture, zero MSVC fixture in this file carried a raw CR byte.

  MsvcRealReportCRLF =
    "unit.c\r\n" &
    "{\r\n" &
    "    \"Version\": \"1.2\",\r\n" &
    "    \"Data\": {\r\n" &
    "        \"Source\": \"c:\\\\p\\\\native\\\\add.c\",\r\n" &
    "        \"ProvidedModule\": \"\",\r\n" &
    "        \"Includes\": [\r\n" &
    "            \"c:\\\\p\\\\native\\\\add.h\",\r\n" &
    "            \"c:\\\\msvc\\\\vc\\\\include\\\\stdint.h\"\r\n" &
    "        ]\r\n" &
    "    }\r\n" &
    "}\r\n"
    ## CR14: `MsvcRealReport`, CRLF end to end (banner line included -- a real
    ## capture would not switch terminators mid-stream). One preceding CRLF
    ## banner line, so this alone stays inside the "harmless" 1-2-line range
    ## the old `pos += line.len + 1` locator tolerated; it pins the ordinary
    ## case rather than the corrupting one (see
    ## `MsvcRealReportCRLFThreeBanners` below for that).

  MsvcRealReportCRLFThreeBanners =
    "unit.c\r\n" &
    "warning: something\r\n" &
    "note: else entirely\r\n" &
    "{\r\n" &
    "    \"Version\": \"1.2\",\r\n" &
    "    \"Data\": {\r\n" &
    "        \"Source\": \"c:\\\\p\\\\native\\\\add.c\",\r\n" &
    "        \"ProvidedModule\": \"\",\r\n" &
    "        \"Includes\": [\r\n" &
    "            \"c:\\\\p\\\\native\\\\add.h\",\r\n" &
    "            \"c:\\\\msvc\\\\vc\\\\include\\\\stdint.h\"\r\n" &
    "        ]\r\n" &
    "    }\r\n" &
    "}\r\n"
    ## CR-X1 / CR14: THREE preceding CRLF lines before the document -- the
    ## threshold the handoff's byte-level simulation found actually corrupts
    ## the old locator (1-2 preceding CRLF lines only shift the slice onto
    ## whitespace `parseJson` already skips; 3+ shifts it into the TEXT of a
    ## preceding line). Real `cl` emits exactly one banner line today, which
    ## is why this was latent rather than live -- but nothing stopped a
    ## future toolset, or a probe run behind extra diagnostic lines, from
    ## reaching this shape.

suite "parseMsvcSourceDeps — CRLF-terminated documents (CR14)":

  test "banner-only CRLF stdout is dpeNoJson, same as the LF fixture":
    let probed = depIncludeHeaders(ccfMsvc, MsvcBannerOnlyCRLF, "c:/p/native/add.c")
    check probed.err == dpeNoJson
    check probed.headers.mapIt(string(it)).len == 0

  test "a CRLF-terminated real report parses, one preceding banner line":
    let probed = depIncludeHeaders(ccfMsvc, MsvcRealReportCRLF, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 2
    check "c:/p/native/add.h".replace("/", "\\") in probed.headers.mapIt(string(it))

  test "3+ preceding CRLF lines before the document still parse (CR-X1 / CR14)":
    ## RED before the fix: the old `pos += line.len + 1` locator undercounts
    ## one byte per CRLF line, so at three preceding lines the reconstructed
    ## slice starts three bytes early -- inside the text of the third banner
    ## line rather than on whitespace -- and `parseJson` sees a leading
    ## non-whitespace byte. That turned a perfectly real document into
    ## `dpeBadJson` (and, through `closure.extractCompileInputs`, a hard
    ## `CrisolError` for a translation unit that has real headers).
    let probed = depIncludeHeaders(ccfMsvc, MsvcRealReportCRLFThreeBanners,
                                   "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 2
    check "c:/p/native/add.h".replace("/", "\\") in probed.headers.mapIt(string(it))

suite "depIncludeHeaders (MSVC) — a missing report is loud, an empty one is an answer":

  test "banner-only stdout (old cl / clang-cl) is dpeNoJson, never an empty header set":
    let probed = depIncludeHeaders(ccfMsvc, MsvcBannerOnly, "c:/p/native/add.c")
    check probed.err == dpeNoJson
    check probed.headers.mapIt(string(it)).len == 0

  test "a real report parses, and system headers are still the caller's to filter":
    let probed = depIncludeHeaders(ccfMsvc, MsvcRealReport, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 2
    check "c:/p/native/add.h".replace("/", "\\") in probed.headers.mapIt(string(it))

  test "an EMPTY Includes array is a real answer, NOT a failure":
    ## The load-bearing distinction. A `.c` that includes nothing genuinely
    ## has an empty header set, and recording that is correct; it must not
    ## be confused with the probe having failed.
    let empty = """unit.c
{ "Version": "1.2", "Data": { "Source": "c:/p/u.c", "Includes": [] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, empty, "c:/p/u.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 0

  test "a truncated document is dpeBadJson":
    let truncated = """unit.c
{ "Version": "1.2", "Data": { "Includes": [ "a.h"
"""
    check depIncludeHeaders(ccfMsvc, truncated, "u.c").err == dpeBadJson

  test "a well-formed document with no Data object is dpeBadJson":
    let noData = """unit.c
{ "Version": "1.2" }
"""
    check depIncludeHeaders(ccfMsvc, noData, "u.c").err == dpeBadJson

  test "Data present but no Includes array is dpeNoIncludes":
    let noIncludes = """unit.c
{ "Version": "1.2", "Data": { "Source": "u.c", "ProvidedModule": "" } }
"""
    check depIncludeHeaders(ccfMsvc, noIncludes, "u.c").err == dpeNoIncludes

  test "a non-string element in Includes is dpeBadJson, never silently skipped":
    let badElem = """unit.c
{ "Version": "1.2", "Data": { "Includes": [ "a.h", 42 ] } }
"""
    check depIncludeHeaders(ccfMsvc, badElem, "u.c").err == dpeBadJson

  test "the document is located by CONTENT, so extra banner lines do not shift the parse":
    ## `{` is found as the first line that IS `{`, never at a fixed index --
    ## the same content-not-position rule the cc banner extraction follows
    ## (issue #23). cl prints one banner line today; resting on that is how
    ## issue #22 happened.
    let extraBanners = "unit.c\nsomething else\n" & MsvcRealReport[len("unit.c\n") .. ^1]
    let probed = depIncludeHeaders(ccfMsvc, extraBanners, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 2

suite "depIncludeHeaders (MSVC) — W9j: Data.Source is cross-checked against the probed unit":

  test "matching Source (same basename, different case/separator/absoluteness) is dscMatch, headers kept":
    let probed = depIncludeHeaders(ccfMsvc, MsvcRealReport, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.sourceCheck == dscMatch
    check probed.headers.mapIt(string(it)).len == 2

  test "a DIFFERENT Source is dscMismatch, and it fails as loudly as a DepProbeError (empty headers)":
    ## A stale or misattributed document: the JSON is well-formed and its
    ## Includes are real, but Data.Source names a translation unit other
    ## than the one this probe was for. Before W9j this passed silently.
    let staleDoc = """unit.c
{
    "Version": "1.2",
    "Data": {
        "Source": "c:\\p\\native\\OTHER.c",
        "Includes": [ "c:\\p\\native\\add.h" ]
    }
}
"""
    let probed = depIncludeHeaders(ccfMsvc, staleDoc, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.sourceCheck == dscMismatch
    check probed.headers.mapIt(string(it)).len == 0   # never a usable-but-suspicious header set

  test "case and separator differences alone are NOT a mismatch (cl lowercases and may absolutize)":
    let doc = """unit.c
{ "Version": "1.2", "Data": { "Source": "C:\\P\\NATIVE\\ADD.C",
  "Includes": [ "c:/p/native/add.h" ] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, doc, "add.c")   # relative, unlike the doc's absolute+uppercased spelling
    check probed.sourceCheck == dscMatch
    check probed.err == dpeNone

  test "no Source field in the document at all is dscSkipped, not a mismatch":
    let noSource = """unit.c
{ "Version": "1.2", "Data": { "Includes": [ "a.h" ] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, noSource, "u.c")
    check probed.sourceCheck == dscSkipped
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["a.h"]

suite "depIncludeHeaders (GNU) — W9j: the source check is MSVC-only":

  test "the GNU arm always reports dscSkipped -- there is no Data.Source to check":
    let rule = "/c/obj.o: /c/src.c /c/a.h\n"
    let probed = depIncludeHeaders(ccfGnuMake, rule, "/c/src.c")
    check probed.sourceCheck == dscSkipped

suite "depIncludeHeaders (GNU) — unchanged by the MSVC arm":

  test "a make-style rule still parses, and never reports an error":
    let rule = "/c/obj.o: /c/src.c /c/a.h \\\n  /c/b.h\n"
    let probed = depIncludeHeaders(ccfGnuMake, rule, "/c/src.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["/c/a.h", "/c/b.h"]   # the source itself excluded

# ---------------------------------------------------------------------------
# W8 — `parseCcMDeps` must reverse GNU `-M`'s own escaping, not
# `splitWhitespace()` through it. A backslash-escaped space in a header path
# (real, e.g. under WSL2 or a build tree with a space in it) must survive as
# ONE token with an embedded space, not shatter into two fragments that both
# resolve to nothing and vanish from the closure (silent under-selection,
# exit code 0). `$$` (a literal `$`) and `\#` (a literal `#`) are the other
# escapes GNU make's dependency writer (cpp's mkdeps.cc `make_write_name`)
# documents; covered alongside so a future regression on either is caught
# here rather than in the field.
# ---------------------------------------------------------------------------

suite "parseCcMDeps — reverses GNU -M's own escaping (issue W8)":

  test "a backslash-escaped space in a header path survives as ONE token":
    ## RED (pre-fix): splitWhitespace() shatters `inc/a\ file.h` into
    ## `inc/a\` and `file.h` -- both then classify pcOutside in closure.nim
    ## and are silently dropped. The fixed token must be the real path, with
    ## the escape gone and the space embedded.
    let rule = "obj.o: src.c inc/a\\ file.h other.h\n"
    let toks = parseCcMDeps(rule).mapIt(string(it))
    check toks == @["src.c", "inc/a file.h", "other.h"]

  test "depIncludeHeaders (GNU) keeps the escaped-space header intact end to end":
    let rule = "obj.o: src.c inc/a\\ file.h\n"
    let probed = depIncludeHeaders(ccfGnuMake, rule, "src.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["inc/a file.h"]

  test "a doubled `$$` unescapes to a literal `$`":
    let rule = "obj.o: src.c inc/$$version.h\n"
    let toks = parseCcMDeps(rule).mapIt(string(it))
    check toks == @["src.c", "inc/$version.h"]

  test "an escaped `#` (`\\#`) unescapes to a literal `#`":
    let rule = "obj.o: src.c inc/a\\#b.h\n"
    let toks = parseCcMDeps(rule).mapIt(string(it))
    check toks == @["src.c", "inc/a#b.h"]

  test "a doubled backslash before a space is one literal backslash, and the space still separates":
    ## Per make's own quoting rule (2N backslashes before a space => N
    ## literal backslashes and the space IS a separator), a path ending in a
    ## literal backslash followed by a real separating space must not be
    ## mistaken for an escaped embedded space.
    let rule = "obj.o: src.c inc\\\\ other.h\n"
    let toks = parseCcMDeps(rule).mapIt(string(it))
    check toks == @["src.c", "inc\\", "other.h"]

  test "ordinary POSIX input is byte-identical to the pre-fix tokenization (pinned)":
    let rule = "/c/obj.o: /c/src.c /c/a.h \\\n  /c/b.h\n"
    check parseCcMDeps(rule).mapIt(string(it)) == @["/c/src.c", "/c/a.h", "/c/b.h"]

# ---------------------------------------------------------------------------
# CR15 — `find(':')` grabs the drive-letter colon on a mingw rule, corrupting
# the first token. Verified harmless to selection (the garbage resolves to
# nothing and is dropped at `extractCompileInputs`' header loop in closure.nim,
# `if pcH.kind != pcTracked: continue`), but it must stop happening: a
# real target-separator colon is being missed.
# ---------------------------------------------------------------------------

suite "parseCcMDeps — the rule's TARGET colon, not the drive-letter colon (issue CR15)":

  test "a mingw rule with drive-letter absolute paths does not corrupt the first dependency token":
    ## RED (pre-fix): find(':') matches the drive-letter colon in
    ## `C:/proj/build/add.o:`, so depsStr begins mid-target and the first
    ## token is the bogus `/proj/build/add.o:` instead of the real
    ## `C:/proj/add.c`.
    let rule = "C:/proj/build/add.o: C:/proj/add.c C:/proj/inc/top.h\n"
    let toks = parseCcMDeps(rule).mapIt(string(it))
    check toks == @["C:/proj/add.c", "C:/proj/inc/top.h"]

  test "depIncludeHeaders (GNU) on a mingw rule reports only the real headers, no bogus target fragment":
    let rule = "C:/proj/build/add.o: C:/proj/add.c C:/proj/inc/top.h\n"
    let probed = depIncludeHeaders(ccfGnuMake, rule, "C:/proj/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["C:/proj/inc/top.h"]

# ---------------------------------------------------------------------------
# CR15 / CR12 — the GNU and MSVC arms of depIncludeHeaders must share the
# property "a header path containing a space survives" (`parseCcMDeps`' W8
# escape handling on GNU; the `/sourceDependencies` JSON on MSVC). Assert it of BOTH
# arms in one place so they cannot silently drift apart again. This also
# covers CR12's MSVC vector (a space in a header path through the
# `/sourceDependencies` JSON path), which until now had no committed test.
# ---------------------------------------------------------------------------

suite "depIncludeHeaders — the GNU and MSVC arms agree: a header path with a space survives":

  test "GNU arm: a backslash-escaped space in a header path survives":
    let rule = "obj.o: src.c inc/a\\ file.h\n"
    let probed = depIncludeHeaders(ccfGnuMake, rule, "src.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["inc/a file.h"]

  test "MSVC arm: a header path containing a space survives (closes CR12)":
    let withSpace = """unit.c
{ "Version": "1.2", "Data": { "Source": "c:/p/u.c",
  "Includes": [ "c:/p/native/a file with space.h" ] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, withSpace, "c:/p/u.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["c:/p/native/a file with space.h"]

suite "ccFamilyOfDriver — classified from the manifest's driver token (issue #21)":

  test "MSVC drivers classify as ccfMsvc, bare or with .exe, any case, any path":
    check ccFamilyOfDriver("cl") == ccfMsvc
    check ccFamilyOfDriver("cl.exe") == ccfMsvc
    check ccFamilyOfDriver("CL.EXE") == ccfMsvc
    check ccFamilyOfDriver("vccexe.exe") == ccfMsvc
    check ccFamilyOfDriver("clang-cl.exe") == ccfMsvc
    check ccFamilyOfDriver("C:/nim/2.2.10-patched/bin/vccexe.exe") == ccfMsvc

  test "gcc-family drivers classify as ccfGnuMake":
    check ccFamilyOfDriver("cc") == ccfGnuMake
    check ccFamilyOfDriver("gcc") == ccfGnuMake
    check ccFamilyOfDriver("clang") == ccfGnuMake
    check ccFamilyOfDriver("/usr/bin/x86_64-linux-gnu-gcc-13") == ccfGnuMake
    check ccFamilyOfDriver("") == ccfGnuMake

  test "`clang` is NOT `clang-cl` — the prefix must not decide":
    check ccFamilyOfDriver("clang") == ccfGnuMake
    check ccFamilyOfDriver("clang-cl") == ccfMsvc

suite "deriveDepInvocation — MSVC is a pure prepend, GNU still strips (issue #21)":

  test "the MSVC arm removes NOTHING: /c and /Fo<obj> both survive":
    ## `/Zs` dominates both (measured against cl 19.44: no .obj, no .pdb, no
    ## .idb written), so replaying them verbatim is safe AND is what stops
    ## the probe rewriting the nimcache object as a side effect. The GNU arm
    ## cannot do this -- `-M` does not suppress `-c`.
    let inv = deriveDepInvocation(
      "vccexe.exe /c --platform:amd64 /nologo /IC:/p/tests /FoC:/p/nc/u.obj C:/p/u.c")
    check inv.ok
    check inv.family == ccfMsvc
    check inv.cmd == "vccexe.exe"
    check inv.sourceFile == "C:/p/u.c"
    check inv.args[0] == "/Zs"
    check inv.args[1] == "/sourceDependencies-"
    check "/c" in inv.args
    check "/FoC:/p/nc/u.obj" in inv.args
    check "--platform:amd64" in inv.args
    check "-M" notin inv.args
    check inv.args[^1] == "C:/p/u.c"

  test "the GNU arm is untouched: -M prepended, -c and -o <obj> dropped":
    let inv = deriveDepInvocation("gcc -c -I/p/inc -o /p/nc/u.o /p/u.c")
    check inv.ok
    check inv.family == ccfGnuMake
    check inv.args[0] == "-M"
    check "-c" notin inv.args
    check "-o" notin inv.args
    check "/p/nc/u.o" notin inv.args
    check "-I/p/inc" in inv.args
    check inv.args[^1] == "/p/u.c"

  test "an untokenizable command degrades to ok=false, never raises":
    let inv = deriveDepInvocation("gcc -c \"unterminated /p/u.c")
    check (not inv.ok)

suite "CR9 -- deriveDepInvocation and closure.ccCmdOutputObj share the GNU -o grammar":
  ## One fact -- which token(s) spell the GNU `-o <obj>` output flag -- has
  ## two consumers: `deriveDepInvocation` STRIPS it out of a dependency-probe
  ## replay, `closure.ccCmdOutputObj` EXTRACTS its value to pair a `compile`
  ## manifest entry with its `link` object. Both procs now go through
  ## `ccprobe.classifyGnuOutputFlag`; these tests drive BOTH from the SAME
  ## `ccCmd` fixture so a future edit to one that the other doesn't follow
  ## fails a test instead of silently diverging (the #21-layer-2 failure
  ## mode, recorded on `closure.ccCmdOutputObj`'s own doc, for the mirror
  ## GNU spelling).

  test "separated form: deriveDepInvocation drops -o <obj>, ccCmdOutputObj extracts the same value":
    let ccCmd = "gcc -c -I/p/inc -o /p/nc/u.o /p/u.c"

    let inv = deriveDepInvocation(ccCmd)
    check inv.ok
    check "-o" notin inv.args
    check "/p/nc/u.o" notin inv.args

    let extracted = ccCmdOutputObj(ccCmd)
    check extracted.ok
    check extracted.obj == "/p/nc/u.o"

  test "fused form: deriveDepInvocation drops -o<obj>, ccCmdOutputObj extracts the same value":
    let ccCmd = "gcc -c -I/p/inc -o/p/nc/u.o /p/u.c"

    let inv = deriveDepInvocation(ccCmd)
    check inv.ok
    check "-o/p/nc/u.o" notin inv.args

    let extracted = ccCmdOutputObj(ccCmd)
    check extracted.ok
    check extracted.obj == "/p/nc/u.o"

  test "a command with neither form: deriveDepInvocation keeps everything, ccCmdOutputObj reports ok=false":
    let ccCmd = "gcc -c -I/p/inc /p/u.c"

    let inv = deriveDepInvocation(ccCmd)
    check inv.ok
    check "-I/p/inc" in inv.args

    let extracted = ccCmdOutputObj(ccCmd)
    check (not extracted.ok)


# -----------------------------------------------------------------------------
# W5a (code review 2026-09-21): the four suites above sit behind
# `when defined(posix)` and do NOT run on windows. Before this block that fact
# was invisible to `ci/assert-subset-honesty.sh`, which audits skips by marker
# -- so the gate that exists precisely to catch "a load-bearing test silently
# started skipping" could not see these four, and slice 7's own diagnosis
# ("a test that skips INVISIBLY is worse than one that fails") was only half
# closed: it fixed the zero-assertions half and left the invisible half open.
#
# These are per-SUITE markers, not a whole-file `CRISOL-SKIP:`. This file runs
# the great majority of its suites on BOTH platforms -- claiming the file skips
# would be false in the other direction, and would tell the gate a lie that
# happens to be convenient.
# ---------------------------------------------------------------------------
# CR5 — a resolveDriver regression must be observable
# ---------------------------------------------------------------------------
#
# The row (code-review ledger, 2026-09-21): `driverDigestFor`/`expectFp`
# compute the EXPECTED driver digest by calling `resolveDriver("cc")` -- the
# same unseamed call production makes -- so expected and actual come from one
# source and can never disagree. A `resolveDriver` returning a
# wrong-but-NONEMPTY path is therefore invisible. Round 2 confirmed it
# empirically: mutating `resolveDriver` that way changed nothing across all 82
# tests in this file. `makeFixedHash` compounds it by returning one digest for
# ANY non-empty path, so a wrong path hashes identically to the right one.
#
# The row names the missing ingredient exactly: "No test anywhere fakes PATH
# or pins a literal driver path." So this suite fakes PATH.
#
# It deliberately does NOT assert anything about the resolved path's SPELLING.
# Nim's `findExe` follows symlinks, so on a normal Linux host
# `resolveDriver("cc")` legitimately answers `/usr/bin/gcc-16` -- a path whose
# basename is not "cc" at all. An assertion on the spelling would be either
# circular (restating `resolveDriver`'s own answer) or simply wrong. Instead
# the fake driver is identified by its CONTENT: the hash seam reads the file
# it was handed and only yields the good digest if that file is the one this
# test planted. That is immune to symlink resolution, absolute-vs-relative
# spelling, and platform path separators alike.

const Cr5Marker = "CRISOL-CR5-FAKE-CC-MARKER"

proc withFakeCcOnPath(body: proc(fakeDir: string)) =
  ## Plant an executable named `cc` (`cc.exe` on Windows) in a private temp
  ## dir, put that dir FIRST on PATH, run `body`, then restore PATH and clean
  ## up. Restoration is unconditional -- a leaked PATH would corrupt every
  ## later suite in this file.
  let dir = getTempDir() / ("crisol_cr5_" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  let exeName = when defined(windows): "cc.exe" else: "cc"
  let fake = dir / exeName
  writeFile(fake, Cr5Marker & "\n")
  when not defined(windows):
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
  let sep = when defined(windows): ";" else: ":"
  let oldPath = getEnv("PATH")
  putEnv("PATH", dir & sep & oldPath)
  try:
    body(dir)
  finally:
    putEnv("PATH", oldPath)
    removeDir(dir)

suite "CR5 — a wrong-but-nonempty resolveDriver answer is caught":

  test "the compiler half's digest comes from the driver file that was actually resolved":
    withFakeCcOnPath(proc(fakeDir: string) =
      var seen: seq[string]
      # The seam identifies the file by CONTENT, not by path spelling.
      let contentAware: BinHashProc = proc(path: string): string =
        seen.add(path)
        if path.len > 0 and fileExists(path) and Cr5Marker in readFile(path):
          "dddddddddddddddd"
        else:
          "NOT-THE-RESOLVED-DRIVER"

      let fp = ccVersion(makeRun("gcc (GCC) 13.2.0", true,
                                 "ldd (GNU libc) 2.38", true),
                         PosixCcProfile, contentAware)
      let pipePos = fp.find('|')
      check pipePos > 0
      let compilerHalf = fp[0 ..< pipePos]

      # PATH is ours, so resolution is deterministic: it MUST have found the
      # planted driver. No host-dependent branch, and nothing restated from
      # `resolveDriver` itself.
      check seen.len >= 1
      check compilerHalf.endsWith(" #dddddddddddddddd")
      # Stated positively too, so the failure message is legible when a
      # regression makes the seam hash some other file.
      check not compilerHalf.endsWith(" #NOT-THE-RESOLVED-DRIVER")
    )

  test "the compiler and runtime halves cannot silently share one digest":
    ## CR5's second leg: `makeFixedHash` handing ONE digest to BOTH halves is
    ## what let a misattributed digest pass unnoticed -- the round-2 reviewer
    ## showed a digest computed from the wrong input, but landing in the right
    ## half, is invisible. Key the seam per file and pin which value belongs
    ## where.
    withFakeCcOnPath(proc(fakeDir: string) =
      let perFile: BinHashProc = proc(path: string): string =
        if path.len == 0: FileHashSentinel
        elif path == TestLibcPath: "rrrrrrrrrrrrrrrr"
        elif fileExists(path) and Cr5Marker in readFile(path): "dddddddddddddddd"
        else: "NOT-THE-RESOLVED-DRIVER"

      let fp = ccVersion(makeRun("gcc (GCC) 13.2.0", true,
                                 "ldd (GNU libc) 2.38", true),
                         PosixCcProfile, perFile)
      let pipePos = fp.find('|')
      check pipePos > 0
      let compilerHalf = fp[0 ..< pipePos]
      let runtimeHalf  = fp[pipePos + 1 .. ^1]

      check compilerHalf.endsWith(" #dddddddddddddddd")
      check runtimeHalf.endsWith(" #rrrrrrrrrrrrrrrr")
      # Neither half may carry the other's digest.
      check not compilerHalf.endsWith(" #rrrrrrrrrrrrrrrr")
      check not runtimeHalf.endsWith(" #dddddddddddddddd")
    )


# -----------------------------------------------------------------------------
when not defined(posix):
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#cc_half_content_fingerprint_realenv"
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#realrun_execv_no_shell_splitting"
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#realrunin_subprocess_cwd"
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#lastprobestderr_w9a_nonmerged"

# No unconditional "all passed" banner. There used to be one here, and it
# printed under SEVEN failures during this review -- a success line emitted by
# a run that failed is the same false signal W5c's out-of-gate `done` line was.
# std/unittest already reports per-test status and sets a nonzero exit code;
# the harness reads that, not prose.
