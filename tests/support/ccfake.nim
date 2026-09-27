## tests/support/ccfake.nim -- a scripted `ccidentity.CcProbeIo`, and the
## recorded probe answers it replays.
##
## The recorded constants are measured output: the MSVC ones from the
## `ghcr.io/coreyleavitt/nim:2.2.10-windows` image (cl 19.44.35228, through
## `vccexe`), the GNU ones from `ghcr.io/coreyleavitt/nim:2.2.10` (gcc 16.2.0,
## clang 22.1.8, glibc 2.43). The mingw and Darwin shapes are NOT measured:
## they are written from the tools' documented output and are marked so.
##
## The recorded compile commands tokenize the same on every host because the
## splitting rules come from the command, never the reading host
## (`ccprobe.argvRulesOf`): the MSVC-family commands split by the Windows C
## runtime's rules, and the GNU ones by the shape of their source path (or a
## `.exe` driver). The MSVC paths are spelled with `/`, which cl accepts; the
## spelling does not decide how they split.
##
## Not a `test_*.nim` file, so the self-discovering test task never runs it.

import std/[strutils, tables]
import crisol/[ccidentity, toolrun]
import "ccprobes"

const
  MsvcManifestCmd* =
    "vccexe.exe /c --platform:amd64 /nologo   /IC:/nim/2.2.10-patched/lib " &
    "/IC:/w/p/sub /nologo /FoC:/nc1/@mstdinfile.nim.c.obj " &
    "C:/nc1/@mstdinfile.nim.c"
  MsvcEpX64* = "\r\n" &
    "crisol_msc_full_ver=194435228\r\n" &
    "crisol_msc_build=0\r\n" &
    "crisol_m_x64=100\r\n" &
    "crisol_m_amd64=100\r\n" &
    "crisol_m_ix86=_M_IX86\r\n" &
    "crisol_m_arm64=_M_ARM64\r\n" &
    "crisol_m_arm64ec=_M_ARM64EC\r\n" &
    "crisol_m_arm=_M_ARM\r\n" &
    "crisol_mt=1\r\n" &
    "crisol_dll=_DLL\r\n" &
    "crisol_debug=_DEBUG\r\n" &
    "crisol_clang=__clang_version__\r\n"
    ## Measured, byte for byte, under no `CL` and under `CL=/W4`, `/MP`,
    ## `/DFOO` and `/nologo`. cl's echo of the source name is on stderr.
  MsvcLinkTrace* = "Searching libraries\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\LIBCMT.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\OLDNAMES.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\um\\kernel32.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\libvcruntime.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\ucrt\\libucrt.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\um\\uuid.lib:\r\n" &
    "Done Searching Libraries\r\n"

  GccManifestCmd* =
    "gcc -c  -w -fmax-errors=3 -fno-strict-aliasing -pthread   " &
    "-I/opt/nim/2.2.10-patched/lib -I/tmp/p/sub " &
    "-o /tmp/nc1/@mstdinfile.nim.c.o /tmp/nc1/@mstdinfile.nim.c"
  GccDumpX64* =
    "#define __GNUC__ 16\n#define __GNUC_MINOR__ 2\n#define __GNUC_PATCHLEVEL__ 0\n" &
    "#define __VERSION__ \"16.2.0\"\n#define __x86_64__ 1\n#define __linux__ 1\n" &
    "#define __SIZEOF_POINTER__ 8\n#define _REENTRANT 1\n"
    ## An excerpt of the measured 408-line dump (the identity lines).
  GccDumpI386* =
    "#define __GNUC__ 16\n#define __GNUC_MINOR__ 2\n#define __GNUC_PATCHLEVEL__ 0\n" &
    "#define __VERSION__ \"16.2.0\"\n#define __i386__ 1\n#define __linux__ 1\n" &
    "#define __SIZEOF_POINTER__ 4\n#define _REENTRANT 1\n"
    ## The same driver under `--passC:-m32` (measured: `__i386__`, no `__x86_64__`).
  ClangDumpX64* =
    "#define __clang__ 1\n#define __clang_major__ 22\n#define __clang_minor__ 1\n" &
    "#define __clang_patchlevel__ 8\n#define __GNUC__ 4\n" &
    "#define __VERSION__ \"Clang 22.1.8\"\n#define __x86_64__ 1\n#define __linux__ 1\n"
  LibcPath* = "/usr/lib/x86_64-linux-gnu/libc.so.6"
  LddVersion* = "ldd (GNU libc) 2.43\nCopyright (C) 2026 Free Software Foundation, Inc.\n"

  MingwDumpX64* =
    "#define __GNUC__ 14\n#define __GNUC_MINOR__ 2\n#define __GNUC_PATCHLEVEL__ 0\n" &
    "#define __x86_64__ 1\n#define __MINGW32__ 1\n#define __MINGW64__ 1\n#define _WIN32 1\n"
    ## NOT measured: the documented mingw-w64 predefines.
  DarwinDumpArm64* =
    "#define __clang__ 1\n#define __clang_major__ 17\n#define __clang_minor__ 0\n" &
    "#define __clang_patchlevel__ 0\n#define __aarch64__ 1\n#define __APPLE__ 1\n" &
    "#define __MACH__ 1\n"
    ## NOT measured: the documented Apple clang predefines.
  DarwinSdk* = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  SwVers* = "ProductName:\t\tmacOS\nProductVersion:\t\t15.2\nBuildVersion:\t\t24C101\n"
    ## NOT measured: the documented `sw_vers` shape.

  MsvcDllLinkTrace* = "Searching libraries\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\MSVCRT.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\OLDNAMES.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\um\\kernel32.lib:\r\n" &
    "    Searching C:\\msvc\\vc\\lib\\vcruntime.lib:\r\n" &
    "    Searching C:\\msvc\\sdk\\lib\\ucrt\\ucrt.lib:\r\n" &
    "Done Searching Libraries\r\n"
    ## The shape of a `/MD` link: import libraries for the DLL runtime. Written
    ## from `MsvcLinkTrace` with the documented `/MD` library names.
  FakeBin* = "/usr/bin"
    ## The PATH directory holding a POSIX fake's driver.
  FakeCwd* = "/w/p"
  FakeNimDir* = "C:\\nim\\bin"
    ## A Windows fake's nim directory, which holds `vccexe.exe` as Nim ships it.
  FakeWinCwd* = "C:\\w\\p"
  SystemRoot* = "C:\\Windows"
  System32* = SystemRoot & "\\System32"

