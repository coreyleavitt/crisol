## gitdiff.nim — D5: changed-file extraction for impact selection.
##
## `changedFiles` calls git directly (via `toolexec.runTool` with an
## explicit `args` sequence and `workingDir = projectRoot`) to produce the
## set of project-root-relative `TrackedPath`s that differ from a reference.
## It is the I/O bridge that feeds `narrow.narrowByDiff`, which selects the
## entrypoints the changed set reaches (`depgraph.diffReach`) and those whose
## recorded closure no longer matches the file system (rule 4,
## `depgraph.entryDrift`, which reads it).
##
## ## Git commands
##
## First, a repo probe (so a clear cekEnvironment error replaces git's own
## terse diagnostics):
##   `git rev-parse --is-inside-work-tree`
##
## Then the diff base, resolved to a commit (R11-S2: an unresolvable base
## that names a path would otherwise be read as a pathspec, and diff to
## nothing):
##   `git rev-parse --verify --end-of-options <base or HEAD>^{commit}`
##
## Then the diff, NUL-separated (`-z`):
##   - No base → `git diff -z --raw --no-abbrev --no-renames --relative
##       --ignore-submodules=none <HEAD's commit> --`
##       (all tracked modifications, staged + unstaged, vs the last commit)
##   - With base → the same against `<base>`'s commit
##       (working tree vs <base> — deliberately includes uncommitted edits;
##        over-selection is safe, under-selection is not)
##   `--raw` carries each path's modes, which `nameVerdict` reads (a
##   gitlink on both sides is a submodule to ask what changed inside it).
##
## Then the untracked-file scan, NUL-separated (M14 -- `git diff` cannot see
## a new, not-yet-added file):
##   `git ls-files -z --others --exclude-standard`
##
## Then the index's gitlinks, in the project and in each checked-out
## submodule (R13-S3, "Submodules" below):
##   `git ls-files -z --stage`
##
## `--no-renames` is always present so a rename surfaces as delete + add.
## `--relative` makes git emit paths relative to the cwd (projectRoot), which
## is exactly the key shape the dep graph stores. `-z` NUL-terminates each
## name with NO per-name quoting — without it, git's default `core.quotepath`
## C-style-quotes and octal-escapes any "unusual" byte (including plain
## non-ASCII UTF-8), corrupting the recovered name. Output is split on `'\0'`
## (never `splitLines`, which would also mis-split a name containing an
## embedded newline — impossible to produce from quoted output but exactly
## the kind of name `-z` output makes representable).
##
## ## Submodules (R10-S5)
##
## git names a changed submodule by its gitlink path alone (`vendor/lib`),
## never the files inside it, and `ls-files --others` names an untracked
## nested repository as a directory (`sub/`) and a new file inside a
## submodule not at all. `--ignore-submodules=none` makes the diff name every
## submodule whose commit moved or whose work tree is dirty (untracked
## content included) whatever `diff.ignoreSubmodules` or `.gitmodules` say,
## and a name that is a real directory with no base to diff against (a new
## submodule, an untracked nested repository) is added by its name alone
## ("Directories" below).
##
## A submodule present on both sides of the diff is asked, through its own
## git, what changed inside it against the commit the base records for it
## (`expandSubmodule`), and only those names count (R12-D2): editing one
## file inside it selects only the tests that read that file. Its own
## gitlink path is not added (R13-L4): a changed name above a member or a
## recorded link selects the entry (`depgraph.diffReach`: `hkAncestor`,
## `hkLink`), so the gitlink name would select every test under the
## submodule whatever changed inside it. A checked-out submodule whose
## recorded commit is not available locally refuses: nothing else can list
## what changed inside it.
##
## A gitlink whose directory holds content but no `.git` entry (R13-S3: the
## entry was removed, or the directory was copied in) is unchanged to git,
## which has no repository to ask, and `ls-files --others` lists nothing
## under a gitlink path. Every gitlink in the index is therefore read
## (`addStrandedGitlinks`): such a directory has no base, so its name is
## added like any other directory's, whether or not the diff names it. An
## uninitialised submodule (an empty directory) adds nothing, whether or not
## the diff names it (R15-D1): a test cannot read anything there now, and an
## entry that recorded a member there is stale on its own
## (`depgraph.entryDrift`, `dkMissing`, narrow rule 4). `nameVerdict` makes
## both decisions, for the diff and for the index.
##
## ## Directories (R14-D8)
##
## A changed name that is a directory as a whole (a new submodule, an
## untracked nested repository, a tracked link replaced by a directory, a
## stranded gitlink) is added by its name alone; the files under it are not
## listed. `depgraph.diffReach` selects every entry with a closure member
## (`hkAncestor`) or a recorded link (`hkLink`) under a changed name, and a
## closure always holds the entrypoint itself, so the name reaches every
## entry a file listing would. Every name here is reduced against the
## project root, and so are closure members: `paths.classify` tags any path
## under the project directory to the project root even when it also lies
## under a configured dependency root nested there, so `ancestorsOrSelf`
## never stops at a nested root's boundary before it reaches the changed
## name. A member tagged to a dependency root lies outside the project
## directory, where no project diff name reaches it either way (the
## tracked-roots boundary). The walk this replaced also refused `--changed`
## whenever a subdirectory could not be listed.
##
## ## Links (R12-D1)
##
## A changed name that is a link, was one at the base, or lies above or
## under one, is added like any other name and never followed:
## `narrow.narrowByDiff` selects every dependency-graph entry that recorded
## a link the changed set names (`depgraph.diffReach`, `hkLink`/`hkUnderLink`),
## or has a member under the name (`hkAncestor`). `nameVerdict`'s doc comment
## walks through why no link shape needs a refusal.
##
## ## Reduction to TrackedPath
##
## Each NUL-separated name git emits is reduced via `fromCanonical` (RFC-0009
## A1): git's `--relative --name-only` output is already the canonical,
## forward-slash, project-root-relative shape `fromCanonical` expects, so
## this succeeds for every name git can actually emit. See `reduceChangedName`
## below for the defensive fallback and its documented residual gap.
##
## ## Errors
##
## If `projectRoot` is not an existing directory, or git is missing, or the
## directory is not a git work tree, or ANY git invocation (the project's
## five, two per changed submodule, and one per checked-out submodule) does
## not finish cleanly (could not
## start, timed out, overflowed, I/O error, or a non-zero exit; one
## `requireGit` holds every one to that), or the diff base does not resolve
## to a commit, or what changed inside a checked-out submodule cannot be
## listed in full, a `CrisolError(cekEnvironment, …)` is raised. None of
## them is best-effort: each one's output is part of the changed set, and a partial
## changed set under-selects.  The CLI maps that to exit 3, consistent with every other
## environment failure.

