## ccidentity.nim -- the identity of the C toolchain Nim will invoke, as the
## C-toolchain component of the soundness key (RFC-0004 component 4; issues
## #21 and #23).
##
## One question: which compiler, targeting what, linking which C runtime, will
## compile this project's tests -- and is that identity sound enough to key a
## shared cache on.
##
## The configured driver
## ---------------------
## The identity is the driver Nim is CONFIGURED to use, not whatever answers
## on PATH. The probe (`probeRun`) compiles a one-line module read from stdin with
## `nim c --compileOnly`, cwd = the project root, and the global crisol.kdl
## flags (the argv `nimargv.nimCompileArgs` builds for every crisol compile),
## into a scratch nimcache under the state directory, and reads the
## compile command Nim recorded in the manifest. So `cc = ...` in the global,
## user and project `nim.cfg` files and a `--cc:` in the global flags are all
## honoured. A per-group `--cc:` and a `nim.cfg`/`config.nims` below the
## project root are not seen: that is issue #24 (the compile environment and
## per-group configuration in the key).
##
## A `config.nims` that can tell the discovery module from a test -- one
## that reads the project's name, path or arguments, directly or through
## what it imports -- is refused rather than trusted
## (`projectDependentIdent`, `scanSources`).
##
## The driver the manifest names is then found where the nim that compiles
## the tests finds it (`ccprobe.locateDriver`): on POSIX the PATH, on
## Windows nim's own directory and cwd before the system directories and
## PATH. The PATH is nim's own, as the discovery module reports it after
## the configuration ran (a `config.nims` can `putEnv` it; R11-S1), and so
## are `CL`/`_CL_` (`NimEnvNames`). The Windows discovery module also asks
## the compiler for its own path (`DiscoverySource`). A relative PATH entry
## is nim's cwd's, not crisol's (R11-S3), so the file found is always an
## absolute path. Every probe runs, and the identity hashes, that file. The fingerprint and the search context
## (`DriverSite`) are one value, `ToolchainProbe`, which a run carries from
## its plan to its execution.
##
## Measured cost of the discovery step: 0.15 s on Linux, 0.7 s in the MSVC
## image. `cachedToolchainProbe` keeps an answer per `CcProbeContext` for as
## long as nothing the probe read has changed (`realStamp`).
##
## The compiler half
## -----------------
## The manifest's command is REPLAYED: `ccprobe.parseCompileCommand` (the one
## parser of a manifest command, shared with the dependency probe) reduces it
## to the driver, the family and the flags without the source, the object
## output or the compile action, and each probe appends its own action and
## translation unit:
##
##   - MSVC family (`cl`, `vccexe`, `clang-cl`): `/EP` over `MsvcMacroTu`,
##     which names `_MSC_FULL_VER`, `_MSC_BUILD`, the target-architecture
##     macros and the runtime-selection macros. Measured on cl 19.44 through
##     both `cl` and `vccexe`: `crisol_msc_full_ver=194435228`, rc 0, under no
##     `CL` and under `CL=/W4`, `/MP`, `/DFOO` and `/nologo`. `/EP` writes no
##     object file. Unlike a banner, the expansion is not localized.
##   - GNU family (gcc, clang, cc): `-dM -E` over an empty unit -- every
##     predefined macro. The whole dump is hashed: it carries the version, the
##     target and the macro-visible effect of the flags (`-m32`, `-pthread`,
##     `-O`). Measured: independent of the `-I` paths and of `LANG`.
##
## The digest also folds the content of the driver binary (a distro rebuild
## that moves no version still moves bytes) and, for MSVC, the values of `CL`
## and `_CL_`: cl reads both on every compile, and a `CL=/DFOO` changes the
## object code without changing any macro the probe names. A `CL`/`_CL_`
## value that names a response file (`@file`) leaves the compiler half
## unidentified: its text does not carry the file's contents, and cl resolves
## the file against each compile's own working directory, which the probe
## does not share. The probes inherit this process's `CL`/`_CL_`; when the
## nim configuration gives cl different ones (`putEnv`/`delEnv` in a
## `config.nims`), the probes cannot replay the build and both halves are
## unidentified (`clMismatch`, R11-S1). Every other compile-affecting
## environment variable is issue #24.
##
## The runtime half
## ----------------
## What the tests RUN against, chosen by the TARGET the compiler half
## reported, never by the host OS (`runtimeProbeFor`):
##
##   - MSVC: link a trivial program with `/link /VERBOSE:LIB` and hash every
##     library the linker searched. Under the static runtime (`/MT`, Nim's
##     default for vcc) those `.lib` files are the runtime code itself. Under
##     the DLL runtime (`/MD`) they are import libraries, so each one that
##     binds a runtime DLL (`MsvcImportDlls`: `vcruntime140.dll`,
##     `ucrtbase.dll`, `msvcp140.dll` and their debug forms) adds that DLL,
##     resolved as the loader resolves it (`loaderDll`).
##   - glibc-style targets: `ldd --version` for the label, and the content of
##     the `libc.so.6` the driver resolves with `-print-file-name=` -- the
##     shared object itself, which the loader maps. `ldd` is optional: when
##     it cannot be run (not on PATH) or fails, the label is the resolved
##     library names instead; the content identifies the runtime either way.
##   - mingw (`__MINGW32__`): the content of `libucrt.a` and `libmsvcrt.a`
##     as the driver resolves them, and, for each that resolves, the system
##     DLL it imports from (`ucrtbase.dll`, `msvcrt.dll`), resolved as the
##     loader resolves it. UNMEASURED: no mingw toolchain in the local images;
##     the recorded shapes in `test_ccidentity.nim` are written from the
##     documented output, and a Windows+mingw run is the proof.
##   - Darwin (`__APPLE__`): the content of the SDK's `usr/lib/libSystem.tbd`
##     (the SDK from `-isysroot`/`--sysroot` in the replayed flags, else
##     `xcrun --show-sdk-path`), which is what the link resolves against, and
##     the `sw_vers` answer (product version, any extra version such as a
##     rapid security response, build), which is what identifies the
##     `libSystem` the tests load: it lives in the dyld shared cache, not in
##     a file this probe can read. UNMEASURED locally: the macOS CI leg is
##     the proof.
##
## A DLL is resolved in the system directory (`System32`; `SysWOW64` for an
## x86 target on 64-bit Windows; `Sysnative` when this process is itself
## 32-bit and the target is not x86), then the Windows directory. The
## loader's earlier step, the program's own directory, is a crisol output
## directory that holds no runtime DLL. A DLL found in neither directory
## leaves the runtime half unidentified rather than being looked up on PATH:
## the test's working directory precedes PATH in the loader's search, so a
## PATH hit is not known to be the copy that loads.
##
## Fail closed
## -----------
## Anything that stops a half from being identified -- the driver cannot be
## discovered, a probe does not finish (`toolrun.RunResult` not `reExited`) or
## exits non-zero, its answer is malformed, an artifact cannot be found or
## read -- makes that half `cfsUnavailable`. `toolchainVerdict` then reads
## `tvUnidentified`, and the run turns the result cache off
## (`toolchainwarn.cacheGate`). A stale cached result is the defect; an
## unidentified toolchain only costs misses.
##
## Serialization
## -------------
## `$` and `parseCcFingerprint` are the one producer and the one parser of
## the `"<compiler half>|<runtime half>"` string that `KeyInputs.ccVersion`,
## `DepGraphHeader.ccVersion` and `depgraph.loadDepGraph` carry. A half is
## `<text> #<hex>` or its sentinel. `CcHalf` can only be built inside this
## module, and every constructor normalizes `text` so it holds no `|` or `#`
## (`validText`), which is what makes `parseCcFingerprint($fp).fp == fp` hold
## for every value.
##
## Imports
## -------
## Only std, `crisol/fnv`, `crisol/nimargv` (no imports), `crisol/toolrun`
## (over `crisol/toolexec`), `crisol/cachesecrets`, `crisol/ccprobe` (itself
## std + `crisol/paths` + `crisol/ioutils`) and `crisol/headerprobe` (std +
## `ccprobe`, `paths`, `toolrun`), none of
## which reach back to `render`, `jsonout`, `runcore` or `api`, which import
## this module.

import std/[algorithm, envvars, json, os, options, strutils, tables, tempfiles, times]
import crisol/fnv       # fnv1a64/toHex16 -- never std/hashes, which is not stable across Nim versions
import crisol/toolrun   # RunProc/RunResult and the real runners
import crisol/ccprobe   # CcFamily/CompileCommand/parseCompileCommand/anySepBaseName -- the shared manifest-command parse
import crisol/nimargv   # nimCompileArgs -- the discovery compile is a crisol compile
import crisol/cachesecrets  # isCacheSecretName -- the stamp ignores the namespace the run scrubs
from crisol/headerprobe import realDriverStop  # where execvp/CreateProcess stop (R13-S4)

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

const
  CcSentinel* = "<cc-unavailable>"
    ## The serialized form of an unidentified compiler half.
  RuntimeSentinel* = "<runtime-unidentified>"
    ## The serialized form of an unidentified runtime half.

type
  CcDigestKind* = enum
    cdkUnreadable  ## the file could not be read (missing, unreadable, empty)
    cdkKnown       ## a content digest was computed

  CcDigest* = object
    ## The result of hashing a file's content.
    case kind*: CcDigestKind
    of cdkKnown: hex*: string
    of cdkUnreadable: discard

  CcFieldState* = enum
    cfsUnavailable ## nothing was identified. Ordinal 0, so the zero value
                   ## `CcHalf()` -- the only one code outside this module can
                   ## build -- is unidentified and fails closed.
    cfsKnown       ## identified: legible text and a content digest

  CcHalf* = object
    ## One half (compiler or runtime) of a `CcFingerprint`. Fields are
    ## private: a half is built by a probe or by `parseCcFingerprint`, so every
    ## known half satisfies `validText`/`validHex`.
    case st: CcFieldState
    of cfsKnown:
      txt: string
      hx:  string
    of cfsUnavailable:
      reason: string  ## diagnostic only: not serialized, ignored by `==`

  CcFingerprint* = object
    compiler*: CcHalf
    runtime*:  CcHalf

