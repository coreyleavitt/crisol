## headerprobe.nim -- run one compile unit's dependency probe and classify
## every header it reports.
##
## The one pipeline both header consumers share: `closure.extractCompileInputs`
## (impact selection) and `artifactid.ccIncludeClosure` (artifact identity).
## Each step is `crisol/ccprobe`'s:
##
##   derive (`deriveDepInvocation`) -> run (the caller's `RunProc`) ->
##   parse (`depIncludeHeaders`) -> classify each header (`paths.classify`,
##   `ReportedPath` overload) -> refuse any header whose identity cannot be
##   established (`reportedHeaderUnresolved`).
##
## Every failure comes back as a `HeaderProbe` with `ok = false`, a
## `HeaderProbeFailure` saying which step failed, the parser's own
## `DepProbeError` when the parse was the step, and one message naming the
## probe (`cc -M` or `/sourceDependencies`), the probed source and, when the
## driver ran, what it said on stderr. What differs between the two callers
## is only what they do with a successful probe's headers: closure keeps
## the tracked ones and drops the rest; artifactid keeps every one.
##
## Kept apart from `ccprobe` so that module stays pure: this one spawns the
## probe (through the injected `RunProc`) and may touch the disk (through
## `classify`'s `CandidateExpander`, and `siteResolver`'s driver search).
## Imports only `ccprobe`, `paths` and `toolrun`, none of which import it
## back.

import std/[os, strutils, tables]
import crisol/ccprobe
import crisol/paths
import crisol/toolrun

type
  HeaderProbeFailure* = enum
    ## Which step of the pipeline refused.
    hpfDerivation     ## no probe invocation could be derived from the
                      ## command (`parseCompileCommand` returned `none`)
    hpfRun            ## the probe did not run to a successful exit
    hpfReport         ## the probe ran; its report is unusable (`depErr`)
    hpfUnresolvedHeader ## a reported header lies under a tracked root, but
                      ## its real spelling is unknown
                      ## (`ccprobe.reportedHeaderUnresolved`)
    hpfDriverUnresolved ## the build's nim would not find the command's
                      ## driver (`DriverLocation.found` false): the probe
                      ## cannot run the compiler the build ran (R10-S6)
    hpfRootsUnpopulated ## a header was reported but `roots` is the
                      ## unpopulated zero value (`paths.populated` false):
                      ## every production caller's is populated, so this is
                      ## a caller defect, never an environmental one (R15-D6)
                      ## -- refused rather than classified against roots
                      ## that cannot say what is tracked, and never returned
                      ## as a distinct "unclassified" success the way this
                      ## pipeline once did

  ProbedHeader* = object
    ## One header out of a successful probe, as reported and as classified.
    reported*: ReportedPath    ## the compiler's own spelling
    pc*: PathClass             ## `classify(reported, roots, expandCandidate)`

  HeaderProbe* = object
    ## The outcome of `probeReportedHeaders`. R15-D6: an `ok` probe is always
    ## classified -- `headers` carries every reported header, classified
    ## against `roots`, unconditionally. There is no separate "unclassified"
    ## success any more: that state existed only to let a test skip building
    ## a real `TrackedRoots`, `closure.extractCompileInputs` already treated
    ## it as unreachable and fatal, and `artifactid.ccIncludeClosure` treated
    ## it as a legitimate (if soundness-weaker) result -- two consumers of
    ## one shared type disagreeing about what its own state means. A caller
    ## with a reported header and unpopulated roots now gets the SAME answer
    ## either way: `ok = false`, `hpfRootsUnpopulated` (see
    ## `probeReportedHeaders`). A test that wants headers without a real,
    ## disk-backed `TrackedRoots` uses `paths.initTrackedRoots` with a
    ## project path that simply matches nothing in the fixture, exactly as
    ## `test_headerprobe.nim`'s own "populated roots" suite already does --
    ## the real classification path, not a bypass of it.
    case ok*: bool
    of true:
      family*: CcFamily            ## which probe ran
      headers*: seq[ProbedHeader]  ## every header reported, in report
                                   ## order, the source itself excluded,
                                   ## classified against `roots`
    of false:
      failure*: HeaderProbeFailure
      depErr*: DepProbeError       ## the parser's verdict for `hpfReport`;
                                   ## `dpeNone` for every other failure
      message*: string             ## names the probe, the source and why

