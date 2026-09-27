## ccprobe.nim -- C compiler dependency-header probing (RFC-0006, issue #16).
##
## Answers one question: which headers did this translation unit include,
## given the exact `ccCmd` a real compile ran. The compiler's own identity
## (`CcFingerprint`, `cachedToolchainProbe`) is a separate concern and lives
## in `crisol/ccidentity`; the process-execution seam (`RunProc`,
## `realRun*`) lives in `crisol/toolrun`.
##
## Everything here is pure: no proc spawns a process, reads a file or hashes
## anything. Each transforms text a caller already has:
##
## - `parseCompileCommand` reduces a manifest `ccCmd` to its driver, family,
##   replayable flags, output object and source. It is the one parser of
##   that command: `deriveDepInvocation` (the dependency probe) and
##   `closure.ccCmdOutputObj` (the external's object) and
##   `ccidentity.ccProbeWith` (the toolchain identity probe) read the
##   command through it, so no two of them can disagree about which token is
##   the output or the source;
## - `deriveDepInvocation` turns that parse into the dependency probe's own
##   invocation (`-M`, or `/Zs /sourceDependencies-`);
## - `depIncludeHeaders` (over `parseCcMDeps`/`parseMsvcSourceDeps`) turns
##   the probe's stdout into the reported header set, or a `DepProbeError`;
## - `reportedHeaderUnresolved` decides whether one reported header can be
##   given a sound identity at all.
##
## `crisol/headerprobe` runs these in order through a `RunProc`;
## `closure.extractCompileInputs` and `artifactid.ccIncludeClosure` both
## call it. `artifactid` re-exports the parsers its own callers use.
##
## Imports: among crisol modules only `crisol/paths` (for `ReportedPath`,
## `classify` and the case-blind root test), whose only crisol import is the
## std-only leaf `crisol/ioutils`. That keeps this module outside the
## closure -> artifactid -> depgraph -> closure cycle: `depgraph` imports
## `closure` and `artifactid` imports `depgraph`, so `closure` cannot import
## `artifactid`, but both can import this.

import std/[json, options, os, strutils]
import crisol/paths     # ReportedPath: header spellings out of a foreign
                        # tool's report carry this type, never a bare
                        # `string`, so `closure`/`artifactid` resolve them
                        # through `classify`'s ReportedPath overload.

# ---------------------------------------------------------------------------
# Tokenizing a manifest compile command
# ---------------------------------------------------------------------------

proc shellSplit*(s: string): tuple[toks: seq[string]; ok: bool] =
  ## Tokenizes a command written for a POSIX shell the way that shell does,
  ## so a whitespace-containing path (realistic under WSL2) survives as one
  ## token instead of silently corrupting the derived probe. The same rules
  ## apply on every host: which rules a command needs is a property of the
  ## host that WROTE it (`argvRulesOf`), never of the host reading it.
  ##
  ## Minimal POSIX-shell-like tokenizer: single-quoted segments (literal, no
  ## escapes inside), double-quoted segments (backslash escapes `\\`, `\"`,
  ## `\$`, `` \` `` inside), and backslash-escaping outside quotes.
  ## Whitespace (space/tab/newline/CR) separates tokens outside quotes.
  ## `ok = false` on an unterminated quote or a trailing unescaped
  ## backslash, which this parser cannot disambiguate; callers treat that
  ## as a derivation failure rather than guess.
  ##
  ## This is the quoting `std/os.quoteShellPosix` produces (single-quote
  ## wrap, `'"'"'` for an embedded quote), which is how a POSIX-hosted Nim
  ## spells a cc command whose `-I` argument contains a space; the real
  ## compile runs that string through a shell (`execProcesses`/
  ## `poEvalCommand`, see compiledriver.nim), so the probe must tokenize
  ## identically. A Windows-hosted Nim writes `quoteShellWindows` instead,
  ## in which `\` is a path separator and `'` an ordinary character; such a
  ## command is split by `msvcArgvSplit`, never here.
  var toks: seq[string]
  var cur = ""
  var haveCur = false
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i]
    case c
    of ' ', '\t', '\n', '\r':
      if haveCur:
        toks.add cur
        cur = ""
        haveCur = false
      inc i
    of '\'':
      haveCur = true
      inc i
      while i < n and s[i] != '\'':
        cur.add s[i]
        inc i
      if i >= n:
        return (toks: newSeq[string](), ok: false)   # unterminated single quote
      inc i   # skip closing quote
    of '"':
      haveCur = true
      inc i
      while i < n and s[i] != '"':
        if s[i] == '\\' and i + 1 < n and s[i + 1] in {'\\', '"', '$', '`'}:
          cur.add s[i + 1]
          i += 2
        else:
          cur.add s[i]
          inc i
      if i >= n:
        return (toks: newSeq[string](), ok: false)   # unterminated double quote
      inc i   # skip closing quote
    of '\\':
      haveCur = true
      if i + 1 < n:
        cur.add s[i + 1]
        i += 2
      else:
        return (toks: newSeq[string](), ok: false)   # trailing unescaped backslash
    else:
      haveCur = true
      cur.add c
      inc i
  if haveCur:
    toks.add cur
  result = (toks: toks, ok: true)

const ArgvSpace = {' ', '\t', '\n', '\r'}