proc state*(h: CcHalf): CcFieldState = h.st

proc text*(h: CcHalf): string =
  ## The legible identity; "" for an unidentified half.
  case h.st
  of cfsKnown: h.txt
  of cfsUnavailable: ""

proc digest*(h: CcHalf): Option[string] =
  ## The content digest (hex), which every known half has; `none` for an
  ## unidentified one, which has no digest at all (not an unreadable one).
  case h.st
  of cfsKnown: some(h.hx)
  of cfsUnavailable: none(string)

proc why*(h: CcHalf): string =
  ## Why the half is unidentified, for the warning line; "" for a half
  ## parsed from its serialized form, and for the zero value.
  case h.st
  of cfsUnavailable: h.reason
  of cfsKnown: ""

proc `==`*(a, b: CcDigest): bool =
  if a.kind != b.kind: return false
  case a.kind
  of cdkKnown: a.hex == b.hex
  of cdkUnreadable: true

proc `==`*(a, b: CcHalf): bool =
  if a.st != b.st: return false
  case a.st
  of cfsKnown: a.txt == b.txt and a.hx == b.hx
  of cfsUnavailable: true

proc validText(t: string): bool =
  ## Non-empty, printable ASCII, no `|` (the half separator) and no `#` (the
  ## digest marker), no leading or trailing space.
  if t.len == 0 or t[0] == ' ' or t[^1] == ' ': return false
  for c in t:
    if c notin {' ' .. '~'} or c in {'|', '#'}: return false
  true

proc validHex(h: string): bool =
  h.len > 0 and h.allCharsInSet(HexDigits)

proc sanitizeText(t: string): string =
  ## `t` mapped into `validText`'s alphabet: every other byte becomes `_`,
  ## whitespace runs collapse to one space, the ends are trimmed.
  result = ""
  for c in t:
    let m = if c in Whitespace: ' '
            elif c notin {' ' .. '~'} or c in {'|', '#'}: '_'
            else: c
    if m == ' ' and (result.len == 0 or result[^1] == ' '): continue
    result.add m
  result = result.strip
  if result.len == 0: result = "unnamed"

proc known(text, hex: string): CcHalf =
  ## A known half. `text` is normalized; `hex` must already be a digest.
  doAssert validHex(hex), "ccidentity: not a hex digest: " & hex
  CcHalf(st: cfsKnown, txt: sanitizeText(text), hx: hex)

proc unavailable(reason: string): CcHalf =
  CcHalf(st: cfsUnavailable, reason: reason)

type
  UnidentifiedPart* = enum
    ## Which part of the toolchain an unidentified verdict is about -- one
    ## value per warning line in `toolchainwarn`, so its `case` is exhaustive.
    upCompiler  ## only the compiler half is unidentified
    upRuntime   ## only the runtime half is unidentified
    upBoth      ## neither half is identified

  ToolchainVerdictKind* = enum
    tvIdentified    ## both halves are known: the fingerprint can key a cache
    tvUnidentified  ## at least one half is unidentified

  ToolchainVerdict* = object
    ## Whether a fingerprint can key the result cache, and if not, which part
    ## could not be identified. An unidentified half serializes to a
    ## constant, so two hosts that differ only in what it failed to see would
    ## share a key: `runcore.runTestsWith` turns the cache off for the run
    ## (`toolchainwarn.cacheGate`) and keys the depgraph and nimcache on a
    ## per-run identity (`toolchainwarn.toolchainIdentity`).
    case kind*: ToolchainVerdictKind
    of tvIdentified: discard
    of tvUnidentified: part*: UnidentifiedPart

proc toolchainVerdict*(fp: CcFingerprint): ToolchainVerdict =
  let c = fp.compiler.st == cfsKnown
  let r = fp.runtime.st == cfsKnown
  if c and r: ToolchainVerdict(kind: tvIdentified)
  elif r: ToolchainVerdict(kind: tvUnidentified, part: upCompiler)
  elif c: ToolchainVerdict(kind: tvUnidentified, part: upRuntime)
  else: ToolchainVerdict(kind: tvUnidentified, part: upBoth)

proc `==`*(a, b: ToolchainVerdict): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tvIdentified: true
  of tvUnidentified: a.part == b.part

proc `$`*(v: ToolchainVerdict): string =
  case v.kind
  of tvIdentified: "identified"
  of tvUnidentified: "unidentified (" & $v.part & ")"

proc serializeHalf(h: CcHalf; unavailableSentinel: string): string =
  ## One half in its serialized shape: `<text> #<hex>`, or the sentinel.
  case h.st
  of cfsKnown: h.txt & " #" & h.hx
  of cfsUnavailable: unavailableSentinel

proc serializeCompilerHalf*(h: CcHalf): string =
  ## A compiler half exactly as `$` writes it: `<text> #<hex>`, or
  ## `CcSentinel`. `render.nim` prints a changed half verbatim with it.
  serializeHalf(h, CcSentinel)

proc serializeRuntimeHalf*(h: CcHalf): string =
  ## A runtime half exactly as `$` writes it: `<text> #<hex>`, or
  ## `RuntimeSentinel`.
  serializeHalf(h, RuntimeSentinel)

proc `$`*(fp: CcFingerprint): string =
  ## THE producer of the `"<compiler half>|<runtime half>"` string.
  serializeCompilerHalf(fp.compiler) & "|" & serializeRuntimeHalf(fp.runtime)

proc parseCcHalf(s, unavailableSentinel: string): tuple[h: CcHalf; ok: bool] =
  if s == unavailableSentinel:
    return (unavailable(""), true)
  let idx = s.rfind(" #")
  if idx < 0: return (unavailable(""), false)
  let text = s[0 ..< idx]
  let hex = s[idx + 2 .. ^1]
  if not validText(text) or sanitizeText(text) != text or not validHex(hex):
    return (unavailable(""), false)
  (known(text, hex), true)

proc parseCcFingerprint*(s: string): tuple[fp: CcFingerprint; ok: bool] =
  ## THE parser: the inverse of `$`. `ok = false` for any string `$` cannot
  ## produce -- no `|`, a half that is neither its sentinel nor
  ## `<text> #<hex>` (a value serialized before the grammar changed, say);
  ## callers fall back rather than guess. For every `CcFingerprint` value,
  ## `parseCcFingerprint($fp) == (fp, true)`.
  let idx = s.find('|')
  if idx < 0: return (CcFingerprint(), false)
  let (c, cOk) = parseCcHalf(s[0 ..< idx], CcSentinel)
  let (r, rOk) = parseCcHalf(s[idx + 1 .. ^1], RuntimeSentinel)
  if not (cOk and rOk): return (CcFingerprint(), false)
  (CcFingerprint(compiler: c, runtime: r), true)

# ---------------------------------------------------------------------------
# Probe seams
# ---------------------------------------------------------------------------

type
  CcHashProc* = proc(path: string): CcDigest {.closure.}
    ## Content-hash the file at `path`. Never raises.

  DiscoveryKind* = enum
    dkFound     ## the compile command Nim recorded for the probe module
    dkNotFound  ## the command could not be learned; `why` says how

  Discovery* = object
    reads*: seq[string]
      ## Every file the discovery compile's answer depends on (the manifest's
      ## `configFiles` and `depfiles`, and the nim binary when it was
      ## learned), for the memo's staleness check (`cachedToolchainProbe`,
      ## `realStamp`).
    case kind*: DiscoveryKind
    of dkFound:
      ccCmd*:  string
      nimExe*: string
        ## The nim binary that ran the compile, when it was learned (Windows:
        ## its directory is where that nim looks first for the C compiler);
        ## "" otherwise.
      nimCwd*: string
        ## The compile's working directory as nim recorded it (the project
        ## root): where a relative driver path, and on Windows the second
        ## search step, resolve.
      nimEnv*: Table[string, string]
        ## Each of `NimEnvNames` as the nim that ran the compile saw it once
        ## its configuration had run (R11-S1): a `config.nims` can
        ## `putEnv`/`delEnv`, and nim spawns the C compiler with its own
        ## environment. An unset variable reads "". Every name is present
        ## in a found discovery (`parseNimEnv`).
    of dkNotFound: why*: string

  CcProbeIo* = object
    ## Every effect the derivation needs, so a test drives it with recorded
    ## output on any host. `run` and `runMerged` execute in a directory that
    ## holds the probe translation units under their fixed names
    ## (`MsvcMacroTu`, `EmptyTu`, `LinkTu`).
    discover*:   proc(): Discovery {.closure.}
    run*:        RunProc   ## separate streams: stdout is parsed
    runMerged*:  RunProc   ## merged streams: the linker's library trace
    hashFile*:   CcHashProc
    pathExists*: proc(path: string): bool {.closure.}
      ## Whether a file or directory exists at `path`, readable or not: the
      ## DLL search stops at the first copy that exists, as the loader does.
    driverStop*: proc(path: string): bool {.closure.}
      ## Whether the driver search stops at `path` (`ccprobe.locateDriver`):
      ## `CreateProcess` stops at the first file or directory of the name,
      ## `execvp` passes over one it may not execute (a directory, a file
      ## without the execute bit), R13-S4. The real one is
      ## `headerprobe.realDriverStop` under `search`.
    getEnv*:     proc(name: string): string {.closure.}
    search*:     DriverSearch
      ## The host's rule for a bare driver name (`dsWindows` on Windows).