proc probeName*(family: CcFamily): string =
  ## The probe a family runs, as messages name it.
  case family
  of ccfGnu: "cc -M"
  of ccfMsvc: "/sourceDependencies"

proc failed(failure: HeaderProbeFailure; depErr: DepProbeError;
            message: string): HeaderProbe =
  HeaderProbe(ok: false, failure: failure, depErr: depErr, message: message)

proc realDriverStop*(path: string; rules: DriverSearch): bool =
  ## Whether the search `rules` describes stops at `path` on the real
  ## filesystem: the `ccprobe.DriverStop` question `locateDriver` asks
  ## (R15-D7: one name -- `driverStop` -- for this question everywhere it is
  ## asked, this being the real answer to it).
  ##
  ## - `dsPosix`: a regular file (a symlink followed) with an execute bit.
  ##   `execvp` moves on past an entry whose `execve` fails with
  ##   EACCES (a directory, or a file without the execute bit) and runs a
  ##   later copy, so the search must too (R13-S4); stopping there would
  ##   probe a file nim never runs, and refuse. On a host without POSIX
  ##   permissions (a `dsPosix` site read on Windows) a regular file is
  ##   the answer.
  ## - `dsWindows`: a file or directory, readable or not, as before:
  ##   `CreateProcess` stops at the first name that exists.
  case rules
  of dsWindows:
    fileExists(path) or dirExists(path)
  of dsPosix:
    # Portable stdlib only (platform APIs live under `crisol/process`):
    # any execute bit stands in for `access(X_OK)`, exact for root and for
    # the usual 0755 compiler. A file only another user may execute is
    # passed over by execvp but stopped at here; the probe then fails and
    # refuses, never runs another compiler.
    try:
      let info = getFileInfo(path, followSymlink = true)
      when defined(posix):
        info.kind == pcFile and
          (info.permissions * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0
      else:
        info.kind == pcFile
    except OSError:
      false

proc siteResolver*(site: DriverSite; driverStop: DriverStop): DriverResolver =
  ## Each driver token resolved against `site` (`ccprobe.locateDriver`),
  ## once per token for the resolver's life (a run, `runner.execute`, or a
  ## measure worker), asking `driverStop` whether the search stops at a
  ## path. An unknown site answers every token with its reason. A found
  ## driver is an absolute path, a relative PATH entry resolved against
  ## nim's cwd (R11-S3), so the probe runs the same file from whatever cwd
  ## its `RunProc` gives it. Tests pass a fake filesystem here; production
  ## uses the one-argument overload.
  var memo = initTable[string, DriverLocation]()
  result = proc(driver: string): DriverLocation =
    if driver notin memo:
      memo[driver] = locateDriver(driver, site, driverStop)
    memo[driver]

proc siteResolver*(site: DriverSite): DriverResolver =
  ## The production resolver: `siteResolver` over the real filesystem,
  ## held to the site's own search rule (`realDriverStop`).
  let rules = if site.known: site.search else: dsPosix   # unread when unknown
  siteResolver(site, proc(path: string): bool = realDriverStop(path, rules))

proc probeReportedHeaders*(ccCmd: string; driver: DriverResolver; run: RunProc;
                           roots: TrackedRoots;
                           expandCandidate: CandidateExpander): HeaderProbe =
  ## Derive, run and parse the dependency probe for `ccCmd`, then classify
  ## every reported header against `roots` (resolving a non-canonical
  ## spelling through `expandCandidate`, `classify`'s own seam). Never
  ## raises; every refusal is a `HeaderProbe` with `ok = false`.
  ##
  ## A header whose identity cannot be established refuses the whole probe
  ## (`hpfUnresolvedHeader`) rather than being dropped or kept under a
  ## spelling that names no file: see `ccprobe.reportedHeaderUnresolved`.
  ##
  ## A relative reported header is classified against the project root
  ## (`paths.nativeCanonicalize` joins it to `roots.project`), which is the
  ## directory the probe must run in for that to mean the same file: the
  ## caller's `run` supplies the cwd.
  ##
  ## R15-D6: a reported header needs `roots` populated (`paths.populated`) to
  ## be classified at all -- an unpopulated `roots` cannot say what is
  ## tracked, so running `classify` against it anyway would answer from a
  ## degenerate root rather than refusing, which is the wrong failure mode
  ## for a soundness-sensitive pipeline. Every production caller's `roots`
  ## is populated; a probe that reports a header with `roots` unpopulated
  ## refuses (`hpfRootsUnpopulated`) rather than returning it unclassified.
  ## A probe with NO headers reported (the source only) never reaches this
  ## question and always succeeds, `roots` or no.
  ##
  ## The probe runs the file `driver` answers for the command's own driver
  ## token: where the build's nim finds that driver (`siteResolver`,
  ## `ccprobe.locateDriver`), never the bare token looked up by `run`'s own
  ## search order, which on Windows (nim's directory first) or with an
  ## empty PATH entry can find a different compiler than the one that
  ## built the unit, and its headers would then be another compiler's
  ## (R10-S6). Each command's token is resolved on its own: Nim compiles a
  ## `{.compile.}`d `.cpp` with the C++ driver (`g++`, `clang++`) beside a
  ## `gcc` or `clang` C compiler. A token the build's nim would not find
  ## refuses with `hpfDriverUnresolved` before anything runs.
  let inv = deriveDepInvocation(ccCmd)
  if not inv.ok:
    return failed(hpfDerivation, dpeNone,
      "could not derive a dependency probe from the compile command " &
      "(an unterminated quote, too few tokens, or an output or dependency " &
      "flag without its argument): '" & ccCmd & "'")
  let name = probeName(inv.family)
  let located = driver(inv.cmd)
  if not located.found:
    return failed(hpfDriverUnresolved, dpeNone,
      name & " probe of '" & inv.sourceFile & "' cannot run: the compile " &
      "command's driver '" & inv.cmd & "' was not resolved to the file " &
      "the build ran (" & located.why & ")")
  let r = run(located.path, inv.args)
  # The driver's stderr is the only signal that explains a failed probe, or
  # one that exits 0 with no usable report (an old `cl` answers
  # `/sourceDependencies` with a bare banner on stdout and a D9002 on
  # stderr). A run that did not finish has no stderr to offer; `describe`
  # says why instead.
  let said = block:
    let diag = if r.ending == reExited: r.errOutput.strip() else: ""
    if diag.len > 0: " -- driver said: " & diag else: ""
  if not r.ok:
    return failed(hpfRun, dpeNone,
      name & " probe of '" & inv.sourceFile & "' failed to run (command: " &
      located.path & "; " & r.describe & ")" & said)
  let parsed = depIncludeHeaders(inv.family, r.output, inv.sourceFile)
  case parsed.err
  of dpeNone:
    discard
  of dpeSourceMismatch:
    return failed(hpfReport, parsed.err,
      name & " probe of '" & inv.sourceFile & "' returned a report for a " &
      "DIFFERENT translation unit (a stale or misattributed report; " &
      $parsed.err & "; driver: " & inv.cmd & ")" & said)
  of dpeNoJson, dpeBadJson, dpeNoIncludes, dpeNoMakeRule:
    return failed(hpfReport, parsed.err,
      name & " probe of '" & inv.sourceFile & "' produced no usable " &
      "dependency report (" & $parsed.err & "; driver: " & inv.cmd & ")" &
      said)
  if parsed.headers.len > 0 and not populated(roots):
    # R15-D6: nothing to classify against -- refuse rather than hand back
    # a header set nothing was checked against (see the doc above).
    return failed(hpfRootsUnpopulated, dpeNone,
      name & " probe of '" & inv.sourceFile & "' reported " &
      $parsed.headers.len & " header(s), but the tracked roots are " &
      "unresolved: nothing can say which are tracked")
  var headers: seq[ProbedHeader]
  for h in parsed.headers:
    let pc = classify(h, roots, expandCandidate)
    if reportedHeaderUnresolved(inv.family, h, pc, roots):
      return failed(hpfUnresolvedHeader, dpeNone,
        name & " probe of '" & inv.sourceFile & "' reported '" & string(h) &
        "', which lies under a tracked root but cannot be resolved to its " &
        "real on-disk spelling (driver: " & inv.cmd & ")")
    headers.add ProbedHeader(reported: h, pc: pc)
  HeaderProbe(ok: true, family: inv.family, headers: headers)
