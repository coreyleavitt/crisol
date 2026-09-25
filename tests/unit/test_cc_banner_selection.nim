## test_cc_banner_selection.nim -- the Windows compiler half believes a line
## only if that SAME line is a banner (R6 round-6 review, 2026-09-24).
##
## R5-4 tightened the ACCEPTOR (`namesCompilerVersion`) but left the SELECTOR
## alone: `ccIdentity` judged `versionLine(output)` -- the first line carrying
## ANY dotted token -- so which line got judged and which line would have
## passed were two different questions. Measured on the unmutated tree, with
## `WindowsCcProfile` and a mingw gcc bystander:
##
##   A  one-line D9024 echoing '10.0.22621.0'                  refused  (ok)
##   B  the same D9024 wrapped onto two lines                  refused  (ok)
##   C  a wrapped D9002 whose continuation carries 3.11 inside
##      a quoted path, UNquoted itself                         BELIEVED (defect)
##   D  a bare echoed command line with a dotted token         BELIEVED (defect)
##   E  a LINK fatal error plus an unprefixed SDK-path line    BELIEVED (defect)
##   F1 real banner, THEN a D9024 line                         believed
##   F2 the same two lines, D9024 FIRST                        refused
##
## C/D/E published to the SHARED L2 tier under a compiler half whose text is
## a path fragment or an argv echo -- text that does not vary with the
## installed toolset, so two hosts on different MSVC toolsets fold to the same
## key. F1/F2 made the verdict depend on which pipe flushed first, the exact
## positional dependence issue #22 exists to remove.
##
## The fix makes the selector and the acceptor ONE predicate: `ccIdentity`
## under `cdVersionOnly` folds the first line satisfying `namesCompilerVersion`
## and refuses when there is none. The predicate itself had to tighten too,
## because a line-level selector alone still believes C's continuation line
## (that was the second half of the finding): a version token now has to be
## FREE-STANDING (its own word, or parenthesised) and carry three components,
## and a line with a quote character or a command-line switch is refused.
##
## The second suite below pins each refusal arm INDEPENDENTLY: every fixture
## there is refused by exactly one arm, so deleting that arm turns exactly
## that test red (mutation-proven; see the handoff's round-6 table).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_cc_banner_selection.nim

import std/[unittest, strutils]
import crisol/ccidentity
import crisol/toolrun      # RunProc

const
  TestDigest = "aaaaaaaaaaaaaaaa"

  MingwGccBanner =
    "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0\n" &
    "Copyright (C) 2023 Free Software Foundation, Inc."

  ClBannerLine =
    "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64"

  ClBannerEn =
    ClBannerLine & "\n" &
    "Copyright (C) Microsoft Corporation.  All rights reserved.\n" &
    "usage: cl [ option... ] filename... [ /link linkoption... ]\n"

  ClBannerDe =
    "Microsoft (R) C/C++-Optimierungscompiler Version 19.44.35228 für x64\n" &
    "Copyright (C) Microsoft Corporation. Alle Rechte vorbehalten.\n" &
    "Syntax: cl [ Option... ] Dateiname... [ /link Linkeroption... ]\n"

  ClBannerJa =
    "使用法: cl [ オプション... ] ファイル名...\n" &
    "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 (x64) 用コンパイラ\n" &
    "著作権 (C) Microsoft Corporation.  All rights reserved.\n"

  CaseA =
    "cl : Command line warning D9024 : unrecognized source file type " &
    "'10.0.22621.0', object file assumed\n"

  CaseB =
    "cl : Command line warning D9024 : unrecognized source file type\n" &
    "'10.0.22621.0', object file assumed\n"

  CaseC =
    "cl : Command line error D9002 : ignoring unknown option\n" &
    "'/I C:\\Python3.11\\include'\n"
    ## The continuation's `3.11` is not itself quote-flanked (`n` before it,
    ## `\` after), so R5-4's `quoteFlanked` passed it and so did every other
    ## anchor: no prefix, no code, no English phrase on that line.

  CaseD =
    "cl /nologo /I C:\\Python3.11\\include unit.c\n"
    ## `cl` echoing its own argv: no banner, no diagnostic anchor, one dotted
    ## token embedded in a path.

  CaseE =
    "LINK : fatal error LNK1104: cannot open file 'kernel32.lib'\n" &
    "C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\10.0.22621.0\\um\\x64\n"
    ## The diagnostic line carries no dotted token, so `versionLine` skipped it
    ## and selected the unprefixed SDK path below it.