const
  StdinModule = "stdinfile"
    ## The name Nim gives a module read from stdin (measured: its C file is
    ## `@mstdinfile.nim.c`). The `-o:` output is given the same name, so the
    ## manifest, named after the output, is `stdinfile.json`.
  NimEnvNames* = ["PATH", "CL", "_CL_"]
    ## The variables the discovery module reports as nim sees them (R11-S1):
    ## PATH, where nim finds a bare driver name (`posix_spawnp`, `sh -c` or
    ## `CreateProcess`, each over nim's own environment), and CL/_CL_, which
    ## cl reads from the environment nim spawns it with. SystemRoot is not
    ## among them: `CreateProcess` finds the system and Windows directories
    ## with `GetSystemDirectory`/`GetWindowsDirectory`, not from the
    ## variable, so a `putEnv("SystemRoot", ...)` in a `config.nims` moves
    ## nothing nim runs. PATHEXT is not read by either search.
  NimEnvLabel* = "crisol_env="
    ## The line the discovery module prints at compile time for each of
    ## `NimEnvNames`: `crisol_env=<NAME>=<hex of the value's bytes>`.
  NimExeLabel* = "crisol_nimexe="
    ## The line the Windows discovery module prints at compile time, naming
    ## the nim binary that compiles it (`getCurrentCompilerExe`). A choosenim
    ## shim execs the real nim, and it is the real one that spawns the C
    ## compiler, so the binary is asked rather than looked up.
proc nimEnvReportSource(): string =
  ## The discovery module's report of `NimEnvNames`: a `static:` block, so
  ## the values are read in the nim process, after its configuration ran.
  ## Hex keeps any byte of a value on its one line.
  var names = ""
  for n in NimEnvNames:
    if names.len > 0: names.add ", "
    names.add "\"" & n & "\""
  "from std/envvars import getEnv\n" &
  "static:\n" &
  "  for n in [" & names & "]:\n" &
  "    var h = \"\"\n" &
  "    for c in getEnv(n):\n" &
  "      h.add \"0123456789abcdef\"[ord(c) shr 4]\n" &
  "      h.add \"0123456789abcdef\"[ord(c) and 15]\n" &
  "    echo \"" & NimEnvLabel & "\", n, \"=\", h\n"

const
  DiscoverySource* =
    nimEnvReportSource() &
    (when defined(windows):
      "from std/os import getCurrentCompilerExe\n" &
      "static: echo \"" & NimExeLabel & "\", getCurrentCompilerExe()\n"
    else: "")
    ## The discovery module. It reports nim's own view of `NimEnvNames`
    ## (R11-S1). On Windows it also names the nim binary, whose directory
    ## nim searches first for a driver (`DriverSearch`), which costs the
    ## `std/os` import (0.2 s measured on Linux).
  EmptyTu* = "crisol_cc_empty.c"
    ## GNU-family macro probe: an empty unit, so `-dM -E` prints only the
    ## predefined macros.
  MsvcMacroTu* = "crisol_cc_macros.c"
    ## MSVC-family macro probe, preprocessed with `/EP`.
  LinkTu* = "crisol_runtime_probe.c"
    ## The MSVC runtime probe. `link /VERBOSE:LIB` names the libraries it
    ## searches only while linking a real program; with no inputs it fails
    ## at LNK1561 and names none (measured).
  LinkObj* = "crisol_runtime_probe.obj"
    ## The MSVC runtime probe's object (`/Fo`), in the probe's working directory.
  LinkExe* = "crisol_runtime_probe.exe"
    ## The MSVC runtime probe's program (`/Fe`), in the probe's working directory.
  LinkTuSrc = "int main(void){return 0;}\n"
  MacroLabelPrefix = "crisol_"

  MsvcMacros = [
    ("msc_full_ver", "_MSC_FULL_VER"),
    ("msc_build",    "_MSC_BUILD"),
    ("m_x64",        "_M_X64"),
    ("m_amd64",      "_M_AMD64"),
    ("m_ix86",       "_M_IX86"),
    ("m_arm64",      "_M_ARM64"),
    ("m_arm64ec",    "_M_ARM64EC"),
    ("m_arm",        "_M_ARM"),
    ("mt",           "_MT"),
    ("dll",          "_DLL"),
    ("debug",        "_DEBUG"),
    ("clang",        "__clang_version__")]
    ## Each becomes one `crisol_<label>=<MACRO>` line of `MsvcMacroTu`. An
    ## undefined macro stays its own name in the `/EP` output, which is an
    ## answer too. `_MT`/`_DLL`/`_DEBUG` record the `/MT`/`/MD`/`/MTd`
    ## runtime choice; `__clang_version__` tells `clang-cl` from `cl`.

proc msvcMacroSource*(): string =
  ## The text of `MsvcMacroTu`.
  result = ""
  for (label, macroName) in MsvcMacros:
    result.add MacroLabelPrefix & label & "=" & macroName & "\n"

# ---------------------------------------------------------------------------
# The configured driver's command
# ---------------------------------------------------------------------------

proc manifestPaths(node: JsonNode; key: string): seq[string] =
  ## The paths a manifest array names: `configFiles` holds strings,
  ## `depfiles` holds `[path, hash]` pairs.
  result = @[]
  let arr = node{key}
  if arr == nil or arr.kind != JArray: return
  for item in arr:
    let p = if item.kind == JString: item.getStr("")
            elif item.kind == JArray and item.len > 0: item[0].getStr("")
            else: ""
    if p.len > 0: result.add p

proc manifestCompileCommand*(manifestJson: string): Discovery =
  ## The compile command for the probe module in a nimcache manifest's
  ## `compile` array (`[[cPath, ccCmd], ...]`). The probe module's own entry
  ## is taken rather than the first one: a stdlib module can carry a
  ## `{.localPassC.}` of its own.
  var node: JsonNode
  try:
    node = parseJson(manifestJson)
  except CatchableError as e:
    return Discovery(kind: dkNotFound, why: "the nimcache manifest is not JSON: " & e.msg)
  let arr = node{"compile"}
  if arr == nil or arr.kind != JArray:
    return Discovery(kind: dkNotFound, why: "the nimcache manifest has no compile array")
  var reads: seq[string] = @[]
  for key in ["configFiles", "depfiles"]:
    for p in manifestPaths(node, key):
      if p notin reads: reads.add p
  let wanted = "@m" & StdinModule & ".nim.c"
  for pair in arr:
    if pair.kind != JArray or pair.len < 2: continue
    let cPath = pair[0].getStr("")
    if anySepBaseName(cPath) == wanted:
      let cmd = pair[1].getStr("")
      if cmd.len > 0:
        return Discovery(kind: dkFound, ccCmd: cmd, reads: reads,
                         nimCwd: node{"currentDir"}.getStr(""), nimExe: "")
  Discovery(kind: dkNotFound, reads: reads,
            why: "the nimcache manifest has no compile command for " & wanted)

proc parseNimExe*(output: string): string =
  ## The nim binary the Windows discovery module named (`NimExeLabel`), or
  ## "". The LAST such line: a project `config.nims` runs before the module
  ## and could print one of its own.
  result = ""
  for raw in output.splitLines:
    let line = raw.strip
    if line.startsWith(NimExeLabel): result = line[NimExeLabel.len .. ^1].strip

proc parseNimEnv*(output: string): tuple[env: Table[string, string]; ok: bool] =
  ## Each of `NimEnvNames` as the discovery module reported it
  ## (`NimEnvLabel`), or `ok = false` when a name is missing or its value is
  ## not whole hex bytes: without the report, where nim finds the compiler
  ## and what CL it passes are unknown. The LAST line per name: a project
  ## `config.nims` runs before the module and could print one of its own.
  result = (initTable[string, string](), false)
  for raw in output.splitLines:
    let line = raw.strip
    if not line.startsWith(NimEnvLabel): continue
    let rest = line[NimEnvLabel.len .. ^1]
    let eq = rest.find('=')
    if eq < 0: continue
    let name = rest[0 ..< eq]
    if name notin NimEnvNames: continue
    let hex = rest[eq + 1 .. ^1]
    if hex.len mod 2 != 0 or not hex.allCharsInSet(HexDigits):
      return (initTable[string, string](), false)
    var value = newStringOfCap(hex.len div 2)
    for i in countup(0, hex.len - 2, 2):
      value.add chr(parseHexInt(hex[i .. i + 1]))
    result.env[name] = value
  for name in NimEnvNames:
    if name notin result.env: return (initTable[string, string](), false)
  result.ok = true

# ---------------------------------------------------------------------------
# Configuration that differs between the probe module and a test (R10-S7)
# ---------------------------------------------------------------------------

const ProjectDependentIdents = ["projectName", "projectDir", "projectPath",
                                "paramStr", "paramCount", "commandLineParams",
                                "querySetting", "querySettingSeq", "nimcacheDir"]
  ## NimScript that can tell the probe module from a test: the discovery
  ## compile's project is `stdinfile` in the project root with the argument
  ## `-`, and its nimcache is the probe's scratch directory; a test's are its
  ## own file, path, argument and nimcache. A `config.nims` that branches on
  ## any of these can configure a different C compiler, target or flags for
  ## the tests than the probe saw. `querySetting` reaches the same values
  ## (`projectName`, `projectFull`, `outFile`, `commandLine`, `nimcacheDir`).

proc nimIdentKey(ident: string): string =
  ## Nim's identifier equality: the first character exactly, the rest
  ## without case and underscores.
  if ident.len == 0: return ""
  result = $ident[0]
  for c in ident[1 .. ^1]:
    if c != '_': result.add c.toLowerAscii