import std/[options, os, osproc, sequtils, sets, strutils]  # process-contract-exempt: git is a short-lived tool invocation, not a compile/run child (RFC-0007 §Scope)
import crisol/[toolexec, types]

const
  GitToolTimeoutMs* = 10_000
    ## CR4: bound on one `git` invocation (`rev-parse`, `diff`, or
    ## `ls-files`) — `changedFiles` runs in the host process during
    ## plan-building, outside RFC-0007's Supervisor and its
    ## `compileTimeoutMs`/tree-kill, so nothing else stops a `git` blocked on
    ## an SSH/credential prompt or a hook from hanging the whole invocation.
    ##
    ## Generous relative to the actual cost: `rev-parse`/`diff`/`ls-files`
    ## are all local-metadata reads that complete in well under a second on a
    ## normal work tree (same order of magnitude as `ccidentity`'s measured
    ## probe cost — see `toolrun.ToolProbeTimeoutMs`), so a legitimately
    ## large repo is never at risk while a genuinely wedged `git` is bounded
    ## to single-digit seconds and surfaces as a clear `CrisolError` instead
    ## of a hang.

# ---------------------------------------------------------------------------
# Internal helper: run git without a shell
# ---------------------------------------------------------------------------

proc requireGit(args: openArray[string]; workingDir, what, risk: string): string =
  ## Run `git <args>` in `workingDir` and return its stdout, or raise
  ## `CrisolError(cekEnvironment, …)` naming `what` (the command, for the
  ## message) and `risk` (what an answer-less run would have cost; "" when
  ## the message says enough) unless git ran to an exit with code 0. Every
  ## git call `changedFiles` makes goes through here: each one's output is
  ## part of the changed set, so none is best-effort.
  ##
  ## No shell intermediary (`poUsePath` finds `git` via PATH), bounded by
  ## `GitToolTimeoutMs`, stdin closed at once. stderr is captured SEPARATELY
  ## and never merged: git writes diagnostics there (on Windows with
  ## `core.autocrlf`, one "LF will be replaced by CRLF" warning per file),
  ## and merged into stdout a warning line would be parsed as a changed-file
  ## NAME. stdout carries the NUL-separated names only; stderr is surfaced
  ## only in error messages. Both pipes are drained concurrently
  ## (`toolexec.runTool`): that per-file warning runs far past the pipe
  ## budget on a large checkout.
  let r = runTool("git", args, workingDir, {poUsePath}, "", GitToolTimeoutMs,
                  MaxToolOutputBytes)
  let tail = if risk.len > 0: " -- " & risk else: ""
  case r.ending
  of reExited:
    if r.exitCode != 0:
      raise newCrisolError(cekEnvironment,
        what & " exited with code " & $r.exitCode & ": " &
        r.errOutput.strip() & tail)
    r.output
  of reNotStarted:
    raise newCrisolError(cekEnvironment,
      "git is not available (could not execute 'git'): " & r.detail & tail)
  of reTimedOut:
    # Names the likely cause (a credential/SSH prompt or a hook). The
    # message ENDS with the fixed `[git timeout]` marker, so the path is
    # identifiable from its tail whatever `workingDir`'s length.
    raise newCrisolError(cekEnvironment,
      what & " did not respond within " & $GitToolTimeoutMs & "ms (" &
      r.detail & "; it may be blocked on a credential/SSH prompt or a " &
      "hook)" & tail & " [git timeout]")
  of reIoError, reOverflow, reInterrupted:
    # An interrupted git is refused like any run that did not finish; the
    # CLI's exit code (130/143) comes from the scope's signal, not from here.
    raise newCrisolError(cekEnvironment,
      what & " did not finish: " & r.detail & tail)

