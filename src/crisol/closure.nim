## closure.nim — source-dependency closure extractor for one entrypoint (D1).
##
## Reads the per-build nimcache JSON produced by `nim c` and extracts the
## transitive set of `.nim` source files the entrypoint depends on, filtered
## to files that live under a *tracked root* (projectRoot or a configured
## depRoot).  Stdlib, nimble-package paths, and anything that cannot be
## resolved to a tracked root are silently excluded.
##
## `@p`/`@n` resolution is index-based (issue #8), not root-guessing: see
## `SourceIndex` / `buildSourceIndex` / the `@p` doc paragraph below.  crisol
## no longer needs to enumerate candidate `--path` roots (`src/`, depRoots,
## …) — any module the compiler actually resolved through SOME `--path`
## entry is on disk somewhere under projectRoot or a depRoot, so a full
## source-tree index finds it regardless of which `--path` produced it
## (project `nim.cfg`/`config.nims`, a dep's own config, …).
##
## ## Algorithm (RFC-0001 §Dependency Source, verified decode algorithm)
##
## The nimcache JSON at `<nimcacheDir>/<binaryName>.json` contains two
## arrays that name compile units:
##
## - `compile` — `[cFilePath, gccCmd]` pairs: the C-compile WORK LIST for
##   this invocation.  Complete only on a cold nimcache; on a warm recompile
##   it holds just the modules whose generated C changed, and is EMPTY when
##   nothing did (a comment-only edit).  NOT a closure source (issue #5).
## - `link`    — object-file paths: everything the linker consumes.  Built
##   from ALL of the compiler's `toCompile` plus external objects, so it is
##   complete on every compile by construction.  THIS is the closure source.
##
## A Nim MODULE object's basename is always `<mangled>.nim.{c,cpp,m}.o` — the
## literal `.nim` component before the backend extension is what distinguishes
## a module object from an external.  The backend extension is `.c` for an
## ordinary module, `.cpp` when the module has `{.importcpp.}` symbols
## (sfCompileToCpp — Nim 2.2.10 cgen's `getCFile` picks this per-module, even
## under plain `nim c`), and `.m` for `{.importobjc.}` symbols.  An entry may
## ALSO be `@m`- or `@p`-mangled without naming a Nim module at all: a
## `{.compile: "foo.c".}`d external, for instance, appears as `@mfoo.c.o` —
## `@m`-prefixed, but no `.nim` component, so it names no source module.
## `moduleMangledNameOf` (below) is the single place that applies this
## `.nim.{c,cpp,m}.o` contract.  For an entry that IS a module object, strip
## `.o` and the backend extension and the mangled name encodes the source
## location:
##
##   basename: strip `.{c,cpp,m}.o` → strip leading prefix → decode body (@s→/, @@→@)
##
## Two prefixes matter:
##
## - `@m<body>` — body is a path relative to `parentDir(realpath(ENTRYPOINT
##   FILE))` (not the CWD, and not merely `realpath` of the entrypoint's
##   lexical *directory* — a symlinked entrypoint FILE inside an otherwise
##   ordinary directory has a different real parent than its lexical one
##   too).  Candidate = normalize(entrypointDir / body).  When the resolved
##   module is reached through a symlinked root (e.g. a depRoot symlinked
##   into milpa's CAS) and the entrypoint is shallow enough that `@m` still
##   beats `@p`, this normalized candidate is a REALPATH outside every
##   tracked root; `resolveMangledAll` then falls back to the same index
##   lookup `@p`/`@n` uses (see that proc's doc comment for the full case
##   analysis).
##
## - `@p<body>` (and `@n<body>`, Nim's nimblePath prefix — treated identically)
##   — body is a path relative to whichever search-path root resolved it
##   (stdlib dir, nimble pkg dir, or ANY project `--path` root — `src/`, a
##   dep's own root, or a root added ad hoc by a `config.nims`/`nim.cfg`
##   `switch("path", …)` somewhere up the project-file's directory chain).
##   crisol cannot know which root from the mangled name alone, and — issue
##   #8 — a fixed guess-list of roots (`projectRoot`, `projectRoot/src`,
##   depRoots, depRoots/src) misses any root added by a config file rather
##   than by crisol's own config, silently dropping that module from the
##   closure.  Instead, `body` is resolved against a once-per-run
##   `SourceIndex` (`buildSourceIndex`, below): every `.nim` file under
##   projectRoot or a depRoot, indexed by basename.  A candidate is kept iff
##   its indexed absolute path equals `body` or ends with `DirSep & body` —
##   exactly the semantics of "some search-path root resolved this suffix".
##   Ambiguous matches (the body suffix matches under multiple indexed
##   files) keep ALL of them (R7 over-selection policy, unchanged).  Stdlib
##   and nimble-package bodies match nothing in the index (excluded) or, in
##   rare basename-collision cases, over-select harmlessly (R7 policy).
##
##   The index walk itself prunes some directories for WALK COST — dot-dirs,
##   `nimcache` dirs, the state dir (see `walkForIndex`'s doc comment) — a
##   file living under one of those is never indexed, so a plain index
##   lookup misses it even though it is tracked (it lives under a root by
##   construction).  That pruning is deliberately a walk-cost decision, not
##   a tracking decision: when `body` resolves to no indexed file at all,
##   `resolveMangledAll` falls back to an EXISTENCE check against
##   `index.roots` directly (join the stripped suffix onto each root, keep
##   whichever candidate(s) exist on disk) before concluding the module is
##   genuinely untracked.  This matters concretely for a milpa `_deps/<dep>`
##   symlink whose realpath target sits under a dot-dir INSIDE projectRoot
##   (rather than in an external CAS) with no `dep-roots` entry naming that
##   dot-dir directly — the compiler resolves the import fine (the symlink
##   is on the search path), but nothing under the dot-dir was indexed to
##   suffix-match against.
##
## The under-tracked-root filter (step 5) is path-location based, NOT
## prefix based.  A project module imported via `--path:src` is `@p`-mangled
## but must be tracked because excluding it breaks both `narrowByDiff` and
## compile-avoidance.  This is the D1a soundness fix.
##
## ## Return value
##
## A `HashSet[string]` of paths relative to `projectRoot`, using forward
## slashes, matching the scheme used by `Entrypoint.path` and future
## dep-graph keys.  The entrypoint's own file is included (its object is in
## `link`).  External objects (`{.compile.}`d C/C++ files and foreign
## libraries) are excluded by `moduleMangledNameOf`'s `.nim.{c,cpp,m}.o` filter —
## they may be `@m`-mangled too, but never end in `.nim.c.o` / `.nim.cpp.o` /
## `.nim.m.o`, so they never name a Nim module in the first place.
##
## ## Error handling
##
## A missing or unparse­able JSON raises `CrisolError(kind: cekEnvironment)`.
## The caller (D2/D6) decides recovery policy; the conservative fallback
## (run the entrypoint regardless) is a later-slice concern.