proc projectDependentIdent*(src: string): string =
  ## The first identifier of `src` (NimScript) that names one of
  ## `ProjectDependentIdents`, compared as Nim compares identifiers, or "".
  ## Comments, string literals and character literals are skipped. Any
  ## spelling Nim would resolve to one of them counts, whatever calls it,
  ## including one split inside backticks: Nim joins the tokens of
  ## `` `project Dir` `` into `projectDir`, and so does this scan.
  ##
  ## A HEURISTIC, NOT A TRUST BOUNDARY (R11-S6). It reads the text, so it
  ## cannot see a name the NimScript builds rather than writes: a template
  ## or macro that assembles the identifier (`` `project name` `` with
  ## `name` a parameter, `ident("project" & "Dir")`), a call through a
  ## proc variable, or a value reached some other way (`getCommand`, an
  ## environment variable the caller sets per compile, a file the script
  ## reads). It catches the configuration that branches on the project in
  ## the ordinary way; it does not make a hostile configuration safe. A
  ## project whose `config.nims` is written to evade it is outside what the
  ## cache key protects against, as is one that edits the compiler.
  var wanted: seq[string] = @[]
  for w in ProjectDependentIdents: wanted.add nimIdentKey(w)
  var i = 0
  while i < src.len:
    let c = src[i]
    if c == '#':
      if i + 1 < src.len and src[i + 1] == '[':
        # A block comment; they nest.
        var depth = 1
        i += 2
        while i < src.len and depth > 0:
          if src[i] == '#' and i + 1 < src.len and src[i + 1] == '[':
            inc depth; i += 2
          elif src[i] == ']' and i + 1 < src.len and src[i + 1] == '#':
            dec depth; i += 2
          else: inc i
      else:
        while i < src.len and src[i] != '\n': inc i
    elif c == '"':
      if i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"':
        let close = src.find("\"\"\"", i + 3)
        i = if close < 0: src.len else: close + 3
      else:
        # A raw literal (`r"..."`, or a generalized one) has no escapes;
        # its prefix identifier was consumed just before this quote.
        let raw = i > 0 and src[i - 1] in IdentChars
        inc i
        while i < src.len and src[i] != '"' and src[i] != '\n':
          if src[i] == '\\' and not raw: inc i
          inc i
        inc i
    elif c == '\'':
      # A character literal (`'a'`, `'\n'`), or a numeric suffix (`1'u8`).
      if i + 2 < src.len and src[i + 1] == '\\':
        let close = src.find('\'', i + 2)
        i = if close < 0: src.len else: close + 1
      elif i + 2 < src.len and src[i + 2] == '\'':
        i += 3
      else: inc i
    elif c == '`':
      # An accent-quoted name: Nim joins the tokens inside into one
      # identifier (`` `project Dir` `` is `projectDir`). An operator
      # (`` `+` ``) joins to no identifier and matches nothing.
      # A backtick with no partner on its line is not a quoted name: step
      # over it alone, so the text after it is still scanned.
      let close = src.find('`', i + 1)
      let span = if close < 0: "" else: src[i + 1 ..< close]
      if close < 0 or '\n' in span:
        inc i
      else:
        var joined = ""
        for ch in span:
          if ch in IdentChars: joined.add ch
          elif ch notin {' ', '\t'}:
            joined = ""
            break
        if joined.len > 0 and joined[0] in IdentStartChars and
           nimIdentKey(joined) in wanted:
          return "`" & span & "`"
        i = close + 1
    elif c in IdentStartChars:
      let start = i
      while i < src.len and src[i] in IdentChars: inc i
      let ident = src[start ..< i]
      if nimIdentKey(ident) in wanted: return ident
    else: inc i
  ""

proc isUnderDir(path, dir: string): bool =
  ## Whether `path` lies inside `dir` (either separator).
  let p = path.replace('\\', '/')
  let d = dir.replace('\\', '/').strip(leading = false, chars = {'/'})
  d.len > 0 and p.len > d.len and p.startsWith(d) and p[d.len] == '/'

proc scanSources*(manifestJson: string): seq[string] =
  ## The files whose NimScript can configure the probe module differently
  ## from a test: every `.nims` config file Nim read, and every source the
  ## compile read from outside Nim's own library (what a `config.nims`
  ## imports or includes -- Nim records those in `depfiles`). Nim's library
  ## is the directory holding `system.nim`; `.cfg` files are not NimScript.
  result = @[]
  var node: JsonNode
  try: node = parseJson(manifestJson)
  except CatchableError: return
  var libDir = ""
  let deps = manifestPaths(node, "depfiles")
  for p in deps:
    let norm = p.replace('\\', '/')
    if norm.endsWith("/lib/system.nim"):
      libDir = norm[0 ..< norm.len - "/system.nim".len]
      break
  for p in manifestPaths(node, "configFiles"):
    if p.toLowerAscii.endsWith(".nims") and p notin result: result.add p
  for p in deps:
    let lower = p.toLowerAscii
    if lower.endsWith(".cfg"): continue
    if libDir.len > 0 and isUnderDir(p, libDir): continue
    if p notin result: result.add p

# ---------------------------------------------------------------------------
# Where the build finds the driver (R10-S6)
# ---------------------------------------------------------------------------

# `DriverLocation`, `DriverSite`, `DriverSearch` and the search itself are
# defined in `crisol/ccprobe`, so the header probe and the measure worker can
# resolve a driver without importing this module; re-exported for every
# holder of a `ToolchainProbe`.
export ccprobe.DriverLocation, ccprobe.DriverSite, ccprobe.DriverSearch

proc siteOf(d: Discovery; io: CcProbeIo): DriverSite =
  ## Where the nim that ran the discovery compile looks for its compilers:
  ## its binary, cwd and PATH as it reported them (R11-S1: a `config.nims`
  ## can `putEnv("PATH", ...)` for nim alone), and the host rule and
  ## SystemRoot as `io` answers them (see `NimEnvNames` for why SystemRoot
  ## is this process's).
  DriverSite(known: true, nimExe: d.nimExe, nimCwd: d.nimCwd, search: io.search,
             pathVar: d.nimEnv.getOrDefault("PATH", ""),
             systemRoot: io.getEnv("SystemRoot"))

# ---------------------------------------------------------------------------
# The compiler half
# ---------------------------------------------------------------------------

type
  MacroAnswer = object
    lines:  seq[string]              ## the answer's identity lines, sorted
    values: Table[string, string]    ## macro/label name -> value

proc parseMsvcAnswer(output: string): tuple[a: MacroAnswer; ok: bool] =
  ## The `crisol_<label>=<value>` lines of an `/EP` answer. Every label must
  ## be present exactly once. cl echoes the source name on stderr, which the
  ## separate-stream runner keeps out of `output`; any other line is ignored.
  var a = MacroAnswer(values: initTable[string, string]())
  for raw in output.splitLines:
    let line = raw.strip
    if not line.startsWith(MacroLabelPrefix): continue
    let eq = line.find('=')
    if eq < 0: continue
    let label = line[MacroLabelPrefix.len ..< eq].strip
    let value = line[eq + 1 .. ^1].strip
    if label in a.values: return (a, false)
    a.values[label] = value
    a.lines.add label & "=" & value
  for (label, _) in MsvcMacros:
    if label notin a.values: return (a, false)
  a.lines.sort
  (a, true)

proc msvcDefined(a: MacroAnswer; label, macroName: string): bool =
  ## An undefined macro expands to its own name under `/EP`.
  a.values.getOrDefault(label, macroName) != macroName

proc msvcSummary(a: MacroAnswer): tuple[text: string; ok: bool] =
  ## `msvc 19.44.35228.0 x64` from `_MSC_FULL_VER` (VVMMBBBBB), `_MSC_BUILD`
  ## and the architecture macros; `clang-cl <v> ...` when clang-cl answered.
  let full = a.values["msc_full_ver"]
  if full.len < 7 or not full.allCharsInSet(Digits): return ("", false)
  let build = a.values["msc_build"]
  let ver = full[0 .. 1] & "." & full[2 .. 3] & "." & full[4 .. ^1] &
            (if build.allCharsInSet(Digits) and build.len > 0: "." & build else: "")
  let arch =
    if a.msvcDefined("m_arm64ec", "_M_ARM64EC"): "arm64ec"
    elif a.msvcDefined("m_arm64", "_M_ARM64"): "arm64"
    elif a.msvcDefined("m_x64", "_M_X64"): "x64"
    elif a.msvcDefined("m_ix86", "_M_IX86"): "x86"
    elif a.msvcDefined("m_arm", "_M_ARM"): "arm"
    else: "unknown-arch"
  var text = "msvc " & ver & " " & arch
  if a.msvcDefined("clang", "__clang_version__"):
    let cv = a.values["clang"].strip(chars = {'"', ' '}).split(' ')[0]
    text = "clang-cl " & cv & " " & text
  (text, true)

proc parseGnuAnswer(output: string): tuple[a: MacroAnswer; ok: bool] =
  ## The `#define NAME VALUE` lines of a `-dM -E` answer.
  var a = MacroAnswer(values: initTable[string, string]())
  for raw in output.splitLines:
    let line = raw.strip(leading = false)
    if not line.startsWith("#define "): continue
    let rest = line["#define ".len .. ^1]
    let sp = rest.find(' ')
    let name = if sp < 0: rest else: rest[0 ..< sp]
    let value = if sp < 0: "" else: rest[sp + 1 .. ^1]
    a.values[name] = value
    a.lines.add line
  a.lines.sort
  (a, a.lines.len > 0)