proc splitNul(output: string): seq[string] =
  ## Splits `-z` git output on NUL, dropping empty fragments (a trailing NUL
  ## after the last name yields one trailing empty split; an entirely empty
  ## `output` yields none). Deliberately does NOT `strip()` each name — `-z`
  ## output carries the exact bytes git recorded, and a name may legitimately
  ## have leading/trailing whitespace.
  for piece in output.split('\0'):
    if piece.len > 0:
      result.add piece

# ---------------------------------------------------------------------------
# Internal helper: reduce one git-emitted name to a TrackedPath
# ---------------------------------------------------------------------------

proc reduceChangedName(name: string; roots: TrackedRoots): Option[TrackedPath] =
  ## Reduces one git-emitted, project-root-relative name to a `TrackedPath`.
  ##
  ## PRIMARY: `fromCanonical` — git's `--relative --name-only -z` output is
  ## already exactly the canonical, forward-slash, project-relative shape
  ## `fromCanonical` expects (never absolute, never `.`/`..`, never a
  ## doubled/leading/trailing separator), so this succeeds for every name
  ## git can actually emit under normal operation.
  ##
  ## DEFENSIVE FALLBACK: `fromCanonical` REJECTS a handful of shapes that
  ## git's own `--relative` contract should never produce from
  ## `projectRoot` — but "should never" is not "cannot", and silently
  ## dropping a real diffed file would be an under-selection (a soundness
  ## bug), whereas over-selecting is merely wasteful. `classify` is TOTAL
  ## and, unlike `fromCanonical`, actively LEXICALLY RESOLVES dot segments
  ## and redundant separators against `roots.project.abs` rather than
  ## rejecting them — so it recovers a valid `TrackedPath` for every one of
  ## `fromCanonical`'s defensive rejections that is still genuinely under a
  ## tracked root, which, per "should never" above, is every real case.
  ##
  ## RESIDUAL GAP (documented, not silently swept): a name that resolves
  ## OUTSIDE every tracked root even after `classify`'s lexical resolution
  ## is unreachable from git's own `--relative` output (that would require
  ## the diff naming a path that climbs above `projectRoot` via `..`
  ## segments, which `git diff --relative` never emits) — there is no
  ## `TrackedPath` to construct for a path outside every tracked root by
  ## definition, so this one case returns `none` and the name is dropped.
  let fc = fromCanonical(name, roots)
  if fc.isSome: return fc
  let pc = classify(name, roots)
  case pc.kind
  of pcTracked: some(pc.tp)
  of pcOutside: none(TrackedPath)