proc makeFixedHash(digest: string): BinHashProc =
  result = proc(path: string): string =
    if path.len == 0: FileHashSentinel else: digest

proc makeWinRun(clOut: string; gccOut = ""): RunProc =
  ## `cl`/`vccexe` answer `clOut` with `ok = true`; `gcc` answers `gccOut` when
  ## that is non-empty and FAILS otherwise; every other candidate fails.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl", "vccexe":
      (output: clOut, ok: true)
    of "gcc":
      if gccOut.len > 0: (output: gccOut, ok: true)
      else:              (output: "", ok: false)
    else:
      (output: "", ok: false)

proc winHalf(clOut: string; gccOut = ""): CcHalf =
  ccIdentity(makeWinRun(clOut, gccOut), WindowsCcProfile,
             makeFixedHash(TestDigest))

proc withKnownRuntime(compiler: CcHalf): CcFingerprint =
  ## The Windows runtime half always carries a content digest, so the
  ## compiler half is the only thing that can make this fingerprint unsound.
  CcFingerprint(
    compiler: compiler,
    runtime: CcHalf(state: cfsKnown, text: "libcmt+libucrt+libvcruntime",
                    digest: CcDigest(kind: cdkKnown, hex: "abc123abc123abc1")))

template checkRefused(clOut: string) =
  ## Refused beside a versioned bystander (R4-1's laundering shape) AND alone
  ## (R5-4's constant-folded-diagnostic shape); unsound either way, and
  ## flagged as a driver that ANSWERED rather than one that was absent. A
  ## template, not a proc: `check` must expand inside the `test` body or its
  ## failure is not attributed to that test (the run still exits 1, but every
  ## test reports OK -- which would make the mutation table unreadable).
  for gccOut in [MingwGccBanner, ""]:
    let half = winHalf(clOut, gccOut)
    checkpoint("gcc bystander = " & $(gccOut.len > 0))
    check half.state == cfsUnavailable
    if half.state == cfsUnavailable:
      check half.answeredUnidentified
    check toolchainUnsound(withKnownRuntime(half))

suite "ccIdentity (Windows) — the line judged is the line folded (R6 matrix)":

  test "A: a one-line D9024 echoing an SDK version is refused":
    checkRefused(CaseA)

  test "B: the same D9024 wrapped onto two lines is refused":
    checkRefused(CaseB)

  test "C: a wrapped D9002 whose continuation holds an unquoted 3.11 in a quoted path is refused":
    checkRefused(CaseC)

  test "D: a bare echoed command line carrying a dotted token is refused":
    checkRefused(CaseD)

  test "E: a LINK fatal error plus an unprefixed SDK-path line is refused":
    checkRefused(CaseE)

  test "F1: banner first, then a D9024 line -- the banner is believed and is the whole text":
    let half = winHalf(ClBannerEn & CaseA)
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text == ClBannerLine
    check not toolchainUnsound(withKnownRuntime(half))

  test "F2: the SAME two lines diagnostic-first -- the SAME verdict and the SAME text":
    ## The verdict must not depend on which of two merged pipes flushed first.
    let f1 = winHalf(ClBannerEn & CaseA)
    let f2 = winHalf(CaseA & ClBannerEn)
    check f2.state == cfsKnown
    check f2 == f1
    if f2.state == cfsKnown:
      check f2.text == ClBannerLine
      check "D9024" notin f2.text

  test "F2 beside a bystander: both banners fold, and nothing of the diagnostic does":
    let half = winHalf(CaseA & ClBannerEn, MingwGccBanner)
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text == ClBannerLine & "; gcc.exe (Rev3, Built by MSYS2 project) 13.2.0"
      check "10.0.22621.0" notin half.text

  test "CONTROL a localized banner (de, ja) is still believed and still publishes":
    for banner in [ClBannerDe, ClBannerJa]:
      checkpoint("banner = " & banner)
      let half = winHalf(banner)
      check half.state == cfsKnown
      if half.state == cfsKnown:
        check "19.44.35228" in half.text
        check "Copyright" notin half.text
      check not toolchainUnsound(withKnownRuntime(half))

  test "CONTROL the healthy MSVC + mingw host folds both banners":
    let half = winHalf(ClBannerEn, MingwGccBanner)
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text.split("; ").len == 2
    check not toolchainUnsound(withKnownRuntime(half))

  test "CONTROL a candidate that is ABSENT does not mark the half as refused":
    ## Nothing answered at all: unavailable, but NOT `answeredUnidentified` --
    ## the distinction the warning ladder in `api.nim` reports on.
    let half = ccIdentity(
      proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
        (output: "", ok: false),
      WindowsCcProfile, makeFixedHash(TestDigest))
    check half.state == cfsUnavailable
    if half.state == cfsUnavailable:
      check not half.answeredUnidentified

