## gitdiff.nim — D5: changed-file extraction for impact selection.
##
## `changedFiles` calls git directly (via `osproc.startProcess` with an
## explicit `args` sequence and `workingDir = projectRoot`) to produce the
## set of project-root-relative `TrackedPath`s that differ from a reference.
## It is the I/O bridge that feeds `narrow.narrowByDiff` (the pure selection
## function) — RFC-0009 A3b-i carries the result as far as narrow's door via
## a temporary adapter in pipeline.nim; narrow.nim itself is not retyped
## until A3b-ii.
##
## ## Git commands
##
## First, a repo probe (so a clear cekEnvironment error replaces git's own
## terse diagnostics):
##   `git rev-parse --is-inside-work-tree`
##
## Then the diff, NUL-separated (`-z`):
##   - No base → `git diff -z --no-renames --relative --name-only HEAD`
##       (all tracked modifications, staged + unstaged, vs the last commit)
##   - With base → `git diff -z --no-renames --relative --name-only <base>`
##       (working tree vs <base> — deliberately includes uncommitted edits;
##        over-selection is safe, under-selection is not)
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
## directory is not a git work tree, a `CrisolError(cekEnvironment, …)` is
## raised.  The CLI maps that to exit 3, consistent with every other
## environment failure.

import std/[options, os, osproc, sets, streams, strutils]  # process-contract-exempt: git is a short-lived tool invocation, not a compile/run child (RFC-0007 §Scope)
import crisol/types

# ---------------------------------------------------------------------------
# Internal helper: run git without a shell
# ---------------------------------------------------------------------------

proc runGit(args: seq[string]; workingDir: string): tuple[output: string; exitCode: int] =
  ## Invoke `git <args>` in `workingDir` without a shell intermediary.
  ## Uses `poUsePath` so `git` is found via PATH; `poStdErrToStdOut` merges
  ## stderr into the captured output so diagnostics are visible.
  ## Returns (output, exitCode); raises OSError if git cannot be exec'd at all.
  let p = startProcess("git", workingDir = workingDir, args = args,
                        options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  let output = p.outputStream.readAll()
  let code   = waitForExit(p)
  result = (output: output, exitCode: code)

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
  var probeOut: string
  var probeCode: int
  try:
    (probeOut, probeCode) = runGit(
      @["rev-parse", "--is-inside-work-tree"],
      workingDir = projectRoot)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "git is not available (could not execute 'git'): " & e.msg)
  except Exception as e:
    raise newCrisolError(cekEnvironment,
      "git is not available (could not execute 'git'): " & e.msg)

  if probeCode != 0 or probeOut.strip() != "true":
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
  let diffArgs =
    if baseRef.len == 0:
      @["diff", "-z", "--no-renames", "--relative", "--name-only", "HEAD"]
    else:
      @["diff", "-z", "--no-renames", "--relative", "--name-only", baseRef]

  var diffOut: string
  var diffCode: int
  try:
    (diffOut, diffCode) = runGit(diffArgs, workingDir = projectRoot)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "git diff failed to execute: " & e.msg)
  except Exception as e:
    raise newCrisolError(cekEnvironment,
      "git diff failed to execute: " & e.msg)

  if diffCode != 0:
    raise newCrisolError(cekEnvironment,
      "git diff exited with code " & $diffCode & ": " & diffOut.strip())

  for name in splitNul(diffOut):
    let tp = reduceChangedName(name, roots)
    if tp.isSome: result.incl tp.get

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
  var untrackedOut: string
  var untrackedCode: int
  try:
    (untrackedOut, untrackedCode) = runGit(
      @["ls-files", "-z", "--others", "--exclude-standard"],
      workingDir = projectRoot)
  except:
    # Best-effort: if ls-files fails for any reason, ignore (safe: over-selection
    # is not possible here; we just miss some untracked files).
    untrackedCode = -1

  if untrackedCode == 0:
    for name in splitNul(untrackedOut):
      let tp = reduceChangedName(name, roots)
      if tp.isSome: result.incl tp.get