# ---------------------------------------------------------------------------
# Internal helper: what one changed name contributes (R12-D1, R12-D2)
# ---------------------------------------------------------------------------

const
  GitGitlinkMode = "160000"
    ## git's tree/index mode for a submodule's gitlink.

type
  PathState* = enum
    ## What a changed name or an index gitlink is on disk now: the one
    ## classifier `nameVerdict` reads (R15-D1). A link is a link whatever
    ## it leads to, and is never followed.
    psAbsent     ## nothing there (deleted)
    psFile       ## a regular file
    psLink       ## a link, to anything or to nothing
    psEmpty      ## an empty real directory: at a gitlink, an uninitialised
                 ## submodule (`deinit`, a clone without `--recursive`)
    psStranded   ## a real directory with content and no `.git` entry: at a
                 ## gitlink, a submodule whose `.git` entry was removed or
                 ## that was copied in (R13-S3)
    psRepo       ## a real directory holding a `.git` entry: a checked-out
                 ## submodule, or a nested repository

  NameVerdict* = enum
    ## What one name contributes to the changed set: the whole decision,
    ## which `addChanged` and `addStrandedGitlinks` only carry out. The zero
    ## value adds the name, which can only over-select.
    vAddName     ## the name itself joins the changed set
    vExpand      ## ask the submodule's own repository: what changed inside
                 ## it (a name the diff reports, `expandSubmodule`), or its
                 ## own gitlinks (the index walk, `addStrandedGitlinks`)
    vNothing     ## contributes nothing