proc msvcArgvSplit*(s: string): tuple[toks: seq[string]; ok: bool] =
  ## Tokenizes a Windows command line by the rules the Microsoft C runtime
  ## applies to it, on every host, so a command reads the same whether or
  ## not crisol runs on the host that compiled it. Those are the rules cl
  ## reads its command line by, and mingw-w64's gcc too: a Windows-hosted
  ## Nim quotes every path with `quoteShellWindows`, which writes exactly
  ## these rules, and starts the compiler through `CreateProcess` with no
  ## shell in between.
  ##
  ## - The program name (first token) ends at the first unquoted space or
  ##   tab; a `"` in it toggles quoting and is removed, and `\` is literal.
  ## - In every later token, a run of N backslashes followed by `"` yields
  ##   N div 2 backslashes, and the `"` is a literal quote when N is odd,
  ##   otherwise a quote toggle; inside quotes, `""` is one literal quote.
  ##   Backslashes not followed by `"` are literal, quoted or not, so a
  ##   quoted UNC path `-I"\\srv\share dir\inc"` keeps both leading
  ##   backslashes, where the shell-style splitter would halve them.
  ## - Space, tab, CR and LF separate tokens outside quotes.
  ##
  ## `ok = false` on an unterminated quote: the C runtime would accept it,
  ## but crisol does not guess at a command whose quotes do not balance.
  var toks: seq[string]
  var cur = ""
  var haveCur = false
  var inQuote = false
  var i = 0
  let n = s.len
  while i < n and s[i] in ArgvSpace: inc i
  while i < n and (inQuote or s[i] notin ArgvSpace):   # the program name
    if s[i] == '"':
      inQuote = not inQuote
    else:
      cur.add s[i]
    haveCur = true
    inc i
  if inQuote:
    return (toks: newSeq[string](), ok: false)
  if haveCur:
    toks.add cur
    cur = ""
    haveCur = false
  while i < n:                                        # the arguments
    let c = s[i]
    if c in ArgvSpace and not inQuote:
      if haveCur:
        toks.add cur
        cur = ""
        haveCur = false
      inc i
    elif c == '\\':
      var j = i
      while j < n and s[j] == '\\': inc j
      let run = j - i
      haveCur = true
      if j < n and s[j] == '"':
        for _ in 0 ..< run div 2: cur.add '\\'
        if run mod 2 == 1:
          cur.add '"'
          i = j + 1
        else:
          i = j          # an unescaped quote: the branch below toggles
      else:
        for _ in 0 ..< run: cur.add '\\'
        i = j
    elif c == '"':
      haveCur = true
      if inQuote and i + 1 < n and s[i + 1] == '"':
        cur.add '"'      # `""` inside quotes: one literal quote
        i += 2
      else:
        inQuote = not inQuote
        inc i
    else:
      haveCur = true
      cur.add c
      inc i
  if inQuote:
    return (toks: newSeq[string](), ok: false)
  if haveCur:
    toks.add cur
  result = (toks: toks, ok: true)

type
  CcFamily* = enum
    ccfGnu       ## gcc/clang/cc: `-M`, GNU-make-style dependency rule on stdout
    ccfMsvc      ## cl/vccexe/clang-cl: `/Zs /sourceDependencies-`, JSON on stdout

  DepProbeError* = enum
    ## Why a dependency probe produced no usable header set. `dpeNone` is the
    ## only value that means "trust the headers"; every other value must
    ## reach the caller as a loud failure. An empty header set is a
    ## legitimate answer (a `.c` file that includes nothing); "the probe did
    ## not answer" is not, and the two must never be confused: a bare banner
    ## parsed as a one-entry header set is a wrong closure vouched for by a
    ## soundness key (issue #21).
    dpeNone         ## parsed; `headers` is the real answer, empty or not
    dpeNoJson       ## no `/sourceDependencies` document on stdout at all
    dpeBadJson      ## a document that is not the shape cl documents
    dpeNoIncludes   ## a valid document whose `Data` carries no `Includes` array
    dpeNoMakeRule   ## GNU: stdout is not exactly one make rule `target: deps`
                    ## (empty, preprocessed source, a macro dump, or extra
                    ## `-MP` phony rules -- all measured shapes of a replay
                    ## that did not print the dependency rule)
    dpeSourceMismatch ## the report describes a different translation unit
                    ## than the one probed: MSVC `Data.Source` names another
                    ## file, or the GNU rule's first prerequisite is not the
                    ## probed source

const MsvcDrivers = ["cl", "vccexe", "clang-cl"]
  ## Compiler-driver basenames that take MSVC-spelled flags. `clang-cl` is
  ## here even though it does not implement `/sourceDependencies`: it
  ## accepts `/`-spelled flags, so the GNU arm would be wrong for it too,
  ## and the JSON-absence check turns its silence into a loud, specific
  ## failure instead of an empty header set. Nothing in crisol claims
  ## clang-cl support.

proc anySepBaseName*(path: string): string =
  ## The final component of `path`, after its last `/` or `\` on every host
  ## -- never the host's own `DirSep`. A path out of a compile command or a
  ## compiler's report describes the toolchain that wrote it, which need not
  ## share the reading host's separator: a POSIX crisol reading a cl
  ## manifest must see `cl.exe` in `C:\VC\bin\cl.exe`. `""` when `path` ends
  ## in a separator.
  let sep = max(path.rfind('/'), path.rfind('\\'))
  path[sep + 1 .. ^1]

proc ccFamilyOfDriver*(driver: string): CcFamily =
  ## Classify a compile command by the driver token the manifest itself
  ## recorded -- never by a compile-time `defined(vcc)`, the host OS, or a
  ## global config.
  ##
  ## Two reasons. A crisol built by gcc can be asked to read a nimcache
  ## produced by cl (and the reverse), so the reading process's own
  ## toolchain says nothing about the artifact in front of it. And the
  ## classification is per compile unit: one manifest's `compile` array is
  ## not guaranteed homogeneous.
  ##
  ## Matching is on the basename, case-folded, with any `.exe` suffix
  ## removed, so an absolute driver path out of a real manifest
  ## (`C:\nim\...\vccexe.exe`) classifies the same as a bare `vccexe`. The
  ## basename is `anySepBaseName`'s, so it follows either separator on
  ## every host.
  var base = anySepBaseName(driver).toLowerAscii
  if base.endsWith(".exe"):
    base.setLen(base.len - 4)
  result = if base in MsvcDrivers: ccfMsvc else: ccfGnu

proc programToken(s: string): string =
  ## The first token of `s` under `msvcArgvSplit`'s program-name rule, which
  ## is also an unquoted driver path's first shell token: enough to classify
  ## the family before choosing the tokenizer for the rest.
  var i = 0
  while i < s.len and s[i] in ArgvSpace: inc i
  var inQuote = false
  while i < s.len and (inQuote or s[i] notin ArgvSpace):
    if s[i] == '"': inQuote = not inQuote
    else: result.add s[i]
    inc i

type
  ArgvRules* = enum
    ## The quoting a compile command was written with, which is the one it
    ## must be split by.
    arPosixShell   ## `quoteShellPosix`, read by `/bin/sh` (`shellSplit`)
    arWindowsArgv  ## `quoteShellWindows`, read by the Microsoft C runtime
                   ## (`msvcArgvSplit`)

proc isWindowsAbsolute(p: string): bool =
  ## A drive-absolute (`C:\`, `C:/`) or UNC (`\\srv`) path: what a
  ## Windows-hosted Nim's absolute paths look like, and what no POSIX
  ## absolute path looks like.
  (p.len >= 3 and p[0] in Letters and p[1] == ':' and p[2] in {'\\', '/'}) or
    p.startsWith("\\\\")

