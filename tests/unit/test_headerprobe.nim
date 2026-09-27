## tests/unit/test_headerprobe.nim -- the shared header pipeline
## (`headerprobe.probeReportedHeaders`) that `closure.extractCompileInputs`
## and `artifactid.ccIncludeClosure` both run.
##
## Pure: every probe is a fake `RunProc`, every root a fixed fold policy, and
## every resolver an injected `CandidateExpander`; nothing touches the disk.

import std/[options, strutils, unittest]
import crisol/headerprobe
import crisol/ccprobe
import crisol/paths
import crisol/toolrun
import ../support/fakerun

proc fixedProbe(policy: FoldPolicy): proc (rootAbs, stateDir: string): Option[FoldPolicy] =
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy)

proc replying(output: string): RunProc =
  result = proc (cmd: string; args: openArray[string]): RunResult =
    fakeReply(output, true)

proc noExpand(p: string): string = p

proc located(cmd: string): DriverResolver =
  ## Every driver token resolves to the file it names: the suites below
  ## that are not about driver resolution.
  discard cmd
  asNamed()

proc recording(seen: ref seq[string]; output: string): RunProc =
  result = proc (cmd: string; args: openArray[string]): RunResult =
    seen[].add cmd
    fakeReply(output, true)

const gccCmd = "gcc -c -I/proj/inc -o /proj/nc/u.o /proj/src/u.c"