proc nameVerdict*(gitlink: bool; state: PathState): NameVerdict =
  ## PURE: the one decision about a name, for the diff and for the index
  ## walk alike (R15-D1). `gitlink` is true for a name the diff reports as a
  ## gitlink on both sides (`:160000 160000`) and for every gitlink the
  ## index walk reads; `state` is what the name is on disk now. Whether the
  ## diff named a gitlink does not change its verdict: the diff names one
  ## whose recorded commit moved since the base, and the walk reads it
  ## again either way.
  ##
  ## A gitlink:
  ##   * `psRepo`: expanded to its own precise records, without its own name
  ##     (R12-D2, R13-L4): a name above a member selects every entry under
  ##     it (`hkAncestor`), which would undo that precision. When its
  ##     recorded commit is not available locally, its own git cannot say
  ##     what changed, and `expandSubmodule` refuses: the one case nothing
  ##     can list.
  ##   * `psStranded`: its name. It has no repository to ask and no base to
  ##     diff against, like an untracked nested repository, so its name
  ##     alone selects every entry with a member or a recorded link under it
  ##     (`hkAncestor`, `hkLink`). The cost is over-selecting the tests that
  ##     read it, on every `--changed` run until the checkout is repaired.
  ##   * `psEmpty`: nothing. A test cannot read anything there now, and an
  ##     entry that recorded a member there, or a link there, is stale on its
  ##     own (`depgraph.entryDrift`: `dkMissing`, `dkMoved`; narrow rule 4).
  ##     Refusing would break `--changed` for every clone with an
  ##     uninitialised submodule, and `--base` in every clone where one was
  ##     bumped since the base.
  ##   * `psAbsent`, `psLink`, `psFile`: its name. git's own diff names such
  ##     a path by its gitlink path as a deletion or a type change
  ##     (`:160000 120000 T`), and a member may still be readable at its
  ##     recorded path through a new link; `hkAncestor` reaches it (R13-S1).
  ##
  ## Any other name is its name alone. Links (R12-D1) are never refused and
  ## never followed. Each dependency-graph entry records the links its
  ## closure was reached through (issue #25), and `narrow.narrowByDiff`
  ## selects every entry a changed name reaches through one
  ## (`depgraph.diffReach`, `hkLink`/`hkUnderLink`) or has a member under
  ## (`hkAncestor`), so the name alone is enough:
  ##   • a link repointed, deleted, or replaced by a file or a real
  ##     directory (base mode 120000): an entry reached through it recorded
  ##     it at this path;
  ##   • a tracked real directory replaced by a link: the diff names the
  ##     files the old directory held, which are closure members, at their
  ##     own paths. A link made in place of a directory with no diff at all
  ##     (a junction on Windows, which git reads as a directory) makes the
  ##     entry stale instead (`depgraph.entryDrift`, `dkUnrecorded`);
  ##   • a link new since the base: an entry recorded while it existed
  ##     recorded it here; an entry recorded without it was not reached
  ##     through it. A new link can still redirect an import that resolved
  ##     elsewhere (a `--path` search order), exactly as a new file at that
  ##     spelling can; the closure does not model search-path shadowing for
  ##     either;
  ##   • a link inside crisol's state dir: the index walk never records one
  ##     there (`closure.walkForIndex` argues why no import can depend on
  ##     one), so the name selects nothing and needs nothing.
  ## An entry recorded before links were recorded cannot exist: format 10
  ## (`DepGraphFormatVersion`) discards every older graph.
  ##
  ## A file, a deleted name, a submodule new or removed since the base, an
  ## untracked nested repository (`ls-files --others` names it `sub/`): a
  ## directory with no base to diff against has changed as a whole, and its
  ## name selects every entry with a member or a recorded link under it
  ## (`hkAncestor`, `hkLink`), so the files under it are not listed (R14-D8,
  ## "Directories" in the module doc).
  if not gitlink: return vAddName
  case state
  of psRepo: vExpand
  of psEmpty: vNothing
  of psStranded, psAbsent, psLink, psFile: vAddName

proc hasGitEntry(dir: string): bool =
  ## True when `dir` holds a `.git` entry: a repository of its own (a
  ## checked-out submodule's gitdir pointer, or a nested repository).
  fileExists(dir / ".git") or dirExists(dir / ".git")

proc pathStateOf(native: string): PathState =
  ## The `PathState` of `native` on disk now. A directory that cannot be
  ## listed counts as having content: adding its name only over-selects.
  if symlinkExists(native): return psLink
  if fileExists(native): return psFile
  if not dirExists(native): return psAbsent
  if hasGitEntry(native): return psRepo
  try:
    for _ in walkDir(native, checkDir = true): return psStranded
  except OSError:
    return psStranded
  psEmpty

type DiffRec = object
  ## One changed path from `git diff --raw -z --no-renames --no-abbrev`, or
  ## from `git ls-files --others` (no modes: `oldMode` and `newMode` "").
  name, oldMode, newMode, oldSha: string

proc parseRawDiff(output: string): seq[DiffRec] =
  ## Parses `git diff --raw -z --no-renames` output: per changed path, a
  ## `:<old mode> <new mode> <old sha> <new sha> <status>` header, then the
  ## path, each NUL-terminated. Anything else raises
  ## `CrisolError(cekEnvironment, …)`: a record it cannot read is a name it
  ## would drop.
  let pieces = splitNul(output)
  var i = 0
  while i < pieces.len:
    let header = pieces[i]
    let fields = header.splitWhitespace()
    if header.len == 0 or header[0] != ':' or fields.len < 5 or
        i + 1 >= pieces.len:
      raise newCrisolError(cekEnvironment,
        "refusing --changed: unexpected 'git diff --raw' record '" & header &
        "', so the changed set may be incomplete")
    result.add DiffRec(name: pieces[i + 1], oldMode: fields[0][1 .. ^1],
                       newMode: fields[1], oldSha: fields[2])
    i += 2

proc untrackedRecs(output: string): seq[DiffRec] =
  ## `git ls-files -z --others` names as mode-less records.
  for name in splitNul(output):
    result.add DiffRec(name: name)