import std/[json, os, sets, strutils, tables]
import crisol/types
import crisol/config  # for stateDirOf — the source-index walk prunes it

# ---------------------------------------------------------------------------
# SourceIndex — once-per-run basename -> absolute-paths index (issue #8)
# ---------------------------------------------------------------------------

type
  IndexedFile = object
    ## One indexed `.nim` file, recorded under both the LEXICAL path
    ## (project/depRoot-relative walk path — what we report and record in
    ## the closure) and the REALPATH (symlinks resolved) — see `lookup`'s
    ## doc comment for why both are needed.
    lexical: string
    real:    string

  SourceIndex* = object
    ## basename ("foo.nim") -> every indexed file under projectRoot or a
    ## depRoot whose file has that basename.  Built once per run
    ## (`buildSourceIndex`) and threaded through `extractClosure` for ALL
    ## entrypoints in the run — never rebuilt per entrypoint.
    byBasename: Table[string, seq[IndexedFile]]
    byReal: Table[string, seq[string]]
      ## realpath (absolute, normalized) -> every indexed file's LEXICAL
      ## path(s) recorded at that realpath.  Used by `lookupByReal` for an
      ## EXACT (non-suffix) match — the mechanism `resolveMangledAll`'s `@m`
      ## branch uses instead of the old whole-index suffix scan (see that
      ## proc's doc comment). Multiple lexicals can share one realpath (two
      ## symlinked roots pointing at the same target, etc.); all are kept
      ## (R7 over-selection policy, same as `byBasename`).
    roots: seq[string]
      ## The lexical, absolute, normalized roots this index was built from
      ## — projectRoot plus EVERY configured depRoot, regardless of whether
      ## it existed on disk at build time (a depRoot need not exist for R5:
      ## a deleted dep must still be reported as "tracked" so its last-known
      ## closure entry is retained rather than silently dropped by the
      ## under-tracked-root filter).  Only roots that DO exist are actually
      ## walked (`buildSourceIndex`).  This is the single source of truth
      ## for "is this path tracked" — both `underAnyRoot` (the `@m` escape
      ## check, below) and `extractClosure`'s under-tracked-root filter use
      ## it; there is no separate, duplicate root list.

proc addToIndex(index: var SourceIndex; lexical: string; real: string) =
  let base = lexical.extractFilename
  index.byBasename.mgetOrPut(base, @[]).add IndexedFile(lexical: lexical, real: real)
  let realNorm = real.normalizedPath
  index.byReal.mgetOrPut(realNorm, @[]).add lexical

