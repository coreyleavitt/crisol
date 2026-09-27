## test_ccidentity.nim -- the C toolchain identity (issues #21/#23): the
## configured driver's preprocessor answer, the target-chosen runtime probe,
## the fail-closed states and the serialized grammar.
##
## Synthetic: `tests/support/ccfake.nim` replays recorded probe output through
## `ccFingerprintWith`, so every suite runs on every host. The real probe is
## exercised by the integration tests (`test_issue23_cc_identity`,
## `test_real_cl_identity`, `test_cc_depgraph_liveness`).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_ccidentity.nim

import std/[envvars, options, os, osproc, random, strutils, tables, tempfiles, unittest]
import crisol/[ccidentity, headerprobe, paths, toolrun]
import "../support/ccfake"
import "../support/ccprobes"

proc keyOf(f: FakeCc): string = $probe(f)

suite "MSVC: the configured driver's /EP answer":

  test "the measured cl 19.44 x64 host is identified, both halves":
    let fp = probe(msvcHost())
    check toolchainVerdict(fp).kind == tvIdentified
    check fp.compiler.text == "msvc 19.44.35228.0 x64"
    check fp.runtime.text == "kernel32+libcmt+libucrt+libvcruntime+oldnames+uuid"

  test "the probe replays the manifest's driver and flags, not a PATH candidate":
    let f = msvcHost()
    discard probe(f)
    let ep = f.calls[0]
    check ep[0] == f.driverPath   # nim's own directory: where the build finds it
    check "--platform:amd64" in ep
    check "/IC:/nim/2.2.10-patched/lib" in ep
    check "/c" notin ep
    check ep[^2 .. ^1] == @["/EP", MsvcMacroTu]

  test "the runtime probe links, and writes its object and program into its own directory":
    # The replayed flags carry neither the manifest's compile action nor its
    # object output (`parseCompileCommand` drops both), so the runtime probe
    # names its own: a `/c` would stop before the link and trace no library,
    # and a missing `/Fo`/`/Fe` would leave the output to cl's defaults.
    let f = msvcHost()
    discard probe(f)
    var link: seq[string] = @[]
    for c in f.calls:
      if "/VERBOSE:LIB" in c: link = c
    check link.len > 0
    check link[0] == f.driverPath
    check "--platform:amd64" in link
    check "/c" notin link and "-c" notin link
    check "/EP" notin link
    check "/Fo" & LinkObj in link
    check "/Fe" & LinkExe in link
    for a in link: check not a.startsWith("/FoC:")   # the manifest's object
    check link[^3 .. ^1] == @[LinkTu, "/link", "/VERBOSE:LIB"]

  test "CL or _CL_ naming a response file is not an identity (R10-S2)":
    # cl expands `@file` from CL/_CL_; the literal text cannot see the file's
    # contents, and cl resolves it against the compile's own cwd.
    for (name, value) in [("CL", "@opts.rsp"), ("_CL_", "/W4 \"@x.rsp\""),
                          ("CL", "/nologo @C:\\r\\flags.rsp /W4"),
                          ("_CL_", "\"@\"x.rsp")]:
      let f = msvcHost()
      f.env[name] = value
      let fp = probe(f)
      checkpoint name & "=" & value
      check fp.compiler.state == cfsUnavailable
      check "response file" in fp.compiler.why
      check name in fp.compiler.why

  test "an @ inside a CL flag is not a response file":
    let f = msvcHost()
    f.env["CL"] = "/DMAIL#a@b /W4"
    check probe(f).compiler.state == cfsKnown

  test "a CL value is identified (R9-D1: the CL=/MP host is no longer refused)":
    let f = msvcHost()
    f.env["CL"] = "/MP"
    check toolchainVerdict(probe(f)).kind == tvIdentified

  test "CL and _CL_ values move the compiler digest (R9-D1c)":
    let base = keyOf(msvcHost())
    var seen = @[base]
    for (name, value) in [("CL", "/DFOO"), ("CL", "/W4"), ("_CL_", "/DFOO")]:
      let f = msvcHost()
      f.env[name] = value
      let k = keyOf(f)
      check k notin seen
      seen.add k

  test "the runtime half does not depend on CL":
    let f = msvcHost()
    f.env["CL"] = "/DFOO"
    check probe(f).runtime == probe(msvcHost()).runtime

  test "target-architecture macros key cross-arch toolsets apart (R9-D1a)":
    let x64 = probe(msvcHost())
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.multiReplace(
      ("crisol_m_x64=100", "crisol_m_x64=_M_X64"),
      ("crisol_m_amd64=100", "crisol_m_amd64=_M_AMD64"),
      ("crisol_m_arm64=_M_ARM64", "crisol_m_arm64=1")), "")
    let arm = probe(f)
    check arm.compiler.text == "msvc 19.44.35228.0 arm64"
    check arm.compiler != x64.compiler

  test "every probed macro is key material, not only what the summary names":
    # Same summary text (`x64`), different architecture macro set.
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("crisol_m_amd64=100",
                                            "crisol_m_amd64=_M_AMD64"), "")
    let fp = probe(f)
    check fp.compiler.text == probe(msvcHost()).compiler.text
    check fp.compiler.digest.get != probe(msvcHost()).compiler.digest.get

  test "the /MD runtime selection moves the key":
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("crisol_dll=_DLL", "crisol_dll=1"), "")
    check keyOf(f) != keyOf(msvcHost())

  test "a different build of the same version moves the key":
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("194435228", "194435229"), "")
    check probe(f).compiler.text == "msvc 19.44.35229.0 x64"
    check keyOf(f) != keyOf(msvcHost())

  test "clang-cl is named as such":
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("crisol_clang=__clang_version__",
                                            "crisol_clang=\"18.1.8 \""), "")
    check probe(f).compiler.text.startsWith("clang-cl 18.1.8 msvc 19.44")

  test "a probe that exits non-zero leaves the compiler unidentified":
    let f = msvcHost()
    f.macroReply = ran(2, "", "cl : Command line error D8021")
    let fp = probe(f)
    check fp.compiler.state == cfsUnavailable
    check "exited 2" in fp.compiler.why
    check (toolchainVerdict(fp).kind == tvUnidentified)

  test "a probe that does not finish leaves the compiler unidentified":
    let f = msvcHost()
    f.macroReply = notRun(reTimedOut, "timed out after 10000 ms")
    check probe(f).compiler.state == cfsUnavailable

  test "an answer missing a label is not an identity":
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("crisol_mt=1\r\n", ""), "")
    check probe(f).compiler.state == cfsUnavailable

  test "an answer whose _MSC_FULL_VER did not expand is not an identity":
    let f = msvcHost()
    f.macroReply = ran(0, MsvcEpX64.replace("194435228", "_MSC_FULL_VER"), "")
    check probe(f).compiler.state == cfsUnavailable

  test "an unreadable driver binary leaves the compiler unidentified":
    let f = msvcHost()
    f.driverHex = ""
    check probe(f).compiler.state == cfsUnavailable