proc addChanged(changed: var HashSet[TrackedPath]; rec: DiffRec;
                prefix, projectRoot: string; roots: TrackedRoots)

proc expandSubmodule(changed: var HashSet[TrackedPath]; sub, recorded,
                     projectRoot: string; roots: TrackedRoots) =
  ## A checked-out submodule `sub` (project-relative) whose recorded commit
  ## at the diff base is `recorded`. Its own git lists what changed inside
  ## it -- its work tree against `recorded`, plus its untracked files -- and
  ## ONLY those names count (R12-D2), each through `addChanged` under the
  ## same rules as the project's own, nested submodules included. A file it
  ## no longer has is named by that diff as deleted.
  ##
  ## A recorded commit that is not available locally makes git exit
  ## non-zero: `CrisolError(cekEnvironment, …)`, since nothing else can say
  ## what changed inside it.
  let subDir = projectRoot / sub
  let risk = "refusing --changed: what changed inside submodule '" & sub &
             "' cannot be listed (is its recorded commit " & recorded &
             " available locally?)"
  let diffOut = requireGit(
    ["diff", "-z", "--raw", "--no-abbrev", "--no-renames",
     "--ignore-submodules=none", recorded, "--"],
    subDir, "git diff in submodule '" & sub & "'", risk)
  let untrackedOut = requireGit(
    ["ls-files", "-z", "--others", "--exclude-standard"], subDir,
    "git ls-files --others in submodule '" & sub & "'", risk)
  for rec in parseRawDiff(diffOut):
    addChanged(changed, rec, sub & "/", projectRoot, roots)
  for rec in untrackedRecs(untrackedOut):
    addChanged(changed, rec, sub & "/", projectRoot, roots)

proc addChanged(changed: var HashSet[TrackedPath]; rec: DiffRec;
                prefix, projectRoot: string; roots: TrackedRoots) =
  ## Add one git-emitted name (`prefix & rec.name`, project-relative; the
  ## prefix is a submodule's path when its own git emitted the name) to
  ## `changed`, as `nameVerdict` decides. The file-system read is here;
  ## the decision is not.
  var trimmed = prefix & rec.name
  while trimmed.len > 1 and trimmed[^1] == '/': trimmed.setLen(trimmed.len - 1)
  let gitlink = rec.oldMode == GitGitlinkMode and rec.newMode == GitGitlinkMode
  case nameVerdict(gitlink, pathStateOf(projectRoot / trimmed))
  of vNothing: discard
  of vAddName:
    let tp = reduceChangedName(trimmed, roots)
    if tp.isSome: changed.incl tp.get
  of vExpand:
    expandSubmodule(changed, trimmed, rec.oldSha, projectRoot, roots)

# ---------------------------------------------------------------------------
# Internal helper: gitlinks with no repository behind them (R13-S3)
# ---------------------------------------------------------------------------

proc indexGitlinks(output: string): seq[string] =
  ## The paths of the gitlinks in `git ls-files -z --stage` output: per
  ## entry `<mode> <sha> <stage><TAB><path>`, NUL-terminated. A record it
  ## cannot read raises `CrisolError(cekEnvironment, …)`: it may be a
  ## gitlink it would drop.
  for rec in splitNul(output):
    let tab = rec.find('\t')
    if tab < 0:
      raise newCrisolError(cekEnvironment,
        "refusing --changed: unexpected 'git ls-files --stage' record '" &
        rec & "', so the changed set may be incomplete")
    if rec.startsWith(GitGitlinkMode & " "):
      result.add rec[tab + 1 .. ^1]