proc walkForIndex(dir: string; recordRoot: string; stateDirAbs: string;
                  index: var SourceIndex) =
  ## Recursively index `.nim` files under `dir`, RECORDING each file's LEXICAL
  ## path as `recordRoot / <relative path from the original walk root>` rather
  ## than whatever `os.walkDir` hands back — this matters for depRoots
  ## (`buildSourceIndex` passes `recordRoot == dir` at the top so recorded
  ## paths are lexically `<depRootAbs>/<rel>`, matching what the
  ## under-tracked-root filter and `toProjectRelative` expect) — AND each
  ## file's REALPATH (symlinks resolved), used by `lookup` to match `@p`
  ## bodies the compiler mangled from a realpath-canonicalized source (e.g.
  ## a depRoot reached through a symlink into milpa's CAS).  `dir`'s real
  ## directory is resolved ONCE per recursive call (`expandFilename`,
  ## falling back to the lexical `dir` on `OSError`) rather than per file.
  ##
  ## Pruning (mirrors discover.nim's `walkNimFiles` walk discipline):
  ##   • never descend into a symlinked directory (pcLinkToDir) — dependency
  ##     content (e.g. milpa's `_deps/*` -> CAS) stays opt-in via depRoots;
  ##     a depRoot itself CAN be a symlink (the caller walks into it
  ##     directly), only NESTED symlinked subdirectories are pruned here.
  ##   • skip directories whose name starts with '.' (.git, .crisol, and
  ##     any other dotdir — e.g. a vendored toolchain checkout living under
  ##     projectRoot, such as this repo's `.docker-home/`).
  ##   • skip directories named "nimcache" (generated, never source).
  ##   • skip the resolved state dir (`stateDirOf`), by absolute-path
  ##     comparison, in case it is ever configured outside the '.'-prefix
  ##     convention.
  ##
  ## IMPORTANT: every rule above is a WALK-COST decision, not a TRACKING
  ## decision. A file under a pruned directory is still "tracked" — it
  ## lives under `recordRoot`/a root by construction — it is simply never
  ## added to `index.byBasename`/`index.byReal`, so a `lookup` against it
  ## misses. `resolveMangledAll`'s `@p`/`@n` branch accounts for exactly
  ## this: when `SourceIndex.lookup` misses entirely, it falls back to an
  ## EXISTENCE check of the stripped body suffix joined onto each of
  ## `index.roots` directly (bypassing the index, and hence this pruning)
  ## rather than treating a pruned-and-therefore-unindexed file as
  ## untracked.
  let realDir =
    try: expandFilename(dir)
    except OSError: dir
  for entry in walkDir(dir):
    let name = entry.path.lastPathPart
    case entry.kind
    of pcLinkToDir:
      discard                          # never descend into symlinked dirs
    of pcDir:
      if name.startsWith("."): continue
      if name == "nimcache": continue
      let entryAbs = entry.path.absolutePath.normalizedPath
      if stateDirAbs.len > 0 and entryAbs == stateDirAbs: continue
      walkForIndex(entry.path, recordRoot / name, stateDirAbs, index)
    of pcFile:
      if entry.path.endsWith(".nim"):
        index.addToIndex(recordRoot / name, realDir / name)
    of pcLinkToFile:
      if entry.path.endsWith(".nim"):
        let real =
          try: expandFilename(entry.path)
          except OSError: recordRoot / name
        index.addToIndex(recordRoot / name, real)

proc buildSourceIndex*(config: Config): SourceIndex =
  ## Walk `config.projectRoot` and each `config.depRoots[i]` once, indexing
  ## every `.nim` file by basename.  See `walkForIndex`'s doc comment for
  ## the exact pruning rules.  Meant to be built ONCE per run (by the
  ## caller — `runner.execute`) and passed to every `extractClosure` call
  ## in that run, never rebuilt per entrypoint.
  ##
  ## `result.roots` records projectRoot AND EVERY configured depRoot
  ## unconditionally — regardless of whether the depRoot exists on disk —
  ## so a deleted/missing depRoot is still "tracked" for the purposes of
  ## `underAnyRoot`/the under-tracked-root filter (R5: a dep that has since
  ## vanished must still be reported, not silently dropped because its root
  ## no longer resolves).  Only EXISTING roots are actually walked.
  result = SourceIndex(byBasename: initTable[string, seq[IndexedFile]](),
                        byReal: initTable[string, seq[string]]())
  let stateDirAbs = stateDirOf(config)

  let prAbs = config.projectRoot.absolutePath.normalizedPath
  result.roots.add prAbs
  if dirExists(prAbs):
    walkForIndex(prAbs, prAbs, stateDirAbs, result)

  for dr in config.depRoots:
    let drAbs = dr.absolutePath.normalizedPath
    result.roots.add drAbs
    if dirExists(drAbs):
      walkForIndex(drAbs, drAbs, stateDirAbs, result)

proc strippedSuffix(body: string): string =
  ## Strip every LEADING `""`/`"."`/`".."` path component from a decoded
  ## `@p`/`@n` body, leaving the suffix relative to whichever search-path
  ## root produced it (see `lookup`'s doc comment for why a body can carry
  ## leading `..` components at all).  Returns `""` if nothing but such
  ## components remains (no usable suffix).
  ##
  ## The SINGLE place this stripping rule lives — shared by `lookup` (index
  ## suffix match) and `resolveMangledAll`'s roots existence-check fallback
  ## (below), so the two can never diverge on what counts as "the suffix".
  let normBody = body.replace('\\', DirSep).replace('/', DirSep)
  var comps = normBody.split(DirSep)
  var start = 0
  while start < comps.len and comps[start] in ["", ".", ".."]:
    inc start
  if start >= comps.len: return ""
  comps[start .. ^1].join($DirSep)