# ---------------------------------------------------------------------------
# One fixture per refusal arm. Each is refused by EXACTLY ONE arm of
# `namesCompilerVersion`, so deleting that arm turns exactly that test red.
# Each is otherwise shaped like a banner: a free-standing, three-component
# version token and nothing else any other arm would catch.
# ---------------------------------------------------------------------------

const
  OnlyPhrase =
    "Command line warning: SDK 10.0.22621.0 not found, using the default\n"
    ## Prefix-less (the text before the colon has spaces), no code, no quote,
    ## no switch, a free-standing token. Only the English phrase refuses it.

  OnlyToolColonPrefix =
    "vccexe: could not find toolset 14.38.33130 under VCToolsInstallDir\n"

  OnlyDiagnosticCode =
    "Befehlszeilenwarnung D9025 : Toolset 14.38.33130 wird überschrieben\n"
    ## German prose, and the program name has been lost (text before the first
    ## colon has a space in it), so neither the phrase nor the prefix fires.
    ## Only the untranslated code `D9025` is left to refuse it.

  OnlyQuote =
    "cl : Command line warning D9024 : unrecognized source file type 'C:\\Tools\\SDK\n" &
    "6.5.3 beta', object file assumed\n"
    ## The continuation's token is its own word on both sides, so only "a
    ## banner never contains a quote character" refuses that line. (The first
    ## line carries no dotted token at all.)

  OnlySwitch =
    "cl /nologo /Zs unit.c 10.0.22621.0\n"
    ## An echoed argv whose dotted argument is its own word.

  OnlyLeftBoundary =
    "C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\10.0.22621.0\n"
    ## The token ends the line (right side free) but is glued to a `\` on the
    ## left: a path component, not a version the line states.

  OnlyRightBoundary =
    "10.0.22621.0\\um\\x64\\kernel32.lib\n"
    ## A wrapped path's continuation: the token starts the line (left side
    ## free) and is glued to a `\` on the right.

  OnlyThreeComponents =
    "vccexe: could not find the Microsoft Visual C++\n" &
    "14.0 toolchain\n"
    ## A wrapped diagnostic whose continuation carries a free-standing
    ## TWO-component token. Every compiler this profile asks prints
    ## major.minor.patch or longer.