suite "probeReportedHeaders -- every step's refusal is distinguishable":

  test "an underivable command never runs the probe":
    var called = false
    let run: RunProc = proc (cmd: string; args: openArray[string]): RunResult =
      called = true
      fakeReply("", true)
    let hp = probeReportedHeaders("gcc", located("gcc"), run, TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfDerivation
    check hp.depErr == dpeNone
    check not called

  test "a failed run names the probe, the source and what the driver said":
    let run: RunProc = proc (cmd: string; args: openArray[string]): RunResult =
      ran(1, "", "fatal: no such include dir")
    let hp = probeReportedHeaders(gccCmd, located(gccCmd), run, TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfRun
    check "cc -M" in hp.message
    check "/proj/src/u.c" in hp.message
    check "no such include dir" in hp.message

  test "an unusable report carries the parser's own verdict":
    let hp = probeReportedHeaders(gccCmd, located(gccCmd), replying(""), TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfReport
    check hp.depErr == dpeNoMakeRule

  test "a report for another translation unit is a source mismatch":
    let hp = probeReportedHeaders(gccCmd, located(gccCmd),
      replying("u.o: /proj/src/OTHER.c /proj/inc/a.h\n"), TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfReport
    check hp.depErr == dpeSourceMismatch
    check "DIFFERENT translation unit" in hp.message

  test "an MSVC probe is named as /sourceDependencies":
    let hp = probeReportedHeaders("cl /c /Fou.obj C:/proj/src/u.c", located("cl /c /Fou.obj C:/proj/src/u.c"),
      replying("u.c\n"), TrackedRoots(), noExpand)
    check not hp.ok
    check hp.depErr == dpeNoJson
    check "/sourceDependencies" in hp.message

# -----------------------------------------------------------------------------
# R10-S6: the probe replays the compile with the driver file the build's nim
# resolved (`ccidentity.locateDriver`), never with the manifest's bare token
# looked up by crisol's own search order, which can find another compiler.
# -----------------------------------------------------------------------------

suite "probeReportedHeaders -- runs the driver the build resolved (R10-S6)":

  test "the probe runs the located driver file, not the manifest's bare token":
    let roots = initTrackedRoots("/proj", @[], "", fixedProbe(fpNone))
    let seen = new(seq[string])
    let hp = probeReportedHeaders(gccCmd, locatedIn("/opt/tc/bin"),
      recording(seen, "u.o: /proj/src/u.c /proj/inc/a.h\n"), roots, noExpand)
    check hp.ok
    check seen[] == @["/opt/tc/bin/gcc"]

  test "the resolver is asked for the command's own driver token":
    let asked = new(seq[string])
    let seen = new(seq[string])
    discard probeReportedHeaders("g++ -c -o /proj/nc/u.o /proj/src/u.cpp",
      recordingResolver(asked, locatedIn("/opt/tc/bin")),
      recording(seen, "u.o: /proj/src/u.cpp\n"), TrackedRoots(), noExpand)
    discard probeReportedHeaders("/opt/tc/bin/clang++ -c -o /proj/nc/v.o /proj/src/v.cpp",
      recordingResolver(asked, asNamed()),
      recording(seen, "v.o: /proj/src/v.cpp\n"), TrackedRoots(), noExpand)
    check asked[] == @["g++", "/opt/tc/bin/clang++"]
    check seen[] == @["/opt/tc/bin/g++", "/opt/tc/bin/clang++"]

  test "an unresolved driver refuses before anything runs":
    let seen = new(seq[string])
    let hp = probeReportedHeaders(gccCmd,
      unresolved("`gcc` is not on the search path nim uses"),
      recording(seen, ""), TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfDriverUnresolved
    check hp.depErr == dpeNone
    check "not on the search path nim uses" in hp.message
    check "/proj/src/u.c" in hp.message
    check "'gcc'" in hp.message
    check seen[].len == 0

suite "probeReportedHeaders -- classification":

  test "R15-D6: unpopulated roots with a reported header refuses rather than skip classification":
    let hp = probeReportedHeaders(gccCmd, located(gccCmd),
      replying("u.o: /proj/src/u.c /proj/inc/a.h /usr/include/stdio.h\n"),
      TrackedRoots(), noExpand)
    check not hp.ok
    check hp.failure == hpfRootsUnpopulated
    check hp.depErr == dpeNone

  test "unpopulated roots with NO header reported still succeeds: nothing needed classifying":
    let hp = probeReportedHeaders(gccCmd, located(gccCmd),
      replying("u.o: /proj/src/u.c\n"), TrackedRoots(), noExpand)
    check hp.ok
    check hp.headers.len == 0

  test "populated roots: tracked and outside headers are both returned, classified":
    let roots = initTrackedRoots("/proj", @[], "", fixedProbe(fpNone))
    let hp = probeReportedHeaders(gccCmd, located(gccCmd),
      replying("u.o: /proj/src/u.c /proj/inc/a.h /usr/include/stdio.h\n"),
      roots, noExpand)
    check hp.ok
    check hp.headers.len == 2
    check hp.headers[0].pc.kind == pcTracked
    check display(hp.headers[0].pc.tp) == "inc/a.h"
    check hp.headers[1].pc.kind == pcOutside

  test "a relative reported header is classified against the project root":
    let roots = initTrackedRoots("/proj", @[], "", fixedProbe(fpNone))
    let hp = probeReportedHeaders("gcc -c -Iinc -o nc/u.o src/u.c", located("gcc -c -Iinc -o nc/u.o src/u.c"),
      replying("u.o: src/u.c inc/a.h\n"), roots, noExpand)
    check hp.ok
    check hp.headers.len == 1
    check hp.headers[0].pc.kind == pcTracked
    check display(hp.headers[0].pc.tp) == "inc/a.h"

  test "a lowercased cl report under a case-sensitive root is refused, not dropped":
    let roots = initTrackedRoots("/Proj", @[], "", fixedProbe(fpNone))
    let doc = "u.c\n" & """{
    "Version": "1.2",
    "Data": {
        "Source": "/proj/src/u.c",
        "Includes": [ "/proj/inc/myheader.h" ]
    }
}
"""
    let hp = probeReportedHeaders("cl /c /Fou.obj /Proj/src/u.c", located("cl /c /Fou.obj /Proj/src/u.c"), replying(doc),
                                  roots, noExpand)
    check not hp.ok
    check hp.failure == hpfUnresolvedHeader
    check hp.depErr == dpeNone
    check "myheader.h" in hp.message