proc lookup(index: SourceIndex; body: string): seq[string] =
  ## Resolve a decoded `@p`/`@n` body (a path relative to SOME search-path
  ## root) against the index.
  ##
  ## `body` is the SHORTEST relative path from SOME search-path root to the
  ## compiler's CANONICALIZED (realpath) source file.  Two consequences:
  ##
  ## - "shortest" means `body` may start with one or more `..` components
  ##   (an in-root file reached via a `--path` root that isn't its own
  ##   ancestor, e.g. `--path:src` importing `../lib/x.nim`).
  ## - "realpath-canonicalized" means that if the search-path root itself is
  ##   reached through a symlink (e.g. a milpa depRoot symlinked into the
  ##   CAS), `body` is relative-to-realpath and can carry MANY `..`
  ##   components followed by the target's absolute, symlink-resolved path
  ##   (e.g. `../../../../home/u/.cache/milpa/cas/.../dep/src/dep.nim`).
  ##
  ## Every LEADING `""`/`"."`/`".."` component is therefore stripped
  ## (`strippedSuffix`) before matching — this is a pure WIDENING of the
  ## suffix match (a shorter suffix can only match more indexed files,
  ## never fewer), so it stays sound under the R7 over-selection policy:
  ## ambiguous/spurious matches are acceptable (they only over-select),
  ## silent drops are not.
  ##
  ## The stripped suffix is matched against BOTH `IndexedFile.lexical` (the
  ## walk-recorded, project/depRoot-relative path — what a `..`-free body
  ## already matched pre-fix) and `IndexedFile.real` (the realpath — what a
  ## realpath-canonicalized body from a symlinked root matches).  The
  ## reported path is always `lexical`: crisol records and diffs against
  ## project-relative paths, never realpaths.
  ##
  ## Multiple matches (ambiguous — the same suffix exists under more than
  ## one indexed location) are ALL returned (R7 over-selection policy).
  ##
  ## This is an INDEX lookup only — it necessarily misses a file that is
  ## on disk but was never indexed, e.g. one living under a directory
  ## `walkForIndex` prunes for WALK COST (a dot-dir, a `nimcache` dir).
  ## That pruning is a walk-cost decision, not a tracking decision: such a
  ## file is still tracked (it lives under a root by construction) and is
  ## recovered separately, by `resolveMangledAll`'s roots existence-check
  ## fallback, when this lookup returns nothing.
  result = @[]
  let suffix = strippedSuffix(body)
  if suffix.len == 0: return
  let sufComps = suffix.split(DirSep)
  let base = sufComps[^1]
  if base notin index.byBasename: return
  let suffixPattern = $DirSep & suffix
  var seen = initHashSet[string]()
  for f in index.byBasename[base]:
    if f.lexical.endsWith(suffixPattern) or f.real.endsWith(suffixPattern):
      if f.lexical notin seen:
        seen.incl f.lexical
        result.add f.lexical

proc lookupByReal(index: SourceIndex; realAbs: string): seq[string] =
  ## Resolve an absolute, normalized REALPATH to the indexed file(s) whose
  ## realpath EXACTLY equals it — the mechanism `resolveMangledAll`'s `@m`
  ## branch uses to recover a candidate that landed outside every tracked
  ## root (or was computed from the wrong base directory — see that proc's
  ## doc comment), returning the LEXICAL path(s) `extractClosure` records.
  ## Unlike `lookup` (used for `@p`/`@n`), this is an EXACT match, not a
  ## suffix match: an `@m` body is not "the shortest relative path from
  ## some search-path root" (ambiguous which root), it is unambiguously
  ## "the path from one specific directory" (the entrypoint's, real or
  ## lexical) — so the candidate it produces is either the file or it isn't,
  ## with no suffix-widening question to resolve.  An untracked,
  ## out-of-every-root import therefore correctly resolves to nothing here
  ## (no indexed file shares its realpath) rather than over-selecting an
  ## unrelated same-suffix decoy elsewhere in the tree.
  index.byReal.getOrDefault(realAbs, @[])

proc underAnyRoot(index: SourceIndex; absPath: string): bool =
  ## True iff `absPath` (normalized absolute) lives under one of `index`'s
  ## recorded lexical roots (projectRoot or a depRoot) — path equals the
  ## root, or starts with `root & DirSep`.  The single source of truth for
  ## "is this path tracked": used both by `resolveMangledAll`'s `@m` branch
  ## (to detect a candidate that escaped every tracked root, e.g. the
  ## realpath-through-a-symlinked-depRoot case, so it can fall back to the
  ## index instead of silently dropping the module) and by `extractClosure`'s
  ## under-tracked-root filter (the SOUNDNESS gate over every resolved
  ## candidate, `@m` and `@p`/`@n` alike) — there is no separate,
  ## independently-computed root list.
  for root in index.roots:
    if absPath == root or absPath.startsWith(root & $DirSep):
      return true
  false

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc addUnique(result: var seq[string]; seen: var HashSet[string];
               cands: seq[string]) =
  ## Append each of `cands` to `result` iff not already in `seen` (and mark
  ## it seen) — the dedup step shared by `resolveMangledAll`'s `@m` case 1
  ## and case 2 branches, both of which union zero or more `lookupByReal`
  ## matches onto a `result` seq that may already hold a candidate.
  for cand in cands:
    if cand notin seen:
      seen.incl cand
      result.add cand

proc toProjectRelative(absPath: string; projectRoot: string): string =
  ## Convert an absolute path to a projectRoot-relative forward-slash path.
  let root = projectRoot.absolutePath.normalizedPath
  let norm  = absPath.normalizedPath
  if norm.startsWith(root & $DirSep):
    result = norm[root.len + 1 .. ^1]
  elif norm == root:
    result = ""
  else:
    result = norm          # fallback: return as-is (shouldn't happen post-filter)
  # Normalise to forward slashes on all platforms.
  result = result.replace($DirSep, "/")

proc decodeBody(raw: string): string =
  ## Decode Nim's mangling escapes in the post-prefix mangled body string:
  ## @s → /, @c → :, @h → #, @@ → @ (protected first so a literal `@` in
  ## the source path never collides with the other escapes).
  raw
    .replace("@@", "\x00")   # protect literal @ temporarily
    .replace("@s", $DirSep)  # @s → path separator
    .replace("@c", ":")      # @c → colon
    .replace("@h", "#")      # @h → hash
    .replace("\x00", "@")    # restore literal @