suite "namesCompilerVersion — every refusal arm is independently load-bearing":

  test "arm: English diagnostic phrase":
    checkRefused(OnlyPhrase)

  test "arm: <program>: prefix":
    checkRefused(OnlyToolColonPrefix)

  test "arm: MSVC diagnostic code (hasDiagnosticCode)":
    checkRefused(OnlyDiagnosticCode)

  test "arm: a quote character anywhere on the line":
    checkRefused(OnlyQuote)

  test "arm: a command-line switch token":
    checkRefused(OnlySwitch)

  test "arm: version token glued on the LEFT":
    checkRefused(OnlyLeftBoundary)

  test "arm: version token glued on the RIGHT":
    checkRefused(OnlyRightBoundary)

  test "arm: fewer than three version components":
    checkRefused(OnlyThreeComponents)

  test "CONTROL each arm's fixture, with that one defect removed, IS believed":
    ## Proves the fixtures isolate: strip the single feature each arm keys on
    ## and the line becomes a banner. Without this, a fixture refused by two
    ## arms would pass every mutation but one silently.
    for believable in [
        "SDK 10.0.22621.0 not found, using the default",       # phrase removed
        "could not find toolset 14.38.33130 under VCToolsInstallDir",  # prefix removed
        "Befehlszeilenwarnung Toolset 14.38.33130 wird überschrieben", # code removed
        "6.5.3 beta, object file assumed",                     # quote removed
        "cl nologo Zs unit.c 10.0.22621.0",                    # switches removed
        "Lib 10.0.22621.0",                                    # left glue removed
        "10.0.22621.0 um x64 kernel32.lib",                    # right glue removed
        "14.0.1 toolchain"]:                                   # third component added
      checkpoint("line = " & believable)
      let half = winHalf(believable & "\n")
      check half.state == cfsKnown
      if half.state == cfsKnown:
        check half.text == believable

suite "toolchainUnsoundReason — the warning ladder can tell a refused driver from an absent one":

  test "a driver that ANSWERED with only a diagnostic is reported as such":
    ## Before R6 this fell through to "a compiler driver or a runtime library
    ## answered, but not both" -- false: the compiler DID answer.
    check toolchainUnsoundReason(withKnownRuntime(winHalf(CaseA))) ==
          turCompilerRefused

  test "no driver answered, runtime known: half missing":
    check toolchainUnsoundReason(withKnownRuntime(CcHalf(state: cfsUnavailable))) ==
          turHalfMissing

  test "neither half: blind":
    check toolchainUnsoundReason(CcFingerprint(
      compiler: CcHalf(state: cfsUnavailable),
      runtime: CcHalf(state: cfsUnavailable))) == turBlind

  test "refused driver AND no runtime: still reported as refused, not as blind":
    ## "Neither answered" would be false here too.
    check toolchainUnsoundReason(CcFingerprint(
      compiler: winHalf(CaseA),
      runtime: CcHalf(state: cfsUnavailable))) == turCompilerRefused

  test "both known, digest-less diagnostic text: the backstop's own reason":
    check toolchainUnsoundReason(withKnownRuntime(
      CcHalf(state: cfsKnown, text: CaseA.strip, digest: CcDigest(kind: cdkNone)))) ==
          turCompilerUnnamed

  test "sound fingerprint: no reason":
    check toolchainUnsoundReason(withKnownRuntime(winHalf(ClBannerEn))) == turSound

# ---------------------------------------------------------------------------
# R7-S1 (round-7 review): a driver that EXITS NON-ZERO is present, not absent.
#
# Measured on the real toolchain (ghcr.io/coreyleavitt/nim:2.2.10-windows, cl
# 19.44.35228, through `realRunMerged`): with ANY non-empty `CL`, `cl` and
# `vccexe` with no arguments print cl's D8003 and EXIT 2. `ccIdentity` read
# `not ok` as "absent" and dropped them silently, so on a host with a bystander
# gcc the bystander's banner became the whole compiler half (`turSound`, L2
# publish) while cl compiled; with no bystander the warning said "half
# missing". An absent candidate comes back `ok = false` with EMPTY output
# (spawn failure); `vccexe` on a host with no reachable cl comes back
# `ok = false` with a Nim traceback and no cl output at all. The fixtures
# below are those captures, verbatim modulo CRLF.
# ---------------------------------------------------------------------------