proc addStrandedGitlinks(changed: var HashSet[TrackedPath];
                         repo, projectRoot: string; roots: TrackedRoots) =
  ## Every gitlink in the index of `repo` (project-relative; "" for the
  ## project itself), and in the index of each checked-out submodule below
  ## it, as `nameVerdict` decides (R13-S3). A gitlink the diff also named
  ## gets the same verdict here, so reading it again adds nothing new. A
  ## checked-out submodule is read the same way (`vExpand`): a stranded
  ## gitlink nested inside it is just as invisible to its diff, and to the
  ## project's, since the outer submodule's work tree is clean to git as
  ## well. One `git ls-files --stage` per repository read; its output is
  ## part of the changed set, so it is held to `requireGit`'s standard.
  ##
  ## R15-S7: a `.git` entry that is no repository (an empty `.git`
  ## directory) makes git in `repo` find the enclosing repository instead,
  ## whose index lists `repo`'s own gitlink as `./`. Descending on that
  ## name would read the same directory forever. Such a directory has no
  ## repository of its own, exactly like a stranded one, so its name is
  ## added and nothing under it is read. Any other name that is not a
  ## plain relative path refuses: it would be read at the wrong place.
  let prefix = if repo.len == 0: "" else: repo & "/"
  let where = if repo.len == 0: "" else: " in submodule '" & repo & "'"
  let output = requireGit(["ls-files", "-z", "--stage"],
    projectRoot / repo, "git ls-files --stage" & where,
    "refusing --changed: the submodules whose repository is missing " &
    "cannot be listed, so the changed set may be incomplete")
  for link in indexGitlinks(output):
    if link == "./" and repo.len > 0:
      let tp = reduceChangedName(repo, roots)
      if tp.isSome: changed.incl tp.get
      return
    # An empty segment covers "", a leading "/" and a trailing "/".
    if link.split('/').anyIt(it.len == 0 or it == "." or it == ".."):
      raise newCrisolError(cekEnvironment,
        "refusing --changed: git ls-files --stage" & where &
        " listed the gitlink '" & link & "', which is not a path under it, " &
        "so the changed set may be incomplete")
    let name = prefix & link
    case nameVerdict(gitlink = true, pathStateOf(projectRoot / name))
    of vNothing: discard
    of vAddName:
      let tp = reduceChangedName(name, roots)
      if tp.isSome: changed.incl tp.get
    of vExpand:
      addStrandedGitlinks(changed, name, projectRoot, roots)

# ---------------------------------------------------------------------------
# Public: changedFiles
# ---------------------------------------------------------------------------