const
  GnuArchMacros = [
    ("__x86_64__", "x86_64"), ("__aarch64__", "aarch64"), ("__i386__", "i386"),
    ("__arm__", "arm"), ("__riscv", "riscv"), ("__powerpc64__", "ppc64"),
    ("__powerpc__", "ppc"), ("__s390x__", "s390x"),
    ("__loongarch64", "loongarch64"), ("__mips__", "mips")]
  GnuOsMacros = [
    ("__ANDROID__", "android"), ("__linux__", "linux"), ("__APPLE__", "darwin"),
    ("__MINGW32__", "mingw"), ("__CYGWIN__", "cygwin"), ("_WIN32", "windows"),
    ("__FreeBSD__", "freebsd"), ("__NetBSD__", "netbsd"),
    ("__OpenBSD__", "openbsd"), ("__DragonFly__", "dragonfly"),
    ("__sun", "solaris"), ("__HAIKU__", "haiku")]

proc gnuSummary(a: MacroAnswer): string =
  ## `gcc 16.2.0 x86_64-linux`, `clang 22.1.8 aarch64-darwin`, ... -- legible
  ## text for a miss explanation; the digest carries the identity.
  template v(name: string): string = a.values.getOrDefault(name, "?")
  let (family, ver) =
    if "__clang__" in a.values:
      ("clang", v("__clang_major__") & "." & v("__clang_minor__") & "." &
                v("__clang_patchlevel__"))
    elif "__GNUC__" in a.values:
      ("gcc", v("__GNUC__") & "." & v("__GNUC_MINOR__") & "." &
              v("__GNUC_PATCHLEVEL__"))
    else: ("cc", "unknown-version")
  var arch = "unknown-arch"
  for (m, name) in GnuArchMacros:
    if m in a.values: arch = name; break
  var os = "unknown-os"
  for (m, name) in GnuOsMacros:
    if m in a.values: os = name; break
  family & " " & ver & " " & arch & "-" & os

proc namesResponseFile*(value: string): bool =
  ## Whether a `CL`/`_CL_` value holds a response-file argument: a token whose
  ## first character, once cl's quotes are removed, is `@`. Tokens split on
  ## unquoted spaces and tabs, as cl splits the variable. An `@` inside a
  ## token (`/DMAIL#a@b`) is an ordinary character.
  var i = 0
  while i < value.len:
    while i < value.len and value[i] in {' ', '\t'}: inc i
    var inQuote = false
    var first = true
    while i < value.len and (inQuote or value[i] notin {' ', '\t'}):
      if value[i] == '"':
        inQuote = not inQuote
      elif first:
        if value[i] == '@': return true
        first = false
      inc i
  false

proc clMismatch(nimEnv: Table[string, string]; io: CcProbeIo): string =
  ## Why the probes cannot replay an MSVC-family compile, or "": nim spawns
  ## cl with a `CL`/`_CL_` (`nimEnv`, what the discovery reported) that
  ## differs from the one the probes inherit from this process (`io`), so
  ## the macro answer and the runtime link would not see the flags the build
  ## compiles with (a `/MD` there picks a different runtime). A
  ## `config.nims` `putEnv`/`delEnv` does this (R11-S1).
  for name in ["CL", "_CL_"]:
    let nimValue = nimEnv.getOrDefault(name, "")
    let here = io.getEnv(name)
    if nimValue != here:
      return "the nim configuration sets " & name & " for the compiler to `" &
             nimValue & "`, but the identity probes run with `" & here &
             "`, so they cannot see the flags the build compiles with"
  ""

proc compilerIdentity(cmd: CompileCommand; io: CcProbeIo):
    tuple[half: CcHalf; answer: MacroAnswer] =
  ## The compiler half, and the macro answer the runtime half is chosen by.
  ## For the MSVC family, `CL`/`_CL_` are folded as the probes read them,
  ## which `clMismatch` has checked is what nim passes the build's cl.
  let probeArgs = case cmd.family
                  of ccfMsvc: cmd.flags & @["/EP", MsvcMacroTu]
                  of ccfGnu: cmd.flags & @["-dM", "-E", EmptyTu]
  let r = io.run(cmd.driver, probeArgs)
  if not r.ok:
    return (unavailable("the configured C compiler `" & cmd.driver &
                        "` did not answer the identity probe (" &
                        describe(r) & ")"), MacroAnswer())
  let (answer, parsed) = case cmd.family
                         of ccfMsvc: parseMsvcAnswer(r.output)
                         of ccfGnu: parseGnuAnswer(r.output)
  if not parsed:
    return (unavailable("the configured C compiler `" & cmd.driver &
                        "` answered the identity probe with no macro values"),
            MacroAnswer())
  var text: string
  case cmd.family
  of ccfMsvc:
    let (t, ok) = msvcSummary(answer)
    if not ok:
      return (unavailable("the configured C compiler `" & cmd.driver &
                          "` reported no usable _MSC_FULL_VER"), answer)
    text = t
  of ccfGnu:
    text = gnuSummary(answer)
  let bin = io.hashFile(cmd.driver)
  if bin.kind != cdkKnown:
    return (unavailable("the binary of the configured C compiler `" &
                        cmd.driver & "` could not be read"), answer)
  var material = $cmd.family & "\x00" & answer.lines.join("\n") & "\x00" & bin.hex
  if cmd.family == ccfMsvc:
    # cl prepends CL and appends _CL_ to every command line it runs.
    for name in ["CL", "_CL_"]:
      let value = io.getEnv(name)
      if namesResponseFile(value):
        return (unavailable("the " & name & " environment variable names a " &
                            "response file, whose contents the identity " &
                            "cannot see (" & name & "=" & value & ")"), answer)
      material.add "\x00" & name & "=" & value
  (known(text, toHex16(fnv1a64(material))), answer)

# ---------------------------------------------------------------------------
# The runtime half
# ---------------------------------------------------------------------------

type
  RuntimeProbeKind = enum
    rpkMsvcLink     ## link a trivial program, hash what `/VERBOSE:LIB` names
    rpkArtifacts    ## resolve named libraries with `-print-file-name=`
    rpkDarwin       ## the SDK's libSystem stub and the OS build

  RuntimeProbe = object
    x86: bool                 ## the target is 32-bit x86 (WOW64 on a 64-bit host)
    case kind: RuntimeProbeKind
    of rpkMsvcLink: discard
    of rpkArtifacts:
      artifacts: seq[tuple[lib, dll: string]]
        ## tried in order; every `lib` that resolves counts, and so does its
        ## `dll` ("" for none), resolved as the Windows loader resolves it
      lddLabel:  bool         ## label the half with `ldd --version`
    of rpkDarwin:
      sysroot: string         ## from the replayed flags; "" asks `xcrun`

const
  MsvcImportDlls = [
    ("msvcrt.lib",    "vcruntime140.dll"),  ("msvcrt.lib",    "ucrtbase.dll"),
    ("vcruntime.lib", "vcruntime140.dll"),  ("ucrt.lib",      "ucrtbase.dll"),
    ("msvcprt.lib",   "msvcp140.dll"),
    ("msvcrtd.lib",   "vcruntime140d.dll"), ("msvcrtd.lib",   "ucrtbased.dll"),
    ("vcruntimed.lib", "vcruntime140d.dll"), ("ucrtd.lib",    "ucrtbased.dll"),
    ("msvcprtd.lib",  "msvcp140d.dll")]
    ## Each `/MD` import library (lower-cased basename) and a runtime DLL a
    ## program linked against it loads. `msvcrt.lib` is the `/MD` startup
    ## library, which binds both. The static-runtime libraries (`libcmt`,
    ## `libvcruntime`, `libucrt`, `libcpmt`) are code, not imports, and bind
    ## no DLL. A C++ program that uses FH4 exceptions on x64 also imports
    ## `vcruntime140_1.dll`; the discovery compile is `nim c`, so the C
    ## runtime is what is identified (a `nim cpp` group is issue #24).

proc sysrootFlag(flags: seq[string]): string =
  ## The value of an `-isysroot`/`--sysroot` flag, or "".
  var i = 0
  while i < flags.len:
    let f = flags[i]
    if f in ["-isysroot", "--sysroot"] and i + 1 < flags.len: return flags[i + 1]
    if f.startsWith("--sysroot="): return f["--sysroot=".len .. ^1]
    if f.startsWith("-isysroot") and f.len > "-isysroot".len:
      return f["-isysroot".len .. ^1]
    inc i
  ""

proc runtimeProbeFor(cmd: CompileCommand; answer: MacroAnswer): RuntimeProbe =
  ## Chosen by the target the compiler reported, not the host OS.
  case cmd.family
  of ccfMsvc:
    RuntimeProbe(kind: rpkMsvcLink, x86: answer.msvcDefined("m_ix86", "_M_IX86"))
  of ccfGnu:
    let x86 = "__i386__" in answer.values
    if "__APPLE__" in answer.values:
      RuntimeProbe(kind: rpkDarwin, x86: x86, sysroot: sysrootFlag(cmd.flags))
    elif "__MINGW32__" in answer.values:
      RuntimeProbe(kind: rpkArtifacts, x86: x86,
                   artifacts: @[(lib: "libucrt.a", dll: "ucrtbase.dll"),
                                (lib: "libmsvcrt.a", dll: "msvcrt.dll")],
                   lddLabel: false)
    else:
      RuntimeProbe(kind: rpkArtifacts, x86: x86,
                   artifacts: @[(lib: "libc.so.6", dll: "")], lddLabel: true)

proc firstLine(s: string): string =
  for line in s.splitLines:
    let t = line.strip
    if t.len > 0: return t
  ""

proc versionLine(s: string): string =
  ## The first line carrying a `<digit>.<digit>` token, else the first line.
  var fallback = ""
  for line in s.splitLines:
    let t = line.strip
    if t.len == 0: continue
    if fallback.len == 0: fallback = t
    for i in 1 ..< t.len - 1:
      if t[i] == '.' and t[i - 1] in Digits and t[i + 1] in Digits: return t
  fallback