const
  ClW4Out =
    ClBannerLine & "\n" &
    "Copyright (C) Microsoft Corporation.  All rights reserved.\n\n" &
    "cl : Command line error D8003 : missing source filename\n"
    ## `CL=/W4`: the full banner AND exit 2.

  ClNologoOut = "cl : Command line error D8003 : missing source filename\n"
    ## `CL=/nologo`: only the D8003, exit 2.

  VccexeNoClOut =
    "Hint: vcvarsall.bat was not found\n" &
    "oserrors.nim(92)         raiseOSError\n" &
    "Error: unhandled exception: The system cannot find the file specified.\n" &
    "Additional info: Requested command not found: 'cl.exe'. OS error: [OSError]\n"
    ## `vccexe` on a Nim + mingw host with no MSVC: exit 1. The WRAPPER ran;
    ## the toolset it wraps is absent.

type Reply = tuple[output: string, ok: bool]

proc makeTableRun(cl, vccexe, gcc: Reply): RunProc =
  ## Every other candidate is ABSENT, in the shape the real seam gives it.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "cl":     cl
    of "vccexe": vccexe
    of "gcc":    gcc
    else:        (output: "", ok: false)

const
  Absent: Reply = (output: "", ok: false)
  GccOk: Reply = (output: MingwGccBanner, ok: true)

proc tableHalf(cl, vccexe, gcc: Reply): CcHalf =
  ccIdentity(makeTableRun(cl, vccexe, gcc), WindowsCcProfile,
             makeFixedHash(TestDigest))

template checkRefusedBy(half: CcHalf; drivers: seq[string]) =
  check half.state == cfsUnavailable
  check half.answeredUnidentified
  if half.state == cfsUnavailable:
    check half.refusedDrivers == drivers
  check toolchainUnsoundReason(withKnownRuntime(half)) == turCompilerRefused

suite "ccIdentity (Windows) — a driver that exits non-zero is present (R7-S1)":

  test "CL=/W4 with a gcc bystander: refused, and gcc does NOT stand in":
    let h = tableHalf((ClW4Out, false), (ClW4Out, false), GccOk)
    checkRefusedBy(h, @["cl", "vccexe"])

  test "CL=/W4 with no bystander: refused (not 'half missing')":
    let h = tableHalf((ClW4Out, false), (ClW4Out, false), Absent)
    checkRefusedBy(h, @["cl", "vccexe"])

  test "CL=/nologo with a gcc bystander: refused":
    let h = tableHalf((ClNologoOut, false), (ClNologoOut, false), GccOk)
    checkRefusedBy(h, @["cl", "vccexe"])

  test "plain shell (cl not on PATH), CL set: vccexe relays cl's answer and is refused":
    let h = tableHalf(Absent, (ClW4Out, false), GccOk)
    checkRefusedBy(h, @["vccexe"])

  test "wrapper evidence arm: a relayed diagnostic CODE alone refuses vccexe":
    ## No banner on the line: only `hasDiagnosticCode` says cl answered.
    let h = tableHalf(Absent, (ClNologoOut, false), GccOk)
    checkRefusedBy(h, @["vccexe"])

  test "wrapper evidence arm: a relayed BANNER alone refuses vccexe":
    ## No diagnostic code anywhere: only the banner says cl answered.
    let h = tableHalf(Absent, (ClBannerLine & "\n", false), GccOk)
    checkRefusedBy(h, @["vccexe"])

  test "driver arm: a DIRECT driver exiting non-zero is refused whatever it printed":
    ## No banner and no code: a wrapper would be read as absent here, a
    ## driver that was spawned cannot be.
    let h = tableHalf(Absent, Absent, (output: "gcc: internal failure\n", ok: false))
    checkRefusedBy(h, @["gcc"])

  test "CONTROL a mingw-only host: vccexe's missing-cl traceback is ABSENCE, gcc is believed":
    let h = tableHalf(Absent, (VccexeNoClOut, false), GccOk)
    check h.state == cfsKnown
    if h.state == cfsKnown:
      check h.text == "gcc.exe (Rev3, Built by MSYS2 project) 13.2.0"
    check not h.answeredUnidentified

  test "CONTROL _CL_=/W4 (cl ignores it with no arguments): identical to plain, believed":
    let h = tableHalf((ClBannerEn, true), (ClBannerEn, true), GccOk)
    check h.state == cfsKnown
    check not toolchainUnsound(withKnownRuntime(h))

  test "R8-L3: a DIRECT driver that exited non-zero printing only whitespace is present, and refused":
    ## Under `RunProc`'s contract only `""` means "did not run", so a capture
    ## of only spaces and newlines came from a process that ran and failed.
    ## Before R8 `presentButFailed` stripped first and read it as absent, so
    ## the bystander gcc stood in for a cl that had run.
    let h = tableHalf((" \r\n\t\n", false), Absent, GccOk)
    checkRefusedBy(h, @["cl"])

  test "R8-L3 CONTROL a WRAPPER printing only whitespace relays nothing: absent, gcc believed":
    let h = tableHalf(Absent, (" \r\n", false), GccOk)
    check h.state == cfsKnown
    check not h.answeredUnidentified

  test "CONTROL every candidate absent: unavailable, NOT refused":
    let h = tableHalf(Absent, Absent, Absent)
    check h.state == cfsUnavailable
    check not h.answeredUnidentified
    check toolchainUnsoundReason(withKnownRuntime(h)) == turHalfMissing

