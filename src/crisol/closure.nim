## closure.nim — source-dependency closure extractor for one entrypoint (D1).
##
## Reads the per-build nimcache JSON produced by `nim c` and extracts the
## transitive set of `.nim` source files the entrypoint depends on, filtered
## to files that live under a *tracked root* (projectRoot or a configured
## depRoot).  Stdlib, nimble-package paths, and anything that cannot be
## resolved to a tracked root are silently excluded.
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
## `moduleCPathOf` (below) is the single place that applies this
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
## - `@p<body>` — body is a path relative to whichever search-path root
##   resolved it (stdlib dir, nimble pkg dir, or a project `--path` root
##   such as `src/`).  crisol cannot know which root from the mangled name,
##   so it tries each tracked root in order: `projectRoot`, `projectRoot/src`,
##   then each `depRoot` and `depRoot/src`.  The first that names an existing
##   file wins.  If none matches → stdlib/nimble → excluded.
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
## libraries) are excluded by `moduleCPathOf`'s `.nim.{c,cpp,m}.o` filter —
## they may be `@m`-mangled too, but never end in `.nim.c.o` / `.nim.cpp.o` /
## `.nim.m.o`, so they never name a Nim module in the first place.
##
## ## Error handling
##
## A missing or unparse­able JSON raises `CrisolError(kind: cekEnvironment)`.
## The caller (D2/D6) decides recovery policy; the conservative fallback
## (run the entrypoint regardless) is a later-slice concern.

import std/[json, os, sets, strutils]
import crisol/types

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc trackedRoots(config: Config): seq[string] =
  ## Ordered list of directories to try when resolving `@p` bodies.
  ## For each root R we include R itself and R/src (the universal src layout).
  result = @[]
  let pr = config.projectRoot.absolutePath.normalizedPath
  result.add pr
  result.add pr / "src"
  for dr in config.depRoots:
    let d = dr.absolutePath.normalizedPath
    result.add d
    result.add d / "src"

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
  ## Decode @s → /, @@ → @ in the post-prefix mangled body string.
  raw
    .replace("@@", "\x00")   # protect literal @ temporarily
    .replace("@s", $DirSep)  # @s → path separator
    .replace("\x00", "@")    # restore literal @

proc moduleCPathOf(objPath: string): string =
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
                       roots: seq[string]): seq[string] =
  ## Decode one mangled module name (`moduleCPathOf`'s output — the
  ## compile-unit basename with the backend extension and `.o` already
  ## stripped, e.g. `@mfoo.nim`) to zero or more absolute `.nim` candidate
  ## paths.
  ##
  ## For `@m`: exactly one candidate (entrypointDir/body), existence not checked
  ##           (R5: record deleted deps too).
  ## For `@p`: ALL tracked roots that produce a valid candidate path are returned,
  ##           regardless of whether the file currently exists on disk (R5+R7 fix):
  ##           - R5: a dep that was deleted still appears as a candidate from its
  ##             original root → the closure records it → narrowByDiff detects the
  ##             deletion in git diff.
  ##           - R7: when multiple roots could have provided the file (ambiguous),
  ##             ALL are recorded (over-selection) so a change to any copy triggers
  ##             re-selection.
  ## For anything else: empty list (conservative).
  # `mangledName` is `moduleCPathOf`'s output — already ".nim.{c,cpp,m}.o"
  # filtered, backend extension and ".o" stripped — so it is always
  # "<@m|@p><body>.nim" here; see that proc's doc comment for the
  # module-object contract this relies on.
  if not (mangledName.startsWith("@m") or mangledName.startsWith("@p")):
    return @[]                               # unknown prefix — exclude

  let noPrefix = mangledName[2 .. ^1]        # strip "@m" or "@p"
  let body     = decodeBody(noPrefix)        # decode @s/@@ escapes

  if mangledName.startsWith("@m"):
    # Relative to the entrypoint's source directory.
    # Single candidate; do NOT check existence (R5: record deleted deps).
    let epDir = entrypointPath.absolutePath.parentDir
    result = @[(epDir / body).normalizedPath]

  else: # "@p"
    # R7 fix: generate candidates from ALL tracked roots where the file EXISTS.
    # When multiple roots have the file (ambiguous), record all of them so a
    # change to any copy triggers re-selection (over-selection, safe).
    # When no root has the file: the file is from stdlib/nimble/was deleted;
    # return empty so the under-root filter excludes it.  For deleted @p deps,
    # the previous closure still holds the path and isEntryStale (R4 fix) will
    # detect the missing file and force a re-run, so soundness is maintained
    # via the stale-entry path rather than the closure-rebuild path.
    result = @[]
    for root in roots:
      let candidate = (root / body).normalizedPath
      if fileExists(candidate):
        result.add candidate

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
                     config: Config): HashSet[string] =
  ## Extract the source-dependency closure for one compiled entrypoint.
  ##
  ## Parameters:
  ##   `nimcacheDir`  — the `--nimcache` directory used to compile `entrypoint`.
  ##   `binaryName`   — the basename of the `-o:` binary (used to locate the
  ##                    JSON: `<nimcacheDir>/<binaryName>.json`).
  ##   `entrypoint`   — absolute (or project-root-relative) path to the `.nim`
  ##                    source file.
  ##   `config`       — must have `projectRoot` set; may have `depRoots`.
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

  let roots      = trackedRoots(config)
  let epAbs      = entrypoint.absolutePath.normalizedPath
  let prAbs      = config.projectRoot.absolutePath.normalizedPath

  # Collect all tracked roots for the under-root filter.
  # A candidate is kept iff it lives under projectRoot OR any depRoot.
  var trackedDirs: seq[string] = @[prAbs]
  for dr in config.depRoots:
    trackedDirs.add dr.absolutePath.normalizedPath

  result = initHashSet[string]()

  for objPath in manifest.link:
    # moduleCPathOf applies the ".nim.{c,cpp,m}.o" module-object contract:
    # only Nim-generated module objects satisfy it — a `{.compile.}`d C/C++
    # external or foreign object/archive names no Nim module and yields "".
    let mangledName = moduleCPathOf(objPath)
    if mangledName == "": continue

    # R5+R7 fix: resolveMangledAll returns ALL candidate paths (possibly multiple
    # for ambiguous @p entries, possibly non-existent for deleted deps).
    let candidates = resolveMangledAll(mangledName, epAbs, roots)
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
