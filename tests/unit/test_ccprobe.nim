## test_ccprobe.nim -- unit tests for `crisol/ccprobe` (the C dependency
## probe: manifest-command replay, `-M` / `/sourceDependencies` parsing) and
## the real runners in `crisol/toolrun` it spawns through.
##
## The parser and derivation suites are synthetic and run on both platforms.
## The runner suites at the bottom run binaries at absolute POSIX paths and are
## POSIX-gated, each with a `CRISOL-SKIP-TEST` marker on Windows. The C
## toolchain IDENTITY is tested in `tests/unit/test_ccidentity.nim`.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_ccprobe.nim

import std/[options, os, unittest, sequtils, strutils, tempfiles]
import crisol/ccprobe      # ccFamilyOfDriver/deriveDepInvocation/depIncludeHeaders/parseCcMDeps
import crisol/toolrun      # RunResult/realRun/realRunMerged/realRunIn
import crisol/paths        # ReportedPath -- depIncludeHeaders/parseCcMDeps yield it
import crisol/closure      # ccCmdOutputObj, driven from the same ccCmd fixtures
                           # as deriveDepInvocation (the shared GNU -o grammar)

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

  test "matching Source (same basename, different case/separator/absoluteness) is accepted, headers kept":
    let probed = depIncludeHeaders(ccfMsvc, MsvcRealReport, "c:/p/native/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)).len == 2

  test "a DIFFERENT Source is dpeSourceMismatch, a DepProbeError like any other (empty headers)":
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
    check probed.err == dpeSourceMismatch
    check probed.headers.mapIt(string(it)).len == 0   # never a usable-but-suspicious header set

  test "case and separator differences alone are NOT a mismatch (cl lowercases and may absolutize)":
    let doc = """unit.c
{ "Version": "1.2", "Data": { "Source": "C:\\P\\NATIVE\\ADD.C",
  "Includes": [ "c:/p/native/add.h" ] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, doc, "add.c")   # relative, unlike the doc's absolute+uppercased spelling
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["c:/p/native/add.h"]

  test "no Source field in the document at all is not a mismatch":
    let noSource = """unit.c
{ "Version": "1.2", "Data": { "Includes": [ "a.h" ] } }
"""
    let probed = depIncludeHeaders(ccfMsvc, noSource, "u.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["a.h"]

suite "depIncludeHeaders (GNU) — a make rule for the probed source":

  test "a make-style rule parses, the source itself excluded":
    let rule = "/c/obj.o: /c/src.c /c/a.h \\\n  /c/b.h\n"
    let probed = depIncludeHeaders(ccfGnu, rule, "/c/src.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["/c/a.h", "/c/b.h"]

  test "a rule for a source that includes nothing is a real, empty answer":
    let probed = depIncludeHeaders(ccfGnu, "src.o: src.c\n", "src.c")
    check probed.err == dpeNone
    check probed.headers.len == 0

  test "EMPTY stdout (gcc -M -MMD, measured: exit 0, rule written to a .d file) is dpeNoMakeRule":
    let probed = depIncludeHeaders(ccfGnu, "", "native/add.c")
    check probed.err == dpeNoMakeRule
    check probed.headers.len == 0

  test "whitespace-only stdout is dpeNoMakeRule":
    check depIncludeHeaders(ccfGnu, "\n\r\n  \n", "native/add.c").err == dpeNoMakeRule

  test "preprocessed source on stdout (clang -M -MMD, measured) is dpeNoMakeRule":
    let clangMMd = "# 1 \"native/add.c\"\n# 1 \"<built-in>\" 1\n" &
      "# 1 \"<built-in>\" 3\n# 412 \"<built-in>\" 3\n# 1 \"<command line>\" 1\n" &
      "# 1 \"<built-in>\" 2\n# 1 \"native/add.c\" 2\n# 1 \"native/add.h\" 1\n" &
      "int add(int a, int b);\n# 2 \"native/add.c\" 2\n" &
      "int add(int a, int b) { return a + b; }\n"
    let probed = depIncludeHeaders(ccfGnu, clangMMd, "native/add.c")
    check probed.err == dpeNoMakeRule
    check probed.headers.len == 0

  test "preprocessed source that happens to contain a colon is still dpeNoMakeRule":
    let text = "# 1 \"u.c\"\nint f(int x) { switch (x) { case 1: return 2; } return 0; }\n"
    check depIncludeHeaders(ccfGnu, text, "u.c").err == dpeNoMakeRule

  test "a macro dump (gcc -M -dM, measured) is dpeNoMakeRule":
    let dump = "#define __DBL_MIN_EXP__ (-1021)\n#define __LDBL_MANT_DIG__ 64\n"
    check depIncludeHeaders(ccfGnu, dump, "u.c").err == dpeNoMakeRule

  test "a second rule (gcc -M -MP phony targets, measured) is dpeNoMakeRule":
    let mp = "add.o: native/add.c /usr/include/stdc-predef.h native/add.h\n" &
             "/usr/include/stdc-predef.h:\nnative/add.h:\n"
    check depIncludeHeaders(ccfGnu, mp, "native/add.c").err == dpeNoMakeRule

  test "a rule whose first prerequisite is a DIFFERENT source is dpeSourceMismatch":
    let probed = depIncludeHeaders(ccfGnu, "o.o: other.c a.h\n", "native/add.c")
    check probed.err == dpeSourceMismatch
    check probed.headers.len == 0

  test "a rule with no prerequisites at all is dpeSourceMismatch":
    check depIncludeHeaders(ccfGnu, "add.o:\n", "native/add.c").err == dpeSourceMismatch

  test "the probed source is matched after make-rule unescaping (a space in its path)":
    let probed = depIncludeHeaders(ccfGnu, "a.o: my\\ dir/add.c my\\ dir/a.h\n",
                                   "my dir/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["my dir/a.h"]

  test "a CRLF-terminated mingw rule with continuations is accepted":
    let rule = "C:/p/add.o: C:/p/add.c \\\r\n C:/p/inc/top.h\r\n"
    let probed = depIncludeHeaders(ccfGnu, rule, "C:/p/add.c")
    check probed.err == dpeNone
    check probed.headers.mapIt(string(it)) == @["C:/p/inc/top.h"]

suite "deriveDepInvocation (GNU) — dependency-output and output-mode flags are not replayed":
  ## Measured against gcc 13 / clang 18 in ghcr.io/coreyleavitt/nim:2.2.10:
  ## `-MD`/`-MMD`/`-MF`/`--write-dependencies`/`-Wp,-MD,f` beside `-M` leave
  ## stdout empty (gcc) or print preprocessed source (clang); `-MP` appends
  ## phony rules; `-MM`/`--user-dependencies` drop system-directory headers
  ## (including ones reached through `-isystem`); `-dM` replaces the rule
  ## with a macro dump. None of them may reach the probe.

  proc gnuArgs(extra: string): seq[string] =
    let inv = deriveDepInvocation("gcc -c " & extra & " -I/p/inc -o /p/nc/u.o /p/u.c")
    doAssert inv.ok
    inv.args

  test "every standalone dependency/output-mode flag is dropped, the rest replayed verbatim":
    for flag in ["-MD", "-MMD", "-MP", "-MG", "-MM", "-M", "-MV", "-E", "-S",
                 "-save-temps", "-save-temps=obj", "-save-temps=cwd",
                 "--dependencies", "--user-dependencies", "--write-dependencies",
                 "--write-user-dependencies", "--print-missing-file-dependencies",
                 "-dM", "-dD", "-dN", "-dI", "-dU",
                 "-fdeps-format=p1689r5", "-fdeps-file=u.ddi", "-fdeps-target=u.o"]:
      let args = gnuArgs("-w " & flag & " -DKEEP=1")
      check args == @["-M", "-w", "-DKEEP=1", "-I/p/inc", "/p/u.c"]

  test "an argument-taking dependency flag is dropped WITH its argument, separated or fused":
    for extra in ["-MF /p/nc/u.d", "-MF/p/nc/u.d", "-MT tgt", "-MTtgt",
                  "-MQ tgt", "-MQtgt", "-MJ /p/nc/u.json", "-MJ/p/nc/u.json"]:
      let args = gnuArgs("-w " & extra & " -DKEEP=1")
      check args == @["-M", "-w", "-DKEEP=1", "-I/p/inc", "/p/u.c"]

  test "-Wp, lists lose only their dependency options; other preprocessor options survive":
    check gnuArgs("-Wp,-MD,/p/nc/u.d") == @["-M", "-I/p/inc", "/p/u.c"]
    check gnuArgs("-Wp,-MMD,/p/nc/u.d") == @["-M", "-I/p/inc", "/p/u.c"]
    check gnuArgs("-Wp,-DFOO,-MD,/p/nc/u.d,-UBAR") ==
      @["-M", "-Wp,-DFOO,-UBAR", "-I/p/inc", "/p/u.c"]
    check gnuArgs("-Wp,-MF,x.d,-MP,-MT,t,-MQ,q,-MG,-M,-MM,-DK") ==
      @["-M", "-Wp,-DK", "-I/p/inc", "/p/u.c"]
    check gnuArgs("-Wp,-DFOO") == @["-M", "-Wp,-DFOO", "-I/p/inc", "/p/u.c"]

  test "-Xpreprocessor pairs lose only their dependency options":
    check gnuArgs("-Xpreprocessor -MD -Xpreprocessor /p/nc/u.d") ==
      @["-M", "-I/p/inc", "/p/u.c"]
    check gnuArgs("-Xpreprocessor -MP -Xpreprocessor -DFOO") ==
      @["-M", "-Xpreprocessor", "-DFOO", "-I/p/inc", "/p/u.c"]

  test "CONTROL look-alike flags that do not touch dependency output are kept":
    for flag in ["-MSVC-looking-but-not", "-march=native", "-D-MD", "-fdump-tree-all",
                 "-dumpbase", "-pipe", "-fsyntax-only", "-isystem/p/sys", "-Wp,-DONLY"]:
      let args = gnuArgs(flag)
      check flag in args

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
    let probed = depIncludeHeaders(ccfGnu, rule, "src.c")
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
    let probed = depIncludeHeaders(ccfGnu, rule, "C:/proj/add.c")
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
    let probed = depIncludeHeaders(ccfGnu, rule, "src.c")
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
    # A backslash path classifies the same on a POSIX host as on Windows.
    check ccFamilyOfDriver("C:\\Program Files\\VC\\bin\\cl.exe") == ccfMsvc
    check ccFamilyOfDriver("C:\\mingw\\bin\\gcc.exe") == ccfGnu

  test "gcc-family drivers classify as ccfGnu":
    check ccFamilyOfDriver("cc") == ccfGnu
    check ccFamilyOfDriver("gcc") == ccfGnu
    check ccFamilyOfDriver("clang") == ccfGnu
    check ccFamilyOfDriver("/usr/bin/x86_64-linux-gnu-gcc-13") == ccfGnu
    check ccFamilyOfDriver("") == ccfGnu

  test "`clang` is NOT `clang-cl` — the prefix must not decide":
    check ccFamilyOfDriver("clang") == ccfGnu
    check ccFamilyOfDriver("clang-cl") == ccfMsvc

suite "deriveDepInvocation — both arms prepend the probe and strip the compile action and output (issue #21)":

  test "the MSVC arm drops /c and /Fo<obj> and keeps every other flag in order":
    ## `/Zs` without `/c` neither links nor writes an object (measured, cl
    ## 19.44: `cl /Zs /sourceDependencies- /Iinc a.c` leaves the directory
    ## unchanged and prints the same report as with `/c /Foout.obj`), so the
    ## probe cannot rewrite the nimcache object whether or not they survive;
    ## dropping them makes both arms read the command through one parse.
    let inv = deriveDepInvocation(
      "vccexe.exe /c --platform:amd64 /nologo /IC:/p/tests /FoC:/p/nc/u.obj C:/p/u.c")
    check inv.ok
    check inv.family == ccfMsvc
    check inv.cmd == "vccexe.exe"
    check inv.sourceFile == "C:/p/u.c"
    check inv.args == @["/Zs", "/sourceDependencies-", "--platform:amd64",
                        "/nologo", "/IC:/p/tests", "C:/p/u.c"]

  test "the GNU arm is untouched: -M prepended, -c and -o <obj> dropped":
    let inv = deriveDepInvocation("gcc -c -I/p/inc -o /p/nc/u.o /p/u.c")
    check inv.ok
    check inv.family == ccfGnu
    check inv.args[0] == "-M"
    check "-c" notin inv.args
    check "-o" notin inv.args
    check "/p/nc/u.o" notin inv.args
    check "-I/p/inc" in inv.args
    check inv.args[^1] == "/p/u.c"

  test "an untokenizable command degrades to ok=false, never raises":
    let inv = deriveDepInvocation("gcc -c \"unterminated /p/u.c")
    check (not inv.ok)

suite "deriveDepInvocation and closure.ccCmdOutputObj read the output through one parse":
  ## One fact -- which token(s) spell the output object -- has two
  ## consumers: `deriveDepInvocation` STRIPS it out of a dependency-probe
  ## replay, `closure.ccCmdOutputObj` EXTRACTS its value to pair a `compile`
  ## manifest entry with its `link` object. Both read `parseCompileCommand`;
  ## these tests drive BOTH from the SAME `ccCmd` so a future edit to one
  ## that the other does not follow fails a test instead of silently
  ## diverging.

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
# Real runners: binaries at absolute POSIX paths.
# -----------------------------------------------------------------------------
when defined(posix):
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
      let r = realRun("/bin/sh", ["-c", "echo $#", "--", "one two"])
      check r.ok
      let trimmed = r.output.strip()
      check trimmed == "1"

    test "realRun returns ok=true for a command that exits 0":
      ## rfc-0007 C1a: `true`/`false` live at /bin/true and /bin/false on
      ## Linux but only at /usr/bin/true and /usr/bin/false on macOS — a
      ## PATH lookup is the portable spelling on both, not a platform branch.
      check realRun(findExe("true"), []).ok

    test "realRun returns ok=false for a command that exits non-zero":
      let r = realRun(findExe("false"), [])
      check not r.ok
      check r.ending == reExited
      check r.exitCode == 1

    test "realRun captures stdout output":
      let r = realRun("/bin/echo", ["hello"])
      check r.ok
      check r.output.strip() == "hello"

  # ---------------------------------------------------------------------------
  # Suite 5: realRunIn — rfc-0007 A2c (issue #17): the returned RunProc always
  # spawns its subprocess with the GIVEN workingDir, regardless of the calling
  # process's own cwd.
  # ---------------------------------------------------------------------------

  suite "realRunIn — subprocess cwd is the given workingDir, not the caller's":

    test "the subprocess sees workingDir as its cwd even when the caller's cwd differs":
      # A fresh, uniquely named directory (R3-13): a predictable name in the
      # shared temp dir could already be a symlink someone planted, which
      # `createDir` accepts and the cleanup's `removeDir` would follow.
      let target = createTempDir("crisol_ccprobe_realrunin_", "")
      defer: removeDir(target)

      let savedCwd = getCurrentDir()
      setCurrentDir(getTempDir())   # deliberately NOT `target`
      defer: setCurrentDir(savedCwd)

      let run = realRunIn(target)
      let r = run("/bin/pwd", [])
      check r.ok
      let output = r.output
      # rfc-0007 C1a: compare against the REALPATH (symlinks resolved), not
      # the lexical absolutePath — `chdir`'s effective cwd (what `pwd`
      # actually observes via getcwd(2)) is inherently the resolved path.
      # On Linux getTempDir() ("/tmp") is not itself a symlink, so this is a
      # no-op there; on macOS getTempDir() routes through /var ->
      # /private/var, so the two forms genuinely differ.
      check output.strip() == target.expandFilename.normalizedPath

    test "workingDir = \"\" behaves exactly like realRun (inherits the caller's cwd)":
      let run = realRunIn("")
      let r = run("/bin/echo", ["hello"])
      check r.ok
      check r.output.strip() == "hello"

  # ---------------------------------------------------------------------------
  # W9a: a separate-stream run's stderr is part of its result, so a caller
  # can recover the driver's own diagnostic.
  # ---------------------------------------------------------------------------

  suite "RunResult.errOutput — W9a: a separate-stream run keeps its stderr":

    test "stdout and stderr land in their own fields":
      let r = realRun("/bin/sh", ["-c", "echo out-line; echo err-line 1>&2"])
      check r.ok
      check r.output.strip() == "out-line"
      check r.errOutput.strip() == "err-line"

    test "exit 0 with nothing useful on stdout still surfaces its stderr (the D9002 shape)":
      ## Models the measured old-cl behaviour: exit 0, stdout is a bare
      ## banner, and the real explanation ("ignoring unknown option") is on
      ## stderr.
      let r = realRun("/bin/sh",
        ["-c", "echo banner-only; echo cl : warning D9002 : ignoring unknown option 1>&2"])
      check r.ok
      check r.output.strip() == "banner-only"
      check "D9002" in r.errOutput

    test "a MERGED run (realRunMerged) has both streams in output and no errOutput":
      let r = realRunMerged("/bin/sh", ["-c", "echo out-line; echo err-line 1>&2"])
      check r.ok
      check "out-line" in r.output
      check "err-line" in r.output
      check r.errOutput == ""


# -----------------------------------------------------------------------------
# R10-S1: `cl /sourceDependencies` lowercases NON-ASCII letters too. Measured
# on cl 19.44 in the MSVC image: a project rooted at `C:\poc\Ärger` reports
# its header as `c:\poc\ärger\inc\myheader.h` (`Ä` is C3 84, `ä` is C3 A4; the
# JSON is valid UTF-8). A byte-wise ASCII fold cannot see that spelling as
# lying under the root, so it classified `pcOutside`, was not reported as
# unresolved, and the closure dropped the header without a word.
# -----------------------------------------------------------------------------

suite "R10-S1 -- a non-ASCII root lowercased by cl is resolved or refused, never dropped":
  const RootSpelling = "C:\\poc\\Ärger"
  const Reported = "c:\\poc\\ärger\\inc\\myheader.h"
  const OnDisk = "C:/poc/Ärger/Inc/MyHeader.h"

  proc rootsFor(policy: FoldPolicy): TrackedRoots =
    initTrackedRoots(RootSpelling, @[], "",
      proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy))

  proc resolvingExpand(p: string): string =
    ## Models GetFinalPathNameByHandleW: any spelling of the one real file
    ## comes back as its on-disk spelling. The comparison is spelled out
    ## against the reported form (after classify's own canonicalization)
    ## rather than folded, so the model cannot share a folding bug with the
    ## code under test.
    let canon = p.replace('\\', '/')
    if canon == "C:/poc/ärger/inc/myheader.h" or canon == "c:/poc/ärger/inc/myheader.h":
      OnDisk
    else: p

  proc noExpand(p: string): string = p   # the resolver found no real spelling

  test "case-folding root: the reported spelling is resolved to its real spelling":
    let roots = rootsFor(fpAsciiLower)
    let rp = ReportedPath(Reported)
    let pc = classify(rp, roots, resolvingExpand)
    check pc.kind == pcTracked
    if pc.kind == pcTracked:
      check pc.tp.display == "Inc/MyHeader.h"
    check not reportedHeaderUnresolved(ccfMsvc, rp, pc, roots)

  test "case-folding root, resolver fails: the header is refused, not dropped":
    let roots = rootsFor(fpAsciiLower)
    let rp = ReportedPath(Reported)
    let pc = classify(rp, roots, noExpand)
    check pc.kind == pcOutside
    check caseBlindRootMembership(rp, roots).underFoldingRoot
    check reportedHeaderUnresolved(ccfMsvc, rp, pc, roots)
    check reportedHeaderUnresolved(ccfGnu, rp, pc, roots)

  test "case-sensitive root: cl's report does not say which file, so it is refused":
    let roots = rootsFor(fpNone)
    let rp = ReportedPath(Reported)
    let pc = classify(rp, roots, noExpand)
    check caseBlindRootMembership(rp, roots).underCaseSensitiveRoot
    check reportedHeaderUnresolved(ccfMsvc, rp, pc, roots)

  test "CONTROL: a sibling sharing the root's letters, and a different letter, stay outside":
    for policy in [fpNone, fpAsciiLower]:
      let roots = rootsFor(policy)
      for other in ["c:\\poc\\ärgerlich\\inc\\myheader.h",   # component boundary
                    "c:\\poc\\örger\\inc\\myheader.h",       # o-umlaut is not a-umlaut
                    "c:\\poc\\arger\\inc\\myheader.h"]:      # nor is plain a
        let rp = ReportedPath(other)
        let m = caseBlindRootMembership(rp, roots)
        check not m.underFoldingRoot
        check not m.underCaseSensitiveRoot
        check not reportedHeaderUnresolved(ccfMsvc, rp, classify(rp, roots, noExpand), roots)

  test "a lowercased non-ASCII Data.Source still names the probed unit":
    let doc = "\u00e4pfel.c\n" & """{
    "Version": "1.2",
    "Data": {
        "Source": "c:\\poc\\ärger\\äpfel.c",
        "Includes": [ "c:\\poc\\ärger\\inc\\myheader.h" ]
    }
}
"""
    let probed = depIncludeHeaders(ccfMsvc, doc, "C:/poc/Ärger/Äpfel.c")
    check probed.err == dpeNone
    check probed.headers.len == 1
    # ...and a genuinely different non-ASCII basename is still a mismatch.
    check depIncludeHeaders(ccfMsvc, doc, "C:/poc/Ärger/Öpfel.c").err == dpeSourceMismatch

  test "caseBlindEqual: Unicode simple folding, whole-string, no partial match":
    check caseBlindEqual("Ärger", "ärger")
    check caseBlindEqual("ÄRGER", "ärger")
    check caseBlindEqual("\u212a", "k")        # KELVIN SIGN folds to k
    check caseBlindEqual("\u03c2", "\u03a3")   # final sigma and capital sigma
    check not caseBlindEqual("Ärger", "Örger")
    check not caseBlindEqual("Ärger", "ärgerx")
    check not caseBlindEqual("straße", "STRASSE")   # full folding is out of scope
    check caseBlindEqual("a\xC3", "A\xC3")     # a malformed trailing byte compares as itself
    check not caseBlindEqual("a\xC3", "a\xC4")

suite "parseCompileCommand -- one parse of a manifest compile command":

  test "MSVC: driver, family, replayable flags, /Fo output and source":
    let c = parseCompileCommand(
      "vccexe.exe /c --platform:amd64 /nologo /IC:/p/tests /FoC:/p/nc/u.obj C:/p/u.c")
    check c.isSome
    check c.get.driver == "vccexe.exe"
    check c.get.family == ccfMsvc
    check c.get.flags == @["--platform:amd64", "/nologo", "/IC:/p/tests"]
    check c.get.output == "C:/p/nc/u.obj"
    check c.get.source == "C:/p/u.c"

  test "MSVC output spellings: -Fo, /Fo:<obj>, and /Fo: followed by its own token":
    check parseCompileCommand("cl /c -Foa.obj a.c").get.output == "a.obj"
    check parseCompileCommand("cl /c /Fo:a.obj a.c").get.output == "a.obj"
    let sep = parseCompileCommand("cl /c /Fo: a.obj /nologo a.c")
    check sep.isSome
    check sep.get.output == "a.obj"
    check sep.get.flags == @["/nologo"]

  test "MSVC dependency-output and preprocess flags are dropped with their arguments":
    let c = parseCompileCommand(
      "cl /c /showIncludes /sourceDependencies deps.json /EP /Iinc -Zs a.c")
    check c.isSome
    check c.get.flags == @["/Iinc"]
    check c.get.output == ""

  test "MSVC: a quoted driver path is one token without its quotes":
    let c = parseCompileCommand("\"C:\\Program Files\\VC\\cl.exe\" /c /Foa.obj a.c")
    check c.isSome
    check c.get.driver == "C:\\Program Files\\VC\\cl.exe"
    check c.get.family == ccfMsvc

  test "GNU: -c, -o <obj> and dependency flags leave; everything else stays in order":
    let c = parseCompileCommand(
      "gcc -c -I/p/inc -o /p/nc/u.o -MD -MF u.d -isystem /p/sys -DX=1 /p/u.c")
    check c.isSome
    check c.get.family == ccfGnu
    check c.get.flags == @["-I/p/inc", "-isystem", "/p/sys", "-DX=1"]
    check c.get.output == "/p/nc/u.o"
    check c.get.source == "/p/u.c"
    check parseCompileCommand("gcc -c -o/p/nc/u.o /p/u.c").get.output == "/p/nc/u.o"

  test "a command that does not parse cleanly is none, never a guess":
    check parseCompileCommand("gcc -c \"unterminated /p/u.c").isNone
    check parseCompileCommand("gcc").isNone
    check parseCompileCommand("").isNone
    check parseCompileCommand("gcc -c -o a.o -o b.o u.c").isNone     # two outputs
    check parseCompileCommand("gcc -c -o u.c").isNone                # -o would eat the source
    check parseCompileCommand("gcc -c -MF u.c").isNone               # -MF would eat the source
    check parseCompileCommand("cl /c /Foa.obj /Fob.obj a.c").isNone  # two outputs
    check parseCompileCommand("cl /c /Fo: a.c").isNone               # /Fo: would eat the source
    check parseCompileCommand("cl /c /I\"unterminated a.c").isNone

  test "deriveDepInvocation is the parse with the probe prepended":
    for cmd in ["gcc -c -I/p/inc -o /p/nc/u.o /p/u.c",
                "vccexe.exe /c /nologo /IC:/p/tests /FoC:/p/nc/u.obj C:/p/u.c"]:
      let c = parseCompileCommand(cmd).get
      let inv = deriveDepInvocation(cmd)
      check inv.ok
      check inv.cmd == c.driver
      check inv.family == c.family
      check inv.sourceFile == c.source
      let lead = case c.family
                 of ccfMsvc: @["/Zs", "/sourceDependencies-"]
                 of ccfGnu: @["-M"]
      check inv.args == lead & c.flags & @[c.source]

suite "msvcArgvSplit -- cl's own command-line rules, on every host":

  test "a quoted UNC include path keeps both leading backslashes":
    const unc = "\\\\srv\\share dir\\inc"      # \\srv\share dir\inc
    let r = msvcArgvSplit("cl /c /I\"" & unc & "\" a.c")
    check r.ok
    check r.toks == @["cl", "/c", "/I" & unc, "a.c"]
    # ...and so does the flag the probe replays.
    let c = parseCompileCommand("cl /c /I\"" & unc & "\" /Foa.obj a.c")
    check c.isSome
    check c.get.flags == @["/I" & unc]

  test "backslashes before a quote: odd count escapes it, even count halves and toggles":
    # a\\\"b  (three backslashes, then a quote) -> a\"b
    check msvcArgvSplit("cl a\\\\\\\"b x.c").toks == @["cl", "a\\\"b", "x.c"]
    # a\\\\"b c"  (four backslashes, then an opening quote) -> a\\b c
    check msvcArgvSplit("cl a\\\\\\\\\"b c\" x.c").toks == @["cl", "a\\\\b c", "x.c"]
    # a\\b  (backslashes not before a quote) -> unchanged
    check msvcArgvSplit("cl a\\\\b x.c").toks == @["cl", "a\\\\b", "x.c"]

  test "a doubled quote inside quotes is one literal quote":
    check msvcArgvSplit("cl \"a\"\"b\" x.c").toks == @["cl", "a\"b", "x.c"]

  test "the program name is literal: backslashes stay, quotes group":
    check msvcArgvSplit("C:\\vc\\cl.exe /c x.c").toks[0] == "C:\\vc\\cl.exe"
    check msvcArgvSplit("\"C:\\a b\\cl.exe\" x.c").toks == @["C:\\a b\\cl.exe", "x.c"]

  test "an unterminated quote is refused":
    check not msvcArgvSplit("cl \"a x.c").ok
    check not msvcArgvSplit("\"C:\\a b\\cl.exe x.c").ok

# -----------------------------------------------------------------------------
# W9e / R9-D14 / R9-S3: a GNU-family command is split by the rules of the host
# that WROTE it, read off the command itself, never by the host reading it.
# Nim's `extccomp.getCompileCFileCmd` quotes every path with `os.quoteShell`,
# which is `quoteShellWindows` on a Windows compile host and `quoteShellPosix`
# elsewhere, so each case below builds its command with the very quoting
# function Nim uses and checks that the parse recovers the paths it quoted.
# -----------------------------------------------------------------------------

suite "parseCompileCommand -- a GNU command is split by the rules it was written with":

  proc gnuCmd(driver: string; incs: openArray[string]; obj, src: string;
              quote: proc (s: string): string {.nimcall.}): string =
    result = quote(driver) & " -c -w"
    for inc in incs: result.add " -I" & quote(inc)
    result.add " -o " & quote(obj) & " " & quote(src)

  const WinIncs = [r"C:\nim\lib", r"C:\Users\O'Brien\my inc",
                   r"C:\Users\O'Brien", r"\\srv\share dir\inc",
                   r"C:\a b\trailing\"]
  const PosixIncs = ["/opt/nim/lib", "/home/o'brien/my inc", "/home/o'brien",
                     "/tmp/a\\b dir", "/tmp/sp ace/$HOME/`x`/\"q\""]

  test "a Windows-hosted mingw command (quoteShellWindows) keeps its backslashes and apostrophes":
    let cmd = gnuCmd(r"C:\mingw\bin\gcc.exe", WinIncs, r"C:\nc\@ma.nim.c.o",
                     r"C:\nc\@ma.nim.c", quoteShellWindows)
    let c = parseCompileCommand(cmd)
    check c.isSome
    check c.get.family == ccfGnu
    check c.get.driver == r"C:\mingw\bin\gcc.exe"
    var want = @["-w"]
    for inc in WinIncs: want.add "-I" & inc
    check c.get.flags == want
    check c.get.output == r"C:\nc\@ma.nim.c.o"
    check c.get.source == r"C:\nc\@ma.nim.c"

  test "a Windows-hosted command is recognised by its source path, whatever the driver is called":
    # `extccomp.needsExeExt` appends `.exe` only to a driver without an
    # extension, so the source path -- always absolute from a Windows host --
    # is what identifies the writer.
    for driver in ["x86_64-w64-mingw32-gcc", r"C:\mingw\bin\gcc-13.2", "gcc.exe"]:
      let c = parseCompileCommand(gnuCmd(driver, [r"C:\Users\O'Brien"],
                                         r"C:\nc\a.o", r"C:\nc\a.c",
                                         quoteShellWindows))
      check c.isSome
      check c.get.flags == @["-w", r"-IC:\Users\O'Brien"]
      check c.get.source == r"C:\nc\a.c"
    # ccfake's mingw shape: forward slashes, no `.exe`.
    let m = parseCompileCommand(
      "x86_64-w64-mingw32-gcc -c -O1 -o C:/nc/a.o C:/nc/@mstdinfile.nim.c")
    check m.isSome
    check m.get.flags == @["-O1"]

  test "a POSIX-hosted command (quoteShellPosix) is split by the shell's rules on every host":
    let cmd = gnuCmd("/usr/bin/gcc", PosixIncs, "/tmp/nc/@ma.nim.c.o",
                     "/tmp/my dir/@ma.nim.c", quoteShellPosix)
    let c = parseCompileCommand(cmd)
    check c.isSome
    var want = @["-w"]
    for inc in PosixIncs: want.add "-I" & inc
    check c.get.flags == want
    check c.get.output == "/tmp/nc/@ma.nim.c.o"
    check c.get.source == "/tmp/my dir/@ma.nim.c"
    # A shell backslash escape outside quotes is an escape even when the
    # reader is a Windows host.
    let esc = parseCompileCommand("gcc -c -o /tmp/nc/a.o /tmp/my\\ dir/a.c")
    check esc.isSome
    check esc.get.source == "/tmp/my dir/a.c"

  test "a relative source falls back to the driver: `.exe` means a Windows host wrote it":
    let w = parseCompileCommand(r"gcc.exe -c -IC:\Users\O'Brien -o obj\a.o a.c")
    check w.isSome
    check w.get.flags == @[r"-IC:\Users\O'Brien"]
    check w.get.output == r"obj\a.o"
    let p = parseCompileCommand("gcc -c '-I/a b' -o obj/a.o a.c")
    check p.isSome
    check p.get.flags == @["-I/a b"]

  test "a command both rule sets read as absolute is ambiguous and refused":
    # POSIX rules: the source is `/tmp/a C:/x.c`; Windows rules: `C:/x.c'`.
    check parseCompileCommand("gcc -c -o /tmp/a.o '/tmp/a C:/x.c'").isNone
    check not deriveDepInvocation("gcc -c -o /tmp/a.o '/tmp/a C:/x.c'").ok

  test "shellSplit applies POSIX rules alone, on every host":
    check shellSplit("a\\ b c\\\\d").toks == @["a b", "c\\d"]
    check not shellSplit("trailing\\").ok
    check shellSplit("'O'\"'\"'Brien'").toks == @["O'Brien"]

  test "anySepBaseName: the final component on either separator":
    check anySepBaseName(r"C:\VC\bin\cl.exe") == "cl.exe"
    check anySepBaseName("/usr/bin/gcc") == "gcc"
    check anySepBaseName(r"C:/mixed\sep/x.c") == "x.c"
    check anySepBaseName("bare") == "bare"
    check anySepBaseName("dir/") == ""

# -----------------------------------------------------------------------------
# The POSIX-only suites above do not run on Windows; each says so by marker,
# which ci/assert-subset-honesty.sh audits.
when not defined(posix):
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#realrun_execv_no_shell_splitting"
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#realrunin_subprocess_cwd"
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccprobe.nim#erroutput_w9a_nonmerged"

# No unconditional "all passed" banner. There used to be one here, and it
# printed under SEVEN failures during this review -- a success line emitted by
# a run that failed is the same false signal W5c's out-of-gate `done` line was.
# std/unittest already reports per-test status and sets a nonzero exit code;
# the harness reads that, not prose.