# ---------------------------------------------------------------------------
# R7-D1 / R7-L4 (round-7 review): the quote arm and `freeStanding`'s right side.
# ---------------------------------------------------------------------------

const
  ClBannerFrLine =
    "Compilateur d'optimisation Microsoft (R) C/C++ version 19.44.35228 pour x64"

suite "namesCompilerVersion — an elision is not a quote; boundaries are observed (R7)":

  test "CONTROL a French banner (an elision apostrophe, d'optimisation) is believed":
    let half = winHalf(ClBannerFrLine & "\n" &
                       "Copyright (C) Microsoft Corporation. Tous droits réservés.\n")
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text == ClBannerFrLine
    check not toolchainUnsound(withKnownRuntime(half))

  test "CONTROL an elision before a NON-ASCII letter (l'éditeur) is believed":
    ## R8-L2: `ElisionSide`'s non-ASCII range, observed. The byte after the
    ## apostrophe is 0xC3 (UTF-8 for `é`), which is not in `Letters`, so
    ## only that range keeps this line a banner. SYNTHETIC -- the wording is
    ## not a measured MSVC banner; the shape (a French elision before an
    ## accented letter) is ordinary French.
    let line = "Compilateur de l'éditeur Microsoft (R) C/C++ version 19.44.35228 pour x64"
    let half = winHalf(line & "\n")
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text == line
    check not toolchainUnsound(withKnownRuntime(half))

  test "an apostrophe that is NOT between two letters is still a quote":
    ## Same shape as OnlyQuote's continuation, spelled with the quote glued to
    ## a word on one side only.
    checkRefused("SDK 6.5.3 beta' object file assumed\n")

  test "CONTROL a distro-suffixed version (`-` on the right) is believed":
    let line = "Ubuntu clang version 14.0.0-1ubuntu1.1"
    let half = winHalf(line & "\n")
    check half.state == cfsKnown
    if half.state == cfsKnown:
      check half.text == line

  # R7-L4: `(` on the left and `)`/`,`/`;` on the right were admitted as word
  # boundaries and observed by nothing. No banner the profile asks for states
  # its version that way (`... Version 19.44.35228 for x64`, `... 13.2.0`,
  # `clang version 17.0.6 (...)`: space or end of line on both sides), so they
  # are gone. One fixture per removed character, each glued on ONE side only,
  # so restoring any single one turns exactly its own case red.
  test "a version opened by `(` is refused":
    checkRefused("Some Compiler Version (19.44.35228 for x64\n")

  test "a version closed by `)` is refused":
    checkRefused("Some Compiler Version 19.44.35228) for x64\n")

  test "a version followed by `,` is refused":
    checkRefused("Some Compiler Version 19.44.35228, for x64\n")

  test "a version followed by `;` is refused":
    checkRefused("Some Compiler Version 19.44.35228; for x64\n")