type
  FakeCc* = ref object
    ## One scripted toolchain. Every reply not set is "the tool is absent".
    discovery*:   Discovery
    macroReply*:  RunResult           ## the answer to `/EP` or `-dM -E`
    linkReply*:   RunResult           ## the answer to `/link /VERBOSE:LIB`
    printFile*:   Table[string, string] ## artifact -> the path the driver prints
    printFileFails*: string           ## the artifact whose `-print-file-name=` lookup exits 1
    lddReply*:    RunResult
    sdkPath*:     RunResult
    sdkVersion*:  RunResult
    swVers*:      RunResult
    fileHex*:     Table[string, string] ## path -> content digest; absent = unreadable
    unreadable*:  seq[string]         ## paths that exist but cannot be read
    driverHex*:   string              ## "" = the driver binary is unreadable
    driverPath*:  string              ## where the driver binary is; "" = nowhere
    env*:         Table[string, string]
      ## This process's environment (`CcProbeIo.getEnv`), which is also what
      ## the discovery reports as nim's, unless `nimEnv` says otherwise.
    nimEnv*:      Table[string, string]
      ## A variable a `config.nims` set for nim alone (`putEnv`): the
      ## discovery reports this value instead of `env`'s.
    search*:      DriverSearch
    calls*:       seq[seq[string]]    ## every run, as `@[cmd] & args`

proc absent(): RunResult = notRun(reNotStarted, "fake: not on PATH")