proc moduleMangledNameOf(objPath: string): string =
  ## Maps one `link` object-file path to the mangled module name
  ## `resolveMangledAll` expects (the compile-unit basename with the backend
  ## extension and trailing `.o` already stripped, e.g. `@mfoo.nim`), or
  ## `""` if `objPath` names no Nim module.
  ##
  ## Contract (the single place it is stated): a Nim MODULE object's
  ## basename is `<mangled>.nim.{c,cpp,m}.o` — `.nim.c.o` for an ordinary
  ## module, `.nim.cpp.o` for a module with `{.importcpp.}` symbols
  ## (sfCompileToCpp — Nim 2.2.10 cgen's `getCFile` picks this per-module,
  ## even under plain `nim c`), `.nim.m.o` for `{.importobjc.}` symbols.
  ## Strip `.o` and the backend extension — what remains, `<mangled>.nim`,
  ## is the module name `resolveMangledAll` decodes. An external (a
  ## `{.compile.}`d C/C++ file, a foreign `.o`/`.a`) may ALSO be `@m`- or
  ## `@p`-mangled (e.g. `@mfixture.c.o` for `{.compile: "fixture.c".}`), but
  ## never carries the `.nim` component before the backend extension, so it
  ## never satisfies this filter — checking the `@m`/`@p` prefix alone is
  ## NOT sufficient to identify a module object.
  let base = objPath.extractFilename
  for suffix in [".nim.c.o", ".nim.cpp.o", ".nim.m.o"]:
    if base.endsWith(suffix):
      return base[0 ..< base.len - (suffix.len - 4)]   # keep through ".nim"
  ""