suite "MSVC: the runtime half":

  test "two SDKs differing only in libucrt.lib content key apart":
    let f = msvcHost()
    f.fileHex["C:\\msvc\\sdk\\lib\\ucrt\\libucrt.lib"] = "ffffffffffffffff"
    check probe(f).runtime != probe(msvcHost()).runtime

  test "library paths never reach the key":
    let f = msvcHost()
    var moved = initTable[string, string]()
    for path, hex in f.fileHex:
      moved[path.replace("C:\\msvc", "D:\\vs")] = hex
    f.fileHex = moved
    f.linkReply = ran(0, MsvcLinkTrace.replace("C:\\msvc", "D:\\vs"), "")
    check probe(f).runtime == probe(msvcHost()).runtime

  test "an unreadable library leaves the runtime unidentified":
    let f = msvcHost()
    f.fileHex.del "C:\\msvc\\vc\\lib\\LIBCMT.lib"
    check probe(f).runtime.state == cfsUnavailable

  test "a link probe that did not finish identifies nothing":
    let f = msvcHost()
    f.linkReply = notRun(reOverflow, "output exceeded the cap")
    check probe(f).runtime.state == cfsUnavailable

  test "a link that failed late is still read":
    let f = msvcHost()
    f.linkReply = ran(1120, MsvcLinkTrace, "")
    check probe(f).runtime.state == cfsKnown

  test "a linker that named nothing leaves the runtime unidentified":
    let f = msvcHost()
    f.linkReply = ran(0, "", "")
    check probe(f).runtime.state == cfsUnavailable

  test "parseVerboseLibPaths dedups the repeated search passes":
    check parseVerboseLibPaths(MsvcLinkTrace & MsvcLinkTrace).len == 6

  test "the static runtime asks for no DLL (the .lib files are the code)":
    let f = msvcHost()   # no SystemRoot: a lookup would refuse
    let fp = probe(f)
    check fp.runtime.state == cfsKnown
    check ".dll" notin fp.runtime.text

  test "/MD: the runtime DLLs the loader resolves are the identity (R10-S3)":
    let fp = probe(msvcDllHost())
    checkpoint fp.runtime.why
    check fp.runtime.state == cfsKnown
    check "vcruntime140.dll" in fp.runtime.text
    check "ucrtbase.dll" in fp.runtime.text
    for dll in ["vcruntime140.dll", "ucrtbase.dll"]:
      let f = msvcDllHost()
      f.fileHex[System32 & "\\" & dll] = "ee00000000000000"
      checkpoint dll
      check probe(f).runtime != fp.runtime

  test "/MD: a runtime DLL outside the system directories is not identified":
    # On PATH only: the test's own cwd and binary directory precede PATH in
    # the loader's search, so which copy loads is not known here.
    let f = msvcDllHost()
    f.fileHex.del System32 & "\\ucrtbase.dll"
    f.fileHex["C:\\tools\\ucrtbase.dll"] = "d200000000000000"
    f.env["PATH"] = "C:\\tools"
    let fp = probe(f)
    check fp.runtime.state == cfsUnavailable
    check "ucrtbase.dll" in fp.runtime.why

  test "/MD: the Windows directory is searched after the system directory":
    let f = msvcDllHost()
    f.fileHex.del System32 & "\\ucrtbase.dll"
    f.fileHex[SystemRoot & "\\ucrtbase.dll"] = "d200000000000000"
    check probe(f).runtime.state == cfsKnown
    f.fileHex[System32 & "\\ucrtbase.dll"] = "d900000000000000"
    let a = probe(f)
    f.fileHex[SystemRoot & "\\ucrtbase.dll"] = "da00000000000000"
    check probe(f).runtime == a.runtime   # the system directory wins

  test "/MD: a present but unreadable runtime DLL is not identified":
    # The loader maps the first copy that exists; a readable copy later in
    # the search is not the one that loads.
    let f = msvcDllHost()
    f.fileHex.del System32 & "\\vcruntime140.dll"
    f.unreadable.add System32 & "\\vcruntime140.dll"
    f.fileHex[SystemRoot & "\\vcruntime140.dll"] = "d100000000000000"
    let fp = probe(f)
    check fp.runtime.state == cfsUnavailable
    check "could not be read" in fp.runtime.why

  test "/MD: no SystemRoot is not identified":
    let f = msvcDllHost()
    f.env.del "SystemRoot"
    check probe(f).runtime.state == cfsUnavailable

  test "/MD, x86 target: the WOW64 system directory is searched":
    let f = msvcDllHost()
    f.macroReply = ran(0, MsvcEpX64.multiReplace(
      ("crisol_m_x64=100", "crisol_m_x64=_M_X64"),
      ("crisol_m_amd64=100", "crisol_m_amd64=_M_AMD64"),
      ("crisol_m_ix86=_M_IX86", "crisol_m_ix86=600")), "")
    f.unreadable.add SystemRoot & "\\SysWOW64"
    f.fileHex[SystemRoot & "\\SysWOW64\\vcruntime140.dll"] = "f100000000000000"
    f.fileHex[SystemRoot & "\\SysWOW64\\ucrtbase.dll"] = "f200000000000000"
    let a = probe(f)
    check a.runtime.state == cfsKnown
    f.fileHex[SystemRoot & "\\SysWOW64\\ucrtbase.dll"] = "f300000000000000"
    check probe(f).runtime != a.runtime
    f.fileHex[System32 & "\\ucrtbase.dll"] = "f400000000000000"
    let b = probe(f)
    f.fileHex[System32 & "\\ucrtbase.dll"] = "f500000000000000"
    check probe(f).runtime == b.runtime   # the 64-bit copy is not what loads

  test "/MD from a 32-bit crisol: Sysnative is the 64-bit system directory":
    # WOW64 redirects a 32-bit process's System32 to SysWOW64; Sysnative
    # exists only for such a process and names the real System32.
    let f = msvcDllHost()
    f.unreadable.add SystemRoot & "\\Sysnative"
    f.fileHex[SystemRoot & "\\Sysnative\\vcruntime140.dll"] = "e100000000000000"
    f.fileHex[SystemRoot & "\\Sysnative\\ucrtbase.dll"] = "e200000000000000"
    let a = probe(f)
    check a.runtime.state == cfsKnown
    f.fileHex[SystemRoot & "\\Sysnative\\ucrtbase.dll"] = "e300000000000000"
    check probe(f).runtime != a.runtime

  test "/MD: the msvcrt.lib startup library alone binds both runtime DLLs":
    let f = msvcDllHost()
    f.linkReply = ran(0, "    Searching C:\\msvc\\vc\\lib\\MSVCRT.lib:\r\n", "")
    let fp = probe(f)
    check "vcruntime140.dll" in fp.runtime.text
    check "ucrtbase.dll" in fp.runtime.text
    f.fileHex.del System32 & "\\ucrtbase.dll"
    check probe(f).runtime.state == cfsUnavailable

  test "/MD debug runtime: the debug DLLs are required":
    let f = msvcDllHost()
    f.linkReply = ran(0, MsvcDllLinkTrace.multiReplace(
      ("vcruntime.lib", "vcruntimed.lib"), ("ucrt.lib", "ucrtd.lib")), "")
    f.fileHex["C:\\msvc\\vc\\lib\\vcruntimed.lib"] = "b400000000000000"
    f.fileHex["C:\\msvc\\sdk\\lib\\ucrt\\ucrtd.lib"] = "b500000000000000"
    check probe(f).runtime.state == cfsUnavailable   # no debug DLLs present
    f.fileHex[System32 & "\\vcruntime140d.dll"] = "d500000000000000"
    f.fileHex[System32 & "\\ucrtbased.dll"] = "d600000000000000"
    check "ucrtbased.dll" in probe(f).runtime.text

suite "GNU: the configured driver's -dM -E dump":

  test "the measured gcc host is identified, both halves":
    let fp = probe(gnuHost(GccManifestCmd, GccDumpX64))
    check toolchainVerdict(fp).kind == tvIdentified
    check fp.compiler.text == "gcc 16.2.0 x86_64-linux"
    check fp.runtime.text == "ldd (GNU libc) 2.43"

  test "the dump replays the manifest flags without -c or -o":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    discard probe(f)
    let c = f.calls[0]
    check c[0] == FakeBin & "/gcc"
    check "-pthread" in c and "-fno-strict-aliasing" in c
    check "-c" notin c and "-o" notin c
    check c[^3 .. ^1] == @["-dM", "-E", EmptyTu]

  test "-m32 (a different target, same driver) keys apart (R9-D1a)":
    let a = probe(gnuHost(GccManifestCmd, GccDumpX64))
    let b = probe(gnuHost(GccManifestCmd.replace("-pthread", "-pthread -m32"), GccDumpI386))
    check b.compiler.text == "gcc 16.2.0 i386-linux"
    check a.compiler != b.compiler

  test "any change in the dump moves the key":
    let a = keyOf(gnuHost(GccManifestCmd, GccDumpX64))
    let b = keyOf(gnuHost(GccManifestCmd, GccDumpX64 & "#define __OPTIMIZE__ 1\n"))
    check a != b

  test "clang is named from its own macros":
    let fp = probe(gnuHost(GccManifestCmd.replace("gcc -c", "clang -c"), ClangDumpX64))
    check fp.compiler.text == "clang 22.1.8 x86_64-linux"

  test "a rebuilt driver binary with the same macros keys apart":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.driverHex = "e2e2e2e2e2e2e2e2"
    check probe(f).compiler != probe(gnuHost(GccManifestCmd, GccDumpX64)).compiler

  test "the environment does not reach the GNU key (only cl reads CL)":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.env["CL"] = "/DFOO"
    check keyOf(f) == keyOf(gnuHost(GccManifestCmd, GccDumpX64))

  test "a dump with no #define lines is not an identity":
    let f = gnuHost(GccManifestCmd, "gcc: error: unrecognized option\n")
    let fp = probe(f)
    check fp.compiler.state == cfsUnavailable
    check fp.runtime.state == cfsUnavailable  # the target is unknown