proc newFakeCc*(ccCmd: string): FakeCc =
  ## A POSIX host whose driver (the command's first token) is on PATH in
  ## `FakeBin`.
  let token = ccCmd.strip.split(' ')[0]
  result = FakeCc(
    discovery: Discovery(kind: dkFound, ccCmd: ccCmd, nimExe: "", nimCwd: FakeCwd),
    macroReply: absent(), linkReply: absent(), lddReply: absent(),
    sdkPath: absent(), sdkVersion: absent(), swVers: absent(),
    printFile: initTable[string, string](),
    fileHex: initTable[string, string](),
    driverHex: "d1d1d1d1d1d1d1d1", driverPath: FakeBin & "/" & token,
    env: initTable[string, string](), search: dsPosix)
  result.env["PATH"] = FakeBin

proc onWindows*(f: FakeCc; driverDir: string) =
  ## Make `f` a Windows host: nim in `FakeNimDir`, the driver in `driverDir`
  ## (`.exe` appended to its name, as `CreateProcess` does).
  f.search = dsWindows
  f.discovery.nimExe = FakeNimDir & "\\nim.exe"
  f.discovery.nimCwd = FakeWinCwd
  var name = f.driverPath.rsplit('/', maxsplit = 1)[^1]
  if '.' notin name: name.add ".exe"
  f.driverPath = driverDir & "\\" & name
  f.env["PATH"] = driverDir

proc msvcHost*(): FakeCc =
  ## The measured MSVC image: cl 19.44 x64, the measured link trace, every
  ## library readable.
  result = newFakeCc(MsvcManifestCmd)
  result.onWindows(FakeNimDir)
  result.macroReply = ran(0, MsvcEpX64, "crisol_cc_macros.c\r\n")
  result.linkReply = ran(0, MsvcLinkTrace, "")
  var i = 0
  for lib in ["C:\\msvc\\vc\\lib\\LIBCMT.lib", "C:\\msvc\\vc\\lib\\OLDNAMES.lib",
              "C:\\msvc\\sdk\\lib\\um\\kernel32.lib",
              "C:\\msvc\\vc\\lib\\libvcruntime.lib",
              "C:\\msvc\\sdk\\lib\\ucrt\\libucrt.lib",
              "C:\\msvc\\sdk\\lib\\um\\uuid.lib"]:
    inc i
    result.fileHex[lib] = "a" & $i & "00000000000000"

proc msvcDllHost*(): FakeCc =
  ## `msvcHost` linking the DLL runtime (`/MD`): the import libraries readable,
  ## the runtime DLLs present in the system directory.
  result = msvcHost()
  result.linkReply = ran(0, MsvcDllLinkTrace, "")
  result.env["SystemRoot"] = SystemRoot
  var i = 0
  for lib in ["C:\\msvc\\vc\\lib\\MSVCRT.lib", "C:\\msvc\\vc\\lib\\vcruntime.lib",
              "C:\\msvc\\sdk\\lib\\ucrt\\ucrt.lib"]:
    inc i
    result.fileHex[lib] = "b" & $i & "00000000000000"
  result.fileHex[System32 & "\\vcruntime140.dll"] = "d100000000000000"
  result.fileHex[System32 & "\\ucrtbase.dll"] = "d200000000000000"

proc mingwHost*(): FakeCc =
  ## A Windows mingw-w64 host (UNMEASURED shape): both import libraries
  ## resolved and readable, both system runtime DLLs present.
  result = newFakeCc("x86_64-w64-mingw32-gcc -c -O1 -o C:/nc/a.o C:/nc/@mstdinfile.nim.c")
  result.onWindows("C:\\mingw\\bin")
  result.macroReply = ran(0, MingwDumpX64, "")
  result.env["SystemRoot"] = SystemRoot
  result.printFile["libucrt.a"] = "C:/mingw/lib/libucrt.a"
  result.printFile["libmsvcrt.a"] = "C:/mingw/lib/libmsvcrt.a"
  result.fileHex["C:/mingw/lib/libucrt.a"] = "1a1a1a1a1a1a1a1a"
  result.fileHex["C:/mingw/lib/libmsvcrt.a"] = "2b2b2b2b2b2b2b2b"
  result.fileHex[System32 & "\\ucrtbase.dll"] = "d200000000000000"
  result.fileHex[System32 & "\\msvcrt.dll"] = "d300000000000000"