proc argvRulesOf*(ccCmd: string; family: CcFamily): Option[ArgvRules] =
  ## The rules `ccCmd` was quoted with, read off the command itself --
  ## never off the host reading it (W9e): a POSIX crisol can be handed a
  ## Windows nimcache, and the reverse.
  ##
  ## - MSVC family: `arWindowsArgv`. cl reads its command line by the C
  ##   runtime's rules.
  ## - GNU family: the host that wrote the command decides. Nim quotes every
  ##   path in a compile command with `os.quoteShell`
  ##   (`extccomp.getCompileCFileCmd`), which is `quoteShellWindows` on a
  ##   Windows host and `quoteShellPosix` elsewhere, and a Windows host
  ##   writes every absolute path drive- or UNC-rooted where a POSIX host
  ##   writes `/`. So the source, the command's last token and always
  ##   absolute from Nim, names the writer: `arWindowsArgv` when the Windows
  ##   split's last token is Windows-absolute, `arPosixShell` when the POSIX
  ##   split's last token starts with `/`.
  ## - Both at once is a command no Nim host writes (`'/tmp/a C:/x.c'`
  ##   reads as absolute under both rules): `none`, and the caller refuses
  ##   the command rather than guess.
  ## - Neither (a relative source: `--genScript`, or a hand-written
  ##   command): the driver decides. `extccomp.needsExeExt` appends `.exe`
  ##   to an extensionless driver exactly when the compile host is Windows,
  ##   so a driver ending in `.exe` is `arWindowsArgv` and any other is
  ##   `arPosixShell`.
  case family
  of ccfMsvc:
    return some(arWindowsArgv)
  of ccfGnu:
    discard
  let win = msvcArgvSplit(ccCmd)
  let posix = shellSplit(ccCmd)
  let winAbs = win.ok and win.toks.len >= 2 and isWindowsAbsolute(win.toks[^1])
  let posixAbs = posix.ok and posix.toks.len >= 2 and posix.toks[^1].startsWith("/")
  if winAbs and posixAbs:
    none(ArgvRules)
  elif winAbs:
    some(arWindowsArgv)
  elif posixAbs:
    some(arPosixShell)
  elif anySepBaseName(programToken(ccCmd)).toLowerAscii.endsWith(".exe"):
    some(arWindowsArgv)
  else:
    some(arPosixShell)

type
  DriverSearch* = enum
    ## How the nim that compiles the tests finds a compiler named by a bare
    ## token, which is where every replay must find it too.
    dsPosix    ## `execvp`/`sh`: the PATH entries in order (an empty entry is
               ## the cwd)
    dsWindows  ## `CreateProcess` with no application name: the directory of
               ## the spawning program (nim), its cwd, the system directory,
               ## the 16-bit system directory, the Windows directory, then
               ## PATH; `.exe` is appended to a name with no extension

  DriverLocation* = object
    ## Where the nim that compiles the tests finds one compiler driver
    ## (`locateDriver`, R10-S6): the file the build runs for a compile
    ## command naming that driver, which is the file every replay of the
    ## command must run too. Defined here, beside the command parse, so the
    ## header probe (`crisol/headerprobe`) can take one without importing
    ## `crisol/ccidentity`.
    case found*: bool
    of true:  path*: string
    of false: why*:  string

  DriverSite* = object
    ## Everything `locateDriver` needs to find a driver the way the nim
    ## that compiles the tests finds it: that nim's binary and working
    ## directory (learned by `ccidentity`'s one discovery compile), the
    ## host's search rule, and the two environment variables the search
    ## reads, as that nim sees them. A site, not one resolved driver: a
    ## build runs more than one driver (Nim compiles a `{.compile.}`d
    ## `.cpp` with the C++ driver, `g++` or `clang++`, beside a `gcc` or
    ## `clang` C compiler), and each manifest command's own driver token is
    ## resolved against it (`locateDriver`). `known` false, with the
    ## reason, when the discovery failed: every resolution then refuses.
    ## Carried to the measure worker in its plan (`workerplan.MeasurePlan`).
    case known*: bool
    of true:
      nimExe*:     string        ## "" when not learned (POSIX never asks)
      nimCwd*:     string
      search*:     DriverSearch
      pathVar*:    string        ## PATH as the nim process has it once its
                                 ## configuration ran (a `config.nims` can
                                 ## `putEnv` it; `ccidentity.NimEnvNames`)
      systemRoot*: string        ## SystemRoot (read by `dsWindows` only): the
                                 ## stand-in for the Windows directory, which
                                 ## `CreateProcess` asks the system for, so it
                                 ## is this process's value, not nim's
    of false:
      why*: string

  DriverResolver* = proc(driver: string): DriverLocation {.closure.}
    ## A run's driver resolution: the file the build's nim runs for a
    ## compile command whose driver token is `driver`. Asked only when a
    ## header probe is about to run (`closure.extractCompileInputs`, for an
    ## external Nim compiled this round), with that command's own token
    ## (`headerprobe.probeReportedHeaders`). The production resolver
    ## (`headerprobe.siteResolver`) resolves each token against one
    ## `DriverSite`, once per token.

  DriverStop* = proc(path: string): bool {.closure.}
    ## Whether the search for a driver's file stops at `path`:
    ## `CreateProcess` stops at the first file or directory of that name;
    ## `execvp` passes over one it may not execute (a directory, a file
    ## without the execute bit) and tries the next entry (R13-S4).
    ## `locateDriver`'s own seam -- this module never touches a real
    ## filesystem (module doc), so the real answer,
    ## `headerprobe.realDriverStop`, lives one module over, where disk
    ## access already lives. R15-D7: one name, one type, for the question
    ## `locateDriver`, `headerprobe.siteResolver` and
    ## `ccidentity.CcProbeIo.driverStop` all ask, replacing three
    ## independent spellings (`pathExists`, `driverStop`, `realDriverStop`)
    ## of the identical `proc(path: string): bool` shape.

proc isAbsoluteOn(path: string; rules: DriverSearch): bool =
  case rules
  of dsPosix: path.startsWith("/")
  of dsWindows:
    path.startsWith("\\") or path.startsWith("/") or
      (path.len >= 2 and path[0] in Letters and path[1] == ':')

proc joinOn(dir, name: string; rules: DriverSearch): string =
  let sep = if rules == dsWindows: '\\' else: '/'
  let d = dir.strip(leading = false, chars = {'/', '\\'})
  if d.len == 0: $sep & name else: d & sep & name

proc dirOf(path: string): string =
  ## Everything before the final separator (either kind), or "".
  for i in countdown(path.high, 0):
    if path[i] in {'\\', '/'}: return path[0 ..< i]
  ""