suite "GNU: the runtime half follows the target":

  test "glibc: two libc builds reporting the same ldd version key apart":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.fileHex[LibcPath] = "0101010101010101"
    check probe(f).runtime != probe(gnuHost(GccManifestCmd, GccDumpX64)).runtime

  test "glibc: an unresolved libc leaves the runtime unidentified":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.printFile.clear()
    check probe(f).runtime.state == cfsUnavailable

  test "glibc: no ldd still identifies the runtime by content":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.lddReply = notRun(reNotStarted, "absent")
    let fp = probe(f)
    check fp.runtime.state == cfsKnown
    check fp.runtime.text == "libc.so.6"

  test "mingw (UNMEASURED shape): libucrt.a and libmsvcrt.a by content (R9-L6)":
    let f = mingwHost()
    let fp = probe(f)
    check toolchainVerdict(fp).kind == tvIdentified
    check fp.compiler.text == "gcc 14.2.0 x86_64-mingw"
    check fp.runtime.text == "libmsvcrt.a+libucrt.a+msvcrt.dll+ucrtbase.dll"
    check f.calls.len >= 1
    for c in f.calls: check c[0] != "ldd"
    f.fileHex["C:/mingw/lib/libucrt.a"] = "3c3c3c3c3c3c3c3c"
    check probe(f).runtime != fp.runtime

  test "mingw: the system DLLs the import libraries bind to are the identity (R10-S3)":
    let base = probe(mingwHost())
    for dll in ["ucrtbase.dll", "msvcrt.dll"]:
      let f = mingwHost()
      f.fileHex[System32 & "\\" & dll] = "ee00000000000000"
      checkpoint dll
      check probe(f).runtime != base.runtime
      f.fileHex.del System32 & "\\" & dll
      check probe(f).runtime.state == cfsUnavailable

  test "mingw: only a resolved import library requires its DLL":
    let f = mingwHost()
    f.printFile.del "libucrt.a"
    f.fileHex.del System32 & "\\ucrtbase.dll"
    check probe(f).runtime.state == cfsKnown

  test "mingw with no Windows system directory (a cross compile) is not identified":
    let f = mingwHost()
    f.env.del "SystemRoot"
    check probe(f).runtime.state == cfsUnavailable

  test "a library that resolves but cannot be read is not dropped from the identity":
    # Dropping it would key the runtime by the libraries that happened to be
    # readable, so a change in the unreadable one could not move the key.
    let f = newFakeCc("gcc -c -o a.o C:/nc/@mstdinfile.nim.c")
    f.macroReply = ran(0, MingwDumpX64, "")
    f.printFile["libucrt.a"] = "C:/mingw/lib/libucrt.a"
    f.printFile["libmsvcrt.a"] = "C:/mingw/lib/libmsvcrt.a"
    f.fileHex["C:/mingw/lib/libmsvcrt.a"] = "2b2b2b2b2b2b2b2b"
    let fp = probe(f)
    check fp.runtime.state == cfsUnavailable
    check "libucrt.a" in fp.runtime.why

  test "a library lookup that fails is not treated as not found":
    let f = mingwHost()
    check probe(f).runtime.state == cfsKnown
    f.printFileFails = "libucrt.a"
    let fp = probe(f)
    check fp.runtime.state == cfsUnavailable
    check "libucrt.a" in fp.runtime.why

  test "mingw: neither import library resolves -> unidentified":
    let f = newFakeCc("gcc -c -o a.o C:/nc/@mstdinfile.nim.c")
    f.macroReply = ran(0, MingwDumpX64, "")
    check probe(f).runtime.state == cfsUnavailable

  test "Darwin (UNMEASURED shape): the SDK's libSystem.tbd via xcrun (R9-L6)":
    let f = darwinHost()
    let fp = probe(f)
    check toolchainVerdict(fp).kind == tvIdentified
    check fp.compiler.text == "clang 17.0.0 aarch64-darwin"
    check fp.runtime.text == "macOS 15.2 24C101, SDK 15.2 libSystem"
    f.fileHex[DarwinSdk & "/usr/lib/libSystem.tbd"] = "5e5e5e5e5e5e5e5e"
    check probe(f).runtime != fp.runtime

  test "Darwin: the OS build is the identity of the libSystem that loads (R10-S3)":
    # The dylib lives in the dyld shared cache, which only the OS version and
    # build name; the SDK stub is the same across OS updates.
    let base = probe(darwinHost())
    for (was, now) in [("24C101", "24C102"), ("15.2", "15.3"),
                       ("BuildVersion", "ProductVersionExtra:\t(a)\nBuildVersion")]:
      let f = darwinHost()
      f.swVers = ran(0, SwVers.replace(was, now), "")
      checkpoint now
      check probe(f).runtime != base.runtime

  test "Darwin: no sw_vers answer, or one without a build, is not identified":
    let f = darwinHost()
    f.swVers = notRun(reNotStarted, "absent")
    check probe(f).runtime.state == cfsUnavailable
    f.swVers = ran(0, "ProductName:\tmacOS\n", "")
    check probe(f).runtime.state == cfsUnavailable
    f.swVers = ran(0, "ProductName:\tmacOS\nProductVersion:\t15.2\n", "")
    check probe(f).runtime.state == cfsUnavailable
    f.swVers = ran(1, SwVers, "")
    check probe(f).runtime.state == cfsUnavailable

  test "Darwin: an -isysroot in the flags is the SDK, xcrun is not asked":
    let f = darwinHost()
    f.discovery = Discovery(kind: dkFound,
      ccCmd: "clang -c -isysroot /sdk/X.sdk -o a.o /nc/@mstdinfile.nim.c")
    f.fileHex["/sdk/X.sdk/usr/lib/libSystem.tbd"] = "4d4d4d4d4d4d4d4d"
    check probe(f).runtime.state == cfsKnown
    for c in f.calls: check c[0] != "xcrun"

  test "Darwin: no SDK found -> unidentified":
    let f = darwinHost()
    f.sdkPath = notRun(reNotStarted, "absent")
    check probe(f).runtime.state == cfsUnavailable

suite "discovery fails closed (R9-D1b)":

  test "a driver that cannot be determined leaves both halves unidentified":
    let f = msvcHost()
    f.discovery = Discovery(kind: dkNotFound, why: "nim exited 1")
    let fp = probe(f)
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check "nim exited 1" in fp.compiler.why
    check f.calls.len == 0

  test "a compile command that cannot be replayed leaves both halves unidentified":
    let f = newFakeCc("gcc")
    check toolchainVerdict(probe(f)) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)

  test "manifestCompileCommand takes the probe module's own entry":
    let m = """{"compile": [["/nc/@psystem.nim.c", "gcc -DSTD -c /nc/@psystem.nim.c"],
                            ["/nc/@mstdinfile.nim.c", "gcc -c /nc/@mstdinfile.nim.c"]]}"""
    let d = manifestCompileCommand(m)
    check d.kind == dkFound
    check d.ccCmd == "gcc -c /nc/@mstdinfile.nim.c"

  test "manifestCompileCommand: a Windows cPath is matched by basename":
    let m = """{"compile": [["C:\\nc1\\@mstdinfile.nim.c", "vccexe.exe /c x.c"]]}"""
    check manifestCompileCommand(m).kind == dkFound

  test "manifestCompileCommand: no entry, no array, not JSON -> not found":
    check manifestCompileCommand("""{"compile": []}""").kind == dkNotFound
    check manifestCompileCommand("""{}""").kind == dkNotFound
    check manifestCompileCommand("not json").kind == dkNotFound