proc darwinHost*(): FakeCc =
  ## A macOS host (UNMEASURED shape): the SDK from xcrun, `sw_vers` answering.
  result = newFakeCc("clang -c -o a.o /nc/@mstdinfile.nim.c")
  result.macroReply = ran(0, DarwinDumpArm64, "")
  result.sdkPath = ran(0, DarwinSdk & "\n", "")
  result.sdkVersion = ran(0, "15.2\n", "")
  result.swVers = ran(0, SwVers, "")
  result.fileHex[DarwinSdk & "/usr/lib/libSystem.tbd"] = "4d4d4d4d4d4d4d4d"

proc gnuHost*(ccCmd, dump: string): FakeCc =
  ## A glibc host: the given driver and dump, `libc.so.6` resolved and readable.
  result = newFakeCc(ccCmd)
  result.macroReply = ran(0, dump, "")
  result.printFile["libc.so.6"] = LibcPath
  result.fileHex[LibcPath] = "c0c0c0c0c0c0c0c0"
  result.lddReply = ran(0, LddVersion, "")

proc hasArg(args: openArray[string]; a: string): bool =
  for x in args:
    if x == a: return true
  false

proc io*(f: FakeCc): CcProbeIo =
  let run = proc(cmd: string; args: openArray[string]): RunResult =
    f.calls.add @[cmd] & @args
    if cmd == "ldd": return f.lddReply
    if cmd == "sw_vers": return f.swVers
    if cmd == "xcrun":
      return if args.hasArg("--show-sdk-path"): f.sdkPath else: f.sdkVersion
    if args.hasArg("/EP") or args.hasArg("-dM"): return f.macroReply
    for a in args:
      if a.startsWith("-print-file-name="):
        let name = a["-print-file-name=".len .. ^1]
        if name == f.printFileFails: return ran(1, "", "fake: lookup failed")
        # gcc echoes the bare name, rc 0, for a library it cannot resolve.
        return ran(0, f.printFile.getOrDefault(name, name) & "\n", "")
    absent()
  let merged = proc(cmd: string; args: openArray[string]): RunResult =
    f.calls.add @[cmd] & @args
    if args.hasArg("/VERBOSE:LIB"): f.linkReply else: absent()
  CcProbeIo(
    discover: proc(): Discovery =
      result = f.discovery
      if result.kind == dkFound:
        for name in NimEnvNames:
          if name notin result.nimEnv:
            result.nimEnv[name] = f.nimEnv.getOrDefault(name,
                                    f.env.getOrDefault(name, ""))
    ,
    run: run,
    runMerged: merged,
    hashFile: proc(path: string): CcDigest =
      if f.driverPath.len > 0 and path == f.driverPath:
        if f.driverHex.len > 0: CcDigest(kind: cdkKnown, hex: f.driverHex)
        else: CcDigest(kind: cdkUnreadable)
      elif path in f.fileHex: CcDigest(kind: cdkKnown, hex: f.fileHex[path])
      else: CcDigest(kind: cdkUnreadable),
    pathExists: proc(path: string): bool =
      (f.driverPath.len > 0 and path == f.driverPath) or
        path in f.fileHex or path in f.unreadable,
    # The fake filesystem has no directories or permission bits: every
    # file it holds is one the driver search stops at.
    driverStop: proc(path: string): bool =
      (f.driverPath.len > 0 and path == f.driverPath) or
        path in f.fileHex or path in f.unreadable,
    getEnv: proc(name: string): string = f.env.getOrDefault(name, ""),
    search: f.search)

proc probe*(f: FakeCc): CcFingerprint = ccFingerprintWith(io(f))

proc fpOf*(s: string): CcFingerprint =
  ## A fingerprint from its serialized form -- how a test outside
  ## `ccidentity` names a specific identity.
  let (fp, ok) = parseCcFingerprint(s)
  doAssert ok, "not a serialized CcFingerprint: " & s
  fp

const
  SoundFp* = "gcc 16.2.0 x86_64-linux #1111111111111111|ldd (GNU libc) 2.43 #2222222222222222"
    ## A serialized identified fingerprint for tests that need any sound one.
  BlindFp* = "<cc-unavailable>|<runtime-unidentified>"

proc knownHalf*(text, hex: string): CcHalf =
  ## An identified half with the given text and digest.
  fpOf(text & " #" & hex & "|" & RuntimeSentinel).compiler