proc changedFiles*(projectRoot: string; roots: TrackedRoots;
                    base: string = ""): HashSet[TrackedPath] =
  ## Return the set of `TrackedPath`s that git reports as changed, reduced
  ## through `roots` (RFC-0009 A3b-i).
  ##
  ## `base == ""` → diff working tree vs HEAD (staged + unstaged).
  ## `base != ""` → diff working tree vs the given ref.
  ##
  ## Raises `CrisolError(cekEnvironment, …)` when:
  ##   - `projectRoot` is empty or does not exist as a directory
  ##   - git is unavailable
  ##   - the directory is not a git work tree
  ##   - the base (or HEAD) does not resolve to a commit (R11-S2)
  ##   - `git diff` or `git ls-files` does not finish or exits non-zero
  ##     (fail closed: a partial changed set would under-select)
  ##   - what changed inside a checked-out submodule cannot be listed
  ##     (`expandSubmodule`: its recorded commit is not available locally)
  ##   - the index's gitlinks cannot be listed (`addStrandedGitlinks`)
  result = initHashSet[TrackedPath]()

  # Validate projectRoot before touching git so the caller gets a clear
  # message rather than an opaque shell error.
  if projectRoot.len == 0 or not dirExists(projectRoot):
    raise newCrisolError(cekEnvironment,
      "projectRoot '" & projectRoot & "' is not an existing directory — " &
      "cannot invoke git")

  # Probe: is this a git work tree?  This both confirms `git` exists and that
  # projectRoot is inside a repository, so we can give a clear message instead
  # of letting git's own diagnostics leak through.
  let inside = requireGit(["rev-parse", "--is-inside-work-tree"], projectRoot,
    "git rev-parse --is-inside-work-tree (--changed requires '" &
    projectRoot & "' to be a git work tree)", "")
  if inside.strip() != "true":
    raise newCrisolError(cekEnvironment,
      "'" & projectRoot & "' is not a git repository — " &
      "--changed requires a git work tree")

  # Build the diff argv.
  let baseRef = base.strip()
  # Reject refs that start with '-': although startProcess uses argv (no shell,
  # so no shell injection), git itself interprets a leading '-' as a flag, e.g.
  # `--output=/path` would silently redirect git's output to an attacker-chosen
  # path with the user's permissions.
  if baseRef.len > 0 and baseRef[0] == '-':
    raise newCrisolError(cekEnvironment,
      "--base: ref must not start with '-': '" & baseRef & "'")
  let diffRef = if baseRef.len == 0: "HEAD" else: baseRef
  # R11-S2: resolve the base to a commit before diffing. Given a name that
  # is no revision but IS a path (a `release/` directory and no `release`
  # ref, as in a shallow CI checkout), `git diff <name>` reads it as a
  # pathspec, diffs the work tree against the index for that path and exits
  # 0 with nothing: an empty changed set. `--end-of-options` keeps the ref
  # from ever being read as an option, and the resolved object name, with
  # `--` after it, is what the diff receives.
  let baseCommit = requireGit(
    ["rev-parse", "--verify", "--end-of-options", diffRef & "^{commit}"],
    projectRoot, "git rev-parse --verify '" & diffRef & "^{commit}'",
    "refusing --changed: the diff base '" & diffRef &
    "' does not resolve to a commit").strip()
  if baseCommit.len == 0 or not baseCommit.allCharsInSet(HexDigits):
    raise newCrisolError(cekEnvironment,
      "refusing --changed: the diff base '" & diffRef & "' resolved to '" &
      baseCommit & "', not a commit id")
  # `--ignore-submodules=none` overrides `diff.ignoreSubmodules` and any
  # `.gitmodules` `ignore =` setting: a submodule whose commit moved, or whose
  # work tree is dirty (untracked content included), is always NAMED. What
  # it names is the gitlink path, not the files inside it; `addChanged`
  # expands it. `--raw` carries each path's modes, which is how a gitlink
  # present on both sides is recognised (`nameVerdict`).
  let diffOut = requireGit(
    ["diff", "-z", "--raw", "--no-abbrev", "--no-renames", "--relative",
     "--ignore-submodules=none", baseCommit, "--"],
    projectRoot, "git diff", "")

  for rec in parseRawDiff(diffOut):
    addChanged(result, rec, "", projectRoot, roots)

  # M14 soundness: include untracked-but-not-ignored files.
  # `git diff --name-only HEAD` only reports tracked-file changes.  A newly
  # created, not-yet-`git add`-ed .nim file that a test now imports is invisible
  # to `git diff` but is still a real source dependency.  Including untracked
  # files here ensures they appear in changedFiles so the closure∩diff
  # intersection can select the right entrypoints.
  #
  # `git ls-files -z --others --exclude-standard` lists untracked files that
  # are not excluded by .gitignore, .git/info/exclude, etc., NUL-separated
  # for the same `core.quotepath` reason as the diff argv above. The output
  # is relative to the cwd (projectRoot), matching the key shape used
  # elsewhere.
  #
  # Held to the same standard as `rev-parse` and `diff` above: anything but a
  # clean exit RAISES. This scan is not best-effort -- when it does not
  # deliver a complete answer (it could not start, timed out, overflowed, hit
  # an I/O error, or git exited non-zero and so did not vouch for whatever it
  # printed), an unknown number of untracked names is missing from the
  # changed set, and `--changed` would narrow against it anyway: exactly the
  # M14 UNDER-selection this invocation exists to close. There is no "select
  # everything" fallback at this seam to degrade to, and refusing only costs
  # a rerun, so the run fails closed (cekEnvironment, CLI exit 3).
  let untrackedOut = requireGit(
    ["ls-files", "-z", "--others", "--exclude-standard"], projectRoot,
    "git ls-files --others --exclude-standard",
    "refusing --changed: untracked (not-yet-added) files cannot be " &
    "enumerated, so the changed set may be incomplete")

  for rec in untrackedRecs(untrackedOut):
    addChanged(result, rec, "", projectRoot, roots)

  # R13-S3: a gitlink whose directory holds content but no repository is
  # unchanged to git and hides everything under it from both scans above.
  addStrandedGitlinks(result, "", projectRoot, roots)