suite "the serialized grammar round-trips every constructible value (R9-D9)":

  proc constructible(): seq[CcFingerprint] =
    result = @[CcFingerprint()]
    let failing = msvcHost()
    failing.discovery = Discovery(kind: dkNotFound, why: "x")
    result.add probe(failing)
    let noRuntime = msvcHost()
    noRuntime.linkReply = ran(0, "", "")
    result.add probe(noRuntime)
    let noCompiler = msvcHost()
    noCompiler.macroReply = ran(2, "", "")
    result.add probe(noCompiler)
    result.add probe(msvcHost())
    result.add probe(gnuHost(GccManifestCmd, GccDumpX64))
    # Hostile text: every separator the grammar uses, control bytes, non-ASCII.
    for dump in ["#define __GNUC__ 1|2 #3\n#define __x86_64__ 1\n",
                 "#define __GNUC__ \"a\tb\"\n",
                 "#define __clang__ 1\n#define __clang_major__ \xC3\xA9|#\n"]:
      result.add probe(gnuHost(GccManifestCmd, dump))
    let clangCl = msvcHost()
    clangCl.macroReply = ran(0, MsvcEpX64.replace("crisol_clang=__clang_version__",
                                                  "crisol_clang=\"x|y #z\""), "")
    result.add probe(clangCl)

  test "parseCcFingerprint($fp) == fp for every constructible value":
    let values = constructible()
    check values.len == 10
    for fp in values:
      let s = $fp
      checkpoint s
      let (back, ok) = parseCcFingerprint(s)
      check ok
      check back == fp
      check $back == s
      check s.count('|') == 1

  test "a legacy digest-less half is not parsed (render falls back to opaque)":
    check not parseCcFingerprint("cl 19.44|glibc 2.38 #abcd").ok
    check not parseCcFingerprint("gcc 13 #abcd").ok
    check not parseCcFingerprint("gcc 13 #xyz|<runtime-unidentified>").ok
    check not parseCcFingerprint(" #abcd|<runtime-unidentified>").ok

  test "sentinels parse to unidentified halves":
    let (fp, ok) = parseCcFingerprint(BlindFp)
    check ok
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check fp == CcFingerprint()

  test "the zero value serializes to the blind sentinels":
    check $CcFingerprint() == BlindFp

suite "toolchainVerdict: one part per half":

  test "each half on its own":
    let sound = fpOf(SoundFp)
    check toolchainVerdict(sound).kind == tvIdentified
    check toolchainVerdict(CcFingerprint(compiler: sound.compiler)) == ToolchainVerdict(kind: tvUnidentified, part: upRuntime)
    check toolchainVerdict(CcFingerprint(runtime: sound.runtime)) == ToolchainVerdict(kind: tvUnidentified, part: upCompiler)
    check toolchainVerdict(CcFingerprint()) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)