proc resolveMangledAll(mangledName: string;
                       entrypointPath: string;
                       index: SourceIndex): seq[string] =
  ## Decode one mangled module name (`moduleMangledNameOf`'s output — the
  ## compile-unit basename with the backend extension and `.o` already
  ## stripped, e.g. `@mfoo.nim`) to zero or more absolute `.nim` candidate
  ## paths.
  ##
  ## For `@m`: `body` is Nim's SHORTEST-relative-path candidate measured
  ##           from the entrypoint's own directory — the mangler's default
  ##           choice, used whenever no `--path` root gives a STRICTLY
  ##           shorter body (`@p`/`@n`, below).  Critically, `body` is always
  ##           computed by the compiler from `parentDir(realpath(ENTRYPOINT
  ##           FILE))` — the real directory containing the resolved
  ##           entrypoint FILE, not `realpath` of the entrypoint's (lexical)
  ##           directory path (`realEpDir`, below, computes exactly this: it
  ##           resolves the entrypoint FILE's realpath first, then takes
  ##           `parentDir` — so a symlinked entrypoint FILE inside an
  ##           ordinary, non-symlinked directory is handled the same way as a
  ##           symlinked entrypoint DIRECTORY).  This drives two distinct
  ##           cases, split on whether the entrypoint's real directory
  ##           differs from its lexical one:
  ##
  ##           1. `realEpDir == epDir` (the common case — neither the
  ##              entrypoint FILE nor any component of its directory is a
  ##              symlink). `body` is then lexical-path-relative from `epDir`
  ##              UNLESS the RESOLVED module is itself reached through a
  ##              symlinked root (e.g. a milpa depRoot symlinked into the
  ##              CAS) and the entrypoint is shallow enough that `@m` still
  ##              wins over `@p` — then `body` carries `..` components up to
  ##              a common ancestor and back down into the symlink's
  ##              REALPATH target, so `(epDir / body).normalizedPath`
  ##              resolves to the dep's REAL path, outside every tracked
  ##              root.  The primary candidate is always
  ##              `(epDir / body).normalizedPath` (existence not checked
  ##              here — this candidate is emitted unconditionally whether
  ##              or not the file is currently on disk; case 2, below, has a
  ##              different fallback rule).  This unconditional emit is NOT
  ##              what makes R5's "deleted dep detected" guarantee hold:
  ##              `depgraph.recordClosure` hashes every returned candidate
  ##              immediately via `closureContentHash` (which `readFile`s
  ##              each path), so a candidate missing AT EXTRACTION TIME makes
  ##              THIS extraction fail and the entry gets invalidated rather
  ##              than persisted with a phantom member — it is never actually
  ##              recorded.  The real detection happens later, against the
  ##              PERSISTED closure from an earlier run when the file still
  ##              existed: `narrow.isEntryStale` and the planner's own
  ##              missing-closure-file check both test that persisted
  ##              closure's files for existence.
  ##
  ##              When that candidate is NOT under any of `index`'s
  ##              recorded roots, it is ALSO resolved via
  ##              `index.lookupByReal` on the identical real path (the plain
  ##              candidate already IS the real path in this branch, since
  ##              `epDir` has no symlink of its own) — an EXACT match, not a
  ##              suffix scan: an untracked, out-of-every-root import (no
  ##              depRoot of its own) has no indexed file at that realpath,
  ##              so it resolves to nothing extra, instead of over-selecting
  ##              an unrelated same-suffix decoy elsewhere in the tree (the
  ##              precision regression a suffix-based fallback previously
  ##              caused).  A genuine symlinked-depRoot escape DOES have an
  ##              indexed file at that exact realpath (the depRoot walk
  ##              records it), so it is correctly recovered at its lexical
  ##              path.  (Note: if a planted symlink inside a tracked root
  ##              happens to make `lookupByReal` resolve to a DIFFERENT
  ##              tracked file than the one actually imported, that
  ##              unrelated file is recorded — over-selection under the R7
  ##              policy; an attacker able to plant symlinks inside a
  ##              tracked root can already edit tracked sources directly, so
  ##              this is not a new capability.)
  ##
  ##           2. `realEpDir != epDir` (the entrypoint's real directory
  ##              differs from its lexical one — either the entrypoint FILE
  ##              itself is a symlink, or some component of its containing
  ##              directory is, or both; not necessarily a depRoot, just an
  ##              ordinary in-project symlink).  `body` was computed by the
  ##              compiler from the REAL directory, so naively joining it
  ##              onto the LEXICAL `epDir` (case 1's arithmetic) does not
  ##              reliably cancel back to the right path whenever the
  ##              lexical and real directories differ in path DEPTH — it can
  ##              land on a bogus, nonexistent, yet still textually-in-root
  ##              path, silently dropping the real dependency while
  ##              polluting the closure with a never-existing entry.  Here
  ##              the REAL candidate, `(realEpDir / body).normalizedPath`,
  ##              is resolved first via `index.lookupByReal`.  IMPORTANT:
  ##              this case's lexical candidate is NOT what the compiler
  ##              actually saw (it is case 1's arithmetic, known unreliable
  ##              here) — so it is used as a fallback ONLY when it exists on
  ##              disk (`fileExists`/`symlinkExists`; this is how the
  ##              entrypoint's own module recovers: a symlinked directory is
  ##              never walked into and indexed by `buildSourceIndex`, but
  ##              the lexical entrypoint path itself resolves through the OS
  ##              symlink just fine).  When the lexical candidate does NOT
  ##              exist either, the REAL candidate itself is kept instead —
  ##              it is then subject to `extractClosure`'s ordinary
  ##              under-tracked-root filter, exactly like any other
  ##              out-of-root import, rather than inventing a nonexistent
  ##              in-root path that would later break `closureContentHash`
  ##              and perpetually invalidate the entry.
  ##
  ##           Results are deduped via the shared `addUnique` helper.
  ##
  ## For `@p`/`@n` (Nim's nimblePath prefix — treated identically to `@p`):
  ##           resolved against `index` (issue #8 — see `SourceIndex.lookup`).
  ##           ALL matches are returned (R7 over-selection policy, unchanged):
  ##           - R7: when the body suffix matches under multiple indexed
  ##             locations (ambiguous), ALL are recorded (over-selection) so
  ##             a change to any copy triggers re-selection.
  ##           - a body that resolves to a file DELETED since the index was
  ##             built simply isn't in the index → no candidate → excluded
  ##             here.  The previous closure still holds the path and
  ##             isEntryStale (R4 fix) detects the missing file and forces a
  ##             re-run, so soundness is maintained via the stale-entry path
  ##             rather than the closure-rebuild path (same policy as before).
  ##           - when `index.lookup` misses entirely (no indexed file at all
  ##             matches the stripped suffix), a SECOND fallback runs before
  ##             giving up: join the stripped suffix (`strippedSuffix`, the
  ##             helper `lookup` also uses) onto each of `index.roots` and
  ##             keep whichever joined candidate(s) exist on disk. This
  ##             recovers a file that IS on disk under a tracked root but
  ##             was never indexed because `walkForIndex` prunes its
  ##             containing directory for WALK COST — a dot-dir or a
  ##             `nimcache` dir — rather than because it is untracked (e.g.
  ##             a milpa depRoot symlink whose target sits under a dot-dir
  ##             inside projectRoot, with no `dep-roots` entry naming that
  ##             dot-dir directly: the symlink is on the search path, so
  ##             the compiler resolves and realpath-canonicalizes the
  ##             import fine, but nothing under the dot-dir was ever
  ##             indexed to suffix-match against). Sound: every candidate
  ##             produced is under a tracked root by construction, and
  ##             existence is checked, so nothing is fabricated; multiple
  ##             roots may match (R7 — all recorded).
  ## For anything else: empty list (conservative).
  # `mangledName` is `moduleMangledNameOf`'s output — already ".nim.{c,cpp,m}.o"
  # filtered, backend extension and ".o" stripped — so it is always
  # "<@m|@p|@n><body>.nim" here; see that proc's doc comment for the
  # module-object contract this relies on.
  if not (mangledName.startsWith("@m") or mangledName.startsWith("@p") or
          mangledName.startsWith("@n")):
    return @[]                               # unknown prefix — exclude

  let noPrefix = mangledName[2 .. ^1]        # strip "@m"/"@p"/"@n"
  let body     = decodeBody(noPrefix)        # decode @s/@@ escapes

  if mangledName.startsWith("@m"):
    # Relative to the entrypoint's source directory. `body` is always
    # computed by the compiler from `parentDir(realpath(ENTRYPOINT FILE))`
    # — see this proc's doc comment for the two cases this splits into.
    let epAbs = entrypointPath.absolutePath
    let epDir = epAbs.parentDir
    let realEpDir =
      try: expandFilename(epAbs).parentDir
      except OSError:
        try: expandFilename(epDir)
        except OSError: epDir
    let lexicalCandidate = (epDir / body).normalizedPath
    var seen = initHashSet[string]()

    if realEpDir == epDir:
      # Case 1: neither the entrypoint FILE nor its containing directory
      # carries a symlink, so `body` is relative to `epDir` exactly as
      # written — the lexical candidate IS the real one. Primary result;
      # existence not checked here (this candidate is emitted regardless of
      # whether the file is currently on disk). That is NOT what makes R5's
      # "deleted dep detected" guarantee hold — recordClosure hashes every
      # closure member immediately (closureContentHash -> readFile), so a
      # member missing right now makes THIS extraction fail rather than get
      # persisted; the real detection happens later, via isEntryStale / the
      # planner's missing-closure-file check against the PERSISTED closure
      # from when the file still existed.
      result = @[lexicalCandidate]
      seen.incl lexicalCandidate
      # A realpath-through-a-symlinked-root escape (this proc's doc
      # comment) puts the candidate outside every tracked root — recover
      # it via an EXACT realpath match (not @p/@n's suffix scan): an
      # untracked, out-of-every-root import has no indexed file at this
      # exact realpath, so it correctly adds nothing, while a genuine
      # symlinked-depRoot dep does and is recovered at its lexical path.
      if not index.underAnyRoot(lexicalCandidate):
        addUnique(result, seen, index.lookupByReal(lexicalCandidate))
    else:
      # Case 2: the entrypoint's REAL directory differs from its LEXICAL
      # one (the entrypoint FILE itself is a symlink, a component of its
      # containing directory is, or both), so `body` was computed from
      # `realEpDir`, not `epDir` — the lexical candidate's `..` arithmetic
      # (case 1's) does not reliably cancel back to the right path. Prefer
      # the REAL candidate via an exact realpath match; the lexical
      # candidate is NOT what the compiler saw here, so it serves as a
      # fallback only when it exists on disk (the entrypoint's own module,
      # e.g. — a symlinked directory is never walked into and indexed by
      # buildSourceIndex, but the lexical path itself still resolves
      # through the OS symlink). When neither resolves, keep the REAL
      # candidate itself: it is then root-filtered by extractClosure like
      # any ordinary out-of-root import, rather than fabricating a
      # nonexistent lexical sibling that would pollute the closure and
      # break closureContentHash.
      let realCandidate = (realEpDir / body).normalizedPath
      result = @[]
      addUnique(result, seen, index.lookupByReal(realCandidate))
      if result.len == 0:
        if fileExists(lexicalCandidate) or symlinkExists(lexicalCandidate):
          result.add lexicalCandidate
        else:
          result.add realCandidate

  else: # "@p" or "@n"
    result = index.lookup(body)
    if result.len == 0:
      # `index.lookup` is an INDEX-ONLY lookup — it misses a file that is
      # genuinely on disk under a tracked root but was never indexed
      # because `walkForIndex` prunes its containing directory for WALK
      # COST (a dot-dir, a `nimcache` dir; e.g. a milpa depRoot symlink
      # whose target sits under a dot-dir inside projectRoot, with no
      # `dep-roots` entry of its own naming that dot-dir directly). That
      # pruning is a walk-cost decision, not a tracking decision: the file
      # is still tracked (it lives under a root by construction), so it is
      # recovered here via a plain EXISTENCE check — join the stripped
      # suffix onto each tracked root and keep whichever candidate(s)
      # actually exist on disk. Sound (every candidate is under a tracked
      # root by construction; existence checked, so nothing fabricated),
      # and consistent with R7: multiple roots may match — all are kept.
      let suffix = strippedSuffix(body)
      if suffix.len > 0:
        var seen = initHashSet[string]()
        for root in index.roots:
          let cand = (root / suffix).normalizedPath
          if fileExists(cand) or symlinkExists(cand):
            if cand notin seen:
              seen.incl cand
              result.add cand

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc parseCompileManifest*(jsonPath: string):
    tuple[compile: seq[tuple[cPath, ccCmd: string]];
          link: seq[string];
          linkcmd: string] =
  ## Low-level nimcache-JSON reader (RFC-0006 §File scoping / "Manifest
  ## access") — the SINGLE JSON-reading implementation shared by
  ## `extractClosure` (below, a filter over this) and RFC-0006's M/R stages
  ## (which need the raw shape `extractClosure` deliberately discards).
  ##
  ## Returns the RAW, UNFILTERED `compile` array as `(cPath, ccCmd)` pairs —
  ## stdlib/nimble paths INCLUDED, cc commands INCLUDED — plus the RAW `link`
  ## array (every object path the linker consumes, external objects INCLUDED;
  ## empty if the manifest has no `link` array) and the `linkcmd` string.
  ## Does no path resolution, no under-root filtering, no @m/@p decoding:
  ## that is `extractClosure`'s job, not this proc's.
  ##
  ## An entry whose `cPath` is empty is skipped (matches the historical
  ## `extractClosure` guard — such an entry cannot name a compile unit).
  ##
  ## Raises `CrisolError(cekEnvironment)` if the JSON is missing, unparseable,
  ## or has no `compile` array.
  if not fileExists(jsonPath):
    raise newCrisolError(cekEnvironment,
      "nimcache JSON not found: " & jsonPath &
      " — was the entrypoint compiled with the expected -o: and --nimcache?")

  let jstr = readFile(jsonPath)
  var jnode: JsonNode
  try:
    jnode = parseJson(jstr)
  except JsonParsingError as e:
    raise newCrisolError(cekEnvironment,
      "failed to parse nimcache JSON at " & jsonPath & ": " & e.msg)

  let compileArr = jnode{"compile"}
  if compileArr == nil or compileArr.kind != JArray:
    raise newCrisolError(cekEnvironment,
      "nimcache JSON at " & jsonPath & " has no 'compile' array")

  var pairs: seq[tuple[cPath, ccCmd: string]] = @[]
  for pair in compileArr:
    if pair.kind != JArray or pair.len < 1: continue
    let cPath = pair[0].getStr("")
    if cPath == "": continue
    let ccCmd = if pair.len >= 2: pair[1].getStr("") else: ""
    pairs.add (cPath: cPath, ccCmd: ccCmd)

  var link: seq[string] = @[]
  let linkArr = jnode{"link"}
  if linkArr != nil and linkArr.kind == JArray:
    for o in linkArr:
      let oPath = o.getStr("")
      if oPath != "": link.add oPath

  result = (compile: pairs, link: link, linkcmd: jnode{"linkcmd"}.getStr(""))