proc locateDriver*(driver: string; site: DriverSite;
                   driverStop: DriverStop): DriverLocation =
  ## The file the nim that compiles the tests runs for `driver`, found the
  ## way that nim finds it (`site.search`), not the way this process would:
  ## on Windows the two search their own directory and cwd first. A search
  ## step that cannot be taken (nim's directory or cwd, or the Windows
  ## directory, is unknown) before the driver is found refuses, on either
  ## host, rather than being skipped: a later step's hit may not be the
  ## copy that runs (R13-D7). `driverStop` answers whether the search stops
  ## at a path (`DriverStop`'s own doc states the rule); `headerprobe.
  ## realDriverStop` is that rule on the real filesystem.
  ##
  ## Every relative location -- a driver path, a PATH entry (`wbin`, `.`,
  ## `./bin`, and on POSIX the empty entry) -- is nim's cwd's, since nim
  ## spawns the compiler from there (R11-S3), so every answer is absolute:
  ## the probe runs it from a scratch dir, and a relative answer would name
  ## a different file there, or none (R12-L1). With nim's cwd unknown, a
  ## relative location reached before the driver is found refuses.
  if not site.known:
    return DriverLocation(found: false, why: site.why)
  let rules = site.search
  if driver.len == 0:
    return DriverLocation(found: false, why: "the compile command names no driver")
  if driver.contains({'/', '\\'}) and (rules == dsWindows or '/' in driver):
    # A path: used as is, a relative one against nim's cwd. Windows appends
    # no `.exe` to a name that carries a path.
    if not isAbsoluteOn(driver, rules) and site.nimCwd.len == 0:
      return DriverLocation(found: false, why: "the compiler `" & driver &
        "` is a relative path, and the cwd nim resolves it against is unknown")
    let p = if isAbsoluteOn(driver, rules): driver else: joinOn(site.nimCwd, driver, rules)
    if driverStop(p): return DriverLocation(found: true, path: p)
    return DriverLocation(found: false, why: "the compiler `" &
                          driver & "` does not exist (" & p & ")")
  var name = driver
  type Step = tuple[dir: Option[string]; unknownWhy: string]
    ## One search step: the directory it searches, or `none` when the step
    ## cannot be taken, with the reason the search then refuses (R13-D7:
    ## an unknown step is never skipped, on either host).
  proc search(steps: openArray[Step]): Option[DriverLocation] =
    ## The first step's hit, or its refusal if it cannot be taken; `none`
    ## when every step was searched and missed.
    for s in steps:
      if s.dir.isNone:
        return some(DriverLocation(found: false, why: s.unknownWhy))
      let p = joinOn(s.dir.get, name, rules)
      if driverStop(p): return some(DriverLocation(found: true, path: p))
    none(DriverLocation)
  proc entryStep(entry: string): Step =
    ## A search path entry as a directory: an absolute one as is, a relative
    ## one (the empty POSIX entry is nim's cwd itself) under nim's cwd;
    ## unknown when the entry is relative and nim's cwd is unknown.
    let why = "nim's search path has a relative entry before any copy of `" &
              name & "`, and the cwd nim resolves it against is unknown"
    if entry.len > 0 and isAbsoluteOn(entry, rules): (some(entry), why)
    elif site.nimCwd.len == 0: (none(string), why)
    elif entry.len == 0: (some(site.nimCwd), why)
    else: (some(joinOn(site.nimCwd, entry, rules)), why)
  var steps: seq[Step] = @[]
  case rules
  of dsPosix:
    for entry in site.pathVar.split(':'):
      steps.add entryStep(entry)
  of dsWindows:
    if '.' notin name: name.add ".exe"
    let nimDir = dirOf(site.nimExe)
    steps.add (dir: (if nimDir.len > 0: some(nimDir) else: none(string)),
               unknownWhy: "the directory of the nim binary that compiles " &
                 "the tests is unknown (`" & site.nimExe & "`), and it looks " &
                 "for `" & name & "` there first")
    steps.add (dir: (if site.nimCwd.len > 0: some(site.nimCwd) else: none(string)),
               unknownWhy: "`" & name & "` is not in nim's directory, and " &
                 "nim's cwd, which it searches next, is unknown")
    let first = search(steps)
    if first.isSome: return first.get
    let root = site.systemRoot
    if root.len == 0:
      return DriverLocation(found: false, why: "`" & name & "` is not in nim's " &
        "directory or cwd, and SystemRoot is not set, so the Windows " &
        "directories nim searches next are unknown")
    steps = @[]
    for d in [joinOn(root, "System32", rules), joinOn(root, "System", rules), root]:
      steps.add (dir: some(d), unknownWhy: "")
    for entry in site.pathVar.split(';'):
      let e = entry.strip(chars = {' ', '"'})
      if e.len > 0: steps.add entryStep(e)
  let found = search(steps)
  if found.isSome: return found.get
  DriverLocation(found: false, why: "the compiler `" & name &
                 "` is not on the search path nim uses")

proc splitCompileCommand*(ccCmd: string; rules: ArgvRules):
    tuple[toks: seq[string]; ok: bool] =
  ## `ccCmd` tokenized by `rules`.
  case rules
  of arPosixShell: shellSplit(ccCmd)
  of arWindowsArgv: msvcArgvSplit(ccCmd)

# ---------------------------------------------------------------------------
# The flags a replay must not carry
# ---------------------------------------------------------------------------

proc gnuDriverDepFlagArity(tok: string): int =
  ## How many tokens a GNU-driver dependency-output or output-mode flag
  ## occupies: 0 = not such a flag (replay it), 1 = drop `tok` alone, 2 =
  ## drop `tok` and the argument token after it.
  ##
  ## Measured against gcc 13 / clang 18 beside `-M`: `-MD`/`-MMD`/`-MF`/
  ## `--write-*dependencies` send the rule to a file, leaving stdout empty
  ## (gcc) or full of preprocessed source (clang); `-MP` appends phony
  ## rules; `-MM`/`--user-dependencies` omit headers found in system
  ## directories, which includes any reached through `-isystem`; `-MG`
  ## hides a missing header; `-MT`/`-MQ` rename the target; `-dM` replaces
  ## the rule with a macro dump; `-MJ`/`-fdeps-*`/`-save-temps` write side
  ## files.
  case tok
  of "-M", "-MM", "-MD", "-MMD", "-MP", "-MG", "-MV", "-E", "-S",
     "-save-temps", "--dependencies", "--user-dependencies",
     "--write-dependencies", "--write-user-dependencies",
     "--print-missing-file-dependencies",
     "-dM", "-dD", "-dN", "-dI", "-dU":
    1
  of "-MF", "-MT", "-MQ", "-MJ":
    2
  else:
    if tok.startsWith("-save-temps=") or tok.startsWith("-fdeps-"): 1
    elif tok.len > 3 and (tok.startsWith("-MF") or tok.startsWith("-MT") or
                          tok.startsWith("-MQ") or tok.startsWith("-MJ")): 1
    else: 0