suite "the driver is the file the build's nim runs (R10-S6)":
  # nim spawns the C compiler with `CreateProcess` on Windows, which looks in
  # nim's own directory and nim's cwd before the system directories and
  # PATH; this process's own search would start from crisol's directory and
  # cwd. The probe must run and hash what nim runs.

  test "Windows: nim's directory wins over a copy on PATH":
    let f = msvcHost()
    f.env["PATH"] = "C:\\other"
    f.fileHex["C:\\other\\vccexe.exe"] = "0e0e0e0e0e0e0e0e"
    let a = probe(f)
    check a.compiler.state == cfsKnown
    for c in f.calls: check c[0] == FakeNimDir & "\\vccexe.exe"
    f.fileHex["C:\\other\\vccexe.exe"] = "0f0f0f0f0f0f0f0f"
    check probe(f).compiler == a.compiler      # the PATH copy never runs
    f.driverHex = "0101010101010101"
    check probe(f).compiler != a.compiler      # nim's copy is the identity

  test "Windows: nim's cwd precedes the system directories and PATH":
    let f = mingwHost()
    let cwdCopy = FakeWinCwd & "\\x86_64-w64-mingw32-gcc.exe"
    f.fileHex[cwdCopy] = "0c0c0c0c0c0c0c0c"
    discard probe(f)
    check f.calls[0][0] == cwdCopy

  test "Windows: the system directories precede PATH":
    let f = mingwHost()
    let sysCopy = System32 & "\\x86_64-w64-mingw32-gcc.exe"
    f.fileHex[sysCopy] = "0d0d0d0d0d0d0d0d"
    discard probe(f)
    check f.calls[0][0] == sysCopy

  test "Windows: .exe is appended to a bare name, not to one with an extension":
    let f = mingwHost()
    discard probe(f)
    check f.calls[0][0].endsWith("\\x86_64-w64-mingw32-gcc.exe")
    check msvcHost().driverPath.endsWith("\\vccexe.exe")   # not vccexe.exe.exe
    let g = msvcHost()
    discard probe(g)
    check g.calls[0][0] == g.driverPath

  test "Windows: an unknown nim binary refuses a bare driver name":
    let f = msvcHost()
    f.discovery.nimExe = ""
    let fp = probe(f)
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check "nim binary" in fp.compiler.why
    check f.calls.len == 0

  test "Windows: past nim's directory and cwd, no SystemRoot refuses":
    let f = mingwHost()
    f.env.del "SystemRoot"
    let fp = probe(f)
    check fp.compiler.state == cfsUnavailable
    check "SystemRoot" in fp.compiler.why

  test "POSIX: the first PATH entry holding the driver wins; an empty entry is nim's cwd":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.env["PATH"] = "/opt/a::" & FakeBin
    f.fileHex[FakeCwd & "/gcc"] = "0a0a0a0a0a0a0a0a"
    discard probe(f)
    check f.calls[0][0] == FakeCwd & "/gcc"
    f.fileHex["/opt/a/gcc"] = "0b0b0b0b0b0b0b0b"
    f.calls = @[]
    discard probe(f)
    check f.calls[0][0] == "/opt/a/gcc"

  test "the driver is searched on nim's PATH, not this process's (R11-S1)":
    # A `config.nims` `putEnv("PATH", thisDir() & "/tools:" & ...)` puts a
    # wrapper first for nim alone; nim runs the wrapper.
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.nimEnv["PATH"] = FakeCwd & "/tools:" & FakeBin
    f.fileHex[FakeCwd & "/tools/gcc"] = "0a0a0a0a0a0a0a0a"
    let fp = probe(f)
    check fp.compiler.state == cfsKnown
    check f.calls[0][0] == FakeCwd & "/tools/gcc"
    let plain = gnuHost(GccManifestCmd, GccDumpX64)
    check probe(plain).compiler != fp.compiler
    let w = mingwHost()
    w.env["PATH"] = "C:\\other"
    w.nimEnv["PATH"] = "C:\\mingw\\bin"
    discard probe(w)
    check w.calls.len > 0
    check w.calls[0][0] == w.driverPath

  test "the site carries nim's PATH, which every command's driver resolves against (R11-S1)":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.nimEnv["PATH"] = FakeCwd & "/tools:" & FakeBin
    f.fileHex[FakeCwd & "/tools/g++"] = "0c0c0c0c0c0c0c0c"
    let fio = io(f)
    let resolve = siteResolver(ccProbeWith(fio).site, fio.pathExists)
    check resolve("g++").path == FakeCwd & "/tools/g++"

  test "CL or _CL_ set for nim alone is refused: the replayed probes cannot see it (R11-S1)":
    for name in ["CL", "_CL_"]:
      checkpoint name
      let f = msvcHost()
      f.nimEnv[name] = "/MD"
      let fp = probe(f)
      check fp.compiler.state == cfsUnavailable
      check name in fp.compiler.why
      let g = msvcHost()
      g.env[name] = "/MD"
      g.nimEnv[name] = ""                   # a `delEnv` in the config
      check probe(g).compiler.state == cfsUnavailable
    # The GNU family does not read CL.
    let h = gnuHost(GccManifestCmd, GccDumpX64)
    h.nimEnv["CL"] = "/MD"
    check probe(h).compiler.state == cfsKnown

  test "CL as nim sees it is the value folded (R11-S1)":
    let a = msvcHost()
    a.env["CL"] = "/DFOO"
    let b = msvcHost()
    b.env["CL"] = "/DFOO"
    b.nimEnv["CL"] = "/DFOO"
    check probe(a).compiler.state == cfsKnown
    check probe(a).compiler == probe(b).compiler
    check probe(a).compiler != probe(msvcHost()).compiler

  test "parseNimEnv: every name, last line wins; a missing or malformed one is no report":
    proc line(name, value: string): string =
      result = NimEnvLabel & name & "="
      for c in value: result.add toHex(ord(c), 2).toLowerAscii
      result.add "\n"
    let full = line("PATH", "/a:/b") & line("CL", "") & line("_CL_", "/W4")
    let (env, ok) = parseNimEnv(full)
    check ok
    check env["PATH"] == "/a:/b"
    check env["CL"] == ""
    check env["_CL_"] == "/W4"
    # A config.nims prints first; the module's own line comes last.
    let (env2, ok2) = parseNimEnv(line("PATH", "/forged") & full)
    check ok2
    check env2["PATH"] == "/a:/b"
    check not parseNimEnv(line("PATH", "/a") & line("CL", "")).ok      # _CL_ missing
    check not parseNimEnv(full & NimEnvLabel & "CL=zz\n").ok           # not hex
    check not parseNimEnv(full & NimEnvLabel & "CL=abc\n").ok          # odd length
    check not parseNimEnv("").ok

  test "a discovery that reports no environment is refused, both halves (R11-S1)":
    # `realDiscover` turns an unparsable report into `dkNotFound`; the site
    # is unknown then too.
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.discovery = Discovery(kind: dkNotFound, why: "the discovery module reported no environment")
    let r = ccProbeWith(io(f))
    check toolchainVerdict(r.fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check not r.site.known

  test "a found discovery missing one of nim's variables is refused, never defaulted (R11-S1)":
    for name in NimEnvNames:
      let f = gnuHost(GccManifestCmd, GccDumpX64)
      var fio = io(f)
      let full = fio.discover
      fio.discover = proc(): Discovery =
        result = full()
        result.nimEnv.del name
      let r = ccProbeWith(fio)
      checkpoint name
      check toolchainVerdict(r.fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
      check name in r.fp.compiler.why
      check not r.site.known
      check f.calls.len == 0

  test "a relative driver path resolves against nim's cwd, not this process's":
    let f = gnuHost(GccManifestCmd.replace("gcc -c", "tools/gcc -c"), GccDumpX64)
    f.driverPath = FakeCwd & "/tools/gcc"
    check probe(f).compiler.state == cfsKnown
    check f.calls[0][0] == FakeCwd & "/tools/gcc"
    let w = msvcHost()
    w.discovery = Discovery(kind: dkFound, nimExe: FakeNimDir & "\\nim.exe",
                            nimCwd: FakeWinCwd,
                            ccCmd: MsvcManifestCmd.replace("vccexe.exe", "bin\\vccexe.exe"))
    w.driverPath = FakeWinCwd & "\\bin\\vccexe.exe"
    check probe(w).compiler.state == cfsKnown
    check w.calls[0][0] == w.driverPath

  test "a driver nim cannot find leaves both halves unidentified":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.driverPath = ""
    let fp = probe(f)
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check "could not be located" in fp.compiler.why
    check f.calls.len == 0

  test "ccProbeWith probes the driver file nim's PATH resolves":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.env["PATH"] = "/opt/a::" & FakeBin
    f.fileHex["/opt/a/gcc"] = "0b0b0b0b0b0b0b0b"
    let r = ccProbeWith(io(f))
    check r.fp == probe(f)
    check f.calls[0][0] == "/opt/a/gcc"           # the macro dump ran it
    let w = msvcHost()
    discard ccProbeWith(io(w))
    check w.calls[0][0] == w.driverPath

  test "ccProbeWith: no driver located, or no command discovered, is refused":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.driverPath = ""
    let r = ccProbeWith(io(f))
    check toolchainVerdict(r.fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check "could not be located" in r.fp.compiler.why
    check f.calls.len == 0
    let g = gnuHost(GccManifestCmd, GccDumpX64)
    g.discovery = Discovery(kind: dkNotFound, why: "no manifest")
    let rg = ccProbeWith(io(g))
    check toolchainVerdict(rg.fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    check "no manifest" in rg.fp.compiler.why
    check g.calls.len == 0

  test "ccProbeWith: the site is known once discovery answered, and not before":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.driverPath = ""                         # no C compiler located ...
    let r = ccProbeWith(io(f))
    check r.site.known                        # ... but the site is still learned
    check r.site.nimCwd == FakeCwd
    check r.site.search == dsPosix
    check r.site.pathVar == FakeBin
    let g = gnuHost(GccManifestCmd, GccDumpX64)
    g.discovery = Discovery(kind: dkNotFound, why: "no manifest")
    let rg = ccProbeWith(io(g))
    check not rg.site.known
    check "no manifest" in rg.site.why

suite "a {.compile.}d .cpp external: its C++ driver resolves on its own (R10-S6)":
  # Nim compiles a `.cpp` external with the C++ driver (`g++` under the gcc
  # toolchain, `clang++` under clang) while the discovery compile, a C
  # unit, resolved the C driver. Each manifest command's driver token is
  # resolved against the one site the discovery learned, with the build's
  # own search, never compared by name with the C driver.

  const CppCmd = "g++ -c -w -fmax-errors=3 -o /nc/@mwrap.cpp.o /proj/src/wrap.cpp"

  proc cppProbe(f: FakeCc; cmd: string; seen: ref seq[string]): HeaderProbe =
    ## `cmd`'s header probe, its driver resolved against the site
    ## `ccProbeWith` learned from `f`; the fake driver reports `cmd`'s own
    ## source and one header beside it.
    let fio = io(f)
    let site = ccProbeWith(fio).site
    let src = cmd.splitWhitespace[^1]
    probeReportedHeaders(cmd, siteResolver(site, fio.pathExists),
      proc(c: string; args: openArray[string]): RunResult =
        seen[].add c
        ran(0, "unit.o: " & src & " " & src.replace(".cpp", ".h") & "\n", ""),
      # R15-D6: a reported header against unpopulated roots now refuses, so
      # these driver-resolution tests use populated roots that match none of
      # the fixture's headers.
      initTrackedRoots("/fake/proj-cpp", @[], "",
        proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(fpNone)),
      proc(p: string): string = p)

  test "discovery resolved gcc; a g++ command whose g++ resolves is probed with that g++":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.fileHex[FakeBin & "/g++"] = "0c0c0c0c0c0c0c0c"
    discard ccProbeWith(io(f))
    check f.calls[0][0] == FakeBin & "/gcc"
    let seen = new(seq[string])
    let hp = cppProbe(f, CppCmd, seen)
    check hp.ok
    check seen[] == @[FakeBin & "/g++"]

  test "one resolver answers each token with its own file, remembered per token":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.fileHex[FakeBin & "/g++"] = "0c0c0c0c0c0c0c0c"
    let fio = io(f)
    var asks = 0
    let resolve = siteResolver(ccProbeWith(fio).site,
      proc(p: string): bool =
        inc asks
        fio.pathExists(p))
    check resolve("gcc").path == FakeBin & "/gcc"
    check resolve("g++").path == FakeBin & "/g++"
    check resolve("gcc").path == FakeBin & "/gcc"
    check not resolve("clang++").found
    let before = asks
    check resolve("g++").path == FakeBin & "/g++"
    check not resolve("clang++").found
    check asks == before                       # neither searched again

  test "the C++ driver is found with the build's search order, not by its name":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.env["PATH"] = "/opt/first:" & FakeBin
    f.fileHex["/opt/first/g++"] = "0d0d0d0d0d0d0d0d"   # an earlier PATH entry wins
    f.fileHex[FakeBin & "/g++"] = "0c0c0c0c0c0c0c0c"
    let seen = new(seq[string])
    check cppProbe(f, CppCmd, seen).ok
    check seen[] == @["/opt/first/g++"]

  test "a C++ driver the build's nim would not find still refuses; nothing runs":
    let f = gnuHost(GccManifestCmd, GccDumpX64)       # no g++ anywhere
    let seen = new(seq[string])
    let hp = cppProbe(f, CppCmd, seen)
    check not hp.ok
    check hp.failure == hpfDriverUnresolved
    check "'g++'" in hp.message
    check seen[].len == 0

  test "an undiscovered site refuses every driver, the C++ one included":
    let f = gnuHost(GccManifestCmd, GccDumpX64)
    f.fileHex[FakeBin & "/g++"] = "0c0c0c0c0c0c0c0c"
    f.discovery = Discovery(kind: dkNotFound, why: "no manifest")
    let seen = new(seq[string])
    let hp = cppProbe(f, CppCmd, seen)
    check not hp.ok
    check hp.failure == hpfDriverUnresolved
    check "no manifest" in hp.message
    check seen[].len == 0

  test "on Windows the C++ driver is searched in nim's directory first, .exe appended":
    let f = mingwHost()
    f.fileHex[FakeNimDir & "\\g++.exe"] = "0e0e0e0e0e0e0e0e"
    f.fileHex["C:\\mingw\\bin\\g++.exe"] = "0f0f0f0f0f0f0f0f"
    let seen = new(seq[string])
    check cppProbe(f, "g++ -c -o C:/nc/w.o C:/proj/src/wrap.cpp", seen).ok
    check seen[] == @[FakeNimDir & "\\g++.exe"]

  test "parseNimExe takes the last label line":
    check parseNimExe("") == ""
    check parseNimExe("crisol_nimexe=C:\\fake\\nim.exe\r\nhint\r\n" &
                      "crisol_nimexe=C:\\nim\\bin\\nim.exe\r\n") == "C:\\nim\\bin\\nim.exe"

suite "configuration that tells the probe from a test is refused (R10-S7)":

  test "projectDependentIdent finds each identifier, in any spelling Nim accepts":
    for src in ["if projectName() == \"a\": switch(\"cc\", \"clang\")",
                "let d = projectDir()", "echo project_path()",
                "if paramStr(1).endsWith(\"x\"): discard", "discard paramCount()",
                "for p in commandLineParams(): discard",
                "import std/compilesettings\necho querySetting(projectFull)",
                "when projectNAME().len > 0: discard"]:
      checkpoint src
      check projectDependentIdent(src).len > 0

  test "projectDependentIdent: nimcacheDir, and backtick-split spellings (R11-S6)":
    ## `nimcacheDir()` is the probe's scratch nimcache for the discovery
    ## compile and each test's own for a test. Inside backticks Nim joins
    ## the tokens into one identifier, so `` `project Dir` `` is projectDir.
    for src in ["if nimcacheDir().len > 0: switch(\"cc\", \"clang\")",
                "let d = `project Dir`()",
                "let d = `projectDir`()",
                "echo `param Str`(1)",
                "echo `nimcache Dir`()"]:
      checkpoint src
      check projectDependentIdent(src).len > 0
    for src in ["let `my var` = 1", "proc `+`(a, b: int): int = a"]:
      checkpoint src
      check projectDependentIdent(src) == ""

  test "projectDependentIdent skips comments, strings and other identifiers":
    for src in ["# projectName() picks the compiler\nswitch(\"define\", \"X\")",
                "#[ projectName\n #[ nested ]# projectDir ]#\ndiscard",
                "switch(\"path\", \"projectName\")",
                "const s = \"\"\"projectPath()\n\"\"\"",
                "switch(\"path\", r\"C:\\projectDir\\\")",
                "switch(\"path\", thisDir() & \"/src\")",
                "let c = 'p'\nlet ProjectName = 1",   # a different identifier: the first letter is exact
                "hint(\"projectDirX\", off)", "let myprojectName = 1"]:
      checkpoint src
      check projectDependentIdent(src) == ""

  test "scanSources: the .nims configs and what they import, not Nim's library or .cfg files":
    let m = """{"configFiles": ["/nim/config/nim.cfg", "/nim/config/config.nims",
                                "/w/p/nim.cfg", "/w/p/config.nims"],
                "depfiles": [["/nim/config/nim.cfg", "h"], ["/nim/lib/system.nim", "h"],
                             ["/nim/lib/pure/os.nim", "h"], ["/w/p/config.nims", "h"],
                             ["/w/p/helper.nim", "h"], ["/w/p/nim.cfg", "h"]]}"""
    check scanSources(m) == @["/nim/config/config.nims", "/w/p/config.nims",
                              "/w/p/helper.nim"]

  test "manifestCompileCommand records what discovery read, and nim's cwd":
    let m = """{"compile": [["/nc/@mstdinfile.nim.c", "gcc -c /nc/@mstdinfile.nim.c"]],
                "currentDir": "/w/p", "configFiles": ["/w/p/nim.cfg"],
                "depfiles": [["/w/p/nim.cfg", "h"], ["/nim/lib/system.nim", "h"]]}"""
    let d = manifestCompileCommand(m)
    check d.kind == dkFound
    check d.nimCwd == "/w/p"
    check d.reads == @["/w/p/nim.cfg", "/nim/lib/system.nim"]

suite "the memo re-probes when what the probe read changes (R10-S8, R10-L6)":

  proc ctxOf(root: string): CcProbeContext =
    CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])

  test "each context gets its own answer":
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(knownHalf("gcc " & ctx.projectRoot, "1111111111111111").serializeCompilerHalf &
                          "|" & RuntimeSentinel)), reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    let a = m.lookup(ctxOf("/a"), probe, stamp)
    let b = m.lookup(ctxOf("/b"), probe, stamp)
    check a.fp.compiler.text == "gcc /a"
    check b.fp.compiler.text == "gcc /b"
    check m.lookup(ctxOf("/a"), probe, stamp).fp == a.fp
    check m.lookup(ctxOf("/b"), probe, stamp).fp == b.fp
    check probes == 2

  test "a changed stamp re-probes and replaces the answer; an unchanged one does not":
    var m: ProbeMemo
    var probes = 0
    var state = "one"
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(knownHalf("gcc " & state, "1111111111111111").serializeCompilerHalf &
                          "|" & RuntimeSentinel)), reads: @["/w/p/nim.cfg"])
    var seen: seq[seq[string]] = @[]
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string =
      seen.add reads
      state
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc one"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc one"
    check probes == 1
    check seen[^1] == @["/w/p/nim.cfg"]   # the stamp is over what the probe read
    state = "two"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc two"
    check probes == 2
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc two"
    check probes == 2

  test "lookup: the driver site and the fingerprint are one probe's, re-probed together":
    var m: ProbeMemo
    var probes = 0
    var state = "one"
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(knownHalf("gcc " & state, "1111111111111111").serializeCompilerHalf &
                          "|" & RuntimeSentinel),
                 site: DriverSite(known: true, nimCwd: "/opt/" & state, search: dsPosix)),
               reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = state
    check m.lookup(ctxOf("/a"), probe, stamp).site.nimCwd == "/opt/one"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc one"
    let hit = m.lookup(ctxOf("/a"), probe, stamp)    # a memo hit keeps the site
    check hit.site.known
    check hit.site.nimCwd == "/opt/one"
    check probes == 1
    state = "two"
    let r = m.lookup(ctxOf("/a"), probe, stamp)
    check r.site.nimCwd == "/opt/two"
    check r.fp.compiler.text == "gcc two"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc two"
    check probes == 2

  test "the state directory is scratch, not a key: contexts differing only in it share one answer (R12-D5)":
    ## `runner.runEntrypoint` probes with a fresh private state directory
    ## per call; keyed on it, the memo never hit and grew one entry a call.
    ## R15-S4: the shared answer is an identified one; an unidentified one
    ## is scoped to its state directory (the test below).
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(knownHalf("gcc", "1111111111111111").serializeCompilerHalf &
                          "|" & knownHalf("libc", "2222222222222222").serializeRuntimeHalf)),
               reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    for i in 0 ..< 5:
      discard m.lookup(CcProbeContext(projectRoot: "/a", stateDir: "/tmp/private" & $i,
                                      flags: @[]), probe, stamp)
    check probes == 1
    check m.len == 1
    discard m.lookup(CcProbeContext(projectRoot: "/a", stateDir: "/s", flags: @["-d:x"]),
                     probe, stamp)
    check probes == 2   # the flags ARE an input of the discovery compile
    check m.len == 2

  test "a probe that could not set up its scratch directory is returned but not recorded (R12-D5)":
    ## With the state directory out of the key, a refusal caused by one
    ## state directory (unwritable, say) must not be served for another.
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      if ctx.stateDir == "/ro":
        ProbeRun(toolchain: ToolchainProbe(fp: fpOf(CcSentinel & "|" & RuntimeSentinel)),
                 reads: @[], scratchFailed: true)
      else:
        ProbeRun(toolchain: ToolchainProbe(
                   fp: fpOf(knownHalf("gcc", "1111111111111111").serializeCompilerHalf &
                            "|" & RuntimeSentinel)), reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    let a = CcProbeContext(projectRoot: "/a", stateDir: "/ro", flags: @[])
    let b = CcProbeContext(projectRoot: "/a", stateDir: "/rw", flags: @[])
    check toolchainVerdict(m.lookup(a, probe, stamp).fp).kind == tvUnidentified
    check m.len == 0
    check m.lookup(b, probe, stamp).fp.compiler.text == "gcc"
    check probes == 2

  test "real probe: an uncreatable state directory is reported as a scratch failure":
    let blocker = getTempDir() / ("crisol_ccid_blocker_" & $getCurrentProcessId())
    writeFile(blocker, "a file, so no directory can be made under it")
    defer: removeFile(blocker)
    let r = probeRun(CcProbeContext(projectRoot: getCurrentDir(), stateDir: blocker / "state",
                                    flags: @[]))
    check r.scratchFailed
    check toolchainVerdict(r.toolchain.fp).kind == tvUnidentified

  test "a probe derived from an interrupted tool run is returned but not recorded (R14-D3)":
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      let interrupted = probes == 1
      let text = if interrupted: "interrupted" else: "gcc real"
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(knownHalf(text, "1111111111111111").serializeCompilerHalf &
                          "|" & RuntimeSentinel)),
               reads: @[], interrupted: interrupted)
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "interrupted"
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc real"
    check probes == 2
    check m.lookup(ctxOf("/a"), probe, stamp).fp.compiler.text == "gcc real"
    check probes == 2   # the answer from an uninterrupted probe is kept

  test "an ordinary failure's unidentified answer is recorded (R14-D3)":
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      ProbeRun(toolchain: ToolchainProbe(
                 fp: fpOf(CcSentinel & "|" & RuntimeSentinel)),
               reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    check toolchainVerdict(m.lookup(ctxOf("/a"), probe, stamp).fp).kind == tvUnidentified
    check toolchainVerdict(m.lookup(ctxOf("/a"), probe, stamp).fp).kind == tvUnidentified
    check probes == 1

  test "an unidentified answer is kept for its own state directory only (R15-S4)":
    ## A probe whose scratch directory was set up but whose tools then failed
    ## in it (a noexec or full `/tmp`, say) is not `scratchFailed`, yet its
    ## answer may be about that directory. Served for another state
    ## directory, it would refuse a toolchain that probes fine there.
    var m: ProbeMemo
    var probes = 0
    let probe = proc(ctx: CcProbeContext): ProbeRun =
      inc probes
      if ctx.stateDir == "/noexec":
        ProbeRun(toolchain: ToolchainProbe(
                   fp: fpOf(knownHalf("gcc", "1111111111111111").serializeCompilerHalf &
                            "|" & RuntimeSentinel)), reads: @[])
      else:
        ProbeRun(toolchain: ToolchainProbe(
                   fp: fpOf(knownHalf("gcc", "1111111111111111").serializeCompilerHalf &
                            "|" & knownHalf("libc", "2222222222222222").serializeRuntimeHalf)),
                 reads: @[])
    let stamp = proc(ctx: CcProbeContext; reads: seq[string]): string = "s"
    let bad = CcProbeContext(projectRoot: "/a", stateDir: "/noexec", flags: @[])
    let good = CcProbeContext(projectRoot: "/a", stateDir: "/rw", flags: @[])
    check toolchainVerdict(m.lookup(bad, probe, stamp).fp).kind == tvUnidentified
    check toolchainVerdict(m.lookup(bad, probe, stamp).fp).kind == tvUnidentified
    check probes == 1   # the same state directory is a hit
    check toolchainVerdict(m.lookup(good, probe, stamp).fp).kind == tvIdentified
    check probes == 2
    check m.len == 1    # the identified answer replaced the scoped one
    # An identified answer is about the toolchain, so every state directory
    # shares it (R12-D5), the one that failed included.
    check toolchainVerdict(m.lookup(bad, probe, stamp).fp).kind == tvIdentified
    check probes == 2

  test "RunWatch: any watched run ending reInterrupted marks the probe interrupted (R14-D3)":
    let w = RunWatch()
    let plain = w.watch(proc(cmd: string, args: openArray[string]): RunResult =
      if cmd == "cc": ran(1, "", "boom") else: notRun(reTimedOut, "slow"))
    discard plain("cc", [])
    discard plain("ld", [])
    check not w.interrupted       # ordinary failures are not interruptions
    let merged = w.watch(proc(cmd: string, args: openArray[string]): RunResult =
      notRun(reInterrupted, "was interrupted"))
    let r = merged("cl", [])
    check r.ending == reInterrupted   # passed through unchanged
    check w.interrupted

  test "realStamp moves with the environment, a read file and a new config file":
    let root = createTempDir("crisol_ccid_stamp_", "")
    defer: removeDir(root)
    let ctx = ctxOf(root)
    let read = root / "read.txt"
    writeFile(read, "a")
    let base = realStamp(ctx, @[read])
    check realStamp(ctx, @[read]) == base
    let oldCl = getEnv("CL")
    putEnv("CL", oldCl & "/DCRISOL_STAMP")
    check realStamp(ctx, @[read]) != base
    if oldCl.len == 0: delEnv("CL") else: putEnv("CL", oldCl)
    check realStamp(ctx, @[read]) == base
    putEnv("CRISOL_CACHE_TOKEN_STAMPTEST", "x")   # scrubbed by every run
    check realStamp(ctx, @[read]) == base
    delEnv("CRISOL_CACHE_TOKEN_STAMPTEST")
    writeFile(read, "b")
    let edited = realStamp(ctx, @[read])
    check edited != base
    writeFile(root / "nim.cfg", "cc = clang\n")    # not read before: now it would be
    check realStamp(ctx, @[read]) != edited

when defined(posix):
  suite "the real probe (POSIX host)":

    test "ccFingerprint identifies this host's configured compiler":
      let root = createTempDir("crisol_ccid_real_", "")
      defer: removeDir(root)
      let fp = ccFingerprint(CcProbeContext(projectRoot: root,
                                            stateDir: root / ".crisol",
                                            flags: @[]))
      checkpoint $fp & " / " & fp.compiler.why & " / " & fp.runtime.why
      check toolchainVerdict(fp).kind == tvIdentified
      # The scratch directory is removed.
      var left = 0
      for _ in walkDir(root / ".crisol"): inc left
      check left == 0

    test "a directory or a non-executable file named like the driver, earlier on PATH, is passed over (R13-S4)":
      # execvp moves past an entry it may not execute and runs the real
      # compiler later on PATH; the probe must identify that one, as it
      # does without the shadows, rather than stop at the shadow and refuse.
      let root = createTempDir("crisol_ccid_shadow_", "")
      defer: removeDir(root)
      let dirs = root / "dirs"
      let noexec = root / "noexec"
      createDir(dirs)
      createDir(noexec)
      for name in ["gcc", "cc", "clang"]:
        createDir(dirs / name)
        writeFile(noexec / name, "#!/bin/sh\nexit 1\n")
        setFilePermissions(noexec / name, {fpUserRead, fpUserWrite})
      let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol",
                               flags: @[])
      let control = ccFingerprint(ctx)
      let saved = getEnv("PATH")
      putEnv("PATH", dirs & $PathSep & noexec & $PathSep & saved)
      let shadowed = try: ccFingerprint(ctx) finally: putEnv("PATH", saved)
      checkpoint $shadowed & " / " & shadowed.compiler.why
      check toolchainVerdict(control).kind == tvIdentified
      check toolchainVerdict(shadowed).kind == tvIdentified
      check shadowed.compiler == control.compiler

    test "the project nim.cfg reaches the probe, wherever the state dir is (R9-D1b)":
      let root = createTempDir("crisol_ccid_cfg_", "")
      defer: removeDir(root)
      # A state directory OUTSIDE the project (CRISOL_STATE_DIR on a
      # mounted volume): the project's nim.cfg must still apply.
      let state = createTempDir("crisol_ccid_cfg_state_", "")
      defer: removeDir(state)
      let ctx = CcProbeContext(projectRoot: root, stateDir: state, flags: @[])
      let plain = ccFingerprint(ctx)
      writeFile(root / "nim.cfg", "passC = \"-DCRISOL_CFG_PROBE=1\"\n")
      let withDefine = ccFingerprint(ctx)
      writeFile(root / "nim.cfg", "cc = nosuchcompiler\n")
      let unknown = ccFingerprint(ctx)
      check toolchainVerdict(plain).kind == tvIdentified
      check toolchainVerdict(withDefine).kind == tvIdentified
      check plain.compiler != withDefine.compiler
      check plain.runtime == withDefine.runtime
      check toolchainVerdict(unknown) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)

    test "the project nim.cfg `cc = ...` selects the identity (R9-D1b)":
      # Needs two distinct GNU-family compilers. On macOS `gcc` is Apple
      # clang, so the premise does not hold there.
      let gcc = findExe("gcc")
      let twoCompilers = findExe("clang").len > 0 and gcc.len > 0 and
                         "clang" notin execProcess(gcc, args = ["--version"],
                                                   options = {poStdErrToStdOut})
      if not twoCompilers:
        echo "CRISOL-SKIP-TEST: tests/unit/test_ccidentity.nim#cfg_cc_selects_gcc_or_clang"
        skip()
      else:
        let root = createTempDir("crisol_ccid_cc_", "")
        defer: removeDir(root)
        let state = createTempDir("crisol_ccid_cc_state_", "")
        defer: removeDir(state)
        let ctx = CcProbeContext(projectRoot: root, stateDir: state, flags: @[])
        writeFile(root / "nim.cfg", "cc = gcc\n")
        let g = ccFingerprint(ctx)
        writeFile(root / "nim.cfg", "cc = clang\n")
        let c = ccFingerprint(ctx)
        check g.compiler.text.startsWith("gcc ")
        check c.compiler.text.startsWith("clang ")
        check g.compiler != c.compiler

    test "the global flags reach the probe: --passC:-m32 is a different target":
      let root = createTempDir("crisol_ccid_flags_", "")
      defer: removeDir(root)
      let a = ccFingerprint(CcProbeContext(projectRoot: root,
                                           stateDir: root / ".crisol", flags: @[]))
      let b = ccFingerprint(CcProbeContext(projectRoot: root,
                                           stateDir: root / ".crisol",
                                           flags: @["--passC:-m32"]))
      check a.compiler != b.compiler

    test "a nim that cannot compile the probe fails closed":
      let root = createTempDir("crisol_ccid_bad_", "")
      defer: removeDir(root)
      let fp = ccFingerprint(CcProbeContext(projectRoot: root,
                                            stateDir: root / ".crisol",
                                            flags: @["--cc:nosuchcompiler"]))
      check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)

    test "a config.nims that branches on the project is refused (R10-S7)":
      let root = createTempDir("crisol_ccid_projname_", "")
      defer: removeDir(root)
      let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])
      writeFile(root / "config.nims", "switch(\"define\", \"crisolPlain\")\n")
      check toolchainVerdict(ccFingerprint(ctx)).kind == tvIdentified
      writeFile(root / "config.nims",
                "if projectName() != \"stdinfile\": switch(\"cc\", \"clang\")\n")
      let fp = ccFingerprint(ctx)
      check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
      check "projectName" in fp.compiler.why
      # Hidden in an imported helper: Nim records it in depfiles.
      writeFile(root / "pick.nim", "proc pick*(): bool = projectDir().len > 0\n")
      writeFile(root / "config.nims", "import pick\nif pick(): discard\n")
      check "projectDir" in ccFingerprint(ctx).compiler.why

    test "a config.nims that puts a wrapper gcc first on PATH: the wrapper is identified (R11-S1)":
      let gcc = findExe("gcc")
      if gcc.len == 0:
        echo "CRISOL-SKIP-TEST: tests/unit/test_ccidentity.nim#config_nims_path_wrapper"
        skip()
      else:
        let root = createTempDir("crisol_ccid_putenv_", "")
        defer: removeDir(root)
        let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])
        writeFile(root / "nim.cfg", "cc = gcc\n")
        let plain = probeRun(ctx)
        check toolchainVerdict(plain.toolchain.fp).kind == tvIdentified
        let wrapper = root / "tools" / "gcc"
        createDir(root / "tools")
        writeFile(wrapper, "#!/bin/sh\n# v1\nexec " & gcc & " \"$@\"\n")
        setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
        # The directory is spelled as this test spells it, not `thisDir()`,
        # which a macOS /var -> /private/var link would respell.
        writeFile(root / "config.nims",
                  "putEnv(\"PATH\", " & escape(root / "tools") &
                  " & \":\" & getEnv(\"PATH\"))\n")
        let wrapped = probeRun(ctx)
        checkpoint $wrapped.toolchain.fp & " / " & wrapped.toolchain.fp.compiler.why
        check toolchainVerdict(wrapped.toolchain.fp).kind == tvIdentified
        check wrapper in wrapped.reads                 # the wrapper was hashed
        check wrapped.toolchain.site.pathVar.startsWith(root / "tools")
        check wrapped.toolchain.fp.compiler != plain.toolchain.fp.compiler
        # Upgrading the wrapper moves the key.
        writeFile(wrapper, "#!/bin/sh\n# v2\nexec " & gcc & " \"$@\"\n")
        check probeRun(ctx).toolchain.fp.compiler != wrapped.toolchain.fp.compiler

    test "cachedCcFingerprint re-probes after the project nim.cfg changes (R10-S8)":
      let root = createTempDir("crisol_ccid_memo_", "")
      defer: removeDir(root)
      let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])
      let before = cachedCcFingerprint(ctx)
      check cachedCcFingerprint(ctx) == before
      writeFile(root / "nim.cfg", "passC = \"-DCRISOL_MEMO_PROBE=1\"\n")
      let after = cachedCcFingerprint(ctx)
      check toolchainVerdict(after).kind == tvIdentified
      check after.compiler != before.compiler
      check after == ccFingerprint(ctx)

    test "cachedCcFingerprint re-probes after a file only the compile read changes (R10-S8)":
      # `flags.nim` is no configuration file Nim looks for by name; the
      # memo knows it only from what the discovery compile recorded.
      let root = createTempDir("crisol_ccid_memo_dep_", "")
      defer: removeDir(root)
      let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])
      writeFile(root / "flags.nim", "const extra* = \"-DCRISOL_DEP=1\"\n")
      writeFile(root / "config.nims", "import flags\nswitch(\"passC\", extra)\n")
      let before = cachedCcFingerprint(ctx)
      check toolchainVerdict(before).kind == tvIdentified
      writeFile(root / "flags.nim", "const extra* = \"-DCRISOL_DEP=22\"\n")
      let after = cachedCcFingerprint(ctx)
      check after.compiler != before.compiler
      check after == ccFingerprint(ctx)