proc extractClosure*(nimcacheDir: string;
                     binaryName: string;
                     entrypoint: string;
                     config: Config;
                     index: SourceIndex): HashSet[string] =
  ## Extract the source-dependency closure for one compiled entrypoint.
  ##
  ## Parameters:
  ##   `nimcacheDir`  — the `--nimcache` directory used to compile `entrypoint`.
  ##   `binaryName`   — the basename of the `-o:` binary (used to locate the
  ##                    JSON: `<nimcacheDir>/<binaryName>.json`).
  ##   `entrypoint`   — absolute (or project-root-relative) path to the `.nim`
  ##                    source file.
  ##   `config`       — must have `projectRoot` set; may have `depRoots`.
  ##   `index`        — a `SourceIndex` (`buildSourceIndex(config)`), used to
  ##                    resolve `@p`/`@n` bodies (issue #8).  Built ONCE per
  ##                    run by the caller (`runner.execute`) — never rebuild
  ##                    per entrypoint; the overload below builds one ad hoc
  ##                    for tests/one-off callers.
  ##
  ## Returns a `HashSet[string]` of projectRoot-relative, forward-slash paths.
  ##
  ## Raises `CrisolError(cekEnvironment)` if the JSON is missing or unparseable.
  ##
  ## A FILTER over `parseCompileManifest`'s raw `link` array (RFC-0006 §File
  ## scoping): stdlib/nimble paths and external objects are deliberately
  ## dropped here — `parseCompileManifest` is the shape that keeps them.
  ##
  ## Reads `link`, NEVER `compile` (issue #5): `compile` is the per-invocation
  ## C work list and is partial/empty on a warm nimcache, so a closure built
  ## from it shrinks to nothing on the first incremental recompile and
  ## permanently disables invalidation.  `link` is complete on every compile.
  ##
  ## Raises `CrisolError(cekEnvironment)` if `link` is empty: a linked binary
  ## has at least its main module's object, so an empty `link` is a malformed
  ## manifest, never a real (empty) closure.

  let jsonPath = nimcacheDir / binaryName & ".json"
  let manifest = parseCompileManifest(jsonPath)
  if manifest.link.len == 0:
    raise newCrisolError(cekEnvironment,
      "nimcache JSON at " & jsonPath & " has no 'link' entries" &
      " — cannot derive the source closure")

  let epAbs = entrypoint.absolutePath.normalizedPath
  let prAbs = config.projectRoot.absolutePath.normalizedPath

  result = initHashSet[string]()

  for objPath in manifest.link:
    # moduleMangledNameOf applies the ".nim.{c,cpp,m}.o" module-object contract:
    # only Nim-generated module objects satisfy it — a `{.compile.}`d C/C++
    # external or foreign object/archive names no Nim module and yields "".
    let mangledName = moduleMangledNameOf(objPath)
    if mangledName == "": continue

    # R5+R7 fix: resolveMangledAll returns ALL candidate paths (possibly multiple
    # for ambiguous @p/@n entries, possibly none for deps no longer on disk).
    let candidates = resolveMangledAll(mangledName, epAbs, index)
    for resolved in candidates:
      if resolved == "": continue            # (shouldn't occur, but be defensive)

      # Under-tracked-root filter: the SOUNDNESS gate. Keeps only what lives
      # under projectRoot or a depRoot — `index.roots`/`underAnyRoot` is the
      # single source of truth for "tracked", shared with `resolveMangledAll`'s
      # `@m` escape check (no separate, independently-computed root list).
      # Stdlib/nimble paths are excluded here. Existence is NOT checked (R5):
      # deleted deps remain in the closure.
      if not index.underAnyRoot(resolved): continue

      # Convert to projectRoot-relative, forward slashes.
      result.incl toProjectRelative(resolved, prAbs)

proc extractClosure*(nimcacheDir: string;
                     binaryName: string;
                     entrypoint: string;
                     config: Config): HashSet[string] =
  ## Convenience overload for tests/one-offs: builds a fresh `SourceIndex`
  ## from `config` and delegates.  Production callers (`depgraph.recordClosure`
  ## via `runner.execute`) build the index ONCE per run instead — see the
  ## 5-arg overload above.
  extractClosure(nimcacheDir, binaryName, entrypoint, config, buildSourceIndex(config))