proc cppDepOptionArity(opt: string): int =
  ## `gnuDriverDepFlagArity` for an option handed to the preprocessor proper
  ## (`-Wp,<list>` / `-Xpreprocessor <opt>`), where `-MD`/`-MMD` take the
  ## dependency file as their own argument (`-Wp,-MD,u.d`, measured).
  case opt
  of "-M", "-MM", "-MP", "-MG": 1
  of "-MD", "-MMD", "-MF", "-MT", "-MQ": 2
  else:
    if opt.len > 3 and (opt.startsWith("-MF") or opt.startsWith("-MT") or
                        opt.startsWith("-MQ")): 1
    else: 0

proc filterPreprocessorDepOptions(items: seq[string]): seq[string] =
  ## `items` (one `-Wp,` list) minus every dependency option and its argument.
  var i = 0
  while i < items.len:
    let arity = cppDepOptionArity(items[i])
    if arity == 0:
      result.add items[i]
    i += max(arity, 1)

proc msvcDropArity(tok: string): int =
  ## `gnuDriverDepFlagArity` for cl: 0 = replay, 1 = drop `tok`, 2 = drop it
  ## and the token after it. cl takes `-` as a flag prefix interchangeably
  ## with `/`, so both spellings are recognised; its option names are
  ## case-sensitive, so nothing is folded.
  ##
  ## Dropped: the compile action (`/c`); the modes that print preprocessed
  ## text instead of compiling (`/E`, `/EP`, `/P`) and `/Zs`, which the
  ## dependency probe adds itself; and every dependency-output flag
  ## (`/showIncludes`, `/sourceDependencies[:directives]`,
  ## `/scanDependencies`), each of which moves or reshapes the report the
  ## probe reads. The object output (`/Fo`) is recognised by
  ## `msvcOutputValue`, because its value is recorded.
  if tok.len < 2 or tok[0] notin {'/', '-'}: return 0
  case tok[1 .. ^1]
  of "c", "E", "EP", "P", "Zs", "showIncludes",
     "sourceDependencies-", "sourceDependencies:directives-",
     "scanDependencies-":
    1
  of "sourceDependencies", "sourceDependencies:directives",
     "scanDependencies":
    2
  else: 0

proc msvcOutputValue(tok: string): tuple[isOutput: bool; value: string] =
  ## Whether `tok` is cl's object-output flag (`/Fo<obj>`, `-Fo<obj>`,
  ## `/Fo:<obj>`), and its value. After a colon cl also accepts the value
  ## as the next token (`/Fo: <obj>`); `value` is then "".
  for prefix in ["/Fo", "-Fo"]:
    if tok.startsWith(prefix):
      var v = tok[prefix.len .. ^1]
      if v.startsWith(":"): v = v[1 .. ^1]
      return (isOutput: true, value: v)
  (isOutput: false, value: "")

# ---------------------------------------------------------------------------
# parseCompileCommand
# ---------------------------------------------------------------------------

type
  CompileCommand* = object
    ## A manifest compile command, reduced to what a replay needs.
    driver*: string       ## the driver token exactly as the manifest recorded it
    family*: CcFamily     ## classified from `driver` (`ccFamilyOfDriver`)
    flags*: seq[string]   ## every token between the driver and the source,
                          ## verbatim and in order, minus the compile action,
                          ## the object output and every dependency-output or
                          ## output-mode flag (`gnuDriverDepFlagArity`,
                          ## `msvcDropArity`), with their arguments
    output*: string       ## the object the command writes ("" if it names none)
    source*: string       ## the translation unit: the command's last token

proc parseCompileCommand*(ccCmd: string): Option[CompileCommand] =
  ## Parse one manifest `ccCmd` (see `closure.parseCompileManifest`). The
  ## family is classified from the driver token, then the whole command is
  ## tokenized by the rules it was quoted with (`argvRulesOf`: always the
  ## Windows C runtime's for MSVC; for GNU, those of the host that wrote
  ## it). The source is the last token, matching
  ## `closure.parseCompileManifest`'s convention that the compiled `.c` is
  ## always the final argument.
  ##
  ## `flags` is a DENYLIST result, never an allow-list: every token survives
  ## verbatim except the ones `CompileCommand.flags`' doc names. Any other
  ## flag (`-isystem`, `-iquote`, `-include`, `-nostdinc`, `/I`, `/FI`, ...)
  ## changes header resolution as much as `-I`/`-D`/`-std` and must reach
  ## every replay unchanged (see `artifactid.nim`'s module
  ## doc, "ccIncludeClosure()").
  ##
  ## GNU output: `-o <obj>` separated (the flag and the next token) or fused
  ## (`-o<obj>`, a token longer than 2 that starts with `-o`). MSVC output:
  ## `/Fo<obj>` (`msvcOutputValue`). Inside `-Wp,<list>` and
  ## `-Xpreprocessor <opt>` only the dependency options are removed
  ## (`cppDepOptionArity`).
  ##
  ## `none` -- never a raise -- when the command cannot be tokenized cleanly
  ## (an unterminated quote, or quoting `argvRulesOf` cannot attribute to
  ## one host), has fewer than 2 tokens, names more than one
  ## output or an empty one, or ends inside a flag's argument (an output or
  ## dependency flag whose argument would be the source). A per-unit oddity
  ## degrades to a loud derivation failure, never a crash past a worker's
  ## `except CatchableError`, and is never guessed at.
  let family = ccFamilyOfDriver(programToken(ccCmd))
  let rules = argvRulesOf(ccCmd, family)
  if rules.isNone:
    return none(CompileCommand)
  let (toks, splitOk) = splitCompileCommand(ccCmd, rules.get)
  if not splitOk or toks.len < 2 or ccFamilyOfDriver(toks[0]) != family:
    return none(CompileCommand)
  let last = toks.len - 1          # the source; flags are toks[1 ..< last]
  var cmd = CompileCommand(driver: toks[0], family: family, source: toks[last])
  var haveOutput = false
  template setOutput(v: string) =
    if haveOutput or v.len == 0: return none(CompileCommand)
    haveOutput = true
    cmd.output = v
  var idx = 1
  while idx < last:
    let t = toks[idx]
    case family
    of ccfMsvc:
      let o = msvcOutputValue(t)
      if o.isOutput:
        if o.value.len == 0 and t.endsWith(":"):
          if idx + 1 >= last: return none(CompileCommand)
          setOutput(toks[idx + 1])
          idx += 2
        else:
          setOutput(o.value)
          inc idx
        continue
      let arity = msvcDropArity(t)
      if arity > 0:
        if idx + arity > last: return none(CompileCommand)
        idx += arity
        continue
      cmd.flags.add t
      inc idx
    of ccfGnu:
      if t == "-c":
        inc idx
        continue
      if t == "-o":
        if idx + 1 >= last: return none(CompileCommand)
        setOutput(toks[idx + 1])
        idx += 2
        continue
      if t.startsWith("-o") and t.len > 2:
        setOutput(t[2 .. ^1])
        inc idx
        continue
      let arity = gnuDriverDepFlagArity(t)
      if arity > 0:
        if idx + arity > last: return none(CompileCommand)
        idx += arity
        continue
      if t.startsWith("-Wp,"):
        let rest = filterPreprocessorDepOptions(t[4 .. ^1].split(','))
        if rest.len > 0:
          cmd.flags.add "-Wp," & rest.join(",")
        inc idx
        continue
      if t == "-Xpreprocessor" and idx + 1 < last:
        let opt = toks[idx + 1]
        let arity = cppDepOptionArity(opt)
        if arity == 0:
          cmd.flags.add t
          cmd.flags.add opt
          idx += 2
        elif arity == 2 and idx + 3 < last and toks[idx + 2] == "-Xpreprocessor":
          idx += 4   # the option and its own -Xpreprocessor-carried argument
        else:
          idx += 2
        continue
      cmd.flags.add t
      inc idx
  some(cmd)