else:
  # The real-probe suite above is POSIX-only; say so, so
  # ci/assert-subset-honesty.sh sees it not run.
  echo "CRISOL-SKIP-TEST: tests/unit/test_ccidentity.nim#real_probe_posix_host"

suite "the serialized grammar round-trips arbitrary compiler text (R6-S6)":

  test "parseCcFingerprint($fp) == fp for random GNU and MSVC answers":
    var rng = initRand(0x5eed)
    proc junk(rng: var Rand): string =
      result = ""
      for _ in 0 ..< rng.rand(0 .. 24):
        result.add char(rng.rand(0 .. 255))
    for i in 0 ..< 300:
      let fp =
        if i mod 2 == 0:
          probe(gnuHost(GccManifestCmd,
                        "#define __GNUC__ " & junk(rng) & "\n#define __GNUC_MINOR__ " &
                        junk(rng) & "\n#define __x86_64__ 1\n#define __linux__ 1\n"))
        else:
          let f = msvcHost()
          f.macroReply = ran(0, MsvcEpX64.replace("crisol_clang=__clang_version__",
                                                  "crisol_clang=\"" & junk(rng) & "\""), "")
          probe(f)
      let s = $fp
      checkpoint s.escape
      let (back, ok) = parseCcFingerprint(s)
      check ok
      check back == fp
      check $back == s