proc foldLibraries(entries: var seq[tuple[name, hex: string]]): string =
  ## One digest over (name, content) pairs, in a total order that ignores the
  ## order they were found in and their paths.
  entries.sort(proc (a, b: tuple[name, hex: string]): int =
    result = cmp(a.name, b.name)
    if result == 0: result = cmp(a.hex, b.hex))
  var running = ""
  for e in entries:
    running = toHex16(fnv1a64(running & "\x00" & e.name & "\x00" & e.hex))
  running

proc loaderDll(dll: string; x86: bool; io: CcProbeIo): tuple[hex, why: string] =
  ## The content of the copy of `dll` the Windows loader maps for a program
  ## of the target architecture: the system directory, then the Windows
  ## directory (see the module doc, "The runtime half"). `why` is non-empty
  ## when no copy is found in either, or the one found cannot be read.
  let root = io.getEnv("SystemRoot").strip(leading = false, chars = {'\\', '/'})
  if root.len == 0:
    return ("", "`" & dll & "` cannot be located: SystemRoot is not set, " &
                "so the Windows system directory is unknown")
  let sysDir =
    if x86 and io.pathExists(root & "\\SysWOW64"): root & "\\SysWOW64"
    elif not x86 and io.pathExists(root & "\\Sysnative"): root & "\\Sysnative"
    else: root & "\\System32"
  for dir in [sysDir, root]:
    let path = dir & "\\" & dll
    if io.pathExists(path):
      let d = io.hashFile(path)
      if d.kind != cdkKnown:
        return ("", "the runtime DLL `" & path & "` could not be read")
      return (d.hex, "")
  ("", "the runtime DLL `" & dll & "` is in neither " & sysDir & " nor " & root)

proc libPathIn(line: string): string =
  ## The library path in one `/VERBOSE:LIB` line, anchored on path syntax (a
  ## drive letter, or a UNC/extended-length `\\` or `//` prefix) rather than
  ## on the verb before it, which is translated in a localized toolset.
  for i in 0 ..< max(line.len - 1, 0):
    if line[i] == ':' and i > 0 and line[i + 1] in {'\\', '/'} and
       line[i - 1] in Letters:
      return line[i - 1 .. ^1]
    if line[i] in {'\\', '/'} and line[i + 1] == line[i] and
       (i == 0 or line[i - 1] notin {'\\', '/'}):
      return line[i .. ^1]
  ""

proc parseVerboseLibPaths*(output: string): seq[string] =
  ## Every distinct library path a `/VERBOSE:LIB` trace names, first-seen
  ## order. The linker repeats its search list once per resolution pass, so
  ## the dedup is what keeps the probe's own program out of the identity.
  result = @[]
  for line in output.splitLines:
    var t = line.strip
    if t.endsWith(":"): t.setLen(t.len - 1)
    if not t.toLowerAscii.endsWith(".lib"): continue
    let path = libPathIn(t)
    if path.len > 0 and path notin result: result.add path

proc msvcRuntime(cmd: CompileCommand; p: RuntimeProbe; io: CcProbeIo): CcHalf =
  ## Every library the linker searches, by lower-cased basename and content,
  ## and every runtime DLL an import library among them binds
  ## (`MsvcImportDlls`). A trace from a run that did not finish could name
  ## fewer libraries than the linker searches, so only `reExited` is read;
  ## its exit code is not consulted (a link that fails late has still named
  ## what it searched).
  ##
  ## The replayed flags carry neither the compile action nor the object
  ## output (`parseCompileCommand` drops both), so the probe names its own
  ## object and program, in its working directory (the scratch directory),
  ## and compiles and links in one step: a `/c` would stop before the link
  ## and the linker would name nothing.
  let r = io.runMerged(cmd.driver, cmd.flags & @["/Fo" & LinkObj, "/Fe" & LinkExe,
                                                 LinkTu, "/link", "/VERBOSE:LIB"])
  if r.ending != reExited:
    return unavailable("the runtime probe through `" & cmd.driver &
                       "` did not finish (" & describe(r) & ")")
  var entries: seq[tuple[name, hex: string]] = @[]
  var dlls: seq[string] = @[]
  for path in parseVerboseLibPaths(r.output):
    let d = io.hashFile(path)
    if d.kind != cdkKnown:
      # Dropping it would narrow the identity to what could be read.
      return unavailable("the runtime library `" & path & "` could not be read")
    let name = anySepBaseName(path).toLowerAscii
    entries.add (name: name, hex: d.hex)
    for (lib, dll) in MsvcImportDlls:
      if lib == name and dll notin dlls: dlls.add dll
  if entries.len == 0:
    return unavailable("the linker named no runtime library")
  var names: seq[string] = @[]
  for e in entries:
    let n = if e.name.endsWith(".lib"): e.name[0 ..< e.name.len - 4] else: e.name
    if n notin names: names.add n
  for dll in dlls:
    let (hex, why) = loaderDll(dll, p.x86, io)
    if why.len > 0: return unavailable(why)
    entries.add (name: dll, hex: hex)
    names.add dll
  names.sort
  let hex = foldLibraries(entries)
  known(names.join("+"), hex)

proc artifactRuntime(cmd: CompileCommand; p: RuntimeProbe; io: CcProbeIo): CcHalf =
  ## Libraries resolved by the driver itself, and the DLL each resolved
  ## import library binds. gcc prints the bare name back, rc 0, when it cannot
  ## resolve one (measured), so an unresolved name is an answer of "not
  ## found", never a path. A failed lookup, a resolved library that cannot be
  ## read, or a bound DLL that cannot be found or read refuses the half:
  ## dropping it would narrow the identity to what could be seen.
  var entries: seq[tuple[name, hex: string]] = @[]
  for (artifact, dll) in p.artifacts:
    let r = io.run(cmd.driver, cmd.flags & @["-print-file-name=" & artifact])
    if not r.ok:
      return unavailable("`" & cmd.driver & " -print-file-name=" & artifact &
                         "` failed (" & describe(r) & ")")
    let path = firstLine(r.output)
    if path.len == 0 or path == artifact: continue
    let d = io.hashFile(path)
    if d.kind != cdkKnown:
      return unavailable("the runtime library `" & path & "` (" & artifact &
                         ") could not be read")
    entries.add (name: artifact, hex: d.hex)
    if dll.len > 0:
      let (hex, why) = loaderDll(dll, p.x86, io)
      if why.len > 0: return unavailable(why)
      entries.add (name: dll, hex: hex)
  if entries.len == 0:
    var libs: seq[string] = @[]
    for a in p.artifacts: libs.add a.lib
    return unavailable("`" & cmd.driver & "` resolved none of " &
                       libs.join(", ") & " to a readable file")
  var label = ""
  if p.lddLabel:
    let ldd = io.run("ldd", ["--version"])
    if ldd.ok: label = versionLine(ldd.output)
  if label.len == 0:
    var names: seq[string] = @[]
    for e in entries: names.add e.name
    names.sort
    label = names.join("+")
  known(label, foldLibraries(entries))

proc swVersField(output, field: string): string =
  ## The value of one `Field:<whitespace>value` line of `sw_vers`, or "".
  for line in output.splitLines:
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip == field:
      return line[colon + 1 .. ^1].strip
  ""

proc darwinRuntime(p: RuntimeProbe; io: CcProbeIo): CcHalf =
  ## The SDK's `usr/lib/libSystem.tbd` -- the text stub the linker resolves
  ## `-lSystem` against -- and the `sw_vers` answer, which identifies the
  ## `libSystem` in the dyld shared cache that the tests load. The whole
  ## answer is hashed, so a `ProductVersionExtra` (a rapid security response)
  ## moves the key too. UNMEASURED locally (no macOS host); the macOS CI leg
  ## is the proof.
  let os = io.run("sw_vers", [])
  if not os.ok:
    return unavailable("`sw_vers` did not answer (" & describe(os) & "), " &
                       "so the macOS build the tests load libSystem from is unknown")
  let product = swVersField(os.output, "ProductVersion")
  let build = swVersField(os.output, "BuildVersion")
  if product.len == 0 or build.len == 0:
    return unavailable("`sw_vers` named no ProductVersion or BuildVersion")
  var sdk = p.sysroot
  var sdkLabel = "libSystem"
  if sdk.len == 0:
    let r = io.run("xcrun", ["--show-sdk-path"])
    if not r.ok:
      return unavailable("`xcrun --show-sdk-path` did not answer (" & describe(r) & ")")
    sdk = firstLine(r.output)
    let v = io.run("xcrun", ["--show-sdk-version"])
    if v.ok and firstLine(v.output).len > 0:
      sdkLabel = "SDK " & firstLine(v.output) & " libSystem"
  if sdk.len == 0:
    return unavailable("no macOS SDK path was found")
  let path = sdk.strip(leading = false, chars = {'/'}) & "/usr/lib/libSystem.tbd"
  let d = io.hashFile(path)
  if d.kind != cdkKnown:
    return unavailable("the SDK runtime stub `" & path & "` could not be read")
  var entries = @[(name: "libSystem.tbd", hex: d.hex),
                  (name: "sw_vers", hex: toHex16(fnv1a64(os.output)))]
  known("macOS " & product & " " & build & ", " & sdkLabel, foldLibraries(entries))

proc runtimeIdentity(cmd: CompileCommand; compilerKnown: bool;
                     answer: MacroAnswer; io: CcProbeIo): CcHalf =
  if cmd.family == ccfGnu and not compilerKnown:
    return unavailable("the target is unknown, so its C runtime cannot be chosen")
  let p = runtimeProbeFor(cmd, answer)
  case p.kind
  of rpkMsvcLink: msvcRuntime(cmd, p, io)
  of rpkArtifacts: artifactRuntime(cmd, p, io)
  of rpkDarwin: darwinRuntime(p, io)