proc deriveDepInvocation*(ccCmd: string):
    tuple[cmd: string; args: seq[string]; sourceFile: string;
          family: CcFamily; ok: bool] =
  ## The dependency-probe invocation for one manifest `ccCmd`, in whichever
  ## form its driver understands: the driver, then the probe's own flags,
  ## then `parseCompileCommand`'s `flags`, then the source.
  ##
  ## - GNU: `-M` in front; the rule arrives on stdout.
  ## - MSVC: `/Zs /sourceDependencies-` in front; the JSON document arrives
  ##   on stdout. `/Zs` (syntax check only) also means no `.obj`, `.pdb` or
  ##   `.idb` is written (measured, cl 19.44), so a flag the MSVC denylist
  ##   does not name still cannot rewrite the nimcache object.
  ##
  ## The family is returned alongside because the CALLER must parse the
  ## output with the matching parser: feeding a `/sourceDependencies`
  ## document to the make-rule parser yields a plausible-looking, wrong
  ## header list. A flag the denylist misses cannot pass silently either:
  ## `depIncludeHeaders` rejects any stdout that is not one report for the
  ## probed source.
  ##
  ## `ok = false` exactly when `parseCompileCommand` returns `none`.
  let parsed = parseCompileCommand(ccCmd)
  if parsed.isNone:
    return (cmd: "", args: newSeq[string](), sourceFile: "",
            family: ccfGnu, ok: false)
  let c = parsed.get
  let lead = case c.family
             of ccfMsvc: @["/Zs", "/sourceDependencies-"]
             of ccfGnu: @["-M"]
  (cmd: c.driver, args: lead & c.flags & @[c.source], sourceFile: c.source,
   family: c.family, ok: true)

proc findRuleTargetColon(s: string): int =
  ## Locate the colon that separates a GNU make rule's TARGET from its
  ## dependency list — never a Windows drive-letter colon (`C:/...` or
  ## `C:\...`). A drive-letter colon is always immediately followed by a
  ## path separator; the rule's real target colon never is (whatever follows
  ## it is the start of the dependency list, or nothing). This is a property
  ## of the rule text itself, so it classifies the same on every host,
  ## including a non-Windows crisol reading a mingw-produced rule.
  result = -1
  var start = 0
  while true:
    let idx = s.find(':', start)
    if idx < 0:
      return -1
    if idx + 1 < s.len and s[idx + 1] in {'/', '\\'}:
      start = idx + 1
      continue
    return idx

proc unescapeMakeRuleTokens(depsStr: string): seq[string] =
  ## Split a GNU make dependency-rule's token list, reversing `-M`'s own
  ## escaping (cpp's dependency writer, mkdeps.cc `make_write_name`) rather
  ## than splitting on whitespace. The escaping is a property of the rule
  ## text, never of the host reading it, so nothing here is host-gated.
  ##
  ## - A run of N backslashes immediately before a space/tab collapses to
  ##   `N div 2` literal backslashes; if N is odd the space/tab is an
  ##   ESCAPED, embedded character of the token (not a separator), and if N
  ##   is even (including zero) the backslashes are literal and the
  ##   space/tab IS the separator. This is make's own quoting rule for
  ##   whitespace in a dependency-rule path.
  ## - `\#` unescapes to a literal `#`.
  ## - `$$` unescapes to a literal `$`.
  ## - A bare, unescaped space/tab/newline/CR is always a separator.
  result = @[]
  var cur = ""
  var haveCur = false
  var i = 0
  let n = depsStr.len
  while i < n:
    let c = depsStr[i]
    if c == '\\' and i + 1 < n and depsStr[i + 1] == '#':
      cur.add '#'
      haveCur = true
      i += 2
    elif c == '\\':
      var j = i
      while j < n and depsStr[j] == '\\': inc j
      let bsCount = j - i
      if j < n and depsStr[j] in {' ', '\t'}:
        let half = bsCount div 2
        for _ in 0 ..< half: cur.add '\\'
        if half > 0: haveCur = true
        if bsCount mod 2 == 1:
          cur.add depsStr[j]     # escaped space/tab: embedded, not a separator
          haveCur = true
          i = j + 1
        else:
          if haveCur:
            result.add cur
            cur = ""
            haveCur = false
          i = j + 1
      else:
        for _ in 0 ..< bsCount: cur.add '\\'
        haveCur = true
        i = j
    elif c == '$' and i + 1 < n and depsStr[i + 1] == '$':
      cur.add '$'
      haveCur = true
      i += 2
    elif c in {' ', '\t', '\n', '\r'}:
      if haveCur:
        result.add cur
        cur = ""
        haveCur = false
      inc i
    else:
      cur.add c
      haveCur = true
      inc i
  if haveCur:
    result.add cur

