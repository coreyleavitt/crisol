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
## - `@m<body>` — body is a path relative to the *entrypoint's source
##   directory* (not the CWD).  Candidate = normalize(entrypointDir / body).
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

proc addToIndex(index: var SourceIndex; lexical: string; real: string) =
  let base = lexical.extractFilename
  index.byBasename.mgetOrPut(base, @[]).add IndexedFile(lexical: lexical, real: real)

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
  result = SourceIndex(byBasename: initTable[string, seq[IndexedFile]]())
  let stateDirAbs = stateDirOf(config)

  let prAbs = config.projectRoot.absolutePath.normalizedPath
  if dirExists(prAbs):
    walkForIndex(prAbs, prAbs, stateDirAbs, result)

  for dr in config.depRoots:
    let drAbs = dr.absolutePath.normalizedPath
    if dirExists(drAbs):
      walkForIndex(drAbs, drAbs, stateDirAbs, result)

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
  ## Every LEADING `""`/`"."`/`".."` component is therefore stripped before
  ## matching — this is a pure WIDENING of the suffix match (a shorter
  ## suffix can only match more indexed files, never fewer), so it stays
  ## sound under the R7 over-selection policy: ambiguous/spurious matches
  ## are acceptable (they only over-select), silent drops are not.
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
  result = @[]
  let normBody = body.replace('\\', DirSep).replace('/', DirSep)
  var comps = normBody.split(DirSep)
  var start = 0
  while start < comps.len and comps[start] in ["", ".", ".."]:
    inc start
  if start >= comps.len: return
  let sufComps = comps[start .. ^1]
  let base = sufComps[^1]
  if base notin index.byBasename: return
  let suffix = sufComps.join($DirSep)
  let suffixPattern = $DirSep & suffix
  var seen = initHashSet[string]()
  for f in index.byBasename[base]:
    if f.lexical.endsWith(suffixPattern) or f.real.endsWith(suffixPattern):
      if f.lexical notin seen:
        seen.incl f.lexical
        result.add f.lexical

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc isUnderRoot(path: string; root: string): bool =
  ## True iff `path` (normalised absolute) starts with `root` followed by a
  ## path separator (or equals root exactly).  Both arguments must be absolute
  ## and already normalised.
  if path == root: return true
  path.startsWith(root & $DirSep)

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
  ## For `@m`: exactly one candidate (entrypointDir/body), existence not checked
  ##           (R5: record deleted deps too).
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
    # Relative to the entrypoint's source directory.
    # Single candidate; do NOT check existence (R5: record deleted deps).
    let epDir = entrypointPath.absolutePath.parentDir
    result = @[(epDir / body).normalizedPath]

  else: # "@p" or "@n"
    result = index.lookup(body)

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

  # Collect all tracked roots for the under-root filter.
  # A candidate is kept iff it lives under projectRoot OR any depRoot.
  var trackedDirs: seq[string] = @[prAbs]
  for dr in config.depRoots:
    trackedDirs.add dr.absolutePath.normalizedPath

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

      # Under-tracked-root filter: the SOUNDNESS gate. Keeps only what lives under
      # projectRoot or a depRoot. Stdlib/nimble paths are excluded here.
      # Existence is NOT checked (R5): deleted deps remain in the closure.
      var underTracked = false
      for dir in trackedDirs:
        if isUnderRoot(resolved, dir):
          underTracked = true
          break
      if not underTracked: continue

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