# ---------------------------------------------------------------------------
# The derivation
# ---------------------------------------------------------------------------

type
  ToolchainProbe* = object
    ## One discovery's answer, as one value (R11-D1): the fingerprint a run
    ## keys by, and where the build's nim finds any driver, which every
    ## header probe of the same run resolves its command's own driver
    ## against (`headerprobe.siteResolver`, R10-S6). A run carries this
    ## value from its plan to its execution, so a key is never paired with
    ## another discovery's site.
    fp*:   CcFingerprint
    site*: DriverSite
      ## Known whenever the discovery compile answered, whatever became of
      ## the C compiler: a `{.compile.}`d `.cpp` runs the C++ driver, which
      ## resolves on its own. `known` false, with the reason, when the
      ## discovery failed.

proc ccProbeWith*(io: CcProbeIo): ToolchainProbe =
  ## THE derivation, over injected effects. The C compiler is found where
  ## the build's nim finds it (`ccprobe.locateDriver` over `site`), and
  ## every probe runs, and the identity hashes, that file. Never raises.
  proc refused(reason: string; site: DriverSite): ToolchainProbe =
    ToolchainProbe(fp: CcFingerprint(compiler: unavailable(reason),
                                     runtime: unavailable(reason)),
                   site: site)
  let d = io.discover()
  case d.kind
  of dkNotFound:
    let reason = "the C compiler Nim is configured to use could not be " &
                 "determined: " & d.why
    return refused(reason, DriverSite(known: false, why: reason))
  of dkFound: discard
  for name in NimEnvNames:
    if name notin d.nimEnv:
      let reason = "the discovery compile did not report nim's " & name &
                   ", so where nim finds the C compiler, and what it passes " &
                   "it, is unknown"
      return refused(reason, DriverSite(known: false, why: reason))
  let site = siteOf(d, io)
  let parsed = parseCompileCommand(d.ccCmd)
  if parsed.isNone:
    return refused("Nim's compile command could not be replayed: " & d.ccCmd, site)
  var cmd = parsed.get
  let loc = ccprobe.locateDriver(cmd.driver, site, io.driverStop)
  if not loc.found:
    return refused("the C compiler Nim will run could not be located: " & loc.why, site)
  if cmd.family == ccfMsvc:
    let why = clMismatch(d.nimEnv, io)
    if why.len > 0: return refused(why, site)
  # Every probe runs, and the identity hashes, the file the build runs.
  cmd.driver = loc.path
  let (compiler, answer) = compilerIdentity(cmd, io)
  ToolchainProbe(fp: CcFingerprint(compiler: compiler,
                                   runtime: runtimeIdentity(cmd, compiler.st == cfsKnown,
                                                            answer, io)),
                 site: site)

# ---------------------------------------------------------------------------
# The real effects
# ---------------------------------------------------------------------------

proc realFileHash*(path: string): CcDigest =
  ## FNV-1a over the file's bytes; `cdkUnreadable` for an empty path, a
  ## missing or unreadable file, or an empty file. Never raises.
  if path.len == 0: return CcDigest(kind: cdkUnreadable)
  try:
    let content = readFile(path)
    if content.len == 0: return CcDigest(kind: cdkUnreadable)
    CcDigest(kind: cdkKnown, hex: toHex16(fnv1a64(content)))
  except CatchableError:
    CcDigest(kind: cdkUnreadable)

type
  CcProbeContext* = object
    ## What the discovery compile needs from the configuration: the project
    ## root (the compile's cwd, which makes it the stdin module's project
    ## directory), the state directory (the scratch directory's parent) and
    ## the global crisol.kdl flags.
    projectRoot*: string
    stateDir*:    string
    flags*:       seq[string]

proc projectDependence(scanned: seq[string]): tuple[why: string; reads: seq[string]] =
  ## The first scanned file whose NimScript can tell the probe module from a
  ## test (`projectDependentIdent`), as a refusal reason, or "". A file that
  ## cannot be read refuses too: what it says is unknown.
  result = ("", @[])
  for path in scanned:
    result.reads.add path
    if not path.toLowerAscii.endsWith(".nims") and
       not path.toLowerAscii.endsWith(".nim"):
      continue
    var src: string
    try: src = readFile(path)
    except CatchableError as e:
      result.why = "`" & path & "`, which configures the compile, could not " &
                   "be read: " & e.msg
      return
    let ident = projectDependentIdent(src)
    if ident.len > 0:
      result.why = "`" & path & "` uses `" & ident & "`, so it can configure " &
                   "a different C compiler for each test than for the probe"
      return

proc realDiscover(ctx: CcProbeContext; scratch: string; run: RunProc): Discovery =
  ## The probe module is compiled from STDIN, with cwd = the project root:
  ## Nim then takes the cwd as the project directory and reads the
  ## `nim.cfg`/`config.nims` of the project root and its parents, which is
  ## what a compile of a test under the project reads (measured: a module
  ## outside the project, such as one under a relocated `CRISOL_STATE_DIR`,
  ## does not see the project's `cc = clang`; the stdin module does).
  ##
  ## What it cannot see is configuration that tells the probe module from a
  ## test: a `config.nims` (or what it imports) branching on the project's
  ## name, path or arguments (`projectDependentIdent`). Such a compile is
  ## refused rather than trusted (R10-S7). Checking each test's own compile
  ## command after the fact would not do: a cache hit compiles nothing.
  ## `run` is `toolrun.realRunWithStdinIn(ctx.projectRoot, DiscoverySource)`,
  ## as the caller watches it.
  let nimcache = scratch / "nimcache"
  let args = nimCompileArgs("-", ctx.flags, nimcache, nimcache / StdinModule,
                            compileOnly = true)
  let r = run("nim", args)
  if not r.ok:
    var detail = describe(r)
    if r.ending == reExited:
      let tail = firstLine(r.output & "\n" & r.errOutput)
      if tail.len > 0: detail.add ": " & tail
    return Discovery(kind: dkNotFound,
                     why: "`nim c --compileOnly` of a probe module failed (" &
                          detail & ")")
  var manifest: string
  try:
    manifest = readFile(nimcache / (StdinModule & ".json"))
  except CatchableError as e:
    return Discovery(kind: dkNotFound, why: "the nimcache manifest could not be read: " & e.msg)
  result = manifestCompileCommand(manifest)
  let dep = projectDependence(scanSources(manifest))
  for p in dep.reads:
    if p notin result.reads: result.reads.add p
  if dep.why.len > 0:
    return Discovery(kind: dkNotFound, why: dep.why, reads: result.reads)
  if result.kind == dkFound:
    let (nimEnv, envOk) = parseNimEnv(r.output)
    if not envOk:
      return Discovery(kind: dkNotFound, reads: result.reads,
                       why: "the discovery module did not report nim's " &
                            "environment (" & NimEnvNames.join(", ") & ")")
    result.nimEnv = nimEnv
    result.nimExe = parseNimExe(r.output)
    if result.nimExe.len > 0: result.reads.add result.nimExe

type
  ProbeRun* = object
    ## A real probe's answer and every file it depends on.
    toolchain*: ToolchainProbe
    reads*:     seq[string]
      ## Each file the probe read, hashed, or looked for (a driver search
      ## step, a DLL location), and each file the discovery compile read.
    interrupted*: bool
      ## Some tool run the probe made ended `reInterrupted`: the answer (an
      ## unidentified half, typically) was decided by an interrupt, not the
      ## toolchain, and must not be kept (R13-L3, R14-D3).
    scratchFailed*: bool
      ## The probe could not set up its scratch directory under
      ## `CcProbeContext.stateDir`: the answer (both halves unidentified) is
      ## about that directory, not the toolchain, and must not be kept for
      ## a context that differs from it only in the state directory (R12-D5).

const
  ProbeDirPrefix = "ccprobe_"
  StaleProbeDirAge* = initDuration(hours = 1)
    ## How old (last modified) a `ccprobe_*` directory must be before a later
    ## probe removes it. A live probe is far younger: it runs a handful of
    ## tools, each bounded by `toolrun.ToolProbeTimeoutMs` plus the
    ## termination grace, and writes into its directory as it goes.

proc reclaimStaleProbeDirs*(stateDir: string) =
  ## Remove the `ccprobe_*` directories under `stateDir` last modified more
  ## than `StaleProbeDirAge` ago. A probe removes its own directory when it
  ## returns, an interrupt included (it unwinds normally), but a process
  ## ended without unwinding -- SIGKILL, a crash, power loss -- leaves it;
  ## the next probe reclaims it here. A younger directory may be a concurrent run's live probe (the plan runs
  ## outside the state-dir lock), so it is kept. Never raises.
  let cutoff = getTime() - StaleProbeDirAge
  try:
    for kind, path in walkDir(stateDir):
      if kind != pcDir or not path.extractFilename.startsWith(ProbeDirPrefix):
        continue
      try:
        if getLastModificationTime(path) < cutoff: removeDir(path)
      except CatchableError: discard
  except CatchableError: discard

proc refusedRun(reason: string): ProbeRun =
  ## The scratch directory could not be set up (`ProbeRun.scratchFailed`).
  ProbeRun(toolchain: ToolchainProbe(
    fp: CcFingerprint(compiler: unavailable(reason), runtime: unavailable(reason)),
    site: DriverSite(known: false, why: reason)),
    scratchFailed: true)