proc parseCcMDeps*(ccMOutput: string): seq[ReportedPath] =
  ## Parse GNU-make-style dependency output (`target: dep1 dep2 \` with
  ## backslash line continuations) into the flat list of dependency tokens,
  ## INCLUDING the source file itself (callers that need it excluded should
  ## filter by the known source path — see `depIncludeHeaders`). Tokenizes
  ## via `unescapeMakeRuleTokens`, so a backslash-escaped space stays inside
  ## one token, and locates the target/dependency-list separator via
  ## `findRuleTargetColon`, which skips a Windows drive-letter colon.
  ##
  ## Returns `ReportedPath`, not `string`: this is gcc/clang `-M`'s echo of
  ## the `#include` directive's literal spelling, unresolved against the
  ## real on-disk file. `paths.classify`/`tracked`'s `ReportedPath` overload
  ## is the sanctioned way to turn one into identity material.
  ##
  ## Tokenization only: text that is not a make rule at all still yields
  ## tokens here. `depIncludeHeaders` is what decides whether the text IS
  ## the rule for the probed source (`parseGnuDepRule`).
  let joined = ccMOutput.replace("\\\r\n", " ").replace("\\\n", " ")
  let colonIdx = findRuleTargetColon(joined)
  let depsStr = if colonIdx >= 0: joined[colonIdx + 1 .. ^1] else: joined
  for tok in unescapeMakeRuleTokens(depsStr):
    result.add ReportedPath(tok)

proc stripLeadingDotSlash(p: string): string =
  ## gcc and clang print a leading `./` (and any separators after it)
  ## stripped from the dependency they echo (`./x.c` and `.//x.c` both
  ## print as `x.c`, measured); nothing else about the spelling changes.
  result = p
  while result.len >= 2 and result[0] == '.' and result[1] in {'/', '\\'}:
    var i = 1
    while i < result.len and result[i] in {'/', '\\'}: inc i
    result = result[i .. ^1]

proc parseGnuDepRule(depOutput, sourceFile: string):
    tuple[deps: seq[ReportedPath]; err: DepProbeError] =
  ## The prerequisites of the ONE make rule a `-M` replay printed, with its
  ## first prerequisite -- the probed source itself, always printed first --
  ## verified and removed. Anything else is an error, never a header set:
  ## - `dpeNoMakeRule`: no rule-target colon, a "target" that is not exactly
  ##   one token (preprocessed source or any other prose before a colon), or
  ##   a second rule after the first (`-MP` phony targets);
  ## - `dpeSourceMismatch`: no prerequisites, or a first prerequisite that is
  ##   not `sourceFile` (after make unescaping and `./` stripping).
  let joined = depOutput.replace("\\\r\n", " ").replace("\\\n", " ")
  let colonIdx = findRuleTargetColon(joined)
  if colonIdx < 0:
    return (deps: newSeq[ReportedPath](), err: dpeNoMakeRule)
  if unescapeMakeRuleTokens(joined[0 ..< colonIdx]).len != 1:
    return (deps: newSeq[ReportedPath](), err: dpeNoMakeRule)
  let depsStr = joined[colonIdx + 1 .. ^1]
  if findRuleTargetColon(depsStr) >= 0:
    return (deps: newSeq[ReportedPath](), err: dpeNoMakeRule)
  let toks = unescapeMakeRuleTokens(depsStr)
  if toks.len == 0 or
     stripLeadingDotSlash(toks[0]) != stripLeadingDotSlash(sourceFile):
    return (deps: newSeq[ReportedPath](), err: dpeSourceMismatch)
  var deps: seq[ReportedPath] = @[]
  for i in 1 ..< toks.len:
    deps.add ReportedPath(toks[i])
  (deps: deps, err: dpeNone)

proc msvcSourceDepsDocStart(s: string): int =
  ## The BYTE index in `s` at which the `/sourceDependencies` JSON document
  ## begins: the position of a `{` that is the first non-whitespace
  ## character on its line -- `-1` if there is none.
  ##
  ## Scans `s` directly rather than reconstructing an offset from split
  ## line lengths, so the index is right whether the preceding lines end in
  ## LF or CRLF: terminator width is never assumed.
  var atLineStart = true
  for i in 0 ..< s.len:
    case s[i]
    of '{':
      if atLineStart: return i
      atLineStart = false
    of '\n':
      atLineStart = true
    of ' ', '\t', '\r':
      discard   # leading whitespace -- still could be the start of the line
    else:
      atLineStart = false
  -1

proc parseMsvcSourceDeps*(depOutput: string):
    tuple[source: string; includes: seq[ReportedPath]; err: DepProbeError] =
  ## Parse a `/sourceDependencies-` document off cl's STDOUT.
  ##
  ## `includes` is `seq[ReportedPath]`, not `seq[string]`: cl lowercases
  ## every path it reports, non-ASCII letters included, so each is a
  ## potentially non-canonical spelling of a real tracked file until
  ## resolved via `paths.classify`/`tracked`'s `ReportedPath` overload.
  ## `source` stays a plain `string`: it is never sliced into identity
  ## material, only compared by basename against the known, TRUSTED
  ## `sourceFile` the probe was invoked for (`msvcSourceMatches`, below).
  ##
  ## cl prints one banner line -- the source's base name -- and then the
  ## pretty-printed JSON, and sends every diagnostic to STDERR (measured),
  ## including the `D9002 ignoring unknown option` that a cl older than
  ## 19.27 answers `/sourceDependencies` with. `crisol/headerprobe` runs
  ## the probe through a `RunProc` whose `output` is stdout alone (stderr
  ## is captured separately), so stdout here is exactly
  ## `<banner>\n<document>` and the document begins at the first line whose
  ## first non-blank character is `{`. Locating it by CONTENT rather than by
  ## line index is what keeps a second banner line, or none, from shifting
  ## the parse.
  ##
  ## The prefix test is deliberately looser than "a line that IS `{`". cl
  ## pretty-prints, so the two agree; but a toolset (or clang-cl, or a
  ## `/diagnostics` setting) that emits the document compactly on one line
  ## would have a plainly present document classified `dpeNoJson` -- "the
  ## probe did not run" -- by the strict form, a misdiagnosis rather than a
  ## stricter check. The enum exists to tell
  ## "no document" apart from "a document of the wrong shape"; a locator
  ## that collapses the second into the first defeats it. cl's banner is a
  ## source FILENAME and cannot begin with `{`, so nothing is given up.
  ##
  ## Absence of the document is a LOUD failure, never an empty header set:
  ## an empty `Includes` array is a real answer about a real translation
  ## unit; a missing document means the probe did not run. Distinguishing
  ## those is the whole reason `/sourceDependencies` was chosen over
  ## `/showIncludes`, which cannot express the difference.
  let start = msvcSourceDepsDocStart(depOutput)
  if start < 0:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeNoJson)

  var doc: JsonNode
  try:
    doc = parseJson(depOutput[start .. ^1])
  except CatchableError:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)

  if doc.kind != JObject or "Data" notin doc or doc["Data"].kind != JObject:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)
  let data = doc["Data"]
  if "Includes" notin data or data["Includes"].kind != JArray:
    return (source: "", includes: newSeq[ReportedPath](), err: dpeNoIncludes)

  var incs: seq[ReportedPath] = @[]
  for n in data["Includes"]:
    if n.kind != JString:
      return (source: "", includes: newSeq[ReportedPath](), err: dpeBadJson)
    incs.add ReportedPath(n.getStr)
  let src = if "Source" in data and data["Source"].kind == JString:
              data["Source"].getStr
            else: ""
  (source: src, includes: incs, err: dpeNone)

proc msvcSourceMatches(probedSource, docSource: string): bool =
  ## Whether a `/sourceDependencies` document's `Data.Source` could
  ## plausibly describe `probedSource` — the translation unit
  ## `deriveDepInvocation` actually targeted.
  ##
  ## Compared by BASENAME, case-blind under Unicode simple folding
  ## (`paths.caseBlindEqual`), with either path separator treated as a
  ## break — never by full-path equality. cl lowercases every path it
  ## reports, non-ASCII letters included (measured), and may report it
  ## ABSOLUTE where the
  ## probe's own `sourceFile` (the manifest `ccCmd`'s last token) is
  ## relative to `config.projectRoot` — a layer this proc has no access to
  ## and cannot resolve against. A full-path comparison would therefore
  ## false-positive-mismatch a document that genuinely describes the probed
  ## unit; basename is the strictest comparison available without a project
  ## root. It is not infallible, but a stale or misattributed document
  ## naming a DIFFERENT translation unit almost never happens to share the
  ## probed unit's final path component, so this still catches the defect
  ## class it exists for without manufacturing false positives out of case
  ## or relative-vs-absolute spelling alone.
  caseBlindEqual(anySepBaseName(probedSource), anySepBaseName(docSource))

proc depIncludeHeaders*(family: CcFamily; depOutput: string;
                        sourceFile: string):
    tuple[headers: seq[ReportedPath]; err: DepProbeError] =
  ## The header set a dependency probe reported, EXCLUDING the compiled
  ## source file itself (excluded by exact match on the known path used to
  ## derive the invocation — never guessed).
  ##
  ## `err == dpeNone` is the ONLY result whose `headers` may be trusted;
  ## every other value leaves `headers` empty and MUST reach the caller as a
  ## loud failure. Both arms can fail:
  ##
  ## - GNU: stdout must be exactly one make rule whose first prerequisite is
  ##   `sourceFile` (`parseGnuDepRule`). A replay that printed nothing (the
  ##   rule went to a `.d` file), preprocessed source, or a macro dump is
  ##   `dpeNoMakeRule`; a rule for another source is `dpeSourceMismatch`.
  ## - MSVC: the `/sourceDependencies` document must be present and well
  ##   formed (`dpeNoJson`/`dpeBadJson`/`dpeNoIncludes`), and its own
  ##   `Data.Source`, when present, must name `sourceFile`
  ##   (`msvcSourceMatches`) -- otherwise `dpeSourceMismatch`, a stale or
  ##   misattributed document.
  ##
  ## cl's `Includes` never lists the translation unit itself, so the
  ## source-exclusion filter is belt-and-braces on that arm; it is applied
  ## to both so the two arms cannot disagree about what a header set
  ## contains.
  ##
  ## `headers` is `seq[ReportedPath]`, not `seq[string]`: every element
  ## came out of a foreign tool's dependency report and must be
  ## resolved (`paths.classify`/`tracked`'s `ReportedPath` overload) before
  ## it becomes cache-key material. `p != sourceFile` and `p.len > 0` are
  ## `ReportedPath`'s two deliberately-exposed, identity-safe operations
  ## (see that type's own doc comment) — neither reads or leaks `sourceFile`
  ## as anything but a known, TRUSTED comparison text.
  let reported =
    case family
    of ccfGnu:
      parseGnuDepRule(depOutput, sourceFile)
    of ccfMsvc:
      let parsed = parseMsvcSourceDeps(depOutput)
      if parsed.err != dpeNone:
        (deps: newSeq[ReportedPath](), err: parsed.err)
      elif parsed.source.len > 0 and
           not msvcSourceMatches(sourceFile, parsed.source):
        (deps: newSeq[ReportedPath](), err: dpeSourceMismatch)
      else:
        (deps: parsed.includes, err: dpeNone)
  if reported.err != dpeNone:
    return (headers: newSeq[ReportedPath](), err: reported.err)
  var hs: seq[ReportedPath] = @[]
  for p in reported.deps:
    if p.len > 0 and p != sourceFile:
      hs.add p
  (headers: hs, err: dpeNone)

proc reportedHeaderUnresolved*(family: CcFamily; reported: ReportedPath;
                               pc: PathClass; roots: TrackedRoots): bool =
  ## True iff `reported` -- one header out of `depIncludeHeaders`, already
  ## classified to `pc` via `classify`'s `ReportedPath` overload -- cannot be
  ## given a sound identity, so the dependency probe as a whole must fail
  ## rather than drop the header (`pcOutside` excludes it from impact
  ## selection) or keep an unresolved spelling (which on a case-sensitive
  ## volume names no file, so its content never changes).
  ##
  ## - Any family: `pcOutside` although the spelling lies under a
  ##   case-FOLDING root once case is disregarded. On such a volume the
  ##   header IS that root's file; resolution to its real spelling failed.
  ## - MSVC: any spelling under a case-SENSITIVE root once case is
  ##   disregarded, tracked or not. `cl /sourceDependencies` lowercases every
  ##   path, non-ASCII letters included (measured, cl 19.44:
  ##   `Inc\MyHeader.h` -> `...\inc\myheader.h`, `C:\poc\Ärger` ->
  ##   `c:\poc\ärger`), and on a case-sensitive root two casings are two
  ##   files, so the report does not say which file was included.
  ##
  ## "Case disregarded" is `paths.caseBlindRootMembership`: Unicode simple
  ## case folding, whose limits (no `ß`/`ss`, no Turkic `i`, no
  ## normalization) its helper `underRootCaseBlind` documents.
  ##
  ## A GNU spelling under a case-sensitive root is exactly the spelling the
  ## compiler opened; if it lies outside every root it is a different
  ## directory, and staying excluded is correct.
  let m = caseBlindRootMembership(reported, roots)
  if pc.kind == pcOutside and m.underFoldingRoot:
    return true
  case family
  of ccfMsvc: m.underCaseSensitiveRoot
  of ccfGnu: false