proc probeRun*(ctx: CcProbeContext): ProbeRun =
  ## The real probe, recording what it reads: a scratch directory under
  ## `ctx.stateDir` holding the discovery nimcache, the probe translation
  ## units and the runtime probe's object and program, removed afterwards
  ## (or, when the process is killed or crashes first, by a later probe:
  ## `reclaimStaleProbeDirs`). Never raises.
  var reads: seq[string] = @[]
  var scratch: string
  reclaimStaleProbeDirs(ctx.stateDir)
  try:
    createDir(ctx.stateDir)
    scratch = createTempDir(ProbeDirPrefix, "", ctx.stateDir)
  except CatchableError as e:
    let reason = "cannot create a probe directory under " & ctx.stateDir & ": " & e.msg
    return refusedRun(reason)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  try:
    writeFile(scratch / EmptyTu, "")
    writeFile(scratch / MsvcMacroTu, msvcMacroSource())
    writeFile(scratch / LinkTu, LinkTuSrc)
  except CatchableError as e:
    let reason = "cannot write the probe sources: " & e.msg
    return refusedRun(reason)
  let watcher = RunWatch()   # every tool run below goes through it
  proc discover(): Discovery =
    result = realDiscover(ctx, scratch,
                          watcher.watch(realRunWithStdinIn(ctx.projectRoot, DiscoverySource)))
    reads.add result.reads
  proc hashFile(path: string): CcDigest =
    reads.add path
    realFileHash(path)
  proc pathExists(path: string): bool =
    reads.add path
    fileExists(path) or dirExists(path)
  let search = (when defined(windows): dsWindows else: dsPosix)
  proc driverStop(path: string): bool =
    reads.add path
    realDriverStop(path, search)
  let io = CcProbeIo(
    discover:   discover,
    run:        watcher.watch(realRunIn(scratch)),
    runMerged:  watcher.watch(realRunMergedIn(scratch)),
    hashFile:   hashFile,
    pathExists: pathExists,
    driverStop: driverStop,
    getEnv:     proc(name: string): string = os.getEnv(name),
    search:     search)
  let toolchain = ccProbeWith(io)   # before `reads` is read: the probe fills it
  ProbeRun(toolchain: toolchain, reads: reads, interrupted: watcher.interrupted)

# ---------------------------------------------------------------------------
# The memo (R10-S8)
# ---------------------------------------------------------------------------

type
  ProbeProc* = proc(ctx: CcProbeContext): ProbeRun {.closure.}
  StampProc* = proc(ctx: CcProbeContext; reads: seq[string]): string {.closure.}
    ## The state of everything a probe's answer depends on, as one string:
    ## equal stamps mean the probe would read the same things again.

  ProbeMemo* = object
    ## Probe answers by context, each valid while its stamp holds.
    entries: seq[tuple[key: MemoKey; scope: string; stamp: string; run: ProbeRun]]
      ## `scope` (R15-S4): "" for an identified answer, which every state
      ## directory shares; the state directory an unidentified answer was
      ## probed under, which only that directory is served (`answerScope`).

  MemoKey = tuple[projectRoot: string; flags: seq[string]]
    ## What of a `CcProbeContext` the answer depends on (R12-D5): the
    ## project root is the discovery compile's cwd and project directory,
    ## and the flags are its arguments. The state directory is only where
    ## the probe's scratch directory goes -- no configuration is read from
    ## it and no probe's answer names it -- so contexts that differ only in
    ## it share an identified answer (an unidentified one is scoped to it,
    ## R15-S4). `runner.runEntrypoint` probes with a fresh
    ## private state directory per call: keyed on it, the memo never hit
    ## and grew an entry a call.

proc memoKey(ctx: CcProbeContext): MemoKey = (ctx.projectRoot, ctx.flags)

proc answerScope(ctx: CcProbeContext; run: ProbeRun): string =
  ## R15-S4: the state directory a recorded answer holds for only, or "" for
  ## every one. An identified answer names the toolchain and nothing of the
  ## scratch directory it was derived in, so it is the same under any state
  ## directory. An unidentified one may be about that directory rather than
  ## the toolchain -- a noexec or full filesystem fails the discovery
  ## compile or a probe's link as surely as a broken compiler does, and the
  ## reason alone cannot tell the two apart -- so it is served only to the
  ## state directory it was probed under; another one probes afresh.
  if toolchainVerdict(run.toolchain.fp).kind == tvIdentified: "" else: ctx.stateDir

proc len*(m: ProbeMemo): int =
  ## How many contexts have a recorded answer.
  m.entries.len

proc lookup*(m: var ProbeMemo; ctx: CcProbeContext; probe: ProbeProc;
             stamp: StampProc): ToolchainProbe =
  ## The probe recorded for `ctx` if the stamp over what that probe read is
  ## unchanged, else a fresh probe, which replaces it. The stamp is taken
  ## after the probe, so a file changed while the probe ran can go unseen
  ## until the next change; everything else that moves the answer re-probes.
  ## The fingerprint and the driver site are one probe's, as one value.
  ##
  ## The ONE memo rule (R13-L3, R14-D3): a probe derived from an interrupted
  ## tool run (`ProbeRun.interrupted`) is returned but never recorded. crisol
  ## refuses every new tool once an interrupt lands (and kills the ones
  ## running), so such an answer (typically "unidentified") says nothing
  ## about the toolchain; recorded, it would be served to a library host's
  ## every later run in the same environment, with caching off. Any other
  ## answer, an ordinary failure's included, is recorded -- except one about
  ## the state directory rather than the toolchain (`ProbeRun.scratchFailed`),
  ## since the state directory is not part of the key (`MemoKey`). An
  ## unidentified answer is recorded for its own state directory only
  ## (`answerScope`, R15-S4); a context with another one re-probes, and its
  ## answer replaces the entry, so a key holds one entry whatever the state
  ## directories it is probed under.
  let key = memoKey(ctx)
  for i in 0 ..< m.entries.len:
    if m.entries[i].key == key:
      let scope = m.entries[i].scope
      if (scope.len == 0 or scope == ctx.stateDir) and
         stamp(ctx, m.entries[i].run.reads) == m.entries[i].stamp:
        return m.entries[i].run.toolchain
      m.entries.delete(i)
      break
  let run = probe(ctx)
  if not (run.interrupted or run.scratchFailed):
    m.entries.add (key: key, scope: answerScope(ctx, run),
                   stamp: stamp(ctx, run.reads), run: run)
  run.toolchain

const
  StampContentLimit = 64 * 1024
    ## A file up to this size is stamped by content (config files); a larger
    ## one (a compiler, a runtime library) by size and modification time.

proc fileStamp(path: string): string =
  try:
    if not (fileExists(path) or dirExists(path)): return "absent"
    let info = getFileInfo(path)
    result = $info.kind & ":" & $info.size & ":" & $info.lastWriteTime.toUnixFloat
    if info.kind == pcFile and info.size <= StampContentLimit:
      result.add ":" & toHex16(fnv1a64(readFile(path)))
  except CatchableError as e:
    result = "error:" & e.msg

proc configCandidates(projectRoot: string): seq[string] =
  ## Where Nim looks for a configuration file the discovery compile would
  ## read: the project root and each parent, and the user configuration
  ## directory. A file created in any of them moves the stamp.
  result = @[]
  var dir = try: absolutePath(projectRoot) except CatchableError: projectRoot  # canon-ok: the directories nim searches for config, a memo stamp input, never identity
  while true:
    result.add dir / "nim.cfg"
    result.add dir / "config.nims"
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir: break
    dir = parent
  result.add getConfigDir() / "nim" / "nim.cfg"
  result.add getConfigDir() / "nim" / "config.nims"

proc nimCandidates(): seq[string] =
  ## Where this process finds `nim`, which runs the discovery compile.
  result = @[]
  when defined(windows):
    result.add getAppDir() / "nim.exe"
    result.add getCurrentDir() / "nim.exe"
  for dir in os.getEnv("PATH").split(PathSep):
    if dir.len == 0: continue
    result.add dir / "nim"
    when defined(windows): result.add dir / "nim.exe"

proc realStamp*(ctx: CcProbeContext; reads: seq[string]): string =
  ## The environment (every variable a probe or the nim and compilers it
  ## runs can read: `CL`, `_CL_`, `PATH`, `INCLUDE`, `LIB`, ...), this
  ## process's cwd, and the state of every file in `reads`, every
  ## configuration file Nim would look for, and every place `nim` could be
  ## found.
  var env: seq[string] = @[]
  for k, v in envPairs():
    # The `CRISOL_CACHE_*` namespace is removed from crisol's own environment
    # before a run's first child (`runcore.resolveCacheSecrets`), so the same
    # host would stamp differently before and after; no probe reads it.
    if not isCacheSecretName(k): env.add k & "=" & v
  env.sort
  var files = reads & configCandidates(ctx.projectRoot) & nimCandidates()
  files.sort
  var material = env.join("\x00") & "\x01" & getCurrentDir()
  var last = ""
  for f in files:
    if f == last: continue
    last = f
    material.add "\x01" & f & "\x00" & fileStamp(f)
  toHex16(fnv1a64(material))

var memo: ProbeMemo

proc cachedToolchainProbe*(ctx: CcProbeContext): ToolchainProbe =
  ## `probeRun(ctx).toolchain`, probed again only when something it depends
  ## on has changed (`realStamp`): a library host that changes `CL`, `PATH`,
  ## a `nim.cfg` or the compiler between runs gets a fresh answer. The
  ## environment nim runs the compiler with (`Discovery.nimEnv`) is this
  ## process's, as the configuration files in `reads` edit it, so the stamp
  ## covers it. This is what `runcore.productionRunDeps` installs as
  ## `RunDeps.ccProbe`: a run probes once, in its plan, and carries the
  ## value to its execution (R11-D1).
  ## `crisol clean` reads it too, for the toolchain its nimcache directories
  ## are judged by (`clean.cleanToolchainOf`). It is the ONE production memo:
  ## the fingerprint-only views tests use (`ccFingerprint`,
  ## `cachedCcFingerprint`, ...) live in `tests/support/ccprobes.nim`
  ## (R12-D7), outside the importable surface.
  memo.lookup(ctx, probeRun, realStamp)
